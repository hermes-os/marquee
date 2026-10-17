import Foundation
import os

// MARK: - Watch Progress Entry

struct WatchProgressEntry: Codable {
    let filePath: String
    var position: Double
    var duration: Double
    var lastPlayed: Date

    var isExpired: Bool {
        Date().timeIntervalSince(lastPlayed) > 15 * 24 * 60 * 60
    }

    var fractionWatched: Double {
        guard duration > 0 else { return 0 }
        return position / duration
    }
}

// MARK: - Watch Progress Store

final class WatchProgressStore {

    private static var instances: [String: WatchProgressStore] = [:]
    private static let instanceLock = DispatchQueue(label: "com.marquee.watchprogress.lock")

    static func forProfile(_ profileID: UUID) -> WatchProgressStore {
        let key = profileID.uuidString
        return instanceLock.sync {
            if let existing = instances[key] {
                return existing
            }
            let store = WatchProgressStore(profileID: key)
            instances[key] = store
            return store
        }
    }

    private let fileURL: URL
    private let completedFileURL: URL
    private let completionLedgerFileURL: URL
    private var entries: [String: WatchProgressEntry] = [:]
    private var completedEntries: [String: WatchProgressEntry] = [:]
    private var completedTitlePaths: Set<String> = []
    private let minimumWatchTime: Double = 120

    private init(profileID: String) {
        let appSupport = Configuration.appSupportDirectory

        try? FileManager.default.createDirectory(
            at: appSupport,
            withIntermediateDirectories: true
        )

        fileURL = appSupport.appendingPathComponent("watch-progress-\(profileID).json")
        completedFileURL = appSupport.appendingPathComponent("watch-completed-\(profileID).json")
        completionLedgerFileURL = appSupport.appendingPathComponent("watch-completion-ledger-\(profileID).json")
        load()
        pruneExpired()
    }

    // MARK: - Public API

    func save(filePath: String, position: Double, duration: Double) {
        guard position >= minimumWatchTime else { return }

        let fraction = duration > 0 ? position / duration : 0
        if fraction > 0.93 {
            entries.removeValue(forKey: filePath)
            completedTitlePaths.insert(filePath)
            completedEntries[filePath] = WatchProgressEntry(
                filePath: filePath,
                position: duration,
                duration: duration,
                lastPlayed: Date()
            )
        } else {
            entries[filePath] = WatchProgressEntry(
                filePath: filePath,
                position: position,
                duration: duration,
                lastPlayed: Date()
            )
        }
        persist()
    }

    func progress(for filePath: String) -> WatchProgressEntry? {
        guard let entry = entries[filePath], !entry.isExpired else {
            return nil
        }
        return entry
    }

    func allActiveEntries() -> [WatchProgressEntry] {
        entries.values
            .filter { !$0.isExpired }
            .sorted { $0.lastPlayed > $1.lastPlayed }
    }

    func completedProgress(for filePath: String) -> WatchProgressEntry? {
        guard let entry = completedEntries[filePath], !entry.isExpired else {
            return nil
        }
        return entry
    }

    func allCompletedEntries() -> [WatchProgressEntry] {
        completedEntries.values
            .filter { !$0.isExpired }
            .sorted { $0.lastPlayed > $1.lastPlayed }
    }

    func completedTitleFilePaths() -> Set<String> {
        completedTitlePaths
    }

    func remove(filePath: String) {
        entries.removeValue(forKey: filePath)
        completedEntries.removeValue(forKey: filePath)
        persist()
    }

    func clearAll() {
        entries.removeAll()
        completedEntries.removeAll()
        completedTitlePaths.removeAll()
        persist()
    }

    // MARK: - Persistence

    private func load() {
        do {
            let data = try Data(contentsOf: fileURL)
            entries = try JSONDecoder().decode([String: WatchProgressEntry].self, from: data)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            // First launch, no file yet
        } catch {
            MarqueeLogger.general.error("Failed to load watch progress: \(error.localizedDescription)")
        }

        do {
            let data = try Data(contentsOf: completedFileURL)
            completedEntries = try JSONDecoder().decode([String: WatchProgressEntry].self, from: data)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            // First launch, no file yet
        } catch {
            MarqueeLogger.general.error("Failed to load completed progress: \(error.localizedDescription)")
        }

        do {
            let data = try Data(contentsOf: completionLedgerFileURL)
            let paths = try JSONDecoder().decode([String].self, from: data)
            completedTitlePaths = Set(paths)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            // First launch, no file yet
        } catch {
            MarqueeLogger.general.error("Failed to load completion ledger: \(error.localizedDescription)")
        }

        let loadedLedgerCount = completedTitlePaths.count
        completedTitlePaths.formUnion(
            completedEntries.values
                .map(\.filePath)
        )
        if completedTitlePaths.count != loadedLedgerCount {
            persist()
        }
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(entries) {
            do {
                try data.write(to: fileURL, options: .atomic)
            } catch {
                MarqueeLogger.general.error("Failed to write watch progress: \(error.localizedDescription)")
            }
        }
        if let data = try? encoder.encode(completedEntries) {
            do {
                try data.write(to: completedFileURL, options: .atomic)
            } catch {
                MarqueeLogger.general.error("Failed to write completed progress: \(error.localizedDescription)")
            }
        }
        if let data = try? encoder.encode(completedTitlePaths.sorted()) {
            do {
                try data.write(to: completionLedgerFileURL, options: .atomic)
            } catch {
                MarqueeLogger.general.error("Failed to write completion ledger: \(error.localizedDescription)")
            }
        }
    }

    private func pruneExpired() {
        let beforeIn = entries.count
        let beforeCo = completedEntries.count
        entries = entries.filter { !$0.value.isExpired }
        completedEntries = completedEntries.filter { !$0.value.isExpired }
        if entries.count != beforeIn || completedEntries.count != beforeCo {
            persist()
        }
    }
}
