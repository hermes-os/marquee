import SwiftUI

// MARK: - Movie Detail View

struct MovieDetailView: View {
    let item: MediaItem
    @ObservedObject var appState: AppState
    @ObservedObject var library: LibraryState
    let onSelectItem: (MediaItem) -> Void
    let dismiss: () -> Void
    var onNavigateToSidebar: () -> Void = {}

    @State private var showFullSynopsis: Bool = false
    @State private var focusState = FocusEngineState(focused: DetailFocusIDs.movieStart)
    @State private var moreLikeFocusedIndex: Int = 0
    @State private var personFocusedRowIndex: Int = 0
    @State private var personFocusedItemIndex: Int = 0
    @State private var scrollGate = RemoteScrollRequestGate()
    @State private var deferredSectionsVisible: Bool = false
    @State private var deferredSectionsRequestID: Int = 0
    @StateObject private var detailScrollController = DetailScrollController()
    @State private var detailScrollOffset: CGFloat = 0
    @State private var moreLikeRowViewportTop: CGFloat?
    @State private var personRowViewportTops: [String: CGFloat] = [:]
    @State private var movieShowMoreViewportTop: CGFloat?
    @State private var pendingFocusTransition: DetailFocusTransition?
    @State private var pendingPlacementCorrection: PendingDetailPlacementCorrection?
    @State private var cachedSimilarItems: [MediaItem] = []
    @State private var cachedPersonRows: [BrowsePersonMediaRow] = []
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.kidsMode) private var kidsMode
    @Environment(\.leanBackMode) private var leanBackMode
    @EnvironmentObject private var remoteInput: RemoteInputRouter

    private var heroHeight: CGFloat {
        MarqueeTheme.scaled(400, leanBack: 560, isLeanBack: leanBackMode)
    }

    private var heroPosterWidth: CGFloat {
        MarqueeTheme.scaled(138, leanBack: 210, isLeanBack: leanBackMode)
    }

    private var heroPosterHeight: CGFloat {
        heroPosterWidth * 1.5
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            (kidsMode ? MarqueeTheme.kidsBackground : MarqueeTheme.background).ignoresSafeArea()

            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        heroSection
                            .id(DetailFocusScrollIDs.movieTop)
                        contentArea
                    }
                    .background(
                        DetailScrollObserver(
                            offset: $detailScrollOffset,
                            controller: detailScrollController
                        )
                        .frame(width: 0, height: 0)
                    )
                }
                .coordinateSpace(name: DetailScrollCoordinateSpace.name)
                .onAppear {
                    reconcileRemoteFocus()
                    scrollToRemoteFocus(proxy: proxy, animated: false)
                    stageDeferredSections()
                    MarqueeSignpost.event("detail-appeared", "movie")
                    #if DEBUG
                    NotificationCenter.default.post(name: .marqueeQADetailSurfaceAppeared, object: "movie")
                    #endif
                }
                .onChange(of: item.id) { _ in
                    resetRemoteFocus()
                    scrollToRemoteFocus(proxy: proxy, animated: false)
                    stageDeferredSections()
                }
                .onChange(of: BrowseSnapshotDetailRevision(snapshot: library.browseSnapshot)) { _ in
                    refreshCachedDeferredSections()
                }
                .onChange(of: focusState.focused) { _ in
                    preheatFocusedMoreLikeArtwork()
                    scrollToRemoteFocus(proxy: proxy, animated: true)
                }
                .onReceive(remoteInput.events) { event in
                    handleRemoteEvent(event)
                }
                .onPreferenceChange(DetailRelatedRowViewportTopPreferenceKey.self) { rowTop in
                    moreLikeRowViewportTop = DetailPlacementGeometry.sanitizedViewportTop(rowTop)
                    applyPendingPlacementCorrectionIfNeeded(animated: false)
                }
                .onPreferenceChange(MovieSynopsisFocusViewportTopPreferenceKey.self) { focusTop in
                    movieShowMoreViewportTop = DetailPlacementGeometry.sanitizedViewportTop(focusTop)
                    applyPendingPlacementCorrectionIfNeeded(animated: false)
                }
                .onPreferenceChange(DetailPersonRowViewportTopPreferenceKey.self) { rowTops in
                    personRowViewportTops = rowTops.compactMapValues {
                        DetailPlacementGeometry.sanitizedViewportTop($0)
                    }
                    applyPendingPlacementCorrectionIfNeeded(animated: false)
                }
            }

            backButton
        }
    }

    private func handleRemoteEvent(_ event: RemoteCommandEvent) {
        guard !appState.playerController.isPlayerPresented else { return }
        guard event.consume() else { return }

        switch event.command {
        case .select:
            AudioIdentityService.shared.playFeedback(for: .select)
            selectRemoteFocus()
        case .back:
            AudioIdentityService.shared.playFeedback(for: .back)
            dismiss()
        case .left:
            moveRemoteFocus(.left)
        case .right:
            moveRemoteFocus(.right)
        case .up:
            moveRemoteFocus(.up)
        case .down:
            moveRemoteFocus(.down)
        }
    }

    // MARK: - Content Area

    private var contentArea: some View {
        VStack(alignment: .leading, spacing: MarqueeTheme.sectionSpacing(isLeanBack: leanBackMode)) {
            actionButtons
                .id("movie-detail-actions")
            synopsisSection
            directorSection
            if deferredSectionsVisible {
                castRow
                moreLikeThisSection
                personRowsSection
                fileInfoSection
            }
        }
        .padding(.horizontal, MarqueeTheme.outerPadding(isLeanBack: leanBackMode))
        .padding(.bottom, MarqueeTheme.scaled(100, leanBack: 150, isLeanBack: leanBackMode))
    }

    // MARK: - Back Button

    private var backButton: some View {
        Button(action: dismiss) {
            Image(systemName: "chevron.left")
                .font(.system(size: MarqueeTheme.scaled(14, leanBack: 22, isLeanBack: leanBackMode), weight: .semibold))
                .frame(
                    width: DetailBackChromeLayout.buttonSize(isLeanBack: leanBackMode),
                    height: DetailBackChromeLayout.buttonSize(isLeanBack: leanBackMode)
                )
            .foregroundColor(MarqueeTheme.textPrimary)
            .background(
                Circle()
                    .fill(Color.black.opacity(0.78))
                    .overlay(
                        Circle()
                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Back")
        .help("Back")
        .detailFocusSurface(
            isFocused: isFocused(DetailFocusIDs.movieBack),
            cornerRadius: 999,
            accent: detailFocusAccent
        )
        .padding(.top, MarqueeTheme.scaled(16, leanBack: 26, isLeanBack: leanBackMode))
        .padding(.leading, DetailBackChromeLayout.leadingPadding(isLeanBack: leanBackMode))
    }

    // MARK: - Hero Section

    private var heroSection: some View {
        ZStack(alignment: .bottomLeading) {
            detailHeroFallback

            if let path = item.displayBackdropPath {
                CachedImageView(
                    path: path,
                    contentMode: .fill,
                    thumbnailPixelSize: ArtworkCache.heroBackdropThumbnailPixelSize,
                    placeholderFillOpacity: 0,
                    placeholderIconOpacity: 0
                )
                    .id(path)
                    .frame(height: heroHeight)
                    .frame(maxWidth: .infinity)
                    .clipped()
            }

            LinearGradient(
                colors: [
                    Color.clear,
                    (kidsMode ? MarqueeTheme.kidsBackground : MarqueeTheme.background).opacity(0.6),
                    kidsMode ? MarqueeTheme.kidsBackground : MarqueeTheme.background,
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            heroTitleOverlay
        }
        .frame(height: heroHeight)
        .clipped()
    }

    private var detailHeroFallback: some View {
        ZStack {
            LinearGradient(
                colors: [
                    MarqueeTheme.surfaceElevated,
                    kidsMode ? MarqueeTheme.kidsBackground : MarqueeTheme.background,
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            if let posterPath = item.displayPosterPath {
                CachedImageView(
                    path: posterPath,
                    contentMode: .fill,
                    thumbnailPixelSize: ArtworkCache.gridPosterThumbnailPixelSize,
                    placeholderFillOpacity: 0,
                    placeholderIconOpacity: 0
                )
                .id(posterPath)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .scaleEffect(1.34)
                .blur(radius: 14)
                .saturation(1.16)
                .contrast(1.08)
                .opacity(0.58)

                LinearGradient(
                    colors: [
                        Color.black.opacity(0.18),
                        Color.black.opacity(0.34),
                        (kidsMode ? MarqueeTheme.kidsBackground : MarqueeTheme.background).opacity(0.78),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            }
        }
        .frame(height: heroHeight)
    }

    private var heroTitleOverlay: some View {
        HStack(alignment: .bottom, spacing: MarqueeTheme.scaled(28, leanBack: 42, isLeanBack: leanBackMode)) {
            VStack(alignment: .leading, spacing: 10) {
                Text(item.displayTitle)
                    .font(.system(size: MarqueeTheme.scaled(36, leanBack: 52, isLeanBack: leanBackMode), weight: .bold))
                    .foregroundColor(MarqueeTheme.textPrimary)
                    .lineLimit(2)

                metadataRow
            }
            .frame(maxWidth: MarqueeTheme.scaled(760, leanBack: 1040, isLeanBack: leanBackMode), alignment: .leading)

            Spacer(minLength: 0)

            heroPosterPreview
        }
        .padding(.horizontal, MarqueeTheme.outerPadding(isLeanBack: leanBackMode))
        .padding(.bottom, MarqueeTheme.scaled(24, leanBack: 38, isLeanBack: leanBackMode))
    }

    @ViewBuilder
    private var heroPosterPreview: some View {
        if let posterPath = item.displayPosterPath {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: MarqueeTheme.cornerRadiusMD)
                    .fill(MarqueeTheme.surfaceLayer)

                CachedImageView(
                    path: posterPath,
                    contentMode: .fill,
                    thumbnailPixelSize: ArtworkCache.gridPosterThumbnailPixelSize
                )
                .id(posterPath)
                .frame(width: heroPosterWidth, height: heroPosterHeight)
                .clipped()

                Text(item.formatBadge)
                    .font(.system(size: MarqueeTheme.scaled(10, leanBack: 14, isLeanBack: leanBackMode), weight: .bold, design: .monospaced))
                    .foregroundColor(MarqueeTheme.textPrimary)
                    .padding(.horizontal, MarqueeTheme.scaled(8, leanBack: 12, isLeanBack: leanBackMode))
                    .padding(.vertical, MarqueeTheme.scaled(4, leanBack: 6, isLeanBack: leanBackMode))
                    .background(
                        Capsule()
                            .fill(Color.black.opacity(0.58))
                    )
                    .padding(MarqueeTheme.scaled(8, leanBack: 12, isLeanBack: leanBackMode))
            }
            .frame(width: heroPosterWidth, height: heroPosterHeight)
            .clipShape(RoundedRectangle(cornerRadius: MarqueeTheme.cornerRadiusMD))
            .overlay(
                RoundedRectangle(cornerRadius: MarqueeTheme.cornerRadiusMD)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.45), radius: 22, y: 14)
        }
    }

    // MARK: - Metadata Row

    private var metadataRow: some View {
        HStack(spacing: MarqueeTheme.scaled(16, leanBack: 22, isLeanBack: leanBackMode)) {
            if let year = item.displayYear {
                Text(year)
                    .foregroundColor(MarqueeTheme.textPrimary)
            }

            certificationBadge

            if let runtime = item.displayRuntime {
                Text(runtime)
                    .foregroundColor(MarqueeTheme.textSecondary)
            }

            starRating

            genreTags
        }
        .font(.system(size: MarqueeTheme.scaled(13, leanBack: 18, isLeanBack: leanBackMode), weight: .medium))
    }

    @ViewBuilder
    private var certificationBadge: some View {
        let cert = item.metadata?.certification ?? item.contentRating
        if let cert = cert, !cert.isEmpty {
            Text(cert)
                .font(.system(size: MarqueeTheme.scaled(11, leanBack: 15, isLeanBack: leanBackMode), weight: .semibold))
                .foregroundColor(MarqueeTheme.textSecondary)
                .padding(.horizontal, MarqueeTheme.scaled(8, leanBack: 12, isLeanBack: leanBackMode))
                .padding(.vertical, MarqueeTheme.scaled(3, leanBack: 5, isLeanBack: leanBackMode))
                .overlay(
                    Capsule()
                        .strokeBorder(MarqueeTheme.textTertiary, lineWidth: 1)
                )
        }
    }

    @ViewBuilder
    private var starRating: some View {
        if let vote = item.metadata?.voteAverage, vote > 0 {
            HStack(spacing: 4) {
                Image(systemName: "star.fill")
                    .font(.system(size: MarqueeTheme.scaled(11, leanBack: 16, isLeanBack: leanBackMode)))
                    .foregroundColor(MarqueeTheme.accentSecondary)
                Text(String(format: "%.1f", vote))
                    .foregroundColor(MarqueeTheme.textPrimary)
            }
        }
    }

    @ViewBuilder
    private var genreTags: some View {
        let genres = item.displayGenres
        if !genres.isEmpty {
            ForEach(genres.prefix(3), id: \.self) { genre in
                Text(genre)
                    .font(.system(size: MarqueeTheme.scaled(11, leanBack: 16, isLeanBack: leanBackMode), weight: .medium))
                    .foregroundColor(MarqueeTheme.textSecondary)
                    .padding(.horizontal, MarqueeTheme.scaled(10, leanBack: 14, isLeanBack: leanBackMode))
                    .padding(.vertical, MarqueeTheme.scaled(4, leanBack: 7, isLeanBack: leanBackMode))
                    .background(
                        Capsule()
                            .fill(MarqueeTheme.surfaceLayer)
                    )
            }
        }
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack(spacing: MarqueeTheme.scaled(12, leanBack: 18, isLeanBack: leanBackMode)) {
            Button(action: { appState.playItem(item, fromStart: true) }) {
                HStack(spacing: MarqueeTheme.scaled(8, leanBack: 12, isLeanBack: leanBackMode)) {
                    Image(systemName: "play.fill")
                        .font(.system(size: MarqueeTheme.scaled(14, leanBack: 21, isLeanBack: leanBackMode)))
                    Text("Start From Beginning")
                        .font(.system(size: MarqueeTheme.scaled(15, leanBack: 22, isLeanBack: leanBackMode), weight: .bold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, MarqueeTheme.scaled(28, leanBack: 42, isLeanBack: leanBackMode))
                .padding(.vertical, MarqueeTheme.scaled(12, leanBack: 18, isLeanBack: leanBackMode))
                .background(
                    RoundedRectangle(cornerRadius: MarqueeTheme.cornerRadiusMD)
                        .fill(
                            LinearGradient(
                                colors: [
                                    MarqueeTheme.accentSecondary,
                                    MarqueeTheme.accentSecondary.opacity(0.85),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                    )
                )
            }
            .buttonStyle(.plain)
            .detailFocusSurface(
                isFocused: isFocused(DetailFocusIDs.movieStart),
                cornerRadius: MarqueeTheme.cornerRadiusMD,
                accent: detailFocusAccent
            )
            .accessibilityLabel("Start \(item.displayTitle) from beginning")

            if item.hasProgress {
                Button(action: { appState.playItem(item) }) {
                    HStack(spacing: MarqueeTheme.scaled(8, leanBack: 12, isLeanBack: leanBackMode)) {
                        Image(systemName: "play.fill")
                            .font(.system(size: MarqueeTheme.scaled(12, leanBack: 18, isLeanBack: leanBackMode)))
                        Text("Resume at \(item.playbackPosition.formattedPlaybackTime)")
                            .font(.system(size: MarqueeTheme.scaled(13, leanBack: 19, isLeanBack: leanBackMode), weight: .semibold))
                    }
                    .foregroundColor(MarqueeTheme.textPrimary)
                    .padding(.horizontal, MarqueeTheme.scaled(20, leanBack: 30, isLeanBack: leanBackMode))
                    .padding(.vertical, MarqueeTheme.scaled(12, leanBack: 18, isLeanBack: leanBackMode))
                    .background(
                        RoundedRectangle(cornerRadius: MarqueeTheme.cornerRadiusMD)
                            .fill(MarqueeTheme.surfaceLayer)
                    )
                }
                .buttonStyle(.plain)
                .detailFocusSurface(
                    isFocused: isFocused(DetailFocusIDs.movieContinue),
                    cornerRadius: MarqueeTheme.cornerRadiusMD,
                    accent: detailFocusAccent
                )
                .accessibilityLabel("Resume \(item.displayTitle) at \(item.playbackPosition.formattedPlaybackTime)")
            }
        }
        .padding(.top, MarqueeTheme.scaled(4, leanBack: 8, isLeanBack: leanBackMode))
    }

    // MARK: - Synopsis Section

    @ViewBuilder
    private var synopsisSection: some View {
        if let overview = item.metadata?.overview, !overview.isEmpty {
            detailFocusContainer(isFocused: isFocused(DetailFocusIDs.movieShowMore)) {
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(title: "SYNOPSIS")

                    Text(overview)
                        .font(.system(size: MarqueeTheme.scaled(14, leanBack: 20, isLeanBack: leanBackMode), weight: .regular))
                        .foregroundColor(MarqueeTheme.textPrimary)
                        .lineSpacing(MarqueeTheme.scaled(4, leanBack: 6, isLeanBack: leanBackMode))
                        .lineLimit(showFullSynopsis ? nil : 3)

                    Button(action: {
                        withAnimation(reduceMotion ? .none : MarqueeTheme.cardHoverAnimation) {
                            showFullSynopsis.toggle()
                        }
                    }) {
                        Text(showFullSynopsis ? "Show Less" : "Show More")
                            .font(.system(size: MarqueeTheme.scaled(12, leanBack: 17, isLeanBack: leanBackMode), weight: .semibold))
                            .foregroundColor(MarqueeTheme.accentBright)
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(
                MovieSynopsisFocusViewportTopObserver()
                    .frame(height: 1)
                    .accessibilityHidden(true),
                alignment: .topLeading
            )
            .id(DetailFocusScrollIDs.movieShowMore)
        }
    }

    // MARK: - Director Section

    @ViewBuilder
    private var directorSection: some View {
        if let director = item.metadata?.director, !director.isEmpty {
            detailFocusContainer(isFocused: false) {
                HStack(spacing: 0) {
                    Text("Directed by ")
                        .font(.system(size: MarqueeTheme.scaled(14, leanBack: 20, isLeanBack: leanBackMode)))
                        .foregroundColor(MarqueeTheme.textSecondary)
                    Button(action: { openScopedSearch(prefix: "director", value: director) }) {
                        Text(director)
                            .font(.system(size: MarqueeTheme.scaled(14, leanBack: 20, isLeanBack: leanBackMode), weight: .semibold))
                            .foregroundColor(MarqueeTheme.textPrimary)
                    }
                    .buttonStyle(.plain)
                    .help("Search \(director)")
                }
            }
            .id("movie-detail-director")
        }
    }

    // MARK: - Cast Row

    @ViewBuilder
    private var castRow: some View {
        if let cast = item.metadata?.cast, !cast.isEmpty {
            detailFocusContainer(isFocused: false) {
                VStack(alignment: .leading, spacing: MarqueeTheme.sectionHeaderToContent(isLeanBack: leanBackMode)) {
                    SectionHeader(title: "CAST")

                    ArrowedScrollRow(ids: Array(cast.prefix(20).map(\.name))) {
                        HStack(spacing: MarqueeTheme.scaled(16, leanBack: 24, isLeanBack: leanBackMode)) {
                            ForEach(cast.prefix(20), id: \.name) { entry in
                                castMemberView(entry)
                                    .id(entry.name)
                            }
                        }
                    }
                }
            }
            .id("movie-detail-cast")
        }
    }

    private func castMemberView(_ entry: TMDBMetadata.CastEntry) -> some View {
        Button(action: { openScopedSearch(prefix: "cast", value: entry.name) }) {
            VStack(spacing: 6) {
                Circle()
                    .fill(MarqueeTheme.surfaceLayer)
                    .frame(
                        width: MarqueeTheme.scaled(64, leanBack: 92, isLeanBack: leanBackMode),
                        height: MarqueeTheme.scaled(64, leanBack: 92, isLeanBack: leanBackMode)
                    )
                    .overlay(
                        Text(entry.name.initials)
                            .font(.system(size: MarqueeTheme.scaled(18, leanBack: 26, isLeanBack: leanBackMode), weight: .semibold))
                            .foregroundColor(MarqueeTheme.textSecondary)
                    )

                Text(entry.name)
                    .font(.system(size: MarqueeTheme.scaled(11, leanBack: 16, isLeanBack: leanBackMode), weight: .medium))
                    .foregroundColor(MarqueeTheme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)

                Text(entry.character)
                    .font(.system(size: MarqueeTheme.scaled(10, leanBack: 14, isLeanBack: leanBackMode)))
                    .foregroundColor(MarqueeTheme.textTertiary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .frame(width: MarqueeTheme.scaled(100, leanBack: 145, isLeanBack: leanBackMode))
        }
        .buttonStyle(.plain)
        .help("Search \(entry.name)")
    }

    // MARK: - More Like This

    @ViewBuilder
    private var moreLikeThisSection: some View {
        let similar = similarItems
        let cardWidth = MarqueeTheme.scaled(120, leanBack: 180, isLeanBack: leanBackMode)
        let cardGap = MarqueeTheme.cardGap(isLeanBack: leanBackMode)
        if !similar.isEmpty {
            VStack(alignment: .leading, spacing: MarqueeTheme.sectionHeaderToContent(isLeanBack: leanBackMode)) {
                SectionHeader(title: "MORE LIKE THIS")
                    .padding(.top, DetailRelatedRowLayout.topClearance(isLeanBack: leanBackMode))
                    .id(DetailRelatedRowLayout.scrollAnchorID)

                DetailRelatedRowViewportTopObserver()
                    .frame(height: 1)
                    .accessibilityHidden(true)

                ArrowedScrollRow(
                    ids: similar.map(\.id),
                    focusedID: focusedMoreLikeItemID,
                    focusItemExtent: cardWidth,
                    focusItemSpacing: cardGap,
                    focusScrollMode: .detailRow,
                    hoverArrowsEnabled: RemotePointerRegionPolicy.rowHoverControlsEnabled(
                        isKeyboardFocusActive: isMoreLikeRemoteFocused
                    )
                ) {
                    LazyHStack(alignment: .top, spacing: cardGap) {
                        ForEach(Array(similar.enumerated()), id: \.element.id) { index, relatedItem in
                            MovieCard(
                                item: relatedItem,
                                cardWidth: cardWidth,
                                isRemoteFocused: isFocused(DetailFocusIDs.movieMoreLike(index)),
                                focusAccent: detailFocusAccent
                            ) {
                                onSelectItem(relatedItem)
                            }
                            .id(relatedItem.id)
                        }
                    }
                }
            }
        }
    }

    private var similarItems: [MediaItem] {
        cachedSimilarItems
    }

    private var deferredSourceItem: MediaItem {
        library.filteredLibraryItems.first { $0.id == item.id } ?? item
    }

    private var personRows: [BrowsePersonMediaRow] {
        cachedPersonRows
    }

    @ViewBuilder
    private var personRowsSection: some View {
        let rows = personRows
        if !rows.isEmpty {
            ForEach(rows.indices, id: \.self) { rowIndex in
                let row = rows[rowIndex]
                MediaItemRow(
                    title: row.title,
                    items: row.items,
                    focusedItemID: focusedPersonItemID(rowIndex: rowIndex),
                    focusScrollMode: .detailRow,
                    onSelect: { onSelectItem($0) }
                )
                .background(alignment: .topLeading) {
                    DetailPersonRowViewportTopObserver(rowID: row.id)
                        .frame(height: 1)
                        .accessibilityHidden(true)
                }
                .id(DetailFocusScrollIDs.moviePersonRow(row.id))
            }
        }
    }

    private var hasSynopsis: Bool {
        guard let overview = item.metadata?.overview else { return false }
        return !overview.isEmpty
    }

    private var focusedMoreLikeItemID: MediaItem.ID? {
        let similar = similarItems
        guard similar.indices.contains(moreLikeFocusedIndex) else { return nil }
        return similar[moreLikeFocusedIndex].id
    }

    private var isMoreLikeRemoteFocused: Bool {
        DetailFocusIDs.movieMoreLikeIndex(from: focusState.focused) != nil
    }

    private var detailFocusAccent: Color {
        kidsMode ? MarqueeTheme.kidsAccent : MarqueeTheme.accentPrimary
    }

    @ViewBuilder
    private func detailFocusContainer<Content: View>(
        isFocused: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(.horizontal, MarqueeTheme.scaled(12, leanBack: 18, isLeanBack: leanBackMode))
            .padding(.vertical, MarqueeTheme.scaled(10, leanBack: 15, isLeanBack: leanBackMode))
            .background(
                ZStack {
                    if isFocused {
                        RoundedRectangle(cornerRadius: MarqueeTheme.cornerRadiusMD)
                            .fill(MarqueeTheme.surfaceElevated.opacity(0.85))
                    }
                }
            )
            .overlay(
                ZStack {
                    if isFocused {
                        RoundedRectangle(cornerRadius: MarqueeTheme.cornerRadiusMD)
                            .strokeBorder(detailFocusAccent.opacity(0.85), lineWidth: 2.25)
                            .shadow(color: detailFocusAccent.opacity(0.45), radius: 22)
                    }
                }
            )
    }

    private func selectRemoteFocus() {
        reconcileRemoteFocus()

        let focus = focusState.focused
        if focus == DetailFocusIDs.movieBack {
            dismiss()
        } else if focus == DetailFocusIDs.movieStart {
            appState.playItem(item, fromStart: true)
        } else if focus == DetailFocusIDs.movieContinue {
            appState.playItem(item)
        } else if focus == DetailFocusIDs.movieShowMore {
            withAnimation(reduceMotion ? .none : MarqueeTheme.cardHoverAnimation) {
                showFullSynopsis.toggle()
            }
        } else if let index = DetailFocusIDs.movieMoreLikeIndex(from: focus) {
            let similar = similarItems
            guard similar.indices.contains(index) else { return }
            onSelectItem(similar[index])
            resetRemoteFocus()
        } else if let personIndex = DetailFocusIDs.moviePersonIndex(from: focus) {
            let rows = personRows
            guard rows.indices.contains(personIndex.row),
                  rows[personIndex.row].items.indices.contains(personIndex.item) else { return }
            onSelectItem(rows[personIndex.row].items[personIndex.item])
            resetRemoteFocus()
        }
    }

    private func moveRemoteFocus(_ direction: FocusDirection) {
        reconcileRemoteFocus()
        let previousFocus = focusState.focused
        let result = FocusEngine(root: movieDetailFocusTree()).move(direction, state: focusState)
        if direction == .left, DetailSidebarHandoffPolicy.shouldHandOff(direction: direction, events: result.events) {
            AudioIdentityService.shared.playFeedback(for: .left, didNavigate: true)
            onNavigateToSidebar()
            return
        }
        focusState = result.state
        syncFocusedIndexes()
        AudioIdentityService.shared.playFeedback(
            for: direction.remoteCommand,
            didNavigate: result.state.focused != previousFocus,
            focusEvents: result.events
        )
        recordPlacementTransition(from: previousFocus, direction: direction)
    }

    private func reconcileRemoteFocus() {
        let similarCount = deferredSectionsVisible ? similarItems.count : 0
        let rows = deferredSectionsVisible ? personRows : []
        moreLikeFocusedIndex = clampedMoreLikeIndex(count: similarCount)
        let personFocus = clampedPersonIndex(rows: rows)
        personFocusedRowIndex = personFocus.row
        personFocusedItemIndex = personFocus.item

        let focus = focusState.focused
        if focus == DetailFocusIDs.movieContinue, !item.hasProgress {
            focusState = FocusEngineState(focused: DetailFocusIDs.movieStart)
        } else if focus == DetailFocusIDs.movieShowMore, !hasSynopsis {
            focusState = FocusEngineState(focused: DetailFocusIDs.movieStart)
        } else if DetailFocusIDs.movieMoreLikeIndex(from: focus) != nil {
            guard similarCount > 0 else {
                focusState = FocusEngineState(focused: DetailFocusIDs.movieStart)
                return
            }
            focusState.focused = DetailFocusIDs.movieMoreLike(moreLikeFocusedIndex)
        } else if let personIndex = DetailFocusIDs.moviePersonIndex(from: focus) {
            guard !rows.isEmpty else {
                focusState = FocusEngineState(focused: DetailFocusIDs.movieStart)
                return
            }
            let clamped = clampedPersonIndex(
                rows: rows,
                proposedRow: personIndex.row,
                proposedItem: personIndex.item
            )
            personFocusedRowIndex = clamped.row
            personFocusedItemIndex = clamped.item
            focusState.focused = DetailFocusIDs.moviePerson(row: clamped.row, item: clamped.item)
        } else if focus != DetailFocusIDs.movieBack,
                  focus != DetailFocusIDs.movieStart,
                  focus != DetailFocusIDs.movieContinue,
                  focus != DetailFocusIDs.movieShowMore {
            focusState = FocusEngineState(focused: DetailFocusIDs.movieStart)
        }
    }

    private func resetRemoteFocus() {
        pendingFocusTransition = nil
        pendingPlacementCorrection = nil
        _ = scrollGate.issue()
        focusState = FocusEngineState(focused: DetailFocusIDs.movieStart)
        moreLikeFocusedIndex = 0
        personFocusedRowIndex = 0
        personFocusedItemIndex = 0
        showFullSynopsis = false
    }

    private func recordPlacementTransition(from previousFocus: FocusNodeID, direction: FocusDirection) {
        guard previousFocus != focusState.focused else { return }
        pendingFocusTransition = DetailFocusTransition(
            from: previousFocus,
            to: focusState.focused,
            direction: direction
        )
    }

    private func movieDetailFocusTree() -> FocusNode {
        let rows = deferredSectionsVisible ? personRows : []
        return DetailFocusTree.movie(MovieDetailFocusConfiguration(
            hasContinueAction: item.hasProgress,
            hasShowMore: hasSynopsis,
            moreLikeCount: deferredSectionsVisible ? similarItems.count : 0,
            preferredMoreLikeIndex: moreLikeFocusedIndex,
            personRowItemCounts: rows.map { $0.items.count },
            preferredPersonRowIndex: personFocusedRowIndex,
            preferredPersonItemIndex: personFocusedItemIndex
        ))
    }

    private func syncFocusedIndexes() {
        if let index = DetailFocusIDs.movieMoreLikeIndex(from: focusState.focused) {
            moreLikeFocusedIndex = clampedMoreLikeIndex(count: similarItems.count, proposed: index)
            focusState.focused = DetailFocusIDs.movieMoreLike(moreLikeFocusedIndex)
        } else if let personIndex = DetailFocusIDs.moviePersonIndex(from: focusState.focused) {
            let clamped = clampedPersonIndex(
                rows: personRows,
                proposedRow: personIndex.row,
                proposedItem: personIndex.item
            )
            personFocusedRowIndex = clamped.row
            personFocusedItemIndex = clamped.item
            focusState.focused = DetailFocusIDs.moviePerson(row: clamped.row, item: clamped.item)
        }
    }

    private func isFocused(_ id: FocusNodeID) -> Bool {
        focusState.focused == id
    }

    private func preheatFocusedMoreLikeArtwork() {
        guard let index = DetailFocusIDs.movieMoreLikeIndex(from: focusState.focused) else { return }
        let similar = similarItems
        guard similar.indices.contains(index) else { return }
        let item = similar[index]
        let posterSize = leanBackMode
            ? ArtworkCache.leanBackPosterThumbnailPixelSize
            : ArtworkCache.gridPosterThumbnailPixelSize
        ArtworkCache.shared.preloadVisiblePosters(
            paths: [item.displayPosterPath],
            pixelSize: posterSize,
            label: "movie-more-like-detail-poster"
        )
        ArtworkCache.shared.preloadVisiblePosters(
            paths: [item.displayBackdropPath],
            pixelSize: ArtworkCache.heroBackdropThumbnailPixelSize,
            label: "movie-more-like-detail-backdrop"
        )
    }

    private func stageDeferredSections() {
        deferredSectionsRequestID &+= 1
        let requestID = deferredSectionsRequestID
        deferredSectionsVisible = false
        cachedSimilarItems = []
        cachedPersonRows = []
        personRowViewportTops = [:]
        DispatchQueue.main.asyncAfter(deadline: .now() + DetailDeferredSectionPolicy.delay) {
            guard requestID == deferredSectionsRequestID else { return }
            let sourceItem = deferredSourceItem
            let nextSimilarItems = library.browseSnapshot.similarMovies(to: sourceItem, in: library.filteredLibraryItems, limit: 10)
            let nextPersonRows = BrowseLeanBackDelightPolicy.personRows(
                for: sourceItem,
                in: library.filteredLibraryItems,
                limit: 10
            )
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                cachedSimilarItems = nextSimilarItems
                cachedPersonRows = nextPersonRows
                deferredSectionsVisible = true
            }
        }
    }

    private func refreshCachedDeferredSections() {
        guard deferredSectionsVisible else { return }
        let sourceItem = deferredSourceItem
        cachedSimilarItems = library.browseSnapshot.similarMovies(to: sourceItem, in: library.filteredLibraryItems, limit: 10)
        cachedPersonRows = BrowseLeanBackDelightPolicy.personRows(
            for: sourceItem,
            in: library.filteredLibraryItems,
            limit: 10
        )
        let activeRowIDs = Set(cachedPersonRows.map(\.id))
        personRowViewportTops = personRowViewportTops.filter { activeRowIDs.contains($0.key) }
        reconcileRemoteFocus()
    }

    private func scrollToRemoteFocus(proxy: ScrollViewProxy, animated: Bool) {
        let focus = focusState.focused
        let transition = pendingFocusTransition ?? DetailFocusTransition(
            from: nil,
            to: focus,
            direction: nil
        )
        pendingFocusTransition = nil
        guard let command = DetailPlacementPolicy.command(for: transition) else {
            cancelPendingVerticalPlacement()
            return
        }
        executePlacementCommand(command, focus: focus, proxy: proxy, animated: animated)
    }

    private func executePlacementCommand(
        _ command: DetailPlacementCommand,
        focus: FocusNodeID,
        proxy: ScrollViewProxy,
        animated: Bool
    ) {
        switch command {
        case .none, .horizontalReveal:
            cancelPendingVerticalPlacement()
        case .verticalBand(let target):
            executeVerticalPlacement(target, focus: focus, proxy: proxy, animated: animated)
        }
    }

    private func cancelPendingVerticalPlacement() {
        pendingPlacementCorrection = nil
        _ = scrollGate.issue()
    }

    private func executeVerticalPlacement(
        _ target: DetailPlacementTarget,
        focus: FocusNodeID,
        proxy: ScrollViewProxy,
        animated: Bool
    ) {
        let serial = scrollGate.issue()
        if target == .top {
            pendingPlacementCorrection = nil
            if detailScrollController.springScroll(
                to: 0,
                animated: animated,
                reduceMotion: reduceMotion
            ) {
                return
            }
            scheduleProxyScroll(
                focus: focus,
                serial: serial,
                proxy: proxy,
                animated: animated
            )
            return
        }

        pendingPlacementCorrection = PendingDetailPlacementCorrection(
            serial: serial,
            target: target,
            animatesCorrection: animated,
            didCorrect: false
        )
        if applyPendingPlacementCorrectionIfNeeded(animated: animated) {
            return
        }
        scheduleProxyScroll(
            focus: focus,
            serial: serial,
            proxy: proxy,
            animated: animated
        )
    }

    @discardableResult
    private func applyPendingPlacementCorrectionIfNeeded(animated: Bool) -> Bool {
        guard var pending = pendingPlacementCorrection,
              scrollGate.accepts(pending.serial),
              !pending.didCorrect,
              let targetViewportTop = measuredViewportTop(for: pending.target) else {
            return false
        }
        let viewportHeight = detailScrollController.viewportHeight
        let geometry = DetailPlacementGeometry(
            currentOffset: detailScrollOffset,
            targetViewportTop: targetViewportTop,
            viewportHeight: viewportHeight
        )
        if let targetOffset = DetailPlacementPolicy.correctionTargetOffset(
            for: pending.target,
            geometry: geometry
        ) {
            guard detailScrollController.springScroll(
                to: targetOffset,
                animated: animated || pending.animatesCorrection,
                reduceMotion: reduceMotion
            ) else {
                return false
            }
        }
        pending.didCorrect = true
        pendingPlacementCorrection = pending
        return true
    }

    private func measuredViewportTop(for target: DetailPlacementTarget) -> CGFloat? {
        switch target {
        case .synopsis:
            return movieShowMoreViewportTop
        case .relatedRow:
            return moreLikeRowViewportTop
        case .personRow(let rowIndex):
            let rows = personRows
            guard rows.indices.contains(rowIndex) else { return nil }
            return personRowViewportTops[rows[rowIndex].id]
        case .top, .overview, .seasons, .episode:
            return nil
        }
    }

    private func scheduleProxyScroll(
        focus: FocusNodeID,
        serial: Int,
        proxy: ScrollViewProxy,
        animated: Bool
    ) {
        let scrollID = scrollID(for: focus)
        let anchor = scrollAnchor(for: focus)
        DispatchQueue.main.async {
            guard scrollGate.accepts(serial) else { return }
            RemoteProgrammaticScrollPolicy.perform(
                animated: animated,
                reduceMotion: reduceMotion
            ) {
                proxy.scrollTo(scrollID, anchor: anchor)
            }
        }
    }

    private func scrollID(for focus: FocusNodeID) -> String {
        if DetailFocusIDs.movieMoreLikeIndex(from: focus) != nil {
            return DetailRelatedRowLayout.scrollAnchorID
        }
        if let personIndex = DetailFocusIDs.moviePersonIndex(from: focus) {
            let rows = personRows
            guard rows.indices.contains(personIndex.row) else {
                return DetailFocusScrollIDs.movieTop
            }
            return DetailFocusScrollIDs.moviePersonRow(rows[personIndex.row].id)
        }
        if focus == DetailFocusIDs.movieShowMore {
            return DetailFocusScrollIDs.movieShowMore
        }
        return DetailFocusScrollIDs.movieTop
    }

    private func scrollAnchor(for focus: FocusNodeID) -> UnitPoint? {
        if DetailFocusIDs.movieMoreLikeIndex(from: focus) != nil {
            return RemoteFocusScrollAnchor.detailRow
        }
        if DetailFocusIDs.moviePersonIndex(from: focus) != nil {
            return RemoteFocusScrollAnchor.detailRow
        }
        if focus == DetailFocusIDs.movieShowMore {
            return RemoteFocusScrollAnchor.detail
        }
        if focus == DetailFocusIDs.movieBack ||
            focus == DetailFocusIDs.movieStart ||
            focus == DetailFocusIDs.movieContinue {
            return RemoteFocusScrollAnchor.detailTop
        }
        return RemoteFocusScrollAnchor.detailTop
    }

    private func clampedMoreLikeIndex(count: Int, proposed: Int? = nil) -> Int {
        guard count > 0 else { return 0 }
        return min(max(proposed ?? moreLikeFocusedIndex, 0), count - 1)
    }

    private func clampedPersonIndex(
        rows: [BrowsePersonMediaRow],
        proposedRow: Int? = nil,
        proposedItem: Int? = nil
    ) -> (row: Int, item: Int) {
        guard !rows.isEmpty else { return (0, 0) }
        let row = min(max(proposedRow ?? personFocusedRowIndex, 0), rows.count - 1)
        guard !rows[row].items.isEmpty else { return (row, 0) }
        let item = min(max(proposedItem ?? personFocusedItemIndex, 0), rows[row].items.count - 1)
        return (row, item)
    }

    private func focusedPersonItemID(rowIndex: Int) -> MediaItem.ID? {
        guard let personIndex = DetailFocusIDs.moviePersonIndex(from: focusState.focused),
              personIndex.row == rowIndex else { return nil }
        let rows = personRows
        guard rows.indices.contains(personIndex.row),
              rows[personIndex.row].items.indices.contains(personIndex.item) else { return nil }
        return rows[personIndex.row].items[personIndex.item].id
    }

    private func openScopedSearch(prefix: String, value: String) {
        NotificationCenter.default.post(
            name: .marqueeOpenScopedSearch,
            object: "\(prefix):\(value)"
        )
    }

    // MARK: - File Info

    private var fileInfoSection: some View {
        detailFocusContainer(isFocused: false) {
            VStack(alignment: .leading, spacing: MarqueeTheme.scaled(12, leanBack: 18, isLeanBack: leanBackMode)) {
                Rectangle()
                    .fill(MarqueeTheme.surfaceLayer)
                    .frame(height: 1)

                SectionHeader(title: "FILE INFO")

                HStack(spacing: 16) {
                    Text(item.formatBadge)
                        .font(.system(size: MarqueeTheme.scaled(12, leanBack: 17, isLeanBack: leanBackMode), weight: .semibold, design: .monospaced))
                        .foregroundColor(MarqueeTheme.textTertiary)
                        .padding(.horizontal, MarqueeTheme.scaled(8, leanBack: 12, isLeanBack: leanBackMode))
                        .padding(.vertical, MarqueeTheme.scaled(3, leanBack: 5, isLeanBack: leanBackMode))
                        .background(
                            RoundedRectangle(cornerRadius: MarqueeTheme.cornerRadiusSM)
                                .fill(MarqueeTheme.surfaceLayer)
                        )

                    Text(formatFileSize(item.fileSize))
                        .font(.system(size: MarqueeTheme.scaled(12, leanBack: 17, isLeanBack: leanBackMode)))
                        .foregroundColor(MarqueeTheme.textTertiary)

                    Text(truncatedFilePath(item.filePath))
                        .font(.system(size: MarqueeTheme.scaled(12, leanBack: 17, isLeanBack: leanBackMode)))
                        .foregroundColor(MarqueeTheme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
        }
        .id("movie-detail-file-info")
    }

    // MARK: - Formatting Helpers

    private func formatFileSize(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1.0 {
            return String(format: "%.1f GB", gb)
        }
        let mb = Double(bytes) / 1_048_576
        return String(format: "%.0f MB", mb)
    }

    private func truncatedFilePath(_ path: String) -> String {
        let components = path.split(separator: "/")
        if components.count >= 2 {
            return components.suffix(2).joined(separator: "/")
        }
        return path
    }

}

private enum DetailDeferredSectionPolicy {
    static let delay: TimeInterval = 0.62
}
