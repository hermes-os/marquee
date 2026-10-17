import QtQuick
import Marquee 3.0

// Marquee/Features/Home/Views/HomeDetailView.swift:187-297 composes Home as a
// vertically scrolling surface with the sticky MARQUEE title bar and the bottom
// fade drawn over it, and answers an empty library with :401-473's scanning
// state or :477-492's empty state instead of that surface. Under the bar sit
// the titled horizontal rows (:612-648): Continue Watching, Recently Watched,
// Play Something, Recently Added, a row per decade, and All Movies, composed by
// the C++ `HomeRowsModel` so this file only draws them. The hero spotlight
// (:496-608) is not composed here yet. The Play Something capsule in the title
// bar is the first stop of the remote's vertical tree (:47, :1056): Up from the
// first row reaches it, Down returns to the card it left.
FocusScope {
    id: root

    property bool leanBack: appController.settings.leanBackMode
    property bool reduceMotion: appController.settings.reduceMotion

    // LibraryState.swift:9 publishes `isScanning`, which HomeDetailView.swift
    // :192 and :312 read for the scanning state and the header capsule. It is
    // a plain property bound to the controller so the shell owns it and a test
    // can hold the surface in a state a real scan settles too quickly to grab,
    // as the poster surface's own request state is held.
    property bool scanning: appController.scanning

    // HomeDetailView.swift:191 and :385-386 count the projection itself rather
    // than any composed row.
    readonly property int movieCount: appController.library.titleCount
    // :386 counts `filteredTVItems` — the production ShowsModel projection,
    // bound directly so the block below fails if this binding breaks.
    readonly property int episodeCount: appController.shows.episodeCount
    // HomeDetailView.swift:191-196 answers a library holding neither movies
    // nor episodes with the scanning state while a scan runs and the empty
    // state once it has completed. The surface is empty only when both halves
    // of the projection are; a populated TV half keeps a movies-less library
    // on the composed surface, exactly as :614's gate keeps the released app
    // there. :614 and :632 are siblings in one LazyVStack, not nested — and
    // :632-643 (the in-rows "No movies found" slot) is unreachable dead
    // code in the released app: :191 already answers the both-empty state
    // with the whole-surface scanning/empty states instead of this surface,
    // so v3 deliberately does NOT reproduce that slot. The live empty copy
    // is owned by `libraryEmptyState` below (:477-492 via :191-196).
    readonly property bool libraryEmpty: root.movieCount === 0 && root.episodeCount === 0
    readonly property bool hasContent: !root.libraryEmpty

    // HomeDetailView.swift:329 and :1008 run `appState.playSomething()` for a
    // tap on the capsule and for Enter while the remote rests on it. The shell
    // owns the pick and the player, as it does for the sidebar's control.
    signal playSomethingActivated()

    readonly property var rows: appController.homeRows
    readonly property var focusState: appController.homeRows.focus

    focus: true

    // :141-143 collapses the title bar past 60 points of scroll.
    readonly property real scrollOffset:
        Math.max(0, scroll.contentY + scroll.topMargin)
    readonly property bool compactHeader: root.scrollOffset > 60

    // :384-389: nothing at all when the library holds neither, otherwise both
    // counts either side of a slash, each singular only at one. Matches the
    // whole-library empty-library gate at :191 and :614: the count vanishes
    // only when both projections are empty.
    readonly property string countLabel: {
        if (root.libraryEmpty) {
            return ""
        }
        const movies = root.movieCount === 1
            ? qsTr("%1 movie").arg(root.movieCount)
            : qsTr("%1 movies").arg(root.movieCount)
        const episodes = root.episodeCount === 1
            ? qsTr("%1 episode").arg(root.episodeCount)
            : qsTr("%1 episodes").arg(root.episodeCount)
        return movies + "  /  " + episodes
    }

    Rectangle {
        anchors.fill: parent
        color: Theme.background
    }

    // :198-211 scrolls the whole surface under the title bar, opening its
    // content 120/170 points down and keeping 100/150 points of run-off below
    // it (:647). The Flickable is that scroll view as well as its content, so
    // this surface has exactly one vertical scroll authority.
    Item {
        id: rowsViewport
        objectName: "homeRowsViewport"

        anchors.fill: parent

        clip: true
        visible: root.hasContent

        Flickable {
            id: scroll
            objectName: "homeScroll"

            anchors.fill: parent

            contentWidth: width
            contentHeight: pageColumn.height
            boundsBehavior: Flickable.StopAtBounds

            // :201's leading spacer and :647's trailing padding, which are the
            // room the sticky bar and the bottom fade are drawn over.
            topMargin: Theme.scaled(120, 170, root.leanBack)
            bottomMargin: Theme.scaled(100, 150, root.leanBack)

            // The placement below is a spring this surface starts, not a
            // Behavior, so a pointer flick of the page is never animated
            // through the focus policy and there is still only one authority
            // moving contentY.
            NumberAnimation {
                id: scrollSpring
                objectName: "homeScrollSpring"
                target: scroll
                property: "contentY"
                duration: Theme.motionNormal
                easing.type: Easing.OutCubic
            }

            // :632 spaces the rows 36/54 points apart, :640's content padding
            // opens the stack 32/48 points below the bar's spacer, and :641
            // insets it by the page's outer padding.
            Column {
                id: pageColumn

                anchors.left: parent.left
                anchors.right: parent.right
                anchors.leftMargin: Theme.outerPadding(root.leanBack)
                anchors.rightMargin: Theme.outerPadding(root.leanBack)
                topPadding: Theme.scaled(32, 48, root.leanBack)
                spacing: Theme.scaled(36, 54, root.leanBack)

                // :612-620 lays the rows out as the members of one stack. At
                // most eight cards of each are drawn (:668); the header still
                // counts the row's whole length.
                Repeater {
                    id: rowRepeater
                    objectName: "homeRows"
                    model: root.rows

                    delegate: MediaItemRow {
                        required property string rowId
                        required property int itemCount
                        required property int index

                        objectName: "homeRow_" + rowId
                        width: pageColumn.width
                        height: implicitHeight

                        totalCount: itemCount
                        focusedIndex: root.activeFocus && !root.rows.playSomethingFocused
                            && root.focusState.row === index
                            ? root.focusState.column
                            : -1

                        onActivated: mediaId => root.openCard(
                            root.rows.cardForId(index, mediaId), true)
                    }
                }
            }
        }
    }

    // HomeDetailView.swift:245 and :301-382: the title bar sits over the
    // scrolled surface, opaque in the page's own background, and collapses
    // past 60 points of scroll.
    Item {
        id: titleBar
        objectName: "homeTitleBar"

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        height: barSurface.height + barFade.height
        visible: root.hasContent
        z: 1

        // :366's top padding sits above :365's bar, and :367's background
        // covers both. Both are written by their own bindings and intercepted
        // by the Behaviors below, so neither is declared readonly.
        property real topPadding: root.compactHeader
            ? Theme.scaled(4, 8, root.leanBack)
            : Theme.scaled(8, 12, root.leanBack)
        property real barHeight: root.compactHeader
            ? Theme.scaled(44, 62, root.leanBack)
            : Theme.scaled(78, 108, root.leanBack)

        // :368 and :377 settle both collapsing measurements in
        // MarqueeTheme.swift:256's compact-header spring, and :273-275
        // withholds it under Reduce Motion. The 350 ms OutCubic curve
        // approximates that response-0.35 spring; its 0.6 damping bounce is
        // not reproduced.
        Behavior on topPadding {
            enabled: !root.reduceMotion
            NumberAnimation {
                objectName: "homeHeaderPaddingSpring"
                duration: Theme.motionPage
                easing.type: Easing.OutCubic
            }
        }

        Behavior on barHeight {
            enabled: !root.reduceMotion
            NumberAnimation {
                objectName: "homeHeaderHeightSpring"
                duration: Theme.motionPage
                easing.type: Easing.OutCubic
            }
        }

        Rectangle {
            id: barSurface
            objectName: "homeTitleBarSurface"

            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            height: titleBar.topPadding + titleBar.barHeight
            color: Theme.background

            // :303 spaces the wordmark, the capsule, and the control; :363
            // insets the whole row by the page's outer padding, and :302-362
            // centres it in the bar below its top padding.
            Row {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.leftMargin: Theme.outerPadding(root.leanBack)
                anchors.rightMargin: Theme.outerPadding(root.leanBack)
                anchors.top: parent.top
                anchors.topMargin: titleBar.topPadding
                height: titleBar.barHeight
                spacing: Theme.scaled(14, 22, root.leanBack)

                // :304-310 fills MARQUEE with MarqueeTheme.swift:140-148's
                // three golds at :309's tracking.
                GradientWordmark {
                    id: wordmark
                    objectName: "homeWordmark"

                    pointSize: root.compactHeader
                        ? Theme.scaled(18, 28, root.leanBack)
                        : Theme.scaled(26, 38, root.leanBack)
                    tracking: Theme.scaled(5, 8, root.leanBack)

                    anchors.verticalCenter: parent.verticalCenter
                    width: implicitWidth
                    height: implicitHeight
                }

                // :312-327: while a scan is running, a capsule of the spinner
                // and the word beside the wordmark.
                Rectangle {
                    id: scanningCapsule
                    objectName: "homeScanningCapsule"

                    anchors.verticalCenter: parent.verticalCenter
                    visible: root.scanning
                    width: scanningRow.width
                        + 2 * Theme.scaled(9, 14, root.leanBack)
                    height: scanningRow.height
                        + 2 * Theme.scaled(4, 7, root.leanBack)
                    radius: height / 2
                    color: Qt.rgba(Theme.surfaceLayer.r, Theme.surfaceLayer.g,
                                   Theme.surfaceLayer.b, 0.82)

                    Row {
                        id: scanningRow

                        anchors.centerIn: parent
                        spacing: Theme.scaled(6, 9, root.leanBack)

                        // :314-316's small progress view at 0.64 scale. AppKit
                        // draws a 16-point spinner at that control size, so the
                        // spokes are drawn here at 16 * 0.64 points, because
                        // that control is not available on this platform. Its
                        // one-second turn is this reconstruction's own cadence.
                        Item {
                            id: spinner
                            objectName: "homeScanningSpinner"

                            anchors.verticalCenter: parent.verticalCenter
                            width: 16 * 0.64
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
                                        context.strokeStyle = Qt.rgba(
                                            Theme.textSecondary.r, Theme.textSecondary.g,
                                            Theme.textSecondary.b, 0.25 + 0.75 * spoke / 7)
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
                                    objectName: "homeScanningSpinnerSpin"
                                    running: scanningCapsule.visible && !root.reduceMotion
                                    from: 0
                                    to: 360
                                    duration: 1000
                                    loops: Animation.Infinite
                                }
                            }
                        }

                        Text {
                            objectName: "homeScanningLabel"
                            anchors.verticalCenter: parent.verticalCenter
                            text: qsTr("Scanning")
                            color: Theme.textSecondary
                            font.pixelSize: Theme.scaled(11, 16, root.leanBack)
                            font.weight: Font.Medium
                        }
                    }
                }

                // :329-355's Play Something capsule, the first stop of the
                // remote's vertical tree (:47). :346-352's focusChrome scales
                // the capsule about its centre while the ring and glow stay on
                // its unscaled bounds, so the slot holds the capsule and its
                // frame as siblings, as a poster card does.
                Item {
                    id: playSomethingSlot
                    objectName: "homePlaySomethingSlot"

                    readonly property bool remoteFocused:
                        root.activeFocus && root.rows.playSomethingFocused

                    anchors.verticalCenter: parent.verticalCenter
                    width: playSomethingRow.width
                        + 2 * Theme.scaled(10, 15, root.leanBack)
                    height: playSomethingRow.height
                        + 2 * Theme.scaled(5, 8, root.leanBack)
                    // The focused control rises above the count beside it.
                    z: playSomethingSlot.remoteFocused ? 1 : 0

                    FocusFrame {
                        objectName: "homePlaySomethingFocusFrame"
                        anchors.fill: parent
                        z: 1
                        active: playSomethingSlot.remoteFocused
                        radius: height / 2
                        focusScale: Theme.capsuleFocusScale
                        ringWidth: Theme.detailRingLineWidth
                        focusedGlowRadius: Theme.detailGlowRadius
                    }

                    Rectangle {
                        id: playSomething
                        objectName: "homePlaySomething"

                        anchors.fill: parent
                        radius: height / 2
                        color: Qt.rgba(Theme.accentPrimary.r, Theme.accentPrimary.g,
                                       Theme.accentPrimary.b, 0.86)
                        border.width: 1
                        border.color: Qt.rgba(Theme.accentSecondary.r, Theme.accentSecondary.g,
                                              Theme.accentSecondary.b, 0.34)
                        scale: playSomethingSlot.remoteFocused ? Theme.capsuleFocusScale : 1.0

                        // The focus spring settles in a quarter second
                        // (MarqueeTheme.swift:252) and is withheld under
                        // Reduce Motion; the final scale is the same.
                        Behavior on scale {
                            enabled: !root.reduceMotion
                            NumberAnimation {
                                objectName: "homePlaySomethingScale"
                                duration: Theme.motionNormal
                                easing.type: Easing.OutCubic
                            }
                        }

                        Row {
                            id: playSomethingRow

                            anchors.centerIn: parent
                            spacing: Theme.scaled(6, 9, root.leanBack)

                            MarqueeSymbol {
                                objectName: "homePlaySomethingSymbol"
                                anchors.verticalCenter: parent.verticalCenter
                                symbol: "shuffle"
                                pointSize: Theme.scaled(11, 16, root.leanBack)
                                color: Theme.accentSecondary
                                // :332's semibold sits one step above the
                                // sidebar symbols' `.medium` ninth of the
                                // point size.
                                strokeRatio: 0.105
                            }

                            Text {
                                objectName: "homePlaySomethingLabel"
                                anchors.verticalCenter: parent.verticalCenter
                                text: qsTr("Play Something")
                                color: Theme.textPrimary
                                font.pixelSize: Theme.scaled(11, 16, root.leanBack)
                                font.weight: Font.DemiBold
                            }
                        }

                        TapHandler {
                            onTapped: root.playSomethingActivated()
                        }

                        Accessible.name: qsTr("Play Something")
                        Accessible.role: Accessible.Button
                    }
                }
            }

            // :357-361 pushes the count to the trailing edge of the same row.
            Text {
                objectName: "homeTitleCount"

                anchors.right: parent.right
                anchors.rightMargin: Theme.outerPadding(root.leanBack)
                anchors.top: parent.top
                anchors.topMargin: titleBar.topPadding
                height: titleBar.barHeight
                verticalAlignment: Text.AlignVCenter

                text: root.countLabel
                color: Theme.textTertiary
                font.pixelSize: Theme.scaled(11, 16, root.leanBack)
                font.weight: Font.Medium
            }
        }

        // :370-377: the bar's own trailing fade, 20 points once collapsed and
        // 6 while open.
        Rectangle {
            id: barFade
            objectName: "homeTitleBarFade"

            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: barSurface.bottom
            height: root.compactHeader ? 20 : 6

            gradient: Gradient {
                GradientStop { position: 0.0; color: Theme.background }
                GradientStop {
                    position: 1.0
                    color: Qt.rgba(Theme.background.r, Theme.background.g,
                                   Theme.background.b, 0)
                }
            }

            Behavior on height {
                enabled: !root.reduceMotion
                NumberAnimation {
                    objectName: "homeHeaderFadeSpring"
                    duration: Theme.motionPage
                    easing.type: Easing.OutCubic
                }
            }
        }
    }

    // :246 draws Marquee/SharedViews/BottomFadeView.swift:5-25 over the
    // surface: an 80-point band running from nothing to the page background.
    Rectangle {
        objectName: "homeBottomFade"

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: 80
        visible: root.hasContent
        z: 2

        gradient: Gradient {
            GradientStop {
                position: 0.0
                color: Qt.rgba(Theme.background.r, Theme.background.g,
                               Theme.background.b, 0)
            }
            GradientStop { position: 1.0; color: Theme.background }
        }
    }

    // :191-196 and :401-473: a library with nothing in it yet, while a scan
    // is running. The gate reuses the both-projections-empty condition above,
    // so an episodes-only library never sees this state: it stays on the
    // composed surface, as the released app does.
    Item {
        id: scanState
        objectName: "libraryScanState"

        anchors.fill: parent
        visible: root.libraryEmpty && root.scanning

        Item {
            anchors.centerIn: parent
            width: Theme.scaled(160, 230, root.leanBack)
            height: width

            // :406-429: the resting ring in the surface layer, and the 0.3 arc
            // over it in MarqueeTheme.swift:142-144's three golds, both stroked
            // three points wide with round caps, turning once a second.
            Canvas {
                objectName: "libraryScanRing"

                anchors.fill: parent
                antialiasing: true

                // :416-423 sweeps the three golds as an AngularGradient about
                // the ring's own centre, so the colour of a point on the arc
                // follows its angle around that centre. SwiftUI spaces an
                // AngularGradient's colours evenly around the sweep, which for
                // three colours puts them at 0, 0.5, and 1 of a full turn
                // measured clockwise from the trim's own start at three
                // o'clock; the trimmed arc therefore shows only the first 0.3
                // of that ramp.
                function sweepColorAt(position) {
                    const stops = [Theme.titleGradientEnd,
                                   Theme.titleGradientMiddle,
                                   Theme.titleGradientStart]
                    const span = 1 / (stops.length - 1)
                    const index = Math.min(stops.length - 2,
                                           Math.floor(position / span))
                    const blend = (position - index * span) / span
                    const from = stops[index]
                    const to = stops[index + 1]
                    return Qt.rgba(from.r + (to.r - from.r) * blend,
                                   from.g + (to.g - from.g) * blend,
                                   from.b + (to.b - from.b) * blend,
                                   1)
                }

                onPaint: {
                    const context = getContext("2d")
                    context.reset()
                    context.clearRect(0, 0, width, height)
                    const centre = width / 2
                    const radius = centre - 1.5
                    context.lineWidth = 3

                    context.strokeStyle = Theme.surfaceLayer
                    context.beginPath()
                    context.arc(centre, centre, radius, 0, 2 * Math.PI)
                    context.stroke()

                    // :414's trim and :424's round caps, painted one degree of
                    // the sweep at a time so each degree carries the colour
                    // the released gradient holds there rather than a colour
                    // taken from a position across the canvas. Over one degree
                    // the released ramp moves by less than a quantization
                    // step, and the round caps of neighbouring degrees overlap
                    // along the arc, so the band is continuous and its two
                    // ends are the only caps that show.
                    const trim = 0.3
                    const degrees = Math.round(trim * 360)
                    context.lineCap = "round"
                    for (let step = 0; step < degrees; ++step) {
                        const from = trim * step / degrees
                        const to = trim * (step + 1) / degrees
                        context.strokeStyle = sweepColorAt((from + to) / 2)
                        context.beginPath()
                        context.arc(centre, centre, radius,
                                    from * 2 * Math.PI, to * 2 * Math.PI)
                        context.stroke()
                    }
                }

                onWidthChanged: requestPaint()
                onHeightChanged: requestPaint()

                // :431-438 turns the arc once a second, for ever. The released
                // view animates this whatever the accessibility setting says;
                // this repository's motion rule is answered instead, so a
                // viewer who asked for less motion gets a still ring. It also
                // stops with the state it belongs to: the surface hides this
                // subtree whenever the library has content or no scan is
                // running, and an animation nothing draws is only work.
                NumberAnimation on rotation {
                    objectName: "libraryScanRingSpin"
                    running: scanState.visible && !root.reduceMotion
                    from: 0
                    to: 360
                    duration: 1000
                    loops: Animation.Infinite
                }
            }

            // :440-458 breathes the logo between 0.85 and 1.15 over 2.2
            // seconds. The released asset is the play-button logo the
            // application icon is drawn from; v3's own shipped icon is that
            // same mark.
            Image {
                id: scanLogo
                objectName: "libraryScanLogo"

                anchors.centerIn: parent
                width: Theme.scaled(88, 128, root.leanBack)
                height: width
                fillMode: Image.PreserveAspectFit
                source: "../../resources/icons/marquee.svg"
                sourceSize.width: width
                sourceSize.height: height

                scale: root.reduceMotion ? 1.0 : 0.85
                opacity: root.reduceMotion ? 1.0 : 0.7

                SequentialAnimation {
                    objectName: "libraryScanLogoBreath"
                    running: scanState.visible && !root.reduceMotion
                    loops: Animation.Infinite

                    ParallelAnimation {
                        NumberAnimation {
                            target: scanLogo
                            property: "scale"
                            to: 1.15
                            duration: 2200
                            easing.type: Easing.InOutQuad
                        }
                        NumberAnimation {
                            target: scanLogo
                            property: "opacity"
                            to: 1.0
                            duration: 2200
                            easing.type: Easing.InOutQuad
                        }
                    }

                    ParallelAnimation {
                        NumberAnimation {
                            target: scanLogo
                            property: "scale"
                            to: 0.85
                            duration: 2200
                            easing.type: Easing.InOutQuad
                        }
                        NumberAnimation {
                            target: scanLogo
                            property: "opacity"
                            to: 0.7
                            duration: 2200
                            easing.type: Easing.InOutQuad
                        }
                    }
                }
            }
        }
    }

    // :195 and :477-492: a library with nothing in it — neither movies nor
    // episodes — and no scan running. The gate reuses the both-empty
    // condition above, so an episodes-only library never sees this state: it
    // stays on the composed surface, as the released app does. THIS is the
    // one surface that owns the `!scanning` term the suite falsifies: a
    // both-empty library with a scan running must show the scanning state
    // (:401-473 via :191-196), never this one.
    Column {
        objectName: "libraryEmptyState"

        anchors.centerIn: parent
        width: Math.min(parent.width, 640)
        spacing: Theme.spacingMD
        visible: root.libraryEmpty && !root.scanning

        // :480-482's `film` symbol at 40/58 points, ultralight, in the
        // tertiary text colour at 0.4.
        MarqueeSymbol {
            objectName: "libraryEmptyGlyph"
            anchors.horizontalCenter: parent.horizontalCenter
            symbol: "film"
            pointSize: Theme.scaled(40, 58, root.leanBack)
            color: Qt.rgba(Theme.textTertiary.r, Theme.textTertiary.g,
                           Theme.textTertiary.b, 0.4)
            // Ultralight is the lightest weight the released symbol offers,
            // about half the stroke of the `.medium` this component defaults to.
            strokeRatio: 0.045
        }

        Text {
            objectName: "libraryEmptyTitle"
            width: parent.width
            text: qsTr("No content found")
            color: Theme.textSecondary
            font.pixelSize: Theme.scaled(17, 24, root.leanBack)
            font.weight: Font.Medium
            horizontalAlignment: Text.AlignHCenter
        }

        Text {
            objectName: "libraryEmptyDetail"
            width: parent.width
            text: qsTr("Content will appear once scanning completes")
            color: Theme.textTertiary
            font.pixelSize: Theme.scaled(12, 17, root.leanBack)
            horizontalAlignment: Text.AlignHCenter
        }
    }

    // Marquee/Utilities/RemoteScrollCoordinator.swift:1261-1289, reached
    // through HomeDetailView's focused-section scroll: put the focused row at
    // the released row anchor, and leave the page alone while that row is
    // already comfortably placed, so moving along a row does not drag the page.
    function placeFocusedRow(animated) {
        const item = rowRepeater.itemAt(root.focusState.row)
        if (item === null || scroll.height <= 0) {
            return
        }
        // :1240-1241 anchors a browse row at 0.36 of the viewport, never
        // closer to the top than 210 points.
        const desiredTop = Math.max(210, Math.round(scroll.height * 0.36))
        // The row is measured against the Flickable itself, whose coordinates
        // are the viewport's, so the page offset and the bar's spacer are
        // carried by contentY rather than by a separate header inset.
        const rowViewportTop = item.mapToItem(scroll, 0, 0).y
        // :1254-1255 tolerates the greater of 48 points and 0.11 of the
        // viewport before the page moves at all.
        if (Math.abs(rowViewportTop - desiredTop) <= Math.max(48, scroll.height * 0.11)) {
            return
        }
        // :1288 clamps the target to the top of the content, which here is the
        // bar's spacer; the bottom is clamped against what was laid out.
        const target = Math.min(
            Math.max(-scroll.topMargin, scroll.contentY + rowViewportTop - desiredTop),
            Math.max(-scroll.topMargin,
                     scroll.contentHeight + scroll.bottomMargin - scroll.height))
        scrollSpring.stop()
        if (!animated || root.reduceMotion) {
            scroll.contentY = target
            return
        }
        scrollSpring.from = scroll.contentY
        scrollSpring.to = target
        scrollSpring.start()
    }

    // The sticky bar is opaque (:367), so a card scrolled under it is neither
    // seen nor reachable: a tap that lands on the bar is the bar's, even though
    // the cards beneath it still hear it. Where the last press landed is kept
    // here, because the card only reports that it was tapped.
    PointHandler {
        id: pressTracker
        acceptedButtons: Qt.LeftButton
    }

    readonly property bool lastPressWasOnTheBar:
        pressTracker.point.position.y < barSurface.height

    // A movie card opens the title's details. An episode card stands for its
    // show: it opens the show page, at that episode when the card names one.
    // The card is a map from the composition (`HomeRowsModel::cardAt`), so a
    // projection replaced underneath cannot open a different title than the
    // focused card is showing.
    function openCard(card, fromPointer) {
        if (card === undefined || card.mediaId === undefined || card.mediaId.length === 0) {
            return
        }
        if (fromPointer === true) {
            if (root.lastPressWasOnTheBar) {
                return
            }
            root.rows.focusCard(card.row, card.column)
        }
        // Opening a title replaces this screen, and with it the delegate the
        // key or tap is still unwinding through.
        if (card.showName.length === 0) {
            Qt.callLater(appController.showMediaDetails, card.mediaId)
            return
        }
        Qt.callLater(function() {
            if (card.opensEpisode) {
                appController.shows.requestEpisodeFocus(card.mediaId)
            }
            appController.navigation.openShowDetail(card.showName)
        })
    }

    // Rows take their height as their delegates load, after the remote has
    // already asked for a row to be placed. Placement is taken again, without
    // motion, once the page has its final height.
    Connections {
        target: pageColumn

        function onHeightChanged() {
            // The first row rests at the top of the page without help; any
            // other row is where the remote last put it, and has to be put
            // back when the rows above it finish growing.
            if (root.activeFocus || root.focusState.row > 0) {
                Qt.callLater(root.placeFocusedRow, false)
            }
        }
    }

    Connections {
        target: root.focusState

        function onFocusChanged() { root.placeFocusedRow(true) }
        // A recomposed library keeps the remote's clamped target but not the
        // page it was placed against, so the placement is taken again without
        // motion.
        function onStructureChanged() { root.placeFocusedRow(false) }
    }

    // Every arrow key is handled in one handler, because Keys mixes a generic
    // handler and per-key handlers on the same item in an order that is not
    // worth depending on. Left at the first column stays unaccepted, so the
    // shell hands the remote to the sidebar.
    Keys.onPressed: event => {
        switch (event.key) {
        case Qt.Key_Left:
            event.accepted = root.rows.moveLeft()
            return
        case Qt.Key_Right:
            root.rows.moveRight()
            event.accepted = true
            return
        case Qt.Key_Up:
            root.rows.moveUp()
            event.accepted = true
            return
        case Qt.Key_Down:
            root.rows.moveDown()
            event.accepted = true
            return
        case Qt.Key_Return:
        case Qt.Key_Enter:
            if (root.rows.playSomethingFocused) {
                root.playSomethingActivated()
            } else {
                root.openCard(root.rows.cardAt(root.focusState.row, root.focusState.column), false)
            }
            event.accepted = true
            return
        default:
            event.accepted = false
        }
    }
}
