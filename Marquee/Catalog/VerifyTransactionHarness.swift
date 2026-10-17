//
//  VerifyTransactionHarness.swift
//  Marquee
//
//  Phase 1 verification harness for the `CatalogStore` transaction
//  contract. Behavioral tests for:
//
//    1. Rollback         — tx that throws restores prior state
//    2. NestedRejection  — nested `withTransaction` throws
//                          `.nestedTransactionNotSupported`
//    3. BatchAtomicity   — a batch upsert participating in a rolled-back
//                          tx leaves no rows behind (proves the batch
//                          rolls back as one unit, not row-by-row)
//    4. ConcurrentWriteIsolation — a write from another task that races
//                          a rolled-back tx is queued behind it and
//                          persists, proving that the tx snapshot did
//                          NOT silently include the unrelated write
//    5. LateTaskIsolation — a child task spawned inside a tx that
//                          inherits the TaskLocal transaction token but
//                          attempts to write AFTER the parent tx ends
//                          must take the write gate normally (must not
//                          bypass via the stale inherited token).
//                          This is the proof that the actor-side
//                          `activeTransactionToken` cleared in `defer`
//                          guards against late inherited-task writes.
//    6. ScanJobLifecycle — upserting a scan job (queued → running →
//                          completed) preserves its append-only audit
//                          events. Catches `INSERT OR REPLACE` regression
//                          where REPLACE + ON DELETE CASCADE wipes the
//                          job's events on every state transition.
//    7. ScanEventDuplicateRejection — appending an event with an ID that
//                          already exists must throw, both single and
//                          mid-batch. Append-only contract: a duplicate
//                          ID is a generator bug, not a re-emit.
//    8. SchemaVersionParity — both stores must report the same
//                          `schemaVersion`, matching `CatalogSchema
//                          .currentVersion`. Catches the drift that
//                          happened when only SQLite was bumped to v2
//                          while in-memory still reported v1.
//    9. ScanEventOrphanRejection — appending an event whose `jobID`
//                          does not match any existing scan job must
//                          throw, both single and within a batch.
//                          SQLite enforces via the NOT NULL FK; in-
//                          memory mirrors the check. Locks store parity
//                          on the orphan-event invariant.
//   10. ScanJobIdentityPreservation — `rootPath` and `createdAt` are
//                          immutable identity fields. Re-upserting the
//                          same `ScanJobID` with different values for
//                          those fields must preserve the originals,
//                          identically across both stores. Catches the
//                          drift where SQLite excluded them from
//                          `DO UPDATE` while in-memory replaced the
//                          whole row.
//
//  Each scenario runs against BOTH `InMemoryCatalogStore` and
//  `SQLiteCatalogStore` (fresh on-disk database in a temp directory)
//  so any divergence between the two implementations is caught here.
//
//  DEBUG-ONLY. The entire body is gated by `#if DEBUG` so the harness
//  is excluded from Release builds. Activated by `--verify-transactions`.
//
//  Exit codes: 0 = all pass, 1 = at least one scenario failed,
//  2 = internal error.
//

#if DEBUG

import Foundation

public enum VerifyTransactionHarness {

    public static let launchArgument = "--verify-transactions"

    // MARK: - Report types

    public struct Report: Codable {
        public let timestamp: String
        public let scenarios: [ScenarioResult]
        public let allPassed: Bool
    }

    public struct ScenarioResult: Codable {
        public let scenario: String
        public let storeKind: String
        public let passed: Bool
        public let detail: String
    }

    // MARK: - Entry point

    public static func runIfRequested() {
        guard CommandLine.arguments.contains(launchArgument) else { return }

        let semaphore = DispatchSemaphore(value: 0)
        let result = ExitCodeBox()

        Task.detached {
            do {
                let code = try await runHarness()
                result.set(code)
            } catch {
                let line = "verify-transactions: error: \(error)\n"
                FileHandle.standardError.write(Data(line.utf8))
                result.set(2)
            }
            semaphore.signal()
        }

        semaphore.wait()
        exit(result.value)
    }

    private final class ExitCodeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Int32 = 2
        func set(_ code: Int32) { lock.lock(); stored = code; lock.unlock() }
        var value: Int32 { lock.lock(); defer { lock.unlock() }; return stored }
    }

    // MARK: - Implementation

    private static func runHarness() async throws -> Int32 {
        var results: [ScenarioResult] = []

        for storeKind in StoreKind.allCases {
            try await withFreshStore(kind: storeKind) { store in
                results.append(await runRollback(store, kind: storeKind))
            }
            try await withFreshStore(kind: storeKind) { store in
                results.append(await runNestedRejection(store, kind: storeKind))
            }
            try await withFreshStore(kind: storeKind) { store in
                results.append(await runBatchAtomicity(store, kind: storeKind))
            }
            try await withFreshStore(kind: storeKind) { store in
                results.append(await runConcurrentWriteIsolation(store, kind: storeKind))
            }
            try await withFreshStore(kind: storeKind) { store in
                results.append(await runLateTaskIsolation(store, kind: storeKind))
            }
            try await withFreshStore(kind: storeKind) { store in
                results.append(await runScanJobLifecycle(store, kind: storeKind))
            }
            try await withFreshStore(kind: storeKind) { store in
                results.append(await runScanEventDuplicateRejection(store, kind: storeKind))
            }
            try await withFreshStore(kind: storeKind) { store in
                results.append(await runSchemaVersionParity(store, kind: storeKind))
            }
            try await withFreshStore(kind: storeKind) { store in
                results.append(await runScanEventOrphanRejection(store, kind: storeKind))
            }
            try await withFreshStore(kind: storeKind) { store in
                results.append(await runScanJobIdentityPreservation(store, kind: storeKind))
            }
        }
        results.append(await runV4MigrationFixture())
        results.append(runV4MigrationFailureRollback())
        if let copyPath = ProcessInfo.processInfo.environment["MARQUEE_VERIFY_MIGRATION_COPY_PATH"],
           !copyPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            results.append(await runV4MigrationCopyRehearsal(path: copyPath))
        }

        let allPassed = results.allSatisfy { $0.passed }
        let report = Report(
            timestamp: iso8601(Date()),
            scenarios: results,
            allPassed: allPassed
        )
        try writeReport(report)

        for r in results {
            let mark = r.passed ? "PASS" : "FAIL"
            let line = "verify-transactions: \(mark) [\(r.storeKind)] \(r.scenario): \(r.detail)\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
        let summary = "verify-transactions: outcome=\(allPassed ? "verified" : "failed")"
            + " passed=\(results.filter { $0.passed }.count)/\(results.count)\n"
        FileHandle.standardError.write(Data(summary.utf8))

        return allPassed ? 0 : 1
    }

    // MARK: - Store kind harness

    private enum StoreKind: String, CaseIterable {
        case inMemory = "in-memory"
        case sqlite   = "sqlite"
    }

    /// Builds a fresh store for the run, executes `work`, and tears down
    /// any on-disk state. SQLite stores are created in a unique temp dir
    /// and deleted afterwards, so each scenario sees a pristine database.
    private static func withFreshStore(
        kind: StoreKind,
        _ work: (CatalogStore) async throws -> Void
    ) async throws {
        switch kind {
        case .inMemory:
            try await work(InMemoryCatalogStore())
        case .sqlite:
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("marquee-tx-verify-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let dbPath = dir.appendingPathComponent("catalog.sqlite").path
            let store = try SQLiteCatalogStore(path: dbPath)
            try await work(store)
        }
    }

    // MARK: - Fixtures

    private static let fixtureVolumeUUID = "tx-verify"

    private static func makeFile(_ tag: String) -> CatalogMediaFile {
        let rel = "fixture/\(tag).mkv"
        let id = MediaIdentity.mediaFileID(volumeUUID: fixtureVolumeUUID, relativePath: rel)
        return CatalogMediaFile(
            id: id,
            volumeUUID: fixtureVolumeUUID,
            relativePath: rel,
            absolutePathSnapshot: "/tmp/\(rel)",
            fileExtension: "mkv",
            fileSize: 1,
            modificationDate: Date(timeIntervalSince1970: 0),
            durationSeconds: nil,
            contentHash: nil,
            dateAdded: Date(timeIntervalSince1970: 0)
        )
    }

    private struct CanaryError: Error, Equatable {}

    // MARK: - Scenario 1: rollback

    private static func runRollback(
        _ store: CatalogStore,
        kind: StoreKind
    ) async -> ScenarioResult {
        let row = makeFile("rollback")
        do {
            try await store.withTransaction { tx in
                try await tx.upsert(mediaFile: row)
                throw CanaryError()
            }
            return ScenarioResult(
                scenario: "rollback",
                storeKind: kind.rawValue,
                passed: false,
                detail: "withTransaction did not rethrow"
            )
        } catch is CanaryError {
            // expected — verify state untouched
        } catch {
            return ScenarioResult(
                scenario: "rollback",
                storeKind: kind.rawValue,
                passed: false,
                detail: "unexpected error: \(error)"
            )
        }
        do {
            let observed = try await store.mediaFile(id: row.id)
            let passed = observed == nil
            return ScenarioResult(
                scenario: "rollback",
                storeKind: kind.rawValue,
                passed: passed,
                detail: passed
                    ? "row absent after thrown tx"
                    : "row present after thrown tx — rollback failed"
            )
        } catch {
            return ScenarioResult(
                scenario: "rollback",
                storeKind: kind.rawValue,
                passed: false,
                detail: "readback error: \(error)"
            )
        }
    }

    // MARK: - Scenario 2: nested rejection

    private static func runNestedRejection(
        _ store: CatalogStore,
        kind: StoreKind
    ) async -> ScenarioResult {
        do {
            try await store.withTransaction { tx in
                _ = try await tx.withTransaction { _ in
                    return ()
                }
            }
            return ScenarioResult(
                scenario: "nestedRejection",
                storeKind: kind.rawValue,
                passed: false,
                detail: "nested withTransaction did not throw"
            )
        } catch CatalogStoreError.nestedTransactionNotSupported {
            return ScenarioResult(
                scenario: "nestedRejection",
                storeKind: kind.rawValue,
                passed: true,
                detail: "threw CatalogStoreError.nestedTransactionNotSupported"
            )
        } catch {
            return ScenarioResult(
                scenario: "nestedRejection",
                storeKind: kind.rawValue,
                passed: false,
                detail: "unexpected error: \(error)"
            )
        }
    }

    // MARK: - Scenario 3: batch atomicity inside rolled-back tx

    private static func runBatchAtomicity(
        _ store: CatalogStore,
        kind: StoreKind
    ) async -> ScenarioResult {
        let r1 = makeFile("batch-1")
        let r2 = makeFile("batch-2")
        let r3 = makeFile("batch-3")
        do {
            try await store.withTransaction { tx in
                try await tx.upsert(mediaFiles: [r1, r2, r3])
                throw CanaryError()
            }
            return ScenarioResult(
                scenario: "batchAtomicity",
                storeKind: kind.rawValue,
                passed: false,
                detail: "tx did not throw"
            )
        } catch is CanaryError {
            // expected
        } catch {
            return ScenarioResult(
                scenario: "batchAtomicity",
                storeKind: kind.rawValue,
                passed: false,
                detail: "unexpected error: \(error)"
            )
        }
        do {
            let f1 = try await store.mediaFile(id: r1.id)
            let f2 = try await store.mediaFile(id: r2.id)
            let f3 = try await store.mediaFile(id: r3.id)
            let allAbsent = f1 == nil && f2 == nil && f3 == nil
            return ScenarioResult(
                scenario: "batchAtomicity",
                storeKind: kind.rawValue,
                passed: allAbsent,
                detail: allAbsent
                    ? "all 3 batch rows absent after rollback"
                    : "partial rows survived: r1=\(f1 != nil) r2=\(f2 != nil) r3=\(f3 != nil)"
            )
        } catch {
            return ScenarioResult(
                scenario: "batchAtomicity",
                storeKind: kind.rawValue,
                passed: false,
                detail: "readback error: \(error)"
            )
        }
    }

    // MARK: - Scenario 4: concurrent write isolation

    /// Task A holds a tx that throws after a small delay. Task B issues
    /// an unrelated upsert during A's window. A's writes must roll back;
    /// B's write must persist. If B were silently included in A's
    /// snapshot, B would also vanish — that failure mode is exactly what
    /// the write-gate contract is meant to prevent.
    ///
    /// Timing: A holds the gate for ~80ms. B starts ~10ms in. The total
    /// scenario completes in <250ms. Insensitive to scheduler jitter on
    /// a dev machine.
    private static func runConcurrentWriteIsolation(
        _ store: CatalogStore,
        kind: StoreKind
    ) async -> ScenarioResult {
        let txRow1 = makeFile("conc-tx-1")
        let txRow2 = makeFile("conc-tx-2")
        let outsideRow = makeFile("conc-outside")

        let txTask = Task<Void, Never> {
            do {
                try await store.withTransaction { tx in
                    try await tx.upsert(mediaFile: txRow1)
                    try await Task.sleep(nanoseconds: 80_000_000)
                    try await tx.upsert(mediaFile: txRow2)
                    throw CanaryError()
                }
            } catch {
                // CanaryError expected; any other error is a test bug
                // we surface via empty store state below.
            }
        }

        // Give txTask a head start to enter the tx and acquire the gate.
        try? await Task.sleep(nanoseconds: 10_000_000)

        let outsideTask = Task<Bool, Never> {
            do {
                try await store.upsert(mediaFile: outsideRow)
                return true
            } catch {
                return false
            }
        }

        await txTask.value
        let outsideOk = await outsideTask.value

        do {
            let id1 = try await store.mediaFile(id: txRow1.id)
            let id2 = try await store.mediaFile(id: txRow2.id)
            let idOut = try await store.mediaFile(id: outsideRow.id)
            let txAbsent = id1 == nil && id2 == nil
            let outsidePresent = idOut != nil
            let passed = outsideOk && txAbsent && outsidePresent
            return ScenarioResult(
                scenario: "concurrentWriteIsolation",
                storeKind: kind.rawValue,
                passed: passed,
                detail: "txAbsent=\(txAbsent) outsidePresent=\(outsidePresent) outsideOk=\(outsideOk)"
            )
        } catch {
            return ScenarioResult(
                scenario: "concurrentWriteIsolation",
                storeKind: kind.rawValue,
                passed: false,
                detail: "readback error: \(error)"
            )
        }
    }

    // MARK: - Scenario 5: late-task isolation

    /// Spawns an unstructured child task INSIDE a transaction; the child
    /// inherits the `inheritedTransactionToken` TaskLocal at creation
    /// time. The child sleeps past the end of the parent transaction,
    /// then attempts to write while a SEPARATE holder transaction is
    /// active. Token-pair semantics:
    ///
    ///   - inherited TaskLocal token: still set in the child (TaskLocal
    ///     is captured at task creation, not cleared when the parent's
    ///     scope exits).
    ///   - actor-side `activeTransactionToken`: cleared in the parent
    ///     transaction's `defer`.
    ///
    /// Therefore `isInsideOwnTransaction` returns false in the child,
    /// the child takes the write gate, and BLOCKS until the holder
    /// transaction releases. Mid-way through the holder window, the
    /// child's row must NOT be visible. After the holder commits, the
    /// child's row appears.
    ///
    /// If the actor-side guard were missing — i.e. the original
    /// TaskLocal-only design Codex flagged — the child would bypass the
    /// gate and the row would appear during the holder's tx.
    ///
    /// Timing budget: holder holds for 200ms, mid-snapshot taken at
    /// ~100ms. Child sleeps for 50ms.
    private static func runLateTaskIsolation(
        _ store: CatalogStore,
        kind: StoreKind
    ) async -> ScenarioResult {
        let parentRow = makeFile("late-parent")
        let lateRow = makeFile("late-child")
        let holderRow = makeFile("late-holder")

        let childHandle: Task<Bool, Never>
        do {
            childHandle = try await store.withTransaction { tx -> Task<Bool, Never> in
                try await tx.upsert(mediaFile: parentRow)
                return Task<Bool, Never> {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    do {
                        try await store.upsert(mediaFile: lateRow)
                        return true
                    } catch {
                        return false
                    }
                }
            }
        } catch {
            return ScenarioResult(
                scenario: "lateTaskIsolation",
                storeKind: kind.rawValue,
                passed: false,
                detail: "parent tx unexpectedly threw: \(error)"
            )
        }

        // Start a holder tx that occupies the gate for 200ms.
        let holderTask = Task<Bool, Never> {
            do {
                try await store.withTransaction { tx in
                    try await tx.upsert(mediaFile: holderRow)
                    try await Task.sleep(nanoseconds: 200_000_000)
                }
                return true
            } catch {
                return false
            }
        }

        // Mid-snapshot: holder is still holding, child's 50ms sleep
        // expired, so child has been trying to write for ~50ms.
        try? await Task.sleep(nanoseconds: 100_000_000)
        let lateRowMid: CatalogMediaFile?
        do {
            lateRowMid = try await store.mediaFile(id: lateRow.id)
        } catch {
            return ScenarioResult(
                scenario: "lateTaskIsolation",
                storeKind: kind.rawValue,
                passed: false,
                detail: "mid-snapshot read failed: \(error)"
            )
        }

        let holderOk = await holderTask.value
        let childOk = await childHandle.value

        do {
            let lateRowFinal = try await store.mediaFile(id: lateRow.id)
            let holderFinal = try await store.mediaFile(id: holderRow.id)
            let parentFinal = try await store.mediaFile(id: parentRow.id)

            // Mid-snapshot must NOT contain the late row (proves child
            // was blocked behind the holder's gate). Final snapshot must
            // contain all three (parent committed, holder committed,
            // child eventually committed after holder released).
            let bypassDetected = lateRowMid != nil
            let allFinalPresent =
                lateRowFinal != nil && holderFinal != nil && parentFinal != nil
            let passed = !bypassDetected
                && allFinalPresent
                && holderOk
                && childOk
            return ScenarioResult(
                scenario: "lateTaskIsolation",
                storeKind: kind.rawValue,
                passed: passed,
                detail: "bypassDetected=\(bypassDetected)"
                    + " allFinalPresent=\(allFinalPresent)"
                    + " holderOk=\(holderOk)"
                    + " childOk=\(childOk)"
            )
        } catch {
            return ScenarioResult(
                scenario: "lateTaskIsolation",
                storeKind: kind.rawValue,
                passed: false,
                detail: "final readback error: \(error)"
            )
        }
    }

    // MARK: - Scenario 6: scan job lifecycle preserves events
    //
    // Codex r1 caught: `INSERT OR REPLACE` + `ON DELETE CASCADE` on
    // scan_event.job_id wiped the audit trail on every state transition.
    // The fix moved scan_job upsert to `ON CONFLICT(id) DO UPDATE`. This
    // scenario locks that fix in: write a job, append an event, transition
    // the job through running → completed, and verify the event survives.

    private static func makeScanJob(
        _ id: String,
        state: ScanJobState,
        files: Int = 0
    ) -> CatalogScanJob {
        CatalogScanJob(
            id: ScanJobID(rawValue: id),
            rootPath: "/tmp/fixture-root",
            volumeUUID: fixtureVolumeUUID,
            state: state,
            createdAt: Date(timeIntervalSince1970: 0),
            startedAt: state == .queued ? nil : Date(timeIntervalSince1970: 1),
            completedAt: state == .completed ? Date(timeIntervalSince1970: 2) : nil,
            lastErrorMessage: nil,
            filesObserved: files,
            filesAdded: files,
            filesUpdated: 0,
            filesRemoved: 0
        )
    }

    private static func makeScanEvent(
        _ id: String,
        job: ScanJobID,
        kind: ScanEventKind = .fileSeen
    ) -> CatalogScanEvent {
        CatalogScanEvent(
            id: ScanEventID(rawValue: id),
            jobID: job,
            kind: kind,
            timestamp: Date(timeIntervalSince1970: 1),
            path: "fixture/seen.mkv",
            detail: nil
        )
    }

    private static func runScanJobLifecycle(
        _ store: CatalogStore,
        kind: StoreKind
    ) async -> ScenarioResult {
        let jobID = ScanJobID(rawValue: "lifecycle-job")
        let queued = makeScanJob(jobID.rawValue, state: .queued)
        let running = makeScanJob(jobID.rawValue, state: .running, files: 5)
        let completed = makeScanJob(jobID.rawValue, state: .completed, files: 10)
        let event = makeScanEvent("lifecycle-event", job: jobID)

        do {
            try await store.upsert(scanJob: queued)
            try await store.append(scanEvent: event)
            try await store.upsert(scanJob: running)
            try await store.upsert(scanJob: completed)

            let job = try await store.scanJob(id: jobID)
            let events = try await store.scanEvents(of: jobID)
            let jobOk = job?.state == .completed && job?.filesObserved == 10
            let eventOk = events.count == 1 && events.first?.id == event.id
            let passed = jobOk && eventOk
            return ScenarioResult(
                scenario: "scanJobLifecycle",
                storeKind: kind.rawValue,
                passed: passed,
                detail: "jobOk=\(jobOk) events=\(events.count) finalState=\(job?.state.rawValue ?? "nil")"
            )
        } catch {
            return ScenarioResult(
                scenario: "scanJobLifecycle",
                storeKind: kind.rawValue,
                passed: false,
                detail: "unexpected error: \(error)"
            )
        }
    }

    // MARK: - Scenario 7: duplicate scan event rejection
    //
    // Both stores must reject a duplicate ScanEventID — single and within
    // a batch. SQLite throws via primary-key constraint; in-memory throws
    // CatalogStoreError.ioFailure with a "duplicate scan event id" message.
    // The harness only cares that *some* error is thrown and that the
    // original row remains untouched.

    private static func runScanEventDuplicateRejection(
        _ store: CatalogStore,
        kind: StoreKind
    ) async -> ScenarioResult {
        let jobID = ScanJobID(rawValue: "dup-job")
        let job = makeScanJob(jobID.rawValue, state: .queued)
        let firstID = ScanEventID(rawValue: "dup-event-1")
        let original = CatalogScanEvent(
            id: firstID,
            jobID: jobID,
            kind: .fileSeen,
            timestamp: Date(timeIntervalSince1970: 1),
            path: "fixture/original.mkv",
            detail: "original"
        )
        let collision = CatalogScanEvent(
            id: firstID,
            jobID: jobID,
            kind: .fileFailed,
            timestamp: Date(timeIntervalSince1970: 2),
            path: "fixture/collision.mkv",
            detail: "collision"
        )

        do {
            try await store.upsert(scanJob: job)
            try await store.append(scanEvent: original)
        } catch {
            return ScenarioResult(
                scenario: "scanEventDuplicateRejection",
                storeKind: kind.rawValue,
                passed: false,
                detail: "setup failed: \(error)"
            )
        }

        // Single-append duplicate must throw.
        var singleRejected = false
        do {
            try await store.append(scanEvent: collision)
        } catch {
            singleRejected = true
        }

        // Batch with internal duplicate must also throw and leave no
        // partial writes (the second/third batch IDs are fresh; if the
        // store leaks, those would appear).
        let batchDupID = ScanEventID(rawValue: "dup-event-2")
        let batchEvent2 = makeScanEvent("dup-event-2", job: jobID)
        let batchEvent2Dup = CatalogScanEvent(
            id: batchDupID,
            jobID: jobID,
            kind: .fileFailed,
            timestamp: Date(timeIntervalSince1970: 3),
            path: "fixture/batch-dup.mkv",
            detail: "batch-dup"
        )
        var batchRejected = false
        do {
            try await store.append(scanEvents: [batchEvent2, batchEvent2Dup])
        } catch {
            batchRejected = true
        }

        do {
            let events = try await store.scanEvents(of: jobID)
            // Original survives; collision did not overwrite.
            let originalSurvived = events.contains { e in
                e.id == firstID && e.detail == "original"
            }
            // Batch was all-or-nothing: dup-event-2 must NOT be present
            // since the batch was rejected. (SQLite enforces via tx
            // rollback; in-memory enforces via pre-validation.)
            let batchAtomic = events.allSatisfy { $0.id != batchDupID }
            let passed = singleRejected
                && batchRejected
                && originalSurvived
                && batchAtomic
            return ScenarioResult(
                scenario: "scanEventDuplicateRejection",
                storeKind: kind.rawValue,
                passed: passed,
                detail: "single=\(singleRejected)"
                    + " batch=\(batchRejected)"
                    + " originalSurvived=\(originalSurvived)"
                    + " batchAtomic=\(batchAtomic)"
            )
        } catch {
            return ScenarioResult(
                scenario: "scanEventDuplicateRejection",
                storeKind: kind.rawValue,
                passed: false,
                detail: "readback error: \(error)"
            )
        }
    }

    // MARK: - Scenario 8: schema version parity

    private static func runSchemaVersionParity(
        _ store: CatalogStore,
        kind: StoreKind
    ) async -> ScenarioResult {
        let reported = await store.schemaVersion
        let expected = CatalogSchema.currentVersion
        let passed = reported == expected
        return ScenarioResult(
            scenario: "schemaVersionParity",
            storeKind: kind.rawValue,
            passed: passed,
            detail: "reported=\(reported) expected=\(expected)"
        )
    }

    // MARK: - Scenario 9: orphan scan event rejection

    private static func runScanEventOrphanRejection(
        _ store: CatalogStore,
        kind: StoreKind
    ) async -> ScenarioResult {
        // Reference a job that was never written. SQLite rejects via FK;
        // in-memory rejects via the parent-job invariant check.
        let missingJob = ScanJobID(rawValue: "orphan-job")
        let orphan = makeScanEvent("orphan-event-1", job: missingJob)

        var singleRejected = false
        do {
            try await store.append(scanEvent: orphan)
        } catch {
            singleRejected = true
        }

        // Batch with one good (parented) event and one orphan. The whole
        // batch must roll back / pre-validate so the good event does NOT
        // land. Establish a real parent first for the good event.
        let realJobID = ScanJobID(rawValue: "real-parent-job")
        let realJob = makeScanJob(realJobID.rawValue, state: .queued)
        do {
            try await store.upsert(scanJob: realJob)
        } catch {
            return ScenarioResult(
                scenario: "scanEventOrphanRejection",
                storeKind: kind.rawValue,
                passed: false,
                detail: "setup: real job upsert failed: \(error)"
            )
        }
        let goodEventID = ScanEventID(rawValue: "good-event-batch")
        let good = makeScanEvent(goodEventID.rawValue, job: realJobID)
        let orphanInBatch = makeScanEvent("orphan-event-batch", job: missingJob)

        var batchRejected = false
        do {
            try await store.append(scanEvents: [good, orphanInBatch])
        } catch {
            batchRejected = true
        }

        do {
            // The orphan single attempt must not have inserted anything.
            // The batch attempt must be all-or-nothing — `good` must NOT
            // be present even though it was a valid event. (For SQLite
            // this comes from BEGIN IMMEDIATE/ROLLBACK around runMany;
            // for in-memory it comes from pre-validating the whole batch
            // before mutating.)
            let goodEvents = try await store.scanEvents(of: realJobID)
            let orphanEvents = try await store.scanEvents(of: missingJob)
            let goodAbsent = goodEvents.allSatisfy { $0.id != goodEventID }
            let orphanAbsent = orphanEvents.isEmpty
            let passed = singleRejected
                && batchRejected
                && goodAbsent
                && orphanAbsent
            return ScenarioResult(
                scenario: "scanEventOrphanRejection",
                storeKind: kind.rawValue,
                passed: passed,
                detail: "single=\(singleRejected)"
                    + " batch=\(batchRejected)"
                    + " goodAbsent=\(goodAbsent)"
                    + " orphanAbsent=\(orphanAbsent)"
            )
        } catch {
            return ScenarioResult(
                scenario: "scanEventOrphanRejection",
                storeKind: kind.rawValue,
                passed: false,
                detail: "readback error: \(error)"
            )
        }
    }

    // MARK: - Scenario 10: scan job identity preservation

    private static func runScanJobIdentityPreservation(
        _ store: CatalogStore,
        kind: StoreKind
    ) async -> ScenarioResult {
        let jobID = ScanJobID(rawValue: "identity-job")
        let originalRoot = "/tmp/original-root"
        let originalCreated = Date(timeIntervalSince1970: 100)
        let mutatedRoot = "/tmp/mutated-root"
        let mutatedCreated = Date(timeIntervalSince1970: 999)

        let original = CatalogScanJob(
            id: jobID,
            rootPath: originalRoot,
            volumeUUID: fixtureVolumeUUID,
            state: .queued,
            createdAt: originalCreated,
            startedAt: nil,
            completedAt: nil,
            lastErrorMessage: nil,
            filesObserved: 0,
            filesAdded: 0,
            filesUpdated: 0,
            filesRemoved: 0
        )
        let mutated = CatalogScanJob(
            id: jobID,
            rootPath: mutatedRoot,
            volumeUUID: fixtureVolumeUUID,
            state: .running,
            createdAt: mutatedCreated,
            startedAt: Date(timeIntervalSince1970: 200),
            completedAt: nil,
            lastErrorMessage: nil,
            filesObserved: 7,
            filesAdded: 7,
            filesUpdated: 0,
            filesRemoved: 0
        )

        do {
            try await store.upsert(scanJob: original)
            try await store.upsert(scanJob: mutated)
            guard let observed = try await store.scanJob(id: jobID) else {
                return ScenarioResult(
                    scenario: "scanJobIdentityPreservation",
                    storeKind: kind.rawValue,
                    passed: false,
                    detail: "job not found after upsert"
                )
            }
            // Identity fields must NOT change.
            let rootPreserved = observed.rootPath == originalRoot
            let createdPreserved = observed.createdAt == originalCreated
            // Mutable fields MUST follow the second upsert.
            let stateUpdated = observed.state == .running
            let countersUpdated = observed.filesObserved == 7
            let passed = rootPreserved
                && createdPreserved
                && stateUpdated
                && countersUpdated
            return ScenarioResult(
                scenario: "scanJobIdentityPreservation",
                storeKind: kind.rawValue,
                passed: passed,
                detail: "rootPreserved=\(rootPreserved)"
                    + " createdPreserved=\(createdPreserved)"
                    + " stateUpdated=\(stateUpdated)"
                    + " countersUpdated=\(countersUpdated)"
            )
        } catch {
            return ScenarioResult(
                scenario: "scanJobIdentityPreservation",
                storeKind: kind.rawValue,
                passed: false,
                detail: "unexpected error: \(error)"
            )
        }
    }

    // MARK: - Scenario 11: v3 -> v4 migration fixture

    private static func runV4MigrationFixture() async -> ScenarioResult {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("marquee-v4-migration-\(UUID().uuidString)", isDirectory: true)
        let dbPath = dir.appendingPathComponent("catalog.sqlite").path
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }

            try createV3FixtureDatabase(at: dbPath)
            let store = try SQLiteCatalogStore(path: dbPath)

            let version = try withConnection(path: dbPath) { conn in
                try conn.userVersion
            }
            guard version == 4 else {
                return ScenarioResult(
                    scenario: "v4MigrationFixture",
                    storeKind: StoreKind.sqlite.rawValue,
                    passed: false,
                    detail: "user_version=\(version) expected=4"
                )
            }

            let schemaOk = try withConnection(path: dbPath) { conn -> Bool in
                let cols = try tableColumns(conn, table: "movie")
                let tables = try sqliteMasterNames(conn, type: "table")
                let indexes = try sqliteMasterNames(conn, type: "index")
                let expectedCols: Set<String> = [
                    "vote_count", "popularity", "collection_id", "collection_name",
                ]
                let expectedTables: Set<String> = ["movie_keyword", "movie_edge"]
                let expectedIndexes: Set<String> = [
                    "movie_tmdb_id_idx",
                    "movie_collection_idx",
                    "movie_keyword_name_idx",
                    "movie_keyword_movie_idx",
                    "movie_edge_source_type_rank_idx",
                    "movie_edge_target_type_idx",
                ]
                return expectedCols.isSubset(of: cols)
                    && expectedTables.isSubset(of: tables)
                    && expectedIndexes.isSubset(of: indexes)
            }

            let dataOk = try withConnection(path: dbPath) { conn -> Bool in
                let rowCountsOk =
                    try conn.queryCount("SELECT count(*) FROM movie") == 2
                    && conn.queryCount("SELECT count(*) FROM show") == 1
                    && conn.queryCount("SELECT count(*) FROM episode") == 1
                    && conn.queryCount("SELECT count(*) FROM scan_job") == 1
                    && conn.queryCount("SELECT count(*) FROM scan_event") == 1
                    && conn.queryCount("SELECT count(*) FROM profile") == 1
                    && conn.queryCount("SELECT count(*) FROM watch_state") == 1
                let extensionTablesEmpty =
                    try conn.queryCount("SELECT count(*) FROM movie_keyword") == 0
                    && conn.queryCount("SELECT count(*) FROM movie_edge") == 0
                let nullsOk = try conn.queryOne(
                    """
                    SELECT vote_count, popularity, collection_id, collection_name
                    FROM movie WHERE id = 'movie-source'
                    """,
                    map: { stmt in
                        stmt.optionalInt(0) == nil
                            && stmt.optionalDouble(1) == nil
                            && stmt.optionalInt(2) == nil
                            && stmt.optionalText(3) == nil
                    }
                ) ?? false
                return rowCountsOk && extensionTablesEmpty && nullsOk
            }

            _ = try SQLiteCatalogStore(path: dbPath)
            let reopenVersion = try withConnection(path: dbPath) { conn in
                try conn.userVersion
            }
            let reopenOk = reopenVersion == 4

            try seedV4ExtensionRows(dbPath: dbPath)
            let changed = CatalogMovie(
                id: MovieID(rawValue: "movie-source"),
                primaryFile: MediaFileID(rawValue: "file-source"),
                title: "Changed Source",
                year: 2002,
                tmdbID: 9001,
                overview: "Changed overview",
                runtimeMinutes: 101,
                certification: "PG-13",
                releaseDate: "2002-02-02",
                genres: ["Drama", "Mystery"],
                voteAverage: 8.2,
                director: "Changed Director"
            )
            try await store.upsert(movie: changed)

            let preservedOk = try withConnection(path: dbPath) { conn -> Bool in
                let movieOk = try conn.queryOne(
                    """
                    SELECT title, vote_count, popularity, collection_id, collection_name
                    FROM movie WHERE id = 'movie-source'
                    """,
                    map: { stmt in
                        stmt.text(0) == "Changed Source"
                            && stmt.optionalInt(1) == 321
                            && stmt.optionalDouble(2) == 42.5
                            && stmt.optionalInt(3) == 77
                            && stmt.optionalText(4) == "Fixture Collection"
                    }
                ) ?? false
                let keywordOk = try conn.queryCount(
                    "SELECT count(*) FROM movie_keyword WHERE movie_id = 'movie-source'"
                ) == 1
                let edgeOk = try conn.queryCount(
                    "SELECT count(*) FROM movie_edge WHERE source_movie_id = 'movie-source'"
                ) == 1
                return movieOk && keywordOk && edgeOk
            }

            try await store.deleteMovie(id: MovieID(rawValue: "movie-source"))
            let cascadeOk = try withConnection(path: dbPath) { conn -> Bool in
                try conn.queryCount("SELECT count(*) FROM movie_keyword") == 0
                    && conn.queryCount("SELECT count(*) FROM movie_edge") == 0
            }

            let passed = schemaOk && dataOk && reopenOk && preservedOk && cascadeOk
            return ScenarioResult(
                scenario: "v4MigrationFixture",
                storeKind: StoreKind.sqlite.rawValue,
                passed: passed,
                detail: "schemaOk=\(schemaOk) dataOk=\(dataOk)"
                    + " reopenOk=\(reopenOk) preservedOk=\(preservedOk)"
                    + " cascadeOk=\(cascadeOk)"
            )
        } catch {
            return ScenarioResult(
                scenario: "v4MigrationFixture",
                storeKind: StoreKind.sqlite.rawValue,
                passed: false,
                detail: "unexpected error: \(error)"
            )
        }
    }

    private static func runV4MigrationFailureRollback() -> ScenarioResult {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("marquee-v4-rollback-\(UUID().uuidString)", isDirectory: true)
        let dbPath = dir.appendingPathComponent("catalog.sqlite").path
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }

            try createV3FixtureDatabase(at: dbPath)
            try withConnection(path: dbPath) { conn in
                do {
                    try conn.execute(
                        """
                        BEGIN IMMEDIATE;
                        ALTER TABLE movie ADD COLUMN vote_count INTEGER;
                        CREATE TABLE movie_keyword (
                            movie_id TEXT NOT NULL REFERENCES movie(id) ON DELETE CASCADE,
                            keyword_id INTEGER NOT NULL,
                            name TEXT NOT NULL COLLATE NOCASE,
                            PRIMARY KEY (movie_id, keyword_id)
                        );
                        SELECT * FROM definitely_missing_failure_injection_table;
                        PRAGMA user_version = 4;
                        COMMIT;
                        """
                    )
                } catch {
                    try? conn.execute("ROLLBACK")
                }
            }

            let rolledBack = try withConnection(path: dbPath) { conn -> Bool in
                let cols = try tableColumns(conn, table: "movie")
                let tables = try sqliteMasterNames(conn, type: "table")
                return try conn.userVersion == 3
                    && !cols.contains("vote_count")
                    && !tables.contains("movie_keyword")
            }
            return ScenarioResult(
                scenario: "v4MigrationFailureRollback",
                storeKind: StoreKind.sqlite.rawValue,
                passed: rolledBack,
                detail: "rolledBack=\(rolledBack)"
            )
        } catch {
            return ScenarioResult(
                scenario: "v4MigrationFailureRollback",
                storeKind: StoreKind.sqlite.rawValue,
                passed: false,
                detail: "unexpected error: \(error)"
            )
        }
    }

    private static func runV4MigrationCopyRehearsal(path: String) async -> ScenarioResult {
        do {
            let beforeVersion = try withConnection(path: path) { conn in
                try conn.userVersion
            }
            let store = try SQLiteCatalogStore(path: path)
            let afterVersion = try withConnection(path: path) { conn in
                try conn.userVersion
            }
            let counts = try await store.countsSnapshot()
            let coverage = try await store.movieIntelligenceCoverageReport()
            let passed = afterVersion == CatalogSchema.currentVersion
                && coverage.movieCount == counts.movies
            return ScenarioResult(
                scenario: "v4MigrationCopyRehearsal",
                storeKind: StoreKind.sqlite.rawValue,
                passed: passed,
                detail: "path=\(path) before=\(beforeVersion)"
                    + " after=\(afterVersion) movies=\(counts.movies)"
                    + " coverageRows=\(coverage.rows.count)"
            )
        } catch {
            return ScenarioResult(
                scenario: "v4MigrationCopyRehearsal",
                storeKind: StoreKind.sqlite.rawValue,
                passed: false,
                detail: "path=\(path) error=\(error)"
            )
        }
    }

    private static func withConnection<T>(
        path: String,
        _ work: (SQLiteConnection) throws -> T
    ) throws -> T {
        let conn = try SQLiteConnection(path: path)
        return try work(conn)
    }

    private static func tableColumns(
        _ conn: SQLiteConnection,
        table: String
    ) throws -> Set<String> {
        let rows = try conn.query(
            "PRAGMA table_info(\(table))",
            map: { stmt in stmt.text(1) }
        )
        return Set(rows)
    }

    private static func sqliteMasterNames(
        _ conn: SQLiteConnection,
        type: String
    ) throws -> Set<String> {
        let rows = try conn.query(
            "SELECT name FROM sqlite_master WHERE type = ?",
            [.text(type)],
            map: { stmt in stmt.text(0) }
        )
        return Set(rows)
    }

    private static func seedV4ExtensionRows(dbPath: String) throws {
        try withConnection(path: dbPath) { conn in
            try conn.run(
                """
                UPDATE movie
                SET vote_count = ?, popularity = ?, collection_id = ?, collection_name = ?
                WHERE id = ?
                """,
                [
                    .int(321),
                    .double(42.5),
                    .int(77),
                    .text("Fixture Collection"),
                    .text("movie-source"),
                ]
            )
            try conn.run(
                """
                INSERT INTO movie_keyword (movie_id, keyword_id, name)
                VALUES (?,?,?)
                """,
                [.text("movie-source"), .int(5), .text("heist")]
            )
            try conn.run(
                """
                INSERT INTO movie_edge
                (source_movie_id, target_movie_id, edge_type, rank, score)
                VALUES (?,?,?,?,?)
                """,
                [
                    .text("movie-source"),
                    .text("movie-target"),
                    .text("similar"),
                    .int(0),
                    .double(0.9),
                ]
            )
        }
    }

    private static func createV3FixtureDatabase(at path: String) throws {
        try withConnection(path: path) { conn in
            try conn.execute(v3FixtureSchemaSQL)
            try conn.run(
                """
                INSERT INTO media_file
                (id, volume_uuid, relative_path, absolute_path_snapshot,
                 file_extension, file_size, modification_date,
                 duration_seconds, content_hash, date_added)
                VALUES (?,?,?,?,?,?,?,?,?,?)
                """,
                [
                    .text("file-source"), .text(fixtureVolumeUUID),
                    .text("Movies/Source.mkv"), .text("/tmp/Movies/Source.mkv"),
                    .text("mkv"), .int(100), .double(0), .double(6000),
                    .null, .double(0),
                ]
            )
            try conn.run(
                """
                INSERT INTO media_file
                (id, volume_uuid, relative_path, absolute_path_snapshot,
                 file_extension, file_size, modification_date,
                 duration_seconds, content_hash, date_added)
                VALUES (?,?,?,?,?,?,?,?,?,?)
                """,
                [
                    .text("file-target"), .text(fixtureVolumeUUID),
                    .text("Movies/Target.mkv"), .text("/tmp/Movies/Target.mkv"),
                    .text("mkv"), .int(100), .double(0), .double(6000),
                    .null, .double(0),
                ]
            )
            try conn.run(
                """
                INSERT INTO media_file
                (id, volume_uuid, relative_path, absolute_path_snapshot,
                 file_extension, file_size, modification_date,
                 duration_seconds, content_hash, date_added)
                VALUES (?,?,?,?,?,?,?,?,?,?)
                """,
                [
                    .text("file-episode"), .text(fixtureVolumeUUID),
                    .text("TV/Show/S01E01.mkv"), .text("/tmp/TV/Show/S01E01.mkv"),
                    .text("mkv"), .int(100), .double(0), .double(3600),
                    .null, .double(0),
                ]
            )

            try conn.run(
                """
                INSERT INTO movie
                (id, primary_file, title, year, tmdb_id, overview,
                 runtime_minutes, certification, release_date,
                 genres_json, vote_average, director)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
                """,
                [
                    .text("movie-source"), .text("file-source"),
                    .text("Source"), .int(2001), .int(9001),
                    .text("Source overview"), .int(100), .text("PG"),
                    .text("2001-01-01"), .text("[\"Drama\"]"),
                    .double(7.1), .text("Director A"),
                ]
            )
            try conn.run(
                """
                INSERT INTO movie
                (id, primary_file, title, year, tmdb_id, overview,
                 runtime_minutes, certification, release_date,
                 genres_json, vote_average, director)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
                """,
                [
                    .text("movie-target"), .text("file-target"),
                    .text("Target"), .int(2003), .int(9002),
                    .text("Target overview"), .int(110), .text("PG-13"),
                    .text("2003-03-03"), .text("[\"Mystery\"]"),
                    .double(7.8), .text("Director B"),
                ]
            )

            try conn.run(
                """
                INSERT INTO show
                (id, title, year, tmdb_id, overview, certification, genres_json,
                 release_date, runtime_minutes, vote_average, director)
                VALUES (?,?,?,?,?,?,?,?,?,?,?)
                """,
                [
                    .text("show-fixture"), .text("Fixture Show"), .int(2020),
                    .int(7000), .text("Show overview"), .text("TV-PG"),
                    .text("[\"Drama\"]"), .text("2020-01-01"),
                    .int(45), .double(7.0), .text("Showrunner"),
                ]
            )
            try conn.run(
                "INSERT INTO season (id, show_id, season_number) VALUES (?,?,?)",
                [.text("season-fixture"), .text("show-fixture"), .int(1)]
            )
            try conn.run(
                """
                INSERT INTO episode
                (id, season_id, primary_file, episode_number, title, overview, runtime_minutes,
                 tmdb_id, certification, release_date, vote_average)
                VALUES (?,?,?,?,?,?,?,?,?,?,?)
                """,
                [
                    .text("episode-fixture"), .text("season-fixture"),
                    .text("file-episode"), .int(1), .text("Pilot"),
                    .text("Episode overview"), .int(45), .int(8000),
                    .null, .text("2020-01-01"), .double(7.4),
                ]
            )

            try conn.run(
                """
                INSERT INTO profile
                (id, display_name, kind, max_certification, created_at)
                VALUES (?,?,?,?,?)
                """,
                [
                    .text("profile-adult"), .text("Adult"), .text("adult"),
                    .null, .double(0),
                ]
            )
            try conn.run(
                """
                INSERT INTO watch_state
                (id, profile_id, target_type, target_id,
                 position_seconds, duration_seconds, completed, last_watched)
                VALUES (?,?,?,?,?,?,?,?)
                """,
                [
                    .text("watch-source"), .text("profile-adult"),
                    .text("movie"), .text("movie-source"),
                    .double(0), .double(6000), .int(1), .double(1),
                ]
            )

            try conn.run(
                """
                INSERT INTO scan_job
                (id, root_path, volume_uuid, state, created_at,
                 started_at, completed_at, last_error_message,
                 files_observed, files_added, files_updated, files_removed)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
                """,
                [
                    .text("scan-job"), .text("/tmp"), .text(fixtureVolumeUUID),
                    .text("completed"), .double(0), .double(1), .double(2),
                    .null, .int(3), .int(3), .int(0), .int(0),
                ]
            )
            try conn.run(
                """
                INSERT INTO scan_event
                (id, job_id, kind, timestamp, path, detail)
                VALUES (?,?,?,?,?,?)
                """,
                [
                    .text("scan-event"), .text("scan-job"), .text("fileSeen"),
                    .double(1), .text("Movies/Source.mkv"), .text("seen"),
                ]
            )
            try conn.setUserVersion(3)
        }
    }

    private static let v3FixtureSchemaSQL = """
    CREATE TABLE IF NOT EXISTS media_file (
        id TEXT PRIMARY KEY,
        volume_uuid TEXT NOT NULL,
        relative_path TEXT NOT NULL,
        absolute_path_snapshot TEXT NOT NULL,
        file_extension TEXT NOT NULL,
        file_size INTEGER NOT NULL,
        modification_date REAL,
        duration_seconds REAL,
        content_hash TEXT,
        date_added REAL NOT NULL
    );

    CREATE TABLE IF NOT EXISTS movie (
        id TEXT PRIMARY KEY,
        primary_file TEXT NOT NULL,
        title TEXT NOT NULL,
        year INTEGER,
        tmdb_id INTEGER,
        overview TEXT,
        runtime_minutes INTEGER,
        certification TEXT,
        release_date TEXT,
        genres_json TEXT NOT NULL DEFAULT '[]',
        vote_average REAL,
        director TEXT
    );

    CREATE TABLE IF NOT EXISTS show (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        year INTEGER,
        tmdb_id INTEGER,
        overview TEXT,
        certification TEXT,
        genres_json TEXT NOT NULL DEFAULT '[]',
        release_date TEXT,
        runtime_minutes INTEGER,
        vote_average REAL,
        director TEXT
    );

    CREATE TABLE IF NOT EXISTS season (
        id TEXT PRIMARY KEY,
        show_id TEXT NOT NULL,
        season_number INTEGER NOT NULL
    );

    CREATE TABLE IF NOT EXISTS episode (
        id TEXT PRIMARY KEY,
        season_id TEXT NOT NULL,
        primary_file TEXT NOT NULL,
        episode_number INTEGER NOT NULL,
        title TEXT,
        overview TEXT,
        runtime_minutes INTEGER,
        tmdb_id INTEGER,
        certification TEXT,
        release_date TEXT,
        vote_average REAL
    );

    CREATE TABLE IF NOT EXISTS artwork_asset (
        id TEXT PRIMARY KEY,
        owner_type TEXT NOT NULL,
        owner_id TEXT NOT NULL,
        kind TEXT NOT NULL,
        local_path TEXT,
        remote_url TEXT,
        source_label TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS watch_state (
        id TEXT PRIMARY KEY,
        profile_id TEXT NOT NULL,
        target_type TEXT NOT NULL,
        target_id TEXT NOT NULL,
        position_seconds REAL NOT NULL,
        duration_seconds REAL,
        completed INTEGER NOT NULL DEFAULT 0,
        last_watched REAL NOT NULL
    );

    CREATE TABLE IF NOT EXISTS profile (
        id TEXT PRIMARY KEY,
        display_name TEXT NOT NULL,
        kind TEXT NOT NULL,
        max_certification TEXT,
        created_at REAL NOT NULL
    );

    CREATE TABLE IF NOT EXISTS scan_job (
        id TEXT PRIMARY KEY,
        root_path TEXT NOT NULL,
        volume_uuid TEXT NOT NULL,
        state TEXT NOT NULL,
        created_at REAL NOT NULL,
        started_at REAL,
        completed_at REAL,
        last_error_message TEXT,
        files_observed INTEGER NOT NULL DEFAULT 0,
        files_added INTEGER NOT NULL DEFAULT 0,
        files_updated INTEGER NOT NULL DEFAULT 0,
        files_removed INTEGER NOT NULL DEFAULT 0
    );

    CREATE INDEX IF NOT EXISTS scan_job_state_idx
        ON scan_job(state);

    CREATE TABLE IF NOT EXISTS scan_event (
        id TEXT PRIMARY KEY,
        job_id TEXT NOT NULL REFERENCES scan_job(id) ON DELETE CASCADE,
        kind TEXT NOT NULL,
        timestamp REAL NOT NULL,
        path TEXT,
        detail TEXT
    );

    CREATE INDEX IF NOT EXISTS scan_event_job_idx
        ON scan_event(job_id);

    CREATE TABLE IF NOT EXISTS person (
        id INTEGER PRIMARY KEY,
        name TEXT NOT NULL,
        profile_path TEXT
    );

    CREATE TABLE IF NOT EXISTS cast_member (
        id TEXT PRIMARY KEY,
        owner_type TEXT NOT NULL,
        owner_id TEXT NOT NULL,
        person_id INTEGER NOT NULL REFERENCES person(id),
        character TEXT NOT NULL,
        ordinal INTEGER NOT NULL
    );

    CREATE INDEX IF NOT EXISTS cast_member_owner_idx
        ON cast_member(owner_type, owner_id, ordinal);
    """

    // MARK: - Report I/O

    private static func writeReport(_ report: Report) throws {
        let dir = try resolveReportsDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let stamp = iso8601(Date()).replacingOccurrences(of: ":", with: "-")
        let url = dir.appendingPathComponent("transaction-verify-\(stamp).json")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)
        try data.write(to: url, options: .atomic)

        let line = "verify-transactions: wrote \(url.path)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    private static func resolveReportsDir() throws -> URL {
        let env = ProcessInfo.processInfo.environment
        if let override = env["MARQUEE_VERIFY_REPORTS_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }

        let fm = FileManager.default
        var dir = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
        for _ in 0..<8 {
            let marker = dir.appendingPathComponent("Marquee.xcodeproj")
            if fm.fileExists(atPath: marker.path) {
                return dir
                    .appendingPathComponent("build", isDirectory: true)
                    .appendingPathComponent("reports", isDirectory: true)
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }

        return fm.temporaryDirectory
            .appendingPathComponent("marquee-verify-reports", isDirectory: true)
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

#endif // DEBUG
