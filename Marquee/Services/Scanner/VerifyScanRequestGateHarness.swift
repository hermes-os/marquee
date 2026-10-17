//
//  VerifyScanRequestGateHarness.swift
//  Marquee
//
//  DEBUG-only verification for serialized scan requests. Activated by
//  `--verify-scan-request-gate`.
//

#if DEBUG

import Foundation

enum VerifyScanRequestGateHarness {
    static let launchArgument = "--verify-scan-request-gate"

    static func runIfRequested() {
        guard CommandLine.arguments.contains(launchArgument) else { return }

        do {
            let detail = try runScenario()
            FileHandle.standardError.write(Data("verify-scan-request-gate: PASS serializedFollowUp: \(detail)\n".utf8))
            FileHandle.standardError.write(Data("verify-scan-request-gate: outcome=verified passed=1/1\n".utf8))
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("verify-scan-request-gate: FAIL serializedFollowUp: \(error)\n".utf8))
            FileHandle.standardError.write(Data("verify-scan-request-gate: outcome=failed passed=0/1\n".utf8))
            exit(1)
        }
    }

    private static func runScenario() throws -> String {
        var gate = ScanRequestGate()

        try expect(gate.request() == .start, "first request should start")
        try expect(gate.isRunning, "gate should be running after first request")
        try expect(!gate.pendingRescan, "first request should not mark pending")

        try expect(gate.request() == .queued, "second request should queue")
        try expect(gate.request() == .queued, "third request should queue")
        try expect(gate.pendingRescan, "queued requests should mark pending")
        try expect(gate.queuedRequestCount == 2, "queued count should be 2")

        try expect(gate.finishPass() == .runAgain, "first completion should drain one follow-up")
        try expect(gate.isRunning, "gate should remain running for follow-up")
        try expect(!gate.pendingRescan, "follow-up should consume pending flag")
        try expect(gate.queuedRequestCount == 0, "follow-up should reset queued count")

        try expect(gate.request() == .queued, "request during follow-up should queue")
        try expect(gate.finishPass() == .runAgain, "follow-up completion should drain new request")
        try expect(gate.finishPass() == .idle, "completion with no pending request should idle")
        try expect(!gate.isRunning, "gate should stop running when idle")
        try expect(gate.request() == .start, "fresh request after idle should start")

        return "active scans queue one follow-up and never overlap"
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition {
            throw HarnessError.assertion(message)
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
