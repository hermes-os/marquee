import QtQuick
import Marquee 3.0

// ProfilePickerView.swift:1257-1544: the profile editor. A 520x560 / 760x760
// panel on the elevated surface with a 16 radius and a 24-point black 0.5
// shadow; the "Edit Profile" / "New Profile" header at 22/31 bold with the
// bold xmark close at 14/20; a scrolled body of the name field, the avatar
// grid, and the maturity picker spaced 28/40 inside 24/34 padding, between
// two surface-layer dividers; and the footer of the inline delete
// confirmation, Cancel, and the accent Save capsule.
FocusScope {
    id: root

    property bool leanBack: false
    property bool reduceMotion: false
    property var store: null
    property string editingProfileId: ""
    property bool canDelete: false
    // The overlay's open state; the fields are reloaded on each opening
    // (:1358-1365).
    property bool active: false

    signal saved(string profileId, string name, string avatarIcon, string avatarColor, int maturityLevel)
    signal deleted(string profileId)
    signal cancelled()

    readonly property bool editing: root.editingProfileId.length > 0
    readonly property string trimmedName: nameField.text.trim()
    readonly property bool canSave: root.trimmedName.length > 0

    property string selectedIcon: ""
    property color selectedColor: "transparent"
    property int maturityLevel: 3
    property bool confirmingDelete: false

    readonly property real padding: Theme.scaled(24, 34, root.leanBack)
    // :1424-1429: 56/78 cells spaced 10/14.
    readonly property real cellSize: Theme.scaled(56, 78, root.leanBack)
    readonly property real cellSpacing: Theme.scaled(10, 14, root.leanBack)

    width: Theme.scaled(520, 760, root.leanBack)
    height: Theme.scaled(560, 760, root.leanBack)

    onActiveChanged: {
        if (!root.active) {
            return
        }
        root.confirmingDelete = false
        if (root.editing) {
            const profile = root.store.profileById(root.editingProfileId)
            nameField.text = profile.name || ""
            root.selectedIcon = profile.avatarIcon || ""
            root.selectedColor = profile.avatarColor || "transparent"
            root.maturityLevel = profile.maturityLevel === undefined ? 3 : profile.maturityLevel
        } else {
            // :1264-1267's initial state: the first catalog avatar and Adult.
            const first = root.store.avatarCatalog[0]
            nameField.text = ""
            root.selectedIcon = first.icon
            root.selectedColor = first.color
            root.maturityLevel = 3
        }
        nameField.forceActiveFocus()
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
        objectName: "profileEditorPanel"
        anchors.fill: parent
        radius: 16
        color: Theme.surfaceElevated
        clip: true

        // Header.
        Item {
            id: header
            objectName: "profileEditorHeader"

            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            height: headerTitle.height + 2 * root.padding

            Text {
                id: headerTitle
                objectName: "profileEditorTitle"
                anchors.left: parent.left
                anchors.leftMargin: root.padding
                anchors.verticalCenter: parent.verticalCenter
                text: root.editing ? qsTr("Edit Profile") : qsTr("New Profile")
                color: Theme.textPrimary
                font.pixelSize: Theme.scaled(22, 31, root.leanBack)
                font.weight: Font.Bold
            }

            MarqueeSymbol {
                objectName: "profileEditorClose"
                anchors.right: parent.right
                anchors.rightMargin: root.padding
                anchors.verticalCenter: parent.verticalCenter
                symbol: "xmark"
                pointSize: Theme.scaled(14, 20, root.leanBack)
                strokeRatio: 0.13
                color: Theme.textTertiary

                TapHandler { onTapped: root.cancelled() }
                Accessible.role: Accessible.Button
                Accessible.name: qsTr("Close")
            }
        }

        Rectangle {
            id: headerDivider
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: header.bottom
            height: 1
            color: Theme.surfaceLayer
        }

        // Body.
        Flickable {
            id: body
            objectName: "profileEditorBody"

            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: headerDivider.bottom
            anchors.bottom: footerDivider.top
            contentWidth: width
            contentHeight: bodyColumn.height + 2 * root.padding
            boundsBehavior: Flickable.StopAtBounds
            clip: true

            Column {
                id: bodyColumn
                x: root.padding
                y: root.padding
                width: body.width - 2 * root.padding
                spacing: Theme.scaled(28, 40, root.leanBack)

                // :1370-1387: the name field.
                Column {
                    width: parent.width
                    spacing: 8

                    Text {
                        text: qsTr("Name")
                        color: Theme.textSecondary
                        font.pixelSize: Theme.scaled(13, 18, root.leanBack)
                        font.weight: Font.DemiBold
                    }

                    Rectangle {
                        width: parent.width
                        height: nameField.implicitHeight + 2 * Theme.scaled(12, 18, root.leanBack)
                        radius: 8
                        color: Theme.surfaceLayer

                        TextInput {
                            id: nameField
                            objectName: "profileEditorName"
                            anchors.fill: parent
                            anchors.margins: Theme.scaled(12, 18, root.leanBack)
                            color: Theme.textPrimary
                            font.pixelSize: Theme.scaled(16, 23, root.leanBack)
                            selectionColor: Theme.accentPrimary
                            clip: true
                            focus: true
                            activeFocusOnTab: true
                            KeyNavigation.tab: avatarGrid
                            Keys.onReturnPressed: root.save()
                            Keys.onEnterPressed: root.save()
                            Keys.onEscapePressed: root.cancelled()
                        }
                    }
                }

                // :1391-1416: the avatar grid. v3 has no character avatar
                // service, so only the Icons section is composed.
                Column {
                    width: parent.width
                    spacing: Theme.scaled(16, 24, root.leanBack)

                    Text {
                        text: qsTr("Icons")
                        color: Theme.textSecondary
                        font.pixelSize: Theme.scaled(13, 18, root.leanBack)
                        font.weight: Font.DemiBold
                    }

                    Grid {
                        id: avatarGrid
                        objectName: "profileEditorAvatars"
                        columns: 8
                        columnSpacing: root.cellSpacing
                        rowSpacing: root.cellSpacing
                        activeFocusOnTab: true

                        Repeater {
                            model: root.store ? root.store.avatarCatalog : []

                            // :1468-1502: a 52/72 rounded cell on the surface
                            // layer, tinted 0.2 accent when chosen, ringed 2
                            // accent when chosen or 1 tertiary on hover, with
                            // the symbol at 22/32 medium in its colour, 1.1
                            // scale on hover.
                            delegate: Item {
                                required property var modelData
                                required property int index

                                objectName: "profileEditorAvatar_" + index
                                width: root.cellSize
                                height: root.cellSize

                                readonly property bool chosen: root.selectedIcon === modelData.icon
                                property bool hovered: false

                                Rectangle {
                                    anchors.centerIn: parent
                                    width: Theme.scaled(52, 72, root.leanBack)
                                    height: width
                                    radius: 8
                                    color: parent.chosen
                                        ? Qt.rgba(Theme.accentPrimary.r, Theme.accentPrimary.g, Theme.accentPrimary.b, 0.2)
                                        : Theme.surfaceLayer
                                    border.width: parent.chosen ? 2 : (parent.hovered ? 1 : 0)
                                    border.color: parent.chosen ? Theme.accentPrimary : Theme.textTertiary
                                    scale: parent.hovered ? 1.1 : 1.0
                                    Behavior on scale {
                                        enabled: !root.reduceMotion
                                        NumberAnimation { duration: Theme.motionNormal; easing.type: Easing.OutCubic }
                                    }

                                    MarqueeSymbol {
                                        anchors.centerIn: parent
                                        symbol: modelData.icon
                                        fallbackSymbol: "person.crop.circle"
                                        pointSize: Theme.scaled(22, 32, root.leanBack)
                                        color: modelData.color
                                    }
                                }

                                HoverHandler { onHoveredChanged: parent.hovered = hovered }
                                TapHandler {
                                    onTapped: {
                                        root.selectedIcon = modelData.icon
                                        root.selectedColor = modelData.color
                                    }
                                }
                            }
                        }
                    }
                }

                // :1506-1531: Content Rating, four buttons of the label at
                // 13/18 over the rating examples at 10/14, the chosen one on
                // the accent in white and semibold.
                Column {
                    width: parent.width
                    spacing: Theme.scaled(12, 18, root.leanBack)

                    Text {
                        text: qsTr("Content Rating")
                        color: Theme.textSecondary
                        font.pixelSize: Theme.scaled(13, 18, root.leanBack)
                        font.weight: Font.DemiBold
                    }

                    Row {
                        objectName: "profileEditorMaturity"
                        spacing: Theme.scaled(8, 12, root.leanBack)

                        Repeater {
                            model: 4

                            delegate: Rectangle {
                                required property int index

                                objectName: "profileEditorMaturity_" + index
                                readonly property bool chosen: root.maturityLevel === index

                                width: maturityColumn.width + 2 * Theme.scaled(16, 24, root.leanBack)
                                height: maturityColumn.height + 2 * Theme.scaled(8, 13, root.leanBack)
                                radius: 8
                                color: chosen ? Theme.accentPrimary : Theme.surfaceLayer

                                Column {
                                    id: maturityColumn
                                    anchors.centerIn: parent
                                    spacing: 4

                                    Text {
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        text: root.store ? root.store.maturityLabelFor(index) : ""
                                        color: parent.parent.chosen ? "#ffffff" : Theme.textSecondary
                                        font.pixelSize: Theme.scaled(13, 18, root.leanBack)
                                        font.weight: parent.parent.chosen ? Font.DemiBold : Font.Normal
                                    }

                                    Text {
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        text: root.store ? root.store.maturityExamplesFor(index) : ""
                                        color: Theme.textTertiary
                                        font.pixelSize: Theme.scaled(10, 14, root.leanBack)
                                    }
                                }

                                TapHandler { onTapped: root.maturityLevel = index }
                            }
                        }
                    }
                }
            }
        }

        Rectangle {
            id: footerDivider
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: footer.top
            height: 1
            color: Theme.surfaceLayer
        }

        // :1297-1345: the footer.
        Item {
            id: footer
            objectName: "profileEditorFooter"

            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: saveButton.height + 2 * root.padding

            Row {
                anchors.left: parent.left
                anchors.leftMargin: root.padding
                anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.scaled(12, 18, root.leanBack)
                visible: root.canDelete

                Text {
                    objectName: "profileEditorDeletePrompt"
                    visible: root.confirmingDelete
                    anchors.verticalCenter: parent.verticalCenter
                    text: qsTr("Delete this profile?")
                    color: "#ff3b30"
                    font.pixelSize: Theme.scaled(13, 18, root.leanBack)
                }

                Text {
                    objectName: "profileEditorDeleteConfirm"
                    visible: root.confirmingDelete
                    anchors.verticalCenter: parent.verticalCenter
                    text: qsTr("Yes, Delete")
                    color: "#ff3b30"
                    font.pixelSize: Theme.scaled(13, 18, root.leanBack)
                    font.weight: Font.DemiBold
                    TapHandler { onTapped: root.deleted(root.editingProfileId) }
                }

                Text {
                    objectName: "profileEditorDeleteCancel"
                    visible: root.confirmingDelete
                    anchors.verticalCenter: parent.verticalCenter
                    text: qsTr("Cancel")
                    color: Theme.textSecondary
                    font.pixelSize: Theme.scaled(13, 18, root.leanBack)
                    TapHandler { onTapped: root.confirmingDelete = false }
                }

                Text {
                    objectName: "profileEditorDelete"
                    visible: !root.confirmingDelete
                    anchors.verticalCenter: parent.verticalCenter
                    text: qsTr("Delete Profile")
                    color: Qt.rgba(1, 0.23, 0.19, 0.8)
                    font.pixelSize: Theme.scaled(13, 18, root.leanBack)
                    TapHandler { onTapped: root.confirmingDelete = true }
                }
            }

            Row {
                anchors.right: parent.right
                anchors.rightMargin: root.padding
                anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.scaled(12, 18, root.leanBack)

                Text {
                    objectName: "profileEditorCancel"
                    anchors.verticalCenter: parent.verticalCenter
                    text: qsTr("Cancel")
                    color: Theme.textSecondary
                    font.pixelSize: Theme.scaled(14, 20, root.leanBack)
                    font.weight: Font.Medium
                    TapHandler { onTapped: root.cancelled() }
                }

                Rectangle {
                    id: saveButton
                    objectName: "profileEditorSave"
                    anchors.verticalCenter: parent.verticalCenter
                    width: saveLabel.width + 2 * Theme.scaled(24, 34, root.leanBack)
                    height: saveLabel.height + 2 * Theme.scaled(8, 13, root.leanBack)
                    radius: height / 2
                    color: root.canSave
                        ? Theme.accentPrimary
                        : Qt.rgba(Theme.accentPrimary.r, Theme.accentPrimary.g, Theme.accentPrimary.b, 0.3)

                    Text {
                        id: saveLabel
                        anchors.centerIn: parent
                        text: qsTr("Save")
                        color: "#ffffff"
                        font.pixelSize: Theme.scaled(14, 20, root.leanBack)
                        font.weight: Font.DemiBold
                    }

                    TapHandler {
                        enabled: root.canSave
                        onTapped: root.save()
                    }
                }
            }
        }
    }

    // :1535-1544.
    function save() {
        if (!root.canSave) {
            return
        }
        root.saved(root.editingProfileId, root.trimmedName, root.selectedIcon,
                   Qt.color(root.selectedColor).toString(), root.maturityLevel)
    }

    Keys.onEscapePressed: root.cancelled()
}
