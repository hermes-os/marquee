import Foundation

// MARK: - Playback Time Formatting

extension TimeInterval {
    var formattedPlaybackTime: String {
        guard self.isFinite, self >= 0 else { return "0:00" }
        let totalSeconds = Int(self)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}
