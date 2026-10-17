import QtQuick
import Marquee 3.0

// Marquee/Features/Library/Views/TVShowsDetailView.swift, grid mode
// (:138-219): the "TV Shows" heading with its show count, then one ShowCardRow
// per composed row, with the empty state when the library holds no episodes.
// Show detail is its own route (:110-116 overlays it; here the navigation
// stack carries it), so this surface only ever shows the grid.
FocusScope {
    id: root

    property bool leanBack: appController.settings.leanBackMode
    property bool reduceMotion: appController.settings.reduceMotion
    readonly property var rows: appController.shows
    readonly property var focusState: appController.shows.focus

    signal requestSidebarFocus()

    focus: true

    Rectangle {
        anchors.fill: parent
        color: Theme.background
    }

    Flickable {
        id: scroll
        objectName: "showsScroll"
        anchors.fill: parent
        contentWidth: width
        contentHeight: pageColumn.height
        boundsBehavior: Flickable.StopAtBounds
        clip: true

        NumberAnimation {
            id: scrollSpring
            objectName: "showsScrollSpring"
            target: scroll
            property: "contentY"
            duration: Theme.motionNormal
            easing.type: Easing.OutCubic
        }

        Column {
            id: pageColumn
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: Theme.outerPadding(root.leanBack)
            anchors.rightMargin: Theme.outerPadding(root.leanBack)
            // TVShowsDetailView.swift:141, :153, :182.
            topPadding: Theme.scaled(28, 44, root.leanBack)
            bottomPadding: Theme.scaled(100, 150, root.leanBack)
            spacing: Theme.scaled(36, 54, root.leanBack)

            // TVShowsDetailView.swift:142-152.
            Item {
                id: header
                width: pageColumn.width
                height: heading.height

                Text {
                    id: heading
                    objectName: "showsHeading"
                    anchors.left: parent.left
                    anchors.top: parent.top
                    text: qsTr("TV Shows")
                    color: Theme.textPrimary
                    font.pixelSize: Theme.scaled(28, 40, root.leanBack)
                    font.weight: Font.Bold
                }

                Text {
                    objectName: "showsCount"
                    anchors.right: parent.right
                    anchors.baseline: heading.baseline
                    visible: root.rows.showCount > 0
                    text: root.rows.showCount === 1
                        ? qsTr("%1 show").arg(root.rows.showCount)
                        : qsTr("%1 shows").arg(root.rows.showCount)
                    color: Theme.textTertiary
                    font.pixelSize: Theme.scaled(13, 18, root.leanBack)
                }
            }

            // TVShowsDetailView.swift:155-156, :256-270: the empty state, shown
            // once the library has no episodes and no scan is running. While
            // a scan runs the surface shows its rows' loading room instead,
            // so the state reads scanning rather than absent while
            // `scanning` is true. This empty state and the rows below are
            // mutually exclusive — the state shows only when the library
            // holds no episodes, the rows only when it holds some — so its
            // stacking position is not observable: it sits in the page
            // column above the row repeater, not above the heading or
            // outside the scrolled page, so an episodes-less library still
            // shows the heading with its empty rows beneath it.
            Column {
                objectName: "showsEmptyState"
                anchors.horizontalCenter: parent.horizontalCenter
                width: Math.min(pageColumn.width, 640)
                topPadding: Theme.scaled(80, 120, root.leanBack)
                spacing: Theme.spacingMD
                visible: root.rows.showCount === 0 && !appController.scanning

                // The `tv` symbol at 40/58 points, ultralight, in the tertiary
                // text colour at 0.4: an outlined screen on a stand.
                Canvas {
                    objectName: "showsEmptyGlyph"
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: Theme.scaled(40, 58, root.leanBack)
                    height: width * 0.78
                    antialiasing: true
                    onPaint: {
                        const context = getContext("2d")
                        context.reset()
                        context.clearRect(0, 0, width, height)
                        const line = Math.max(1, width * 0.035)
                        context.strokeStyle = Qt.rgba(Theme.textTertiary.r, Theme.textTertiary.g,
                                                      Theme.textTertiary.b, 0.4)
                        context.lineWidth = line
                        context.lineCap = "round"
                        const screenHeight = height * 0.76
                        context.beginPath()
                        context.roundedRect(line / 2, line / 2, width - line, screenHeight - line,
                                            width * 0.08, width * 0.08)
                        context.stroke()
                        context.beginPath()
                        context.moveTo(width * 0.24, height - line / 2)
                        context.lineTo(width * 0.76, height - line / 2)
                        context.stroke()
                    }
                    onWidthChanged: requestPaint()
                    onHeightChanged: requestPaint()
                }

                Text {
                    objectName: "showsEmptyTitle"
                    width: parent.width
                    text: qsTr("No TV shows found")
                    color: Theme.textSecondary
                    font.pixelSize: Theme.scaled(17, 24, root.leanBack)
                    font.weight: Font.Medium
                    horizontalAlignment: Text.AlignHCenter
                }

                // TVShowsDetailView.swift:264.
                Text {
                    objectName: "showsEmptyDetail"
                    width: parent.width
                    text: qsTr("Scanning %1").arg(appController.settings.tvShowsRoots.length > 0
                        ? appController.settings.tvShowsRoots[0]
                        : "~/TV Shows")
                    color: Theme.textTertiary
                    font.pixelSize: Theme.scaled(12, 17, root.leanBack)
                    elide: Text.ElideMiddle
                    horizontalAlignment: Text.AlignHCenter
                }
            }

            // TVShowsDetailView.swift:157-179: the composed rows follow the
            // empty-state slot in the same stack. The two are mutually
            // exclusive — the empty state shows only when the library holds
            // no episodes, the rows only when it holds some — so the empty
            // state's stacking position is not observable.
            Repeater {
                id: rowRepeater
                objectName: "showRows"
                model: root.rows
                // `rowTitle` and `shows` bind straight onto the row's own
                // required properties from the model roles of the same name.
                delegate: ShowCardRow {
                    required property string rowId
                    required property int showCount
                    required property int index
                    objectName: "showRow_" + rowId
                    width: pageColumn.width
                    height: implicitHeight
                    totalCount: showCount
                    focusedIndex: root.activeFocus && root.focusState.row === index
                        ? root.focusState.column
                        : -1
                    onActivated: showName => root.openShow(showName)
                }
            }
        }
    }

    // BottomFadeView (TVShowsDetailView.swift:108).
    Rectangle {
        objectName: "showsBottomFade"
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

    // TVShowsDetailView.swift:291-329 through RemoteHomeRowScrollPlacement:
    // the focused row is brought to the comfortable band when it has left it,
    // with the same band MoviesScreen.qml derives.
    function placeFocusedRow(animated) {
        const item = rowRepeater.itemAt(root.focusState.row)
        if (item === null || scroll.height <= 0) {
            return
        }
        const desiredTop = Math.max(210, Math.round(scroll.height * 0.36))
        const rowViewportTop = item.mapToItem(scroll, 0, 0).y
        if (Math.abs(rowViewportTop - desiredTop) <= Math.max(48, scroll.height * 0.11)) {
            return
        }
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

    // TVShowsDetailView.swift:168-174, :506-513.
    function openShow(showName) {
        if (showName.length === 0) {
            return
        }
        Qt.callLater(appController.navigation.openShowDetail, showName)
    }

    Connections {
        target: root.focusState
        function onFocusChanged() { root.placeFocusedRow(true) }
        function onStructureChanged() { root.placeFocusedRow(false) }
    }

    // TVShowsDetailView.swift:494-530: Select opens the focused show, the
    // arrows move through the grid, and Back or a Left at the grid's edge
    // hands the remote to the sidebar.
    Keys.onPressed: event => {
        switch (event.key) {
        case Qt.Key_Left:
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
            root.openShow(
                root.rows.showNameAt(root.focusState.row, root.focusState.column))
            event.accepted = true
            return
        case Qt.Key_Escape:
        case Qt.Key_Back:
        case Qt.Key_Backspace:
            root.requestSidebarFocus()
            event.accepted = true
            return
        default:
            event.accepted = false
        }
    }
}
