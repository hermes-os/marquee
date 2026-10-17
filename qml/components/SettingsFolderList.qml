import QtQuick
import Marquee 3.0

// SettingsDetailView.swift:221-288: one folder list of the Library section.
// The heading, the empty hint or the folder rows with their remove controls,
// and the Add Folder control. The Library section shows two of these, one
// for movies and one for TV shows (:186-197).
Column {
    id: root

    required property string title
    required property var paths
    // The prefix of the focus kinds this list answers to: "folder" and
    // "addFolder" for the movies list, "tvFolder" and "addTvFolder" for the
    // TV list, so each list's controls stay distinct in the page's order.
    required property string folderKind
    required property string addKind
    required property var isFocused
    required property var reveal

    signal removeRequested(int index)
    signal addRequested()

    spacing: 10

    Text {
        text: root.title
        color: Theme.textPrimary
        font.pixelSize: 14
        font.weight: Font.DemiBold
    }

    // :227-236.
    Row {
        visible: root.paths.length === 0
        spacing: 8
        topPadding: 8
        bottomPadding: 8

        MarqueeSymbol {
            anchors.verticalCenter: parent.verticalCenter
            symbol: "folder.badge.questionmark"
            pointSize: 13
            color: Theme.textTertiary
        }

        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: qsTr("No folders configured. Add a folder to get started.")
            color: Theme.textTertiary
            font.pixelSize: 13
        }
    }

    Column {
        width: parent.width
        spacing: 6

        Repeater {
            id: folderRepeater
            objectName: root.folderKind + "Repeater"
            model: root.paths

            // :260-288.
            Rectangle {
                id: folderRow
                required property string modelData
                required property int index
                readonly property bool focused: root.isFocused(root.folderKind, index)

                width: parent.width
                height: 16 + Math.max(pathLabel.height, 14)
                radius: Theme.radiusSM
                color: Theme.surfaceElevated
                border.width: folderRow.focused ? 2 : 0
                border.color: Theme.structuralFocus

                onFocusedChanged: if (focused) root.reveal(folderRow)

                MarqueeSymbol {
                    id: folderIcon
                    anchors.left: parent.left
                    anchors.leftMargin: 12
                    anchors.verticalCenter: parent.verticalCenter
                    symbol: "folder.fill"
                    pointSize: 12
                    color: Theme.accentSecondary
                }

                Text {
                    id: pathLabel
                    anchors.left: folderIcon.right
                    anchors.leftMargin: 10
                    anchors.right: removeControl.left
                    anchors.rightMargin: 10
                    anchors.verticalCenter: parent.verticalCenter
                    text: folderRow.modelData
                    color: Theme.textSecondary
                    font.pixelSize: 13
                    elide: Text.ElideMiddle
                }

                MarqueeSymbol {
                    id: removeControl
                    anchors.right: parent.right
                    anchors.rightMargin: 12
                    anchors.verticalCenter: parent.verticalCenter
                    symbol: "minus.circle.fill"
                    pointSize: 14
                    color: folderRow.focused ? Theme.textPrimary : Theme.textTertiary

                    TapHandler {
                        onTapped: root.removeRequested(folderRow.index)
                    }
                }
            }
        }
    }

    // :247-256.
    Item {
        id: addFolderControl
        objectName: root.addKind + "Control"
        readonly property bool focused: root.isFocused(root.addKind)
        width: addFolderRow.width + 12
        height: 26
        onFocusedChanged: if (focused) root.reveal(addFolderControl)

        Rectangle {
            anchors.fill: parent
            radius: Theme.radiusSM
            color: "transparent"
            border.width: addFolderControl.focused ? 2 : 0
            border.color: Theme.structuralFocus
        }

        Row {
            id: addFolderRow
            anchors.centerIn: parent
            spacing: 6

            MarqueeSymbol {
                anchors.verticalCenter: parent.verticalCenter
                symbol: "plus"
                pointSize: 11
                strokeRatio: 0.16
                color: Theme.accentBright
            }

            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: qsTr("Add Folder")
                color: Theme.accentBright
                font.pixelSize: 13
                font.weight: Font.Medium
            }
        }

        TapHandler {
            onTapped: root.addRequested()
        }
    }
}
