import SwiftUI
import AppKit

// MARK: - Search Text Field

struct SearchTextField: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool

    let focusRequestID: Int
    let placeholder: String
    let fontSize: CGFloat
    let onEditingStarted: () -> Void
    let onCommand: (Selector) -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let textField = FocusableSearchNSTextField()
        textField.identifier = NSUserInterfaceItemIdentifier("MarqueeSearchField")
        textField.isBordered = false
        textField.drawsBackground = false
        textField.isEditable = true
        textField.isSelectable = true
        textField.isEnabled = true
        textField.refusesFirstResponder = false
        textField.focusRingType = .none
        textField.placeholderString = placeholder
        textField.textColor = .white
        textField.font = .systemFont(ofSize: fontSize)
        textField.delegate = context.coordinator
        textField.lineBreakMode = .byTruncatingTail
        textField.onWindowAttached = { [weak textField, weak coordinator = context.coordinator] in
            guard let textField else { return }
            guard coordinator?.parent.isFocused == true else { return }
            coordinator?.focus(textField, requestID: coordinator?.parent.focusRequestID ?? -1)
        }
        return textField
    }

    func updateNSView(_ textField: NSTextField, context: Context) {
        context.coordinator.parent = self
        SearchTextFieldResponderSync.synchronize(
            textField,
            text: text,
            isFocused: isFocused,
            isCapturingInput: SearchInputBuffer.shared.isCapturingInput
        )
        textField.placeholderString = placeholder
        textField.font = .systemFont(ofSize: fontSize)
        let hasResponderFocus = SearchTextFieldResponderSync.hasResponderFocus(textField)
        if isFocused && (context.coordinator.lastFocusRequestID != focusRequestID || !hasResponderFocus) {
            context.coordinator.focus(textField, requestID: focusRequestID)
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SearchTextField
        var lastFocusRequestID: Int = -1

        init(_ parent: SearchTextField) {
            self.parent = parent
        }

        func focus(_ textField: NSTextField, requestID: Int) {
            guard let window = textField.window else { return }
            lastFocusRequestID = requestID
            if let editor = textField.currentEditor(), window.firstResponder === editor {
                beginSearchFieldEditing(applyingBufferTo: textField)
                parent.isFocused = true
                return
            }
            if window.firstResponder === textField {
                beginSearchFieldEditing(applyingBufferTo: textField)
                parent.isFocused = true
                return
            }
            window.makeFirstResponder(textField)
            if let editor = textField.currentEditor() {
                editor.selectedRange = NSRange(location: textField.stringValue.count, length: 0)
            }
            beginSearchFieldEditing(applyingBufferTo: textField)
            parent.isFocused = true
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            beginSearchFieldEditing(applyingBufferTo: notification.object as? NSTextField)
            parent.onEditingStarted()
            parent.isFocused = true
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.onEditingStarted()
            parent.text = field.stringValue
            parent.isFocused = true
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            SearchInputBuffer.shared.setSearchFieldEditing(false)
            parent.isFocused = false
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            parent.onCommand(commandSelector)
        }

        private func beginSearchFieldEditing(applyingBufferTo textField: NSTextField?) {
            let bufferedText = SearchInputBuffer.shared.beginSearchFieldEditingAndDrainCapture()
            guard !bufferedText.isEmpty else { return }
            parent.text = bufferedText
            textField?.stringValue = bufferedText
            if let editor = textField?.currentEditor() {
                editor.string = bufferedText
                editor.selectedRange = NSRange(location: bufferedText.count, length: 0)
            }
        }
    }
}

final class FocusableSearchNSTextField: NSTextField {
    var onWindowAttached: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        onWindowAttached?()
    }
}

enum SearchTextFieldResponderSync {
    static func synchronize(
        _ textField: NSTextField,
        text: String,
        isFocused: Bool,
        isCapturingInput: Bool
    ) {
        if !isFocused, hasResponderFocus(textField) {
            textField.window?.makeFirstResponder(nil)
        }

        let isEditing = isEditing(textField)
        let shouldSyncText = !isEditing || isCapturingInput || !isFocused
        guard textField.stringValue != text, shouldSyncText else { return }

        textField.stringValue = text
        if let editor = textField.currentEditor() {
            editor.string = text
            editor.selectedRange = NSRange(location: text.count, length: 0)
        }
    }

    static func hasResponderFocus(_ textField: NSTextField) -> Bool {
        if isEditing(textField) { return true }
        return textField.window?.firstResponder === textField
    }

    private static func isEditing(_ textField: NSTextField) -> Bool {
        guard let editor = textField.currentEditor() else { return false }
        return textField.window?.firstResponder === editor
    }
}

#if DEBUG
enum VerifySearchFieldResponderSyncHarness {
    static let launchArgument = "--verify-search-field-responder-sync"

    static func runIfRequested() {
        guard CommandLine.arguments.contains(launchArgument) else { return }

        do {
            let detail = try runScenario()
            FileHandle.standardError.write(Data("verify-search-field-responder-sync: PASS responderOwnership: \(detail)\n".utf8))
            FileHandle.standardError.write(Data("verify-search-field-responder-sync: outcome=verified passed=3/3\n".utf8))
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("verify-search-field-responder-sync: FAIL responderOwnership: \(error)\n".utf8))
            FileHandle.standardError.write(Data("verify-search-field-responder-sync: outcome=failed passed=0/3\n".utf8))
            exit(1)
        }
    }

    private static func runScenario() throws -> String {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let contentView = NSView(frame: window.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 480, height: 120))
        let textField = FocusableSearchNSTextField(frame: NSRect(x: 24, y: 44, width: 360, height: 32))
        textField.isEditable = true
        textField.isSelectable = true
        textField.refusesFirstResponder = false
        textField.stringValue = ""
        contentView.addSubview(textField)
        window.contentView = contentView
        window.makeKeyAndOrderFront(nil)

        defer {
            window.orderOut(nil)
            window.close()
        }

        try verifyRemoteOwnershipResignsAndSyncs(textField)
        try verifyPhysicalEditingIsAuthoritative(textField)
        try verifyCaptureCanForceSyncWhileEditing(textField)
        return "remote sync, physical edit preservation, capture force-sync"
    }

    private static func verifyRemoteOwnershipResignsAndSyncs(_ textField: NSTextField) throws {
        startEditing(textField, value: "")
        guard SearchTextFieldResponderSync.hasResponderFocus(textField) else {
            throw HarnessError.assertion("field did not begin editing before remote ownership")
        }

        SearchTextFieldResponderSync.synchronize(
            textField,
            text: "k",
            isFocused: false,
            isCapturingInput: false
        )

        guard !SearchTextFieldResponderSync.hasResponderFocus(textField) else {
            throw HarnessError.assertion("remote ownership did not resign text-field first responder")
        }
        guard textField.stringValue == "k" else {
            throw HarnessError.assertion("remote-owned field did not show synchronized text: \(textField.stringValue)")
        }
    }

    private static func verifyPhysicalEditingIsAuthoritative(_ textField: NSTextField) throws {
        startEditing(textField, value: "manual")
        SearchTextFieldResponderSync.synchronize(
            textField,
            text: "remote",
            isFocused: true,
            isCapturingInput: false
        )

        guard currentEditorText(for: textField) == "manual" else {
            throw HarnessError.assertion("physical editing was overwritten by programmatic sync")
        }
    }

    private static func verifyCaptureCanForceSyncWhileEditing(_ textField: NSTextField) throws {
        startEditing(textField, value: "manual")
        SearchTextFieldResponderSync.synchronize(
            textField,
            text: "buffered",
            isFocused: true,
            isCapturingInput: true
        )

        guard currentEditorText(for: textField) == "buffered" else {
            throw HarnessError.assertion("capture force-sync did not update editor text")
        }
    }

    private static func startEditing(_ textField: NSTextField, value: String) {
        textField.stringValue = value
        textField.window?.makeFirstResponder(textField)
        textField.selectText(nil)
        if let editor = textField.currentEditor() {
            editor.string = value
            editor.selectedRange = NSRange(location: value.count, length: 0)
        }
    }

    private static func currentEditorText(for textField: NSTextField) -> String {
        textField.currentEditor()?.string ?? textField.stringValue
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
