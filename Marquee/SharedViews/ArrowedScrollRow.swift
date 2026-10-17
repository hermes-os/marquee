import AppKit
import SwiftUI

// MARK: - ArrowedScrollRow
//
// A horizontal scroll wrapper that overlays hover-revealed left/right nav
// buttons so users without a trackpad can advance through a row by mouse.
//
// Caller passes the ordered list of item IDs (must match `.id(...)` modifiers
// applied to each card inside `content`). Remote focus uses exact AppKit
// offsets through `RemoteHorizontalScrollController`; ScrollViewReader remains
// only for pointer-driven hover arrows.
//
// Arrows only appear while the row is hovered AND there's room to scroll in
// that direction. The trackpad swipe gesture continues to work normally.

struct ArrowedScrollRow<ID: Hashable, Content: View>: View {

    let ids: [ID]
    var focusedID: ID?
    var focusItemExtent: CGFloat? = nil
    var focusItemSpacing: CGFloat? = nil
    var focusScrollMode: RemoteHorizontalFocusScrollPolicy.Mode = .standard
    var focusContentInset: CGFloat = 0
    var hoverArrowsEnabled: Bool = true
    @ViewBuilder var content: () -> Content

    @Environment(\.leanBackMode) private var leanBackMode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isHovering: Bool = false
    @State private var scrollIndex: Int = 0
    @StateObject private var horizontalScrollController = RemoteHorizontalScrollController()

    private var pageStep: Int {
        leanBackMode ? 3 : 4
    }

    private var haloPadding: CGFloat {
        MarqueeTheme.focusChromeHaloPadding(isLeanBack: leanBackMode)
    }

    private var leadingContentPadding: CGFloat {
        RemoteHorizontalFocusScrollPolicy.leadingContentPadding(
            mode: focusScrollMode,
            isLeanBack: leanBackMode
        ) + normalizedFocusContentInset
    }

    private var minimumTrailingContentPadding: CGFloat {
        haloPadding + normalizedFocusContentInset
    }

    private var scrollTrailingContentPadding: CGFloat {
        guard let focusItemExtent,
              let focusItemSpacing,
              let padding = RemoteHorizontalFocusScrollPolicy.requiredTrailingPadding(
                count: ids.count,
                itemExtent: focusItemExtent,
                itemSpacing: focusItemSpacing,
                viewportExtent: horizontalScrollController.viewportExtent,
                leadingInset: leadingContentPadding,
                minimumTrailingInset: minimumTrailingContentPadding
              ) else {
            return minimumTrailingContentPadding
        }
        return padding
    }

    private var normalizedFocusContentInset: CGFloat {
        guard focusContentInset.isFinite, focusContentInset > 0 else { return 0 }
        return focusContentInset
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                content()
                    .background(
                        RemoteHorizontalScrollObserver(controller: horizontalScrollController)
                            .frame(width: 0, height: 0)
                    )
                    .padding(.leading, leadingContentPadding)
                    .padding(.trailing, scrollTrailingContentPadding)
                    .padding(.vertical, haloPadding)
            }
            .padding(.horizontal, -haloPadding)
            .overlay(alignment: .leading) {
                if showHoverArrows && scrollIndex > 0 {
                    arrowButton(systemName: "chevron.left") {
                        let target = max(0, scrollIndex - pageStep)
                        scrollIndex = target
                        RemoteProgrammaticScrollPolicy.perform(animated: true, duration: 0.3) {
                            proxy.scrollTo(ids[target], anchor: .leading)
                        }
                    }
                    .padding(.leading, 4)
                    .transition(.opacity)
                }
            }
            .overlay(alignment: .trailing) {
                if showHoverArrows && scrollIndex < ids.count - 1 {
                    arrowButton(systemName: "chevron.right") {
                        let target = min(ids.count - 1, scrollIndex + pageStep)
                        scrollIndex = target
                        RemoteProgrammaticScrollPolicy.perform(animated: true, duration: 0.3) {
                            proxy.scrollTo(ids[target], anchor: .leading)
                        }
                    }
                    .padding(.trailing, 4)
                    .transition(.opacity)
                }
            }
            .onAppear {
                scrollToFocusedID(focusedID, animated: false)
            }
            .onChange(of: horizontalScrollController.attachmentSerial) { _ in
                scrollToFocusedID(focusedID, animated: false)
            }
            .onChange(of: horizontalScrollController.viewportChangeSerial) { _ in
                scrollToFocusedID(focusedID, animated: false)
            }
            .onChange(of: horizontalScrollController.contentChangeSerial) { _ in
                scrollToFocusedID(focusedID, animated: false)
            }
            .onChange(of: focusedID) { id in
                scrollToFocusedID(id, animated: true)
            }
            .onChange(of: ids) { _ in
                scrollIndex = min(max(0, scrollIndex), max(0, ids.count - 1))
                scrollToFocusedID(focusedID, animated: false)
            }
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }

    private var showHoverArrows: Bool {
        ids.count > 1 && hoverArrowsEnabled && isHovering
    }

    private func arrowButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: MarqueeTheme.scaled(16, leanBack: 24, isLeanBack: leanBackMode), weight: .bold))
                .foregroundColor(MarqueeTheme.textPrimary)
                .frame(
                    width: MarqueeTheme.scaled(36, leanBack: 56, isLeanBack: leanBackMode),
                    height: MarqueeTheme.scaled(36, leanBack: 56, isLeanBack: leanBackMode)
                )
                .background(
                    Circle()
                        .fill(Color.black.opacity(0.65))
                )
        }
        .buttonStyle(.plain)
    }

    private func scrollToFocusedID(_ id: ID?, animated: Bool) {
        guard let id, let index = ids.firstIndex(of: id) else { return }
        scrollIndex = index
        guard let focusItemExtent,
              let focusItemSpacing,
              let offset = RemoteHorizontalFocusScrollPolicy.offset(
            for: index,
            count: ids.count,
            itemExtent: focusItemExtent,
            itemSpacing: focusItemSpacing,
            viewportExtent: horizontalScrollController.viewportExtent,
            leadingInset: leadingContentPadding,
            trailingInset: minimumTrailingContentPadding
        ) else { return }
        _ = horizontalScrollController.springScroll(
            to: offset,
            animated: animated,
            reduceMotion: reduceMotion
        )
    }
}

private struct RemoteHorizontalScrollObserver: NSViewRepresentable {
    let controller: RemoteHorizontalScrollController

    func makeNSView(context: Context) -> NSView {
        let view = RemoteHorizontalScrollAttachmentView()
        view.onAttach = { [weak controller] scrollView in
            controller?.attach(scrollView)
        }
        view.onDetach = { [weak controller] scrollView in
            controller?.detach(scrollView)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class RemoteHorizontalScrollAttachmentView: NSView {
    var onAttach: ((NSScrollView) -> Void)?
    var onDetach: ((NSScrollView) -> Void)?
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
        var current = superview
        while let view = current {
            if let scrollView = view as? NSScrollView {
                guard attachedScrollView !== scrollView else { return true }
                detachFromCurrentScrollView()
                attachedScrollView = scrollView
                onAttach?(scrollView)
                return true
            }
            current = view.superview
        }
        return false
    }

    private func detachFromCurrentScrollView() {
        guard let attachedScrollView else { return }
        self.attachedScrollView = nil
        onDetach?(attachedScrollView)
    }
}

#if DEBUG
enum VerifyRemoteHorizontalScrollAttachmentHarness {
    static func verifyReparenting() throws -> String {
        let firstScrollView = makeScrollView()
        let secondScrollView = makeScrollView()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1_600, height: 300))
        firstScrollView.frame.origin = .zero
        secondScrollView.frame.origin = NSPoint(x: 800, y: 0)
        container.addSubview(firstScrollView)
        container.addSubview(secondScrollView)

        let window = NSWindow(
            contentRect: container.bounds,
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        window.contentView = container

        let attachmentView = RemoteHorizontalScrollAttachmentView(frame: .zero)
        var attachments: [ObjectIdentifier] = []
        var detachments: [ObjectIdentifier] = []
        attachmentView.onAttach = { scrollView in
            attachments.append(ObjectIdentifier(scrollView))
        }
        attachmentView.onDetach = { scrollView in
            detachments.append(ObjectIdentifier(scrollView))
        }

        guard let firstDocumentView = firstScrollView.documentView,
              let secondDocumentView = secondScrollView.documentView else {
            window.close()
            throw HarnessError.assertion("attachment harness requires two document views")
        }
        firstDocumentView.addSubview(attachmentView)
        guard attachments == [ObjectIdentifier(firstScrollView)] else {
            window.close()
            throw HarnessError.assertion("attachment view did not discover its first containing scroll view")
        }

        attachmentView.removeFromSuperview()
        secondDocumentView.addSubview(attachmentView)
        guard attachments == [ObjectIdentifier(firstScrollView), ObjectIdentifier(secondScrollView)] else {
            window.close()
            throw HarnessError.assertion("attachment view did not detach and reattach after reparenting: \(attachments.count) attachment(s)")
        }
        guard detachments == [ObjectIdentifier(firstScrollView)] else {
            window.close()
            throw HarnessError.assertion("attachment view did not report the stale first scroll view during reparenting")
        }

        let thirdScrollView = makeScrollView()
        thirdScrollView.frame.origin = NSPoint(x: 0, y: 0)
        container.addSubview(thirdScrollView)
        let intermediateView = NSView(frame: .zero)
        let delayedAttachmentView = RemoteHorizontalScrollAttachmentView(frame: .zero)
        var delayedAttachment: NSScrollView?
        delayedAttachmentView.onAttach = { delayedAttachment = $0 }
        intermediateView.addSubview(delayedAttachmentView)
        container.addSubview(intermediateView)
        guard delayedAttachment == nil,
              let thirdDocumentView = thirdScrollView.documentView else {
            window.close()
            throw HarnessError.assertion("delayed attachment setup unexpectedly discovered a scroll view")
        }
        thirdDocumentView.addSubview(intermediateView)
        guard waitUntil({ delayedAttachment === thirdScrollView }, timeout: 1.5) else {
            window.close()
            throw HarnessError.assertion("attachment retry did not discover a containing scroll view after an ancestor was reparented")
        }

        window.close()
        return "attachment view detached stale ownership, followed direct reparenting, and retried delayed ancestor discovery"
    }

    private static func makeScrollView() -> NSScrollView {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        scrollView.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 1_600, height: 300))
        return scrollView
    }

    private static func waitUntil(_ condition: () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
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
