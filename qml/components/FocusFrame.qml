import QtQuick
import Marquee 3.0

// Marquee/Theme/ViewModifiers/CardHoverModifier.swift:48-72 draws focus
// chrome around a surface's layout bounds: the owner scales its content by
// focusScale while this frame stays at the unscaled bounds, so the shadows
// follow the scaled silhouette and the ring keeps its unscaled inset.
Item {
    id: root

    property bool active: false
    property real radius: Theme.radiusMD
    property color accent: Theme.structuralFocus
    // Scale the owner draws its focused content at; the frame itself never
    // scales.
    property real focusScale: Theme.posterFocusScale
    // How far outside the bounds the shadows may paint. A poster row reserves
    // Marquee/Theme/MarqueeTheme.swift:230-232 vertically; other surfaces let
    // the blurred shadows run their course.
    property real haloPadding: Math.ceil(Math.max(
        root.focusedShadowRadius + root.focusedShadowOffsetY,
        root.focusedGlowRadius))
    // Marquee/Theme/ViewModifiers/CardHoverModifier.swift:64-67 supplies the
    // 2.25-point ring and 0.95 opacity.
    property real ringWidth: Theme.posterRingLineWidth
    property real ringOpacity: 0.95

    // Marquee/Theme/ViewModifiers/CardHoverModifier.swift:51-59 supplies the
    // resting and focused shadows and the focused accent glow.
    property real focusedShadowRadius: 26
    property real focusedShadowOffsetY: 14
    property real focusedShadowOpacity: 0.68
    property real idleShadowRadius: 4
    property real idleShadowOffsetY: 2
    property real idleShadowOpacity: 0.22
    property real focusedGlowRadius: Theme.posterGlowRadius
    property real focusedGlowOpacity: 0.48

    clip: false

    // The shadows are SoftShadow items, which blur on the GPU where there is
    // one; a Canvas `shadowBlur` here cost the GUI thread about 370 ms each
    // time it painted. The halo item keeps the padded bounds the canvas had.
    Item {
        id: halo

        objectName: "focusHalo"
        anchors.fill: parent
        anchors.margins: -root.haloPadding

        // CardHoverModifier.swift:50-55 casts the shadows from the content
        // as scaled, so the silhouette grows about its centre.
        readonly property real shadowScale: root.active ? root.focusScale : 1.0

        // Emitted once a frame that follows a change to the halo's state has
        // been presented, as the canvas this item replaced did when it
        // finished repainting for that state.
        signal painted()

        property bool stale: false
        readonly property var state: [root.active, root.accent, root.radius, root.focusScale,
            root.focusedShadowRadius, root.focusedShadowOffsetY, root.focusedShadowOpacity,
            root.idleShadowRadius, root.idleShadowOffsetY, root.idleShadowOpacity,
            root.focusedGlowRadius, root.focusedGlowOpacity, root.width, root.height]
        onStateChanged: {
            halo.stale = true
            halo.update()
        }

        Connections {
            target: halo.Window.window

            function onFrameSwapped() {
                if (halo.stale) {
                    halo.stale = false
                    halo.painted()
                }
            }
        }

        SoftShadow {
            objectName: "focusShadow"

            anchors.centerIn: parent
            width: root.width * halo.shadowScale
            height: root.height * halo.shadowScale
            radius: root.radius * halo.shadowScale
            // CardHoverModifier.swift:51-55 uses black opacity 0.68, radius
            // 26, and a 14-point downward offset while focused.
            shadowColor: Qt.rgba(0, 0, 0, root.active
                ? root.focusedShadowOpacity : root.idleShadowOpacity)
            blur: root.active ? root.focusedShadowRadius : root.idleShadowRadius
            offsetY: root.active ? root.focusedShadowOffsetY : root.idleShadowOffsetY
        }

        // The loader takes the shadow's footprint: a Loader resizes what it
        // loads to its own size, and the glow is cast from the silhouette.
        Loader {
            anchors.centerIn: parent
            width: root.width * halo.shadowScale
            height: root.height * halo.shadowScale
            active: root.active

            // CardHoverModifier.swift:56-59 uses the structural accent at
            // opacity 0.48 and no vertical offset for its glow.
            sourceComponent: SoftShadow {
                objectName: "focusGlow"

                radius: root.radius * halo.shadowScale
                shadowColor: Qt.rgba(root.accent.r, root.accent.g, root.accent.b,
                                     root.focusedGlowOpacity)
                blur: root.focusedGlowRadius
                offsetY: 0
            }
        }
    }

    // CardHoverModifier.swift:61-69 pads the ring overlay by its own line
    // width inside the unscaled bounds and strokes inward from there, screen
    // blended over whatever is already painted beneath it.
    FocusRing {
        id: ring

        objectName: "focusRing"
        anchors.fill: parent
        anchors.margins: root.ringWidth
        visible: root.active
        opacity: root.ringOpacity
        lineWidth: root.ringWidth
        cornerRadius: root.radius
        color: root.accent
    }
}
