import Foundation

// MARK: - Diagnostics Collector

struct DiagnosticsSnapshot: Codable {
    let generatedAt: Date
    let app: DiagnosticsAppInfo
    let imagePipeline: ImagePipelineDiagnostics
    let recentCrashReports: [DiagnosticsCrashReport]
}

struct DiagnosticsAppInfo: Codable {
    let appName: String
    let bundleIdentifier: String
    let version: String
    let build: String
    let osVersion: String
}

struct DiagnosticsCrashReport: Codable {
    let fileName: String
    let redactedReportPath: String
    let redactedProcessPath: String?
    let modifiedAt: Date
    let fileSize: Int64
    let incidentID: String?
    let captureTime: String?
    let exceptionType: String?
    let signal: String?
    let faultingThread: Int?
}

enum DiagnosticsCollector {
    static func collect(
        crashReportDirectory: URL = defaultCrashReportDirectory,
        maxCrashReports: Int = 10
    ) -> DiagnosticsSnapshot {
        let reports = recentCrashReportURLs(
            in: crashReportDirectory,
            maxCrashReports: maxCrashReports
        ).map(makeCrashReport)

        return DiagnosticsSnapshot(
            generatedAt: Date(),
            app: appInfo(),
            imagePipeline: ImageDecodePipeline.shared.diagnostics(),
            recentCrashReports: reports
        )
    }

    static func writeSnapshot(
        to directory: URL = Configuration.appSupportDirectory.appendingPathComponent("diagnostics", isDirectory: true),
        crashReportDirectory: URL = defaultCrashReportDirectory,
        maxCrashReports: Int = 10
    ) throws -> URL {
        let snapshot = collect(
            crashReportDirectory: crashReportDirectory,
            maxCrashReports: maxCrashReports
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = exportDateFormatter.string(from: snapshot.generatedAt)
        let url = directory.appendingPathComponent("marquee-diagnostics-\(stamp).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(snapshot).write(to: url, options: .atomic)
        return url
    }

    static var defaultCrashReportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
    }

    private static func appInfo() -> DiagnosticsAppInfo {
        let info = Bundle.main.infoDictionary ?? [:]
        return DiagnosticsAppInfo(
            appName: (info["CFBundleName"] as? String) ?? "Marquee",
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "com.marquee.app",
            version: (info["CFBundleShortVersionString"] as? String) ?? "unknown",
            build: (info["CFBundleVersion"] as? String) ?? "unknown",
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString
        )
    }

    private static func recentCrashReportURLs(
        in directory: URL,
        maxCrashReports: Int
    ) -> [URL] {
        guard maxCrashReports > 0 else { return [] }
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )) ?? []

        return urls
            .filter { url in
                let name = url.lastPathComponent
                return name.hasPrefix("Marquee") && url.pathExtension == "ips"
            }
            .sorted { lhs, rhs in
                modificationDate(for: lhs) > modificationDate(for: rhs)
            }
            .prefix(maxCrashReports)
            .map { $0 }
    }

    private static func makeCrashReport(from url: URL) -> DiagnosticsCrashReport {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let parsed = parseCrashReport(url)
        return DiagnosticsCrashReport(
            fileName: url.lastPathComponent,
            redactedReportPath: redact(url.path),
            redactedProcessPath: parsed.processPath.map(redact),
            modifiedAt: values?.contentModificationDate ?? Date(timeIntervalSince1970: 0),
            fileSize: Int64(values?.fileSize ?? 0),
            incidentID: parsed.incidentID,
            captureTime: parsed.captureTime,
            exceptionType: parsed.exceptionType,
            signal: parsed.signal,
            faultingThread: parsed.faultingThread
        )
    }

    private struct ParsedCrashReport {
        var incidentID: String?
        var captureTime: String?
        var exceptionType: String?
        var signal: String?
        var faultingThread: Int?
        var processPath: String?
    }

    private static func parseCrashReport(_ url: URL) -> ParsedCrashReport {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            return ParsedCrashReport()
        }

        let body: String
        if let newline = raw.firstIndex(of: "\n") {
            body = String(raw[raw.index(after: newline)...])
        } else {
            body = raw
        }

        guard let data = body.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ParsedCrashReport()
        }

        let exception = dict["exception"] as? [String: Any]
        return ParsedCrashReport(
            incidentID: dict["incident"] as? String,
            captureTime: dict["captureTime"] as? String,
            exceptionType: exception?["type"] as? String,
            signal: exception?["signal"] as? String,
            faultingThread: dict["faultingThread"] as? Int,
            processPath: dict["procPath"] as? String
        )
    }

    private static func modificationDate(for url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? Date(timeIntervalSince1970: 0)
    }

    private static func redact(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard path.hasPrefix(home) else { return path }
        return "~" + path.dropFirst(home.count)
    }

    private static let exportDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}
