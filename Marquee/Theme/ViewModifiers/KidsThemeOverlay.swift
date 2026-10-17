import SwiftUI

// MARK: - Kids Mode Environment Key

private struct KidsModeKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

extension EnvironmentValues {
    var kidsMode: Bool {
        get { self[KidsModeKey.self] }
        set { self[KidsModeKey.self] = newValue }
    }
}

// MARK: - Kids Theme Overlay Modifier

struct KidsThemeOverlay: ViewModifier {
    let isKidsProfile: Bool

    func body(content: Content) -> some View {
        content
            .environment(\.kidsMode, isKidsProfile)
    }
}

extension View {
    func kidsTheme(active: Bool) -> some View {
        modifier(KidsThemeOverlay(isKidsProfile: active))
    }
}
