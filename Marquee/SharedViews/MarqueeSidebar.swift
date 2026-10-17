import SwiftUI
import AppKit

// MARK: - Sidebar Item

enum SidebarItem: String, CaseIterable, Identifiable {
    case home = "Home"
    case search = "Search"
    case movies = "Movies"
    case tvShows = "TV Shows"
    case settings = "Settings"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .search: return "magnifyingglass"
        case .movies: return "film"
        case .tvShows: return "tv"
        case .settings: return "gearshape"
        }
    }
}

// MARK: - Custom Sidebar

struct MarqueeSidebar: View {
    @Binding var selection: SidebarItem
    var remoteFocusedItem: SidebarItem?
    var playSomethingRemoteFocused: Bool = false
    var profileRemoteFocused: Bool = false
    var onSwitchProfile: () -> Void = {}
    var onPlaySomething: () -> Void = {}
    var activeProfile: UserProfile?
    var activeProfileAvatarImage: NSImage?

    @Environment(\.kidsMode) private var kidsMode
    @Environment(\.leanBackMode) private var leanBackMode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var sidebarWidth: CGFloat {
        MarqueeTheme.scaled(56, leanBack: 78, isLeanBack: leanBackMode)
    }

    private var avatarDiameter: CGFloat {
        MarqueeTheme.scaled(30, leanBack: 44, isLeanBack: leanBackMode)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: MarqueeTheme.scaled(2, leanBack: 6, isLeanBack: leanBackMode)) {
                ForEach(SidebarItem.allCases) { item in
                    Button(action: {
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            selection = item
                        }
                    }) {
                        SidebarRow(
                            item: item,
                            isSelected: selection == item,
                            isRemoteFocused: remoteFocusedItem == item
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(item.rawValue))
                    .accessibilityHint(Text("Open \(item.rawValue)"))
                    .help(item.rawValue)
                }
            }
            .padding(.top, MarqueeTheme.scaled(18, leanBack: 28, isLeanBack: leanBackMode))

            Button(action: onPlaySomething) {
                Image(systemName: "shuffle")
                    .font(.system(size: MarqueeTheme.scaled(14, leanBack: 21, isLeanBack: leanBackMode), weight: .medium))
                    .foregroundColor(playSomethingRemoteFocused ? MarqueeTheme.textPrimary : MarqueeTheme.accentSecondary.opacity(0.78))
                    .frame(
                        width: MarqueeTheme.scaled(22, leanBack: 32, isLeanBack: leanBackMode),
                        height: MarqueeTheme.scaled(22, leanBack: 32, isLeanBack: leanBackMode)
                    )
                    .padding(.vertical, MarqueeTheme.scaled(7, leanBack: 12, isLeanBack: leanBackMode))
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(playSomethingRemoteFocused
                                ? MarqueeTheme.accentPrimary
                                : MarqueeTheme.accentPrimary.opacity(0.14)
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(
                                playSomethingRemoteFocused ? MarqueeTheme.structuralFocus : Color.clear,
                                lineWidth: playSomethingRemoteFocused ? 1 : 0
                            )
                    )
                    .scaleEffect(playSomethingRemoteFocused ? 1.03 : 1.0)
                    .animation(MarqueeTheme.motion(MarqueeTheme.cardHoverAnimation, reduceMotion: reduceMotion), value: playSomethingRemoteFocused)
                    .padding(.horizontal, MarqueeTheme.scaled(8, leanBack: 12, isLeanBack: leanBackMode))
                    .padding(.top, MarqueeTheme.scaled(10, leanBack: 16, isLeanBack: leanBackMode))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play Something")
            .help("Play Something")

            Spacer()

            // Profile switch
            Button(action: onSwitchProfile) {
                profileAvatar
                    .padding(.vertical, MarqueeTheme.scaled(6, leanBack: 10, isLeanBack: leanBackMode))
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(profileRemoteFocused ? MarqueeTheme.structuralFocus.opacity(0.14) : Color.clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(
                                profileRemoteFocused ? MarqueeTheme.structuralFocus : Color.clear,
                                lineWidth: profileRemoteFocused ? 2 : 0
                            )
                    )
                    .scaleEffect(profileRemoteFocused ? 1.03 : 1.0)
                    .animation(MarqueeTheme.motion(MarqueeTheme.cardHoverAnimation, reduceMotion: reduceMotion), value: profileRemoteFocused)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(activeProfile?.name ?? "Switch Profile")
            .accessibilityHint("Switch Profile")
            .help(activeProfile?.name ?? "Switch Profile")
            .padding(.horizontal, MarqueeTheme.scaled(8, leanBack: 12, isLeanBack: leanBackMode))
            .padding(.bottom, MarqueeTheme.scaled(12, leanBack: 20, isLeanBack: leanBackMode))
        }
        .frame(width: sidebarWidth)
        .background(kidsMode ? MarqueeTheme.kidsSurfaceLayer : MarqueeTheme.surfaceLayer)
        .clipped()
    }

    @ViewBuilder
    private var profileAvatar: some View {
        if let image = activeProfileAvatarImage {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: avatarDiameter, height: avatarDiameter)
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                )
        } else {
            ZStack {
                Circle()
                    .fill(MarqueeTheme.surfaceElevated)

                Image(systemName: activeProfile?.avatar.icon ?? "person.crop.circle")
                    .font(.system(size: MarqueeTheme.scaled(15, leanBack: 22, isLeanBack: leanBackMode), weight: .medium))
                    .foregroundColor(
                        activeProfile?.avatar.color
                            ?? (kidsMode ? MarqueeTheme.kidsAccent : MarqueeTheme.accentBright)
                    )
            }
            .frame(width: avatarDiameter, height: avatarDiameter)
        }
    }
}

// MARK: - Sidebar Row

struct SidebarRow: View {
    let item: SidebarItem
    let isSelected: Bool
    var isRemoteFocused: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.leanBackMode) private var leanBackMode
    @State private var isHovered: Bool = false

    var body: some View {
        Image(systemName: item.icon)
            .font(.system(size: MarqueeTheme.scaled(14, leanBack: 21, isLeanBack: leanBackMode), weight: .medium))
            .foregroundColor(iconColor)
            .frame(
                width: MarqueeTheme.scaled(22, leanBack: 32, isLeanBack: leanBackMode),
                height: MarqueeTheme.scaled(22, leanBack: 32, isLeanBack: leanBackMode)
            )
            .padding(.vertical, MarqueeTheme.scaled(7, leanBack: 12, isLeanBack: leanBackMode))
            .frame(maxWidth: .infinity)
            .background(rowBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(
                        isRemoteFocused ? MarqueeTheme.structuralFocus : Color.clear,
                        lineWidth: isRemoteFocused ? 2 : 0
                    )
            )
            .scaleEffect(isRemoteFocused && !isSelected ? 1.03 : 1.0)
            .animation(MarqueeTheme.motion(MarqueeTheme.cardHoverAnimation, reduceMotion: reduceMotion), value: isHovered)
            .animation(MarqueeTheme.motion(MarqueeTheme.cardHoverAnimation, reduceMotion: reduceMotion), value: isRemoteFocused)
            .padding(.horizontal, MarqueeTheme.scaled(8, leanBack: 12, isLeanBack: leanBackMode))
            .onHover { hovering in
                isHovered = hovering
            }
            .help(item.rawValue)
    }

    // MARK: - Styling

    private var iconColor: Color {
        if isRemoteFocused { return MarqueeTheme.structuralFocus }
        if isSelected { return MarqueeTheme.accentBright }
        if isHovered { return MarqueeTheme.textPrimary }
        return MarqueeTheme.textTertiary
    }

    @ViewBuilder
    private var rowBackground: some View {
        if isRemoteFocused {
            RoundedRectangle(cornerRadius: 6)
                .fill(MarqueeTheme.structuralFocus.opacity(0.14))
        } else if isSelected {
            RoundedRectangle(cornerRadius: 6)
                .fill(MarqueeTheme.accentPrimary.opacity(0.2))
        } else if isHovered {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(0.05))
        }
    }
}
