import QtQuick
import Marquee 3.0

// A square player HUD control: PlayerControlsOverlay.swift:166-215's
// PlayerHUDControlFocusModifier. A black-at-0.52 rounded square (0.24 of its
// side) with a white-at-0.10 hairline, which turns structural-accent at 0.28
// with a brighter hairline and the focus chrome (scale 1.07, 30-point glow)
// when it holds the remote. The 48 and 68 sides, the 3 and 4 ring widths, and
// the glyph sizes of 16 and 24 are the compact and lean-back values
// (PlayerControlsOverlay.swift:158-162, :337-471).
FocusScope {
    id: root

    property string symbol: ""
    property color symbolColor: Theme.textPrimary
    // Text drawn on the button: alone it replaces the symbol (the speed
    // control's "1.5x", PlayerControlsOverlay.swift:503-510), beside one it is
    // set inside it (the skip buttons' "10" and "30", :380, :392).
    property string label: ""
    property color labelColor: root.symbolColor
    property real labelSize: Theme.scaled(12, 17, root.leanBack)
    property real glyphSize: Theme.scaled(16, 24, root.leanBack)
    // How round the face is: PlayerControlsOverlay.swift:207 rounds to 0.24
    // of the side, and the top bar's close control is a circle (:181).
    property real cornerRatio: 0.24
    property bool leanBack: false
    property bool reduceMotion: false
    property string accessibleName: ""
    readonly property bool focused: root.activeFocus

    // `byPointer` tells a tap from a key, so the owner can hand a menu the
    // way it was opened.
    signal activated(bool byPointer)

    implicitWidth: Theme.scaled(48, 68, root.leanBack)
    implicitHeight: implicitWidth
    width: implicitWidth
    height: implicitHeight

    FocusFrame {
        anchors.fill: parent
        active: root.focused
        radius: root.width * root.cornerRatio
        focusScale: 1.07
        ringWidth: Theme.scaled(3, 4, root.leanBack)
        focusedGlowRadius: 30
    }

    Rectangle {
        id: face
        objectName: "playerHudButtonFace"
        anchors.fill: parent
        radius: root.width * root.cornerRatio
        color: root.focused ? Qt.rgba(Theme.structuralFocus.r, Theme.structuralFocus.g,
                                      Theme.structuralFocus.b, 0.28)
                            : Qt.rgba(0, 0, 0, 0.52)
        border.width: 1
        border.color: Qt.rgba(1, 1, 1, root.focused ? 0.22 : 0.10)
        scale: root.focused ? 1.07 : 1.0

        Behavior on scale {
            enabled: !root.reduceMotion
            NumberAnimation {
                duration: Theme.motionFast
                easing.type: Easing.OutCubic
            }
        }

        MarqueeSymbol {
            anchors.centerIn: parent
            visible: root.symbol.length > 0
            symbol: root.symbol
            color: root.symbolColor
            pointSize: root.glyphSize
        }

        Text {
            objectName: "playerHudButtonLabel"
            anchors.centerIn: parent
            visible: root.label.length > 0
            text: root.label
            color: root.labelColor
            font.pixelSize: root.labelSize
            font.weight: Font.DemiBold
            font.family: "monospace"
        }
    }

    Keys.onReturnPressed: event => { event.accepted = true; root.activated(false) }
    Keys.onEnterPressed: event => { event.accepted = true; root.activated(false) }
    Keys.onSpacePressed: event => { event.accepted = true; root.activated(false) }
    Keys.onSelectPressed: event => { event.accepted = true; root.activated(false) }

    TapHandler {
        onTapped: root.activated(true)
    }

    Accessible.name: root.accessibleName
    Accessible.role: Accessible.Button
}
