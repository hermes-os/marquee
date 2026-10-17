import QtQuick
import Marquee 3.0

// Marquee/SharedViews/MovieCard.swift:356-413 composes a browse row as a
// leading-aligned stack of a header and a horizontal card row spaced 12 points
// apart, with the row's own title on the left and its whole length as
// "N title(s)" on the right.
Item {
    id: root

    required property string rowTitle
    // The row's items as a model of the same roles the library grid reads.
    required property var items
    // MovieCard.swift:410-412 counts the row's whole length, not the cards
    // that happen to be rendered.
    required property int totalCount
    // The column the remote is on in this row, or -1 when focus is elsewhere.
    property int focusedIndex: -1
    property bool leanBack: appController.settings.leanBackMode
    property bool reduceMotion: appController.settings.reduceMotion

    signal activated(string mediaId)

    readonly property real haloPadding: Theme.posterFocusHaloPadding(root.leanBack)
    readonly property real cardWidth: Theme.posterCardWidth(root.leanBack)
    readonly property real cardGap: Theme.cardGap(root.leanBack)
    readonly property real cardStride: root.cardWidth + root.cardGap
    // The delegate's own height, which reserves the halo room a focused card's
    // chrome paints into above and below its artwork.
    readonly property real cardHeight:
        Theme.posterCardHeight(root.leanBack) + 2 * root.haloPadding

    implicitHeight: header.height + Theme.rowHeaderToContent + root.cardHeight

    // Marquee/Utilities/RemoteGridFocus.swift:2422-2463 places a focused card
    // one slot past the centre of the visible slots and stops at the last
    // reachable step, so a row scrolls only as far as it has content for.
    function focusOffset(index) {
        const count = row.count
        if (count <= 0 || index < 0 || index >= count || root.cardStride <= 0) {
            return -1
        }
        const slots = root.visibleSlotCount()
        const requestedStep = Math.max(0, index - Math.floor(slots / 2) + 1)
        const maximumStep = Math.max(0, count - slots)
        return Math.min(requestedStep, maximumStep) * root.cardStride
    }

    // RemoteGridFocus.swift:2508-2524 counts the whole slots left in the
    // viewport once both insets are removed, and never reports fewer than one.
    // Both callers below pass the halo padding as the trailing inset
    // (ArrowedScrollRow.swift:49-51 and :174), so the slot count never depends
    // on the trailing padding derived from it.
    function visibleSlotCount() {
        if (root.cardStride <= 0) {
            return 1
        }
        const usable = Math.max(0, viewport.width - 2 * root.haloPadding)
        return Math.max(1, Math.floor((usable + root.cardGap) / root.cardStride))
    }

    // RemoteGridFocus.swift:2493-2505 pads the row's trailing edge by whatever
    // the last placement needs beyond the content, so the final cards still
    // reach their slot instead of stopping short at the content's end.
    function trailingPadding() {
        const count = row.count
        if (count <= 0) {
            return root.haloPadding
        }
        const contentExtent = count * root.cardWidth + Math.max(0, count - 1) * root.cardGap
        const maximumOffset = Math.max(0, count - root.visibleSlotCount()) * root.cardStride
        const required = maximumOffset + viewport.width - root.haloPadding - contentExtent
        return Math.max(root.haloPadding, required)
    }

    // The placement is a spring the surface starts, not a Behavior, so a
    // pointer flick of this row is never animated through the focus policy.
    function scrollToFocusedCard(animated) {
        const offset = root.focusOffset(root.focusedIndex)
        if (offset < 0) {
            return
        }
        const target = offset - row.leftMargin
        rowScrollSpring.stop()
        // Marquee/Utilities/RemoteScrollCoordinator.swift:805-815 places the
        // row at once rather than animating when motion is reduced.
        if (!animated || root.reduceMotion) {
            row.contentX = target
            return
        }
        rowScrollSpring.from = row.contentX
        rowScrollSpring.to = target
        rowScrollSpring.start()
    }

    onFocusedIndexChanged: root.scrollToFocusedCard(true)

    // ArrowedScrollRow.swift:120-125 reconciles the same placement whenever the
    // row's viewport or its content geometry changes, so a card focused before
    // the change is not left clipped by it with no key left to repair it: at the
    // row's end another Right does not move the clamped selection and so cannot
    // take the placement again.
    //
    // The released row observes the scroll view's clip and document views
    // (RemoteScrollCoordinator.swift:1128-1154) and places on the main queue a
    // turn later; this defers for the same reason, because the row's own
    // trailing padding is a binding on that geometry and a placement taken
    // before it settles would be clamped by the padding the old size asked for.
    // The view is laid out first because a placement set before it has applied
    // its new delegate sizes is overwritten by that layout when it runs.
    function reconcilePlacement() {
        row.forceLayout()
        root.scrollToFocusedCard(false)
    }

    // Card width, gap, and halo all change with lean-back mode, which is this
    // row's whole content geometry.
    onCardStrideChanged: Qt.callLater(root.reconcilePlacement)
    onHaloPaddingChanged: Qt.callLater(root.reconcilePlacement)

    Item {
        id: header

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        // The count is baseline-aligned in a smaller face, so it descends no
        // further than the title it is aligned to.
        height: rowTitleText.height

        Text {
            id: rowTitleText
            objectName: "movieRowTitle"

            anchors.left: parent.left
            anchors.top: parent.top
            anchors.right: rowCountText.left
            anchors.rightMargin: Theme.spacingMD

            text: root.rowTitle
            color: Theme.textPrimary
            font.pixelSize: Theme.rowTitleSize(root.leanBack)
            font.weight: Font.DemiBold
            elide: Text.ElideRight
        }

        // MovieCard.swift:377-383 aligns the count with the title's first text
        // baseline rather than with the top of its own box.
        Text {
            id: rowCountText
            objectName: "movieRowCount"

            anchors.right: parent.right
            anchors.baseline: rowTitleText.baseline

            text: root.totalCount === 1
                ? qsTr("%1 title").arg(root.totalCount)
                : qsTr("%1 titles").arg(root.totalCount)
            color: Theme.textTertiary
            font.pixelSize: Theme.rowCountSize(root.leanBack)
            font.weight: Font.Medium
        }
    }

    // Marquee/SharedViews/ArrowedScrollRow.swift:75-87 widens the row's scroll
    // view by the halo padding on both sides and starts its content a halo
    // padding in, so a card at either end paints its chrome into the page's
    // outer padding instead of being cut at the row's boundary.
    Item {
        id: viewport
        objectName: "movieRowViewport"

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: -root.haloPadding
        anchors.rightMargin: -root.haloPadding
        anchors.top: header.bottom
        anchors.topMargin: Theme.rowHeaderToContent
        height: root.cardHeight
        clip: true

        // The usable viewport the placement clamps against, whose changes the
        // released row answers through `viewportChangeSerial`
        // (RemoteScrollCoordinator.swift:1203-1212).
        onWidthChanged: Qt.callLater(root.reconcilePlacement)

        ListView {
            id: row
            objectName: "movieRow"

            anchors.fill: parent
            orientation: ListView.Horizontal
            clip: false
            model: root.items
            spacing: root.cardGap
            leftMargin: root.haloPadding
            rightMargin: root.trailingPadding()
            boundsBehavior: Flickable.StopAtBounds
            // Every arrow key belongs to the surface that owns this row's
            // focus, so the view must not also claim one.
            keyNavigationEnabled: false
            reuseItems: true

            NumberAnimation {
                id: rowScrollSpring
                objectName: "movieRowScrollSpring"
                target: row
                property: "contentX"
                duration: Theme.motionNormal
                easing.type: Easing.OutCubic
            }

            delegate: PosterCard {
                required property string mediaId
                required property int index

                width: root.cardWidth
                height: root.cardHeight
                selected: root.focusedIndex === index

                onActivated: root.activated(mediaId)
            }

            // A recomposed row keeps the remote's column but not its old
            // content extent, so the placement is taken again without motion.
            onCountChanged: root.scrollToFocusedCard(false)
        }
    }
}
