import QtQuick
import QtQuick.Effects
import Marquee 3.0

// Marquee/Features/Home/Views/HeroCarousel.swift:39-539: the Home hero. The
// spotlights, the slide in front, and the timer that moves it on belong to the
// C++ `HeroSpotlightModel` (`hero`); this file draws them and asks it to move.
// The released carousel is an infinite strip of cards laid out around a
// scroll position (:121-125, :153-178): the card at the position is in front at
// full size, its neighbours sit 0.82 of a card width away, a step smaller and
// half faded, and the two beyond them are invisible but already mounted so
// their artwork has decoded by the time they slide in (:48-61).
Item {
    id: root
    objectName: "heroCarousel"

    required property var hero
    // True while the remote rests on the hero (HomeDetailView.swift:502).
    property bool remoteFocused: false
    property bool leanBack: appController.settings.leanBackMode
    property bool reduceMotion: appController.settings.reduceMotion

    // A tap on Watch Now: the spotlight as `HeroSpotlightModel::current`.
    signal playRequested(var spotlight)
    // The pointer touched the hero, so the remote should be on it.
    signal pointerTouched()

    readonly property int cardCount: root.hero.count
    // :69-75: the card the position is nearest to.
    readonly property int centerLogical: Math.round(root.scrollPosition)
    // :111-117 and :64-66.
    readonly property real cardWidth: root.width * (root.leanBack ? 0.76 : 0.72)
    readonly property real cardSpacing: root.cardWidth * (root.leanBack ? 0.86 : 0.82)
    readonly property real cardHeight: Theme.scaled(390, 500, root.leanBack)

    // :17-19 and :121: the position the cards are laid out around, and what a
    // drag adds to it. The model's position is where the carousel is heading;
    // this follows it with the slide animation (:219 `.animation(slideAnimation,
    // value: scrollPosition)`), or with a ten millisecond step under Reduce
    // Motion (:63-65), so the final position is the same either way.
    property real scrollPosition: root.hero.position
    property real dragOffset: 0
    // A drag moves the strip with the finger. The released view adds the drag
    // to the position (:122), which carries the cards against the finger while
    // the gesture's end then advances the other way; here it follows the
    // finger and the end settles from where the drag left it.
    readonly property real effectivePosition:
        root.scrollPosition - root.dragOffset / Math.max(1, root.cardSpacing)

    implicitHeight: Theme.scaled(420, 520, root.leanBack)

    // The slide's length, which Reduce Motion cuts to the released ten
    // milliseconds (:63-65) without changing where it ends.
    readonly property int slideDuration: root.reduceMotion ? 10 : Theme.motionHero

    Behavior on scrollPosition {
        NumberAnimation {
            objectName: "heroSlideAnimation"
            duration: root.slideDuration
            easing.type: root.reduceMotion ? Easing.Linear : Easing.OutCubic
        }
    }

    NumberAnimation {
        id: dragSettle
        objectName: "heroDragSettle"
        target: root
        property: "dragOffset"
        to: 0
        duration: root.slideDuration
        easing.type: Easing.OutCubic
    }

    Binding {
        target: root.hero
        property: "active"
        value: root.visible
    }

    Binding {
        target: root.hero
        property: "remoteFocused"
        value: root.remoteFocused
    }

    Binding {
        target: root.hero
        property: "reduceMotion"
        value: root.reduceMotion
    }

    // The model outlives this screen (the route Loader recreates it), so its
    // timer is stopped here rather than left for a Binding to restore, which
    // a destroyed one does not reliably do for a C++ property.
    Component.onDestruction: root.hero.active = false

    // :123-132.
    Canvas {
        objectName: "heroGlow"
        anchors.fill: parent
        antialiasing: true

        readonly property color ink: Theme.accentPrimary
        readonly property real endRadius: Theme.scaled(400, 560, root.leanBack)
        onInkChanged: requestPaint()
        onEndRadiusChanged: requestPaint()
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()

        onPaint: {
            const context = getContext("2d")
            context.reset()
            context.clearRect(0, 0, width, height)
            const gradient = context.createRadialGradient(
                width / 2, height / 2, 40, width / 2, height / 2, endRadius)
            gradient.addColorStop(0, Qt.rgba(ink.r, ink.g, ink.b, 0.08))
            gradient.addColorStop(1, Qt.rgba(ink.r, ink.g, ink.b, 0))
            context.fillStyle = gradient
            context.fillRect(0, 0, width, height)
        }
    }

    // :133-163 mounts the five logical cards around the position. A slot keeps
    // the logical card it was given while that card stays in the window, so a
    // card that slides one place never changes delegate and its artwork is not
    // asked for twice.
    Repeater {
        id: cards
        objectName: "heroCards"

        model: 5

        delegate: Item {
            id: card

            required property int index

            readonly property int windowStart: root.centerLogical - 2
            readonly property int logical:
                card.windowStart + (((card.index - card.windowStart) % 5) + 5) % 5
            readonly property var spotlight: {
                root.hero.revision
                return root.hero.spotlightAt(card.logical)
            }
            readonly property bool known: card.spotlight.title !== undefined

            // :137-141.
            readonly property real fraction: card.logical - root.effectivePosition
            readonly property real distance: Math.abs(card.fraction)
            readonly property real slideScale: Math.max(0.82, 1.0 - card.distance * 0.12)
            readonly property real slideOpacity: Math.max(0.0, 1.0 - card.distance * 0.5)
            readonly property bool isCenter: card.distance < 0.5
            // :251: the ring and the lift show for the centre card while the
            // pointer is over it or the remote is on it.
            readonly property bool showHover: card.isCenter && (hover.hovered || root.remoteFocused)
            readonly property bool remoteOnCard: root.remoteFocused && card.isCenter

            // The backdrop sets when the text is shown (:36-40, :253-258,
            // :346-349): a card whose backdrop is still decoding shows the
            // fallback wordmark alone, and one with no backdrop at all shows
            // its content at once.
            readonly property bool revealed:
                !card.known
                || String(card.spotlight.backdropUrl).length === 0
                || backdrop.status === Image.Ready
                || backdrop.status === Image.Error

            objectName: "heroCard"
            visible: card.known && card.slideOpacity > 0
            opacity: card.slideOpacity
            z: card.isCenter ? 1 : 0
            width: root.cardWidth
            height: root.cardHeight
            x: (root.width - root.cardWidth) / 2 + card.fraction * root.cardSpacing
            y: (root.height - root.cardHeight) / 2

            // :310-312 scales the card with its distance, and :362 lifts the
            // remote's card by another 2.5%.
            scale: card.slideScale * (card.remoteOnCard ? 1.025 : 1.0)
            Behavior on scale {
                enabled: !root.reduceMotion
                NumberAnimation {
                    duration: Theme.motionFast
                    easing.type: Easing.OutCubic
                }
            }

            // :363-374: two shadows beneath the card. Resting, a soft black
            // pair; with the pointer or the remote, a deeper black pair, and
            // the accent glow for the remote alone.
            SoftShadow {
                objectName: "heroGlowShadow"
                anchors.fill: parent
                z: -2
                radius: Theme.radiusLG
                shadowColor: card.showHover
                    ? Qt.rgba(Theme.structuralFocus.r, Theme.structuralFocus.g,
                              Theme.structuralFocus.b, root.remoteFocused ? 0.36 : 0.0)
                    : Qt.rgba(0, 0, 0, 0.3)
                blur: card.showHover ? (root.remoteFocused ? 26 : 16) : 6
                offsetY: card.showHover ? 8 : 3
            }

            SoftShadow {
                objectName: "heroDepthShadow"
                anchors.fill: parent
                z: -1
                radius: Theme.radiusLG
                shadowColor: Qt.rgba(0, 0, 0, card.showHover ? 0.62 : 0.3)
                blur: card.showHover ? 18 : 6
                offsetY: card.showHover ? 10 : 3
            }

            // :349 clips the whole card to its rounded rectangle. Qt clips to
            // rectangles, so on a GPU scene graph the card is drawn into a
            // layer and masked by the rounded shape; the software scene graph
            // (the offscreen test platform) has no shader effects and keeps
            // the rectangle.
            readonly property bool gpu: card.GraphicsInfo.api !== GraphicsInfo.Software
                && card.GraphicsInfo.api !== GraphicsInfo.Unknown

            Item {
                id: content
                objectName: "heroCardContent"

                anchors.fill: parent
                clip: true
                visible: !card.gpu
                layer.enabled: card.gpu

                // :207-219, :221-236: the elevated fill with the film symbol
                // and the wordmark that show until the artwork is ready.
                Rectangle {
                    anchors.fill: parent
                    color: Theme.surfaceElevated

                    Column {
                        anchors.centerIn: parent
                        spacing: Theme.scaled(8, 12, root.leanBack)

                        MarqueeSymbol {
                            objectName: "heroFallbackSymbol"
                            anchors.horizontalCenter: parent.horizontalCenter
                            symbol: "film.stack"
                            pointSize: Theme.scaled(26, 38, root.leanBack)
                            color: Qt.rgba(Theme.textTertiary.r, Theme.textTertiary.g,
                                           Theme.textTertiary.b, 0.22)
                            strokeRatio: 0.045
                        }

                        Text {
                            objectName: "heroFallbackWordmark"
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: "MARQUEE"
                            color: Qt.rgba(Theme.accentSecondary.r, Theme.accentSecondary.g,
                                           Theme.accentSecondary.b, 0.28)
                            font.pixelSize: Theme.scaled(11, 16, root.leanBack)
                            font.weight: Font.DemiBold
                            font.letterSpacing: Theme.scaled(3, 4, root.leanBack)
                        }
                    }
                }

                Item {
                    id: reveal
                    objectName: "heroReveal"

                    anchors.fill: parent
                    opacity: card.revealed ? 1 : 0
                    Behavior on opacity {
                        enabled: !root.reduceMotion
                        NumberAnimation {
                            duration: Theme.motionFast
                            easing.type: Easing.OutCubic
                        }
                    }

                    // :260-274: the poster, magnified, blurred and half
                    // faded, behind a backdrop that may not cover the card.
                    Image {
                        id: posterImage
                        objectName: "heroPoster"

                        anchors.fill: parent
                        source: card.known ? card.spotlight.posterUrl : ""
                        asynchronous: true
                        fillMode: Image.PreserveAspectCrop
                        sourceSize.width: 360
                        visible: !card.gpu && status === Image.Ready
                        scale: 1.18
                        opacity: 0.5
                    }

                    MultiEffect {
                        objectName: "heroPosterBlur"

                        anchors.fill: parent
                        source: posterImage
                        visible: card.gpu && posterImage.status === Image.Ready
                        scale: 1.18
                        opacity: 0.5
                        blurEnabled: true
                        // :267's radius 12 over a blurMax of 32.
                        blurMax: 32
                        blur: 0.375
                        saturation: 0.12
                        contrast: 0.08
                    }

                    // :276-292: the backdrop, filled to the card.
                    Image {
                        id: backdrop
                        objectName: "heroBackdrop"

                        anchors.fill: parent
                        source: card.known ? card.spotlight.backdropUrl : ""
                        asynchronous: true
                        fillMode: Image.PreserveAspectCrop
                        // ArtworkCache.swift:14's 1200 by 675 thumbnail.
                        sourceSize.width: 1200
                    }

                    // :294-302.
                    Rectangle {
                        anchors.fill: parent
                        color: Qt.rgba(0, 0, 0, 0.18)
                    }

                    Rectangle {
                        anchors.fill: parent
                        gradient: Gradient {
                            GradientStop { position: 0.0; color: Qt.rgba(0, 0, 0, 0.0) }
                            GradientStop { position: 0.5; color: Qt.rgba(0, 0, 0, 0.3) }
                            GradientStop {
                                position: 1.0
                                color: Qt.rgba(0, 0, 0, card.showHover ? 0.9 : 0.85)
                            }
                        }
                    }

                    // :304-322: the category capsule.
                    Rectangle {
                        objectName: "heroCategory"

                        x: Theme.scaled(16, 24, root.leanBack)
                        y: Theme.scaled(16, 24, root.leanBack)
                        width: badgeRow.width + 2 * Theme.scaled(10, 15, root.leanBack)
                        height: badgeRow.height + 2 * Theme.scaled(5, 8, root.leanBack)
                        radius: height / 2
                        color: Qt.rgba(0, 0, 0, 0.6)

                        Row {
                            id: badgeRow

                            anchors.centerIn: parent
                            spacing: Theme.scaled(5, 8, root.leanBack)

                            MarqueeSymbol {
                                anchors.verticalCenter: parent.verticalCenter
                                symbol: card.known ? card.spotlight.icon : ""
                                pointSize: Theme.scaled(10, 14, root.leanBack)
                                color: Theme.accentSecondary
                                strokeRatio: 0.105
                            }

                            Text {
                                objectName: "heroCategoryText"
                                anchors.verticalCenter: parent.verticalCenter
                                text: card.known ? String(card.spotlight.category).toUpperCase() : ""
                                color: Theme.accentSecondary
                                font.pixelSize: Theme.scaled(10, 14, root.leanBack)
                                font.weight: Font.Bold
                                font.letterSpacing: Theme.scaled(1.2, 1.6, root.leanBack)
                            }
                        }
                    }

                    // :324-376: title, facts and the Watch Now capsule.
                    Column {
                        id: textBlock

                        anchors.left: parent.left
                        anchors.bottom: parent.bottom
                        anchors.margins: Theme.scaled(20, 32, root.leanBack)
                        width: parent.width - 2 * Theme.scaled(20, 32, root.leanBack)
                        spacing: Theme.scaled(6, 10, root.leanBack)

                        Text {
                            objectName: "heroTitle"
                            width: parent.width
                            text: card.known ? card.spotlight.title : ""
                            color: "#ffffff"
                            font.pixelSize: Theme.scaled(28, 42, root.leanBack)
                            font.weight: Font.Bold
                            wrapMode: Text.Wrap
                            maximumLineCount: 2
                            elide: Text.ElideRight
                        }

                        Row {
                            spacing: Theme.scaled(8, 12, root.leanBack)

                            Text {
                                objectName: "heroYear"
                                visible: text.length > 0
                                text: card.known ? card.spotlight.year : ""
                                color: Theme.textSecondary
                                font.pixelSize: Theme.scaled(13, 18, root.leanBack)
                                font.weight: Font.Medium
                            }

                            Text {
                                objectName: "heroRuntime"
                                visible: text.length > 0
                                text: card.known ? card.spotlight.runtime : ""
                                color: Theme.textSecondary
                                font.pixelSize: Theme.scaled(13, 18, root.leanBack)
                                font.weight: Font.Medium
                            }

                            Text {
                                objectName: "heroFormat"
                                visible: text.length > 0
                                text: card.known ? card.spotlight.formatBadge : ""
                                color: Qt.rgba(Theme.accentSecondary.r, Theme.accentSecondary.g,
                                               Theme.accentSecondary.b, 0.8)
                                font.pixelSize: Theme.scaled(11, 15, root.leanBack)
                                font.weight: Font.DemiBold
                                font.family: "monospace"
                            }
                        }

                        Item {
                            width: 1
                            height: Theme.scaled(4, 8, root.leanBack) - parent.spacing
                            visible: card.isCenter
                        }

                        Rectangle {
                            id: watchNow
                            objectName: "heroWatchNow"

                            visible: card.isCenter
                            width: watchRow.width + 2 * Theme.scaled(18, 26, root.leanBack)
                            height: watchRow.height + 2 * Theme.scaled(8, 13, root.leanBack)
                            radius: height / 2
                            color: Theme.accentPrimary

                            Row {
                                id: watchRow

                                anchors.centerIn: parent
                                spacing: Theme.scaled(6, 10, root.leanBack)

                                MarqueeSymbol {
                                    anchors.verticalCenter: parent.verticalCenter
                                    symbol: "play.fill"
                                    pointSize: Theme.scaled(12, 18, root.leanBack)
                                    color: "#ffffff"
                                }

                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: qsTr("Watch Now")
                                    color: "#ffffff"
                                    font.pixelSize: Theme.scaled(13, 19, root.leanBack)
                                    font.weight: Font.DemiBold
                                }
                            }

                            TapHandler {
                                onTapped: {
                                    root.pointerTouched()
                                    root.playRequested(card.spotlight)
                                }
                            }

                            Accessible.name: qsTr("Watch %1").arg(
                                card.known ? card.spotlight.title : "")
                            Accessible.description: qsTr("Start playback")
                            Accessible.role: Accessible.Button
                        }
                    }
                }
            }

            Item {
                id: mask
                objectName: "heroCardMask"

                anchors.fill: parent
                visible: false
                layer.enabled: card.gpu

                Rectangle {
                    anchors.fill: parent
                    radius: Theme.radiusLG
                    color: "#ffffff"
                }
            }

            MultiEffect {
                objectName: "heroCardMasked"

                anchors.fill: parent
                source: content
                visible: card.gpu
                maskEnabled: true
                maskSource: mask
            }

            // :350-355: the ring, drawn inside the card's edge.
            Rectangle {
                objectName: "heroRing"

                anchors.fill: parent
                radius: Theme.radiusLG
                color: "transparent"
                border.width: card.remoteOnCard ? 3 : 1.5
                border.color: card.showHover
                    ? Qt.rgba(Theme.structuralFocus.r, Theme.structuralFocus.g,
                              Theme.structuralFocus.b, root.remoteFocused ? 0.9 : 0.4)
                    : "transparent"
            }

            HoverHandler {
                id: hover
                enabled: card.isCenter
            }

            // :147-163: a tap on a side card brings it to the front; the
            // centre card's own controls take the tap there.
            TapHandler {
                enabled: !card.isCenter
                onTapped: {
                    root.pointerTouched()
                    root.hero.step(card.logical - root.hero.position)
                }
            }
        }
    }

    // :165-192: the strip fades into the page to either side.
    Rectangle {
        objectName: "heroFadeLeading"

        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: (root.width - root.cardWidth) / 2 + 30
        z: 2

        gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop { position: 0.0; color: Qt.rgba(Theme.background.r, Theme.background.g, Theme.background.b, 0.9) }
            GradientStop { position: 1.0; color: Qt.rgba(Theme.background.r, Theme.background.g, Theme.background.b, 0) }
        }
    }

    Rectangle {
        objectName: "heroFadeTrailing"

        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: (root.width - root.cardWidth) / 2 + 30
        z: 2

        gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop { position: 0.0; color: Qt.rgba(Theme.background.r, Theme.background.g, Theme.background.b, 0) }
            GradientStop { position: 1.0; color: Qt.rgba(Theme.background.r, Theme.background.g, Theme.background.b, 0.9) }
        }
    }

    // :194-206 and :419-432: the arrows, shown only with something to move to.
    Repeater {
        model: root.cardCount > 1 ? [-1, 1] : []

        delegate: Rectangle {
            id: arrow

            required property int modelData

            objectName: arrow.modelData < 0 ? "heroArrowLeft" : "heroArrowRight"
            z: 3
            width: Theme.scaled(36, 58, root.leanBack)
            height: width
            radius: width / 2
            color: Qt.rgba(0, 0, 0, 0.45)
            anchors.verticalCenter: parent.verticalCenter
            x: arrow.modelData < 0
                ? Theme.scaled(16, 28, root.leanBack)
                : root.width - width - Theme.scaled(16, 28, root.leanBack)

            MarqueeSymbol {
                anchors.centerIn: parent
                symbol: arrow.modelData < 0 ? "chevron.left" : "chevron.right"
                pointSize: Theme.scaled(18, 28, root.leanBack)
                color: "#ffffff"
                strokeRatio: 0.105
            }

            TapHandler {
                onTapped: {
                    root.pointerTouched()
                    root.hero.step(arrow.modelData)
                }
            }

            Accessible.name: arrow.modelData < 0 ? qsTr("Previous spotlight") : qsTr("Next spotlight")
            Accessible.role: Accessible.Button
        }
    }

    // :208-239: one dot per spotlight under the cards.
    Row {
        id: dots
        objectName: "heroDots"

        visible: root.cardCount > 1
        z: 3
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: Theme.scaled(14, 24, root.leanBack)
        spacing: Theme.scaled(6, 10, root.leanBack)

        Repeater {
            model: root.cardCount

            delegate: Item {
                id: dot

                required property int index
                readonly property bool current: dot.index === root.hero.currentIndex

                objectName: "heroDot_" + dot.index
                // A larger target than the dot itself, which is six points.
                width: Theme.scaled(14, 20, root.leanBack)
                height: width

                Rectangle {
                    anchors.centerIn: parent
                    width: dot.current ? Theme.scaled(8, 13, root.leanBack)
                                       : Theme.scaled(6, 10, root.leanBack)
                    height: width
                    radius: width / 2
                    color: dot.current
                        ? Theme.accentSecondary
                        : Qt.rgba(Theme.textTertiary.r, Theme.textTertiary.g,
                                  Theme.textTertiary.b, 0.4)

                    Behavior on width {
                        enabled: !root.reduceMotion
                        NumberAnimation {
                            duration: Theme.motionNormal
                            easing.type: Easing.OutCubic
                        }
                    }
                }

                TapHandler {
                    onTapped: {
                        root.pointerTouched()
                        root.hero.moveTo(dot.index)
                    }
                }
            }
        }
    }

    // :199-221: a drag moves the strip; past 40 points, or fast enough, it
    // steps by one and otherwise settles back.
    DragHandler {
        id: drag
        objectName: "heroDrag"

        target: null
        yAxis.enabled: false
        // :200 starts at ten points.
        dragThreshold: 10

        property real lastVelocity: 0

        onTranslationChanged: {
            dragSettle.stop()
            root.dragOffset = drag.translation.x
        }
        onCentroidChanged: drag.lastVelocity = drag.centroid.velocity.x

        onActiveChanged: {
            if (drag.active) {
                root.pointerTouched()
                return
            }
            const distance = root.dragOffset
            // :205-206 compares the predicted end of the gesture with where it
            // is; a quarter second of the finger's speed stands in for that.
            const flick = drag.lastVelocity * 0.25
            dragSettle.from = root.dragOffset
            if (distance < -40 || flick < -200) {
                root.hero.step(1)
            } else if (distance > 40 || flick > 200) {
                root.hero.step(-1)
            }
            dragSettle.restart()
        }
    }
}
