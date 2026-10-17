import SwiftUI

// MARK: - App Router

final class AppRouter: ObservableObject {

    @Published var selectedItem: SidebarItem = .home
    @Published var sidebarRemoteFocused: Bool = false
    @Published var focusedSidebarItem: SidebarItem = .home
    @Published var sidebarFocusOnPlaySomething: Bool = false
    @Published var sidebarFocusOnProfile: Bool = false

    func focusSidebar() {
        performSidebarRemoteTransition(animated: false) {
            focusedSidebarItem = selectedItem
            sidebarFocusOnPlaySomething = false
            sidebarFocusOnProfile = false
            sidebarRemoteFocused = true
        }
    }

    func releaseSidebarFocus(animated: Bool = false) {
        performSidebarRemoteTransition(animated: animated) {
            sidebarRemoteFocused = false
            sidebarFocusOnPlaySomething = false
            sidebarFocusOnProfile = false
        }
    }

    func handleSidebarRemoteCommand(
        _ command: RemoteCommand,
        presentProfilePicker: () -> Void,
        playSomething: () -> Void = {}
    ) {
        switch command {
        case .up:
            moveSidebarFocus(delta: -1)
        case .down:
            moveSidebarFocus(delta: 1)
        case .select, .right:
            if sidebarFocusOnProfile {
                presentProfilePicker()
            } else if sidebarFocusOnPlaySomething {
                playSomething()
                releaseSidebarFocus()
            } else {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    selectedItem = focusedSidebarItem
                }
                releaseSidebarFocus()
            }
        case .left:
            // The sidebar is the leftmost surface; Left is a boundary.
            break
        case .back:
            releaseSidebarFocus()
        }
    }

    private func moveSidebarFocus(delta: Int) {
        let items = SidebarItem.allCases
        if sidebarFocusOnProfile {
            if delta < 0 {
                sidebarFocusOnProfile = false
                sidebarFocusOnPlaySomething = true
            }
            return
        }
        if sidebarFocusOnPlaySomething {
            if delta < 0 {
                sidebarFocusOnPlaySomething = false
                focusedSidebarItem = items.last ?? .home
            } else if delta > 0 {
                sidebarFocusOnPlaySomething = false
                sidebarFocusOnProfile = true
            }
            return
        }
        guard let currentIndex = items.firstIndex(of: focusedSidebarItem) else {
            focusedSidebarItem = selectedItem
            return
        }
        let nextIndex = currentIndex + delta
        if nextIndex >= items.count {
            sidebarFocusOnPlaySomething = true
        } else {
            focusedSidebarItem = items[max(0, nextIndex)]
        }
    }

    private func performSidebarRemoteTransition(animated: Bool, updates: () -> Void) {
        if animated {
            withAnimation(MarqueeTheme.sidebarAnimation) {
                updates()
            }
            return
        }

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            updates()
        }
    }
}
