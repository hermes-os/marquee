import QtQuick
import Marquee 3.0

// ProfilePickerView.swift:591-600 is the one alert the released application
// shows: a title, a message, a destructive primary action, and Cancel. AppKit
// draws it as a centred sheet; here it is a centred panel on the elevated
// surface over a dimmed scrim, with the same copy and the same two actions,
// Cancel to the right of the destructive action as AppKit lays them out.
Item {
    id: root

    property bool open: false
    property string title: ""
    property string message: ""
    property string confirmLabel: qsTr("OK")
    property bool destructive: false
    property bool leanBack: false

    signal confirmed()
    signal dismissed()

    visible: root.open
    focus: root.open

    onOpenChanged: {
        if (root.open) {
            root.forceActiveFocus()
        }
    }

    Rectangle {
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.55)
        TapHandler { onTapped: root.dismissed() }
    }

    SoftShadow {
        anchors.fill: panel
        radius: panel.radius
        shadowColor: Qt.rgba(0, 0, 0, 0.5)
        blur: 24
        offsetY: 8
    }

    Rectangle {
        id: panel
        objectName: "confirmDialogPanel"

        anchors.centerIn: parent
        width: Theme.scaled(420, 600, root.leanBack)
        height: column.height + 2 * Theme.scaled(24, 34, root.leanBack)
        radius: 16
        color: Theme.surfaceElevated

        Column {
            id: column
            anchors.centerIn: parent
            width: parent.width - 2 * Theme.scaled(24, 34, root.leanBack)
            spacing: Theme.scaled(12, 18, root.leanBack)

            Text {
                objectName: "confirmDialogTitle"
                width: parent.width
                text: root.title
                color: Theme.textPrimary
                font.pixelSize: Theme.scaled(17, 24, root.leanBack)
                font.weight: Font.Bold
                wrapMode: Text.Wrap
            }

            Text {
                objectName: "confirmDialogMessage"
                width: parent.width
                text: root.message
                color: Theme.textSecondary
                font.pixelSize: Theme.scaled(13, 18, root.leanBack)
                wrapMode: Text.Wrap
            }

            Row {
                anchors.right: parent.right
                spacing: Theme.scaled(12, 18, root.leanBack)
                topPadding: Theme.scaled(8, 12, root.leanBack)

                Rectangle {
                    objectName: "confirmDialogConfirm"
                    width: confirmText.width + 2 * Theme.scaled(20, 28, root.leanBack)
                    height: confirmText.height + 2 * Theme.scaled(8, 13, root.leanBack)
                    radius: height / 2
                    color: root.destructive ? "#c0392b" : Theme.accentPrimary

                    Text {
                        id: confirmText
                        anchors.centerIn: parent
                        text: root.confirmLabel
                        color: "#ffffff"
                        font.pixelSize: Theme.scaled(14, 20, root.leanBack)
                        font.weight: Font.DemiBold
                    }

                    TapHandler { onTapped: root.confirmed() }
                }

                Rectangle {
                    objectName: "confirmDialogCancel"
                    width: cancelText.width + 2 * Theme.scaled(20, 28, root.leanBack)
                    height: cancelText.height + 2 * Theme.scaled(8, 13, root.leanBack)
                    radius: height / 2
                    color: "transparent"
                    border.width: 1
                    border.color: Qt.rgba(Theme.textTertiary.r, Theme.textTertiary.g, Theme.textTertiary.b, 0.4)

                    Text {
                        id: cancelText
                        anchors.centerIn: parent
                        text: qsTr("Cancel")
                        color: Theme.textSecondary
                        font.pixelSize: Theme.scaled(14, 20, root.leanBack)
                        font.weight: Font.Medium
                    }

                    TapHandler { onTapped: root.dismissed() }
                }
            }
        }
    }

    Keys.onPressed: event => {
        switch (event.key) {
        case Qt.Key_Return:
        case Qt.Key_Enter:
            root.confirmed()
            event.accepted = true
            return
        case Qt.Key_Escape:
        case Qt.Key_Back:
        case Qt.Key_Backspace:
            root.dismissed()
            event.accepted = true
            return
        default:
            event.accepted = true
        }
    }
}
