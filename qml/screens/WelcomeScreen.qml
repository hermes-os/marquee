import QtQuick
import QtQuick.Layouts
import Marquee 3.0

FocusScope {
    id: root

    required property string title
    property bool leanBack: appController.settings.leanBackMode

    Rectangle {
        anchors.fill: parent
        color: Theme.background
    }

    ColumnLayout {
        anchors.centerIn: parent
        width: Math.min(parent.width * 0.72, 920)
        spacing: Theme.scaled(16, 24, root.leanBack)

        Text {
            text: "MARQUEE"
            color: Theme.accentSecondary
            font.pixelSize: Theme.scaled(36, 52, root.leanBack)
            font.weight: Font.Bold
            font.letterSpacing: Theme.scaled(7, 11, root.leanBack)
            Layout.alignment: Qt.AlignHCenter
        }

        Text {
            text: root.title
            color: Theme.textPrimary
            font.pixelSize: Theme.scaled(30, 44, root.leanBack)
            font.weight: Font.DemiBold
            Layout.alignment: Qt.AlignHCenter
        }

        Text {
            text: qsTr("The Linux rewrite shell is active. Catalog, playback, and parity surfaces land in the following review slices.")
            color: Theme.textSecondary
            font.pixelSize: Theme.scaled(16, 22, root.leanBack)
            wrapMode: Text.Wrap
            horizontalAlignment: Text.AlignHCenter
            Layout.fillWidth: true
        }

        Rectangle {
            Layout.alignment: Qt.AlignHCenter
            Layout.topMargin: Theme.spacingLG
            implicitWidth: statusText.implicitWidth + 36
            implicitHeight: statusText.implicitHeight + 20
            radius: height / 2
            color: Qt.rgba(0.48, 0.37, 0.65, 0.24)
            border.width: 1
            border.color: Qt.rgba(0.79, 0.66, 0.30, 0.34)

            Text {
                id: statusText
                anchors.centerIn: parent
                text: qsTr("C++23 · Qt 6/QML · native Wayland")
                color: Theme.textPrimary
                font.pixelSize: Theme.scaled(13, 18, root.leanBack)
                font.weight: Font.Medium
            }
        }
    }
}
