import QtQuick
import Marquee 3.0

// ProfilePickerView.swift:1118-1253: a management tile. A 128 disc with the
// symbol at 48 medium, the name at 16 semibold over the maturity label at 11
// medium, and the four round action controls (move left, edit, delete, move
// right) sized by :99-127 from the tile width, all on a 0.86 surface-layer
// panel with a 1-point 0.05 white edge that becomes the 2.5 structural ring
// while the tile holds focus, under a shadow that turns structural on focus.
Item {
    id: root

    property string title: ""
    property string subtitle: ""
    property string symbol: ""
    property color symbolColor: Theme.textPrimary
    property bool canMoveLeft: true
    property bool canMoveRight: true
    property bool canDelete: true
    property bool tileFocused: false
    // 0-3 for move left, edit, delete, move right; -1 for none.
    property int focusedAction: -1

    signal editRequested()
    signal deleteRequested()
    signal moveLeftRequested()
    signal moveRightRequested()
    signal pointerEntered()

    // :99-127: the buttons share the width inside a 16 inset, no larger than
    // 32 each and no closer than the spacing that keeps four at 26.
    readonly property real usableWidth: Math.max(0, root.width - 2 * 16)
    readonly property real minimumButton: Math.min(26, root.usableWidth / 4)
    readonly property real actionSpacing: Math.min(8, Math.max(0, (root.usableWidth - 4 * root.minimumButton) / 3))
    readonly property real actionSize: Math.min(32, Math.max(0, (root.usableWidth - 3 * root.actionSpacing) / 4))

    SoftShadow {
        anchors.fill: panel
        radius: panel.radius
        shadowColor: root.tileFocused
            ? Qt.rgba(Theme.structuralFocus.r, Theme.structuralFocus.g, Theme.structuralFocus.b, 0.34)
            : Qt.rgba(0, 0, 0, 0.24)
        blur: root.tileFocused ? 18 : 6
        offsetY: root.tileFocused ? 8 : 3
    }

    Rectangle {
        id: panel
        objectName: "profileTilePanel"

        anchors.fill: parent
        radius: Theme.radiusMD
        color: Qt.rgba(Theme.surfaceLayer.r, Theme.surfaceLayer.g, Theme.surfaceLayer.b, 0.86)
        border.width: root.tileFocused ? 2.5 : 1
        border.color: root.tileFocused ? Theme.structuralFocus : Qt.rgba(1, 1, 1, 0.05)
    }

    Column {
        objectName: "profileTileColumn"
        anchors.centerIn: parent
        width: parent.width - 2 * 16
        spacing: 12

        Rectangle {
            objectName: "profileTileDisc"
            anchors.horizontalCenter: parent.horizontalCenter
            width: 128
            height: 128
            radius: 64
            color: Theme.surfaceElevated

            MarqueeSymbol {
                objectName: "profileTileSymbol"
                anchors.centerIn: parent
                symbol: root.symbol
                fallbackSymbol: "person.crop.circle"
                pointSize: 48
                color: root.symbolColor
            }
        }

        Column {
            width: parent.width
            spacing: 4

            Text {
                objectName: "profileTileTitle"
                width: parent.width
                text: root.title
                color: Theme.textPrimary
                font.pixelSize: 16
                font.weight: Font.DemiBold
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideRight
            }

            Text {
                objectName: "profileTileSubtitle"
                width: parent.width
                text: root.subtitle
                color: Theme.textTertiary
                font.pixelSize: 11
                font.weight: Font.Medium
                horizontalAlignment: Text.AlignHCenter
            }
        }

        Row {
            objectName: "profileTileActions"
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: root.actionSpacing

            Repeater {
                model: [
                    { symbol: "chevron.left", enabled: root.canMoveLeft, destructive: false },
                    { symbol: "pencil", enabled: true, destructive: false },
                    { symbol: "trash", enabled: root.canDelete, destructive: true },
                    { symbol: "chevron.right", enabled: root.canMoveRight, destructive: false }
                ]

                // :1215-1252: a 13 semibold symbol on an elevated disc, red
                // for the destructive one, dimmed to 0.3 when disabled, with a
                // 2-point structural ring while focused.
                delegate: Rectangle {
                    required property var modelData
                    required property int index

                    objectName: "profileTileAction_" + index
                    width: root.actionSize
                    height: root.actionSize
                    radius: width / 2
                    color: Theme.surfaceElevated
                    border.width: root.focusedAction === index ? 2 : 0
                    border.color: Theme.structuralFocus

                    MarqueeSymbol {
                        anchors.centerIn: parent
                        symbol: modelData.symbol
                        pointSize: 13
                        strokeRatio: 0.105
                        color: modelData.destructive
                            ? Qt.rgba(1, 0, 0, modelData.enabled ? 0.9 : 0.3)
                            : Qt.rgba(Theme.textSecondary.r, Theme.textSecondary.g,
                                      Theme.textSecondary.b, modelData.enabled ? 1 : 0.3)
                    }

                    TapHandler {
                        enabled: modelData.enabled
                        onTapped: {
                            switch (index) {
                            case 0: root.moveLeftRequested(); break
                            case 1: root.editRequested(); break
                            case 2: root.deleteRequested(); break
                            case 3: root.moveRightRequested(); break
                            }
                        }
                    }

                    Accessible.role: Accessible.Button
                    Accessible.name: {
                        switch (index) {
                        case 0: return qsTr("Move %1 left").arg(root.title)
                        case 1: return qsTr("Edit %1").arg(root.title)
                        case 2: return qsTr("Delete %1").arg(root.title)
                        default: return qsTr("Move %1 right").arg(root.title)
                        }
                    }
                }
            }
        }
    }

    HoverHandler {
        onHoveredChanged: if (hovered) root.pointerEntered()
    }

    Accessible.name: qsTr("Manage %1, %2").arg(root.title).arg(root.subtitle)
}
