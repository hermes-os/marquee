pragma Singleton

import QtQuick

QtObject {
    // v2 parity palette
    readonly property color background: "#0d0b1a"
    readonly property color surfaceElevated: "#1a1525"
    readonly property color surfaceLayer: "#231d30"
    readonly property color accentPrimary: "#7b5ea7"
    readonly property color structuralFocus: "#7b5ea7"
    readonly property color accentSecondary: "#c9a84c"
    readonly property color accentBright: "#9e86ff"
    readonly property color textPrimary: "#f5f0eb"
    readonly property color textSecondary: "#9b8fb0"
    readonly property color textTertiary: "#6b6178"

    // Marquee/Theme/MarqueeTheme.swift:140-148 fills the MARQUEE wordmark with
    // three golds from the app icon's play button, top-leading to
    // bottom-trailing. HomeDetailView.swift:416-423 sweeps the same three
    // around the scan ring in its own order.
    readonly property color titleGradientStart: "#d4af5c"
    readonly property color titleGradientMiddle: "#e8d08c"
    readonly property color titleGradientEnd: "#c9a84c"

    readonly property color kidsBackground: "#140e28"
    readonly property color kidsSurface: "#221838"
    readonly property color kidsSurfaceLayer: "#2e2245"
    readonly property color kidsAccent: "#ffd600"
    readonly property color kidsAccentWarm: "#ff804d"
    readonly property color kidsTextPrimary: "#fff5e6"

    readonly property int spacingXS: 4
    readonly property int spacingSM: 8
    readonly property int spacingMD: 16
    readonly property int spacingLG: 24
    readonly property int spacingXL: 32
    readonly property int spacingXXL: 48

    readonly property int outerPaddingCompact: 48
    readonly property int outerPaddingLeanBack: 72
    readonly property int cardGapCompact: 10
    readonly property int cardGapLeanBack: 16
    readonly property int sectionSpacingCompact: 48
    readonly property int sectionSpacingLeanBack: 64

    readonly property real posterCardWidthCompact: 150
    readonly property real posterCardWidthLeanBack: 225
    readonly property real posterTitleSizeCompact: 13
    readonly property real posterTitleSizeLeanBack: 18
    readonly property real posterTitleLineHeightCompact: 16
    readonly property real posterTitleLineHeightLeanBack: 22
    readonly property real posterMetadataSizeCompact: 11
    readonly property real posterMetadataSizeLeanBack: 15
    readonly property real posterMetadataLineHeightCompact: 13
    readonly property real posterMetadataLineHeightLeanBack: 18
    readonly property real posterLabelSpacingCompact: 2
    readonly property real posterLabelSpacingLeanBack: 4
    // Marquee/SharedViews/MovieCard.swift:366-371 sizes a browse row's own
    // header, and :375 spaces it 12 points from the cards below it.
    readonly property real rowTitleSizeCompact: 20
    readonly property real rowTitleSizeLeanBack: 28
    readonly property real rowCountSizeCompact: 12
    readonly property real rowCountSizeLeanBack: 16
    readonly property int rowHeaderToContent: 12
    readonly property real posterFrameTopPaddingCompact: 8
    readonly property real posterFrameTopPaddingLeanBack: 12
    // Marquee/Theme/MarqueeTheme.swift:230-232 reserves this halo around
    // focused cards in compact/lean-back modes.
    readonly property real posterFocusHaloPaddingCompact: 36
    readonly property real posterFocusHaloPaddingLeanBack: 52

    readonly property int radiusSM: 4
    readonly property int radiusMD: 8
    readonly property int radiusLG: 12
    // Marquee/SharedViews/MarqueeSidebar.swift rounds every sidebar control
    // to 6 points, which is neither of the theme's own radii: :86 and :93 the
    // Play Something control, :116 and :120 the profile control, and :193 and
    // :221-228 a route row's background and remote-focus ring.
    readonly property int sidebarControlRadius: 6
    readonly property int kidsRadiusMD: 14
    readonly property int kidsRadiusLG: 18

    readonly property real posterAspect: 2.0 / 3.0
    // Marquee/Theme/ViewModifiers/CardHoverModifier.swift:5-17 fixes the
    // poster and detail focus scales, glow radii, and ring line widths.
    readonly property real posterFocusScale: 1.045
    // Marquee/Features/Player/Views/PlayerControlsOverlay.swift:181: the
    // player HUD's controls grow by 1.07 on focus.
    readonly property real controlFocusScale: 1.07
    readonly property real detailFocusScale: 1.0
    // Marquee/Theme/ViewModifiers/CardHoverModifier.swift:7: the scale of a
    // plain control's focus chrome, such as Home's Play Something capsule.
    readonly property real capsuleFocusScale: 1.035
    readonly property real posterGlowRadius: 28
    readonly property real detailGlowRadius: 20
    readonly property real posterRingLineWidth: 2.25
    readonly property real detailRingLineWidth: 2.25
    readonly property int motionFast: 120
    readonly property int motionNormal: 250
    readonly property int motionPage: 350
    // Marquee/Theme/MarqueeTheme.swift:258's hero spring (response 0.5,
    // damping 0.82), as an ease that settles in the same half second; the
    // 0.82 damping's small overshoot is not reproduced.
    readonly property int motionHero: 500

    function scaled(compact, leanBack, enabled) {
        return enabled ? leanBack : compact
    }

    function outerPadding(leanBack) {
        return leanBack ? outerPaddingLeanBack : outerPaddingCompact
    }

    function cardGap(leanBack) {
        return leanBack ? cardGapLeanBack : cardGapCompact
    }

    function posterCardWidth(leanBack) {
        return scaled(posterCardWidthCompact, posterCardWidthLeanBack, leanBack)
    }

    function posterTitleSize(leanBack) {
        return scaled(posterTitleSizeCompact, posterTitleSizeLeanBack, leanBack)
    }

    function posterTitleLineHeight(leanBack) {
        return scaled(posterTitleLineHeightCompact, posterTitleLineHeightLeanBack, leanBack)
    }

    function posterMetadataSize(leanBack) {
        return scaled(posterMetadataSizeCompact, posterMetadataSizeLeanBack, leanBack)
    }

    function posterMetadataLineHeight(leanBack) {
        return scaled(posterMetadataLineHeightCompact, posterMetadataLineHeightLeanBack, leanBack)
    }

    function posterLabelSpacing(leanBack) {
        return scaled(posterLabelSpacingCompact, posterLabelSpacingLeanBack, leanBack)
    }

    function rowTitleSize(leanBack) {
        return scaled(rowTitleSizeCompact, rowTitleSizeLeanBack, leanBack)
    }

    function rowCountSize(leanBack) {
        return scaled(rowCountSizeCompact, rowCountSizeLeanBack, leanBack)
    }

    function posterFrameTopPadding(leanBack) {
        return scaled(posterFrameTopPaddingCompact, posterFrameTopPaddingLeanBack, leanBack)
    }

    function posterFocusHaloPadding(leanBack) {
        return scaled(posterFocusHaloPaddingCompact,
                      posterFocusHaloPaddingLeanBack,
                      leanBack)
    }

    function posterLabelHeight(leanBack) {
        return 2 * posterTitleLineHeight(leanBack)
            + 2 * posterMetadataLineHeight(leanBack)
            + 2 * posterLabelSpacing(leanBack)
    }

    function posterCardHeight(leanBack) {
        return posterFrameTopPadding(leanBack)
            + posterCardWidth(leanBack) / posterAspect
            + scaled(6, 10, leanBack)
            + posterLabelHeight(leanBack)
    }

    function sectionSpacing(leanBack) {
        return leanBack ? sectionSpacingLeanBack : sectionSpacingCompact
    }
}
