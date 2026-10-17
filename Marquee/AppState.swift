import Combine
import SwiftUI
import UniformTypeIdentifiers

#if DEBUG
struct QASearchPublicationEvidence: Sendable {
    let resultCount: Int
    let publishedAt: Date
}

struct QAHomeRowsInteractiveEvidence: Sendable {
    let profileID: UUID
    let selectionCompletedAt: Date
    let rowID: String
    let itemIDs: [UUID]
    let rowCount: Int
    let itemCount: Int
    let completedAt: Date
}

struct QAShowEpisodeFocusEvidence: Sendable {
    let focusedIndex: Int
    let episodeCount: Int
}
#endif

extension Notification.Name {
    static let marqueeActivateSearch = Notification.Name("marqueeActivateSearch")
    static let marqueeOpenScopedSearch = Notification.Name("marqueeOpenScopedSearch")
    static let marqueeFocusSearchField = Notification.Name("marqueeFocusSearchField")
    static let marqueeBufferedSearchInputChanged = Notification.Name("marqueeBufferedSearchInputChanged")
    #if DEBUG
    static let marqueeQAVisualTourFocusFirstSearchResult = Notification.Name("marqueeQAVisualTourFocusFirstSearchResult")
    static let marqueeQAVisualTourFocusFirstShowEpisode = Notification.Name("marqueeQAVisualTourFocusFirstShowEpisode")
    static let marqueeQAVisualTourProbeShowEpisodeFocus = Notification.Name("marqueeQAVisualTourProbeShowEpisodeFocus")
    static let marqueeQAVisualTourFocusFirstShowMoreLike = Notification.Name("marqueeQAVisualTourFocusFirstShowMoreLike")
    static let marqueeQAVisualTourShowEpisodeFocused = Notification.Name("marqueeQAVisualTourShowEpisodeFocused")
    static let marqueeQASearchStateProbe = Notification.Name("marqueeQASearchStateProbe")
    static let marqueeQARouteSurfaceAppeared = Notification.Name("marqueeQARouteSurfaceAppeared")
    static let marqueeQADetailSurfaceAppeared = Notification.Name("marqueeQADetailSurfaceAppeared")
    static let marqueeQAHomeRowsInteractive = Notification.Name("marqueeQAHomeRowsInteractive")
    static let marqueeQASearchResultsPublished = Notification.Name("marqueeQASearchResultsPublished")
    static let marqueeQABrowsePresentationObserved = Notification.Name("marqueeQABrowsePresentationObserved")
    static let marqueeQABrowseReturnPlaced = Notification.Name("marqueeQABrowseReturnPlaced")
    #endif
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var appStateRef: AppState?
    private var activationObserver: Any?
    private var shortcutMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        PlaybackCache.cleanUpAbandonedFiles()

        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53,
               Self.appStateRef?.playerController.isPlayerPresented == true {
                Self.appStateRef?.dismissPlayer()
                return nil
            }
            if event.modifierFlags.contains(.command),
               (event.keyCode == 3 || event.charactersIgnoringModifiers?.lowercased() == "f") {
                guard ProfileExitTransitionPolicy.acceptsInput(
                    isExitInFlight: Self.appStateRef?.isProfileExitInFlight == true
                ) else { return nil }
                SearchInputBuffer.shared.beginCapture()
                NotificationCenter.default.post(name: .marqueeActivateSearch, object: nil)
                return nil
            }
            if SearchInputBuffer.shared.capture(event) {
                return nil
            }
            return event
        }

        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            for window in NSApplication.shared.windows {
                if window.isMiniaturized {
                    window.deminiaturize(nil)
                    window.makeKeyAndOrderFront(nil)
                    return
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let observer = activationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let monitor = shortcutMonitor {
            NSEvent.removeMonitor(monitor)
        }
        Self.appStateRef?.closePlayer()
    }
}

// MARK: - App State
struct PostPlayHandoff: Identifiable {
    let source: MediaItem
    let candidate: MediaItem

    var id: String {
        "\(source.id.uuidString)-\(candidate.id.uuidString)"
    }
}

class AppState: ObservableObject {
    let playback = PlaybackSession()
    let router = AppRouter()
    let profileSession: ProfileSession
    let library: LibraryState
    let searchSession: SearchSession
    let profileStore = ProfileStore.shared
    let userSettings = UserSettings.shared

    @Published var currentError: AppError?
    @Published var postPlayHandoff: PostPlayHandoff?
    @Published private(set) var profileExitSelectionID: UUID?
    @Published private(set) var profileExitLibraryCounts: (movies: Int, episodes: Int)?
    @Published private(set) var isProfileExitPresentationActive = false
    private var scheduledProfileExitSelectionID: UUID?
    private var profileExitCompletionSerial = 0
    #if DEBUG
    private var deferredProfileExitSelectionID: UUID?
    #endif

    private var cancellables = Set<AnyCancellable>()

    var isProfileExitInFlight: Bool {
        profileExitSelectionID != nil
    }

    init(skipPersistenceForHarness: Bool = false) {
        let session = ProfileSession()
        profileSession = session
        let libraryState = LibraryState(
            currentProfile: { session.activeProfile },
            isProfilePickerVisible: { session.showProfilePicker },
            openPersistentStore: !skipPersistenceForHarness,
            restoreProjectedCache: !skipPersistenceForHarness
        )
        library = libraryState
        let search = SearchSession(index: libraryState.browseSnapshot.searchIndex)
        searchSession = search
        playback.onError = { [weak self] error in
            self?.showError(error)
        }
        profileSession.hooks = ProfileSessionHooks(
            setWatchStore: { [weak self] store in self?.library.setWatchStore(store) },
            configurePlayer: { [weak self] in self?.configurePlayerForCurrentProfile() },
            applyWatchProgress: { [weak self] in self?.library.applyWatchProgress() },
            recomputeFilteredItems: { [weak self] in self?.library.recomputeFilteredItems() },
            recomputeProgressRows: { [weak self] in self?.library.recomputeProgressRows() },
            scheduleHomeArtworkPreheat: { [weak self] delay, allowWhileProfilePicker in
                self?.library.scheduleHomeArtworkPreheat(delay: delay, allowWhileProfilePicker: allowWhileProfilePicker)
            },
            beginBackgroundScanIfNeeded: { [weak self] in self?.library.beginBackgroundScanIfNeeded() },
            filteredCounts: { [weak self] in
                (self?.library.filteredLibraryItems.count ?? 0, self?.library.filteredTVItems.count ?? 0)
            }
        )
        profileSession.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        library.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        libraryState.$browseSnapshot
            .map(\.searchIndex)
            .removeDuplicates { previous, next in
                previous.revisionKey == next.revisionKey
            }
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak search] nextIndex in
                search?.updateIndex(nextIndex)
            }
            .store(in: &cancellables)
        let playerController = playback.playerController
        AudioIdentityService.shared.configurePlayerPresentation { [weak playerController] in
            playerController?.isPlayerPresented ?? false
        }
        playerController.$isPlayerPresented
            .removeDuplicates()
            .sink { isPresented in
                AudioIdentityService.shared.playerPresentationDidChange(isPresented)
            }
            .store(in: &cancellables)
    }

    // MARK: - Narrow Object Shims

    var playerController: PlayerController {
        playback.playerController
    }

    var activeProfile: UserProfile? {
        profileSession.activeProfile
    }

    var showProfilePicker: Bool {
        profileSession.showProfilePicker
    }

    // MARK: - Player Delegation

    func playFile(at path: String) {
        postPlayHandoff = nil
        playback.playFile(at: path)
    }

    func playItem(_ item: MediaItem, fromStart: Bool = false) {
        postPlayHandoff = nil
        playback.playItem(item, fromStart: fromStart)
    }

    func playPostPlayHandoff(id: String) {
        guard let handoff = postPlayHandoff,
              handoff.id == id else { return }
        if let activeProfile, !activeProfile.allows(item: handoff.candidate) {
            postPlayHandoff = nil
            return
        }
        playItem(handoff.candidate)
    }

    func playSomething() {
        guard let pick = nextPlaySomethingPick() else { return }
        playItem(pick)
    }

    func nextPlaySomethingPick() -> MediaItem? {
        let salt = "\(activeProfile?.id.uuidString ?? "no-profile")-\(UUID().uuidString)"
        return BrowseLeanBackDelightPolicy.playSomethingPick(
            movies: library.filteredLibraryItems,
            showSummaries: library.browseSnapshot.showSummaries,
            tasteProfile: library.browseSnapshot.tasteProfile,
            salt: salt
        )
    }

    func dismissPlayer() {
        playback.dismissPlayer()
    }

    func closePlayer() {
        playback.closePlayer()
    }

    func dismissPostPlayHandoff(id: String? = nil) {
        guard id == nil || postPlayHandoff?.id == id else { return }
        postPlayHandoff = nil
    }

    // MARK: - Profile Delegation

    @discardableResult
    func beginProfileExitSelection(_ profile: UserProfile) -> Bool {
        guard profileExitSelectionID == nil else { return false }
        profileExitLibraryCounts = (
            movies: library.filteredLibraryItems.count,
            episodes: library.filteredTVItems.count
        )
        profileExitCompletionSerial &+= 1
        scheduledProfileExitSelectionID = nil
        isProfileExitPresentationActive = false
        profileExitSelectionID = profile.id
        selectProfile(profile)
        return true
    }

    func profileExitPresentationDidStart(selectionID: UUID) {
        #if DEBUG
        guard deferredProfileExitSelectionID != selectionID else { return }
        #endif
        guard profileExitSelectionID == selectionID,
              scheduledProfileExitSelectionID != selectionID else { return }
        scheduledProfileExitSelectionID = selectionID
        isProfileExitPresentationActive = true
        scheduleProfileExitCompletion(
            selectionID: selectionID,
            after: ProfileExitTransitionPolicy.duration
        )
    }

    private func scheduleProfileExitCompletion(selectionID: UUID, after delay: TimeInterval) {
        profileExitCompletionSerial &+= 1
        let completionSerial = profileExitCompletionSerial
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard self?.profileExitSelectionID == selectionID,
                  self?.profileExitCompletionSerial == completionSerial else { return }
            self?.scheduledProfileExitSelectionID = nil
            self?.isProfileExitPresentationActive = false
            self?.profileExitSelectionID = nil
            self?.profileExitLibraryCounts = nil
        }
    }

    #if DEBUG
    func deferProfileExitPresentationForVisualQA(selectionID: UUID) {
        guard profileExitSelectionID == selectionID else { return }
        profileExitCompletionSerial &+= 1
        scheduledProfileExitSelectionID = nil
        deferredProfileExitSelectionID = selectionID
        isProfileExitPresentationActive = false
    }

    func startDeferredProfileExitPresentationForVisualQA(selectionID: UUID) {
        guard profileExitSelectionID == selectionID,
              deferredProfileExitSelectionID == selectionID else { return }
        deferredProfileExitSelectionID = nil
        scheduledProfileExitSelectionID = selectionID
        isProfileExitPresentationActive = true
        scheduleProfileExitCompletion(selectionID: selectionID, after: 2.0)
    }

    func armProfileExitCompletionForVisualQA(selectionID: UUID) {
        guard profileExitSelectionID == selectionID,
              isProfileExitPresentationActive else { return }
        scheduleProfileExitCompletion(
            selectionID: selectionID,
            after: ProfileExitTransitionPolicy.duration
        )
    }
    #endif

    func selectProfile(_ profile: UserProfile) {
        dismissPostPlayHandoff()
        profileSession.selectProfile(profile)
    }

    func reconcileActiveProfile() {
        dismissPostPlayHandoff()
        profileSession.reconcileActiveProfile()
    }

    func switchProfile() {
        dismissPostPlayHandoff()
        profileSession.switchProfile()
    }

    private func configurePlayerForCurrentProfile() {
        playback.configure(
            watchStore: library.watchStore,
            onItemProgressUpdated: { [weak library] path in
                library?.applyWatchProgressForItem(at: path)
            },
            findNextEpisode: { [weak library] currentItem -> MediaItem? in
                guard let library,
                      let showName = currentItem.showName else { return nil }
                return PlayerEpisodePlaybackPolicy.nextEpisode(
                    after: currentItem,
                    in: library.episodes(forShow: showName)
                )
            },
            onPlaybackCompleted: { [weak self] item in
                self?.presentPostPlayHandoff(after: item)
            }
        )
    }

    private func presentPostPlayHandoff(after item: MediaItem) {
        guard let candidate = BrowseLeanBackDelightPolicy.postPlayHandoffCandidate(
            after: item,
            dismissal: .ended,
            movies: library.filteredLibraryItems,
            similarity: library.browseSnapshot.similarity
        ) else {
            postPlayHandoff = nil
            return
        }
        postPlayHandoff = PostPlayHandoff(source: item, candidate: candidate)
    }

    // MARK: - Error Handling

    func showError(_ error: AppError) {
        withAnimation(MarqueeTheme.modalPresentationAnimation) {
            currentError = error
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.dismissError()
        }
    }

    func dismissError() {
        withAnimation(MarqueeTheme.quietDismissAnimation) {
            currentError = nil
        }
    }
}
