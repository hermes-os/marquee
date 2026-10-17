import SwiftUI
import AppKit

// MARK: - Window Accessor

struct WindowAccessor: NSViewRepresentable {
    let callback: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                self.callback(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Window Styling

enum MarqueeWindowStyle {
    private static let styledWindows = NSHashTable<NSWindow>.weakObjects()

    static func apply(to window: NSWindow) {
        guard !styledWindows.contains(window) else { return }
        styledWindows.add(window)

        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = NSColor(MarqueeTheme.background)

        window.styleMask.insert(.fullSizeContentView)
        window.minSize = WindowPresentationPolicy.minimumWindowSize
        WindowPresentationPolicy.applyInitialFrameIfNeeded(window)
    }
}

private enum WindowPresentationPolicy {
    static let minimumWindowSize = NSSize(width: 1100, height: 700)
    private static let preferredWindowSize = NSSize(width: 1440, height: 900)

    static func applyInitialFrameIfNeeded(_ window: NSWindow) {
        guard let screen = window.screen ?? NSScreen.main else { return }
        let visibleFrame = screen.visibleFrame
        guard visibleFrame.width >= minimumWindowSize.width,
              visibleFrame.height >= minimumWindowSize.height else { return }

        let targetSize = NSSize(
            width: min(preferredWindowSize.width, visibleFrame.width),
            height: min(preferredWindowSize.height, visibleFrame.height)
        )
        let targetFrame = NSRect(
            x: visibleFrame.midX - targetSize.width / 2,
            y: visibleFrame.midY - targetSize.height / 2,
            width: targetSize.width,
            height: targetSize.height
        )
        guard window.frame.size.width < targetFrame.width * 0.92 ||
              window.frame.size.height < targetFrame.height * 0.92 else { return }
        window.setFrame(targetFrame, display: true, animate: false)
    }
}
