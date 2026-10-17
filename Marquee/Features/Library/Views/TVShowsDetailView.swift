import SwiftUI

// MARK: - TV Shows Detail View

struct TVShowsDetailView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var library: LibraryState
    var onRemoteBackAtRoot: () -> Void = {}

    @Environment(\.kidsMode) private var kidsMode
    @Environment(\.leanBackMode) private var leanBackMode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var remoteInput: RemoteInputRouter

    @State private var selectedShow: String?
    @State private var focusState = FocusEngineState(focused: TVShowsDetailFocusIDs.root)
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
        route: .tvShows,
        detailVisible: false,
        playerVisible: false,
        postPlayID: nil
    )

    private var focusTargetByID: [FocusNodeID: (rowIndex: Int, itemIndex: Int)] {
        var mapping: [FocusNodeID: (Int, Int)] = [:]
        for (rowIndex, row) in showRows.enumerated() {
            for (itemIndex, show) in row.shows.enumerated() {
                mapping[TVShowsDetailFocusIDs.item(rowID: row.id, showName: show.showName)] = (rowIndex, itemIndex)
            }
        }
        return mapping
    }

    private var focusTree: FocusNode {
        FocusNode(
            TVShowsDetailFocusIDs.root,
            kind: .container(.vertical),
            children: showRows.compactMap { row in
                guard !row.shows.isEmpty else { return nil }
                return FocusNode(
                    TVShowsDetailFocusIDs.row(row.id),
                    kind: .container(.grid(columns: row.shows.count)),
                    preferredFocus: row.shows.first
                        .map { TVShowsDetailFocusIDs.item(rowID: row.id, showName: $0.showName) },
                    children: row.shows.enumerated().map { _, show in
                        FocusNode(
                            TVShowsDetailFocusIDs.item(rowID: row.id, showName: show.showName),
                            kind: .leaf
                        )
                    }
                )
            }
        )
    }

    private var focusedPosition: (rowIndex: Int, itemIndex: Int)? {
        focusTargetByID[focusState.focused]
    }

    private var focusedRowID: String? {
        guard let (rowIndex, _) = focusedPosition,
              showRows.indices.contains(rowIndex) else { return nil }
        return showRows[rowIndex].id
    }

    private var showRows: [BrowseShowRow] {
        library.browseSnapshot.showRows
    }

    private var visibleShowRows: [BrowseShowRow] {
        Array(showRows.prefix(max(0, min(visibleRowLimit, showRows.count))))
    }

    private var showRowsSignature: String {
        showRows.map { "\($0.id):\($0.shows.count)" }.joined(separator: "|")
    }

    private var isDetailPresented: Bool {
        selectedShow != nil
    }

    private var browsePresentationState: BrowseSurfacePresentationState {
        BrowseSurfacePresentationState(
            route: .tvShows,
            detailVisible: isDetailPresented,
            playerVisible: appState.playerController.isPlayerPresented,
            postPlayID: appState.postPlayHandoff?.id
        )
    }

    var body: some View {
        ZStack {
            (kidsMode ? MarqueeTheme.kidsBackground : MarqueeTheme.background).ignoresSafeArea()

            gridMode

            BottomFadeView()

            if let show = selectedShow {
                showDetailMode(show)
                    .background(
                        (kidsMode ? MarqueeTheme.kidsBackground : MarqueeTheme.background)
                            .ignoresSafeArea()
                    )
            }
        }
        .onAppear {
            MarqueeMode.set(.browsing)
            clampRemoteFocus()
            stageRowsForFirstPaint()
            MarqueeSignpost.event("route-appeared", "tv-shows")
            #if DEBUG
            NotificationCenter.default.post(name: .marqueeQARouteSurfaceAppeared, object: "tv-shows")
            #endif
        }
        .onChange(of: showRowsSignature) { _ in
            clampRemoteFocus()
            stageRowsForFirstPaint()
        }
        .onReceive(remoteInput.events) { event in
            handleRemoteEvent(event)
        }
    }

    // MARK: - Grid Mode

    private var gridMode: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: MarqueeTheme.scaled(36, leanBack: 54, isLeanBack: leanBackMode)) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("TV Shows")
                            .font(.system(size: MarqueeTheme.scaled(28, leanBack: 40, isLeanBack: leanBackMode), weight: .bold))
                            .foregroundColor(MarqueeTheme.textPrimary)
                        Spacer()
                        if !library.browseSnapshot.showSummaries.isEmpty {
                            Text("\(library.browseSnapshot.showSummaries.count) show\(library.browseSnapshot.showSummaries.count == 1 ? "" : "s")")
                                .font(.system(size: MarqueeTheme.scaled(13, leanBack: 18, isLeanBack: leanBackMode)))
                                .foregroundColor(MarqueeTheme.textTertiary)
                        }
                    }
                    .padding(.top, MarqueeTheme.scaled(28, leanBack: 44, isLeanBack: leanBackMode))

                    if library.filteredTVItems.isEmpty && !library.isScanning {
                        emptyState
                    } else if !library.browseSnapshot.showSummaries.isEmpty {
                        ForEach(Array(visibleShowRows.enumerated()), id: \.element.id) { rowIndex, row in
                            let renderedShows = stagedShowNames(for: row, rowIndex: rowIndex)
                            ShowCardRow(
                                title: row.title,
                                showNames: renderedShows,
                                totalCount: row.shows.count,
                                posterForShow: { library.browseSnapshot.showSummary(named: $0)?.posterPath },
                                upNextForShow: { library.browseSnapshot.showSummary(named: $0)?.upNextLabel },
                                seasonCountForShow: { library.browseSnapshot.showSummary(named: $0)?.seasonCount ?? 0 },
                                focusedShowName: focusedShowName(in: rowIndex),
                                onSelectShow: { name in
                                    var transaction = Transaction()
                                    transaction.disablesAnimations = true
                                    withTransaction(transaction) {
                                        selectedShow = name
                                    }
                                }
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
            .coordinateSpace(name: "tv-browse-scroll")
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
            .onChange(of: showRowsSignature) { _ in
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
    }

    private func stagedShowNames(for row: BrowseShowRow, rowIndex: Int) -> [String] {
        let showNames = row.shows.map(\.showName)
        let focusedColumn = focusedPosition?.rowIndex == rowIndex ? focusedPosition?.itemIndex : nil
        let limit = stagedItemLimit(
            rowIndex: rowIndex,
            itemCount: showNames.count,
            totalRowCount: showRows.count,
            focusedColumn: focusedColumn
        )
        return Array(showNames.prefix(limit))
    }

    // MARK: - Show Detail Mode

    private func showDetailMode(_ show: String) -> some View {
        ShowDetailView(
            showName: show,
            appState: appState,
            library: library,
            onSelectShow: { relatedShow in
                withAnimation(MarqueeTheme.motion(MarqueeTheme.pageTransitionAnimation, reduceMotion: reduceMotion)) {
                    selectedShow = relatedShow
                }
            },
            onDismiss: {
                withAnimation(MarqueeTheme.motion(MarqueeTheme.pageTransitionAnimation, reduceMotion: reduceMotion)) {
                    selectedShow = nil
                }
            },
            onNavigateToSidebar: onRemoteBackAtRoot
        )
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: MarqueeTheme.spacingMD) {
            Image(systemName: "tv")
                .font(.system(size: MarqueeTheme.scaled(40, leanBack: 58, isLeanBack: leanBackMode), weight: .ultraLight))
                .foregroundColor(MarqueeTheme.textTertiary.opacity(0.4))
            Text("No TV shows found")
                .font(.system(size: MarqueeTheme.scaled(17, leanBack: 24, isLeanBack: leanBackMode), weight: .medium))
                .foregroundColor(MarqueeTheme.textSecondary)
            Text("Scanning \(UserSettings.shared.tvShowsPaths.first ?? "~/TV Shows")")
                .font(.system(size: MarqueeTheme.scaled(12, leanBack: 17, isLeanBack: leanBackMode)))
                .foregroundColor(MarqueeTheme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, MarqueeTheme.scaled(80, leanBack: 120, isLeanBack: leanBackMode))
    }

    private func focusedShowName(in rowIndex: Int) -> String? {
        guard let (focusedRowIndex, focusedShowIndex) = focusedPosition,
              focusedRowIndex == rowIndex,
              showRows.indices.contains(focusedRowIndex),
              showRows[focusedRowIndex].shows.indices.contains(focusedShowIndex) else {
            return nil
        }
        return showRows[focusedRowIndex].shows[focusedShowIndex].showName
    }

    private func focusedShowName() -> String? {
        guard let focused = focusedPosition,
              showRows.indices.contains(focused.rowIndex),
              showRows[focused.rowIndex].shows.indices.contains(focused.itemIndex) else {
            return nil
        }
        return showRows[focused.rowIndex].shows[focused.itemIndex].showName
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
                value: [id: proxy.frame(in: .named("tv-browse-scroll")).minY]
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
        guard let row = showRows.first(where: { $0.id == rowID }),
              let focusLabel = focusedShowName() else { return false }
        let evidence = BrowseReturnPlacementEvidence(
            route: .tvShows,
            target: target,
            focusID: focusLabel,
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
        guard showRows.indices.contains(focusedPosition.rowIndex),
              showRows[focusedPosition.rowIndex].shows.indices.contains(focusedPosition.itemIndex) else {
            focusState = FocusEngineState(focused: firstAvailableFocus())
            return
        }
    }

    private func firstAvailableFocus() -> FocusNodeID {
        for row in showRows {
            guard let first = row.shows.first else { continue }
            return TVShowsDetailFocusIDs.item(rowID: row.id, showName: first.showName)
        }
        return TVShowsDetailFocusIDs.root
    }

    private func stageRowsForFirstPaint() {
        let signature = showRowsSignature
        let focusedRow = focusedPosition?.rowIndex ?? 0
        let firstPaintLimit = min(
            showRows.count,
            max(2, focusedRow + 1)
        )
        setVisibleRowLimitWithoutAnimation(firstPaintLimit)
        guard firstPaintLimit < showRows.count else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + BrowseGridFirstPaintPolicy.stagingExpandDelay) { [signature] in
            guard showRowsSignature == signature else { return }
            setVisibleRowLimitWithoutAnimation(showRows.count)
        }
    }

    private func setVisibleRowLimitWithoutAnimation(_ limit: Int) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            visibleRowLimit = limit
        }
    }

    private func handleRemoteEvent(_ event: RemoteCommandEvent) {
        guard selectedShow == nil,
              !appState.playerController.isPlayerPresented else {
            return
        }

        guard event.consume() else { return }

        switch event.command {
        case .back:
            AudioIdentityService.shared.playFeedback(for: .back, didNavigate: false)
            onRemoteBackAtRoot()
        case .select:
            AudioIdentityService.shared.playFeedback(for: .select)
            guard let show = focusedShow else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                selectedShow = show
            }
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

    private var focusedShow: String? {
        guard let focused = focusedPosition,
              showRows.indices.contains(focused.rowIndex),
              showRows[focused.rowIndex].shows.indices.contains(focused.itemIndex) else {
            return nil
        }
        return showRows[focused.rowIndex].shows[focused.itemIndex].showName
    }

    private func hasLeftBoundary(_ events: [FocusEngineEvent]) -> Bool {
        events.contains { event in
            if case let .boundaryHit(_, direction) = event {
                return direction == .left
            }
            return false
        }
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
}

private enum TVShowsDetailFocusIDs {
    static let root: FocusNodeID = "tv-shows-detail-root"

    static func row(_ id: String) -> FocusNodeID {
        FocusNodeID("tv-shows-detail-row:\(id)")
    }

    static func item(rowID: String, showName: String) -> FocusNodeID {
        FocusNodeID("tv-shows-detail-item:\(rowID):\(showName)")
    }
}
