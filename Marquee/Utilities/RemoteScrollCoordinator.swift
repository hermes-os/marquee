import AppKit
import CoreGraphics
import Foundation
import SwiftUI

enum BrowseReturnFocus: Equatable {
    case header
    case hero
    case row(String)

    static func home(_ focus: RemoteHomeFocus, rowID: String?) -> BrowseReturnFocus? {
        switch focus {
        case .playSomething:
            return .header
        case .hero:
            return .hero
        case .row:
            return rowID.map(BrowseReturnFocus.row)
        }
    }

    static func grid(rowID: String?) -> BrowseReturnFocus? {
        rowID.map(BrowseReturnFocus.row)
    }
}

enum BrowseReturnPlacementTarget: Equatable {
    case top
    case row(String)
}

enum BrowseReturnPlacementPolicy {
    static func target(for focus: BrowseReturnFocus?) -> BrowseReturnPlacementTarget? {
        switch focus {
        case .header, .hero:
            return .top
        case .row(let id):
            return .row(id)
        case nil:
            return nil
        }
    }
}

enum BrowseSurfaceRoute: Equatable {
    case home
    case movies
    case tvShows
}

struct BrowseSurfacePresentationState: Equatable {
    let route: BrowseSurfaceRoute
    let detailVisible: Bool
    let playerVisible: Bool
    let postPlayID: String?
}

enum BrowseSurfaceExitPolicy {
    static func shouldPlace(
        from previous: BrowseSurfacePresentationState,
        to current: BrowseSurfacePresentationState
    ) -> Bool {
        guard previous.route == current.route else { return false }
        return previous.hasPlacementBlocker && !current.hasPlacementBlocker
    }
}

private extension BrowseSurfacePresentationState {
    var hasPlacementBlocker: Bool {
        detailVisible || playerVisible || postPlayID != nil
    }
}

struct BrowseReturnGeometrySample {
    let target: BrowseReturnPlacementTarget
    let targetMinY: CGFloat
    let viewportHeight: CGFloat
    let currentOffset: CGFloat
    let contentHeight: CGFloat
    let attachmentEpoch: Int
    let focusGeneration: Int
}

#if DEBUG
struct BrowseReturnPlacementEvidence {
    let route: BrowseSurfaceRoute
    let target: BrowseReturnPlacementTarget
    let focusID: String
    let rowTitle: String?
    let rowViewportTop: CGFloat?
    let viewportHeight: CGFloat
    let currentOffset: CGFloat

    var isCorrectlyPlaced: Bool {
        switch target {
        case .top:
            return abs(currentOffset) < 0.5
        case .row:
            guard !focusID.isEmpty,
                  let rowTitle,
                  !rowTitle.isEmpty,
                  let rowViewportTop else {
                return false
            }
            return RemoteScrollPlacement.homeRow.isComfortablyPlaced(
                rowViewportTop: rowViewportTop,
                viewportHeight: viewportHeight
            )
        }
    }
}
#endif

struct PendingBrowseReturnPlacement {
    private enum PlacementPhase {
        case awaitingInitialPlacement
        case awaitingPlacementEcho
        case awaitingMeasuredCorrection
        case awaitingCorrectionEcho
    }

    private struct Request {
        let serial: Int
        let target: BrowseReturnPlacementTarget
        let focusGeneration: Int
        var attachmentEpoch: Int
        var phase: PlacementPhase
        var lastCommandedOffset: CGFloat?
    }

    private var serial = 0
    private var request: Request?

    mutating func issue(
        target: BrowseReturnPlacementTarget,
        focusGeneration: Int,
        attachmentEpoch: Int
    ) -> Int {
        serial += 1
        request = Request(
            serial: serial,
            target: target,
            focusGeneration: focusGeneration,
            attachmentEpoch: attachmentEpoch,
            phase: .awaitingInitialPlacement,
            lastCommandedOffset: nil
        )
        return serial
    }

    mutating func consume(sample: BrowseReturnGeometrySample, serial: Int) -> CGFloat? {
        guard var request,
              request.serial == serial,
              request.target == sample.target,
              request.focusGeneration == sample.focusGeneration,
              sample.attachmentEpoch >= request.attachmentEpoch else {
            return nil
        }

        if sample.attachmentEpoch > request.attachmentEpoch {
            request.attachmentEpoch = sample.attachmentEpoch
            request.phase = .awaitingInitialPlacement
            request.lastCommandedOffset = nil
        }

        let proposed: CGFloat
        switch sample.target {
        case .top:
            proposed = 0
        case .row:
            proposed = sample.targetMinY
                - RemoteScrollPlacement.homeRow.desiredViewportTop(viewportHeight: sample.viewportHeight)
        }
        guard let offset = RemoteScrollGeometry.safeOffset(
            proposed: proposed,
            contentHeight: sample.contentHeight,
            viewportHeight: sample.viewportHeight
        ) else {
            return nil
        }

        switch request.phase {
        case .awaitingInitialPlacement:
            request.phase = .awaitingPlacementEcho
            request.lastCommandedOffset = offset
            self.request = request
            return offset
        case .awaitingPlacementEcho:
            if let lastCommandedOffset = request.lastCommandedOffset,
               abs(lastCommandedOffset - sample.currentOffset) < 0.5,
               isComfortablyPlaced(sample) {
                request.phase = .awaitingMeasuredCorrection
                self.request = request
                return nil
            }
        case .awaitingMeasuredCorrection:
            break
        case .awaitingCorrectionEcho:
            self.request = nil
            return nil
        }

        guard !isComfortablyPlaced(sample) else {
            self.request = nil
            return nil
        }
        request.phase = .awaitingCorrectionEcho
        request.lastCommandedOffset = offset
        self.request = request
        return offset
    }

    func isActive(serial: Int) -> Bool {
        request?.serial == serial
    }

    func isAwaitingMeasuredCorrection(serial: Int) -> Bool {
        request?.serial == serial && request?.phase == .awaitingMeasuredCorrection
    }

    mutating func cancel(focusGeneration: Int) {
        guard let request, request.focusGeneration != focusGeneration else { return }
        self.request = nil
    }

    mutating func cancelIfTargetChanged(to target: BrowseReturnPlacementTarget?) {
        guard request?.target != target else { return }
        request = nil
    }

    private func isComfortablyPlaced(_ sample: BrowseReturnGeometrySample) -> Bool {
        switch sample.target {
        case .top:
            return abs(sample.currentOffset) < 0.5
        case .row:
            return RemoteScrollPlacement.homeRow.isComfortablyPlaced(
                rowViewportTop: sample.targetMinY - sample.currentOffset,
                viewportHeight: sample.viewportHeight
            )
        }
    }
}

// MARK: - Browse Return Placement Runtime

final class BrowseVerticalScrollController: ObservableObject {
    private weak var scrollView: NSScrollView?
    private var observers: [NSObjectProtocol] = []
    @Published private(set) var attachmentEpoch = 0
    @Published private(set) var geometryChangeSerial = 0

    var viewportHeight: CGFloat {
        scrollView?.contentView.bounds.height ?? 0
    }

    var contentHeight: CGFloat {
        scrollView?.documentView?.bounds.height ?? 0
    }

    var currentOffset: CGFloat {
        max(0, scrollView?.contentView.bounds.origin.y ?? 0)
    }

    func attach(_ scrollView: NSScrollView) {
        guard self.scrollView !== scrollView else { return }
        if let previousScrollView = self.scrollView {
            RemoteAppKitScrollMotion.detach(previousScrollView)
        }
        removeObservers()
        self.scrollView = scrollView
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.postsFrameChangedNotifications = true
        scrollView.documentView?.postsFrameChangedNotifications = true

        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSView.frameDidChangeNotification, object: scrollView, queue: .main) { [weak self] _ in
                self?.geometryChangeSerial += 1
            },
        ]
        if let documentView = scrollView.documentView {
            observers.append(
                center.addObserver(forName: NSView.frameDidChangeNotification, object: documentView, queue: .main) { [weak self] _ in
                    self?.geometryChangeSerial += 1
                }
            )
        }
        attachmentEpoch += 1
        geometryChangeSerial += 1
    }

    func detach(_ scrollView: NSScrollView) {
        guard self.scrollView === scrollView else { return }
        RemoteAppKitScrollMotion.detach(scrollView)
        removeObservers()
        self.scrollView = nil
        attachmentEpoch += 1
        geometryChangeSerial += 1
    }

    @discardableResult
    func scroll(to y: CGFloat, animated: Bool, reduceMotion: Bool = false) -> Bool {
        guard let scrollView else { return false }
        return RemoteAppKitScrollMotion.scroll(
            scrollView,
            to: y,
            animated: animated,
            reduceMotion: reduceMotion
        )
    }

    /// Same clamped target, reached with the `MarqueeTheme.focusScrollSpring`
    /// instead of an instant jump. Reduce Motion and unanimated requests place
    /// instantly, so this is a superset of `scroll(to:animated:reduceMotion:)`
    /// for surfaces that have adopted spring motion.
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

    private func removeObservers() {
        let center = NotificationCenter.default
        observers.forEach(center.removeObserver)
        observers.removeAll()
    }

    deinit {
        if let scrollView {
            RemoteAppKitScrollMotion.detach(scrollView)
        }
        removeObservers()
    }
}

struct BrowseVerticalScrollObserver: NSViewRepresentable {
    @Binding var offset: CGFloat
    let controller: BrowseVerticalScrollController

    func makeNSView(context: Context) -> NSView {
        let view = BrowseScrollSpy()
        view.onChange = { value in
            offset = value
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
}

enum BrowseRowViewportTopPreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]

    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

final class BrowseScrollSpy: NSView {
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
        guard let clipView = notification.object as? NSClipView else { return }
        let y = max(0, clipView.bounds.origin.y)
        DispatchQueue.main.async { [weak self] in
            self?.onChange?(y)
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

// MARK: - Scroll Geometry Safety

enum RemoteScrollGeometry {

    static func safeOffset(
        proposed: CGFloat,
        contentExtent: CGFloat,
        viewportExtent: CGFloat
    ) -> CGFloat? {
        guard proposed.isFinite,
              contentExtent.isFinite,
              contentExtent >= 0,
              viewportExtent.isFinite,
              viewportExtent > 0 else {
            return nil
        }
        let maxOffset = max(0, contentExtent - viewportExtent)
        return min(max(0, proposed), maxOffset)
    }

    static func safeOffset(
        proposed: CGFloat,
        contentHeight: CGFloat,
        viewportHeight: CGFloat
    ) -> CGFloat? {
        safeOffset(
            proposed: proposed,
            contentExtent: contentHeight,
            viewportExtent: viewportHeight
        )
    }
}

// MARK: - AppKit Scroll Motion

struct RemoteScrollAnimationStart<Target: Equatable>: Equatable {
    let target: Target
    let generation: Int
}

// MARK: - Spring Offset Animation

/// Unit-step response of a damped spring, used to interpolate a scroll offset
/// toward a target the placement authority has already computed and clamped.
/// The curve is a pure function of elapsed time so motion stays deterministic,
/// and it reports settled past `settlingDuration` so a run terminates on the
/// exact target offset rather than asymptotically near it.
struct RemoteScrollSpring: Equatable {
    /// Approximate time to first reach the target, in seconds.
    let response: Double
    /// 1.0 is critically damped; below that overshoots.
    let dampingFraction: Double

    private static let settledEnvelope = 0.001

    init(response: Double, dampingFraction: Double) {
        self.response = max(0.0001, response)
        self.dampingFraction = min(max(0.0001, dampingFraction), 1.0)
    }

    private var angularFrequency: Double {
        (2.0 * Double.pi) / response
    }

    /// Time after which the remaining displacement is below the settle epsilon,
    /// so the animator can finish exactly on target.
    var settlingDuration: TimeInterval {
        let decay = dampingFraction * angularFrequency
        return -log(Self.settledEnvelope) / decay
    }

    func isSettled(at elapsed: TimeInterval) -> Bool {
        elapsed >= settlingDuration
    }

    /// Fraction of the distance travelled at `elapsed`, exactly 0 at zero and
    /// exactly 1 once settled.
    func progress(at elapsed: TimeInterval) -> Double {
        guard elapsed > 0 else { return 0 }
        guard !isSettled(at: elapsed) else { return 1 }

        let omega = angularFrequency
        let zeta = dampingFraction
        let envelope = exp(-zeta * omega * elapsed)

        if zeta >= 1 {
            return 1 - envelope * (1 + omega * elapsed)
        }

        let damped = omega * (1 - zeta * zeta).squareRoot()
        let oscillation = cos(damped * elapsed)
            + (zeta * omega / damped) * sin(damped * elapsed)
        return 1 - envelope * oscillation
    }

    /// Offset between `start` and `target` at `elapsed`, terminating on exactly
    /// `target` so every placement validator still sees the clamped value.
    func offset(from start: CGFloat, to target: CGFloat, at elapsed: TimeInterval) -> CGFloat {
        guard !isSettled(at: elapsed) else { return target }
        return start + (target - start) * CGFloat(progress(at: elapsed))
    }
}

/// Reduce Motion and an unanimated request both bypass the spring entirely, so
/// placement stays instant and identical to today's behaviour. There is no
/// operating-system gate here: the animator drives offsets itself rather than
/// asking AppKit to animate, which is what keeps it macOS 12-safe.
enum RemoteScrollSpringPolicy {
    static func shouldSpring(requested: Bool, reduceMotion: Bool) -> Bool {
        requested && !reduceMotion
    }
}

/// Which axis of the document offset a spring run drives. The placement
/// authority already clamps per axis; this only selects which component moves.
enum RemoteScrollSpringAxis: Equatable {
    case vertical
    case horizontal

    func extent(of size: CGSize) -> CGFloat {
        switch self {
        case .vertical: return size.height
        case .horizontal: return size.width
        }
    }

    func offset(of point: CGPoint) -> CGFloat {
        switch self {
        case .vertical: return point.y
        case .horizontal: return point.x
        }
    }

    func point(_ offset: CGFloat, in origin: CGPoint) -> CGPoint {
        switch self {
        case .vertical: return CGPoint(x: origin.x, y: offset)
        case .horizontal: return CGPoint(x: offset, y: origin.y)
        }
    }
}

/// What a driver asks its owner to do with the document offset.
enum RemoteScrollSpringOutcome: Equatable {
    /// Place instantly on this offset. Reduce Motion, an unanimated request, and
    /// a zero-distance request all take this path, which is exactly today's
    /// behaviour.
    case settle(CGFloat)
    /// A run is in flight; tick the driver until it reports finished.
    case animating
    /// The request matched the in-flight target, so the run continues untouched.
    case unchanged
}

struct RemoteScrollSpringTick: Equatable {
    let offset: CGFloat
    let isFinished: Bool
}

/// Interpolates one axis of a scroll offset toward targets the placement
/// authority has already computed and clamped. A pure state machine: it holds no
/// timer and touches no AppKit, so its owner stays the single authority and the
/// contract is deterministic under test. A newer target collapses the in-flight
/// run, restarting from the offset reached so far rather than queueing behind it,
/// which is what keeps held direction keys responsive.
struct RemoteScrollSpringDriver {
    private struct Run: Equatable {
        let start: CGFloat
        let target: CGFloat
        let startedAt: TimeInterval
    }

    let spring: RemoteScrollSpring
    private var run: Run?
    private(set) var generation = 0

    init(spring: RemoteScrollSpring = MarqueeTheme.focusScrollSpring) {
        self.spring = spring
    }

    var isAnimating: Bool { run != nil }

    var activeTarget: CGFloat? { run?.target }

    /// Retarget from `current`. Bypasses entirely unless the request is animated
    /// and Reduce Motion is off.
    mutating func request(
        target: CGFloat,
        from current: CGFloat,
        at now: TimeInterval,
        animated: Bool,
        reduceMotion: Bool
    ) -> RemoteScrollSpringOutcome {
        guard RemoteScrollSpringPolicy.shouldSpring(
            requested: animated,
            reduceMotion: reduceMotion
        ) else {
            cancel()
            return .settle(target)
        }

        if let run, run.target == target {
            return .unchanged
        }

        guard target != current else {
            cancel()
            return .settle(target)
        }

        generation &+= 1
        run = Run(start: current, target: target, startedAt: now)
        return .animating
    }

    /// Advance the run. Returns nil when nothing is in flight. The final tick
    /// reports the target offset exactly, so placement validators still see the
    /// byte-exact clamped value.
    mutating func tick(at now: TimeInterval) -> RemoteScrollSpringTick? {
        guard let run else { return nil }
        let elapsed = max(0, now - run.startedAt)

        guard !spring.isSettled(at: elapsed) else {
            self.run = nil
            return RemoteScrollSpringTick(offset: run.target, isFinished: true)
        }

        return RemoteScrollSpringTick(
            offset: spring.offset(from: run.start, to: run.target, at: elapsed),
            isFinished: false
        )
    }

    mutating func cancel() {
        guard run != nil else { return }
        generation &+= 1
        run = nil
    }
}

struct RemoteScrollAnimationCoalescer<Target: Equatable> {
    private(set) var generation = 0
    private(set) var activeTarget: Target?
    private(set) var pendingTarget: Target?

    mutating func request(_ target: Target) -> RemoteScrollAnimationStart<Target>? {
        if activeTarget == nil {
            generation &+= 1
            activeTarget = target
            pendingTarget = nil
            return RemoteScrollAnimationStart(target: target, generation: generation)
        }
        if target == activeTarget {
            pendingTarget = nil
            return nil
        }
        guard target != pendingTarget else { return nil }
        pendingTarget = target
        return nil
    }

    mutating func complete(generation: Int) -> RemoteScrollAnimationStart<Target>? {
        guard self.generation == generation,
              activeTarget != nil else { return nil }
        activeTarget = nil
        guard let pendingTarget else { return nil }
        self.pendingTarget = nil
        self.generation &+= 1
        activeTarget = pendingTarget
        return RemoteScrollAnimationStart(
            target: pendingTarget,
            generation: self.generation
        )
    }

    mutating func cancelAndAdvanceGeneration() {
        generation &+= 1
        activeTarget = nil
        pendingTarget = nil
    }
}

#if DEBUG
struct RemoteScrollAnimationSnapshot: Equatable {
    let activeTarget: NSPoint?
    let pendingTarget: NSPoint?
}
#endif

enum RemoteAppKitScrollMotion {

    private final class ClipAnimationState {
        weak var scrollView: NSScrollView?
        var coalescer = RemoteScrollAnimationCoalescer<NSPoint>()

        init(scrollView: NSScrollView) {
            self.scrollView = scrollView
        }

        func invalidate() {
            coalescer.cancelAndAdvanceGeneration()
            scrollView = nil
        }
    }

    private static var animationStates: [ObjectIdentifier: ClipAnimationState] = [:]

    static func shouldAnimate(
        requested: Bool,
        reduceMotion: Bool,
        operatingSystemVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) -> Bool {
        requested
            && !reduceMotion
            && RemoteProgrammaticScrollPolicy.allowsAnimatedScroll(on: operatingSystemVersion)
    }

    @discardableResult
    static func scroll(
        _ scrollView: NSScrollView,
        to proposedY: CGFloat,
        animated: Bool,
        reduceMotion: Bool,
        operatingSystemVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) -> Bool {
        guard let documentView = scrollView.documentView else {
            return false
        }

        let clipView = scrollView.contentView
        guard let safeY = RemoteScrollGeometry.safeOffset(
            proposed: proposedY,
            contentHeight: documentView.bounds.height,
            viewportHeight: clipView.bounds.height
        ) else {
            return false
        }
        let target = NSPoint(x: clipView.bounds.origin.x, y: safeY)

        guard shouldAnimate(
            requested: animated,
            reduceMotion: reduceMotion,
            operatingSystemVersion: operatingSystemVersion
        ) else {
            cancelAnimation(for: scrollView)
            clipView.setBoundsOrigin(target)
            scrollView.reflectScrolledClipView(clipView)
            publishBoundsChange(for: clipView)
            return true
        }

        guard !consumeRequestAtCurrentModelTarget(target, for: scrollView) else {
            return true
        }
        let state = animationState(for: scrollView)
        if let start = state.coalescer.request(target) {
            startAnimation(start, state: state)
        }
        return true
    }

    @discardableResult
    static func scrollHorizontally(
        _ scrollView: NSScrollView,
        to proposedX: CGFloat,
        animated: Bool,
        reduceMotion: Bool,
        operatingSystemVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) -> Bool {
        guard let documentView = scrollView.documentView else {
            return false
        }

        let clipView = scrollView.contentView
        guard let safeX = RemoteScrollGeometry.safeOffset(
            proposed: proposedX,
            contentExtent: documentView.bounds.width,
            viewportExtent: clipView.bounds.width
        ) else {
            return false
        }
        let target = NSPoint(x: safeX, y: clipView.bounds.origin.y)

        guard shouldAnimate(
            requested: animated,
            reduceMotion: reduceMotion,
            operatingSystemVersion: operatingSystemVersion
        ) else {
            cancelAnimation(for: scrollView)
            clipView.setBoundsOrigin(target)
            scrollView.reflectScrolledClipView(clipView)
            publishBoundsChange(for: clipView)
            return true
        }

        guard !consumeRequestAtCurrentModelTarget(target, for: scrollView) else {
            return true
        }
        let state = animationState(for: scrollView)
        if let start = state.coalescer.request(target) {
            startAnimation(start, state: state)
        }
        return true
    }

    static func detach(_ scrollView: NSScrollView) {
        cancelAnimation(for: scrollView)
    }

    #if DEBUG
    static func animationSnapshot(for scrollView: NSScrollView) -> RemoteScrollAnimationSnapshot? {
        let key = ObjectIdentifier(scrollView.contentView)
        guard let state = animationStates[key], state.scrollView === scrollView else {
            return nil
        }
        return RemoteScrollAnimationSnapshot(
            activeTarget: state.coalescer.activeTarget,
            pendingTarget: state.coalescer.pendingTarget
        )
    }
    #endif

    private static func animationState(for scrollView: NSScrollView) -> ClipAnimationState {
        let key = ObjectIdentifier(scrollView.contentView)
        if let existing = animationStates[key], existing.scrollView === scrollView {
            return existing
        }
        let state = ClipAnimationState(scrollView: scrollView)
        animationStates[key] = state
        return state
    }

    private static func consumeRequestAtCurrentModelTarget(
        _ target: NSPoint,
        for scrollView: NSScrollView
    ) -> Bool {
        let clipView = scrollView.contentView
        guard target == clipView.bounds.origin else { return false }

        // AppKit updates model bounds as soon as an animation starts. Route a
        // repeated active target through the coalescer so it can discard an
        // obsolete pending target instead of treating the request as a no-op.
        let key = ObjectIdentifier(clipView)
        if let state = animationStates[key],
           state.scrollView === scrollView,
           state.coalescer.activeTarget != nil {
            _ = state.coalescer.request(target)
        }
        return true
    }

    private static func startAnimation(
        _ start: RemoteScrollAnimationStart<NSPoint>,
        state: ClipAnimationState
    ) {
        guard let scrollView = state.scrollView else { return }
        let clipView = scrollView.contentView
        NSAnimationContext.runAnimationGroup { context in
            context.duration = MarqueeTheme.focusScrollDuration
            context.timingFunction = MarqueeTheme.focusScrollTimingFunction
            clipView.animator().setBoundsOrigin(start.target)
        } completionHandler: {
            guard state.scrollView === scrollView else { return }
            scrollView.reflectScrolledClipView(clipView)
            publishBoundsChange(for: clipView)
            if let followUp = state.coalescer.complete(generation: start.generation) {
                startAnimation(followUp, state: state)
                return
            }
            let key = ObjectIdentifier(clipView)
            if let registered = animationStates[key], registered === state,
               state.coalescer.activeTarget == nil {
                animationStates.removeValue(forKey: key)
            }
        }
    }

    private static func cancelAnimation(for scrollView: NSScrollView) {
        cancelSpring(for: scrollView)
        let key = ObjectIdentifier(scrollView.contentView)
        guard let state = animationStates.removeValue(forKey: key) else { return }
        state.invalidate()
        scrollView.contentView.layer?.removeAllAnimations()
    }

    // MARK: - Spring Offset Motion

    private final class SpringState {
        weak var scrollView: NSScrollView?
        var driver = RemoteScrollSpringDriver()
        var timer: Timer?
        let axis: RemoteScrollSpringAxis

        init(scrollView: NSScrollView, axis: RemoteScrollSpringAxis) {
            self.scrollView = scrollView
            self.axis = axis
        }

        func invalidate() {
            timer?.invalidate()
            timer = nil
            driver.cancel()
            scrollView = nil
        }
    }

    private static var springStates: [ObjectIdentifier: SpringState] = [:]

    /// Interpolate the document offset toward a target the authority has already
    /// clamped, driving the clip view directly on the main thread so no native
    /// programmatic scroll animation is involved.
    @discardableResult
    static func springScroll(
        _ scrollView: NSScrollView,
        to proposedOffset: CGFloat,
        axis: RemoteScrollSpringAxis,
        animated: Bool,
        reduceMotion: Bool
    ) -> Bool {
        guard let documentView = scrollView.documentView else { return false }
        let clipView = scrollView.contentView
        guard let safeOffset = RemoteScrollGeometry.safeOffset(
            proposed: proposedOffset,
            contentExtent: axis.extent(of: documentView.bounds.size),
            viewportExtent: axis.extent(of: clipView.bounds.size)
        ) else {
            return false
        }

        let state = springState(for: scrollView, axis: axis)
        let current = axis.offset(of: clipView.bounds.origin)
        let outcome = state.driver.request(
            target: safeOffset,
            from: current,
            at: Date.timeIntervalSinceReferenceDate,
            animated: animated,
            reduceMotion: reduceMotion
        )

        switch outcome {
        case .unchanged:
            return true
        case .settle(let offset):
            state.timer?.invalidate()
            state.timer = nil
            apply(offset: offset, axis: axis, to: scrollView)
            releaseSpringStateIfIdle(state, key: ObjectIdentifier(clipView))
            return true
        case .animating:
            scheduleSpringTick(state)
            return true
        }
    }

    private static func springState(
        for scrollView: NSScrollView,
        axis: RemoteScrollSpringAxis
    ) -> SpringState {
        let key = ObjectIdentifier(scrollView.contentView)
        if let existing = springStates[key],
           existing.scrollView === scrollView,
           existing.axis == axis {
            return existing
        }
        springStates[key]?.invalidate()
        let state = SpringState(scrollView: scrollView, axis: axis)
        springStates[key] = state
        return state
    }

    private static func scheduleSpringTick(_ state: SpringState) {
        guard state.timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { timer in
            advanceSpring(state, timer: timer)
        }
        state.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private static func advanceSpring(
        _ state: SpringState,
        timer: Timer
    ) {
        guard let scrollView = state.scrollView else {
            timer.invalidate()
            state.timer = nil
            return
        }

        guard let tick = state.driver.tick(at: Date.timeIntervalSinceReferenceDate) else {
            timer.invalidate()
            state.timer = nil
            releaseSpringStateIfIdle(state, key: ObjectIdentifier(scrollView.contentView))
            return
        }

        apply(offset: tick.offset, axis: state.axis, to: scrollView)

        guard tick.isFinished else { return }
        timer.invalidate()
        state.timer = nil
        releaseSpringStateIfIdle(state, key: ObjectIdentifier(scrollView.contentView))
    }

    private static func apply(
        offset: CGFloat,
        axis: RemoteScrollSpringAxis,
        to scrollView: NSScrollView
    ) {
        let clipView = scrollView.contentView
        clipView.setBoundsOrigin(axis.point(offset, in: clipView.bounds.origin))
        scrollView.reflectScrolledClipView(clipView)
        publishBoundsChange(for: clipView)
    }

    private static func releaseSpringStateIfIdle(_ state: SpringState, key: ObjectIdentifier) {
        guard !state.driver.isAnimating, state.timer == nil else { return }
        guard let registered = springStates[key], registered === state else { return }
        springStates.removeValue(forKey: key)
    }

    private static func cancelSpring(for scrollView: NSScrollView) {
        let key = ObjectIdentifier(scrollView.contentView)
        guard let state = springStates.removeValue(forKey: key) else { return }
        state.invalidate()
    }

    private static func publishBoundsChange(for clipView: NSClipView) {
        guard clipView.postsBoundsChangedNotifications else { return }
        NotificationCenter.default.post(
            name: NSView.boundsDidChangeNotification,
            object: clipView
        )
    }
}

final class RemoteHorizontalScrollController: ObservableObject {
    private weak var scrollView: NSScrollView?
    private var viewportObservers: [NSObjectProtocol] = []
    @Published private(set) var attachmentSerial = 0
    @Published private(set) var viewportChangeSerial = 0
    @Published private(set) var contentChangeSerial = 0
    private var publishedViewportExtent: CGFloat = 0

    var viewportExtent: CGFloat {
        publishedViewportExtent
    }

    func attach(_ scrollView: NSScrollView) {
        guard self.scrollView !== scrollView else {
            publishViewportExtentIfChanged()
            return
        }
        if let previousScrollView = self.scrollView {
            RemoteAppKitScrollMotion.detach(previousScrollView)
        }
        removeViewportObservers()
        self.scrollView = scrollView
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.postsFrameChangedNotifications = true
        scrollView.documentView?.postsFrameChangedNotifications = true
        let center = NotificationCenter.default
        viewportObservers = [
            center.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                self?.publishViewportExtentIfChanged()
            },
            center.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: scrollView,
                queue: .main
            ) { [weak self] _ in
                self?.publishViewportExtentIfChanged()
            },
        ]
        if let documentView = scrollView.documentView {
            viewportObservers.append(
                center.addObserver(
                    forName: NSView.frameDidChangeNotification,
                    object: documentView,
                    queue: .main
                ) { [weak self] _ in
                    self?.contentChangeSerial += 1
                }
            )
        }
        attachmentSerial += 1
        contentChangeSerial += 1
        publishViewportExtentIfChanged(force: true)
    }

    func detach(_ scrollView: NSScrollView) {
        guard self.scrollView === scrollView else { return }
        RemoteAppKitScrollMotion.detach(scrollView)
        removeViewportObservers()
        self.scrollView = nil
        publishedViewportExtent = 0
        attachmentSerial += 1
        viewportChangeSerial += 1
        contentChangeSerial += 1
    }

    func scroll(
        to x: CGFloat,
        animated: Bool,
        reduceMotion: Bool = false
    ) -> Bool {
        guard let scrollView else { return false }
        return RemoteAppKitScrollMotion.scrollHorizontally(
            scrollView,
            to: x,
            animated: animated,
            reduceMotion: reduceMotion
        )
    }

    /// Same clamped whole-card offset, reached with the spring instead of an
    /// instant jump. Reduce Motion and unanimated requests place instantly.
    @discardableResult
    func springScroll(
        to x: CGFloat,
        animated: Bool,
        reduceMotion: Bool = false
    ) -> Bool {
        guard let scrollView else { return false }
        return RemoteAppKitScrollMotion.springScroll(
            scrollView,
            to: x,
            axis: .horizontal,
            animated: animated,
            reduceMotion: reduceMotion
        )
    }

    private func publishViewportExtentIfChanged(force: Bool = false) {
        guard let width = scrollView?.contentView.bounds.width,
              width.isFinite,
              width > 0 else {
            return
        }
        guard force || abs(width - publishedViewportExtent) >= 0.5 else { return }
        publishedViewportExtent = width
        viewportChangeSerial += 1
    }

    private func removeViewportObservers() {
        let center = NotificationCenter.default
        viewportObservers.forEach(center.removeObserver)
        viewportObservers.removeAll()
    }

    deinit {
        if let scrollView {
            RemoteAppKitScrollMotion.detach(scrollView)
        }
        removeViewportObservers()
    }
}

// MARK: - Unified Placement Policy

enum RemoteScrollPlacement {
    case homeRow
    case detailEpisode
    case detailRelatedRow(isLeanBack: Bool)

    func desiredViewportTop(viewportHeight: CGFloat) -> CGFloat {
        guard let viewportHeight = DetailPlacementGeometry.sanitizedViewportHeight(viewportHeight) else {
            return 0
        }
        switch self {
        case .homeRow:
            return max(210, (viewportHeight * RemoteFocusScrollAnchor.row.y).rounded())
        case .detailEpisode:
            return RemoteDetailFocusPlacement.targetViewportTop(viewportHeight: viewportHeight)
        case .detailRelatedRow:
            return RemoteDetailFocusPlacement.targetViewportTop(viewportHeight: viewportHeight)
        }
    }

    func placementTolerance(viewportHeight: CGFloat) -> CGFloat? {
        guard let viewportHeight = DetailPlacementGeometry.sanitizedViewportHeight(viewportHeight) else {
            return nil
        }
        switch self {
        case .homeRow:
            return max(48, viewportHeight * 0.11)
        case .detailEpisode, .detailRelatedRow:
            return nil
        }
    }

    func isComfortablyPlaced(rowViewportTop: CGFloat, viewportHeight: CGFloat) -> Bool {
        guard rowViewportTop.isFinite,
              DetailPlacementGeometry.sanitizedViewportHeight(viewportHeight) != nil else {
            return false
        }
        switch self {
        case .detailEpisode, .detailRelatedRow:
            return RemoteDetailFocusPlacement.contains(rowViewportTop, viewportHeight: viewportHeight)
        case .homeRow:
            let desired = desiredViewportTop(viewportHeight: viewportHeight)
            guard let tolerance = placementTolerance(viewportHeight: viewportHeight) else {
                return false
            }
            return abs(rowViewportTop - desired) <= tolerance
        }
    }

    static func targetOffset(
        currentOffset: CGFloat,
        rowViewportTop: CGFloat,
        desiredViewportTop: CGFloat
    ) -> CGFloat {
        guard currentOffset.isFinite,
              rowViewportTop.isFinite,
              desiredViewportTop.isFinite else {
            return 0
        }
        return max(0, currentOffset + rowViewportTop - desiredViewportTop)
    }

    static func heroTargetOffset() -> CGFloat {
        0
    }
}

enum RemoteDetailFocusPlacement {
    static let minimumAnchorY: CGFloat = 0.26
    static let maximumAnchorY: CGFloat = 0.36

    static func targetViewportTop(viewportHeight: CGFloat) -> CGFloat {
        guard let viewportHeight = DetailPlacementGeometry.sanitizedViewportHeight(viewportHeight) else {
            return 0
        }
        return (viewportHeight * RemoteFocusScrollAnchor.detail.y).rounded()
    }

    static func targetOffset(
        currentOffset: CGFloat,
        focusViewportTop: CGFloat,
        viewportHeight: CGFloat
    ) -> CGFloat {
        guard currentOffset.isFinite,
              focusViewportTop.isFinite,
              DetailPlacementGeometry.sanitizedViewportHeight(viewportHeight) != nil else {
            return 0
        }
        return RemoteScrollPlacement.targetOffset(
            currentOffset: currentOffset,
            rowViewportTop: focusViewportTop,
            desiredViewportTop: targetViewportTop(viewportHeight: viewportHeight)
        )
    }

    static func resolvedViewportTop(
        currentOffset: CGFloat,
        targetOffset: CGFloat,
        focusViewportTop: CGFloat
    ) -> CGFloat {
        guard currentOffset.isFinite,
              targetOffset.isFinite,
              focusViewportTop.isFinite else {
            return 0
        }
        return currentOffset + focusViewportTop - targetOffset
    }

    static func contains(_ rowViewportTop: CGFloat, viewportHeight: CGFloat) -> Bool {
        guard rowViewportTop.isFinite,
              let viewportHeight = DetailPlacementGeometry.sanitizedViewportHeight(viewportHeight) else {
            return false
        }
        let band = (viewportHeight * minimumAnchorY)...(viewportHeight * maximumAnchorY)
        return band.contains(rowViewportTop)
    }
}

// MARK: - Detail Placement Authority

enum DetailFocusContainer: Equatable {
    case top
    case actions
    case synopsis
    case overview
    case seasons
    case episodes
    case moreLike
    case personRow(Int)
    case other(FocusNodeID)
}

struct DetailFocusTransition: Equatable {
    let from: FocusNodeID?
    let to: FocusNodeID
    let direction: FocusDirection?

    init(from: FocusNodeID?, to: FocusNodeID, direction: FocusDirection?) {
        self.from = from
        self.to = to
        self.direction = direction
    }

    var fromContainer: DetailFocusContainer? {
        from.map(DetailPlacementPolicy.container)
    }

    var toContainer: DetailFocusContainer {
        DetailPlacementPolicy.container(for: to)
    }

    var sameContainer: Bool {
        guard let fromContainer else { return false }
        return fromContainer == toContainer
    }
}

enum DetailPlacementTarget: Equatable {
    case top
    case synopsis
    case overview
    case seasons
    case episode
    case relatedRow
    case personRow(Int)
}

enum DetailPlacementCommand: Equatable {
    case none
    // Requests a detail-band landing; view integrations provide measured
    // AppKit corrections only for targets they currently observe.
    case verticalBand(DetailPlacementTarget)
    case horizontalReveal(DetailPlacementTarget)

    var includesVerticalScroll: Bool {
        switch self {
        case .verticalBand:
            return true
        case .none, .horizontalReveal:
            return false
        }
    }
}

struct DetailPlacementGeometry: Equatable {
    let currentOffset: CGFloat
    let targetViewportTop: CGFloat
    let viewportHeight: CGFloat

    static func sanitizedViewportTop(_ value: CGFloat?) -> CGFloat? {
        guard let value, value.isFinite else { return nil }
        return value
    }

    static func sanitizedViewportHeight(_ value: CGFloat) -> CGFloat? {
        guard value.isFinite, value > 0 else { return nil }
        return value
    }
}

struct PendingDetailPlacementCorrection: Equatable {
    let serial: Int
    let target: DetailPlacementTarget
    let focus: FocusNodeID?
    let animatesCorrection: Bool
    var didCorrect: Bool

    init(
        serial: Int,
        target: DetailPlacementTarget,
        focus: FocusNodeID? = nil,
        animatesCorrection: Bool = false,
        didCorrect: Bool
    ) {
        self.serial = serial
        self.target = target
        self.focus = focus
        self.animatesCorrection = animatesCorrection
        self.didCorrect = didCorrect
    }

    func accepts(measurement: DetailPlacementMeasurement) -> Bool {
        guard target == .episode else { return true }
        guard let focus else { return false }
        return measurement.focus == focus && measurement.viewportTop.isFinite
    }
}

struct DetailPlacementMeasurement: Equatable {
    let focus: FocusNodeID
    let viewportTop: CGFloat
}

enum DetailPlacementPolicy {
    static func command(for transition: DetailFocusTransition) -> DetailPlacementCommand? {
        if transition.sameContainer, transition.direction?.isHorizontal == true {
            switch transition.toContainer {
            case .moreLike:
                return .horizontalReveal(.relatedRow)
            case .personRow(let row):
                return .horizontalReveal(.personRow(row))
            case .top, .actions, .synopsis, .overview, .seasons, .episodes, .other:
                return DetailPlacementCommand.none
            }
        }

        switch transition.toContainer {
        case .moreLike:
            return .verticalBand(.relatedRow)
        case .personRow(let row):
            return .verticalBand(.personRow(row))
        case .synopsis:
            return .verticalBand(.synopsis)
        case .overview:
            return .verticalBand(.overview)
        case .seasons:
            return .verticalBand(.seasons)
        case .episodes:
            return .verticalBand(.episode)
        case .top, .actions:
            return .verticalBand(.top)
        case .other:
            return nil
        }
    }

    static func correctionTargetOffset(for target: DetailPlacementTarget, geometry: DetailPlacementGeometry) -> CGFloat? {
        guard DetailPlacementGeometry.sanitizedViewportHeight(geometry.viewportHeight) != nil,
              geometry.currentOffset.isFinite,
              geometry.targetViewportTop.isFinite else {
            return nil
        }
        guard !RemoteDetailFocusPlacement.contains(
            geometry.targetViewportTop,
            viewportHeight: geometry.viewportHeight
        ) else {
            return nil
        }
        switch target {
        case .top:
            return 0
        case .synopsis, .overview, .seasons, .episode, .relatedRow, .personRow:
            return RemoteDetailFocusPlacement.targetOffset(
                currentOffset: geometry.currentOffset,
                focusViewportTop: geometry.targetViewportTop,
                viewportHeight: geometry.viewportHeight
            )
        }
    }

    static func container(for focus: FocusNodeID) -> DetailFocusContainer {
        if focus == DetailFocusIDs.movieBack || focus == DetailFocusIDs.showBack {
            return .top
        }
        if focus == DetailFocusIDs.movieStart || focus == DetailFocusIDs.movieContinue ||
            focus == DetailFocusIDs.showStart || focus == DetailFocusIDs.showContinue {
            return .actions
        }
        if focus == DetailFocusIDs.movieShowMore {
            return .synopsis
        }
        if focus == DetailFocusIDs.showOverview {
            return .overview
        }
        if focus == DetailFocusIDs.showSeasons {
            return .seasons
        }
        if DetailFocusIDs.showEpisodeIndex(from: focus) != nil {
            return .episodes
        }
        if DetailFocusIDs.movieMoreLikeIndex(from: focus) != nil ||
            DetailFocusIDs.showMoreLikeIndex(from: focus) != nil {
            return .moreLike
        }
        if let personIndex = DetailFocusIDs.moviePersonIndex(from: focus) {
            return .personRow(personIndex.row)
        }
        if let personIndex = DetailFocusIDs.showPersonIndex(from: focus) {
            return .personRow(personIndex.row)
        }
        return .other(focus)
    }
}

extension FocusDirection {
    var isHorizontal: Bool {
        switch self {
        case .left, .right:
            return true
        case .up, .down:
            return false
        }
    }
}
