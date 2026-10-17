import QtQuick
import Marquee 3.0

// SettingsDetailView.swift:523-537 and :482-491: a macOS pop-up picker at a
// fixed width. The closed control shows the current choice with a chevron;
// the remote's Left/Right (or Select then Up/Down) walk the options, which
// is how a pop-up reads on a remote without a pointer.
Item {
    id: root

    property var options: []
    property string currentValue: ""
    property string placeholder: ""
    // Maps a stored value to the label shown for it.
    property var displayName: value => value
    property bool focused: false
    property real controlWidth: 160

    signal selected(string value)

    readonly property int currentIndex: root.options.indexOf(root.currentValue)

    implicitWidth: root.controlWidth
    implicitHeight: 24

    function step(delta) {
        if (root.options.length === 0) {
            return
        }
        const next = Math.min(root.options.length - 1,
                              Math.max(0, root.currentIndex + delta))
        if (next !== root.currentIndex) {
            root.selected(root.options[next])
        }
    }

    Rectangle {
        anchors.fill: parent
        radius: 6
        color: Theme.surfaceElevated
        border.width: root.focused ? 2 : 1
        border.color: root.focused ? Theme.structuralFocus : Qt.rgba(1, 1, 1, 0.12)

        Text {
            objectName: "pickerLabel"
            anchors.left: parent.left
            anchors.leftMargin: 10
            anchors.right: chevrons.left
            anchors.rightMargin: 6
            anchors.verticalCenter: parent.verticalCenter
            text: root.currentIndex >= 0 ? root.displayName(root.currentValue) : root.placeholder
            color: root.currentIndex >= 0 ? Theme.textPrimary : Theme.textSecondary
            font.pixelSize: 13
            elide: Text.ElideRight
        }

        // The stacked chevrons of a macOS pop-up button.
        Item {
            id: chevrons
            anchors.right: parent.right
            anchors.rightMargin: 6
            anchors.verticalCenter: parent.verticalCenter
            width: 14
            height: 16

            Rectangle {
                anchors.fill: parent
                radius: 4
                color: Theme.structuralFocus
            }

            Canvas {
                anchors.fill: parent
                onPaint: {
                    const context = getContext("2d")
                    context.clearRect(0, 0, width, height)
                    context.strokeStyle = "white"
                    context.lineWidth = 1.5
                    context.lineCap = "round"
                    context.lineJoin = "round"
                    context.beginPath()
                    context.moveTo(4, 6.5)
                    context.lineTo(7, 3.5)
                    context.lineTo(10, 6.5)
                    context.moveTo(4, 9.5)
                    context.lineTo(7, 12.5)
                    context.lineTo(10, 9.5)
                    context.stroke()
                }
            }
        }
    }

    TapHandler {
        onTapped: root.step(1)
    }
}
