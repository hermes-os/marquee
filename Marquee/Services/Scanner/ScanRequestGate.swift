import Foundation

enum ScanRequestDecision {
    case start
    case queued
}

enum ScanCompletionDecision {
    case idle
    case runAgain
}

struct ScanRequestGate {
    private(set) var isRunning = false
    private(set) var pendingRescan = false
    private(set) var queuedRequestCount = 0

    mutating func request() -> ScanRequestDecision {
        if isRunning {
            pendingRescan = true
            queuedRequestCount += 1
            return .queued
        }

        isRunning = true
        pendingRescan = false
        queuedRequestCount = 0
        return .start
    }

    mutating func finishPass() -> ScanCompletionDecision {
        if pendingRescan {
            pendingRescan = false
            queuedRequestCount = 0
            isRunning = true
            return .runAgain
        }

        isRunning = false
        return .idle
    }
}
