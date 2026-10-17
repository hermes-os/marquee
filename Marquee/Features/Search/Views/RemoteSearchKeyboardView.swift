import SwiftUI

struct RemoteSearchKeyboardView: View {
    let focusedKeyID: String?
    let onPress: (RemoteSearchKeyboardKey) -> Void

    @Environment(\.leanBackMode) private var leanBackMode

    var body: some View {
        VStack(spacing: rowSpacing) {
            ForEach(Array(RemoteSearchKeyboardPolicy.layout.enumerated()), id: \.offset) { _, row in
                HStack(spacing: keySpacing) {
                    ForEach(row) { key in
                        RemoteSearchKeyboardKeyView(
                            key: key,
                            isFocused: focusedKeyID == key.id,
                            onPress: { onPress(key) }
                        )
                        .frame(width: keyWidth * key.width, height: keyHeight)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .padding(.horizontal, MarqueeTheme.scaled(18, leanBack: 28, isLeanBack: leanBackMode))
        .padding(.vertical, MarqueeTheme.scaled(16, leanBack: 24, isLeanBack: leanBackMode))
        .background(
            RoundedRectangle(cornerRadius: MarqueeTheme.cornerRadiusLG)
                .fill(MarqueeTheme.surfaceLayer.opacity(0.96))
        )
        .overlay(
            RoundedRectangle(cornerRadius: MarqueeTheme.cornerRadiusLG)
                .strokeBorder(MarqueeTheme.textTertiary.opacity(0.18), lineWidth: 1)
        )
    }

    private var keyWidth: CGFloat {
        MarqueeTheme.scaled(42, leanBack: 62, isLeanBack: leanBackMode)
    }

    private var keyHeight: CGFloat {
        MarqueeTheme.scaled(34, leanBack: 50, isLeanBack: leanBackMode)
    }

    private var keySpacing: CGFloat {
        MarqueeTheme.scaled(7, leanBack: 10, isLeanBack: leanBackMode)
    }

    private var rowSpacing: CGFloat {
        MarqueeTheme.scaled(8, leanBack: 12, isLeanBack: leanBackMode)
    }
}

private struct RemoteSearchKeyboardKeyView: View {
    let key: RemoteSearchKeyboardKey
    let isFocused: Bool
    let onPress: () -> Void

    @Environment(\.leanBackMode) private var leanBackMode
    @State private var isHovered = false

    var body: some View {
        Button(action: onPress) {
            Text(key.title)
                .font(.system(
                    size: MarqueeTheme.scaled(14, leanBack: 20, isLeanBack: leanBackMode),
                    weight: isFocused ? .bold : .semibold
                ))
                .foregroundColor(isFocused ? .black : MarqueeTheme.textPrimary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .background(keyBackground)
                .overlay(keyStroke)
                .clipShape(RoundedRectangle(cornerRadius: MarqueeTheme.cornerRadiusSM))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(key.title)
    }

    @ViewBuilder
    private var keyBackground: some View {
        if isFocused {
            RoundedRectangle(cornerRadius: MarqueeTheme.cornerRadiusSM)
                .fill(MarqueeTheme.accentBright)
        } else if isHovered {
            RoundedRectangle(cornerRadius: MarqueeTheme.cornerRadiusSM)
                .fill(MarqueeTheme.surfaceElevated)
        } else {
            RoundedRectangle(cornerRadius: MarqueeTheme.cornerRadiusSM)
                .fill(MarqueeTheme.surfaceElevated.opacity(0.72))
        }
    }

    private var keyStroke: some View {
        RoundedRectangle(cornerRadius: MarqueeTheme.cornerRadiusSM)
            .strokeBorder(
                isFocused ? Color.white.opacity(0.82) : MarqueeTheme.textTertiary.opacity(0.18),
                lineWidth: isFocused ? 2 : 1
            )
    }
}
