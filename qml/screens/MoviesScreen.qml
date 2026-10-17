import QtQuick
import Marquee 3.0

// Marquee/Features/Library/Views/MoviesDetailView.swift:101-211 draws the
// Movies route: a "Movies" heading with the library's title count beside it,
// over the composed movie rows, scrolling vertically inside the page's outer
// padding, with the empty state at :213-229 when the library holds no movies.
FocusScope {
    id: root

    property bool leanBack: appController.settings.leanBackMode
    property bool reduceMotion: appController.settings.reduceMotion

    readonly property var rows: appController.movieRows
    readonly property var focusState: appController.movieRows.focus

    // MoviesDetailView.swift:478-480 and :498-500: Back at the route's root,
    // and Left at its first column, return the remote to the sidebar rather
    // than leaving the surface.
    signal requestSidebarFocus()

    focus: true

    Rectangle {
        anchors.fill: parent
        color: Theme.background
    }

    // MoviesDetailView.swift:105-144 scrolls the whole page: the heading at
    // :108-119, the empty state at :121-122, and the rows at :124-135 are
    // members of one `LazyVStack` inside one vertical `ScrollView`. The heading
    // therefore travels with the rows once the page overflows, and the viewport
    // the placement below measures against is the whole surface rather than the
    // strip beneath a pinned header.
    Flickable {
        id: scroll
        objectName: "moviesScroll"

        anchors.fill: parent

        contentWidth: width
        contentHeight: pageColumn.height
        boundsBehavior: Flickable.StopAtBounds
        clip: true

        // The placement below is a spring this surface starts, not a Behavior,
        // so a pointer flick of the page is never animated through the focus
        // policy and there is still only one authority moving contentY.
        NumberAnimation {
            id: scrollSpring
            objectName: "moviesScrollSpring"
            target: scroll
            property: "contentY"
            duration: Theme.motionNormal
            easing.type: Easing.OutCubic
        }

        // :138 insets the stack by the page's outer padding, :119 opens it
        // 28/44 points below the top of the surface, :107 separates the heading
        // from the first row and the rows from each other by the same 36/54
        // points, and :139 keeps 100/150 points of run-off below the last row.
        Column {
            id: pageColumn

            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: Theme.outerPadding(root.leanBack)
            anchors.rightMargin: Theme.outerPadding(root.leanBack)
            topPadding: Theme.scaled(28, 44, root.leanBack)
            bottomPadding: Theme.scaled(100, 150, root.leanBack)
            spacing: Theme.scaled(36, 54, root.leanBack)

            // MoviesDetailView.swift:108-119 puts the heading and its count on
            // one baseline, at the head of the scrolled stack.
            Item {
                id: header

                width: pageColumn.width
                height: heading.height

                Text {
                    id: heading
                    objectName: "moviesHeading"

                    anchors.left: parent.left
                    anchors.top: parent.top

                    text: qsTr("Movies")
                    color: Theme.textPrimary
                    font.pixelSize: Theme.scaled(28, 40, root.leanBack)
                    font.weight: Font.Bold
                }

                // MoviesDetailView.swift:113-117 counts every movie the library
                // holds and shows nothing at all when it holds none.
                Text {
                    objectName: "moviesTitleCount"

                    anchors.right: parent.right
                    anchors.baseline: heading.baseline

                    visible: root.rows.titleCount > 0
                    text: root.rows.titleCount === 1
                        ? qsTr("%1 title").arg(root.rows.titleCount)
                        : qsTr("%1 titles").arg(root.rows.titleCount)
                    color: Theme.textTertiary
                    font.pixelSize: Theme.scaled(13, 18, root.leanBack)
                }
            }

            // MoviesDetailView.swift:121-122 and :215-229 put the empty state
            // where a row would have gone, centred, 80/120 points into its own
            // slot in that same stack.
            Column {
                objectName: "moviesEmptyState"

                anchors.horizontalCenter: parent.horizontalCenter
                width: Math.min(pageColumn.width, 640)
                topPadding: Theme.scaled(80, 120, root.leanBack)
                spacing: Theme.spacingMD
                visible: root.rows.titleCount === 0

                Canvas {
                    objectName: "moviesEmptyGlyph"

                    anchors.horizontalCenter: parent.horizontalCenter
                    width: Theme.scaled(40, 58, root.leanBack)
                    height: width * 0.72
                    antialiasing: true

                    // The `film` symbol at 40/58 points, ultralight, in the
                    // tertiary text colour at 0.4: an outlined film frame with
                    // sprocket holes, drawn here because SF Symbols are not
                    // available on this platform.
                    onPaint: {
                        const context = getContext("2d")
                        context.reset()
                        context.clearRect(0, 0, width, height)
                        const line = Math.max(1, width * 0.035)
                        context.strokeStyle = Qt.rgba(Theme.textTertiary.r, Theme.textTertiary.g,
                                                      Theme.textTertiary.b, 0.4)
                        context.lineWidth = line
                        context.beginPath()
                        context.roundedRect(line / 2, line / 2, width - line, height - line,
                                            width * 0.08, width * 0.08)
                        context.stroke()
                        const holeSize = width * 0.09
                        const holeInset = width * 0.1
                        for (let index = 0; index < 4; ++index) {
                            const x = holeInset + index * (width - 2 * holeInset - holeSize) / 3
                            context.strokeRect(x, holeInset, holeSize, holeSize)
                            context.strokeRect(x, height - holeInset - holeSize, holeSize, holeSize)
                        }
                    }

                    onWidthChanged: requestPaint()
                    onHeightChanged: requestPaint()
                }

                Text {
                    objectName: "moviesEmptyTitle"
                    width: parent.width
                    text: qsTr("No movies found")
                    color: Theme.textSecondary
                    font.pixelSize: Theme.scaled(17, 24, root.leanBack)
                    font.weight: Font.Medium
                    horizontalAlignment: Text.AlignHCenter
                }

                // MoviesDetailView.swift:223 names the first configured movies
                // folder, falling back to the folder the released application
                // defaults to.
                Text {
                    objectName: "moviesEmptyDetail"
                    width: parent.width
                    text: qsTr("Scanning %1").arg(appController.settings.libraryRoots.length > 0
                        ? appController.settings.libraryRoots[0]
                        : "~/Movies")
                    color: Theme.textTertiary
                    font.pixelSize: Theme.scaled(12, 17, root.leanBack)
                    elide: Text.ElideMiddle
                    horizontalAlignment: Text.AlignHCenter
                }
            }

            // MoviesDetailView.swift:124-135 lays the rows out as the members
            // of that same stack which follow the heading.
            Repeater {
                id: rowRepeater
                objectName: "movieRows"
                model: root.rows

                // rowTitle and items are the model's own roles, so the row
                // component's required properties of those names are filled
                // from the composition rather than rebound here.
                delegate: MediaItemRow {
                    required property string rowId
                    required property int itemCount
                    required property int index

                    objectName: "movieRow_" + rowId
                    width: pageColumn.width
                    height: implicitHeight

                    totalCount: itemCount
                    focusedIndex: root.activeFocus && root.focusState.row === index
                        ? root.focusState.column
                        : -1

                    onActivated: mediaId => root.openTitle(mediaId)
                }
            }
        }
    }

    // MoviesDetailView.swift:177 draws
    // Marquee/SharedViews/BottomFadeView.swift:14-24 over the scrolled page:
    // an 80-point band running from nothing to the page's own background, so a
    // row leaving the bottom of the surface fades out instead of being cut at
    // its edge. It is drawn over the scroll rather than inside it, takes no
    // pointer input (:23), and owns no scrolling, focus, or layout of its own.
    Rectangle {
        objectName: "moviesBottomFade"

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: 80
        z: 1

        gradient: Gradient {
            GradientStop {
                position: 0.0
                color: Qt.rgba(Theme.background.r, Theme.background.g,
                               Theme.background.b, 0)
            }
            GradientStop { position: 1.0; color: Theme.background }
        }
    }

    // Marquee/Utilities/RemoteScrollCoordinator.swift:1261-1289, reached
    // through MoviesDetailView.swift:259-279: put the focused row at the
    // released row anchor, and leave the page alone while that row is already
    // comfortably placed, so moving along a row does not drag the page.
    function placeFocusedRow(animated) {
        const item = rowRepeater.itemAt(root.focusState.row)
        if (item === null || scroll.height <= 0) {
            return
        }
        // :1240-1241 anchors a browse row at 0.36 of the viewport, never
        // closer to the top than 210 points.
        const desiredTop = Math.max(210, Math.round(scroll.height * 0.36))
        // The row is measured against the Flickable itself, whose coordinates
        // are the viewport's, so the heading scrolled above it is carried by
        // the page offset rather than by a separate header inset.
        const rowViewportTop = item.mapToItem(scroll, 0, 0).y
        // :1254-1255 tolerates the greater of 48 points and 0.11 of the
        // viewport before the page moves at all.
        if (Math.abs(rowViewportTop - desiredTop) <= Math.max(48, scroll.height * 0.11)) {
            return
        }
        // :1288 clamps the target to the top of the content; the bottom is
        // clamped against the content this surface actually laid out.
        const target = Math.min(
            Math.max(0, scroll.contentY + rowViewportTop - desiredTop),
            Math.max(0, scroll.contentHeight - scroll.height))
        scrollSpring.stop()
        if (!animated || root.reduceMotion) {
            scroll.contentY = target
            return
        }
        scrollSpring.from = scroll.contentY
        scrollSpring.to = target
        scrollSpring.start()
    }

    // MoviesDetailView.swift:481-484 opens the focused title's details. The
    // identity comes from the composition, so a projection replaced underneath
    // cannot open a different title than the focused card is showing.
    function openTitle(mediaId) {
        if (mediaId.length === 0) {
            return
        }
        // Opening a title replaces this screen, and with it the delegate the
        // key or tap is still unwinding through.
        Qt.callLater(appController.showMediaDetails, mediaId)
    }

    Connections {
        target: root.focusState

        function onFocusChanged() { root.placeFocusedRow(true) }
        // A recomposed library keeps the remote's clamped target but not the
        // page it was placed against, so the placement is taken again without
        // motion, as MoviesDetailView.swift:160-162 does.
        function onStructureChanged() { root.placeFocusedRow(false) }
    }

    // The route's whole key map lives in one handler, because Keys mixes a
    // generic handler and per-key handlers on the same item in an order that
    // is not worth depending on.
    Keys.onPressed: event => {
        switch (event.key) {
        case Qt.Key_Left:
            // At the first column the key belongs to the sidebar, so it is
            // left unaccepted for the shell's own hand-off.
            event.accepted = root.focusState.moveLeft()
            return
        case Qt.Key_Right:
            root.focusState.moveRight()
            event.accepted = true
            return
        case Qt.Key_Up:
            root.focusState.moveUp()
            event.accepted = true
            return
        case Qt.Key_Down:
            root.focusState.moveDown()
            event.accepted = true
            return
        case Qt.Key_Return:
        case Qt.Key_Enter:
            root.openTitle(
                root.rows.mediaIdAt(root.focusState.row, root.focusState.column))
            event.accepted = true
            return
        case Qt.Key_Escape:
        case Qt.Key_Back:
        case Qt.Key_Backspace:
            // MoviesDetailView.swift:478-480 answers Back at the route's root
            // by returning the remote to the sidebar, so the key is accepted
            // here rather than reaching the shell's history back.
            root.requestSidebarFocus()
            event.accepted = true
            return
        default:
            event.accepted = false
        }
    }
}
