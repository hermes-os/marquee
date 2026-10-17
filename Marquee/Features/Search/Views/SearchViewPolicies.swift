import AppKit

enum SearchResultsUpdatePolicy {
    static func delay(for _: String) -> TimeInterval {
        // SearchSession evaluates on a cancellable user-initiated worker.
        // Scheduling immediately keeps input responsive while its generation
        // token coalesces stale keystrokes without blocking the main thread.
        0
    }
}

enum SearchRootFocusPlacementPolicy {
    static let fieldScrollID = "search-field"
    static let keyboardScrollID = "search-remote-keyboard"

    static func scrollID(isFieldFocused: Bool, isKeyboardFocused: Bool) -> String? {
        if isKeyboardFocused { return keyboardScrollID }
        if isFieldFocused { return fieldScrollID }
        return nil
    }
}

enum SearchResultScrollIdentity {
    static func movie(generation: UInt64, itemID: UUID) -> String {
        "search-result-\(generation)-movie-\(itemID.uuidString)"
    }

    static func show(generation: UInt64, showName: String) -> String {
        "search-result-\(generation)-show-\(showName)"
    }
}

enum SearchResultPlacementPolicy {
    static func shouldScroll(
        from previous: SearchResultGridFocus?,
        to current: SearchResultGridFocus,
        columnCount: Int
    ) -> Bool {
        guard let previous else { return true }
        let columns = max(1, columnCount)
        switch (previous, current) {
        case (.movie(let lhs), .movie(let rhs)), (.show(let lhs), .show(let rhs)):
            return lhs / columns != rhs / columns
        case (.movie, .show), (.show, .movie):
            return true
        }
    }
}

enum SearchResultRenderPolicy {
    static let firstPaintMovieLimit = 5
    static let firstPaintShowLimit = 2
    static let expandedMovieLimit = 72
    static let expandedShowLimit = 48
    static let expansionDelay: TimeInterval = 0.45
}

enum SearchFocusPolicy {
    static let retryDelays: [TimeInterval] = [0.06, 0.16, 0.32]
}

enum SearchFocusRetryPolicy {
    static func shouldApplyRetry(
        owner: RemoteInputOwner,
        isFieldOwner: Bool,
        burstMatches: Bool
    ) -> Bool {
        SearchInputOwnershipPolicy.consumesRemoteCommands(owner: owner) && isFieldOwner && burstMatches
    }
}

enum SearchPendingResultFocusDestination: Equatable {
    case keyboard
    case field
}

enum SearchPendingResultFocusPolicy {
    static func destination(
        keyboardPresented: Bool,
        hasKeyboardFocus: Bool
    ) -> SearchPendingResultFocusDestination {
        keyboardPresented && hasKeyboardFocus ? .keyboard : .field
    }
}

enum SearchPendingResultEntryPolicy {
    static func nextInteractionGeneration(after current: UInt64) -> UInt64 {
        current &+ 1
    }

    static func shouldFulfill(
        hasPendingIntent: Bool,
        searchFocusIsActive: Bool,
        intentInteractionGeneration: UInt64?,
        currentInteractionGeneration: UInt64
    ) -> Bool {
        hasPendingIntent
            && searchFocusIsActive
            && intentInteractionGeneration == currentInteractionGeneration
    }
}

enum SearchKeyboardVisiblePhysicalEditOutcome: Equatable {
    case applyText(String)
    case passThrough
}

enum SearchKeyboardVisiblePhysicalEditPolicy {
    static func outcome(
        for event: NSEvent,
        currentText: String
    ) -> SearchKeyboardVisiblePhysicalEditOutcome {
        guard event.type == .keyDown else { return .passThrough }

        let reservedModifiers: NSEvent.ModifierFlags = [.command, .control, .option]
        guard event.modifierFlags.intersection(reservedModifiers).isEmpty else {
            return .passThrough
        }

        switch Int(event.keyCode) {
        case 51:
            return .applyText(String(currentText.dropLast()))
        case 36, 53, 123, 124, 125, 126:
            return .passThrough
        default:
            break
        }

        guard let characters = event.characters, !characters.isEmpty else {
            return .passThrough
        }
        guard characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            return .passThrough
        }

        return .applyText(currentText + characters)
    }
}

#if DEBUG
enum VerifySearchKeyboardEventRoutingHarness {
    static let launchArgument = "--verify-search-keyboard-event-routing"

    static func runIfRequested() {
        guard CommandLine.arguments.contains(launchArgument) else { return }

        do {
            let detail = try runScenario()
            FileHandle.standardError.write(Data("verify-search-keyboard-event-routing: PASS keyboardVisibleEventRouting: \(detail)\n".utf8))
            FileHandle.standardError.write(Data("verify-search-keyboard-event-routing: outcome=verified passed=16/16\n".utf8))
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("verify-search-keyboard-event-routing: FAIL keyboardVisibleEventRouting: \(error)\n".utf8))
            FileHandle.standardError.write(Data("verify-search-keyboard-event-routing: outcome=failed passed=0/16\n".utf8))
            exit(1)
        }
    }

    private static func runScenario() throws -> String {
        try verifyKeyboardVisiblePhysicalEdits()
        try verifyFocusRetryOwnership()
        return "physical space/delete preserved; stale field retries gated"
    }

    private static func verifyKeyboardVisiblePhysicalEdits() throws {
        try expectOutcome(
            keyCode: 49,
            characters: " ",
            currentText: "alien",
            expected: .applyText("alien "),
            message: "physical space should append a literal space while keyboard is visible"
        )
        try expectOutcome(
            keyCode: 51,
            characters: "\u{7F}",
            currentText: "alien",
            expected: .applyText("alie"),
            message: "physical delete should remove one character from existing query"
        )
        try expectOutcome(
            keyCode: 51,
            characters: "\u{7F}",
            currentText: "",
            expected: .applyText(""),
            message: "physical delete on an empty query should still be consumed as editing"
        )
        try expectOutcome(
            keyCode: 0,
            characters: "a",
            currentText: "king",
            expected: .applyText("kinga"),
            message: "physical letter should append to the existing query"
        )
        try expectOutcome(
            keyCode: 36,
            characters: "\r",
            currentText: "alien",
            expected: .passThrough,
            message: "remote return/select should remain available"
        )
        try expectOutcome(
            keyCode: 123,
            characters: "",
            currentText: "alien",
            expected: .passThrough,
            message: "remote arrow should remain available"
        )
        try expectOutcome(
            keyCode: 49,
            characters: " ",
            modifiers: [.command],
            currentText: "alien",
            expected: .passThrough,
            message: "reserved modifier shortcuts should pass through"
        )
    }

    private static func verifyFocusRetryOwnership() throws {
        guard SearchFocusRetryPolicy.shouldApplyRetry(
            owner: .searchRoot,
            isFieldOwner: true,
            burstMatches: true
        ) else {
            throw HarnessError.assertion("field-owned current burst should apply")
        }
        guard !SearchFocusRetryPolicy.shouldApplyRetry(
            owner: .searchRoot,
            isFieldOwner: false,
            burstMatches: true
        ) else {
            throw HarnessError.assertion("keyboard/result ownership should reject stale field retry")
        }
        for owner in RemoteInputOwner.allCases where owner != .searchRoot {
            guard !SearchFocusRetryPolicy.shouldApplyRetry(
                owner: owner,
                isFieldOwner: true,
                burstMatches: true
            ) else {
                throw HarnessError.assertion("\(owner.rawValue) ownership should reject field retry")
            }
        }
        guard !SearchFocusRetryPolicy.shouldApplyRetry(
            owner: .searchRoot,
            isFieldOwner: true,
            burstMatches: false
        ) else {
            throw HarnessError.assertion("stale burst should reject field retry")
        }
    }

    private static func expectOutcome(
        keyCode: UInt16,
        characters: String,
        modifiers: NSEvent.ModifierFlags = [],
        currentText: String,
        expected: SearchKeyboardVisiblePhysicalEditOutcome,
        message: String
    ) throws {
        let event = try keyEvent(
            keyCode: keyCode,
            characters: characters,
            modifiers: modifiers
        )
        let outcome = SearchKeyboardVisiblePhysicalEditPolicy.outcome(for: event, currentText: currentText)
        guard outcome == expected else {
            throw HarnessError.assertion("\(message): expected \(expected), got \(outcome)")
        }
    }

    private static func keyEvent(
        keyCode: UInt16,
        characters: String,
        modifiers: NSEvent.ModifierFlags
    ) throws -> NSEvent {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ) else {
            throw HarnessError.assertion("could not create key event for keyCode \(keyCode)")
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

#if DEBUG
enum VerifySearchResultsUpdatePolicyHarness {
    static let launchArgument = "--verify-search-results-update-policy"

    static func runIfRequested() {
        guard CommandLine.arguments.contains(launchArgument) else { return }

        do {
            let detail = try runScenario()
            FileHandle.standardError.write(Data("verify-search-results-update-policy: PASS avoidsArtificialDelay: \(detail)\n".utf8))
            FileHandle.standardError.write(Data("verify-search-results-update-policy: outcome=verified passed=1/1\n".utf8))
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("verify-search-results-update-policy: FAIL avoidsArtificialDelay: \(error)\n".utf8))
            FileHandle.standardError.write(Data("verify-search-results-update-policy: outcome=failed passed=0/1\n".utf8))
            exit(1)
        }
    }

    private static func runScenario() throws -> String {
        guard SearchResultsUpdatePolicy.delay(for: "") == 0 else {
            throw HarnessError.assertion("empty search did not clear immediately")
        }
        let firstCharacterDelay = SearchResultsUpdatePolicy.delay(for: "a")
        let fastTypingDelay = SearchResultsUpdatePolicy.delay(for: "alien")
        guard firstCharacterDelay == 0,
              fastTypingDelay == 0 else {
            throw HarnessError.assertion(
                "non-empty queries retained an artificial scheduling delay: first=\(firstCharacterDelay) full=\(fastTypingDelay)"
            )
        }
        let itemID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let firstGenerationMovieID = SearchResultScrollIdentity.movie(
            generation: 41,
            itemID: itemID
        )
        guard firstGenerationMovieID != SearchResultScrollIdentity.movie(
            generation: 42,
            itemID: itemID
        ), firstGenerationMovieID != SearchResultScrollIdentity.show(
            generation: 41,
            showName: itemID.uuidString
        ) else {
            throw HarnessError.assertion("result-cell identity was not qualified by generation and result domain")
        }
        guard SearchRootFocusPlacementPolicy.scrollID(
            isFieldFocused: true,
            isKeyboardFocused: false
        ) == SearchRootFocusPlacementPolicy.fieldScrollID,
        SearchRootFocusPlacementPolicy.scrollID(
            isFieldFocused: false,
            isKeyboardFocused: true
        ) == SearchRootFocusPlacementPolicy.keyboardScrollID,
        SearchRootFocusPlacementPolicy.scrollID(
            isFieldFocused: false,
            isKeyboardFocused: false
        ) == nil else {
            throw HarnessError.assertion("Search root focus did not resolve to one viewport placement target")
        }
        guard SearchPendingResultFocusPolicy.destination(
            keyboardPresented: true,
            hasKeyboardFocus: true
        ) == .keyboard,
        SearchPendingResultFocusPolicy.destination(
            keyboardPresented: false,
            hasKeyboardFocus: true
        ) == .field,
        SearchPendingResultFocusPolicy.destination(
            keyboardPresented: false,
            hasKeyboardFocus: false
        ) == .field else {
            throw HarnessError.assertion("pending result entry retained an invisible keyboard or suggestion owner")
        }
        let entryInteractionGeneration: UInt64 = 41
        let newerInteractionGeneration = SearchPendingResultEntryPolicy
            .nextInteractionGeneration(after: entryInteractionGeneration)
        guard SearchPendingResultEntryPolicy.shouldFulfill(
            hasPendingIntent: true,
            searchFocusIsActive: true,
            intentInteractionGeneration: entryInteractionGeneration,
            currentInteractionGeneration: entryInteractionGeneration
        ), !SearchPendingResultEntryPolicy.shouldFulfill(
            hasPendingIntent: true,
            searchFocusIsActive: false,
            intentInteractionGeneration: entryInteractionGeneration,
            currentInteractionGeneration: entryInteractionGeneration
        ), !SearchPendingResultEntryPolicy.shouldFulfill(
            hasPendingIntent: false,
            searchFocusIsActive: true,
            intentInteractionGeneration: nil,
            currentInteractionGeneration: entryInteractionGeneration
        ), !SearchPendingResultEntryPolicy.shouldFulfill(
            hasPendingIntent: true,
            searchFocusIsActive: true,
            intentInteractionGeneration: entryInteractionGeneration,
            currentInteractionGeneration: newerInteractionGeneration
        ) else {
            throw HarnessError.assertion("pending result entry survived inactive Search or newer explicit navigation")
        }
        return "all-queries=immediate cancellable-worker-coalescing generation-domain-cell-identity visible-pending-owner pending-sidebar-cancel"
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
