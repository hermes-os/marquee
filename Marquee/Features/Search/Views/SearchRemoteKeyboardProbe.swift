import Foundation

#if DEBUG
struct SearchRemoteKeyboardProbeSnapshot: Codable, Equatable {
    let reason: String
    let query: String
    let debouncedQuery: String
    let detailPresented: Bool
    let focusOwner: String
    let keyboardVisible: Bool
    let focusedKeyID: String?
    let keyMonitorInstalled: Bool
    let fieldFocused: Bool
    let suggestionsVisible: Bool
    let suggestionFocus: Int?
    let resultFocus: String?
    let firstVisibleResultAvailable: Bool
    let visibleMovieCount: Int
    let visibleShowCount: Int
    let consumedCommand: Bool?
}

@MainActor
final class SearchRemoteKeyboardTourProbe {
    static let shared = SearchRemoteKeyboardTourProbe()

    private(set) var snapshots: [SearchRemoteKeyboardProbeSnapshot] = []
    private(set) var latest: SearchRemoteKeyboardProbeSnapshot?

    private init() {}

    func reset() {
        snapshots = []
        latest = nil
    }

    func record(_ snapshot: SearchRemoteKeyboardProbeSnapshot) {
        snapshots.append(snapshot)
        latest = snapshot
    }
}
#endif
