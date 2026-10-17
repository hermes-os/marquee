//
//  VerifyVolumeRegistryHarness.swift
//  Marquee
//
//  Phase 2 verification harness for `VolumeRegistry`.
//
//  Covers:
//    - InMemoryVolumeRegistry parity scenarios (resolution, deepest
//      match, normalization, mount/unmount events, multi-subscriber
//      fan-out, post-unmount resolve failure).
//    - SystemVolumeRegistry smoke checks against the live host
//      (mountedVolumes non-empty, root resolution, byUUID round-trip).
//
//  DEBUG-ONLY. The entire body is gated by `#if DEBUG` so the harness
//  is excluded from Release builds. Activated by `--verify-volumes`.
//
//  Exit codes: 0 = all pass, 1 = at least one scenario failed,
//  2 = internal error.
//

#if DEBUG

import Foundation

public enum VerifyVolumeRegistryHarness {

    public static let launchArgument = "--verify-volumes"

    // MARK: - Report types

    public struct ScenarioResult: Codable {
        public let storeKind: String
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
                let line = "verify-volumes: error: \(error)\n"
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

        // In-memory parity scenarios.
        results.append(await scenarioResolveDeepestMatch())
        results.append(await scenarioRootVolumeFallback())
        results.append(await scenarioPathOutsideAnyVolume())
        results.append(await scenarioMountEventDelivery())
        results.append(await scenarioUnmountClearsResolution())
        results.append(await scenarioMultipleSubscribers())
        results.append(await scenarioUUIDCanonicalization())
        results.append(await scenarioMountPathNormalization())

        // System smoke checks.
        results.append(await scenarioSystemMountedVolumesNonEmpty())
        results.append(await scenarioSystemRootResolution())

        let allPassed = results.allSatisfy { $0.passed }
        for r in results {
            let mark = r.passed ? "PASS" : "FAIL"
            let line = "verify-volumes: \(mark) [\(r.storeKind)] \(r.scenario): \(r.detail)\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
        let summary = "verify-volumes: outcome=\(allPassed ? "verified" : "failed")"
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

    // MARK: - Fixtures

    private static func makeRoot() -> VolumeDescriptor {
        VolumeDescriptor(
            uuid: "00000000-0000-0000-0000-000000000001",
            mountPath: "/",
            label: "Macintosh HD",
            isRemovable: false,
            isNetwork: false
        )
    }

    private static func makeNested() -> VolumeDescriptor {
        VolumeDescriptor(
            uuid: "11111111-1111-1111-1111-111111111111",
            mountPath: "/Volumes/FixtureDisk",
            label: "FixtureDisk",
            isRemovable: true,
            isNetwork: false
        )
    }

    // MARK: - Scenarios (in-memory)

    private static func scenarioResolveDeepestMatch() async -> ScenarioResult {
        let kind = "InMemory"
        let scenario = "resolveDeepestMatch"
        let registry = InMemoryVolumeRegistry(seed: [makeRoot(), makeNested()])
        do {
            let url = URL(fileURLWithPath: "/Volumes/FixtureDisk/Movies/x.mkv")
            let (vol, rel) = try await registry.resolve(url: url)
            guard vol.uuid == makeNested().uuid else {
                return .init(storeKind: kind, scenario: scenario, passed: false,
                             detail: "expected nested volume, got \(vol.uuid)")
            }
            guard rel == "Movies/x.mkv" else {
                return .init(storeKind: kind, scenario: scenario, passed: false,
                             detail: "expected 'Movies/x.mkv', got '\(rel)'")
            }
            return .init(storeKind: kind, scenario: scenario, passed: true,
                         detail: "deepest match selected, relPath canonical")
        } catch {
            return .init(storeKind: kind, scenario: scenario, passed: false,
                         detail: "threw: \(error)")
        }
    }

    private static func scenarioRootVolumeFallback() async -> ScenarioResult {
        let kind = "InMemory"
        let scenario = "rootVolumeFallback"
        let registry = InMemoryVolumeRegistry(seed: [makeRoot(), makeNested()])
        do {
            let url = URL(fileURLWithPath: "/Users/example/Movies/clip.mkv")
            let (vol, rel) = try await registry.resolve(url: url)
            guard vol.uuid == makeRoot().uuid else {
                return .init(storeKind: kind, scenario: scenario, passed: false,
                             detail: "expected root, got \(vol.uuid)")
            }
            guard rel == "Users/example/Movies/clip.mkv" else {
                return .init(storeKind: kind, scenario: scenario, passed: false,
                             detail: "expected 'Users/example/Movies/clip.mkv', got '\(rel)'")
            }
            return .init(storeKind: kind, scenario: scenario, passed: true,
                         detail: "root fallback when no nested match")
        } catch {
            return .init(storeKind: kind, scenario: scenario, passed: false,
                         detail: "threw: \(error)")
        }
    }

    private static func scenarioPathOutsideAnyVolume() async -> ScenarioResult {
        let kind = "InMemory"
        let scenario = "pathOutsideAnyVolume"
        // No root seeded — every path should fail.
        let registry = InMemoryVolumeRegistry(seed: [makeNested()])
        do {
            let url = URL(fileURLWithPath: "/Users/example/file.mkv")
            _ = try await registry.resolve(url: url)
            return .init(storeKind: kind, scenario: scenario, passed: false,
                         detail: "expected throw, returned successfully")
        } catch VolumeRegistryError.pathNotOnMountedVolume(let p) {
            return .init(storeKind: kind, scenario: scenario, passed: true,
                         detail: "rejected with pathNotOnMountedVolume(\(p))")
        } catch {
            return .init(storeKind: kind, scenario: scenario, passed: false,
                         detail: "wrong error: \(error)")
        }
    }

    private static func scenarioMountEventDelivery() async -> ScenarioResult {
        let kind = "InMemory"
        let scenario = "mountEventDelivery"
        let registry = InMemoryVolumeRegistry(seed: [makeRoot()])
        let stream = await registry.mountEvents()
        let collected = collectFirst(stream, count: 2)
        let nested = makeNested()
        await registry.simulateMount(nested)
        await registry.simulateUnmount(uuid: nested.uuid)
        let events = await collected.value
        guard events.count == 2 else {
            return .init(storeKind: kind, scenario: scenario, passed: false,
                         detail: "expected 2 events, got \(events.count)")
        }
        guard case .mounted(let v0) = events[0], v0.uuid == nested.uuid else {
            return .init(storeKind: kind, scenario: scenario, passed: false,
                         detail: "first event not .mounted(nested)")
        }
        guard case .unmounted(let u1, _) = events[1], u1 == nested.uuid else {
            return .init(storeKind: kind, scenario: scenario, passed: false,
                         detail: "second event not .unmounted(nested)")
        }
        return .init(storeKind: kind, scenario: scenario, passed: true,
                     detail: "mounted+unmounted observed in order")
    }

    private static func scenarioUnmountClearsResolution() async -> ScenarioResult {
        let kind = "InMemory"
        let scenario = "unmountClearsResolution"
        let registry = InMemoryVolumeRegistry(seed: [makeNested()])
        let url = URL(fileURLWithPath: "/Volumes/FixtureDisk/x.mkv")
        do {
            _ = try await registry.resolve(url: url)
        } catch {
            return .init(storeKind: kind, scenario: scenario, passed: false,
                         detail: "pre-unmount resolve failed: \(error)")
        }
        await registry.simulateUnmount(uuid: makeNested().uuid)
        do {
            _ = try await registry.resolve(url: url)
            return .init(storeKind: kind, scenario: scenario, passed: false,
                         detail: "post-unmount resolve unexpectedly succeeded")
        } catch VolumeRegistryError.pathNotOnMountedVolume {
            return .init(storeKind: kind, scenario: scenario, passed: true,
                         detail: "post-unmount resolve threw correctly")
        } catch {
            return .init(storeKind: kind, scenario: scenario, passed: false,
                         detail: "wrong error: \(error)")
        }
    }

    private static func scenarioMultipleSubscribers() async -> ScenarioResult {
        let kind = "InMemory"
        let scenario = "multipleSubscribers"
        let registry = InMemoryVolumeRegistry(seed: [makeRoot()])
        let s1 = await registry.mountEvents()
        let s2 = await registry.mountEvents()
        let c1 = collectFirst(s1, count: 1)
        let c2 = collectFirst(s2, count: 1)
        let nested = makeNested()
        await registry.simulateMount(nested)
        let e1 = await c1.value
        let e2 = await c2.value
        guard e1.count == 1, e2.count == 1 else {
            return .init(storeKind: kind, scenario: scenario, passed: false,
                         detail: "subscriber counts: \(e1.count), \(e2.count)")
        }
        return .init(storeKind: kind, scenario: scenario, passed: true,
                     detail: "both subscribers received the mount")
    }

    private static func scenarioUUIDCanonicalization() async -> ScenarioResult {
        let kind = "InMemory"
        let scenario = "uuidCanonicalization"
        let upper = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        let descriptor = VolumeDescriptor(
            uuid: "  \(upper)  ",
            mountPath: "/Volumes/Test",
            label: "Test"
        )
        guard descriptor.uuid == upper.lowercased() else {
            return .init(storeKind: kind, scenario: scenario, passed: false,
                         detail: "uuid not lowercased+trimmed: \(descriptor.uuid)")
        }
        let registry = InMemoryVolumeRegistry(seed: [descriptor])
        guard await registry.volume(byUUID: upper) != nil else {
            return .init(storeKind: kind, scenario: scenario, passed: false,
                         detail: "lookup by uppercase uuid failed")
        }
        return .init(storeKind: kind, scenario: scenario, passed: true,
                     detail: "case-insensitive lookup, canonical storage")
    }

    private static func scenarioMountPathNormalization() async -> ScenarioResult {
        let kind = "InMemory"
        let scenario = "mountPathNormalization"
        let descriptor = VolumeDescriptor(
            uuid: "22222222-2222-2222-2222-222222222222",
            mountPath: "/Volumes/FixtureDisk/",
            label: "FixtureDisk"
        )
        guard descriptor.mountPath == "/Volumes/FixtureDisk" else {
            return .init(storeKind: kind, scenario: scenario, passed: false,
                         detail: "trailing slash not stripped: '\(descriptor.mountPath)'")
        }
        let registry = InMemoryVolumeRegistry(seed: [descriptor])
        do {
            let url = URL(fileURLWithPath: "/Volumes/FixtureDisk/file.mkv")
            let (_, rel) = try await registry.resolve(url: url)
            guard rel == "file.mkv" else {
                return .init(storeKind: kind, scenario: scenario, passed: false,
                             detail: "expected 'file.mkv', got '\(rel)'")
            }
            return .init(storeKind: kind, scenario: scenario, passed: true,
                         detail: "trailing slash stripped, resolution clean")
        } catch {
            return .init(storeKind: kind, scenario: scenario, passed: false,
                         detail: "threw: \(error)")
        }
    }

    // MARK: - Scenarios (system smoke)

    private static func scenarioSystemMountedVolumesNonEmpty() async -> ScenarioResult {
        let kind = "System"
        let scenario = "systemMountedVolumesNonEmpty"
        let registry = await SystemVolumeRegistry()
        let mounted = await registry.mountedVolumes()
        if mounted.isEmpty {
            return .init(storeKind: kind, scenario: scenario, passed: false,
                         detail: "no mounted volumes — root should always be present")
        }
        return .init(storeKind: kind, scenario: scenario, passed: true,
                     detail: "found \(mounted.count) mounted volume(s)")
    }

    private static func scenarioSystemRootResolution() async -> ScenarioResult {
        let kind = "System"
        let scenario = "systemRootResolution"
        let registry = await SystemVolumeRegistry()
        do {
            let url = URL(fileURLWithPath: "/")
            let (vol, rel) = try await registry.resolve(url: url)
            guard !vol.uuid.isEmpty else {
                return .init(storeKind: kind, scenario: scenario, passed: false,
                             detail: "root resolved to empty uuid")
            }
            // Root path resolves to empty relative path.
            guard rel.isEmpty else {
                return .init(storeKind: kind, scenario: scenario, passed: false,
                             detail: "root rel path expected empty, got '\(rel)'")
            }
            // Round-trip through volume(byUUID:).
            guard await registry.volume(byUUID: vol.uuid) != nil else {
                return .init(storeKind: kind, scenario: scenario, passed: false,
                             detail: "byUUID lookup of just-resolved volume failed")
            }
            return .init(storeKind: kind, scenario: scenario, passed: true,
                         detail: "root resolves with uuid='\(vol.uuid)' label='\(vol.label ?? "")'")
        } catch {
            return .init(storeKind: kind, scenario: scenario, passed: false,
                         detail: "threw: \(error)")
        }
    }

    // MARK: - Helpers

    /// Spawn a Task that drains the first `count` events from `stream`
    /// into an array. Returns a Task whose `value` resolves once the
    /// count is reached or the stream finishes.
    private static func collectFirst(
        _ stream: AsyncStream<VolumeMountEvent>,
        count: Int
    ) -> Task<[VolumeMountEvent], Never> {
        Task {
            var collected: [VolumeMountEvent] = []
            for await e in stream {
                collected.append(e)
                if collected.count >= count { break }
            }
            return collected
        }
    }

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
        let url = dir.appendingPathComponent("verify-volumes-\(stamp).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)
        try data.write(to: url, options: .atomic)
        let line = "verify-volumes: wrote \(url.path)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}

#endif
