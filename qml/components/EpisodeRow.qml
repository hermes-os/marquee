import QtQuick
import Marquee 3.0

// Marquee/SharedViews/EpisodeRow.swift: one episode of the selected season.
// A 200x112 (lean-back 290x163) thumbnail leads, then the "E4" label in the
// accent colour with the UP NEXT capsule, the title, and the runtime; the
// watched tick trails. Remote focus scales the row 1.035, tints it in the
// accent, and rings it at 2.5 (EpisodeRow.swift:27-38, :178-196).
Item {
    id: root

    required property var episode
    property bool focused: false
    property bool leanBack: appController.settings.leanBackMode
    property bool kidsMode: appController.kidsMode
    property bool reduceMotion: appController.settings.reduceMotion

    signal play()

    // EpisodeRow.swift:49-51.
    readonly property color activeAccent: root.kidsMode ? Theme.kidsAccent : Theme.accentSecondary
    // EpisodeRow.swift:120-124.
    readonly property real thumbWidth: root.leanBack ? 290 : 200
    readonly property real thumbHeight: root.leanBack ? 163 : 112
    readonly property real rowPadding: Theme.scaled(10, 16, root.leanBack)
    readonly property bool hovered: hover.hovered

    readonly property color backgroundColor: root.focused
        ? Qt.rgba(root.activeAccent.r, root.activeAccent.g, root.activeAccent.b, 0.16)
        : root.episode.isUpNext
            ? Qt.rgba(Theme.accentPrimary.r, Theme.accentPrimary.g, Theme.accentPrimary.b, 0.08)
            : root.hovered ? Qt.rgba(1, 1, 1, 0.018) : "transparent"

    readonly property real restScale: root.focused ? 1.035 : 1.0

    implicitHeight: root.thumbHeight + 2 * root.rowPadding
    z: root.focused ? 1 : 0

    // A pooled row that is reused starts at rest, with no fade of the
    // episode it showed before.
    property bool settling: false
    function settle() {
        root.settling = true
        surface.scale = root.restScale
        surface.scale = Qt.binding(() => root.restScale)
        background.color = root.backgroundColor
        background.color = Qt.binding(() => root.backgroundColor)
        root.settling = false
    }

    Item {
        id: surface
        objectName: "episodeRowSurface"
        anchors.fill: parent
        scale: root.restScale
        Behavior on scale {
            enabled: !root.reduceMotion && !root.settling
            NumberAnimation { duration: Theme.motionFast; easing.type: Easing.OutCubic }
        }

        // EpisodeRow.swift:27-38: the black lift and the accent glow.
        SoftShadow {
            anchors.fill: background
            radius: Theme.radiusMD
            shadowColor: Qt.rgba(0, 0, 0, root.focused ? 0.6 : (root.hovered ? 0.18 : 0.1))
            blur: root.focused ? 22 : (root.hovered ? 5 : 2)
            offsetY: root.focused ? 12 : (root.hovered ? 2 : 1)
        }
        SoftShadow {
            anchors.fill: background
            radius: Theme.radiusMD
            visible: root.focused
            shadowColor: Qt.rgba(root.activeAccent.r, root.activeAccent.g,
                                 root.activeAccent.b, 0.5)
            blur: 24
            offsetY: 0
        }

        // EpisodeRow.swift:178-196.
        Rectangle {
            id: background
            anchors.fill: parent
            radius: Theme.radiusMD
            color: root.backgroundColor
            border.width: root.focused ? 2.5 : 0
            border.color: root.activeAccent
            Behavior on color {
                enabled: !root.reduceMotion && !root.settling
                ColorAnimation { duration: Theme.motionFast }
            }
        }

        Row {
            anchors.fill: parent
            anchors.margins: root.rowPadding
            spacing: Theme.scaled(16, 24, root.leanBack)

            // EpisodeRow.swift:79-118.
            Item {
                id: thumb
                width: root.thumbWidth
                height: root.thumbHeight
                anchors.verticalCenter: parent.verticalCenter

                Rectangle {
                    anchors.fill: parent
                    radius: Theme.radiusSM
                    color: root.kidsMode ? Theme.kidsSurface : Theme.surfaceElevated
                }

                Image {
                    id: still
                    anchors.fill: parent
                    source: root.episode.thumbUrl
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    cache: true
                    visible: status === Image.Ready
                    sourceSize.width: 580
                }

                // EpisodeRow.swift:87-90: `play.rectangle`, ultralight, at
                // 22/32 in the tertiary colour at 0.3.
                Canvas {
                    anchors.centerIn: parent
                    visible: !still.visible
                    width: Theme.scaled(22, 32, root.leanBack)
                    height: width * 0.72
                    onPaint: {
                        const context = getContext("2d")
                        context.reset()
                        context.clearRect(0, 0, width, height)
                        const line = Math.max(1, width * 0.05)
                        const tint = Qt.rgba(Theme.textTertiary.r, Theme.textTertiary.g,
                                             Theme.textTertiary.b, 0.3)
                        context.strokeStyle = tint
                        context.lineWidth = line
                        context.beginPath()
                        context.roundedRect(line / 2, line / 2, width - line, height - line,
                                            width * 0.1, width * 0.1)
                        context.stroke()
                        context.fillStyle = tint
                        context.beginPath()
                        context.moveTo(width * 0.4, height * 0.3)
                        context.lineTo(width * 0.68, height * 0.5)
                        context.lineTo(width * 0.4, height * 0.7)
                        context.closePath()
                        context.fill()
                    }
                    onWidthChanged: requestPaint()
                }

                // EpisodeRow.swift:92-100: a black scrim with the play glyph
                // while focused; a faint lift while hovered.
                Rectangle {
                    anchors.fill: parent
                    radius: Theme.radiusSM
                    color: root.focused ? Qt.rgba(0, 0, 0, 0.3)
                                        : root.hovered ? Qt.rgba(1, 1, 1, 0.045) : "transparent"
                }
                Canvas {
                    anchors.centerIn: parent
                    visible: root.focused
                    width: Theme.scaled(20, 30, root.leanBack)
                    height: width
                    onPaint: {
                        const context = getContext("2d")
                        context.reset()
                        context.clearRect(0, 0, width, height)
                        context.fillStyle = "#ffffff"
                        context.beginPath()
                        context.moveTo(width * 0.18, 0)
                        context.lineTo(width, height / 2)
                        context.lineTo(width * 0.18, height)
                        context.closePath()
                        context.fill()
                    }
                    onWidthChanged: requestPaint()
                }

                // EpisodeRow.swift:102-116: progress along the bottom edge.
                Rectangle {
                    anchors.left: parent.left
                    anchors.bottom: parent.bottom
                    height: 3
                    width: parent.width * root.episode.progress
                    color: root.activeAccent
                    visible: root.episode.hasProgress
                }
            }

            // EpisodeRow.swift:127-158.
            Column {
                id: info
                width: parent.width - thumb.width - parent.spacing
                       - watchedTick.width - Theme.scaled(8, 12, root.leanBack)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.scaled(4, 8, root.leanBack)

                Row {
                    spacing: Theme.scaled(8, 12, root.leanBack)

                    Text {
                        objectName: "episodeRowLabel"
                        text: "E" + root.episode.episodeNumber
                        color: root.activeAccent
                        font.pixelSize: Theme.scaled(13, 18, root.leanBack)
                        font.weight: Font.Bold
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    // EpisodeRow.swift:133-143.
                    Rectangle {
                        objectName: "episodeRowUpNext"
                        visible: root.episode.isUpNext
                        width: upNextText.width + 2 * Theme.scaled(8, 12, root.leanBack)
                        height: upNextText.height + 2 * Theme.scaled(3, 5, root.leanBack)
                        radius: height / 2
                        color: Qt.rgba(Theme.accentPrimary.r, Theme.accentPrimary.g,
                                       Theme.accentPrimary.b, 0.2)
                        anchors.verticalCenter: parent.verticalCenter
                        Text {
                            id: upNextText
                            anchors.centerIn: parent
                            text: qsTr("UP NEXT")
                            color: Theme.accentPrimary
                            font.pixelSize: Theme.scaled(9, 13, root.leanBack)
                            font.weight: Font.Bold
                            font.letterSpacing: Theme.scaled(0.8, 1.1, root.leanBack)
                        }
                    }
                }

                Text {
                    objectName: "episodeRowTitle"
                    width: parent.width
                    text: root.episode.title
                    color: Theme.textPrimary
                    font.pixelSize: Theme.scaled(14, 21, root.leanBack)
                    font.weight: Font.Medium
                    elide: Text.ElideRight
                    maximumLineCount: root.leanBack ? 2 : 1
                    wrapMode: Text.Wrap
                }

                Text {
                    objectName: "episodeRowRuntime"
                    visible: root.episode.runtime.length > 0
                    text: root.episode.runtime
                    color: Theme.textSecondary
                    font.pixelSize: Theme.scaled(12, 17, root.leanBack)
                }
            }
        }

        // EpisodeRow.swift:162-175: `checkmark.circle.fill` trailing, at
        // 18/26 in the accent at 0.6.
        Item {
            id: watchedTick
            anchors.right: parent.right
            anchors.rightMargin: root.rowPadding + Theme.scaled(8, 12, root.leanBack)
            anchors.verticalCenter: parent.verticalCenter
            width: Theme.scaled(18, 26, root.leanBack)
            height: width
            visible: root.episode.watched
            Rectangle {
                anchors.fill: parent
                radius: width / 2
                color: root.activeAccent
                opacity: 0.6
            }
            Canvas {
                anchors.fill: parent
                onPaint: {
                    const context = getContext("2d")
                    context.reset()
                    context.clearRect(0, 0, width, height)
                    context.strokeStyle = Theme.background
                    context.lineWidth = Math.max(1.5, width * 0.12)
                    context.lineCap = "round"
                    context.lineJoin = "round"
                    context.beginPath()
                    context.moveTo(width * 0.28, height * 0.52)
                    context.lineTo(width * 0.44, height * 0.68)
                    context.lineTo(width * 0.72, height * 0.34)
                    context.stroke()
                }
                onWidthChanged: requestPaint()
            }
        }
    }

    HoverHandler { id: hover }

    TapHandler {
        onTapped: root.play()
    }
}
