import SwiftUI
import Combine
import os

enum PlayerEpisodePlaybackPolicy {
    static func nextEpisode(
        after currentItem: MediaItem,
        in orderedEpisodes: [MediaItem]
    ) -> MediaItem? {
        guard currentItem.isEpisode,
              let currentIndex = orderedEpisodes.firstIndex(where: { $0.id == currentItem.id }) else {
            return nil
        }
        let nextIndex = currentIndex + 1
        guard orderedEpisodes.indices.contains(nextIndex) else { return nil }
        return orderedEpisodes[nextIndex]
    }
}

// MARK: - Player Controller

class PlayerController: ObservableObject {

    @Published var playerService: MPVPlayerService?
    @Published var isPlayerPresented: Bool = false
    @Published var isTransitioning: Bool = false

    private var currentPlayingPath: String?
    private(set) var currentPlayingItem: MediaItem?
    private var progressTimer: Timer?
    private var watchStore: WatchProgressStore?
    private var onItemProgressUpdated: ((String) -> Void)?
    private var findNextEpisode: ((MediaItem) -> MediaItem?)?
    private var onPlaybackCompleted: ((MediaItem) -> Void)?
    private var startupSignpostCancellable: AnyCancellable?
    private var pendingStartupSignpostID: OSSignpostID?

    // MARK: - Configuration

    func configure(
        watchStore: WatchProgressStore?,
        onItemProgressUpdated: @escaping (String) -> Void,
        findNextEpisode: ((MediaItem) -> MediaItem?)? = nil,
        onPlaybackCompleted: ((MediaItem) -> Void)? = nil
    ) {
        self.watchStore = watchStore
        self.onItemProgressUpdated = onItemProgressUpdated
        self.findNextEpisode = findNextEpisode
        self.onPlaybackCompleted = onPlaybackCompleted
    }

    // MARK: - Playback

    func playItem(_ item: MediaItem, fromStart: Bool = false) {
        guard FileManager.default.fileExists(atPath: item.filePath) else { return }
        currentPlayingItem = item
        loadFile(at: item.filePath, fromStart: fromStart)
    }

    var nextEpisode: MediaItem? {
        guard let currentPlayingItem, currentPlayingItem.isEpisode else { return nil }
        return findNextEpisode?(currentPlayingItem)
    }

    func playNextEpisode() {
        guard let nextEpisode else { return }
        playItem(nextEpisode)
    }

    func playFile(at path: String, fromStart: Bool = false) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        currentPlayingItem = nil
        loadFile(at: path, fromStart: fromStart)
    }

    private func loadFile(at path: String, fromStart: Bool = false) {
        saveCurrentProgress()

        let oldService = playerService
        oldService?.onPlaybackEnded = nil
        oldService?.setPaused(true)

        let nextService = MPVPlayerService()
        nextService.onPlaybackEnded = { [weak self] in
            self?.handlePlaybackEnded()
        }
        if let orphaned = pendingStartupSignpostID {
            MarqueeSignpost.event("playback-start-outcome", "superseded")
            MarqueeSignpost.end("playback-start", orphaned)
        }
        let startupSignpostID = MarqueeSignpost.begin("playback-start")
        pendingStartupSignpostID = startupSignpostID
        startupSignpostCancellable = nextService.$lifecycleState
            .filter { $0 == .playing || $0 == .failed || $0 == .stopped || $0 == .ended }
            .prefix(1)
            .sink { [weak self] state in
                MarqueeSignpost.event("playback-start-outcome", "\(state)")
                MarqueeSignpost.end("playback-start", startupSignpostID)
                if self?.pendingStartupSignpostID == startupSignpostID {
                    self?.pendingStartupSignpostID = nil
                }
            }
        playerService = nextService

        currentPlayingPath = path
        isPlayerPresented = true
        nextService.loadFile(path)

        if fromStart {
            watchStore?.remove(filePath: path)
            onItemProgressUpdated?(path)
        } else if let entry = watchStore?.progress(for: path) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self, weak nextService] in
                guard let self = self, let nextService = nextService,
                      self.playerService === nextService else { return }
                nextService.seek(to: entry.position)
            }
        }

        if let oldService {
            retireServiceAfterViewDetach(oldService)
        }
        startProgressTracking()
    }

    private func handlePlaybackEnded() {
        if UserSettings.shared.autoPlayNextEpisode,
           let currentItem = currentPlayingItem,
           currentItem.isEpisode,
           let nextEpisode = findNextEpisode?(currentItem) {
            playItem(nextEpisode)
        } else {
            if let currentItem = currentPlayingItem {
                onPlaybackCompleted?(currentItem)
            }
            dismissPlayer()
        }
    }

    func dismissPlayer() {
        guard isPlayerPresented, !isTransitioning else { return }
        let playedPath = currentPlayingPath
        let service = playerService
        saveCurrentProgress()
        stopProgressTracking()
        service?.onPlaybackEnded = nil
        service?.setPaused(true)

        withAnimation(MarqueeTheme.quickControlAnimation) {
            isTransitioning = true
        }

        // Let SwiftUI detach the render view first. The mpv diagnostic path now
        // stops native playback inside detachRenderView() before releasing the
        // layer, which avoids teardown racing a dead rendering surface.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self else { return }
            self.isPlayerPresented = false
            withAnimation(MarqueeTheme.quickControlAnimation) {
                self.isTransitioning = false
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self = self else { return }
                service?.stop()

                self.currentPlayingPath = nil
                self.currentPlayingItem = nil
                if let service, self.playerService === service {
                    self.playerService = nil
                }

                if let path = playedPath {
                    self.onItemProgressUpdated?(path)
                }
            }
        }
    }

    func closePlayer() {
        let service = playerService
        saveCurrentProgress()
        stopProgressTracking()
        service?.onPlaybackEnded = nil
        service?.setPaused(true)
        isPlayerPresented = false
        currentPlayingPath = nil
        currentPlayingItem = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            service?.stop()
            if let service, self?.playerService === service {
                self?.playerService = nil
            }
        }
    }

    private func retireServiceAfterViewDetach(_ service: MPVPlayerService) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            service.stop()
        }
    }

    // MARK: - Progress Tracking

    private func saveCurrentProgress() {
        guard let store = watchStore,
              let path = currentPlayingPath,
              let service = playerService,
              service.currentTime > 0 else { return }
        store.save(
            filePath: path,
            position: service.currentTime,
            duration: service.duration
        )
    }

    private func startProgressTracking() {
        stopProgressTracking()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.saveCurrentProgress()
        }
    }

    private func stopProgressTracking() {
        progressTimer?.invalidate()
        progressTimer = nil
    }
}
