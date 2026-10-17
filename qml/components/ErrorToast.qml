import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Marquee 3.0

Rectangle {
    id: root

    required property string title
    required property string message
    signal dismissed()

    implicitWidth: Math.min(720, content.implicitWidth + 48)
    implicitHeight: content.implicitHeight + 28
    radius: 10
    color: Theme.surfaceElevated
    border.width: 1
    border.color: Qt.rgba(1, 1, 1, 0.08)

    RowLayout {
        id: content
        anchors.fill: parent
        anchors.margins: 16
        spacing: 12

        Text {
            text: "⚠"
            color: Theme.accentSecondary
            font.pixelSize: 22
            Layout.alignment: Qt.AlignTop
        }

        ColumnLayout {
            spacing: 2
            Layout.fillWidth: true

            Text {
                text: root.title
                color: Theme.textPrimary
                font.pixelSize: 18
                font.weight: Font.DemiBold
                Layout.fillWidth: true
            }

            Text {
                text: root.message
                color: Theme.textSecondary
                font.pixelSize: 16
                wrapMode: Text.Wrap
                maximumLineCount: 2
                elide: Text.ElideRight
                Layout.fillWidth: true
            }
        }

        ToolButton {
            text: "×"
            font.pixelSize: 24
            onClicked: root.dismissed()
            Accessible.name: qsTr("Dismiss error")
        }
    }
}
