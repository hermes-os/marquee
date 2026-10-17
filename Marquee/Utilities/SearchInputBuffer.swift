import AppKit
import Foundation

final class SearchInputBuffer {
    static let shared = SearchInputBuffer()

    private var text: String = ""
    private var captureUntil: Date?
    private var searchFieldIsEditing = false

    private init() {}

    var currentText: String {
        expireCaptureIfNeeded()
        return text
    }

    var isCapturingInput: Bool {
        isCapturing
    }

    func beginCapture() {
        text = ""
        captureUntil = Date().addingTimeInterval(4.0)
    }

    func capture(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, isCapturing else { return false }
        guard !searchFieldIsEditing else { return false }

        let reservedModifiers: NSEvent.ModifierFlags = [.command, .control, .option]
        guard event.modifierFlags.intersection(reservedModifiers).isEmpty else { return false }

        switch Int(event.keyCode) {
        case 51:
            guard !text.isEmpty else { return true }
            text.removeLast()
            publishChange()
            return true
        case 36, 53, 123, 124, 125, 126:
            return false
        default:
            break
        }

        guard let characters = event.characters,
              characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            return false
        }
        text.append(characters)
        captureUntil = Date().addingTimeInterval(2.0)
        publishChange()
        return true
    }

    func drain() -> String {
        let value = text
        text = ""
        captureUntil = nil
        return value
    }

    func stopCapture() {
        text = ""
        captureUntil = nil
    }

    func seedProgrammaticQuery(_ value: String) {
        text = value
        captureUntil = Date().addingTimeInterval(4.0)
        searchFieldIsEditing = false
        publishChange()
    }

    func beginSearchFieldEditingAndDrainCapture() -> String {
        expireCaptureIfNeeded()
        let value = text
        text = ""
        captureUntil = nil
        searchFieldIsEditing = true
        return value
    }

    func setSearchFieldEditing(_ editing: Bool) {
        expireCaptureIfNeeded()
        searchFieldIsEditing = editing
        if editing {
            text = ""
            captureUntil = nil
        }
    }

    #if DEBUG
    func seedForVisualQA(_ value: String) {
        text = value
        captureUntil = Date().addingTimeInterval(10.0)
        searchFieldIsEditing = false
        publishChange()
    }
    #endif

    private var isCapturing: Bool {
        expireCaptureIfNeeded()
        return captureUntil != nil
    }

    private func expireCaptureIfNeeded() {
        if let captureUntil, captureUntil < Date() {
            text = ""
            self.captureUntil = nil
        }
    }

    private func publishChange() {
        NotificationCenter.default.post(name: .marqueeBufferedSearchInputChanged, object: nil)
    }
}

#if DEBUG
enum VerifySearchInputBufferHarness {
    static let launchArgument = "--verify-search-input-buffer"

    static func runIfRequested() {
        guard CommandLine.arguments.contains(launchArgument) else { return }

        do {
            let detail = try runScenario()
            FileHandle.standardError.write(Data("verify-search-input-buffer: PASS captureLifecycle: \(detail)\n".utf8))
            FileHandle.standardError.write(Data("verify-search-input-buffer: outcome=verified passed=2/2\n".utf8))
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("verify-search-input-buffer: FAIL captureLifecycle: \(error)\n".utf8))
            FileHandle.standardError.write(Data("verify-search-input-buffer: outcome=failed passed=0/2\n".utf8))
            exit(1)
        }
    }

    private static func runScenario() throws -> String {
        let buffer = SearchInputBuffer.shared
        buffer.stopCapture()
        buffer.setSearchFieldEditing(false)

        buffer.beginCapture()
        for character in ["b", "l", "u", "e", "y"] {
            guard buffer.capture(try keyEvent(character)) else {
                throw HarnessError.assertion("failed to capture \(character)")
            }
        }
        guard buffer.currentText == "bluey" else {
            throw HarnessError.assertion("captured text=\(buffer.currentText)")
        }

        let drained = buffer.beginSearchFieldEditingAndDrainCapture()
        guard drained == "bluey" else {
            throw HarnessError.assertion("drained text=\(drained)")
        }
        guard buffer.isCapturingInput == false else {
            throw HarnessError.assertion("capture stayed active after search field began editing")
        }
        guard buffer.capture(try keyEvent("z")) == false else {
            throw HarnessError.assertion("normal typing was still intercepted while search field was editing")
        }

        buffer.setSearchFieldEditing(false)
        try verifyStopCaptureDisablesGlobalInput(buffer)
        return "drained=\(drained), capture disabled while editing, stopCapture disables global capture"
    }

    private static func verifyStopCaptureDisablesGlobalInput(_ buffer: SearchInputBuffer) throws {
        buffer.stopCapture()
        buffer.setSearchFieldEditing(false)
        buffer.beginCapture()
        guard buffer.capture(try keyEvent("k")) else {
            throw HarnessError.assertion("failed to capture seed character before stopCapture")
        }
        buffer.stopCapture()
        guard buffer.isCapturingInput == false else {
            throw HarnessError.assertion("stopCapture left capture active")
        }
        guard buffer.capture(try keyEvent("x")) == false else {
            throw HarnessError.assertion("global capture consumed text after stopCapture")
        }
    }

    private static func keyEvent(_ character: String) throws -> NSEvent {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: character,
            charactersIgnoringModifiers: character,
            isARepeat: false,
            keyCode: 0
        ) else {
            throw HarnessError.assertion("could not create key event for \(character)")
        }
        return event
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
