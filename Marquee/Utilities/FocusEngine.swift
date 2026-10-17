import Foundation

struct FocusNodeID: Hashable, ExpressibleByStringLiteral, CustomStringConvertible {
    let rawValue: String

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    init(stringLiteral value: String) {
        self.init(value)
    }

    var description: String { rawValue }
}

enum FocusDirection: CaseIterable, Hashable {
    case up
    case down
    case left
    case right
}

enum FocusAxis: Equatable {
    case horizontal
    case vertical
}

enum FocusNodeKind: Equatable {
    case container(FocusContainerKind)
    case leaf
    case stepper(axis: FocusAxis)
}

enum FocusContainerKind: Equatable {
    case horizontal
    case vertical
    case grid(columns: Int)
}

enum FocusStyle: CaseIterable {
    case cardLift
    case buttonRing
    case sectionRing
}

enum FocusRenderingStrategy: Equatable {
    case structuralInsertRemove
}

enum FocusStyleSurface {
    static func renderingStrategy(for style: FocusStyle) -> FocusRenderingStrategy {
        .structuralInsertRemove
    }

    static func focusRingNodeCount(style: FocusStyle, isFocused: Bool) -> Int {
        isFocused ? 1 : 0
    }
}

struct FocusNode {
    let id: FocusNodeID
    let kind: FocusNodeKind
    let preferredFocus: FocusNodeID?
    let guides: [FocusDirection: FocusNodeID]
    let children: [FocusNode]

    /// When a move leaves this container, hand the sibling the focused child's
    /// visual grid column instead of its flat descendant index. Single-row
    /// containers are unaffected because the two are equal there; multi-row
    /// grids need it so leaving row 2 column 1 enters the sibling at column 1
    /// rather than at index 5. Off by default, so existing trees are unchanged.
    let carriesGridColumn: Bool

    init(
        _ id: FocusNodeID,
        kind: FocusNodeKind,
        preferredFocus: FocusNodeID? = nil,
        guides: [FocusDirection: FocusNodeID] = [:],
        children: [FocusNode] = [],
        carriesGridColumn: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.preferredFocus = preferredFocus
        self.guides = guides
        self.children = children
        self.carriesGridColumn = carriesGridColumn
    }
}

struct FocusEngineState: Equatable {
    var focused: FocusNodeID
    var rememberedChildByContainer: [FocusNodeID: FocusNodeID] = [:]
    var preferredGridColumnByContainer: [FocusNodeID: Int] = [:]
}

struct FocusStepperActivation: Equatable {
    let nodeID: FocusNodeID
    let delta: Int
}

enum FocusEngineEvent: Equatable {
    case focusChanged(from: FocusNodeID, to: FocusNodeID)
    case boundaryHit(FocusNodeID, FocusDirection)
    case stepperActivated(FocusStepperActivation)
    case restored(FocusNodeID)
}

struct FocusEngineResult: Equatable {
    var state: FocusEngineState
    var events: [FocusEngineEvent]
}

struct FocusEngine {
    let root: FocusNode

    func move(_ direction: FocusDirection, state: FocusEngineState) -> FocusEngineResult {
        let index = FocusEngineIndex(root: root)
        guard let current = index.node(state.focused) else {
            return boundaryResult(direction, state: state)
        }

        if let activation = stepperActivation(for: current, direction: direction) {
            return FocusEngineResult(
                state: state,
                events: [.stepperActivated(activation)]
            )
        }

        if let targetID = current.guides[direction],
           let target = index.focusTarget(for: targetID, state: state, hintIndex: nil) {
            return focusResult(to: target.id, direction: direction, state: state, index: index)
        }

        guard let path = index.path(to: state.focused), path.count >= 2 else {
            return boundaryResult(direction, state: state)
        }

        for parentIndex in stride(from: path.count - 2, through: 0, by: -1) {
            let container = path[parentIndex]
            let child = path[parentIndex + 1]
            guard let movement = movementTarget(
                in: container,
                from: child,
                focused: state.focused,
                direction: direction,
                state: state,
                index: index
            ) else {
                continue
            }

            return focusResult(
                to: movement.target.id,
                direction: direction,
                state: state,
                index: index,
                gridColumnOverride: movement.gridColumnOverride
            )
        }

        return boundaryResult(direction, state: state)
    }

    func restoreFocus(in containerID: FocusNodeID, state: FocusEngineState) -> FocusEngineResult {
        let index = FocusEngineIndex(root: root)
        guard let container = index.node(containerID),
              let target = restoreTarget(in: container, state: state, index: index) else {
            return FocusEngineResult(state: state, events: [.restored(state.focused)])
        }

        let updated = stateAfterFocusing(
            target.id,
            state: state,
            index: index,
            gridColumnOverride: nil
        )
        return FocusEngineResult(state: updated, events: [.restored(target.id)])
    }

    private func stepperActivation(
        for node: FocusNode,
        direction: FocusDirection
    ) -> FocusStepperActivation? {
        guard case let .stepper(axis) = node.kind else { return nil }

        switch (axis, direction) {
        case (.horizontal, .left), (.vertical, .up):
            return FocusStepperActivation(nodeID: node.id, delta: -1)
        case (.horizontal, .right), (.vertical, .down):
            return FocusStepperActivation(nodeID: node.id, delta: 1)
        default:
            return nil
        }
    }

    private struct MovementTarget {
        let target: FocusNode
        let gridColumnOverride: (FocusNodeID, Int)?
    }

    private func movementTarget(
        in container: FocusNode,
        from child: FocusNode,
        focused: FocusNodeID,
        direction: FocusDirection,
        state: FocusEngineState,
        index: FocusEngineIndex
    ) -> MovementTarget? {
        guard case let .container(kind) = container.kind else { return nil }

        switch kind {
        case .horizontal:
            guard direction == .left || direction == .right,
                  let childIndex = container.children.firstIndex(where: { $0.id == child.id }) else {
                return nil
            }
            let targetIndex = childIndex + (direction == .left ? -1 : 1)
            guard container.children.indices.contains(targetIndex),
                  let target = index.focusTarget(
                    in: container.children[targetIndex],
                    state: state,
                    hintIndex: descendantIndex(in: child, focused: focused, index: index)
                  ) else {
                return nil
            }
            return MovementTarget(target: target, gridColumnOverride: nil)

        case .vertical:
            guard direction == .up || direction == .down,
                  let childIndex = container.children.firstIndex(where: { $0.id == child.id }) else {
                return nil
            }
            let targetIndex = childIndex + (direction == .up ? -1 : 1)
            guard container.children.indices.contains(targetIndex),
                  let target = index.focusTarget(
                    in: container.children[targetIndex],
                    state: state,
                    hintIndex: descendantIndex(in: child, focused: focused, index: index)
                  ) else {
                return nil
            }
            return MovementTarget(target: target, gridColumnOverride: nil)

        case let .grid(columns):
            guard columns > 0,
                  let childIndex = container.children.firstIndex(where: { $0.id == child.id }) else {
                return nil
            }

            if direction == .left || direction == .right {
                let delta = direction == .left ? -1 : 1
                let targetIndex = childIndex + delta
                guard container.children.indices.contains(targetIndex),
                      childIndex / columns == targetIndex / columns,
                      let target = index.focusTarget(
                        in: container.children[targetIndex],
                        state: state,
                        hintIndex: nil
                      ) else {
                    return nil
                }
                return MovementTarget(
                    target: target,
                    gridColumnOverride: (container.id, targetIndex % columns)
                )
            }

            let desiredColumn = state.preferredGridColumnByContainer[container.id]
                ?? (childIndex % columns)
            let targetRow = (childIndex / columns) + (direction == .up ? -1 : 1)
            guard targetRow >= 0 else { return nil }
            let rowStart = targetRow * columns
            guard rowStart < container.children.count else { return nil }
            let rowEnd = min(rowStart + columns, container.children.count)
            let targetIndex = (rowStart..<rowEnd).min { lhs, rhs in
                abs((lhs % columns) - desiredColumn) < abs((rhs % columns) - desiredColumn)
            }
            guard let targetIndex,
                  let target = index.focusTarget(
                    in: container.children[targetIndex],
                    state: state,
                    hintIndex: nil
                  ) else {
                return nil
            }
            return MovementTarget(
                target: target,
                gridColumnOverride: (container.id, desiredColumn)
            )
        }
    }

    private func descendantIndex(
        in node: FocusNode,
        focused: FocusNodeID,
        index: FocusEngineIndex
    ) -> Int? {
        let descendants = index.focusableDescendants(in: node)
        guard let flatIndex = descendants.firstIndex(where: { $0.id == focused }) else {
            return nil
        }
        guard node.carriesGridColumn,
              case let .container(.grid(columns)) = node.kind,
              columns > 0 else {
            return flatIndex
        }
        return flatIndex % columns
    }

    private func restoreTarget(
        in container: FocusNode,
        state: FocusEngineState,
        index: FocusEngineIndex
    ) -> FocusNode? {
        if let remembered = state.rememberedChildByContainer[container.id],
           index.contains(container.id, descendant: remembered),
           let target = index.focusTarget(for: remembered, state: state, hintIndex: nil) {
            return target
        }

        if let preferred = container.preferredFocus,
           index.contains(container.id, descendant: preferred),
           let target = index.focusTarget(for: preferred, state: state, hintIndex: nil) {
            return target
        }

        return index.focusTarget(in: container, state: state, hintIndex: nil)
    }

    private func focusResult(
        to target: FocusNodeID,
        direction: FocusDirection,
        state: FocusEngineState,
        index: FocusEngineIndex,
        gridColumnOverride: (FocusNodeID, Int)? = nil
    ) -> FocusEngineResult {
        guard target != state.focused else {
            return boundaryResult(direction, state: state)
        }

        let updated = stateAfterFocusing(
            target,
            state: state,
            index: index,
            gridColumnOverride: gridColumnOverride
        )
        return FocusEngineResult(
            state: updated,
            events: [.focusChanged(from: state.focused, to: target)]
        )
    }

    private func boundaryResult(
        _ direction: FocusDirection,
        state: FocusEngineState
    ) -> FocusEngineResult {
        FocusEngineResult(
            state: state,
            events: [.boundaryHit(state.focused, direction)]
        )
    }

    private func stateAfterFocusing(
        _ target: FocusNodeID,
        state: FocusEngineState,
        index: FocusEngineIndex,
        gridColumnOverride: (FocusNodeID, Int)?
    ) -> FocusEngineState {
        guard let path = index.path(to: target) else { return state }

        var next = state
        next.focused = target

        if path.count >= 2 {
            for parentIndex in 0..<(path.count - 1) {
                let parent = path[parentIndex]
                let child = path[parentIndex + 1]
                if case let .container(kind) = parent.kind {
                    next.rememberedChildByContainer[parent.id] = child.id
                    if case let .grid(columns) = kind,
                       columns > 0,
                       let childIndex = parent.children.firstIndex(where: { $0.id == child.id }) {
                        next.preferredGridColumnByContainer[parent.id] = childIndex % columns
                    }
                }
            }
        }

        if let (containerID, column) = gridColumnOverride {
            next.preferredGridColumnByContainer[containerID] = column
        }

        return next
    }
}

private struct FocusEngineIndex {
    private let nodesByID: [FocusNodeID: FocusNode]
    private let pathsByID: [FocusNodeID: [FocusNode]]

    init(root: FocusNode) {
        var nodes: [FocusNodeID: FocusNode] = [:]
        var paths: [FocusNodeID: [FocusNode]] = [:]

        func visit(_ node: FocusNode, path: [FocusNode]) {
            let nextPath = path + [node]
            nodes[node.id] = node
            paths[node.id] = nextPath
            for child in node.children {
                visit(child, path: nextPath)
            }
        }

        visit(root, path: [])
        self.nodesByID = nodes
        self.pathsByID = paths
    }

    func node(_ id: FocusNodeID) -> FocusNode? {
        nodesByID[id]
    }

    func path(to id: FocusNodeID) -> [FocusNode]? {
        pathsByID[id]
    }

    func contains(_ ancestor: FocusNodeID, descendant: FocusNodeID) -> Bool {
        guard let path = pathsByID[descendant] else { return false }
        return path.dropLast().contains { $0.id == ancestor }
    }

    func focusTarget(
        for id: FocusNodeID,
        state: FocusEngineState,
        hintIndex: Int?
    ) -> FocusNode? {
        guard let node = nodesByID[id] else { return nil }
        return focusTarget(in: node, state: state, hintIndex: hintIndex)
    }

    func focusTarget(
        in node: FocusNode,
        state: FocusEngineState,
        hintIndex: Int?
    ) -> FocusNode? {
        switch node.kind {
        case .leaf, .stepper:
            return node
        case .container:
            if let remembered = state.rememberedChildByContainer[node.id],
               contains(node.id, descendant: remembered),
               let target = focusTarget(for: remembered, state: state, hintIndex: nil) {
                return target
            }

            let descendants = focusableDescendants(in: node)
            if let hintIndex,
               !descendants.isEmpty {
                return descendants[min(max(hintIndex, 0), descendants.count - 1)]
            }

            if let preferred = node.preferredFocus,
               contains(node.id, descendant: preferred),
               let target = focusTarget(for: preferred, state: state, hintIndex: nil) {
                return target
            }

            return descendants.first
        }
    }

    func focusableDescendants(in node: FocusNode) -> [FocusNode] {
        switch node.kind {
        case .leaf, .stepper:
            return [node]
        case .container:
            return node.children.flatMap { focusableDescendants(in: $0) }
        }
    }
}

#if DEBUG
enum VerifyFocusEngineHarness {
    static let launchArgument = "--verify-focus-engine"

    static func runIfRequested() {
        guard CommandLine.arguments.contains(launchArgument) else { return }

        do {
            let detail = try runScenario()
            FileHandle.standardError.write(Data("verify-focus-engine: PASS traversalMatrix: \(detail)\n".utf8))
            FileHandle.standardError.write(Data("verify-focus-engine: outcome=verified passed=1/1\n".utf8))
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("verify-focus-engine: FAIL traversalMatrix: \(error)\n".utf8))
            FileHandle.standardError.write(Data("verify-focus-engine: outcome=failed passed=0/1\n".utf8))
            exit(1)
        }
    }

    private static func runScenario() throws -> String {
        try verifyTraversalMatrix()
        try verifyMemoryRestoreAndGuides()
        try verifyGridColumnResolution()
        try verifySiblingEntryHintProjection()
        try verifyStepperSemantics()
        try verifyInvalidTargetsFallBack()
        try verifyStructuralRenderingSurface()

        return "lrud traversal matrix, memory/restore, guides, grid resolution, sibling entry hint projection, stepper activation, invalid-target fallback, and structural focus styling contracts verified"
    }

    private static func verifyTraversalMatrix() throws {
        let engine = FocusEngine(root: fixtureTree())
        try verifyMatrix(
            engine,
            cases: [
                MoveCase("sidebar", .up, .boundary),
                MoveCase("sidebar", .down, .boundary),
                MoveCase("sidebar", .left, .boundary),
                MoveCase("sidebar", .right, .focus("hero")),

                MoveCase("hero", .up, .boundary),
                MoveCase("hero", .down, .focus("continue-0")),
                MoveCase("hero", .left, .focus("sidebar")),
                MoveCase("hero", .right, .boundary),

                MoveCase("continue-0", .up, .focus("hero")),
                MoveCase("continue-0", .down, .focus("movie-0")),
                MoveCase("continue-0", .left, .focus("sidebar")),
                MoveCase("continue-0", .right, .focus("continue-1")),

                MoveCase("continue-1", .up, .focus("hero")),
                MoveCase("continue-1", .down, .focus("movie-1")),
                MoveCase("continue-1", .left, .focus("continue-0")),
                MoveCase("continue-1", .right, .focus("continue-2")),

                MoveCase("continue-2", .up, .focus("hero")),
                MoveCase("continue-2", .down, .focus("movie-2")),
                MoveCase("continue-2", .left, .focus("continue-1")),
                MoveCase("continue-2", .right, .boundary),

                MoveCase("movie-0", .up, .focus("continue-0")),
                MoveCase("movie-0", .down, .boundary),
                MoveCase("movie-0", .left, .focus("sidebar")),
                MoveCase("movie-0", .right, .focus("movie-1")),

                MoveCase("movie-1", .up, .focus("continue-1")),
                MoveCase("movie-1", .down, .boundary),
                MoveCase("movie-1", .left, .focus("movie-0")),
                MoveCase("movie-1", .right, .focus("movie-2")),

                MoveCase("movie-2", .up, .focus("continue-2")),
                MoveCase("movie-2", .down, .boundary),
                MoveCase("movie-2", .left, .focus("movie-1")),
                MoveCase("movie-2", .right, .focus("movie-3")),

                MoveCase("movie-3", .up, .focus("continue-2")),
                MoveCase("movie-3", .down, .boundary),
                MoveCase("movie-3", .left, .focus("movie-2")),
                MoveCase("movie-3", .right, .boundary),
            ]
        )
    }

    private static func verifyMemoryRestoreAndGuides() throws {
        let engine = FocusEngine(root: fixtureTree())
        var state = FocusEngineState(focused: "continue-0")

        state = try expectMove(engine, state, .right, "continue-1")
        state = try expectMove(engine, state, .down, "movie-1")
        state = try expectMove(engine, state, .right, "movie-2")
        state = try expectMove(engine, state, .up, "continue-1")

        let restored = engine.restoreFocus(in: "movies-row", state: state)
        try assert(restored.state.focused == "movie-2", "restore should use movies row memory, got \(restored.state.focused)")
        try assert(restored.events == [.restored("movie-2")], "restore should report restored movie-2, got \(restored.events)")

        let guided = engine.move(.left, state: FocusEngineState(focused: "hero"))
        try assert(guided.state.focused == "sidebar", "hero left guide should redirect to sidebar, got \(guided.state.focused)")
    }

    private static func verifyGridColumnResolution() throws {
        let engine = FocusEngine(root: gridFixture())
        try verifyMatrix(
            engine,
            cases: [
                MoveCase("cell-0", .up, .boundary),
                MoveCase("cell-0", .down, .focus("cell-3")),
                MoveCase("cell-0", .left, .boundary),
                MoveCase("cell-0", .right, .focus("cell-1")),

                MoveCase("cell-1", .up, .boundary),
                MoveCase("cell-1", .down, .focus("cell-4")),
                MoveCase("cell-1", .left, .focus("cell-0")),
                MoveCase("cell-1", .right, .focus("cell-2")),

                MoveCase("cell-2", .up, .boundary),
                MoveCase("cell-2", .down, .focus("cell-5")),
                MoveCase("cell-2", .left, .focus("cell-1")),
                MoveCase("cell-2", .right, .boundary),

                MoveCase("cell-3", .up, .focus("cell-0")),
                MoveCase("cell-3", .down, .focus("cell-6")),
                MoveCase("cell-3", .left, .boundary),
                MoveCase("cell-3", .right, .focus("cell-4")),

                MoveCase("cell-4", .up, .focus("cell-1")),
                MoveCase("cell-4", .down, .focus("cell-6")),
                MoveCase("cell-4", .left, .focus("cell-3")),
                MoveCase("cell-4", .right, .focus("cell-5")),

                MoveCase("cell-5", .up, .focus("cell-2")),
                MoveCase("cell-5", .down, .focus("cell-6")),
                MoveCase("cell-5", .left, .focus("cell-4")),
                MoveCase("cell-5", .right, .boundary),

                MoveCase("cell-6", .up, .focus("cell-3")),
                MoveCase("cell-6", .down, .boundary),
                MoveCase("cell-6", .left, .boundary),
                MoveCase("cell-6", .right, .boundary),
            ]
        )

        var state = FocusEngineState(focused: "cell-1")
        state = try expectMove(engine, state, .down, "cell-4")
        state = try expectMove(engine, state, .down, "cell-6")
        state = try expectMove(engine, state, .up, "cell-4")
        state = try expectMove(engine, state, .left, "cell-3")
        state = try expectMove(engine, state, .right, "cell-4")

        let boundary = engine.move(.right, state: FocusEngineState(focused: "cell-6"))
        try assert(boundary.state.focused == "cell-6", "grid right boundary should keep focus, got \(boundary.state.focused)")
        try assert(boundary.events == [.boundaryHit("cell-6", .right)], "expected right boundary at sparse grid tail, got \(boundary.events)")
    }

    /// Leaving a multi-row grid for a sibling container: by default the sibling
    /// receives the focused child's flat descendant index, and with
    /// `carriesGridColumn` it receives the visual column instead. Both are
    /// asserted so the default stays pinned for the surfaces that rely on it.
    private static func verifySiblingEntryHintProjection() throws {
        func tree(carriesColumn: Bool) -> FocusNode {
            FocusNode(
                "hint-root",
                kind: .container(.vertical),
                children: [
                    FocusNode(
                        "hint-source",
                        kind: .container(.grid(columns: 4)),
                        children: (0..<8).map { FocusNode(FocusNodeID("hint-source-\($0)"), kind: .leaf) },
                        carriesGridColumn: carriesColumn
                    ),
                    FocusNode(
                        "hint-sibling",
                        kind: .container(.grid(columns: 4)),
                        children: (0..<5).map { FocusNode(FocusNodeID("hint-sibling-\($0)"), kind: .leaf) }
                    ),
                ]
            )
        }

        // Row 1, column 1 of the source grid.
        let origin: FocusNodeID = "hint-source-5"

        let flat = FocusEngine(root: tree(carriesColumn: false))
            .move(.down, state: FocusEngineState(focused: origin)).state.focused
        try assert(
            flat == "hint-sibling-4",
            "default sibling entry should carry the flat index 5 clamped to 4, got \(flat)"
        )

        let projected = FocusEngine(root: tree(carriesColumn: true))
            .move(.down, state: FocusEngineState(focused: origin)).state.focused
        try assert(
            projected == "hint-sibling-1",
            "carriesGridColumn should enter the sibling at visual column 1, got \(projected)"
        )

        // The projection clamps when the sibling's matching column is absent.
        let narrow = FocusNode(
            "hint-root",
            kind: .container(.vertical),
            children: [
                FocusNode(
                    "hint-source",
                    kind: .container(.grid(columns: 4)),
                    children: (0..<8).map { FocusNodeID("hint-source-\($0)") }.map {
                        FocusNode($0, kind: .leaf)
                    },
                    carriesGridColumn: true
                ),
                FocusNode(
                    "hint-sibling",
                    kind: .container(.grid(columns: 4)),
                    children: [FocusNode("hint-sibling-0", kind: .leaf)]
                ),
            ]
        )
        let clamped = FocusEngine(root: narrow)
            .move(.down, state: FocusEngineState(focused: "hint-source-7")).state.focused
        try assert(
            clamped == "hint-sibling-0",
            "projected column should clamp into a shorter sibling, got \(clamped)"
        )
    }

    private static func verifyStepperSemantics() throws {
        let engine = FocusEngine(root: FocusNode(
            "root",
            kind: .container(.vertical),
            children: [
                FocusNode("season-stepper", kind: .stepper(axis: .horizontal)),
                FocusNode("episode-0", kind: .leaf)
            ]
        ))
        try verifyMatrix(
            engine,
            cases: [
                MoveCase("season-stepper", .up, .boundary),
                MoveCase("season-stepper", .down, .focus("episode-0")),
                MoveCase("season-stepper", .left, .stepper(delta: -1)),
                MoveCase("season-stepper", .right, .stepper(delta: 1)),

                MoveCase("episode-0", .up, .focus("season-stepper")),
                MoveCase("episode-0", .down, .boundary),
                MoveCase("episode-0", .left, .boundary),
                MoveCase("episode-0", .right, .boundary),
            ]
        )

        var state = FocusEngineState(focused: "season-stepper")
        let right = engine.move(.right, state: state)
        try assert(right.state.focused == "season-stepper", "right on stepper should not move focus, got \(right.state.focused)")
        try assert(
            right.events == [.stepperActivated(FocusStepperActivation(nodeID: "season-stepper", delta: 1))],
            "right on stepper should activate +1, got \(right.events)"
        )

        let left = engine.move(.left, state: right.state)
        try assert(left.state.focused == "season-stepper", "left on stepper should not move focus, got \(left.state.focused)")
        try assert(
            left.events == [.stepperActivated(FocusStepperActivation(nodeID: "season-stepper", delta: -1))],
            "left on stepper should activate -1, got \(left.events)"
        )

        state = try expectMove(engine, state, .down, "episode-0")
        state = try expectMove(engine, state, .up, "season-stepper")
    }

    private static func verifyInvalidTargetsFallBack() throws {
        let tree = FocusNode(
            "root",
            kind: .container(.vertical),
            children: [
                FocusNode(
                    "section",
                    kind: .container(.vertical),
                    preferredFocus: "section",
                    children: [
                        FocusNode("fallback", kind: .leaf)
                    ]
                )
            ]
        )
        let index = FocusEngineIndex(root: tree)
        try assert(
            !index.contains("section", descendant: "section"),
            "container should not be treated as its own descendant"
        )

        let engine = FocusEngine(root: tree)
        let preferredFallback = engine.restoreFocus(
            in: "section",
            state: FocusEngineState(focused: "fallback")
        )
        try assert(
            preferredFallback.state.focused == "fallback",
            "self-referential preferred focus should fall back to first child, got \(preferredFallback.state.focused)"
        )
        try assert(
            preferredFallback.events == [.restored("fallback")],
            "self-referential preferred focus should report fallback restore, got \(preferredFallback.events)"
        )

        var rememberedState = FocusEngineState(focused: "fallback")
        rememberedState.rememberedChildByContainer["section"] = "section"
        let rememberedFallback = engine.restoreFocus(in: "section", state: rememberedState)
        try assert(
            rememberedFallback.state.focused == "fallback",
            "self-referential remembered child should fall back to first child, got \(rememberedFallback.state.focused)"
        )
        try assert(
            rememberedFallback.events == [.restored("fallback")],
            "self-referential remembered child should report fallback restore, got \(rememberedFallback.events)"
        )
    }

    private static func verifyStructuralRenderingSurface() throws {
        for style in FocusStyle.allCases {
            try assert(
                FocusStyleSurface.renderingStrategy(for: style) == .structuralInsertRemove,
                "focus style \(style) must use structural insert/remove rendering"
            )
            try assert(
                FocusStyleSurface.focusRingNodeCount(style: style, isFocused: false) == 0,
                "unfocused style \(style) must insert zero focus-ring nodes"
            )
            try assert(
                FocusStyleSurface.focusRingNodeCount(style: style, isFocused: true) == 1,
                "focused style \(style) must structurally insert a focus-ring node"
            )
        }
    }

    private static func fixtureTree() -> FocusNode {
        FocusNode(
            "root",
            kind: .container(.horizontal),
            children: [
                FocusNode("sidebar", kind: .leaf),
                FocusNode(
                    "main",
                    kind: .container(.vertical),
                    preferredFocus: "hero",
                    children: [
                        FocusNode("hero", kind: .leaf, guides: [.left: "sidebar"]),
                        row("continue-row", children: ["continue-0", "continue-1", "continue-2"]),
                        row("movies-row", children: ["movie-0", "movie-1", "movie-2", "movie-3"])
                    ]
                )
            ]
        )
    }

    private static func gridFixture() -> FocusNode {
        FocusNode(
            "root",
            kind: .container(.grid(columns: 3)),
            children: (0...6).map { FocusNode(FocusNodeID("cell-\($0)"), kind: .leaf) }
        )
    }

    private static func row(_ id: FocusNodeID, children: [FocusNodeID]) -> FocusNode {
        FocusNode(
            id,
            kind: .container(.horizontal),
            children: children.map { FocusNode($0, kind: .leaf) }
        )
    }

    private static func expectMove(
        _ engine: FocusEngine,
        _ state: FocusEngineState,
        _ direction: FocusDirection,
        _ expected: FocusNodeID
    ) throws -> FocusEngineState {
        let result = engine.move(direction, state: state)
        try assert(result.state.focused == expected, "expected \(direction) from \(state.focused) to focus \(expected), got \(result.state.focused) with events \(result.events)")
        try assert(result.events.contains(.focusChanged(from: state.focused, to: expected)), "expected focusChanged event to \(expected), got \(result.events)")
        return result.state
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

    private static func verifyMatrix(
        _ engine: FocusEngine,
        cases: [MoveCase]
    ) throws {
        let grouped = Dictionary(grouping: cases, by: { $0.from })
        for (node, nodeCases) in grouped {
            try assert(
                nodeCases.count == FocusDirection.allCases.count,
                "matrix for \(node) must cover every direction, got \(nodeCases.count)"
            )
        }

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
                    "expected \(moveCase.direction) from \(moveCase.from) to stay on boundary, got \(result.state.focused)"
                )
                try assert(
                    result.events == [.boundaryHit(moveCase.from, moveCase.direction)],
                    "expected boundary event for \(moveCase.from) \(moveCase.direction), got \(result.events)"
                )
            case let .stepper(delta):
                try assert(
                    result.state.focused == moveCase.from,
                    "expected stepper \(moveCase.direction) from \(moveCase.from) to keep focus, got \(result.state.focused)"
                )
                try assert(
                    result.events == [.stepperActivated(FocusStepperActivation(nodeID: moveCase.from, delta: delta))],
                    "expected stepper delta \(delta) from \(moveCase.from), got \(result.events)"
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
#endif
