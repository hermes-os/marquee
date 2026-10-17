import QtQuick
import Marquee 3.0

// Marquee/SharedViews/ShowCardRow.swift: one row of show cards under a title
// and a "N shows" count. The geometry is MediaItemRow's, because
// ShowCardRow.swift:59-68 sizes its cards and gap exactly as MovieCardRow
// does; only the card's contents differ (ShowCard.swift:16-29).
Item {
    id: root

    required property string rowTitle
    required property var shows
    required property int totalCount
    property int focusedIndex: -1
    property bool leanBack: appController.settings.leanBackMode
    property bool reduceMotion: appController.settings.reduceMotion
    // ShowDetailView.swift:723-729: the related row draws narrower cards under
    // its own section header.
    property bool headerVisible: true
    property real cardWidth: Theme.posterCardWidth(root.leanBack)

    signal activated(string showName)

    readonly property real haloPadding: Theme.posterFocusHaloPadding(root.leanBack)
    readonly property real cardGap: Theme.cardGap(root.leanBack)
    readonly property real cardStride: root.cardWidth + root.cardGap
    readonly property real cardHeight: Theme.posterFrameTopPadding(root.leanBack)
        + root.cardWidth / Theme.posterAspect
        + Theme.scaled(6, 10, root.leanBack)
        + Theme.posterLabelHeight(root.leanBack)
        + 2 * root.haloPadding

    implicitHeight: (root.headerVisible ? header.height + Theme.rowHeaderToContent : 0)
                    + root.cardHeight

    // ArrowedScrollRow.swift:49-51 and :174 keep the focused card centred
    // within the slots that fit, the same placement MediaItemRow.qml derives.
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

    function visibleSlotCount() {
        if (root.cardStride <= 0) {
            return 1
        }
        const usable = Math.max(0, viewport.width - 2 * root.haloPadding)
        return Math.max(1, Math.floor((usable + root.cardGap) / root.cardStride))
    }

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

    function scrollToFocusedCard(animated) {
        const offset = root.focusOffset(root.focusedIndex)
        if (offset < 0) {
            return
        }
        const target = offset - row.leftMargin
        rowScrollSpring.stop()
        if (!animated || root.reduceMotion) {
            row.contentX = target
            return
        }
        rowScrollSpring.from = row.contentX
        rowScrollSpring.to = target
        rowScrollSpring.start()
    }

    onFocusedIndexChanged: root.scrollToFocusedCard(true)

    function reconcilePlacement() {
        row.forceLayout()
        root.scrollToFocusedCard(false)
    }

    onCardStrideChanged: Qt.callLater(root.reconcilePlacement)
    onHaloPaddingChanged: Qt.callLater(root.reconcilePlacement)

    Item {
        id: header
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        height: root.headerVisible ? rowTitleText.height : 0
        visible: root.headerVisible

        // ShowCardRow.swift:70-78.
        Text {
            id: rowTitleText
            objectName: "showRowTitle"
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

        Text {
            id: rowCountText
            objectName: "showRowCount"
            anchors.right: parent.right
            anchors.baseline: rowTitleText.baseline
            text: root.totalCount === 1
                ? qsTr("%1 show").arg(root.totalCount)
                : qsTr("%1 shows").arg(root.totalCount)
            color: Theme.textTertiary
            font.pixelSize: Theme.rowCountSize(root.leanBack)
            font.weight: Font.Medium
        }
    }

    Item {
        id: viewport
        objectName: "showRowViewport"
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: -root.haloPadding
        anchors.rightMargin: -root.haloPadding
        anchors.top: header.bottom
        anchors.topMargin: root.headerVisible ? Theme.rowHeaderToContent : 0
        height: root.cardHeight
        clip: true
        onWidthChanged: Qt.callLater(root.reconcilePlacement)

        ListView {
            id: row
            objectName: "showRow"
            anchors.fill: parent
            orientation: ListView.Horizontal
            clip: false
            model: root.shows
            spacing: root.cardGap
            leftMargin: root.haloPadding
            rightMargin: root.trailingPadding()
            boundsBehavior: Flickable.StopAtBounds
            keyNavigationEnabled: false
            reuseItems: true

            NumberAnimation {
                id: rowScrollSpring
                objectName: "showRowScrollSpring"
                target: row
                property: "contentX"
                duration: Theme.motionNormal
                easing.type: Easing.OutCubic
            }

            // ShowCard.swift:16-29: the season count is both the primary line
            // and the fallback badge, the up-next label is the highlight line,
            // and the fallback symbol is `tv.fill`.
            // `posterUrl` binds from the role of the same name.
            delegate: PosterCard {
                required property string showName
                required property string seasonLabel
                required property string upNextLabel
                required property int index
                width: root.cardWidth
                height: root.cardHeight
                title: showName
                year: 0
                metadata: seasonLabel
                formatBadge: seasonLabel
                highlightMetadata: upNextLabel
                fallbackSymbol: "tv.fill"
                selected: root.focusedIndex === index
                onActivated: root.activated(showName)
            }

            onCountChanged: root.scrollToFocusedCard(false)
        }
    }
}
