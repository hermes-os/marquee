import SwiftUI
import AppKit

// MARK: - ObservableScrollView (NSScrollView bridge)

struct ObservableScrollView<Content: View>: NSViewRepresentable {

    @Binding var offset: CGFloat
    let content: Content

    init(offset: Binding<CGFloat>, @ViewBuilder content: () -> Content) {
        self._offset = offset
        self.content = content()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(offset: $offset)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder

        let hostingView = NSHostingView(rootView: content)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        hostingView.setContentHuggingPriority(.defaultLow, for: .vertical)

        let clipView = FlippedClipView()
        clipView.drawsBackground = false
        clipView.documentView = hostingView
        scrollView.contentView = clipView

        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: clipView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: clipView.trailingAnchor),
            hostingView.widthAnchor.constraint(greaterThanOrEqualToConstant: 100),
            hostingView.heightAnchor.constraint(greaterThanOrEqualToConstant: 100),
        ])

        clipView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.boundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: clipView
        )

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {}

    // MARK: - Coordinator

    class Coordinator: NSObject {
        var offset: Binding<CGFloat>
        private var lastUpdateTime: TimeInterval = 0

        init(offset: Binding<CGFloat>) {
            self.offset = offset
        }

        @objc func boundsDidChange(_ notification: Notification) {
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastUpdateTime >= 0.016 else { return }
            lastUpdateTime = now

            guard let clipView = notification.object as? NSClipView else { return }
            DispatchQueue.main.async {
                self.offset.wrappedValue = max(0, clipView.bounds.origin.y)
            }
        }
    }
}

// MARK: - Flipped Clip View

final class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}
