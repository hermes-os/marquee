import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct ContentView: View {

    @ObservedObject var appState: AppState
    @ObservedObject var playerController: PlayerController
    @ObservedObject var router: AppRouter

    @State private var isDragTargeted: Bool = false
    @State private var searchSelectionKeepsExistingCapture: Bool = false
    @State private var searchFieldFocusRequestSerial: Int = 0
    @State private var sidebarProfileAvatarImage: NSImage?
    @StateObject private var displayMode = DisplayModeMonitor()
    @StateObject private var remoteInput = RemoteInputRouter()
    @StateObject private var focusCoordinator = FocusCoordinator()

    init(appState: AppState) {
        self._appState = ObservedObject(wrappedValue: appState)
        self._playerController = ObservedObject(wrappedValue: appState.playerController)
        self._router = ObservedObject(wrappedValue: appState.router)
    }

    private var isKidsMode: Bool {
        appState.activeProfile?.maturityLevel == .kids
    }

    var body: some View {
        ZStack {
            if appState.showProfilePicker || appState.isProfileExitInFlight {
                ProfilePickerView(appState: appState, library: appState.library)
                    .opacity(appState.isProfileExitPresentationActive ? 0 : 1)
                    .animation(
                        MarqueeTheme.profileExitAnimation,
                        value: appState.isProfileExitPresentationActive
                    )
                    .transition(ProfileExitTransitionPolicy.rootTransition.transition)
                    .zIndex(4)
            }

            if !appState.showProfilePicker {
                appShell
                    .transition(ProfileExitTransitionPolicy.rootTransition.transition)

                if playerController.isTransitioning {
                    TransitionLoadingView()
                        .transition(.opacity)
                        .zIndex(1)
                }

                if playerController.isPlayerPresented,
                   let playerService = playerController.playerService {
                    PlayerView(
                        playerService: playerService,
                        currentItem: playerController.currentPlayingItem,
                        hasNextEpisode: playerController.nextEpisode != nil,
                        onNextEpisode: { playerController.playNextEpisode() }
                    ) {
                        appState.dismissPlayer()
                    }
                    .id(ObjectIdentifier(playerService))
                    .transition(.opacity)
                    .zIndex(2)
                }

                if let handoff = appState.postPlayHandoff,
                   !playerController.isPlayerPresented {
                    PostPlayHandoffOverlay(
                        handoff: handoff,
                        onPlay: { appState.playPostPlayHandoff(id: handoff.id) },
                        onDismiss: { appState.dismissPostPlayHandoff(id: $0) }
                    )
                    .transition(.opacity)
                    .zIndex(2.5)
                }

                if let error = appState.currentError {
                    errorToast(error)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .zIndex(3)
                }
            }
        }
        .animation(MarqueeTheme.profileExitAnimation, value: appState.showProfilePicker)
        .allowsHitTesting(
            ProfileExitTransitionPolicy.acceptsInput(
                isExitInFlight: appState.isProfileExitInFlight
            )
        )
        .environment(\.leanBackMode, displayMode.isLeanBack)
        .environmentObject(remoteInput)
        .kidsTheme(active: isKidsMode)
        .onDrop(of: [.fileURL], isTargeted: $isDragTargeted) { providers in
            handleDrop(providers)
        }
        .overlay(dragOverlay)
        .background(
            WindowAccessor { window in
                displayMode.attach(window: window)
                MarqueeWindowStyle.apply(to: window)
                #if DEBUG
                NativeVisualQATour.shared.startIfRequested(
                    window: window,
                    appState: appState,
                    setRoute: routeForVisualQATour,
                    sendRemote: { command in
                        remoteInput.send(command)
                    },
                    openMovieDetail: openMovieDetailForVisualQATour,
                    openShowDetail: openShowDetailForVisualQATour,
                    dismissDetail: dismissSearchDetail
                )
                #endif
            }
        )
        .onAppear {
            MarqueeMode.set(.browsing)
            router.focusedSidebarItem = router.selectedItem
            focusCoordinator.update(with: ownershipState)
            refreshSidebarProfileAvatar()
            if !appState.showProfilePicker {
                appState.library.beginBackgroundScanIfNeeded()
            }
        }
        .onChange(of: appState.activeProfile) { _ in
            refreshSidebarProfileAvatar()
        }
        .onChange(of: ownershipState) { state in
            focusCoordinator.update(with: state)
        }
        .onChange(of: appState.profileExitSelectionID) { selectionID in
            guard let selectionID else { return }
            DispatchQueue.main.async {
                appState.profileExitPresentationDidStart(selectionID: selectionID)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .marqueeActivateSearch)) { _ in
            if !appState.showProfilePicker,
               ProfileExitTransitionPolicy.acceptsInput(
                   isExitInFlight: appState.isProfileExitInFlight
               ) {
                if router.selectedItem != .search {
                    searchSelectionKeepsExistingCapture = true
                }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    router.selectedItem = .search
                    router.focusedSidebarItem = .search
                    router.sidebarRemoteFocused = false
                    router.sidebarFocusOnPlaySomething = false
                    router.sidebarFocusOnProfile = false
                }
                requestSearchFieldFocus()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .marqueeOpenScopedSearch)) { notification in
            guard let query = notification.object as? String else { return }
            openScopedSearch(query)
        }
        .onChange(of: router.selectedItem) { newValue in
            MarqueeSignpost.event("route-switch", newValue.rawValue)
            router.focusedSidebarItem = newValue
            router.sidebarFocusOnPlaySomething = false
            router.sidebarFocusOnProfile = false
            if newValue == .search {
                if searchSelectionKeepsExistingCapture {
                    searchSelectionKeepsExistingCapture = false
                } else {
                    SearchInputBuffer.shared.beginCapture()
                }
                requestSearchFieldFocus()
            } else {
                searchSelectionKeepsExistingCapture = false
                SearchInputBuffer.shared.stopCapture()
                invalidateSearchFieldFocusRequests()
                dismissSearchDetail()
            }
        }
        .onChange(of: appState.showProfilePicker) { showing in
            MarqueeLogger.general.info("root profile picker visibility changed showing=\(showing, privacy: .public)")
            if showing {
                normalizeRootStateForProfilePicker()
            } else {
                appState.library.beginBackgroundScanIfNeeded()
            }
        }
    }

    // MARK: - App Shell

    @Environment(\.kidsMode) private var kidsMode

    private var appShell: some View {
        HStack(spacing: 0) {
            MarqueeSidebar(
                selection: $router.selectedItem,
                remoteFocusedItem: (
                    router.sidebarRemoteFocused
                        && !router.sidebarFocusOnPlaySomething
                        && !router.sidebarFocusOnProfile
                ) ? router.focusedSidebarItem : nil,
                playSomethingRemoteFocused: router.sidebarRemoteFocused && router.sidebarFocusOnPlaySomething,
                profileRemoteFocused: router.sidebarRemoteFocused && router.sidebarFocusOnProfile,
                onSwitchProfile: presentProfilePickerFromSidebar,
                onPlaySomething: { appState.playSomething() },
                activeProfile: appState.activeProfile,
                activeProfileAvatarImage: sidebarProfileAvatarImage
            )
            detailContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(kidsMode ? MarqueeTheme.kidsBackground : MarqueeTheme.background)
        .frame(minWidth: 1100, minHeight: 700)
        .overlay(alignment: .topLeading) {
            if browseRemoteCatcherActive {
                KeyCatcher(
                    onKeyDown: handleBrowseRemoteKey
                )
                    .frame(width: 1, height: 1)
            }
        }
    }

    // MARK: - Detail

    @State private var searchSelectedMovie: MediaItem?
    @State private var searchSelectedShow: String?
    @State private var searchSelectedShowTargetEpisode: MediaItem?

    private func selectFromSearch(_ item: MediaItem) {
        if let show = item.showName {
            searchSelectedShow = show
            searchSelectedShowTargetEpisode = item
        } else {
            searchSelectedMovie = item
        }
    }

    private func dismissSearchDetail() {
        searchSelectedMovie = nil
        searchSelectedShow = nil
        searchSelectedShowTargetEpisode = nil
    }

    @ViewBuilder
    private var detailContent: some View {
        switch router.selectedItem {
        case .home:
            HomeDetailView(
                appState: appState,
                library: appState.library,
                onOpenFile: openFile,
                onRemoteBackAtRoot: focusSidebar
            )
        case .search:
            searchContent
        case .movies:
            MoviesDetailView(
                appState: appState,
                library: appState.library,
                onRemoteBackAtRoot: focusSidebar
            )
        case .tvShows:
            TVShowsDetailView(
                appState: appState,
                library: appState.library,
                onRemoteBackAtRoot: focusSidebar
            )
        case .settings:
            SettingsDetailView(
                library: appState.library,
                remoteEscapeEnabled: !router.sidebarRemoteFocused,
                onRemoteBackAtRoot: focusSidebar
            )
        }
    }

    // MARK: - Remote Navigation

    private var searchHasDetail: Bool {
        searchSelectedMovie != nil || searchSelectedShow != nil
    }

    private var ownershipState: RemoteOwnershipState {
        RemoteOwnershipState(
            showProfilePicker: ProfileExitTransitionPolicy.retainsProfileInputOwnership(
                showProfilePicker: appState.showProfilePicker,
                isExitInFlight: appState.isProfileExitInFlight
            ),
            playerPresented: playerController.isPlayerPresented,
            postPlayHandoffVisible: appState.postPlayHandoff != nil && !playerController.isPlayerPresented,
            sidebarRemoteFocused: router.sidebarRemoteFocused,
            selectedItem: router.selectedItem,
            searchHasDetail: searchHasDetail
        )
    }

    private var browseRemoteCatcherActive: Bool {
        guard ProfileExitTransitionPolicy.acceptsInput(
            isExitInFlight: appState.isProfileExitInFlight
        ) else { return false }
        return BrowseRemoteCatcherPolicy.isActive(
            showProfilePicker: appState.showProfilePicker,
            playerPresented: playerController.isPlayerPresented,
            postPlayHandoffVisible: appState.postPlayHandoff != nil && !playerController.isPlayerPresented,
            sidebarRemoteFocused: router.sidebarRemoteFocused,
            selectedItem: router.selectedItem,
            searchHasDetail: searchHasDetail
        )
    }

    private func handleBrowseRemoteKey(_ event: MarqueeKeyEvent) -> Bool {
        guard let command = event.key?.remoteCommand else {
            return false
        }

        switch RemoteOwnershipPolicy.owner(for: ownershipState) {
        case .profilePicker, .player, .postPlayHandoff:
            return false
        case .sidebar:
            let previousFocusedItem = router.focusedSidebarItem
            let previousPlaySomething = router.sidebarFocusOnPlaySomething
            let previousProfile = router.sidebarFocusOnProfile
            let previousRemoteFocused = router.sidebarRemoteFocused
            if command == .select || command == .right {
                AudioIdentityService.shared.playFeedback(for: .select)
            } else if command == .back {
                AudioIdentityService.shared.playFeedback(for: .back)
            }
            router.handleSidebarRemoteCommand(
                command,
                presentProfilePicker: presentProfilePickerFromSidebar,
                playSomething: { appState.playSomething() }
            )
            if command == .up || command == .down || command == .left {
                let didNavigate = previousFocusedItem != router.focusedSidebarItem
                    || previousPlaySomething != router.sidebarFocusOnPlaySomething
                    || previousProfile != router.sidebarFocusOnProfile
                    || previousRemoteFocused != router.sidebarRemoteFocused
                AudioIdentityService.shared.playFeedback(
                    for: command,
                    didNavigate: didNavigate,
                    didReachBoundary: !didNavigate
                )
            }
            return true
        case .browse, .searchDetail:
            remoteInput.send(command)
            return true
        case .settings:
            if command == .back || command == .left {
                if command == .back {
                    AudioIdentityService.shared.playFeedback(for: .back)
                } else {
                    AudioIdentityService.shared.playFeedback(for: .left, didNavigate: true)
                }
                focusSidebar()
                return true
            }
            return false
        case .searchRoot:
            if command == .back {
                AudioIdentityService.shared.playFeedback(for: .back)
                focusSidebar()
                return true
            }
            return false
        }
    }

    private func focusSidebar() {
        invalidateSearchFieldFocusRequests()
        router.focusSidebar()
    }

    private func refreshSidebarProfileAvatar() {
        guard let name = appState.activeProfile?.characterAvatarName else {
            sidebarProfileAvatarImage = nil
            return
        }
        sidebarProfileAvatarImage = AvatarService.shared.cachedAvatar(named: name)?.image
    }

    private func presentProfilePickerFromSidebar() {
        normalizeRootStateForProfilePicker()
        appState.switchProfile()
    }

    private func normalizeRootStateForProfilePicker() {
        let state = SidebarProfilePresentationPolicy.normalizedState
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            router.selectedItem = state.selectedItem
            router.focusedSidebarItem = state.focusedSidebarItem
            router.sidebarRemoteFocused = state.sidebarRemoteFocused
            router.sidebarFocusOnPlaySomething = state.sidebarFocusOnPlaySomething
            router.sidebarFocusOnProfile = state.sidebarFocusOnProfile
            searchSelectionKeepsExistingCapture = false
            searchSelectedMovie = nil
            searchSelectedShow = nil
            searchSelectedShowTargetEpisode = nil
        }
        SearchInputBuffer.shared.stopCapture()
        invalidateSearchFieldFocusRequests()
    }

    private func requestSearchFieldFocus() {
        searchFieldFocusRequestSerial &+= 1
        let serial = searchFieldFocusRequestSerial
        for delay in SearchRouteFocusPolicy.notificationDelays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard serial == searchFieldFocusRequestSerial else { return }
                NotificationCenter.default.post(name: .marqueeFocusSearchField, object: nil)
            }
        }
    }

    private func invalidateSearchFieldFocusRequests() {
        searchFieldFocusRequestSerial &+= 1
    }

    private func openScopedSearch(_ query: String) {
        SearchInputBuffer.shared.seedProgrammaticQuery(query)
        dismissSearchDetail()
        searchSelectionKeepsExistingCapture = true
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            router.selectedItem = .search
            router.focusedSidebarItem = .search
            router.sidebarRemoteFocused = false
            router.sidebarFocusOnPlaySomething = false
            router.sidebarFocusOnProfile = false
        }
        requestSearchFieldFocus()
    }

    #if DEBUG
    private func routeForVisualQATour(_ item: SidebarItem) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            router.selectedItem = item
            router.focusedSidebarItem = item
            router.sidebarRemoteFocused = false
            router.sidebarFocusOnPlaySomething = false
            router.sidebarFocusOnProfile = false
            searchSelectedMovie = nil
            searchSelectedShow = nil
            searchSelectedShowTargetEpisode = nil
        }
        if item == .search {
            requestSearchFieldFocus()
        }
    }

    private func openMovieDetailForVisualQATour(_ item: MediaItem) {
        prepareSearchRouteForVisualQATour()
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            searchSelectedMovie = item
            searchSelectedShow = nil
            searchSelectedShowTargetEpisode = nil
        }
    }

    private func openShowDetailForVisualQATour(_ showName: String) {
        prepareSearchRouteForVisualQATour()
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            searchSelectedMovie = nil
            searchSelectedShow = showName
            searchSelectedShowTargetEpisode = nil
        }
    }

    private func prepareSearchRouteForVisualQATour() {
        guard router.selectedItem != .search else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                searchSelectedMovie = nil
                searchSelectedShow = nil
                searchSelectedShowTargetEpisode = nil
            }
            return
        }
        routeForVisualQATour(.search)
    }
    #endif

    @ViewBuilder
    private var searchContent: some View {
        ZStack {
            SearchView(
                searchSession: appState.searchSession,
                focusCoordinator: focusCoordinator,
                isDetailPresented: searchHasDetail,
                sidebarRemoteFocused: router.sidebarRemoteFocused,
                onRemoteBackAtRoot: focusSidebar,
                onSelectMovie: { selectFromSearch($0) },
                onSelectShow: { searchSelectedShow = $0 }
            )

            if let show = searchSelectedShow {
                ShowDetailView(
                    showName: show,
                    appState: appState,
                    library: appState.library,
                    targetEpisode: searchSelectedShowTargetEpisode,
                    onSelectItem: { selectFromSearch($0) },
                    onSelectShow: { relatedShow in
                        searchSelectedShow = relatedShow
                        searchSelectedShowTargetEpisode = nil
                    },
                    onDismiss: dismissSearchDetail,
                    onNavigateToSidebar: focusSidebar
                )
                .background(
                    (isKidsMode ? MarqueeTheme.kidsBackground : MarqueeTheme.background)
                        .ignoresSafeArea()
                )
            } else if let movie = searchSelectedMovie {
                MovieDetailView(
                    item: movie,
                    appState: appState,
                    library: appState.library,
                    onSelectItem: { selectFromSearch($0) },
                    dismiss: { dismissSearchDetail() },
                    onNavigateToSidebar: focusSidebar
                )
                .background(
                    (isKidsMode ? MarqueeTheme.kidsBackground : MarqueeTheme.background)
                        .ignoresSafeArea()
                )
            }
        }
    }

    // MARK: - Error Toast

    private func errorToast(_ error: AppError) -> some View {
        VStack {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(MarqueeTheme.accentSecondary)
                        .font(.system(size: MarqueeTheme.scaled(16, leanBack: 22, isLeanBack: displayMode.isLeanBack)))

                VStack(alignment: .leading, spacing: 2) {
                    Text(error.title)
                        .font(.system(size: MarqueeTheme.scaled(13, leanBack: 18, isLeanBack: displayMode.isLeanBack), weight: .semibold))
                        .foregroundColor(MarqueeTheme.textPrimary)
                    Text(error.message)
                        .font(.system(size: MarqueeTheme.scaled(12, leanBack: 16, isLeanBack: displayMode.isLeanBack)))
                        .foregroundColor(MarqueeTheme.textSecondary)
                        .lineLimit(2)
                }

                Spacer()

                Button(action: { appState.dismissError() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: MarqueeTheme.scaled(10, leanBack: 14, isLeanBack: displayMode.isLeanBack), weight: .bold))
                        .foregroundColor(MarqueeTheme.textTertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(MarqueeTheme.scaled(16, leanBack: 22, isLeanBack: displayMode.isLeanBack))
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(MarqueeTheme.surfaceElevated)
                    .shadow(color: Color.black.opacity(0.4), radius: 12, y: 4)
            )
            .padding(.horizontal, MarqueeTheme.scaled(60, leanBack: 88, isLeanBack: displayMode.isLeanBack))
            .padding(.top, MarqueeTheme.scaled(16, leanBack: 24, isLeanBack: displayMode.isLeanBack))

            Spacer()
        }
    }

    // MARK: - Open File

    private func openFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        appState.playFile(at: url.path)
    }

    // MARK: - Drag Overlay

    @ViewBuilder
    private var dragOverlay: some View {
        if isDragTargeted {
            ZStack {
                Color.black.opacity(0.7).ignoresSafeArea()

                VStack(spacing: MarqueeTheme.spacingMD) {
                    ZStack {
                        Circle()
                            .fill(MarqueeTheme.accentPrimary.opacity(0.15))
                            .frame(
                                width: MarqueeTheme.scaled(100, leanBack: 150, isLeanBack: displayMode.isLeanBack),
                                height: MarqueeTheme.scaled(100, leanBack: 150, isLeanBack: displayMode.isLeanBack)
                            )
                        Image(systemName: "play.rectangle.on.rectangle")
                            .font(.system(size: MarqueeTheme.scaled(40, leanBack: 58, isLeanBack: displayMode.isLeanBack), weight: .thin))
                            .foregroundColor(MarqueeTheme.accentSecondary)
                    }

                    Text("Drop to Play")
                        .font(.system(size: MarqueeTheme.scaled(20, leanBack: 30, isLeanBack: displayMode.isLeanBack), weight: .semibold))
                        .foregroundColor(MarqueeTheme.textPrimary)
                }
            }
            .ignoresSafeArea()
        }
    }

    // MARK: - Drop Handling

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil),
                  isVideoFile(url) else { return }
            DispatchQueue.main.async {
                appState.playFile(at: url.path)
            }
        }
        return true
    }

    private func isVideoFile(_ url: URL) -> Bool {
        let videoExtensions: Set<String> = ["mp4", "m4v", "mov", "avi", "ts", "mpg", "mpeg", "m2ts", "vob", "mkv", "webm", "flv", "wmv"]
        return videoExtensions.contains(url.pathExtension.lowercased())
    }
}

private enum SearchRouteFocusPolicy {
    static let notificationDelays: [TimeInterval] = [0.0, 0.12]
}

// MARK: - Lean Back Display Mode

private final class DisplayModeMonitor: ObservableObject {
    @Published private(set) var isLeanBack: Bool = DisplayModeMonitor.detectLeanBackMode()

    private var appObserver: NSObjectProtocol?
    private var windowObservers: [NSObjectProtocol] = []
    private weak var window: NSWindow?

    init() {
        appObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    deinit {
        if let appObserver {
            NotificationCenter.default.removeObserver(appObserver)
        }
        removeWindowObservers()
    }

    func attach(window: NSWindow) {
        guard self.window !== window else {
            refresh()
            return
        }

        removeWindowObservers()
        self.window = window

        for name in [
            NSWindow.didChangeScreenNotification,
            NSWindow.didResizeNotification,
            NSWindow.didEnterFullScreenNotification,
            NSWindow.didExitFullScreenNotification,
        ] {
            let observer = NotificationCenter.default.addObserver(
                forName: name,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.refresh()
            }
            windowObservers.append(observer)
        }

        refresh()
    }

    private func refresh() {
        let next = Self.detectLeanBackMode(window: window)
        if next != isLeanBack {
            isLeanBack = next
        }
    }

    private func removeWindowObservers() {
        for observer in windowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        windowObservers.removeAll()
    }

    private static func detectLeanBackMode(window: NSWindow? = nil) -> Bool {
        let screens = NSScreen.screens
        if screens.count > 1 {
            return true
        }

        guard let screen = window?.screen ?? NSScreen.main else {
            return false
        }

        let name = screen.localizedName.lowercased()
        if name.contains("tv") || name.contains("television") {
            return true
        }

        let isBuiltInDisplay = name.contains("built-in")
            || name.contains("retina display")
            || name.contains("color lcd")

        let frame = screen.visibleFrame.width > 0 ? screen.visibleFrame : screen.frame
        let isLargePresentationCanvas = frame.width >= 1900 && frame.height >= 1000
        let isSingleExternalDisplay = screens.count == 1 && !isBuiltInDisplay && frame.width >= 1280 && frame.height >= 720

        return isLargePresentationCanvas || isSingleExternalDisplay
    }
}

private struct LeanBackModeKey: EnvironmentKey {
    static let defaultValue: Bool = NSScreen.screens.count > 1
}

extension EnvironmentValues {
    var leanBackMode: Bool {
        get { self[LeanBackModeKey.self] }
        set { self[LeanBackModeKey.self] = newValue }
    }
}

// MARK: - Post-play Handoff

private struct PostPlayHandoffOverlay: View {
    let handoff: PostPlayHandoff
    let onPlay: () -> Void
    let onDismiss: (String) -> Void

    @Environment(\.leanBackMode) private var leanBackMode

    var body: some View {
        VStack {
            Spacer()

            HStack(alignment: .center, spacing: MarqueeTheme.scaled(18, leanBack: 28, isLeanBack: leanBackMode)) {
                if let poster = handoff.candidate.displayPosterPath {
                    CachedImageView(
                        path: poster,
                        contentMode: .fill,
                        thumbnailPixelSize: ArtworkCache.gridPosterThumbnailPixelSize
                    )
                    .frame(
                        width: MarqueeTheme.scaled(68, leanBack: 108, isLeanBack: leanBackMode),
                        height: MarqueeTheme.scaled(102, leanBack: 162, isLeanBack: leanBackMode)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: MarqueeTheme.cornerRadiusMD))
                }

                VStack(alignment: .leading, spacing: MarqueeTheme.scaled(6, leanBack: 10, isLeanBack: leanBackMode)) {
                    Text("PAIRS WELL WITH")
                        .font(.system(size: MarqueeTheme.scaled(10, leanBack: 14, isLeanBack: leanBackMode), weight: .bold))
                        .foregroundColor(MarqueeTheme.accentSecondary.opacity(0.78))

                    Text(handoff.candidate.displayTitle)
                        .font(.system(size: MarqueeTheme.scaled(18, leanBack: 28, isLeanBack: leanBackMode), weight: .semibold))
                        .foregroundColor(MarqueeTheme.textPrimary)
                        .lineLimit(2)

                    Text("After \(handoff.source.displayTitle)")
                        .font(.system(size: MarqueeTheme.scaled(12, leanBack: 17, isLeanBack: leanBackMode), weight: .medium))
                        .foregroundColor(MarqueeTheme.textSecondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button(action: onPlay) {
                    Image(systemName: "play.fill")
                        .font(.system(size: MarqueeTheme.scaled(13, leanBack: 20, isLeanBack: leanBackMode), weight: .semibold))
                        .foregroundColor(MarqueeTheme.textPrimary)
                        .frame(
                            width: MarqueeTheme.scaled(44, leanBack: 68, isLeanBack: leanBackMode),
                            height: MarqueeTheme.scaled(44, leanBack: 68, isLeanBack: leanBackMode)
                        )
                        .background(Circle().fill(MarqueeTheme.accentPrimary))
                        .overlay(
                            Circle()
                                .strokeBorder(MarqueeTheme.accentSecondary.opacity(0.24), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Play recommendation")

                Button(action: { onDismiss(handoff.id) }) {
                    Image(systemName: "xmark")
                        .font(.system(size: MarqueeTheme.scaled(12, leanBack: 18, isLeanBack: leanBackMode), weight: .bold))
                        .foregroundColor(MarqueeTheme.textSecondary)
                        .frame(
                            width: MarqueeTheme.scaled(34, leanBack: 52, isLeanBack: leanBackMode),
                            height: MarqueeTheme.scaled(34, leanBack: 52, isLeanBack: leanBackMode)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss recommendation")
            }
            .padding(MarqueeTheme.scaled(18, leanBack: 28, isLeanBack: leanBackMode))
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(MarqueeTheme.surfaceElevated.opacity(0.96))
                    .shadow(color: Color.black.opacity(0.42), radius: 18, y: 8)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(MarqueeTheme.accentPrimary.opacity(0.42), lineWidth: 1)
            )
            .padding(.horizontal, MarqueeTheme.outerPadding(isLeanBack: leanBackMode))
            .padding(.bottom, MarqueeTheme.scaled(34, leanBack: 56, isLeanBack: leanBackMode))
        }
        .background(
            KeyCatcher(onKeyDown: { event in
                guard let command = event.key?.remoteCommand else { return false }
                switch command {
                case .select:
                    AudioIdentityService.shared.playFeedback(for: .select)
                    onPlay()
                    return true
                case .back, .left:
                    AudioIdentityService.shared.play(.back)
                    onDismiss(handoff.id)
                    return true
                case .up, .down, .right:
                    AudioIdentityService.shared.playFeedback(
                        for: command,
                        didReachBoundary: true
                    )
                    return true
                }
            })
            .frame(width: 1, height: 1)
        )
        .task(id: handoff.id) {
            let handoffID = handoff.id
            do {
                try await Task.sleep(nanoseconds: 8_000_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                onDismiss(handoffID)
            }
        }
    }
}

// MARK: - Preview

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView(appState: AppState())
            .preferredColorScheme(.dark)
    }
}
