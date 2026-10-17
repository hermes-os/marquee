import QtQuick
import Marquee 3.0

// MarqueeTheme.swift:134-141 fills MARQUEE with the three golds of the app
// icon's play button, top-leading to bottom-trailing, at a tracking the call
// site sets. The word is laid out by a Text item with that letter spacing in
// the face the rest of the shell resolves, and the gradient is painted
// through its coverage in one pass.
Item {
    id: root

    property string text: "MARQUEE"
    property real pointSize: 34
    property real tracking: 8

    implicitWidth: wordmark.implicitWidth
    implicitHeight: wordmark.implicitHeight

    Text {
        id: wordmark
        objectName: "gradientWordmarkText"
        anchors.fill: parent
        text: root.text
        font.pixelSize: root.pointSize
        font.weight: Font.Bold
        font.letterSpacing: root.tracking
        color: "#ffffff"
        visible: false
        layer.enabled: true
        layer.smooth: true
    }

    ShaderEffect {
        objectName: "gradientWordmarkFill"
        anchors.fill: parent
        property var source: wordmark
        property color start: Theme.titleGradientStart
        property color middle: Theme.titleGradientMiddle
        property color end: Theme.titleGradientEnd
        fragmentShader: "qrc:/qt/qml/Marquee/qml/shaders/wordmarkgradient.frag.qsb"
    }
}
