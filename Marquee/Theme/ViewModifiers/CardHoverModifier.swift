import SwiftUI

// MARK: - Card Hover Modifier

enum FocusChromeMetrics {
    static let posterFocusScale: CGFloat = 1.045
    static let controlFocusScale: CGFloat = 1.035
    static let detailFocusScale: CGFloat = 1.0
    static let posterGlowRadius: CGFloat = 28
    static let detailGlowRadius: CGFloat = 20
    static let posterRingLineWidth: CGFloat = 2.25
    static let detailRingLineWidth: CGFloat = 2.25
    static let focusedShadowRadius: CGFloat = 26
    static let focusedShadowY: CGFloat = 14
    static let idleShadowRadius: CGFloat = 4
    static let idleShadowY: CGFloat = 2
}

struct FocusChromeModifier: ViewModifier {
    let isFocused: Bool
    var cornerRadius: CGFloat = MarqueeTheme.cornerRadiusMD
    var accent: Color?
    var focusScale: CGFloat?
    var raisesZIndex: Bool = true
    var glowRadius: CGFloat = FocusChromeMetrics.posterGlowRadius
    var ringLineWidth: CGFloat = FocusChromeMetrics.posterRingLineWidth

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.kidsMode) private var kidsMode

    private var activeAccent: Color {
        // Keep the parameter source-compatible, but structural focus is never profile- or call-site-colored.
        MarqueeTheme.structuralFocus
    }

    private var effectiveCornerRadius: CGFloat {
        kidsMode ? max(cornerRadius, MarqueeTheme.kidsCornerRadiusMD) : cornerRadius
    }

    private var defaultFocusScale: CGFloat {
        kidsMode ? 1.055 : FocusChromeMetrics.posterFocusScale
    }

    private var effectiveFocusScale: CGFloat {
        focusScale ?? defaultFocusScale
    }

    func body(content: Content) -> some View {
        content
            .scaleEffect(isFocused ? effectiveFocusScale : 1.0)
            .shadow(
                color: Color.black.opacity(isFocused ? 0.68 : 0.22),
                radius: isFocused ? FocusChromeMetrics.focusedShadowRadius : FocusChromeMetrics.idleShadowRadius,
                y: isFocused ? FocusChromeMetrics.focusedShadowY : FocusChromeMetrics.idleShadowY
            )
            .shadow(
                color: activeAccent.opacity(isFocused ? 0.48 : 0),
                radius: isFocused ? glowRadius : 0,
                y: 0
            )
            .overlay(
                ZStack {
                    if isFocused {
                        RoundedRectangle(cornerRadius: effectiveCornerRadius)
                            .strokeBorder(activeAccent.opacity(0.95), lineWidth: ringLineWidth)
                            .padding(ringLineWidth)
                            .blendMode(.screen)
                    }
                }
            )
            .zIndex(raisesZIndex && isFocused ? 1 : 0)
            .animation(MarqueeTheme.motion(MarqueeTheme.cardFocusAnimation, reduceMotion: reduceMotion), value: isFocused)
    }
}

// MARK: - View Extension

extension View {
    func focusChrome(
        _ isFocused: Bool,
        cornerRadius: CGFloat = MarqueeTheme.cornerRadiusMD,
        accent: Color? = nil,
        focusScale: CGFloat? = nil,
        raisesZIndex: Bool = true,
        glowRadius: CGFloat = FocusChromeMetrics.posterGlowRadius,
        ringLineWidth: CGFloat = FocusChromeMetrics.posterRingLineWidth
    ) -> some View {
        modifier(FocusChromeModifier(
            isFocused: isFocused,
            cornerRadius: cornerRadius,
            accent: accent,
            focusScale: focusScale,
            raisesZIndex: raisesZIndex,
            glowRadius: glowRadius,
            ringLineWidth: ringLineWidth
        ))
    }
}
