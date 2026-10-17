import QtQuick
import Marquee 3.0

// SettingsDetailView.swift:500-515: a horizontal slider whose track is
// tinted with the primary accent; Left/Right move it by one step.
Item {
    id: root

    property real value: 0
    property real from: 0
    property real to: 1
    property real stepSize: 0.1
    property bool focused: false

    signal moved(real value)

    implicitWidth: 200
    implicitHeight: 20

    readonly property real fraction:
        root.to > root.from ? (root.value - root.from) / (root.to - root.from) : 0

    function step(delta) {
        const next = Math.min(root.to, Math.max(root.from, root.value + delta * root.stepSize))
        if (Math.abs(next - root.value) > 1e-6) {
            root.moved(Number(next.toFixed(4)))
        }
    }

    Rectangle {
        id: track
        anchors.verticalCenter: parent.verticalCenter
        anchors.left: parent.left
        anchors.right: parent.right
        height: 4
        radius: 2
        color: Qt.rgba(1, 1, 1, 0.16)

        Rectangle {
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: parent.width * root.fraction
            radius: 2
            color: Theme.accentPrimary
        }
    }

    Rectangle {
        id: knob
        width: 18
        height: 18
        radius: 9
        anchors.verticalCenter: parent.verticalCenter
        x: (root.width - width) * root.fraction
        color: "white"
        border.width: root.focused ? 2 : 0
        border.color: Theme.structuralFocus
    }

    DragHandler {
        target: null
        onCentroidChanged: {
            if (active) {
                const fraction = Math.min(1, Math.max(0, centroid.position.x / root.width))
                const raw = root.from + (root.to - root.from) * fraction
                const snapped = Math.round(raw / root.stepSize) * root.stepSize
                root.moved(Number(Math.min(root.to, Math.max(root.from, snapped)).toFixed(4)))
            }
        }
    }
}
