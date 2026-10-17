import QtQuick
import Marquee 3.0

// The pop-up menu behind the player HUD's Subtitles and Audio buttons
// (Marquee/Features/Player/Views/PlayerControlsOverlay.swift:426-485). The
// released app uses a macOS pop-up Menu: one row per choice with a checkmark
// on the current one, and for subtitles an "Off" row and a divider ahead of
// the tracks. A remote cannot drive a native pop-up, so this one takes the
// remote itself: Up and Down move the highlight, Select chooses, and Escape
// closes the menu without leaving the player.
FocusScope {
    id: root

    // [{ label, value, selected }]: `value` is handed back by `chosen`.
    property var entries: []
    // The Subtitles menu rules its "Off" row off from the tracks below it.
    property bool dividerAfterFirst: false
    property bool leanBack: false
    property bool reduceMotion: false
    // The control this menu belongs to: the menu sits above it, aligned to
    // its right edge, and hands the remote back to it on close.
    property Item anchorItem: null
    property string accessibleName: ""

    // Set by the owner when a tap opened the menu: the pointer has no
    // control to hold, so the owner lets the HUD go when the menu closes.
    property bool openedByPointer: false
    property bool isOpen: false
    property int highlighted: 0

    readonly property real rowHeight: Theme.scaled(30, 44, root.leanBack)
    readonly property real rowFont: Theme.scaled(13, 19, root.leanBack)
    readonly property real sidePadding: Theme.scaled(12, 18, root.leanBack)
    readonly property real dividerHeight: root.dividerAfterFirst ? 9 : 0
    readonly property real contentHeight:
        root.entries.length * root.rowHeight + root.dividerHeight
    readonly property real maxHeight: parent ? parent.height * 0.6 : 400

    signal chosen(var value)
    signal closed()

    // Track names run long ("English (Dolby Digital Plus 5.1)"), so the menu
    // keeps one comfortable width and elides rather than resizing as the
    // file's tracks change.
    width: Theme.scaled(300, 440, root.leanBack)
    height: Math.min(root.contentHeight, root.maxHeight) + 2 * 6
    z: 10
    visible: opacity > 0
    opacity: root.isOpen ? 1 : 0

    Behavior on opacity {
        enabled: !root.reduceMotion
        NumberAnimation {
            duration: Theme.motionFast
            easing.type: Easing.OutCubic
        }
    }

    function open() {
        let selectedIndex = 0
        for (let index = 0; index < root.entries.length; ++index) {
            if (root.entries[index].selected) {
                selectedIndex = index
                break
            }
        }
        root.highlighted = selectedIndex
        root.place()
        root.isOpen = true
        list.positionViewAtIndex(selectedIndex, ListView.Contain)
        root.forceActiveFocus()
    }

    // Closes the menu and hands the remote back to the control it came from.
    function close() {
        if (!root.isOpen) {
            return
        }
        root.isOpen = false
        if (root.anchorItem) {
            root.anchorItem.forceActiveFocus()
        }
        root.closed()
    }

    function choose(index) {
        if (index < 0 || index >= root.entries.length) {
            return
        }
        const value = root.entries[index].value
        root.close()
        root.chosen(value)
    }

    function move(delta) {
        const next = Math.max(0, Math.min(root.entries.length - 1, root.highlighted + delta))
        root.highlighted = next
        list.positionViewAtIndex(next, ListView.Contain)
    }

    function place() {
        if (!root.anchorItem || !root.parent) {
            return
        }
        const origin = root.anchorItem.mapToItem(root.parent, 0, 0)
        const gap = Theme.scaled(8, 12, root.leanBack)
        root.x = Math.max(gap, Math.min(root.parent.width - root.width - gap,
                                        origin.x + root.anchorItem.width - root.width))
        root.y = Math.max(gap, origin.y - root.height - gap)
    }

    onHeightChanged: if (root.isOpen) root.place()
    onWidthChanged: if (root.isOpen) root.place()

    Keys.onPressed: event => {
        switch (event.key) {
        case Qt.Key_Up:
            root.move(-1)
            break
        case Qt.Key_Down:
            root.move(1)
            break
        case Qt.Key_Return:
        case Qt.Key_Enter:
        case Qt.Key_Select:
        case Qt.Key_Space:
            root.choose(root.highlighted)
            break
        case Qt.Key_Escape:
        case Qt.Key_Back:
        case Qt.Key_Backspace:
            root.close()
            break
        case Qt.Key_Left:
        case Qt.Key_Right:
            // A menu holds the remote: the player's seek keys wait outside.
            break
        default:
            return
        }
        event.accepted = true
    }

    // A tap anywhere outside the open menu closes it, the way a pop-up
    // dismisses itself. The catcher is as large as the player screen and
    // sits behind the menu.
    Item {
        parent: root.parent
        objectName: "trackMenuDismiss"
        x: 0
        y: 0
        width: parent ? parent.width : 0
        height: parent ? parent.height : 0
        z: root.z - 1
        visible: root.isOpen

        TapHandler {
            onTapped: root.close()
        }
    }

    Rectangle {
        anchors.fill: parent
        radius: Theme.radiusMD
        color: Theme.surfaceElevated
        border.width: 1
        border.color: Qt.rgba(1, 1, 1, 0.14)
    }

    ListView {
        id: list
        objectName: "trackMenuList"
        anchors.fill: parent
        anchors.margins: 6
        clip: true
        interactive: root.contentHeight > root.maxHeight
        model: root.entries
        currentIndex: root.highlighted
        boundsBehavior: Flickable.StopAtBounds

        delegate: Item {
            id: row
            required property int index
            required property var modelData
            readonly property bool current: root.highlighted === row.index

            width: list.width
            height: root.rowHeight + (root.dividerAfterFirst && row.index === 0 ? 9 : 0)

            Rectangle {
                id: rowBackground
                x: 0
                width: parent.width
                height: root.rowHeight
                radius: Theme.radiusSM
                color: row.current ? Qt.rgba(Theme.structuralFocus.r, Theme.structuralFocus.g,
                                             Theme.structuralFocus.b, 0.55)
                                   : "transparent"

                Text {
                    objectName: "trackMenuLabel"
                    anchors.left: parent.left
                    anchors.leftMargin: root.sidePadding
                    anchors.right: check.left
                    anchors.rightMargin: root.sidePadding
                    anchors.verticalCenter: parent.verticalCenter
                    text: row.modelData.label
                    color: Theme.textPrimary
                    font.pixelSize: root.rowFont
                    font.weight: Font.Medium
                    elide: Text.ElideRight
                }

                // The released row puts a checkmark after a Spacer on the
                // current choice.
                Canvas {
                    id: check
                    objectName: "trackMenuCheck"
                    anchors.right: parent.right
                    anchors.rightMargin: root.sidePadding
                    anchors.verticalCenter: parent.verticalCenter
                    width: Theme.scaled(12, 18, root.leanBack)
                    height: width
                    visible: row.modelData.selected
                    antialiasing: true
                    onVisibleChanged: requestPaint()
                    onWidthChanged: requestPaint()
                    onPaint: {
                        const context = getContext("2d")
                        context.reset()
                        context.clearRect(0, 0, width, height)
                        context.strokeStyle = "white"
                        context.lineWidth = Math.max(1.5, width * 0.14)
                        context.lineCap = "round"
                        context.lineJoin = "round"
                        context.beginPath()
                        context.moveTo(0.12 * width, 0.54 * height)
                        context.lineTo(0.40 * width, 0.80 * height)
                        context.lineTo(0.90 * width, 0.20 * height)
                        context.stroke()
                    }
                }

                HoverHandler {
                    onHoveredChanged: if (hovered) root.highlighted = row.index
                }

                TapHandler {
                    onTapped: root.choose(row.index)
                }

                Accessible.name: row.modelData.label
                Accessible.role: Accessible.MenuItem
                Accessible.checked: row.modelData.selected
            }

            // The divider under "Off".
            Rectangle {
                visible: root.dividerAfterFirst && row.index === 0
                x: root.sidePadding / 2
                y: root.rowHeight + 4
                width: parent.width - root.sidePadding
                height: 1
                color: Qt.rgba(1, 1, 1, 0.14)
            }
        }
    }

    Accessible.name: root.accessibleName
    Accessible.role: Accessible.PopupMenu
}
