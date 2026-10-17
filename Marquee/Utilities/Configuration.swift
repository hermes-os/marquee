import Foundation

// MARK: - Configuration

enum Configuration {

    // MARK: - TMDB

    static var tmdbAPIKey: String {
        guard let key = tmdbAPIKey(at: localSecretsFileURL) else {
            MarqueeLogger.network.error("TMDB API key missing: local Secrets.plist absent or empty")
            return ""
        }
        return key
    }

    static let tmdbBaseURL = "https://api.themoviedb.org/3"
    static let tmdbImageBaseURL = "https://image.tmdb.org/t/p"

    // MARK: - Image Sizes

    static let posterDownloadSize = "w780"
    static let backdropDownloadSize = "w1280"
    static let avatarImageSize = "w185"

    // MARK: - Defaults

    static let defaultWatchedThreshold: Double = 0.93
    static let minimumWatchSeconds: TimeInterval = 120
    static let watchProgressExpirationDays: Int = 15
    static let maxConcurrentTMDBRequests: Int = 8
    static let maxCastMembers: Int = 10

    // MARK: - Paths

    static var appSupportDirectory: URL {
        activeDataDirectory
    }

    static var appCacheDirectory: URL {
        let cachesDirectory = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first ?? localAppSupportDirectory.appendingPathComponent("Cache", isDirectory: true)
        return cachesDirectory.appendingPathComponent("Marquee", isDirectory: true)
    }

    static var artworkCacheDirectory: URL {
        appCacheDirectory.appendingPathComponent("artwork", isDirectory: true)
    }

    static var mediaRootDirectory: URL? {
        preferredMediaRoot()
    }

    static var localAppSupportDirectory: URL {
        let supportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support")
        return supportDirectory.appendingPathComponent("Marquee")
    }

    static var localSecretsFileURL: URL {
        localAppSupportDirectory.appendingPathComponent("Secrets.plist", isDirectory: false)
    }

    static var localHostConfigurationFileURL: URL {
        localAppSupportDirectory.appendingPathComponent("HostConfiguration.plist", isDirectory: false)
    }

    #if DEBUG
    static let sidecarRootOverrideEnvironmentKey = "MARQUEE_SIDECAR_ROOT"
    static var liveMediaSidecarDirectory: URL {
        guard let root = preferredMediaRoot() else {
            return localAppSupportDirectory
        }
        return root.appendingPathComponent(".marquee", isDirectory: true)
    }
    #endif

    // MARK: - Private

    private static func tmdbAPIKey(at url: URL) -> String? {
        guard let dict = NSDictionary(contentsOf: url),
              let key = dict["TMDBAPIKey"] as? String,
              !key.isEmpty else {
            return nil
        }
        return key
    }

    private static func hostMediaRootPaths(at url: URL) -> [String] {
        guard let dict = NSDictionary(contentsOf: url),
              let paths = dict["MediaRootPaths"] as? [String] else {
            return []
        }
        return paths.compactMap { path in
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    #if DEBUG
    static func debugTMDBAPIKey(at url: URL) -> String? {
        tmdbAPIKey(at: url)
    }

    static func debugHostMediaRootPaths(at url: URL) -> [String] {
        hostMediaRootPaths(at: url)
    }
    #endif

    private static var activeDataDirectory: URL {
        #if DEBUG
        if let override = debugResolvedSidecarRootOverrideDirectory() {
            return override
        }
        #endif

        if let override = ProcessInfo.processInfo.environment["MARQUEE_DATA_DIR"],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }

        #if DEBUG
        if let harnessDirectory = debugHarnessSidecarDirectory {
            return harnessDirectory
        }
        #endif

        if let root = preferredMediaRoot() {
            return root.appendingPathComponent(".marquee", isDirectory: true)
        }

        return localAppSupportDirectory
    }

    #if DEBUG
    static func debugResolvedSidecarRootOverrideDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        let argumentOverride: String? = {
            guard let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--qa-sidecar-root"),
                  ProcessInfo.processInfo.arguments.indices.contains(index + 1) else {
                return nil
            }
            return ProcessInfo.processInfo.arguments[index + 1]
        }()
        guard let override = argumentOverride ?? environment[sidecarRootOverrideEnvironmentKey],
              !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let requested = URL(fileURLWithPath: override, isDirectory: true)
        if debugSidecarURLIsLiveOrChild(requested) {
            return debugRejectedSidecarOverrideDirectory
        }

        return requested
    }

    static var debugHarnessSidecarDirectory: URL? {
        guard isHarnessLaunch else { return nil }
        return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(
                "marquee-harness-sidecar-\(ProcessInfo.processInfo.processIdentifier)",
                isDirectory: true
            )
    }

    static func debugSidecarURLIsLiveOrChild(_ url: URL) -> Bool {
        let path = canonicalPathForSidecarGuard(url)
        let live = canonicalPathForSidecarGuard(liveMediaSidecarDirectory)
        return path == live || path.hasPrefix(live + "/")
    }

    static var debugRejectedSidecarOverrideDirectory: URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(
                "marquee-rejected-sidecar-override-\(ProcessInfo.processInfo.processIdentifier)",
                isDirectory: true
            )
    }

    private static func canonicalPathForSidecarGuard(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static var isHarnessLaunch: Bool {
        ProcessInfo.processInfo.arguments.contains { argument in
            argument.hasPrefix("--verify-") || argument.hasPrefix("--qa-")
        }
    }
    #endif

    private static func preferredMediaRoot() -> URL? {
        let fm = FileManager.default
        if let override = ProcessInfo.processInfo.environment["MARQUEE_MEDIA_ROOT"],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let url = URL(fileURLWithPath: override, isDirectory: true)
            return isUsableMediaRoot(url, fileManager: fm) ? url : nil
        }

        let configuredPaths = hostMediaRootPaths(at: localHostConfigurationFileURL)
        for path in configuredPaths {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            if isUsableMediaRoot(url, fileManager: fm) { return url }
        }
        if !configuredPaths.isEmpty { return nil }

        let volumesURL = URL(fileURLWithPath: "/Volumes", isDirectory: true)
        guard let volumes = try? fm.contentsOfDirectory(
            at: volumesURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        var candidates: [URL] = []
        var candidatePaths = Set<String>()
        for volume in volumes.sorted(by: { $0.path < $1.path }) {
            let direct = volume
            if isUsableMediaRoot(direct, fileManager: fm),
               candidatePaths.insert(direct.standardizedFileURL.path).inserted {
                candidates.append(direct)
            }

            let tapeMachine = volume.appendingPathComponent("Tape-Machine", isDirectory: true)
            if isUsableMediaRoot(tapeMachine, fileManager: fm),
               candidatePaths.insert(tapeMachine.standardizedFileURL.path).inserted {
                candidates.append(tapeMachine)
            }
        }

        guard candidates.count == 1 else {
            if candidates.count > 1 {
                MarqueeLogger.general.error(
                    "Multiple media roots found; configure HostConfiguration.plist or MARQUEE_MEDIA_ROOT"
                )
            }
            return nil
        }
        return candidates[0]
    }

    private static func isUsableMediaRoot(_ url: URL, fileManager fm: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return false
        }

        let movies = url.appendingPathComponent("MOVIES", isDirectory: true)
        let tv = url.appendingPathComponent("TV", isDirectory: true)
        return fm.fileExists(atPath: movies.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
            && fm.fileExists(atPath: tv.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}

#if DEBUG && !QA_NO_HARNESSES
enum VerifyConfigurationHarness {
    static let launchArgument = "--verify-configuration"

    static func runIfRequested() {
        guard CommandLine.arguments.contains(launchArgument) else { return }

        do {
            try verifyExternalSecretsContract()
            try verifyHostConfigurationContract()
            FileHandle.standardError.write(Data(
                "verify-configuration: PASS external Secrets.plist lookup; ordered host media roots; bundle exclusion; missing/empty fallback\n".utf8
            ))
            FileHandle.standardError.write(Data(
                "verify-configuration: outcome=verified passed=4/4\n".utf8
            ))
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("verify-configuration: FAIL \(error)\n".utf8))
            FileHandle.standardError.write(Data(
                "verify-configuration: outcome=failed passed=0/4\n".utf8
            ))
            exit(1)
        }
    }

    private static func verifyExternalSecretsContract() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("marquee-configuration-harness-\(UUID().uuidString)", isDirectory: true)
        let valid = root.appendingPathComponent("Secrets.plist")
        let empty = root.appendingPathComponent("Empty.plist")
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let validData = try PropertyListSerialization.data(
            fromPropertyList: ["TMDBAPIKey": "fixture-key"],
            format: .xml,
            options: 0
        )
        let emptyData = try PropertyListSerialization.data(
            fromPropertyList: ["TMDBAPIKey": ""],
            format: .xml,
            options: 0
        )
        try validData.write(to: valid, options: .atomic)
        try emptyData.write(to: empty, options: .atomic)

        guard Configuration.debugTMDBAPIKey(at: valid) == "fixture-key" else {
            throw HarnessError.assertion("external plist did not resolve its synthetic key")
        }
        guard Configuration.debugTMDBAPIKey(at: empty) == nil,
              Configuration.debugTMDBAPIKey(at: root.appendingPathComponent("Missing.plist")) == nil else {
            throw HarnessError.assertion("missing or empty local configuration did not stay offline-safe")
        }
        let bundlePath = Bundle.main.bundleURL.standardizedFileURL.path + "/"
        guard !Configuration.localSecretsFileURL.standardizedFileURL.path.hasPrefix(bundlePath) else {
            throw HarnessError.assertion("local configuration resolved inside the app bundle")
        }
    }

    private static func verifyHostConfigurationContract() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("marquee-host-configuration-harness-\(UUID().uuidString)", isDirectory: true)
        let valid = root.appendingPathComponent("HostConfiguration.plist")
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["MediaRootPaths": [" /Volumes/Primary/Library ", "", "/Volumes/Backup/Library"]],
            format: .xml,
            options: 0
        )
        try data.write(to: valid, options: .atomic)

        let paths = Configuration.debugHostMediaRootPaths(at: valid)
        guard paths == ["/Volumes/Primary/Library", "/Volumes/Backup/Library"] else {
            throw HarnessError.assertion("host media-root order or trimming changed: \(paths)")
        }
    }

    private enum HarnessError: Error, CustomStringConvertible {
        case assertion(String)

        var description: String {
            switch self {
            case .assertion(let message): return message
            }
        }
    }
}
#endif
