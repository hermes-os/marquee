import Combine
import Foundation
import SwiftUI
import AppKit

// MARK: - Remote Input Router

enum RemoteCommand: Equatable {
    case up
    case down
    case left
    case right
    case select
    case back
}

final class RemoteCommandEvent {
    let id = UUID()
    let command: RemoteCommand
    private let lock = NSLock()
    private var consumed = false

    init(command: RemoteCommand) {
        self.command = command
    }

    func consume() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard !consumed else { return false }
        consumed = true
        return true
    }
}

final class RemoteInputRouter: ObservableObject {
    let events = PassthroughSubject<RemoteCommandEvent, Never>()

    func send(_ command: RemoteCommand) {
        events.send(RemoteCommandEvent(command: command))
    }
}

#if DEBUG
enum VerifyRemoteInputHarness {
    static let launchArgument = "--verify-remote-input"

    static func runIfRequested() {
        guard CommandLine.arguments.contains(launchArgument) else { return }

        do {
            let detail = try runScenario()
            FileHandle.standardError.write(Data("verify-remote-input: PASS commandStream: \(detail)\n".utf8))
            FileHandle.standardError.write(Data("verify-remote-input: outcome=verified passed=29/29\n".utf8))
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("verify-remote-input: FAIL commandStream: \(error)\n".utf8))
            FileHandle.standardError.write(Data("verify-remote-input: outcome=failed passed=0/29\n".utf8))
            exit(1)
        }
    }

    /// Headless subset: every pure policy check, none of the animated AppKit
    /// placement paths, so a display-less toolchain host can gate focus policy.
    static let policyOnlyArgument = "--verify-hud-focus-policy"

    static func runPolicyOnlyIfRequested() {
        guard CommandLine.arguments.contains(policyOnlyArgument) else { return }

        do {
            try verifyHomeFocusEngineTree()
            try verifyHeroWraparound()
            try verifyHomeSectionIdentityForScrolling()
            try verifyRemoteFocusScrollAnchors()
            try verifyBrowseReturnPlacementPolicy()
            try verifyPendingBrowseReturnPlacementLifecycle()
            try verifyBrowseSurfaceExitPolicy()
            try verifyRemoteScrollRequestGate()
            try verifyProgrammaticScrollPolicy()
            try verifyHorizontalFocusScrollPolicy()
            try verifyPlayerHUDFocusPolicy()
            try verifyFocusChromePolicy()
            try verifyDetailPlacementPolicy()
            try verifyDetailEpisodeTraversalPolicy()
            try verifyBrowseRemoteCatcherPolicy()
            try verifyRemoteOwnershipMatrix()
            try verifySearchInputOwnership()
            try verifySidebarProfilePresentationPolicy()
            try verifyAppRouterSidebarTraversal()
            FileHandle.standardError.write(Data("verify-hud-focus-policy: PASS policy checks\n".utf8))
            FileHandle.standardError.write(Data("verify-hud-focus-policy: outcome=verified passed=19/19\n".utf8))
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("verify-hud-focus-policy: FAIL \(error)\n".utf8))
            FileHandle.standardError.write(Data("verify-hud-focus-policy: outcome=failed\n".utf8))
            exit(1)
        }
    }

    private static func runScenario() throws -> String {
        let router = RemoteInputRouter()

        router.send(.select)

        var received: [RemoteCommand] = []
        let cancellable = router.events.sink { event in
            received.append(event.command)
        }
        defer { cancellable.cancel() }

        guard received.isEmpty else {
            throw HarnessError.assertion("subscriber received stale pre-subscription command(s): \(received)")
        }

        router.send(.select)

        guard received == [.select] else {
            throw HarnessError.assertion("expected one live select after subscription, got \(received)")
        }

        let backEvent = RemoteCommandEvent(command: .back)
        guard backEvent.consume() else {
            throw HarnessError.assertion("first consumer could not consume a fresh back event")
        }
        guard !backEvent.consume() else {
            throw HarnessError.assertion("second consumer consumed the same back event")
        }

        try verifyHomeFocusEngineTree()
        try verifyHeroWraparound()
        try verifyHomeSectionIdentityForScrolling()
        try verifyRemoteFocusScrollAnchors()
        try verifyHomeHeroScrollPlacement()
        try verifyHomeRowScrollPlacement()
        try verifyBrowseGridSpringAdoption()
        try verifyBrowseReturnPlacementPolicy()
        try verifyPendingBrowseReturnPlacementLifecycle()
        try verifyBrowseSurfaceExitPolicy()
        let homeScrollRuntimeDetail = try VerifyHomeScrollRuntimeHarness.verify()
        try verifyRemoteScrollRequestGate()
        try verifyProgrammaticScrollPolicy()
        try verifyScrollAnimationCoalescer()
        try verifyScrollSpringAnimator()
        try verifyScrollMotionProductionPath()
        try verifyHorizontalFocusScrollPolicy()
        try verifyPlayerHUDFocusPolicy()
        try verifyFocusChromePolicy()
        try verifyDetailPlacementPolicy()
        try verifyDetailEpisodeTraversalPolicy()
        try verifyDetailEpisodeRowScrollLayout()
        try verifyBrowseRemoteCatcherPolicy()
        try verifyRemoteOwnershipMatrix()
        try verifySearchInputOwnership()
        try verifyRemoteScrollSafety()
        try verifySidebarProfilePresentationPolicy()
        try verifyAppRouterSidebarTraversal()

        return "pre-subscription select was not replayed; next select delivered once; commands are single-consumer; the Home FocusEngine tree orders header, hero, and rows, inherits the focused column into the next row, and restores it on return; Hero index arithmetic wraps left and right; Home scroll section changes only on vertical focus moves; focused rows use a TV reading-band scroll anchor; Home hero returns through an explicit AppKit top scroll target; Home rows use measured AppKit scroll placement; browse grids reuse the same Home row comfort check and spring path for vertical focused-row motion; return focus maps header/hero to top and stable row IDs to the reading band; pending return placement rejects stale geometry and permits one measured correction; composite surface exits place only after the final blocker disappears; \(homeScrollRuntimeDetail); stale queued scroll requests are ignored; macOS 12 programmatic scroll animations are disabled; animated AppKit requests collapse obsolete pending targets and detach stale scroll-view ownership; all focusable poster rows use flat-leading, exact whole-card monotonic offsets with trailing clamp through AppKit placement; Home header Play Something is reachable above the hero and activates playback; Player HUD traverses canvas, Back, and capability-filtered transport controls with remembered return focus; FocusChrome poster lift and row halo headroom stay inside the Gate A taste contract; detail placement authority suppresses vertical scroll on same-row horizontal moves and corrects measured vertical targets once into the detail band; Show detail episode-list entry starts at the boundary episode for the traversal direction; Show detail episode rows use measured viewport correction instead of SwiftUI edge snapping; browse key catcher is mounted only on remote-owned surfaces; remote ownership derivation matches the legacy catcher truth table across all 160 modal states with correct precedence; search consumes remote commands only while searchRoot owns input and captures physical typing only for searchRoot/sidebar owners across all 160 modal states; unified scroll placement matches the frozen legacy formulas and degenerate scroll geometry is rejected before reaching AppKit; sidebar profile presentation normalizes root focus before the picker owns input; AppRouter reproduces the sidebar traversal state machine including Play Something remote activation, profile affordance entry, boundary Left no-op, and route commit focus release"
    }

    private static func verifyBrowseReturnPlacementPolicy() throws {
        let cases: [(BrowseReturnFocus?, BrowseReturnPlacementTarget?)] = [
            (.header, .top),
            (.hero, .top),
            (.row("recently-watched"), .row("recently-watched")),
            (nil, nil),
        ]
        for (focus, expected) in cases {
            guard BrowseReturnPlacementPolicy.target(for: focus) == expected else {
                throw HarnessError.assertion("return target mismatch focus=\(String(describing: focus)) expected=\(String(describing: expected))")
            }
        }
        guard BrowseReturnFocus.home(.playSomething, rowID: nil) == .header,
              BrowseReturnFocus.home(.hero, rowID: nil) == .hero,
              BrowseReturnFocus.home(.row(RemoteGridPosition(row: 4, column: 2)), rowID: "recently-watched") == .row("recently-watched") else {
            throw HarnessError.assertion("Home return-focus adapter did not preserve header/hero/stable row identity")
        }
        guard BrowseReturnFocus.grid(rowID: "genre-drama") == .row("genre-drama"),
              BrowseReturnFocus.grid(rowID: nil) == nil else {
            throw HarnessError.assertion("Movies/TV return-focus adapter must use stable row IDs and reject missing rows")
        }
    }

    private static func verifyPendingBrowseReturnPlacementLifecycle() throws {
        var state = PendingBrowseReturnPlacement()
        let serial = state.issue(target: .row("recently-watched"), focusGeneration: 3, attachmentEpoch: 7)
        guard state.isActive(serial: serial) else {
            throw HarnessError.assertion("new return placement request was not active")
        }
        let valid = BrowseReturnGeometrySample(
            target: .row("recently-watched"),
            targetMinY: 1_020,
            viewportHeight: 900,
            currentOffset: 600,
            contentHeight: 2_400,
            attachmentEpoch: 7,
            focusGeneration: 3
        )
        guard state.consume(sample: valid, serial: serial) == 696 else {
            throw HarnessError.assertion("initial return placement did not resolve the focused row to the 36% reading band")
        }
        guard state.consume(sample: BrowseReturnGeometrySample(
            target: valid.target,
            targetMinY: 1_020,
            viewportHeight: 900,
            currentOffset: 696,
            contentHeight: 2_400,
            attachmentEpoch: 7,
            focusGeneration: 3
        ), serial: serial) == nil else {
            throw HarnessError.assertion("identical post-scroll geometry spent the measured-correction budget")
        }
        guard state.isAwaitingMeasuredCorrection(serial: serial) else {
            throw HarnessError.assertion("placed return echo did not open the measured-correction window")
        }
        guard state.consume(sample: BrowseReturnGeometrySample(
            target: valid.target,
            targetMinY: 1_020,
            viewportHeight: 900,
            currentOffset: 696,
            contentHeight: 2_400,
            attachmentEpoch: 6,
            focusGeneration: 3
        ), serial: serial) == nil else {
            throw HarnessError.assertion("stale attachment geometry was accepted")
        }
        guard state.consume(sample: BrowseReturnGeometrySample(
            target: valid.target,
            targetMinY: 1_150,
            viewportHeight: 900,
            currentOffset: 696,
            contentHeight: 2_400,
            attachmentEpoch: 7,
            focusGeneration: 3
        ), serial: serial) == 826 else {
            throw HarnessError.assertion("one out-of-band geometry change did not receive its measured correction")
        }
        guard state.isActive(serial: serial) else {
            throw HarnessError.assertion("measured correction did not remain active for its geometry echo")
        }
        guard state.consume(sample: BrowseReturnGeometrySample(
            target: valid.target,
            targetMinY: 1_290,
            viewportHeight: 900,
            currentOffset: 826,
            contentHeight: 2_400,
            attachmentEpoch: 7,
            focusGeneration: 3
        ), serial: serial) == nil else {
            throw HarnessError.assertion("return placement issued more than one measured correction")
        }
        guard !state.isActive(serial: serial) else {
            throw HarnessError.assertion("completed return placement remained externally active")
        }

        let superseded = state.issue(target: .row("all-movies"), focusGeneration: 4, attachmentEpoch: 8)
        guard state.consume(sample: valid, serial: serial) == nil,
              superseded != serial else {
            throw HarnessError.assertion("a superseded return request remained active")
        }
        state.cancel(focusGeneration: 5)
        guard !state.isActive(serial: superseded) else {
            throw HarnessError.assertion("cancelled return placement remained externally active")
        }
        guard state.consume(sample: BrowseReturnGeometrySample(
            target: .row("all-movies"),
            targetMinY: 900,
            viewportHeight: 900,
            currentOffset: 500,
            contentHeight: 2_400,
            attachmentEpoch: 8,
            focusGeneration: 4
        ), serial: superseded) == nil else {
            throw HarnessError.assertion("focus-generation cancellation left a return request active")
        }

        var rebound = PendingBrowseReturnPlacement()
        let reboundSerial = rebound.issue(
            target: .row("recently-watched"),
            focusGeneration: 8,
            attachmentEpoch: 10
        )
        let reboundSample = BrowseReturnGeometrySample(
            target: .row("recently-watched"),
            targetMinY: 1_020,
            viewportHeight: 900,
            currentOffset: 600,
            contentHeight: 2_400,
            attachmentEpoch: 12,
            focusGeneration: 8
        )
        guard rebound.consume(sample: reboundSample, serial: reboundSerial) == 696 else {
            throw HarnessError.assertion("return placement did not rebind after scroll-view reattachment")
        }
        guard rebound.consume(sample: BrowseReturnGeometrySample(
            target: reboundSample.target,
            targetMinY: reboundSample.targetMinY,
            viewportHeight: reboundSample.viewportHeight,
            currentOffset: 696,
            contentHeight: reboundSample.contentHeight,
            attachmentEpoch: 10,
            focusGeneration: reboundSample.focusGeneration
        ), serial: reboundSerial) == nil else {
            throw HarnessError.assertion("pre-reattachment geometry was accepted after rebinding")
        }

        var tolerance = PendingBrowseReturnPlacement()
        let toleranceSerial = tolerance.issue(
            target: .row("recently-watched"),
            focusGeneration: 9,
            attachmentEpoch: 20
        )
        let toleranceInitial = BrowseReturnGeometrySample(
            target: .row("recently-watched"),
            targetMinY: 1_020,
            viewportHeight: 900,
            currentOffset: 600,
            contentHeight: 2_400,
            attachmentEpoch: 20,
            focusGeneration: 9
        )
        guard tolerance.consume(sample: toleranceInitial, serial: toleranceSerial) == 696,
              tolerance.consume(sample: BrowseReturnGeometrySample(
                target: toleranceInitial.target,
                targetMinY: toleranceInitial.targetMinY,
                viewportHeight: toleranceInitial.viewportHeight,
                currentOffset: 696,
                contentHeight: toleranceInitial.contentHeight,
                attachmentEpoch: toleranceInitial.attachmentEpoch,
                focusGeneration: toleranceInitial.focusGeneration
              ), serial: toleranceSerial) == nil,
              tolerance.consume(sample: BrowseReturnGeometrySample(
                target: toleranceInitial.target,
                targetMinY: 1_040,
                viewportHeight: toleranceInitial.viewportHeight,
                currentOffset: 696,
                contentHeight: toleranceInitial.contentHeight,
                attachmentEpoch: toleranceInitial.attachmentEpoch,
                focusGeneration: toleranceInitial.focusGeneration
              ), serial: toleranceSerial) == nil,
              tolerance.consume(sample: BrowseReturnGeometrySample(
                target: toleranceInitial.target,
                targetMinY: 1_180,
                viewportHeight: toleranceInitial.viewportHeight,
                currentOffset: 696,
                contentHeight: toleranceInitial.contentHeight,
                attachmentEpoch: toleranceInitial.attachmentEpoch,
                focusGeneration: toleranceInitial.focusGeneration
              ), serial: toleranceSerial) == nil else {
            throw HarnessError.assertion("in-band return geometry did not close the correction lifecycle")
        }

        var removedTarget = PendingBrowseReturnPlacement()
        let removedTargetSerial = removedTarget.issue(
            target: .row("removed-row"),
            focusGeneration: 10,
            attachmentEpoch: 30
        )
        removedTarget.cancelIfTargetChanged(to: nil)
        guard removedTarget.consume(sample: BrowseReturnGeometrySample(
            target: .row("removed-row"),
            targetMinY: 1_020,
            viewportHeight: 900,
            currentOffset: 600,
            contentHeight: 2_400,
            attachmentEpoch: 30,
            focusGeneration: 10
        ), serial: removedTargetSerial) == nil else {
            throw HarnessError.assertion("removed return target left a placement request active")
        }

        var invalidGeometry = PendingBrowseReturnPlacement()
        let invalidSerial = invalidGeometry.issue(
            target: .row("recently-watched"),
            focusGeneration: 11,
            attachmentEpoch: 40
        )
        for invalidValue in [CGFloat.nan, .infinity, -.infinity] {
            guard invalidGeometry.consume(sample: BrowseReturnGeometrySample(
                target: .row("recently-watched"),
                targetMinY: invalidValue,
                viewportHeight: 900,
                currentOffset: 600,
                contentHeight: 2_400,
                attachmentEpoch: 40,
                focusGeneration: 11
            ), serial: invalidSerial) == nil else {
                throw HarnessError.assertion("non-finite return geometry produced a placement")
            }
        }
        guard invalidGeometry.consume(sample: BrowseReturnGeometrySample(
            target: .row("recently-watched"),
            targetMinY: 1_020,
            viewportHeight: 900,
            currentOffset: 600,
            contentHeight: -1,
            attachmentEpoch: 40,
            focusGeneration: 11
        ), serial: invalidSerial) == nil else {
            throw HarnessError.assertion("negative content extent produced a return placement")
        }
    }

    private static func verifyBrowseSurfaceExitPolicy() throws {
        func state(
            _ detail: Bool,
            _ player: Bool,
            _ handoff: String? = nil,
            route: BrowseSurfaceRoute = .home
        ) -> BrowseSurfacePresentationState {
            BrowseSurfacePresentationState(
                route: route,
                detailVisible: detail,
                playerVisible: player,
                postPlayID: handoff
            )
        }

        guard BrowseSurfaceExitPolicy.shouldPlace(from: state(false, true), to: state(false, false)) else {
            throw HarnessError.assertion("manual player dismissal did not place the exposed browse surface")
        }
        let endedSequence = [
            state(false, true),
            state(false, true, "handoff"),
            state(false, false, "handoff"),
            state(false, false),
        ]
        let endedDecisions = zip(endedSequence, endedSequence.dropFirst()).map {
            BrowseSurfaceExitPolicy.shouldPlace(from: $0.0, to: $0.1)
        }
        guard endedDecisions == [false, false, true] else {
            throw HarnessError.assertion("ended playback placed between overlays or missed final dismissal: \(endedDecisions)")
        }
        guard !BrowseSurfaceExitPolicy.shouldPlace(from: state(true, true), to: state(true, false)),
              BrowseSurfaceExitPolicy.shouldPlace(from: state(true, false), to: state(false, false)),
              !BrowseSurfaceExitPolicy.shouldPlace(from: state(false, true, route: .home), to: state(false, false, route: .movies)),
              !BrowseSurfaceExitPolicy.shouldPlace(from: state(false, false), to: state(false, false)) else {
            throw HarnessError.assertion("composite exit policy mishandled overlapping detail, route change, or repeated state")
        }
    }

    /// Home's header/hero/rows tree as `HomeDetailView` builds it. Proves the
    /// shared engine reproduces the legacy vertical order and the
    /// remembered-then-inherit column behavior that `RemoteHomeFocus` provided.
    /// Hero wrap is surface-local edge policy and is covered by the view.
    private static func verifyHomeFocusEngineTree() throws {
        let heroCount = 3
        let rows = [("continue-watching", 4), ("recently-added", 3)]
        let tree = FocusNode(
            "home-root",
            kind: .container(.vertical),
            children: [FocusNode("home-play-something", kind: .leaf)]
                + [
                    FocusNode(
                        "home-hero",
                        kind: .container(.grid(columns: heroCount)),
                        children: (0..<heroCount).map {
                            FocusNode(
                                FocusNodeID("home-hero-item:\($0)"),
                                kind: .leaf,
                                guides: [.down: "home-row:continue-watching"]
                            )
                        }
                    )
                ]
                + rows.map { id, count in
                    FocusNode(
                        FocusNodeID("home-row:\(id)"),
                        kind: .container(.grid(columns: count)),
                        children: (0..<count).map {
                            FocusNode(FocusNodeID("home-item:\(id):\($0)"), kind: .leaf)
                        }
                    )
                }
        )
        let engine = FocusEngine(root: tree)
        var state = FocusEngineState(focused: "home-hero-item:0")

        func move(_ direction: FocusDirection) {
            state = engine.move(direction, state: state).state
        }

        move(.up)
        guard state.focused == "home-play-something" else {
            throw HarnessError.assertion("expected up from Home hero to reach the header, got \(state.focused)")
        }
        for direction in [FocusDirection.up, .left, .right] {
            move(direction)
            guard state.focused == "home-play-something" else {
                throw HarnessError.assertion("Home header should stay bounded on \(direction), got \(state.focused)")
            }
        }

        move(.down)
        guard state.focused == "home-hero-item:0" else {
            throw HarnessError.assertion("expected down from header to restore the Home hero, got \(state.focused)")
        }

        move(.right)
        move(.right)
        move(.down)
        guard state.focused == "home-item:continue-watching:0" else {
            throw HarnessError.assertion("expected first entry from hero column 2 to start the content row at column 0, got \(state.focused)")
        }

        move(.right)
        move(.right)
        move(.down)
        guard state.focused == "home-item:recently-added:2" else {
            throw HarnessError.assertion("expected the next row to inherit column 2, got \(state.focused)")
        }

        move(.up)
        guard state.focused == "home-item:continue-watching:2" else {
            throw HarnessError.assertion("expected up to restore column 2 in the first row, got \(state.focused)")
        }

        move(.up)
        guard state.focused == "home-hero-item:2" else {
            throw HarnessError.assertion("expected up from the first content row to restore hero column 2, got \(state.focused)")
        }

        let boundary = engine.move(.left, state: FocusEngineState(focused: "home-item:continue-watching:0"))
        guard boundary.events.contains(where: { event in
            if case let .boundaryHit(_, direction) = event { return direction == .left }
            return false
        }) else {
            throw HarnessError.assertion("expected a left boundary at row column 0 so the view can escalate to root back")
        }
    }

    private static func verifyHeroWraparound() throws {
        guard RemoteHomeFocus.wrappedHeroIndex(current: 0, delta: -1, count: 5) == 4 else {
            throw HarnessError.assertion("expected left from first hero to wrap to last")
        }
        guard RemoteHomeFocus.wrappedHeroIndex(current: 4, delta: 1, count: 5) == 0 else {
            throw HarnessError.assertion("expected right from last hero to wrap to first")
        }
        guard RemoteHomeFocus.wrappedHeroIndex(current: 2, delta: 1, count: 5) == 3 else {
            throw HarnessError.assertion("expected middle hero to advance normally")
        }
        guard RemoteHomeFocus.wrappedHeroIndex(current: 2, delta: -1, count: 5) == 1 else {
            throw HarnessError.assertion("expected middle hero to reverse normally")
        }
    }

    private static func verifyHomeSectionIdentityForScrolling() throws {
        let rowIDs = ["continue-watching", "recently-added", "all-movies"]

        func rowID(_ row: Int) -> String? {
            rowIDs.indices.contains(row) ? rowIDs[row] : nil
        }

        guard RemoteHomeFocus.playSomething.sectionID(hasHero: true, rowID: rowID) == nil else {
            throw HarnessError.assertion("expected the header to have no scroll section")
        }

        guard RemoteHomeFocus.hero.sectionID(hasHero: true, rowID: rowID) == "hero-spotlight" else {
            throw HarnessError.assertion("expected hero section id before moving into content")
        }

        let firstRow = RemoteHomeFocus.row(RemoteGridPosition(row: 0, column: 0))
        guard firstRow.sectionID(hasHero: true, rowID: rowID) == "continue-watching" else {
            throw HarnessError.assertion("expected first content row section for row 0")
        }

        // Column is not part of scroll section identity, so horizontal moves
        // inside a row never change the vertical scroll target.
        let firstRowShifted = RemoteHomeFocus.row(RemoteGridPosition(row: 0, column: 3))
        guard firstRowShifted.sectionID(hasHero: true, rowID: rowID)
            == firstRow.sectionID(hasHero: true, rowID: rowID) else {
            throw HarnessError.assertion("horizontal focus move should not change vertical scroll section")
        }

        let secondRow = RemoteHomeFocus.row(RemoteGridPosition(row: 1, column: 0))
        guard secondRow.sectionID(hasHero: true, rowID: rowID) == "recently-added" else {
            throw HarnessError.assertion("vertical focus move should change scroll section to next row")
        }
    }

    private static func verifyRemoteFocusScrollAnchors() throws {
        guard (0.30...0.42).contains(RemoteFocusScrollAnchor.row.y) else {
            throw HarnessError.assertion("focused row anchor should stay in the TV reading band, got \(RemoteFocusScrollAnchor.row.y)")
        }
        guard (0.26...0.36).contains(RemoteFocusScrollAnchor.detail.y) else {
            throw HarnessError.assertion("detail focus anchor should stay in the TV reading band, got \(RemoteFocusScrollAnchor.detail.y)")
        }
        guard (0.26...0.36).contains(RemoteFocusScrollAnchor.detailRow.y) else {
            throw HarnessError.assertion("detail related-row anchor should stay in the same focus-static reading band, got \(RemoteFocusScrollAnchor.detailRow.y)")
        }
        guard RemoteFocusScrollAnchor.detailTop.y == 0 else {
            throw HarnessError.assertion("detail top anchor should preserve the page hero at the top")
        }
        guard DetailRelatedRowLayout.topClearance(isLeanBack: false) >= 80 else {
            throw HarnessError.assertion("compact related-row clearance should keep the section heading below the back chrome")
        }
        guard DetailRelatedRowLayout.topClearance(isLeanBack: true) >= 120 else {
            throw HarnessError.assertion("lean-back related-row clearance should keep the section heading below the back chrome")
        }
        guard DetailBackChromeLayout.fitsBeforeContent(isLeanBack: false) else {
            throw HarnessError.assertion("compact detail back chrome should fit in the gutter before content starts")
        }
        guard DetailBackChromeLayout.fitsBeforeContent(isLeanBack: true) else {
            throw HarnessError.assertion("lean-back detail back chrome should fit in the gutter before content starts")
        }
    }

    private static func verifyHomeHeroScrollPlacement() throws {
        guard RemoteHomeHeroScrollPlacement.targetOffset(currentOffset: 0) == 0 else {
            throw HarnessError.assertion("Home hero return should preserve the scroll origin when already at top")
        }
        guard RemoteHomeHeroScrollPlacement.targetOffset(currentOffset: 640) == 0 else {
            throw HarnessError.assertion("Home hero return should target the scroll origin instead of a stale row offset")
        }

        try verifyHomeSpringAdoptionPreservesTargets()
    }

    /// M1 slice 2: Home rows and the hero return target now reach their offsets
    /// through the spring. The frozen formulas stay the source of truth, so the
    /// spring must land on exactly the offset they produce, and Reduce Motion must
    /// still place instantly on that same offset.
    private static func verifyHomeSpringAdoptionPreservesTargets() throws {
        let spring = MarqueeTheme.focusScrollSpring
        let settle = spring.settlingDuration

        // Hero return: the frozen target is the scroll origin from any offset.
        let heroTarget = RemoteHomeHeroScrollPlacement.targetOffset(currentOffset: 640)
        var hero = RemoteScrollSpringDriver()
        guard hero.request(
            target: heroTarget, from: 640, at: 0, animated: true, reduceMotion: false
        ) == .animating else {
            throw HarnessError.assertion("hero return over a real distance should spring")
        }
        guard let heroEnd = hero.tick(at: settle),
              heroEnd.offset == heroTarget, heroEnd.isFinished else {
            throw HarnessError.assertion("hero spring must terminate on the frozen hero target exactly")
        }

        // Reduce Motion places on the identical offset without animating.
        var heroReduced = RemoteScrollSpringDriver()
        guard heroReduced.request(
            target: heroTarget, from: 640, at: 0, animated: true, reduceMotion: true
        ) == .settle(heroTarget), !heroReduced.isAnimating else {
            throw HarnessError.assertion("Reduce Motion must place the hero return instantly on the frozen target")
        }

        // Home rows: the frozen comfort target for a measured row.
        let viewportHeight: CGFloat = 900
        let rowTarget = RemoteHomeRowScrollPlacement.targetOffset(
            currentOffset: 0,
            rowViewportTop: 820,
            desiredViewportTop: RemoteHomeRowScrollPlacement.desiredViewportTop(
                viewportHeight: viewportHeight
            )
        )
        var row = RemoteScrollSpringDriver()
        guard row.request(
            target: rowTarget, from: 0, at: 0, animated: true, reduceMotion: false
        ) == .animating else {
            throw HarnessError.assertion("a row placement over a real distance should spring")
        }
        let rowEnd = row.tick(at: settle)
        guard rowEnd?.offset == rowTarget, rowEnd?.isFinished == true else {
            throw HarnessError.assertion("row spring must terminate on the frozen row target exactly, got \(String(describing: rowEnd)) vs \(rowTarget)")
        }

        // A held direction key retargets mid-glide and still lands exactly.
        var repeated = RemoteScrollSpringDriver()
        _ = repeated.request(target: rowTarget, from: 0, at: 0, animated: true, reduceMotion: false)
        guard let inFlight = repeated.tick(at: spring.response * 0.2), !inFlight.isFinished else {
            throw HarnessError.assertion("expected an in-flight row tick before the repeat")
        }
        let nextRowTarget = rowTarget + 240
        _ = repeated.request(
            target: nextRowTarget,
            from: inFlight.offset,
            at: spring.response * 0.2,
            animated: true,
            reduceMotion: false
        )
        guard let repeatedEnd = repeated.tick(at: spring.response * 0.2 + settle),
              repeatedEnd.offset == nextRowTarget, repeatedEnd.isFinished else {
            throw HarnessError.assertion("a repeated row move must terminate on the newer frozen target exactly")
        }
    }

    private static func verifyHomeRowScrollPlacement() throws {
        guard RemoteHomeRowScrollPlacement.desiredViewportTop(viewportHeight: 900) == 324 else {
            throw HarnessError.assertion("expected Home row comfort target to use 36% of the viewport")
        }
        guard RemoteHomeRowScrollPlacement.desiredViewportTop(viewportHeight: 520) == 210 else {
            throw HarnessError.assertion("expected compact Home row comfort target to keep rows below the title bar")
        }

        let hiddenAboveHeader = RemoteHomeRowScrollPlacement.targetOffset(
            currentOffset: 600,
            rowViewportTop: 40,
            desiredViewportTop: RemoteHomeRowScrollPlacement.desiredViewportTop(viewportHeight: 900)
        )
        guard hiddenAboveHeader == 316 else {
            throw HarnessError.assertion("expected hidden Home row to scroll back to the TV-safe band, got \(hiddenAboveHeader)")
        }

        let belowReadingBand = RemoteHomeRowScrollPlacement.targetOffset(
            currentOffset: 600,
            rowViewportTop: 500,
            desiredViewportTop: RemoteHomeRowScrollPlacement.desiredViewportTop(viewportHeight: 900)
        )
        guard belowReadingBand == 776 else {
            throw HarnessError.assertion("expected low Home row to scroll forward to the TV-safe band, got \(belowReadingBand)")
        }

        let clampedTop = RemoteHomeRowScrollPlacement.targetOffset(
            currentOffset: 90,
            rowViewportTop: 80,
            desiredViewportTop: RemoteHomeRowScrollPlacement.desiredViewportTop(viewportHeight: 900)
        )
        guard clampedTop == 0 else {
            throw HarnessError.assertion("expected Home row target to clamp at top, got \(clampedTop)")
        }

        guard RemoteHomeRowScrollPlacement.isComfortablyPlaced(
            rowViewportTop: 318,
            viewportHeight: 900
        ) else {
            throw HarnessError.assertion("expected a Home row near the comfort target to avoid corrective scrolling")
        }

        guard !RemoteHomeRowScrollPlacement.isComfortablyPlaced(
            rowViewportTop: 49,
            viewportHeight: 900
        ) else {
            throw HarnessError.assertion("expected a Home row pinned near the window top to require corrective scrolling")
        }

        guard RemotePointerRegionPolicy.rowHoverControlsEnabled(isKeyboardFocusActive: false) else {
            throw HarnessError.assertion("expected pointer hover controls to remain available during pointer browsing")
        }

        guard !RemotePointerRegionPolicy.rowHoverControlsEnabled(isKeyboardFocusActive: true) else {
            throw HarnessError.assertion("expected pointer hover controls to stay hidden while keyboard focus owns a row")
        }
    }

    /// M1 browse grid vertical scroll: Movies and TV browse grids reuse
    /// `RemoteHomeRowScrollPlacement` and reach their offsets through the spring.
    /// The frozen formulas stay the source of truth, so the spring must land on
    /// exactly the offset they produce, and Reduce Motion must still place
    /// instantly on that same offset.
    private static func verifyBrowseGridSpringAdoption() throws {
        let spring = MarqueeTheme.focusScrollSpring
        let settle = spring.settlingDuration

        let viewportHeight: CGFloat = 900
        let rowViewportTop: CGFloat = 820
        let targetOffset = RemoteHomeRowScrollPlacement.targetOffset(
            currentOffset: 0,
            rowViewportTop: rowViewportTop,
            desiredViewportTop: RemoteHomeRowScrollPlacement.desiredViewportTop(viewportHeight: viewportHeight)
        )

        var driver = RemoteScrollSpringDriver()
        guard driver.request(
            target: targetOffset, from: 0, at: 0, animated: true, reduceMotion: false
        ) == .animating else {
            throw HarnessError.assertion("browse grid row placement over a real distance should spring")
        }
        guard let end = driver.tick(at: settle),
              end.offset == targetOffset, end.isFinished else {
            throw HarnessError.assertion("browse grid spring must terminate on the frozen row target exactly")
        }

        var reduced = RemoteScrollSpringDriver()
        guard reduced.request(
            target: targetOffset, from: 0, at: 0, animated: true, reduceMotion: true
        ) == .settle(targetOffset), !reduced.isAnimating else {
            throw HarnessError.assertion("Reduce Motion must place browse grid rows instantly on the frozen target")
        }

        var repeated = RemoteScrollSpringDriver()
        _ = repeated.request(target: targetOffset, from: 0, at: 0, animated: true, reduceMotion: false)
        guard let inFlight = repeated.tick(at: spring.response * 0.2), !inFlight.isFinished else {
            throw HarnessError.assertion("expected an in-flight browse grid tick before the repeat")
        }
        let nextTarget = targetOffset + 240
        _ = repeated.request(
            target: nextTarget,
            from: inFlight.offset,
            at: spring.response * 0.2,
            animated: true,
            reduceMotion: false
        )
        guard let repeatedEnd = repeated.tick(at: spring.response * 0.2 + settle),
              repeatedEnd.offset == nextTarget, repeatedEnd.isFinished else {
            throw HarnessError.assertion("a repeated browse grid row move must terminate on the newer frozen target exactly")
        }
    }

    private static func verifySidebarProfilePresentationPolicy() throws {
        let state = SidebarProfilePresentationPolicy.normalizedState

        guard state.selectedItem == .home,
              state.focusedSidebarItem == .home,
              state.sidebarRemoteFocused == false,
              state.sidebarFocusOnPlaySomething == false,
              state.sidebarFocusOnProfile == false else {
            throw HarnessError.assertion("sidebar profile presentation must reset to unfocused Home state, got \(state)")
        }

        guard !BrowseRemoteCatcherPolicy.isActive(
            showProfilePicker: true,
            playerPresented: false,
            sidebarRemoteFocused: state.sidebarRemoteFocused,
            selectedItem: state.selectedItem,
            searchHasDetail: false
        ) else {
            throw HarnessError.assertion("profile picker must own remote input after sidebar profile switch")
        }
    }

    private static func verifyAppRouterSidebarTraversal() throws {
        let router = AppRouter()
        router.selectedItem = .movies

        router.focusSidebar()
        guard router.sidebarRemoteFocused,
              !router.sidebarFocusOnPlaySomething,
              !router.sidebarFocusOnProfile,
              router.focusedSidebarItem == .movies else {
            throw HarnessError.assertion("focusSidebar must take remote focus on the selected item")
        }

        router.handleSidebarRemoteCommand(.left, presentProfilePicker: {})
        guard router.sidebarRemoteFocused,
              !router.sidebarFocusOnPlaySomething,
              !router.sidebarFocusOnProfile,
              router.focusedSidebarItem == .movies else {
            throw HarnessError.assertion("Left on the sidebar must be a boundary no-op")
        }

        let items = SidebarItem.allCases
        for _ in items.indices {
            router.handleSidebarRemoteCommand(.down, presentProfilePicker: {})
        }
        guard router.sidebarFocusOnProfile, !router.sidebarFocusOnPlaySomething else {
            throw HarnessError.assertion("Down past the Play Something affordance must land on the profile affordance")
        }

        router.handleSidebarRemoteCommand(.up, presentProfilePicker: {})
        guard !router.sidebarFocusOnProfile, router.sidebarFocusOnPlaySomething else {
            throw HarnessError.assertion("Up from the profile affordance must restore the Play Something affordance")
        }

        router.handleSidebarRemoteCommand(.up, presentProfilePicker: {})
        guard !router.sidebarFocusOnPlaySomething, router.focusedSidebarItem == items.last else {
            throw HarnessError.assertion("Up from Play Something must restore the last sidebar item")
        }

        var played = false
        router.sidebarFocusOnPlaySomething = true
        router.sidebarFocusOnProfile = false
        router.handleSidebarRemoteCommand(
            .select,
            presentProfilePicker: {},
            playSomething: { played = true }
        )
        guard played,
              !router.sidebarRemoteFocused,
              !router.sidebarFocusOnPlaySomething,
              !router.sidebarFocusOnProfile else {
            throw HarnessError.assertion("Select on Play Something must trigger playback and release sidebar focus")
        }

        var presented = false
        router.focusSidebar()
        router.sidebarFocusOnProfile = true
        router.sidebarFocusOnPlaySomething = false
        router.handleSidebarRemoteCommand(.select, presentProfilePicker: { presented = true })
        guard presented else {
            throw HarnessError.assertion("Select on the profile affordance must present the profile picker")
        }

        router.sidebarFocusOnProfile = false
        router.sidebarFocusOnPlaySomething = false
        router.focusedSidebarItem = .settings
        router.handleSidebarRemoteCommand(.select, presentProfilePicker: {})
        guard router.selectedItem == .settings,
              !router.sidebarRemoteFocused,
              !router.sidebarFocusOnPlaySomething,
              !router.sidebarFocusOnProfile else {
            throw HarnessError.assertion("Select on a sidebar item must commit the route and release sidebar focus")
        }
    }

    private static func verifyRemoteScrollRequestGate() throws {
        let gate = RemoteScrollRequestGate()
        let first = gate.issue()
        let second = gate.issue()

        guard !gate.accepts(first) else {
            throw HarnessError.assertion("stale first scroll request was accepted after a newer request")
        }
        guard gate.accepts(second) else {
            throw HarnessError.assertion("newest scroll request was not accepted")
        }
    }

    private static func verifyProgrammaticScrollPolicy() throws {
        let monterey = OperatingSystemVersion(majorVersion: 12, minorVersion: 7, patchVersion: 6)
        let ventura = OperatingSystemVersion(majorVersion: 13, minorVersion: 0, patchVersion: 0)

        guard !RemoteProgrammaticScrollPolicy.allowsAnimatedScroll(on: monterey) else {
            throw HarnessError.assertion("macOS 12 should use non-animated programmatic scrolling to avoid SwiftUI fullscreen scroll-target crashes")
        }
        guard RemoteProgrammaticScrollPolicy.allowsAnimatedScroll(on: ventura) else {
            throw HarnessError.assertion("macOS 13+ should keep animated programmatic scrolling available")
        }

        guard !RemoteAppKitScrollMotion.shouldAnimate(
            requested: true,
            reduceMotion: false,
            operatingSystemVersion: monterey
        ) else {
            throw HarnessError.assertion("AppKit clip-view scrolling must stay instant on macOS 12")
        }
        guard RemoteAppKitScrollMotion.shouldAnimate(
            requested: true,
            reduceMotion: false,
            operatingSystemVersion: ventura
        ) else {
            throw HarnessError.assertion("AppKit clip-view scrolling should allow requested focus easing on macOS 13+")
        }
        guard !RemoteAppKitScrollMotion.shouldAnimate(
                requested: true,
                reduceMotion: true,
                operatingSystemVersion: ventura
              ),
              !RemoteAppKitScrollMotion.shouldAnimate(
                requested: false,
                reduceMotion: false,
                operatingSystemVersion: ventura
              ) else {
            throw HarnessError.assertion("AppKit clip-view scrolling should stay instant for reduce motion and non-animated placement")
        }
        guard MarqueeTheme.focusScrollDuration == 0.22 else {
            throw HarnessError.assertion("AppKit focus scroll duration must use the single 220ms Gate A token")
        }
    }

    /// M1 slice 1: the spring the placement authority will interpolate offsets
    /// with. Asserts it terminates on the exact clamped target, starts from the
    /// current offset when a newer target interrupts it, and is bypassed by
    /// Reduce Motion. No target formula is involved — the spring only moves
    /// between offsets the authority already computed.
    private static func verifyScrollSpringAnimator() throws {
        let spring = MarqueeTheme.focusScrollSpring

        guard spring.progress(at: 0) == 0 else {
            throw HarnessError.assertion("spring should not move before any time elapses")
        }
        guard spring.settlingDuration > 0, spring.settlingDuration < 5 else {
            throw HarnessError.assertion("spring settling duration should be finite and short, got \(spring.settlingDuration)")
        }

        // Terminates on the exact target, not asymptotically near it.
        guard spring.offset(from: 0, to: 1400, at: spring.settlingDuration) == 1400,
              spring.offset(from: 0, to: 1400, at: spring.settlingDuration * 2) == 1400,
              spring.isSettled(at: spring.settlingDuration) else {
            throw HarnessError.assertion("spring must terminate on the exact target offset")
        }

        // Degenerate distances stay exact at every sample.
        guard spring.offset(from: 390, to: 390, at: 0.05) == 390 else {
            throw HarnessError.assertion("a zero-distance spring must hold the offset")
        }

        // Mid-flight it lies strictly between the endpoints and is still moving.
        let mid = spring.offset(from: 0, to: 1000, at: spring.response * 0.25)
        guard mid > 0, mid < 1000, !spring.isSettled(at: spring.response * 0.25) else {
            throw HarnessError.assertion("spring should be in flight a quarter of the way through its response, got \(mid)")
        }

        // Interruption collapse: retargeting from the in-flight offset still ends
        // exactly on the newer target, so a newer request supersedes cleanly.
        let interrupted = spring.offset(from: mid, to: 640, at: spring.settlingDuration)
        guard interrupted == 640 else {
            throw HarnessError.assertion("an interrupted spring must terminate on the newer target, got \(interrupted)")
        }

        // Reduce Motion, and an unanimated request, bypass the spring entirely.
        guard RemoteScrollSpringPolicy.shouldSpring(requested: true, reduceMotion: false),
              !RemoteScrollSpringPolicy.shouldSpring(requested: true, reduceMotion: true),
              !RemoteScrollSpringPolicy.shouldSpring(requested: false, reduceMotion: false) else {
            throw HarnessError.assertion("spring gating should honour Reduce Motion and unanimated requests")
        }

        // The spring is not gated on the operating system, unlike the native
        // programmatic path, which stays disabled on macOS 12.
        guard !RemoteProgrammaticScrollPolicy.allowsAnimatedScroll(
            on: OperatingSystemVersion(majorVersion: 12, minorVersion: 6, patchVersion: 0)
        ) else {
            throw HarnessError.assertion("native programmatic scroll animation must stay disabled on macOS 12")
        }

        try verifyScrollSpringDriver()
    }

    /// The driver that interpolates a clamped target. Proves terminal offsets are
    /// byte-exact, that a newer target collapses the run in flight instead of
    /// queueing behind it, and that Reduce Motion bypasses motion entirely.
    private static func verifyScrollSpringDriver() throws {
        let spring = MarqueeTheme.focusScrollSpring
        let settle = spring.settlingDuration

        // Reduce Motion places instantly and never starts a run.
        var reduced = RemoteScrollSpringDriver()
        guard reduced.request(
            target: 1400, from: 0, at: 0, animated: true, reduceMotion: true
        ) == .settle(1400), !reduced.isAnimating, reduced.tick(at: 0.1) == nil else {
            throw HarnessError.assertion("Reduce Motion must place instantly without starting a spring run")
        }

        // An unanimated request behaves the same way.
        var instant = RemoteScrollSpringDriver()
        guard instant.request(
            target: 640, from: 0, at: 0, animated: false, reduceMotion: false
        ) == .settle(640), !instant.isAnimating else {
            throw HarnessError.assertion("an unanimated request must place instantly")
        }

        // A zero-distance request settles rather than animating in place.
        var stationary = RemoteScrollSpringDriver()
        guard stationary.request(
            target: 390, from: 390, at: 0, animated: true, reduceMotion: false
        ) == .settle(390), !stationary.isAnimating else {
            throw HarnessError.assertion("a zero-distance request must settle instead of animating")
        }

        // A real run animates, stays strictly inside the interval, and terminates
        // on the exact target.
        var driver = RemoteScrollSpringDriver()
        guard driver.request(
            target: 1400, from: 0, at: 0, animated: true, reduceMotion: false
        ) == .animating, driver.isAnimating, driver.activeTarget == 1400 else {
            throw HarnessError.assertion("an animated request over a real distance must start a run")
        }
        guard let midTick = driver.tick(at: spring.response * 0.25),
              midTick.offset > 0, midTick.offset < 1400, !midTick.isFinished else {
            throw HarnessError.assertion("mid-flight tick should be strictly inside the interval")
        }
        guard let endTick = driver.tick(at: settle),
              endTick.offset == 1400, endTick.isFinished else {
            throw HarnessError.assertion("the final tick must report the exact target, got \(String(describing: driver.tick(at: settle)))")
        }
        guard !driver.isAnimating, driver.tick(at: settle + 1) == nil else {
            throw HarnessError.assertion("a finished run must not keep ticking")
        }

        // Repeating the in-flight target does not restart the run.
        var repeated = RemoteScrollSpringDriver()
        _ = repeated.request(target: 800, from: 0, at: 0, animated: true, reduceMotion: false)
        let generationBefore = repeated.generation
        guard repeated.request(
            target: 800, from: 120, at: 0.05, animated: true, reduceMotion: false
        ) == .unchanged, repeated.generation == generationBefore else {
            throw HarnessError.assertion("repeating the active target must not restart the run")
        }

        // Interruption collapse: a newer target takes over immediately from the
        // offset reached so far, advances the generation so stale ticks are
        // ignored, and still terminates exactly on the newer target.
        var collapsing = RemoteScrollSpringDriver()
        _ = collapsing.request(target: 1400, from: 0, at: 0, animated: true, reduceMotion: false)
        guard let inFlight = collapsing.tick(at: spring.response * 0.3) else {
            throw HarnessError.assertion("expected an in-flight tick before interrupting")
        }
        let staleGeneration = collapsing.generation
        guard collapsing.request(
            target: 640,
            from: inFlight.offset,
            at: spring.response * 0.3,
            animated: true,
            reduceMotion: false
        ) == .animating, collapsing.generation != staleGeneration,
              collapsing.activeTarget == 640 else {
            throw HarnessError.assertion("a newer target must collapse the in-flight run and advance the generation")
        }
        guard let collapsedEnd = collapsing.tick(at: spring.response * 0.3 + settle),
              collapsedEnd.offset == 640, collapsedEnd.isFinished else {
            throw HarnessError.assertion("an interrupted run must terminate on the newer target exactly")
        }

        // Reduce Motion mid-flight collapses to instant placement.
        var interruptedByReduceMotion = RemoteScrollSpringDriver()
        _ = interruptedByReduceMotion.request(
            target: 1400, from: 0, at: 0, animated: true, reduceMotion: false
        )
        guard interruptedByReduceMotion.request(
            target: 900, from: 300, at: 0.05, animated: true, reduceMotion: true
        ) == .settle(900), !interruptedByReduceMotion.isAnimating else {
            throw HarnessError.assertion("Reduce Motion arriving mid-flight must collapse to instant placement")
        }

        // Cancelling stops the run and advances the generation.
        var cancelled = RemoteScrollSpringDriver()
        _ = cancelled.request(target: 500, from: 0, at: 0, animated: true, reduceMotion: false)
        let beforeCancel = cancelled.generation
        cancelled.cancel()
        guard !cancelled.isAnimating, cancelled.generation != beforeCancel,
              cancelled.tick(at: 0.1) == nil else {
            throw HarnessError.assertion("cancelling must stop the run and advance the generation")
        }

        // Axis selection touches only its own component.
        guard RemoteScrollSpringAxis.vertical.point(390, in: CGPoint(x: 166, y: 0)) == CGPoint(x: 166, y: 390),
              RemoteScrollSpringAxis.horizontal.point(166, in: CGPoint(x: 0, y: 390)) == CGPoint(x: 166, y: 390),
              RemoteScrollSpringAxis.vertical.offset(of: CGPoint(x: 166, y: 390)) == 390,
              RemoteScrollSpringAxis.horizontal.offset(of: CGPoint(x: 166, y: 390)) == 166 else {
            throw HarnessError.assertion("spring axis selection should move only its own component")
        }
    }

    private static func verifyScrollAnimationCoalescer() throws {
        var coalescer = RemoteScrollAnimationCoalescer<CGFloat>()
        guard let first = coalescer.request(100),
              first.target == 100,
              coalescer.activeTarget == 100,
              coalescer.pendingTarget == nil else {
            throw HarnessError.assertion("first coalesced scroll request did not start")
        }

        guard coalescer.request(200) == nil,
              coalescer.activeTarget == 100,
              coalescer.pendingTarget == 200 else {
            throw HarnessError.assertion("in-flight request retargeted active motion instead of replacing one pending target")
        }
        guard coalescer.request(300) == nil,
              coalescer.activeTarget == 100,
              coalescer.pendingTarget == 300 else {
            throw HarnessError.assertion("latest in-flight request did not replace the pending target")
        }
        guard coalescer.request(300) == nil,
              coalescer.pendingTarget == 300 else {
            throw HarnessError.assertion("duplicate pending target did not collapse")
        }
        guard coalescer.request(100) == nil,
              coalescer.activeTarget == 100,
              coalescer.pendingTarget == nil else {
            throw HarnessError.assertion("repeat of the active target did not collapse obsolete pending motion")
        }
        guard coalescer.request(300) == nil,
              coalescer.pendingTarget == 300 else {
            throw HarnessError.assertion("latest target did not repopulate the single pending slot")
        }

        let staleGeneration = first.generation - 1
        guard coalescer.complete(generation: staleGeneration) == nil,
              coalescer.activeTarget == 100,
              coalescer.pendingTarget == 300 else {
            throw HarnessError.assertion("stale completion mutated the active coalescer generation")
        }
        guard let followUp = coalescer.complete(generation: first.generation),
              followUp.target == 300,
              coalescer.activeTarget == 300,
              coalescer.pendingTarget == nil else {
            throw HarnessError.assertion("active completion did not start only the latest pending target")
        }

        let beforeCancel = coalescer.generation
        coalescer.cancelAndAdvanceGeneration()
        guard coalescer.generation > beforeCancel,
              coalescer.activeTarget == nil,
              coalescer.pendingTarget == nil,
              coalescer.complete(generation: followUp.generation) == nil else {
            throw HarnessError.assertion("instant/detach cancellation did not invalidate active and pending motion")
        }
    }

    private static func verifyScrollMotionProductionPath() throws {
        guard Thread.isMainThread else {
            throw HarnessError.assertion("AppKit scroll-motion verification must run on the main thread")
        }

        let ventura = OperatingSystemVersion(majorVersion: 13, minorVersion: 0, patchVersion: 0)
        var windows: [NSWindow] = []

        func makeScrollView() -> NSScrollView {
            let frame = NSRect(x: 0, y: 0, width: 320, height: 240)
            let scrollView = NSScrollView(frame: frame)
            scrollView.contentView.wantsLayer = true
            scrollView.contentView.postsBoundsChangedNotifications = true
            let documentView = NSView(frame: NSRect(x: 0, y: 0, width: 2_000, height: 2_000))
            documentView.wantsLayer = true
            scrollView.documentView = documentView

            let window = NSWindow(
                contentRect: frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.contentView = scrollView
            window.contentView?.layoutSubtreeIfNeeded()
            windows.append(window)
            return scrollView
        }

        func requestVertical(_ scrollView: NSScrollView, _ target: CGFloat) -> Bool {
            RemoteAppKitScrollMotion.scroll(
                scrollView,
                to: target,
                animated: true,
                reduceMotion: false,
                operatingSystemVersion: ventura
            )
        }

        func requestHorizontal(_ scrollView: NSScrollView, _ target: CGFloat) -> Bool {
            RemoteAppKitScrollMotion.scrollHorizontally(
                scrollView,
                to: target,
                animated: true,
                reduceMotion: false,
                operatingSystemVersion: ventura
            )
        }

        func expectClose(_ actual: CGFloat, _ expected: CGFloat, _ context: String) throws {
            guard abs(actual - expected) < 0.5 else {
                throw HarnessError.assertion("\(context): expected \(expected), got \(actual)")
            }
        }

        func expectSnapshot(
            _ scrollView: NSScrollView,
            active: NSPoint,
            pending: NSPoint?,
            _ context: String
        ) throws {
            guard let snapshot = RemoteAppKitScrollMotion.animationSnapshot(for: scrollView),
                  snapshot.activeTarget == active,
                  snapshot.pendingTarget == pending else {
                throw HarnessError.assertion(
                    "\(context): expected active=\(active) pending=\(String(describing: pending)), got \(String(describing: RemoteAppKitScrollMotion.animationSnapshot(for: scrollView)))"
                )
            }
        }

        defer {
            windows.forEach { window in
                if let scrollView = window.contentView as? NSScrollView {
                    RemoteAppKitScrollMotion.detach(scrollView)
                }
                window.contentView = nil
                window.close()
            }
        }

        let repeatedTargetScrollView = makeScrollView()
        guard requestVertical(repeatedTargetScrollView, 240) else {
            throw HarnessError.assertion("production vertical coalescing did not start its first animation")
        }
        let verticalActiveTarget = NSPoint(x: 0, y: 240)
        let verticalPendingTarget = NSPoint(x: 0, y: 720)
        try expectSnapshot(
            repeatedTargetScrollView,
            active: verticalActiveTarget,
            pending: nil,
            "initial vertical animation state"
        )
        // `animator()` model-bound updates differ across supported AppKit
        // releases. Put the clip view in the already-at-active-target state
        // explicitly so this fixture deterministically exercises that branch.
        repeatedTargetScrollView.contentView.setBoundsOrigin(verticalActiveTarget)
        guard requestVertical(repeatedTargetScrollView, 720) else {
            throw HarnessError.assertion("production vertical coalescing rejected a valid pending target")
        }
        try expectSnapshot(
            repeatedTargetScrollView,
            active: verticalActiveTarget,
            pending: verticalPendingTarget,
            "pending vertical animation state"
        )
        guard requestVertical(repeatedTargetScrollView, 240) else {
            throw HarnessError.assertion("production vertical coalescing rejected its repeated active target")
        }
        try expectSnapshot(
            repeatedTargetScrollView,
            active: verticalActiveTarget,
            pending: nil,
            "repeated active vertical target did not clear obsolete pending motion"
        )
        RemoteAppKitScrollMotion.detach(repeatedTargetScrollView)
        guard RemoteAppKitScrollMotion.animationSnapshot(for: repeatedTargetScrollView) == nil else {
            throw HarnessError.assertion("vertical animation state survived explicit detach")
        }

        let repeatedHorizontalScrollView = makeScrollView()
        guard requestHorizontal(repeatedHorizontalScrollView, 260) else {
            throw HarnessError.assertion("production horizontal coalescing did not start its first animation")
        }
        let horizontalActiveTarget = NSPoint(x: 260, y: 0)
        let horizontalPendingTarget = NSPoint(x: 780, y: 0)
        try expectSnapshot(
            repeatedHorizontalScrollView,
            active: horizontalActiveTarget,
            pending: nil,
            "initial horizontal animation state"
        )
        repeatedHorizontalScrollView.contentView.setBoundsOrigin(horizontalActiveTarget)
        guard requestHorizontal(repeatedHorizontalScrollView, 780) else {
            throw HarnessError.assertion("production horizontal coalescing rejected a valid pending target")
        }
        try expectSnapshot(
            repeatedHorizontalScrollView,
            active: horizontalActiveTarget,
            pending: horizontalPendingTarget,
            "pending horizontal animation state"
        )
        guard requestHorizontal(repeatedHorizontalScrollView, 260) else {
            throw HarnessError.assertion("production horizontal coalescing rejected its repeated active target")
        }
        try expectSnapshot(
            repeatedHorizontalScrollView,
            active: horizontalActiveTarget,
            pending: nil,
            "repeated active horizontal target did not clear obsolete pending motion"
        )
        RemoteAppKitScrollMotion.detach(repeatedHorizontalScrollView)
        guard RemoteAppKitScrollMotion.animationSnapshot(for: repeatedHorizontalScrollView) == nil else {
            throw HarnessError.assertion("horizontal animation state survived explicit detach")
        }

        let oldVerticalScrollView = makeScrollView()
        let newVerticalScrollView = makeScrollView()
        let verticalController = BrowseVerticalScrollController()
        verticalController.attach(oldVerticalScrollView)
        guard requestVertical(oldVerticalScrollView, 280),
              requestVertical(oldVerticalScrollView, 840) else {
            throw HarnessError.assertion("vertical reattachment fixture did not queue old-scroll-view motion")
        }
        try expectSnapshot(
            oldVerticalScrollView,
            active: NSPoint(x: 0, y: 280),
            pending: NSPoint(x: 0, y: 840),
            "vertical reattachment fixture"
        )
        verticalController.attach(newVerticalScrollView)
        guard RemoteAppKitScrollMotion.animationSnapshot(for: oldVerticalScrollView) == nil else {
            throw HarnessError.assertion("vertical reattachment left old animation state registered")
        }
        guard verticalController.scroll(to: 360, animated: false) else {
            throw HarnessError.assertion("vertical controller did not retain ownership of its replacement scroll view")
        }
        try expectClose(
            newVerticalScrollView.contentView.bounds.origin.y,
            360,
            "vertical replacement scroll view"
        )

        let oldDetailScrollView = makeScrollView()
        let newDetailScrollView = makeScrollView()
        let detailController = DetailScrollController()
        let detailSpy = DetailScrollSpy()
        detailSpy.onAttachScrollView = { scrollView in
            detailController.attach(scrollView)
        }
        detailSpy.onDetachScrollView = { scrollView in
            detailController.detach(scrollView)
        }
        guard let oldDetailDocumentView = oldDetailScrollView.documentView,
              let newDetailDocumentView = newDetailScrollView.documentView else {
            throw HarnessError.assertion("detail reattachment fixture requires document views")
        }
        oldDetailDocumentView.addSubview(detailSpy)
        guard requestVertical(oldDetailScrollView, 320),
              requestVertical(oldDetailScrollView, 880) else {
            throw HarnessError.assertion("detail observer fixture did not queue old-scroll-view motion")
        }
        try expectSnapshot(
            oldDetailScrollView,
            active: NSPoint(x: 0, y: 320),
            pending: NSPoint(x: 0, y: 880),
            "detail observer reattachment fixture"
        )
        newDetailDocumentView.addSubview(detailSpy)
        guard RemoteAppKitScrollMotion.animationSnapshot(for: oldDetailScrollView) == nil else {
            throw HarnessError.assertion("detail observer reattachment left old animation state registered")
        }
        guard detailController.scroll(to: 440, animated: false) else {
            throw HarnessError.assertion("detail controller did not retain ownership of its replacement scroll view")
        }
        try expectClose(
            newDetailScrollView.contentView.bounds.origin.y,
            440,
            "detail replacement scroll view"
        )
        detailSpy.dismantle()
        guard !detailController.scroll(to: 520, animated: false),
              RemoteAppKitScrollMotion.animationSnapshot(for: newDetailScrollView) == nil else {
            throw HarnessError.assertion("detail observer teardown retained scroll ownership or motion")
        }

        let oldHorizontalScrollView = makeScrollView()
        let newHorizontalScrollView = makeScrollView()
        let horizontalController = RemoteHorizontalScrollController()
        horizontalController.attach(oldHorizontalScrollView)
        guard requestHorizontal(oldHorizontalScrollView, 300),
              requestHorizontal(oldHorizontalScrollView, 900) else {
            throw HarnessError.assertion("horizontal reattachment fixture did not queue old-scroll-view motion")
        }
        try expectSnapshot(
            oldHorizontalScrollView,
            active: NSPoint(x: 300, y: 0),
            pending: NSPoint(x: 900, y: 0),
            "horizontal reattachment fixture"
        )
        horizontalController.attach(newHorizontalScrollView)
        guard RemoteAppKitScrollMotion.animationSnapshot(for: oldHorizontalScrollView) == nil else {
            throw HarnessError.assertion("horizontal reattachment left old animation state registered")
        }
        guard horizontalController.scroll(to: 420, animated: false) else {
            throw HarnessError.assertion("horizontal controller did not retain ownership of its replacement scroll view")
        }
        try expectClose(
            newHorizontalScrollView.contentView.bounds.origin.x,
            420,
            "horizontal replacement scroll view"
        )
    }

    private static func verifyHorizontalFocusScrollPolicy() throws {
        let itemExtent: CGFloat = 150
        let itemSpacing: CGFloat = 16
        let itemStride = itemExtent + itemSpacing
        let viewportExtents: [CGFloat] = [520, 800, 980, 1_280]
        let insetPairs: [(leading: CGFloat, trailing: CGFloat)] = [
            (24, 24),
            (36, 36),
            (52, 36),
            (52, 52),
            (72, 72),
            (76, 52),
            (100, 84),
            (148, 124),
        ]

        for viewportExtent in viewportExtents {
            for insets in insetPairs {
                let usableViewport = viewportExtent - insets.leading - insets.trailing
                let visibleSlotCount = max(1, Int(floor((usableViewport + itemSpacing) / itemStride)))
                let centerSlot = visibleSlotCount / 2

                for count in 1...30 {
                    let maximumStep = max(0, count - visibleSlotCount)
                    let maximumOffset = CGFloat(maximumStep) * itemStride
                    let offsets = try (0..<count).map { index -> CGFloat in
                        guard let offset = RemoteHorizontalFocusScrollPolicy.offset(
                            for: index,
                            count: count,
                            itemExtent: itemExtent,
                            itemSpacing: itemSpacing,
                            viewportExtent: viewportExtent,
                            leadingInset: insets.leading,
                            trailingInset: insets.trailing
                        ) else {
                            throw HarnessError.assertion("valid horizontal geometry returned nil for viewport=\(viewportExtent) insets=\(insets) index=\(index) count=\(count)")
                        }
                        let requestedStep = max(0, index - centerSlot + 1)
                        let expectedOffset = CGFloat(min(requestedStep, maximumStep)) * itemStride
                        guard abs(offset - expectedOffset) < 0.001 else {
                            throw HarnessError.assertion("viewport=\(viewportExtent) insets=\(insets) index=\(index) count=\(count) offset=\(offset) expected piecewise offset=\(expectedOffset)")
                        }
                        return offset
                    }

                    if count <= visibleSlotCount, offsets.contains(where: { abs($0) > 0.001 }) {
                        throw HarnessError.assertion("short row count=\(count) should stay flat for viewport=\(viewportExtent) insets=\(insets), got \(offsets)")
                    }
                    for pair in zip(offsets, offsets.dropFirst()) {
                        let delta = pair.1 - pair.0
                        guard abs(delta) < 0.001 || abs(delta - itemStride) < 0.001 else {
                            throw HarnessError.assertion("every horizontal transition must stay flat or move exactly one whole card, got delta=\(delta) offsets=\(offsets)")
                        }
                    }
                    for offset in offsets where abs(offset) > 0.001 {
                        guard abs(offset.truncatingRemainder(dividingBy: itemStride)) < 0.001 else {
                            throw HarnessError.assertion("every nonzero horizontal origin must be an exact whole-card stride, got \(offset) in \(offsets)")
                        }
                    }
                    guard abs((offsets.last ?? 0) - maximumOffset) < 0.001 else {
                        throw HarnessError.assertion("final focus must reach the trailing clamp \(maximumOffset), got \(offsets.last ?? -1)")
                    }

                    let reverseOffsets = try (0..<count).reversed().map { index -> CGFloat in
                        guard let offset = RemoteHorizontalFocusScrollPolicy.offset(
                            for: index,
                            count: count,
                            itemExtent: itemExtent,
                            itemSpacing: itemSpacing,
                            viewportExtent: viewportExtent,
                            leadingInset: insets.leading,
                            trailingInset: insets.trailing
                        ) else {
                            throw HarnessError.assertion("reverse traversal returned nil for index=\(index) count=\(count)")
                        }
                        return offset
                    }
                    guard Array(reverseOffsets.reversed()) == offsets else {
                        throw HarnessError.assertion("reverse traversal must reproduce exact forward offsets for count=\(count)")
                    }
                }
            }
        }

        guard RemoteHorizontalFocusScrollPolicy.offset(
            for: 2,
            count: 6,
            itemExtent: itemExtent,
            itemSpacing: itemSpacing,
            viewportExtent: 980,
            leadingInset: 24,
            trailingInset: 24
        ) == itemStride,
        RemoteHorizontalFocusScrollPolicy.requiredTrailingPadding(
            count: 6,
            itemExtent: itemExtent,
            itemSpacing: itemSpacing,
            viewportExtent: 980,
            leadingInset: 24,
            minimumTrailingInset: 24
        ) == 142 else {
            throw HarnessError.assertion("six-card 980-point regression must step to x=166 and reserve 142 trailing points instead of emitting fractional x=48")
        }

        guard RemoteHorizontalFocusScrollPolicy.offset(
            for: -1,
            count: 5,
            itemExtent: itemExtent,
            itemSpacing: itemSpacing,
            viewportExtent: 980,
            leadingInset: 24,
            trailingInset: 24
        ) == nil,
        RemoteHorizontalFocusScrollPolicy.offset(
            for: 5,
            count: 5,
            itemExtent: itemExtent,
            itemSpacing: itemSpacing,
            viewportExtent: 980,
            leadingInset: 24,
            trailingInset: 24
        ) == nil,
        RemoteHorizontalFocusScrollPolicy.offset(
            for: 0,
            count: 0,
            itemExtent: itemExtent,
            itemSpacing: itemSpacing,
            viewportExtent: 980,
            leadingInset: 24,
            trailingInset: 24
        ) == nil,
        RemoteHorizontalFocusScrollPolicy.offset(
            for: 0,
            count: 5,
            itemExtent: .nan,
            itemSpacing: itemSpacing,
            viewportExtent: 980,
            leadingInset: 24,
            trailingInset: 24
        ) == nil,
        RemoteHorizontalFocusScrollPolicy.offset(
            for: 0,
            count: 5,
            itemExtent: itemExtent,
            itemSpacing: itemSpacing,
            viewportExtent: 980,
            leadingInset: -1,
            trailingInset: 24
        ) == nil else {
            throw HarnessError.assertion("invalid horizontal focus geometry should not produce offsets")
        }
    }

    private static func verifyPlayerHUDFocusPolicy() throws {
        let filmCapabilities = PlayerHUDCapabilities(
            hasSubtitles: false,
            hasMultipleAudioTracks: false
        )
        let midSeasonCapabilities = PlayerHUDCapabilities(
            hasSubtitles: true,
            hasMultipleAudioTracks: true,
            hasNextEpisode: true
        )
        let finalEpisodeCapabilities = PlayerHUDCapabilities(
            hasSubtitles: true,
            hasMultipleAudioTracks: true
        )

        guard PlayerHUDFocusPolicy.transportControls(capabilities: filmCapabilities) == [
            .restart,
            .skipBack,
            .playPause,
            .skipForward,
            .speed,
            .fullscreen,
        ] else {
            throw HarnessError.assertion("Player HUD must omit unavailable subtitle and audio controls")
        }

        guard PlayerHUDFocusPolicy.transportControls(capabilities: midSeasonCapabilities).contains(.nextEpisode),
              !PlayerHUDFocusPolicy.transportControls(capabilities: filmCapabilities).contains(.nextEpisode),
              !PlayerHUDFocusPolicy.transportControls(capabilities: finalEpisodeCapabilities).contains(.nextEpisode) else {
            throw HarnessError.assertion("Player HUD must show Next Episode only when an episode follows")
        }

        guard [PlayerHUDControl.back, .canvas]
            + PlayerHUDFocusPolicy.transportControls(capabilities: midSeasonCapabilities)
            == PlayerHUDControl.allCases else {
            throw HarnessError.assertion("Player HUD focus inventory must contain Back, canvas, and every available transport control without a duplicate close control")
        }

        guard PlayerHUDFocusPolicy.transportControls(capabilities: finalEpisodeCapabilities) == [
            .restart,
            .skipBack,
            .playPause,
            .skipForward,
            .subtitles,
            .audioTrack,
            .speed,
            .fullscreen,
        ] else {
            throw HarnessError.assertion("Final episode HUD must remove Next Episode while retaining available controls")
        }

        let fixedSpeedCapabilities = PlayerHUDCapabilities(
            hasSubtitles: true,
            hasMultipleAudioTracks: true,
            canChangeSpeed: false
        )
        let fixedSpeedControls = PlayerHUDFocusPolicy.transportControls(capabilities: fixedSpeedCapabilities)
        guard !fixedSpeedControls.contains(.speed),
              fixedSpeedControls.last == .fullscreen else {
            throw HarnessError.assertion("Player HUD must omit the speed control on backends that cannot retime playback")
        }

        let recoveredState = PlayerHUDFocusPolicy.normalized(
            FocusEngineState(focused: PlayerHUDFocusIDs.speed),
            capabilities: fixedSpeedCapabilities
        )
        guard recoveredState.focused == PlayerHUDFocusPolicy.initialState.focused else {
            throw HarnessError.assertion("Player HUD focus must leave a hidden speed control for the canvas")
        }

        var state = PlayerHUDFocusPolicy.initialState
        state = PlayerHUDFocusPolicy.move(.up, state: state, capabilities: midSeasonCapabilities)
        guard state.focused == PlayerHUDFocusIDs.back else {
            throw HarnessError.assertion("Player canvas Up must focus the visible top Back control")
        }

        state = PlayerHUDFocusPolicy.move(.down, state: state, capabilities: midSeasonCapabilities)
        guard state.focused == PlayerHUDFocusIDs.canvas else {
            throw HarnessError.assertion("Player Back Down must return to the seek canvas")
        }

        state = PlayerHUDFocusPolicy.move(.down, state: state, capabilities: midSeasonCapabilities)
        guard state.focused == PlayerHUDFocusIDs.playPause else {
            throw HarnessError.assertion("Player canvas Down must enter transport at Play/Pause")
        }

        state = PlayerHUDFocusPolicy.move(.left, state: state, capabilities: midSeasonCapabilities)
        guard state.focused == PlayerHUDFocusIDs.skipBack else {
            throw HarnessError.assertion("Player transport Left must move to Skip Back")
        }

        state = PlayerHUDFocusPolicy.move(.left, state: state, capabilities: midSeasonCapabilities)
        guard state.focused == PlayerHUDFocusIDs.restart else {
            throw HarnessError.assertion("Player transport Left must reach Restart")
        }

        state = PlayerHUDFocusPolicy.move(.right, state: state, capabilities: midSeasonCapabilities)
        guard state.focused == PlayerHUDFocusIDs.skipBack else {
            throw HarnessError.assertion("Player transport Right must move to Skip Back")
        }

        state = PlayerHUDFocusPolicy.move(.right, state: state, capabilities: midSeasonCapabilities)
        guard state.focused == PlayerHUDFocusIDs.playPause else {
            throw HarnessError.assertion("Player transport Right must move to Play/Pause")
        }

        state = PlayerHUDFocusPolicy.move(.right, state: state, capabilities: midSeasonCapabilities)
        guard state.focused == PlayerHUDFocusIDs.skipForward else {
            throw HarnessError.assertion("Player transport Right must move to Skip Forward")
        }

        state = PlayerHUDFocusPolicy.move(.up, state: state, capabilities: midSeasonCapabilities)
        guard state.focused == PlayerHUDFocusIDs.canvas else {
            throw HarnessError.assertion("Every Player transport control must reach the seek canvas with one Up command")
        }

        state = PlayerHUDFocusPolicy.move(.up, state: state, capabilities: midSeasonCapabilities)
        guard state.focused == PlayerHUDFocusIDs.back else {
            throw HarnessError.assertion("Player canvas Up must reach Back")
        }

        state = PlayerHUDFocusPolicy.move(.down, state: state, capabilities: midSeasonCapabilities)
        guard state.focused == PlayerHUDFocusIDs.canvas else {
            throw HarnessError.assertion("Player Back Down must return through the seek canvas")
        }

        state = PlayerHUDFocusPolicy.move(.down, state: state, capabilities: midSeasonCapabilities)
        guard state.focused == PlayerHUDFocusIDs.skipForward else {
            throw HarnessError.assertion("Player canvas Down must restore the remembered transport control")
        }

        for control in PlayerHUDFocusPolicy.transportControls(capabilities: midSeasonCapabilities) {
            let transportState = FocusEngineState(focused: PlayerHUDFocusIDs.id(for: control))
            guard PlayerHUDFocusPolicy.move(
                .up,
                state: transportState,
                capabilities: midSeasonCapabilities
            ).focused == PlayerHUDFocusIDs.canvas else {
                throw HarnessError.assertion("Player transport control \(control) could not return to the seek canvas")
            }
        }

        let unavailableState = FocusEngineState(focused: PlayerHUDFocusIDs.audioTrack)
        guard PlayerHUDFocusPolicy.normalized(
            unavailableState,
            capabilities: filmCapabilities
        ).focused == PlayerHUDFocusIDs.canvas else {
            throw HarnessError.assertion("Player HUD must leave a transport control that becomes unavailable")
        }
    }

    private static func verifyFocusChromePolicy() throws {
        guard FocusChromeMetrics.posterFocusScale >= 1.03,
              FocusChromeMetrics.posterFocusScale <= 1.06 else {
            throw HarnessError.assertion("poster focus lift must stay in the Gate A 1.03-1.06 range")
        }

        let compactHalo = MarqueeTheme.focusChromeHaloPadding(isLeanBack: false)
        let leanBackHalo = MarqueeTheme.focusChromeHaloPadding(isLeanBack: true)
        let requiredHalo = FocusChromeMetrics.posterGlowRadius + FocusChromeMetrics.posterRingLineWidth + 4
        let compactBreathingRoom = MarqueeTheme.focusChromeLeadingEdgeBreathingRoom(isLeanBack: false)
        let leanBackBreathingRoom = MarqueeTheme.focusChromeLeadingEdgeBreathingRoom(isLeanBack: true)

        guard compactHalo >= requiredHalo else {
            throw HarnessError.assertion("compact row halo \(compactHalo) must reserve at least \(requiredHalo) points for the FocusChrome glow")
        }

        guard leanBackHalo > compactHalo else {
            throw HarnessError.assertion("lean-back row halo \(leanBackHalo) should expand beyond compact halo \(compactHalo)")
        }

        guard compactBreathingRoom >= MarqueeTheme.spacingMD,
              compactBreathingRoom.truncatingRemainder(dividingBy: MarqueeTheme.spacingSM) == 0,
              leanBackBreathingRoom >= compactBreathingRoom,
              leanBackBreathingRoom.truncatingRemainder(dividingBy: MarqueeTheme.spacingSM) == 0 else {
            throw HarnessError.assertion("focused leading-edge breathing room must add at least 16 points on the 8-point grid")
        }

        guard RemoteHorizontalFocusScrollPolicy.leadingContentPadding(
            mode: .detailRow,
            isLeanBack: false
        ) == compactHalo + compactBreathingRoom,
        RemoteHorizontalFocusScrollPolicy.leadingContentPadding(
            mode: .detailRow,
            isLeanBack: true
        ) == leanBackHalo + leanBackBreathingRoom else {
            throw HarnessError.assertion("detail More Like rows must reserve both FocusChrome halo and leading-edge breathing room")
        }

        guard FocusChromeMetrics.detailFocusScale == 1.0 else {
            throw HarnessError.assertion("detail text/control focus chrome should not lift detail subtrees on macOS 12")
        }

        guard PlayerHUDChromeMetrics.compactControlSize >= 44,
              PlayerHUDChromeMetrics.leanBackControlSize >= 64,
              PlayerHUDChromeMetrics.focusScale >= 1.065,
              PlayerHUDChromeMetrics.compactRingLineWidth >= 3,
              PlayerHUDChromeMetrics.leanBackRingLineWidth >= 4 else {
            throw HarnessError.assertion("Player HUD controls must preserve a ten-foot focus target and high-contrast ring")
        }
    }

    private static func verifyDetailPlacementPolicy() throws {
        let showHorizontal = DetailFocusTransition(
            from: DetailFocusIDs.showMoreLike(1),
            to: DetailFocusIDs.showMoreLike(2),
            direction: .right
        )
        guard DetailPlacementPolicy.command(for: showHorizontal) == .horizontalReveal(.relatedRow) else {
            throw HarnessError.assertion("horizontal Show More Like movement should reveal horizontally without vertical detail scroll")
        }
        guard DetailPlacementPolicy.command(for: showHorizontal)?.includesVerticalScroll == false else {
            throw HarnessError.assertion("horizontal Show More Like movement must not issue a vertical scroll request")
        }

        let movieHorizontal = DetailFocusTransition(
            from: DetailFocusIDs.movieMoreLike(1),
            to: DetailFocusIDs.movieMoreLike(2),
            direction: .right
        )
        guard DetailPlacementPolicy.command(for: movieHorizontal) == .horizontalReveal(.relatedRow) else {
            throw HarnessError.assertion("horizontal Movie More Like movement should reveal horizontally without vertical detail scroll")
        }

        let showVertical = DetailFocusTransition(
            from: DetailFocusIDs.showEpisode(3),
            to: DetailFocusIDs.showMoreLike(1),
            direction: .down
        )
        guard DetailPlacementPolicy.command(for: showVertical) == .verticalBand(.relatedRow) else {
            throw HarnessError.assertion("vertical entry into Show More Like should park the row in the detail band")
        }

        let synopsisTransition = DetailFocusTransition(
            from: DetailFocusIDs.movieStart,
            to: DetailFocusIDs.movieShowMore,
            direction: .down
        )
        guard DetailPlacementPolicy.command(for: synopsisTransition) == .verticalBand(.synopsis) else {
            throw HarnessError.assertion("movie synopsis focus should request one vertical detail-band placement")
        }

        let geometry = DetailPlacementGeometry(
            currentOffset: 120,
            targetViewportTop: 520,
            viewportHeight: 900
        )
        guard let targetOffset = DetailPlacementPolicy.correctionTargetOffset(
            for: .synopsis,
            geometry: geometry
        ) else {
            throw HarnessError.assertion("movie synopsis outside the detail band should produce a measured correction")
        }
        let resolvedTop = RemoteDetailFocusPlacement.resolvedViewportTop(
            currentOffset: geometry.currentOffset,
            targetOffset: targetOffset,
            focusViewportTop: geometry.targetViewportTop
        )
        guard RemoteDetailFocusPlacement.contains(resolvedTop, viewportHeight: geometry.viewportHeight) else {
            throw HarnessError.assertion("movie synopsis correction should resolve into the detail band, got \(resolvedTop)")
        }

        let alreadyPlaced = DetailPlacementGeometry(
            currentOffset: 120,
            targetViewportTop: RemoteDetailFocusPlacement.targetViewportTop(viewportHeight: 900),
            viewportHeight: 900
        )
        guard DetailPlacementPolicy.correctionTargetOffset(for: .synopsis, geometry: alreadyPlaced) == nil else {
            throw HarnessError.assertion("already band-placed detail focus should not schedule a corrective scroll")
        }
        guard DetailPlacementGeometry.sanitizedViewportTop(.infinity) == nil,
              DetailPlacementGeometry.sanitizedViewportHeight(0) == nil else {
            throw HarnessError.assertion("detail placement geometry must reject non-finite and zero-size layout measurements")
        }

        let pendingEpisodeCorrection = PendingDetailPlacementCorrection(
            serial: 11,
            target: .episode,
            focus: DetailFocusIDs.showEpisode(2),
            didCorrect: false
        )
        let staleEpisodeMeasurement = DetailPlacementMeasurement(
            focus: DetailFocusIDs.showEpisode(1),
            viewportTop: RemoteDetailFocusPlacement.targetViewportTop(viewportHeight: 900)
        )
        guard !pendingEpisodeCorrection.accepts(measurement: staleEpisodeMeasurement) else {
            throw HarnessError.assertion("pending episode placement must reject stale geometry from the previously focused episode")
        }
        let currentEpisodeMeasurement = DetailPlacementMeasurement(
            focus: DetailFocusIDs.showEpisode(2),
            viewportTop: RemoteDetailFocusPlacement.targetViewportTop(viewportHeight: 900)
        )
        guard pendingEpisodeCorrection.accepts(measurement: currentEpisodeMeasurement) else {
            throw HarnessError.assertion("pending episode placement must accept geometry from the newly focused episode")
        }
    }

    private static func verifyDetailEpisodeTraversalPolicy() throws {
        guard DetailEpisodeTraversalPolicy.entryIndex(direction: 1, episodeCount: 10) == 0 else {
            throw HarnessError.assertion("entering the episode list from above should focus the first episode")
        }
        guard DetailEpisodeTraversalPolicy.entryIndex(direction: -1, episodeCount: 10) == 9 else {
            throw HarnessError.assertion("entering the episode list from below should focus the last episode")
        }
        guard DetailEpisodeTraversalPolicy.entryIndex(direction: 1, episodeCount: 0) == nil else {
            throw HarnessError.assertion("empty episode lists should not produce a focus entry index")
        }
    }

    private static func verifyDetailEpisodeRowScrollLayout() throws {
        let viewportHeight: CGFloat = 900
        let desired = DetailEpisodeRowScrollLayout.desiredViewportTop(viewportHeight: viewportHeight)
        guard RemoteDetailFocusPlacement.contains(desired, viewportHeight: viewportHeight) else {
            throw HarnessError.assertion("focused episode row should land in the detail focus band, got \(desired)")
        }
        let relatedDesired = DetailRelatedRowLayout.desiredViewportTop(
            viewportHeight: viewportHeight,
            isLeanBack: false
        )
        guard RemoteDetailFocusPlacement.contains(relatedDesired, viewportHeight: viewportHeight) else {
            throw HarnessError.assertion("focused related row should land in the detail focus band, got \(relatedDesired)")
        }
        guard DetailEpisodeRowScrollLayout.isComfortablyPlaced(
            rowViewportTop: desired + 20,
            viewportHeight: viewportHeight
        ) else {
            throw HarnessError.assertion("episode row near the comfort target should not scroll")
        }
        guard !DetailEpisodeRowScrollLayout.isComfortablyPlaced(
            rowViewportTop: 90,
            viewportHeight: viewportHeight
        ) else {
            throw HarnessError.assertion("episode row pinned near the top should require correction")
        }
        guard !DetailEpisodeRowScrollLayout.isComfortablyPlaced(
            rowViewportTop: 820,
            viewportHeight: viewportHeight
        ) else {
            throw HarnessError.assertion("episode row below the reading band should require correction")
        }
        let movieSynopsisTarget = RemoteDetailFocusPlacement.targetOffset(
            currentOffset: 120,
            focusViewportTop: 520,
            viewportHeight: viewportHeight
        )
        let movieSynopsisViewportTop = RemoteDetailFocusPlacement.resolvedViewportTop(
            currentOffset: 120,
            targetOffset: movieSynopsisTarget,
            focusViewportTop: 520
        )
        guard RemoteDetailFocusPlacement.contains(movieSynopsisViewportTop, viewportHeight: viewportHeight) else {
            throw HarnessError.assertion("movie synopsis focus should resolve into the detail band, got \(movieSynopsisViewportTop)")
        }
        let nearTopTarget = RemoteDetailFocusPlacement.targetOffset(
            currentOffset: 20,
            focusViewportTop: 240,
            viewportHeight: viewportHeight
        )
        let nearTopViewportTop = RemoteDetailFocusPlacement.resolvedViewportTop(
            currentOffset: 20,
            targetOffset: nearTopTarget,
            focusViewportTop: 240
        )
        guard nearTopTarget == 0,
              RemoteDetailFocusPlacement.contains(nearTopViewportTop, viewportHeight: viewportHeight) else {
            throw HarnessError.assertion("near-top movie synopsis focus should clamp without overshooting, target=\(nearTopTarget) top=\(nearTopViewportTop)")
        }
    }

    private static func verifyBrowseRemoteCatcherPolicy() throws {
        guard BrowseRemoteCatcherPolicy.isActive(
            showProfilePicker: false,
            playerPresented: false,
            sidebarRemoteFocused: false,
            selectedItem: .home,
            searchHasDetail: false
        ) else {
            throw HarnessError.assertion("Home should mount the browse remote catcher")
        }
        guard BrowseRemoteCatcherPolicy.isActive(
            showProfilePicker: false,
            playerPresented: false,
            sidebarRemoteFocused: false,
            selectedItem: .search,
            searchHasDetail: true
        ) else {
            throw HarnessError.assertion("Search detail overlays should rejoin the browse remote command stream")
        }
        guard !BrowseRemoteCatcherPolicy.isActive(
            showProfilePicker: false,
            playerPresented: false,
            sidebarRemoteFocused: false,
            selectedItem: .search,
            searchHasDetail: false
        ) else {
            throw HarnessError.assertion("Search root should keep native search input ownership")
        }
        guard !BrowseRemoteCatcherPolicy.isActive(
            showProfilePicker: false,
            playerPresented: false,
            sidebarRemoteFocused: false,
            selectedItem: .settings,
            searchHasDetail: false
        ) else {
            throw HarnessError.assertion("Settings root should keep native control ownership")
        }
        guard BrowseRemoteCatcherPolicy.isActive(
            showProfilePicker: false,
            playerPresented: false,
            sidebarRemoteFocused: true,
            selectedItem: .settings,
            searchHasDetail: false
        ) else {
            throw HarnessError.assertion("Sidebar remote focus should reclaim the browse catcher even from Settings")
        }
        guard !BrowseRemoteCatcherPolicy.isActive(
            showProfilePicker: true,
            playerPresented: false,
            sidebarRemoteFocused: true,
            selectedItem: .home,
            searchHasDetail: false
        ),
        !BrowseRemoteCatcherPolicy.isActive(
            showProfilePicker: false,
            playerPresented: true,
            sidebarRemoteFocused: true,
            selectedItem: .home,
            searchHasDetail: false
        ) else {
            throw HarnessError.assertion("Profile picker and player surfaces should own their own remote catchers")
        }
        guard !BrowseRemoteCatcherPolicy.isActive(
            showProfilePicker: false,
            playerPresented: false,
            postPlayHandoffVisible: true,
            sidebarRemoteFocused: true,
            selectedItem: .home,
            searchHasDetail: false
        ),
        !BrowseRemoteCatcherPolicy.isActive(
            showProfilePicker: false,
            playerPresented: false,
            postPlayHandoffVisible: true,
            sidebarRemoteFocused: false,
            selectedItem: .search,
            searchHasDetail: false
        ) else {
            throw HarnessError.assertion("Post-play handoff should own remote input over browse, search, and sidebar catchers")
        }
    }

    private static func verifyRemoteOwnershipMatrix() throws {
        func legacyCatcherOracle(
            showProfilePicker: Bool,
            playerPresented: Bool,
            postPlayHandoffVisible: Bool,
            sidebarRemoteFocused: Bool,
            selectedItem: SidebarItem,
            searchHasDetail: Bool
        ) -> Bool {
            guard !showProfilePicker, !playerPresented, !postPlayHandoffVisible else {
                return false
            }
            if sidebarRemoteFocused {
                return true
            }
            switch selectedItem {
            case .home, .movies, .tvShows:
                return true
            case .search:
                return searchHasDetail
            case .settings:
                return false
            }
        }

        for showProfilePicker in [false, true] {
            for playerPresented in [false, true] {
                for postPlayHandoffVisible in [false, true] {
                    for sidebarRemoteFocused in [false, true] {
                        for selectedItem in SidebarItem.allCases {
                            for searchHasDetail in [false, true] {
                                let state = RemoteOwnershipState(
                                    showProfilePicker: showProfilePicker,
                                    playerPresented: playerPresented,
                                    postPlayHandoffVisible: postPlayHandoffVisible,
                                    sidebarRemoteFocused: sidebarRemoteFocused,
                                    selectedItem: selectedItem,
                                    searchHasDetail: searchHasDetail
                                )
                                let owner = RemoteOwnershipPolicy.owner(for: state)

                                let mounts = RemoteOwnershipPolicy.browseCatcherMounts(for: owner)
                                let oracle = legacyCatcherOracle(
                                    showProfilePicker: showProfilePicker,
                                    playerPresented: playerPresented,
                                    postPlayHandoffVisible: postPlayHandoffVisible,
                                    sidebarRemoteFocused: sidebarRemoteFocused,
                                    selectedItem: selectedItem,
                                    searchHasDetail: searchHasDetail
                                )
                                guard mounts == oracle else {
                                    throw HarnessError.assertion(
                                        "ownership catcher mount diverged from legacy truth table for \(state): owner=\(owner.rawValue) mounts=\(mounts) oracle=\(oracle)"
                                    )
                                }

                                if showProfilePicker {
                                    guard owner == .profilePicker else {
                                        throw HarnessError.assertion("profile picker must own input whenever presented, got \(owner.rawValue)")
                                    }
                                } else if playerPresented {
                                    guard owner == .player else {
                                        throw HarnessError.assertion("player must own input over route/sidebar states, got \(owner.rawValue)")
                                    }
                                } else if postPlayHandoffVisible {
                                    guard owner == .postPlayHandoff else {
                                        throw HarnessError.assertion("post-play handoff must own input over route/sidebar states, got \(owner.rawValue)")
                                    }
                                } else if sidebarRemoteFocused {
                                    guard owner == .sidebar else {
                                        throw HarnessError.assertion("sidebar focus must own input over route states, got \(owner.rawValue)")
                                    }
                                } else {
                                    let expected: RemoteInputOwner
                                    switch selectedItem {
                                    case .home, .movies, .tvShows:
                                        expected = .browse
                                    case .search:
                                        expected = searchHasDetail ? .searchDetail : .searchRoot
                                    case .settings:
                                        expected = .settings
                                    }
                                    guard owner == expected else {
                                        throw HarnessError.assertion("route \(selectedItem.rawValue) expected owner \(expected.rawValue), got \(owner.rawValue)")
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        let coordinator = FocusCoordinator()
        var publishCount = 0
        let cancellable = coordinator.objectWillChange.sink { _ in
            publishCount += 1
        }
        defer { cancellable.cancel() }

        let settingsState = RemoteOwnershipState(
            showProfilePicker: false,
            playerPresented: false,
            postPlayHandoffVisible: false,
            sidebarRemoteFocused: false,
            selectedItem: .settings,
            searchHasDetail: false
        )
        coordinator.update(with: settingsState)
        guard coordinator.owner == .settings, publishCount == 1 else {
            throw HarnessError.assertion("coordinator should publish exactly one transition to settings, got owner=\(coordinator.owner.rawValue) publishes=\(publishCount)")
        }
        coordinator.update(with: settingsState)
        guard publishCount == 1 else {
            throw HarnessError.assertion("coordinator must not republish an unchanged owner, publishes=\(publishCount)")
        }
    }

    private static func verifySearchInputOwnership() throws {
        for owner in RemoteInputOwner.allCases {
            let consumes = SearchInputOwnershipPolicy.consumesRemoteCommands(owner: owner)
            guard consumes == (owner == .searchRoot) else {
                throw HarnessError.assertion("search must consume remote commands only as searchRoot owner, diverged at \(owner.rawValue)")
            }
            let captures = SearchInputOwnershipPolicy.capturesPhysicalTyping(owner: owner)
            guard captures == (owner == .searchRoot || owner == .sidebar) else {
                throw HarnessError.assertion("search physical typing capture diverged at \(owner.rawValue)")
            }
        }

        for showProfilePicker in [false, true] {
            for playerPresented in [false, true] {
                for postPlayHandoffVisible in [false, true] {
                    for sidebarRemoteFocused in [false, true] {
                        for selectedItem in SidebarItem.allCases {
                            for searchHasDetail in [false, true] {
                                let state = RemoteOwnershipState(
                                    showProfilePicker: showProfilePicker,
                                    playerPresented: playerPresented,
                                    postPlayHandoffVisible: postPlayHandoffVisible,
                                    sidebarRemoteFocused: sidebarRemoteFocused,
                                    selectedItem: selectedItem,
                                    searchHasDetail: searchHasDetail
                                )
                                let owner = RemoteOwnershipPolicy.owner(for: state)
                                let expected = !showProfilePicker
                                    && !playerPresented
                                    && !postPlayHandoffVisible
                                    && !sidebarRemoteFocused
                                    && selectedItem == .search
                                    && !searchHasDetail
                                guard SearchInputOwnershipPolicy.consumesRemoteCommands(owner: owner) == expected else {
                                    throw HarnessError.assertion(
                                        "search command consumption diverged from search-root derivation for \(state): owner=\(owner.rawValue)"
                                    )
                                }
                                let expectedTyping = !showProfilePicker
                                    && !playerPresented
                                    && !postPlayHandoffVisible
                                    && (sidebarRemoteFocused || (selectedItem == .search && !searchHasDetail))
                                guard SearchInputOwnershipPolicy.capturesPhysicalTyping(owner: owner) == expectedTyping else {
                                    throw HarnessError.assertion(
                                        "search typing capture diverged from searchRoot/sidebar derivation for \(state): owner=\(owner.rawValue)"
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private static func verifyRemoteScrollSafety() throws {
        func expectClose(_ actual: CGFloat, _ expected: CGFloat, _ label: String) throws {
            guard abs(actual - expected) < 0.001 else {
                throw HarnessError.assertion("\(label): expected \(expected), got \(actual)")
            }
        }

        let homeRow = RemoteScrollPlacement.homeRow
        try expectClose(homeRow.desiredViewportTop(viewportHeight: 900), max(210, (900 * 0.36).rounded()), "homeRow desired top at 900")
        try expectClose(homeRow.desiredViewportTop(viewportHeight: 520), 210, "homeRow desired top floor at 520")
        guard let homeTolerance = homeRow.placementTolerance(viewportHeight: 900) else {
            throw HarnessError.assertion("homeRow should expose a symmetric placement tolerance")
        }
        try expectClose(homeTolerance, max(48, 900 * 0.11), "homeRow tolerance at 900")

        let episode = RemoteScrollPlacement.detailEpisode
        try expectClose(episode.desiredViewportTop(viewportHeight: 900), RemoteDetailFocusPlacement.targetViewportTop(viewportHeight: 900), "episode desired top at 900")
        try expectClose(episode.desiredViewportTop(viewportHeight: 520), RemoteDetailFocusPlacement.targetViewportTop(viewportHeight: 520), "episode desired top at 520")
        guard episode.placementTolerance(viewportHeight: 520) == nil else {
            throw HarnessError.assertion("episode comfort should use the explicit detail focus band instead of a symmetric tolerance")
        }
        guard episode.isComfortablyPlaced(rowViewportTop: 234, viewportHeight: 900),
              episode.isComfortablyPlaced(rowViewportTop: 324, viewportHeight: 900),
              !episode.isComfortablyPlaced(rowViewportTop: 233, viewportHeight: 900),
              !episode.isComfortablyPlaced(rowViewportTop: 325, viewportHeight: 900) else {
            throw HarnessError.assertion("episode comfort band must stay inside 26%-36% of the viewport")
        }

        let relatedCompact = RemoteScrollPlacement.detailRelatedRow(isLeanBack: false)
        let relatedLeanBack = RemoteScrollPlacement.detailRelatedRow(isLeanBack: true)
        try expectClose(relatedCompact.desiredViewportTop(viewportHeight: 900), RemoteDetailFocusPlacement.targetViewportTop(viewportHeight: 900), "related compact desired top at 900")
        try expectClose(relatedLeanBack.desiredViewportTop(viewportHeight: 900), RemoteDetailFocusPlacement.targetViewportTop(viewportHeight: 900), "related leanback desired top at 900")
        try expectClose(relatedCompact.desiredViewportTop(viewportHeight: 300), RemoteDetailFocusPlacement.targetViewportTop(viewportHeight: 300), "related compact desired top at 300")
        guard relatedCompact.placementTolerance(viewportHeight: 900) == nil,
              relatedLeanBack.placementTolerance(viewportHeight: 900) == nil else {
            throw HarnessError.assertion("related comfort should use the explicit detail focus band instead of a symmetric tolerance")
        }
        guard relatedCompact.isComfortablyPlaced(rowViewportTop: 234, viewportHeight: 900),
              relatedCompact.isComfortablyPlaced(rowViewportTop: 324, viewportHeight: 900),
              !relatedCompact.isComfortablyPlaced(rowViewportTop: 233, viewportHeight: 900),
              !relatedCompact.isComfortablyPlaced(rowViewportTop: 325, viewportHeight: 900) else {
            throw HarnessError.assertion("related comfort band must stay inside 26%-36% of the viewport")
        }

        try expectClose(
            RemoteScrollPlacement.targetOffset(currentOffset: 100, rowViewportTop: 700, desiredViewportTop: 324),
            476,
            "targetOffset basic"
        )
        try expectClose(
            RemoteScrollPlacement.targetOffset(currentOffset: 0, rowViewportTop: 100, desiredViewportTop: 324),
            0,
            "targetOffset clamps below zero"
        )
        try expectClose(RemoteScrollPlacement.heroTargetOffset(), 0, "hero target offset")

        guard homeRow.isComfortablyPlaced(rowViewportTop: 423, viewportHeight: 900),
              !homeRow.isComfortablyPlaced(rowViewportTop: 424, viewportHeight: 900) else {
            throw HarnessError.assertion("homeRow comfort tolerance boundary drifted from 324±99 at 900")
        }

        let degenerateInputs: [(CGFloat, CGFloat, CGFloat, String)] = [
            (.nan, 2000, 600, "nan proposed"),
            (.infinity, 2000, 600, "infinite proposed"),
            (-.infinity, 2000, 600, "negative infinite proposed"),
            (100, .nan, 600, "nan content height"),
            (100, -1, 600, "negative content height"),
            (100, 2000, .nan, "nan viewport height"),
            (100, 2000, 0, "zero viewport"),
            (100, 2000, -5, "negative viewport"),
        ]
        for (proposed, content, viewport, label) in degenerateInputs {
            guard RemoteScrollGeometry.safeOffset(proposed: proposed, contentHeight: content, viewportHeight: viewport) == nil else {
                throw HarnessError.assertion("safeOffset accepted degenerate geometry: \(label)")
            }
        }

        guard let clamped = RemoteScrollGeometry.safeOffset(proposed: 9_999, contentHeight: 2_000, viewportHeight: 600) else {
            throw HarnessError.assertion("safeOffset rejected a valid over-scroll clamp case")
        }
        try expectClose(clamped, 1_400, "safeOffset clamps to content max")
        guard let zeroClamped = RemoteScrollGeometry.safeOffset(proposed: -50, contentHeight: 2_000, viewportHeight: 600) else {
            throw HarnessError.assertion("safeOffset rejected a valid negative clamp case")
        }
        try expectClose(zeroClamped, 0, "safeOffset clamps negative to zero")
        guard let passthrough = RemoteScrollGeometry.safeOffset(proposed: 390, contentHeight: 2_000, viewportHeight: 600) else {
            throw HarnessError.assertion("safeOffset rejected a valid in-range offset")
        }
        try expectClose(passthrough, 390, "safeOffset passes through in-range offset")
        guard let shortContent = RemoteScrollGeometry.safeOffset(proposed: 100, contentHeight: 300, viewportHeight: 600) else {
            throw HarnessError.assertion("safeOffset rejected content shorter than viewport")
        }
        try expectClose(shortContent, 0, "safeOffset pins short content to zero")
    }

    private enum HarnessError: Error, CustomStringConvertible {
        case assertion(String)

        var description: String {
            switch self {
            case .assertion(let message):
                return message
            }
        }
    }
}
#endif

extension MarqueeKey {
    var remoteCommand: RemoteCommand? {
        switch self {
        case .up:
            return .up
        case .down:
            return .down
        case .left:
            return .left
        case .right:
            return .right
        case .select:
            return .select
        case .escape:
            return .back
        case .subtitles, .fullscreen, .mute, .speedDown, .speedUp:
            return nil
        }
    }
}

// MARK: - Remote Grid Focus

struct RemoteGridPosition: Equatable {
    var row: Int = 0
    var column: Int = 0
}

enum RemoteHomeFocus: Equatable {
    case playSomething
    case hero
    case row(RemoteGridPosition)
}

enum RemoteFocusScrollAnchor {
    static let hero = UnitPoint(x: 0.5, y: 0.30)
    static let row = UnitPoint(x: 0.5, y: 0.36)
    static let detail = UnitPoint(x: 0.5, y: 0.30)
    static let detailRow = UnitPoint(x: 0.5, y: 0.30)
    static let detailTop = UnitPoint(x: 0.5, y: 0)
}

enum BrowseRemoteCatcherPolicy {
    static func isActive(
        showProfilePicker: Bool,
        playerPresented: Bool,
        postPlayHandoffVisible: Bool = false,
        sidebarRemoteFocused: Bool,
        selectedItem: SidebarItem,
        searchHasDetail: Bool
    ) -> Bool {
        let owner = RemoteOwnershipPolicy.owner(
            for: RemoteOwnershipState(
                showProfilePicker: showProfilePicker,
                playerPresented: playerPresented,
                postPlayHandoffVisible: postPlayHandoffVisible,
                sidebarRemoteFocused: sidebarRemoteFocused,
                selectedItem: selectedItem,
                searchHasDetail: searchHasDetail
            )
        )
        return RemoteOwnershipPolicy.browseCatcherMounts(for: owner)
    }
}

struct SidebarRemoteRootState: Equatable, CustomStringConvertible {
    let selectedItem: SidebarItem
    let focusedSidebarItem: SidebarItem
    let sidebarRemoteFocused: Bool
    let sidebarFocusOnPlaySomething: Bool
    let sidebarFocusOnProfile: Bool

    var description: String {
        "selected=\(selectedItem.rawValue) focused=\(focusedSidebarItem.rawValue) remoteFocused=\(sidebarRemoteFocused) playSomethingFocused=\(sidebarFocusOnPlaySomething) profileFocused=\(sidebarFocusOnProfile)"
    }
}

enum SidebarProfilePresentationPolicy {
    static let normalizedState = SidebarRemoteRootState(
        selectedItem: .home,
        focusedSidebarItem: .home,
        sidebarRemoteFocused: false,
        sidebarFocusOnPlaySomething: false,
        sidebarFocusOnProfile: false
    )
}

enum RemoteHorizontalFocusScrollPolicy {
    enum Mode {
        case standard
        case detailRow
    }

    static func leadingContentPadding(mode: Mode, isLeanBack: Bool) -> CGFloat {
        let haloPadding = MarqueeTheme.focusChromeHaloPadding(isLeanBack: isLeanBack)
        switch mode {
        case .standard:
            return haloPadding
        case .detailRow:
            return haloPadding + MarqueeTheme.focusChromeLeadingEdgeBreathingRoom(isLeanBack: isLeanBack)
        }
    }

    static func offset(
        for index: Int,
        count: Int,
        itemExtent: CGFloat,
        itemSpacing: CGFloat,
        viewportExtent: CGFloat,
        leadingInset: CGFloat,
        trailingInset: CGFloat
    ) -> CGFloat? {
        guard count > 0,
              (0..<count).contains(index),
              itemExtent.isFinite,
              itemSpacing.isFinite,
              viewportExtent.isFinite,
              leadingInset.isFinite,
              trailingInset.isFinite,
              itemExtent > 0,
              itemSpacing >= 0,
              viewportExtent > 0,
              leadingInset >= 0,
              trailingInset >= 0 else {
            return nil
        }

        let itemStride = itemExtent + itemSpacing
        guard itemStride.isFinite,
              itemStride > 0,
              let visibleSlotCount = visibleSlotCount(
                itemExtent: itemExtent,
                itemSpacing: itemSpacing,
                viewportExtent: viewportExtent,
                leadingInset: leadingInset,
                trailingInset: trailingInset
              ) else {
            return nil
        }

        let centerSlot = visibleSlotCount / 2
        let requestedStep = max(0, index - centerSlot + 1)
        let maximumStep = max(0, count - visibleSlotCount)
        return CGFloat(min(requestedStep, maximumStep)) * itemStride
    }

    static func requiredTrailingPadding(
        count: Int,
        itemExtent: CGFloat,
        itemSpacing: CGFloat,
        viewportExtent: CGFloat,
        leadingInset: CGFloat,
        minimumTrailingInset: CGFloat
    ) -> CGFloat? {
        guard count > 0,
              itemExtent.isFinite,
              itemSpacing.isFinite,
              viewportExtent.isFinite,
              leadingInset.isFinite,
              minimumTrailingInset.isFinite,
              itemExtent > 0,
              itemSpacing >= 0,
              viewportExtent > 0,
              leadingInset >= 0,
              minimumTrailingInset >= 0,
              let visibleSlotCount = visibleSlotCount(
                itemExtent: itemExtent,
                itemSpacing: itemSpacing,
                viewportExtent: viewportExtent,
                leadingInset: leadingInset,
                trailingInset: minimumTrailingInset
              ) else {
            return nil
        }

        let itemStride = itemExtent + itemSpacing
        let itemContentExtent = CGFloat(count) * itemExtent
            + CGFloat(max(0, count - 1)) * itemSpacing
        let maximumOffset = CGFloat(max(0, count - visibleSlotCount)) * itemStride
        let required = maximumOffset + viewportExtent - leadingInset - itemContentExtent
        guard itemStride.isFinite,
              itemContentExtent.isFinite,
              maximumOffset.isFinite,
              required.isFinite else {
            return nil
        }
        return max(minimumTrailingInset, required)
    }

    private static func visibleSlotCount(
        itemExtent: CGFloat,
        itemSpacing: CGFloat,
        viewportExtent: CGFloat,
        leadingInset: CGFloat,
        trailingInset: CGFloat
    ) -> Int? {
        let itemStride = itemExtent + itemSpacing
        guard itemStride.isFinite, itemStride > 0 else { return nil }
        let usableViewportExtent = max(0, viewportExtent - leadingInset - trailingInset)
        let rawVisibleSlotCount = (usableViewportExtent + itemSpacing) / itemStride
        guard rawVisibleSlotCount.isFinite,
              rawVisibleSlotCount <= CGFloat(Int.max) else {
            return nil
        }
        return max(1, Int(floor(rawVisibleSlotCount)))
    }
}

enum DetailEpisodeTraversalPolicy {
    static func entryIndex(direction: Int, episodeCount: Int) -> Int? {
        guard episodeCount > 0 else { return nil }
        return direction < 0 ? episodeCount - 1 : 0
    }
}

enum DetailEpisodeRowScrollLayout {
    static func desiredViewportTop(viewportHeight: CGFloat) -> CGFloat {
        RemoteScrollPlacement.detailEpisode.desiredViewportTop(viewportHeight: viewportHeight)
    }

    static func isComfortablyPlaced(
        rowViewportTop: CGFloat,
        viewportHeight: CGFloat
    ) -> Bool {
        RemoteScrollPlacement.detailEpisode.isComfortablyPlaced(
            rowViewportTop: rowViewportTop,
            viewportHeight: viewportHeight
        )
    }
}

struct DetailEpisodeRowViewportTopObserver: View {
    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: DetailEpisodeRowViewportTopPreferenceKey.self,
                value: proxy.frame(in: .named(DetailScrollCoordinateSpace.name)).minY
            )
        }
    }
}

struct DetailEpisodeRowViewportTopPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat? = nil

    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = nextValue() ?? value
    }
}

enum DetailRelatedRowLayout {
    static let scrollAnchorID = "detail-related-row-scroll-anchor"
    private static let compactTopClearance: CGFloat = 92
    private static let leanBackTopClearance: CGFloat = 132

    static func topClearance(isLeanBack: Bool) -> CGFloat {
        MarqueeTheme.scaled(compactTopClearance, leanBack: leanBackTopClearance, isLeanBack: isLeanBack)
    }

    static func desiredViewportTop(viewportHeight: CGFloat, isLeanBack: Bool) -> CGFloat {
        RemoteScrollPlacement.detailRelatedRow(isLeanBack: isLeanBack)
            .desiredViewportTop(viewportHeight: viewportHeight)
    }

    static func isComfortablyPlaced(rowViewportTop: CGFloat, viewportHeight: CGFloat, isLeanBack: Bool) -> Bool {
        RemoteScrollPlacement.detailRelatedRow(isLeanBack: isLeanBack).isComfortablyPlaced(
            rowViewportTop: rowViewportTop,
            viewportHeight: viewportHeight
        )
    }

}

enum DetailScrollCoordinateSpace {
    static let name = "detail-scroll"
}

struct DetailRelatedRowViewportTopObserver: View {
    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: DetailRelatedRowViewportTopPreferenceKey.self,
                value: proxy.frame(in: .named(DetailScrollCoordinateSpace.name)).minY
            )
        }
    }
}

struct DetailRelatedRowViewportTopPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat? = nil

    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = nextValue() ?? value
    }
}

struct DetailPersonRowViewportTopObserver: View {
    let rowID: String

    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: DetailPersonRowViewportTopPreferenceKey.self,
                value: [rowID: proxy.frame(in: .named(DetailScrollCoordinateSpace.name)).minY]
            )
        }
    }
}

struct DetailPersonRowViewportTopPreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]

    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct MovieSynopsisFocusViewportTopObserver: View {
    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: MovieSynopsisFocusViewportTopPreferenceKey.self,
                value: proxy.frame(in: .named(DetailScrollCoordinateSpace.name)).minY
            )
        }
    }
}

struct MovieSynopsisFocusViewportTopPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat? = nil

    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = nextValue() ?? value
    }
}

struct DetailScrollObserver: NSViewRepresentable {
    @Binding var offset: CGFloat
    let controller: DetailScrollController

    func makeNSView(context: Context) -> NSView {
        let view = DetailScrollSpy()
        view.onChange = { [self] value in
            self.offset = value
        }
        view.onAttachScrollView = { scrollView in
            controller.attach(scrollView)
        }
        view.onDetachScrollView = { scrollView in
            controller.detach(scrollView)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        (nsView as? DetailScrollSpy)?.dismantle()
    }
}

final class DetailScrollController: ObservableObject {
    private weak var scrollView: NSScrollView?

    var viewportHeight: CGFloat {
        guard let height = scrollView?.contentView.bounds.height,
              DetailPlacementGeometry.sanitizedViewportHeight(height) != nil else {
            return 900
        }
        return height
    }

    func attach(_ scrollView: NSScrollView) {
        guard self.scrollView !== scrollView else { return }
        if let previousScrollView = self.scrollView {
            RemoteAppKitScrollMotion.detach(previousScrollView)
        }
        self.scrollView = scrollView
    }

    func detach(_ scrollView: NSScrollView) {
        guard self.scrollView === scrollView else { return }
        RemoteAppKitScrollMotion.detach(scrollView)
        self.scrollView = nil
    }

    func scroll(to y: CGFloat, animated: Bool, reduceMotion: Bool = false) -> Bool {
        guard let scrollView else { return false }
        return RemoteAppKitScrollMotion.scroll(
            scrollView,
            to: y,
            animated: animated,
            reduceMotion: reduceMotion
        )
    }

    /// Same clamped detail-band target, reached with the spring instead of an
    /// instant jump. Reduce Motion and unanimated requests place instantly.
    @discardableResult
    func springScroll(to y: CGFloat, animated: Bool, reduceMotion: Bool = false) -> Bool {
        guard let scrollView else { return false }
        return RemoteAppKitScrollMotion.springScroll(
            scrollView,
            to: y,
            axis: .vertical,
            animated: animated,
            reduceMotion: reduceMotion
        )
    }

    deinit {
        if let scrollView {
            RemoteAppKitScrollMotion.detach(scrollView)
        }
    }
}

private final class DetailScrollSpy: NSView {
    var onChange: ((CGFloat) -> Void)?
    var onAttachScrollView: ((NSScrollView) -> Void)?
    var onDetachScrollView: ((NSScrollView) -> Void)?
    private static let attachRetryInterval: TimeInterval = 0.05
    private static let maxAttachAttempts = 40
    private weak var attachedScrollView: NSScrollView?
    private var attachmentGeneration = 0

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        reconcileContainingScrollView()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reconcileContainingScrollView()
    }

    override func removeFromSuperview() {
        attachmentGeneration += 1
        detachFromCurrentScrollView()
        super.removeFromSuperview()
    }

    func dismantle() {
        attachmentGeneration += 1
        detachFromCurrentScrollView()
        onChange = nil
        onAttachScrollView = nil
        onDetachScrollView = nil
    }

    private func reconcileContainingScrollView() {
        attachmentGeneration += 1
        let generation = attachmentGeneration
        guard window != nil else {
            detachFromCurrentScrollView()
            return
        }
        guard !attachToContainingScrollViewIfAvailable() else { return }
        detachFromCurrentScrollView()
        scheduleAttachmentRetry(generation: generation, attempt: 1)
    }

    private func scheduleAttachmentRetry(generation: Int, attempt: Int) {
        guard attempt <= Self.maxAttachAttempts else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.attachRetryInterval) { [weak self] in
            guard let self,
                  self.window != nil,
                  self.attachmentGeneration == generation else { return }
            if !self.attachToContainingScrollViewIfAvailable() {
                self.scheduleAttachmentRetry(generation: generation, attempt: attempt + 1)
            }
        }
    }

    @discardableResult
    private func attachToContainingScrollViewIfAvailable() -> Bool {
        var current: NSView? = superview
        while let view = current {
            if let scrollView = view as? NSScrollView {
                guard attachedScrollView !== scrollView else { return true }
                detachFromCurrentScrollView()
                attachedScrollView = scrollView
                onAttachScrollView?(scrollView)
                scrollView.contentView.postsBoundsChangedNotifications = true
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(boundsChanged),
                    name: NSView.boundsDidChangeNotification,
                    object: scrollView.contentView
                )
                return true
            }
            current = view.superview
        }
        return false
    }

    private func detachFromCurrentScrollView() {
        guard let attachedScrollView else { return }
        NotificationCenter.default.removeObserver(
            self,
            name: NSView.boundsDidChangeNotification,
            object: attachedScrollView.contentView
        )
        self.attachedScrollView = nil
        onDetachScrollView?(attachedScrollView)
    }

    @objc private func boundsChanged(_ notification: Notification) {
        guard let clipView = notification.object as? NSClipView,
              clipView === attachedScrollView?.contentView else { return }
        let y = max(0, clipView.bounds.origin.y)
        DispatchQueue.main.async { [weak self] in
            guard let self, clipView === self.attachedScrollView?.contentView else { return }
            self.onChange?(y)
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

enum DetailBackChromeLayout {
    static let compactLeadingPadding: CGFloat = 12
    static let leanBackLeadingPadding: CGFloat = 14
    static let compactButtonSize: CGFloat = 32
    static let leanBackButtonSize: CGFloat = 48

    static func leadingPadding(isLeanBack: Bool) -> CGFloat {
        MarqueeTheme.scaled(compactLeadingPadding, leanBack: leanBackLeadingPadding, isLeanBack: isLeanBack)
    }

    static func buttonSize(isLeanBack: Bool) -> CGFloat {
        MarqueeTheme.scaled(compactButtonSize, leanBack: leanBackButtonSize, isLeanBack: isLeanBack)
    }

    static func fitsBeforeContent(isLeanBack: Bool) -> Bool {
        leadingPadding(isLeanBack: isLeanBack) + buttonSize(isLeanBack: isLeanBack) <= MarqueeTheme.outerPadding(isLeanBack: isLeanBack)
    }
}

enum RemoteHomeRowScrollPlacement {
    static func desiredViewportTop(viewportHeight: CGFloat) -> CGFloat {
        RemoteScrollPlacement.homeRow.desiredViewportTop(viewportHeight: viewportHeight)
    }

    static func isComfortablyPlaced(
        rowViewportTop: CGFloat,
        viewportHeight: CGFloat
    ) -> Bool {
        RemoteScrollPlacement.homeRow.isComfortablyPlaced(
            rowViewportTop: rowViewportTop,
            viewportHeight: viewportHeight
        )
    }

    static func targetOffset(
        currentOffset: CGFloat,
        rowViewportTop: CGFloat,
        desiredViewportTop: CGFloat
    ) -> CGFloat {
        RemoteScrollPlacement.targetOffset(
            currentOffset: currentOffset,
            rowViewportTop: rowViewportTop,
            desiredViewportTop: desiredViewportTop
        )
    }
}

enum RemoteHomeHeroScrollPlacement {
    static func targetOffset(currentOffset _: CGFloat) -> CGFloat {
        RemoteScrollPlacement.heroTargetOffset()
    }
}

enum RemotePointerRegionPolicy {
    static func rowHoverControlsEnabled(isKeyboardFocusActive: Bool) -> Bool {
        !isKeyboardFocusActive
    }
}

final class RemoteScrollRequestGate {
    private var currentSerial = 0

    func issue() -> Int {
        currentSerial += 1
        return currentSerial
    }

    func accepts(_ serial: Int) -> Bool {
        serial == currentSerial
    }
}

enum RemoteProgrammaticScrollPolicy {
    static var allowsAnimatedScroll: Bool {
        allowsAnimatedScroll(on: ProcessInfo.processInfo.operatingSystemVersion)
    }

    static func allowsAnimatedScroll(on version: OperatingSystemVersion) -> Bool {
        version.majorVersion >= 13
    }

    static func perform(animated: Bool, reduceMotion: Bool = false, duration: Double = 0.25, _ action: @escaping () -> Void) {
        guard animated && !reduceMotion && allowsAnimatedScroll else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                action()
            }
            return
        }

        withAnimation(.easeInOut(duration: duration)) {
            action()
        }
    }
}

extension RemoteHomeFocus {
    var rowPosition: RemoteGridPosition? {
        guard case .row(let position) = self else { return nil }
        return position
    }

    static func wrappedHeroIndex(current: Int, delta: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let wrapped = (current + delta) % count
        return wrapped < 0 ? wrapped + count : wrapped
    }

    func sectionID(hasHero: Bool, rowID: (Int) -> String?) -> String? {
        switch self {
        case .playSomething:
            return nil
        case .hero where hasHero:
            return "hero-spotlight"
        case .hero, .row:
            break
        }
        guard let position = rowPosition else { return nil }
        return rowID(position.row)
    }
}

struct RemoteFocusCardModifier: ViewModifier {
    let isFocused: Bool

    func body(content: Content) -> some View {
        content
            .focusChrome(
                isFocused,
                cornerRadius: MarqueeTheme.cornerRadiusMD,
                accent: MarqueeTheme.accentPrimary,
                focusScale: FocusChromeMetrics.controlFocusScale,
                glowRadius: FocusChromeMetrics.detailGlowRadius,
                ringLineWidth: FocusChromeMetrics.detailRingLineWidth
            )
    }
}

extension View {
    func remoteFocused(_ isFocused: Bool) -> some View {
        modifier(RemoteFocusCardModifier(isFocused: isFocused))
    }
}
