import Foundation

// MARK: - Marquee Mode Flag

enum MarqueeMode {
    enum Mode: String {
        case browsing
        case playing
    }

    static let fileURL = URL(fileURLWithPath: "/tmp/marquee-mode")

    static func set(_ mode: Mode) {
        let payload = "\(mode.rawValue)\n"
        do {
            try payload.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            MarqueeLogger.general.error("Failed to write Marquee mode flag: \(error.localizedDescription)")
        }
    }
}
