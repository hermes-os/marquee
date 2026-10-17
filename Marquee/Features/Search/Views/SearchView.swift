import SwiftUI
import AppKit

// MARK: - Search View

struct SearchView: View {
    @ObservedObject var searchSession: SearchSession
    @ObservedObject var focusCoordinator: FocusCoordinator
    var isDetailPresented: Bool = false
    var sidebarRemoteFocused: Bool = false
    var onRemoteBackAtRoot: () -> Void = {}
    let onSelectMovie: (MediaItem) -> Void
    let onSelectShow: (String) -> Void

    @Environment(\.kidsMode) private var kidsMode
    @Environment(\.leanBackMode) private var leanBackMode
    @State private var searchText: String = ""
    @State private var selectedSuggestionIndex: Int = -1
    @State private var showSuggestions: Bool = false
    @State private var isSearchFieldFocused: Bool = false
    @State private var searchFocusRequestID: Int = 0
    @State private var searchFocusBurstID: Int = 0
    @State private var searchRemoteFocus: SearchRemoteFocus = .field
    @State private var remoteKeyboardPresented: Bool = false
    @State private var lastRemoteKeyboardFocus: RemoteKeyboardFocus = RemoteSearchKeyboardPolicy.initialFocus()
    @State private var lastActivatedResultIdentity: SearchResultFocus?
    @State private var searchResultsExpanded: Bool = false
    @State private var searchResultsExpansionID: Int = 0
    @State private var resultGridColumnCount: Int = 1
    @State private var isApplyingSuggestionSelection: Bool = false
    @State private var lastPlacedResultFocus: SearchResultFocus?
    @State private var pendingResultEntry: PendingResultEntry?
    @State private var remoteInteractionGeneration: UInt64 = 0

    private enum SearchRemoteFocus: Equatable {
        case inactive
        case field
        case suggestions(Int)
        case keyboard(RemoteKeyboardFocus)
        case results(SearchResultFocus)
    }

    private enum SearchResultFocus: Equatable {
        case movie(UUID)
        case show(String)
    }

    private enum ResultEntryFallback: Equatable {
        case field
        case suggestion(Int)
        case stay
    }

    private struct PendingResultEntry: Equatable {
        let generation: UInt64
        let query: String
        let fallback: ResultEntryFallback
        let interactionGeneration: UInt64
    }

    private enum SearchRemoteCommandSource {
        case localMonitor(keyCode: UInt16)
        case textFieldCommand
    }

    private var remoteResultFocus: SearchResultFocus? {
        guard case .results(let focus) = searchRemoteFocus else { return nil }
        return focus
    }

    private var remoteKeyboardFocus: RemoteKeyboardFocus? {
        guard case .keyboard(let focus) = searchRemoteFocus else { return nil }
        return focus
    }

    private var remoteSuggestionFocus: Int? {
        guard case .suggestions(let index) = searchRemoteFocus else { return nil }
        return index
    }

    private var isRemoteKeyboardVisible: Bool {
        remoteKeyboardPresented
    }

    private var rootFocusScrollID: String? {
        SearchRootFocusPlacementPolicy.scrollID(
            isFieldFocused: searchRemoteFocus == .field,
            isKeyboardFocused: remoteKeyboardFocus != nil
        )
    }

    private var resultMinimumCardWidth: CGFloat {
        MarqueeTheme.scaled(130, leanBack: 200, isLeanBack: leanBackMode)
    }

    private var resultHorizontalSpacing: CGFloat {
        MarqueeTheme.cardGap(isLeanBack: leanBackMode)
    }

    private var gridColumns: [GridItem] {
        [
            GridItem(
                .adaptive(minimum: resultMinimumCardWidth),
                spacing: resultHorizontalSpacing
            )
        ]
    }

    var body: some View {
        ZStack {
            (kidsMode ? MarqueeTheme.kidsBackground : MarqueeTheme.background).ignoresSafeArea()

            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: MarqueeTheme.sectionSpacing(isLeanBack: leanBackMode)) {
                        searchBarWithSuggestions
                            .id("search-field")
                        if isRemoteKeyboardVisible {
                            remoteSearchKeyboard
                                .id("search-remote-keyboard")
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                        resultsContent
                            .background(SearchResultsGridWidthReader())
                    }
                    .padding(.horizontal, MarqueeTheme.outerPadding(isLeanBack: leanBackMode))
                    .padding(.bottom, MarqueeTheme.outerPadding(isLeanBack: leanBackMode))
                }
                .onPreferenceChange(SearchResultsGridWidthPreferenceKey.self) { width in
                    let nextCount = SearchResultGridNavigationPolicy.columnCount(
                        availableWidth: width,
                        minimumCardWidth: resultMinimumCardWidth,
                        spacing: resultHorizontalSpacing
                    )
                    if nextCount != resultGridColumnCount {
                        resultGridColumnCount = nextCount
                    }
                }
                .onChange(of: remoteResultFocus) { focus in
                    let previousFocus = lastPlacedResultFocus
                    lastPlacedResultFocus = focus
                    guard let focus,
                          let currentGridFocus = gridFocus(for: focus),
                          SearchResultPlacementPolicy.shouldScroll(
                            from: previousFocus.flatMap { gridFocus(for: $0) },
                            to: currentGridFocus,
                            columnCount: resultGridColumnCount
                          ),
                          let scrollID = resultScrollID(for: focus) else { return }
                    RemoteProgrammaticScrollPolicy.perform(animated: true, duration: 0.22) {
                        proxy.scrollTo(scrollID, anchor: .center)
                    }
                }
                .onChange(of: rootFocusScrollID) { scrollID in
                    guard let scrollID else { return }
                    RemoteProgrammaticScrollPolicy.perform(animated: true, duration: 0.22) {
                        proxy.scrollTo(scrollID, anchor: .top)
                    }
                }
            }
        }
        .onAppear {
            _ = searchSession.request(query: searchText)
            if !isDetailPresented {
                applyBufferedSearchInput(stopCapture: false)
                enterFieldFocus()
            }
            MarqueeSignpost.event("route-appeared", "search")
            #if DEBUG
            NotificationCenter.default.post(name: .marqueeQARouteSurfaceAppeared, object: "search")
            #endif
        }
        .onChange(of: searchText) { newValue in
            selectedSuggestionIndex = -1
            showSuggestions = !newValue.trimmingCharacters(in: .whitespaces).isEmpty && !isRemoteKeyboardVisible
            if (remoteResultFocus != nil || remoteSuggestionFocus != nil), !isApplyingSuggestionSelection {
                searchRemoteFocus = .field
            }
            if pendingResultEntry?.query != newValue {
                pendingResultEntry = nil
            }
            searchResultsExpanded = false
            _ = searchSession.request(query: newValue)
        }
        .onChange(of: isDetailPresented) { detailPresented in
            if detailPresented {
                searchResultsExpansionID &+= 1
                searchResultsExpanded = false
                pendingResultEntry = nil
                enterInactiveFocus()
            } else {
                // Collapse first, then restore. A deep restored result may need
                // to expand immediately and must not be hidden again afterward.
                scheduleSearchResultsExpansion(for: searchSession.presentation)
                restoreRemoteFocusAfterDetailReturn()
            }
        }
        .onChange(of: sidebarRemoteFocused) { focused in
            if focused {
                enterInactiveFocus()
            } else if !isDetailPresented, searchRemoteFocus == .inactive {
                enterFieldFocus()
            }
        }
        .onReceive(searchSession.presentationUpdates) { snapshot in
            handleSearchPresentation(snapshot)
        }
        .onReceive(NotificationCenter.default.publisher(for: .marqueeFocusSearchField)) { _ in
            guard !isDetailPresented, !sidebarRemoteFocused else { return }
            applyBufferedSearchInput(stopCapture: false)
            enterFieldFocus()
        }
        .onReceive(NotificationCenter.default.publisher(for: .marqueeBufferedSearchInputChanged)) { _ in
            guard !isDetailPresented else { return }
            applyBufferedSearchInput(stopCapture: false)
        }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: .marqueeQAVisualTourFocusFirstSearchResult)) { _ in
            guard !isDetailPresented else { return }
            showSuggestions = false
            selectedSuggestionIndex = -1
            _ = focusFirstResult(fallback: .stay)
            recordQASearchSnapshot(reason: "focus-first-search-result")
        }
        .onReceive(NotificationCenter.default.publisher(for: .marqueeQASearchStateProbe)) { notification in
            let reason = notification.object as? String ?? "probe"
            recordQASearchSnapshot(reason: reason)
        }
        #endif
    }

    // MARK: - Search Bar with Suggestions

    private var searchBarWithSuggestions: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: MarqueeTheme.scaled(10, leanBack: 15, isLeanBack: leanBackMode)) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: MarqueeTheme.scaled(15, leanBack: 22, isLeanBack: leanBackMode), weight: .medium))
                    .foregroundColor(MarqueeTheme.textTertiary)

                SearchTextField(
                    text: $searchText,
                    isFocused: $isSearchFieldFocused,
                    focusRequestID: searchFocusRequestID,
                    placeholder: "Search movies, shows, cast...",
                    fontSize: MarqueeTheme.scaled(15, leanBack: 22, isLeanBack: leanBackMode),
                    onEditingStarted: handleSearchFieldEditingStarted,
                    onCommand: handleSearchFieldCommand
                )
                .frame(height: MarqueeTheme.scaled(22, leanBack: 32, isLeanBack: leanBackMode))

                if !searchText.isEmpty {
                    Button(action: {
                        searchText = ""
                        showSuggestions = false
                        enterFieldFocus()
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: MarqueeTheme.scaled(14, leanBack: 20, isLeanBack: leanBackMode)))
                            .foregroundColor(MarqueeTheme.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, MarqueeTheme.scaled(14, leanBack: 22, isLeanBack: leanBackMode))
            .padding(.vertical, MarqueeTheme.scaled(10, leanBack: 16, isLeanBack: leanBackMode))
            .background(
                RoundedRectangle(cornerRadius: showSuggestions && !suggestions.isEmpty ? 10 : 10)
                    .fill(MarqueeTheme.surfaceElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        isSearchFieldFocused ? MarqueeTheme.accentPrimary.opacity(0.5) : MarqueeTheme.textTertiary.opacity(0.3),
                        lineWidth: 1
                    )
            )

            if showSuggestions && !suggestions.isEmpty {
                suggestionsList
            }
        }
        .padding(.top, MarqueeTheme.scaled(32, leanBack: 48, isLeanBack: leanBackMode))
        .onAppear { installKeyMonitor() }
        .onDisappear {
            removeKeyMonitor()
        }
    }

    private var remoteSearchKeyboard: some View {
        let focusedKeyID = remoteKeyboardFocus.flatMap { RemoteSearchKeyboardPolicy.key(at: $0)?.id }
        return RemoteSearchKeyboardView(
            focusedKeyID: focusedKeyID,
            onPress: applyRemoteKeyboardKey
        )
    }

    @State private var keyMonitor: Any?

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let keyEvent = MarqueeKeyEvent(event)
            let capturesTyping = SearchInputOwnershipPolicy.capturesPhysicalTyping(owner: focusCoordinator.owner)
            if isRemoteKeyboardVisible, capturesTyping, handleKeyboardVisiblePhysicalEdit(event) {
                return nil
            }
            if isRemoteKeyboardVisible, capturesTyping, keyEvent.key == nil, captureUnfocusedSearchText(event) {
                return nil
            }

            guard let command = keyEvent.key?.remoteCommand else { return event }
            let consumed = handleSearchRemoteCommand(command, source: .localMonitor(keyCode: event.keyCode))
            recordQASearchSnapshot(reason: "remote-\(command)", consumedCommand: consumed)
            return consumed ? nil : event
        }
    }

    private func handleSearchRemoteCommand(_ command: RemoteCommand, source: SearchRemoteCommandSource) -> Bool {
        guard SearchInputOwnershipPolicy.consumesRemoteCommands(owner: focusCoordinator.owner) else { return false }

        // A later explicit command supersedes any delayed result-entry intent.
        // A command that requests results records this new generation below.
        remoteInteractionGeneration = SearchPendingResultEntryPolicy
            .nextInteractionGeneration(after: remoteInteractionGeneration)
        let previousFocus = searchRemoteFocus
        let consumed: Bool
        switch searchRemoteFocus {
        case .inactive:
            consumed = false
        case .field:
            consumed = handleFieldRemoteCommand(command, source: source)
        case .suggestions(let index):
            consumed = handleRemoteSuggestionCommand(command, index: index)
        case .keyboard(let focus):
            consumed = handleKeyboardRemoteCommand(command, focus: focus)
        case .results:
            consumed = handleRemoteResultCommand(command)
        }

        if consumed {
            let didNavigate = searchRemoteFocus != previousFocus
            AudioIdentityService.shared.playFeedback(
                for: command,
                didNavigate: didNavigate,
                didReachBoundary: command != .select && command != .back && !didNavigate
            )
        }
        return consumed
    }

    private func handleFieldRemoteCommand(_ command: RemoteCommand, source: SearchRemoteCommandSource) -> Bool {
        let preservesNativeSpacebar: Bool = {
            guard command == .select else { return false }
            guard case .localMonitor(let keyCode) = source else { return false }
            return keyCode == 49
        }()

        switch RemoteSearchKeyboardFlowPolicy.fieldDestination(
            for: command,
            preservesNativeSpacebar: preservesNativeSpacebar,
            hasSuggestions: hasVisibleSuggestions
        ) {
        case .keyboard:
            enterKeyboardFocus(resetToInitial: true)
            return true
        case .suggestions:
            enterSuggestionFocus(0)
            return true
        case .results:
            showSuggestions = false
            selectedSuggestionIndex = -1
            return focusFirstResult(fallback: .field)
        case .sidebar:
            enterInactiveFocus()
            onRemoteBackAtRoot()
            return true
        case .passThrough:
            return false
        }
    }

    private func handleKeyboardRemoteCommand(_ command: RemoteCommand, focus: RemoteKeyboardFocus) -> Bool {
        switch command {
        case .back:
            enterFieldFocus()
        case .select:
            guard let key = RemoteSearchKeyboardPolicy.key(at: focus) else { return true }
            applyRemoteKeyboardKey(key)
        case .left, .right, .up, .down:
            switch RemoteSearchKeyboardPolicy.move(focus, command: command) {
            case .stay(let nextFocus):
                setKeyboardFocus(nextFocus)
            case .exit(.field):
                enterFieldFocus()
            case .exit(.sidebar):
                enterInactiveFocus()
                onRemoteBackAtRoot()
            case .exit(.results):
                _ = focusFirstResult(fallback: .field)
            }
        }
        return true
    }

    private func handleRemoteSuggestionCommand(_ command: RemoteCommand, index: Int) -> Bool {
        switch SearchSuggestionNavigationPolicy.destination(
            index: index,
            count: suggestions.count,
            command: command
        ) {
        case .suggestion(let nextIndex):
            setSuggestionFocus(nextIndex)
        case .applySuggestion(let suggestionIndex):
            applySuggestion(at: suggestionIndex, focusResults: true)
        case .field:
            enterFieldFocus()
        case .results:
            if !focusFirstResult(fallback: .suggestion(index)) {
                setSuggestionFocus(index)
            }
        case .sidebar:
            enterInactiveFocus()
            onRemoteBackAtRoot()
        case .stay:
            setSuggestionFocus(index)
        }
        return true
    }

    private func applyRemoteKeyboardKey(_ key: RemoteSearchKeyboardKey) {
        switch key.kind {
        case .done:
            remoteKeyboardPresented = false
            showSuggestions = false
            selectedSuggestionIndex = -1
            if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                enterFieldFocus()
            } else {
                _ = focusFirstResult(fallback: .field)
            }
        default:
            searchText = RemoteSearchKeyboardPolicy.applying(key, to: searchText)
            remoteKeyboardPresented = true
            showSuggestions = false
            selectedSuggestionIndex = -1
            if let focus = remoteKeyboardFocus {
                setKeyboardFocus(focus)
            } else {
                enterKeyboardFocus()
            }
        }
    }

    private func captureUnfocusedSearchText(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }

        let reservedModifiers: NSEvent.ModifierFlags = [.command, .control, .option]
        guard event.modifierFlags.intersection(reservedModifiers).isEmpty else { return false }

        switch Int(event.keyCode) {
        case 36, 53, 123, 124, 125, 126:
            return false
        default:
            break
        }

        guard let characters = event.characters,
              characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            return false
        }

        SearchInputBuffer.shared.beginCapture()
        guard SearchInputBuffer.shared.capture(event) else { return false }
        applyBufferedSearchInput(stopCapture: false)
        enterFieldFocus()
        return true
    }

    private func handleKeyboardVisiblePhysicalEdit(_ event: NSEvent) -> Bool {
        switch SearchKeyboardVisiblePhysicalEditPolicy.outcome(for: event, currentText: searchText) {
        case .applyText(let updatedText):
            SearchInputBuffer.shared.stopCapture()
            searchText = updatedText
            enterFieldFocus()
            return true
        case .passThrough:
            return false
        }
    }

    private func handleSearchFieldCommand(_ commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveUp(_:)):
            return handleSearchRemoteCommand(.up, source: .textFieldCommand)
        case #selector(NSResponder.moveDown(_:)):
            return handleSearchRemoteCommand(.down, source: .textFieldCommand)
        case #selector(NSResponder.moveRight(_:)):
            return handleSearchRemoteCommand(.right, source: .textFieldCommand)
        case #selector(NSResponder.moveLeft(_:)):
            return handleSearchRemoteCommand(.left, source: .textFieldCommand)
        case #selector(NSResponder.insertNewline(_:)):
            return handleSearchRemoteCommand(.select, source: .textFieldCommand)
        case #selector(NSResponder.cancelOperation(_:)):
            return handleSearchRemoteCommand(.back, source: .textFieldCommand)
        default:
            return false
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    private func handleRemoteResultCommand(_ command: RemoteCommand) -> Bool {
        switch command {
        case .left:
            moveRemoteResultFocus(command: command)
        case .right:
            moveRemoteResultFocus(command: command)
        case .up:
            moveRemoteResultFocus(command: command)
        case .down:
            moveRemoteResultFocus(command: command)
        case .select:
            activateRemoteResultFocus()
        case .back:
            switch RemoteSearchKeyboardFlowPolicy.resultExitDestination(keyboardVisible: remoteKeyboardPresented) {
            case .keyboard:
                enterKeyboardFocus()
            case .field:
                enterFieldFocus()
            }
        }
        return true
    }

    // MARK: - Suggestions

    private var suggestions: [String] {
        let presentation = searchSession.presentation
        guard presentation.phase == .ready,
              presentation.query == searchText else { return [] }
        return presentation.suggestions
    }

    private var hasVisibleSuggestions: Bool {
        showSuggestions && !suggestions.isEmpty
    }

    private var shouldPreserveSuggestionsDuringResultPublish: Bool {
        guard !isApplyingSuggestionSelection, !isRemoteKeyboardVisible else { return false }
        return searchRemoteFocus == .field || remoteSuggestionFocus != nil
    }

    private var suggestionsList: some View {
        let focusedSuggestionIndex = remoteSuggestionFocus ?? selectedSuggestionIndex
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.offset) { index, suggestion in
                Button(action: {
                    applySuggestion(at: index, focusResults: false)
                }) {
                    HStack(spacing: MarqueeTheme.scaled(10, leanBack: 15, isLeanBack: leanBackMode)) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: MarqueeTheme.scaled(11, leanBack: 16, isLeanBack: leanBackMode), weight: .medium))
                            .foregroundColor(MarqueeTheme.textTertiary)

                        Text(suggestion)
                            .font(.system(size: MarqueeTheme.scaled(13, leanBack: 19, isLeanBack: leanBackMode), weight: .regular))
                            .foregroundColor(MarqueeTheme.textPrimary)
                            .lineLimit(1)

                        Spacer()
                    }
                    .padding(.horizontal, MarqueeTheme.scaled(14, leanBack: 22, isLeanBack: leanBackMode))
                    .padding(.vertical, MarqueeTheme.scaled(8, leanBack: 13, isLeanBack: leanBackMode))
                    .background(
                        index == focusedSuggestionIndex
                            ? MarqueeTheme.accentPrimary.opacity(0.15)
                            : Color.clear
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .background(MarqueeTheme.surfaceLayer)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.top, 4)
    }

    private func applySuggestion(at index: Int, focusResults: Bool) {
        guard suggestions.indices.contains(index) else { return }
        let suggestion = suggestions[index]
        isApplyingSuggestionSelection = true
        searchText = suggestion
        showSuggestions = false
        selectedSuggestionIndex = -1

        if focusResults {
            _ = focusFirstResult(fallback: .field)
        } else {
            _ = searchSession.request(query: suggestion, immediate: true)
        }

        DispatchQueue.main.async {
            isApplyingSuggestionSelection = false
        }
    }

    private func handleSearchFieldEditingStarted() {
        remoteKeyboardPresented = false
        searchRemoteFocus = .field
        showSuggestions = !searchText.trimmingCharacters(in: .whitespaces).isEmpty
        selectedSuggestionIndex = -1
    }

    private func enterFieldFocus() {
        remoteKeyboardPresented = false
        searchRemoteFocus = .field
        showSuggestions = !searchText.trimmingCharacters(in: .whitespaces).isEmpty
        selectedSuggestionIndex = -1
        focusSearchField()
    }

    private func enterKeyboardFocus(resetToInitial: Bool = false) {
        let focus = resetToInitial
            ? RemoteSearchKeyboardPolicy.initialFocus()
            : (remoteKeyboardFocus ?? lastRemoteKeyboardFocus)
        setKeyboardFocus(focus)
        showSuggestions = false
        selectedSuggestionIndex = -1
        SearchInputBuffer.shared.stopCapture()
        SearchInputBuffer.shared.setSearchFieldEditing(false)
    }

    private func enterSuggestionFocus(_ index: Int) {
        setSuggestionFocus(index)
    }

    private func enterInactiveFocus() {
        // Leaving Search supersedes any queued Done/Down/Right result entry.
        // A later ready snapshot must not reclaim focus from the sidebar.
        pendingResultEntry = nil
        leaveSearchFieldFocus()
        remoteKeyboardPresented = false
        searchRemoteFocus = .inactive
        showSuggestions = false
        selectedSuggestionIndex = -1
        SearchInputBuffer.shared.stopCapture()
        SearchInputBuffer.shared.setSearchFieldEditing(false)
    }

    private func setKeyboardFocus(_ focus: RemoteKeyboardFocus) {
        leaveSearchFieldFocus()
        lastRemoteKeyboardFocus = focus
        remoteKeyboardPresented = true
        searchRemoteFocus = .keyboard(focus)
    }

    private func setSuggestionFocus(_ index: Int) {
        guard !suggestions.isEmpty else {
            enterFieldFocus()
            return
        }
        leaveSearchFieldFocus()
        remoteKeyboardPresented = false
        let clamped = min(max(0, index), suggestions.count - 1)
        searchRemoteFocus = .suggestions(clamped)
        showSuggestions = true
        selectedSuggestionIndex = clamped
        SearchInputBuffer.shared.stopCapture()
        SearchInputBuffer.shared.setSearchFieldEditing(false)
    }

    private func setResultFocus(_ focus: SearchResultFocus) {
        leaveSearchFieldFocus()
        searchRemoteFocus = .results(focus)
        showSuggestions = false
        selectedSuggestionIndex = -1
        SearchInputBuffer.shared.setSearchFieldEditing(false)
    }

    private func leaveSearchFieldFocus() {
        searchFocusBurstID &+= 1
        isSearchFieldFocused = false
    }

    private func focusSearchField() {
        let needsRetryBurst = !isSearchFieldFocused
        searchFocusBurstID &+= 1
        let burstID = searchFocusBurstID
        isSearchFieldFocused = true
        searchFocusRequestID &+= 1
        guard needsRetryBurst else { return }

        for delay in SearchFocusPolicy.retryDelays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard SearchFocusRetryPolicy.shouldApplyRetry(
                    owner: focusCoordinator.owner,
                    isFieldOwner: searchRemoteFocus == .field,
                    burstMatches: burstID == searchFocusBurstID
                ) else { return }
                isSearchFieldFocused = true
                searchFocusRequestID &+= 1
            }
        }
    }

    private func applyBufferedSearchInput(stopCapture: Bool) {
        let bufferedText = stopCapture ? SearchInputBuffer.shared.drain() : SearchInputBuffer.shared.currentText
        guard !bufferedText.isEmpty else { return }
        if searchText != bufferedText {
            searchText = bufferedText
        }
    }

    private func handleSearchPresentation(_ snapshot: SearchPresentationSnapshot) {
        guard snapshot.query == searchText else { return }

        switch snapshot.phase {
        case .empty:
            searchResultsExpansionID &+= 1
            searchResultsExpanded = false
            showSuggestions = false
            selectedSuggestionIndex = -1
            if pendingResultEntry?.generation == snapshot.generation {
                let fallback = pendingResultEntry?.fallback ?? .stay
                pendingResultEntry = nil
                applyResultEntryFallback(fallback)
            }
        case .pending:
            searchResultsExpansionID &+= 1
            searchResultsExpanded = false
            showSuggestions = false
            selectedSuggestionIndex = -1
            if let intent = pendingResultEntry,
               intent.query == snapshot.query,
               intent.generation != snapshot.generation {
                pendingResultEntry = PendingResultEntry(
                    generation: snapshot.generation,
                    query: intent.query,
                    fallback: intent.fallback,
                    interactionGeneration: intent.interactionGeneration
                )
            }
        case .ready:
            if shouldPreserveSuggestionsDuringResultPublish {
                showSuggestions = !snapshot.suggestions.isEmpty
                if !showSuggestions {
                    selectedSuggestionIndex = -1
                }
            } else {
                showSuggestions = false
                selectedSuggestionIndex = -1
            }

            preheatFirstPaintArtwork(snapshot.results, snapshot: snapshot)
            scheduleSearchResultsExpansion(for: snapshot)
            reconcileResultFocus(with: snapshot.results)
            fulfillPendingResultEntry(with: snapshot)

            #if DEBUG
            NotificationCenter.default.post(
                name: .marqueeQASearchResultsPublished,
                object: QASearchPublicationEvidence(
                    resultCount: snapshot.results.totalCount,
                    publishedAt: Date()
                )
            )
            #endif
        }
    }

    private func preheatFirstPaintArtwork(
        _ results: BrowseSearchResults,
        snapshot: SearchPresentationSnapshot
    ) {
        let firstMovieResults = Array(results.movies.prefix(SearchResultRenderPolicy.firstPaintMovieLimit))
        let firstShowResults = Array(results.shows.prefix(SearchResultRenderPolicy.firstPaintShowLimit))
        let moviePaths = firstMovieResults.map { $0.item.gridPosterPath }
        let showPaths = firstShowResults.map { $0.item.gridShowPosterPath }
        let pixelSize = leanBackMode
            ? ArtworkCache.leanBackPosterThumbnailPixelSize
            : ArtworkCache.gridPosterThumbnailPixelSize
        ArtworkCache.shared.preloadVisiblePosters(
            paths: moviePaths + showPaths,
            pixelSize: pixelSize,
            label: "search"
        )

        let detailBackdropPaths = firstMovieResults.map { $0.item.displayBackdropPath }
            + firstShowResults.map { $0.item.displayShowBackdropPath }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
            let current = searchSession.presentation
            guard current.phase == .ready,
                  current.generation == snapshot.generation,
                  current.indexRevision == snapshot.indexRevision else { return }
            ArtworkCache.shared.preloadVisiblePosters(
                paths: detailBackdropPaths,
                pixelSize: ArtworkCache.heroBackdropThumbnailPixelSize,
                label: "search-detail-backdrop"
            )
        }
    }

    private func scheduleSearchResultsExpansion(for snapshot: SearchPresentationSnapshot) {
        searchResultsExpansionID &+= 1
        let expansionID = searchResultsExpansionID
        searchResultsExpanded = false
        let normalizedQuery = snapshot.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard snapshot.phase == .ready,
              !normalizedQuery.isEmpty,
              !isDetailPresented else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + SearchResultRenderPolicy.expansionDelay) {
            guard expansionID == searchResultsExpansionID else { return }
            let current = searchSession.presentation
            guard current.phase == .ready,
                  current.generation == snapshot.generation,
                  current.indexRevision == snapshot.indexRevision else { return }
            guard !isDetailPresented else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                searchResultsExpanded = true
            }
        }
    }

    // MARK: - Results Content

    private var trimmedQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var currentResults: BrowseSearchResults {
        let presentation = searchSession.presentation
        guard presentation.phase == .ready,
              presentation.query == searchText else { return .empty }
        return presentation.results
    }

    private var visibleMovieResults: [BrowseSearchHit] {
        visibleMovieResults(in: currentResults)
    }

    private var visibleShowResults: [BrowseShowSearchHit] {
        visibleShowResults(in: currentResults)
    }

    private var hasFirstVisibleResult: Bool {
        !visibleMovieResults.isEmpty || !visibleShowResults.isEmpty
    }

    private func visibleMovieResults(in results: BrowseSearchResults) -> [BrowseSearchHit] {
        Array(results.movies.prefix(searchResultsExpanded ? SearchResultRenderPolicy.expandedMovieLimit : SearchResultRenderPolicy.firstPaintMovieLimit))
    }

    private func visibleShowResults(in results: BrowseSearchResults) -> [BrowseShowSearchHit] {
        Array(results.shows.prefix(searchResultsExpanded ? SearchResultRenderPolicy.expandedShowLimit : SearchResultRenderPolicy.firstPaintShowLimit))
    }

    @ViewBuilder
    private var resultsContent: some View {
        let query = trimmedQuery
        if query.isEmpty {
            searchLandingState
        } else {
            let presentation = searchSession.presentation
            if presentation.query != searchText || presentation.phase == .pending {
                searchPendingState(query: query)
            } else if presentation.phase == .ready, presentation.results.totalCount == 0 {
                emptyState(query: query)
            } else if presentation.phase == .ready {
                let searchResults = presentation.results
                let totalCount = searchResults.totalCount
                VStack(alignment: .leading, spacing: MarqueeTheme.sectionSpacing(isLeanBack: leanBackMode)) {
                    resultsCountLabel(count: totalCount, query: query)

                    let movieResults = visibleMovieResults(in: searchResults)
                    if !searchResults.movies.isEmpty {
                        movieResultsSection(
                            title: "MOVIES",
                            results: movieResults
                        )
                    }

                    let showResults = visibleShowResults(in: searchResults)
                    if !searchResults.shows.isEmpty {
                        showResultsSection(
                            title: "TV SHOWS",
                            results: showResults
                        )
                    }
                }
            } else {
                searchLandingState
            }
        }
    }

    // MARK: - Results Count

    private func resultsCountLabel(count: Int, query: String) -> some View {
        Text("\(count) result\(count == 1 ? "" : "s") for '\(query)'")
            .font(.system(size: MarqueeTheme.scaled(12, leanBack: 17, isLeanBack: leanBackMode)))
            .foregroundColor(MarqueeTheme.textTertiary)
    }

    // MARK: - Results Section

    private func movieResultsSection(
        title: String,
        results: [BrowseSearchHit]
    ) -> some View {
        VStack(alignment: .leading, spacing: MarqueeTheme.sectionHeaderToContent(isLeanBack: leanBackMode)) {
            SectionHeader(title: title)

            LazyVGrid(columns: gridColumns, alignment: .leading, spacing: MarqueeTheme.scaled(MarqueeTheme.spacingMD, leanBack: 24, isLeanBack: leanBackMode)) {
                ForEach(results, id: \.item.id) { result in
                    movieResultCard(result: result)
                        .id(SearchResultScrollIdentity.movie(
                            generation: searchSession.presentation.generation,
                            itemID: result.item.id
                        ))
                }
            }
        }
    }

    private func showResultsSection(
        title: String,
        results: [BrowseShowSearchHit]
    ) -> some View {
        VStack(alignment: .leading, spacing: MarqueeTheme.sectionHeaderToContent(isLeanBack: leanBackMode)) {
            SectionHeader(title: title)

            LazyVGrid(columns: gridColumns, alignment: .leading, spacing: MarqueeTheme.scaled(MarqueeTheme.spacingMD, leanBack: 24, isLeanBack: leanBackMode)) {
                ForEach(results, id: \.showName) { result in
                    showResultCard(result: result)
                        .id(SearchResultScrollIdentity.show(
                            generation: searchSession.presentation.generation,
                            showName: result.showName
                        ))
                }
            }
        }
    }

    // MARK: - Movie Result Card

    private func movieResultCard(result: BrowseSearchHit) -> some View {
        SearchResultCardView(
            posterPath: result.item.gridPosterPath,
            title: result.item.displayTitle,
            subtitle: movieSubtitle(for: result.item),
            matchType: result.matchType,
            matchDetail: result.matchDetail,
            isRemoteFocused: remoteResultFocus == .movie(result.item.id),
            onSelect: { onSelectMovie(result.item) }
        )
    }

    // MARK: - Show Result Card

    private func showResultCard(result: BrowseShowSearchHit) -> some View {
        SearchResultCardView(
            posterPath: result.item.gridShowPosterPath,
            title: result.showName,
            subtitle: "\(result.seasonCount) Season\(result.seasonCount == 1 ? "" : "s")",
            matchType: result.matchType,
            matchDetail: result.matchDetail,
            isRemoteFocused: remoteResultFocus == .show(result.showName),
            fallbackSystemImage: "tv.fill",
            onSelect: { onSelectShow(result.showName) }
        )
    }

    // MARK: - Remote Result Navigation

    @discardableResult
    private func focusFirstResult(fallback: ResultEntryFallback) -> Bool {
        let query = searchText
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            applyResultEntryFallback(fallback)
            return false
        }

        let presentation = searchSession.presentation
        if presentation.phase == .ready, presentation.query == query {
            pendingResultEntry = nil
            guard focusFirstReadyResult() else {
                applyResultEntryFallback(fallback)
                return false
            }
            return true
        }

        prepareVisibleFocusForPendingResultEntry()
        let generation = searchSession.request(query: query, immediate: true)
        pendingResultEntry = PendingResultEntry(
            generation: generation,
            query: query,
            fallback: fallback,
            interactionGeneration: remoteInteractionGeneration
        )
        fulfillPendingResultEntry(with: searchSession.presentation)
        return true
    }

    private func prepareVisibleFocusForPendingResultEntry() {
        switch SearchPendingResultFocusPolicy.destination(
            keyboardPresented: remoteKeyboardPresented,
            hasKeyboardFocus: remoteKeyboardFocus != nil
        ) {
        case .keyboard:
            showSuggestions = false
            selectedSuggestionIndex = -1
        case .field:
            enterFieldFocus()
            showSuggestions = false
            selectedSuggestionIndex = -1
        }
    }

    @discardableResult
    private func focusFirstReadyResult() -> Bool {
        let state = SearchResultReachabilityState(
            visibleMovieCount: visibleMovieResults.count,
            visibleShowCount: visibleShowResults.count,
            pendingMovieCount: currentResults.movies.count,
            pendingShowCount: currentResults.shows.count,
            resultsExpanded: searchResultsExpanded
        )
        guard let focus = SearchResultReachabilityPolicy.firstReachableResult(in: state) else {
            return false
        }
        if SearchResultReachabilityPolicy.shouldExpandBeforeFocusingResults(state) {
            searchResultsExpansionID &+= 1
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                searchResultsExpanded = true
            }
        }
        guard let stableFocus = searchResultFocus(for: focus) else { return false }
        setResultFocus(stableFocus)
        return true
    }

    private func activateRemoteResultFocus() {
        guard let focus = remoteResultFocus else { return }

        switch focus {
        case .movie(let itemID):
            guard let result = visibleMovieResults.first(where: { $0.item.id == itemID }) else { return }
            lastActivatedResultIdentity = focus
            onSelectMovie(result.item)
        case .show(let showName):
            guard visibleShowResults.contains(where: { $0.showName == showName }) else { return }
            lastActivatedResultIdentity = focus
            onSelectShow(showName)
        }
    }

    private func moveRemoteResultFocus(command: RemoteCommand) {
        guard let focus = remoteResultFocus,
              let currentGridFocus = gridFocus(for: focus) else {
            _ = focusFirstResult(fallback: .field)
            return
        }

        let destination = SearchResultGridNavigationPolicy.destination(
            focus: currentGridFocus,
            command: command,
            movieCount: visibleMovieResults.count,
            showCount: visibleShowResults.count,
            columnCount: resultGridColumnCount
        )

        switch destination {
        case .result(let nextFocus):
            if let stableFocus = searchResultFocus(for: nextFocus) {
                setResultFocus(stableFocus)
            }
        case .fieldOrKeyboard:
            switch RemoteSearchKeyboardFlowPolicy.resultExitDestination(keyboardVisible: remoteKeyboardPresented) {
            case .keyboard:
                enterKeyboardFocus()
            case .field:
                enterFieldFocus()
            }
        case .sidebar:
            enterInactiveFocus()
            onRemoteBackAtRoot()
        case .stay:
            break
        }
    }

    private func gridFocus(for focus: SearchResultFocus) -> SearchResultGridFocus? {
        switch focus {
        case .movie(let itemID):
            guard let index = visibleMovieResults.firstIndex(where: { $0.item.id == itemID }) else { return nil }
            return .movie(index)
        case .show(let showName):
            guard let index = visibleShowResults.firstIndex(where: { $0.showName == showName }) else { return nil }
            return .show(index)
        }
    }

    private func searchResultFocus(for focus: SearchResultGridFocus) -> SearchResultFocus? {
        switch focus {
        case .movie(let index):
            guard visibleMovieResults.indices.contains(index) else { return nil }
            return .movie(visibleMovieResults[index].item.id)
        case .show(let index):
            guard visibleShowResults.indices.contains(index) else { return nil }
            return .show(visibleShowResults[index].showName)
        }
    }

    private func resultScrollID(for focus: SearchResultFocus) -> String? {
        let generation = searchSession.presentation.generation
        switch focus {
        case .movie(let itemID):
            guard visibleMovieResults.contains(where: { $0.item.id == itemID }) else { return nil }
            return SearchResultScrollIdentity.movie(
                generation: generation,
                itemID: itemID
            )
        case .show(let showName):
            guard visibleShowResults.contains(where: { $0.showName == showName }) else { return nil }
            return SearchResultScrollIdentity.show(
                generation: generation,
                showName: showName
            )
        }
    }

    private func focusResult(with identity: SearchResultFocus) -> Bool {
        if !canFocusVisibleResult(with: identity) {
            guard canFocusResult(with: identity) else { return false }
            expandResultsImmediately()
        }
        guard canFocusVisibleResult(with: identity) else { return false }
        setResultFocus(identity)
        return true
    }

    private func canFocusResult(with identity: SearchResultFocus) -> Bool {
        switch identity {
        case .movie(let itemID):
            return currentResults.movies.contains(where: { $0.item.id == itemID })
        case .show(let showName):
            return currentResults.shows.contains(where: { $0.showName == showName })
        }
    }

    private func canFocusVisibleResult(with identity: SearchResultFocus) -> Bool {
        switch identity {
        case .movie(let itemID):
            return visibleMovieResults.contains(where: { $0.item.id == itemID })
        case .show(let showName):
            return visibleShowResults.contains(where: { $0.showName == showName })
        }
    }

    private func restoreRemoteFocusAfterDetailReturn() {
        let canRestoreIdentity = lastActivatedResultIdentity.map { canFocusResult(with: $0) } ?? false
        switch RemoteSearchKeyboardFlowPolicy.detailReturnDestination(
            canRestoreIdentity: canRestoreIdentity,
            hasFirstResult: hasFirstVisibleResult
        ) {
        case .restoredResult:
            if let identity = lastActivatedResultIdentity {
                _ = focusResult(with: identity)
            }
        case .firstResult:
            _ = focusFirstResult(fallback: .field)
        case .field:
            enterFieldFocus()
        }
        recordQASearchSnapshot(reason: "detail-return")
    }

    private func reconcileResultFocus(with results: BrowseSearchResults) {
        guard let focus = remoteResultFocus else { return }
        let remainsAvailable: Bool
        switch focus {
        case .movie(let itemID):
            remainsAvailable = results.movies.contains(where: { $0.item.id == itemID })
        case .show(let showName):
            remainsAvailable = results.shows.contains(where: { $0.showName == showName })
        }

        if remainsAvailable {
            if !canFocusVisibleResult(with: focus) {
                expandResultsImmediately()
            }
        } else if pendingResultEntry == nil {
            enterFieldFocus()
        }
    }

    private func fulfillPendingResultEntry(with snapshot: SearchPresentationSnapshot) {
        let intent = pendingResultEntry
        guard SearchPendingResultEntryPolicy.shouldFulfill(
            hasPendingIntent: intent != nil,
            searchFocusIsActive: searchRemoteFocus != .inactive,
            intentInteractionGeneration: intent?.interactionGeneration,
            currentInteractionGeneration: remoteInteractionGeneration
        ) else {
            pendingResultEntry = nil
            return
        }
        guard let intent,
              snapshot.phase == .ready,
              snapshot.generation == intent.generation,
              snapshot.query == intent.query else { return }
        pendingResultEntry = nil
        if !focusFirstReadyResult() {
            applyResultEntryFallback(intent.fallback)
        }
    }

    private func applyResultEntryFallback(_ fallback: ResultEntryFallback) {
        switch fallback {
        case .field:
            enterFieldFocus()
        case .suggestion(let index):
            if suggestions.indices.contains(index) {
                setSuggestionFocus(index)
            } else {
                enterFieldFocus()
            }
        case .stay:
            break
        }
    }

    private func expandResultsImmediately() {
        searchResultsExpansionID &+= 1
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            searchResultsExpanded = true
        }
    }

    // MARK: - Empty State

    private var searchLandingState: some View {
        VStack(spacing: MarqueeTheme.scaled(18, leanBack: 28, isLeanBack: leanBackMode)) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: MarqueeTheme.scaled(34, leanBack: 50, isLeanBack: leanBackMode), weight: .light))
                .foregroundStyle(MarqueeTheme.titleGradient)

            VStack(spacing: MarqueeTheme.scaled(6, leanBack: 10, isLeanBack: leanBackMode)) {
                Text("Search your library")
                    .font(.system(size: MarqueeTheme.scaled(17, leanBack: 25, isLeanBack: leanBackMode), weight: .semibold))
                    .foregroundColor(MarqueeTheme.textPrimary)

                Text("Titles, shows, episodes, cast, directors, genres, years, and filenames.")
                    .font(.system(size: MarqueeTheme.scaled(13, leanBack: 19, isLeanBack: leanBackMode)))
                    .foregroundColor(MarqueeTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }

            HStack(spacing: MarqueeTheme.scaled(8, leanBack: 12, isLeanBack: leanBackMode)) {
                ForEach(["Alien", "Thriller", "Ridley"], id: \.self) { sample in
                    Button(action: {
                        searchText = sample
                        _ = searchSession.request(query: sample, immediate: true)
                        showSuggestions = false
                        enterFieldFocus()
                    }) {
                        Text(sample)
                            .font(.system(size: MarqueeTheme.scaled(12, leanBack: 18, isLeanBack: leanBackMode), weight: .medium))
                            .foregroundColor(MarqueeTheme.textSecondary)
                            .padding(.horizontal, MarqueeTheme.scaled(12, leanBack: 18, isLeanBack: leanBackMode))
                            .padding(.vertical, MarqueeTheme.scaled(6, leanBack: 9, isLeanBack: leanBackMode))
                            .background(
                                Capsule()
                                    .fill(MarqueeTheme.surfaceLayer)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, MarqueeTheme.scaled(72, leanBack: 110, isLeanBack: leanBackMode))
    }

    private func searchPendingState(query: String) -> some View {
        VStack(spacing: MarqueeTheme.scaled(12, leanBack: 18, isLeanBack: leanBackMode)) {
            ProgressView()
                .controlSize(leanBackMode ? .large : .regular)

            Text("Searching for '\(query)'…")
                .font(.system(size: MarqueeTheme.scaled(14, leanBack: 20, isLeanBack: leanBackMode), weight: .medium))
                .foregroundColor(MarqueeTheme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, MarqueeTheme.scaled(80, leanBack: 120, isLeanBack: leanBackMode))
    }

    private func emptyState(query: String) -> some View {
        VStack(spacing: MarqueeTheme.spacingMD) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: MarqueeTheme.scaled(36, leanBack: 52, isLeanBack: leanBackMode), weight: .ultraLight))
                .foregroundColor(MarqueeTheme.textTertiary.opacity(0.5))

            Text("No results for '\(query)'")
                .font(.system(size: MarqueeTheme.scaled(15, leanBack: 22, isLeanBack: leanBackMode), weight: .medium))
                .foregroundColor(MarqueeTheme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, MarqueeTheme.scaled(80, leanBack: 120, isLeanBack: leanBackMode))
    }

    // MARK: - Helpers

    private func movieSubtitle(for item: MediaItem) -> String {
        var parts: [String] = []
        if let year = item.displayYear {
            parts.append(year)
        }
        if let runtime = item.displayRuntime {
            parts.append(runtime)
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    private func recordQASearchSnapshot(reason: String, consumedCommand: Bool? = nil) {
        #if DEBUG
        SearchRemoteKeyboardTourProbe.shared.record(SearchRemoteKeyboardProbeSnapshot(
            reason: reason,
            query: searchText,
            debouncedQuery: searchSession.presentation.query,
            detailPresented: focusCoordinator.owner == .searchDetail,
            focusOwner: qaFocusOwner,
            keyboardVisible: remoteKeyboardPresented,
            focusedKeyID: remoteKeyboardFocus.flatMap { RemoteSearchKeyboardPolicy.key(at: $0)?.id },
            keyMonitorInstalled: keyMonitor != nil,
            fieldFocused: isSearchFieldFocused,
            suggestionsVisible: showSuggestions && !suggestions.isEmpty,
            suggestionFocus: remoteSuggestionFocus,
            resultFocus: qaResultFocus,
            firstVisibleResultAvailable: hasFirstVisibleResult,
            visibleMovieCount: visibleMovieResults.count,
            visibleShowCount: visibleShowResults.count,
            consumedCommand: consumedCommand
        ))
        #endif
    }

    private var qaFocusOwner: String {
        switch searchRemoteFocus {
        case .inactive:
            return "inactive"
        case .field:
            return "field"
        case .suggestions:
            return "suggestions"
        case .keyboard:
            return "keyboard"
        case .results:
            return "results"
        }
    }

    private var qaResultFocus: String? {
        guard let focus = remoteResultFocus,
              let gridFocus = gridFocus(for: focus) else { return nil }
        switch gridFocus {
        case .movie(let index): return "movie-\(index)"
        case .show(let index): return "show-\(index)"
        }
    }

}
