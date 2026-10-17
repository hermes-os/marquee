import QtQuick
import QtQuick.Effects

// One SwiftUI `.shadow(color:radius:y:)` cast from a rounded rectangle or a
// circle, drawn the way FocusFrame.qml casts its halo: the shape's shadow with
// the shape itself cut back out, so only the blurred shadow remains. Anchor it
// to the shape that casts it; it paints outside those bounds by the blur and
// offset.
//
// On a GPU scene graph the blur is a MultiEffect, so the first frame does not
// wait on the CPU: a Canvas `shadowBlur` is a raster convolution on the GUI
// thread that costs about 370 ms for one 286 px shadow. The software scene
// graph (the offscreen test platform) has no shader effects, so it keeps the
// Canvas, which is the only way it can show a blur at all.
Item {
    id: root

    property color shadowColor: Qt.rgba(0, 0, 0, 0.3)
    property real blur: 8
    property real offsetY: 4
    // Corner radius of the casting shape; half the size makes a circle.
    property real radius: 0

    readonly property real reach: Math.ceil(root.blur * 2 + Math.abs(root.offsetY))

    // MultiEffect blurs up to `blurMax` pixels. A canvas `shadowBlur` of B
    // reaches about this many times B pixels at the same visual weight,
    // measured against the Canvas shadow this item replaced on blurs of 4 to
    // 26.
    readonly property real blurMax: 64
    readonly property real blurScale: 1.9

    // Attached to the item, so it reads Unknown until the item is in a window.
    readonly property int graphicsApi: root.GraphicsInfo.api
    readonly property bool software: root.graphicsApi === GraphicsInfo.Software
    readonly property bool hardware: root.graphicsApi !== GraphicsInfo.Software
        && root.graphicsApi !== GraphicsInfo.Unknown

    Loader {
        id: effectLoader

        anchors.fill: parent
        // Not while hidden: a glow that waits for focus would otherwise hold
        // its effect and about eight layer textures per item.
        active: root.hardware && root.visible && root.width > 0 && root.height > 0
            && root.shadowColor.a > 0
        sourceComponent: gpuShadow
    }

    Loader {
        id: canvasLoader

        anchors.fill: parent
        active: root.software
        sourceComponent: canvasShadow
    }

    Component {
        id: gpuShadow

        Item {
            objectName: "softShadowEffect"

            // The shape, in the shadow's own colour so the blur carries its
            // alpha, on a transparent field that leaves room for the blur.
            Item {
                id: shape

                anchors.fill: parent
                anchors.margins: -root.reach
                visible: false
                layer.enabled: true

                Rectangle {
                    x: root.reach
                    y: root.reach
                    width: root.width
                    height: root.height
                    radius: root.radius
                    color: root.shadowColor
                }
            }

            // The same silhouette, where the shadow's own sits before its
            // offset, to cut out of the result.
            Item {
                id: cutout

                anchors.fill: parent
                anchors.margins: -root.reach
                visible: false
                layer.enabled: true

                Rectangle {
                    x: root.reach
                    y: root.reach - root.offsetY
                    width: root.width
                    height: root.height
                    radius: root.radius
                    color: "white"
                }
            }

            MultiEffect {
                x: -root.reach
                y: -root.reach + root.offsetY
                width: shape.width
                height: shape.height
                source: shape
                autoPaddingEnabled: false
                blurEnabled: root.blur > 0
                blurMax: root.blurMax
                blur: Math.min(1, root.blur * root.blurScale / root.blurMax)
                maskEnabled: true
                maskInverted: true
                maskSource: cutout
            }
        }
    }

    Component {
        id: canvasShadow

        Canvas {
            id: canvas
            objectName: "softShadowCanvas"

            anchors.fill: parent
            anchors.margins: -root.reach
            antialiasing: true

            readonly property color painted: root.shadowColor
            readonly property real paintedBlur: root.blur
            readonly property real paintedOffset: root.offsetY
            readonly property real paintedRadius: root.radius

            onPaintedChanged: requestPaint()
            onPaintedBlurChanged: requestPaint()
            onPaintedOffsetChanged: requestPaint()
            onPaintedRadiusChanged: requestPaint()
            onWidthChanged: requestPaint()
            onHeightChanged: requestPaint()
            onAvailableChanged: requestPaint()
            Component.onCompleted: requestPaint()

            function shapePath(context, x, y, shapeWidth, shapeHeight, cornerRadius) {
                const corner = Math.max(0, Math.min(cornerRadius, Math.min(shapeWidth, shapeHeight) / 2))
                context.beginPath()
                context.moveTo(x + corner, y)
                context.lineTo(x + shapeWidth - corner, y)
                context.arcTo(x + shapeWidth, y, x + shapeWidth, y + corner, corner)
                context.lineTo(x + shapeWidth, y + shapeHeight - corner)
                context.arcTo(x + shapeWidth, y + shapeHeight, x + shapeWidth - corner, y + shapeHeight, corner)
                context.lineTo(x + corner, y + shapeHeight)
                context.arcTo(x, y + shapeHeight, x, y + shapeHeight - corner, corner)
                context.lineTo(x, y + corner)
                context.arcTo(x, y, x + corner, y, corner)
                context.closePath()
            }

            onPaint: {
                const context = getContext("2d")
                context.reset()
                context.clearRect(0, 0, width, height)
                if (root.width <= 0 || root.height <= 0 || root.shadowColor.a <= 0) {
                    return
                }
                const x = root.reach
                const y = root.reach
                context.save()
                context.shadowColor = root.shadowColor
                context.shadowBlur = root.blur
                context.shadowOffsetX = 0
                context.shadowOffsetY = root.offsetY
                context.fillStyle = "#ffffff"
                shapePath(context, x, y, root.width, root.height, root.radius)
                context.fill()

                context.shadowColor = "transparent"
                context.shadowBlur = 0
                context.shadowOffsetY = 0
                context.globalCompositeOperation = "destination-out"
                shapePath(context, x, y, root.width, root.height, root.radius)
                context.fill()
                context.restore()
            }
        }
    }
}
