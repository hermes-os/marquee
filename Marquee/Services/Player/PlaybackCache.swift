import Foundation

enum PlaybackCache {
    static let playbackCacheEnvironmentKey = "MARQUEE_PLAYBACK_CACHE_DIR"

    private static let marqueeDirectoryName = ".marquee"
    private static let playbackCacheDirectoryName = "playback-cache"
    private static let defaultMinimumStreamingFreeBytes: UInt64 = 1 * 1024 * 1024 * 1024

    static func directory(
        forSourcePath sourcePath: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = environment[playbackCacheEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            let overrideURL = URL(fileURLWithPath: override, isDirectory: true)
            #if DEBUG
            if Configuration.debugSidecarURLIsLiveOrChild(overrideURL) {
                return debugRejectedPlaybackCacheDirectory(environment: environment)
            }
            #endif
            return overrideURL
        }

        #if DEBUG
        if let sidecarRoot = Configuration.debugResolvedSidecarRootOverrideDirectory(environment: environment) {
            return sidecarRoot
                .appendingPathComponent(playbackCacheDirectoryName, isDirectory: true)
        }

        if environment == ProcessInfo.processInfo.environment,
           let harnessDirectory = Configuration.debugHarnessSidecarDirectory {
            return harnessDirectory
                .appendingPathComponent(playbackCacheDirectoryName, isDirectory: true)
        }
        #endif

        if let mediaRoot = mediaRoot(forSourcePath: sourcePath) {
            return mediaRoot
                .appendingPathComponent(marqueeDirectoryName, isDirectory: true)
                .appendingPathComponent(playbackCacheDirectoryName, isDirectory: true)
        }

        return Configuration.appSupportDirectory
            .appendingPathComponent(playbackCacheDirectoryName, isDirectory: true)
    }

    static func ensureDirectory(
        forSourcePath sourcePath: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> URL {
        try ensureDirectory(directory(forSourcePath: sourcePath, environment: environment))
    }

    static func ensureDirectory(_ directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func processEnvironment(
        base: [String: String] = ProcessInfo.processInfo.environment,
        forSourcePath sourcePath: String? = nil
    ) -> [String: String] {
        processEnvironment(base: base, directory: directory(forSourcePath: sourcePath, environment: base))
    }

    static func processEnvironment(
        base: [String: String] = ProcessInfo.processInfo.environment,
        directory: URL
    ) -> [String: String] {
        var environment = base
        let path = directory.standardizedFileURL.path
        environment["TMPDIR"] = path
        environment["TMP"] = path
        environment["TEMP"] = path
        environment[playbackCacheEnvironmentKey] = path
        return environment
    }

    #if DEBUG
    private static func debugRejectedPlaybackCacheDirectory(environment: [String: String]) -> URL {
        if let sidecarRoot = Configuration.debugResolvedSidecarRootOverrideDirectory(environment: environment) {
            return sidecarRoot
                .appendingPathComponent(playbackCacheDirectoryName, isDirectory: true)
        }

        if environment == ProcessInfo.processInfo.environment,
           let harnessDirectory = Configuration.debugHarnessSidecarDirectory {
            return harnessDirectory
                .appendingPathComponent(playbackCacheDirectoryName, isDirectory: true)
        }

        return Configuration.debugRejectedSidecarOverrideDirectory
            .appendingPathComponent(playbackCacheDirectoryName, isDirectory: true)
    }
    #endif

    static func cleanUpAbandonedFiles() {
        guard let directory = try? ensureDirectory() else { return }
        cleanUpAbandonedFiles(in: directory)
    }

    static func cleanUpAbandonedFiles(in directory: URL) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return }

        for file in files where isAbandonedCacheFile(file) {
            try? fm.removeItem(at: file)
        }
    }

    @discardableResult
    static func requireFreeBytes(
        forSourcePath sourcePath: String? = nil,
        minimumBytes: UInt64 = minimumStreamingFreeBytes
    ) throws -> URL {
        let directory = try ensureDirectory(forSourcePath: sourcePath)
        try requireFreeBytes(in: directory, minimumBytes: minimumBytes)
        return directory
    }

    static func requireFreeBytes(in directory: URL, minimumBytes: UInt64) throws {
        guard minimumBytes > 0,
              let available = availableBytes(onVolumeFor: directory),
              available < minimumBytes else {
            return
        }
        throw PlaybackCacheError.insufficientSpace(
            directory: directory,
            available: available,
            required: minimumBytes
        )
    }

    static var minimumStreamingFreeBytes: UInt64 {
        let raw = ProcessInfo.processInfo.environment["MARQUEE_MIN_PLAYBACK_CACHE_FREE_BYTES"]
        if let raw, let value = UInt64(raw), value > 0 {
            return value
        }
        return defaultMinimumStreamingFreeBytes
    }

    private static func mediaRoot(forSourcePath sourcePath: String?) -> URL? {
        guard let sourcePath = sourcePath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sourcePath.isEmpty else {
            return Configuration.mediaRootDirectory
        }

        let sourceURL = URL(fileURLWithPath: sourcePath).standardizedFileURL
        if let configuredRoot = Configuration.mediaRootDirectory,
           path(sourceURL.path, isInsideOrEqualTo: configuredRoot.path) {
            return configuredRoot
        }

        let components = sourceURL.pathComponents
        if let root = mediaRootFromLibraryComponents(components) {
            return root
        }

        if let tapeMachineRoot = tapeMachineRootFromVolumeComponents(components) {
            return tapeMachineRoot
        }

        if let volumeRoot = volumeRootFromComponents(components) {
            return volumeRoot
        }

        return Configuration.mediaRootDirectory
    }

    private static func mediaRootFromLibraryComponents(_ components: [String]) -> URL? {
        guard let index = components.firstIndex(where: isLibraryRootComponent),
              index > 1 else {
            return nil
        }
        let rootPath = NSString.path(withComponents: Array(components[..<index]))
        guard rootPath != "/" else { return nil }
        return URL(fileURLWithPath: rootPath, isDirectory: true)
    }

    private static func tapeMachineRootFromVolumeComponents(_ components: [String]) -> URL? {
        guard components.count > 3,
              components[1] == "Volumes",
              components[3].caseInsensitiveCompare("Tape-Machine") == .orderedSame else {
            return nil
        }
        let rootPath = NSString.path(withComponents: Array(components.prefix(4)))
        return URL(fileURLWithPath: rootPath, isDirectory: true)
    }

    private static func volumeRootFromComponents(_ components: [String]) -> URL? {
        guard components.count > 2,
              components[1] == "Volumes" else {
            return nil
        }
        let rootPath = NSString.path(withComponents: Array(components.prefix(3)))
        return URL(fileURLWithPath: rootPath, isDirectory: true)
    }

    private static func isLibraryRootComponent(_ component: String) -> Bool {
        component.caseInsensitiveCompare("MOVIES") == .orderedSame
            || component.caseInsensitiveCompare("TV") == .orderedSame
    }

    private static func path(_ path: String, isInsideOrEqualTo rootPath: String) -> Bool {
        let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let normalizedRoot = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL.path
        return normalizedPath == normalizedRoot || normalizedPath.hasPrefix(normalizedRoot + "/")
    }

    private static func isAbandonedCacheFile(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return name.hasSuffix(".tmp")
            || name.hasSuffix(".part")
            || name.hasSuffix(".partial")
            || name.contains(".partial.")
            || name.hasSuffix(".ffmpeg.log")
            || name.hasSuffix(".ffprobe.log")
            || name.hasSuffix(".ffplay.log")
    }

    private static func availableBytes(onVolumeFor url: URL) -> UInt64? {
        let keys: Set<URLResourceKey> = [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        if let important = values.volumeAvailableCapacityForImportantUsage, important > 0 {
            return UInt64(important)
        }
        if let capacity = values.volumeAvailableCapacity, capacity > 0 {
            return UInt64(capacity)
        }
        return nil
    }
}

enum PlaybackCacheError: LocalizedError {
    case insufficientSpace(directory: URL, available: UInt64, required: UInt64)

    var errorDescription: String? {
        switch self {
        case .insufficientSpace(let directory, let available, let required):
            return "Playback cache is low on space at \(directory.path). Available: \(Self.formatBytes(available)); required: \(Self.formatBytes(required))."
        }
    }

    private static func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }
}
