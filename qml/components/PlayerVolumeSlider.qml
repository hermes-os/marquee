import QtQuick
import Marquee 3.0

// The volume slider beside the player HUD's mute control
// (PlayerControlsOverlay.swift:535-542: a 0 to 100 slider, 80 wide and 130 in
// lean-back). A remote cannot drag, so Enter takes the slider and Left and
// Right then move the volume by one step until Enter, Back, Up or Down lets
// it go; a pointer taps or drags it directly.
FocusScope {
    id: root

    // Percent, 0 to 100.
    property real value: 100
    property real step: 5
    property bool muted: false
    property bool leanBack: false
    property bool reduceMotion: false
    property string accessibleName: ""
    // The remote has taken the slider: Left and Right change the volume.
    property bool editing: false
    readonly property bool focused: root.activeFocus
    readonly property real fraction: Math.max(0, Math.min(1, root.value / 100))

    // The new absolute volume, from a key step or the pointer.
    signal adjusted(real value)

    implicitWidth: Theme.scaled(80, 130, root.leanBack)
    implicitHeight: Theme.scaled(48, 68, root.leanBack)
    width: implicitWidth
    height: implicitHeight

    onActiveFocusChanged: if (!root.activeFocus) root.editing = false

    function valueAt(x) {
        return Math.round(Math.max(0, Math.min(1, x / root.width)) * 100)
    }

    FocusFrame {
        anchors.fill: parent
        active: root.focused
        radius: root.height * 0.24
        focusScale: 1.07
        ringWidth: Theme.scaled(3, 4, root.leanBack)
        focusedGlowRadius: 30
    }

    Rectangle {
        id: face
        objectName: "playerVolumeFace"
        anchors.fill: parent
        radius: root.height * 0.24
        color: root.editing ? Qt.rgba(Theme.structuralFocus.r, Theme.structuralFocus.g,
                                      Theme.structuralFocus.b, 0.28)
                            : Qt.rgba(0, 0, 0, 0.52)
        border.width: 1
        border.color: Qt.rgba(1, 1, 1, root.focused ? 0.22 : 0.10)
    }

    Rectangle {
        id: track
        anchors.verticalCenter: parent.verticalCenter
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: knob.width / 2 + 4
        anchors.rightMargin: knob.width / 2 + 4
        height: Theme.scaled(4, 6, root.leanBack)
        radius: height / 2
        color: Qt.rgba(1, 1, 1, 0.16)

        Rectangle {
            objectName: "playerVolumeFill"
            width: parent.width * root.fraction
            height: parent.height
            radius: parent.radius
            color: root.muted ? Theme.textTertiary : Theme.accentSecondary
        }
    }

    Rectangle {
        id: knob
        width: Theme.scaled(14, 20, root.leanBack)
        height: width
        radius: width / 2
        anchors.verticalCenter: parent.verticalCenter
        x: 4 + (root.width - 8 - width) * root.fraction
        color: root.muted ? Theme.textTertiary : "white"
        border.width: root.editing ? 2 : 0
        border.color: Theme.structuralFocus
    }

    Keys.onPressed: event => {
        const select = event.key === Qt.Key_Return || event.key === Qt.Key_Enter
            || event.key === Qt.Key_Select || event.key === Qt.Key_Space
        if (!root.editing) {
            if (select) {
                root.editing = true
                event.accepted = true
            }
            return
        }
        switch (event.key) {
        case Qt.Key_Left:
            root.adjusted(Math.max(0, root.value - root.step))
            break
        case Qt.Key_Right:
            root.adjusted(Math.min(100, root.value + root.step))
            break
        case Qt.Key_Return:
        case Qt.Key_Enter:
        case Qt.Key_Select:
        case Qt.Key_Space:
        case Qt.Key_Escape:
        case Qt.Key_Back:
        case Qt.Key_Backspace:
            root.editing = false
            break
        case Qt.Key_Up:
        case Qt.Key_Down:
            // The slider lets go and the key does its ordinary work.
            root.editing = false
            return
        default:
            return
        }
        event.accepted = true
    }

    TapHandler {
        onTapped: eventPoint => root.adjusted(root.valueAt(eventPoint.position.x))
    }

    DragHandler {
        target: null
        onCentroidChanged: {
            if (active) {
                root.adjusted(root.valueAt(centroid.position.x))
            }
        }
    }

    Accessible.name: root.accessibleName
    Accessible.role: Accessible.Slider
}
