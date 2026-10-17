import Foundation
import SwiftUI

struct RemoteSearchKeyboardKey: Identifiable, Equatable {
    enum Kind: Equatable {
        case character(String)
        case space
        case delete
        case clear
        case done
    }

    let id: String
    let title: String
    let kind: Kind
    let width: CGFloat
}

struct RemoteKeyboardFocus: Equatable {
    var row: Int
    var column: Int
}

enum RemoteSearchKeyboardExit: Equatable {
    case field
    case results
    case sidebar
}

enum RemoteSearchKeyboardMove: Equatable {
    case stay(RemoteKeyboardFocus)
    case exit(RemoteSearchKeyboardExit)
}

enum RemoteSearchFieldDestination: Equatable {
    case keyboard
    case suggestions
    case results
    case sidebar
    case passThrough
}

enum RemoteSearchCompletionDestination: Equatable {
    case field
    case results
}

enum RemoteSearchDetailReturnDestination: Equatable {
    case restoredResult
    case firstResult
    case field
}

enum RemoteSearchResultExitDestination: Equatable {
    case keyboard
    case field
}

enum RemoteSearchKeyboardPolicy {
    static let layout: [[RemoteSearchKeyboardKey]] = [
        row("1234567890"),
        row("QWERTYUIOP"),
        row("ASDFGHJKL"),
        row("ZXCVBNM"),
        [
            actionKey(id: "space", title: "Space", kind: .space, width: 2.4),
            actionKey(id: "delete", title: "Delete", kind: .delete, width: 1.4),
            actionKey(id: "clear", title: "Clear", kind: .clear, width: 1.25),
            actionKey(id: "done", title: "Done", kind: .done, width: 1.25)
        ]
    ]

    static func initialFocus() -> RemoteKeyboardFocus {
        RemoteKeyboardFocus(row: 1, column: 0)
    }

    static func key(at focus: RemoteKeyboardFocus) -> RemoteSearchKeyboardKey? {
        guard layout.indices.contains(focus.row),
              layout[focus.row].indices.contains(focus.column) else {
            return nil
        }
        return layout[focus.row][focus.column]
    }

    static func move(_ focus: RemoteKeyboardFocus, command: RemoteCommand) -> RemoteSearchKeyboardMove {
        guard let normalized = normalizedFocus(focus) else {
            return .stay(initialFocus())
        }

        switch command {
        case .left:
            guard normalized.column > 0 else { return .exit(.sidebar) }
            return .stay(RemoteKeyboardFocus(row: normalized.row, column: normalized.column - 1))
        case .right:
            let lastColumn = layout[normalized.row].count - 1
            guard normalized.column < lastColumn else { return .stay(normalized) }
            return .stay(RemoteKeyboardFocus(row: normalized.row, column: normalized.column + 1))
        case .up:
            guard normalized.row > 0 else { return .exit(.field) }
            return .stay(clampedFocus(row: normalized.row - 1, preferredColumn: normalized.column))
        case .down:
            guard normalized.row < layout.count - 1 else { return .exit(.results) }
            return .stay(clampedFocus(row: normalized.row + 1, preferredColumn: normalized.column))
        case .select, .back:
            return .stay(normalized)
        }
    }

    static func applying(_ key: RemoteSearchKeyboardKey, to text: String) -> String {
        switch key.kind {
        case .character(let value):
            return text + value.lowercased()
        case .space:
            guard !text.hasSuffix(" ") else { return text }
            return text + " "
        case .delete:
            guard !text.isEmpty else { return text }
            return String(text.dropLast())
        case .clear:
            return ""
        case .done:
            return text
        }
    }

    private static func row(_ characters: String) -> [RemoteSearchKeyboardKey] {
        characters.map { character in
            let title = String(character)
            return RemoteSearchKeyboardKey(
                id: "char-\(title.lowercased())",
                title: title,
                kind: .character(title),
                width: 1
            )
        }
    }

    private static func actionKey(
        id: String,
        title: String,
        kind: RemoteSearchKeyboardKey.Kind,
        width: CGFloat
    ) -> RemoteSearchKeyboardKey {
        RemoteSearchKeyboardKey(id: id, title: title, kind: kind, width: width)
    }

    private static func normalizedFocus(_ focus: RemoteKeyboardFocus) -> RemoteKeyboardFocus? {
        guard layout.indices.contains(focus.row), !layout[focus.row].isEmpty else { return nil }
        return RemoteKeyboardFocus(
            row: focus.row,
            column: min(max(0, focus.column), layout[focus.row].count - 1)
        )
    }

    private static func clampedFocus(row: Int, preferredColumn: Int) -> RemoteKeyboardFocus {
        let lastColumn = max(0, layout[row].count - 1)
        return RemoteKeyboardFocus(row: row, column: min(preferredColumn, lastColumn))
    }
}

enum RemoteSearchKeyboardFlowPolicy {
    static func fieldDestination(
        for command: RemoteCommand,
        preservesNativeSpacebar: Bool,
        hasSuggestions: Bool = false
    ) -> RemoteSearchFieldDestination {
        switch command {
        case .down:
            if hasSuggestions {
                return .suggestions
            }
            return .keyboard
        case .select:
            return preservesNativeSpacebar ? .passThrough : .keyboard
        case .right:
            return .results
        case .left, .back:
            return .sidebar
        case .up:
            return .passThrough
        }
    }

    static func completionDestination(hasResults: Bool) -> RemoteSearchCompletionDestination {
        hasResults ? .results : .field
    }

    static func detailReturnDestination(
        canRestoreIdentity: Bool,
        hasFirstResult: Bool
    ) -> RemoteSearchDetailReturnDestination {
        if canRestoreIdentity {
            return .restoredResult
        }
        if hasFirstResult {
            return .firstResult
        }
        return .field
    }

    static func resultExitDestination(keyboardVisible: Bool) -> RemoteSearchResultExitDestination {
        keyboardVisible ? .keyboard : .field
    }
}

enum SearchSuggestionNavigationDestination: Equatable {
    case suggestion(Int)
    case applySuggestion(Int)
    case field
    case results
    case sidebar
    case stay
}

enum SearchSuggestionNavigationPolicy {
    static func destination(
        index: Int,
        count: Int,
        command: RemoteCommand
    ) -> SearchSuggestionNavigationDestination {
        guard count > 0 else { return .field }
        let clamped = min(max(0, index), count - 1)

        switch command {
        case .up:
            guard clamped > 0 else { return .field }
            return .suggestion(clamped - 1)
        case .down:
            guard clamped < count - 1 else { return .results }
            return .suggestion(clamped + 1)
        case .select:
            return .applySuggestion(clamped)
        case .right:
            return .applySuggestion(clamped)
        case .left:
            return .sidebar
        case .back:
            return .field
        }
    }
}

struct SearchResultReachabilityState: Equatable {
    let visibleMovieCount: Int
    let visibleShowCount: Int
    let pendingMovieCount: Int
    let pendingShowCount: Int
    let resultsExpanded: Bool
}

enum SearchResultReachabilityPolicy {
    static func firstReachableResult(in state: SearchResultReachabilityState) -> SearchResultGridFocus? {
        if state.visibleMovieCount > 0 {
            return .movie(0)
        }
        if state.visibleShowCount > 0 {
            return .show(0)
        }
        if state.pendingMovieCount > 0 {
            return .movie(0)
        }
        if state.pendingShowCount > 0 {
            return .show(0)
        }
        return nil
    }

    static func shouldExpandBeforeFocusingResults(_ state: SearchResultReachabilityState) -> Bool {
        guard !state.resultsExpanded else { return false }
        guard state.visibleMovieCount == 0, state.visibleShowCount == 0 else { return false }
        return state.pendingMovieCount > 0 || state.pendingShowCount > 0
    }
}

enum SearchResultGridFocus: Equatable {
    case movie(Int)
    case show(Int)
}

enum SearchResultGridDestination: Equatable {
    case result(SearchResultGridFocus)
    case fieldOrKeyboard
    case sidebar
    case stay
}

enum SearchResultGridNavigationPolicy {
    static func columnCount(
        availableWidth: CGFloat,
        minimumCardWidth: CGFloat,
        spacing: CGFloat
    ) -> Int {
        guard availableWidth > 0, minimumCardWidth > 0 else { return 1 }
        return max(1, Int((availableWidth + spacing) / (minimumCardWidth + spacing)))
    }

    /// Traversal runs through the shared `FocusEngine` over a vertical tree of the
    /// movie grid and the show grid, both marked `carriesGridColumn` so leaving one
    /// section enters the other at the same visual column. Escapes stay
    /// surface-local because they hand off input ownership rather than move focus.
    static func destination(
        focus: SearchResultGridFocus,
        command: RemoteCommand,
        movieCount: Int,
        showCount: Int,
        columnCount: Int
    ) -> SearchResultGridDestination {
        let columns = max(1, columnCount)

        switch command {
        case .select:
            return .stay
        case .back:
            return .fieldOrKeyboard
        case .left, .right, .up, .down:
            break
        }

        guard let direction = focusDirection(for: command) else { return .stay }

        // Skipping a partial trailing movie row is the one rule the tree cannot
        // express: the engine would step to the nearest surviving cell in that
        // row, where search deliberately leaves the section instead.
        if direction == .down, case .movie(let index) = focus, index + columns >= movieCount {
            guard showCount > 0 else { return .stay }
            return .result(.show(min(index % columns, showCount - 1)))
        }
        if direction == .down, case .show(let index) = focus, index + columns >= showCount {
            return .stay
        }

        guard let origin = node(for: focus, movieCount: movieCount, showCount: showCount) else {
            return escape(for: direction)
        }

        var state = FocusEngineState(focused: origin)

        // Moving up out of the shows grid lands on the *last* movie row at the
        // same column. The engine's carried column enters a sibling at its first
        // row, so the destination cell is seeded; remembered children outrank the
        // carried column.
        if direction == .up, case .show(let index) = focus, movieCount > 0 {
            let lastRowStart = ((movieCount - 1) / columns) * columns
            let target = min(lastRowStart + (index % columns), movieCount - 1)
            state.rememberedChildByContainer[GridFocusIDs.movies] = GridFocusIDs.movie(target)
        }

        let tree = focusTree(movieCount: movieCount, showCount: showCount, columns: columns)
        let moved = FocusEngine(root: tree).move(direction, state: state).state.focused
        guard moved != origin else { return escape(for: direction) }
        guard let next = gridFocus(for: moved) else { return .stay }
        return .result(next)
    }

    // MARK: - Engine Tree

    private enum GridFocusIDs {
        static let root: FocusNodeID = "search-results-root"
        static let movies: FocusNodeID = "search-results-movies"
        static let shows: FocusNodeID = "search-results-shows"

        static func movie(_ index: Int) -> FocusNodeID {
            FocusNodeID("search-result-movie:\(index)")
        }

        static func show(_ index: Int) -> FocusNodeID {
            FocusNodeID("search-result-show:\(index)")
        }
    }

    private static func focusDirection(for command: RemoteCommand) -> FocusDirection? {
        switch command {
        case .left: return .left
        case .right: return .right
        case .up: return .up
        case .down: return .down
        case .select, .back: return nil
        }
    }

    /// Holding still on a horizontal or downward edge, but handing input back to
    /// the field or keyboard on the leading and upward edges.
    private static func escape(for direction: FocusDirection) -> SearchResultGridDestination {
        switch direction {
        case .left, .up: return .fieldOrKeyboard
        case .right, .down: return .stay
        }
    }

    private static func focusTree(
        movieCount: Int,
        showCount: Int,
        columns: Int
    ) -> FocusNode {
        var sections: [FocusNode] = []
        if movieCount > 0 {
            sections.append(
                FocusNode(
                    GridFocusIDs.movies,
                    kind: .container(.grid(columns: columns)),
                    children: (0..<movieCount).map { FocusNode(GridFocusIDs.movie($0), kind: .leaf) },
                    carriesGridColumn: true
                )
            )
        }
        if showCount > 0 {
            sections.append(
                FocusNode(
                    GridFocusIDs.shows,
                    kind: .container(.grid(columns: columns)),
                    children: (0..<showCount).map { FocusNode(GridFocusIDs.show($0), kind: .leaf) },
                    carriesGridColumn: true
                )
            )
        }
        return FocusNode(GridFocusIDs.root, kind: .container(.vertical), children: sections)
    }

    private static func node(
        for focus: SearchResultGridFocus,
        movieCount: Int,
        showCount: Int
    ) -> FocusNodeID? {
        switch focus {
        case .movie(let index):
            guard index >= 0, index < movieCount else { return nil }
            return GridFocusIDs.movie(index)
        case .show(let index):
            guard index >= 0, index < showCount else { return nil }
            return GridFocusIDs.show(index)
        }
    }

    private static func gridFocus(for node: FocusNodeID) -> SearchResultGridFocus? {
        let raw = node.rawValue
        if raw.hasPrefix("search-result-movie:"),
           let index = Int(raw.dropFirst("search-result-movie:".count)) {
            return .movie(index)
        }
        if raw.hasPrefix("search-result-show:"),
           let index = Int(raw.dropFirst("search-result-show:".count)) {
            return .show(index)
        }
        return nil
    }

}

#if DEBUG
enum VerifySearchRemoteKeyboardHarness {
    static let launchArgument = "--verify-search-remote-keyboard"

    static func runIfRequested() {
        guard CommandLine.arguments.contains(launchArgument) else { return }

        do {
            let detail = try runScenario()
            FileHandle.standardError.write(Data("verify-search-remote-keyboard: PASS policy: \(detail)\n".utf8))
            FileHandle.standardError.write(Data("verify-search-remote-keyboard: outcome=verified passed=22/22\n".utf8))
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("verify-search-remote-keyboard: FAIL policy: \(error)\n".utf8))
            FileHandle.standardError.write(Data("verify-search-remote-keyboard: outcome=failed passed=0/22\n".utf8))
            exit(1)
        }
    }

    private static func runScenario() throws -> String {
        try verifyInitialFocus()
        try verifyTextEntry()
        try verifyNumericEntry()
        try verifyEditingActions()
        try verifyEdgeExits()
        try verifyRaggedVerticalClamp()
        try verifyRightEdgeStaysPut()
        try verifyDoneKeyExists()
        try verifyFieldFlow()
        try verifySuggestionFlow()
        try verifyCompletionFlow()
        try verifyDetailReturnFlow()
        try verifyResultExitFlow()
        try verifySearchResultReachability()
        try verifyResultGridNavigation()
        try verifyNativeSpacebarPassThrough()
        try verifyRemoteSelectOpensKeyboard()
        return "layout=\(RemoteSearchKeyboardPolicy.layout.count) rows"
    }

    private static func verifyInitialFocus() throws {
        let focus = RemoteSearchKeyboardPolicy.initialFocus()
        guard let key = RemoteSearchKeyboardPolicy.key(at: focus) else {
            throw HarnessError.assertion("initial focus did not resolve to a key")
        }
        guard key.title == "Q" else {
            throw HarnessError.assertion("initial focus should be Q, got \(key.title)")
        }
    }

    private static func verifyTextEntry() throws {
        let query = try type("KINGSMAN")
        guard query == "kingsman" || query == "KINGSMAN" else {
            throw HarnessError.assertion("expected kingsman query, got \(query)")
        }
    }

    private static func verifyNumericEntry() throws {
        let query = try type("1984")
        guard query == "1984" else {
            throw HarnessError.assertion("expected 1984 query, got \(query)")
        }
    }

    private static func verifyEditingActions() throws {
        let space = try key(titled: "Space")
        let delete = try key(titled: "Delete")
        let clear = try key(titled: "Clear")

        guard RemoteSearchKeyboardPolicy.applying(space, to: "king") == "king " else {
            throw HarnessError.assertion("space should append one space")
        }
        guard RemoteSearchKeyboardPolicy.applying(space, to: "king ") == "king " else {
            throw HarnessError.assertion("space should not append duplicate trailing spaces")
        }
        guard RemoteSearchKeyboardPolicy.applying(delete, to: "kings") == "king" else {
            throw HarnessError.assertion("delete should remove one character")
        }
        guard RemoteSearchKeyboardPolicy.applying(clear, to: "kingsman") == "" else {
            throw HarnessError.assertion("clear should empty text")
        }
    }

    private static func verifyEdgeExits() throws {
        guard RemoteSearchKeyboardPolicy.move(RemoteKeyboardFocus(row: 1, column: 0), command: .left) == .exit(.sidebar) else {
            throw HarnessError.assertion("left from left edge should exit to sidebar")
        }
        guard RemoteSearchKeyboardPolicy.move(RemoteKeyboardFocus(row: 0, column: 2), command: .up) == .exit(.field) else {
            throw HarnessError.assertion("up from top row should exit to field")
        }
        let actionRow = max(0, RemoteSearchKeyboardPolicy.layout.count - 1)
        guard RemoteSearchKeyboardPolicy.move(RemoteKeyboardFocus(row: actionRow, column: 0), command: .down) == .exit(.results) else {
            throw HarnessError.assertion("down from action row should exit to results")
        }
    }

    private static func verifyRaggedVerticalClamp() throws {
        guard RemoteSearchKeyboardPolicy.move(RemoteKeyboardFocus(row: 1, column: 9), command: .down) == .stay(RemoteKeyboardFocus(row: 2, column: 8)) else {
            throw HarnessError.assertion("vertical movement should clamp into shorter destination row")
        }
    }

    private static func verifyRightEdgeStaysPut() throws {
        let focus = RemoteKeyboardFocus(row: 3, column: 6)
        guard RemoteSearchKeyboardPolicy.move(focus, command: .right) == .stay(focus) else {
            throw HarnessError.assertion("right edge should stay on current key")
        }
    }

    private static func verifyDoneKeyExists() throws {
        _ = try key(titled: "Done")
    }

    private static func verifyFieldFlow() throws {
        guard RemoteSearchKeyboardFlowPolicy.fieldDestination(for: .down, preservesNativeSpacebar: false) == .keyboard else {
            throw HarnessError.assertion("field down should enter keyboard")
        }
        guard RemoteSearchKeyboardFlowPolicy.fieldDestination(for: .select, preservesNativeSpacebar: false) == .keyboard else {
            throw HarnessError.assertion("field select should enter keyboard")
        }
        guard RemoteSearchKeyboardFlowPolicy.fieldDestination(for: .left, preservesNativeSpacebar: false) == .sidebar else {
            throw HarnessError.assertion("field left should exit to sidebar")
        }
        guard RemoteSearchKeyboardFlowPolicy.fieldDestination(for: .right, preservesNativeSpacebar: false) == .results else {
            throw HarnessError.assertion("field right should enter results")
        }
    }

    private static func verifySuggestionFlow() throws {
        guard RemoteSearchKeyboardFlowPolicy.fieldDestination(for: .down, preservesNativeSpacebar: false, hasSuggestions: true) == .suggestions else {
            throw HarnessError.assertion("field down should enter visible suggestions before opening keyboard")
        }
        guard SearchSuggestionNavigationPolicy.destination(index: 0, count: 3, command: .down) == .suggestion(1) else {
            throw HarnessError.assertion("suggestion down should move one suggestion at a time")
        }
        guard SearchSuggestionNavigationPolicy.destination(index: 2, count: 3, command: .down) == .results else {
            throw HarnessError.assertion("down from last suggestion should move into results")
        }
        guard SearchSuggestionNavigationPolicy.destination(index: 1, count: 3, command: .select) == .applySuggestion(1) else {
            throw HarnessError.assertion("select should apply the focused suggestion")
        }
    }

    private static func verifyCompletionFlow() throws {
        guard RemoteSearchKeyboardFlowPolicy.completionDestination(hasResults: true) == .results else {
            throw HarnessError.assertion("done should prefer results when results exist")
        }
        guard RemoteSearchKeyboardFlowPolicy.completionDestination(hasResults: false) == .field else {
            throw HarnessError.assertion("done should return to field without results")
        }
    }

    private static func verifyDetailReturnFlow() throws {
        guard RemoteSearchKeyboardFlowPolicy.detailReturnDestination(canRestoreIdentity: true, hasFirstResult: true) == .restoredResult else {
            throw HarnessError.assertion("detail return should restore identity first")
        }
        guard RemoteSearchKeyboardFlowPolicy.detailReturnDestination(canRestoreIdentity: false, hasFirstResult: true) == .firstResult else {
            throw HarnessError.assertion("detail return should fall back to first result")
        }
        guard RemoteSearchKeyboardFlowPolicy.detailReturnDestination(canRestoreIdentity: false, hasFirstResult: false) == .field else {
            throw HarnessError.assertion("detail return should fall back to field without results")
        }
    }

    private static func verifyResultExitFlow() throws {
        guard RemoteSearchKeyboardFlowPolicy.resultExitDestination(keyboardVisible: true) == .keyboard else {
            throw HarnessError.assertion("result exit should return to visible keyboard")
        }
        guard RemoteSearchKeyboardFlowPolicy.resultExitDestination(keyboardVisible: false) == .field else {
            throw HarnessError.assertion("result exit should return to field when keyboard is hidden")
        }
    }

    private static func verifySearchResultReachability() throws {
        let hiddenMovieResults = SearchResultReachabilityState(
            visibleMovieCount: 0,
            visibleShowCount: 0,
            pendingMovieCount: 2,
            pendingShowCount: 1,
            resultsExpanded: false
        )
        guard SearchResultReachabilityPolicy.shouldExpandBeforeFocusingResults(hiddenMovieResults) else {
            throw HarnessError.assertion("remote entry should expand pending search results before focusing the grid")
        }
        guard SearchResultReachabilityPolicy.firstReachableResult(in: hiddenMovieResults) == .movie(0) else {
            throw HarnessError.assertion("remote entry should reach the first pending movie result even before expansion")
        }

        let hiddenShowResults = SearchResultReachabilityState(
            visibleMovieCount: 0,
            visibleShowCount: 0,
            pendingMovieCount: 0,
            pendingShowCount: 2,
            resultsExpanded: false
        )
        guard SearchResultReachabilityPolicy.shouldExpandBeforeFocusingResults(hiddenShowResults) else {
            throw HarnessError.assertion("remote entry should expand pending show results before focusing the grid")
        }
        guard SearchResultReachabilityPolicy.firstReachableResult(in: hiddenShowResults) == .show(0) else {
            throw HarnessError.assertion("remote entry should reach the first pending show result when no movies are present")
        }

        let visibleResults = SearchResultReachabilityState(
            visibleMovieCount: 1,
            visibleShowCount: 1,
            pendingMovieCount: 4,
            pendingShowCount: 4,
            resultsExpanded: false
        )
        guard SearchResultReachabilityPolicy.firstReachableResult(in: visibleResults) == .movie(0),
              !SearchResultReachabilityPolicy.shouldExpandBeforeFocusingResults(visibleResults) else {
            throw HarnessError.assertion("remote entry should focus already-visible results without forcing expansion")
        }
    }

    private static func verifyResultGridNavigation() throws {
        guard !SearchResultPlacementPolicy.shouldScroll(
            from: .movie(4),
            to: .movie(5),
            columnCount: 4
        ), SearchResultPlacementPolicy.shouldScroll(
            from: .movie(3),
            to: .movie(7),
            columnCount: 4
        ), SearchResultPlacementPolicy.shouldScroll(
            from: .movie(7),
            to: .show(3),
            columnCount: 4
        ) else {
            throw HarnessError.assertion("search placement must ignore same-row movement and place row/section changes")
        }
        guard SearchResultGridNavigationPolicy.destination(
            focus: .movie(4),
            command: .left,
            movieCount: 8,
            showCount: 3,
            columnCount: 4
        ) == .fieldOrKeyboard else {
            throw HarnessError.assertion("left from a visual row edge should escape directly to Search")
        }
        guard SearchResultGridNavigationPolicy.destination(
            focus: .movie(3),
            command: .right,
            movieCount: 8,
            showCount: 3,
            columnCount: 4
        ) == .stay else {
            throw HarnessError.assertion("right should not wrap into the next visual row")
        }
        guard SearchResultGridNavigationPolicy.destination(
            focus: .movie(0),
            command: .down,
            movieCount: 8,
            showCount: 3,
            columnCount: 4
        ) == .result(.movie(4)) else {
            throw HarnessError.assertion("movie down should move to the same visual column in the next movie row")
        }
        guard SearchResultGridNavigationPolicy.destination(
            focus: .movie(6),
            command: .down,
            movieCount: 8,
            showCount: 3,
            columnCount: 4
        ) == .result(.show(2)) else {
            throw HarnessError.assertion("movie down past the final movie row should enter shows at the same column")
        }
        guard SearchResultGridNavigationPolicy.destination(
            focus: .show(1),
            command: .up,
            movieCount: 8,
            showCount: 3,
            columnCount: 4
        ) == .result(.movie(5)) else {
            throw HarnessError.assertion("show up should return to the last movie row at the same column")
        }

        try verifySearchResultSectionTraversal()
    }

    /// Cross-section traversal for the results tree: the carried visual column,
    /// clamping into a shorter section, section order, and every vertical edge.
    private static func verifySearchResultSectionTraversal() throws {
        func moved(
            _ focus: SearchResultGridFocus,
            _ command: RemoteCommand,
            movies: Int,
            shows: Int,
            columns: Int = 4
        ) -> SearchResultGridDestination {
            SearchResultGridNavigationPolicy.destination(
                focus: focus,
                command: command,
                movieCount: movies,
                showCount: shows,
                columnCount: columns
            )
        }

        // A show in column N moving Up reaches the movie in the same visual
        // column of the last movie row, for every column of a full row.
        for column in 0..<4 {
            guard moved(.show(column), .up, movies: 8, shows: 4) == .result(.movie(4 + column)) else {
                throw HarnessError.assertion("show column \(column) Up did not carry into the same movie column")
            }
        }

        // And downward, movies carry their column into the shows section.
        for column in 0..<4 {
            guard moved(.movie(4 + column), .down, movies: 8, shows: 4) == .result(.show(column)) else {
                throw HarnessError.assertion("movie column \(column) Down did not carry into the same show column")
            }
        }

        // Clamping into a shorter section, in both directions.
        guard moved(.movie(7), .down, movies: 8, shows: 2) == .result(.show(1)) else {
            throw HarnessError.assertion("Down into a shorter show section should clamp to its last cell")
        }
        guard moved(.show(3), .up, movies: 6, shows: 4) == .result(.movie(5)) else {
            throw HarnessError.assertion("Up into a shorter final movie row should clamp to its last cell")
        }

        // Section order: shows never precede movies, so Up from the first movie
        // row escapes and Down from the last show row holds.
        guard moved(.movie(2), .up, movies: 8, shows: 4) == .fieldOrKeyboard else {
            throw HarnessError.assertion("Up from the first movie row should hand input back to Search")
        }
        guard moved(.show(3), .down, movies: 8, shows: 4) == .stay else {
            throw HarnessError.assertion("Down from the last show row should hold focus")
        }

        // Vertical edges with a section absent.
        guard moved(.show(1), .up, movies: 0, shows: 4) == .fieldOrKeyboard else {
            throw HarnessError.assertion("Up from shows with no movies should hand input back to Search")
        }
        guard moved(.movie(6), .down, movies: 8, shows: 0) == .stay else {
            throw HarnessError.assertion("Down from the last movie row with no shows should hold focus")
        }

        // A partial trailing movie row is skipped rather than stepped into.
        guard moved(.movie(3), .down, movies: 6, shows: 3) == .result(.show(2)) else {
            throw HarnessError.assertion("Down over a partial movie row should enter shows at the clamped column")
        }
        guard moved(.show(0), .down, movies: 6, shows: 3) == .stay else {
            throw HarnessError.assertion("Down in a partial trailing show row should hold focus")
        }

        // Within a section the column is preserved on full rows.
        guard moved(.movie(1), .down, movies: 8, shows: 4) == .result(.movie(5)),
              moved(.movie(5), .up, movies: 8, shows: 4) == .result(.movie(1)) else {
            throw HarnessError.assertion("in-section vertical movement should preserve the column")
        }
    }

    private static func verifyNativeSpacebarPassThrough() throws {
        guard RemoteSearchKeyboardFlowPolicy.fieldDestination(for: .select, preservesNativeSpacebar: true) == .passThrough else {
            throw HarnessError.assertion("native spacebar should keep text-field space insertion")
        }
    }

    private static func verifyRemoteSelectOpensKeyboard() throws {
        guard RemoteSearchKeyboardFlowPolicy.fieldDestination(for: .select, preservesNativeSpacebar: false) == .keyboard else {
            throw HarnessError.assertion("remote select should open keyboard from field focus")
        }
    }

    private static func type(_ titles: String) throws -> String {
        try titles.reduce(into: "") { text, character in
            text = RemoteSearchKeyboardPolicy.applying(try key(titled: String(character)), to: text)
        }
    }

    private static func key(titled title: String) throws -> RemoteSearchKeyboardKey {
        for row in RemoteSearchKeyboardPolicy.layout {
            if let key = row.first(where: { $0.title == title }) {
                return key
            }
        }
        throw HarnessError.assertion("missing key \(title)")
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
