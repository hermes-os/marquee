//
//  VerifyDurationProbeHarness.swift
//  Marquee
//
//  Phase 2E.4d step (d.1) — actor-level scenarios that pin the
//  DurationProbe contract:
//    A. probesMissingDurationsAndSkipsKnown
//    B. failedLoadKeepsDurationNil
//    C. secondPassIsNoOpAfterFill
//
//  Driven via FakeDurationLoader with deterministic per-path
//  responses. InMemory catalog backing; no global state.
//
//  DEBUG-only — gated by `#if DEBUG`. Activated by
//  `--verify-duration-probe`.
//
//  Exit codes: 0 = all pass, 1 = at least one scenario failed,
//  2 = internal error.
//

#if DEBUG

import Foundation

public enum VerifyDurationProbeHarness {

    public static let launchArgument = "--verify-duration-probe"

    public static func runIfRequested() {
        guard CommandLine.arguments.contains(launchArgument) else { return }

        let semaphore = DispatchSemaphore(value: 0)
        let result = ExitCodeBox()

        Task.detached {
            do {
                let code = try await runHarness()
                result.set(code)
            } catch {
                let line = "verify-duration-probe: error: \(error)\n"
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

    private struct Outcome {
        let name: String
        let passed: Bool
        let detail: String
    }

    private static func runHarness() async throws -> Int32 {
        var results: [Outcome] = []

        results.append(await wrap("probesMissingDurationsAndSkipsKnown") {
            try await runProbesMissingAndSkipsKnown()
        })
        results.append(await wrap("failedLoadKeepsDurationNil") {
            try await runFailedLoadKeepsNil()
        })
        results.append(await wrap("secondPassIsNoOpAfterFill") {
            try await runSecondPassIsNoOp()
        })

        for r in results {
            let mark = r.passed ? "PASS" : "FAIL"
            let line = "verify-duration-probe: \(mark) \(r.name): \(r.detail)\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
        let passed = results.filter { $0.passed }.count
        let allPassed = passed == results.count
        let summary = "verify-duration-probe: outcome="
            + (allPassed ? "verified" : "failed")
            + " passed=\(passed)/\(results.count)\n"
        FileHandle.standardError.write(Data(summary.utf8))
        return allPassed ? 0 : 1
    }

    private static func wrap(
        _ name: String,
        _ body: () async throws -> String
    ) async -> Outcome {
        do {
            let detail = try await body()
            return Outcome(name: name, passed: true, detail: detail)
        } catch {
            return Outcome(name: name, passed: false, detail: "\(error)")
        }
    }

    // MARK: - Fixtures

    private static let volumeUUID = "duration-verify"

    private static func makeFile(
        relativePath: String,
        durationSeconds: TimeInterval? = nil
    ) -> CatalogMediaFile {
        let id = MediaIdentity.mediaFileID(
            volumeUUID: volumeUUID,
            relativePath: relativePath
        )
        return CatalogMediaFile(
            id: id,
            volumeUUID: volumeUUID,
            relativePath: relativePath,
            absolutePathSnapshot: "/tmp/marquee-duration/\(relativePath)",
            fileExtension: "mkv",
            fileSize: 1,
            modificationDate: Date(timeIntervalSince1970: 0),
            durationSeconds: durationSeconds,
            contentHash: nil,
            dateAdded: Date(timeIntervalSince1970: 0)
        )
    }

    /// Deterministic loader: keyed responses by absolutePath. Tracks
    /// the calls so scenarios can assert the loader was invoked
    /// exactly the right number of times.
    private actor FakeDurationLoader: DurationLoading {
        private var responses: [String: TimeInterval?]
        private(set) var calls: [String] = []

        init(responses: [String: TimeInterval?]) {
            self.responses = responses
        }

        func loadDuration(at fileURL: URL) async -> TimeInterval? {
            calls.append(fileURL.path)
            return responses[fileURL.path] ?? nil
        }

        func callCount() -> Int { calls.count }
    }

    // MARK: - Scenario A

    private static func runProbesMissingAndSkipsKnown() async throws -> String {
        let store = InMemoryCatalogStore()
        let nilFile = makeFile(relativePath: "Movies/A.mkv", durationSeconds: nil)
        let knownFile = makeFile(relativePath: "Movies/B.mkv", durationSeconds: 100)
        try await store.upsert(mediaFile: nilFile)
        try await store.upsert(mediaFile: knownFile)

        let loader = FakeDurationLoader(responses: [
            nilFile.absolutePathSnapshot: 60,
            knownFile.absolutePathSnapshot: 999  // must not be called
        ])
        let probe = DurationProbe(
            catalog: store,
            loader: loader,
            maxConcurrent: 4
        )
        let summary = try await probe.probeMissing()
        guard summary.probed == 1, summary.skipped == 1, summary.failed == 0 else {
            throw HarnessError.assertion(
                "summary mismatch: \(summary)"
            )
        }

        let calls = await loader.callCount()
        guard calls == 1 else {
            throw HarnessError.assertion(
                "loader called \(calls) times, expected 1 (skipped row leaked into probe)"
            )
        }

        let after = try await store.allMediaFiles()
        let aRow = after.first { $0.relativePath == "Movies/A.mkv" }
        let bRow = after.first { $0.relativePath == "Movies/B.mkv" }
        guard aRow?.durationSeconds == 60 else {
            throw HarnessError.assertion(
                "A.mkv duration not filled: \(String(describing: aRow?.durationSeconds))"
            )
        }
        guard bRow?.durationSeconds == 100 else {
            throw HarnessError.assertion(
                "B.mkv duration overwritten: \(String(describing: bRow?.durationSeconds))"
            )
        }
        return "probed 1 nil row → 60s, skipped 1 known row at 100s, no spurious loader call"
    }

    // MARK: - Scenario B

    private static func runFailedLoadKeepsNil() async throws -> String {
        let store = InMemoryCatalogStore()
        let file = makeFile(relativePath: "Movies/Corrupt.mkv", durationSeconds: nil)
        try await store.upsert(mediaFile: file)

        // Loader returns nil for this path (load failed).
        let loader = FakeDurationLoader(responses: [
            file.absolutePathSnapshot: nil
        ])
        let probe = DurationProbe(catalog: store, loader: loader)
        let summary = try await probe.probeMissing()
        guard summary.probed == 0, summary.skipped == 0, summary.failed == 1 else {
            throw HarnessError.assertion("summary mismatch: \(summary)")
        }
        let after = try await store.allMediaFiles()
        let row = after.first { $0.relativePath == "Movies/Corrupt.mkv" }
        guard row?.durationSeconds == nil else {
            throw HarnessError.assertion(
                "failed load wrote duration: \(String(describing: row?.durationSeconds))"
            )
        }
        return "load failed → durationSeconds stayed nil, retry on next pass"
    }

    // MARK: - Scenario C

    private static func runSecondPassIsNoOp() async throws -> String {
        let store = InMemoryCatalogStore()
        let file = makeFile(relativePath: "Movies/Once.mkv", durationSeconds: nil)
        try await store.upsert(mediaFile: file)

        let loader = FakeDurationLoader(responses: [
            file.absolutePathSnapshot: 42
        ])
        let probe = DurationProbe(catalog: store, loader: loader)

        let firstSummary = try await probe.probeMissing()
        guard firstSummary.probed == 1 else {
            throw HarnessError.assertion("first pass: \(firstSummary)")
        }

        let secondSummary = try await probe.probeMissing()
        guard secondSummary.probed == 0,
              secondSummary.skipped == 1,
              secondSummary.failed == 0 else {
            throw HarnessError.assertion("second pass mismatch: \(secondSummary)")
        }
        let calls = await loader.callCount()
        guard calls == 1 else {
            throw HarnessError.assertion(
                "loader called \(calls) times across two passes, expected 1"
            )
        }
        return "first pass filled 1, second pass skipped 1, loader invoked once"
    }

    // MARK: - Errors

    private enum HarnessError: Error, CustomStringConvertible {
        case assertion(String)

        var description: String {
            switch self {
            case .assertion(let msg): return "assertion: \(msg)"
            }
        }
    }
}

#endif
