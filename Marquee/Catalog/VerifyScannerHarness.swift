//
//  VerifyScannerHarness.swift
//  Marquee
//
//  Phase 2 verification harness for `DiffScanner`.
//
//  Covers the behavioral contract of `DiffScanner` against fixture
//  trees rooted in a temporary directory. Each scenario builds its
//  own tree under `MARQUEE_VERIFY_REPORTS_DIR` (or the default
//  Application Support directory), runs a scan, and asserts on:
//    - the catalog row counts and contents the scan produced,
//    - the `CatalogScanJob` terminal state and counters,
//    - the kinds and ordering of `CatalogScanEvent` rows.
//
//  DEBUG-ONLY. The entire body is gated by `#if DEBUG` so the harness
//  is excluded from Release builds. Activated by `--verify-scanner`.
//
//  Exit codes: 0 = all pass, 1 = at least one scenario failed,
//  2 = internal error.
//

#if DEBUG

import Foundation

public enum VerifyScannerHarness {

    public static let launchArgument = "--verify-scanner"

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
                let line = "verify-scanner: error: \(error)\n"
                FileHandle.standardError.write(Data(line.utf8))
                result.set(2)
            }
        }
        semaphore.wait()
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

        // Each scenario runs against both store implementations. The
        // `InMemoryCatalogStore` pass exists for fast feedback and the
        // `SQLiteCatalogStore` pass exists because that is the
        // production write path — the scanner's transactional value is
        // load-bearing on whichever store the user actually runs
        // against, so behavioral parity has to be proven, not assumed.
        for (label, makeStore) in storeFactories() {
            results.append(await runScenario("emptyTreeNoOps", label, makeStore,
                scenarioEmptyTreeNoOps))
            results.append(await runScenario("addNewFiles", label, makeStore,
                scenarioAddNewFiles))
            results.append(await runScenario("detectMtimeUpdate", label, makeStore,
                scenarioDetectMtimeUpdate))
            results.append(await runScenario("detectRemoval", label, makeStore,
                scenarioDetectRemoval))
            results.append(await runScenario("ignoreNonVideoExtensions", label, makeStore,
                scenarioIgnoreNonVideoExtensions))
            results.append(await runScenario("ignoreSymlinks", label, makeStore,
                scenarioIgnoreSymlinks))
            results.append(await runScenario("resumeIdempotency", label, makeStore,
                scenarioResumeIdempotency))
            results.append(await runScenario("countersMatchEvents", label, makeStore,
                scenarioCountersMatchEvents))
            results.append(await runScenario("batchedTransactionsCommitInOrder", label, makeStore,
                scenarioBatchedTransactionsCommitInOrder))
            results.append(await runScenario("rootMissingThrows", label, makeStore,
                scenarioRootMissingThrows))
            results.append(await runScenario("nestedRootRelativePaths", label, makeStore,
                scenarioNestedRootRelativePaths))
            results.append(await runScenario("appStateDualRootPopulation", label, makeStore,
                scenarioAppStateDualRootPopulation))
            results.append(await runScenario("failedJobOnTransactionError", label, makeStore,
                scenarioFailedJobOnTransactionError))
        }

        let allPassed = results.allSatisfy { $0.passed }
        for r in results {
            let mark = r.passed ? "PASS" : "FAIL"
            let line = "verify-scanner: \(mark) \(r.scenario): \(r.detail)\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
        let summary = "verify-scanner: outcome=\(allPassed ? "verified" : "failed")"
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

    /// Wraps a freshly-constructed catalog store with the cleanup
    /// hook needed to release any disk artefacts (e.g. the SQLite
    /// database file). The store itself is held by the scenario; once
    /// the scenario returns and the local reference drops, the actor
    /// can be deallocated and `cleanup` is free to remove the file.
    private struct StoreHandle {
        let store: any CatalogStore
        let cleanup: () -> Void
    }

    /// Returns the (label, factory) pairs every scenario runs against.
    /// The label is the suffix appended to the scenario name in the
    /// report (e.g. `addNewFiles.sqlite`), so a parity break is
    /// immediately attributable to the failing store.
    private static func storeFactories() -> [(label: String, make: (String) throws -> StoreHandle)] {
        return [
            ("memory", makeInMemoryStoreHandle),
            ("sqlite", makeSQLiteStoreHandle)
        ]
    }

    private static func makeInMemoryStoreHandle(scenario: String) -> StoreHandle {
        StoreHandle(
            store: InMemoryCatalogStore(),
            cleanup: {}
        )
    }

    private static func makeSQLiteStoreHandle(scenario: String) throws -> StoreHandle {
        // One database file per scenario so a corrupted state on one
        // run cannot bleed into another, and so a parallel future
        // executor would not collide on the path.
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "verify-scanner-\(scenario)-\(UUID().uuidString).sqlite"
            )
        let store = try SQLiteCatalogStore(path: dbURL.path)
        return StoreHandle(
            store: store,
            cleanup: {
                // Best-effort. If the OS still has the file open
                // (rare; SQLiteCatalogStore closes its handle in its
                // deinit) the next run's TMPDIR sweep will reap it.
                try? FileManager.default.removeItem(at: dbURL)
                // SQLite WAL/SHM siblings may exist alongside the .db
                // file. SQLite names them `<dbpath>-wal` / `<dbpath>-shm`
                // (suffix, not extension), so build the URLs literally
                // rather than via `appendingPathExtension`, which would
                // produce `<dbpath>.wal` and miss the real sidecars.
                let wal = URL(fileURLWithPath: dbURL.path + "-wal")
                let shm = URL(fileURLWithPath: dbURL.path + "-shm")
                try? FileManager.default.removeItem(at: wal)
                try? FileManager.default.removeItem(at: shm)
            }
        )
    }

    /// Constructs a fresh store via `makeStore` and dispatches to the
    /// scenario closure. Wraps the `<base>` name with the store
    /// label so the report reads e.g. `addNewFiles.sqlite`. Any
    /// thrown error during store construction is reported as a
    /// scenario failure rather than an internal error so a broken
    /// SQLite environment does not mask in-memory results.
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

    // MARK: - Fixtures

    /// Builds a fresh tmp directory + matching `InMemoryVolumeRegistry`
    /// where the tmp directory IS the volume's mount path. The volume
    /// UUID is deterministic per scenario so any rerun is comparable.
    private struct Fixture {
        let rootURL: URL
        let registry: InMemoryVolumeRegistry
        let volumeUUID: String

        func cleanup() {
            try? FileManager.default.removeItem(at: rootURL)
        }
    }

    private static func makeFixture(
        scenario: String
    ) throws -> Fixture {
        // Realpath the scenario root before we hand it to the registry.
        // On macOS, `URL.standardizedFileURL` does not resolve `/tmp` →
        // `/private/tmp`, but the walk does (FileManager standardizes
        // through the OS), and the volume registry compares prefixes
        // literally. If we seeded the registry with `/tmp/...` while
        // the walk emits `/private/tmp/...`, `deepestMatch` would
        // refuse the resolution and the scenario would error out
        // before exercising the diff at all.
        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent("verify-scanner-\(scenario)-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(
            at: raw, withIntermediateDirectories: true
        )
        let rootURL = URL(fileURLWithPath:
            (raw.path as NSString).standardizingPath,
            isDirectory: true
        )
        let uuid = "11111111-1111-1111-1111-\(stableSuffix(for: scenario))"
        let descriptor = VolumeDescriptor(
            uuid: uuid,
            mountPath: rootURL.path,
            label: "verify-\(scenario)",
            isRemovable: false,
            isNetwork: false
        )
        let registry = InMemoryVolumeRegistry(seed: [descriptor])
        return Fixture(
            rootURL: rootURL,
            registry: registry,
            volumeUUID: VolumeDescriptor(
                uuid: uuid,
                mountPath: rootURL.path
            ).uuid
        )
    }

    private static func stableSuffix(for s: String) -> String {
        // 12 hex chars derived from the scenario name, padded so it
        // always fits the UUID's last segment.
        let hex = MediaIdentity.shortHash(s)
        let padded = (hex + String(repeating: "0", count: 12)).prefix(12)
        return String(padded)
    }

    private static func writeFile(
        _ url: URL,
        bytes: Int = 16,
        mtime: Date? = nil
    ) throws {
        let data = Data(repeating: 0xab, count: bytes)
        try data.write(to: url, options: .atomic)
        if let mtime {
            try FileManager.default.setAttributes(
                [.modificationDate: mtime], ofItemAtPath: url.path
            )
        }
    }

    // MARK: - Scenarios

    private static func scenarioEmptyTreeNoOps(
        _ scenario: String,
        _ store: any CatalogStore
    ) async -> ScenarioResult {
        do {
            let fix = try makeFixture(scenario: scenario)
            defer { fix.cleanup() }
            let scanner = DiffScanner(catalog: store, volumes: fix.registry)
            let job = try await scanner.scan(rootPath: fix.rootURL.path)
            guard job.state == .completed else {
                return .init(scenario: scenario, passed: false,
                             detail: "expected completed, got \(job.state)")
            }
            guard job.filesObserved == 0,
                  job.filesAdded == 0,
                  job.filesUpdated == 0,
                  job.filesRemoved == 0 else {
                return .init(scenario: scenario, passed: false,
                             detail: "non-zero counters on empty tree: \(job)")
            }
            let counts = try await store.countsSnapshot()
            guard counts.mediaFiles == 0 else {
                return .init(scenario: scenario, passed: false,
                             detail: "mediaFiles!=0 on empty tree: \(counts.mediaFiles)")
            }
            return .init(scenario: scenario, passed: true,
                         detail: "empty tree → 0 mediaFiles, completed job")
        } catch {
            return .init(scenario: scenario, passed: false,
                         detail: "threw: \(error)")
        }
    }

    private static func scenarioAddNewFiles(
        _ scenario: String,
        _ store: any CatalogStore
    ) async -> ScenarioResult {
        do {
            let fix = try makeFixture(scenario: scenario)
            defer { fix.cleanup() }
            for i in 0..<5 {
                try writeFile(fix.rootURL.appendingPathComponent("clip\(i).mkv"))
            }
            let scanner = DiffScanner(catalog: store, volumes: fix.registry)
            let job = try await scanner.scan(rootPath: fix.rootURL.path)
            guard job.state == .completed else {
                return .init(scenario: scenario, passed: false,
                             detail: "expected completed, got \(job.state)")
            }
            guard job.filesAdded == 5,
                  job.filesObserved == 5,
                  job.filesUpdated == 0,
                  job.filesRemoved == 0 else {
                return .init(scenario: scenario, passed: false,
                             detail: "counters off: added=\(job.filesAdded) observed=\(job.filesObserved)")
            }
            let counts = try await store.countsSnapshot()
            guard counts.mediaFiles == 5 else {
                return .init(scenario: scenario, passed: false,
                             detail: "expected 5 mediaFiles, got \(counts.mediaFiles)")
            }
            let events = try await store.scanEvents(of: job.id)
            let addedCount = events.filter { $0.kind == .fileAdded }.count
            guard addedCount == 5 else {
                return .init(scenario: scenario, passed: false,
                             detail: "expected 5 fileAdded events, got \(addedCount)")
            }
            return .init(scenario: scenario, passed: true,
                         detail: "5 files added with matching events")
        } catch {
            return .init(scenario: scenario, passed: false,
                         detail: "threw: \(error)")
        }
    }

    private static func scenarioDetectMtimeUpdate(
        _ scenario: String,
        _ store: any CatalogStore
    ) async -> ScenarioResult {
        do {
            let fix = try makeFixture(scenario: scenario)
            defer { fix.cleanup() }
            let file = fix.rootURL.appendingPathComponent("movie.mkv")
            let earlier = Date(timeIntervalSince1970: 1_700_000_000)
            try writeFile(file, bytes: 16, mtime: earlier)

            let scanner = DiffScanner(catalog: store, volumes: fix.registry)
            let firstJob = try await scanner.scan(rootPath: fix.rootURL.path)
            guard firstJob.filesAdded == 1 else {
                return .init(scenario: scenario, passed: false,
                             detail: "first scan didn't add: \(firstJob)")
            }

            // Same path, larger size + new mtime → must register an
            // update.
            let later = Date(timeIntervalSince1970: 1_800_000_000)
            try writeFile(file, bytes: 32, mtime: later)
            let secondJob = try await scanner.scan(rootPath: fix.rootURL.path)
            guard secondJob.filesUpdated == 1,
                  secondJob.filesAdded == 0,
                  secondJob.filesRemoved == 0 else {
                return .init(scenario: scenario, passed: false,
                             detail: "second scan counters off: \(secondJob)")
            }
            let stored = try await store.allMediaFiles()
            guard stored.count == 1, stored.first?.fileSize == 32 else {
                return .init(scenario: scenario, passed: false,
                             detail: "stored size not refreshed")
            }
            return .init(scenario: scenario, passed: true,
                         detail: "size+mtime change → fileUpdated")
        } catch {
            return .init(scenario: scenario, passed: false,
                         detail: "threw: \(error)")
        }
    }

    private static func scenarioDetectRemoval(
        _ scenario: String,
        _ store: any CatalogStore
    ) async -> ScenarioResult {
        do {
            let fix = try makeFixture(scenario: scenario)
            defer { fix.cleanup() }
            let file = fix.rootURL.appendingPathComponent("gone.mkv")
            try writeFile(file)

            let scanner = DiffScanner(catalog: store, volumes: fix.registry)
            _ = try await scanner.scan(rootPath: fix.rootURL.path)
            try FileManager.default.removeItem(at: file)

            let job = try await scanner.scan(rootPath: fix.rootURL.path)
            guard job.filesRemoved == 1, job.filesAdded == 0 else {
                return .init(scenario: scenario, passed: false,
                             detail: "removal counters off: \(job)")
            }
            let counts = try await store.countsSnapshot()
            guard counts.mediaFiles == 0 else {
                return .init(scenario: scenario, passed: false,
                             detail: "mediaFile not deleted: count=\(counts.mediaFiles)")
            }
            let events = try await store.scanEvents(of: job.id)
            guard events.contains(where: { $0.kind == .fileRemoved }) else {
                return .init(scenario: scenario, passed: false,
                             detail: "no fileRemoved event")
            }
            return .init(scenario: scenario, passed: true,
                         detail: "vanished file → fileRemoved + delete")
        } catch {
            return .init(scenario: scenario, passed: false,
                         detail: "threw: \(error)")
        }
    }

    private static func scenarioIgnoreNonVideoExtensions(
        _ scenario: String,
        _ store: any CatalogStore
    ) async -> ScenarioResult {
        do {
            let fix = try makeFixture(scenario: scenario)
            defer { fix.cleanup() }
            try writeFile(fix.rootURL.appendingPathComponent("notes.txt"))
            try writeFile(fix.rootURL.appendingPathComponent("poster.jpg"))
            try writeFile(fix.rootURL.appendingPathComponent("subs.srt"))
            try writeFile(fix.rootURL.appendingPathComponent("clip.mkv"))

            let scanner = DiffScanner(catalog: store, volumes: fix.registry)
            let job = try await scanner.scan(rootPath: fix.rootURL.path)
            guard job.filesObserved == 1, job.filesAdded == 1 else {
                return .init(scenario: scenario, passed: false,
                             detail: "non-video files not ignored: \(job)")
            }
            return .init(scenario: scenario, passed: true,
                         detail: "only .mkv ingested; .txt/.jpg/.srt skipped")
        } catch {
            return .init(scenario: scenario, passed: false,
                         detail: "threw: \(error)")
        }
    }

    private static func scenarioIgnoreSymlinks(
        _ scenario: String,
        _ store: any CatalogStore
    ) async -> ScenarioResult {
        do {
            let fix = try makeFixture(scenario: scenario)
            defer { fix.cleanup() }
            let real = fix.rootURL.appendingPathComponent("real.mkv")
            try writeFile(real)
            // Symlink points back at the real file. A scanner that
            // follows symlinks would either ingest it twice or — if a
            // self-loop — never terminate.
            let link = fix.rootURL.appendingPathComponent("link.mkv")
            try FileManager.default.createSymbolicLink(
                at: link, withDestinationURL: real
            )
            let scanner = DiffScanner(catalog: store, volumes: fix.registry)
            let job = try await scanner.scan(rootPath: fix.rootURL.path)
            guard job.filesAdded == 1, job.filesObserved == 1 else {
                return .init(scenario: scenario, passed: false,
                             detail: "symlink not skipped: \(job)")
            }
            return .init(scenario: scenario, passed: true,
                         detail: "symlink ignored, real file ingested once")
        } catch {
            return .init(scenario: scenario, passed: false,
                         detail: "threw: \(error)")
        }
    }

    private static func scenarioResumeIdempotency(
        _ scenario: String,
        _ store: any CatalogStore
    ) async -> ScenarioResult {
        do {
            let fix = try makeFixture(scenario: scenario)
            defer { fix.cleanup() }
            for i in 0..<3 {
                try writeFile(fix.rootURL.appendingPathComponent("clip\(i).mkv"))
            }
            let scanner = DiffScanner(catalog: store, volumes: fix.registry)
            _ = try await scanner.scan(rootPath: fix.rootURL.path)
            let secondJob = try await scanner.scan(rootPath: fix.rootURL.path)
            guard secondJob.filesAdded == 0,
                  secondJob.filesUpdated == 0,
                  secondJob.filesRemoved == 0 else {
                return .init(scenario: scenario, passed: false,
                             detail: "second scan not a no-op: \(secondJob)")
            }
            let counts = try await store.countsSnapshot()
            guard counts.mediaFiles == 3 else {
                return .init(scenario: scenario, passed: false,
                             detail: "row count drifted on rescan: \(counts.mediaFiles)")
            }
            return .init(scenario: scenario, passed: true,
                         detail: "rescan over unchanged tree wrote zero rows")
        } catch {
            return .init(scenario: scenario, passed: false,
                         detail: "threw: \(error)")
        }
    }

    private static func scenarioCountersMatchEvents(
        _ scenario: String,
        _ store: any CatalogStore
    ) async -> ScenarioResult {
        do {
            let fix = try makeFixture(scenario: scenario)
            defer { fix.cleanup() }
            for i in 0..<4 {
                try writeFile(fix.rootURL.appendingPathComponent("c\(i).mkv"))
            }
            let scanner = DiffScanner(catalog: store, volumes: fix.registry)
            let job = try await scanner.scan(rootPath: fix.rootURL.path)
            let events = try await store.scanEvents(of: job.id)
            let added = events.filter { $0.kind == .fileAdded }.count
            let updated = events.filter { $0.kind == .fileUpdated }.count
            let removed = events.filter { $0.kind == .fileRemoved }.count
            guard added == job.filesAdded,
                  updated == job.filesUpdated,
                  removed == job.filesRemoved else {
                return .init(scenario: scenario, passed: false,
                             detail: "counters disagree with events: " +
                                     "job(\(job.filesAdded)/\(job.filesUpdated)/\(job.filesRemoved)) " +
                                     "events(\(added)/\(updated)/\(removed))")
            }
            // started must come before any file event; completed must
            // come last.
            guard events.first?.kind == .started else {
                return .init(scenario: scenario, passed: false,
                             detail: "first event not started: \(String(describing: events.first?.kind))")
            }
            guard events.last?.kind == .completed else {
                return .init(scenario: scenario, passed: false,
                             detail: "last event not completed: \(String(describing: events.last?.kind))")
            }
            return .init(scenario: scenario, passed: true,
                         detail: "job counters match event histogram, ordering correct")
        } catch {
            return .init(scenario: scenario, passed: false,
                         detail: "threw: \(error)")
        }
    }

    private static func scenarioBatchedTransactionsCommitInOrder(
        _ scenario: String,
        _ store: any CatalogStore
    ) async -> ScenarioResult {
        do {
            let fix = try makeFixture(scenario: scenario)
            defer { fix.cleanup() }
            // 7 files with batch size 3 → 3 add tx (3 + 3 + 1).
            for i in 0..<7 {
                try writeFile(fix.rootURL.appendingPathComponent("f\(i).mkv"))
            }
            let scanner = DiffScanner(
                catalog: store,
                volumes: fix.registry,
                config: DiffScannerConfig(batchSize: 3)
            )
            let job = try await scanner.scan(rootPath: fix.rootURL.path)
            guard job.filesAdded == 7, job.state == .completed else {
                return .init(scenario: scenario, passed: false,
                             detail: "expected 7 added & completed, got \(job)")
            }
            let counts = try await store.countsSnapshot()
            guard counts.mediaFiles == 7 else {
                return .init(scenario: scenario, passed: false,
                             detail: "row count drift after batched commit: \(counts.mediaFiles)")
            }
            return .init(scenario: scenario, passed: true,
                         detail: "7 files across 3 batches all committed")
        } catch {
            return .init(scenario: scenario, passed: false,
                         detail: "threw: \(error)")
        }
    }

    private static func scenarioRootMissingThrows(
        _ scenario: String,
        _ store: any CatalogStore
    ) async -> ScenarioResult {
        do {
            let fix = try makeFixture(scenario: scenario)
            defer { fix.cleanup() }
            let scanner = DiffScanner(catalog: store, volumes: fix.registry)
            let missing = fix.rootURL.appendingPathComponent("does-not-exist")
            do {
                _ = try await scanner.scan(rootPath: missing.path)
                return .init(scenario: scenario, passed: false,
                             detail: "expected throw, returned successfully")
            } catch DiffScannerError.rootDoesNotExist {
                return .init(scenario: scenario, passed: true,
                             detail: "missing root rejected before any catalog write")
            } catch {
                return .init(scenario: scenario, passed: false,
                             detail: "wrong error: \(error)")
            }
        } catch {
            return .init(scenario: scenario, passed: false,
                         detail: "fixture error: \(error)")
        }
    }

    /// Mount path is the parent directory; scan root is a child of
    /// that mount. Asserts that the catalog stores volume-relative
    /// paths (i.e. `Movies/...`) and that a second scan against the
    /// same tree is a no-op.
    ///
    /// This is the scenario every other test missed: in `makeFixture`,
    /// `mountPath == scanRoot`, so the scanner could store any
    /// strip-the-absolute-path value and idempotency would still hold.
    /// Here the volume is broader than the scan root, which is the
    /// real shape (a library volume mounted at `/Volumes/FixtureDisk`
    /// with the user pointing the scanner at `/Volumes/FixtureDisk/Movies`).
    private static func scenarioNestedRootRelativePaths(
        _ scenario: String,
        _ store: any CatalogStore
    ) async -> ScenarioResult {
        do {
            // Build a `mount/` directory that is registered as the
            // volume, and a `mount/Movies/` directory that is the
            // actual scan root.
            let raw = FileManager.default.temporaryDirectory
                .appendingPathComponent("verify-scanner-\(scenario)-\(UUID().uuidString)",
                                        isDirectory: true)
            try FileManager.default.createDirectory(
                at: raw, withIntermediateDirectories: true
            )
            let mountURL = URL(fileURLWithPath:
                (raw.path as NSString).standardizingPath,
                isDirectory: true
            )
            defer { try? FileManager.default.removeItem(at: mountURL) }

            let scanRoot = mountURL.appendingPathComponent("Movies", isDirectory: true)
            let nested = scanRoot.appendingPathComponent("Subdir", isDirectory: true)
            try FileManager.default.createDirectory(
                at: nested, withIntermediateDirectories: true
            )
            try writeFile(scanRoot.appendingPathComponent("clip.mkv"))
            try writeFile(nested.appendingPathComponent("clip2.mkv"))

            // Register the mount, NOT the scan root.
            let descriptor = VolumeDescriptor(
                uuid: "11111111-1111-1111-1111-\(stableSuffix(for: scenario))",
                mountPath: mountURL.path,
                label: "verify-\(scenario)",
                isRemovable: false,
                isNetwork: false
            )
            let registry = InMemoryVolumeRegistry(seed: [descriptor])
            let scanner = DiffScanner(catalog: store, volumes: registry)

            let firstJob = try await scanner.scan(rootPath: scanRoot.path)
            guard firstJob.state == .completed,
                  firstJob.filesAdded == 2,
                  firstJob.filesObserved == 2 else {
                return .init(scenario: scenario, passed: false,
                             detail: "first scan counters off: \(firstJob)")
            }

            // The catalog must hold volume-relative paths, i.e. paths
            // anchored at the mount, not at the scan root and not
            // absolute. Anything else means the importer's IDs and
            // the scanner's IDs cannot collide on the same file.
            let stored = try await store.allMediaFiles()
            let paths = Set(stored.map { $0.relativePath })
            let expected: Set<String> = [
                "Movies/clip.mkv",
                "Movies/Subdir/clip2.mkv"
            ]
            guard paths == expected else {
                return .init(scenario: scenario, passed: false,
                             detail: "stored paths \(paths) != expected \(expected)")
            }

            // Second scan over the same tree must be a no-op. If the
            // first scan stored absolute-style paths, the prefix
            // filter in `loadExistingMediaFiles` would miss them and
            // the scanner would re-add every file, blowing this check.
            let secondJob = try await scanner.scan(rootPath: scanRoot.path)
            guard secondJob.filesAdded == 0,
                  secondJob.filesUpdated == 0,
                  secondJob.filesRemoved == 0 else {
                return .init(scenario: scenario, passed: false,
                             detail: "rescan with mount!=scanRoot wrote rows: \(secondJob)")
            }

            return .init(scenario: scenario, passed: true,
                         detail: "scan rooted under mount stores volume-relative paths and rescans as no-op")
        } catch {
            return .init(scenario: scenario, passed: false,
                         detail: "threw: \(error)")
        }
    }

    /// Mirrors `LibraryState.scanLibrary()`'s Phase 2E.2 wiring:
    /// `populateCatalogScan` is invoked once per `moviesPaths` entry
    /// and once per `tvShowsPaths` entry against the *same* shared
    /// `CatalogStore` and `VolumeRegistry`. The catalog must end up
    /// holding both roots' files, neither scan may incidentally delete
    /// the other root's rows (the prefix filter inside
    /// `loadExistingMediaFiles` is what keeps those isolated), and a
    /// second pass over both roots must be a clean no-op.
    ///
    /// This is the integration evidence Codex r1 asked for: proves
    /// the wired call pattern is safe, not just that `DiffScanner`
    /// is safe in isolation.
    private static func scenarioAppStateDualRootPopulation(
        _ scenario: String,
        _ store: any CatalogStore
    ) async -> ScenarioResult {
        do {
            let raw = FileManager.default.temporaryDirectory
                .appendingPathComponent("verify-scanner-\(scenario)-\(UUID().uuidString)",
                                        isDirectory: true)
            try FileManager.default.createDirectory(
                at: raw, withIntermediateDirectories: true
            )
            let mountURL = URL(fileURLWithPath:
                (raw.path as NSString).standardizingPath,
                isDirectory: true
            )
            defer { try? FileManager.default.removeItem(at: mountURL) }

            let moviesRoot = mountURL.appendingPathComponent("Movies", isDirectory: true)
            let tvRoot = mountURL.appendingPathComponent("TV", isDirectory: true)
            try FileManager.default.createDirectory(
                at: moviesRoot, withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: tvRoot, withIntermediateDirectories: true
            )
            try writeFile(moviesRoot.appendingPathComponent("movie1.mkv"))
            try writeFile(moviesRoot.appendingPathComponent("movie2.mkv"))
            try writeFile(tvRoot.appendingPathComponent("show.s01e01.mkv"))

            let descriptor = VolumeDescriptor(
                uuid: "11111111-1111-1111-1111-\(stableSuffix(for: scenario))",
                mountPath: mountURL.path,
                label: "verify-\(scenario)",
                isRemovable: false,
                isNetwork: false
            )
            let registry = InMemoryVolumeRegistry(seed: [descriptor])
            let scanner = DiffScanner(catalog: store, volumes: registry)

            // First pass — Movies, then TV. Matches AppState's loop
            // order in scanLibrary().
            let moviesJob1 = try await scanner.scan(rootPath: moviesRoot.path)
            guard moviesJob1.filesAdded == 2,
                  moviesJob1.filesRemoved == 0,
                  moviesJob1.state == .completed else {
                return .init(scenario: scenario, passed: false,
                             detail: "movies first scan off: \(moviesJob1)")
            }
            let tvJob1 = try await scanner.scan(rootPath: tvRoot.path)
            guard tvJob1.filesAdded == 1,
                  tvJob1.filesRemoved == 0,
                  tvJob1.state == .completed else {
                return .init(scenario: scenario, passed: false,
                             detail: "tv first scan off (movies rows leaked into tv diff?): \(tvJob1)")
            }

            // Both roots present in the catalog under their volume-
            // relative prefixes.
            let stored = try await store.allMediaFiles()
            let paths = Set(stored.map { $0.relativePath })
            let expected: Set<String> = [
                "Movies/movie1.mkv",
                "Movies/movie2.mkv",
                "TV/show.s01e01.mkv"
            ]
            guard paths == expected else {
                return .init(scenario: scenario, passed: false,
                             detail: "catalog paths \(paths) != expected \(expected)")
            }

            // Second pass — both roots, both must be no-ops. If the
            // first TV scan had clobbered Movies rows (or vice versa),
            // this rescan would re-add them.
            let moviesJob2 = try await scanner.scan(rootPath: moviesRoot.path)
            guard moviesJob2.filesAdded == 0,
                  moviesJob2.filesUpdated == 0,
                  moviesJob2.filesRemoved == 0 else {
                return .init(scenario: scenario, passed: false,
                             detail: "movies rescan not no-op: \(moviesJob2)")
            }
            let tvJob2 = try await scanner.scan(rootPath: tvRoot.path)
            guard tvJob2.filesAdded == 0,
                  tvJob2.filesUpdated == 0,
                  tvJob2.filesRemoved == 0 else {
                return .init(scenario: scenario, passed: false,
                             detail: "tv rescan not no-op: \(tvJob2)")
            }

            let countsAfter = try await store.countsSnapshot()
            guard countsAfter.mediaFiles == 3 else {
                return .init(scenario: scenario, passed: false,
                             detail: "row count drift after dual rescan: \(countsAfter.mediaFiles)")
            }

            return .init(scenario: scenario, passed: true,
                         detail: "dual-root population isolated; both rescans no-op; 3 rows persistent")
        } catch {
            return .init(scenario: scenario, passed: false,
                         detail: "threw: \(error)")
        }
    }

    /// Wraps a real `CatalogStore` so the Nth `withTransaction` call
    /// throws `CatalogStoreError.ioFailure`. Lets the harness exercise
    /// the contract that `DiffScanner.scan` returns a `.failed` job
    /// (rather than rethrowing) when a mid-scan write fails — the
    /// invariant `populateCatalogScan` relies on to log the difference
    /// between a successful scan and a recorded failure.
    ///
    /// Failure is injected at tx #2 (the first `applyDiff` batch),
    /// because tx #1 is the started-transition write, which `scan`
    /// performs before its `do/catch` block — failing there propagates
    /// out as a thrown error rather than landing in the job state, so
    /// it is not the path under test.
    private static func scenarioFailedJobOnTransactionError(
        _ scenario: String,
        _ store: any CatalogStore
    ) async -> ScenarioResult {
        do {
            let fix = try makeFixture(scenario: scenario)
            defer { fix.cleanup() }
            for i in 0..<5 {
                try writeFile(fix.rootURL.appendingPathComponent("clip\(i).mkv"))
            }
            let failingStore = FailOnNthTransactionStore(
                inner: store,
                failOnCallNumber: 2
            )
            let scanner = DiffScanner(catalog: failingStore, volumes: fix.registry)

            let job: CatalogScanJob
            do {
                job = try await scanner.scan(rootPath: fix.rootURL.path)
            } catch {
                return .init(scenario: scenario, passed: false,
                             detail: "scan rethrew instead of returning failed-state job: \(error)")
            }

            guard job.state == .failed else {
                return .init(scenario: scenario, passed: false,
                             detail: "expected state=failed, got \(job.state)")
            }
            guard let msg = job.lastErrorMessage, !msg.isEmpty else {
                return .init(scenario: scenario, passed: false,
                             detail: "failed job has no lastErrorMessage")
            }

            // The persisted scan_job row must agree with the returned
            // value — otherwise `populateCatalogScan` and an audit
            // reader could see different terminal states for the same
            // job.
            guard let persisted = try await store.scanJob(id: job.id),
                  persisted.state == .failed else {
                return .init(scenario: scenario, passed: false,
                             detail: "persisted scan_job row not in failed state")
            }

            return .init(scenario: scenario, passed: true,
                         detail: "tx error mid-scan → state=failed with lastErrorMessage; persisted row matches")
        } catch {
            return .init(scenario: scenario, passed: false,
                         detail: "fixture error: \(error)")
        }
    }

    // MARK: - Report I/O

    private static func reportsDirectory() throws -> URL {
        if let override = ProcessInfo.processInfo
            .environment["MARQUEE_VERIFY_REPORTS_DIR"] {
            let url = URL(fileURLWithPath: override, isDirectory: true)
            try FileManager.default.createDirectory(
                at: url, withIntermediateDirectories: true
            )
            return url
        }
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = appSupport.appendingPathComponent("Marquee/verify-reports", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        return dir
    }

    private static func writeReport(_ report: Report) throws {
        let dir = try reportsDirectory()
        let stamp = ISO8601DateFormatter().string(from: report.timestamp)
            .replacingOccurrences(of: ":", with: "-")
        let url = dir.appendingPathComponent("verify-scanner-\(stamp).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)
        try data.write(to: url, options: .atomic)
        let line = "verify-scanner: wrote \(url.path)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}

// MARK: - Failing transaction proxy (test-only)

/// Test-only `CatalogStore` proxy that fails the Nth `withTransaction`
/// call with `CatalogStoreError.ioFailure`. Every other method is a
/// straight passthrough to `inner`. Used by
/// `scenarioFailedJobOnTransactionError` to prove the scanner converts
/// mid-scan transactional failures into a `.failed`-state job rather
/// than rethrowing — the contract `populateCatalogScan` depends on.
fileprivate actor FailOnNthTransactionStore: CatalogStore {

    private let inner: any CatalogStore
    private let failOnCallNumber: Int
    private var calls: Int = 0

    init(inner: any CatalogStore, failOnCallNumber: Int) {
        precondition(failOnCallNumber >= 1, "failOnCallNumber must be >= 1")
        self.inner = inner
        self.failOnCallNumber = failOnCallNumber
    }

    var schemaVersion: Int {
        get async { await inner.schemaVersion }
    }

    // MARK: Transaction (the only behavior actually under test)

    func withTransaction<T: Sendable>(
        _ work: @Sendable (any CatalogStore) async throws -> T
    ) async throws -> T {
        calls += 1
        let n = calls
        if n == failOnCallNumber {
            throw CatalogStoreError.ioFailure(
                "FailOnNthTransactionStore: simulated failure on tx #\(n)"
            )
        }
        return try await inner.withTransaction(work)
    }

    // MARK: Passthrough — media files

    func upsert(mediaFile: CatalogMediaFile) async throws {
        try await inner.upsert(mediaFile: mediaFile)
    }
    func mediaFile(id: MediaFileID) async throws -> CatalogMediaFile? {
        try await inner.mediaFile(id: id)
    }
    func allMediaFiles() async throws -> [CatalogMediaFile] {
        try await inner.allMediaFiles()
    }
    func deleteMediaFile(id: MediaFileID) async throws {
        try await inner.deleteMediaFile(id: id)
    }

    // MARK: Passthrough — movies

    func upsert(movie: CatalogMovie) async throws {
        try await inner.upsert(movie: movie)
    }
    func movie(id: MovieID) async throws -> CatalogMovie? {
        try await inner.movie(id: id)
    }
    func allMovies() async throws -> [CatalogMovie] {
        try await inner.allMovies()
    }
    func deleteMovie(id: MovieID) async throws {
        try await inner.deleteMovie(id: id)
    }

    // MARK: Passthrough — shows / seasons / episodes

    func upsert(show: CatalogShow) async throws {
        try await inner.upsert(show: show)
    }
    func show(id: ShowID) async throws -> CatalogShow? {
        try await inner.show(id: id)
    }
    func allShows() async throws -> [CatalogShow] {
        try await inner.allShows()
    }
    func upsert(season: CatalogSeason) async throws {
        try await inner.upsert(season: season)
    }
    func seasons(of show: ShowID) async throws -> [CatalogSeason] {
        try await inner.seasons(of: show)
    }
    func upsert(episode: CatalogEpisode) async throws {
        try await inner.upsert(episode: episode)
    }
    func episode(id: EpisodeID) async throws -> CatalogEpisode? {
        try await inner.episode(id: id)
    }
    func episodes(of season: SeasonID) async throws -> [CatalogEpisode] {
        try await inner.episodes(of: season)
    }

    // MARK: Passthrough — artwork

    func upsert(artwork: CatalogArtworkAsset) async throws {
        try await inner.upsert(artwork: artwork)
    }
    func artwork(for owner: ArtworkOwner) async throws -> [CatalogArtworkAsset] {
        try await inner.artwork(for: owner)
    }

    // MARK: Passthrough — watch state

    func upsert(watchState: CatalogWatchState) async throws {
        try await inner.upsert(watchState: watchState)
    }
    func watchState(
        profile: ProfileID,
        target: WatchTarget
    ) async throws -> CatalogWatchState? {
        try await inner.watchState(profile: profile, target: target)
    }
    func watchStates(profile: ProfileID) async throws -> [CatalogWatchState] {
        try await inner.watchStates(profile: profile)
    }

    // MARK: Passthrough — profiles

    func upsert(profile: CatalogProfile) async throws {
        try await inner.upsert(profile: profile)
    }
    func profile(id: ProfileID) async throws -> CatalogProfile? {
        try await inner.profile(id: id)
    }
    func allProfiles() async throws -> [CatalogProfile] {
        try await inner.allProfiles()
    }

    // MARK: Passthrough — scan jobs and events

    func upsert(scanJob: CatalogScanJob) async throws {
        try await inner.upsert(scanJob: scanJob)
    }
    func scanJob(id: ScanJobID) async throws -> CatalogScanJob? {
        try await inner.scanJob(id: id)
    }
    func allScanJobs() async throws -> [CatalogScanJob] {
        try await inner.allScanJobs()
    }
    func append(scanEvent: CatalogScanEvent) async throws {
        try await inner.append(scanEvent: scanEvent)
    }
    func append(scanEvents: [CatalogScanEvent]) async throws {
        try await inner.append(scanEvents: scanEvents)
    }
    func scanEvents(of job: ScanJobID) async throws -> [CatalogScanEvent] {
        try await inner.scanEvents(of: job)
    }

    // MARK: Passthrough — batch upserts

    func upsert(mediaFiles: [CatalogMediaFile]) async throws {
        try await inner.upsert(mediaFiles: mediaFiles)
    }
    func upsert(movies: [CatalogMovie]) async throws {
        try await inner.upsert(movies: movies)
    }
    func upsert(shows: [CatalogShow]) async throws {
        try await inner.upsert(shows: shows)
    }
    func upsert(seasons: [CatalogSeason]) async throws {
        try await inner.upsert(seasons: seasons)
    }
    func upsert(episodes: [CatalogEpisode]) async throws {
        try await inner.upsert(episodes: episodes)
    }
    func upsert(artwork: [CatalogArtworkAsset]) async throws {
        try await inner.upsert(artwork: artwork)
    }
    func upsert(watchStates: [CatalogWatchState]) async throws {
        try await inner.upsert(watchStates: watchStates)
    }

    // MARK: Passthrough — enrichment composite

    func replaceEnrichment(
        owner: ArtworkOwner,
        core: CatalogEnrichmentCore,
        cast: [CatalogCastEntry],
        artwork: [CatalogArtworkAsset]
    ) async throws {
        try await inner.replaceEnrichment(
            owner: owner,
            core: core,
            cast: cast,
            artwork: artwork
        )
    }

    func replaceMovieIntelligence(
        movieID: MovieID,
        voteCount: Int?,
        popularity: Double?,
        collectionID: Int?,
        collectionName: String?,
        keywords: [CatalogMovieKeyword],
        edges: [CatalogMovieEdge]
    ) async throws {
        try await inner.replaceMovieIntelligence(
            movieID: movieID,
            voteCount: voteCount,
            popularity: popularity,
            collectionID: collectionID,
            collectionName: collectionName,
            keywords: keywords,
            edges: edges
        )
    }

    func enrichmentSnapshot() async throws -> CatalogEnrichmentSnapshot {
        try await inner.enrichmentSnapshot()
    }

    func movieIntelligenceCoverageReport() async throws -> CatalogMovieIntelligenceCoverageReport {
        try await inner.movieIntelligenceCoverageReport()
    }

    // MARK: Passthrough — counts

    func countsSnapshot() async throws -> CatalogCounts {
        try await inner.countsSnapshot()
    }
}

#endif
