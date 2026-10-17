import SwiftUI

// MARK: - Movies Detail View

struct MoviesDetailView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var library: LibraryState
    var onRemoteBackAtRoot: () -> Void = {}

    @Environment(\.kidsMode) private var kidsMode
    @Environment(\.leanBackMode) private var leanBackMode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var remoteInput: RemoteInputRouter
    @State private var selectedItem: MediaItem?
    @State private var focusState = FocusEngineState(focused: MoviesDetailFocusIDs.root)
    @State private var visibleRowLimit: Int = 2
    @State private var scrollGate = RemoteScrollRequestGate()
    @State private var scrollOffset: CGFloat = 0
    @StateObject private var scrollController = BrowseVerticalScrollController()
    @State private var measuredRowViewportTops: [String: CGFloat] = [:]
    @State private var pendingReturnPlacement = PendingBrowseReturnPlacement()
    @State private var pendingReturnPlacementSerial: Int?
    #if DEBUG
    @State private var publishedQAReturnPlacementSerial: Int?
    #endif
    @State private var focusGeneration = 0
    @State private var previousPresentationState = BrowseSurfacePresentationState(
        route: .movies,
        detailVisible: false,
        playerVisible: false,
        postPlayID: nil
    )

    private var focusTargetByID: [FocusNodeID: (rowIndex: Int, itemIndex: Int)] {
        var mapping: [FocusNodeID: (Int, Int)] = [:]
        for (rowIndex, row) in movieRows.enumerated() {
            for (itemIndex, item) in row.items.enumerated() {
                mapping[MoviesDetailFocusIDs.item(rowID: row.id, itemID: item.id)] = (rowIndex, itemIndex)
            }
        }
        return mapping
    }

    private var focusTree: FocusNode {
        FocusNode(
            MoviesDetailFocusIDs.root,
            kind: .container(.vertical),
            children: movieRows.compactMap { row in
                guard !row.items.isEmpty else { return nil }
                return FocusNode(
                    MoviesDetailFocusIDs.row(row.id),
                    kind: .container(.grid(columns: row.items.count)),
                    preferredFocus: row.items.first
                        .map { MoviesDetailFocusIDs.item(rowID: row.id, itemID: $0.id) },
                    children: row.items.enumerated().map { itemIndex, item in
                        FocusNode(
                            MoviesDetailFocusIDs.item(rowID: row.id, itemID: item.id),
                            kind: .leaf
                        )
                    }
                )
            }
        )
    }

    private var movieRows: [BrowseMediaRow] {
        library.browseSnapshot.movieRows
    }

    private var visibleMovieRows: [BrowseMediaRow] {
        Array(movieRows.prefix(max(0, min(visibleRowLimit, movieRows.count))))
    }

    private var movieRowsSignature: String {
        movieRows.map { "\($0.id):\($0.items.count)" }.joined(separator: "|")
    }

    private var isDetailPresented: Bool {
        selectedItem != nil
    }

    private var focusedPosition: (rowIndex: Int, itemIndex: Int)? {
        focusTargetByID[focusState.focused]
    }

    private var focusedRowID: String? {
        guard let (rowIndex, _) = focusedPosition,
              movieRows.indices.contains(rowIndex) else { return nil }
        return movieRows[rowIndex].id
    }

    private var browsePresentationState: BrowseSurfacePresentationState {
        BrowseSurfacePresentationState(
            route: .movies,
            detailVisible: isDetailPresented,
            playerVisible: appState.playerController.isPlayerPresented,
            postPlayID: appState.postPlayHandoff?.id
        )
    }

    var body: some View {
        ZStack {
            (kidsMode ? MarqueeTheme.kidsBackground : MarqueeTheme.background).ignoresSafeArea()

            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: MarqueeTheme.scaled(36, leanBack: 54, isLeanBack: leanBackMode)) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Movies")
                                .font(.system(size: MarqueeTheme.scaled(28, leanBack: 40, isLeanBack: leanBackMode), weight: .bold))
                                .foregroundColor(MarqueeTheme.textPrimary)
                            Spacer()
                            if !library.filteredLibraryItems.isEmpty {
                                Text("\(library.filteredLibraryItems.count) title\(library.filteredLibraryItems.count == 1 ? "" : "s")")
                                    .font(.system(size: MarqueeTheme.scaled(13, leanBack: 18, isLeanBack: leanBackMode)))
                                    .foregroundColor(MarqueeTheme.textTertiary)
                            }
                        }
                        .padding(.top, MarqueeTheme.scaled(28, leanBack: 44, isLeanBack: leanBackMode))

                        if library.filteredLibraryItems.isEmpty {
                            emptyState
                        } else {
                            ForEach(Array(visibleMovieRows.enumerated()), id: \.element.id) { rowIndex, row in
                                let renderedItems = stagedItems(for: row, rowIndex: rowIndex)
                                MediaItemRow(
                                    title: row.title,
                                    items: renderedItems,
                                    totalCount: row.items.count,
                                    focusedItemID: focusedItemID(in: rowIndex),
                                    onSelect: { selectedItem = $0 }
                                )
                                .id(row.id)
                                .background(rowViewportTopObserver(id: row.id))
                            }
                        }
                    }
                    .padding(.horizontal, MarqueeTheme.outerPadding(isLeanBack: leanBackMode))
                    .padding(.bottom, MarqueeTheme.scaled(100, leanBack: 150, isLeanBack: leanBackMode))
                    .background(
                        BrowseVerticalScrollObserver(offset: $scrollOffset, controller: scrollController)
                            .frame(width: 0, height: 0)
                    )
                }
                .coordinateSpace(name: "movies-browse-scroll")
                .onPreferenceChange(BrowseRowViewportTopPreferenceKey.self) { values in
                    measuredRowViewportTops = values
                    performPendingReturnPlacementIfPossible()
                }
                .onAppear {
                    previousPresentationState = browsePresentationState
                    scrollFocusedRow(proxy: proxy, animated: false)
                }
                .onChange(of: focusedRowID) { _ in
                    focusGeneration += 1
                    pendingReturnPlacement.cancel(focusGeneration: focusGeneration)
                    pendingReturnPlacementSerial = nil
                    scrollFocusedRow(proxy: proxy, animated: true)
                }
                .onChange(of: movieRowsSignature) { _ in
                    scrollFocusedRow(proxy: proxy, animated: false)
                }
                .onChange(of: isDetailPresented) { _ in
                    observePresentationState()
                }
                .onChange(of: appState.postPlayHandoff?.id) { _ in
                    observePresentationState()
                }
                .onChange(of: scrollController.geometryChangeSerial) { _ in
                    performPendingReturnPlacementIfPossible()
                }
                .onReceive(appState.playerController.$isPlayerPresented) { playerVisible in
                    observePresentationState(playerVisible: playerVisible)
                }
            }

            BottomFadeView()

            if let item = selectedItem {
                MovieDetailView(
                    item: item,
                    appState: appState,
                    library: library,
                    onSelectItem: { selectedItem = $0 },
                    dismiss: { selectedItem = nil },
                    onNavigateToSidebar: onRemoteBackAtRoot
                )
                .background(
                    (kidsMode ? MarqueeTheme.kidsBackground : MarqueeTheme.background)
                        .ignoresSafeArea()
                )
                .transition(.opacity)
            }
        }
        .onAppear {
            MarqueeMode.set(.browsing)
            clampRemoteFocus()
            stageRowsForFirstPaint()
            MarqueeSignpost.event("route-appeared", "movies")
            #if DEBUG
            NotificationCenter.default.post(name: .marqueeQARouteSurfaceAppeared, object: "movies")
            #endif
        }
        .onChange(of: movieRowsSignature) { _ in
            clampRemoteFocus()
            stageRowsForFirstPaint()
        }
        .onReceive(remoteInput.events) { event in
            handleRemoteEvent(event)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: MarqueeTheme.spacingMD) {
            Image(systemName: "film")
                .font(.system(size: MarqueeTheme.scaled(40, leanBack: 58, isLeanBack: leanBackMode), weight: .ultraLight))
                .foregroundColor(MarqueeTheme.textTertiary.opacity(0.4))
            Text("No movies found")
                .font(.system(size: MarqueeTheme.scaled(17, leanBack: 24, isLeanBack: leanBackMode), weight: .medium))
                .foregroundColor(MarqueeTheme.textSecondary)
            Text("Scanning \(UserSettings.shared.moviesPaths.first ?? "~/Movies")")
                .font(.system(size: MarqueeTheme.scaled(12, leanBack: 17, isLeanBack: leanBackMode)))
                .foregroundColor(MarqueeTheme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, MarqueeTheme.scaled(80, leanBack: 120, isLeanBack: leanBackMode))
    }

    private func focusedItemID(in rowIndex: Int) -> MediaItem.ID? {
        guard let (focusedRowIndex, focusedItemIndex) = focusedPosition,
              focusedRowIndex == rowIndex,
              movieRows.indices.contains(focusedRowIndex),
              movieRows[focusedRowIndex].items.indices.contains(focusedItemIndex) else {
            return nil
        }
        return movieRows[focusedRowIndex].items[focusedItemIndex].id
    }

    private func scrollFocusedRow(proxy: ScrollViewProxy, animated: Bool) {
        guard let id = focusedRowID else { return }
        let serial = scrollGate.issue()
        let action = {
            guard scrollGate.accepts(serial) else { return }
            if self.scrollFocusedGridRowIfNeeded(id: id, animated: animated) {
                return
            }
            proxy.scrollTo(id, anchor: RemoteFocusScrollAnchor.row)
        }
        let perform = {
            RemoteProgrammaticScrollPolicy.perform(animated: animated, reduceMotion: reduceMotion) {
                action()
            }
        }
        DispatchQueue.main.async(execute: perform)
    }

    private func scrollFocusedGridRowIfNeeded(id: String, animated: Bool) -> Bool {
        guard let rowViewportTop = measuredRowViewportTops[id] else { return false }
        let viewportHeight = scrollController.viewportHeight
        guard !RemoteHomeRowScrollPlacement.isComfortablyPlaced(
            rowViewportTop: rowViewportTop,
            viewportHeight: viewportHeight
        ) else {
            return true
        }

        let targetOffset = RemoteHomeRowScrollPlacement.targetOffset(
            currentOffset: scrollOffset,
            rowViewportTop: rowViewportTop,
            desiredViewportTop: RemoteHomeRowScrollPlacement.desiredViewportTop(viewportHeight: viewportHeight)
        )
        return scrollController.springScroll(
            to: targetOffset,
            animated: animated,
            reduceMotion: reduceMotion
        )
    }

    private func rowViewportTopObserver(id: String) -> some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: BrowseRowViewportTopPreferenceKey.self,
                value: [id: proxy.frame(in: .named("movies-browse-scroll")).minY]
            )
        }
    }

    private func observePresentationState(playerVisible: Bool? = nil) {
        var current = browsePresentationState
        if let playerVisible {
            current = BrowseSurfacePresentationState(
                route: current.route,
                detailVisible: current.detailVisible,
                playerVisible: playerVisible,
                postPlayID: current.postPlayID
            )
        }
        guard current != previousPresentationState else { return }
        let previous = previousPresentationState
        previousPresentationState = current
        #if DEBUG
        NotificationCenter.default.post(
            name: .marqueeQABrowsePresentationObserved,
            object: current
        )
        #endif
        guard BrowseSurfaceExitPolicy.shouldPlace(from: previous, to: current) else { return }
        issueReturnPlacement()
    }

    private func issueReturnPlacement() {
        clampRemoteFocus()
        guard let target = BrowseReturnPlacementPolicy.target(
            for: BrowseReturnFocus.grid(rowID: focusedRowID)
        ) else { return }
        pendingReturnPlacementSerial = pendingReturnPlacement.issue(
            target: target,
            focusGeneration: focusGeneration,
            attachmentEpoch: scrollController.attachmentEpoch
        )
        #if DEBUG
        publishedQAReturnPlacementSerial = nil
        #endif
        performPendingReturnPlacementIfPossible()
    }

    private func performPendingReturnPlacementIfPossible() {
        let currentTarget = BrowseReturnPlacementPolicy.target(
            for: BrowseReturnFocus.grid(rowID: focusedRowID)
        )
        pendingReturnPlacement.cancelIfTargetChanged(to: currentTarget)
        guard let serial = pendingReturnPlacementSerial,
              let id = focusedRowID,
              let viewportTop = measuredRowViewportTops[id],
              let target = currentTarget else {
            if currentTarget == nil {
                pendingReturnPlacementSerial = nil
            }
            return
        }
        guard pendingReturnPlacement.isActive(serial: serial) else {
            pendingReturnPlacementSerial = nil
            return
        }
        let sample = BrowseReturnGeometrySample(
            target: target,
            targetMinY: scrollController.currentOffset + viewportTop,
            viewportHeight: scrollController.viewportHeight,
            currentOffset: scrollController.currentOffset,
            contentHeight: scrollController.contentHeight,
            attachmentEpoch: scrollController.attachmentEpoch,
            focusGeneration: focusGeneration
        )
        let offset = pendingReturnPlacement.consume(sample: sample, serial: serial)
        #if DEBUG
        if publishedQAReturnPlacementSerial != serial,
           publishQAReturnPlacementIfCorrect(
                target: target,
                rowID: id,
                rowViewportTop: viewportTop
            ) {
            publishedQAReturnPlacementSerial = serial
        }
        #endif
        if !pendingReturnPlacement.isActive(serial: serial) {
            pendingReturnPlacementSerial = nil
        }
        if let offset {
            _ = scrollController.scroll(to: offset, animated: false, reduceMotion: reduceMotion)
        }
    }

    #if DEBUG
    private func publishQAReturnPlacementIfCorrect(
        target: BrowseReturnPlacementTarget,
        rowID: String,
        rowViewportTop: CGFloat
    ) -> Bool {
        guard let row = movieRows.first(where: { $0.id == rowID }),
              let focusedItemID = focusedItemID(in: focusedPosition?.rowIndex ?? -1) else { return false }
        let evidence = BrowseReturnPlacementEvidence(
            route: .movies,
            target: target,
            focusID: focusedItemID.uuidString,
            rowTitle: row.title,
            rowViewportTop: rowViewportTop,
            viewportHeight: scrollController.viewportHeight,
            currentOffset: scrollController.currentOffset
        )
        guard evidence.isCorrectlyPlaced else { return false }
        NotificationCenter.default.post(
            name: .marqueeQABrowseReturnPlaced,
            object: evidence
        )
        return true
    }
    #endif

    private func clampRemoteFocus() {
        guard let focusedPosition else {
            focusState = FocusEngineState(focused: firstAvailableFocus())
            return
        }
        guard movieRows.indices.contains(focusedPosition.rowIndex),
              movieRows[focusedPosition.rowIndex].items.indices.contains(focusedPosition.itemIndex) else {
            focusState = FocusEngineState(focused: firstAvailableFocus())
            return
        }
    }

    private func firstAvailableFocus() -> FocusNodeID {
        for row in movieRows {
            guard let first = row.items.first else { continue }
            return MoviesDetailFocusIDs.item(rowID: row.id, itemID: first.id)
        }
        return MoviesDetailFocusIDs.root
    }

    private func stageRowsForFirstPaint() {
        let signature = movieRowsSignature
        let focusedRow = focusedPosition?.rowIndex ?? 0
        let firstPaintLimit = min(
            movieRows.count,
            max(2, focusedRow + 1)
        )
        setVisibleRowLimitWithoutAnimation(firstPaintLimit)
        guard firstPaintLimit < movieRows.count else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + BrowseGridFirstPaintPolicy.stagingExpandDelay) { [signature] in
            guard movieRowsSignature == signature else { return }
            setVisibleRowLimitWithoutAnimation(movieRows.count)
        }
    }

    private func setVisibleRowLimitWithoutAnimation(_ limit: Int) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            visibleRowLimit = limit
        }
    }

    private func stagedItems(for row: BrowseMediaRow, rowIndex: Int) -> [MediaItem] {
        let focusedColumn = focusedPosition?.rowIndex == rowIndex ? focusedPosition?.itemIndex : nil
        let limit = stagedItemLimit(
            rowIndex: rowIndex,
            itemCount: row.items.count,
            totalRowCount: movieRows.count,
            focusedColumn: focusedColumn
        )
        return Array(row.items.prefix(limit))
    }

    private func stagedItemLimit(
        rowIndex: Int,
        itemCount: Int,
        totalRowCount: Int,
        focusedColumn: Int?
    ) -> Int {
        guard itemCount > 0 else { return 0 }
        guard visibleRowLimit < totalRowCount else { return itemCount }
        let focusedRequirement = rowIndex == (focusedPosition?.rowIndex ?? 0)
            ? (focusedColumn ?? 0) + 1
            : 0
        return min(itemCount, max(BrowseGridFirstPaintPolicy.initialRowItemLimit, focusedRequirement))
    }

    private func handleRemoteEvent(_ event: RemoteCommandEvent) {
        guard selectedItem == nil,
              !appState.playerController.isPlayerPresented else {
            return
        }

        guard event.consume() else { return }

        switch event.command {
        case .back:
            AudioIdentityService.shared.playFeedback(for: .back, didNavigate: false)
            onRemoteBackAtRoot()
        case .select:
            guard let item = focusedMovieItem else { return }
            AudioIdentityService.shared.playFeedback(for: .select)
            selectedItem = item
        case .up, .down, .left, .right:
            clampRemoteFocus()
            let previousFocus = focusState.focused
            guard let direction = focusDirection(for: event.command) else { return }
            let result = FocusEngine(root: focusTree).move(direction, state: focusState)
            focusState = result.state
            let didNavigate = focusState.focused != previousFocus
            AudioIdentityService.shared.playFeedback(
                for: event.command,
                didNavigate: didNavigate,
                focusEvents: result.events,
                didReachBoundary: !didNavigate
            )
            if hasLeftBoundary(result.events) {
                onRemoteBackAtRoot()
            }
        }
    }

    private func focusDirection(for command: RemoteCommand) -> FocusDirection? {
        switch command {
        case .up:
            return .up
        case .down:
            return .down
        case .left:
            return .left
        case .right:
            return .right
        case .select, .back:
            return nil
        }
    }

    private var focusedMovieItem: MediaItem? {
        guard let focused = focusedPosition,
              movieRows.indices.contains(focused.rowIndex),
              movieRows[focused.rowIndex].items.indices.contains(focused.itemIndex) else {
            return nil
        }
        return movieRows[focused.rowIndex].items[focused.itemIndex]
    }

    private func hasLeftBoundary(_ events: [FocusEngineEvent]) -> Bool {
        events.contains { event in
            if case let .boundaryHit(_, direction) = event {
                return direction == .left
            }
            return false
        }
    }
}

private enum MoviesDetailFocusIDs {
    static let root: FocusNodeID = "movies-detail-root"

    static func row(_ id: String) -> FocusNodeID {
        FocusNodeID("movies-detail-row:\(id)")
    }

    static func item(rowID: String, itemID: MediaItem.ID) -> FocusNodeID {
        FocusNodeID("movies-detail-item:\(rowID):\(itemID.uuidString)")
    }
}
