import Foundation

// MARK: - Playback Session

final class PlaybackSession {

    let playerController = PlayerController()

    var onError: ((AppError) -> Void)?

    func playFile(at path: String) {
        guard FileManager.default.fileExists(atPath: path) else {
            onError?(.fileNotFound(path: path))
            return
        }
        playerController.playFile(at: path)
    }

    func playItem(_ item: MediaItem, fromStart: Bool = false) {
        guard FileManager.default.fileExists(atPath: item.filePath) else {
            onError?(.fileNotFound(path: item.filePath))
            return
        }
        playerController.playItem(item, fromStart: fromStart)
    }

    func dismissPlayer() {
        playerController.dismissPlayer()
    }

    func closePlayer() {
        playerController.closePlayer()
    }

    func configure(
        watchStore: WatchProgressStore?,
        onItemProgressUpdated: @escaping (String) -> Void,
        findNextEpisode: ((MediaItem) -> MediaItem?)? = nil,
        onPlaybackCompleted: ((MediaItem) -> Void)? = nil
    ) {
        playerController.configure(
            watchStore: watchStore,
            onItemProgressUpdated: onItemProgressUpdated,
            findNextEpisode: findNextEpisode,
            onPlaybackCompleted: onPlaybackCompleted
        )
    }
}
