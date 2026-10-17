import QtQuick
import QtQuick.Effects
import Marquee 3.0

// Marquee/Features/Detail/Views/MovieDetailView.swift: one movie. The
// backdrop hero (MovieDetailView.swift:35-45 sizes it 400/560) with the
// fallback treatment, the title, the metadata line, and the poster preview
// at the trailing edge (:184-279); then the gold-gradient Start From
// Beginning and conditional "Resume at <time>" actions under the detail
// focus surface (:390-451); then SYNOPSIS (:455-487), Directed by
// (:492-510), MORE LIKE THIS (:571-611), and FILE INFO (:1105-1138). The
// remote walks Back, the actions, and the related row.
FocusScope {
    id: root
    objectName: "detailsScreen"

    property bool leanBack: appController.settings.leanBackMode
    property bool kidsMode: appController.kidsMode
    property bool reduceMotion: appController.settings.reduceMotion

    readonly property string mediaId: appController.navigation.selectedMediaId
    property var details: ({})
    property var similar: []
    readonly property bool known: details.mediaId !== undefined

    // MovieDetailView.swift:663-665: the focus accent follows the kids
    // profile; the page background does too (:49).
    readonly property color focusAccent: root.kidsMode ? Theme.kidsAccent : Theme.accentPrimary
    readonly property color pageBackground: root.kidsMode ? Theme.kidsBackground : Theme.background
    // MovieDetailView.swift:35-45.
    readonly property real heroHeight: Theme.scaled(400, 560, root.leanBack)
    readonly property real heroPosterWidth: Theme.scaled(138, 210, root.leanBack)
    readonly property real heroPosterHeight: root.heroPosterWidth * 1.5
    readonly property real outerPadding: Theme.outerPadding(root.leanBack)
    // DetailBackChromeLayout (RemoteGridFocus.swift:2842-2859).
    readonly property real backButtonSize: Theme.scaled(32, 48, root.leanBack)
    readonly property real backLeadingPadding: Theme.scaled(12, 14, root.leanBack)
    // DetailRelatedRowLayout (RemoteGridFocus.swift:2569-2576).
    readonly property real relatedTopClearance: Theme.scaled(92, 132, root.leanBack)
    readonly property string resumeLabel: root.details.hasResume === true
        ? qsTr("Resume at %1").arg(root.details.resumeTime) : ""

    // The focus tree, flattened: "back", "start", "continue", "more". The
    // related-row member carries its own index.
    property string focusNode: "start"
    property int focusedMore: 0

    readonly property bool showsResume: root.known && root.details.hasResume === true
    readonly property int similarCount: root.similar.length

    focus: true

    // Every scan replaces the projection wholesale, so the facts are read again
    // when the catalog publishes a new one rather than held from the moment
    // this surface opened.
    Connections {
        target: appController.library
        function onModelReset() { root.reload() }
    }
    // The persisted resume point is answered back through the same queued
    // projection connection a scan uses, so the open surface re-reads its
    // facts on data changes exactly as it does for a rescan.
    Connections {
        target: appController.library
        function onDataChanged() { root.reload() }
    }
    Connections {
        target: appController
        function onCatalogProgressPersisted(mediaId) {
            if (mediaId === root.mediaId) {
                root.reload()
            }
        }
    }

    onMediaIdChanged: {
        root.focusNode = "start"
        root.focusedMore = 0
        root.reload()
    }

    function reload() {
        root.details = appController.library.detailsForId(root.mediaId)
        root.similar = appController.library.similarMovies(root.mediaId, 10)
        root.reconcileFocus()
    }

    function firstAvailableFocus() {
        if (root.similarCount > 0) {
            return "start"
        }
        return "start"
    }

    function reconcileFocus() {
        if (root.focusNode === "continue" && !root.showsResume) {
            root.focusNode = "start"
        } else if (root.focusNode === "more" && root.similarCount === 0) {
            root.focusNode = "start"
        } else if (root.focusNode !== "back" && root.focusNode !== "start"
                   && root.focusNode !== "continue" && root.focusNode !== "more") {
            root.focusNode = "start"
        }
        root.focusedMore = Math.min(root.focusedMore, Math.max(0, root.similarCount - 1))
    }

    function activateFocus() {
        switch (root.focusNode) {
        case "back":
            appController.navigation.goBack()
            return
        case "start":
            root.playFromStart()
            return
        case "continue":
            root.playResume()
            return
        case "more":
            if (root.focusedMore < root.similarCount) {
                Qt.callLater(appController.showMediaDetails,
                             root.similar[root.focusedMore].mediaId)
            }
            return
        }
    }

    // MovieDetailView.swift:694-740's tree: Back above the action row, the
    // actions above the related row. Left at the leftmost member hands off to
    // the sidebar.
    signal requestSidebarFocus()

    function moveFocus(direction) {
        const node = root.focusNode
        const order = ["actions"]
        if (root.similarCount > 0) {
            order.push("more")
        }
        const section = node === "start" || node === "continue" ? "actions" : node
        const sectionIndex = order.indexOf(section)

        if (direction === "up") {
            if (node === "back") {
                return true
            }
            if (node === "more" && root.focusedMore > 0) {
                // Within the related row a step stays inside it until the top.
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
            if (sectionIndex >= 0 && sectionIndex + 1 < order.length) {
                root.enterSection(order[sectionIndex + 1], "down")
            }
            return true
        }
        if (direction === "right") {
            if (node === "start" && root.showsResume) {
                root.focusNode = "continue"
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
        case "more":
            root.focusNode = "more"
            root.focusedMore = direction === "down" ? 0 : root.similarCount - 1
            return
        }
    }

    Component.onCompleted: {
        root.reload()
        forceActiveFocus()
    }

    function metadataLine() {
        if (!root.known) {
            return ""
        }
        var parts = []
        if (root.details.year > 0) {
            parts.push(String(root.details.year))
        }
        if (root.details.runtime !== undefined && String(root.details.runtime).length > 0) {
            parts.push(String(root.details.runtime))
        }
        if (root.details.formatBadge.length > 0) {
            parts.push(root.details.formatBadge)
        }
        return parts.join(" · ")
    }

    function playFromStart() {
        if (!root.known) {
            return
        }
        // Opening the player replaces this screen, so the activation has to run
        // after the key or pointer delivery that is still unwinding through it.
        Qt.callLater(appController.playMediaId, root.details.mediaId, true)
    }

    function playResume() {
        if (!root.known) {
            return
        }
        Qt.callLater(appController.playMediaId, root.details.mediaId, false)
    }

    Rectangle {
        anchors.fill: parent
        color: root.pageBackground
    }

    Text {
        objectName: "detailsMissingState"
        anchors.centerIn: parent
        width: Math.min(parent.width * 0.6, 640)
        visible: !root.known

        text: qsTr("This title is no longer in the library.")
        color: Theme.textSecondary
        font.pixelSize: Theme.scaled(17, 22, root.leanBack)
        wrapMode: Text.Wrap
        horizontalAlignment: Text.AlignHCenter
    }

    Flickable {
        id: scroll
        objectName: "detailsScroll"
        anchors.fill: parent
        visible: root.known
        contentWidth: width
        contentHeight: pageColumn.height
        boundsBehavior: Flickable.StopAtBounds
        clip: true

        NumberAnimation {
            id: scrollSpring
            target: scroll
            property: "contentY"
            duration: Theme.motionNormal
            easing.type: Easing.OutCubic
        }

        Item {
            id: pageColumn
            width: scroll.width
            height: hero.height + contentColumn.height

            // MovieDetailView.swift:186-218.
            Item {
                id: hero
                objectName: "detailsHero"
                width: pageColumn.width
                height: root.heroHeight
                clip: true

                // MovieDetailView.swift:220-259: the fallback is the surface
                // gradient, then the poster blown up and blurred under a
                // leading-to-trailing scrim. The compact poster fallback is a
                // placeholder: its slots are headless-safe but never painted.
                // :222-229 runs surfaceElevated .topLeading to the page
                // background .bottomTrailing. Rectangle gradients are
                // axis-aligned only, so the diagonal paints on a Canvas.
                Canvas {
                    objectName: "detailsHeroFallbackGradient"
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
                    objectName: "detailsHeroFallback"
                    anchors.centerIn: parent
                    width: parent.width * 1.34
                    height: parent.height * 1.34
                    source: root.known ? root.details.posterUrl : ""
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    visible: false
                    sourceSize.width: 600
                }
                // MovieDetailView.swift:242-245: scaled 1.34, blurred 14,
                // saturation 1.16, contrast 1.08, at 0.58. MultiEffect's
                // blur is the fraction of blurMax applied (effective pixel
                // radius = blur * blurMax), so the oracle's 14-point
                // radius is blur 0.4375 at blurMax 32.
                MultiEffect {
                    objectName: "detailsHeroBlur"
                    anchors.fill: heroPosterFallback
                    source: heroPosterFallback
                    visible: heroPosterFallback.status === Image.Ready
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

                // MovieDetailView.swift:204-213.
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

                // MovieDetailView.swift:261-279.
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
                        // MovieDetailView.swift:263: heroTitleOverlay's title
                        // stack is spaced 10.
                        spacing: 10

                        Text {
                            objectName: "detailsTitle"
                            width: parent.width
                            text: root.known ? root.details.title : ""
                            color: Theme.textPrimary
                            font.pixelSize: Theme.scaled(36, 52, root.leanBack)
                            font.weight: Font.Bold
                            wrapMode: Text.Wrap
                            maximumLineCount: 2
                            elide: Text.ElideRight
                        }

                        // MovieDetailView.swift:320-339: year, runtime; the
                        // certification, rating, and genre slots the oracle
                        // draws around them wait on the metadata milestone
                        // (plan section 5) and render as nothing while their
                        // inputs are empty, exactly as the oracle's
                        // @ViewBuilders do.
                        Row {
                            objectName: "detailsMetadataLine"
                            spacing: Theme.scaled(16, 22, root.leanBack)
                            Text {
                                objectName: "detailsMetadata"
                                // MovieDetailView.swift:322: the year slot is
                                // present only for a dated title; an undated
                                // one contributes an empty string, not a "0".
                                visible: root.details.year !== undefined && root.details.year > 0
                                text: root.details.year !== undefined && root.details.year > 0
                                    ? String(root.details.year) : ""
                                color: Theme.textPrimary
                                font.pixelSize: Theme.scaled(13, 18, root.leanBack)
                                font.weight: Font.Medium
                            }
                            Text {
                                objectName: "detailsRuntime"
                                visible: root.details.runtime !== undefined
                                    && String(root.details.runtime).length > 0
                                text: root.details.runtime !== undefined
                                    ? String(root.details.runtime) : ""
                                color: Theme.textSecondary
                                font.pixelSize: Theme.scaled(13, 18, root.leanBack)
                                font.weight: Font.Medium
                            }
                            Text {
                                objectName: "detailsCertification"
                                visible: false
                                text: ""
                                color: Theme.textSecondary
                                font.pixelSize: Theme.scaled(11, 15, root.leanBack)
                                font.weight: Font.DemiBold
                            }
                            Text {
                                objectName: "detailsRating"
                                visible: false
                                text: ""
                                color: Theme.textPrimary
                                font.pixelSize: Theme.scaled(13, 18, root.leanBack)
                                font.weight: Font.Medium
                            }
                        }

                        Row {
                            objectName: "detailsGenres"
                            visible: false
                            spacing: Theme.scaled(6, 10, root.leanBack)
                        }
                    }

                    // MovieDetailView.swift:281-316.
                    Item {
                        id: heroPoster
                        objectName: "detailsPosterPreview"
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
                                source: root.known ? root.details.posterUrl : ""
                                fillMode: Image.PreserveAspectCrop
                                asynchronous: true
                                sourceSize.width: 400
                            }

                            // MovieDetailView.swift:297-306: the format badge
                            // in monospace on a black 0.58 capsule.
                            Rectangle {
                                anchors.left: parent.left
                                anchors.bottom: parent.bottom
                                anchors.margins: Theme.scaled(8, 12, root.leanBack)
                                width: formatBadge.width + 2 * Theme.scaled(8, 12, root.leanBack)
                                height: formatBadge.height + 2 * Theme.scaled(4, 6, root.leanBack)
                                radius: height / 2
                                color: Qt.rgba(0, 0, 0, 0.58)
                                Text {
                                    id: formatBadge
                                    anchors.centerIn: parent
                                    text: root.known ? root.details.formatBadge : ""
                                    color: Theme.textPrimary
                                    font.pixelSize: Theme.scaled(10, 14, root.leanBack)
                                    font.weight: Font.Bold
                                    font.family: "monospace"
                                }
                            }
                        }
                    }

                    // MovieDetailView.swift:281-316: the poster preview. The
                    // composed poster slot the tenth suite owns is drawn by
                    // the preview's own fallback: MovieCard.swift:215-222
                    // draws no artwork for a title without a sidecar and keeps
                    // the fallback beneath naming the title.
                    PosterArt {
                        id: poster
                        objectName: "detailsPoster"
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        width: root.heroPosterWidth
                        opacity: 0
                        enabled: false
                        visible: true
                        source: root.known ? root.details.posterUrl : ""
                        title: root.known ? root.details.title : ""
                        badge: root.known ? root.details.formatBadge : ""
                    }
                }
            }

            // MovieDetailView.swift:135-150: the content stack under the
            // hero. contentArea carries no top padding of its own; the 4/8
            // sits on the action row (:449).
            Column {
                id: contentColumn
                objectName: "detailsContent"
                y: hero.height
                width: pageColumn.width
                leftPadding: root.outerPadding
                rightPadding: root.outerPadding
                bottomPadding: Theme.scaled(100, 150, root.leanBack)
                spacing: Theme.sectionSpacing(root.leanBack)
                // Keep section placement coherent when compact/lean-back
                // metrics change before the next positioner polish.
                onSpacingChanged: forceLayout()

                // MovieDetailView.swift:135-137 and :390-450: actionButtons
                // is contentArea's FIRST child, under the hero — never
                // inside it.
                Row {
                    id: actions
                    objectName: "detailsActions"
                    spacing: Theme.scaled(12, 18, root.leanBack)
                    topPadding: Theme.scaled(4, 8, root.leanBack)
                    onHeightChanged: contentColumn.forceLayout()

                    // MovieDetailView.swift:391-397: Start is the :391
                    // outer-HStack spacing 12 with the :393
                    // inner-HStack spacing 8, label 15 bold and
                    // glyph play.fill 14; :400-401 padding 28/12; :402-403 and :417-421 an
                    // 8-point rounded rectangle (cornerRadiusMD,
                    // MarqueeTheme.swift:245) with the matching
                    // radius-8 focus surface.
                    DetailCapsuleButton {
                        objectName: "detailsPlayButton"
                        label: qsTr("Start From Beginning")
                        glyph: "play.fill"
                        fill: Theme.accentSecondary
                        textColor: "#ffffff"
                        leanBack: root.leanBack
                        focused: root.activeFocus && root.focusNode === "start"
                        focusAccent: root.focusAccent
                        kidsMode: root.kidsMode
                        pageBackground: root.pageBackground
                        // DetailFocusSurfaceModifier.swift:12-14 floors
                        // only the focus surface at kidsCornerRadiusMD
                        // (MarqueeTheme.swift:185) in kids mode; the
                        // fill stays 8, and focusRadius applies the
                        // floor itself.
                        surfaceRadius: Theme.radiusMD
                        horizontalPadding: Theme.scaled(28, 42, root.leanBack)
                        verticalPadding: Theme.scaled(12, 18, root.leanBack)
                        contentSpacing: Theme.scaled(8, 12, root.leanBack)
                        labelFontSize: Theme.scaled(15, 22, root.leanBack)
                        labelFontWeight: Font.Bold
                        glyphSize: Theme.scaled(14, 21, root.leanBack)
                        onActivated: root.playFromStart()
                    }

                    // MovieDetailView.swift:426-430: Resume is label
                    // 13 semibold with glyph play.fill 12; :433-434
                    // padding 20/12; :436-437 and :441-445 an
                    // 8-point rounded rectangle with the matching
                    // radius-8 focus surface.
                    DetailCapsuleButton {
                        objectName: "detailsResumeButton"
                        visible: root.showsResume
                        label: root.resumeLabel
                        glyph: "play.fill"
                        fill: Theme.surfaceLayer
                        textColor: Theme.textPrimary
                        leanBack: root.leanBack
                        focused: root.activeFocus && root.focusNode === "continue"
                        focusAccent: root.focusAccent
                        kidsMode: root.kidsMode
                        pageBackground: root.pageBackground
                        // Same kids-mode floor as Start above.
                        surfaceRadius: Theme.radiusMD
                        horizontalPadding: Theme.scaled(20, 30, root.leanBack)
                        verticalPadding: Theme.scaled(12, 18, root.leanBack)
                        contentSpacing: Theme.scaled(8, 12, root.leanBack)
                        labelFontSize: Theme.scaled(13, 19, root.leanBack)
                        labelFontWeight: Font.DemiBold
                        glyphSize: Theme.scaled(12, 18, root.leanBack)
                        onActivated: root.playResume()
                    }
                }

                Text {
                    objectName: "detailsPath"
                    width: parent.width - 2 * root.outerPadding
                    visible: false
                    text: root.known ? root.details.relativePath : ""
                    color: Theme.textTertiary
                    font.pixelSize: Theme.scaled(12, 17, root.leanBack)
                    elide: Text.ElideMiddle
                }

                // MovieDetailView.swift:454-487: SYNOPSIS with Show More. The
                // oracle draws the whole section only for a non-empty overview
                // (:456); the offline catalog carries none, so the section is
                // absent here. An invisible Column child is skipped by the
                // column layout, so no space and no inter-section gap remain.
                Column {
                    objectName: "detailsSynopsis"
                    visible: false
                    width: parent.width - 2 * root.outerPadding
                    spacing: 10
                    Text {
                        objectName: "detailsSynopsisHeader"
                        text: root.kidsMode ? qsTr("Synopsis") : qsTr("SYNOPSIS")
                        color: root.kidsMode ? Theme.kidsAccent : Theme.textSecondary
                        font.pixelSize: root.kidsMode ? Theme.scaled(14, 20, root.leanBack)
                                                      : Theme.scaled(11, 16, root.leanBack)
                        font.weight: Font.Bold
                        font.letterSpacing: root.kidsMode ? 0 : 1.5
                    }
                    Text {
                        objectName: "detailsSynopsisBody"
                        visible: false
                        width: parent.width
                        text: ""
                        color: Theme.textPrimary
                        font.pixelSize: Theme.scaled(14, 20, root.leanBack)
                        wrapMode: Text.Wrap
                    }
                    Text {
                        objectName: "detailsSynopsisToggle"
                        visible: false
                        text: qsTr("Show More")
                        color: Theme.accentBright
                        font.pixelSize: Theme.scaled(12, 17, root.leanBack)
                        font.weight: Font.DemiBold
                    }
                }

                // MovieDetailView.swift:491-510: Directed by. The oracle draws
                // the whole line only for a non-empty director (:493); the
                // offline catalog carries none, so the line is absent here. An
                // invisible Column child is skipped by the column layout, so
                // no space and no inter-section gap remain.
                Row {
                    objectName: "detailsDirector"
                    visible: false
                    width: parent.width - 2 * root.outerPadding
                    spacing: 0
                    Text {
                        objectName: "detailsDirectorPrefix"
                        text: qsTr("Directed by ")
                        color: Theme.textSecondary
                        font.pixelSize: Theme.scaled(14, 20, root.leanBack)
                    }
                    Text {
                        objectName: "detailsDirectorName"
                        visible: false
                        text: ""
                        color: Theme.textPrimary
                        font.pixelSize: Theme.scaled(14, 20, root.leanBack)
                        font.weight: Font.DemiBold
                    }
                }

                // MovieDetailView.swift:571-611: MORE LIKE THIS. An empty
                // `similar` draws nothing there, and draws nothing here.
                Column {
                    objectName: "detailsMoreLikeThis"
                    width: parent.width - 2 * root.outerPadding
                    visible: root.similarCount > 0
                    topPadding: root.relatedTopClearance
                    spacing: Theme.scaled(16, 22, root.leanBack)

                    Text {
                        objectName: "detailsMoreLikeThisHeader"
                        text: root.kidsMode ? qsTr("More Like This") : qsTr("MORE LIKE THIS")
                        color: root.kidsMode ? Theme.kidsAccent : Theme.textSecondary
                        font.pixelSize: root.kidsMode ? Theme.scaled(14, 20, root.leanBack)
                                                      : Theme.scaled(11, 16, root.leanBack)
                        font.weight: Font.Bold
                        font.letterSpacing: root.kidsMode ? 0 : 1.5
                    }

                    MediaItemRow {
                        id: moreLikeRow
                        objectName: "detailsMoreLikeThisRow"
                        width: parent.width
                        height: implicitHeight
                        rowTitle: ""
                        items: root.similar
                        totalCount: root.similarCount
                        leanBack: root.leanBack
                        reduceMotion: root.reduceMotion
                        focusedIndex: root.activeFocus && root.focusNode === "more"
                            ? root.focusedMore : -1
                        onActivated: mediaId => Qt.callLater(appController.showMediaDetails, mediaId)
                    }
                }

                // MovieDetailView.swift:1105-1138: FILE INFO.
                Column {
                    objectName: "detailsFileInfo"
                    width: parent.width - 2 * root.outerPadding
                    spacing: Theme.scaled(12, 18, root.leanBack)

                    Rectangle {
                        width: parent.width
                        height: 1
                        color: Theme.surfaceLayer
                    }

                    Text {
                        objectName: "detailsFileInfoHeader"
                        text: qsTr("FILE INFO")
                        color: Theme.textSecondary
                        font.pixelSize: Theme.scaled(11, 16, root.leanBack)
                        font.weight: Font.Bold
                        font.letterSpacing: 1.5
                    }

                    Row {
                        objectName: "detailsFileInfoRow"
                        width: parent.width
                        spacing: 16
                        Rectangle {
                            width: fileInfoBadge.width + 2 * Theme.scaled(8, 12, root.leanBack)
                            height: fileInfoBadge.height + 2 * Theme.scaled(4, 6, root.leanBack)
                            radius: Theme.radiusSM
                            color: Theme.surfaceLayer
                            Text {
                                id: fileInfoBadge
                                anchors.centerIn: parent
                                text: root.known ? root.details.formatBadge : ""
                                color: Theme.textTertiary
                                font.pixelSize: Theme.scaled(12, 17, root.leanBack)
                                font.weight: Font.DemiBold
                                font.family: "monospace"
                            }
                        }
                        Text {
                            objectName: "detailsFileInfoSize"
                            anchors.verticalCenter: parent.verticalCenter
                            text: root.known ? root.details.fileSizeText : ""
                            color: Theme.textTertiary
                            font.pixelSize: Theme.scaled(12, 17, root.leanBack)
                        }
                        Text {
                            objectName: "detailsFileInfoPath"
                            anchors.verticalCenter: parent.verticalCenter
                            width: Math.max(0, parent.width - x - 16)
                            text: root.known ? root.details.relativePath : ""
                            color: Theme.textTertiary
                            font.pixelSize: Theme.scaled(12, 17, root.leanBack)
                            elide: Text.ElideLeft
                            maximumLineCount: 1
                        }
                    }
                }
            }
        }
    }

    // MovieDetailView.swift:154-182: the leading circular Back control.
    Item {
        id: backButton
        objectName: "detailsBack"
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
        Accessible.name: "Back"
        Accessible.role: Accessible.Button
    }

    // The focused section is scrolled into a comfortable band.
    function placeFocus(animated) {
        if (!root.known) {
            return
        }
        let target = -1
        switch (root.focusNode) {
        case "back":
        case "start":
        case "continue":
            target = 0
            break
        case "more":
            target = Math.max(0, moreLikeRow.mapToItem(pageColumn, 0, 0).y
                              - root.relatedTopClearance)
            break
        }
        if (target < 0) {
            return
        }
        target = Math.min(target, Math.max(0, scroll.contentHeight - scroll.height))
        scrollSpring.stop()
        if (!animated || root.reduceMotion) {
            scroll.contentY = target
            return
        }
        scrollSpring.from = scroll.contentY
        scrollSpring.to = target
        scrollSpring.start()
    }

    onFocusNodeChanged: root.placeFocus(true)
    onFocusedMoreChanged: root.placeFocus(true)

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
            // (MovieDetailView.swift:119-121's Back does the same one step).
            event.accepted = false
        }
    }
}
