import SwiftUI

enum ShowDetailPersonRowsPolicy {
    static func shouldRender(rowCount: Int, hasSelectionHandler: Bool) -> Bool {
        hasSelectionHandler && rowCount > 0
    }
}

// MARK: - Show Detail View

struct ShowDetailView: View {
    let showName: String
    @ObservedObject var appState: AppState
    @ObservedObject var library: LibraryState
    var targetEpisode: MediaItem? = nil
    var onSelectItem: ((MediaItem) -> Void)? = nil
    var onSelectShow: ((String) -> Void)? = nil
    var onDismiss: (() -> Void)? = nil
    var onNavigateToSidebar: () -> Void = {}

    @Environment(\.kidsMode) private var kidsMode
    @Environment(\.leanBackMode) private var leanBackMode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var remoteInput: RemoteInputRouter
    @State private var selectedSeason: Int = 1
    @State private var showFullOverview: Bool = false
    @State private var focusedEpisodeIndex: Int = 0
    @State private var focusState = FocusEngineState(focused: DetailFocusIDs.showStart)
    @State private var moreLikeFocusedIndex: Int = 0
    @State private var personFocusedRowIndex: Int = 0
    @State private var personFocusedItemIndex: Int = 0
    @State private var scrollGate = RemoteScrollRequestGate()
    @State private var deferredSectionsVisible: Bool = false
    @State private var deferredSectionsRequestID: Int = 0
    @State private var heroArtworkVisible: Bool = false
    @State private var heroArtworkRequestID: Int = 0
    @StateObject private var detailScrollController = DetailScrollController()
    @State private var detailScrollOffset: CGFloat = 0
    @State private var focusedEpisodeMeasurement: DetailPlacementMeasurement?
    @State private var moreLikeRowViewportTop: CGFloat?
    @State private var personRowViewportTops: [String: CGFloat] = [:]
    @State private var pendingFocusTransition: DetailFocusTransition?
    @State private var pendingPlacementCorrection: PendingDetailPlacementCorrection?
    @State private var cachedSimilarShows: [String] = []
    @State private var cachedPersonRows: [BrowsePersonMediaRow] = []

    private var allSeasons: [Int] {
        library.seasons(forShow: showName)
    }

    private var currentEpisodes: [MediaItem] {
        library.episodes(forShow: showName, season: selectedSeason)
    }

    private var allEpisodes: [MediaItem] {
        library.episodes(forShow: showName)
    }

    private var upNext: MediaItem? {
        library.upNextEpisode(forShow: showName)
    }

    private var firstEpisode: MediaItem? {
        allEpisodes.first
    }

    private var representativeItem: MediaItem? {
        allEpisodes.first
    }

    private var totalEpisodeCount: Int {
        allEpisodes.count
    }

    private var yearLabel: String? {
        representativeItem?.displayYear
    }

    private var heroHeight: CGFloat {
        MarqueeTheme.scaled(350, leanBack: 500, isLeanBack: leanBackMode)
    }

    private var heroPosterWidth: CGFloat {
        MarqueeTheme.scaled(132, leanBack: 200, isLeanBack: leanBackMode)
    }

    private var heroPosterHeight: CGFloat {
        heroPosterWidth * 1.5
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        heroArea
                            .id(DetailFocusScrollIDs.showTop)
                        synopsisSection
                        if deferredSectionsVisible {
                            castSection
                            creatorCredit
                            seasonPicker
                            episodeList
                            moreLikeThisSection
                            personRowsSection
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .background(
                        DetailScrollObserver(
                            offset: $detailScrollOffset,
                            controller: detailScrollController
                        )
                        .frame(width: 0, height: 0)
                    )
                }
                .id(showName)
                .coordinateSpace(name: DetailScrollCoordinateSpace.name)
                .onAppear {
                    initSelectedSeason()
                    syncFocusedEpisodeToAnchor()
                    focusState = FocusEngineState(focused: firstAvailableFocus())
                    reconcileRemoteFocus()
                    scrollToRemoteFocus(proxy: proxy, animated: false)
                    stageHeroArtwork()
                    stageDeferredSections()
                    MarqueeSignpost.event("detail-appeared", "show")
                    #if DEBUG
                    NotificationCenter.default.post(name: .marqueeQADetailSurfaceAppeared, object: "show")
                    #endif
                }
                .onChange(of: selectedSeason) { _ in
                    focusedEpisodeMeasurement = nil
                    clampFocusedEpisode()
                    reconcileRemoteFocus()
                    scrollToRemoteFocus(proxy: proxy, animated: true)
                }
                .onChange(of: showName) { _ in
                    resetRemoteFocus()
                    initSelectedSeason()
                    syncFocusedEpisodeToAnchor()
                    scrollToRemoteFocus(proxy: proxy, animated: false)
                    stageHeroArtwork()
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
                #if DEBUG
                .onReceive(NotificationCenter.default.publisher(for: .marqueeQAVisualTourFocusFirstShowEpisode)) { _ in
                    focusFirstEpisodeForVisualQATour()
                }
                .onReceive(NotificationCenter.default.publisher(for: .marqueeQAVisualTourProbeShowEpisodeFocus)) { _ in
                    reportEpisodeFocusForVisualQATour()
                }
                .onReceive(NotificationCenter.default.publisher(for: .marqueeQAVisualTourFocusFirstShowMoreLike)) { _ in
                    focusFirstMoreLikeForVisualQATour()
                }
                #endif
                .onPreferenceChange(DetailRelatedRowViewportTopPreferenceKey.self) { rowTop in
                    moreLikeRowViewportTop = DetailPlacementGeometry.sanitizedViewportTop(rowTop)
                    applyPendingPlacementCorrectionIfNeeded(animated: false)
                }
                .onPreferenceChange(DetailEpisodeRowViewportTopPreferenceKey.self) { rowTop in
                    if let viewportTop = DetailPlacementGeometry.sanitizedViewportTop(rowTop),
                       let focus = currentEpisodeFocusID() {
                        focusedEpisodeMeasurement = DetailPlacementMeasurement(
                            focus: focus,
                            viewportTop: viewportTop
                        )
                    } else {
                        focusedEpisodeMeasurement = nil
                    }
                    applyPendingPlacementCorrectionIfNeeded(animated: false)
                }
                .onPreferenceChange(DetailPersonRowViewportTopPreferenceKey.self) { rowTops in
                    personRowViewportTops = rowTops.compactMapValues {
                        DetailPlacementGeometry.sanitizedViewportTop($0)
                    }
                    applyPendingPlacementCorrectionIfNeeded(animated: false)
                }
            }

            if onDismiss != nil {
                backButton
            }
        }
    }

    // MARK: - Back Button

    private var backButton: some View {
        Button(action: { onDismiss?() }) {
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
            isFocused: isFocused(DetailFocusIDs.showBack),
            cornerRadius: 999,
            accent: detailFocusAccent
        )
        .padding(.top, MarqueeTheme.scaled(16, leanBack: 26, isLeanBack: leanBackMode))
        .padding(.leading, DetailBackChromeLayout.leadingPadding(isLeanBack: leanBackMode))
    }

    // MARK: - Hero Area

    private var heroArea: some View {
        ZStack(alignment: .bottomLeading) {
            detailHeroFallback

            if heroArtworkVisible, let path = representativeItem?.displayShowBackdropPath {
                CachedImageView(
                    path: path,
                    contentMode: .fill,
                    thumbnailPixelSize: ArtworkCache.heroBackdropThumbnailPixelSize,
                    placeholderFillOpacity: 0,
                    placeholderIconOpacity: 0
                )
                    .id(path)
                    .frame(height: heroHeight)
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

            HStack(alignment: .bottom, spacing: MarqueeTheme.scaled(28, leanBack: 42, isLeanBack: leanBackMode)) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(showName)
                        .font(.system(size: MarqueeTheme.scaled(32, leanBack: 46, isLeanBack: leanBackMode), weight: .bold))
                        .foregroundColor(MarqueeTheme.textPrimary)
                        .lineLimit(2)

                    HStack(spacing: MarqueeTheme.scaled(10, leanBack: 15, isLeanBack: leanBackMode)) {
                        if let year = yearLabel {
                            Text(year)
                        }
                        Text("\(allSeasons.count) Season\(allSeasons.count == 1 ? "" : "s")")
                        Text("\(totalEpisodeCount) Episodes")

                        if let cert = representativeItem?.metadata?.certification, !cert.isEmpty {
                            Text(cert)
                                .font(.system(size: MarqueeTheme.scaled(11, leanBack: 15, isLeanBack: leanBackMode), weight: .semibold))
                                .foregroundColor(MarqueeTheme.textSecondary)
                                .padding(.horizontal, MarqueeTheme.scaled(8, leanBack: 12, isLeanBack: leanBackMode))
                                .padding(.vertical, MarqueeTheme.scaled(3, leanBack: 5, isLeanBack: leanBackMode))
                                .overlay(
                                    Capsule()
                                        .stroke(MarqueeTheme.textTertiary, lineWidth: 1)
                                )
                        }

                        if let rating = representativeItem?.metadata?.voteAverage, rating > 0 {
                            HStack(spacing: 3) {
                                Image(systemName: "star.fill")
                                    .font(.system(size: MarqueeTheme.scaled(10, leanBack: 14, isLeanBack: leanBackMode)))
                                    .foregroundColor(MarqueeTheme.accentSecondary)
                                Text(String(format: "%.1f", rating))
                            }
                        }
                    }
                    .font(.system(size: MarqueeTheme.scaled(13, leanBack: 18, isLeanBack: leanBackMode), weight: .medium))
                    .foregroundColor(MarqueeTheme.textSecondary)

                    heroGenreTags

                    showActionButtons
                }
                .frame(maxWidth: MarqueeTheme.scaled(760, leanBack: 1040, isLeanBack: leanBackMode), alignment: .leading)

                Spacer(minLength: 0)

                heroPosterPreview
            }
            .padding(MarqueeTheme.outerPadding(isLeanBack: leanBackMode))
            .padding(.bottom, MarqueeTheme.scaled(8, leanBack: 16, isLeanBack: leanBackMode))
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

            if heroArtworkVisible, let posterPath = representativeItem?.displayShowPosterPath {
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

    @ViewBuilder
    private var heroPosterPreview: some View {
        if heroArtworkVisible, let posterPath = representativeItem?.displayShowPosterPath {
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

                Text("\(allSeasons.count)S")
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

    @ViewBuilder
    private var showActionButtons: some View {
        if firstEpisode != nil {
            HStack(spacing: MarqueeTheme.scaled(10, leanBack: 15, isLeanBack: leanBackMode)) {
                Button(action: playShowFromBeginning) {
                    HStack(spacing: MarqueeTheme.scaled(6, leanBack: 10, isLeanBack: leanBackMode)) {
                        Image(systemName: "backward.end.fill")
                            .font(.system(size: MarqueeTheme.scaled(11, leanBack: 16, isLeanBack: leanBackMode)))
                        Text("Start From Beginning")
                            .font(.system(size: MarqueeTheme.scaled(13, leanBack: 19, isLeanBack: leanBackMode), weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, MarqueeTheme.scaled(20, leanBack: 30, isLeanBack: leanBackMode))
                    .padding(.vertical, MarqueeTheme.scaled(10, leanBack: 15, isLeanBack: leanBackMode))
                    .background(Capsule().fill(MarqueeTheme.accentPrimary))
                }
                .buttonStyle(.plain)
                .detailFocusSurface(
                    isFocused: isFocused(DetailFocusIDs.showStart),
                    cornerRadius: 999,
                    accent: detailFocusAccent
                )
                .accessibilityLabel("Start \(showName) from beginning")

                if shouldShowContinueAction, let next = upNext {
                    Button(action: { appState.playItem(next) }) {
                        HStack(spacing: MarqueeTheme.scaled(6, leanBack: 10, isLeanBack: leanBackMode)) {
                            Image(systemName: "play.fill")
                                .font(.system(size: MarqueeTheme.scaled(12, leanBack: 18, isLeanBack: leanBackMode)))
                            Text(continueActionLabel(for: next))
                                .font(.system(size: MarqueeTheme.scaled(13, leanBack: 19, isLeanBack: leanBackMode), weight: .semibold))
                        }
                        .foregroundColor(MarqueeTheme.textPrimary)
                        .padding(.horizontal, MarqueeTheme.scaled(20, leanBack: 30, isLeanBack: leanBackMode))
                        .padding(.vertical, MarqueeTheme.scaled(10, leanBack: 15, isLeanBack: leanBackMode))
                        .background(Capsule().fill(MarqueeTheme.surfaceLayer))
                    }
                    .buttonStyle(.plain)
                    .detailFocusSurface(
                        isFocused: isFocused(DetailFocusIDs.showContinue),
                        cornerRadius: 999,
                        accent: detailFocusAccent
                    )
                    .accessibilityLabel("Continue \(showName) with \(next.episodeLabel)")
                }
            }
            .padding(.top, MarqueeTheme.scaled(4, leanBack: 8, isLeanBack: leanBackMode))
            .id("show-detail-actions")
        }
    }

    // MARK: - Genre Tags

    @ViewBuilder
    private var heroGenreTags: some View {
        let genres = representativeItem?.displayGenres ?? []
        if !genres.isEmpty {
            HStack(spacing: MarqueeTheme.scaled(6, leanBack: 10, isLeanBack: leanBackMode)) {
                ForEach(genres.prefix(4), id: \.self) { genre in
                    Text(genre)
                        .font(.system(size: MarqueeTheme.scaled(11, leanBack: 16, isLeanBack: leanBackMode), weight: .medium))
                        .foregroundColor(MarqueeTheme.textSecondary)
                        .padding(.horizontal, MarqueeTheme.scaled(10, leanBack: 14, isLeanBack: leanBackMode))
                        .padding(.vertical, MarqueeTheme.scaled(4, leanBack: 7, isLeanBack: leanBackMode))
                        .background(
                            Capsule().fill(MarqueeTheme.surfaceLayer)
                        )
                }
            }
        }
    }

    // MARK: - Synopsis

    @ViewBuilder
    private var synopsisSection: some View {
        if let overview = representativeItem?.metadata?.overview, !overview.isEmpty {
            detailFocusContainer(isFocused: isFocused(DetailFocusIDs.showOverview)) {
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: "ABOUT")

                    Text(overview)
                        .font(.system(size: MarqueeTheme.scaled(14, leanBack: 20, isLeanBack: leanBackMode), weight: .regular))
                        .foregroundColor(MarqueeTheme.textPrimary)
                        .lineLimit(showFullOverview ? nil : 3)
                        .lineSpacing(MarqueeTheme.scaled(3, leanBack: 5, isLeanBack: leanBackMode))

                    Button(action: {
                        withAnimation(reduceMotion ? nil : MarqueeTheme.cardHoverAnimation) {
                            showFullOverview.toggle()
                        }
                    }) {
                        Text(showFullOverview ? "Show Less" : "Show More")
                            .font(.system(size: MarqueeTheme.scaled(12, leanBack: 17, isLeanBack: leanBackMode), weight: .medium))
                            .foregroundColor(MarqueeTheme.accentBright)
                            .padding(.vertical, MarqueeTheme.scaled(4, leanBack: 7, isLeanBack: leanBackMode))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, MarqueeTheme.outerPadding(isLeanBack: leanBackMode))
            .padding(.top, MarqueeTheme.scaled(24, leanBack: 36, isLeanBack: leanBackMode))
            .id(DetailFocusScrollIDs.showMore)
        }
    }

    // MARK: - Cast Row

    @ViewBuilder
    private var castSection: some View {
        let cast = representativeItem?.metadata?.cast ?? []
        if !cast.isEmpty {
            detailFocusContainer(isFocused: false) {
                VStack(alignment: .leading, spacing: MarqueeTheme.scaled(12, leanBack: 18, isLeanBack: leanBackMode)) {
                    SectionHeader(title: "CAST")
                        .padding(.horizontal, MarqueeTheme.outerPadding(isLeanBack: leanBackMode))

                    ArrowedScrollRow(ids: Array(0..<min(cast.count, 12))) {
                        HStack(spacing: MarqueeTheme.scaled(16, leanBack: 24, isLeanBack: leanBackMode)) {
                            ForEach(Array(cast.prefix(12).enumerated()), id: \.offset) { index, member in
                                castMemberView(member)
                                    .id(index)
                            }
                        }
                        .padding(.horizontal, MarqueeTheme.outerPadding(isLeanBack: leanBackMode))
                    }
                }
            }
            .padding(.top, MarqueeTheme.scaled(24, leanBack: 36, isLeanBack: leanBackMode))
            .id("show-detail-cast")
        }
    }

    private func castMemberView(_ member: TMDBMetadata.CastEntry) -> some View {
        Button(action: { openScopedSearch(prefix: "cast", value: member.name) }) {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(MarqueeTheme.surfaceLayer)
                        .frame(
                            width: MarqueeTheme.scaled(56, leanBack: 82, isLeanBack: leanBackMode),
                            height: MarqueeTheme.scaled(56, leanBack: 82, isLeanBack: leanBackMode)
                        )

                    Text(member.name.initials)
                        .font(.system(size: MarqueeTheme.scaled(18, leanBack: 26, isLeanBack: leanBackMode), weight: .semibold))
                        .foregroundColor(MarqueeTheme.textTertiary)
                }

                Text(member.name)
                    .font(.system(size: MarqueeTheme.scaled(11, leanBack: 16, isLeanBack: leanBackMode), weight: .medium))
                    .foregroundColor(MarqueeTheme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)

                Text(member.character)
                    .font(.system(size: MarqueeTheme.scaled(10, leanBack: 14, isLeanBack: leanBackMode), weight: .regular))
                    .foregroundColor(MarqueeTheme.textTertiary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .frame(width: MarqueeTheme.scaled(100, leanBack: 145, isLeanBack: leanBackMode))
        }
        .buttonStyle(.plain)
        .help("Search \(member.name)")
    }

    // MARK: - Creator Credit

    @ViewBuilder
    private var creatorCredit: some View {
        if let creator = representativeItem?.metadata?.director, !creator.isEmpty {
            detailFocusContainer(isFocused: false) {
                HStack(spacing: 0) {
                    Text("Created by ")
                        .font(.system(size: MarqueeTheme.scaled(13, leanBack: 18, isLeanBack: leanBackMode), weight: .regular))
                        .foregroundColor(MarqueeTheme.textSecondary)
                    Button(action: { openScopedSearch(prefix: "director", value: creator) }) {
                        Text(creator)
                            .font(.system(size: MarqueeTheme.scaled(13, leanBack: 18, isLeanBack: leanBackMode), weight: .semibold))
                            .foregroundColor(MarqueeTheme.textPrimary)
                    }
                    .buttonStyle(.plain)
                    .help("Search \(creator)")
                }
            }
            .padding(.horizontal, MarqueeTheme.outerPadding(isLeanBack: leanBackMode))
            .padding(.top, MarqueeTheme.scaled(16, leanBack: 24, isLeanBack: leanBackMode))
            .id("show-detail-creator")
        }
    }

    // MARK: - Season Picker

    @ViewBuilder
    private var seasonPicker: some View {
        if allSeasons.count > 1 {
            if allSeasons.count <= 6 {
                seasonTabs
            } else {
                seasonDropdown
            }
        }
    }

    private var seasonTabs: some View {
        HStack(spacing: MarqueeTheme.scaled(4, leanBack: 8, isLeanBack: leanBackMode)) {
            ForEach(allSeasons, id: \.self) { season in
                Button(action: {
                    selectSeason(season)
                }) {
                    Text("Season \(season)")
                        .font(.system(size: MarqueeTheme.scaled(13, leanBack: 18, isLeanBack: leanBackMode), weight: selectedSeason == season ? .semibold : .regular))
                        .foregroundColor(selectedSeason == season ? .white : MarqueeTheme.textSecondary)
                        .padding(.horizontal, MarqueeTheme.scaled(16, leanBack: 24, isLeanBack: leanBackMode))
                        .padding(.vertical, MarqueeTheme.scaled(8, leanBack: 13, isLeanBack: leanBackMode))
                        .background(
                            Capsule().fill(
                                selectedSeason == season
                                    ? MarqueeTheme.accentPrimary
                                    : MarqueeTheme.surfaceElevated
                            )
                        )
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, MarqueeTheme.outerPadding(isLeanBack: leanBackMode))
        .padding(.vertical, MarqueeTheme.scaled(16, leanBack: 26, isLeanBack: leanBackMode))
        .background(
            ZStack {
                if isFocused(DetailFocusIDs.showSeasons) {
                    RoundedRectangle(cornerRadius: MarqueeTheme.cornerRadiusMD)
                        .fill(MarqueeTheme.surfaceElevated.opacity(0.45))
                }
            }
        )
        .detailFocusSurface(
            isFocused: isFocused(DetailFocusIDs.showSeasons),
            cornerRadius: MarqueeTheme.cornerRadiusMD,
            accent: detailFocusAccent
        )
        .id(DetailFocusScrollIDs.showSeasons)
    }

    private var seasonDropdown: some View {
        HStack {
            Menu {
                ForEach(allSeasons, id: \.self) { season in
                    Button("Season \(season)") {
                        selectSeason(season)
                    }
                }
            } label: {
                HStack(spacing: MarqueeTheme.scaled(6, leanBack: 10, isLeanBack: leanBackMode)) {
                    Text("Season \(selectedSeason)")
                        .font(.system(size: MarqueeTheme.scaled(14, leanBack: 20, isLeanBack: leanBackMode), weight: .semibold))
                        .foregroundColor(MarqueeTheme.textPrimary)
                    Image(systemName: "chevron.down")
                        .font(.system(size: MarqueeTheme.scaled(10, leanBack: 15, isLeanBack: leanBackMode), weight: .semibold))
                        .foregroundColor(MarqueeTheme.textSecondary)
                }
                .padding(.horizontal, MarqueeTheme.scaled(16, leanBack: 24, isLeanBack: leanBackMode))
                .padding(.vertical, MarqueeTheme.scaled(8, leanBack: 13, isLeanBack: leanBackMode))
                .background(
                    Capsule().fill(MarqueeTheme.surfaceElevated)
                )
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Spacer()
        }
        .padding(.horizontal, MarqueeTheme.outerPadding(isLeanBack: leanBackMode))
        .padding(.vertical, MarqueeTheme.scaled(16, leanBack: 26, isLeanBack: leanBackMode))
        .background(
            ZStack {
                if isFocused(DetailFocusIDs.showSeasons) {
                    RoundedRectangle(cornerRadius: MarqueeTheme.cornerRadiusMD)
                        .fill(MarqueeTheme.surfaceElevated.opacity(0.45))
                }
            }
        )
        .detailFocusSurface(
            isFocused: isFocused(DetailFocusIDs.showSeasons),
            cornerRadius: MarqueeTheme.cornerRadiusMD,
            accent: detailFocusAccent
        )
        .id(DetailFocusScrollIDs.showSeasons)
    }

    // MARK: - Episode List

    private var episodeList: some View {
        LazyVStack(spacing: MarqueeTheme.scaled(4, leanBack: 8, isLeanBack: leanBackMode)) {
            ForEach(Array(currentEpisodes.enumerated()), id: \.element.id) { index, episode in
                EpisodeRow(
                    item: episode,
                    isUpNext: episode.id == upNext?.id,
                    isRemoteFocused: false,
                    onPlay: { appState.playItem(episode) }
                )
                .detailFocusSurface(
                    isFocused: isFocused(DetailFocusIDs.showEpisode(index)),
                    cornerRadius: MarqueeTheme.cornerRadiusMD,
                    accent: detailFocusAccent
                )
                .background {
                    if isFocused(DetailFocusIDs.showEpisode(index)) {
                        DetailEpisodeRowViewportTopObserver()
                            .frame(height: 1)
                            .accessibilityHidden(true)
                    }
                }
                .id(DetailFocusScrollIDs.showEpisode(index))
            }
        }
        // macOS 12 can retain position-identified LazyVStack children across
        // data replacement. A season boundary must invalidate the whole lazy
        // subtree so old episode pixels cannot cover the new logical rows.
        .id(selectedSeason)
        .padding(.horizontal, MarqueeTheme.outerPadding(isLeanBack: leanBackMode))
        .padding(.bottom, MarqueeTheme.scaled(28, leanBack: 42, isLeanBack: leanBackMode))
    }

    // MARK: - More Like This

    @ViewBuilder
    private var moreLikeThisSection: some View {
        let shows = similarShows
        let cardWidth = MarqueeTheme.scaled(120, leanBack: 180, isLeanBack: leanBackMode)
        let cardGap = MarqueeTheme.cardGap(isLeanBack: leanBackMode)
        if !shows.isEmpty {
            VStack(alignment: .leading, spacing: MarqueeTheme.sectionHeaderToContent(isLeanBack: leanBackMode)) {
                SectionHeader(title: "MORE LIKE THIS")
                    .padding(.top, DetailRelatedRowLayout.topClearance(isLeanBack: leanBackMode))
                    .id(DetailRelatedRowLayout.scrollAnchorID)
                    .padding(.horizontal, MarqueeTheme.outerPadding(isLeanBack: leanBackMode))

                DetailRelatedRowViewportTopObserver()
                    .frame(height: 1)
                    .accessibilityHidden(true)

                ArrowedScrollRow(
                    ids: shows,
                    focusedID: focusedMoreLikeShowName,
                    focusItemExtent: cardWidth,
                    focusItemSpacing: cardGap,
                    focusScrollMode: .detailRow,
                    focusContentInset: MarqueeTheme.outerPadding(isLeanBack: leanBackMode),
                    hoverArrowsEnabled: RemotePointerRegionPolicy.rowHoverControlsEnabled(
                        isKeyboardFocusActive: isMoreLikeRemoteFocused
                    )
                ) {
                    LazyHStack(alignment: .top, spacing: cardGap) {
                        ForEach(Array(shows.enumerated()), id: \.element) { index, name in
                            ShowCard(
                                showName: name,
                                posterPath: library.representativeEpisode(forShow: name)?.gridShowPosterPath,
                                cardWidth: cardWidth,
                                upNextLabel: library.upNextEpisode(forShow: name)?.episodeLabel,
                                seasonCount: library.seasons(forShow: name).count,
                                isRemoteFocused: isFocused(DetailFocusIDs.showMoreLike(index)),
                                focusAccent: detailFocusAccent,
                                onSelect: { onSelectShow?(name) }
                            )
                            .id(name)
                        }
                    }
                }
            }
            .padding(.bottom, MarqueeTheme.scaled(100, leanBack: 150, isLeanBack: leanBackMode))
        }
    }

    private var shouldShowContinueAction: Bool {
        guard let next = upNext else { return false }
        guard let first = firstEpisode else { return true }
        return next.id != first.id || next.hasProgress
    }

    private var hasOverview: Bool {
        guard let overview = representativeItem?.metadata?.overview else { return false }
        return !overview.isEmpty
    }

    private var similarShows: [String] {
        cachedSimilarShows
    }

    private var personRows: [BrowsePersonMediaRow] {
        cachedPersonRows
    }

    @ViewBuilder
    private var personRowsSection: some View {
        let rows = personRows
        if ShowDetailPersonRowsPolicy.shouldRender(
            rowCount: rows.count,
            hasSelectionHandler: onSelectItem != nil
        ) {
            VStack(alignment: .leading, spacing: MarqueeTheme.scaled(28, leanBack: 42, isLeanBack: leanBackMode)) {
                ForEach(rows.indices, id: \.self) { rowIndex in
                    let row = rows[rowIndex]
                    MediaItemRow(
                        title: row.title,
                        items: row.items,
                        focusedItemID: focusedPersonItemID(rowIndex: rowIndex),
                        focusScrollMode: .detailRow,
                        onSelect: { item in
                            onSelectItem?(item)
                        }
                    )
                    .padding(.horizontal, MarqueeTheme.outerPadding(isLeanBack: leanBackMode))
                    .background(alignment: .topLeading) {
                        DetailPersonRowViewportTopObserver(rowID: row.id)
                            .frame(height: 1)
                            .accessibilityHidden(true)
                    }
                    .id(DetailFocusScrollIDs.showPersonRow(row.id))
                }
            }
            .padding(.bottom, MarqueeTheme.scaled(28, leanBack: 42, isLeanBack: leanBackMode))
        }
    }

    private var focusedMoreLikeShowName: String? {
        let shows = similarShows
        guard shows.indices.contains(moreLikeFocusedIndex) else { return nil }
        return shows[moreLikeFocusedIndex]
    }

    private var isMoreLikeRemoteFocused: Bool {
        DetailFocusIDs.showMoreLikeIndex(from: focusState.focused) != nil
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

    private func continueActionLabel(for item: MediaItem) -> String {
        if item.hasProgress {
            return "Resume \(item.episodeLabel)"
        }
        return "Continue \(item.episodeLabel)"
    }

    private func openScopedSearch(prefix: String, value: String) {
        NotificationCenter.default.post(
            name: .marqueeOpenScopedSearch,
            object: "\(prefix):\(value)"
        )
    }

    private func playShowFromBeginning() {
        guard let firstEpisode else { return }
        appState.playItem(firstEpisode, fromStart: true)
    }

    private func selectRemoteFocus() {
        reconcileRemoteFocus()

        let focus = focusState.focused
        if focus == DetailFocusIDs.showBack {
            onDismiss?()
        } else if focus == DetailFocusIDs.showStart {
            playShowFromBeginning()
        } else if focus == DetailFocusIDs.showContinue {
            guard let next = upNext else { return }
            appState.playItem(next)
        } else if focus == DetailFocusIDs.showOverview {
            withAnimation(reduceMotion ? nil : MarqueeTheme.cardHoverAnimation) {
                showFullOverview.toggle()
            }
        } else if let index = DetailFocusIDs.showEpisodeIndex(from: focus) {
            guard currentEpisodes.indices.contains(index) else { return }
            appState.playItem(currentEpisodes[index])
        } else if let index = DetailFocusIDs.showMoreLikeIndex(from: focus) {
            let shows = similarShows
            guard shows.indices.contains(index) else { return }
            onSelectShow?(shows[index])
            resetRemoteFocus()
        } else if let personIndex = DetailFocusIDs.showPersonIndex(from: focus) {
            let rows = focusablePersonRows
            guard rows.indices.contains(personIndex.row),
                  rows[personIndex.row].items.indices.contains(personIndex.item) else { return }
            onSelectItem?(rows[personIndex.row].items[personIndex.item])
            resetRemoteFocus()
        }
    }

    private func moveRemoteFocus(_ direction: FocusDirection) {
        reconcileRemoteFocus()
        let previousFocus = focusState.focused
        var result = FocusEngine(root: showDetailFocusTree()).move(direction, state: focusState)
        var didReachStepperBoundary = false
        if let activation = result.events.compactMap({ event -> FocusStepperActivation? in
            if case let .stepperActivated(activation) = event { return activation }
            return nil
        }).first, activation.nodeID == DetailFocusIDs.showSeasons {
            if stepSeason(direction: activation.delta) {
                result.state = ShowDetailFocusReconciler.resettingEpisodeMemoryAfterSeasonChange(result.state)
            } else {
                didReachStepperBoundary = true
            }
        } else if direction == .left,
                  DetailSidebarHandoffPolicy.shouldHandOff(direction: direction, events: result.events) {
            AudioIdentityService.shared.playFeedback(for: .left, didNavigate: true)
            onNavigateToSidebar()
            return
        }
        applyFocusResult(result, previousFocus: previousFocus, direction: direction)
        AudioIdentityService.shared.playFeedback(
            for: direction.remoteCommand,
            didNavigate: result.state.focused != previousFocus,
            focusEvents: result.events,
            didReachBoundary: didReachStepperBoundary
        )
        recordPlacementTransition(from: previousFocus, direction: direction)
    }

    private func reconcileRemoteFocus() {
        let similarCount = deferredSectionsVisible ? similarShows.count : 0
        let rows = deferredSectionsVisible ? focusablePersonRows : []
        let result = ShowDetailFocusReconciler.reconcile(ShowDetailFocusReconciliationContext(
            state: focusState,
            firstAvailableFocus: firstAvailableFocus(),
            hasBack: onDismiss != nil,
            hasStartAction: firstEpisode != nil,
            hasContinueAction: shouldShowContinueAction,
            hasOverview: hasOverview,
            hasSeasonStepper: deferredSectionsVisible && allSeasons.count > 1,
            areDeferredSectionsVisible: deferredSectionsVisible,
            episodeCount: currentEpisodes.count,
            moreLikeCount: similarCount,
            personRowItemCounts: rows.map { $0.items.count },
            proposedEpisodeIndex: focusedEpisodeIndex,
            proposedMoreLikeIndex: moreLikeFocusedIndex,
            proposedPersonRowIndex: personFocusedRowIndex,
            proposedPersonItemIndex: personFocusedItemIndex
        ))
        focusState = result.state
        focusedEpisodeIndex = result.focusedEpisodeIndex
        moreLikeFocusedIndex = result.moreLikeFocusedIndex
        personFocusedRowIndex = result.personFocusedRowIndex
        personFocusedItemIndex = result.personFocusedItemIndex
    }

    private func resetRemoteFocus() {
        pendingFocusTransition = nil
        pendingPlacementCorrection = nil
        focusedEpisodeMeasurement = nil
        _ = scrollGate.issue()
        focusState = FocusEngineState(focused: firstEpisode == nil ? firstAvailableFocus() : DetailFocusIDs.showStart)
        moreLikeFocusedIndex = 0
        focusedEpisodeIndex = 0
        personFocusedRowIndex = 0
        personFocusedItemIndex = 0
        showFullOverview = false
    }

    #if DEBUG
    private func focusFirstEpisodeForVisualQATour() {
        guard deferredSectionsVisible, !currentEpisodes.isEmpty else { return }
        let previousFocus = focusState.focused
        focusedEpisodeIndex = 0
        focusState.focused = DetailFocusIDs.showEpisode(focusedEpisodeIndex)
        focusState.rememberedChildByContainer[DetailFocusIDs.showEpisodes] = focusState.focused
        recordPlacementTransition(from: previousFocus, direction: .down)
        reportEpisodeFocusForVisualQATour()
    }

    private func reportEpisodeFocusForVisualQATour() {
        guard let focusedIndex = DetailFocusIDs.showEpisodeIndex(from: focusState.focused),
              currentEpisodes.indices.contains(focusedIndex) else {
            return
        }
        NotificationCenter.default.post(
            name: .marqueeQAVisualTourShowEpisodeFocused,
            object: QAShowEpisodeFocusEvidence(
                focusedIndex: focusedIndex,
                episodeCount: currentEpisodes.count
            )
        )
    }

    private func focusFirstMoreLikeForVisualQATour() {
        guard deferredSectionsVisible, !similarShows.isEmpty else { return }
        let previousFocus = focusState.focused
        moreLikeFocusedIndex = 0
        focusState.focused = DetailFocusIDs.showMoreLike(0)
        recordPlacementTransition(from: previousFocus, direction: .down)
        preheatFocusedMoreLikeArtwork()
    }
    #endif

    private func preheatFocusedMoreLikeArtwork() {
        guard let index = DetailFocusIDs.showMoreLikeIndex(from: focusState.focused) else { return }
        let shows = similarShows
        guard shows.indices.contains(index),
              let item = library.representativeEpisode(forShow: shows[index]) else { return }
        let posterSize = leanBackMode
            ? ArtworkCache.leanBackPosterThumbnailPixelSize
            : ArtworkCache.gridPosterThumbnailPixelSize
        ArtworkCache.shared.preloadVisiblePosters(
            paths: [item.displayShowPosterPath],
            pixelSize: posterSize,
            label: "show-more-like-detail-poster"
        )
        ArtworkCache.shared.preloadVisiblePosters(
            paths: [item.displayShowBackdropPath],
            pixelSize: ArtworkCache.heroBackdropThumbnailPixelSize,
            label: "show-more-like-detail-backdrop"
        )
    }

    private func stageDeferredSections() {
        deferredSectionsRequestID &+= 1
        let requestID = deferredSectionsRequestID
        deferredSectionsVisible = false
        cachedSimilarShows = []
        cachedPersonRows = []
        personRowViewportTops = [:]
        DispatchQueue.main.asyncAfter(deadline: .now() + DetailDeferredSectionPolicy.delay) {
            guard requestID == deferredSectionsRequestID else { return }
            let nextSimilarShows = library.browseSnapshot.similarShowNames(to: showName, limit: 10)
            let nextPersonRows: [BrowsePersonMediaRow]
            if let representativeItem {
                nextPersonRows = BrowseLeanBackDelightPolicy.personRows(
                    for: representativeItem,
                    in: library.filteredLibraryItems,
                    limit: 10
                )
            } else {
                nextPersonRows = []
            }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                cachedSimilarShows = nextSimilarShows
                cachedPersonRows = nextPersonRows
                deferredSectionsVisible = true
            }
        }
    }

    private func refreshCachedDeferredSections() {
        guard deferredSectionsVisible else { return }
        cachedSimilarShows = library.browseSnapshot.similarShowNames(to: showName, limit: 10)
        if let representativeItem {
            cachedPersonRows = BrowseLeanBackDelightPolicy.personRows(
                for: representativeItem,
                in: library.filteredLibraryItems,
                limit: 10
            )
        } else {
            cachedPersonRows = []
        }
        let activeRowIDs = Set(cachedPersonRows.map(\.id))
        personRowViewportTops = personRowViewportTops.filter { activeRowIDs.contains($0.key) }
        reconcileRemoteFocus()
    }

    private func stageHeroArtwork() {
        heroArtworkRequestID &+= 1
        let requestID = heroArtworkRequestID
        heroArtworkVisible = false
        DispatchQueue.main.asyncAfter(deadline: .now() + DetailHeroArtworkPolicy.delay) {
            guard requestID == heroArtworkRequestID else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                heroArtworkVisible = true
            }
        }
    }

    private func firstAvailableFocus() -> FocusNodeID {
        if firstEpisode != nil {
            return DetailFocusIDs.showStart
        }
        if hasOverview {
            return DetailFocusIDs.showOverview
        }
        if deferredSectionsVisible, allSeasons.count > 1 {
            return DetailFocusIDs.showSeasons
        }
        if deferredSectionsVisible, !currentEpisodes.isEmpty {
            return DetailFocusIDs.showEpisode(clampedEpisodeIndex())
        }
        if deferredSectionsVisible, !similarShows.isEmpty {
            return DetailFocusIDs.showMoreLike(clampedMoreLikeIndex(count: similarShows.count))
        }
        if deferredSectionsVisible, let firstPersonFocus = firstPersonFocusID() {
            return firstPersonFocus
        }
        if onDismiss != nil {
            return DetailFocusIDs.showBack
        }
        return DetailFocusIDs.showStart
    }

    private func showDetailFocusTree() -> FocusNode {
        let rows = deferredSectionsVisible ? focusablePersonRows : []
        return DetailFocusTree.show(ShowDetailFocusConfiguration(
            hasBack: onDismiss != nil,
            hasStartAction: firstEpisode != nil,
            hasContinueAction: shouldShowContinueAction,
            hasOverview: hasOverview,
            hasSeasonStepper: deferredSectionsVisible && allSeasons.count > 1,
            episodeCount: deferredSectionsVisible ? currentEpisodes.count : 0,
            moreLikeCount: deferredSectionsVisible ? similarShows.count : 0,
            preferredMoreLikeIndex: moreLikeFocusedIndex,
            personRowItemCounts: rows.map { $0.items.count },
            preferredPersonRowIndex: personFocusedRowIndex,
            preferredPersonItemIndex: personFocusedItemIndex
        ))
    }

    private func applyFocusResult(
        _ result: FocusEngineResult,
        previousFocus: FocusNodeID,
        direction: FocusDirection
    ) {
        var nextState = result.state
        if let episodeIndex = DetailFocusIDs.showEpisodeIndex(from: nextState.focused) {
            let entryIndex = episodeEntryIndex(
                previousFocus: previousFocus,
                direction: direction,
                fallback: episodeIndex
            )
            focusedEpisodeIndex = clampedEpisodeIndex(entryIndex)
            nextState.focused = DetailFocusIDs.showEpisode(focusedEpisodeIndex)
            nextState.rememberedChildByContainer[DetailFocusIDs.showEpisodes] = nextState.focused
        }
        if let moreLikeIndex = DetailFocusIDs.showMoreLikeIndex(from: nextState.focused) {
            moreLikeFocusedIndex = clampedMoreLikeIndex(count: similarShows.count, proposed: moreLikeIndex)
            nextState.focused = DetailFocusIDs.showMoreLike(moreLikeFocusedIndex)
        }
        if let personIndex = DetailFocusIDs.showPersonIndex(from: nextState.focused) {
            let clamped = clampedPersonIndex(
                rows: focusablePersonRows,
                proposedRow: personIndex.row,
                proposedItem: personIndex.item
            )
            personFocusedRowIndex = clamped.row
            personFocusedItemIndex = clamped.item
            nextState.focused = DetailFocusIDs.showPerson(row: clamped.row, item: clamped.item)
        }
        focusState = nextState
    }

    private func recordPlacementTransition(from previousFocus: FocusNodeID, direction: FocusDirection) {
        guard previousFocus != focusState.focused else { return }
        pendingFocusTransition = DetailFocusTransition(
            from: previousFocus,
            to: focusState.focused,
            direction: direction
        )
    }

    private func episodeEntryIndex(
        previousFocus: FocusNodeID,
        direction: FocusDirection,
        fallback: Int
    ) -> Int {
        guard DetailFocusIDs.showEpisodeIndex(from: previousFocus) == nil,
              let verticalDirection = detailEpisodeEntryDirection(for: direction),
              let entryIndex = DetailEpisodeTraversalPolicy.entryIndex(
                direction: verticalDirection,
                episodeCount: currentEpisodes.count
              ) else {
            return fallback
        }
        return entryIndex
    }

    private func detailEpisodeEntryDirection(for direction: FocusDirection) -> Int? {
        switch direction {
        case .down:
            return 1
        case .up:
            return -1
        case .left, .right:
            return nil
        }
    }

    private func isFocused(_ id: FocusNodeID) -> Bool {
        focusState.focused == id
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
            focus: focus,
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
              let targetViewportTop = measuredViewportTop(for: pending) else {
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

    private func measuredViewportTop(for pending: PendingDetailPlacementCorrection) -> CGFloat? {
        switch pending.target {
        case .episode:
            guard let measurement = focusedEpisodeMeasurement,
                  pending.accepts(measurement: measurement) else {
                return nil
            }
            return measurement.viewportTop
        case .relatedRow:
            return moreLikeRowViewportTop
        case .personRow(let rowIndex):
            let rows = focusablePersonRows
            guard rows.indices.contains(rowIndex) else { return nil }
            return personRowViewportTops[rows[rowIndex].id]
        case .top, .synopsis, .overview, .seasons:
            return nil
        }
    }

    private func currentEpisodeFocusID() -> FocusNodeID? {
        guard DetailFocusIDs.showEpisodeIndex(from: focusState.focused) != nil else {
            return nil
        }
        return focusState.focused
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
        if let episodeIndex = DetailFocusIDs.showEpisodeIndex(from: focus) {
            return DetailFocusScrollIDs.showEpisode(episodeIndex)
        }
        if DetailFocusIDs.showMoreLikeIndex(from: focus) != nil {
            return DetailRelatedRowLayout.scrollAnchorID
        }
        if let personIndex = DetailFocusIDs.showPersonIndex(from: focus) {
            let rows = focusablePersonRows
            guard rows.indices.contains(personIndex.row) else {
                return DetailFocusScrollIDs.showTop
            }
            return DetailFocusScrollIDs.showPersonRow(rows[personIndex.row].id)
        }
        if focus == DetailFocusIDs.showOverview {
            return DetailFocusScrollIDs.showMore
        }
        if focus == DetailFocusIDs.showSeasons {
            return DetailFocusScrollIDs.showSeasons
        }
        return DetailFocusScrollIDs.showTop
    }

    private func scrollAnchor(for focus: FocusNodeID) -> UnitPoint? {
        if DetailFocusIDs.showMoreLikeIndex(from: focus) != nil {
            return RemoteFocusScrollAnchor.detailRow
        }
        if DetailFocusIDs.showPersonIndex(from: focus) != nil {
            return RemoteFocusScrollAnchor.detailRow
        }
        if focus == DetailFocusIDs.showOverview {
            return RemoteFocusScrollAnchor.detail
        }
        if DetailFocusIDs.showEpisodeIndex(from: focus) != nil ||
            focus == DetailFocusIDs.showSeasons {
            return RemoteFocusScrollAnchor.detail
        }
        if focus == DetailFocusIDs.showBack ||
            focus == DetailFocusIDs.showStart ||
            focus == DetailFocusIDs.showContinue {
            return RemoteFocusScrollAnchor.detailTop
        }
        return RemoteFocusScrollAnchor.detailTop
    }

    private func handleRemoteEvent(_ event: RemoteCommandEvent) {
        guard !appState.playerController.isPlayerPresented else { return }
        guard event.consume() else { return }

        switch event.command {
        case .up:
            moveRemoteFocus(.up)
        case .down:
            moveRemoteFocus(.down)
        case .left:
            moveRemoteFocus(.left)
        case .right:
            moveRemoteFocus(.right)
        case .select:
            AudioIdentityService.shared.playFeedback(for: .select)
            selectRemoteFocus()
        case .back:
            AudioIdentityService.shared.playFeedback(for: .back)
            onDismiss?()
        }
    }

    @discardableResult
    private func stepSeason(direction: Int) -> Bool {
        guard let currentIndex = allSeasons.firstIndex(of: selectedSeason) else { return false }
        let nextIndex = max(0, min(allSeasons.count - 1, currentIndex + direction))
        guard nextIndex != currentIndex else { return false }
        selectSeason(allSeasons[nextIndex])
        return true
    }

    private func selectSeason(_ season: Int) {
        guard selectedSeason != season else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            selectedSeason = season
            focusedEpisodeIndex = 0
            focusState = ShowDetailFocusReconciler.resettingEpisodeMemoryAfterSeasonChange(focusState)
        }
    }

    private func clampFocusedEpisode() {
        focusedEpisodeIndex = min(max(0, focusedEpisodeIndex), max(0, currentEpisodes.count - 1))
    }

    private func clampedEpisodeIndex(_ proposed: Int? = nil) -> Int {
        guard !currentEpisodes.isEmpty else { return 0 }
        return min(max(proposed ?? focusedEpisodeIndex, 0), currentEpisodes.count - 1)
    }

    private func clampedMoreLikeIndex(count: Int, proposed: Int? = nil) -> Int {
        guard count > 0 else { return 0 }
        return min(max(proposed ?? moreLikeFocusedIndex, 0), count - 1)
    }

    private var focusablePersonRows: [BrowsePersonMediaRow] {
        let rows = personRows
        guard ShowDetailPersonRowsPolicy.shouldRender(
            rowCount: rows.count,
            hasSelectionHandler: onSelectItem != nil
        ) else { return [] }
        return rows
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
        guard let personIndex = DetailFocusIDs.showPersonIndex(from: focusState.focused),
              personIndex.row == rowIndex else { return nil }
        let rows = focusablePersonRows
        guard rows.indices.contains(personIndex.row),
              rows[personIndex.row].items.indices.contains(personIndex.item) else { return nil }
        return rows[personIndex.row].items[personIndex.item].id
    }

    private func firstPersonFocusID() -> FocusNodeID? {
        let rows = focusablePersonRows
        guard !rows.isEmpty, !rows[0].items.isEmpty else { return nil }
        return DetailFocusIDs.showPerson(row: 0, item: 0)
    }

    // MARK: - Navigation Helpers

    private func initSelectedSeason() {
        if let target = targetEpisode, let season = target.seasonNumber {
            selectedSeason = season
        } else if let next = upNext, let season = next.seasonNumber {
            selectedSeason = season
        } else if let first = allSeasons.first {
            selectedSeason = first
        }
    }

    private func syncFocusedEpisodeToAnchor() {
        let anchor = targetEpisode ?? upNext
        if let item = anchor,
           item.seasonNumber == selectedSeason,
           let index = currentEpisodes.firstIndex(where: { $0.id == item.id }) {
            focusedEpisodeIndex = index
        } else {
            clampFocusedEpisode()
        }
    }

}

private enum DetailDeferredSectionPolicy {
    static let delay: TimeInterval = 0.62
}

private enum DetailHeroArtworkPolicy {
    static let delay: TimeInterval = 0.36
}
