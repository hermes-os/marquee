//
//  VerifyProjectionHarness.swift
//  Marquee
//
//  Phase 2E.3 verification harness for `DefaultCatalogProjection` and
//  `CatalogProjection.attachWatchState`.
//
//  Each scenario seeds a `CatalogStore` with `CatalogMediaFile` rows
//  whose `relativePath` corresponds to a freshly-built fixture tree on
//  disk (so sidecar lookups have something real to read). It then runs
//  the projection against the configured library roots and asserts on
//  the produced `[MediaItem]` shape: `filePath`, `title`, `year`,
//  `showName`, `seasonNumber`, `episodeNumber`, sidecar paths, and
//  duration carry-through. Watch-state scenarios use a real
//  `WatchProgressStore` keyed by a unique-per-scenario profile UUID
//  and clean up the JSON files afterward.
//
//  DEBUG-ONLY. Activated by `--verify-projection`.
//
//  Exit codes: 0 = all pass, 1 = at least one scenario failed,
//  2 = internal error.
//

#if DEBUG

import Foundation

public enum VerifyProjectionHarness {

    public static let launchArgument = "--verify-projection"

    // MARK: - Report types

    public struct ScenarioResult: Codable {
        public let scenario: String
        public let passed: Bool
        public let detail: String
    }

    public struct Report: Codable {
        public let timestamp: Date
        public let outcome: String
        public let passed: Int
        public let total: Int
        public let scenarios: [ScenarioResult]
    }

    // MARK: - Entry point

    public static func runIfRequested() {
        guard CommandLine.arguments.contains(launchArgument) else { return }

        let result = ExitCodeBox()
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            defer { semaphore.signal() }
            do {
                let code = try await runHarness()
                result.set(code)
            } catch {
                let line = "verify-projection: error: \(error)\n"
                FileHandle.standardError.write(Data(line.utf8))
                result.set(2)
            }
        }
        // Drain the main RunLoop while waiting so any `await MainActor.run`
        // hops the harness Task makes (e.g. `MediaScannerService.scan` setting
        // `@Published isScanning`) can land on the main thread instead of
        // deadlocking against `semaphore.wait()`.
        while semaphore.wait(timeout: .now()) == .timedOut {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
        exit(result.value)
    }

    private final class ExitCodeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Int32 = 0
        var value: Int32 { lock.lock(); defer { lock.unlock() }; return stored }
        func set(_ v: Int32) { lock.lock(); stored = v; lock.unlock() }
    }

    // MARK: - Implementation

    private static func runHarness() async throws -> Int32 {
        var results: [ScenarioResult] = []

        for (label, makeStore) in storeFactories() {
            results.append(await runScenario("emptyCatalogYieldsEmptyArray",
                label, makeStore, scenarioEmptyCatalog))
            results.append(await runScenario("movieRowProducesMovieItem",
                label, makeStore, scenarioMovieRow))
            results.append(await runScenario("movieRowDiscoversSidecars",
                label, makeStore, scenarioMovieRowSidecars))
            results.append(await runScenario("tvEpisodeRowProducesEpisode",
                label, makeStore, scenarioTVEpisodeRow))
            results.append(await runScenario("tvEpisodeInfersOfflineShowGenres",
                label, makeStore, scenarioTVEpisodeInfersOfflineShowGenres))
            results.append(await runScenario("extrasFolderRowFiltered",
                label, makeStore, scenarioExtrasFolderFiltered))
            results.append(await runScenario("genreInferredFromFirstSubfolder",
                label, makeStore, scenarioGenreInferred))
            results.append(await runScenario("movieFamilyFolderInfersBrowseGenres",
                label, makeStore, scenarioMovieFamilyFolderInfersBrowseGenres))
            results.append(await runScenario("offlineVolumeFallsBackToSnapshot",
                label, makeStore, scenarioOfflineVolumeFallback))
            results.append(await runScenario("outOfRootRowFiltered",
                label, makeStore, scenarioOutOfRootRowFiltered))
            results.append(await runScenario("watchStateAttachActiveProgress",
                label, makeStore, scenarioWatchStateActive))
            results.append(await runScenario("watchStateAttachCompleted",
                label, makeStore, scenarioWatchStateCompleted))
            results.append(await runScenario("watchStateAttachUnknownPathCleared",
                label, makeStore, scenarioWatchStateCleared))
            results.append(await runScenario("projectionEmitsTMDBFromCatalog",
                label, makeStore, scenarioProjectionEmitsTMDBFromCatalog))
            results.append(await runScenario("projectionFallsBackToFilenameWhenEnrichmentAbsent",
                label, makeStore, scenarioProjectionFallsBackToFilenameWhenEnrichmentAbsent))
            results.append(await runScenario("projectionSidecarVsTMDBArtworkSplit",
                label, makeStore, scenarioProjectionSidecarVsTMDBArtworkSplit))
            results.append(await runScenario("projectionSidecarVisibleWithoutEnrichment",
                label, makeStore, scenarioProjectionSidecarVisibleWithoutEnrichment))
            results.append(await runScenario("projectionEpisodeReadsShowAndEpisodeArtwork",
                label, makeStore, scenarioProjectionEpisodeReadsShowAndEpisodeArtwork))
            results.append(await runScenario("projectionEpisodeStillSidecarWinsInRows",
                label, makeStore, scenarioProjectionEpisodeStillSidecarWinsInRows))
            results.append(await runScenario("projectionLocalEpisodeTitleWinsOverMismatchedTMDB",
                label, makeStore, scenarioProjectionLocalEpisodeTitleWinsOverMismatchedTMDB))
            results.append(await runScenario("projectionEpisodeMetadataParityWithScanner",
                label, makeStore, scenarioProjectionEpisodeMetadataParityWithScanner))
        }
        results.append(scenarioLocalGenreMaturityFallback())
        results.append(scenarioKidsProfileAllowsFamilyLocalGenre())
        results.append(scenarioAnimationAloneIsNotKidsSafe())
        results.append(scenarioOfflineTVGenreTitleNormalization())
        results.append(scenarioDisplayGenresPrefersMetadata())
        results.append(scenarioGenericFamilyMetadataMergesLocalGenreVariety())
        results.append(scenarioExternalDataDirectoryConfiguration())

        let allPassed = results.allSatisfy { $0.passed }
        for r in results {
            let mark = r.passed ? "PASS" : "FAIL"
            let line = "verify-projection: \(mark) \(r.scenario): \(r.detail)\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
        let summary = "verify-projection: outcome=\(allPassed ? "verified" : "failed")"
            + " passed=\(results.filter { $0.passed }.count)/\(results.count)\n"
        FileHandle.standardError.write(Data(summary.utf8))

        let report = Report(
            timestamp: Date(),
            outcome: allPassed ? "verified" : "failed",
            passed: results.filter { $0.passed }.count,
            total: results.count,
            scenarios: results
        )
        try writeReport(report)

        return allPassed ? 0 : 1
    }

    // MARK: - Store factories

    private struct StoreHandle {
        let store: any CatalogStore
        let cleanup: () -> Void
    }

    private static func storeFactories() -> [(label: String, make: (String) throws -> StoreHandle)] {
        return [
            ("memory", makeInMemoryStoreHandle),
            ("sqlite", makeSQLiteStoreHandle)
        ]
    }

    private static func makeInMemoryStoreHandle(scenario: String) -> StoreHandle {
        StoreHandle(store: InMemoryCatalogStore(), cleanup: {})
    }

    private static func makeSQLiteStoreHandle(scenario: String) throws -> StoreHandle {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "verify-projection-\(scenario)-\(UUID().uuidString).sqlite"
            )
        let store = try SQLiteCatalogStore(path: dbURL.path)
        return StoreHandle(
            store: store,
            cleanup: {
                try? FileManager.default.removeItem(at: dbURL)
                let wal = URL(fileURLWithPath: dbURL.path + "-wal")
                let shm = URL(fileURLWithPath: dbURL.path + "-shm")
                try? FileManager.default.removeItem(at: wal)
                try? FileManager.default.removeItem(at: shm)
            }
        )
    }

    private static func runScenario(
        _ base: String,
        _ label: String,
        _ makeStore: (String) throws -> StoreHandle,
        _ body: (String, any CatalogStore) async -> ScenarioResult
    ) async -> ScenarioResult {
        let scenarioName = "\(base).\(label)"
        let handle: StoreHandle
        do {
            handle = try makeStore(base)
        } catch {
            return .init(scenario: scenarioName, passed: false,
                         detail: "store init: \(error)")
        }
        let raw = await body(base, handle.store)
        handle.cleanup()
        return .init(scenario: scenarioName, passed: raw.passed,
                     detail: raw.detail)
    }

    // MARK: - Fixture builder

    private struct Fixture {
        let rootURL: URL
        let registry: InMemoryVolumeRegistry
        let volumeUUID: String

        func cleanup() {
            try? FileManager.default.removeItem(at: rootURL)
        }

        func absolutePath(for relative: String) -> String {
            (rootURL.path as NSString).appendingPathComponent(relative)
        }

        /// Construct a `CatalogMediaFile` row whose `volumeUUID +
        /// relativePath` resolve under this fixture's mount.
        func makeRow(
            relativePath: String,
            fileSize: Int64 = 1024,
            modificationDate: Date? = Date(timeIntervalSince1970: 1_700_000_000),
            durationSeconds: TimeInterval? = 5400
        ) -> CatalogMediaFile {
            let id = MediaIdentity.mediaFileID(
                volumeUUID: volumeUUID,
                relativePath: relativePath
            )
            let absolute = absolutePath(for: relativePath)
            let ext = ((relativePath as NSString).pathExtension as NSString)
                .lowercased
            return CatalogMediaFile(
                id: id,
                volumeUUID: volumeUUID,
                relativePath: relativePath,
                absolutePathSnapshot: absolute,
                fileExtension: ext,
                fileSize: fileSize,
                modificationDate: modificationDate,
                durationSeconds: durationSeconds,
                contentHash: nil,
                dateAdded: Date(timeIntervalSince1970: 1_700_000_000)
            )
        }
    }

    private static func makeFixture(
        scenario: String,
        canonicalRoot: Bool = false
    ) throws -> Fixture {
        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "verify-projection-\(scenario)-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: raw, withIntermediateDirectories: true
        )
        // Most scenarios run with the standardized (un-resolved) path
        // because they only exercise the projection side, which is
        // internally consistent. The scanner/projection parity scenario
        // opts in to `canonicalRoot: true` so the fixture root matches
        // the form `FileManager.enumerator(at:)` emits — macOS resolves
        // `/var/folders/...` → `/private/var/folders/...` on enumerator
        // output, mirroring how production NSOpenPanel paths arrive
        // already canonical. We can't use `URL.resolvingSymlinksInPath()`
        // (does not resolve `/var`) or `NSString.resolvingSymlinksInPath`
        // (also standardizes, which strips `/private/`). Use realpath(3)
        // directly when canonicalization is requested.
        let rootURL: URL
        if canonicalRoot {
            rootURL = URL(
                fileURLWithPath: canonicalizePath(raw.path),
                isDirectory: true
            )
        } else {
            rootURL = URL(
                fileURLWithPath: (raw.path as NSString).standardizingPath,
                isDirectory: true
            )
        }
        let uuid = "22222222-2222-2222-2222-\(stableSuffix(for: scenario))"
        let descriptor = VolumeDescriptor(
            uuid: uuid,
            mountPath: rootURL.path,
            label: "verify-projection-\(scenario)",
            isRemovable: false,
            isNetwork: false
        )
        let registry = InMemoryVolumeRegistry(seed: [descriptor])
        return Fixture(
            rootURL: rootURL,
            registry: registry,
            volumeUUID: descriptor.uuid
        )
    }

    private static func stableSuffix(for s: String) -> String {
        let hex = MediaIdentity.shortHash(s)
        let padded = (hex + String(repeating: "0", count: 12)).prefix(12)
        return String(padded)
    }

    /// Canonicalize a path via realpath(3). Resolves the macOS
    /// `/var` → `/private/var` symlink so two paths that point to
    /// the same on-disk file compare equal as strings. Falls back
    /// to the input path if realpath fails (e.g. file removed
    /// mid-test). Used only by the scanner/projection parity
    /// scenario; production paths come from NSOpenPanel and are
    /// already canonical.
    private static func canonicalizePath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func writeFile(
        at absolutePath: String,
        bytes: Int = 16
    ) throws {
        let url = URL(fileURLWithPath: absolutePath)
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent, withIntermediateDirectories: true
        )
        try Data(repeating: 0xab, count: bytes).write(to: url, options: .atomic)
    }

    // MARK: - Scenarios

    private static func scenarioEmptyCatalog(
        scenario: String,
        store: any CatalogStore
    ) async -> ScenarioResult {
        do {
            let fx = try makeFixture(scenario: scenario)
            defer { fx.cleanup() }

            let projection = DefaultCatalogProjection(
                catalog: store,
                volumes: fx.registry,
                libraryRoots: [fx.rootURL.path]
            )
            let items = try await projection.projectMediaItems()
            guard items.isEmpty else {
                return .init(scenario: scenario, passed: false,
                             detail: "expected empty, got \(items.count) items")
            }
            return .init(scenario: scenario, passed: true,
                         detail: "0 rows → 0 items")
        } catch {
            return .init(scenario: scenario, passed: false,
                         detail: "threw: \(error)")
        }
    }

    private static func scenarioMovieRow(
        scenario: String,
        store: any CatalogStore
    ) async -> ScenarioResult {
        do {
            let fx = try makeFixture(scenario: scenario)
            defer { fx.cleanup() }

            let rel = "Inception (2010)/Inception (2010).mkv"
            let absolute = fx.absolutePath(for: rel)
            try writeFile(at: absolute)

            let row = fx.makeRow(relativePath: rel, durationSeconds: 8880)
            try await store.upsert(mediaFile: row)

            let projection = DefaultCatalogProjection(
                catalog: store,
                volumes: fx.registry,
                libraryRoots: [fx.rootURL.path]
            )
            let items = try await projection.projectMediaItems()

            guard items.count == 1 else {
                return .init(scenario: scenario, passed: false,
                             detail: "expected 1 item, got \(items.count)")
            }
            let item = items[0]
            guard item.title == "Inception" else {
                return .init(scenario: scenario, passed: false,
                             detail: "title=\(item.title) want=Inception")
            }
            guard item.year == 2010 else {
                return .init(scenario: scenario, passed: false,
                             detail: "year=\(String(describing: item.year)) want=2010")
            }
            guard item.duration == 8880 else {
                return .init(scenario: scenario, passed: false,
                             detail: "duration=\(String(describing: item.duration)) want=8880")
            }
            guard item.filePath == absolute else {
                return .init(scenario: scenario, passed: false,
                             detail: "filePath=\(item.filePath) want=\(absolute)")
            }
            return .init(scenario: scenario, passed: true,
                         detail: "movie row → MediaItem(title=Inception, year=2010, dur=8880)")
        } catch {
            return .init(scenario: scenario, passed: false,
                         detail: "threw: \(error)")
        }
    }

    private static func scenarioMovieRowSidecars(
        scenario: String,
        store: any CatalogStore
    ) async -> ScenarioResult {
        do {
            let fx = try makeFixture(scenario: scenario)
            defer { fx.cleanup() }

            let rel = "Tron (1982)/Tron (1982).mkv"
            try writeFile(at: fx.absolutePath(for: rel))
            let posterAbs = (fx.absolutePath(for: "Tron (1982)") as NSString)
                .appendingPathComponent("poster.jpg")
            try writeFile(at: posterAbs, bytes: 8)
            let fanartAbs = (fx.absolutePath(for: "Tron (1982)") as NSString)
                .appendingPathComponent("fanart.jpg")
            try writeFile(at: fanartAbs, bytes: 8)

            try await store.upsert(mediaFile: fx.makeRow(relativePath: rel))

            let projection = DefaultCatalogProjection(
                catalog: store,
                volumes: fx.registry,
                libraryRoots: [fx.rootURL.path]
            )
            let items = try await projection.projectMediaItems()

            guard items.count == 1, let item = items.first else {
                return .init(scenario: scenario, passed: false,
                             detail: "expected 1 item, got \(items.count)")
            }
            guard item.posterImagePath == posterAbs else {
                return .init(scenario: scenario, passed: false,
                             detail: "posterImagePath=\(String(describing: item.posterImagePath))")
            }
            guard item.backdropImagePath == fanartAbs else {
                return .init(scenario: scenario, passed: false,
                             detail: "backdropImagePath=\(String(describing: item.backdropImagePath))")
            }
            return .init(scenario: scenario, passed: true,
                         detail: "sidecar poster + fanart resolved")
        } catch {
            return .init(scenario: scenario, passed: false,
                         detail: "threw: \(error)")
        }
    }

    private static func scenarioTVEpisodeRow(
        scenario: String,
        store: any CatalogStore
    ) async -> ScenarioResult {
        do {
            let fx = try makeFixture(scenario: scenario)
            defer { fx.cleanup() }

            let rel = "The Wire/Season 1/The Wire - s01e01 - The Target.mkv"
            try writeFile(at: fx.absolutePath(for: rel))
            try await store.upsert(mediaFile: fx.makeRow(relativePath: rel))

            let projection = DefaultCatalogProjection(
                catalog: store,
                volumes: fx.registry,
                libraryRoots: [fx.rootURL.path]
            )
            let items = try await projection.projectMediaItems()

            guard items.count == 1, let item = items.first else {
                return .init(scenario: scenario, passed: false,
                             detail: "expected 1 item, got \(items.count)")
            }
            guard item.showName == "The Wire" else {
                return .init(scenario: scenario, passed: false,
                             detail: "showName=\(String(describing: item.showName))")
            }
            guard item.seasonNumber == 1 else {
                return .init(scenario: scenario, passed: false,
                             detail: "seasonNumber=\(String(describing: item.seasonNumber))")
            }
            guard item.episodeNumber == 1 else {
                return .init(scenario: scenario, passed: false,
                             detail: "episodeNumber=\(String(describing: item.episodeNumber))")
            }
            guard item.episodeTitle == "The Target" else {
                return .init(scenario: scenario, passed: false,
                             detail: "episodeTitle=\(String(describing: item.episodeTitle))")
            }
            return .init(scenario: scenario, passed: true,
                         detail: "TV row → s01e01 The Target")
        } catch {
            return .init(scenario: scenario, passed: false,
                         detail: "threw: \(error)")
        }
    }

    private static func scenarioTVEpisodeInfersOfflineShowGenres(
        scenario: String,
        store: any CatalogStore
    ) async -> ScenarioResult {
        do {
            let fx = try makeFixture(scenario: scenario)
            defer { fx.cleanup() }

            let rel = "Bluey (2018)/Season 1/Bluey - s01e01 - Magic Xylophone.mkv"
            try writeFile(at: fx.absolutePath(for: rel))
            try await store.upsert(mediaFile: fx.makeRow(relativePath: rel))

            let projection = DefaultCatalogProjection(
                catalog: store,
                volumes: fx.registry,
                libraryRoots: [fx.rootURL.path]
            )
            let items = try await projection.projectMediaItems()

            guard items.count == 1, let item = items.first else {
                return .init(scenario: scenario, passed: false,
                             detail: "expected 1 item, got \(items.count)")
            }
            let genres = Set(item.displayGenres)
            guard genres.isSuperset(of: ["Kids", "Animation", "Family"]) else {
                return .init(scenario: scenario, passed: false,
                             detail: "displayGenres=\(item.displayGenres)")
            }
            return .init(scenario: scenario, passed: true,
                         detail: "offline TV folder Bluey → Kids/Animation/Family genres")
        } catch {
            return .init(scenario: scenario, passed: false,
                         detail: "threw: \(error)")
        }
    }

    private static func scenarioExtrasFolderFiltered(
        scenario: String,
        store: any CatalogStore
    ) async -> ScenarioResult {
        do {
            let fx = try makeFixture(scenario: scenario)
            defer { fx.cleanup() }

            let movieRel = "Heat (1995)/Heat (1995).mkv"
            let extraRel = "Heat (1995)/Featurettes/Behind the scenes.mkv"
            try writeFile(at: fx.absolutePath(for: movieRel))
            try writeFile(at: fx.absolutePath(for: extraRel))
            try await store.upsert(mediaFile: fx.makeRow(relativePath: movieRel))
            try await store.upsert(mediaFile: fx.makeRow(relativePath: extraRel))

            let projection = DefaultCatalogProjection(
                catalog: store,
                volumes: fx.registry,
                libraryRoots: [fx.rootURL.path]
            )
            let items = try await projection.projectMediaItems()

            guard items.count == 1 else {
                return .init(scenario: scenario, passed: false,
                             detail: "expected 1 item, got \(items.count)")
            }
            guard items[0].title == "Heat" else {
                return .init(scenario: scenario, passed: false,
                             detail: "title=\(items[0].title)")
            }
            return .init(scenario: scenario, passed: true,
                         detail: "Featurettes/ row filtered, movie kept")
        } catch {
            return .init(scenario: scenario, passed: false,
                         detail: "threw: \(error)")
        }
    }

    private static func scenarioGenreInferred(
        scenario: String,
        store: any CatalogStore
    ) async -> ScenarioResult {
        do {
            let fx = try makeFixture(scenario: scenario)
            defer { fx.cleanup() }

            let rel = "Action/Die Hard (1988)/Die Hard (1988).mkv"
            try writeFile(at: fx.absolutePath(for: rel))
            try await store.upsert(mediaFile: fx.makeRow(relativePath: rel))

            let projection = DefaultCatalogProjection(
                catalog: store,
                volumes: fx.registry,
                libraryRoots: [fx.rootURL.path]
            )
            let items = try await projection.projectMediaItems()

            guard items.count == 1, let item = items.first else {
                return .init(scenario: scenario, passed: false,
                             detail: "expected 1 item, got \(items.count)")
            }
            guard item.genre == "Action" else {
                return .init(scenario: scenario, passed: false,
                             detail: "genre=\(String(describing: item.genre)) want=Action")
            }
            return .init(scenario: scenario, passed: true,
                         detail: "first subfolder Action → genre=Action")
        } catch {
            return .init(scenario: scenario, passed: false,
                         detail: "threw: \(error)")
        }
    }

    private static func scenarioMovieFamilyFolderInfersBrowseGenres(
        scenario: String,
        store: any CatalogStore
    ) async -> ScenarioResult {
        do {
            let fx = try makeFixture(scenario: scenario)
            defer { fx.cleanup() }

            let rel = "Family/Inside Out (2015)/Inside Out (2015).mkv"
            try writeFile(at: fx.absolutePath(for: rel))
            try await store.upsert(mediaFile: fx.makeRow(relativePath: rel))

            let projection = DefaultCatalogProjection(
                catalog: store,
                volumes: fx.registry,
                libraryRoots: [fx.rootURL.path]
            )
            let items = try await projection.projectMediaItems()

            guard items.count == 1, let item = items.first else {
                return .init(scenario: scenario, passed: false,
                             detail: "expected 1 item, got \(items.count)")
            }
            let genres = Set(item.displayGenres)
            guard genres.isSuperset(of: ["Family", "Animation"]) else {
                return .init(scenario: scenario, passed: false,
                             detail: "displayGenres=\(item.displayGenres)")
            }
            return .init(scenario: scenario, passed: true,
                         detail: "Family movie folder yields richer browse genres")
        } catch {
            return .init(scenario: scenario, passed: false,
                         detail: "threw: \(error)")
        }
    }

    private static func scenarioOfflineVolumeFallback(
        scenario: String,
        store: any CatalogStore
    ) async -> ScenarioResult {
        do {
            let fx = try makeFixture(scenario: scenario)
            defer { fx.cleanup() }

            // Seed the row with an absolutePathSnapshot under the
            // fixture root, then build a registry that does NOT know
            // about the volume. Projection should fall back to the
            // snapshot path so downstream UI still gets a usable
            // filePath even when the source volume is offline.
            let rel = "OfflineMovie (1999)/OfflineMovie (1999).mkv"
            let snapshotAbs = fx.absolutePath(for: rel)
            try writeFile(at: snapshotAbs)

            let row = fx.makeRow(relativePath: rel)
            try await store.upsert(mediaFile: row)

            let emptyRegistry = InMemoryVolumeRegistry(seed: [])
            let projection = DefaultCatalogProjection(
                catalog: store,
                volumes: emptyRegistry,
                libraryRoots: [fx.rootURL.path]
            )
            let items = try await projection.projectMediaItems()

            guard items.count == 1, let item = items.first else {
                return .init(scenario: scenario, passed: false,
                             detail: "expected 1 item, got \(items.count)")
            }
            guard item.filePath == snapshotAbs else {
                return .init(scenario: scenario, passed: false,
                             detail: "filePath=\(item.filePath) want snapshot=\(snapshotAbs)")
            }
            return .init(scenario: scenario, passed: true,
                         detail: "offline volume → snapshot filePath used")
        } catch {
            return .init(scenario: scenario, passed: false,
                         detail: "threw: \(error)")
        }
    }

    /// Boundary case for the library-root scope: the catalog can hold
    /// rows from volumes/roots the user has since removed from
    /// settings (or from legacy imports that predate the current
    /// configured roots). Projection must drop those — otherwise a
    /// future UI flip resurrects stale items. Seeds two rows: one
    /// under the configured library root, one under a second volume
    /// the harness mounts but does NOT pass to `libraryRoots`. Asserts
    /// only the in-root row survives.
    private static func scenarioOutOfRootRowFiltered(
        scenario: String,
        store: any CatalogStore
    ) async -> ScenarioResult {
        do {
            let inRoot = try makeFixture(scenario: "\(scenario)-in")
            defer { inRoot.cleanup() }
            let outOfRoot = try makeFixture(scenario: "\(scenario)-out")
            defer { outOfRoot.cleanup() }

            let inRel = "InRoot (2010)/InRoot (2010).mkv"
            let outRel = "OutOfRoot (2011)/OutOfRoot (2011).mkv"
            try writeFile(at: inRoot.absolutePath(for: inRel))
            try writeFile(at: outOfRoot.absolutePath(for: outRel))

            try await store.upsert(mediaFile: inRoot.makeRow(relativePath: inRel))
            try await store.upsert(mediaFile: outOfRoot.makeRow(relativePath: outRel))

            // Combined registry knows about BOTH volumes so the
            // projection's path resolution succeeds for both rows; the
            // filter must rely on `libraryRoots`, not on the registry
            // knowing nothing about the second volume.
            let combined = await mergedRegistry(
                inRoot.registry, outOfRoot.registry
            )
            // Pass ONLY the in-root mount as a configured library root.
            let projection = DefaultCatalogProjection(
                catalog: store,
                volumes: combined,
                libraryRoots: [inRoot.rootURL.path]
            )
            let items = try await projection.projectMediaItems()

            guard items.count == 1, let item = items.first else {
                return .init(scenario: scenario, passed: false,
                             detail: "expected 1 item (in-root only), got \(items.count)")
            }
            guard item.title == "InRoot" else {
                return .init(scenario: scenario, passed: false,
                             detail: "wrong row survived: title=\(item.title)")
            }
            return .init(scenario: scenario, passed: true,
                         detail: "out-of-root row filtered, in-root row kept")
        } catch {
            return .init(scenario: scenario, passed: false,
                         detail: "threw: \(error)")
        }
    }

    /// Combines two `InMemoryVolumeRegistry` seeds into one registry
    /// covering both volumes. The projection only needs `mountedVolumes`
    /// behavior, so a fresh `InMemoryVolumeRegistry` reseeded with both
    /// descriptors is sufficient.
    private static func mergedRegistry(
        _ a: InMemoryVolumeRegistry,
        _ b: InMemoryVolumeRegistry
    ) async -> InMemoryVolumeRegistry {
        let aVols = await a.mountedVolumes()
        let bVols = await b.mountedVolumes()
        return InMemoryVolumeRegistry(seed: aVols + bVols)
    }

    // MARK: - Watch-state scenarios

    private static func makeWatchStore(profileTag: String) -> (UUID, WatchProgressStore) {
        // Stable-per-tag UUID so reruns reuse and clobber the same JSON
        // file rather than leaking new files across runs. We still call
        // clearAll() at the end of each scenario.
        let raw = MediaIdentity.shortHash("verify-projection-\(profileTag)")
        let padded = (raw + String(repeating: "0", count: 32)).prefix(32)
        let s = String(padded)
        let uuidString = "\(s.prefix(8))-\(s.dropFirst(8).prefix(4))-\(s.dropFirst(12).prefix(4))-\(s.dropFirst(16).prefix(4))-\(s.dropFirst(20).prefix(12))"
        let uuid = UUID(uuidString: uuidString.uppercased()) ?? UUID()
        return (uuid, WatchProgressStore.forProfile(uuid))
    }

    private static func scenarioWatchStateActive(
        scenario: String,
        store: any CatalogStore
    ) async -> ScenarioResult {
        do {
            let fx = try makeFixture(scenario: scenario)
            defer { fx.cleanup() }

            let rel = "Active (2001)/Active (2001).mkv"
            let abs = fx.absolutePath(for: rel)
            try writeFile(at: abs)
            try await store.upsert(mediaFile: fx.makeRow(relativePath: rel))

            let projection = DefaultCatalogProjection(
                catalog: store,
                volumes: fx.registry,
                libraryRoots: [fx.rootURL.path]
            )
            let items = try await projection.projectMediaItems()

            // Pre-attach assertion: projection must emit default watch
            // state so attach is a real change, not a silent passthrough.
            guard items.count == 1, items[0].playbackPosition == 0,
                  items[0].lastPlayedDate == nil, !items[0].isWatched else {
                return .init(scenario: scenario, passed: false,
                             detail: "default watch state not zero")
            }

            let (_, watchStore) = makeWatchStore(profileTag: scenario)
            defer { watchStore.clearAll() }
            // Active progress: position >= 120 and fraction <= 0.93.
            watchStore.save(filePath: abs, position: 300, duration: 1000)

            DefaultCatalogProjection.attachWatchState(
                items: items, from: watchStore
            )
            let item = items[0]
            guard item.playbackPosition == 300, item.lastPlayedDate != nil,
                  !item.isWatched else {
                return .init(scenario: scenario, passed: false,
                             detail: "active state not applied: pos=\(item.playbackPosition) watched=\(item.isWatched)")
            }
            return .init(scenario: scenario, passed: true,
                         detail: "active progress 300/1000 attached")
        } catch {
            return .init(scenario: scenario, passed: false,
                         detail: "threw: \(error)")
        }
    }

    private static func scenarioWatchStateCompleted(
        scenario: String,
        store: any CatalogStore
    ) async -> ScenarioResult {
        do {
            let fx = try makeFixture(scenario: scenario)
            defer { fx.cleanup() }

            let rel = "Completed (2002)/Completed (2002).mkv"
            let abs = fx.absolutePath(for: rel)
            try writeFile(at: abs)
            try await store.upsert(mediaFile: fx.makeRow(relativePath: rel))

            let projection = DefaultCatalogProjection(
                catalog: store,
                volumes: fx.registry,
                libraryRoots: [fx.rootURL.path]
            )
            let items = try await projection.projectMediaItems()

            let (_, watchStore) = makeWatchStore(profileTag: scenario)
            defer { watchStore.clearAll() }
            // Completed: fraction > 0.93 routes to completedEntries.
            watchStore.save(filePath: abs, position: 970, duration: 1000)

            DefaultCatalogProjection.attachWatchState(
                items: items, from: watchStore
            )
            guard items.count == 1 else {
                return .init(scenario: scenario, passed: false,
                             detail: "expected 1 item, got \(items.count)")
            }
            let item = items[0]
            guard item.isWatched, item.playbackPosition == 0,
                  item.lastPlayedDate != nil else {
                return .init(scenario: scenario, passed: false,
                             detail: "completed state not applied: watched=\(item.isWatched) pos=\(item.playbackPosition)")
            }
            return .init(scenario: scenario, passed: true,
                         detail: "completed 970/1000 → isWatched=true pos=0")
        } catch {
            return .init(scenario: scenario, passed: false,
                         detail: "threw: \(error)")
        }
    }

    private static func scenarioWatchStateCleared(
        scenario: String,
        store: any CatalogStore
    ) async -> ScenarioResult {
        do {
            let fx = try makeFixture(scenario: scenario)
            defer { fx.cleanup() }

            let rel = "Cleared (2003)/Cleared (2003).mkv"
            let abs = fx.absolutePath(for: rel)
            try writeFile(at: abs)
            try await store.upsert(mediaFile: fx.makeRow(relativePath: rel))

            let projection = DefaultCatalogProjection(
                catalog: store,
                volumes: fx.registry,
                libraryRoots: [fx.rootURL.path]
            )
            let items = try await projection.projectMediaItems()

            // Pre-poison so attach has something to clear.
            items[0].playbackPosition = 999
            items[0].lastPlayedDate = Date(timeIntervalSince1970: 1)
            items[0].isWatched = true

            let (_, watchStore) = makeWatchStore(profileTag: scenario)
            defer { watchStore.clearAll() }
            // No save() — store has no entry for this path.

            DefaultCatalogProjection.attachWatchState(
                items: items, from: watchStore
            )
            let item = items[0]
            guard item.playbackPosition == 0, item.lastPlayedDate == nil,
                  !item.isWatched else {
                return .init(scenario: scenario, passed: false,
                             detail: "uncleared: pos=\(item.playbackPosition) watched=\(item.isWatched)")
            }
            return .init(scenario: scenario, passed: true,
                         detail: "missing entry → fields cleared to defaults")
        } catch {
            return .init(scenario: scenario, passed: false,
                         detail: "threw: \(error)")
        }
    }


    // MARK: - 2E.4b enrichment-snapshot read scenarios

    /// Phase 2E.4b core: projection must read the catalog enrichment
    /// snapshot and graft TMDB fields onto its emitted `MediaItem`s. Seeds
    /// a single movie row plus a `replaceEnrichment` call carrying core +
    /// one cast entry + a poster + a backdrop. Asserts every grafted
    /// field — title overrides filename, tmdbID, contentRating,
    /// thumb*Path (= artwork.localPath), and metadata reconstruction
    /// (cast ordering + remoteURL passthrough).
    private static func scenarioProjectionEmitsTMDBFromCatalog(
        scenario: String,
        store: any CatalogStore
    ) async -> ScenarioResult {
        do {
            let fx = try makeFixture(scenario: scenario)
            defer { fx.cleanup() }

            let rel = "matrix.1999.dvdrip.mkv"
            try writeFile(at: fx.absolutePath(for: rel))
            let row = fx.makeRow(relativePath: rel)
            try await store.upsert(mediaFile: row)

            let movieID = MediaIdentity.movieID(primaryFile: row.id)
            let owner = ArtworkOwner.movie(movieID)
            let movie = CatalogMovie(
                id: movieID,
                primaryFile: row.id,
                title: "The Matrix",
                year: 1999,
                tmdbID: 603,
                overview: "A hacker discovers reality is a simulation.",
                runtimeMinutes: 136,
                certification: "R",
                releaseDate: "1999-03-31",
                genres: ["Action", "Science Fiction"],
                voteAverage: 8.2,
                director: "Lana Wachowski"
            )
            let cast = [
                CatalogCastEntry(
                    personTMDBID: 6384,
                    name: "Keanu Reeves",
                    profilePath: "/keanu.jpg",
                    character: "Neo",
                    ordinal: 0
                )
            ]
            let posterArtwork = CatalogArtworkAsset(
                id: MediaIdentity.artworkID(owner: owner, kind: .poster, sourceLabel: "tmdb"),
                owner: owner,
                kind: .poster,
                localPath: "/cache/matrix-poster.jpg",
                remoteURL: "https://image.tmdb.org/t/p/w500/matrix.jpg",
                sourceLabel: "tmdb"
            )
            let backdropArtwork = CatalogArtworkAsset(
                id: MediaIdentity.artworkID(owner: owner, kind: .backdrop, sourceLabel: "tmdb"),
                owner: owner,
                kind: .backdrop,
                localPath: "/cache/matrix-backdrop.jpg",
                remoteURL: "https://image.tmdb.org/t/p/w1280/matrix-bg.jpg",
                sourceLabel: "tmdb"
            )
            try await store.replaceEnrichment(
                owner: owner,
                core: .movie(movie),
                cast: cast,
                artwork: [posterArtwork, backdropArtwork]
            )

            let projection = DefaultCatalogProjection(
                catalog: store,
                volumes: fx.registry,
                libraryRoots: [fx.rootURL.path]
            )
            let items = try await projection.projectMediaItems()
            guard items.count == 1, let item = items.first else {
                return .init(scenario: scenario, passed: false,
                             detail: "expected 1 item, got \(items.count)")
            }
            if item.title != "The Matrix" {
                return .init(scenario: scenario, passed: false,
                             detail: "title=\(item.title) want=The Matrix (filename would yield 'matrix')")
            }
            if item.year != 1999 {
                return .init(scenario: scenario, passed: false,
                             detail: "year=\(String(describing: item.year)) want=1999")
            }
            if item.tmdbID != 603 {
                return .init(scenario: scenario, passed: false,
                             detail: "tmdbID=\(String(describing: item.tmdbID)) want=603")
            }
            if item.contentRating != "R" {
                return .init(scenario: scenario, passed: false,
                             detail: "contentRating=\(String(describing: item.contentRating)) want=R")
            }
            if item.thumbPosterPath != "/cache/matrix-poster.jpg" {
                return .init(scenario: scenario, passed: false,
                             detail: "thumbPosterPath=\(String(describing: item.thumbPosterPath))")
            }
            if item.thumbBackdropPath != "/cache/matrix-backdrop.jpg" {
                return .init(scenario: scenario, passed: false,
                             detail: "thumbBackdropPath=\(String(describing: item.thumbBackdropPath))")
            }
            guard let meta = item.metadata else {
                return .init(scenario: scenario, passed: false,
                             detail: "metadata missing")
            }
            if meta.tmdbID != 603 || meta.director != "Lana Wachowski"
                || meta.voteAverage != 8.2 || meta.runtime != 136
                || meta.certification != "R" || meta.releaseDate != "1999-03-31"
                || meta.genres != ["Action", "Science Fiction"]
                || meta.posterPath != "https://image.tmdb.org/t/p/w500/matrix.jpg"
                || meta.backdropPath != "https://image.tmdb.org/t/p/w1280/matrix-bg.jpg" {
                return .init(scenario: scenario, passed: false,
                             detail: "metadata field drift: \(meta)")
            }
            guard meta.cast.count == 1, meta.cast[0].name == "Keanu Reeves",
                  meta.cast[0].character == "Neo",
                  meta.cast[0].tmdbPersonID == 6384,
                  meta.cast[0].profilePath == "/keanu.jpg" else {
                return .init(scenario: scenario, passed: false,
                             detail: "cast drift: \(meta.cast)")
            }
            return .init(scenario: scenario, passed: true,
                         detail: "movie row + replaceEnrichment → MediaItem grafted with TMDB fields + cast + remote URLs")
        } catch {
            return .init(scenario: scenario, passed: false,
                         detail: "threw: \(error)")
        }
    }

    /// Boundary: catalog row with no enrichment → projection must still
    /// emit a usable item from filename-derived defaults so a partially-
    /// populated catalog (mid-scan, before TMDBEnrichmentService runs)
    /// doesn't blank out the UI.
    private static func scenarioProjectionFallsBackToFilenameWhenEnrichmentAbsent(
        scenario: String,
        store: any CatalogStore
    ) async -> ScenarioResult {
        do {
            let fx = try makeFixture(scenario: scenario)
            defer { fx.cleanup() }

            let rel = "Inception (2010)/Inception (2010).mkv"
            try writeFile(at: fx.absolutePath(for: rel))
            try await store.upsert(mediaFile: fx.makeRow(relativePath: rel))

            let projection = DefaultCatalogProjection(
                catalog: store,
                volumes: fx.registry,
                libraryRoots: [fx.rootURL.path]
            )
            let items = try await projection.projectMediaItems()
            guard items.count == 1, let item = items.first else {
                return .init(scenario: scenario, passed: false,
                             detail: "expected 1 item, got \(items.count)")
            }
            if item.title != "Inception" || item.year != 2010 {
                return .init(scenario: scenario, passed: false,
                             detail: "filename fallback wrong: title=\(item.title) year=\(String(describing: item.year))")
            }
            if item.tmdbID != nil || item.contentRating != nil || item.metadata != nil {
                return .init(scenario: scenario, passed: false,
                             detail: "expected nil enrichment, got tmdbID=\(String(describing: item.tmdbID))")
            }
            if item.thumbPosterPath != nil || item.thumbBackdropPath != nil {
                return .init(scenario: scenario, passed: false,
                             detail: "expected nil thumb paths without enrichment")
            }
            return .init(scenario: scenario, passed: true,
                         detail: "no enrichment → filename-derived item, all TMDB fields nil")
        } catch {
            return .init(scenario: scenario, passed: false,
                         detail: "threw: \(error)")
        }
    }

    /// Sidecar vs TMDB artwork separation. With both a `poster.jpg`
    /// sidecar AND a `replaceEnrichment` poster row, the projection must
    /// land sidecar bytes on `posterImagePath` (authoritative per
    /// `feedback_local_artwork_over_tmdb`) AND TMDB bytes on
    /// `thumbPosterPath` (the secondary "downloaded poster" slot the UI
    /// uses when a sidecar is unavailable). They live in separate fields;
    /// neither overwrites the other.
    private static func scenarioProjectionSidecarVsTMDBArtworkSplit(
        scenario: String,
        store: any CatalogStore
    ) async -> ScenarioResult {
        do {
            let fx = try makeFixture(scenario: scenario)
            defer { fx.cleanup() }

            let rel = "Tron (1982)/Tron (1982).mkv"
            try writeFile(at: fx.absolutePath(for: rel))
            let sidecarAbs = (fx.absolutePath(for: "Tron (1982)") as NSString)
                .appendingPathComponent("poster.jpg")
            try writeFile(at: sidecarAbs, bytes: 8)
            let row = fx.makeRow(relativePath: rel)
            try await store.upsert(mediaFile: row)

            let movieID = MediaIdentity.movieID(primaryFile: row.id)
            let owner = ArtworkOwner.movie(movieID)
            let movie = CatalogMovie(
                id: movieID,
                primaryFile: row.id,
                title: "Tron",
                year: 1982,
                tmdbID: 97,
                overview: nil,
                runtimeMinutes: nil,
                certification: nil,
                releaseDate: nil,
                genres: [],
                voteAverage: nil,
                director: nil
            )
            let tmdbPoster = CatalogArtworkAsset(
                id: MediaIdentity.artworkID(owner: owner, kind: .poster, sourceLabel: "tmdb"),
                owner: owner,
                kind: .poster,
                localPath: "/cache/tron-tmdb.jpg",
                remoteURL: "https://image.tmdb.org/t/p/w500/tron.jpg",
                sourceLabel: "tmdb"
            )
            try await store.replaceEnrichment(
                owner: owner,
                core: .movie(movie),
                cast: [],
                artwork: [tmdbPoster]
            )

            let projection = DefaultCatalogProjection(
                catalog: store,
                volumes: fx.registry,
                libraryRoots: [fx.rootURL.path]
            )
            let items = try await projection.projectMediaItems()
            guard items.count == 1, let item = items.first else {
                return .init(scenario: scenario, passed: false,
                             detail: "expected 1 item, got \(items.count)")
            }
            if item.posterImagePath != sidecarAbs {
                return .init(scenario: scenario, passed: false,
                             detail: "posterImagePath=\(String(describing: item.posterImagePath)) want sidecar=\(sidecarAbs)")
            }
            if item.thumbPosterPath != "/cache/tron-tmdb.jpg" {
                return .init(scenario: scenario, passed: false,
                             detail: "thumbPosterPath=\(String(describing: item.thumbPosterPath)) want=/cache/tron-tmdb.jpg")
            }
            return .init(scenario: scenario, passed: true,
                         detail: "sidecar → posterImagePath; TMDB → thumbPosterPath; no overwrite")
        } catch {
            return .init(scenario: scenario, passed: false,
                         detail: "threw: \(error)")
        }
    }

    /// Sidecar discovery is not gated on enrichment. A movie row with no
    /// `replaceEnrichment` call but a `poster.jpg` next to it must still
    /// surface the sidecar, so the legacy "sidecars-only" workflow keeps
    /// working when the user has not let online metadata run.
    private static func scenarioProjectionSidecarVisibleWithoutEnrichment(
        scenario: String,
        store: any CatalogStore
    ) async -> ScenarioResult {
        do {
            let fx = try makeFixture(scenario: scenario)
            defer { fx.cleanup() }

            let rel = "Blade Runner (1982)/Blade Runner (1982).mkv"
            try writeFile(at: fx.absolutePath(for: rel))
            let sidecarAbs = (fx.absolutePath(for: "Blade Runner (1982)") as NSString)
                .appendingPathComponent("poster.jpg")
            try writeFile(at: sidecarAbs, bytes: 8)
            try await store.upsert(mediaFile: fx.makeRow(relativePath: rel))

            let projection = DefaultCatalogProjection(
                catalog: store,
                volumes: fx.registry,
                libraryRoots: [fx.rootURL.path]
            )
            let items = try await projection.projectMediaItems()
            guard items.count == 1, let item = items.first else {
                return .init(scenario: scenario, passed: false,
                             detail: "expected 1 item, got \(items.count)")
            }
            if item.posterImagePath != sidecarAbs {
                return .init(scenario: scenario, passed: false,
                             detail: "posterImagePath=\(String(describing: item.posterImagePath)) want=\(sidecarAbs)")
            }
            if item.tmdbID != nil || item.thumbPosterPath != nil {
                return .init(scenario: scenario, passed: false,
                             detail: "expected no enrichment, got tmdbID=\(String(describing: item.tmdbID)) thumb=\(String(describing: item.thumbPosterPath))")
            }
            return .init(scenario: scenario, passed: true,
                         detail: "no enrichment + sidecar poster → posterImagePath populated, TMDB fields nil")
        } catch {
            return .init(scenario: scenario, passed: false,
                         detail: "threw: \(error)")
        }
    }

    /// Per-owner artwork separation. Show-level TMDB poster + backdrop
    /// must land on `showThumb*Path`; episode-level TMDB `still` must
    /// land on the episode's `thumbBackdropPath`. Neither bleeds into
    /// the other side. Asserts the projection's owner-keyed lookup is
    /// honoured against the snapshot's polymorphic `artworkByOwner`.
    private static func scenarioProjectionEpisodeReadsShowAndEpisodeArtwork(
        scenario: String,
        store: any CatalogStore
    ) async -> ScenarioResult {
        do {
            let fx = try makeFixture(scenario: scenario)
            defer { fx.cleanup() }

            let rel = "The Wire (2002)/Season 1/The Wire - s01e01 - The Target.mkv"
            try writeFile(at: fx.absolutePath(for: rel))
            let row = fx.makeRow(relativePath: rel)
            try await store.upsert(mediaFile: row)

            let showID = MediaIdentity.showID(title: "The Wire", year: 2002)
            let seasonID = MediaIdentity.seasonID(show: showID, seasonNumber: 1)
            let episodeID = MediaIdentity.episodeID(
                season: seasonID,
                episodeNumber: 1,
                primaryFile: row.id
            )
            let show = CatalogShow(
                id: showID,
                title: "The Wire",
                year: 2002,
                tmdbID: 1438,
                overview: nil,
                certification: nil,
                genres: []
            )
            let showOwner = ArtworkOwner.show(showID)
            let showPoster = CatalogArtworkAsset(
                id: MediaIdentity.artworkID(owner: showOwner, kind: .poster, sourceLabel: "tmdb"),
                owner: showOwner,
                kind: .poster,
                localPath: "/cache/wire-show-poster.jpg",
                remoteURL: nil,
                sourceLabel: "tmdb"
            )
            let showBackdrop = CatalogArtworkAsset(
                id: MediaIdentity.artworkID(owner: showOwner, kind: .backdrop, sourceLabel: "tmdb"),
                owner: showOwner,
                kind: .backdrop,
                localPath: "/cache/wire-show-backdrop.jpg",
                remoteURL: nil,
                sourceLabel: "tmdb"
            )
            try await store.replaceEnrichment(
                owner: showOwner,
                core: .show(show),
                cast: [],
                artwork: [showPoster, showBackdrop]
            )

            let episode = CatalogEpisode(
                id: episodeID,
                seasonID: seasonID,
                primaryFile: row.id,
                episodeNumber: 1,
                title: "The Target",
                overview: nil,
                runtimeMinutes: nil
            )
            let episodeOwner = ArtworkOwner.episode(episodeID)
            let episodeStill = CatalogArtworkAsset(
                id: MediaIdentity.artworkID(owner: episodeOwner, kind: .still, sourceLabel: "tmdb"),
                owner: episodeOwner,
                kind: .still,
                localPath: "/cache/wire-s01e01-still.jpg",
                remoteURL: nil,
                sourceLabel: "tmdb"
            )
            try await store.replaceEnrichment(
                owner: episodeOwner,
                core: .episode(episode),
                cast: [],
                artwork: [episodeStill]
            )

            let projection = DefaultCatalogProjection(
                catalog: store,
                volumes: fx.registry,
                libraryRoots: [fx.rootURL.path]
            )
            let items = try await projection.projectMediaItems()
            guard items.count == 1, let item = items.first else {
                return .init(scenario: scenario, passed: false,
                             detail: "expected 1 item, got \(items.count)")
            }
            if item.showThumbPosterPath != "/cache/wire-show-poster.jpg" {
                return .init(scenario: scenario, passed: false,
                             detail: "showThumbPosterPath=\(String(describing: item.showThumbPosterPath))")
            }
            if item.showThumbBackdropPath != "/cache/wire-show-backdrop.jpg" {
                return .init(scenario: scenario, passed: false,
                             detail: "showThumbBackdropPath=\(String(describing: item.showThumbBackdropPath))")
            }
            if item.thumbBackdropPath != "/cache/wire-s01e01-still.jpg" {
                return .init(scenario: scenario, passed: false,
                             detail: "thumbBackdropPath=\(String(describing: item.thumbBackdropPath))")
            }
            // Per-owner separation: show artwork must NOT bleed into the
            // episode's primary thumb fields, and the episode's still
            // must NOT bleed into showThumb*.
            if item.thumbPosterPath != nil {
                return .init(scenario: scenario, passed: false,
                             detail: "thumbPosterPath leak: \(String(describing: item.thumbPosterPath))")
            }
            return .init(scenario: scenario, passed: true,
                         detail: "show artwork → showThumb*Path; episode still → thumbBackdropPath; no cross-bleed")
        } catch {
            return .init(scenario: scenario, passed: false,
                         detail: "threw: \(error)")
        }
    }

    /// Exact per-episode sidecar stills (for example downloaded YouTube
    /// thumbnails or manually captured screen grabs named like the video)
    /// must be preserved separately from generic season `fanart.jpg`. The
    /// show page row should prefer that exact still over both TMDB stills
    /// and folder-level backdrop art.
    private static func scenarioProjectionEpisodeStillSidecarWinsInRows(
        scenario: String,
        store: any CatalogStore
    ) async -> ScenarioResult {
        do {
            let fx = try makeFixture(scenario: scenario)
            defer { fx.cleanup() }

            let rel = "The Why Files (2020)/Season 1/The Why Files S01E01 - Pilot.mp4"
            try writeFile(at: fx.absolutePath(for: rel))
            let row = fx.makeRow(relativePath: rel)
            try await store.upsert(mediaFile: row)

            let sidecarStill = (fx.absolutePath(for: "The Why Files (2020)/Season 1") as NSString)
                .appendingPathComponent("The Why Files S01E01 - Pilot.jpg")
            let seasonFanart = (fx.absolutePath(for: "The Why Files (2020)/Season 1") as NSString)
                .appendingPathComponent("fanart.jpg")
            try writeFile(at: sidecarStill, bytes: 8)
            try writeFile(at: seasonFanart, bytes: 8)

            let showID = MediaIdentity.showID(title: "The Why Files", year: 2020)
            let seasonID = MediaIdentity.seasonID(show: showID, seasonNumber: 1)
            let episodeID = MediaIdentity.episodeID(
                season: seasonID,
                episodeNumber: 1,
                primaryFile: row.id
            )
            let episode = CatalogEpisode(
                id: episodeID,
                seasonID: seasonID,
                primaryFile: row.id,
                episodeNumber: 1,
                title: "Pilot",
                overview: nil,
                runtimeMinutes: nil
            )
            let episodeOwner = ArtworkOwner.episode(episodeID)
            let tmdbStill = CatalogArtworkAsset(
                id: MediaIdentity.artworkID(owner: episodeOwner, kind: .still, sourceLabel: "tmdb"),
                owner: episodeOwner,
                kind: .still,
                localPath: "/cache/why-files-tmdb-still.jpg",
                remoteURL: nil,
                sourceLabel: "tmdb"
            )
            try await store.replaceEnrichment(
                owner: episodeOwner,
                core: .episode(episode),
                cast: [],
                artwork: [tmdbStill]
            )

            let projection = DefaultCatalogProjection(
                catalog: store,
                volumes: fx.registry,
                libraryRoots: [fx.rootURL.path]
            )
            let items = try await projection.projectMediaItems()
            guard items.count == 1, let item = items.first else {
                return .init(scenario: scenario, passed: false,
                             detail: "expected 1 item, got \(items.count)")
            }
            if item.localEpisodeStillPath != sidecarStill {
                return .init(scenario: scenario, passed: false,
                             detail: "localEpisodeStillPath=\(String(describing: item.localEpisodeStillPath)) want=\(sidecarStill)")
            }
            if item.thumbBackdropPath != "/cache/why-files-tmdb-still.jpg" {
                return .init(scenario: scenario, passed: false,
                             detail: "thumbBackdropPath=\(String(describing: item.thumbBackdropPath))")
            }
            if item.backdropImagePath != seasonFanart {
                return .init(scenario: scenario, passed: false,
                             detail: "backdropImagePath=\(String(describing: item.backdropImagePath))")
            }
            if item.gridBackdropPath != sidecarStill {
                return .init(scenario: scenario, passed: false,
                             detail: "gridBackdropPath=\(String(describing: item.gridBackdropPath))")
            }
            return .init(scenario: scenario, passed: true,
                         detail: "exact episode still sidecar wins over TMDB still and season fanart for row thumbnails")
        } catch {
            return .init(scenario: scenario, passed: false,
                         detail: "threw: \(error)")
        }
    }

    /// TNG-style numbering can have a double-length premiere named
    /// `S01E01E02`, after which local files may carry a physical episode
    /// number that does not match TMDB's canonical episode number. In that
    /// case the filename title is the only trustworthy row label.
    private static func scenarioProjectionLocalEpisodeTitleWinsOverMismatchedTMDB(
        scenario: String,
        store: any CatalogStore
    ) async -> ScenarioResult {
        do {
            let fx = try makeFixture(scenario: scenario)
            defer { fx.cleanup() }

            let rel = "Star Trek The Next Generation (1987)/Season 1/Star Trek TNG S01E03 The Naked Now.mp4"
            try writeFile(at: fx.absolutePath(for: rel))
            let row = fx.makeRow(relativePath: rel)
            try await store.upsert(mediaFile: row)

            let showID = MediaIdentity.showID(title: "Star Trek The Next Generation", year: 1987)
            let seasonID = MediaIdentity.seasonID(show: showID, seasonNumber: 1)
            let episodeID = MediaIdentity.episodeID(
                season: seasonID,
                episodeNumber: 3,
                primaryFile: row.id
            )
            let episodeOwner = ArtworkOwner.episode(episodeID)
            let enrichedEpisode = CatalogEpisode(
                id: episodeID,
                seasonID: seasonID,
                primaryFile: row.id,
                episodeNumber: 3,
                title: "Code of Honor",
                overview: nil,
                runtimeMinutes: nil
            )
            try await store.replaceEnrichment(
                owner: episodeOwner,
                core: .episode(enrichedEpisode),
                cast: [],
                artwork: []
            )

            let projection = DefaultCatalogProjection(
                catalog: store,
                volumes: fx.registry,
                libraryRoots: [fx.rootURL.path]
            )
            let items = try await projection.projectMediaItems()
            guard items.count == 1, let item = items.first else {
                return .init(scenario: scenario, passed: false,
                             detail: "expected 1 item, got \(items.count)")
            }
            guard item.episodeNumber == 3 else {
                return .init(scenario: scenario, passed: false,
                             detail: "episodeNumber=\(String(describing: item.episodeNumber))")
            }
            guard item.episodeTitle == "The Naked Now" else {
                return .init(scenario: scenario, passed: false,
                             detail: "episodeTitle=\(String(describing: item.episodeTitle))")
            }
            return .init(scenario: scenario, passed: true,
                         detail: "filename episode title beats mismatched TMDB title for TNG-style numbering")
        } catch {
            return .init(scenario: scenario, passed: false,
                         detail: "threw: \(error)")
        }
    }

    /// Locks down the enriched TV-episode shape consumed by `ShowDetailView`.
    /// The projection must surface voteAverage,
    /// director, releaseDate, runtime, certification, genres, tmdbID,
    /// plus a fully-shaped cast row. Episode `MediaItem.metadata` carries
    /// *show* metadata, which is what the UI consumes; episode-level fields
    /// (`CatalogEpisode.tmdbID`,
    /// etc.) live on the episode row but are not surfaced here.
    private static func scenarioProjectionEpisodeMetadataParityWithScanner(
        scenario: String,
        store: any CatalogStore
    ) async -> ScenarioResult {
        do {
            let fx = try makeFixture(scenario: scenario)
            defer { fx.cleanup() }

            let rel = "Breaking Bad (2008)/Season 1/Breaking Bad - s01e01 - Pilot.mkv"
            try writeFile(at: fx.absolutePath(for: rel))
            let row = fx.makeRow(relativePath: rel)
            try await store.upsert(mediaFile: row)

            let showID = MediaIdentity.showID(title: "Breaking Bad", year: 2008)
            let show = CatalogShow(
                id: showID,
                title: "Breaking Bad",
                year: 2008,
                tmdbID: 1396,
                overview: "A high school chemistry teacher turns to making meth.",
                certification: "TV-MA",
                genres: ["Drama", "Crime"],
                releaseDate: "2008-01-20",
                runtimeMinutes: 47,
                voteAverage: 8.4,
                director: "Vince Gilligan"
            )
            let showOwner = ArtworkOwner.show(showID)
            let cast = [
                CatalogCastEntry(
                    personTMDBID: 17419,
                    name: "Bryan Cranston",
                    profilePath: "/bryan.jpg",
                    character: "Walter White",
                    ordinal: 0
                ),
                CatalogCastEntry(
                    personTMDBID: 84497,
                    name: "Aaron Paul",
                    profilePath: "/aaron.jpg",
                    character: "Jesse Pinkman",
                    ordinal: 1
                )
            ]
            try await store.replaceEnrichment(
                owner: showOwner,
                core: .show(show),
                cast: cast,
                artwork: []
            )

            let projection = DefaultCatalogProjection(
                catalog: store,
                volumes: fx.registry,
                libraryRoots: [fx.rootURL.path]
            )
            let items = try await projection.projectMediaItems()
            guard items.count == 1, let item = items.first else {
                return .init(scenario: scenario, passed: false,
                             detail: "expected 1 item, got \(items.count)")
            }
            if item.title != "Breaking Bad" || item.year != 2008 {
                return .init(scenario: scenario, passed: false,
                             detail: "title/year drift: \(item.title) \(String(describing: item.year))")
            }
            if item.tmdbID != 1396 {
                return .init(scenario: scenario, passed: false,
                             detail: "tmdbID=\(String(describing: item.tmdbID)) want=1396")
            }
            if item.contentRating != "TV-MA" {
                return .init(scenario: scenario, passed: false,
                             detail: "contentRating=\(String(describing: item.contentRating)) want=TV-MA")
            }
            guard let meta = item.metadata else {
                return .init(scenario: scenario, passed: false,
                             detail: "metadata missing")
            }
            if meta.tmdbID != 1396 || meta.director != "Vince Gilligan"
                || meta.voteAverage != 8.4 || meta.runtime != 47
                || meta.certification != "TV-MA"
                || meta.releaseDate != "2008-01-20"
                || meta.genres != ["Drama", "Crime"]
                || meta.overview != "A high school chemistry teacher turns to making meth." {
                return .init(scenario: scenario, passed: false,
                             detail: "metadata field drift: \(meta)")
            }
            guard meta.cast.count == 2 else {
                return .init(scenario: scenario, passed: false,
                             detail: "expected 2 cast entries, got \(meta.cast.count)")
            }
            if meta.cast[0].name != "Bryan Cranston"
                || meta.cast[0].character != "Walter White"
                || meta.cast[0].tmdbPersonID != 17419
                || meta.cast[0].profilePath != "/bryan.jpg" {
                return .init(scenario: scenario, passed: false,
                             detail: "cast[0] drift: \(meta.cast[0])")
            }
            if meta.cast[1].name != "Aaron Paul"
                || meta.cast[1].tmdbPersonID != 84497 {
                return .init(scenario: scenario, passed: false,
                             detail: "cast[1] drift: \(meta.cast[1])")
            }
            return .init(scenario: scenario, passed: true,
                         detail: "v3 show shape (voteAverage/director/releaseDate/runtime/cert/genres/tmdbID + cast×2) surfaced on episode MediaItem.metadata")
        } catch {
            return .init(scenario: scenario, passed: false,
                         detail: "threw: \(error)")
        }
    }

    private static func scenarioLocalGenreMaturityFallback() -> ScenarioResult {
        let scenario = "localGenreMaturityFallback"
        let item = MediaItem(
            filePath: "/tmp/Kids/Wonder.mkv",
            fileName: "Wonder.mkv",
            title: "Wonder",
            year: nil,
            fileExtension: "mkv",
            fileSize: 1,
            genre: "Kids"
        )
        let profile = UserProfile(
            name: "Kids",
            avatar: ProfileAvatar.catalog[0],
            maturityLevel: .kids
        )

        guard item.maturityLevel == .kids, profile.allows(item: item) else {
            return .init(
                scenario: scenario,
                passed: false,
                detail: "local Kids folder genre did not produce kids-allowed maturity=\(item.maturityLevel)"
            )
        }
        return .init(
            scenario: scenario,
            passed: true,
            detail: "local folder genre feeds maturity filtering when TMDB metadata is absent"
        )
    }

    private static func scenarioKidsProfileAllowsFamilyLocalGenre() -> ScenarioResult {
        let scenario = "kidsProfileAllowsFamilyLocalGenre"
        let item = MediaItem(
            filePath: "/tmp/Family/WALL-E.mkv",
            fileName: "WALL-E.mkv",
            title: "WALL-E",
            year: nil,
            fileExtension: "mkv",
            fileSize: 1,
            genre: "Family"
        )
        let profile = UserProfile(
            name: "Kids",
            avatar: ProfileAvatar.catalog[0],
            maturityLevel: .kids
        )

        guard item.maturityLevel == .family, profile.allows(item: item) else {
            return .init(
                scenario: scenario,
                passed: false,
                detail: "Kids profile rejected Family local genre maturity=\(item.maturityLevel)"
            )
        }
        return .init(
            scenario: scenario,
            passed: true,
            detail: "Kids profile includes locally classified Family content"
        )
    }

    private static func scenarioAnimationAloneIsNotKidsSafe() -> ScenarioResult {
        let scenario = "animationAloneIsNotKidsSafe"
        let item = MediaItem(
            filePath: "/tmp/Animation/AdultAnimated.mkv",
            fileName: "AdultAnimated.mkv",
            title: "Adult Animated",
            year: nil,
            fileExtension: "mkv",
            fileSize: 1,
            localGenres: ["Animation", "Comedy"]
        )
        let profile = UserProfile(
            name: "Kids",
            avatar: ProfileAvatar.catalog[0],
            maturityLevel: .kids
        )

        guard item.maturityLevel == .teen, !profile.allows(item: item) else {
            return .init(
                scenario: scenario,
                passed: false,
                detail: "animation-only maturity=\(item.maturityLevel) allowed=\(profile.allows(item: item))"
            )
        }
        return .init(
            scenario: scenario,
            passed: true,
            detail: "Animation without Kids/Family signal stays out of Kids profile"
        )
    }

    private static func scenarioOfflineTVGenreTitleNormalization() -> ScenarioResult {
        let scenario = "offlineTVGenreTitleNormalization"
        let genres = Set(CatalogContentPolicy.inferOfflineTVGenres(
            forShowTitle: "Foster's Home for Imaginary Friends (2004)"
        ))

        guard genres.isSuperset(of: ["Kids", "Animation", "Family"]) else {
            return .init(
                scenario: scenario,
                passed: false,
                detail: "genres=\(Array(genres).sorted())"
            )
        }
        return .init(
            scenario: scenario,
            passed: true,
            detail: "apostrophe/year-normalized show title maps to offline TV genres"
        )
    }

    private static func scenarioDisplayGenresPrefersMetadata() -> ScenarioResult {
        let scenario = "displayGenresPrefersMetadata"
        let metadata = TMDBMetadata(
            tmdbID: 1,
            overview: nil,
            genres: ["Adventure", "Family"],
            cast: [],
            director: nil,
            certification: "PG",
            voteAverage: nil,
            posterPath: nil,
            backdropPath: nil,
            releaseDate: nil,
            runtime: nil
        )
        let item = MediaItem(
            filePath: "/tmp/Local/Example.mkv",
            fileName: "Example.mkv",
            title: "Example",
            year: nil,
            fileExtension: "mkv",
            fileSize: 1,
            genre: "Local",
            metadata: metadata
        )

        guard item.displayGenres == ["Adventure", "Family"] else {
            return .init(
                scenario: scenario,
                passed: false,
                detail: "displayGenres=\(item.displayGenres)"
            )
        }
        return .init(
            scenario: scenario,
            passed: true,
            detail: "metadata genre list remains authoritative, local genre is fallback only"
        )
    }

    private static func scenarioGenericFamilyMetadataMergesLocalGenreVariety() -> ScenarioResult {
        let scenario = "genericFamilyMetadataMergesLocalGenreVariety"
        let metadata = TMDBMetadata(
            tmdbID: 1,
            overview: nil,
            genres: ["Family"],
            cast: [],
            director: nil,
            certification: "PG",
            voteAverage: nil,
            posterPath: nil,
            backdropPath: nil,
            releaseDate: nil,
            runtime: nil
        )
        let item = MediaItem(
            filePath: "/tmp/Family/Inside Out.mkv",
            fileName: "Inside Out.mkv",
            title: "Inside Out",
            year: nil,
            fileExtension: "mkv",
            fileSize: 1,
            localGenres: ["Family", "Animation", "Comedy"],
            metadata: metadata
        )

        guard item.displayGenres == ["Family", "Animation", "Comedy"] else {
            return .init(
                scenario: scenario,
                passed: false,
                detail: "displayGenres=\(item.displayGenres)"
            )
        }
        return .init(
            scenario: scenario,
            passed: true,
            detail: "generic Family metadata keeps local browse variety"
        )
    }

    private static func scenarioExternalDataDirectoryConfiguration() -> ScenarioResult {
        let scenario = "externalDataDirectoryConfiguration"
        let env = ProcessInfo.processInfo.environment

        #if DEBUG
        let liveChild = Configuration.liveMediaSidecarDirectory
            .appendingPathComponent("verify-reports", isDirectory: true)
        if let resolvedLiveChild = Configuration.debugResolvedSidecarRootOverrideDirectory(
            environment: [Configuration.sidecarRootOverrideEnvironmentKey: liveChild.path]
        ) {
            guard !Configuration.debugSidecarURLIsLiveOrChild(resolvedLiveChild) else {
                return .init(
                    scenario: scenario,
                    passed: false,
                    detail: "MARQUEE_SIDECAR_ROOT live child resolved to \(resolvedLiveChild.path)"
                )
            }
        }

        if let sidecarRoot = env[Configuration.sidecarRootOverrideEnvironmentKey], !sidecarRoot.isEmpty {
            let expected = (
                Configuration.debugResolvedSidecarRootOverrideDirectory(environment: env)
                    ?? URL(fileURLWithPath: sidecarRoot, isDirectory: true)
            ).standardizedFileURL.path
            let actual = Configuration.appSupportDirectory
                .standardizedFileURL.path
            let live = Configuration.liveMediaSidecarDirectory
                .standardizedFileURL.path
            guard actual == expected else {
                return .init(
                    scenario: scenario,
                    passed: false,
                    detail: "MARQUEE_SIDECAR_ROOT actual=\(actual) expected=\(expected)"
                )
            }
            guard actual != live else {
                return .init(
                    scenario: scenario,
                    passed: false,
                    detail: "MARQUEE_SIDECAR_ROOT must not resolve to live sidecar \(live)"
                )
            }
            guard !Configuration.debugSidecarURLIsLiveOrChild(URL(fileURLWithPath: actual, isDirectory: true)) else {
                return .init(
                    scenario: scenario,
                    passed: false,
                    detail: "MARQUEE_SIDECAR_ROOT must not resolve inside live sidecar \(actual)"
                )
            }

            let fm = FileManager.default
            let marker = "verify-projection-sidecar-sandbox-\(UUID().uuidString).txt"
            let actualMarker = URL(fileURLWithPath: actual, isDirectory: true)
                .appendingPathComponent(marker)
            let liveMarker = Configuration.liveMediaSidecarDirectory
                .appendingPathComponent(marker)
            do {
                try fm.createDirectory(
                    at: URL(fileURLWithPath: actual, isDirectory: true),
                    withIntermediateDirectories: true
                )
                try "sandbox".write(to: actualMarker, atomically: true, encoding: .utf8)
                defer { try? fm.removeItem(at: actualMarker) }
                guard !fm.fileExists(atPath: liveMarker.path) else {
                    return .init(
                        scenario: scenario,
                        passed: false,
                        detail: "sandbox marker unexpectedly landed in live sidecar \(liveMarker.path)"
                    )
                }
            } catch {
                return .init(
                    scenario: scenario,
                    passed: false,
                    detail: "sidecar sandbox marker failed: \(error.localizedDescription)"
                )
            }

            return .init(
                scenario: scenario,
                passed: true,
                detail: "MARQUEE_SIDECAR_ROOT routes harness support away from live media sidecar"
            )
        }
        #endif

        if let override = env["MARQUEE_DATA_DIR"], !override.isEmpty {
            let expected = URL(fileURLWithPath: override, isDirectory: true)
                .standardizedFileURL.path
            let actual = Configuration.appSupportDirectory
                .standardizedFileURL.path
            guard actual == expected else {
                return .init(
                    scenario: scenario,
                    passed: false,
                    detail: "MARQUEE_DATA_DIR actual=\(actual) expected=\(expected)"
                )
            }
            guard Configuration.artworkCacheDirectory.path.hasPrefix(actual + "/cache/") else {
                return .init(
                    scenario: scenario,
                    passed: false,
                    detail: "artworkCacheDirectory=\(Configuration.artworkCacheDirectory.path)"
                )
            }
            return .init(
                scenario: scenario,
                passed: true,
                detail: "MARQUEE_DATA_DIR routes support/cache into one data root"
            )
        }

        #if DEBUG
        if CommandLine.arguments.contains(launchArgument) {
            let actual = Configuration.appSupportDirectory
                .standardizedFileURL.path
            let live = Configuration.liveMediaSidecarDirectory
                .standardizedFileURL.path
            guard actual != live else {
                return .init(
                    scenario: scenario,
                    passed: false,
                    detail: "verification launch must not resolve to live sidecar \(live)"
                )
            }
            guard !Configuration.debugSidecarURLIsLiveOrChild(URL(fileURLWithPath: actual, isDirectory: true)) else {
                return .init(
                    scenario: scenario,
                    passed: false,
                    detail: "verification launch must not resolve inside live sidecar \(actual)"
                )
            }
            return .init(
                scenario: scenario,
                passed: true,
                detail: "verification launch uses a scratch sidecar root when no override is set"
            )
        }
        #endif

        if let mediaRoot = env["MARQUEE_MEDIA_ROOT"], !mediaRoot.isEmpty {
            let expected = URL(fileURLWithPath: mediaRoot, isDirectory: true)
                .appendingPathComponent(".marquee", isDirectory: true)
                .standardizedFileURL.path
            let actual = Configuration.appSupportDirectory
                .standardizedFileURL.path
            guard actual == expected else {
                return .init(
                    scenario: scenario,
                    passed: false,
                    detail: "MARQUEE_MEDIA_ROOT actual=\(actual) expected=\(expected)"
                )
            }
            return .init(
                scenario: scenario,
                passed: true,
                detail: "MARQUEE_MEDIA_ROOT routes data to media-root .marquee"
            )
        }

        return .init(
            scenario: scenario,
            passed: true,
            detail: "no storage override set"
        )
    }

    // MARK: - Report write

    private static func writeReport(_ report: Report) throws {
        let dir = try resolveReportsDir()
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        let url = dir.appendingPathComponent("verify-projection-report.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)
        try data.write(to: url, options: .atomic)
    }

    private static func resolveReportsDir() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["MARQUEE_VERIFY_REPORTS_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return appSupport.appendingPathComponent("Marquee/Verify", isDirectory: true)
    }
}

#endif
