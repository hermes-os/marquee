import Combine
import Foundation

struct SearchPresentationSnapshot {
    enum Phase: Equatable {
        case empty
        case pending
        case ready
    }

    let generation: UInt64
    let query: String
    let indexRevision: String
    let phase: Phase
    let suggestions: [String]
    let results: BrowseSearchResults

    static func empty(
        generation: UInt64 = 0,
        query: String = "",
        indexRevision: String
    ) -> SearchPresentationSnapshot {
        SearchPresentationSnapshot(
            generation: generation,
            query: query,
            indexRevision: indexRevision,
            phase: .empty,
            suggestions: [],
            results: .empty
        )
    }
}

private final class SearchRequestCancellationToken {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

final class SearchSession: ObservableObject {
    @Published private(set) var presentation: SearchPresentationSnapshot
    let presentationUpdates: AnyPublisher<SearchPresentationSnapshot, Never>

    private let workerQueue = DispatchQueue(
        label: "com.marquee.search-query",
        qos: .userInitiated
    )
    private let presentationSubject: PassthroughSubject<SearchPresentationSnapshot, Never>
    private var index: BrowseSearchIndex
    private var currentQuery = ""
    private var latestGeneration: UInt64 = 0
    private var cancellationToken: SearchRequestCancellationToken?
    private var currentRequestIsImmediate = false

    init(index: BrowseSearchIndex) {
        let presentationSubject = PassthroughSubject<SearchPresentationSnapshot, Never>()
        self.presentationSubject = presentationSubject
        presentationUpdates = presentationSubject.eraseToAnyPublisher()
        self.index = index
        presentation = .empty(indexRevision: index.revisionKey)
    }

    deinit {
        cancellationToken?.cancel()
    }

    func updateIndex(_ nextIndex: BrowseSearchIndex) {
        precondition(Thread.isMainThread)
        guard nextIndex.revisionKey != index.revisionKey else { return }
        index = nextIndex
        _ = request(query: currentQuery, immediate: true)
    }

    @discardableResult
    func request(query: String, immediate: Bool = false) -> UInt64 {
        precondition(Thread.isMainThread)
        currentQuery = query
        let indexRevision = index.revisionKey

        if presentation.query == query,
           presentation.indexRevision == indexRevision {
            switch presentation.phase {
            case .empty, .ready:
                return presentation.generation
            case .pending where currentRequestIsImmediate || !immediate:
                return presentation.generation
            case .pending:
                break
            }
        }

        cancellationToken?.cancel()
        latestGeneration &+= 1
        let generation = latestGeneration
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalizedQuery.isEmpty else {
            cancellationToken = nil
            currentRequestIsImmediate = false
            publish(.empty(
                generation: generation,
                query: query,
                indexRevision: indexRevision
            ))
            return generation
        }

        let token = SearchRequestCancellationToken()
        cancellationToken = token
        currentRequestIsImmediate = immediate
        publish(SearchPresentationSnapshot(
            generation: generation,
            query: query,
            indexRevision: indexRevision,
            phase: .pending,
            suggestions: [],
            results: .empty
        ))

        let worker = index.workerSnapshot
        let delay = immediate ? 0 : SearchResultsUpdatePolicy.delay(for: query)
        workerQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard !token.isCancelled else { return }
            let signpostID = MarqueeSignpost.begin("search-evaluate")
            let evaluation = worker.evaluate(query) { token.isCancelled }
            MarqueeSignpost.end("search-evaluate", signpostID)
            guard let evaluation, !token.isCancelled else { return }

            DispatchQueue.main.async {
                self?.accept(
                    evaluation,
                    query: query,
                    generation: generation,
                    indexRevision: indexRevision,
                    token: token
                )
            }
        }
        return generation
    }

    private func accept(
        _ evaluation: BrowseSearchIndex.WorkerEvaluation,
        query: String,
        generation: UInt64,
        indexRevision: String,
        token: SearchRequestCancellationToken
    ) {
        precondition(Thread.isMainThread)
        guard generation == latestGeneration,
              query == currentQuery,
              indexRevision == index.revisionKey,
              cancellationToken === token,
              !token.isCancelled else { return }

        let results = index.materialize(evaluation)
        cancellationToken = nil
        currentRequestIsImmediate = false
        publish(SearchPresentationSnapshot(
            generation: generation,
            query: query,
            indexRevision: indexRevision,
            phase: .ready,
            suggestions: evaluation.suggestions,
            results: results
        ))
    }

    /// `@Published` emits from `willSet`; side-effect consumers instead use
    /// `presentationUpdates`, which is sent only after storage completes.
    private func publish(_ snapshot: SearchPresentationSnapshot) {
        precondition(Thread.isMainThread)
        presentation = snapshot
        presentationSubject.send(snapshot)
    }
}

#if DEBUG
enum VerifySearchSessionHarness {
    static let launchArgument = "--verify-search-session"

    static func runIfRequested() {
        guard CommandLine.arguments.contains(launchArgument) else { return }

        do {
            let detail = try runScenario()
            FileHandle.standardError.write(Data("verify-search-session: PASS latestWins: \(detail)\n".utf8))
            FileHandle.standardError.write(Data("verify-search-session: outcome=verified passed=6/6\n".utf8))
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("verify-search-session: FAIL latestWins: \(error)\n".utf8))
            FileHandle.standardError.write(Data("verify-search-session: outcome=failed passed=0/6\n".utf8))
            exit(1)
        }
    }

    private static func runScenario() throws -> String {
        let alien = makeMovie(title: "Alien", path: "/qa/search/Alien (1979).mp4")
        let distractor = makeMovie(title: "101 Dalmatians", path: "/qa/search/101 Dalmatians (1961).mp4")
        let firstIndex = BrowseSearchIndex(movies: [alien, distractor], shows: [])
        let session = SearchSession(index: firstIndex)

        var readyQueries: [String] = []
        var publishedOffMain = false
        var incoherentDelivery = false
        let cancellable = session.presentationUpdates.sink { snapshot in
            if !Thread.isMainThread { publishedOffMain = true }
            let current = session.presentation
            if snapshot.generation != current.generation
                || snapshot.query != current.query
                || snapshot.indexRevision != current.indexRevision
                || snapshot.phase != current.phase {
                incoherentDelivery = true
            }
            if snapshot.phase == .ready {
                readyQueries.append(snapshot.query)
            }
        }
        defer { cancellable.cancel() }

        _ = session.request(query: "a")
        let alienGeneration = session.request(query: "alien")
        guard waitUntil(timeout: 2.0, predicate: {
            session.presentation.phase == .ready
                && session.presentation.generation == alienGeneration
        }) else {
            throw HarnessError.assertion("latest query did not publish")
        }
        guard readyQueries == ["alien"] else {
            throw HarnessError.assertion("stale query published: \(readyQueries)")
        }
        guard session.presentation.results.movies.first?.item.id == alien.id,
              session.presentation.results.movies.first?.item.displayTitle == "Alien" else {
            throw HarnessError.assertion("accepted result identity did not match Alien")
        }
        guard !publishedOffMain else {
            throw HarnessError.assertion("presentation published off the main thread")
        }
        guard !incoherentDelivery else {
            throw HarnessError.assertion("presentation side effect arrived before the snapshot was stored")
        }

        let matrix = makeMovie(title: "The Matrix", path: "/qa/search/The Matrix (1999).mp4")
        let sameCountReplacement = BrowseSearchIndex(movies: [matrix, distractor], shows: [])
        guard sameCountReplacement.revisionKey != firstIndex.revisionKey else {
            throw HarnessError.assertion("same-count replacement reused the old search revision")
        }
        session.updateIndex(sameCountReplacement)
        let matrixGeneration = session.request(query: "the matrix", immediate: true)
        guard waitUntil(timeout: 2.0, predicate: {
            session.presentation.phase == .ready
                && session.presentation.generation == matrixGeneration
        }), session.presentation.results.movies.first?.item.id == matrix.id else {
            throw HarnessError.assertion("replacement index did not resolve the current MediaItem")
        }

        let emptyGeneration = session.request(query: "", immediate: true)
        guard session.presentation.phase == .empty,
              session.presentation.generation == emptyGeneration,
              session.presentation.results.totalCount == 0,
              session.presentation.suggestions.isEmpty else {
            throw HarnessError.assertion("empty query did not cancel and clear atomically")
        }

        return "ordinary request burst kept only the latest generation; coherent Alien identity; main-thread post-store publication; same-count revision replaced; empty cancellation"
    }

    private static func waitUntil(
        timeout: TimeInterval,
        predicate: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return predicate()
    }

    private static func makeMovie(title: String, path: String) -> MediaItem {
        MediaItem(
            filePath: path,
            fileName: URL(fileURLWithPath: path).lastPathComponent,
            title: title,
            year: nil,
            fileExtension: "mp4",
            fileSize: 1
        )
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
