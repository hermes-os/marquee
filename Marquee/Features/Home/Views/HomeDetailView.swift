import SwiftUI
import AppKit

// MARK: - Home Detail View

struct HomeDetailView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var library: LibraryState
    let onOpenFile: () -> Void
    var onRemoteBackAtRoot: () -> Void = {}

    @Environment(\.kidsMode) private var kidsMode
    @Environment(\.leanBackMode) private var leanBackMode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var remoteInput: RemoteInputRouter
    @State private var scrollOffset: CGFloat = 0
    @State private var scanRotation: Angle = .degrees(0)
    @State private var selectedItem: MediaItem?
    @State private var selectedShow: String?
    @State private var selectedShowTargetEpisode: MediaItem?
    @State private var focusState = FocusEngineState(focused: HomeFocusIDs.heroItem(0))
    @State private var scrollGate = RemoteScrollRequestGate()
    @State private var previewArtworkReady: Bool = false
    @State private var rowsContentReady: Bool = false
    @State private var homeContentStageGeneration = 0
    @StateObject private var homeScrollController = BrowseVerticalScrollController()
    @State private var measuredRowViewportTops: [String: CGFloat] = [:]
    @State private var pendingReturnPlacement = PendingBrowseReturnPlacement()
    @State private var pendingReturnPlacementSerial: Int?
    #if DEBUG
    @State private var publishedQAReturnPlacementSerial: Int?
    #endif
    @State private var focusGeneration = 0
    @State private var previousPresentationState = BrowseSurfacePresentationState(
        route: .home,
        detailVisible: false,
        playerVisible: false,
        postPlayID: nil
    )

    // MARK: - Focus Tree

    /// Header, hero, and rows as one vertical tree. Row containers carry the
    /// focused column across vertical moves through the engine's hint index,
    /// which reproduces the legacy remembered-then-inherit column behavior.
    private var focusTree: FocusNode {
        var children: [FocusNode] = [FocusNode(HomeFocusIDs.playSomething, kind: .leaf)]
        let firstRowFocusID = homeRows.first(where: { !$0.items.isEmpty }).map {
            HomeFocusIDs.row($0.id)
        }

        if !heroSpotlightItems.isEmpty {
            children.append(
                FocusNode(
                    HomeFocusIDs.hero,
                    kind: .container(.grid(columns: heroSpotlightItems.count)),
                    children: heroSpotlightItems.indices.map {
                        FocusNode(
                            HomeFocusIDs.heroItem($0),
                            kind: .leaf,
                            guides: firstRowFocusID.map { [.down: $0] } ?? [:]
                        )
                    }
                )
            )
        }

        children.append(
            contentsOf: homeRows.compactMap { row in
                guard !row.items.isEmpty else { return nil }
                return FocusNode(
                    HomeFocusIDs.row(row.id),
                    kind: .container(.grid(columns: row.items.count)),
                    children: row.items.map {
                        FocusNode(HomeFocusIDs.item(rowID: row.id, itemID: $0.id), kind: .leaf)
                    }
                )
            }
        )

        return FocusNode(HomeFocusIDs.root, kind: .container(.vertical), children: children)
    }

    /// Placement descriptor derived from engine state. Section identity and
    /// `BrowseReturnFocus.home` still speak `RemoteHomeFocus`; it is no longer
    /// the focus authority.
    private var remoteFocus: RemoteHomeFocus {
        let focused = focusState.focused
        if focused == HomeFocusIDs.playSomething { return .playSomething }
        if HomeFocusIDs.heroItemIndex(focused) != nil || focused == HomeFocusIDs.hero {
            return .hero
        }
        if let position = rowPosition(for: focused) { return .row(position) }
        return hasHeroSpotlight ? .hero : .playSomething
    }

    private var focusedHeroIndex: Int {
        if let index = HomeFocusIDs.heroItemIndex(focusState.focused) { return index }
        if let remembered = focusState.rememberedChildByContainer[HomeFocusIDs.hero],
           let index = HomeFocusIDs.heroItemIndex(remembered) {
            return index
        }
        return 0
    }

    private func setFocusedHeroIndex(_ index: Int) {
        guard heroSpotlightItems.indices.contains(index) else { return }
        let id = HomeFocusIDs.heroItem(index)
        focusState.rememberedChildByContainer[HomeFocusIDs.hero] = id
        if HomeFocusIDs.heroItemIndex(focusState.focused) != nil {
            focusState.focused = id
        }
    }

    private func rowPosition(for id: FocusNodeID) -> RemoteGridPosition? {
        for (rowIndex, row) in homeRows.enumerated() {
            if let column = row.items.firstIndex(where: {
                HomeFocusIDs.item(rowID: row.id, itemID: $0.id) == id
            }) {
                return RemoteGridPosition(row: rowIndex, column: column)
            }
        }
        return nil
    }

    private func select(_ item: MediaItem) {
        if let show = item.showName {
            selectedShow = show
            selectedShowTargetEpisode = nil
        } else {
            selectedItem = item
        }
    }

    private func dismissDetail() {
        selectedItem = nil
        selectedShow = nil
        selectedShowTargetEpisode = nil
    }

    private var isCompact: Bool {
        scrollOffset > 60
    }

    // MARK: - Computed Rows

    private var heroSpotlightItems: [HeroSpotlight] {
        library.browseSnapshot.heroSpotlights
    }

    private var hasHeroSpotlight: Bool {
        !heroSpotlightItems.isEmpty
    }

    private var homeRows: [BrowseMediaRow] {
        library.browseSnapshot.homeRows
    }

    private var homeFocusRows: [HomeFocusRowSnapshot] {
        homeRows.map { HomeFocusRowSnapshot(id: $0.id, itemIDs: $0.items.map(\.id)) }
    }

    private var homeRowsSignature: String {
        HomeFocusContentPolicy.signature(
            heroIDs: heroSpotlightItems.map { $0.item.id },
            rows: homeFocusRows
        )
    }

    private var isDetailPresented: Bool {
        selectedItem != nil || selectedShow != nil
    }

    private var browsePresentationState: BrowseSurfacePresentationState {
        BrowseSurfacePresentationState(
            route: .home,
            detailVisible: isDetailPresented,
            playerVisible: appState.playerController.isPlayerPresented,
            postPlayID: appState.postPlayHandoff?.id
        )
    }

    private var activeBackground: Color {
        kidsMode ? MarqueeTheme.kidsBackground : MarqueeTheme.background
    }

    var body: some View {
        ZStack(alignment: .top) {
            activeBackground.ignoresSafeArea()

            if library.filteredLibraryItems.isEmpty && library.filteredTVItems.isEmpty {
                if library.isScanning {
                    scanningView
                } else {
                    emptyLibraryState
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            Spacer().frame(height: MarqueeTheme.scaled(120, leanBack: 170, isLeanBack: leanBackMode))
                            heroSpotlight
                                .id("hero-spotlight")
                            contentRows
                        }
                        .frame(maxWidth: .infinity)
                        .background(
                            BrowseVerticalScrollObserver(offset: $scrollOffset, controller: homeScrollController)
                                .frame(width: 0, height: 0)
                        )
                    }
                    .coordinateSpace(name: HomeScrollCoordinateSpace.name)
                    .onPreferenceChange(BrowseRowViewportTopPreferenceKey.self) { values in
                        measuredRowViewportTops = values
                        performPendingReturnPlacementIfPossible()
                    }
                    .onAppear {
                        previousPresentationState = browsePresentationState
                        scrollFocusedSection(proxy: proxy, animated: false)
                    }
                    .onChange(of: focusedSectionID) { _ in
                        focusGeneration += 1
                        pendingReturnPlacement.cancel(focusGeneration: focusGeneration)
                        pendingReturnPlacementSerial = nil
                        scrollFocusedSection(proxy: proxy, animated: true)
                    }
                    .onChange(of: homeRowsSignature) { _ in
                        clampRemoteFocus()
                        scrollFocusedSection(proxy: proxy, animated: false)
                    }
                    .onChange(of: isDetailPresented) { presented in
                        observePresentationState()
                    }
                    .onChange(of: appState.postPlayHandoff?.id) { _ in
                        observePresentationState()
                    }
                    .onChange(of: homeScrollController.geometryChangeSerial) { _ in
                        performPendingReturnPlacementIfPossible()
                    }
                    .onReceive(appState.playerController.$isPlayerPresented) { playerVisible in
                        observePresentationState(playerVisible: playerVisible)
                    }
                }

                stickyTitleBar
                BottomFadeView()
            }

            if let show = selectedShow {
                ShowDetailView(
                    showName: show,
                    appState: appState,
                    library: library,
                    targetEpisode: selectedShowTargetEpisode,
                    onSelectItem: { select($0) },
                    onSelectShow: { relatedShow in
                        selectedShow = relatedShow
                        selectedShowTargetEpisode = nil
                    },
                    onDismiss: dismissDetail,
                    onNavigateToSidebar: onRemoteBackAtRoot
                )
                .background(activeBackground.ignoresSafeArea())
                .transition(.opacity)
            } else if let item = selectedItem {
                MovieDetailView(
                    item: item,
                    appState: appState,
                    library: library,
                    onSelectItem: { select($0) },
                    dismiss: dismissDetail,
                    onNavigateToSidebar: onRemoteBackAtRoot
                )
                .background(activeBackground.ignoresSafeArea())
                .transition(.opacity)
            }
        }
        .onAppear {
            MarqueeMode.set(.browsing)
            clampRemoteFocus()
            stageHomeContent()
            MarqueeLogger.general.info("home appeared rows=\(homeRows.count, privacy: .public) hero=\(heroSpotlightItems.count, privacy: .public) movies=\(library.filteredLibraryItems.count, privacy: .public) tv=\(library.filteredTVItems.count, privacy: .public)")
        }
        .onChange(of: appState.showProfilePicker) { showing in
            guard !showing else { return }
            stageHomeContent()
        }
        .onChange(of: homeRowsSignature) { _ in
            clampRemoteFocus()
        }
        .onReceive(remoteInput.events) { event in
            handleRemoteEvent(event)
        }
        .onDisappear {
            homeContentStageGeneration &+= 1
        }
    }

    // MARK: - Sticky Title Bar

    private var stickyTitleBar: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: MarqueeTheme.scaled(14, leanBack: 22, isLeanBack: leanBackMode)) {
                Text("MARQUEE")
                    .font(.system(size: isCompact
                        ? MarqueeTheme.scaled(18, leanBack: 28, isLeanBack: leanBackMode)
                        : MarqueeTheme.scaled(26, leanBack: 38, isLeanBack: leanBackMode),
                        weight: .bold))
                    .tracking(MarqueeTheme.scaled(5, leanBack: 8, isLeanBack: leanBackMode))
                    .foregroundStyle(kidsMode ? MarqueeTheme.kidsTitleGradient : MarqueeTheme.titleGradient)

                if library.isScanning {
                    HStack(spacing: MarqueeTheme.scaled(6, leanBack: 9, isLeanBack: leanBackMode)) {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.64)
                        Text("Scanning")
                            .font(.system(size: MarqueeTheme.scaled(11, leanBack: 16, isLeanBack: leanBackMode), weight: .medium))
                            .foregroundColor(MarqueeTheme.textSecondary)
                    }
                    .padding(.horizontal, MarqueeTheme.scaled(9, leanBack: 14, isLeanBack: leanBackMode))
                    .padding(.vertical, MarqueeTheme.scaled(4, leanBack: 7, isLeanBack: leanBackMode))
                    .background(
                        Capsule()
                            .fill(MarqueeTheme.surfaceLayer.opacity(0.82))
                    )
                }

                Button(action: { appState.playSomething() }) {
                    HStack(spacing: MarqueeTheme.scaled(6, leanBack: 9, isLeanBack: leanBackMode)) {
                        Image(systemName: "shuffle")
                            .font(.system(size: MarqueeTheme.scaled(11, leanBack: 16, isLeanBack: leanBackMode), weight: .semibold))
                            .foregroundColor(MarqueeTheme.accentSecondary)
                        Text("Play Something")
                            .font(.system(size: MarqueeTheme.scaled(11, leanBack: 16, isLeanBack: leanBackMode), weight: .semibold))
                    }
                    .foregroundColor(MarqueeTheme.textPrimary)
                    .padding(.horizontal, MarqueeTheme.scaled(10, leanBack: 15, isLeanBack: leanBackMode))
                    .padding(.vertical, MarqueeTheme.scaled(5, leanBack: 8, isLeanBack: leanBackMode))
                    .background(Capsule().fill(MarqueeTheme.accentPrimary.opacity(0.86)))
                    .overlay(
                        Capsule()
                            .strokeBorder(MarqueeTheme.accentSecondary.opacity(0.34), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .focusChrome(
                    remoteFocus == .playSomething,
                    cornerRadius: 999,
                    accent: MarqueeTheme.accentPrimary,
                    focusScale: FocusChromeMetrics.controlFocusScale,
                    glowRadius: FocusChromeMetrics.detailGlowRadius,
                    ringLineWidth: FocusChromeMetrics.detailRingLineWidth
                )
                .accessibilityLabel("Play Something")

                Spacer()

                Text(libraryCountLabel)
                    .font(.system(size: MarqueeTheme.scaled(11, leanBack: 16, isLeanBack: leanBackMode), weight: .medium))
                    .foregroundColor(MarqueeTheme.textTertiary)
            }
                .padding(.horizontal, MarqueeTheme.outerPadding(isLeanBack: leanBackMode))
                .frame(maxWidth: .infinity)
                .frame(height: isCompact ? MarqueeTheme.scaled(44, leanBack: 62, isLeanBack: leanBackMode) : MarqueeTheme.scaled(78, leanBack: 108, isLeanBack: leanBackMode))
                .padding(.top, isCompact ? MarqueeTheme.scaled(4, leanBack: 8, isLeanBack: leanBackMode) : MarqueeTheme.scaled(8, leanBack: 12, isLeanBack: leanBackMode))
                .background(activeBackground)
                .animation(MarqueeTheme.motion(MarqueeTheme.compactHeaderAnimation, reduceMotion: reduceMotion), value: isCompact)

            LinearGradient(
                colors: [activeBackground, activeBackground.opacity(0)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: isCompact ? 20 : 6)
            .allowsHitTesting(false)
            .animation(MarqueeTheme.motion(MarqueeTheme.compactHeaderAnimation, reduceMotion: reduceMotion), value: isCompact)

            Spacer()
                .allowsHitTesting(false)
        }
    }

    private var libraryCountLabel: String {
        let movies = library.filteredLibraryItems.count
        let episodes = library.filteredTVItems.count
        if movies == 0 && episodes == 0 { return "" }
        return "\(movies) movie\(movies == 1 ? "" : "s")  /  \(episodes) episode\(episodes == 1 ? "" : "s")"
    }

    // MARK: - Bottom Fade

    private var bottomFade: some View {
        BottomFadeView()
    }

    // MARK: - Scanning State

    @State private var logoDepth: Bool = false

    private var scanningView: some View {
        VStack {
            Spacer()

            ZStack {
                Circle()
                    .stroke(MarqueeTheme.surfaceLayer, lineWidth: 3)
                    .frame(
                        width: MarqueeTheme.scaled(160, leanBack: 230, isLeanBack: leanBackMode),
                        height: MarqueeTheme.scaled(160, leanBack: 230, isLeanBack: leanBackMode)
                    )

                Circle()
                    .trim(from: 0, to: 0.3)
                    .stroke(
                        AngularGradient(
                            colors: [
                                Color(red: 0xC9 / 255.0, green: 0xA8 / 255.0, blue: 0x4C / 255.0),
                                Color(red: 0xE8 / 255.0, green: 0xD0 / 255.0, blue: 0x8C / 255.0),
                                Color(red: 0xD4 / 255.0, green: 0xAF / 255.0, blue: 0x5C / 255.0),
                            ],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round)
                    )
                    .frame(
                        width: MarqueeTheme.scaled(160, leanBack: 230, isLeanBack: leanBackMode),
                        height: MarqueeTheme.scaled(160, leanBack: 230, isLeanBack: leanBackMode)
                    )
                    .rotationEffect(scanRotation)
                    .onAppear {
                        withAnimation(
                            .linear(duration: 1.0)
                            .repeatForever(autoreverses: false)
                        ) {
                            scanRotation = .degrees(360)
                        }
                    }

                Image("MarqueeLogo")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(
                        width: MarqueeTheme.scaled(88, leanBack: 128, isLeanBack: leanBackMode),
                        height: MarqueeTheme.scaled(88, leanBack: 128, isLeanBack: leanBackMode)
                    )
                    .scaleEffect(logoDepth ? 1.15 : 0.85)
                    .opacity(logoDepth ? 1.0 : 0.7)
                    .shadow(
                        color: Color(red: 0xC9 / 255.0, green: 0xA8 / 255.0, blue: 0x4C / 255.0)
                            .opacity(logoDepth ? 0.7 : 0.1),
                        radius: logoDepth ? 24 : 6
                    )
                    .shadow(
                        color: Color.black.opacity(logoDepth ? 0.5 : 0.2),
                        radius: logoDepth ? 16 : 4,
                        y: logoDepth ? 8 : 2
                    )
            }
            .onAppear {
                withAnimation(
                    .easeInOut(duration: 2.2)
                    .repeatForever(autoreverses: true)
                ) {
                    logoDepth = true
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .transition(.opacity)
    }

    // MARK: - Empty State

    private var emptyLibraryState: some View {
        VStack(spacing: MarqueeTheme.spacingMD) {
            Spacer()
            Image(systemName: kidsMode ? "sparkles" : "film")
                .font(.system(size: MarqueeTheme.scaled(40, leanBack: 58, isLeanBack: leanBackMode), weight: .ultraLight))
                .foregroundColor(MarqueeTheme.textTertiary.opacity(0.4))
            Text(kidsMode ? "Loading your shows..." : "No content found")
                .font(.system(size: MarqueeTheme.scaled(17, leanBack: 24, isLeanBack: leanBackMode), weight: .medium))
                .foregroundColor(MarqueeTheme.textSecondary)
            Text("Content will appear once scanning completes")
                .font(.system(size: MarqueeTheme.scaled(12, leanBack: 17, isLeanBack: leanBackMode)))
                .foregroundColor(MarqueeTheme.textTertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Hero Spotlight

    private var heroSpotlight: some View {
        Group {
            if hasHeroSpotlight {
                HeroCarousel(
                    spotlights: heroSpotlightItems,
                    onPlay: { appState.playItem($0) },
                    isRemoteFocused: remoteFocus == .hero,
                    focusedIndex: focusedHeroIndex,
                    onFocusedIndexChange: { setFocusedHeroIndex($0) }
                )
            } else {
                heroFirstPaint
            }
        }
            .padding(.bottom, MarqueeTheme.scaled(12, leanBack: 20, isLeanBack: leanBackMode))
    }

    private var heroFirstPaint: some View {
        let spotlight = heroSpotlightItems.first
        return ZStack {
            RoundedRectangle(cornerRadius: MarqueeTheme.cornerRadiusLG)
                .fill(MarqueeTheme.surfaceElevated)

            if let posterPath = spotlight?.item.displayPosterPath {
                CachedImageView(
                    path: posterPath,
                    contentMode: .fill,
                    thumbnailPixelSize: ArtworkCache.gridPosterThumbnailPixelSize,
                    placeholderFillOpacity: 0,
                    placeholderIconOpacity: 0
                )
                .scaleEffect(1.2)
                .blur(radius: 12)
                .saturation(1.12)
                .contrast(1.08)
                .opacity(0.52)
            }

            Color.black.opacity(0.22)

            LinearGradient(
                colors: [
                    Color.black.opacity(0.62),
                    Color.black.opacity(0.18),
                    Color.black.opacity(0.76),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .frame(height: MarqueeTheme.scaled(420, leanBack: 520, isLeanBack: leanBackMode))
        .clipShape(RoundedRectangle(cornerRadius: MarqueeTheme.cornerRadiusLG))
        .overlay(alignment: .topLeading) {
            heroFirstPaintBadge(spotlight)
                .padding(MarqueeTheme.scaled(20, leanBack: 32, isLeanBack: leanBackMode))
        }
        .overlay(alignment: .bottomLeading) {
            heroFirstPaintContent(spotlight)
                .padding(MarqueeTheme.scaled(20, leanBack: 32, isLeanBack: leanBackMode))
        }
        .padding(.horizontal, MarqueeTheme.outerPadding(isLeanBack: leanBackMode))
    }

    private func heroFirstPaintBadge(_ spotlight: HeroSpotlight?) -> some View {
        HStack(spacing: MarqueeTheme.scaled(5, leanBack: 8, isLeanBack: leanBackMode)) {
            Image(systemName: spotlight?.icon ?? "film.stack")
                .font(.system(size: MarqueeTheme.scaled(10, leanBack: 14, isLeanBack: leanBackMode), weight: .semibold))
            Text((spotlight?.category ?? "Spotlight").uppercased())
                .font(.system(size: MarqueeTheme.scaled(10, leanBack: 14, isLeanBack: leanBackMode), weight: .bold))
                .tracking(MarqueeTheme.scaled(1.2, leanBack: 1.6, isLeanBack: leanBackMode))
        }
        .foregroundColor(MarqueeTheme.accentSecondary)
        .padding(.horizontal, MarqueeTheme.scaled(10, leanBack: 15, isLeanBack: leanBackMode))
        .padding(.vertical, MarqueeTheme.scaled(5, leanBack: 8, isLeanBack: leanBackMode))
        .background(Capsule().fill(Color.black.opacity(0.62)))
    }

    private func heroFirstPaintContent(_ spotlight: HeroSpotlight?) -> some View {
        HStack(alignment: .bottom, spacing: MarqueeTheme.scaled(20, leanBack: 30, isLeanBack: leanBackMode)) {
            VStack(alignment: .leading, spacing: MarqueeTheme.scaled(6, leanBack: 10, isLeanBack: leanBackMode)) {
                Text(spotlight?.item.browseTitle ?? "MARQUEE")
                    .font(.system(size: MarqueeTheme.scaled(28, leanBack: 42, isLeanBack: leanBackMode), weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(2)

                if let spotlight {
                    HStack(spacing: MarqueeTheme.scaled(8, leanBack: 12, isLeanBack: leanBackMode)) {
                        if let year = spotlight.item.isEpisode ? nil : spotlight.item.displayYear {
                            Text(year)
                        }
                        Text(spotlight.item.isEpisode ? spotlight.item.episodeLabel : spotlight.item.formatBadge)
                            .font(.system(size: MarqueeTheme.scaled(11, leanBack: 15, isLeanBack: leanBackMode), weight: .semibold, design: .monospaced))
                            .foregroundColor(MarqueeTheme.accentSecondary.opacity(0.8))
                    }
                    .font(.system(size: MarqueeTheme.scaled(13, leanBack: 18, isLeanBack: leanBackMode), weight: .medium))
                    .foregroundColor(MarqueeTheme.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let spotlight {
                PosterFallbackArtwork(
                    title: spotlight.item.browseTitle,
                    badge: spotlight.item.isEpisode ? spotlight.item.episodeLabel : spotlight.item.formatBadge,
                    systemImage: spotlight.item.isEpisode ? "tv.fill" : "play.rectangle.fill"
                )
                .frame(
                    width: MarqueeTheme.scaled(116, leanBack: 172, isLeanBack: leanBackMode),
                    height: MarqueeTheme.scaled(174, leanBack: 258, isLeanBack: leanBackMode)
                )
            }
        }
    }

    // MARK: - Content Rows

    private var contentRows: some View {
        LazyVStack(alignment: .leading, spacing: MarqueeTheme.scaled(36, leanBack: 54, isLeanBack: leanBackMode)) {
            if !library.filteredLibraryItems.isEmpty || !library.filteredTVItems.isEmpty {
                if rowsContentReady {
                    ForEach(Array(homeRows.enumerated()), id: \.element.id) { rowIndex, row in
                        MediaItemRow(
                            title: row.title,
                            items: row.items,
                            focusedItemID: focusedItemID(in: rowIndex),
                            onSelect: { select($0) }
                        )
                        .id(row.id)
                        .background(rowViewportTopObserver(id: row.id))
                        .background(qaHomeRowsInteractiveProbe(row: row, rowIndex: rowIndex))
                    }
                } else {
                    firstRowsPreview
                }
            }

            if library.filteredLibraryItems.isEmpty && library.filteredTVItems.isEmpty && !library.isScanning {
                VStack(spacing: MarqueeTheme.spacingMD) {
                    Text("No movies found")
                        .font(.system(size: MarqueeTheme.scaled(17, leanBack: 24, isLeanBack: leanBackMode), weight: .medium))
                        .foregroundColor(MarqueeTheme.textSecondary)
                    Text("Scanning \(UserSettings.shared.moviesPaths.first ?? "~/Movies")")
                        .font(.system(size: MarqueeTheme.scaled(12, leanBack: 17, isLeanBack: leanBackMode)))
                        .foregroundColor(MarqueeTheme.textTertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, MarqueeTheme.scaled(60, leanBack: 88, isLeanBack: leanBackMode))
            }
        }
        .padding(.top, MarqueeTheme.scaled(32, leanBack: 48, isLeanBack: leanBackMode))
        .padding(.horizontal, MarqueeTheme.outerPadding(isLeanBack: leanBackMode))
        .padding(.bottom, MarqueeTheme.scaled(100, leanBack: 150, isLeanBack: leanBackMode))
    }

    private var firstRowsPreview: some View {
        let row = homeRows.first
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(row?.title ?? "Recently Added")
                    .font(.system(size: leanBackMode ? 28 : 20, weight: .semibold))
                    .foregroundColor(MarqueeTheme.textPrimary)

                Spacer()

                if let row {
                    Text("\(row.items.count) title\(row.items.count == 1 ? "" : "s")")
                        .font(.system(size: leanBackMode ? 16 : 12, weight: .medium))
                        .foregroundColor(MarqueeTheme.textTertiary)
                }
            }

            HStack(spacing: MarqueeTheme.cardGap(isLeanBack: leanBackMode)) {
                ForEach(Array((row?.items ?? []).prefix(8))) { item in
                    FirstPaintPosterCard(item: item, showArtwork: previewArtworkReady)
                }
            }
        }
    }

    private func stageHomeContent() {
        homeContentStageGeneration &+= 1
        let generation = homeContentStageGeneration
        previewArtworkReady = true
        rowsContentReady = false
        DispatchQueue.main.async {
            guard generation == homeContentStageGeneration else { return }
            rowsContentReady = true
        }
    }

    @ViewBuilder
    private func qaHomeRowsInteractiveProbe(row: BrowseMediaRow, rowIndex: Int) -> some View {
        #if DEBUG
        if rowIndex == 0 {
            QAHomeRowsInteractiveProbe(
                descriptor: qaHomeRowsInteractiveDescriptor(row: row, rowIndex: rowIndex)
            )
        }
        #else
        EmptyView()
        #endif
    }

    #if DEBUG
    private func qaHomeRowsInteractiveDescriptor(
        row: BrowseMediaRow,
        rowIndex: Int
    ) -> QAHomeRowsInteractiveDescriptor? {
        guard rowIndex == 0,
              !row.items.isEmpty,
              !appState.showProfilePicker,
              !appState.isProfileExitInFlight,
              appState.router.selectedItem == .home,
              let currentFirstRow = homeRows.first,
              currentFirstRow.id == row.id,
              currentFirstRow.items.map(\.id) == row.items.map(\.id),
              let profileID = appState.activeProfile?.id,
              let selectionEvidence = appState.profileSession.debugSelectionCompletionEvidence,
              selectionEvidence.profileID == profileID else {
            return nil
        }
        return QAHomeRowsInteractiveDescriptor(
            profileID: profileID,
            selectionCompletedAt: selectionEvidence.completedAt,
            rowID: row.id,
            itemIDs: row.items.map(\.id),
            rowCount: homeRows.count
        )
    }
    #endif

    private func focusedItemID(in rowIndex: Int) -> MediaItem.ID? {
        guard let rowFocus = remoteFocus.rowPosition,
              rowIndex == rowFocus.row,
              homeRows.indices.contains(rowIndex),
              homeRows[rowIndex].items.indices.contains(rowFocus.column) else {
            return nil
        }
        return homeRows[rowIndex].items[rowFocus.column].id
    }

    private var focusedRowID: String? {
        guard let rowFocus = remoteFocus.rowPosition,
              homeRows.indices.contains(rowFocus.row) else { return nil }
        return homeRows[rowFocus.row].id
    }

    private var focusedSectionID: String? {
        switch remoteFocus {
        case .playSomething:
            return nil
        case .hero:
            return hasHeroSpotlight ? "hero-spotlight" : nil
        case .row(let position):
            guard homeRows.indices.contains(position.row) else { return nil }
            return homeRows[position.row].id
        }
    }

    private func scrollFocusedSection(proxy: ScrollViewProxy, animated: Bool) {
        guard let id = focusedSectionID else { return }
        let serial = scrollGate.issue()
        let action = {
            guard scrollGate.accepts(serial) else { return }
            if remoteFocus == .hero {
                if homeScrollController.springScroll(
                    to: RemoteHomeHeroScrollPlacement.targetOffset(currentOffset: scrollOffset),
                    animated: animated,
                    reduceMotion: reduceMotion
                ) {
                    return
                }
                proxy.scrollTo(id, anchor: RemoteFocusScrollAnchor.hero)
            } else {
                if scrollFocusedHomeRowIfNeeded(id: id, animated: animated) {
                    return
                }
                proxy.scrollTo(id, anchor: RemoteFocusScrollAnchor.row)
            }
        }
        let perform = {
            RemoteProgrammaticScrollPolicy.perform(animated: animated, reduceMotion: reduceMotion) {
                action()
            }
        }
        DispatchQueue.main.async(execute: perform)
    }

    private func scrollFocusedHomeRowIfNeeded(id: String, animated: Bool) -> Bool {
        guard let rowViewportTop = measuredRowViewportTops[id] else { return false }
        let viewportHeight = homeScrollController.viewportHeight
        guard !RemoteHomeRowScrollPlacement.isComfortablyPlaced(
            rowViewportTop: rowViewportTop,
            viewportHeight: viewportHeight
        ) else {
            return true
        }

        let targetOffset = RemoteHomeRowScrollPlacement.targetOffset(
            currentOffset: scrollOffset,
            rowViewportTop: rowViewportTop,
            desiredViewportTop: RemoteHomeRowScrollPlacement.desiredViewportTop(viewportHeight: viewportHeight)
        )
        return homeScrollController.springScroll(
            to: targetOffset,
            animated: animated,
            reduceMotion: reduceMotion
        )
    }

    private func rowViewportTopObserver(id: String) -> some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: BrowseRowViewportTopPreferenceKey.self,
                value: [id: proxy.frame(in: .named(HomeScrollCoordinateSpace.name)).minY]
            )
        }
    }

    private func observePresentationState(playerVisible: Bool? = nil) {
        var current = browsePresentationState
        if let playerVisible {
            current = BrowseSurfacePresentationState(
                route: current.route,
                detailVisible: current.detailVisible,
                playerVisible: playerVisible,
                postPlayID: current.postPlayID
            )
        }
        guard current != previousPresentationState else { return }
        let previous = previousPresentationState
        previousPresentationState = current
        #if DEBUG
        NotificationCenter.default.post(
            name: .marqueeQABrowsePresentationObserved,
            object: current
        )
        #endif
        guard BrowseSurfaceExitPolicy.shouldPlace(from: previous, to: current) else { return }
        issueReturnPlacement()
    }

    private func issueReturnPlacement() {
        clampRemoteFocus()
        guard let target = BrowseReturnPlacementPolicy.target(
            for: BrowseReturnFocus.home(remoteFocus, rowID: focusedRowID)
        ) else { return }
        pendingReturnPlacementSerial = pendingReturnPlacement.issue(
            target: target,
            focusGeneration: focusGeneration,
            attachmentEpoch: homeScrollController.attachmentEpoch
        )
        #if DEBUG
        publishedQAReturnPlacementSerial = nil
        #endif
        performPendingReturnPlacementIfPossible()
    }

    private func performPendingReturnPlacementIfPossible() {
        let currentTarget = BrowseReturnPlacementPolicy.target(
            for: BrowseReturnFocus.home(remoteFocus, rowID: focusedRowID)
        )
        pendingReturnPlacement.cancelIfTargetChanged(to: currentTarget)
        guard let serial = pendingReturnPlacementSerial,
              let target = currentTarget else {
            pendingReturnPlacementSerial = nil
            return
        }
        guard pendingReturnPlacement.isActive(serial: serial) else {
            pendingReturnPlacementSerial = nil
            return
        }
        let targetMinY: CGFloat
        switch target {
        case .top:
            targetMinY = 0
        case .row(let id):
            guard let viewportTop = measuredRowViewportTops[id] else { return }
            targetMinY = homeScrollController.currentOffset + viewportTop
        }
        let sample = BrowseReturnGeometrySample(
            target: target,
            targetMinY: targetMinY,
            viewportHeight: homeScrollController.viewportHeight,
            currentOffset: homeScrollController.currentOffset,
            contentHeight: homeScrollController.contentHeight,
            attachmentEpoch: homeScrollController.attachmentEpoch,
            focusGeneration: focusGeneration
        )
        let offset = pendingReturnPlacement.consume(sample: sample, serial: serial)
        #if DEBUG
        if publishedQAReturnPlacementSerial != serial,
           publishQAReturnPlacementIfCorrect(target: target) {
            publishedQAReturnPlacementSerial = serial
        }
        #endif
        if !pendingReturnPlacement.isActive(serial: serial) {
            pendingReturnPlacementSerial = nil
        }
        if let offset {
            _ = homeScrollController.scroll(to: offset, animated: false, reduceMotion: reduceMotion)
        }
    }

    #if DEBUG
    private func publishQAReturnPlacementIfCorrect(target: BrowseReturnPlacementTarget) -> Bool {
        let evidence: BrowseReturnPlacementEvidence
        switch target {
        case .top:
            let focusID: String
            switch remoteFocus {
            case .playSomething:
                focusID = "header"
            case .hero:
                focusID = heroSpotlightItems.indices.contains(focusedHeroIndex)
                    ? heroSpotlightItems[focusedHeroIndex].item.id.uuidString
                    : "hero"
            case .row:
                return false
            }
            evidence = BrowseReturnPlacementEvidence(
                route: .home,
                target: target,
                focusID: focusID,
                rowTitle: nil,
                rowViewportTop: nil,
                viewportHeight: homeScrollController.viewportHeight,
                currentOffset: homeScrollController.currentOffset
            )
        case .row(let id):
            guard let row = homeRows.first(where: { $0.id == id }),
                  let rowViewportTop = measuredRowViewportTops[id],
                  case .row(let position) = remoteFocus,
                  homeRows.indices.contains(position.row),
                  homeRows[position.row].id == id,
                  row.items.indices.contains(position.column) else { return false }
            evidence = BrowseReturnPlacementEvidence(
                route: .home,
                target: target,
                focusID: row.items[position.column].id.uuidString,
                rowTitle: row.title,
                rowViewportTop: rowViewportTop,
                viewportHeight: homeScrollController.viewportHeight,
                currentOffset: homeScrollController.currentOffset
            )
        }
        guard evidence.isCorrectlyPlaced else { return false }
        NotificationCenter.default.post(
            name: .marqueeQABrowseReturnPlaced,
            object: evidence
        )
        return true
    }
    #endif

    /// Content can shrink under a stale focus ID. Keep the remembered section
    /// and clamp its preferred column instead of discarding all focus memory.
    private func clampRemoteFocus() {
        guard !focusContains(focusTree, id: focusState.focused) else { return }
        focusState = HomeFocusContentPolicy.repair(
            focusState,
            heroIDs: heroSpotlightItems.map { $0.item.id },
            rows: homeFocusRows
        )
    }

    private func focusContains(_ node: FocusNode, id: FocusNodeID) -> Bool {
        if node.id == id { return true }
        return node.children.contains { focusContains($0, id: id) }
    }

    private func handleRemoteEvent(_ event: RemoteCommandEvent) {
        guard selectedItem == nil,
              selectedShow == nil,
              !appState.playerController.isPlayerPresented else {
            return
        }

        guard event.consume() else { return }

        switch event.command {
        case .up, .down, .left, .right:
            clampRemoteFocus()
            guard let direction = focusDirection(for: event.command) else { return }
            let previousFocused = focusState.focused
            let result = FocusEngine(root: focusTree).move(direction, state: focusState)
            focusState = result.state

            // Surface-local edge policy, the same shape Movies uses to turn a
            // left boundary into back-at-root: the hero wraps instead.
            if focusState.focused == previousFocused,
               let wrapped = wrappedHeroFocus(for: direction, from: previousFocused) {
                focusState.focused = wrapped
                focusState.rememberedChildByContainer[HomeFocusIDs.hero] = wrapped
            }

            let didNavigate = focusState.focused != previousFocused
            if direction == .left, !didNavigate, rowPosition(for: previousFocused) != nil {
                AudioIdentityService.shared.playFeedback(for: .left, didNavigate: true)
                onRemoteBackAtRoot()
            } else {
                AudioIdentityService.shared.playFeedback(
                    for: event.command,
                    didNavigate: didNavigate,
                    didReachBoundary: !didNavigate
                )
            }
        case .select:
            AudioIdentityService.shared.playFeedback(for: .select)
            clampRemoteFocus()
            switch remoteFocus {
            case .playSomething:
                appState.playSomething()
            case .hero:
                guard heroSpotlightItems.indices.contains(focusedHeroIndex) else { return }
                appState.playItem(heroSpotlightItems[focusedHeroIndex].item)
            case .row(let rowFocus):
                guard homeRows.indices.contains(rowFocus.row),
                      homeRows[rowFocus.row].items.indices.contains(rowFocus.column) else {
                    return
                }
                select(homeRows[rowFocus.row].items[rowFocus.column])
            }
        case .back:
            AudioIdentityService.shared.playFeedback(for: .back)
            onRemoteBackAtRoot()
        }
    }

    private func focusDirection(for command: RemoteCommand) -> FocusDirection? {
        switch command {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .select, .back: return nil
        }
    }

    /// Hero left/right wrap rather than stopping at the container edge.
    private func wrappedHeroFocus(
        for direction: FocusDirection,
        from focused: FocusNodeID
    ) -> FocusNodeID? {
        guard direction == .left || direction == .right,
              let current = HomeFocusIDs.heroItemIndex(focused),
              heroSpotlightItems.count > 1 else {
            return nil
        }
        let wrapped = RemoteHomeFocus.wrappedHeroIndex(
            current: current,
            delta: direction == .left ? -1 : 1,
            count: heroSpotlightItems.count
        )
        return HomeFocusIDs.heroItem(wrapped)
    }

}

private enum HomeFocusIDs {
    static let root: FocusNodeID = "home-root"
    static let playSomething: FocusNodeID = "home-play-something"
    static let hero: FocusNodeID = "home-hero"

    static func heroItem(_ index: Int) -> FocusNodeID {
        FocusNodeID("home-hero-item:\(index)")
    }

    static func heroItemIndex(_ id: FocusNodeID) -> Int? {
        let prefix = "home-hero-item:"
        guard id.rawValue.hasPrefix(prefix) else { return nil }
        return Int(id.rawValue.dropFirst(prefix.count))
    }

    static func row(_ id: String) -> FocusNodeID {
        FocusNodeID("home-row:\(id)")
    }

    static func item(rowID: String, itemID: MediaItem.ID) -> FocusNodeID {
        FocusNodeID("home-item:\(rowID):\(itemID.uuidString)")
    }
}

private struct HomeFocusRowSnapshot {
    let id: String
    let itemIDs: [UUID]
}

private enum HomeFocusContentPolicy {
    static func signature(heroIDs: [UUID], rows: [HomeFocusRowSnapshot]) -> String {
        let hero = heroIDs.map(\.uuidString).joined(separator: ",")
        let rows = rows.map { row in
            "\(row.id):\(row.itemIDs.map(\.uuidString).joined(separator: ","))"
        }.joined(separator: "|")
        return "hero:\(hero)|\(rows)"
    }

    static func repair(
        _ state: FocusEngineState,
        heroIDs: [UUID],
        rows: [HomeFocusRowSnapshot]
    ) -> FocusEngineState {
        var repaired = state
        let rememberedSection = state.rememberedChildByContainer[HomeFocusIDs.root]

        if rememberedSection == HomeFocusIDs.hero || HomeFocusIDs.heroItemIndex(state.focused) != nil,
           !heroIDs.isEmpty {
            let preferredColumn = state.preferredGridColumnByContainer[HomeFocusIDs.hero]
                ?? HomeFocusIDs.heroItemIndex(state.focused)
                ?? 0
            let column = min(max(0, preferredColumn), heroIDs.count - 1)
            let target = HomeFocusIDs.heroItem(column)
            repaired.focused = target
            repaired.rememberedChildByContainer[HomeFocusIDs.root] = HomeFocusIDs.hero
            repaired.rememberedChildByContainer[HomeFocusIDs.hero] = target
            repaired.preferredGridColumnByContainer[HomeFocusIDs.hero] = column
            return repaired
        }

        if let rememberedSection,
           let row = rows.first(where: {
               HomeFocusIDs.row($0.id) == rememberedSection && !$0.itemIDs.isEmpty
           }) {
            let preferredColumn = state.preferredGridColumnByContainer[rememberedSection] ?? 0
            let column = min(max(0, preferredColumn), row.itemIDs.count - 1)
            let target = HomeFocusIDs.item(rowID: row.id, itemID: row.itemIDs[column])
            repaired.focused = target
            repaired.rememberedChildByContainer[rememberedSection] = target
            repaired.preferredGridColumnByContainer[rememberedSection] = column
            return repaired
        }

        if !heroIDs.isEmpty {
            repaired.focused = HomeFocusIDs.heroItem(0)
        } else if let row = rows.first(where: { !$0.itemIDs.isEmpty }), let itemID = row.itemIDs.first {
            repaired.focused = HomeFocusIDs.item(rowID: row.id, itemID: itemID)
        } else {
            repaired.focused = HomeFocusIDs.playSomething
        }
        return repaired
    }
}

#if DEBUG
private struct QAHomeRowsInteractiveDescriptor: Equatable {
    let profileID: UUID
    let selectionCompletedAt: Date
    let rowID: String
    let itemIDs: [UUID]
    let rowCount: Int

    var evidence: QAHomeRowsInteractiveEvidence {
        QAHomeRowsInteractiveEvidence(
            profileID: profileID,
            selectionCompletedAt: selectionCompletedAt,
            rowID: rowID,
            itemIDs: itemIDs,
            rowCount: rowCount,
            itemCount: itemIDs.count,
            completedAt: Date()
        )
    }
}

private struct QAHomeRowsInteractiveProbe: NSViewRepresentable {
    let descriptor: QAHomeRowsInteractiveDescriptor?

    func makeNSView(context: Context) -> QAHomeRowsInteractiveProbeView {
        let view = QAHomeRowsInteractiveProbeView()
        view.update(descriptor)
        return view
    }

    func updateNSView(_ nsView: QAHomeRowsInteractiveProbeView, context: Context) {
        nsView.update(descriptor)
    }

    static func dismantleNSView(_ nsView: QAHomeRowsInteractiveProbeView, coordinator: ()) {
        nsView.detach()
    }
}

private final class QAHomeRowsInteractiveProbeView: NSView {
    private var descriptor: QAHomeRowsInteractiveDescriptor?
    private var lastPublishedDescriptor: QAHomeRowsInteractiveDescriptor?
    private var publishGeneration = 0

    func update(_ descriptor: QAHomeRowsInteractiveDescriptor?) {
        guard self.descriptor != descriptor else { return }
        self.descriptor = descriptor
        if descriptor == nil {
            lastPublishedDescriptor = nil
            publishGeneration &+= 1
            return
        }
        schedulePublishIfAttached()
    }

    func detach() {
        descriptor = nil
        lastPublishedDescriptor = nil
        publishGeneration &+= 1
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            publishGeneration &+= 1
        } else {
            lastPublishedDescriptor = nil
            schedulePublishIfAttached()
        }
    }

    override func layout() {
        super.layout()
        schedulePublishIfAttached()
    }

    private func schedulePublishIfAttached() {
        guard window != nil,
              superview != nil,
              bounds.width > 0,
              bounds.height > 0,
              bounds.width.isFinite,
              bounds.height.isFinite,
              let descriptor,
              descriptor != lastPublishedDescriptor else {
            return
        }
        publishGeneration &+= 1
        let generation = publishGeneration
        let scheduledDescriptor = descriptor
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.publishGeneration == generation,
                  self.window != nil,
                  self.superview != nil,
                  self.bounds.width > 0,
                  self.bounds.height > 0,
                  self.bounds.width.isFinite,
                  self.bounds.height.isFinite,
                  self.descriptor == scheduledDescriptor else {
                return
            }
            self.lastPublishedDescriptor = scheduledDescriptor
            NotificationCenter.default.post(
                name: .marqueeQAHomeRowsInteractive,
                object: scheduledDescriptor.evidence
            )
        }
    }
}
#endif

private struct FirstPaintPosterCard: View {
    let item: MediaItem
    let showArtwork: Bool

    @Environment(\.leanBackMode) private var leanBackMode

    private var posterThumbnailSize: CGSize {
        leanBackMode
            ? ArtworkCache.leanBackPosterThumbnailPixelSize
            : ArtworkCache.gridPosterThumbnailPixelSize
    }

    private var cardWidth: CGFloat {
        leanBackMode ? 225 : 150
    }

    private var posterHeight: CGFloat {
        UniversalPosterCardArtworkLayout.frameHeight(forWidth: cardWidth)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: MarqueeTheme.cornerRadiusMD)
                    .fill(MarqueeTheme.surfaceElevated)

                PosterFallbackArtwork(
                    title: item.browseTitle,
                    badge: item.isEpisode ? item.episodeLabel : item.formatBadge,
                    systemImage: item.isEpisode ? "tv.fill" : "film.fill"
                )

                if showArtwork, let path = item.isEpisode ? item.gridShowPosterPath : item.gridPosterPath {
                    CachedImageView(
                        path: path,
                        contentMode: .fill,
                        thumbnailPixelSize: posterThumbnailSize,
                        placeholderFillOpacity: 0,
                        placeholderIconOpacity: 0
                    )
                }
            }
            .frame(height: posterHeight)
            .clipShape(RoundedRectangle(cornerRadius: MarqueeTheme.cornerRadiusMD))

            Text(item.browseTitle)
                .font(.system(size: leanBackMode ? 18 : 13, weight: .medium))
                .foregroundColor(MarqueeTheme.textSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: cardWidth, alignment: .leading)
    }
}

// MARK: - Scroll Offset Observer

private enum HomeScrollCoordinateSpace {
    static let name = "home-scroll"
}

#if DEBUG
enum VerifyHomeScrollRuntimeHarness {
    static func verify() throws -> String {
        guard Thread.isMainThread else {
            throw HarnessError.assertion("Home scroll runtime harness must run on the main thread")
        }

        let staleItemIDs = [UUID(), UUID(), UUID()]
        let replacementItemIDs = [UUID(), UUID(), UUID()]
        let beforeReplacement = HomeFocusContentPolicy.signature(
            heroIDs: [],
            rows: [HomeFocusRowSnapshot(id: "recently-added", itemIDs: staleItemIDs)]
        )
        let afterReplacement = HomeFocusContentPolicy.signature(
            heroIDs: [],
            rows: [HomeFocusRowSnapshot(id: "recently-added", itemIDs: replacementItemIDs)]
        )
        guard beforeReplacement != afterReplacement else {
            throw HarnessError.assertion("same-count Home item replacement must invalidate stale focus identity")
        }

        let rowID = HomeFocusIDs.row("recently-added")
        let otherRowID = HomeFocusIDs.row("favorites")
        let otherRememberedItem = HomeFocusIDs.item(rowID: "favorites", itemID: UUID())
        var staleFocusState = FocusEngineState(
            focused: HomeFocusIDs.item(rowID: "recently-added", itemID: staleItemIDs[2])
        )
        staleFocusState.rememberedChildByContainer[HomeFocusIDs.root] = rowID
        staleFocusState.rememberedChildByContainer[rowID] = staleFocusState.focused
        staleFocusState.rememberedChildByContainer[otherRowID] = otherRememberedItem
        staleFocusState.preferredGridColumnByContainer[rowID] = 2

        let replacedFocusState = HomeFocusContentPolicy.repair(
            staleFocusState,
            heroIDs: [],
            rows: [HomeFocusRowSnapshot(id: "recently-added", itemIDs: replacementItemIDs)]
        )
        let replacementTarget = HomeFocusIDs.item(
            rowID: "recently-added",
            itemID: replacementItemIDs[2]
        )
        guard replacedFocusState.focused == replacementTarget,
              replacedFocusState.rememberedChildByContainer[HomeFocusIDs.root] == rowID,
              replacedFocusState.rememberedChildByContainer[rowID] == replacementTarget,
              replacedFocusState.rememberedChildByContainer[otherRowID] == otherRememberedItem,
              replacedFocusState.preferredGridColumnByContainer[rowID] == 2 else {
            throw HarnessError.assertion("same-count Home replacement must preserve section and column memory")
        }

        let survivingItemID = UUID()
        let shrunkFocusState = HomeFocusContentPolicy.repair(
            staleFocusState,
            heroIDs: [],
            rows: [HomeFocusRowSnapshot(id: "recently-added", itemIDs: [survivingItemID])]
        )
        let clampedTarget = HomeFocusIDs.item(rowID: "recently-added", itemID: survivingItemID)
        guard shrunkFocusState.focused == clampedTarget,
              shrunkFocusState.rememberedChildByContainer[HomeFocusIDs.root] == rowID,
              shrunkFocusState.rememberedChildByContainer[rowID] == clampedTarget,
              shrunkFocusState.rememberedChildByContainer[otherRowID] == otherRememberedItem,
              shrunkFocusState.preferredGridColumnByContainer[rowID] == 0 else {
            throw HarnessError.assertion("shrinking Home row must clamp focus without clearing other row memory")
        }

        let unattachedController = BrowseVerticalScrollController()
        guard !unattachedController.scroll(to: 120, animated: false) else {
            throw HarnessError.assertion("unattached Home scroll controller should report failed scroll")
        }

        let unattachedHorizontalController = RemoteHorizontalScrollController()
        guard unattachedHorizontalController.attachmentSerial == 0 else {
            throw HarnessError.assertion("fresh horizontal controller should start unattached")
        }
        guard !unattachedHorizontalController.scroll(to: 166, animated: false) else {
            throw HarnessError.assertion("unattached horizontal scroll controller should report failed scroll")
        }

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let documentView = NSView(frame: NSRect(x: 0, y: 0, width: 2_400, height: 2_000))
        scrollView.documentView = documentView
        scrollView.contentView.postsBoundsChangedNotifications = true

        let controller = BrowseVerticalScrollController()
        var didAttach = false
        var observedOffset: CGFloat?
        let spy = BrowseScrollSpy(frame: .zero)
        spy.onAttachScrollView = { attachedScrollView in
            guard attachedScrollView === scrollView else { return }
            didAttach = true
            controller.attach(attachedScrollView)
        }
        spy.onChange = { offset in
            observedOffset = offset
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        window.contentView = scrollView
        documentView.addSubview(spy)

        guard waitUntil({ didAttach }, timeout: 1.5) else {
            window.close()
            throw HarnessError.assertion("_ScrollSpy did not attach to the containing NSScrollView")
        }

        guard controller.scroll(to: 390, animated: false) else {
            window.close()
            throw HarnessError.assertion("attached Home scroll controller did not perform AppKit scroll")
        }

        let y = scrollView.contentView.bounds.origin.y
        guard abs(y - 390) < 0.5 else {
            window.close()
            throw HarnessError.assertion("expected AppKit Home scroll y=390, got \(y)")
        }

        // `BrowseScrollSpy.boundsChanged` receives the notification synchronously
        // but hands the offset to the main queue, so the spy's callback runs on a
        // later turn. Polling the captured value against a wall-clock deadline
        // raced a starved run loop; draining one main-queue turn is exact,
        // because the queue is FIFO and the spy enqueued its callback during the
        // scroll above.
        guard flushMainQueue(timeout: 2.0) else {
            window.close()
            throw HarnessError.assertion("main queue did not drain a turn while waiting for the _ScrollSpy callback")
        }
        guard let observedScrollOffset = observedOffset,
              abs(observedScrollOffset - 390) < 0.5 else {
            window.close()
            throw HarnessError.assertion("expected _ScrollSpy to observe y=390, got \(String(describing: observedOffset))")
        }

        guard controller.scroll(to: 9_999, animated: false) else {
            window.close()
            throw HarnessError.assertion("attached Home scroll controller did not perform clamped AppKit scroll")
        }

        let maxY = documentView.bounds.height - scrollView.contentView.bounds.height
        let clampedY = scrollView.contentView.bounds.origin.y

        guard abs(clampedY - maxY) < 0.5 else {
            window.close()
            throw HarnessError.assertion("expected clamped Home scroll y=\(maxY), got \(clampedY)")
        }

        for degenerate in [CGFloat.nan, .infinity, -.infinity] {
            guard !controller.scroll(to: degenerate, animated: false) else {
                window.close()
                throw HarnessError.assertion("attached Home scroll controller accepted a non-finite offset \(degenerate)")
            }
            let unchangedY = scrollView.contentView.bounds.origin.y
            guard abs(unchangedY - maxY) < 0.5 else {
                window.close()
                throw HarnessError.assertion("non-finite offset \(degenerate) moved the clip view to y=\(unchangedY)")
            }
        }

        guard controller.scroll(to: 720, animated: false, reduceMotion: false) else {
            window.close()
            throw HarnessError.assertion("instant AppKit placement did not accept a finite target")
        }
        let instantTargetY = scrollView.contentView.bounds.origin.y

        guard controller.scroll(to: 0, animated: false, reduceMotion: false),
              controller.scroll(to: 720, animated: true, reduceMotion: false),
              waitUntil({
                  abs(scrollView.contentView.bounds.origin.y - instantTargetY) < 0.5
              }, timeout: 1.0) else {
            window.close()
            throw HarnessError.assertion("animated AppKit placement did not settle on the instant placement target")
        }
        let animatedTargetY = scrollView.contentView.bounds.origin.y
        guard abs(animatedTargetY - instantTargetY) < 0.5 else {
            window.close()
            throw HarnessError.assertion("animated AppKit target \(animatedTargetY) differed from instant target \(instantTargetY)")
        }

        guard controller.scroll(to: 0, animated: false, reduceMotion: false),
              controller.scroll(to: 720, animated: true, reduceMotion: true) else {
            window.close()
            throw HarnessError.assertion("reduce-motion AppKit placement did not accept a finite target")
        }
        let reduceMotionTargetY = scrollView.contentView.bounds.origin.y
        guard abs(reduceMotionTargetY - instantTargetY) < 0.5 else {
            window.close()
            throw HarnessError.assertion("reduce-motion AppKit placement should land instantly at y=\(instantTargetY), got \(reduceMotionTargetY)")
        }

        for degenerate in [CGFloat.nan, .infinity, -.infinity] {
            guard !controller.scroll(to: degenerate, animated: true, reduceMotion: false) else {
                window.close()
                throw HarnessError.assertion("animated AppKit placement accepted a non-finite offset \(degenerate)")
            }
            guard abs(scrollView.contentView.bounds.origin.y - reduceMotionTargetY) < 0.5 else {
                window.close()
                throw HarnessError.assertion("animated non-finite offset \(degenerate) moved the clip view")
            }
        }

        let verticalAttachmentDetail = try verifyVerticalAttachmentReparenting()
        let mountedReturnDetail = try verifyMountedCompositeReturnPlacement()

        let horizontalController = RemoteHorizontalScrollController()
        horizontalController.attach(scrollView)
        guard horizontalController.attachmentSerial == 1 else {
            window.close()
            throw HarnessError.assertion("first horizontal scroll-view attachment should publish serial 1")
        }
        horizontalController.attach(scrollView)
        guard horizontalController.attachmentSerial == 1 else {
            window.close()
            throw HarnessError.assertion("reattaching the same horizontal scroll view should not publish duplicate placement work")
        }
        guard abs(horizontalController.viewportExtent - 800) < 0.5 else {
            window.close()
            throw HarnessError.assertion("expected horizontal viewport extent 800, got \(horizontalController.viewportExtent)")
        }
        let initialViewportChangeSerial = horizontalController.viewportChangeSerial
        scrollView.frame.size.width = 640
        scrollView.layoutSubtreeIfNeeded()
        guard waitUntil({
            horizontalController.viewportChangeSerial > initialViewportChangeSerial
                && abs(horizontalController.viewportExtent - 640) < 0.5
        }, timeout: 1.0) else {
            window.close()
            throw HarnessError.assertion("horizontal controller did not publish viewport resize from 800 to 640")
        }

        let preservedY = scrollView.contentView.bounds.origin.y
        guard horizontalController.scroll(to: 332, animated: false) else {
            window.close()
            throw HarnessError.assertion("attached horizontal controller did not perform AppKit scroll")
        }
        guard abs(scrollView.contentView.bounds.origin.x - 332) < 0.5,
              abs(scrollView.contentView.bounds.origin.y - preservedY) < 0.5 else {
            window.close()
            throw HarnessError.assertion("horizontal AppKit scroll must move x=332 while preserving y=\(preservedY), got \(scrollView.contentView.bounds.origin)")
        }

        guard horizontalController.scroll(to: 9_999, animated: false) else {
            window.close()
            throw HarnessError.assertion("attached horizontal controller did not perform clamped AppKit scroll")
        }
        let maxX = documentView.bounds.width - scrollView.contentView.bounds.width
        guard abs(scrollView.contentView.bounds.origin.x - maxX) < 0.5 else {
            window.close()
            throw HarnessError.assertion("expected clamped horizontal x=\(maxX), got \(scrollView.contentView.bounds.origin.x)")
        }

        for degenerate in [CGFloat.nan, .infinity, -.infinity] {
            guard !horizontalController.scroll(to: degenerate, animated: true) else {
                window.close()
                throw HarnessError.assertion("horizontal AppKit placement accepted non-finite offset \(degenerate)")
            }
            guard abs(scrollView.contentView.bounds.origin.x - maxX) < 0.5 else {
                window.close()
                throw HarnessError.assertion("horizontal non-finite offset \(degenerate) moved the clip view")
            }
        }

        guard horizontalController.scroll(to: 0, animated: false),
              horizontalController.scroll(to: 166, animated: false),
              abs(scrollView.contentView.bounds.origin.x - 166) < 0.5,
              horizontalController.scroll(to: 0, animated: false),
              horizontalController.scroll(to: 664, animated: true),
              waitUntil({ abs(scrollView.contentView.bounds.origin.x - 664) < 0.5 }, timeout: 1.0) else {
            window.close()
            throw HarnessError.assertion("animated horizontal AppKit placement did not settle on x=664")
        }

        guard horizontalController.scroll(to: 0, animated: false),
              horizontalController.scroll(to: 664, animated: true, reduceMotion: true),
              abs(scrollView.contentView.bounds.origin.x - 664) < 0.5 else {
            window.close()
            throw HarnessError.assertion("reduce-motion horizontal AppKit placement should land instantly on x=664")
        }
        let attachmentDetail = try VerifyRemoteHorizontalScrollAttachmentHarness.verifyReparenting()
        let mountedRowDetail = try verifyMountedArrowedScrollRow()
        window.close()

        return "_ScrollSpy attached to NSScrollView; vertical and horizontal controllers moved the real AppKit clip view, published the 800->640 viewport resize, preserved the exact x=166 whole-card origin through safe clamping, clamped at y=\(Int(maxY))/x=\(Int(maxX)), kept animated and instant targets identical, honored reduce motion, and rejected non-finite offsets without moving the clip view; \(verticalAttachmentDetail); \(mountedReturnDetail); \(attachmentDetail); \(mountedRowDetail)"
    }

    private static func verifyVerticalAttachmentReparenting() throws -> String {
        func makeScrollView() -> NSScrollView {
            let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            scrollView.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 2_000))
            return scrollView
        }

        let firstScrollView = makeScrollView()
        let secondScrollView = makeScrollView()
        secondScrollView.frame.origin = NSPoint(x: 800, y: 0)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1_600, height: 600))
        container.addSubview(firstScrollView)
        container.addSubview(secondScrollView)
        let window = NSWindow(
            contentRect: container.bounds,
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        window.contentView = container

        let controller = BrowseVerticalScrollController()
        let spy = BrowseScrollSpy(frame: .zero)
        var attachments: [ObjectIdentifier] = []
        var detachments: [ObjectIdentifier] = []
        spy.onAttachScrollView = { scrollView in
            attachments.append(ObjectIdentifier(scrollView))
            controller.attach(scrollView)
        }
        spy.onDetachScrollView = { scrollView in
            detachments.append(ObjectIdentifier(scrollView))
            controller.detach(scrollView)
        }

        guard let firstDocumentView = firstScrollView.documentView,
              let secondDocumentView = secondScrollView.documentView else {
            window.close()
            throw HarnessError.assertion("vertical attachment harness requires document views")
        }
        firstDocumentView.addSubview(spy)
        guard attachments == [ObjectIdentifier(firstScrollView)] else {
            window.close()
            throw HarnessError.assertion("vertical observer did not attach to its first scroll view")
        }
        let firstEpoch = controller.attachmentEpoch
        spy.removeFromSuperview()
        secondDocumentView.addSubview(spy)
        guard attachments == [ObjectIdentifier(firstScrollView), ObjectIdentifier(secondScrollView)],
              detachments == [ObjectIdentifier(firstScrollView)],
              controller.attachmentEpoch > firstEpoch else {
            window.close()
            throw HarnessError.assertion("vertical observer retained stale ownership during direct reparenting")
        }

        let thirdScrollView = makeScrollView()
        container.addSubview(thirdScrollView)
        let intermediateView = NSView(frame: .zero)
        let delayedSpy = BrowseScrollSpy(frame: .zero)
        var delayedAttachment: NSScrollView?
        delayedSpy.onAttachScrollView = { delayedAttachment = $0 }
        intermediateView.addSubview(delayedSpy)
        container.addSubview(intermediateView)
        guard delayedAttachment == nil,
              let thirdDocumentView = thirdScrollView.documentView else {
            window.close()
            throw HarnessError.assertion("vertical delayed-attachment setup was invalid")
        }
        thirdDocumentView.addSubview(intermediateView)
        guard waitUntil({ delayedAttachment === thirdScrollView }, timeout: 1.5) else {
            window.close()
            throw HarnessError.assertion("vertical observer retry did not follow its delayed ancestor")
        }

        window.close()
        return "vertical attachment detached stale ownership, followed direct reparenting, and generation-gated delayed ancestor discovery"
    }

    private static func verifyMountedCompositeReturnPlacement() throws -> String {
        func state(
            route: BrowseSurfaceRoute,
            detail: Bool = false,
            player: Bool = false,
            handoff: String? = nil
        ) -> BrowseSurfacePresentationState {
            BrowseSurfacePresentationState(
                route: route,
                detailVisible: detail,
                playerVisible: player,
                postPlayID: handoff
            )
        }

        func verify(
            route: BrowseSurfaceRoute,
            sequence: [BrowseSurfacePresentationState]
        ) throws {
            let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 900))
            let documentView = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 2_400))
            scrollView.documentView = documentView
            let window = NSWindow(
                contentRect: scrollView.bounds,
                styleMask: [],
                backing: .buffered,
                defer: false
            )
            window.contentView = scrollView

            let controller = BrowseVerticalScrollController()
            let spy = BrowseScrollSpy(frame: .zero)
            spy.onAttachScrollView = { controller.attach($0) }
            spy.onDetachScrollView = { controller.detach($0) }
            documentView.addSubview(spy)
            guard waitUntil({ controller.attachmentEpoch > 0 }, timeout: 1.5),
                  controller.scroll(to: 600, animated: false) else {
                window.close()
                throw HarnessError.assertion("mounted \(route) return harness did not attach and seed its scroll offset")
            }

            var pending = PendingBrowseReturnPlacement()
            var previous = sequence[0]
            var placementCount = 0
            for current in sequence.dropFirst() {
                defer { previous = current }
                guard BrowseSurfaceExitPolicy.shouldPlace(from: previous, to: current) else { continue }
                let target = BrowseReturnPlacementTarget.row("focused-row")
                let serial = pending.issue(
                    target: target,
                    focusGeneration: 4,
                    attachmentEpoch: controller.attachmentEpoch
                )
                let sample = BrowseReturnGeometrySample(
                    target: target,
                    targetMinY: 1_020,
                    viewportHeight: controller.viewportHeight,
                    currentOffset: controller.currentOffset,
                    contentHeight: controller.contentHeight,
                    attachmentEpoch: controller.attachmentEpoch,
                    focusGeneration: 4
                )
                guard let targetOffset = pending.consume(sample: sample, serial: serial),
                      controller.scroll(to: targetOffset, animated: false) else {
                    window.close()
                    throw HarnessError.assertion("mounted \(route) dismissal did not reach AppKit placement")
                }
                placementCount += 1
            }

            let expectedOffset = CGFloat(1_020 - 324)
            guard placementCount == 1,
                  abs(controller.currentOffset - expectedOffset) < 0.5 else {
                window.close()
                throw HarnessError.assertion("mounted \(route) return placed \(placementCount) times at y=\(controller.currentOffset)")
            }
            window.close()
        }

        try verify(route: .home, sequence: [
            state(route: .home, detail: true),
            state(route: .home),
        ])
        try verify(route: .movies, sequence: [
            state(route: .movies, player: true),
            state(route: .movies),
        ])
        try verify(route: .tvShows, sequence: [
            state(route: .tvShows, player: true),
            state(route: .tvShows, player: true, handoff: "next"),
            state(route: .tvShows, handoff: "next"),
            state(route: .tvShows),
        ])
        return "mounted Home detail, Movies player, and TV post-play dismissal sequences each issued one measured AppKit return placement"
    }

    private static func verifyMountedArrowedScrollRow() throws -> String {
        let size = NSSize(width: 908, height: 280)
        let model = MountedArrowedScrollRowModel()
        let host = NSHostingView(
            rootView: MountedArrowedScrollRowHarnessView(model: model)
                .frame(width: size.width, height: size.height)
                // The lean-back default keys off attached display count, so an
                // unpinned harness measures different scaled padding whenever a
                // second screen is connected to the QA host.
                .environment(\.leanBackMode, false)
        )
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: host.bounds,
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        host.layoutSubtreeIfNeeded()

        guard waitUntil({ findHorizontalScrollView(in: host) != nil }, timeout: 1.5),
              let mountedScrollView = findHorizontalScrollView(in: host) else {
            window.close()
            throw HarnessError.assertion("mounted ArrowedScrollRow did not expose its horizontal NSScrollView")
        }
        let viewportWidth = mountedScrollView.contentView.bounds.width
        guard abs(viewportWidth - 980) < 0.5 else {
            window.close()
            throw HarnessError.assertion("mounted ArrowedScrollRow regression requires a 980-point viewport, got \(viewportWidth)")
        }

        guard waitUntil({
            guard let documentView = mountedScrollView.documentView else { return false }
            let maximumOffset = documentView.bounds.width - mountedScrollView.contentView.bounds.width
            return maximumOffset >= 165.5
                && abs(mountedScrollView.contentView.bounds.origin.x - 166) < 0.5
        }, timeout: 1.5) else {
            let observedX = mountedScrollView.contentView.bounds.origin.x
            let documentWidth = mountedScrollView.documentView?.bounds.width ?? 0
            window.close()
            throw HarnessError.assertion("mounted ArrowedScrollRow did not lay out trailing slack and move initial focus 2 to exact x=166, got x=\(observedX) documentWidth=\(documentWidth)")
        }
        model.focusedID = 0
        guard waitUntil({ abs(mountedScrollView.contentView.bounds.origin.x) < 0.5 }, timeout: 1.5) else {
            window.close()
            throw HarnessError.assertion("mounted ArrowedScrollRow did not return focus to exact x=0")
        }
        model.focusedID = 2
        guard waitUntil({ abs(mountedScrollView.contentView.bounds.origin.x - 166) < 0.5 }, timeout: 1.5) else {
            window.close()
            throw HarnessError.assertion("mounted ArrowedScrollRow did not repeat the exact x=166 focus movement")
        }

        window.close()
        return "mounted ArrowedScrollRow observer discovered the shipped NSScrollView, laid out trailing slack, and moved initial plus repeated focus to exact x=166"
    }

    private static func findHorizontalScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView,
           let documentView = scrollView.documentView,
           documentView.bounds.width > scrollView.contentView.bounds.width + 0.5 {
            return scrollView
        }
        for subview in view.subviews {
            if let match = findHorizontalScrollView(in: subview) {
                return match
            }
        }
        return nil
    }

    /// Runs the main queue forward by one turn. Blocks already queued ahead of
    /// the marker have executed once this returns true, so a caller waiting on a
    /// main-queue callback gets a FIFO guarantee instead of a wall-clock guess.
    private static func flushMainQueue(timeout: TimeInterval) -> Bool {
        var didFlush = false
        DispatchQueue.main.async { didFlush = true }
        return waitUntil({ didFlush }, timeout: timeout)
    }

    private static func waitUntil(_ condition: () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    private enum HarnessError: Error, CustomStringConvertible {
        case assertion(String)

        var description: String {
            switch self {
            case .assertion(let message):
                return message
            }
        }
    }
}

private final class MountedArrowedScrollRowModel: ObservableObject {
    @Published var focusedID = 2
}

private struct MountedArrowedScrollRowHarnessView: View {
    @ObservedObject var model: MountedArrowedScrollRowModel
    private let ids = Array(0..<6)

    var body: some View {
        ArrowedScrollRow(
            ids: ids,
            focusedID: model.focusedID,
            focusItemExtent: 150,
            focusItemSpacing: 16,
            hoverArrowsEnabled: false
        ) {
            LazyHStack(alignment: .top, spacing: 16) {
                ForEach(ids, id: \.self) { id in
                    Color.clear
                        .frame(width: 150, height: 220)
                        .id(id)
                }
            }
        }
    }
}
#endif
