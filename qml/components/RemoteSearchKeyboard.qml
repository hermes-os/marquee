import QtQuick
import Marquee 3.0

// Marquee/Features/Search/Views/RemoteSearchKeyboardView.swift:3-52: the
// on-screen keyboard the remote types with. Five rows from
// RemoteSearchKeyboardPolicy.swift:49-60 (digits, three letter rows, and
// Space / Delete / Clear / Done at 2.4, 1.4, 1.25, 1.25 key widths), centred
// in a 0.96 surface-layer panel with the large corner radius and a 0.18
// tertiary stroke.
Item {
    id: root

    property bool leanBack: appController.settings.leanBackMode
    // The focused key as row and column; a negative row focuses no key.
    property int focusRow: -1
    property int focusColumn: -1

    signal keyPressed(string kind, string value)

    // RemoteSearchKeyboardPolicy.swift:49-60.
    readonly property var layout: [
        rowOf("1234567890"),
        rowOf("QWERTYUIOP"),
        rowOf("ASDFGHJKL"),
        rowOf("ZXCVBNM"),
        [
            { id: "space", title: "Space", kind: "space", value: " ", width: 2.4 },
            { id: "delete", title: "Delete", kind: "delete", value: "", width: 1.4 },
            { id: "clear", title: "Clear", kind: "clear", value: "", width: 1.25 },
            { id: "done", title: "Done", kind: "done", value: "", width: 1.25 }
        ]
    ]

    function rowOf(characters) {
        const keys = []
        for (let i = 0; i < characters.length; ++i) {
            const title = characters.charAt(i)
            keys.push({ id: "char-" + title.toLowerCase(), title: title,
                        kind: "character", value: title, width: 1 })
        }
        return keys
    }

    // RemoteSearchKeyboardView.swift:33-45.
    readonly property real keyWidth: Theme.scaled(42, 62, root.leanBack)
    readonly property real keyHeight: Theme.scaled(34, 50, root.leanBack)
    readonly property real keySpacing: Theme.scaled(7, 10, root.leanBack)
    readonly property real rowSpacing: Theme.scaled(8, 12, root.leanBack)
    readonly property real horizontalPadding: Theme.scaled(18, 28, root.leanBack)
    readonly property real verticalPadding: Theme.scaled(16, 24, root.leanBack)

    // RemoteSearchKeyboardPolicy.swift:62-64: focus enters on Q.
    function initialFocus() {
        return { row: 1, column: 0 }
    }

    function keyAt(row, column) {
        if (row < 0 || row >= root.layout.length) {
            return null
        }
        const keys = root.layout[row]
        if (column < 0 || column >= keys.length) {
            return null
        }
        return keys[column]
    }

    // RemoteSearchKeyboardPolicy.swift:71-92: movement stays inside the
    // panel except on its edges, where it names the neighbour it leaves to.
    // Returns { row, column } or { exit: "field" | "results" | "sidebar" }.
    function move(row, column, direction) {
        if (row < 0 || row >= root.layout.length) {
            return root.initialFocus()
        }
        const lastColumn = root.layout[row].length - 1
        column = Math.min(Math.max(0, column), lastColumn)
        switch (direction) {
        case "left":
            if (column === 0) {
                return { exit: "sidebar" }
            }
            return { row: row, column: column - 1 }
        case "right":
            if (column >= lastColumn) {
                return { row: row, column: column }
            }
            return { row: row, column: column + 1 }
        case "up":
            if (row === 0) {
                return { exit: "field" }
            }
            return { row: row - 1,
                     column: Math.min(column, root.layout[row - 1].length - 1) }
        case "down":
            if (row >= root.layout.length - 1) {
                return { exit: "results" }
            }
            return { row: row + 1,
                     column: Math.min(column, root.layout[row + 1].length - 1) }
        }
        return { row: row, column: column }
    }

    implicitWidth: rows.implicitWidth + 2 * root.horizontalPadding
    implicitHeight: rows.implicitHeight + 2 * root.verticalPadding

    Rectangle {
        anchors.fill: parent
        radius: Theme.radiusLG
        color: Qt.rgba(Theme.surfaceLayer.r, Theme.surfaceLayer.g, Theme.surfaceLayer.b, 0.96)
        border.width: 1
        border.color: Qt.rgba(Theme.textTertiary.r, Theme.textTertiary.g,
                              Theme.textTertiary.b, 0.18)
    }

    Column {
        id: rows
        anchors.centerIn: parent
        spacing: root.rowSpacing

        Repeater {
            model: root.layout.length

            Row {
                id: keyRow
                required property int index
                readonly property var keys: root.layout[index]
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: root.keySpacing

                Repeater {
                    model: keyRow.keys.length

                    // RemoteSearchKeyboardView.swift:54-103.
                    Item {
                        id: key
                        required property int index
                        readonly property var descriptor: keyRow.keys[index]
                        readonly property bool focused:
                            root.focusRow === keyRow.index && root.focusColumn === index

                        objectName: "remoteKey-" + descriptor.id
                        width: root.keyWidth * descriptor.width
                        height: root.keyHeight

                        Rectangle {
                            anchors.fill: parent
                            radius: Theme.radiusSM
                            // :83-95: bright accent focused, elevated on hover,
                            // 0.72 elevated at rest.
                            color: key.focused
                                ? Theme.accentBright
                                : (keyHover.hovered
                                    ? Theme.surfaceElevated
                                    : Qt.rgba(Theme.surfaceElevated.r, Theme.surfaceElevated.g,
                                              Theme.surfaceElevated.b, 0.72))
                            // :96-103: a two-point white 0.82 stroke focused,
                            // one point of 0.18 tertiary otherwise.
                            border.width: key.focused ? 2 : 1
                            border.color: key.focused
                                ? Qt.rgba(1, 1, 1, 0.82)
                                : Qt.rgba(Theme.textTertiary.r, Theme.textTertiary.g,
                                          Theme.textTertiary.b, 0.18)
                        }

                        Text {
                            anchors.fill: parent
                            anchors.margins: 2
                            text: key.descriptor.title
                            // :63-68: 14/20 points, bold when focused, black ink
                            // on the accent.
                            font.pixelSize: Theme.scaled(14, 20, root.leanBack)
                            font.weight: key.focused ? Font.Bold : Font.DemiBold
                            color: key.focused ? "black" : Theme.textPrimary
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                            fontSizeMode: Text.HorizontalFit
                            minimumPixelSize: Theme.scaled(14, 20, root.leanBack) * 0.78
                            elide: Text.ElideNone
                        }

                        HoverHandler {
                            id: keyHover
                        }

                        TapHandler {
                            onTapped: root.keyPressed(key.descriptor.kind, key.descriptor.value)
                        }

                        Accessible.role: Accessible.Button
                        Accessible.name: key.descriptor.title
                    }
                }
            }
        }
    }
}
