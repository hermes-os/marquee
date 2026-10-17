import QtQuick
import Marquee 3.0

// SettingsDetailView.swift:418-421: a macOS switch toggle tinted with the
// primary accent. The track is 38x22 with a 20-point knob; the remote's
// focus is a structural ring, and Select flips it.
Item {
    id: root

    property bool checked: false
    property bool focused: false
    property bool reduceMotion: appController.settings.reduceMotion

    signal toggled(bool value)

    implicitWidth: 38
    implicitHeight: 22

    Rectangle {
        id: track
        anchors.fill: parent
        radius: height / 2
        color: root.checked ? Theme.accentPrimary : Theme.surfaceElevated
        border.width: root.focused ? 2 : 1
        border.color: root.focused
            ? Theme.structuralFocus
            : Qt.rgba(1, 1, 1, root.checked ? 0.0 : 0.16)

        Behavior on color {
            enabled: !root.reduceMotion
            ColorAnimation { duration: Theme.motionNormal }
        }
    }

    Rectangle {
        id: knob
        width: 18
        height: 18
        radius: 9
        y: 2
        x: root.checked ? root.width - width - 2 : 2
        color: "white"

        Behavior on x {
            enabled: !root.reduceMotion
            NumberAnimation { duration: Theme.motionNormal; easing.type: Easing.OutCubic }
        }
    }

    TapHandler {
        onTapped: root.toggled(!root.checked)
    }
}
