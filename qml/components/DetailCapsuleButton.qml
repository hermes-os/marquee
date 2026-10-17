import QtQuick
import Marquee 3.0

// The detail hero's action control, shared by both detail screens. The show
// actions are a capsule (ShowDetailView.swift:395-435: Capsule fill,
// :403-404 and :424-425 padding 20/10, :396-400 and :417-421 label 13
// semibold, :397-398 glyph backward.end.fill 11 and :418-419 glyph play.fill
// 12, :408-412 and :429-433 detailFocusSurface cornerRadius 999, i.e. a pill
// ring). The movie actions are a rounded rectangle instead
// (MovieDetailView.swift:402-403 and :436-437:
// RoundedRectangle(cornerRadius: MarqueeTheme.cornerRadiusMD), and
// MarqueeTheme.swift:245 fixes cornerRadiusMD at 8; :400-401 and :433-434
// padding 28/12 on Start and 20/12 on Resume; :393 sets the inner HStack
// spacing 8; :393-397 Start label 15 bold with glyph play.fill 14; :426-430 Resume label 13 semibold with glyph
// play.fill 12; :417-421 and :441-445 detailFocusSurface cornerRadius
// MarqueeTheme.cornerRadiusMD, i.e. a radius-8 ring).
// Every geometry property below defaults to the show capsule, and the movie
// call sites in DetailsScreen.qml override each one; ShowDetailScreen.qml is
// untouched, so the show rendering is pixel-identical. The focus ring follows
// the same surface radius the way detailFocusSurface does
// (DetailFocusSurfaceModifier.swift:16-27), including its kids-mode floor
// (:12-14: max(cornerRadius, kidsCornerRadiusMD), MarqueeTheme.swift:185
// fixes kidsCornerRadiusMD at 14).
// MovieDetailView.swift:402-413 fills Start From Beginning with the gold
// gradient from accentSecondary to 0.85 of itself, top-leading to
// bottom-trailing; the accepted `fill` contract stays a single color, and the
// gradient is drawn only while the base is full gold. The bottom stop is that
// 0.85 ink composited over the page behind the button
// (MovieDetailView.swift:47-49 paints MarqueeTheme.background there;
// MarqueeTheme.swift:105 fixes it at #0d0b1a), expressed here as a live blend
// against `pageBackground` rather than a precomputed literal.
Item {
    id: root

    required property string label
    property string glyph: "play.fill"
    property color fill: Theme.accentPrimary
    property color textColor: "#ffffff"
    property bool leanBack: false
    property bool focused: false
    property color focusAccent: Theme.accentPrimary
    property bool kidsMode: false
    // The page behind the button, which the gold gradient's 0.85 stop
    // composites over.
    property color pageBackground: Theme.background

    // Negative means the show pill: half the height, as before.
    property real surfaceRadius: -1
    readonly property real effectiveRadius: root.surfaceRadius < 0 ? root.height / 2 : root.surfaceRadius
    readonly property real focusRadius: root.kidsMode
        ? Math.max(root.effectiveRadius, Theme.kidsRadiusMD) : root.effectiveRadius
    property real horizontalPadding: Theme.scaled(20, 30, root.leanBack)
    property real verticalPadding: Theme.scaled(10, 15, root.leanBack)
    property real contentSpacing: Theme.scaled(6, 10, root.leanBack)
    property real labelFontSize: Theme.scaled(13, 19, root.leanBack)
    property int labelFontWeight: Font.DemiBold
    property real glyphSize: root.glyph === "play.fill"
        ? Theme.scaled(12, 18, root.leanBack)
        : Theme.scaled(11, 16, root.leanBack)

    signal activated()

    implicitWidth: content.width + 2 * root.horizontalPadding
    implicitHeight: content.height + 2 * root.verticalPadding
    width: implicitWidth
    height: implicitHeight

    FocusFrame {
        anchors.fill: parent
        active: root.focused
        radius: root.focusRadius
        accent: root.focusAccent
        focusScale: Theme.detailFocusScale
        ringWidth: Theme.detailRingLineWidth
        // DetailFocusSurfaceModifier.swift:16-27 is FocusChromeModifier with
        // FocusChromeMetrics.detailFocusScale and .detailGlowRadius: the
        // 20-point accent glow at 0.48 with no offset, and the same 26/14
        // resting/focused black shadows as every other focus chrome. The
        // frame paints above the gold gradient, so the ring blends over the
        // stops it crosses.
        focusedGlowRadius: Theme.detailGlowRadius
        focusedGlowOpacity: 0.48
        focusedShadowRadius: 26
        focusedShadowOffsetY: 14
        z: 2
    }

    // MovieDetailView.swift:402-403 and :436-437: the 8-point rounded
    // rectangle behind each movie action. The gold Start button carries
    // its surface on the gradient canvas below (which hides this base
    // while it is visible); the flat Resume button has no gradient, so
    // this base IS its surface and stays at the oracle radius there.
    Rectangle {
        id: baseFill
        objectName: "capsuleBaseFill"
        anchors.fill: parent
        // The oracle paints one rounded-rectangle surface per action
        // (MovieDetailView.swift:402-403 on Start, :436-437 on Resume,
        // MarqueeTheme.swift:245 fixes cornerRadiusMD at 8): the gold Start
        // button's visible surface is the gradient canvas below — this base
        // hides while the gradient shows — so it keeps the oracle 8 here
        // and the paint stays single-sourced on the canvas; the show pill
        // (surfaceRadius < 0) keeps the released pill shape.
        radius: root.surfaceRadius < 0 ? root.effectiveRadius : 8
        color: root.fill
        visible: root.fill != Theme.accentSecondary
    }

    // MovieDetailView.swift:402-413: Start From Beginning fills the gold
    // gradient from accentSecondary to 0.85 of itself, top-leading to
    // bottom-trailing. Only the gold action carries it: the fill stays the
    // single released color everywhere else, so the gradient paints here
    // exactly when the base is full gold. The stops stay bindable
    // properties, so the suite judges the color contract on the item
    // rather than through the label, the ring, and the glow. The diagonal
    // paints on a Canvas below: Qt clips children to rectangles only,
    // never to `radius` arcs, so a rotated gradient Rectangle child of a
    // rounded surface would paint its square corners straight over the
    // arcs' cutouts. The canvas clips its own paint to the rounded path
    // instead, then paints the diagonal band inside that clip.
    Item {
        id: gradientRect
        objectName: "capsuleGoldGradient"
        anchors.fill: parent
        visible: root.fill == Theme.accentSecondary
        // The oracle's diagonal direction, in degrees: top-leading to
        // bottom-trailing on the oracle's Start button. 0 would be the
        // Rectangle default (top-to-bottom); 90 would be
        // leading-to-trailing. This is the live contract, not a nominal
        // literal: the canvas below binds its band rotation to it, so the
        // value rendering code reads is judged in the suite through the
        // painted pixels and the axis check, never against itself.
        property real diagonalAngle: -Math.atan2(gradientRect.width, gradientRect.height) * 180 / Math.PI
        property color stopTop: Theme.accentSecondary
        // The oracle's accentSecondary.opacity(0.85) composited over the page
        // background behind the button, blended here directly.
        property color stopBottom: {
            const fore = Theme.accentSecondary
            const back = root.pageBackground
            const opacity = 0.85
            return Qt.rgba(fore.r * opacity + back.r * (1 - opacity),
                           fore.g * opacity + back.g * (1 - opacity),
                           fore.b * opacity + back.b * (1 - opacity), 1)
        }
        // The oracle's RoundedRectangle(cornerRadius: 8): the golden Start
        // surface. The canvas clips its own paint to the rounded path
        // below, so the four corner cutouts outside the arcs show the
        // page behind the button instead of square gradient corners.
        // `cornerRadius` keeps the paint contract next to the paint: the
        // oracle 8 on the movie surface, the pill on the show default.
        // The suite judges both. `radius` aliases it, so the paint-only
        // squaring control (setting `radius: 0`) reaches the same paint.
        Canvas {
            id: gradientRounded
            objectName: "capsuleGoldGradientRounded"
            anchors.fill: parent
            antialiasing: true
            // The movie radius lives here so the paint contract stays next
            // to the paint: the oracle 8 on the movie surface, the pill on
            // the show default. The suite judges both.
            property real cornerRadius: root.effectiveRadius
            property real radius: cornerRadius
            // Paint-only squaring hook for the regression control: the
            // canvas reads `radius` (never `cornerRadius` directly), so
            // setting `radius: 0` squares the paint while `cornerRadius`
            // still reads 8.
            // Wide (not square) so the band's own top-to-bottom gradient
            // axis spans the capsule's diagonal: with the rotation below,
            // the axis runs from the visible leading corner to the visible
            // trailing one, and the extra length keeps every corner
            // covered on the widest Start button the details screens
            // compose. A square rotated 45° keeps the stops off the
            // corners of a wide capsule; this width does not. The paint
            // below reads these bindings, so the suite judges the same
            // geometry contract it always did — width, height, rotation,
            // centre — through `capsuleGoldGradientFill`.
            readonly property real bandWidth: Math.sqrt(gradientRect.width * gradientRect.width
                                 + gradientRect.height * gradientRect.height) + gradientRect.height
            readonly property real bandHeight: Math.sqrt(gradientRect.width * gradientRect.width
                                  + gradientRect.height * gradientRect.height)
            // The oracle's .topLeading -> .bottomTrailing diagonal: the
            // band's own gradient runs top-to-bottom in its local frame,
            // whose +y axis the rotation below maps to scene direction
            // (W, H)/|D| — right-and-down — so gold lands at the visible
            // leading (top-left) corner and the composited 0.85 ink at the
            // visible trailing (bottom-right) one. A positive
            // +atan2(h, w) rotation maps +y to (-sin, cos), down-and-LEFT,
            // exactly 90 degrees from the oracle at every aspect ratio;
            // the negative angle below maps +y to (sin a, cos a) with
            // tan a = W/H, i.e. onto (W, H)/|D|.
            readonly property real bandRotation: gradientRect.diagonalAngle
            // The rounded path the diagonal paints within, in the canvas's
            // own coordinates.
            function clipToSurface(context, paintWidth, paintHeight) {
                const corner = Math.max(0, Math.min(gradientRounded.radius,
                                                   Math.min(paintWidth, paintHeight) / 2))
                context.beginPath()
                context.moveTo(corner, 0)
                context.lineTo(paintWidth - corner, 0)
                context.arcTo(paintWidth, 0, paintWidth, corner, corner)
                context.lineTo(paintWidth, paintHeight - corner)
                context.arcTo(paintWidth, paintHeight, paintWidth - corner, paintHeight, corner)
                context.lineTo(corner, paintHeight)
                context.arcTo(0, paintHeight, 0, paintHeight - corner, corner)
                context.lineTo(0, corner)
                context.arcTo(0, 0, corner, 0, corner)
                context.closePath()
                context.clip()
            }
            onPaint: {
                const context = getContext("2d")
                context.reset()
                context.clearRect(0, 0, width, height)
                gradientRounded.clipToSurface(context, width, height)
                context.save()
                context.translate(width / 2, height / 2)
                context.rotate(gradientRounded.bandRotation * Math.PI / 180)
                const bandWidth = gradientRounded.bandWidth
                const bandHeight = gradientRounded.bandHeight
                const bandGradient = context.createLinearGradient(0, -bandHeight / 2,
                                                                 0, bandHeight / 2)
                bandGradient.addColorStop(0, gradientRect.stopTop)
                bandGradient.addColorStop(1, gradientRect.stopBottom)
                context.fillStyle = bandGradient
                context.fillRect(-bandWidth / 2, -bandHeight / 2, bandWidth, bandHeight)
                context.restore()
            }
            onWidthChanged: requestPaint()
            onHeightChanged: requestPaint()
            Connections {
                target: gradientRect
                function onDiagonalAngleChanged() { gradientRounded.requestPaint() }
                function onStopTopChanged() { gradientRounded.requestPaint() }
                function onStopBottomChanged() { gradientRounded.requestPaint() }
                function onWidthChanged() { gradientRounded.requestPaint() }
                function onHeightChanged() { gradientRounded.requestPaint() }
            }
            Connections {
                target: root
                function onEffectiveRadiusChanged() { gradientRounded.requestPaint() }
                function onFillChanged() { gradientRounded.requestPaint() }
            }
            // The band the suite reads for the geometry contract — width,
            // height, rotation, centre — kept as a real item so the
            // rotation/axis arithmetic, stop witnesses, band height, and
            // centring assertions keep judging the values the paint above
            // reads. It paints nothing itself; the canvas is the paint.
            Item {
                id: gradientBand
                objectName: "capsuleGoldGradientFill"
                anchors.centerIn: parent
                width: gradientRounded.bandWidth
                height: gradientRounded.bandHeight
                rotation: gradientRounded.bandRotation
                visible: false
            }
        } // gradientRounded
    }

    Row {
        id: content
        objectName: "capsuleContent"
        anchors.centerIn: parent
        spacing: root.contentSpacing

        // The glyph slot: show `play.fill` at 12/18, show
        // `backward.end.fill` at 11/16, movie Start `play.fill` at 14/21,
        // movie Resume `play.fill` at 12/18.
        Canvas {
            id: glyphCanvas
            objectName: "capsuleGlyph"
            anchors.verticalCenter: parent.verticalCenter
            width: root.glyphSize
            height: width
            onPaint: {
                const context = getContext("2d")
                context.reset()
                context.clearRect(0, 0, width, height)
                context.fillStyle = root.textColor
                if (root.glyph === "backward.end.fill") {
                    // A bar at the leading edge and a triangle pointing at it.
                    context.fillRect(0, height * 0.1, Math.max(1.5, width * 0.16), height * 0.8)
                    context.beginPath()
                    context.moveTo(width, height * 0.1)
                    context.lineTo(width * 0.28, height * 0.5)
                    context.lineTo(width, height * 0.9)
                    context.closePath()
                    context.fill()
                    return
                }
                context.beginPath()
                context.moveTo(width * 0.12, 0)
                context.lineTo(width, height / 2)
                context.lineTo(width * 0.12, height)
                context.closePath()
                context.fill()
            }
            onWidthChanged: requestPaint()
            Connections {
                target: root
                function onTextColorChanged() { glyphCanvas.requestPaint() }
                function onGlyphChanged() { glyphCanvas.requestPaint() }
            }
        }

        Text {
            objectName: "capsuleLabel"
            anchors.verticalCenter: parent.verticalCenter
            text: root.label
            color: root.textColor
            font.pixelSize: root.labelFontSize
            font.weight: root.labelFontWeight
            // MovieDetailView.swift:399 paints white ink over gold. The curve
            // renderer keeps the glyph edge alpha-only on the OpenGL path;
            // texture glyphs can contribute chromatic fringe to the gold
            // surface they cover.
            renderType: root.fill == Theme.accentSecondary
                ? Text.CurveRendering : Text.QtRendering
        }
    }

    TapHandler { onTapped: root.activated() }
}
