import Combine
import Foundation

// MARK: - Remote Input Owner

enum RemoteInputOwner: String, CaseIterable {
    case profilePicker
    case player
    case postPlayHandoff
    case sidebar
    case browse
    case searchDetail
    case searchRoot
    case settings
}

// MARK: - Ownership State

struct RemoteOwnershipState: Equatable {
    var showProfilePicker: Bool
    var playerPresented: Bool
    var postPlayHandoffVisible: Bool
    var sidebarRemoteFocused: Bool
    var selectedItem: SidebarItem
    var searchHasDetail: Bool
}

// MARK: - Ownership Policy

enum RemoteOwnershipPolicy {

    static func owner(for state: RemoteOwnershipState) -> RemoteInputOwner {
        if state.showProfilePicker {
            return .profilePicker
        }
        if state.playerPresented {
            return .player
        }
        if state.postPlayHandoffVisible {
            return .postPlayHandoff
        }
        if state.sidebarRemoteFocused {
            return .sidebar
        }
        switch state.selectedItem {
        case .home, .movies, .tvShows:
            return .browse
        case .search:
            return state.searchHasDetail ? .searchDetail : .searchRoot
        case .settings:
            return .settings
        }
    }

    static func browseCatcherMounts(for owner: RemoteInputOwner) -> Bool {
        switch owner {
        case .sidebar, .browse, .searchDetail:
            return true
        case .profilePicker, .player, .postPlayHandoff, .searchRoot, .settings:
            return false
        }
    }
}

// MARK: - Search Input Ownership

enum SearchInputOwnershipPolicy {

    static func consumesRemoteCommands(owner: RemoteInputOwner) -> Bool {
        owner == .searchRoot
    }

    static func capturesPhysicalTyping(owner: RemoteInputOwner) -> Bool {
        switch owner {
        case .searchRoot, .sidebar:
            return true
        case .profilePicker, .player, .postPlayHandoff, .browse, .searchDetail, .settings:
            return false
        }
    }
}

// MARK: - Focus Coordinator

final class FocusCoordinator: ObservableObject {

    @Published private(set) var owner: RemoteInputOwner = .browse

    func update(with state: RemoteOwnershipState) {
        let next = RemoteOwnershipPolicy.owner(for: state)
        guard next != owner else { return }
        MarqueeLogger.general.info("remote input owner \(self.owner.rawValue, privacy: .public) -> \(next.rawValue, privacy: .public)")
        owner = next
    }
}
