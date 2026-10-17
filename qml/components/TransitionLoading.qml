import QtQuick
import QtQuick.Effects
import Marquee 3.0

// Marquee/Features/Player/Views/PlayerView.swift:57-69 draws a failed player
// as PlayerFailureOverlay over the video layer, and :62-66 covers a starting
// player with the PlayerStartupOverlay: :642-675's ZStack of the artwork
// backdrop — :648-657's displayBackdrop at :655's 1.04 scale, :656's blur
// 16, :657's black at 0.62, :659-667's top-to-bottom 0.78/0.48/0.82 vertical
// gradient — behind :618-640's PlayerPreparationOverlay card (:623's 12/18
// stack over 22/34-by-16/24 padding in the black-at-0.72 radius-8 card with
// the white-at-0.12 stroke; :624-626's small white progress spinner and
// :628-630's copy at 14/20 medium in white at 0.86). Both live outside the
// auto-hiding controls layer, and :108-124 names the copy after the
// lifecycle: "Opening video..." while the file loads, "Starting playback..."
// at the first frame, and nothing once playback has truly started. The
// oracle reaches the clock only in lifecycle .playing, so a mid-session seek
// back to 0 never re-enters the startup branch: the overlay follows the
// item's one-way start-of-session latch, not the absolute position. libmpv
// reports no lifecycle state on this stack; the first reported position past
// the startup window is what clears it. The backdrop treatments are separate
// named items — 1.04 overscan on the Image, black-at-0.62 on its own
// Rectangle, blur on the MultiEffect — so the suite judges each oracle
// treatment on its own item instead of one fused coefficient.
Item {
    id: root

    // The preparing copy PlayerView.swift:116-124 names.
    property string message: ""
    // The backdrop PlayerView.swift:64 resolves as the title's display
    // backdrop first, then its display poster. Empty draws the oracle's
    // backdrop-less composition: the page ink behind the preparation card.
    property url artwork: ""
    property bool leanBack: appController.settings.leanBackMode
    property bool reduceMotion: appController.settings.reduceMotion

    Rectangle {
        anchors.fill: parent
        color: "black"
    }

    // :655-657 applies scale, then blur, then the black overlay. Only the
    // overscanned artwork belongs in the blur source; the dim stays above
    // the effect so its edges are not blurred with the image.
    Item {
        id: treatedBackdrop
        objectName: "playerStartupTreatedBackdrop"
        anchors.fill: parent
        visible: false

        // 1.04× about the centre, as .scaleEffect scales: width/height grow
        // 4% while x/y shift half the bleed back, so the overscan spills
        // evenly on all four sides.
        Image {
            id: backdrop
            objectName: "playerStartupBackdrop"

            property real overscan: 1.04
            x: -(width - parent.width) / 2
            y: -(height - parent.height) / 2
            width: parent.width * overscan
            height: parent.height * overscan
            source: root.artwork
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            cache: true
            sourceSize.width: 1920
        }
    }

    // MultiEffect's blur is a fraction of blurMax: :656's radius 16 is
    // blur 0.5 at blurMax 32.
    MultiEffect {
        objectName: "playerStartupBackdropBlur"

        anchors.fill: parent
        source: treatedBackdrop
        visible: backdrop.status === Image.Ready
        blurEnabled: true
        blur: 0.5
        blurMax: 32
    }

    // :657's black overlay is outside the blur source, before the shade.
    Rectangle {
        objectName: "playerStartupBackdropDim"

        anchors.fill: parent
        visible: backdrop.status === Image.Ready
        color: Qt.rgba(0, 0, 0, 0.62)
    }

    // :659-667's top-to-bottom black gradient over the dimmed backdrop.
    Rectangle {
        objectName: "playerStartupBackdropShade"

        anchors.fill: parent
        visible: backdrop.status === Image.Ready
        gradient: Gradient {
            orientation: Gradient.Vertical
            GradientStop {
                objectName: "playerStartupShadeStop"
                position: 0.0; color: Qt.rgba(0, 0, 0, 0.78)
            }
            GradientStop {
                objectName: "playerStartupShadeStop"
                position: 0.5; color: Qt.rgba(0, 0, 0, 0.48)
            }
            GradientStop {
                objectName: "playerStartupShadeStop"
                position: 1.0; color: Qt.rgba(0, 0, 0, 0.82)
            }
        }
    }

    // :618-640's PlayerPreparationOverlay card, centred: :623's 12/18 stack
    // over 22/34-by-16/24 padding in the black-at-0.72 radius-8 card with
    // the white-at-0.12 1px stroke. The oracle carries no .frame(maxWidth:)
    // on this card — its VStack hugs the message — so the column below hugs
    // the message too: its width follows the wider of the spinner and the
    // message's unwrapped ideal width, clamped below by zero and above by
    // the frame so the card can neither go negative nor exceed it. The
    // 520/760 constant belongs to the failure
    // card's Text (PlayerView.swift:593) and must not appear here.
    // The column reads its ideal from the hidden same-font probe Text
    // below, which carries no width or wrap so its implicitWidth is that
    // ideal by construction: a wrap-independent, loop-free input, kept as
    // a sibling of the column so the binding never feeds back on itself.
    // (The live copy's own implicitWidth reports the same ideal in
    // practice — the suite reads both — but the probe is what the column
    // sizes against.) It paints nothing and carries no objectName, so the
    // suite keeps judging the live copy, never the probe.
    Rectangle {
        id: card
        objectName: "playerStartupCard"

        anchors.centerIn: parent
        width: cardColumn.width + 2 * Theme.scaled(22, 34, root.leanBack)
        height: cardColumn.height + 2 * Theme.scaled(16, 24, root.leanBack)
        color: Qt.rgba(0, 0, 0, 0.72)
        radius: 8
        // :635-637's white-at-0.12 1px stroke on the same radius. The stroke
        // lives in its own properties because grouped `border.width`/
        // `border.color` sub-properties are not readable back through
        // QObject::property().
        property int strokeWidth: 1
        property color strokeColor: Qt.rgba(1, 1, 1, 0.12)
        border.width: strokeWidth
        border.color: strokeColor

        Column {
            id: cardColumn
            objectName: "playerStartupColumn"

            x: Theme.scaled(22, 34, root.leanBack)
            y: Theme.scaled(16, 24, root.leanBack)
            // Zero floor: for a frame narrower than the chrome the
            // frame-minus-chrome bound goes negative; without this floor
            // the column — and the card width derived from it — would
            // bind negative with it.
            width: Math.max(0, Math.min(root.width - 2 * Theme.scaled(22, 34, root.leanBack)
                                        - 2 * Theme.scaled(32, 48, root.leanBack),
                                        Math.max(spinner.width, cardMessageMeasure.implicitWidth)))
            spacing: Theme.scaled(12, 18, root.leanBack)

            // :624-626's small white progress spinner. The released control
            // is AppKit's small spinner with no scaleEffect
            // (PlayerView.swift:624-626); v3 draws the released 16-point
            // spokes at full size, turning once a second.
            Item {
                id: spinner
                objectName: "playerStartupSpinner"

                anchors.horizontalCenter: parent.horizontalCenter
                width: 16
                height: width

                Canvas {
                    anchors.fill: parent
                    antialiasing: true

                    onPaint: {
                        const context = getContext("2d")
                        context.reset()
                        context.clearRect(0, 0, width, height)
                        const centre = width / 2
                        const outer = width * 0.46
                        const inner = width * 0.22
                        context.lineWidth = Math.max(1, width * 0.12)
                        context.lineCap = "round"
                        for (let spoke = 0; spoke < 8; ++spoke) {
                            const angle = spoke * Math.PI / 4
                            context.strokeStyle = Qt.rgba(1, 1, 1, 0.25 + 0.75 * spoke / 7)
                            context.beginPath()
                            context.moveTo(centre + inner * Math.cos(angle),
                                           centre + inner * Math.sin(angle))
                            context.lineTo(centre + outer * Math.cos(angle),
                                           centre + outer * Math.sin(angle))
                            context.stroke()
                        }
                    }

                    onWidthChanged: requestPaint()
                    onHeightChanged: requestPaint()

                    NumberAnimation on rotation {
                        objectName: "playerStartupSpinnerSpin"
                        running: root.visible && !root.reduceMotion
                        from: 0
                        to: 360
                        duration: 1000
                        loops: Animation.Infinite
                    }
                }
            }

            // :628-630's preparation copy: 14/20 medium in white at 0.86.
            Text {
                objectName: "playerStartupMessage"
                width: parent.width
                visible: root.message.length > 0
                text: root.message
                color: Qt.rgba(1, 1, 1, 0.86)
                font.pixelSize: Theme.scaled(14, 20, root.leanBack)
                font.weight: Font.Medium
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
            }
        }

        // The unwrapped ideal width the hug contract sizes against: the same
        // font and copy as the live message above, but with no width or wrap
        // of its own, so implicitWidth is that ideal by construction — a
        // wrap-independent, loop-free input for the column above.
        // A sibling of the column (outside it) so the column's width can
        // bind to it without a binding loop. Paints nothing and carries no
        // objectName, so the suite keeps judging the live copy above.
        Text {
            id: cardMessageMeasure
            visible: false
            text: root.message
            font.pixelSize: Theme.scaled(14, 20, root.leanBack)
            font.weight: Font.Medium
        }
    }
}
