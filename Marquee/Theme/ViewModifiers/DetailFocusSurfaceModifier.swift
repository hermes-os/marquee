import SwiftUI

// MARK: - Detail Focus Surface Modifier

struct DetailFocusSurfaceModifier: ViewModifier {
    let isFocused: Bool
    let cornerRadius: CGFloat
    let accent: Color

    @Environment(\.kidsMode) private var kidsMode

    private var effectiveCornerRadius: CGFloat {
        kidsMode ? max(cornerRadius, MarqueeTheme.kidsCornerRadiusMD) : cornerRadius
    }

    func body(content: Content) -> some View {
        content
            .focusChrome(
                isFocused,
                cornerRadius: effectiveCornerRadius,
                accent: accent,
                focusScale: FocusChromeMetrics.detailFocusScale,
                raisesZIndex: true,
                glowRadius: FocusChromeMetrics.detailGlowRadius,
                ringLineWidth: FocusChromeMetrics.detailRingLineWidth
            )
    }
}

extension View {
    func detailFocusSurface(isFocused: Bool, cornerRadius: CGFloat, accent: Color) -> some View {
        modifier(DetailFocusSurfaceModifier(
            isFocused: isFocused,
            cornerRadius: cornerRadius,
            accent: accent
        ))
    }
}
