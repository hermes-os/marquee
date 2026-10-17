//
//  VerifyImagePipelineHarness.swift
//  Marquee
//
//  DEBUG-only verification for coalesced and cancellable image decode requests.
//  Activated by `--verify-image-pipeline`.
//

#if DEBUG

import AppKit
import Foundation

enum VerifyImagePipelineHarness {
    static let launchArgument = "--verify-image-pipeline"

    static func runIfRequested() {
        guard CommandLine.arguments.contains(launchArgument) else { return }

        do {
            let detail = try runScenario()
            FileHandle.standardError.write(Data("verify-image-pipeline: PASS coalescesAndCancels: \(detail)\n".utf8))
            FileHandle.standardError.write(Data("verify-image-pipeline: outcome=verified passed=1/1\n".utf8))
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("verify-image-pipeline: FAIL coalescesAndCancels: \(error)\n".utf8))
            FileHandle.standardError.write(Data("verify-image-pipeline: outcome=failed passed=0/1\n".utf8))
            exit(1)
        }
    }

    private static func runScenario() throws -> String {
        try verifyCoalescedDecode()
        try verifyCancellationSuppressesCompletion()
        try verifyLoadStateMachine()
        try verifyHeroReadinessIdentity()
        try verifyPlaceholderPresentation()
        return "coalesced duplicate decode, cancelled stale completion, runtime load/readiness state, and placeholder suppression"
    }

    private static func verifyLoadStateMachine() throws {
        let size = CGSize(width: 320, height: 180)
        var machine = CachedImageLoadStateMachine()

        _ = machine.begin(
            request: .init(path: nil, thumbnailPixelSize: size)
        )
        guard machine.state == .terminalFallback else {
            throw HarnessError.assertion("nil image path must resolve immediately to terminal fallback")
        }

        let cacheRequest = CachedImageLoadStateMachine.Request(
            path: "/tmp/cache-hit.jpg",
            thumbnailPixelSize: size
        )
        let cacheGeneration = machine.begin(request: cacheRequest)
        guard machine.state == .loading else {
            throw HarnessError.assertion("cache lookup must establish the current request before resolving")
        }
        machine.complete(
            request: cacheRequest,
            generation: cacheGeneration,
            imageAvailable: true
        )
        guard machine.state == .ready else {
            throw HarnessError.assertion("memory-cache hit must resolve immediately to ready")
        }

        let successRequest = CachedImageLoadStateMachine.Request(
            path: "/tmp/decode-success.jpg",
            thumbnailPixelSize: size
        )
        let successGeneration = machine.begin(request: successRequest)
        guard machine.state == .loading else {
            throw HarnessError.assertion("uncached image request must enter loading")
        }
        machine.complete(
            request: successRequest,
            generation: successGeneration,
            imageAvailable: true
        )
        guard machine.state == .ready else {
            throw HarnessError.assertion("successful decode must enter ready")
        }

        let failureRequest = CachedImageLoadStateMachine.Request(
            path: "/tmp/decode-failure.jpg",
            thumbnailPixelSize: size
        )
        let failureGeneration = machine.begin(request: failureRequest)
        machine.complete(
            request: failureRequest,
            generation: failureGeneration,
            imageAvailable: false
        )
        guard machine.state == .terminalFallback else {
            throw HarnessError.assertion("failed decode must enter terminal fallback")
        }

        let staleRequest = CachedImageLoadStateMachine.Request(
            path: "/tmp/stale.jpg",
            thumbnailPixelSize: size
        )
        let staleGeneration = machine.begin(request: staleRequest)
        let replacementRequest = CachedImageLoadStateMachine.Request(
            path: "/tmp/replacement.jpg",
            thumbnailPixelSize: size
        )
        _ = machine.begin(request: replacementRequest)
        let acceptedStaleCompletion = machine.complete(
            request: staleRequest,
            generation: staleGeneration,
            imageAvailable: true
        )
        guard !acceptedStaleCompletion,
              machine.request == replacementRequest,
              machine.state == .loading else {
            throw HarnessError.assertion("stale completion replaced the current path/load state")
        }
        machine.cancel(generation: staleGeneration)
        guard machine.state == .loading else {
            throw HarnessError.assertion("stale cancellation changed the replacement request")
        }

        let repeatedRequest = CachedImageLoadStateMachine.Request(
            path: "/tmp/repeated.jpg",
            thumbnailPixelSize: size
        )
        let firstRepeatedGeneration = machine.begin(request: repeatedRequest)
        let currentRepeatedGeneration = machine.begin(request: repeatedRequest)
        let acceptedRepeatedCompletion = machine.complete(
            request: repeatedRequest,
            generation: firstRepeatedGeneration,
            imageAvailable: true
        )
        guard !acceptedRepeatedCompletion,
              machine.state == .loading else {
            throw HarnessError.assertion("stale generation completed a repeated image request")
        }
        machine.complete(
            request: repeatedRequest,
            generation: currentRepeatedGeneration,
            imageAvailable: true
        )
        guard machine.state == .ready else {
            throw HarnessError.assertion("current repeated image request did not complete")
        }
    }

    private static func verifyHeroReadinessIdentity() throws {
        var tracker = HeroArtworkReadinessTracker()
        tracker.receive(artworkID: "media", path: "/tmp/first.jpg", state: .loading)
        guard !tracker.revealsHeroContent(artworkID: "media", path: "/tmp/first.jpg") else {
            throw HarnessError.assertion("hero content must remain hidden while backdrop is loading")
        }

        tracker.receive(artworkID: "media", path: "/tmp/replacement.jpg", state: .loading)
        tracker.receive(artworkID: "media", path: "/tmp/first.jpg", state: .ready)
        guard tracker.state(artworkID: "media", path: "/tmp/replacement.jpg") == .loading,
              !tracker.revealsHeroContent(artworkID: "media", path: "/tmp/replacement.jpg") else {
            throw HarnessError.assertion("stale hero completion replaced the current artwork request")
        }

        tracker.receive(artworkID: "media", path: "/tmp/replacement.jpg", state: .ready)
        guard tracker.revealsHeroContent(artworkID: "media", path: "/tmp/replacement.jpg") else {
            throw HarnessError.assertion("current ready backdrop must reveal the complete hero unit")
        }
        guard tracker.revealsHeroContent(artworkID: "media", path: nil) else {
            throw HarnessError.assertion("nil-path hero must reveal its terminal fallback")
        }

        guard tracker.revealsHeroContent(artworkID: "media", path: "/tmp/replacement.jpg") else {
            throw HarnessError.assertion("role changes must preserve readiness for the same media artwork")
        }
    }

    private static func verifyPlaceholderPresentation() throws {
        let suppressed = CachedImagePlaceholderPresentation.resolve(
            explicitIconOpacity: 0,
            isTerminalFallback: true
        )
        guard suppressed.iconOpacity == 0,
              suppressed.wordmarkOpacity == 0 else {
            throw HarnessError.assertion("explicit placeholder suppression must hide icon and wordmark")
        }

        let explicit = CachedImagePlaceholderPresentation.resolve(
            explicitIconOpacity: 0.55,
            isTerminalFallback: false
        )
        guard explicit.iconOpacity == 0.55,
              explicit.wordmarkOpacity == 0.55 else {
            throw HarnessError.assertion("explicit placeholder opacity must apply to icon and wordmark")
        }

        let loadingDefault = CachedImagePlaceholderPresentation.resolve(
            explicitIconOpacity: nil,
            isTerminalFallback: false
        )
        let fallbackDefault = CachedImagePlaceholderPresentation.resolve(
            explicitIconOpacity: nil,
            isTerminalFallback: true
        )
        guard loadingDefault.iconOpacity == 0.18,
              loadingDefault.wordmarkOpacity == 0.34,
              fallbackDefault.iconOpacity == 0.32,
              fallbackDefault.wordmarkOpacity == 0.34 else {
            throw HarnessError.assertion("default placeholder presentation changed unexpectedly")
        }
    }

    private static func verifyCoalescedDecode() throws {
        var decodeCount = 0
        let pipeline = ImageDecodePipeline.makeForHarness(
            resolvePath: { path, _ in path },
            decode: { _ in
                decodeCount += 1
                Thread.sleep(forTimeInterval: 0.03)
                return NSImage(size: NSSize(width: 12, height: 12))
            }
        )

        let callbackQueue = DispatchQueue(label: "verify-image-pipeline.coalesced.callback")
        let finished = DispatchSemaphore(value: 0)
        var callbackCount = 0

        let firstToken = pipeline.load(path: "/tmp/poster.jpg", thumbnailPixelSize: CGSize(width: 120, height: 180), callbackQueue: callbackQueue) { image in
            if image != nil { callbackCount += 1 }
            finished.signal()
        }
        let secondToken = pipeline.load(path: "/tmp/poster.jpg", thumbnailPixelSize: CGSize(width: 120, height: 180), callbackQueue: callbackQueue) { image in
            if image != nil { callbackCount += 1 }
            finished.signal()
        }

        try withExtendedLifetime((firstToken, secondToken)) {
            guard finished.wait(timeout: .now() + 2) == .success,
                  finished.wait(timeout: .now() + 2) == .success else {
                throw HarnessError.assertion("timed out waiting for coalesced callbacks")
            }
            callbackQueue.sync {}
        }

        guard decodeCount == 1 else {
            throw HarnessError.assertion("expected 1 decode for duplicate requests, got \(decodeCount)")
        }
        guard callbackCount == 2 else {
            throw HarnessError.assertion("expected both coalesced callbacks, got \(callbackCount)")
        }
    }

    private static func verifyCancellationSuppressesCompletion() throws {
        let decodeStarted = DispatchSemaphore(value: 0)
        let releaseDecode = DispatchSemaphore(value: 0)
        var callbackCount = 0
        let pipeline = ImageDecodePipeline.makeForHarness(
            resolvePath: { path, _ in path },
            decode: { _ in
                decodeStarted.signal()
                _ = releaseDecode.wait(timeout: .now() + 2)
                return NSImage(size: NSSize(width: 8, height: 8))
            }
        )

        let callbackQueue = DispatchQueue(label: "verify-image-pipeline.cancel.callback")
        let token = pipeline.load(path: "/tmp/cancel.jpg", thumbnailPixelSize: nil, callbackQueue: callbackQueue) { _ in
            callbackCount += 1
        }

        guard decodeStarted.wait(timeout: .now() + 2) == .success else {
            throw HarnessError.assertion("decode did not start")
        }
        token.cancel()
        releaseDecode.signal()
        Thread.sleep(forTimeInterval: 0.08)
        callbackQueue.sync {}

        guard callbackCount == 0 else {
            throw HarnessError.assertion("cancelled request still completed")
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
