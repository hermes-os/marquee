import QtQuick
import Marquee 3.0

// The notice Home keeps while part of the library cannot be read: a drive that
// is unplugged or a mount that is down. The released app has no such notice;
// it keeps listing a missing volume's titles from a snapshot. Here the titles
// of a missing folder are withheld (reaching their files can block the whole
// interface for the drive's device timeout), so the viewer is told which
// folder is missing and what to do about it, for as long as it is missing.
// It is plain text with no control: Settings is one sidebar stop away.
Rectangle {
    id: root

    // The folders as configured, in the order the scan reported them.
    property var roots: []
    property bool leanBack: false

    // How many folders are named before the rest are counted.
    readonly property int listedLimit: 3
    readonly property var listed: root.roots.slice(0, root.listedLimit)
    readonly property int more: Math.max(0, root.roots.length - root.listedLimit)

    readonly property string title: root.roots.length === 1
        ? qsTr("Library folder not available")
        : qsTr("%1 library folders not available").arg(root.roots.length)
    readonly property string hint:
        qsTr("Plug the drive in and rescan in Settings, or change the library folders in Settings.")
    // The whole notice as one string, for assistive technology and for tests.
    readonly property string text: {
        const lines = [root.title].concat(root.listed)
        if (root.more > 0) {
            lines.push(qsTr("and %1 more").arg(root.more))
        }
        lines.push(root.hint)
        return lines.join("\n")
    }

    readonly property real padding: Theme.scaled(14, 20, root.leanBack)

    implicitHeight: content.implicitHeight + 2 * root.padding
    radius: Theme.scaled(10, 14, root.leanBack)
    color: Theme.surfaceElevated
    border.width: 1
    border.color: Qt.rgba(Theme.accentSecondary.r, Theme.accentSecondary.g,
                          Theme.accentSecondary.b, 0.34)

    Accessible.role: Accessible.StaticText
    Accessible.name: root.text

    Row {
        id: content

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: root.padding
        spacing: Theme.scaled(12, 18, root.leanBack)

        MarqueeSymbol {
            id: glyph
            objectName: "libraryNoticeGlyph"

            symbol: "externaldrive"
            pointSize: Theme.scaled(20, 28, root.leanBack)
            color: Theme.accentSecondary
        }

        Column {
            width: content.width - glyph.width - content.spacing
            spacing: Theme.scaled(3, 5, root.leanBack)

            Text {
                objectName: "libraryNoticeTitle"
                width: parent.width
                text: root.title
                color: Theme.textPrimary
                font.pixelSize: Theme.scaled(14, 20, root.leanBack)
                font.weight: Font.DemiBold
                elide: Text.ElideRight
            }

            Repeater {
                model: root.listed

                Text {
                    required property string modelData

                    objectName: "libraryNoticePath"
                    width: parent.width
                    text: modelData
                    color: Theme.textSecondary
                    font.pixelSize: Theme.scaled(12, 17, root.leanBack)
                    // The end of a path says which folder, its start says which
                    // drive; both are kept.
                    elide: Text.ElideMiddle
                }
            }

            Text {
                objectName: "libraryNoticeMore"
                width: parent.width
                visible: root.more > 0
                height: visible ? implicitHeight : 0
                text: qsTr("and %1 more").arg(root.more)
                color: Theme.textSecondary
                font.pixelSize: Theme.scaled(12, 17, root.leanBack)
            }

            Text {
                objectName: "libraryNoticeHint"
                width: parent.width
                text: root.hint
                color: Theme.textTertiary
                font.pixelSize: Theme.scaled(12, 17, root.leanBack)
                wrapMode: Text.Wrap
            }
        }
    }
}
