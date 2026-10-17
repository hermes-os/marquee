import SwiftUI
import AppKit

// MARK: - Key Catcher

struct MarqueeKeyEvent {
    let keyCode: UInt16
    let modifierFlags: NSEvent.ModifierFlags
    let charactersIgnoringModifiers: String?
    let isRepeat: Bool

    init(_ event: NSEvent) {
        keyCode = event.keyCode
        modifierFlags = event.modifierFlags
        charactersIgnoringModifiers = event.charactersIgnoringModifiers
        isRepeat = event.isARepeat
    }

    var key: MarqueeKey? {
        let reservedModifiers: NSEvent.ModifierFlags = [.command, .control, .option]
        guard modifierFlags.intersection(reservedModifiers).isEmpty else { return nil }

        switch keyCode {
        case 36: return .select
        case 49: return .select
        case 53: return .escape
        case 123: return .left
        case 124: return .right
        case 125: return .down
        case 126: return .up
        default:
            switch charactersIgnoringModifiers?.lowercased() {
            case "s": return .subtitles
            case "f": return .fullscreen
            case "m": return .mute
            case "[": return .speedDown
            case "]": return .speedUp
            default: return nil
            }
        }
    }
}

enum MarqueeKey {
    case up
    case down
    case left
    case right
    case select
    case escape
    case subtitles
    case fullscreen
    case mute
    case speedDown
    case speedUp
}

struct KeyCatcher: NSViewRepresentable {
    var onKeyDown: (MarqueeKeyEvent) -> Bool
    var onKeyUp: (MarqueeKeyEvent) -> Bool = { _ in false }

    func makeCoordinator() -> Coordinator {
        Coordinator(onKeyDown: onKeyDown, onKeyUp: onKeyUp)
    }

    func makeNSView(context: Context) -> KeyCatcherView {
        let view = KeyCatcherView()
        view.onKeyDown = onKeyDown
        view.onKeyUp = onKeyUp
        context.coordinator.view = view
        context.coordinator.installMonitorIfNeeded()
        view.requestFocus()
        return view
    }

    func updateNSView(_ nsView: KeyCatcherView, context: Context) {
        nsView.onKeyDown = onKeyDown
        nsView.onKeyUp = onKeyUp
        context.coordinator.onKeyDown = onKeyDown
        context.coordinator.onKeyUp = onKeyUp
        context.coordinator.view = nsView
        context.coordinator.installMonitorIfNeeded()
        nsView.requestFocus()
    }

    static func dismantleNSView(_ nsView: KeyCatcherView, coordinator: Coordinator) {
        coordinator.removeMonitor()
        nsView.onKeyDown = nil
        nsView.onKeyUp = nil
    }

    final class Coordinator {
        var onKeyDown: (MarqueeKeyEvent) -> Bool
        var onKeyUp: (MarqueeKeyEvent) -> Bool
        weak var view: KeyCatcherView?
        private var monitor: Any?

        init(
            onKeyDown: @escaping (MarqueeKeyEvent) -> Bool,
            onKeyUp: @escaping (MarqueeKeyEvent) -> Bool
        ) {
            self.onKeyDown = onKeyDown
            self.onKeyUp = onKeyUp
        }

        deinit {
            removeMonitor()
        }

        func installMonitorIfNeeded() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
                guard let self, self.shouldHandle(event) else {
                    return event
                }

                let handled: Bool
                if event.type == .keyDown {
                    handled = self.onKeyDown(MarqueeKeyEvent(event))
                } else {
                    handled = self.onKeyUp(MarqueeKeyEvent(event))
                }
                return handled ? nil : event
            }
        }

        func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        private func shouldHandle(_ event: NSEvent) -> Bool {
            guard let view, let window = view.window, window.isKeyWindow else { return false }
            let reservedModifiers: NSEvent.ModifierFlags = [.command, .control, .option]
            guard event.modifierFlags.intersection(reservedModifiers).isEmpty else { return false }
            if let eventWindow = event.window, eventWindow !== window {
                return false
            }
            return !view.hasHiddenAncestor
        }
    }
}

final class KeyCatcherView: NSView {
    var onKeyDown: ((MarqueeKeyEvent) -> Bool)?
    var onKeyUp: ((MarqueeKeyEvent) -> Bool)?

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        requestFocus()
    }

    func requestFocus() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window?.firstResponder !== self else { return }
            self.window?.makeFirstResponder(self)
        }
    }

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(MarqueeKeyEvent(event)) == true {
            return
        }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        if onKeyUp?(MarqueeKeyEvent(event)) == true {
            return
        }
        super.keyUp(with: event)
    }
}

private extension NSView {
    var hasHiddenAncestor: Bool {
        if isHidden { return true }
        var ancestor = superview
        while let view = ancestor {
            if view.isHidden { return true }
            ancestor = view.superview
        }
        return false
    }
}
