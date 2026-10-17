import Foundation
import QuartzCore
import SwiftUI

enum StructuralFocusPalette {
    static let red = Double(0x7B) / 255.0
    static let green = Double(0x5E) / 255.0
    static let blue = Double(0xA7) / 255.0
}

struct ProfileManagementLayoutPolicy {
    static let tileWidth: CGFloat = 220
    static let tileHeight: CGFloat = 280
    static let addTileHeight: CGFloat = 280
    static let rowSpacing: CGFloat = 24
    static let actionSpacing: CGFloat = 8
}

enum ProfileManagementRemoteAction: CaseIterable, Equatable {
    case moveLeft
    case edit
    case delete
    case moveRight
}

enum ProfileManagementRemoteNavigationPolicy {
    static func enabledActions(profileIndex: Int, profileCount: Int) -> [ProfileManagementRemoteAction] {
        guard profileIndex >= 0, profileIndex < profileCount else { return [] }
        return ProfileManagementRemoteAction.allCases.filter { action in
            switch action {
            case .moveLeft: return profileIndex > 0
            case .edit: return true
            case .delete: return profileCount > 1
            case .moveRight: return profileIndex < profileCount - 1
            }
        }
    }
}

enum ProfileManagementAction: CaseIterable, Equatable {
    case edit
    case delete
    case add
    case done

    var accessibilityLabel: String {
        switch self {
        case .edit: return "Edit profile"
        case .delete: return "Delete profile"
        case .add: return "Add profile"
        case .done: return "Done managing profiles"
        }
    }

    var accessibilityHint: String {
        switch self {
        case .edit: return "Opens profile editing"
        case .delete: return "Permanently removes this profile"
        case .add: return "Creates a new profile"
        case .done: return "Returns to profile selection"
        }
    }

}

enum ProfileExitRootTransition: Equatable {
    case opacityOnly

    var transition: AnyTransition {
        switch self {
        case .opacityOnly:
            return .opacity
        }
    }
}

enum ProfileExitTransitionPolicy {
    static let rootTransition: ProfileExitRootTransition = .opacityOnly
    static let scale: CGFloat = 1
    static let saturation: Double = 1
    static let retainsFocusedRing = true
    static let duration: TimeInterval = 0.24

    static func acceptsInput(isExitInFlight: Bool) -> Bool { !isExitInFlight }

    static func retainsProfileInputOwnership(
        showProfilePicker: Bool,
        isExitInFlight: Bool
    ) -> Bool {
        showProfilePicker || isExitInFlight
    }

    static var focusColor: Color {
        MarqueeTheme.accentPrimary
    }
}

// TODO: [M4 Migration] Replace Animation properties with Spring(duration:bounce:) values (macOS 14+)

enum MarqueeTheme {

    // MARK: - Colors

    /// Primary app background (near-black with purple undertone)
    static let background = Color(red: 0x0D / 255.0, green: 0x0B / 255.0, blue: 0x1A / 255.0)

    /// Card backgrounds, panels
    static let surfaceElevated = Color(red: 0x1A / 255.0, green: 0x15 / 255.0, blue: 0x25 / 255.0)

    /// Sidebar, overlays, modals
    static let surfaceLayer = Color(red: 0x23 / 255.0, green: 0x1D / 255.0, blue: 0x30 / 255.0)

    /// Buttons, selection states, active nav, focus rings
    static let accentPrimary = Color(red: 0x7B / 255.0, green: 0x5E / 255.0, blue: 0xA7 / 255.0)

    /// Structural focus chrome. This remains amethyst in every profile and surface.
    static let structuralFocus = Color(
        red: StructuralFocusPalette.red,
        green: StructuralFocusPalette.green,
        blue: StructuralFocusPalette.blue
    )

    /// Gold highlights, badges, progress bar fill, premium markers
    static let accentSecondary = Color(red: 0xC9 / 255.0, green: 0xA8 / 255.0, blue: 0x4C / 255.0)

    /// Links, hover states, bright focus rings
    static let accentBright = Color(red: 0x9E / 255.0, green: 0x86 / 255.0, blue: 0xFF / 255.0)

    /// Warm white body text
    static let textPrimary = Color(red: 0xF5 / 255.0, green: 0xF0 / 255.0, blue: 0xEB / 255.0)

    /// Muted lavender for metadata, timestamps
    static let textSecondary = Color(red: 0x9B / 255.0, green: 0x8F / 255.0, blue: 0xB0 / 255.0)

    /// Disabled states, placeholder text
    static let textTertiary = Color(red: 0x6B / 255.0, green: 0x61 / 255.0, blue: 0x78 / 255.0)

    // MARK: - Title Gradient (matches app icon play button)

    static let titleGradient = LinearGradient(
        colors: [
            Color(red: 0xD4 / 255.0, green: 0xAF / 255.0, blue: 0x5C / 255.0),
            Color(red: 0xE8 / 255.0, green: 0xD0 / 255.0, blue: 0x8C / 255.0),
            Color(red: 0xC9 / 255.0, green: 0xA8 / 255.0, blue: 0x4C / 255.0),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    // MARK: - Kids Mode Colors

    /// Kids background (warmer, slightly lighter purple)
    static let kidsBackground = Color(red: 0x14 / 255.0, green: 0x0E / 255.0, blue: 0x28 / 255.0)

    /// Kids card surfaces (brighter purple)
    static let kidsSurface = Color(red: 0x22 / 255.0, green: 0x18 / 255.0, blue: 0x38 / 255.0)

    /// Kids sidebar/overlay layer (brighter purple)
    static let kidsSurfaceLayer = Color(red: 0x2E / 255.0, green: 0x22 / 255.0, blue: 0x45 / 255.0)

    /// Kids bright gold accent
    static let kidsAccent = Color(red: 1.0, green: 0.84, blue: 0.0)

    /// Kids warm coral secondary accent
    static let kidsAccentWarm = Color(red: 1.0, green: 0.5, blue: 0.3)

    /// Kids warmer white text
    static let kidsTextPrimary = Color(red: 1.0, green: 0.96, blue: 0.90)

    // MARK: - Kids Title Gradient

    static let kidsTitleGradient = LinearGradient(
        colors: [
            Color(red: 1.0, green: 0.84, blue: 0.0),
            Color(red: 1.0, green: 0.5, blue: 0.5),
            Color(red: 0.8, green: 0.4, blue: 1.0),
            Color(red: 0.4, green: 0.6, blue: 1.0),
        ],
        startPoint: .leading,
        endPoint: .trailing
    )

    // MARK: - Kids Corner Radii

    static let kidsCornerRadiusMD: CGFloat = 14
    static let kidsCornerRadiusLG: CGFloat = 18

    // MARK: - Kids Card Animation

    static let kidsCardHoverScale: CGFloat = 1.08

    // MARK: - Spacing (8pt grid)

    static let spacingXS: CGFloat = 4
    static let spacingSM: CGFloat = 8
    static let spacingMD: CGFloat = 16
    static let spacingLG: CGFloat = 24
    static let spacingXL: CGFloat = 32
    static let spacingXXL: CGFloat = 48

    static let outerPadding: CGFloat = 48
    static let cardGap: CGFloat = 10
    static let sectionSpacing: CGFloat = 48
    static let sectionHeaderToContent: CGFloat = 16

    // MARK: - Lean-Back / TV Scaling

    static let leanBackScale: CGFloat = 1.45

    static func scaled(_ compact: CGFloat, leanBack: CGFloat? = nil, isLeanBack: Bool) -> CGFloat {
        isLeanBack ? (leanBack ?? compact * leanBackScale) : compact
    }

    static func outerPadding(isLeanBack: Bool) -> CGFloat {
        scaled(outerPadding, leanBack: 72, isLeanBack: isLeanBack)
    }

    static func sectionSpacing(isLeanBack: Bool) -> CGFloat {
        scaled(sectionSpacing, leanBack: 64, isLeanBack: isLeanBack)
    }

    static func sectionHeaderToContent(isLeanBack: Bool) -> CGFloat {
        scaled(sectionHeaderToContent, leanBack: 22, isLeanBack: isLeanBack)
    }

    static func cardGap(isLeanBack: Bool) -> CGFloat {
        scaled(cardGap, leanBack: 16, isLeanBack: isLeanBack)
    }

    static func focusChromeHaloPadding(isLeanBack: Bool) -> CGFloat {
        scaled(36, leanBack: 52, isLeanBack: isLeanBack)
    }

    static func focusChromePosterTopPadding(isLeanBack: Bool) -> CGFloat {
        scaled(8, leanBack: 12, isLeanBack: isLeanBack)
    }

    static func focusChromeLeadingEdgeBreathingRoom(isLeanBack: Bool) -> CGFloat {
        scaled(spacingMD, leanBack: spacingLG, isLeanBack: isLeanBack)
    }

    // MARK: - Corner Radii

    static let cornerRadiusSM: CGFloat = 4
    static let cornerRadiusMD: CGFloat = 8
    static let cornerRadiusLG: CGFloat = 12

    // MARK: - Motion

    // Design doc: Spring(duration: 0.25, bounce: 0.15) — bounce 0.15 ≈ dampingFraction 0.7
    static let cardHoverAnimation: Animation = .spring(response: 0.25, dampingFraction: 0.7)
    static let cardFocusAnimation: Animation = .spring(response: 0.25, dampingFraction: 0.72)
    static let quickControlAnimation: Animation = .spring(response: 0.25, dampingFraction: 0.9)
    static let modalPresentationAnimation: Animation = .spring(response: 0.3, dampingFraction: 0.8)
    static let quietDismissAnimation: Animation = .spring(response: 0.3, dampingFraction: 0.95)
    static let compactHeaderAnimation: Animation = .spring(response: 0.35, dampingFraction: 0.6)
    static let reorderAnimation: Animation = .spring(response: 0.25, dampingFraction: 0.7)
    static let heroCarouselAnimation: Animation = .spring(response: 0.5, dampingFraction: 0.82)
    static let heroIndicatorAnimation: Animation = .spring(response: 0.25, dampingFraction: 0.9)
    static let selectionFadeAnimation: Animation = .easeOut(duration: 0.12)
    static let profileExitAnimation: Animation = .easeInOut(duration: ProfileExitTransitionPolicy.duration)
    static let pageTransitionAnimation: Animation = .spring(response: 0.35, dampingFraction: 0.75)
    static let sidebarAnimation: Animation = .spring(response: 0.3, dampingFraction: 0.75)
    static let focusScrollDuration: TimeInterval = 0.22
    static let focusScrollTimingFunction = CAMediaTimingFunction(name: .easeOut)

    /// Spring the scroll placement authority interpolates offsets with, matching
    /// the hero carousel's feel so traversal and the carousel read as one motion
    /// system. Numeric rather than a SwiftUI `Animation` because the authority
    /// drives clip-view offsets directly.
    static let focusScrollSpring = RemoteScrollSpring(response: 0.5, dampingFraction: 0.82)

    static func motion(_ animation: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }
}
