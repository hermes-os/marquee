import Foundation
import os

// MARK: - Marquee Logger

enum MarqueeLogger {

    private static let subsystem = "com.marquee.app"

    static let general = os.Logger(subsystem: subsystem, category: "general")
    static let network = os.Logger(subsystem: subsystem, category: "network")
    static let scanner = os.Logger(subsystem: subsystem, category: "scanner")
    static let player = os.Logger(subsystem: subsystem, category: "player")
    static let cache = os.Logger(subsystem: subsystem, category: "cache")
}
