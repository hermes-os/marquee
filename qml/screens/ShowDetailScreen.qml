import QtQuick
import QtQuick.Effects
import Marquee 3.0

// Marquee/Features/Library/Views/ShowDetailView.swift: one show. The backdrop
// hero with the title, the year / seasons / episodes line, the genre tags and
// the Start From Beginning / Continue actions, with the poster preview at the
// trailing edge; then the season tabs, the episode rows of the selected
// season, and More Like This. The remote walks Back, the actions, the season
// stepper, the rows, and the related row (DetailFocusEngine.swift:430-520).
FocusScope {
    id: root

    required property string showName
    property bool leanBack: appController.settings.leanBackMode
    property bool kidsMode: appController.kidsMode
    property bool reduceMotion: appController.settings.reduceMotion

    signal requestSidebarFocus()

    readonly property var shows: appController.shows
    property var details: ({})
    property int selectedSeason: 0
    property var episodes: []
    property var similar: null

    // ShowDetailView.swift:829-831.
    readonly property color focusAccent: root.kidsMode ? Theme.kidsAccent : Theme.accentPrimary
    readonly property color pageBackground: root.kidsMode ? Theme.kidsBackground : Theme.background
    // ShowDetailView.swift:79-89.
    readonly property real heroHeight: Theme.scaled(350, 500, root.leanBack)
    readonly property real heroPosterWidth: Theme.scaled(132, 200, root.leanBack)
    readonly property real heroPosterHeight: root.heroPosterWidth * 1.5
    readonly property real outerPadding: Theme.outerPadding(root.leanBack)
    // DetailBackChromeLayout (RemoteGridFocus.swift:2842-2854).
    readonly property real backButtonSize: Theme.scaled(32, 48, root.leanBack)
    readonly property real backLeadingPadding: Theme.scaled(12, 14, root.leanBack)

    readonly property var seasons: root.details.seasons !== undefined ? root.details.seasons : []
    readonly property bool hasEpisodes: root.details.firstEpisodeId !== undefined
                                        && root.details.firstEpisodeId.length > 0
    readonly property bool showsContinue: root.details.showsContinue === true
    readonly property bool hasSeasonStepper: root.seasons.length > 1
    readonly property int similarCount: root.similar !== null ? root.similar.rowCount() : 0

    // The focus tree, flattened: "back", "start", "continue", "seasons",
    // "episode", "more". Row members carry their own index.
    property string focusNode: "start"
    property int focusedEpisode: 0
    property int focusedMore: 0

    focus: true

    function reload() {
        root.details = root.shows.showDetails(root.showName)
        const seasons = root.details.seasons !== undefined ? root.details.seasons : []
        if (seasons.length === 0) {
            root.selectedSeason = 0
        } else if (seasons.indexOf(root.selectedSeason) < 0) {
            // ShowDetailView.swift:118-127: the season holding up-next opens
            // first; otherwise the lowest one.
            const upNextSeason = root.details.upNextSeason !== undefined ? root.details.upNextSeason : 0
            root.selectedSeason = seasons.indexOf(upNextSeason) >= 0 ? upNextSeason : seasons[0]
        }
        root.reloadEpisodes()
        if (root.similar !== null) {
            root.similar.destroy()
        }
        root.similar = root.shows.similarShows(root.showName, 10)
        root.reconcileFocus()
    }

    function reloadEpisodes() {
        // A new model sends the list back to its start, where the page used
        // to stay put when its rows were replaced; keep the offset (clamped
        // to the new length) and let the focus placement correct it.
        const keptOffset = scroll.count > 0 ? scroll.contentY : Number.NaN
        root.episodes = root.selectedSeason > 0
            ? root.shows.episodesOf(root.showName, root.selectedSeason)
            : []
        // A new model sets the view's current item back to 0 and the view
        // keeps that item built, whatever the scroll.
        scroll.currentIndex = -1
        if (root.focusedEpisode >= root.episodes.length) {
            root.focusedEpisode = Math.max(0, root.episodes.length - 1)
        }
        if (!isNaN(keptOffset)) {
            scroll.contentY = Math.max(scroll.originY,
                                       Math.min(keptOffset, scroll.originY + scroll.contentHeight - scroll.height))
        }
        root.placeFocus(false)
    }

    // ShowDetailView.swift:1097-1120.
    function firstAvailableFocus() {
        if (root.hasEpisodes) {
            return "start"
        }
        if (root.hasSeasonStepper) {
            return "seasons"
        }
        if (root.episodes.length > 0) {
            return "episode"
        }
        if (root.similarCount > 0) {
            return "more"
        }
        return "back"
    }

    function reconcileFocus() {
        const node = root.focusNode
        const valid = node === "back"
            || (node === "start" && root.hasEpisodes)
            || (node === "continue" && root.showsContinue)
            || (node === "seasons" && root.hasSeasonStepper)
            || (node === "episode" && root.episodes.length > 0)
            || (node === "more" && root.similarCount > 0)
        if (!valid) {
            root.focusNode = root.firstAvailableFocus()
        }
        root.focusedEpisode = Math.min(root.focusedEpisode, Math.max(0, root.episodes.length - 1))
        root.focusedMore = Math.min(root.focusedMore, Math.max(0, root.similarCount - 1))
    }

    // ShowDetailView.swift:600-602, :920-921: a season change forgets the
    // remembered episode.
    function selectSeason(season) {
        if (season === root.selectedSeason) {
            return
        }
        root.selectedSeason = season
        root.focusedEpisode = 0
        root.reloadEpisodes()
    }

    function stepSeason(delta) {
        const index = root.seasons.indexOf(root.selectedSeason)
        const next = index + delta
        if (next < 0 || next >= root.seasons.length) {
            return false
        }
        root.selectSeason(root.seasons[next])
        return true
    }

    function playEpisode(mediaId, fromStart) {
        if (mediaId === undefined || mediaId.length === 0) {
            return
        }
        Qt.callLater(appController.playMediaId, mediaId, fromStart === true)
    }

    // ShowDetailView.swift:879-909.
    function activateFocus() {
        switch (root.focusNode) {
        case "back":
            appController.navigation.goBack()
            return
        case "start":
            root.playEpisode(root.details.firstEpisodeId, true)
            return
        case "continue":
            root.playEpisode(root.details.upNextId, false)
            return
        case "episode":
            if (root.focusedEpisode < root.episodes.length) {
                root.playEpisode(root.episodes[root.focusedEpisode].mediaId, false)
            }
            return
        case "more":
            if (root.similar !== null && root.focusedMore < root.similarCount) {
                Qt.callLater(appController.navigation.openShowDetail,
                             root.similar.showNameAt(root.focusedMore))
            }
            return
        }
    }

    // The tree from DetailFocusEngine.swift:430-520: back above the action
    // row, the actions above the season stepper, then the episodes, then the
    // related row. Left at the leftmost member hands off to the sidebar.
    function moveFocus(direction) {
        const node = root.focusNode
        const order = []
        if (root.hasEpisodes) {
            order.push("actions")
        }
        if (root.hasSeasonStepper) {
            order.push("seasons")
        }
        if (root.episodes.length > 0) {
            order.push("episode")
        }
        if (root.similarCount > 0) {
            order.push("more")
        }
        const section = node === "start" || node === "continue" ? "actions" : node
        const sectionIndex = order.indexOf(section)

        if (direction === "up") {
            if (node === "back") {
                return true
            }
            // Within the episode list a step stays inside it until the top.
            if (node === "episode" && root.focusedEpisode > 0) {
                root.focusedEpisode -= 1
                return true
            }
            if (sectionIndex > 0) {
                root.enterSection(order[sectionIndex - 1], "up")
            } else {
                root.focusNode = "back"
            }
            return true
        }
        if (direction === "down") {
            if (node === "back") {
                if (order.length > 0) {
                    root.enterSection(order[0], "down")
                }
                return true
            }
            if (node === "episode" && root.focusedEpisode + 1 < root.episodes.length) {
                root.focusedEpisode += 1
                return true
            }
            if (sectionIndex >= 0 && sectionIndex + 1 < order.length) {
                root.enterSection(order[sectionIndex + 1], "down")
            }
            return true
        }
        if (direction === "right") {
            if (node === "start" && root.showsContinue) {
                root.focusNode = "continue"
            } else if (node === "seasons") {
                root.stepSeason(1)
            } else if (node === "more" && root.focusedMore + 1 < root.similarCount) {
                root.focusedMore += 1
            }
            return true
        }
        // left
        if (node === "continue") {
            root.focusNode = "start"
            return true
        }
        if (node === "seasons") {
            root.stepSeason(-1)
            return true
        }
        if (node === "more" && root.focusedMore > 0) {
            root.focusedMore -= 1
            return true
        }
        return false
    }

    function enterSection(section, direction) {
        switch (section) {
        case "actions":
            root.focusNode = "start"
            return
        case "seasons":
            root.focusNode = "seasons"
            return
        case "episode":
            // ShowDetailView.swift:1145-1152: entering the rows from above
            // lands on the first row; from below, the last.
            root.moveFocusTo("episode", direction === "down" ? 0 : root.episodes.length - 1)
            return
        case "more":
            root.focusNode = "more"
            return
        }
    }

    // A Home card for an episode opens this page at that episode: its season
    // is selected and the remote starts on its row. The request is spent by
    // the first page that asks, whichever show it was meant for.
    function landOnRequestedEpisode() {
        const request = root.shows.takeEpisodeFocus(root.showName)
        if (request.mediaId === undefined) {
            return
        }
        root.selectSeason(request.season)
        for (let index = 0; index < root.episodes.length; ++index) {
            if (root.episodes[index].mediaId === request.mediaId) {
                root.moveFocusTo("episode", index)
                return
            }
        }
    }

    Component.onCompleted: {
        root.reload()
        root.landOnRequestedEpisode()
    }
    onShowNameChanged: {
        root.focusNode = "start"
        root.focusedEpisode = 0
        root.focusedMore = 0
        root.reload()
        root.landOnRequestedEpisode()
    }
    Component.onDestruction: {
        if (root.similar !== null) {
            root.similar.destroy()
        }
    }

    Connections {
        target: root.shows
        function onShowProgressChanged(showName) {
            if (showName === root.showName) {
                root.reload()
            }
        }
        function onShowsChanged() { root.reload() }
    }

    Rectangle {
        anchors.fill: parent
        color: root.pageBackground
    }

    // The whole page is one list: the hero and the season picker are its
    // header, the episodes are its rows, and More Like This is its footer.
    // One scroll authority keeps the focus placement below simple, and the
    // list builds only the rows near the viewport, so a season of hundreds
    // holds a handful of rows (and their shadow effects) in memory, not all.
    ListView {
        id: scroll
        objectName: "showDetailScroll"
        anchors.fill: parent
        model: root.episodes
        spacing: Theme.scaled(4, 8, root.leanBack)
        boundsBehavior: Flickable.StopAtBounds
        clip: true
        reuseItems: true
        cacheBuffer: Math.round(height * 0.5)
        // The page owns the remote; the list must not step its own current
        // item on the arrows.
        keyNavigationEnabled: false
        // The view keeps its current item built wherever it scrolls; the
        // page tracks the focused row itself, so the view has none.
        currentIndex: -1

        NumberAnimation {
            id: scrollSpring
            target: scroll
            property: "contentY"
            duration: Theme.motionNormal
            easing.type: Easing.OutCubic
        }

        // The rows are the content item's children; this name is how the
        // page's tests and tooling find them.
        Component.onCompleted: scroll.contentItem.objectName = "showDetailEpisodes"

        // A placement asked for before the list had a size or its header
        // and footer is made as soon as it has them.
        onHeightChanged: if (root.placePending) root.placeFocus(false)
        onHeaderItemChanged: if (root.placePending) root.placeFocus(false)
        onFooterItemChanged: if (root.placePending) root.placeFocus(false)

        // ShowDetailView.swift:686-716: the rows sit outerPadding in from
        // both edges. The view owns a row's x, so the inset lives in the row's
        // slot, which spans the page.
        delegate: Item {
            id: slot
            required property var modelData
            required property int index
            objectName: "showDetailEpisode_" + index
            width: scroll.width
            height: row.height
            // The focused row's lift and glow reach over the rows after it.
            z: row.focused ? 1 : 0
            // What the page's tests and tooling read from a row.
            readonly property alias focused: row.focused
            readonly property alias hovered: row.hovered

            EpisodeRow {
                id: row
                x: root.outerPadding
                width: slot.width - 2 * root.outerPadding
                episode: slot.modelData
                focused: root.activeFocus && root.focusNode === "episode"
                         && root.focusedEpisode === slot.index
                onPlay: root.playEpisode(slot.modelData.mediaId, false)
            }

            // A pooled slot keeps its last index; without a name it cannot be
            // mistaken for a row that is still on the page.
            ListView.onPooled: objectName = ""
            // A row scrolled out mid-fade comes back for another episode;
            // it must not carry the old episode's scale or colour fade.
            ListView.onReused: {
                objectName = Qt.binding(() => "showDetailEpisode_" + slot.index)
                row.settle()
            }
        }

        header: Column {
            id: pageHeader
            width: scroll.width
            property alias seasonPickerItem: seasonPicker

            // ShowDetailView.swift:231-311.
            Item {
                id: hero
                objectName: "showDetailHero"
                width: pageHeader.width
                height: root.heroHeight
                clip: true

                // ShowDetailView.swift:313-352: the fallback is the poster,
                // blown up and blurred, under a leading-to-trailing scrim.
                // :315-322 runs topLeading to bottomTrailing. Rectangle
                // gradients are axis-aligned, so the diagonal uses a Canvas.
                Canvas {
                    objectName: "showDetailHeroFallbackGradient"
                    anchors.fill: parent
                    renderTarget: Canvas.Image
                    renderStrategy: Canvas.Immediate
                    property color stopStart: Theme.surfaceElevated
                    property color stopEnd: root.pageBackground
                    onStopStartChanged: requestPaint()
                    onStopEndChanged: requestPaint()
                    onPaint: {
                        const context = getContext("2d")
                        context.reset()
                        const fill = context.createLinearGradient(0, 0, width, height)
                        fill.addColorStop(0, String(stopStart))
                        fill.addColorStop(1, String(stopEnd))
                        context.fillStyle = fill
                        context.fillRect(0, 0, width, height)
                    }
                    onWidthChanged: requestPaint()
                    onHeightChanged: requestPaint()
                    Component.onCompleted: requestPaint()
                }

                Image {
                    id: heroPosterFallback
                    anchors.centerIn: parent
                    width: parent.width * 1.34
                    height: parent.height * 1.34
                    source: root.details.posterUrl !== undefined ? root.details.posterUrl : ""
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    visible: false
                    sourceSize.width: 600
                }
                // ShowDetailView.swift:334-338: scaled 1.34, blurred 14,
                // saturation 1.16, contrast 1.08, at 0.58. MultiEffect's
                // blur is the fraction of blurMax applied (effective pixel
                // radius = blur * blurMax), so the oracle's 14-point
                // radius is blur 0.4375 at blurMax 32.
                MultiEffect {
                    anchors.fill: heroPosterFallback
                    source: heroPosterFallback
                    visible: heroPosterFallback.status === Image.Ready && !heroBackdrop.visible
                    opacity: 0.58
                    blurEnabled: true
                    blur: 0.4375
                    blurMax: 32
                    saturation: 0.16
                    contrast: 0.08
                }
                Rectangle {
                    anchors.fill: parent
                    visible: heroPosterFallback.visible
                    gradient: Gradient {
                        orientation: Gradient.Horizontal
                        GradientStop { position: 0.0; color: Qt.rgba(0, 0, 0, 0.18) }
                        GradientStop { position: 0.5; color: Qt.rgba(0, 0, 0, 0.34) }
                        GradientStop {
                            position: 1.0
                            color: Qt.rgba(root.pageBackground.r, root.pageBackground.g,
                                           root.pageBackground.b, 0.78)
                        }
                    }
                }

                Image {
                    id: heroBackdrop
                    anchors.fill: parent
                    source: root.details.backdropUrl !== undefined ? root.details.backdropUrl : ""
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    visible: status === Image.Ready
                    sourceSize.width: 1920
                }

                // ShowDetailView.swift:248-256.
                Rectangle {
                    anchors.fill: parent
                    gradient: Gradient {
                        orientation: Gradient.Vertical
                        GradientStop { position: 0.0; color: "transparent" }
                        GradientStop {
                            position: 0.5
                            color: Qt.rgba(root.pageBackground.r, root.pageBackground.g,
                                           root.pageBackground.b, 0.6)
                        }
                        GradientStop { position: 1.0; color: root.pageBackground }
                    }
                }

                // ShowDetailView.swift:258-307.
                Item {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    anchors.margins: root.outerPadding
                    anchors.bottomMargin: root.outerPadding + Theme.scaled(8, 16, root.leanBack)
                    height: Math.max(heroText.height, heroPoster.visible ? heroPoster.height : 0)

                    Column {
                        id: heroText
                        anchors.left: parent.left
                        anchors.bottom: parent.bottom
                        width: Math.min(parent.width - (heroPoster.visible ? heroPoster.width
                                        + Theme.scaled(28, 42, root.leanBack) : 0),
                                        Theme.scaled(760, 1040, root.leanBack))
                        spacing: 8

                        Text {
                            objectName: "showDetailTitle"
                            width: parent.width
                            text: root.showName
                            color: Theme.textPrimary
                            font.pixelSize: Theme.scaled(32, 46, root.leanBack)
                            font.weight: Font.Bold
                            wrapMode: Text.Wrap
                            maximumLineCount: 2
                            elide: Text.ElideRight
                        }

                        // ShowDetailView.swift:265-294.
                        Row {
                            objectName: "showDetailFacts"
                            spacing: Theme.scaled(10, 15, root.leanBack)
                            Text {
                                visible: root.details.year !== undefined && root.details.year > 0
                                text: root.details.year !== undefined ? String(root.details.year) : ""
                                color: Theme.textSecondary
                                font.pixelSize: Theme.scaled(13, 18, root.leanBack)
                                font.weight: Font.Medium
                            }
                            Text {
                                text: root.seasons.length === 1
                                    ? qsTr("1 Season")
                                    : qsTr("%1 Seasons").arg(root.seasons.length)
                                color: Theme.textSecondary
                                font.pixelSize: Theme.scaled(13, 18, root.leanBack)
                                font.weight: Font.Medium
                            }
                            Text {
                                text: qsTr("%1 Episodes").arg(
                                    root.details.episodeCount !== undefined ? root.details.episodeCount : 0)
                                color: Theme.textSecondary
                                font.pixelSize: Theme.scaled(13, 18, root.leanBack)
                                font.weight: Font.Medium
                            }
                        }

                        // ShowDetailView.swift:444-461.
                        Row {
                            objectName: "showDetailGenres"
                            visible: root.details.genres !== undefined && root.details.genres.length > 0
                            spacing: Theme.scaled(6, 10, root.leanBack)
                            Repeater {
                                model: root.details.genres !== undefined
                                    ? root.details.genres.slice(0, 4) : []
                                delegate: Rectangle {
                                    required property string modelData
                                    width: genreText.width + 2 * Theme.scaled(10, 14, root.leanBack)
                                    height: genreText.height + 2 * Theme.scaled(4, 7, root.leanBack)
                                    radius: height / 2
                                    color: Theme.surfaceLayer
                                    Text {
                                        id: genreText
                                        anchors.centerIn: parent
                                        text: modelData
                                        color: Theme.textSecondary
                                        font.pixelSize: Theme.scaled(11, 16, root.leanBack)
                                        font.weight: Font.Medium
                                    }
                                }
                            }
                        }

                        // ShowDetailView.swift:391-440.
                        Row {
                            id: actions
                            objectName: "showDetailActions"
                            visible: root.hasEpisodes
                            spacing: Theme.scaled(10, 15, root.leanBack)
                            topPadding: Theme.scaled(4, 8, root.leanBack)

                            DetailCapsuleButton {
                                objectName: "showDetailStart"
                                label: qsTr("Start From Beginning")
                                glyph: "backward.end.fill"
                                fill: Theme.accentPrimary
                                textColor: "#ffffff"
                                leanBack: root.leanBack
                                focused: root.activeFocus && root.focusNode === "start"
                                focusAccent: root.focusAccent
                                onActivated: root.playEpisode(root.details.firstEpisodeId, true)
                            }

                            DetailCapsuleButton {
                                objectName: "showDetailContinue"
                                visible: root.showsContinue
                                label: root.details.continueLabel !== undefined
                                    ? root.details.continueLabel : ""
                                glyph: "play.fill"
                                fill: Theme.surfaceLayer
                                textColor: Theme.textPrimary
                                leanBack: root.leanBack
                                focused: root.activeFocus && root.focusNode === "continue"
                                focusAccent: root.focusAccent
                                onActivated: root.playEpisode(root.details.upNextId, false)
                            }
                        }
                    }

                    // ShowDetailView.swift:354-389.
                    Item {
                        id: heroPoster
                        objectName: "showDetailPosterPreview"
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        width: root.heroPosterWidth
                        height: root.heroPosterHeight
                        visible: posterImage.status === Image.Ready

                        SoftShadow {
                            anchors.fill: parent
                            radius: Theme.radiusMD
                            shadowColor: Qt.rgba(0, 0, 0, 0.45)
                            blur: 22
                            offsetY: 14
                        }

                        Rectangle {
                            anchors.fill: parent
                            radius: Theme.radiusMD
                            color: Theme.surfaceLayer
                            border.width: 1
                            border.color: Qt.rgba(1, 1, 1, 0.12)
                            clip: true

                            Image {
                                id: posterImage
                                anchors.fill: parent
                                source: root.details.posterUrl !== undefined ? root.details.posterUrl : ""
                                fillMode: Image.PreserveAspectCrop
                                asynchronous: true
                                sourceSize.width: 400
                            }

                            // ShowDetailView.swift:370-379: "3S" in monospace.
                            Rectangle {
                                anchors.left: parent.left
                                anchors.bottom: parent.bottom
                                anchors.margins: Theme.scaled(8, 12, root.leanBack)
                                width: seasonBadge.width + 2 * Theme.scaled(8, 12, root.leanBack)
                                height: seasonBadge.height + 2 * Theme.scaled(4, 6, root.leanBack)
                                radius: height / 2
                                color: Qt.rgba(0, 0, 0, 0.58)
                                Text {
                                    id: seasonBadge
                                    anchors.centerIn: parent
                                    text: root.seasons.length + "S"
                                    color: Theme.textPrimary
                                    font.pixelSize: Theme.scaled(10, 14, root.leanBack)
                                    font.weight: Font.Bold
                                    font.family: "monospace"
                                }
                            }
                        }
                    }
                }
            }

            // ShowDetailView.swift:584-636: season tabs when there are two to
            // six; the dropdown beyond that renders as the same stepper
            // capsule here, because the remote steps it either way.
            Item {
                id: seasonPicker
                objectName: "showDetailSeasons"
                width: pageHeader.width
                visible: root.hasSeasonStepper
                height: visible ? seasonTabs.height + 2 * Theme.scaled(16, 26, root.leanBack) : 0

                Rectangle {
                    anchors.fill: parent
                    anchors.leftMargin: root.outerPadding - Theme.scaled(12, 18, root.leanBack)
                    anchors.rightMargin: root.outerPadding - Theme.scaled(12, 18, root.leanBack)
                    radius: Theme.radiusMD
                    color: Theme.surfaceElevated
                    opacity: root.activeFocus && root.focusNode === "seasons" ? 0.45 : 0
                }
                FocusFrame {
                    anchors.fill: parent
                    anchors.leftMargin: root.outerPadding - Theme.scaled(12, 18, root.leanBack)
                    anchors.rightMargin: root.outerPadding - Theme.scaled(12, 18, root.leanBack)
                    active: root.activeFocus && root.focusNode === "seasons"
                    // ShowDetailView.swift:622-628 fills the picker only while
                    // focused; a clear surface casts no resting shadow.
                    idleShadowOpacity: 0
                    radius: Theme.radiusMD
                    accent: root.focusAccent
                    focusScale: Theme.detailFocusScale
                    ringWidth: Theme.detailRingLineWidth
                    focusedShadowRadius: Theme.detailGlowRadius
                }

                Row {
                    id: seasonTabs
                    anchors.left: parent.left
                    anchors.leftMargin: root.outerPadding
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.scaled(4, 8, root.leanBack)

                    Repeater {
                        model: root.seasons.length <= 6 ? root.seasons : [root.selectedSeason]
                        delegate: Rectangle {
                            required property int modelData
                            readonly property bool selected: modelData === root.selectedSeason
                            width: seasonText.width + 2 * Theme.scaled(16, 24, root.leanBack)
                            height: seasonText.height + 2 * Theme.scaled(8, 13, root.leanBack)
                            radius: height / 2
                            color: selected ? Theme.accentPrimary : Theme.surfaceElevated
                            Text {
                                id: seasonText
                                anchors.centerIn: parent
                                text: qsTr("Season %1").arg(modelData)
                                color: selected ? "#ffffff" : Theme.textSecondary
                                font.pixelSize: Theme.scaled(13, 18, root.leanBack)
                                font.weight: selected ? Font.DemiBold : Font.Normal
                            }
                            TapHandler { onTapped: root.selectSeason(modelData) }
                        }
                    }
                }
            }

            // ShowDetailView.swift:686-716: the rows start below the picker, or
            // below a gap when there is no picker.
            Item {
                width: pageHeader.width
                height: root.hasSeasonStepper ? 0 : Theme.scaled(16, 26, root.leanBack)
            }
        }

        footer: Column {
            id: pageFooter
            width: scroll.width
            property alias moreLikeItem: moreLikeRow

            // The rows' bottom padding.
            Item {
                width: pageFooter.width
                height: Theme.scaled(28, 42, root.leanBack)
            }

            // ShowDetailView.swift:720-766.
            Column {
                objectName: "showDetailMoreLikeThis"
                width: pageFooter.width
                visible: root.similarCount > 0
                leftPadding: root.outerPadding
                rightPadding: root.outerPadding
                topPadding: Theme.scaled(8, 12, root.leanBack)
                bottomPadding: Theme.scaled(100, 150, root.leanBack)
                spacing: Theme.scaled(16, 22, root.leanBack)

                Text {
                    objectName: "showDetailMoreLikeThisHeader"
                    text: root.kidsMode ? qsTr("More Like This") : qsTr("MORE LIKE THIS")
                    color: root.kidsMode ? Theme.kidsAccent : Theme.textSecondary
                    font.pixelSize: root.kidsMode ? Theme.scaled(14, 20, root.leanBack)
                                                  : Theme.scaled(11, 16, root.leanBack)
                    font.weight: Font.Bold
                    font.letterSpacing: root.kidsMode ? 0 : 1.5
                }

                ShowCardRow {
                    id: moreLikeRow
                    width: pageFooter.width - 2 * root.outerPadding
                    height: implicitHeight
                    rowTitle: ""
                    shows: root.similar
                    totalCount: root.similarCount
                    headerVisible: false
                    cardWidth: Theme.scaled(120, 180, root.leanBack)
                    focusedIndex: root.activeFocus && root.focusNode === "more" ? root.focusedMore : -1
                    onActivated: showName => Qt.callLater(appController.navigation.openShowDetail, showName)
                }
            }
        }
    }

    // ShowDetailView.swift:199-227.
    Item {
        id: backButton
        objectName: "showDetailBack"
        x: root.backLeadingPadding
        y: Theme.scaled(16, 26, root.leanBack)
        width: root.backButtonSize
        height: root.backButtonSize
        z: 2

        FocusFrame {
            anchors.fill: parent
            active: root.activeFocus && root.focusNode === "back"
            radius: width / 2
            accent: root.focusAccent
            focusScale: Theme.detailFocusScale
            ringWidth: Theme.detailRingLineWidth
            focusedShadowRadius: Theme.detailGlowRadius
        }

        Rectangle {
            anchors.fill: parent
            radius: width / 2
            color: Qt.rgba(0, 0, 0, 0.78)
            border.width: 1
            border.color: Qt.rgba(1, 1, 1, 0.12)
        }

        // `chevron.left` at 14/22, semibold.
        Canvas {
            anchors.centerIn: parent
            width: Theme.scaled(14, 22, root.leanBack) * 0.6
            height: Theme.scaled(14, 22, root.leanBack)
            onPaint: {
                const context = getContext("2d")
                context.reset()
                context.clearRect(0, 0, width, height)
                context.strokeStyle = Theme.textPrimary
                context.lineWidth = Math.max(1.5, height * 0.14)
                context.lineCap = "round"
                context.lineJoin = "round"
                context.beginPath()
                context.moveTo(width * 0.85, height * 0.1)
                context.lineTo(width * 0.15, height * 0.5)
                context.lineTo(width * 0.85, height * 0.9)
                context.stroke()
            }
            onWidthChanged: requestPaint()
        }

        TapHandler { onTapped: appController.navigation.goBack() }
    }

    // Set when a placement had to wait for the list to have a size.
    property bool placePending: false

    // ShowDetailView.swift:1139-1200 through the placement policies: the
    // focused section is scrolled into a comfortable band. Offsets are in
    // the list's content coordinates, whose top is `originY`.
    function placeFocus(animated) {
        if (scroll.height <= 0 || scroll.headerItem === null || scroll.footerItem === null) {
            root.placePending = true
            return
        }
        root.placePending = false
        const top = scroll.originY
        let target = Number.NaN
        let jump = false
        switch (root.focusNode) {
        case "back":
        case "start":
        case "continue":
            target = top
            break
        case "seasons":
            target = Math.max(top, scroll.headerItem.seasonPickerItem
                                       .mapToItem(scroll.contentItem, 0, 0).y
                                   - Math.round(scroll.height * 0.18))
            break
        case "episode": {
            let item = scroll.itemAtIndex(root.focusedEpisode)
            if (item === null) {
                // The row is not built: bring it in first, then place it
                // against the real geometry. The view has no animation to
                // run across rows that were never on screen.
                scroll.positionViewAtIndex(root.focusedEpisode, ListView.Contain)
                item = scroll.itemAtIndex(root.focusedEpisode)
                if (item === null) {
                    return
                }
                jump = true
            }
            const rowTop = item.y
            const band = Math.round(scroll.height * 0.36)
            if (!jump
                && rowTop - scroll.contentY >= Math.round(scroll.height * 0.12)
                && rowTop + item.height - scroll.contentY <= scroll.height - Math.round(scroll.height * 0.12)) {
                return
            }
            target = Math.max(top, rowTop - band)
            break
        }
        case "more":
            target = Math.max(top, scroll.footerItem.moreLikeItem
                                       .mapToItem(scroll.contentItem, 0, 0).y
                                   - Theme.scaled(36, 54, root.leanBack) * 2)
            break
        }
        if (isNaN(target)) {
            return
        }
        target = Math.min(target, Math.max(top, top + scroll.contentHeight - scroll.height))
        scrollSpring.stop()
        if (!animated || jump || root.reduceMotion) {
            scroll.contentY = target
            return
        }
        scrollSpring.from = scroll.contentY
        scrollSpring.to = target
        scrollSpring.start()
    }

    // A move that sets the node and the row together places once, against
    // both: placing between the two writes would walk the list to a row the
    // move is leaving.
    property bool placementHeld: false
    function moveFocusTo(node, episode) {
        root.placementHeld = true
        root.focusNode = node
        if (episode >= 0) {
            root.focusedEpisode = episode
        }
        root.placementHeld = false
        root.placeFocus(true)
    }

    onFocusNodeChanged: if (!root.placementHeld) root.placeFocus(true)
    onFocusedEpisodeChanged: if (!root.placementHeld) root.placeFocus(true)
    onFocusedMoreChanged: if (!root.placementHeld) root.placeFocus(true)

    Keys.onPressed: event => {
        switch (event.key) {
        case Qt.Key_Left:
            if (!root.moveFocus("left")) {
                root.requestSidebarFocus()
            }
            event.accepted = true
            return
        case Qt.Key_Right:
            root.moveFocus("right")
            event.accepted = true
            return
        case Qt.Key_Up:
            root.moveFocus("up")
            event.accepted = true
            return
        case Qt.Key_Down:
            root.moveFocus("down")
            event.accepted = true
            return
        case Qt.Key_Return:
        case Qt.Key_Enter:
            root.activateFocus()
            event.accepted = true
            return
        default:
            // Escape and Back bubble to the shell, which pops one route
            // (ShowDetailView.swift:199-227's Back does the same one step).
            event.accepted = false
        }
    }
}
