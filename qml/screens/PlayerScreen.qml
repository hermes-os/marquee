import QtQuick
import QtQuick.Layouts
import Marquee 3.0

FocusScope {
    id: root
    objectName: "playerScreen"

    required property string title
    property string subtitle: ""
    property bool reduceMotion: appController.settings.reduceMotion
    property bool leanBack: appController.settings.leanBackMode
    property bool controlsVisible: true
    // The window's fullscreen state belongs to the shell (Main.qml), which
    // tells the viewer's toggle from the one playback made on entry.
    signal fullscreenRequested()
    // PlayerView.swift:243-257 hides the mouse cursor when the controls
    // auto-hide and shows it again on movement. "Still watching?" keeps it:
    // its buttons are for the pointer. A failed player keeps its pointer and
    // its controls too (:226-233): the failure card's Close is a pointer
    // target.
    readonly property bool pointerHidden:
        !root.controlsVisible && !root.stillWatching && !video.failed
    // Where a drag along the progress bar would land, as a fraction of the
    // film; -1 when none is under way.
    property real barDragFraction: -1
    readonly property real playedFraction:
        video.duration > 0 ? Math.min(1, root.shownPosition / video.duration) : 0

    // PlayerView.swift:62 covers a starting player with its startup overlay,
    // and :108-124 names the copy after the lifecycle: "Opening video..."
    // while the file loads, "Starting playback..." at the first frame, and
    // nothing once playback has truly started or when the load cannot start
    // at all. The overlay itself is terminal-state aware: :108-112's guard
    // returns nil for .failed and .stopped, and :121's switch returns nil
    // for .idle, .paused, .seeking, .ended, .failed, and .stopped — an early
    // pause, seek, end, or stop leaves no startup copy on the released app.
    // This stack reports no lifecycle state, only the item's one-way
    // start-of-session latch, its pause flag, and its end signal, so the
    // terminal contract is modelled explicitly below: the cover follows the
    // latch, never the absolute position (a mid-session seek back to 0
    // never re-enters the startup branch), and it yields the moment any
    // terminal state is known — failed, paused-before-start, seeking,
    // ended, or stopped — even though the position threshold has not
    // cleared the latch yet. The oracle reaches the clock only in
    // lifecycle .playing, so a mid-session seek back to 0 never re-enters
    // the startup branch; libmpv reports no lifecycle state on this stack
    // and the first reported position past the startup window is what
    // clears the latch for the established case.
    readonly property string startupMessage: !video.startupPending ? ""
        : root.startupTerminal ? "" : video.position > 0 ? "Starting playback..." : "Opening video..."
    // The transition cover holds while the session is still starting and has
    // neither started nor failed. The latch clears once, the first time a
    // position past the startup window proves playback established, and no
    // backward seek within the session sets it again — including while
    // paused, when no further position reports arrive to move anything.
    // Terminal states yield the cover even while the latch is still set:
    // the item reports pause, end, and failure as they arrive, and the
    // screen tracks seek/stop beside them, so an early pause, an
    // in-flight seek, a reached end, or a stop never leaves "Opening
    // video..." or "Starting playback..." up over settled video. The
    // pause yield is startup-only: once the latch clears, an established
    // pause keeps whatever the latch already decided. Seek, end, and stop
    // are plain writable screen state (libmpv reports no lifecycle state
    // on this stack), so the suite drives them through the screen's own
    // properties; pause and failure arrive through the item's own slots.
    property bool startupSeeking: false
    property bool startupEnded: false
    property bool startupStopped: false
    readonly property bool startupTerminal:
        video.failed || root.startupEnded || root.startupStopped
        || root.startupSeeking || (video.paused && video.startupPending)
    readonly property bool showingStartupOverlay:
        video.startupPending && !root.startupTerminal
    readonly property bool showingFailureOverlay: video.failed

    // The remote sits on a HUD control or inside a track menu, a hold of Left
    // or Right is scrubbing, or the pointer is pressed on the progress bar
    // (held still or dragging): the HUD stays up for as long as any of them
    // holds it.
    readonly property bool hasSubtitleMenu: video.subtitleTracks.length > 0
    readonly property bool hasAudioMenu: video.audioTracks.length > 1
    readonly property bool menuOpen: subtitleMenu.isOpen || audioMenu.isOpen || speedMenu.isOpen
    readonly property bool hudHeld: closeControl.activeFocus || restartControl.activeFocus
        || skipBackControl.activeFocus || playPauseControl.activeFocus
        || skipForwardControl.activeFocus || nextEpisodeControl.activeFocus
        || subtitleButton.activeFocus
        || audioButton.activeFocus || speedButton.activeFocus || muteControl.activeFocus
        || volumeControl.activeFocus || fullscreenControl.activeFocus
        || root.menuOpen || scrubber.scrubbing
        || progressTap.pressed || root.barDragFraction >= 0
    // While a hold scrubs, the clock and the bar show where letting go would
    // land rather than the frozen picture's position.
    readonly property real shownPosition:
        scrubber.scrubbing ? scrubber.target : video.position

    // The next-episode card: it knows when the clock has reached the lead
    // time before the end and whether the viewer hid it for this episode. It
    // is only allowed for an episode that has a next one, with Auto-play Next
    // Episode on.
    NextEpisodeCard {
        id: nextCard
        objectName: "nextEpisodeCardState"
        position: video.position
        duration: video.duration
        speed: video.speed
        allowed: appController.hasNextEpisode && appController.settings.autoPlayNextEpisode
        onShownChanged: {
            if (nextCard.shown) {
                // Play Now takes the remote, unless a track menu holds it.
                if (!root.menuOpen && !root.stillWatching) {
                    playNowButton.forceActiveFocus()
                }
            } else if (root.cardHeld) {
                root.releaseHud()
            }
        }
    }
    readonly property bool cardHeld: playNowButton.activeFocus || hideCardButton.activeFocus
    // "Still watching?" took the place of the next episode at the end of the
    // file; it stays until the viewer chooses.
    property bool stillWatching: false

    focus: true

    Rectangle {
        anchors.fill: parent
        color: "black"
    }

    MpvVideoItem {
        id: video
        objectName: "videoSurface"
        anchors.fill: parent

        // The session decides where the file opens, so the start position is
        // in place before the source it applies to.
        startPosition: appController.player.startPosition
        source: appController.player.currentFileUrl
        // SettingsDetailView.swift:366-369's Hardware Decoding row persists
        // in SettingsStore; the item honors it as the libmpv hwdec option.
        hardwareDecodingEnabled: appController.settings.hardwareDecodingEnabled
        // SettingsDetailView.swift:387-405 and AVPlayerService.swift:371-392:
        // the saved languages choose the tracks a file opens with, and the
        // saved size (SubtitleOverlayView.swift:49-58) scales the subtitles.
        // The file loads only once the scene graph has handed the item a
        // render context, which is after these bindings are in place.
        defaultAudioLanguage: appController.settings.defaultAudioLanguage
        defaultSubtitleLanguage: appController.settings.defaultSubtitleLanguage
        subtitleScale: appController.settings.subtitleScale
        subtitleLeanBack: root.leanBack

        // What playback is doing is reported as it changes; the session owns
        // when any of it becomes a stored resume point. libmpv reports the
        // length on its own schedule, often after the first positions, so it
        // is reported when it arrives rather than with the next position.
        // A new source opens a new session, so the startup-only terminal
        // flags reset with it: an auto-play-next-episode handoff reuses
        // this item while the route stays on Player, and the next session
        // must start covered rather than inherit the last session's end.
        // A position report ends the seeking state the same way the
        // oracle's transient .seeking ends: the seek settled, so the copy
        // is again decided by the latch and the clock.
        onPositionChanged: {
            root.startupSeeking = false
            root.reportPlayback()
        }
        onSourceChanged: {
            // The previous file's tracks go with it, and so do the menus
            // listing them; a hold that was scrubbing it has nothing left to
            // scrub.
            scrubber.cancel()
            root.closeTrackMenus()
            root.releaseHud()
            root.startupSeeking = false
            root.startupEnded = false
            root.startupStopped = false
            // A new episode may show its card again, and a pending question
            // belonged to the episode that ended.
            nextCard.reset()
            root.stillWatching = false
        }
        onDurationChanged: root.reportPlayback()
        onPausedChanged: root.reportPlayback()
        onStartupPendingChanged: {
            if (!video.startupPending) {
                root.handoffPending = false
            }
        }
    }

    // PlayerView.swift:57-69 draws a failed player as PlayerFailureOverlay
    // over the video layer (:573-616), and :62-66 covers a starting player
    // with the PlayerStartupOverlay. Both live outside the auto-hiding
    // layer: PlayerView.swift:45-67 composes them before
    // controlsLayer in the ZStack, so while either is up the state surface
    // is what owns the frame. The state layer therefore
    // keeps z: 0 with the controls scrim above it at z: 1: the state
    // overlay covers the HUD while it is up, and the controls scrim stacks
    // above the state surface — the macOS overlay owns the frame while it
    // is up, never the reverse. The startup overlay owns the frame while the file
    // loads: :642-675's artwork backdrop behind :618-640's preparation card,
    // with :108-124's copy ("Opening video..." while the file loads,
    // "Starting playback..." at the first frame). It is the source-backed
    // player-startup preparation surface, not the route-transition cover:
    // TransitionLoadingView.swift:5-63 with its 160 ring and 88 logo is
    // ContentView.swift:46-50's shell-level route-transition cover, which no
    // route on this stack drives (route swaps are synchronous), so it is not
    // hosted here. Both leave the way the scrim does: opacity driven by
    // state with `visible` following it, settling over Theme.motionPage.
    // PlayerView.swift:57 gates that failure on the lifecycle state, so the
    // card reads the item's own failed channel here; the message is only the
    // card's copy (:59), with the item's fallback applying underneath.
    // The state layer intentionally keeps its z below the controls scrim
    // (the ZStack order in PlayerView.swift:45-67): the full-screen state
    // surface covers the video and HUD chrome beneath it while it is up,
    // and the controls scrim stacks above the state surface — the macOS
    // overlay owns the frame while it is up, never the reverse.
    Item {
        id: stateLayer
        objectName: "playerStateLayer"
        anchors.fill: parent
        z: 0

        TransitionLoading {
            id: startupOverlay
            objectName: "playerStartupOverlay"

            anchors.fill: parent
            message: root.startupMessage
            // PlayerView.swift:64 resolves the backdrop as the playing
            // title's display backdrop first, then its display poster.
            // A loose file has no catalog row, so the oracle's backdrop-less
            // composition draws there instead.
            artwork: appController.playerArtworkUrl
            visible: opacity > 0
            opacity: root.showingStartupOverlay ? 1 : 0

            Behavior on opacity {
                enabled: !root.reduceMotion
                NumberAnimation {
                    objectName: "playerStartupOverlayFade"
                    duration: Theme.motionPage
                    easing.type: Easing.OutCubic
                }
            }
        }

        // :573-616: the yellow warning glyph at 34/50 semibold, the
        // "Playback unavailable" title at 22/32 semibold in white, and the
        // service's message at 14/20 in white at 0.82, clamped to four
        // centred lines, over the black the video leaves. Card chrome is the
        // black-at-0.72 rounded-8 fill (:609) with the white-at-0.12 1px
        // stroke (:610-613), padded 28/42 inside and 32/48 outside (:608,
        // :614). The glyph is drawn with existing Canvas primitives because
        // SF Symbols are not available on this platform.
        // The card is placed, not anchored: anchors.centerIn inside a
        // visible-bound subtree never re-evaluates once the subtree shows,
        // so a centred card would keep the zero size it was born with.
        Item {
            objectName: "playerFailureCard"
            anchors.fill: parent
            visible: opacity > 0
            opacity: root.showingFailureOverlay ? 1 : 0

            Behavior on opacity {
                enabled: !root.reduceMotion
                NumberAnimation {
                    objectName: "playerFailureCardFade"
                    duration: Theme.motionPage
                    easing.type: Easing.OutCubic
                }
            }

            // :609's black-at-0.72 card fill, rounded 8. A named item so the
            // suite judges the card chrome contract on the item itself.
            // The stroke lives in its own properties because grouped
            // `border.width`/`border.color` sub-properties are not readable
            // back through QObject::property().
            Rectangle {
                id: failureCardChrome
                objectName: "playerFailureCardBackground"
                x: failureCardColumn.x - Theme.scaled(28, 42, root.leanBack)
                y: failureCardColumn.y - Theme.scaled(28, 42, root.leanBack)
                width: failureCardColumn.width + 2 * Theme.scaled(28, 42, root.leanBack)
                height: failureCardColumn.height + 2 * Theme.scaled(28, 42, root.leanBack)
                color: Qt.rgba(0, 0, 0, 0.72)
                radius: 8
                // :610-613's white-at-0.12 1px stroke on the same radius.
                property int strokeWidth: 1
                property color strokeColor: Qt.rgba(1, 1, 1, 0.12)
                border.width: strokeWidth
                border.color: strokeColor
            }

            Column {
                id: failureCardColumn
                objectName: "playerFailureColumn"
                x: (parent.width - width) / 2
                y: (parent.height - height) / 2
                width: Math.min(parent.width - 2 * Theme.scaled(32, 48, root.leanBack)
                                - 2 * Theme.scaled(28, 42, root.leanBack),
                                Theme.scaled(520, 760, root.leanBack))
                spacing: Theme.scaled(16, 24, root.leanBack)

                // :581-583's exclamationmark.triangle.fill at 34/50
                // semibold in yellow: a filled triangle with a rounded
                // exclamation bar and dot.
                Canvas {
                    objectName: "playerFailureGlyph"
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: Theme.scaled(34, 50, root.leanBack) * 1.1
                    height: Theme.scaled(34, 50, root.leanBack)
                    antialiasing: true
                    property color glyphColor: "yellow"
                    onPaint: {
                        const context = getContext("2d")
                        context.reset()
                        context.clearRect(0, 0, width, height)
                        context.fillStyle = glyphColor
                        context.strokeStyle = glyphColor
                        const r = Math.min(width, height) * 0.12
                        context.beginPath()
                        context.moveTo(width / 2, r * 0.4)
                        context.lineTo(width - r * 0.4, height - r * 0.4)
                        context.lineTo(r * 0.4, height - r * 0.4)
                        context.closePath()
                        context.fill()
                        const ink = Qt.rgba(0, 0, 0, 0.72)
                        context.fillStyle = ink
                        context.lineCap = "round"
                        const barWidth = Math.max(2, width * 0.085)
                        context.lineWidth = barWidth
                        context.beginPath()
                        context.moveTo(width / 2, height * 0.32)
                        context.lineTo(width / 2, height * 0.62)
                        context.stroke()
                        context.beginPath()
                        context.arc(width / 2, height * 0.75, barWidth * 0.62, 0, 2 * Math.PI)
                        context.fill()
                    }
                    onWidthChanged: requestPaint()
                    onHeightChanged: requestPaint()
                }

                Text {
                    objectName: "playerFailureTitle"
                    width: parent.width
                    text: qsTr("Playback unavailable")
                    color: "white"
                    font.pixelSize: Theme.scaled(22, 32, root.leanBack)
                    font.weight: Font.DemiBold
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.Wrap
                }

                Text {
                    objectName: "playerFailureMessage"
                    width: parent.width
                    text: video.errorMessage
                    color: Qt.rgba(1, 1, 1, 0.82)
                    font.pixelSize: Theme.scaled(14, 20, root.leanBack)
                    wrapMode: Text.Wrap
                    maximumLineCount: 4
                    elide: Text.ElideRight
                    horizontalAlignment: Text.AlignHCenter
                }

                // :596-606's Close control at 120/180 by 34/52, white fill
                // in a radius-6 rectangle with 14/20 semibold black copy,
                // leaving the player the way Back and Escape already do.
                // The released Close is a plain Button outside the HUD
                // focus model — PlayerHUDControl
                // (PlayerControlsOverlay.swift:5-13) has no failure-close
                // member and PlayerHUDFocusPolicy.initialState is .canvas
                // (:84-87) — so the card takes no focus when it appears
                // and answers the pointer only. Select stays on the canvas
                // (PlayerView.swift:305-308 routes .select to
                // activateHUDControl, :414-415 answers .canvas with
                // togglePause); only Escape (:337-339) or the mouse closes.
                Rectangle {
                    id: failureClose
                    objectName: "playerFailureClose"
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: Theme.scaled(120, 180, root.leanBack)
                    height: Theme.scaled(34, 52, root.leanBack)
                    radius: 6
                    color: "white"

                    Text {
                        objectName: "playerFailureCloseLabel"
                        anchors.centerIn: parent
                        text: qsTr("Close")
                        color: "black"
                        font.pixelSize: Theme.scaled(14, 20, root.leanBack)
                        font.weight: Font.DemiBold
                    }

                    TapHandler { onTapped: appController.navigation.goBack() }
                    Accessible.name: qsTr("Close")
                    Accessible.role: Accessible.Button
                }
            }
        }
    }

    // PlayerView.swift:170-196: the top bar carries the close control and,
    // under it, the title block. It shares the bottom controls' auto-hide.
    Item {
        id: topBar
        objectName: "playerTopBar"
        z: 1

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        implicitHeight: topColumn.implicitHeight + Theme.scaled(16, 28, root.leanBack)
        height: implicitHeight
        opacity: root.controlsVisible ? 1.0 : 0.0
        visible: opacity > 0

        Behavior on opacity {
            enabled: !root.reduceMotion
            NumberAnimation {
                duration: Theme.motionNormal
                easing.type: Easing.OutCubic
            }
        }

        Rectangle {
            anchors.fill: parent
            gradient: Gradient {
                GradientStop { position: 0.0; color: Qt.rgba(0, 0, 0, 0.72) }
                GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0) }
            }
        }

        ColumnLayout {
            id: topColumn
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            // :189-190: 20 (36 in lean-back) at the sides, 16 (28) above.
            anchors.leftMargin: Theme.scaled(20, 36, root.leanBack)
            anchors.rightMargin: Theme.scaled(20, 36, root.leanBack)
            anchors.topMargin: Theme.scaled(16, 28, root.leanBack)
            spacing: Theme.scaled(10, 16, root.leanBack)

            // :173-188: a chevron in a black-at-0.5 circle that closes the
            // player at once; Back is the two-step control, this is not.
            PlayerHudButton {
                id: closeControl
                objectName: "closeControl"
                implicitWidth: Theme.scaled(36, 58, root.leanBack)
                cornerRatio: 0.5
                symbol: "chevron.left"
                glyphSize: Theme.scaled(16, 24, root.leanBack)
                leanBack: root.leanBack
                reduceMotion: root.reduceMotion
                accessibleName: qsTr("Close")
                onActivated: root.close()
            }

            Text {
                objectName: "playerTitle"
                text: root.title
                color: Theme.textPrimary
                font.pixelSize: Theme.scaled(18, 27, root.leanBack)
                font.weight: Font.DemiBold
                elide: Text.ElideRight
                Layout.fillWidth: true
            }

            // :207-213: the episode line beneath the show.
            Text {
                objectName: "playerSubtitle"
                visible: root.subtitle.length > 0
                text: root.subtitle
                color: Qt.rgba(1, 1, 1, 0.78)
                font.pixelSize: Theme.scaled(13, 19, root.leanBack)
                font.weight: Font.Medium
                elide: Text.ElideRight
                Layout.fillWidth: true
            }
        }
    }

    Rectangle {
        id: scrim
        objectName: "playerScrim"
        z: 1

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        implicitHeight: controls.implicitHeight + Theme.spacingXXL
            + Theme.scaled(Theme.spacingMD, 28, root.leanBack)
        // PlayerControlsOverlay.swift:567-575: clear at the top of the
        // controls, black at 0.8 at the bottom.
        gradient: Gradient {
            GradientStop { position: 0.0; color: Qt.rgba(0, 0, 0, 0) }
            GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.8) }
        }
        opacity: root.controlsVisible ? 1.0 : 0.0
        visible: opacity > 0

        Behavior on opacity {
            enabled: !root.reduceMotion
            NumberAnimation {
                duration: Theme.motionNormal
                easing.type: Easing.OutCubic
            }
        }

        // :250-254: 24 (40 in lean-back) at the sides and 16 (28) below; the
        // fade above the seek bar is the gradient's own room.
        ColumnLayout {
            id: controls
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.leftMargin: Theme.scaled(Theme.spacingLG, 40, root.leanBack)
            anchors.rightMargin: Theme.scaled(Theme.spacingLG, 40, root.leanBack)
            anchors.bottomMargin: Theme.scaled(Theme.spacingMD, 28, root.leanBack)
            spacing: Theme.spacingMD

            // PlayerControlsOverlay.swift:273-302: the bar answers a tap or a
            // drag by seeking to that fraction of the film. A drag commits
            // where it is let go, so the picture is not asked to follow
            // every pixel.
            Item {
                id: progressHit
                objectName: "playerProgress"
                Layout.fillWidth: true
                implicitHeight: Theme.scaled(24, 38, root.leanBack)

                // :243-262: a capsule 4 (7 in lean-back) high, the tertiary
                // text colour at 0.3 under the secondary accent's fill.
                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width
                    height: Theme.scaled(4, 7, root.leanBack)
                    radius: height / 2
                    color: Qt.rgba(Theme.textTertiary.r, Theme.textTertiary.g,
                                   Theme.textTertiary.b, 0.3)

                    Rectangle {
                        objectName: "playerProgressFill"
                        width: parent.width * (root.barDragFraction >= 0
                                               ? root.barDragFraction : root.playedFraction)
                        height: parent.height
                        radius: parent.radius
                        color: Theme.accentSecondary
                    }
                }

                TapHandler {
                    id: progressTap
                    onTapped: eventPoint => root.seekToFraction(
                        eventPoint.position.x / progressHit.width)
                    // Whatever ends the press, the wait for hiding starts
                    // again from there; a cancelled press seeks nothing.
                    onPressedChanged: {
                        if (!pressed) {
                            root.revealHud()
                        }
                    }
                }

                DragHandler {
                    target: null
                    onCentroidChanged: {
                        if (active) {
                            root.barDragFraction = Math.max(
                                0, Math.min(1, centroid.position.x / progressHit.width))
                        }
                    }
                    onActiveChanged: {
                        if (!active && root.barDragFraction >= 0) {
                            const fraction = root.barDragFraction
                            root.barDragFraction = -1
                            root.seekToFraction(fraction)
                        }
                        if (!active) {
                            root.revealHud()
                        }
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.spacingMD

                Text {
                    objectName: "playbackStatus"
                    text: video.paused ? qsTr("Paused") : qsTr("Playing")
                    color: Theme.accentBright
                    font.pixelSize: Theme.scaled(14, 18, root.leanBack)
                    font.weight: Font.Medium
                }

                Item { Layout.fillWidth: true }

                Text {
                    text: qsTr("Space pause · ←/→ −10s/+30s, hold to scrub · ↓ controls · Esc hide, then leave")
                    color: Theme.textTertiary
                    font.pixelSize: Theme.scaled(13, 16, root.leanBack)
                }
            }

            // PlayerControlsOverlay.swift:310-319: the transport group, the
            // clock, then (after a Spacer) the track and speed controls, the
            // volume and the fullscreen button. The remote walks them left to
            // right, Restart first: Down from the picture lands there, so
            // Enter in front of a running film cannot send it back to the
            // beginning by accident.
            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.scaled(Theme.spacingMD, 24, root.leanBack)

                // :365-375: backward.end.
                PlayerHudButton {
                    id: restartControl
                    objectName: "restartControl"
                    symbol: "backward.end"
                    leanBack: root.leanBack
                    reduceMotion: root.reduceMotion
                    accessibleName: qsTr("Restart")
                    onActivated: root.restart()
                }

                // :377-387: gobackward.10, which steps back as a Left tap does.
                PlayerHudButton {
                    id: skipBackControl
                    objectName: "skipBackControl"
                    symbol: "gobackward"
                    label: "10"
                    glyphSize: Theme.scaled(26, 38, root.leanBack)
                    labelSize: Theme.scaled(8, 12, root.leanBack)
                    leanBack: root.leanBack
                    reduceMotion: root.reduceMotion
                    accessibleName: qsTr("Back 10 seconds")
                    onActivated: root.skip(-10)
                }

                // :403-411.
                PlayerHudButton {
                    id: playPauseControl
                    objectName: "playPauseControl"
                    symbol: video.paused ? "play.fill" : "pause.fill"
                    glyphSize: Theme.scaled(22, 34, root.leanBack)
                    leanBack: root.leanBack
                    reduceMotion: root.reduceMotion
                    accessibleName: video.paused ? qsTr("Play") : qsTr("Pause")
                    onActivated: root.togglePause()
                }

                // :389-399: goforward.30.
                PlayerHudButton {
                    id: skipForwardControl
                    objectName: "skipForwardControl"
                    symbol: "goforward"
                    label: "30"
                    glyphSize: Theme.scaled(26, 38, root.leanBack)
                    labelSize: Theme.scaled(8, 12, root.leanBack)
                    leanBack: root.leanBack
                    reduceMotion: root.reduceMotion
                    accessibleName: qsTr("Forward 30 seconds")
                    onActivated: root.skip(30)
                }

                // PlayerControlsOverlay.swift:96-98, :353-362: forward.end,
                // after the skip controls, only while an episode that has a
                // next one plays. An invisible item leaves the layout and the
                // remote's order alike.
                PlayerHudButton {
                    id: nextEpisodeControl
                    objectName: "nextEpisodeControl"
                    visible: appController.hasNextEpisode
                    symbol: "forward.end"
                    leanBack: root.leanBack
                    reduceMotion: root.reduceMotion
                    accessibleName: qsTr("Next episode")
                    onActivated: root.playNextEpisode()
                }

                // :415-424.
                Text {
                    objectName: "playerClock"
                    // :415-424: the slash is drawn in the tertiary colour.
                    textFormat: Text.StyledText
                    text: root.formatTime(root.shownPosition)
                        + " <font color=\"" + Theme.textTertiary + "\">/</font> "
                        + root.formatTime(video.duration)
                    color: Theme.textSecondary
                    font.pixelSize: Theme.scaled(12, 17, root.leanBack)
                    font.weight: Font.Medium
                    font.family: "monospace"
                }

                Item { Layout.fillWidth: true }

                // :339-344 offers the subtitle menu when the file lists any
                // subtitle (hasSubtitles) and the audio menu only when it
                // lists more than one audio track.
                PlayerHudButton {
                    id: subtitleButton
                    objectName: "subtitlesButton"
                    visible: root.hasSubtitleMenu
                    // :454-456: the filled bubble, in the secondary accent,
                    // while a subtitle shows.
                    symbol: video.subtitleTrackId > 0 ? "captions.bubble.fill" : "captions.bubble"
                    symbolColor: video.subtitleTrackId > 0 ? Theme.accentSecondary : Theme.textPrimary
                    leanBack: root.leanBack
                    reduceMotion: root.reduceMotion
                    accessibleName: qsTr("Subtitles")
                    onActivated: byPointer => root.openTrackMenu(subtitleMenu, byPointer)
                }

                PlayerHudButton {
                    id: audioButton
                    objectName: "audioButton"
                    visible: root.hasAudioMenu
                    symbol: "speaker.wave.2"
                    leanBack: root.leanBack
                    reduceMotion: root.reduceMotion
                    accessibleName: qsTr("Audio")
                    onActivated: byPointer => root.openTrackMenu(audioMenu, byPointer)
                }

                // :490-515: the speed reads as text, in the secondary accent
                // when it is not 1x.
                PlayerHudButton {
                    id: speedButton
                    objectName: "speedButton"
                    label: root.speedLabel(video.speed)
                    labelColor: Math.abs(video.speed - 1.0) > 1e-6
                        ? Theme.accentSecondary : Theme.textPrimary
                    leanBack: root.leanBack
                    reduceMotion: root.reduceMotion
                    accessibleName: qsTr("Playback speed")
                    onActivated: byPointer => root.openTrackMenu(speedMenu, byPointer)
                }

                // :526-556: the speaker icon mutes; the slider sets the level.
                PlayerHudButton {
                    id: muteControl
                    objectName: "muteControl"
                    symbol: root.volumeIcon
                    leanBack: root.leanBack
                    reduceMotion: root.reduceMotion
                    accessibleName: video.muted ? qsTr("Unmute") : qsTr("Mute")
                    onActivated: root.toggleMute()
                }

                PlayerVolumeSlider {
                    id: volumeControl
                    objectName: "volumeControl"
                    value: video.volume
                    muted: video.muted
                    leanBack: root.leanBack
                    reduceMotion: root.reduceMotion
                    accessibleName: qsTr("Volume")
                    onAdjusted: value => root.setVolume(value)
                }

                // :560-570.
                PlayerHudButton {
                    id: fullscreenControl
                    objectName: "fullscreenControl"
                    symbol: "arrow.up.left.and.arrow.down.right"
                    leanBack: root.leanBack
                    reduceMotion: root.reduceMotion
                    accessibleName: qsTr("Fullscreen")
                    onActivated: root.toggleFullscreen()
                }
            }
        }
    }

    // The next-episode card: the next episode's title, the wait until the
    // file ends, Play Now and Hide. It sits above the HUD's controls at the
    // right-hand edge and is its own surface, so it stays when the HUD hides.
    Rectangle {
        id: nextCardView
        objectName: "nextEpisodeCard"
        z: 5
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.rightMargin: Theme.outerPadding(root.leanBack)
        anchors.bottomMargin: (root.controlsVisible ? scrim.height : 0)
            + Theme.scaled(24, 36, root.leanBack)
        width: Theme.scaled(340, 500, root.leanBack)
        height: cardColumn.implicitHeight + 2 * Theme.scaled(18, 26, root.leanBack)
        radius: 8
        color: Qt.rgba(0, 0, 0, 0.78)
        border.width: 1
        border.color: Qt.rgba(1, 1, 1, 0.12)
        opacity: nextCard.shown && !root.stillWatching ? 1 : 0
        visible: opacity > 0
        // The fade keeps the card on screen for a moment after the next
        // episode has started; a click in that moment is for nothing.
        enabled: nextCard.shown && !root.stillWatching

        Behavior on opacity {
            enabled: !root.reduceMotion
            NumberAnimation {
                duration: Theme.motionNormal
                easing.type: Easing.OutCubic
            }
        }

        Column {
            id: cardColumn
            x: Theme.scaled(18, 26, root.leanBack)
            y: Theme.scaled(18, 26, root.leanBack)
            width: parent.width - 2 * Theme.scaled(18, 26, root.leanBack)
            spacing: Theme.scaled(8, 12, root.leanBack)

            Text {
                objectName: "nextEpisodeCardCountdown"
                width: parent.width
                text: qsTr("Next episode in %1").arg(nextCard.secondsLeft)
                color: Theme.accentSecondary
                font.pixelSize: Theme.scaled(13, 19, root.leanBack)
                font.weight: Font.Medium
            }

            Text {
                objectName: "nextEpisodeCardTitle"
                width: parent.width
                text: {
                    const next = appController.nextEpisode
                    return next.label === undefined ? "" : next.label + " \u00B7 " + next.title
                }
                color: "white"
                font.pixelSize: Theme.scaled(17, 25, root.leanBack)
                font.weight: Font.DemiBold
                elide: Text.ElideRight
                maximumLineCount: 2
                wrapMode: Text.Wrap
            }

            Row {
                spacing: Theme.scaled(12, 18, root.leanBack)

                PlayerCardButton {
                    id: playNowButton
                    objectName: "nextEpisodeCardPlayNow"
                    label: qsTr("Play Now")
                    primary: true
                    leanBack: root.leanBack
                    reduceMotion: root.reduceMotion
                    onActivated: root.playNextEpisode()
                    Keys.onRightPressed: event => { hideCardButton.forceActiveFocus(); event.accepted = true }
                    Keys.onLeftPressed: event => { event.accepted = true }
                }

                PlayerCardButton {
                    id: hideCardButton
                    objectName: "nextEpisodeCardHide"
                    label: qsTr("Hide")
                    leanBack: root.leanBack
                    reduceMotion: root.reduceMotion
                    onActivated: root.hideCard()
                    Keys.onLeftPressed: event => { playNowButton.forceActiveFocus(); event.accepted = true }
                    Keys.onRightPressed: event => { event.accepted = true }
                }
            }
        }
    }

    // "Still watching?" replaces the next episode at the end of the file once
    // three auto-played episodes and 90 minutes without input have passed.
    Rectangle {
        id: stillWatchingView
        objectName: "stillWatchingPrompt"
        z: 6
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.82)
        opacity: root.stillWatching ? 1 : 0
        visible: opacity > 0

        Behavior on opacity {
            enabled: !root.reduceMotion
            NumberAnimation {
                duration: Theme.motionPage
                easing.type: Easing.OutCubic
            }
        }

        // The scene behind is not the viewer's to poke while the question is
        // up: no press, hover or wheel reaches the HUD under it.
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.AllButtons
            hoverEnabled: true
            onWheel: wheel => wheel.accepted = true
        }

        Column {
            x: (parent.width - width) / 2
            y: (parent.height - height) / 2
            spacing: Theme.scaled(20, 30, root.leanBack)

            Text {
                objectName: "stillWatchingTitle"
                anchors.horizontalCenter: parent.horizontalCenter
                text: qsTr("Still watching?")
                color: "white"
                font.pixelSize: Theme.scaled(26, 40, root.leanBack)
                font.weight: Font.DemiBold
            }

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: {
                    const next = appController.nextEpisode
                    return next.label === undefined ? "" : next.label + " \u00B7 " + next.title
                }
                color: Qt.rgba(1, 1, 1, 0.82)
                font.pixelSize: Theme.scaled(15, 22, root.leanBack)
            }

            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: Theme.scaled(16, 24, root.leanBack)

                PlayerCardButton {
                    id: continueButton
                    objectName: "stillWatchingContinue"
                    label: qsTr("Continue")
                    primary: true
                    leanBack: root.leanBack
                    reduceMotion: root.reduceMotion
                    onActivated: root.continueWatching()
                    Keys.onRightPressed: event => { stopButton.forceActiveFocus(); event.accepted = true }
                }

                PlayerCardButton {
                    id: stopButton
                    objectName: "stillWatchingStop"
                    label: qsTr("Stop")
                    leanBack: root.leanBack
                    reduceMotion: root.reduceMotion
                    onActivated: root.close()
                    Keys.onLeftPressed: event => { continueButton.forceActiveFocus(); event.accepted = true }
                }
            }
        }
    }

    // PlayerControlsOverlay.swift:426-485: the subtitle menu lists "Off", a
    // divider, then every subtitle track; the audio menu lists the audio
    // tracks. Each marks the current choice. The menus sit above the HUD and
    // answer the remote themselves (PlayerTrackMenu.qml).
    PlayerTrackMenu {
        id: subtitleMenu
        objectName: "subtitlesMenu"
        anchorItem: subtitleButton
        leanBack: root.leanBack
        reduceMotion: root.reduceMotion
        dividerAfterFirst: true
        accessibleName: qsTr("Subtitles")
        entries: {
            const rows = [{ label: qsTr("Off"), value: 0, selected: video.subtitleTrackId === 0 }]
            for (const track of video.subtitleTracks) {
                rows.push({ label: track.label, value: track.id,
                            selected: track.id === video.subtitleTrackId })
            }
            return rows
        }
        onChosen: value => video.selectSubtitleTrack(value)
        onClosed: root.trackMenuClosed(subtitleMenu)
    }

    PlayerTrackMenu {
        id: audioMenu
        objectName: "audioMenu"
        anchorItem: audioButton
        leanBack: root.leanBack
        reduceMotion: root.reduceMotion
        accessibleName: qsTr("Audio")
        entries: {
            const rows = []
            for (const track of video.audioTracks) {
                rows.push({ label: track.label, value: track.id,
                            selected: track.id === video.audioTrackId })
            }
            return rows
        }
        onChosen: value => video.selectAudioTrack(value)
        onClosed: root.trackMenuClosed(audioMenu)
    }

    // :490-502: one row per step, a checkmark on the current speed.
    PlayerTrackMenu {
        id: speedMenu
        objectName: "speedMenu"
        anchorItem: speedButton
        leanBack: root.leanBack
        reduceMotion: root.reduceMotion
        accessibleName: qsTr("Playback speed")
        entries: {
            const rows = []
            for (const step of video.speedSteps) {
                rows.push({ label: root.speedLabel(step), value: step,
                            selected: Math.abs(step - video.speed) < 1e-6 })
            }
            return rows
        }
        onChosen: value => video.setSpeed(value)
        onClosed: root.trackMenuClosed(speedMenu)
    }

    // PlayerView.swift:243-256 hides the controls 3 seconds after they were
    // last shown.
    Timer {
        id: hideControls
        interval: 3000
        onTriggered: {
            // Hiding the scrim under a focused control, or under an open
            // track menu, would leave the remote pointed at something the
            // viewer can no longer see.
            if (!root.hudHeld && !video.failed) {
                root.controlsVisible = false
            }
        }
    }

    // Left and Right: a tap steps, a hold over half a second scrubs
    // (PlayerView.swift:453-523). The scrubber decides; the film is moved
    // here.
    SeekScrubber {
        id: scrubber
        objectName: "seekScrubber"
        position: video.position
        duration: video.duration
        paused: video.paused

        // The oracle's .seeking branch draws no startup copy (:121): a seek
        // before playback establishes ends the starting state. Only a seek
        // that was issued does: one dropped because the file has not opened
        // settles nothing, and no position report would bring the copy back.
        onSkipRequested: seconds => {
            if (video.seekRelative(seconds)) {
                root.startupSeeking = true
            }
        }
        onSeekRequested: seconds => {
            if (video.seekAbsolute(seconds)) {
                root.startupSeeking = true
            }
        }
        onPauseRequested: paused => paused ? video.pause() : video.play()
    }

    // A key-up that never arrives (the window lost focus mid-hold) must not
    // leave the film paused and the scrub running.
    Connections {
        target: root.Window.window
        function onActiveChanged() {
            if (!root.Window.active) {
                scrubber.cancel()
            }
        }
    }

    // PlayerView.swift:285-290: a moving pointer brings the controls back.
    // Qt re-sends the last hover when items appear, hide or move under a
    // still pointer, so only a change of place counts: otherwise the HUD
    // would bring itself back every time it faded.
    HoverHandler {
        id: pointerWatch
        cursorShape: root.pointerHidden ? Qt.BlankCursor : Qt.ArrowCursor
        property point lastPlace: Qt.point(-1, -1)
        onPointChanged: {
            const place = point.scenePosition
            if (Math.abs(place.x - lastPlace.x) < 2 && Math.abs(place.y - lastPlace.y) < 2) {
                return
            }
            lastPlace = place
            root.revealHud()
        }
    }

    Connections {
        target: video
        // PlayerController.swift:126-138: an episode hands off to the next
        // one when the preference allows; anything else dismisses. Either
        // way the session reached its ordinary end, so the startup cover
        // yields even if the position threshold never cleared its latch:
        // the oracle's .ended branch draws no startup copy (:121). This
        // answers only the ordinary end: the oracle applies .fail — never
        // .ended — for an error END_FILE (MPVPlayerService.swift:2636-2637),
        // and PlayerView.swift:57 keeps the failed player on screen behind
        // its failure card, so an error end must never dismiss through
        // here. The item enforces the same split at the source: eof-reached
        // reports playbackEnded only while no failure is latched.
        function onPlaybackEnded() {
            if (video.failed || root.handoffPending) {
                return
            }
            root.startupEnded = true
            const id = appController.player.mediaId
            // Three episodes in a row that nobody chose, and no input for
            // 90 minutes: ask before starting a fourth.
            if (appController.stillWatchingDue(id)) {
                root.askStillWatching()
                return
            }
            if (appController.continueAfterPlayback(id)) {
                root.markHandoff()
            } else {
                appController.finishPlayback(id)
            }
        }

        function onFailedChanged() {
            if (video.failed) {
                root.handoffPending = false
                hideControls.stop()
                root.controlsVisible = true
            } else {
                hideControls.restart()
            }
        }
    }

    Keys.onPressed: event => {
        // KeyCatcher.swift:20-21: a chord with Control, Alt or Meta is never
        // a player key.
        if (event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)) {
            return
        }
        // "Still watching?" is answered with its two controls, which take
        // their own keys; Back leaves like Stop and nothing else moves the
        // film or the HUD behind the question.
        if (root.stillWatching) {
            if (event.key === Qt.Key_Escape || event.key === Qt.Key_Back
                    || event.key === Qt.Key_Backspace) {
                root.close()
            }
            event.accepted = true
            return
        }
        switch (event.key) {
        case Qt.Key_Space:
        case Qt.Key_K:
        case Qt.Key_MediaTogglePlayPause:
        case Qt.Key_Return:
        case Qt.Key_Enter:
        case Qt.Key_Select:
            // KeyCatcher.swift:24-25 maps both Return (36) and Space (49)
            // to .select, and PlayerView.swift:305-308 answers .select
            // with activateHUDControl(focusedHUDControl) — .canvas from
            // PlayerHUDFocusPolicy.initialState (:84-87) — which :414-415
            // answers with togglePause. A focused control takes Enter
            // itself; the failure card takes no focus and answers the
            // pointer only.
            video.togglePause()
            break
        case Qt.Key_MediaPlay:
            video.play()
            break
        case Qt.Key_MediaPause:
            video.pause()
            break
        case Qt.Key_MediaStop:
            video.stop()
            // The oracle's .stopped branch draws no startup copy (:112,
            // :121): the session is over even though the item's latch never
            // cleared, so the cover yields here rather than waiting on it.
            root.startupStopped = true
            appController.navigation.goBack()
            event.accepted = true
            return
        case Qt.Key_Escape:
        case Qt.Key_Back:
        case Qt.Key_Backspace:
            // The order is: menu (it takes the key itself), then the card,
            // then the HUD, then leave.
            if (nextCard.shown) {
                root.hideCard()
                event.accepted = true
                return
            }
            // The first press hides a visible HUD; only with the HUD hidden
            // does Back leave. A child pressing Back to get the controls out
            // of the way must not lose the film. A failed player has no
            // film to protect and its HUD cannot be hidden, so it leaves.
            if (root.controlsVisible && !video.failed) {
                root.hideHud()
            } else {
                root.close()
            }
            event.accepted = true
            return
        case Qt.Key_Left:
        case Qt.Key_Right: {
            const direction = event.key === Qt.Key_Left ? -1 : 1
            // PlayerView.swift:287-293: with a HUD control focused Left and
            // Right walk the controls instead of seeking.
            if (root.hudHeld) {
                if (!event.isAutoRepeat) {
                    root.moveHud(direction)
                }
                break
            }
            // A held key repeats; the scrubber times the hold itself.
            if (!event.isAutoRepeat) {
                scrubber.press(direction)
            }
            break
        }
        case Qt.Key_Down:
            if (closeControl.activeFocus) {
                root.releaseHud()
            } else if (!root.hudHeld) {
                restartControl.focus = true
            }
            // From the HUD's controls Down has nowhere further to go.
            break
        case Qt.Key_Up:
            // The first Up of a hidden HUD only brings it back; from the
            // picture the next one reaches the close control above it.
            if (root.hudHeld) {
                if (!closeControl.activeFocus) {
                    root.releaseHud()
                }
            } else if (root.controlsVisible) {
                closeControl.forceActiveFocus()
            } else {
                root.releaseHud()
            }
            break
        // KeyCatcher.swift:32-37 and PlayerView.swift:340-359.
        case Qt.Key_S:
            video.toggleSubtitles()
            break
        case Qt.Key_F:
            root.toggleFullscreen()
            break
        case Qt.Key_M:
            root.toggleMute()
            break
        case Qt.Key_BracketLeft:
            video.stepSpeed(-1)
            break
        case Qt.Key_BracketRight:
            video.stepSpeed(1)
            break
        default:
            return
        }

        root.revealHud()
        event.accepted = true
    }

    Keys.onReleased: event => {
        if (event.isAutoRepeat) {
            event.accepted = true
            return
        }
        if (event.key === Qt.Key_Left) {
            scrubber.release(-1)
            event.accepted = true
        } else if (event.key === Qt.Key_Right) {
            scrubber.release(1)
            event.accepted = true
        }
    }

    // The HUD controls the remote can land on, left to right.
    function hudControls() {
        // Availability, not visibility: a HUD fading in is not yet visible,
        // and the remote must still reach its controls.
        const controls = [restartControl, skipBackControl, playPauseControl,
                          skipForwardControl]
        if (appController.hasNextEpisode) {
            controls.push(nextEpisodeControl)
        }
        if (root.hasSubtitleMenu) {
            controls.push(subtitleButton)
        }
        if (root.hasAudioMenu) {
            controls.push(audioButton)
        }
        controls.push(speedButton, muteControl, volumeControl, fullscreenControl)
        return controls
    }

    function moveHud(delta) {
        const controls = root.hudControls()
        const at = controls.findIndex(item => item.activeFocus)
        if (at < 0) {
            return
        }
        const next = controls[Math.max(0, Math.min(controls.length - 1, at + delta))]
        next.forceActiveFocus()
    }

    // Hands the remote back to the player surface, which reads the transport
    // keys. A focus scope keeps its focused child, so each control lets go.
    function releaseHud() {
        closeControl.focus = false
        for (const control of root.hudControls()) {
            control.focus = false
        }
        subtitleButton.focus = false
        audioButton.focus = false
        nextEpisodeControl.focus = false
        playNowButton.focus = false
        hideCardButton.focus = false
        continueButton.focus = false
        stopButton.focus = false
        root.forceActiveFocus()
    }

    // Shows the controls and starts their 3-second wait again
    // (PlayerView.swift:259-270).
    function revealHud() {
        // The HUD stays out from under the question.
        if (root.stillWatching) {
            return
        }
        root.controlsVisible = true
        hideControls.restart()
    }

    // The first Back: the controls go, the film stays.
    function hideHud() {
        hideControls.stop()
        root.closeTrackMenus()
        root.releaseHud()
        scrubber.cancel()
        root.controlsVisible = false
    }

    // The HUD control and the card's Play Now: the next episode, at the
    // position it was left at.
    //
    function playNextEpisode() {
        if (!root.startNextEpisode()) {
            root.revealHud()
        }
    }

    // The one way this screen starts the next episode. Once it has, the
    // player's media id already names the new episode, so a second press, a
    // click on the fading card or the end of the old file would read it as
    // the episode to leave and skip one: everything that asks waits until the
    // new episode has started or failed. Startup ends at 0.35 s of playback,
    // which a file that ends sooner, a stalled open or a pause pressed inside
    // that window never reaches; the wait is capped so none of them can hold
    // the screen against a request for good.
    property bool handoffPending: false

    Timer {
        id: handoffCap
        interval: 1500
        onTriggered: root.handoffPending = false
    }

    function markHandoff() {
        root.handoffPending = video.startupPending && !video.failed
        if (root.handoffPending) {
            handoffCap.restart()
        }
    }

    function startNextEpisode() {
        if (root.handoffPending) {
            return true
        }
        if (!appController.playNextEpisode(appController.player.mediaId)) {
            return false
        }
        root.markHandoff()
        return true
    }

    function hideCard() {
        const held = root.cardHeld
        nextCard.hide()
        if (held) {
            root.releaseHud()
        }
    }

    function askStillWatching() {
        hideControls.stop()
        root.controlsVisible = false
        root.closeTrackMenus()
        root.releaseHud()
        scrubber.cancel()
        root.stillWatching = true
        continueButton.forceActiveFocus()
    }

    function continueWatching() {
        root.stillWatching = false
        if (!root.startNextEpisode()) {
            appController.finishPlayback(appController.player.mediaId)
        }
    }

    function close() {
        scrubber.cancel()
        appController.navigation.goBack()
    }

    function skip(seconds) {
        scrubber.skip(seconds)
        root.revealHud()
    }

    function togglePause() {
        video.togglePause()
        root.revealHud()
    }

    function toggleMute() {
        video.toggleMute()
        root.revealHud()
    }

    function setVolume(percent) {
        video.setVolume(percent)
        root.revealHud()
    }

    function toggleFullscreen() {
        root.fullscreenRequested()
        root.revealHud()
    }

    function seekToFraction(fraction) {
        if (!(video.duration > 0)) {
            return
        }
        if (video.seekAbsolute(Math.max(0, Math.min(1, fraction)) * video.duration)) {
            root.startupSeeking = true
        }
        root.revealHud()
    }

    // PlayerControlsOverlay.swift:517-522: whole speeds read "2x", the rest
    // as their digits, "0.75x".
    function speedLabel(speed) {
        return Number(speed.toFixed(2)) + "x"
    }

    // :546-556.
    readonly property string volumeIcon: {
        if (video.muted || video.volume <= 0) {
            return "speaker.slash.fill"
        }
        if (video.volume < 33) {
            return "speaker.wave.1.fill"
        }
        return video.volume < 66 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
    }

    function openTrackMenu(menu, byPointer) {
        root.closeTrackMenus()
        hideControls.stop()
        root.controlsVisible = true
        menu.openedByPointer = byPointer === true
        menu.open()
    }

    function closeTrackMenus() {
        subtitleMenu.close()
        audioMenu.close()
        speedMenu.close()
    }

    // A closed menu hands the remote back to its button; the HUD then ages out
    // as it does for any held control.
    // A menu a tap opened has no remote to hand back: the button would keep
    // the HUD up for good, so the HUD is released and ages out like after any
    // other tap.
    function trackMenuClosed(menu) {
        if (menu.openedByPointer) {
            menu.openedByPointer = false
            root.releaseHud()
        }
        root.controlsVisible = true
        hideControls.restart()
    }

    // Sends the film back to its opening frame and tells the session that is
    // where it now stands, so leaving straight afterwards cannot resume at the
    // point the viewer restarted away from. A seek the item dropped (the file
    // is still opening) moved nothing, so nothing is reported.
    function restart() {
        if (video.seekAbsolute(0))
            appController.player.reportRestart()
        root.revealHud()
    }

    function reportPlayback() {
        appController.player.reportPlayback(video.position, video.duration, video.paused)
    }

    function formatTime(seconds) {
        if (!(seconds > 0))
            return "0:00"
        var whole = Math.floor(seconds)
        var minutes = Math.floor(whole / 60)
        var remainder = whole % 60
        if (minutes < 60)
            return minutes + ":" + (remainder < 10 ? "0" : "") + remainder
        var hours = Math.floor(minutes / 60)
        var trailing = minutes % 60
        return hours + ":" + (trailing < 10 ? "0" : "") + trailing
               + ":" + (remainder < 10 ? "0" : "") + remainder
    }

    Component.onCompleted: {
        forceActiveFocus()
        hideControls.start()
    }
}
