import QtQuick
import Marquee 3.0

Item {
    id: root

    required property string title
    required property int year
    required property url posterUrl
    required property string metadata
    // Marquee/SharedViews/MovieCard.swift:13-18 hands the fallback artwork the
    // title's format badge; episodes, which hand it their episode label, are
    // a surface v3 does not have yet.
    required property string formatBadge
    // Marquee/SharedViews/MovieCard.swift:113-114, :265-270: a second
    // metadata line in the caller's colour, which search fills with the
    // match detail. Empty everywhere else, and the reserved label block
    // (:68-88) already holds its line.
    property string highlightMetadata: ""
    property color highlightColor: Theme.accentSecondary
    // UniversalPosterCard.swift:112: the fallback artwork's symbol.
    property string fallbackSymbol: "film.fill"
    property bool selected: false
    property bool reduceMotion: appController.settings.reduceMotion
    property bool leanBack: appController.settings.leanBackMode
    // Marquee/SharedViews/MovieCard.swift:109, :142: a caller may size the
    // card; a row or grid of fixed cards leaves it at the released width.
    property real artworkWidth: Theme.posterCardWidth(root.leanBack)
    readonly property real haloPadding:
        Theme.posterFocusHaloPadding(root.leanBack)

    signal activated()

    implicitWidth: root.artworkWidth
    implicitHeight: Theme.posterFrameTopPadding(root.leanBack)
        + root.artworkWidth / Theme.posterAspect
        + Theme.scaled(6, 10, root.leanBack)
        + Theme.posterLabelHeight(root.leanBack)
        + 2 * root.haloPadding
    // Marquee/Theme/ViewModifiers/CardHoverModifier.swift:71 raises focused
    // cards above their peers so the outside halo remains visible when
    // delegates share a row.
    z: root.selected ? 1 : 0

    Item {
        id: card
        objectName: "posterFrame"

        x: 0
        y: root.haloPadding + Theme.posterFrameTopPadding(root.leanBack)
        width: root.artworkWidth
        height: art.height

        // Marquee/Theme/ViewModifiers/CardHoverModifier.swift:71 raises a
        // focused poster above its peers.
        z: root.selected ? 1 : 0

        // Marquee/Theme/ViewModifiers/CardHoverModifier.swift:50 scales the
        // rendered artwork about its centre; the frame's layout bounds, and
        // the focus chrome placed on them, do not move.
        scale: root.selected ? Theme.posterFocusScale : 1.0

        // Marquee/Theme/MarqueeTheme.swift:252 settles the focus spring in
        // a quarter second.
        Behavior on scale {
            enabled: !root.reduceMotion
            NumberAnimation {
                objectName: "posterScaleSpring"
                duration: Theme.motionNormal
                easing.type: Easing.OutCubic
            }
        }

        PosterArt {
            id: art

            width: parent.width
            source: root.posterUrl
            title: root.title
            badge: root.formatBadge
            symbol: root.fallbackSymbol

            // Marquee/SharedViews/MovieCard.swift:215-222 is the one call site
            // that configures the placeholder, and it suppresses the whole of
            // it: no elevated fill and no ink, so a card reading its sidecar
            // shows the fallback artwork :209-213 stacked beneath rather than
            // an extra loading treatment over it.
            placeholderFillOpacity: 0
            placeholderIconOpacity: 0
            placeholderWordmarkOpacity: 0

            // MovieCard.swift:227-231 gives remote focus precedence over the
            // hover wash, including while the hover animation is in flight.
            Rectangle {
                objectName: "posterHoverScrim"
                anchors.fill: parent
                radius: parent.radius
                visible: !root.selected
                color: "white"
                opacity: hover.hovered ? 0.045 : 0.0

                Behavior on opacity {
                    enabled: !root.reduceMotion
                    NumberAnimation {
                        objectName: "posterHoverAnimation"
                        duration: Theme.motionNormal
                        easing.type: Easing.OutCubic
                    }
                }
            }

            // Marquee/SharedViews/MovieCard.swift:226-229 washes the focused
            // poster surface and centres the chevron badge on it.
            Rectangle {
                objectName: "posterFocusScrim"
                anchors.fill: parent
                radius: parent.radius
                visible: root.selected
                color: Qt.rgba(0, 0, 0, 0.28)
            }

            Rectangle {
                id: badge
                objectName: "posterFocusBadge"

                // Marquee/SharedViews/MovieCard.swift:233-247: a 44/64-point
                // black 0.52 disc with a 16/24-point semibold chevron nudged
                // one point right.
                readonly property real chevronSize: Theme.scaled(16, 24, root.leanBack)

                anchors.centerIn: parent
                width: Theme.scaled(44, 64, root.leanBack)
                height: width
                radius: width / 2
                visible: root.selected
                color: Qt.rgba(0, 0, 0, 0.52)

                Canvas {
                    objectName: "posterFocusChevron"
                    anchors.fill: parent
                    anchors.leftMargin: 1
                    antialiasing: true

                    onPaint: {
                        const context = getContext("2d")
                        context.clearRect(0, 0, width, height)
                        const size = badge.chevronSize
                        const halfHeight = size * 0.45
                        const halfWidth = size * 0.26
                        const centreX = width / 2
                        const centreY = height / 2
                        context.strokeStyle = Qt.rgba(1, 1, 1, 0.94)
                        context.lineWidth = size * 0.15
                        context.lineCap = "round"
                        context.lineJoin = "round"
                        context.beginPath()
                        context.moveTo(centreX - halfWidth, centreY - halfHeight)
                        context.lineTo(centreX + halfWidth, centreY)
                        context.lineTo(centreX - halfWidth, centreY + halfHeight)
                        context.stroke()
                    }

                    onWidthChanged: requestPaint()
                    onHeightChanged: requestPaint()
                }
            }
        }
    }

    // Marquee/SharedViews/MovieCard.swift:160-171 applies the focus chrome
    // after the clip, on the poster frame's layout bounds.
    FocusFrame {
        objectName: "posterFocusFrame"
        x: card.x
        y: card.y
        width: card.width
        height: card.height
        z: 1
        active: root.selected
        radius: Theme.radiusMD
        focusScale: Theme.posterFocusScale
        haloPadding: root.haloPadding
        ringWidth: Theme.posterRingLineWidth
        focusedGlowRadius: Theme.posterGlowRadius
    }

    Column {
        id: caption

        objectName: "posterCaption"

        anchors.top: card.bottom
        anchors.topMargin: Theme.scaled(6, 10, root.leanBack)
        x: 0
        width: root.artworkWidth
        height: Theme.posterLabelHeight(root.leanBack)
        spacing: Theme.posterLabelSpacing(root.leanBack)
        // The caption is laid out after the poster frame, so it reads over
        // the frame's shadow rather than under it.
        z: 2

        Text {
            objectName: "posterTitle"
            width: parent.width
            height: Theme.posterTitleLineHeight(root.leanBack) * 2
            text: root.title
            color: root.selected || hover.hovered ? Theme.textPrimary : Theme.textSecondary
            font.pixelSize: Theme.posterTitleSize(root.leanBack)
            font.weight: Font.Medium
            lineHeight: Theme.posterTitleLineHeight(root.leanBack)
            lineHeightMode: Text.FixedHeight
            maximumLineCount: 2
            wrapMode: Text.Wrap
            elide: Text.ElideRight
            horizontalAlignment: Text.AlignLeft
        }

        Text {
            objectName: "posterMetadata"
            width: parent.width
            height: Theme.posterMetadataLineHeight(root.leanBack)
            // Marquee/SharedViews/MovieCard.swift:46-53 supplies the
            // already-joined primary metadata.
            visible: root.metadata.length > 0
            text: root.metadata
            color: Theme.textTertiary
            font.pixelSize: Theme.posterMetadataSize(root.leanBack)
            lineHeight: Theme.posterMetadataLineHeight(root.leanBack)
            lineHeightMode: Text.FixedHeight
            maximumLineCount: 1
            elide: Text.ElideRight
            horizontalAlignment: Text.AlignLeft
        }

        Text {
            objectName: "posterHighlightMetadata"
            width: parent.width
            height: Theme.posterMetadataLineHeight(root.leanBack)
            // MovieCard.swift:265-270: one semibold line in the highlight
            // colour, only when the caller has one.
            visible: root.highlightMetadata.length > 0
            text: root.highlightMetadata
            color: root.highlightColor
            font.pixelSize: Theme.posterMetadataSize(root.leanBack)
            font.weight: Font.DemiBold
            lineHeight: Theme.posterMetadataLineHeight(root.leanBack)
            lineHeightMode: Text.FixedHeight
            maximumLineCount: 1
            elide: Text.ElideRight
            horizontalAlignment: Text.AlignLeft
        }
    }

    // MovieCard.swift:137-146 hovers the poster and caption as one rectangle,
    // excluding the row's reserved halo. Hover never owns keyboard selection.
    Item {
        x: card.x
        y: root.haloPadding
        width: root.artworkWidth
        height: caption.y + caption.height - y

        HoverHandler {
            id: hover
        }
    }

    TapHandler {
        onTapped: root.activated()
    }

    Accessible.name: root.title
    Accessible.role: Accessible.Button
}
