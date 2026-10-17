import QtQuick
import QtQuick.Controls
import QtQuick.Dialogs
import Marquee 3.0

// Marquee/Features/Settings/Views/SettingsDetailView.swift:27-52: the
// settings route. A vertical scroll of the header (:60-92), the overview
// metric tiles (:94-175), and the Library (:178-354), Playback (:358-413),
// Sound (:438-514), Storage (:562-820), and About (:824-854) sections,
// clamped to 1280/1720 points wide with the outer padding on the sides and
// 100/150 below.
//
// The released page is pointer-driven; the remote reaches it only through
// Escape and Left at the page edge (:46-58, :1019-1112), which return the
// remote to the sidebar. On this stack every control is also reachable in
// reading order from the remote: Up/Down move between controls, Left/Right
// step pickers and sliders, and Select acts. Left on a control that does
// not consume it is :1068's key 123 and hands the remote to the sidebar.
FocusScope {
    id: root
    focus: true

    signal requestSidebarFocus()

    property bool leanBack: appController.settings.leanBackMode
    property bool reduceMotion: appController.settings.reduceMotion

    readonly property var settings: appController.settings
    readonly property var session: appController.settingsSession
    readonly property int quickMotion: root.reduceMotion ? 0 : Theme.motionNormal

    readonly property real outerPadding: Theme.outerPadding(root.leanBack)
    // :32 and :41-43.
    readonly property real stackSpacing: Theme.scaled(28, 40, root.leanBack)
    readonly property real maxContentWidth: Theme.scaled(1280, 1720, root.leanBack)
    readonly property real bottomPadding: Theme.scaled(100, 150, root.leanBack)
    // :863-864: a section's header row and its body.
    readonly property real sectionSpacing: Theme.scaled(12, 18, root.leanBack)

    // The reading-order list of remote-reachable controls, rebuilt when the
    // folder list changes. Each entry names the control so the handler acts
    // without reaching into layout.
    property var controls: []
    property int focusIndex: -1

    // :15-16: the inline confirmations.
    property bool showClearConfirmation: false
    property bool showClearCacheConfirmation: false

    // Set before the folder panel takes focus, so the page keeps its place
    // while the panel is up and can tell that loss of focus from a real one.
    property bool folderPanelOpen: false

    function rebuildControls() {
        const list = []
        const roots = root.settings.libraryRoots
        for (let index = 0; index < roots.length; ++index) {
            list.push({ kind: "folder", index: index })
        }
        list.push({ kind: "addFolder" })
        const tvRoots = root.settings.tvShowsRoots
        for (let index = 0; index < tvRoots.length; ++index) {
            list.push({ kind: "tvFolder", index: index })
        }
        list.push({ kind: "addTvFolder" })
        list.push({ kind: "switch", key: "onlineMetadataEnabled" })
        list.push({ kind: "rescan" })
        list.push({ kind: "switch", key: "hardwareDecodingEnabled" })
        list.push({ kind: "switch", key: "autoPlayNextEpisode" })
        list.push({ kind: "picker", key: "defaultSubtitleLanguage" })
        list.push({ kind: "slider", key: "subtitleScale" })
        list.push({ kind: "picker", key: "defaultAudioLanguage" })
        list.push({ kind: "switch", key: "interfaceSounds" })
        list.push({ kind: "switch", key: "launchIdentEnabled" })
        list.push({ kind: "picker", key: "soundPack" })
        list.push({ kind: "button", key: "clearCache" })
        list.push({ kind: "button", key: "clearHistory" })
        list.push({ kind: "button", key: "exportDiagnostics" })
        root.controls = list
        if (root.focusIndex >= list.length) {
            root.focusIndex = list.length - 1
        }
    }

    function controlAt(index) {
        return index >= 0 && index < root.controls.length ? root.controls[index] : null
    }

    function isFocused(kind, key) {
        const control = controlAt(root.focusIndex)
        return (root.activeFocus || root.folderPanelOpen) && control !== null
            && control.kind === kind
            && (key === undefined || control.key === key || control.index === key)
    }

    Component.onCompleted: rebuildControls()

    onActiveFocusChanged: {
        // The remote arrives from the sidebar on the first control; leaving
        // drops the highlight so the page reads as pointer-only again. The
        // modal folder panel (:298) borrows focus without leaving the page,
        // so the place is kept for its return.
        if (root.activeFocus) {
            if (root.focusIndex < 0) {
                root.focusIndex = 0
            }
        } else if (!root.folderPanelOpen) {
            root.focusIndex = -1
        }
    }

    // Which list the open panel is adding to (:290-303 takes the binding).
    property bool folderPanelForTv: false

    function openFolderPanel(forTv) {
        root.folderPanelForTv = forTv === true
        root.folderPanelOpen = true
        folderDialog.open()
    }

    Connections {
        target: folderDialog
        function onVisibleChanged() {
            if (!folderDialog.visible) {
                // The panel hands focus back as it closes; the page takes
                // it again once that has settled.
                Qt.callLater(function() {
                    root.forceActiveFocus()
                    root.folderPanelOpen = false
                })
            }
        }
    }

    Connections {
        target: root.settings
        function onLibraryRootsChanged() { root.rebuildControls() }
        function onTvShowsRootsChanged() { root.rebuildControls() }
    }

    Keys.onPressed: event => {
        if (root.folderPanelOpen) {
            return
        }
        const control = controlAt(root.focusIndex)
        switch (event.key) {
        case Qt.Key_Up:
            if (root.focusIndex > 0) {
                root.focusIndex -= 1
            }
            event.accepted = true
            return
        case Qt.Key_Down:
            if (root.focusIndex < root.controls.length - 1) {
                root.focusIndex += 1
            }
            event.accepted = true
            return
        case Qt.Key_Left:
            if (control && (control.kind === "picker" || control.kind === "slider")) {
                adjust(control, -1)
            } else {
                // :1068: key 123 (Left) at the page returns to the sidebar.
                root.requestSidebarFocus()
            }
            event.accepted = true
            return
        case Qt.Key_Right:
            if (control && (control.kind === "picker" || control.kind === "slider")) {
                adjust(control, 1)
                event.accepted = true
            }
            return
        case Qt.Key_Return:
        case Qt.Key_Enter:
        case Qt.Key_Select:
        case Qt.Key_Space:
            if (control) {
                activate(control)
                event.accepted = true
            }
            return
        case Qt.Key_Escape:
        case Qt.Key_Back:
        case Qt.Key_Backspace:
            // :46-58 and :1068: Escape (key 53) leaves the page. An open
            // inline confirmation is dismissed first, as a pointer's Cancel.
            if (root.showClearConfirmation || root.showClearCacheConfirmation) {
                root.showClearConfirmation = false
                root.showClearCacheConfirmation = false
                event.accepted = true
                return
            }
            root.requestSidebarFocus()
            event.accepted = true
            return
        }
    }

    function adjust(control, delta) {
        if (control.kind === "slider") {
            subtitleScaleSlider.step(delta)
        } else if (control.key === "defaultSubtitleLanguage") {
            subtitleLanguagePicker.step(delta)
        } else if (control.key === "defaultAudioLanguage") {
            audioLanguagePicker.step(delta)
        } else if (control.key === "soundPack") {
            soundPackPicker.step(delta)
        }
    }

    function activate(control) {
        switch (control.kind) {
        case "folder":
            // :274-280: the row's remove control.
            root.session.removeLibraryRoot(control.index)
            return
        case "addFolder":
            openFolderPanel(false)
            return
        case "tvFolder":
            root.session.removeTvShowsRoot(control.index)
            return
        case "addTvFolder":
            openFolderPanel(true)
            return
        case "rescan":
            if (!root.session.hasQueuedScan) {
                root.session.rescanLibrary()
            }
            return
        case "switch":
            root.settings[control.key] = !root.settings[control.key]
            return
        case "button":
            if (control.key === "clearCache") {
                if (root.showClearCacheConfirmation) {
                    root.session.clearImageCache()
                    root.showClearCacheConfirmation = false
                } else {
                    root.showClearCacheConfirmation = true
                }
            } else if (control.key === "clearHistory") {
                if (root.showClearConfirmation) {
                    root.session.clearWatchHistory()
                    root.showClearConfirmation = false
                } else {
                    root.showClearConfirmation = true
                }
            } else if (control.key === "exportDiagnostics") {
                if (!root.session.exportingDiagnostics) {
                    root.session.exportDiagnostics()
                }
            }
            return
        }
    }

    // :290-303: the macOS open panel for a single directory, as Qt's folder
    // dialog on this stack; the choice is appended unless already listed.
    FolderDialog {
        id: folderDialog
        objectName: "folderDialog"
        title: qsTr("Select a media folder")
        acceptLabel: qsTr("Add Folder")
        // The panel stays inside the theater window rather than opening a
        // second top-level over a fullscreen surface, and its close hands
        // the remote straight back to the page.
        popupType: Popup.Item
        onAccepted: root.folderPanelForTv
            ? root.session.addTvShowsRoot(selectedFolder.toString())
            : root.session.addLibraryRoot(selectedFolder.toString())
    }

    Flickable {
        id: scroller
        objectName: "settingsScroller"
        anchors.fill: parent
        contentWidth: width
        contentHeight: stack.y + stack.height + root.bottomPadding
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        function reveal(item) {
            if (!item) {
                return
            }
            const top = item.mapToItem(scroller.contentItem, 0, 0).y
            const bottom = top + item.height
            const margin = 24
            if (top < contentY + margin) {
                contentY = Math.max(0, top - margin)
            } else if (bottom > contentY + height - margin) {
                contentY = Math.max(0, Math.min(contentHeight - height, bottom - height + margin))
            }
        }

        Column {
            id: stack
            x: root.outerPadding
            width: Math.min(root.maxContentWidth, scroller.width - root.outerPadding * 2)
            spacing: root.stackSpacing
            // :91: the header's top clearance.
            topPadding: Theme.scaled(30, 46, root.leanBack)

            // SettingsDetailView.swift:60-92.
            Item {
                id: header
                width: parent.width
                height: headerLabels.height

                Column {
                    id: headerLabels
                    anchors.left: parent.left
                    anchors.right: statusCapsule.left
                    anchors.rightMargin: 24
                    spacing: Theme.scaled(8, 12, root.leanBack)

                    Text {
                        objectName: "settingsTitle"
                        text: qsTr("Settings")
                        color: Theme.textPrimary
                        font.pixelSize: Theme.scaled(32, 46, root.leanBack)
                        font.weight: Font.Bold
                    }

                    Text {
                        width: parent.width
                        text: qsTr("Tune library, playback, and maintenance without interrupting the screening room.")
                        color: Theme.textSecondary
                        font.pixelSize: Theme.scaled(13, 19, root.leanBack)
                        font.weight: Font.Medium
                        wrapMode: Text.WordWrap
                        maximumLineCount: 2
                        elide: Text.ElideRight
                    }
                }

                // :75-89: the scan status capsule on the trailing edge.
                Rectangle {
                    id: statusCapsule
                    objectName: "scanStatusCapsule"
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    width: statusRow.width + Theme.scaled(12, 18, root.leanBack) * 2
                    height: statusRow.height + Theme.scaled(7, 11, root.leanBack) * 2
                    radius: height / 2
                    color: Qt.rgba(Theme.surfaceElevated.r, Theme.surfaceElevated.g,
                                   Theme.surfaceElevated.b, 0.9)

                    Row {
                        id: statusRow
                        anchors.centerIn: parent
                        spacing: Theme.scaled(8, 12, root.leanBack)

                        MarqueeSymbol {
                            anchors.verticalCenter: parent.verticalCenter
                            symbol: appController.scanning
                                ? "arrow.triangle.2.circlepath" : "checkmark.seal.fill"
                            pointSize: Theme.scaled(14, 20, root.leanBack)
                            color: appController.scanning ? Theme.accentSecondary : Theme.accentBright
                        }

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: appController.scanning ? qsTr("Scan active") : qsTr("Library ready")
                            color: Theme.textSecondary
                            font.pixelSize: Theme.scaled(12, 17, root.leanBack)
                            font.weight: Font.DemiBold
                        }
                    }
                }
            }

            // SettingsDetailView.swift:94-133: the overview grid, adaptive
            // columns of at least 210/300 at a 12/18 gap.
            Grid {
                id: overview
                objectName: "settingsOverview"
                width: parent.width
                columnSpacing: Theme.scaled(12, 18, root.leanBack)
                rowSpacing: Theme.scaled(12, 18, root.leanBack)
                readonly property real minimumTileWidth: Theme.scaled(210, 300, root.leanBack)
                columns: Math.max(1, Math.min(4, Math.floor((width + columnSpacing)
                                                            / (minimumTileWidth + columnSpacing))))
                readonly property real tileWidth: (width - columnSpacing * (columns - 1)) / columns

                MetricTile {
                    width: overview.tileWidth
                    icon: "film"
                    title: qsTr("Movies")
                    value: String(appController.library.titleCount)
                    accent: Theme.accentSecondary
                }

                MetricTile {
                    width: overview.tileWidth
                    icon: "tv"
                    title: qsTr("Episodes")
                    value: String(appController.shows.episodeCount)
                    accent: Theme.accentBright
                }

                MetricTile {
                    width: overview.tileWidth
                    icon: "folder"
                    title: qsTr("Sources")
                    value: String(root.settings.libraryRoots.length
                                  + root.settings.tvShowsRoots.length)
                    accent: Theme.textSecondary
                }

                MetricTile {
                    width: overview.tileWidth
                    icon: "externaldrive"
                    title: qsTr("Image Cache")
                    // :684-693.
                    value: root.session.measuringImageCache
                        ? qsTr("Measuring...")
                        : (root.session.imageCacheSize !== "Not measured"
                            ? root.session.imageCacheSize : qsTr("Ready"))
                    accent: Qt.rgba(Theme.accentSecondary.r, Theme.accentSecondary.g,
                                    Theme.accentSecondary.b, 0.9)
                }
            }

            // SettingsDetailView.swift:178-219: Library.
            SettingsSection {
                objectName: "librarySection"
                title: qsTr("Library")
                subtitle: qsTr("Choose the folders Marquee watches and decide when metadata enrichment is allowed.")
                icon: "folder.fill"
                accent: Theme.accentSecondary

                Column {
                    width: parent.width
                    padding: 20
                    spacing: 24

                    // :186-197: the Movies and TV Shows folder lists, divided.
                    SettingsFolderList {
                        objectName: "moviesFolderList"
                        width: parent.width - 40
                        title: qsTr("Movies Folders")
                        paths: root.settings.libraryRoots
                        folderKind: "folder"
                        addKind: "addFolder"
                        isFocused: root.isFocused
                        reveal: scroller.reveal
                        onRemoveRequested: index => root.session.removeLibraryRoot(index)
                        onAddRequested: root.openFolderPanel(false)
                    }

                    SectionDivider { width: parent.width - 40 }

                    SettingsFolderList {
                        objectName: "tvShowsFolderList"
                        width: parent.width - 40
                        title: qsTr("TV Shows Folders")
                        paths: root.settings.tvShowsRoots
                        folderKind: "tvFolder"
                        addKind: "addTvFolder"
                        isFocused: root.isFocused
                        reveal: scroller.reveal
                        onRemoveRequested: index => root.session.removeTvShowsRoot(index)
                        onAddRequested: root.openFolderPanel(true)
                    }

                    SectionDivider { width: parent.width - 40 }

                    // :202-206: the row keeps its own 20-point padding inside
                    // the section's, so it sits inset from the folder lists.
                    ToggleRow {
                        id: onlineMetadataRow
                        objectName: "onlineMetadataRow"
                        width: parent.width - 40
                        title: qsTr("Online Metadata")
                        subtitle: qsTr("Fetch TMDB details and artwork during library scans.")
                        checked: root.settings.onlineMetadataEnabled
                        focused: root.isFocused("switch", "onlineMetadataEnabled")
                        onToggled: value => root.settings.onlineMetadataEnabled = value
                        onFocusedChanged: if (focused) scroller.reveal(onlineMetadataRow)
                    }

                    SectionDivider { width: parent.width - 40 }

                    // :305-354: the rescan row.
                    Item {
                        id: rescanRow
                        objectName: "rescanRow"
                        readonly property bool focused: root.isFocused("rescan")
                        width: parent.width - 40
                        height: Math.max(rescanLabels.height, rescanButton.height)
                        onFocusedChanged: if (focused) scroller.reveal(rescanRow)

                        Column {
                            id: rescanLabels
                            anchors.left: parent.left
                            anchors.right: rescanButton.left
                            anchors.rightMargin: 16
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 4

                            Text {
                                text: qsTr("Rescan Library")
                                color: Theme.textPrimary
                                font.pixelSize: 14
                                font.weight: Font.DemiBold
                            }

                            Text {
                                text: qsTr("Re-scan all configured folders for media files.")
                                color: Theme.textSecondary
                                font.pixelSize: 12
                            }

                            Text {
                                objectName: "scanStatusText"
                                visible: text.length > 0
                                text: root.session.scanStatusText
                                color: root.session.hasQueuedScan ? Theme.accentSecondary : Theme.textTertiary
                                font.pixelSize: 11
                                font.weight: Font.Medium
                            }
                        }

                        CapsuleButton {
                            id: rescanButton
                            objectName: "rescanButton"
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            icon: appController.scanning ? "" : "arrow.clockwise"
                            busy: appController.scanning
                            // :350-354.
                            text: root.session.hasQueuedScan
                                ? qsTr("Queued")
                                : (appController.scanning ? qsTr("Queue Scan") : qsTr("Rescan"))
                            textSize: 13
                            horizontalPadding: 16
                            verticalPadding: 7
                            enabled: !root.session.hasQueuedScan
                            focused: rescanRow.focused
                            onActivated: root.session.rescanLibrary()
                        }
                    }
                }
            }

            // SettingsDetailView.swift:358-413: Playback.
            SettingsSection {
                objectName: "playbackSection"
                title: qsTr("Playback")
                subtitle: qsTr("Set the defaults that shape every movie night before the player opens.")
                icon: "play.rectangle.fill"
                accent: Theme.accentBright

                Column {
                    width: parent.width

                    ToggleRow {
                        id: hardwareDecodingRow
                        objectName: "hardwareDecodingRow"
                        width: parent.width
                        title: qsTr("Hardware Decoding")
                        // :368: VideoToolbox on the released build; the libmpv
                        // hwdec option on this stack, applied live by
                        // MpvVideoItem from this stored value.
                        subtitle: qsTr("Use hardware-accelerated video decoding.")
                        checked: root.settings.hardwareDecodingEnabled
                        focused: root.isFocused("switch", "hardwareDecodingEnabled")
                        onToggled: value => root.settings.hardwareDecodingEnabled = value
                        onFocusedChanged: if (focused) scroller.reveal(hardwareDecodingRow)
                    }

                    SectionDivider { width: parent.width; inset: 20 }

                    ToggleRow {
                        id: autoPlayRow
                        objectName: "autoPlayRow"
                        width: parent.width
                        title: qsTr("Auto-play Next Episode")
                        subtitle: qsTr("Automatically play the next episode when the current one ends.")
                        checked: root.settings.autoPlayNextEpisode
                        focused: root.isFocused("switch", "autoPlayNextEpisode")
                        onToggled: value => root.settings.autoPlayNextEpisode = value
                        onFocusedChanged: if (focused) scroller.reveal(autoPlayRow)
                    }

                    SectionDivider { width: parent.width; inset: 20 }

                    // :541-558. MpvVideoItem reads the stored value when a
                    // file opens (PlayerScreen.qml binds it).
                    PickerRow {
                        id: subtitleLanguageRow
                        objectName: "subtitleLanguageRow"
                        width: parent.width
                        title: qsTr("Default Subtitle Language")
                        focused: root.isFocused("picker", "defaultSubtitleLanguage")
                        onFocusedChanged: if (focused) scroller.reveal(subtitleLanguageRow)

                        SettingsPicker {
                            id: subtitleLanguagePicker
                            objectName: "subtitleLanguagePicker"
                            controlWidth: 160
                            options: root.settings.subtitleLanguages
                            currentValue: root.settings.defaultSubtitleLanguage
                            focused: subtitleLanguageRow.focused
                            onSelected: value => root.settings.defaultSubtitleLanguage = value
                        }
                    }

                    SectionDivider { width: parent.width; inset: 20 }

                    // :516-539. MpvVideoItem applies the stored value as
                    // libmpv's sub-scale.
                    Item {
                        id: subtitleSizeRow
                        objectName: "subtitleSizeRow"
                        readonly property bool focused: root.isFocused("slider", "subtitleScale")
                        width: parent.width
                        height: subtitleSizeLabels.height + 40
                        onFocusedChanged: if (focused) scroller.reveal(subtitleSizeRow)

                        Column {
                            id: subtitleSizeLabels
                            anchors.left: parent.left
                            anchors.leftMargin: 20
                            anchors.right: subtitleScaleSlider.left
                            anchors.rightMargin: 18
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 3

                            Text {
                                text: qsTr("Subtitle Size")
                                color: Theme.textPrimary
                                font.pixelSize: 14
                                font.weight: Font.Medium
                            }

                            Text {
                                text: qsTr("Scales subtitles during playback.")
                                color: Theme.textSecondary
                                font.pixelSize: 12
                            }
                        }

                        SettingsSlider {
                            id: subtitleScaleSlider
                            objectName: "subtitleScaleSlider"
                            anchors.right: subtitleScaleValue.left
                            anchors.rightMargin: 18
                            anchors.verticalCenter: parent.verticalCenter
                            width: 180
                            from: 0.8
                            to: 2.2
                            stepSize: 0.05
                            value: root.settings.subtitleScale
                            focused: subtitleSizeRow.focused
                            onMoved: value => root.settings.subtitleScale = value
                        }

                        Text {
                            id: subtitleScaleValue
                            objectName: "subtitleScaleValue"
                            anchors.right: parent.right
                            anchors.rightMargin: 20
                            anchors.verticalCenter: parent.verticalCenter
                            width: 46
                            horizontalAlignment: Text.AlignRight
                            text: Math.round(root.settings.subtitleScale * 100) + "%"
                            color: Theme.textTertiary
                            font.pixelSize: 12
                            font.weight: Font.Medium
                            font.family: "monospace"
                        }
                    }

                    SectionDivider { width: parent.width; inset: 20 }

                    PickerRow {
                        id: audioLanguageRow
                        objectName: "audioLanguageRow"
                        width: parent.width
                        title: qsTr("Default Audio Language")
                        focused: root.isFocused("picker", "defaultAudioLanguage")
                        onFocusedChanged: if (focused) scroller.reveal(audioLanguageRow)

                        SettingsPicker {
                            id: audioLanguagePicker
                            objectName: "audioLanguagePicker"
                            controlWidth: 160
                            options: root.settings.audioLanguages
                            currentValue: root.settings.defaultAudioLanguage
                            focused: audioLanguageRow.focused
                            onSelected: value => root.settings.defaultAudioLanguage = value
                        }
                    }
                }
            }

            // SettingsDetailView.swift:438-514: Sound. There is no sound
            // subsystem on this stack yet, so every row below persists its
            // released value in SettingsStore and says "Saved" outright.
            SettingsSection {
                objectName: "soundSection"
                title: qsTr("Sound")
                subtitle: qsTr("Keep remote feedback quiet, distinct, and separate from playback.")
                icon: "speaker.wave.2.fill"
                accent: Theme.accentPrimary

                Column {
                    width: parent.width

                    ToggleRow {
                        id: interfaceSoundsRow
                        objectName: "interfaceSoundsRow"
                        width: parent.width
                        title: qsTr("Interface sounds · Saved")
                        subtitle: qsTr("Saved for a future sound update; the theater stays quiet until then.")
                        checked: root.settings.interfaceSounds
                        focused: root.isFocused("switch", "interfaceSounds")
                        onToggled: value => root.settings.interfaceSounds = value
                        onFocusedChanged: if (focused) scroller.reveal(interfaceSoundsRow)
                    }

                    SectionDivider { width: parent.width; inset: 20 }

                    ToggleRow {
                        id: launchIdentRow
                        objectName: "launchIdentRow"
                        width: parent.width
                        title: qsTr("Launch ident · Saved")
                        subtitle: qsTr("Saved for a future sound update; no ident plays at launch yet.")
                        checked: root.settings.launchIdentEnabled
                        focused: root.isFocused("switch", "launchIdentEnabled")
                        onToggled: value => root.settings.launchIdentEnabled = value
                        onFocusedChanged: if (focused) scroller.reveal(launchIdentRow)
                    }

                    SectionDivider { width: parent.width; inset: 20 }

                    // :475-514: the sound pack picker with its subtitle and
                    // the "Choose a pack" placeholder for no pack. The choice
                    // persists only; no cue player reads it yet.
                    Item {
                        id: soundPackRow
                        objectName: "soundPackRow"
                        readonly property bool focused: root.isFocused("picker", "soundPack")
                        width: parent.width
                        height: soundPackLabels.height + 40
                        onFocusedChanged: if (focused) scroller.reveal(soundPackRow)

                        Column {
                            id: soundPackLabels
                            anchors.left: parent.left
                            anchors.leftMargin: 20
                            anchors.right: soundPackPicker.left
                            anchors.rightMargin: 18
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 3

                            Text {
                                // AudioIdentityService.swift:45.
                                text: qsTr("Sound pack · Saved")
                                color: Theme.textPrimary
                                font.pixelSize: 14
                                font.weight: Font.Medium
                            }

                            Text {
                                text: qsTr("Saved for a future sound update; no cues play yet.")
                                color: Theme.textSecondary
                                font.pixelSize: 12
                            }
                        }

                        SettingsPicker {
                            id: soundPackPicker
                            objectName: "soundPackPicker"
                            anchors.right: parent.right
                            anchors.rightMargin: 20
                            anchors.verticalCenter: parent.verticalCenter
                            controlWidth: 180
                            options: root.settings.soundPacks
                            // AudioIdentityService.swift:39-41: the pack's
                            // display name is its raw value capitalized.
                            displayName: value => value.charAt(0).toUpperCase() + value.slice(1)
                            currentValue: root.settings.soundPack
                            placeholder: qsTr("Choose a pack")
                            focused: soundPackRow.focused
                            onSelected: value => root.settings.soundPack = value
                        }
                    }
                }
            }

            // SettingsDetailView.swift:562-585: Storage.
            SettingsSection {
                objectName: "storageSection"
                title: qsTr("Storage")
                subtitle: qsTr("Inspect local cache state, clear private history, and export diagnostics when needed.")
                icon: "internaldrive.fill"
                accent: Theme.textSecondary

                Column {
                    width: parent.width

                    // :587-677: the image cache row.
                    Item {
                        id: imageCacheRow
                        objectName: "imageCacheRow"
                        readonly property bool focused: root.isFocused("button", "clearCache")
                        width: parent.width
                        height: imageCacheLabels.height + 40
                        onFocusedChanged: if (focused) scroller.reveal(imageCacheRow)

                        Column {
                            id: imageCacheLabels
                            anchors.left: parent.left
                            anchors.leftMargin: 20
                            anchors.right: imageCacheControls.left
                            anchors.rightMargin: 16
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 3

                            Text {
                                text: qsTr("Image Cache")
                                color: Theme.textPrimary
                                font.pixelSize: 14
                                font.weight: Font.Medium
                            }

                            Text {
                                objectName: "imageCacheSummary"
                                width: parent.width
                                // :679-682. v3 decodes through Qt's image
                                // pipeline and keeps no hit/miss counters, so
                                // the summary carries the disk figure alone.
                                text: qsTr("Disk %1.").arg(root.session.imageCacheSize.toLowerCase())
                                color: Theme.textSecondary
                                font.pixelSize: 12
                                wrapMode: Text.WordWrap
                            }
                        }

                        Row {
                            id: imageCacheControls
                            anchors.right: parent.right
                            anchors.rightMargin: 20
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 0

                            Text {
                                objectName: "imageCacheSize"
                                anchors.verticalCenter: parent.verticalCenter
                                rightPadding: 12
                                text: root.session.imageCacheSize
                                color: Theme.textTertiary
                                font.pixelSize: 12
                            }

                            // :605-621: the measure control.
                            Item {
                                width: 24 + 8
                                height: 24
                                anchors.verticalCenter: parent.verticalCenter

                                MarqueeSymbol {
                                    anchors.left: parent.left
                                    anchors.verticalCenter: parent.verticalCenter
                                    visible: !root.session.measuringImageCache
                                    symbol: "arrow.clockwise"
                                    pointSize: 11
                                    color: Theme.textSecondary
                                }

                                BusyRing {
                                    anchors.left: parent.left
                                    anchors.verticalCenter: parent.verticalCenter
                                    visible: root.session.measuringImageCache
                                    running: visible
                                    size: 16
                                }

                                TapHandler {
                                    enabled: !root.session.measuringImageCache
                                    onTapped: root.session.measureImageCache()
                                }
                            }

                            // :623-674: confirm, cleared, or the clear control.
                            Row {
                                visible: root.showClearCacheConfirmation
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 8
                                opacity: visible ? 1 : 0
                                Behavior on opacity { NumberAnimation { duration: root.quickMotion } }

                                CapsuleButton {
                                    objectName: "clearCacheConfirmButton"
                                    text: qsTr("Clear")
                                    destructive: true
                                    focused: imageCacheRow.focused
                                    onActivated: {
                                        root.session.clearImageCache()
                                        root.showClearCacheConfirmation = false
                                    }
                                }

                                CapsuleButton {
                                    text: qsTr("Cancel")
                                    muted: true
                                    onActivated: root.showClearCacheConfirmation = false
                                }
                            }

                            Text {
                                objectName: "cacheClearedLabel"
                                visible: !root.showClearCacheConfirmation && root.session.cacheCleared
                                anchors.verticalCenter: parent.verticalCenter
                                text: qsTr("Cleared")
                                color: Theme.accentSecondary
                                font.pixelSize: 12
                                font.weight: Font.Medium
                            }

                            CapsuleButton {
                                objectName: "clearCacheButton"
                                visible: !root.showClearCacheConfirmation && !root.session.cacheCleared
                                anchors.verticalCenter: parent.verticalCenter
                                text: qsTr("Clear Cache")
                                focused: imageCacheRow.focused
                                onActivated: root.showClearCacheConfirmation = true
                            }
                        }
                    }

                    SectionDivider { width: parent.width; inset: 20 }

                    // :695-768: the watch history row.
                    Item {
                        id: watchHistoryRow
                        objectName: "watchHistoryRow"
                        readonly property bool focused: root.isFocused("button", "clearHistory")
                        width: parent.width
                        height: watchHistoryLabels.height + 40
                        onFocusedChanged: if (focused) scroller.reveal(watchHistoryRow)

                        Column {
                            id: watchHistoryLabels
                            anchors.left: parent.left
                            anchors.leftMargin: 20
                            anchors.right: watchHistoryControls.left
                            anchors.rightMargin: 16
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 3

                            Text {
                                text: qsTr("Watch History")
                                color: Theme.textPrimary
                                font.pixelSize: 14
                                font.weight: Font.Medium
                            }

                            Text {
                                width: parent.width
                                text: qsTr("Clears Continue Watching, Recently Watched, and every saved playback position and watched mark for this profile. Watched titles show in Recently Added again.")
                                color: Theme.textSecondary
                                font.pixelSize: 12
                                wrapMode: Text.WordWrap
                            }
                        }

                        Row {
                            id: watchHistoryControls
                            anchors.right: parent.right
                            anchors.rightMargin: 20
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 8

                            CapsuleButton {
                                objectName: "clearHistoryConfirmButton"
                                visible: root.showClearConfirmation
                                text: qsTr("Clear")
                                destructive: true
                                focused: watchHistoryRow.focused
                                onActivated: {
                                    root.session.clearWatchHistory()
                                    root.showClearConfirmation = false
                                }
                            }

                            CapsuleButton {
                                visible: root.showClearConfirmation
                                text: qsTr("Cancel")
                                muted: true
                                onActivated: root.showClearConfirmation = false
                            }

                            Text {
                                objectName: "historyClearedLabel"
                                visible: !root.showClearConfirmation && root.session.historyCleared
                                anchors.verticalCenter: parent.verticalCenter
                                text: qsTr("Cleared")
                                color: Theme.accentSecondary
                                font.pixelSize: 12
                                font.weight: Font.Medium
                            }

                            CapsuleButton {
                                objectName: "clearHistoryButton"
                                visible: !root.showClearConfirmation && !root.session.historyCleared
                                text: qsTr("Clear History")
                                focused: watchHistoryRow.focused
                                onActivated: root.showClearConfirmation = true
                            }
                        }
                    }

                    SectionDivider { width: parent.width; inset: 20 }

                    // :770-820: the diagnostics row.
                    Item {
                        id: diagnosticsRow
                        objectName: "diagnosticsRow"
                        readonly property bool focused: root.isFocused("button", "exportDiagnostics")
                        width: parent.width
                        height: diagnosticsLabels.height + 40
                        onFocusedChanged: if (focused) scroller.reveal(diagnosticsRow)

                        Column {
                            id: diagnosticsLabels
                            anchors.left: parent.left
                            anchors.leftMargin: 20
                            anchors.right: exportButton.left
                            anchors.rightMargin: 16
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 3

                            Text {
                                text: qsTr("Crash Diagnostics")
                                color: Theme.textPrimary
                                font.pixelSize: 14
                                font.weight: Font.Medium
                            }

                            Text {
                                width: parent.width
                                text: qsTr("Exports recent Marquee crash reports and app details for debugging.")
                                color: Theme.textSecondary
                                font.pixelSize: 12
                                wrapMode: Text.WordWrap
                            }

                            Text {
                                objectName: "diagnosticsSavedLabel"
                                visible: root.session.diagnosticsExportedPath.length > 0
                                width: parent.width
                                topPadding: 3
                                text: qsTr("Saved: %1").arg(root.session.diagnosticsExportedPath)
                                color: Theme.accentSecondary
                                font.pixelSize: 11
                                elide: Text.ElideMiddle
                            }

                            Text {
                                objectName: "diagnosticsFailedLabel"
                                visible: root.session.diagnosticsExportedPath.length === 0
                                    && root.session.diagnosticsExportFailed.length > 0
                                width: parent.width
                                topPadding: 3
                                text: root.session.diagnosticsExportFailed
                                color: Qt.rgba(1, 0.23, 0.19, 0.85)
                                font.pixelSize: 11
                                wrapMode: Text.WordWrap
                                maximumLineCount: 2
                                elide: Text.ElideRight
                            }
                        }

                        CapsuleButton {
                            id: exportButton
                            objectName: "exportDiagnosticsButton"
                            anchors.right: parent.right
                            anchors.rightMargin: 20
                            anchors.verticalCenter: parent.verticalCenter
                            icon: root.session.exportingDiagnostics ? "" : "square.and.arrow.up"
                            busy: root.session.exportingDiagnostics
                            text: root.session.exportingDiagnostics ? qsTr("Exporting...") : qsTr("Export")
                            enabled: !root.session.exportingDiagnostics
                            focused: diagnosticsRow.focused
                            onActivated: root.session.exportDiagnostics()
                        }
                    }
                }
            }

            // SettingsDetailView.swift:824-854: About.
            SettingsSection {
                objectName: "aboutSection"
                title: qsTr("About")
                subtitle: qsTr("Build identity for the local macOS screening room.")
                icon: "sparkles"
                accent: Theme.accentSecondary

                Column {
                    width: parent.width
                    padding: 20
                    spacing: 16

                    Item {
                        width: parent.width - 40
                        height: aboutWordmark.height

                        GradientWordmark {
                            id: aboutWordmark
                            anchors.left: parent.left
                            anchors.verticalCenter: parent.verticalCenter
                            text: "Marquee"
                            pointSize: 18
                            tracking: 0
                        }

                        Text {
                            objectName: "versionLabel"
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            text: qsTr("Version %1").arg(appController.version)
                            color: Theme.textTertiary
                            font.pixelSize: 13
                        }
                    }

                    Text {
                        text: qsTr("Premium Home Theater")
                        color: Theme.textSecondary
                        font.pixelSize: 13
                    }
                }
            }
        }
    }

    // SettingsDetailView.swift:135-174: one overview tile.
    component MetricTile: Rectangle {
        id: tile
        property string icon: ""
        property string title: ""
        property string value: ""
        property color accent: Theme.textSecondary

        readonly property real tilePadding: Theme.scaled(14, 20, root.leanBack)
        readonly property real iconSize: Theme.scaled(34, 50, root.leanBack)

        height: Math.max(Theme.scaled(72, 104, root.leanBack),
                         tileLabels.height + tilePadding * 2)
        radius: Theme.radiusMD
        color: Qt.rgba(Theme.surfaceLayer.r, Theme.surfaceLayer.g, Theme.surfaceLayer.b, 0.88)
        border.width: 1
        border.color: Qt.rgba(1, 1, 1, 0.045)

        Rectangle {
            id: iconBadge
            x: tile.tilePadding
            anchors.verticalCenter: parent.verticalCenter
            width: tile.iconSize
            height: tile.iconSize
            radius: width / 2
            color: Qt.rgba(tile.accent.r, tile.accent.g, tile.accent.b, 0.13)

            MarqueeSymbol {
                anchors.centerIn: parent
                symbol: tile.icon
                pointSize: Theme.scaled(16, 24, root.leanBack)
                color: tile.accent
            }
        }

        Column {
            id: tileLabels
            anchors.left: iconBadge.right
            anchors.leftMargin: Theme.scaled(12, 18, root.leanBack)
            anchors.right: parent.right
            anchors.rightMargin: tile.tilePadding
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2

            Text {
                width: parent.width
                text: tile.title.toUpperCase()
                color: Theme.textTertiary
                font.pixelSize: Theme.scaled(11, 16, root.leanBack)
                font.weight: Font.DemiBold
                elide: Text.ElideRight
            }

            Text {
                width: parent.width
                text: tile.value
                color: Theme.textPrimary
                font.pixelSize: Theme.scaled(15, 22, root.leanBack)
                font.weight: Font.DemiBold
                elide: Text.ElideRight
                // :159: the value may shrink to three quarters before it
                // elides.
                fontSizeMode: Text.HorizontalFit
                minimumPixelSize: Math.round(Theme.scaled(15, 22, root.leanBack) * 0.75)
            }
        }
    }

    // SettingsDetailView.swift:856-895: a titled section whose body sits on
    // the layered surface with the hairline border.
    component SettingsSection: Column {
        id: section
        property string title: ""
        property string subtitle: ""
        property string icon: ""
        property color accent: Theme.textSecondary
        default property alias body: sectionBody.data

        width: parent.width
        spacing: root.sectionSpacing

        Row {
            width: parent.width
            spacing: Theme.scaled(12, 18, root.leanBack)

            Rectangle {
                width: Theme.scaled(30, 44, root.leanBack)
                height: width
                radius: Theme.radiusMD
                color: Qt.rgba(section.accent.r, section.accent.g, section.accent.b, 0.13)

                MarqueeSymbol {
                    anchors.centerIn: parent
                    symbol: section.icon
                    pointSize: Theme.scaled(14, 21, root.leanBack)
                    color: section.accent
                }
            }

            Column {
                width: parent.width - Theme.scaled(30, 44, root.leanBack) - parent.spacing
                spacing: 3

                Text {
                    text: section.title
                    color: Theme.textPrimary
                    font.pixelSize: Theme.scaled(18, 26, root.leanBack)
                    font.weight: Font.Bold
                }

                Text {
                    width: parent.width
                    text: section.subtitle
                    color: Theme.textSecondary
                    font.pixelSize: Theme.scaled(12, 17, root.leanBack)
                    font.weight: Font.Medium
                    wrapMode: Text.WordWrap
                    maximumLineCount: 2
                    elide: Text.ElideRight
                }
            }
        }

        Rectangle {
            id: sectionBody
            width: parent.width
            height: childrenRect.height
            radius: Theme.radiusMD
            color: Theme.surfaceLayer
            border.width: 1
            border.color: Qt.rgba(1, 1, 1, 0.045)
        }
    }

    // :191-192: the section divider.
    component SectionDivider: Item {
        property real inset: 0
        height: 1

        Rectangle {
            x: parent.inset
            width: parent.width - parent.inset * 2
            height: 1
            color: Qt.rgba(Theme.textTertiary.r, Theme.textTertiary.g, Theme.textTertiary.b, 0.3)
        }
    }

    // :415-434: a titled row with a subtitle and the trailing switch.
    component ToggleRow: Item {
        id: toggleRow
        property string title: ""
        property string subtitle: ""
        property bool checked: false
        property bool focused: false
        property real inset: 20
        signal toggled(bool value)

        height: toggleLabels.height + 40

        Column {
            id: toggleLabels
            anchors.left: parent.left
            anchors.leftMargin: toggleRow.inset
            anchors.right: toggle.left
            anchors.rightMargin: 16
            anchors.verticalCenter: parent.verticalCenter
            spacing: 3

            Text {
                width: parent.width
                text: toggleRow.title
                color: Theme.textPrimary
                font.pixelSize: 14
                font.weight: Font.Medium
                elide: Text.ElideRight
            }

            Text {
                width: parent.width
                text: toggleRow.subtitle
                color: Theme.textSecondary
                font.pixelSize: 12
                wrapMode: Text.WordWrap
            }
        }

        SettingsSwitch {
            id: toggle
            anchors.right: parent.right
            anchors.rightMargin: toggleRow.inset
            anchors.verticalCenter: parent.verticalCenter
            checked: toggleRow.checked
            focused: toggleRow.focused
            onToggled: value => toggleRow.toggled(value)
        }
    }

    // :541-558: a titled row with the trailing picker.
    component PickerRow: Item {
        id: pickerRow
        property string title: ""
        property bool focused: false
        default property alias control: pickerHolder.data

        height: 24 + 40

        Text {
            anchors.left: parent.left
            anchors.leftMargin: 20
            anchors.right: pickerHolder.left
            anchors.rightMargin: 16
            anchors.verticalCenter: parent.verticalCenter
            text: pickerRow.title
            color: Theme.textPrimary
            font.pixelSize: 14
            font.weight: Font.Medium
            elide: Text.ElideRight
        }

        Item {
            id: pickerHolder
            anchors.right: parent.right
            anchors.rightMargin: 20
            anchors.verticalCenter: parent.verticalCenter
            width: childrenRect.width
            height: childrenRect.height
        }
    }

    // :323-345 and :661-673: a capsule button on the elevated surface, red
    // for a destructive confirm (:636) and muted for Cancel (:645-650).
    component CapsuleButton: Rectangle {
        id: capsule
        property string text: ""
        property string icon: ""
        property bool busy: false
        property bool destructive: false
        property bool muted: false
        property bool focused: false
        property real textSize: 12
        property real horizontalPadding: 14
        property real verticalPadding: 5
        signal activated()

        width: capsuleRow.width + horizontalPadding * 2
        height: capsuleRow.height + verticalPadding * 2
        radius: height / 2
        color: capsule.destructive ? Qt.rgba(1, 0.23, 0.19, 0.8) : Theme.surfaceElevated
        border.width: capsule.focused ? 2 : 0
        border.color: Theme.structuralFocus
        opacity: enabled ? 1 : 0.5

        Row {
            id: capsuleRow
            anchors.centerIn: parent
            spacing: 6

            BusyRing {
                anchors.verticalCenter: parent.verticalCenter
                visible: capsule.busy
                running: visible
                size: 12
            }

            MarqueeSymbol {
                anchors.verticalCenter: parent.verticalCenter
                visible: capsule.icon.length > 0
                symbol: capsule.icon
                pointSize: capsule.textSize - 1
                color: capsule.destructive ? "white" : Theme.textPrimary
            }

            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: capsule.text
                color: capsule.destructive ? "white"
                    : (capsule.muted ? Theme.textSecondary : Theme.textPrimary)
                font.pixelSize: capsule.textSize
                font.weight: capsule.muted ? Font.Medium : Font.DemiBold
            }
        }

        TapHandler {
            enabled: capsule.enabled
            onTapped: capsule.activated()
        }
    }

    // :327-330 and :606-610: the small progress ring in a button.
    component BusyRing: Item {
        id: ring
        property bool running: false
        property real size: 14
        width: size
        height: size

        Canvas {
            id: ringCanvas
            anchors.fill: parent
            onPaint: {
                const context = getContext("2d")
                context.clearRect(0, 0, width, height)
                context.strokeStyle = Theme.textSecondary
                context.lineWidth = Math.max(1.5, width * 0.12)
                context.lineCap = "round"
                context.beginPath()
                context.arc(width / 2, height / 2, width / 2 - context.lineWidth,
                            0, Math.PI * 1.5)
                context.stroke()
            }
            Component.onCompleted: requestPaint()
        }

        RotationAnimation on rotation {
            running: ring.running && !root.reduceMotion
            from: 0
            to: 360
            duration: 900
            loops: Animation.Infinite
        }
    }
}
