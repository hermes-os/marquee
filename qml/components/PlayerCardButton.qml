import QtQuick
import Marquee 3.0

// A text button on the player's cards (Next episode, Still watching?). It
// takes the remote like the HUD's controls do: the 1.07 focus scale, the
// structural-accent face and ring, and Enter, Space or Select activate it. The
// primary action is drawn white, as the failure card's Close is.
FocusScope {
    id: root

    property string label: ""
    property bool primary: false
    property bool leanBack: false
    property bool reduceMotion: false
    readonly property bool focused: root.activeFocus

    signal activated(bool byPointer)

    implicitWidth: Math.max(Theme.scaled(120, 180, root.leanBack),
                            labelText.implicitWidth + 2 * Theme.scaled(20, 30, root.leanBack))
    implicitHeight: Theme.scaled(34, 52, root.leanBack)
    width: implicitWidth
    height: implicitHeight

    FocusFrame {
        anchors.fill: parent
        active: root.focused
        radius: Theme.radiusMD
        focusScale: Theme.controlFocusScale
        ringWidth: Theme.scaled(3, 4, root.leanBack)
        focusedGlowRadius: 30
    }

    Rectangle {
        objectName: "playerCardButtonFace"
        anchors.fill: parent
        radius: Theme.radiusMD
        color: root.focused ? Qt.rgba(Theme.structuralFocus.r, Theme.structuralFocus.g,
                                      Theme.structuralFocus.b, 0.55)
                            : root.primary ? "white" : Qt.rgba(0, 0, 0, 0.52)
        border.width: 1
        border.color: Qt.rgba(1, 1, 1, root.focused ? 0.30 : 0.14)
        scale: root.focused ? Theme.controlFocusScale : 1.0

        Behavior on scale {
            enabled: !root.reduceMotion
            NumberAnimation {
                duration: Theme.motionFast
                easing.type: Easing.OutCubic
            }
        }

        Text {
            id: labelText
            anchors.centerIn: parent
            text: root.label
            color: root.focused || !root.primary ? Theme.textPrimary : "black"
            font.pixelSize: Theme.scaled(14, 20, root.leanBack)
            font.weight: Font.DemiBold
        }
    }

    Keys.onReturnPressed: event => { event.accepted = true; root.activated(false) }
    Keys.onEnterPressed: event => { event.accepted = true; root.activated(false) }
    Keys.onSpacePressed: event => { event.accepted = true; root.activated(false) }
    Keys.onSelectPressed: event => { event.accepted = true; root.activated(false) }

    TapHandler {
        onTapped: root.activated(true)
    }

    Accessible.name: root.label
    Accessible.role: Accessible.Button
}
