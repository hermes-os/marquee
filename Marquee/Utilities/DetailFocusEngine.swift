import Foundation

// A detail surface hands remote focus to the sidebar when a Left move dies at
// the focus tree's left boundary. Stepper activations never reach this policy;
// the season stepper keeps consuming Left even at its first season.
enum DetailSidebarHandoffPolicy {
    static func shouldHandOff(direction: FocusDirection, events: [FocusEngineEvent]) -> Bool {
        guard direction == .left else { return false }
        return events.contains { event in
            if case .boundaryHit(_, .left) = event { return true }
            return false
        }
    }
}

enum DetailFocusIDs {
    static let movieRoot: FocusNodeID = "movie-detail-root"
    static let movieBack: FocusNodeID = "movie-detail-back"
    static let movieActions: FocusNodeID = "movie-detail-actions"
    static let movieStart: FocusNodeID = "movie-detail-start"
    static let movieContinue: FocusNodeID = "movie-detail-continue"
    static let movieShowMore: FocusNodeID = "movie-detail-show-more"
    static let movieMoreLikeRow: FocusNodeID = "movie-detail-more-like-row"

    static let showRoot: FocusNodeID = "show-detail-root"
    static let showBack: FocusNodeID = "show-detail-back"
    static let showActions: FocusNodeID = "show-detail-actions"
    static let showStart: FocusNodeID = "show-detail-start"
    static let showContinue: FocusNodeID = "show-detail-continue"
    static let showOverview: FocusNodeID = "show-detail-overview"
    static let showSeasons: FocusNodeID = "show-detail-seasons"
    static let showEpisodes: FocusNodeID = "show-detail-episodes"
    static let showMoreLikeRow: FocusNodeID = "show-detail-more-like-row"

    static func movieMoreLike(_ index: Int) -> FocusNodeID {
        FocusNodeID("movie-detail-more-like-\(index)")
    }

    static func moviePersonRow(_ row: Int) -> FocusNodeID {
        FocusNodeID("movie-detail-person-row-\(row)")
    }

    static func moviePerson(row: Int, item: Int) -> FocusNodeID {
        FocusNodeID("movie-detail-person-\(row)-\(item)")
    }

    static func showEpisode(_ index: Int) -> FocusNodeID {
        FocusNodeID("show-detail-episode-\(index)")
    }

    static func showMoreLike(_ index: Int) -> FocusNodeID {
        FocusNodeID("show-detail-more-like-\(index)")
    }

    static func showPersonRow(_ row: Int) -> FocusNodeID {
        FocusNodeID("show-detail-person-row-\(row)")
    }

    static func showPerson(row: Int, item: Int) -> FocusNodeID {
        FocusNodeID("show-detail-person-\(row)-\(item)")
    }

    static func movieMoreLikeIndex(from id: FocusNodeID) -> Int? {
        index(from: id, prefix: "movie-detail-more-like-")
    }

    static func moviePersonIndex(from id: FocusNodeID) -> (row: Int, item: Int)? {
        rowItemIndex(from: id, prefix: "movie-detail-person-")
    }

    static func showEpisodeIndex(from id: FocusNodeID) -> Int? {
        index(from: id, prefix: "show-detail-episode-")
    }

    static func showMoreLikeIndex(from id: FocusNodeID) -> Int? {
        index(from: id, prefix: "show-detail-more-like-")
    }

    static func showPersonIndex(from id: FocusNodeID) -> (row: Int, item: Int)? {
        rowItemIndex(from: id, prefix: "show-detail-person-")
    }

    private static func index(from id: FocusNodeID, prefix: String) -> Int? {
        guard id.rawValue.hasPrefix(prefix) else { return nil }
        return Int(id.rawValue.dropFirst(prefix.count))
    }

    private static func rowItemIndex(from id: FocusNodeID, prefix: String) -> (row: Int, item: Int)? {
        guard id.rawValue.hasPrefix(prefix) else { return nil }
        let suffix = id.rawValue.dropFirst(prefix.count)
        let parts = suffix.split(separator: "-")
        guard parts.count == 2,
              let row = Int(parts[0]),
              let item = Int(parts[1]) else { return nil }
        return (row, item)
    }
}

enum DetailFocusScrollIDs {
    static let movieTop = "movie-detail-top"
    static let movieShowMore = "movie-detail-synopsis"
    static let showTop = "show-detail-top"
    static let showMore = "show-detail-overview"
    static let showSeasons = "show-detail-seasons"

    static func showEpisode(_ index: Int) -> String {
        "show-detail-episode-\(index)"
    }

    static func moviePersonRow(_ rowID: String) -> String {
        "movie-detail-person-row-\(rowID)"
    }

    static func showPersonRow(_ rowID: String) -> String {
        "show-detail-person-row-\(rowID)"
    }
}

struct MovieDetailFocusConfiguration {
    var hasContinueAction: Bool
    var hasShowMore: Bool
    var moreLikeCount: Int
    var preferredMoreLikeIndex: Int
    var personRowItemCounts: [Int] = []
    var preferredPersonRowIndex: Int = 0
    var preferredPersonItemIndex: Int = 0
}

struct ShowDetailFocusConfiguration {
    var hasBack: Bool
    var hasStartAction: Bool
    var hasContinueAction: Bool
    var hasOverview: Bool
    var hasSeasonStepper: Bool
    var episodeCount: Int
    var moreLikeCount: Int
    var preferredMoreLikeIndex: Int
    var personRowItemCounts: [Int] = []
    var preferredPersonRowIndex: Int = 0
    var preferredPersonItemIndex: Int = 0
}

struct ShowDetailFocusReconciliationContext {
    var state: FocusEngineState
    var firstAvailableFocus: FocusNodeID
    var hasBack: Bool
    var hasStartAction: Bool
    var hasContinueAction: Bool
    var hasOverview: Bool
    var hasSeasonStepper: Bool
    var areDeferredSectionsVisible: Bool
    var episodeCount: Int
    var moreLikeCount: Int
    var personRowItemCounts: [Int] = []
    var proposedEpisodeIndex: Int
    var proposedMoreLikeIndex: Int
    var proposedPersonRowIndex: Int = 0
    var proposedPersonItemIndex: Int = 0
}

struct ShowDetailFocusReconciliationResult {
    var state: FocusEngineState
    var focusedEpisodeIndex: Int
    var moreLikeFocusedIndex: Int
    var personFocusedRowIndex: Int = 0
    var personFocusedItemIndex: Int = 0
}

enum ShowDetailFocusReconciler {
    static func resettingEpisodeMemoryAfterSeasonChange(
        _ state: FocusEngineState
    ) -> FocusEngineState {
        var resetState = state
        resetState.rememberedChildByContainer[DetailFocusIDs.showEpisodes] = nil
        return resetState
    }

    static func reconcile(
        _ context: ShowDetailFocusReconciliationContext
    ) -> ShowDetailFocusReconciliationResult {
        let clampedEpisodeIndex = clampedIndex(context.proposedEpisodeIndex, count: context.episodeCount)
        let clampedMoreLikeIndex = clampedIndex(context.proposedMoreLikeIndex, count: context.moreLikeCount)
        let clampedPersonFocus = clampedPersonIndex(
            row: context.proposedPersonRowIndex,
            item: context.proposedPersonItemIndex,
            rowItemCounts: context.personRowItemCounts
        )

        func fallback() -> ShowDetailFocusReconciliationResult {
            ShowDetailFocusReconciliationResult(
                state: FocusEngineState(focused: context.firstAvailableFocus),
                focusedEpisodeIndex: clampedEpisodeIndex,
                moreLikeFocusedIndex: clampedMoreLikeIndex,
                personFocusedRowIndex: clampedPersonFocus.row,
                personFocusedItemIndex: clampedPersonFocus.item
            )
        }

        var state = context.state
        let focus = state.focused
        if focus == DetailFocusIDs.showBack {
            guard context.hasBack else { return fallback() }
        } else if focus == DetailFocusIDs.showStart {
            guard context.hasStartAction else { return fallback() }
        } else if focus == DetailFocusIDs.showContinue {
            guard context.hasContinueAction else { return fallback() }
        } else if focus == DetailFocusIDs.showOverview {
            guard context.hasOverview else { return fallback() }
        } else if focus == DetailFocusIDs.showSeasons {
            guard context.areDeferredSectionsVisible, context.hasSeasonStepper else { return fallback() }
        } else if let episodeIndex = DetailFocusIDs.showEpisodeIndex(from: focus) {
            guard context.areDeferredSectionsVisible, context.episodeCount > 0 else {
                return fallback()
            }
            let focusedEpisodeIndex = clampedIndex(episodeIndex, count: context.episodeCount)
            state.focused = DetailFocusIDs.showEpisode(focusedEpisodeIndex)
            return ShowDetailFocusReconciliationResult(
                state: state,
                focusedEpisodeIndex: focusedEpisodeIndex,
                moreLikeFocusedIndex: clampedMoreLikeIndex,
                personFocusedRowIndex: clampedPersonFocus.row,
                personFocusedItemIndex: clampedPersonFocus.item
            )
        } else if let moreLikeIndex = DetailFocusIDs.showMoreLikeIndex(from: focus) {
            guard context.areDeferredSectionsVisible, context.moreLikeCount > 0 else {
                return fallback()
            }
            let focusedMoreLikeIndex = clampedIndex(moreLikeIndex, count: context.moreLikeCount)
            state.focused = DetailFocusIDs.showMoreLike(focusedMoreLikeIndex)
            return ShowDetailFocusReconciliationResult(
                state: state,
                focusedEpisodeIndex: clampedEpisodeIndex,
                moreLikeFocusedIndex: focusedMoreLikeIndex,
                personFocusedRowIndex: clampedPersonFocus.row,
                personFocusedItemIndex: clampedPersonFocus.item
            )
        } else if let personIndex = DetailFocusIDs.showPersonIndex(from: focus) {
            guard context.areDeferredSectionsVisible,
                  context.personRowItemCounts.contains(where: { $0 > 0 }) else {
                return fallback()
            }
            let focusedPerson = clampedPersonIndex(
                row: personIndex.row,
                item: personIndex.item,
                rowItemCounts: context.personRowItemCounts
            )
            state.focused = DetailFocusIDs.showPerson(row: focusedPerson.row, item: focusedPerson.item)
            return ShowDetailFocusReconciliationResult(
                state: state,
                focusedEpisodeIndex: clampedEpisodeIndex,
                moreLikeFocusedIndex: clampedMoreLikeIndex,
                personFocusedRowIndex: focusedPerson.row,
                personFocusedItemIndex: focusedPerson.item
            )
        } else {
            return fallback()
        }

        return ShowDetailFocusReconciliationResult(
            state: state,
            focusedEpisodeIndex: clampedEpisodeIndex,
            moreLikeFocusedIndex: clampedMoreLikeIndex,
            personFocusedRowIndex: clampedPersonFocus.row,
            personFocusedItemIndex: clampedPersonFocus.item
        )
    }

    private static func clampedIndex(_ proposed: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(proposed, 0), count - 1)
    }

    private static func clampedPersonIndex(
        row proposedRow: Int,
        item proposedItem: Int,
        rowItemCounts: [Int]
    ) -> (row: Int, item: Int) {
        let nonEmptyRows = rowItemCounts.enumerated().filter { $0.element > 0 }
        guard !nonEmptyRows.isEmpty else { return (0, 0) }
        let nearestRow = nonEmptyRows.min { lhs, rhs in
            abs(lhs.offset - proposedRow) < abs(rhs.offset - proposedRow)
        }?.offset ?? nonEmptyRows[0].offset
        let itemCount = rowItemCounts[nearestRow]
        return (
            nearestRow,
            min(max(proposedItem, 0), itemCount - 1)
        )
    }
}

enum DetailFocusTree {
    static func movie(_ config: MovieDetailFocusConfiguration) -> FocusNode {
        let moreLikeTarget = moreLikePreferredID(
            count: config.moreLikeCount,
            preferred: config.preferredMoreLikeIndex,
            makeID: DetailFocusIDs.movieMoreLike
        )
        let personTarget = personPreferredID(
            rowItemCounts: config.personRowItemCounts,
            preferredRow: config.preferredPersonRowIndex,
            preferredItem: config.preferredPersonItemIndex,
            makeID: DetailFocusIDs.moviePerson
        )
        let firstBelowActions = firstExisting([
            config.hasShowMore ? DetailFocusIDs.movieShowMore : nil,
            moreLikeTarget,
            personTarget
        ])
        var movieShowMoreGuides = guide(.down, to: moreLikeTarget)
        if moreLikeTarget == nil {
            movieShowMoreGuides = guide(.down, to: personTarget)
        }
        movieShowMoreGuides[.up] = DetailFocusIDs.movieStart

        var children: [FocusNode] = [
            FocusNode(
                DetailFocusIDs.movieBack,
                kind: .leaf,
                guides: guide(.down, to: DetailFocusIDs.movieStart)
            ),
            movieActionRow(
                includeContinue: config.hasContinueAction,
                downGuide: firstBelowActions
            )
        ]

        if config.hasShowMore {
            children.append(
                FocusNode(
                    DetailFocusIDs.movieShowMore,
                    kind: .leaf,
                    guides: movieShowMoreGuides
                )
            )
        }

        if config.moreLikeCount > 0 {
            children.append(
                FocusNode(
                    DetailFocusIDs.movieMoreLikeRow,
                    kind: .container(.grid(columns: config.moreLikeCount)),
                    preferredFocus: moreLikeTarget,
                    children: (0..<config.moreLikeCount).map { index in
                        FocusNode(
                            DetailFocusIDs.movieMoreLike(index),
                            kind: .leaf,
                            guides: [.up: config.hasShowMore ? DetailFocusIDs.movieShowMore : DetailFocusIDs.movieStart]
                        )
                    }
                )
            )
        }

        children.append(contentsOf: personRows(
            rowItemCounts: config.personRowItemCounts,
            preferredRow: config.preferredPersonRowIndex,
            preferredItem: config.preferredPersonItemIndex,
            makeRowID: DetailFocusIDs.moviePersonRow,
            makeID: DetailFocusIDs.moviePerson
        ))

        return FocusNode(
            DetailFocusIDs.movieRoot,
            kind: .container(.vertical),
            preferredFocus: DetailFocusIDs.movieStart,
            children: children
        )
    }

    static func show(_ config: ShowDetailFocusConfiguration) -> FocusNode {
        let moreLikeTarget = moreLikePreferredID(
            count: config.moreLikeCount,
            preferred: config.preferredMoreLikeIndex,
            makeID: DetailFocusIDs.showMoreLike
        )
        let personTarget = personPreferredID(
            rowItemCounts: config.personRowItemCounts,
            preferredRow: config.preferredPersonRowIndex,
            preferredItem: config.preferredPersonItemIndex,
            makeID: DetailFocusIDs.showPerson
        )
        let firstEpisode = config.episodeCount > 0 ? DetailFocusIDs.showEpisode(0) : nil
        let lastEpisode = config.episodeCount > 0 ? DetailFocusIDs.showEpisode(config.episodeCount - 1) : nil
        let episodeEscapeTarget = firstExisting([
            config.hasSeasonStepper ? DetailFocusIDs.showSeasons : nil,
            config.hasOverview ? DetailFocusIDs.showOverview : nil,
            config.hasStartAction ? DetailFocusIDs.showStart : nil,
            config.hasBack ? DetailFocusIDs.showBack : nil
        ])
        let firstBelowActions = firstExisting([
            config.hasOverview ? DetailFocusIDs.showOverview : nil,
            config.hasSeasonStepper ? DetailFocusIDs.showSeasons : nil,
            firstEpisode,
            moreLikeTarget,
            personTarget
        ])
        let upFromMoreLike = firstExisting([
            lastEpisode,
            config.hasSeasonStepper ? DetailFocusIDs.showSeasons : nil,
            config.hasOverview ? DetailFocusIDs.showOverview : nil,
            config.hasStartAction ? DetailFocusIDs.showStart : nil,
            config.hasBack ? DetailFocusIDs.showBack : nil
        ])
        let previousAboveOverview = firstExisting([
            config.hasStartAction ? DetailFocusIDs.showStart : nil,
            config.hasBack ? DetailFocusIDs.showBack : nil
        ])

        var children: [FocusNode] = []
        if config.hasBack {
            children.append(
                FocusNode(
                    DetailFocusIDs.showBack,
                    kind: .leaf,
                    guides: guide(.down, to: config.hasStartAction ? DetailFocusIDs.showStart : firstBelowActions)
                )
            )
        }
        if config.hasStartAction {
            children.append(
                showActionRow(
                    includeContinue: config.hasContinueAction,
                    downGuide: firstBelowActions
                )
            )
        }
        if config.hasOverview {
            children.append(
                FocusNode(
                    DetailFocusIDs.showOverview,
                    kind: .leaf,
                    guides: guide(.up, to: previousAboveOverview)
                )
            )
        }
        if config.hasSeasonStepper {
            children.append(
                FocusNode(
                    DetailFocusIDs.showSeasons,
                    kind: .stepper(axis: .horizontal),
                    guides: guide(
                        .up,
                        to: config.hasOverview ? DetailFocusIDs.showOverview : previousAboveOverview
                    )
                )
            )
        }
        if config.episodeCount > 0 {
            children.append(
                FocusNode(
                    DetailFocusIDs.showEpisodes,
                    kind: .container(.vertical),
                    preferredFocus: firstEpisode,
                    children: (0..<config.episodeCount).map { index in
                        let isLast = index == config.episodeCount - 1
                        var episodeGuides = isLast ? guide(.down, to: moreLikeTarget ?? personTarget) : [:]
                        episodeGuides[.left] = episodeEscapeTarget
                        if index == 0 {
                            if config.hasSeasonStepper {
                                episodeGuides[.up] = DetailFocusIDs.showSeasons
                            } else if !config.hasOverview {
                                episodeGuides[.up] = previousAboveOverview
                            }
                        }
                        return FocusNode(
                            DetailFocusIDs.showEpisode(index),
                            kind: .leaf,
                            guides: episodeGuides
                        )
                    }
                )
            )
        }
        if config.moreLikeCount > 0 {
            children.append(
                FocusNode(
                    DetailFocusIDs.showMoreLikeRow,
                    kind: .container(.grid(columns: config.moreLikeCount)),
                    preferredFocus: moreLikeTarget,
                    children: (0..<config.moreLikeCount).map { index in
                        FocusNode(
                            DetailFocusIDs.showMoreLike(index),
                            kind: .leaf,
                            guides: guide(.up, to: upFromMoreLike)
                        )
                    }
                )
            )
        }
        children.append(contentsOf: personRows(
            rowItemCounts: config.personRowItemCounts,
            preferredRow: config.preferredPersonRowIndex,
            preferredItem: config.preferredPersonItemIndex,
            makeRowID: DetailFocusIDs.showPersonRow,
            makeID: DetailFocusIDs.showPerson
        ))

        return FocusNode(
            DetailFocusIDs.showRoot,
            kind: .container(.vertical),
            preferredFocus: firstExisting([
                config.hasStartAction ? DetailFocusIDs.showStart : nil,
                config.hasOverview ? DetailFocusIDs.showOverview : nil,
                config.hasSeasonStepper ? DetailFocusIDs.showSeasons : nil,
                firstEpisode,
                moreLikeTarget,
                personTarget,
                config.hasBack ? DetailFocusIDs.showBack : nil
            ]),
            children: children
        )
    }

    private static func movieActionRow(
        includeContinue: Bool,
        downGuide: FocusNodeID?
    ) -> FocusNode {
        var children = [
            FocusNode(
                DetailFocusIDs.movieStart,
                kind: .leaf,
                guides: guide(.down, to: downGuide)
            )
        ]
        if includeContinue {
            children.append(
                FocusNode(
                    DetailFocusIDs.movieContinue,
                    kind: .leaf,
                    guides: guide(.down, to: downGuide)
                )
            )
        }
        return FocusNode(
            DetailFocusIDs.movieActions,
            kind: .container(.horizontal),
            preferredFocus: DetailFocusIDs.movieStart,
            children: children
        )
    }

    private static func showActionRow(
        includeContinue: Bool,
        downGuide: FocusNodeID?
    ) -> FocusNode {
        var children = [
            FocusNode(
                DetailFocusIDs.showStart,
                kind: .leaf,
                guides: guide(.down, to: downGuide)
            )
        ]
        if includeContinue {
            children.append(
                FocusNode(
                    DetailFocusIDs.showContinue,
                    kind: .leaf,
                    guides: guide(.down, to: downGuide)
                )
            )
        }
        return FocusNode(
            DetailFocusIDs.showActions,
            kind: .container(.horizontal),
            preferredFocus: DetailFocusIDs.showStart,
            children: children
        )
    }

    private static func moreLikePreferredID(
        count: Int,
        preferred: Int,
        makeID: (Int) -> FocusNodeID
    ) -> FocusNodeID? {
        guard count > 0 else { return nil }
        return makeID(min(max(preferred, 0), count - 1))
    }

    private static func personPreferredID(
        rowItemCounts: [Int],
        preferredRow: Int,
        preferredItem: Int,
        makeID: (_ row: Int, _ item: Int) -> FocusNodeID
    ) -> FocusNodeID? {
        guard let row = nearestNonEmptyRow(preferredRow, rowItemCounts: rowItemCounts) else { return nil }
        let item = min(max(preferredItem, 0), rowItemCounts[row] - 1)
        return makeID(row, item)
    }

    private static func personRows(
        rowItemCounts: [Int],
        preferredRow: Int,
        preferredItem: Int,
        makeRowID: (Int) -> FocusNodeID,
        makeID: (_ row: Int, _ item: Int) -> FocusNodeID
    ) -> [FocusNode] {
        rowItemCounts.enumerated().compactMap { row, itemCount in
            guard itemCount > 0 else { return nil }
            let preferred = row == preferredRow
                ? min(max(preferredItem, 0), itemCount - 1)
                : 0
            return FocusNode(
                makeRowID(row),
                kind: .container(.grid(columns: itemCount)),
                preferredFocus: makeID(row, preferred),
                children: (0..<itemCount).map { item in
                    FocusNode(makeID(row, item), kind: .leaf)
                }
            )
        }
    }

    private static func nearestNonEmptyRow(_ proposed: Int, rowItemCounts: [Int]) -> Int? {
        rowItemCounts.enumerated()
            .filter { $0.element > 0 }
            .min { lhs, rhs in
                abs(lhs.offset - proposed) < abs(rhs.offset - proposed)
            }?
            .offset
    }

    private static func firstExisting(_ ids: [FocusNodeID?]) -> FocusNodeID? {
        ids.first { $0 != nil } ?? nil
    }

    private static func guide(_ direction: FocusDirection, to target: FocusNodeID?) -> [FocusDirection: FocusNodeID] {
        guard let target else { return [:] }
        return [direction: target]
    }
}

#if DEBUG
enum VerifyDetailFocusHarness {
    static let launchArgument = "--verify-detail-focus-engine"

    static func runIfRequested() {
        guard CommandLine.arguments.contains(launchArgument) else { return }

        do {
            let detail = try runScenario()
            FileHandle.standardError.write(Data("verify-detail-focus-engine: PASS detailTraversal: \(detail)\n".utf8))
            FileHandle.standardError.write(Data("verify-detail-focus-engine: outcome=verified passed=1/1\n".utf8))
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("verify-detail-focus-engine: FAIL detailTraversal: \(error)\n".utf8))
            FileHandle.standardError.write(Data("verify-detail-focus-engine: outcome=failed passed=0/1\n".utf8))
            exit(1)
        }
    }

    private static func runScenario() throws -> String {
        try verifyMovieTraversal()
        try verifyShowTraversal()
        try verifyStatefulActionRowReentry()
        try verifyMoreLikeRowsUseGrid()
        try verifyPersonRowsAreRemoteReachable()
        try verifyShowAdapterReconciliationPolicy()
        try verifyDetailSourceAdoption()
        return "movie/show detail engine trees, stateful action-row re-entry, conditional continue membership, show overview action, season stepper, episode entry, related-row guides, person-row focus, show adapter reconciliation, and source adoption verified"
    }

    private static func verifyMovieTraversal() throws {
        let fullEngine = FocusEngine(root: DetailFocusTree.movie(MovieDetailFocusConfiguration(
            hasContinueAction: true,
            hasShowMore: true,
            moreLikeCount: 3,
            preferredMoreLikeIndex: 1
        )))
        try verifyMoves(
            fullEngine,
            [
                MoveCase(DetailFocusIDs.movieBack, .down, .focus(DetailFocusIDs.movieStart)),
                MoveCase(DetailFocusIDs.movieBack, .up, .boundary),
                MoveCase(DetailFocusIDs.movieStart, .right, .focus(DetailFocusIDs.movieContinue)),
                MoveCase(DetailFocusIDs.movieContinue, .left, .focus(DetailFocusIDs.movieStart)),
                MoveCase(DetailFocusIDs.movieContinue, .down, .focus(DetailFocusIDs.movieShowMore)),
                MoveCase(DetailFocusIDs.movieShowMore, .up, .focus(DetailFocusIDs.movieStart)),
                MoveCase(DetailFocusIDs.movieShowMore, .down, .focus(DetailFocusIDs.movieMoreLike(1))),
                MoveCase(DetailFocusIDs.movieMoreLike(1), .left, .focus(DetailFocusIDs.movieMoreLike(0))),
                MoveCase(DetailFocusIDs.movieMoreLike(1), .right, .focus(DetailFocusIDs.movieMoreLike(2))),
                MoveCase(DetailFocusIDs.movieMoreLike(2), .up, .focus(DetailFocusIDs.movieShowMore)),
                MoveCase(DetailFocusIDs.movieMoreLike(2), .down, .boundary)
            ]
        )

        let compactEngine = FocusEngine(root: DetailFocusTree.movie(MovieDetailFocusConfiguration(
            hasContinueAction: false,
            hasShowMore: false,
            moreLikeCount: 2,
            preferredMoreLikeIndex: 0
        )))
        try verifyMoves(
            compactEngine,
            [
                MoveCase(DetailFocusIDs.movieStart, .right, .boundary),
                MoveCase(DetailFocusIDs.movieStart, .down, .focus(DetailFocusIDs.movieMoreLike(0))),
                MoveCase(DetailFocusIDs.movieMoreLike(1), .up, .focus(DetailFocusIDs.movieStart))
            ]
        )
    }

    private static func verifyMoreLikeRowsUseGrid() throws {
        let movieTree = DetailFocusTree.movie(MovieDetailFocusConfiguration(
            hasContinueAction: true,
            hasShowMore: true,
            moreLikeCount: 3,
            preferredMoreLikeIndex: 1
        ))
        try assert(
            nodeKind(DetailFocusIDs.movieMoreLikeRow, in: movieTree) == .container(.grid(columns: 3)),
            "movie More Like row must be represented as a one-row grid"
        )

        let showTree = DetailFocusTree.show(ShowDetailFocusConfiguration(
            hasBack: true,
            hasStartAction: true,
            hasContinueAction: true,
            hasOverview: true,
            hasSeasonStepper: true,
            episodeCount: 4,
            moreLikeCount: 3,
            preferredMoreLikeIndex: 1
        ))
        try assert(
            nodeKind(DetailFocusIDs.showMoreLikeRow, in: showTree) == .container(.grid(columns: 3)),
            "show More Like row must be represented as a one-row grid"
        )
    }

    private static func verifyPersonRowsAreRemoteReachable() throws {
        let movieEngine = FocusEngine(root: DetailFocusTree.movie(MovieDetailFocusConfiguration(
            hasContinueAction: true,
            hasShowMore: true,
            moreLikeCount: 3,
            preferredMoreLikeIndex: 1,
            personRowItemCounts: [2, 3],
            preferredPersonRowIndex: 0,
            preferredPersonItemIndex: 1
        )))
        try verifyMoves(
            movieEngine,
            [
                MoveCase(DetailFocusIDs.movieMoreLike(1), .down, .focus(DetailFocusIDs.moviePerson(row: 0, item: 1))),
                MoveCase(DetailFocusIDs.moviePerson(row: 0, item: 1), .left, .focus(DetailFocusIDs.moviePerson(row: 0, item: 0))),
                MoveCase(DetailFocusIDs.moviePerson(row: 0, item: 1), .down, .focus(DetailFocusIDs.moviePerson(row: 1, item: 1))),
                MoveCase(DetailFocusIDs.moviePerson(row: 1, item: 1), .up, .focus(DetailFocusIDs.moviePerson(row: 0, item: 1)))
            ]
        )
        let movieTree = DetailFocusTree.movie(MovieDetailFocusConfiguration(
            hasContinueAction: true,
            hasShowMore: true,
            moreLikeCount: 3,
            preferredMoreLikeIndex: 1,
            personRowItemCounts: [2],
            preferredPersonRowIndex: 0,
            preferredPersonItemIndex: 0
        ))
        try assert(
            nodeKind(DetailFocusIDs.moviePersonRow(0), in: movieTree) == .container(.grid(columns: 2)),
            "movie person rows must be represented as one-row grids"
        )

        let showEngine = FocusEngine(root: DetailFocusTree.show(ShowDetailFocusConfiguration(
            hasBack: true,
            hasStartAction: true,
            hasContinueAction: true,
            hasOverview: true,
            hasSeasonStepper: true,
            episodeCount: 4,
            moreLikeCount: 3,
            preferredMoreLikeIndex: 1,
            personRowItemCounts: [2, 3],
            preferredPersonRowIndex: 0,
            preferredPersonItemIndex: 1
        )))
        try verifyMoves(
            showEngine,
            [
                MoveCase(DetailFocusIDs.showMoreLike(1), .down, .focus(DetailFocusIDs.showPerson(row: 0, item: 1))),
                MoveCase(DetailFocusIDs.showPerson(row: 0, item: 0), .right, .focus(DetailFocusIDs.showPerson(row: 0, item: 1))),
                MoveCase(DetailFocusIDs.showPerson(row: 0, item: 1), .down, .focus(DetailFocusIDs.showPerson(row: 1, item: 1))),
                MoveCase(DetailFocusIDs.showPerson(row: 1, item: 1), .up, .focus(DetailFocusIDs.showPerson(row: 0, item: 1)))
            ]
        )
        let showTree = DetailFocusTree.show(ShowDetailFocusConfiguration(
            hasBack: true,
            hasStartAction: true,
            hasContinueAction: true,
            hasOverview: true,
            hasSeasonStepper: true,
            episodeCount: 4,
            moreLikeCount: 3,
            preferredMoreLikeIndex: 1,
            personRowItemCounts: [2],
            preferredPersonRowIndex: 0,
            preferredPersonItemIndex: 0
        ))
        try assert(
            nodeKind(DetailFocusIDs.showPersonRow(0), in: showTree) == .container(.grid(columns: 2)),
            "show person rows must be represented as one-row grids"
        )
    }

    private static func verifyShowAdapterReconciliationPolicy() throws {
        let fullContext = ShowDetailFocusReconciliationContext(
            state: FocusEngineState(focused: DetailFocusIDs.showOverview),
            firstAvailableFocus: DetailFocusIDs.showStart,
            hasBack: true,
            hasStartAction: true,
            hasContinueAction: true,
            hasOverview: true,
            hasSeasonStepper: true,
            areDeferredSectionsVisible: true,
            episodeCount: 4,
            moreLikeCount: 3,
            proposedEpisodeIndex: 0,
            proposedMoreLikeIndex: 0
        )
        try assert(
            ShowDetailFocusReconciler.reconcile(fullContext).state.focused == DetailFocusIDs.showOverview,
            "valid show overview focus must not reset to the start action"
        )
        try assert(
            ShowDetailFocusReconciler.reconcile(fullContext.withFocus(DetailFocusIDs.showContinue)).state.focused == DetailFocusIDs.showContinue,
            "valid show continue focus must not reset to the start action"
        )
        try assert(
            ShowDetailFocusReconciler.reconcile(fullContext.withFocus(DetailFocusIDs.showSeasons)).state.focused == DetailFocusIDs.showSeasons,
            "valid show seasons stepper focus must not reset to the start action"
        )
        let episodeResult = ShowDetailFocusReconciler.reconcile(fullContext.withFocus(DetailFocusIDs.showEpisode(99)))
        try assert(
            episodeResult.state.focused == DetailFocusIDs.showEpisode(3) &&
                episodeResult.focusedEpisodeIndex == 3,
            "stale show episode focus must clamp to the mounted episode range"
        )
        let moreLikeResult = ShowDetailFocusReconciler.reconcile(fullContext.withFocus(DetailFocusIDs.showMoreLike(99)))
        try assert(
            moreLikeResult.state.focused == DetailFocusIDs.showMoreLike(2) &&
                moreLikeResult.moreLikeFocusedIndex == 2,
            "stale show More Like focus must clamp to the mounted related range"
        )
        try assert(
            ShowDetailFocusReconciler.reconcile(fullContext.withFocus(DetailFocusIDs.showOverview, hasOverview: false)).state.focused == DetailFocusIDs.showStart,
            "unmounted show overview focus must fall back to the first available action"
        )
        try assert(
            ShowDetailFocusReconciler.reconcile(fullContext.withFocus(DetailFocusIDs.showSeasons, areDeferredSectionsVisible: false)).state.focused == DetailFocusIDs.showStart,
            "unmounted show seasons focus must fall back to the first available action"
        )

        try verifySource(
            path: "Marquee/Features/Library/Views/ShowDetailView.swift",
            removedTokens: [],
            requiredTokens: [
                "ShowDetailFocusReconciler.reconcile("
            ]
        )
    }

    private static func nodeKind(_ id: FocusNodeID, in node: FocusNode) -> FocusNodeKind? {
        if node.id == id {
            return node.kind
        }
        for child in node.children {
            if let kind = nodeKind(id, in: child) {
                return kind
            }
        }
        return nil
    }

    private static func verifyShowTraversal() throws {
        let fullEngine = FocusEngine(root: DetailFocusTree.show(ShowDetailFocusConfiguration(
            hasBack: true,
            hasStartAction: true,
            hasContinueAction: true,
            hasOverview: true,
            hasSeasonStepper: true,
            episodeCount: 4,
            moreLikeCount: 3,
            preferredMoreLikeIndex: 1
        )))
        try verifyMoves(
            fullEngine,
            [
                MoveCase(DetailFocusIDs.showBack, .down, .focus(DetailFocusIDs.showStart)),
                MoveCase(DetailFocusIDs.showStart, .right, .focus(DetailFocusIDs.showContinue)),
                MoveCase(DetailFocusIDs.showContinue, .left, .focus(DetailFocusIDs.showStart)),
                MoveCase(DetailFocusIDs.showContinue, .down, .focus(DetailFocusIDs.showOverview)),
                MoveCase(DetailFocusIDs.showOverview, .up, .focus(DetailFocusIDs.showStart)),
                MoveCase(DetailFocusIDs.showOverview, .down, .focus(DetailFocusIDs.showSeasons)),
                MoveCase(DetailFocusIDs.showSeasons, .up, .focus(DetailFocusIDs.showOverview)),
                MoveCase(DetailFocusIDs.showSeasons, .right, .stepper(delta: 1)),
                MoveCase(DetailFocusIDs.showSeasons, .down, .focus(DetailFocusIDs.showEpisode(0))),
                MoveCase(DetailFocusIDs.showEpisode(0), .down, .focus(DetailFocusIDs.showEpisode(1))),
                MoveCase(DetailFocusIDs.showEpisode(0), .up, .focus(DetailFocusIDs.showSeasons)),
                MoveCase(DetailFocusIDs.showEpisode(2), .left, .focus(DetailFocusIDs.showSeasons)),
                MoveCase(DetailFocusIDs.showEpisode(3), .down, .focus(DetailFocusIDs.showMoreLike(1))),
                MoveCase(DetailFocusIDs.showMoreLike(0), .up, .focus(DetailFocusIDs.showEpisode(3))),
                MoveCase(DetailFocusIDs.showMoreLike(1), .right, .focus(DetailFocusIDs.showMoreLike(2)))
            ]
        )

        let compactEngine = FocusEngine(root: DetailFocusTree.show(ShowDetailFocusConfiguration(
            hasBack: false,
            hasStartAction: true,
            hasContinueAction: false,
            hasOverview: false,
            hasSeasonStepper: false,
            episodeCount: 2,
            moreLikeCount: 2,
            preferredMoreLikeIndex: 0
        )))
        try verifyMoves(
            compactEngine,
            [
                MoveCase(DetailFocusIDs.showStart, .right, .boundary),
                MoveCase(DetailFocusIDs.showStart, .down, .focus(DetailFocusIDs.showEpisode(0))),
                MoveCase(DetailFocusIDs.showEpisode(1), .left, .focus(DetailFocusIDs.showStart)),
                MoveCase(DetailFocusIDs.showEpisode(1), .down, .focus(DetailFocusIDs.showMoreLike(0))),
                MoveCase(DetailFocusIDs.showMoreLike(1), .up, .focus(DetailFocusIDs.showEpisode(1)))
            ]
        )
    }

    private static func verifyStatefulActionRowReentry() throws {
        let movieEngine = FocusEngine(root: DetailFocusTree.movie(MovieDetailFocusConfiguration(
            hasContinueAction: true,
            hasShowMore: true,
            moreLikeCount: 3,
            preferredMoreLikeIndex: 1
        )))
        var movieState = FocusEngineState(focused: DetailFocusIDs.movieStart)
        movieState = try expectMove(movieEngine, movieState, .right, DetailFocusIDs.movieContinue)
        movieState = try expectMove(movieEngine, movieState, .down, DetailFocusIDs.movieShowMore)
        movieState = try expectMove(movieEngine, movieState, .up, DetailFocusIDs.movieStart)
        var movieBackState = FocusEngineState(focused: DetailFocusIDs.movieStart)
        movieBackState = try expectMove(movieEngine, movieBackState, .right, DetailFocusIDs.movieContinue)
        movieBackState = try expectMove(movieEngine, movieBackState, .up, DetailFocusIDs.movieBack)
        _ = try expectMove(movieEngine, movieBackState, .down, DetailFocusIDs.movieStart)

        let showEngine = FocusEngine(root: DetailFocusTree.show(ShowDetailFocusConfiguration(
            hasBack: true,
            hasStartAction: true,
            hasContinueAction: true,
            hasOverview: true,
            hasSeasonStepper: true,
            episodeCount: 4,
            moreLikeCount: 3,
            preferredMoreLikeIndex: 1
        )))
        var showState = FocusEngineState(focused: DetailFocusIDs.showStart)
        showState = try expectMove(showEngine, showState, .right, DetailFocusIDs.showContinue)
        showState = try expectMove(showEngine, showState, .down, DetailFocusIDs.showOverview)
        _ = try expectMove(showEngine, showState, .up, DetailFocusIDs.showStart)
        var showBackState = FocusEngineState(focused: DetailFocusIDs.showStart)
        showBackState = try expectMove(showEngine, showBackState, .right, DetailFocusIDs.showContinue)
        showBackState = try expectMove(showEngine, showBackState, .up, DetailFocusIDs.showBack)
        _ = try expectMove(showEngine, showBackState, .down, DetailFocusIDs.showStart)

        let seasonFirstShowEngine = FocusEngine(root: DetailFocusTree.show(ShowDetailFocusConfiguration(
            hasBack: true,
            hasStartAction: true,
            hasContinueAction: true,
            hasOverview: false,
            hasSeasonStepper: true,
            episodeCount: 4,
            moreLikeCount: 3,
            preferredMoreLikeIndex: 1
        )))
        var seasonFirstState = FocusEngineState(focused: DetailFocusIDs.showStart)
        seasonFirstState = try expectMove(seasonFirstShowEngine, seasonFirstState, .right, DetailFocusIDs.showContinue)
        seasonFirstState = try expectMove(seasonFirstShowEngine, seasonFirstState, .down, DetailFocusIDs.showSeasons)
        _ = try expectMove(seasonFirstShowEngine, seasonFirstState, .up, DetailFocusIDs.showStart)
        var seasonSteppedState = FocusEngineState(focused: DetailFocusIDs.showSeasons)
        seasonSteppedState.rememberedChildByContainer[DetailFocusIDs.showEpisodes] = DetailFocusIDs.showEpisode(3)
        seasonSteppedState = ShowDetailFocusReconciler.resettingEpisodeMemoryAfterSeasonChange(seasonSteppedState)
        _ = try expectMove(seasonFirstShowEngine, seasonSteppedState, .down, DetailFocusIDs.showEpisode(0))

        let episodeFirstShowEngine = FocusEngine(root: DetailFocusTree.show(ShowDetailFocusConfiguration(
            hasBack: true,
            hasStartAction: true,
            hasContinueAction: true,
            hasOverview: false,
            hasSeasonStepper: false,
            episodeCount: 4,
            moreLikeCount: 3,
            preferredMoreLikeIndex: 1
        )))
        var episodeFirstState = FocusEngineState(focused: DetailFocusIDs.showStart)
        episodeFirstState = try expectMove(episodeFirstShowEngine, episodeFirstState, .right, DetailFocusIDs.showContinue)
        episodeFirstState = try expectMove(episodeFirstShowEngine, episodeFirstState, .down, DetailFocusIDs.showEpisode(0))
        _ = try expectMove(episodeFirstShowEngine, episodeFirstState, .up, DetailFocusIDs.showStart)
    }

    private static func expectMove(
        _ engine: FocusEngine,
        _ state: FocusEngineState,
        _ direction: FocusDirection,
        _ expected: FocusNodeID
    ) throws -> FocusEngineState {
        let result = engine.move(direction, state: state)
        try assert(
            result.state.focused == expected,
            "expected stateful \(direction) from \(state.focused) to focus \(expected), got \(result.state.focused) with events \(result.events)"
        )
        try assert(
            result.events == [.focusChanged(from: state.focused, to: expected)],
            "expected stateful focusChanged from \(state.focused) to \(expected), got \(result.events)"
        )
        return result.state
    }

    private static func verifyDetailSourceAdoption() throws {
        try verifySource(
            path: "Marquee/Features/Detail/Views/MovieDetailView.swift",
            removedTokens: [
                "MovieDetailRemoteFocus",
                "verticalFocusOrder",
                "moveRemoteFocusHorizontally",
                "moveRemoteFocusVertically",
                "remoteLiftFocused"
            ],
            requiredTokens: [
                "FocusEngine(root: movieDetailFocusTree())",
                "DetailFocusIDs.movieStart",
                "DetailFocusIDs.movieMoreLike",
                "isRemoteFocused: isFocused(DetailFocusIDs.movieMoreLike(index))",
                "focusScrollMode: .detailRow",
                "focusAccent: detailFocusAccent"
            ]
        )
        try verifySource(
            path: "Marquee/Features/Library/Views/ShowDetailView.swift",
            removedTokens: [
                "ShowDetailRemoteFocus",
                "verticalFocusOrder",
                "moveRemoteFocusHorizontally",
                "moveRemoteFocusVertically",
                "remoteLiftFocused"
            ],
            requiredTokens: [
                "FocusEngine(root: showDetailFocusTree())",
                "DetailFocusIDs.showOverview",
                "DetailFocusIDs.showSeasons",
                "DetailFocusIDs.showEpisode",
                "isRemoteFocused: isFocused(DetailFocusIDs.showMoreLike(index))",
                "focusScrollMode: .detailRow",
                "focusAccent: detailFocusAccent"
            ]
        )
    }

    private static func verifySource(
        path: String,
        removedTokens: [String],
        requiredTokens: [String]
    ) throws {
        let root = FileManager.default.currentDirectoryPath
        let source = try String(contentsOfFile: "\(root)/\(path)")
        for token in removedTokens {
            try assert(!source.contains(token), "\(path) still contains old detail focus token \(token)")
        }
        for token in requiredTokens {
            try assert(source.contains(token), "\(path) is missing detail focus engine token \(token)")
        }
    }

    private enum ExpectedMove {
        case focus(FocusNodeID)
        case boundary
        case stepper(delta: Int)
    }

    private struct MoveCase {
        let from: FocusNodeID
        let direction: FocusDirection
        let expected: ExpectedMove

        init(_ from: FocusNodeID, _ direction: FocusDirection, _ expected: ExpectedMove) {
            self.from = from
            self.direction = direction
            self.expected = expected
        }
    }

    private static func verifyMoves(_ engine: FocusEngine, _ cases: [MoveCase]) throws {
        for moveCase in cases {
            let state = FocusEngineState(focused: moveCase.from)
            let result = engine.move(moveCase.direction, state: state)
            switch moveCase.expected {
            case let .focus(expected):
                try assert(
                    result.state.focused == expected,
                    "expected \(moveCase.direction) from \(moveCase.from) to focus \(expected), got \(result.state.focused) with events \(result.events)"
                )
                try assert(
                    result.events == [.focusChanged(from: moveCase.from, to: expected)],
                    "expected focusChanged from \(moveCase.from) to \(expected), got \(result.events)"
                )
            case .boundary:
                try assert(
                    result.state.focused == moveCase.from,
                    "expected boundary from \(moveCase.from) \(moveCase.direction), got focus \(result.state.focused)"
                )
                try assert(
                    result.events == [.boundaryHit(moveCase.from, moveCase.direction)],
                    "expected boundary event from \(moveCase.from) \(moveCase.direction), got \(result.events)"
                )
            case let .stepper(delta):
                try assert(
                    result.state.focused == moveCase.from,
                    "expected stepper to keep focus on \(moveCase.from), got \(result.state.focused)"
                )
                try assert(
                    result.events == [.stepperActivated(FocusStepperActivation(nodeID: moveCase.from, delta: delta))],
                    "expected stepper delta \(delta) on \(moveCase.from), got \(result.events)"
                )
            }
        }
    }

    private static func assert(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw HarnessError(message) }
    }

    private struct HarnessError: Error, CustomStringConvertible {
        let description: String

        init(_ description: String) {
            self.description = description
        }
    }
}

private extension ShowDetailFocusReconciliationContext {
    func withFocus(
        _ focus: FocusNodeID,
        hasOverview: Bool? = nil,
        areDeferredSectionsVisible: Bool? = nil
    ) -> ShowDetailFocusReconciliationContext {
        ShowDetailFocusReconciliationContext(
            state: FocusEngineState(focused: focus),
            firstAvailableFocus: firstAvailableFocus,
            hasBack: hasBack,
            hasStartAction: hasStartAction,
            hasContinueAction: hasContinueAction,
            hasOverview: hasOverview ?? self.hasOverview,
            hasSeasonStepper: hasSeasonStepper,
            areDeferredSectionsVisible: areDeferredSectionsVisible ?? self.areDeferredSectionsVisible,
            episodeCount: episodeCount,
            moreLikeCount: moreLikeCount,
            proposedEpisodeIndex: proposedEpisodeIndex,
            proposedMoreLikeIndex: proposedMoreLikeIndex
        )
    }
}
#endif
