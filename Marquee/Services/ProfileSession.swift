import Foundation

// MARK: - Profile Session Hooks

struct ProfileSessionHooks {
    var setWatchStore: (WatchProgressStore?) -> Void
    var configurePlayer: () -> Void
    var applyWatchProgress: () -> Void
    var recomputeFilteredItems: () -> Void
    var recomputeProgressRows: () -> Void
    var scheduleHomeArtworkPreheat: (_ delay: TimeInterval, _ allowWhileProfilePicker: Bool) -> Void
    var beginBackgroundScanIfNeeded: () -> Void
    var filteredCounts: () -> (movies: Int, tv: Int)
}

#if DEBUG
struct ProfileSelectionCompletionEvidence: Equatable {
    let profileID: UUID
    let completedAt: Date
}
#endif

// MARK: - Profile Session

final class ProfileSession: ObservableObject {

    @Published var activeProfile: UserProfile?
    @Published var showProfilePicker: Bool = true
    #if DEBUG
    @Published private(set) var debugSelectionCompletionEvidence: ProfileSelectionCompletionEvidence?
    #endif

    let profileStore = ProfileStore.shared
    var hooks: ProfileSessionHooks?

    func selectProfile(_ profile: UserProfile) {
        MarqueeLogger.general.info("selectProfile start id=\(profile.id.uuidString, privacy: .public) maturity=\(profile.maturityLevel.rawValue, privacy: .public)")
        let signpostID = MarqueeSignpost.begin("profile-select")
        activeProfile = profile
        #if DEBUG
        debugSelectionCompletionEvidence = nil
        #endif

        if profile.maturityLevel == .adult {
            hooks?.scheduleHomeArtworkPreheat(2.0, true)
            showProfilePicker = false
            MarqueeLogger.general.info("selectProfile hid picker before deferred adult profile setup")
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.hooks?.setWatchStore(WatchProgressStore.forProfile(profile.id))
                self.profileStore.selectProfile(id: profile.id)
                self.hooks?.configurePlayer()
                self.hooks?.beginBackgroundScanIfNeeded()
                MarqueeLogger.general.info("selectProfile deferred adult profile setup finished")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
                guard let self else { return }
                self.hooks?.applyWatchProgress()
                self.hooks?.recomputeFilteredItems()
                self.hooks?.recomputeProgressRows()
                let counts = self.hooks?.filteredCounts() ?? (movies: 0, tv: 0)
                MarqueeLogger.general.info("selectProfile deferred adult recompute finished movies=\(counts.movies, privacy: .public) tv=\(counts.tv, privacy: .public)")
                #if DEBUG
                if self.activeProfile?.id == profile.id {
                    self.debugSelectionCompletionEvidence = ProfileSelectionCompletionEvidence(
                        profileID: profile.id,
                        completedAt: Date()
                    )
                }
                #endif
                MarqueeSignpost.end("profile-select", signpostID)
            }
        } else {
            hooks?.setWatchStore(WatchProgressStore.forProfile(profile.id))
            profileStore.selectProfile(id: profile.id)
            hooks?.configurePlayer()
            hooks?.applyWatchProgress()
            hooks?.recomputeFilteredItems()
            hooks?.scheduleHomeArtworkPreheat(2.0, true)
            showProfilePicker = false
            let counts = hooks?.filteredCounts() ?? (movies: 0, tv: 0)
            MarqueeLogger.general.info("selectProfile hid picker after filtered recompute movies=\(counts.movies, privacy: .public) tv=\(counts.tv, privacy: .public)")
            hooks?.beginBackgroundScanIfNeeded()
            #if DEBUG
            debugSelectionCompletionEvidence = ProfileSelectionCompletionEvidence(
                profileID: profile.id,
                completedAt: Date()
            )
            #endif
            MarqueeSignpost.end("profile-select", signpostID)
        }
    }

    func reconcileActiveProfile() {
        guard let currentProfile = activeProfile else { return }
        if let refreshed = profileStore.profiles.first(where: { $0.id == currentProfile.id }) {
            activeProfile = refreshed
            hooks?.setWatchStore(WatchProgressStore.forProfile(refreshed.id))
            profileStore.selectProfile(id: refreshed.id)
        } else if let fallback = profileStore.selectedProfile() {
            activeProfile = fallback
            hooks?.setWatchStore(WatchProgressStore.forProfile(fallback.id))
            profileStore.selectProfile(id: fallback.id)
        } else {
            activeProfile = nil
            hooks?.setWatchStore(nil)
        }
        hooks?.configurePlayer()
        hooks?.applyWatchProgress()
        hooks?.recomputeFilteredItems()
    }

    func switchProfile() {
        showProfilePicker = true
    }
}
