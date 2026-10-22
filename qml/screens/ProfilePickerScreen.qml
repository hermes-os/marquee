import QtQuick
import Marquee 3.0

// Marquee/Features/Settings/Views/ProfilePickerView.swift:552-601 composes the
// picker: the gradient backdrop, the MARQUEE header block, the row of profile
// cards with the Add Profile card after them, and the Manage Profiles capsule;
// :1084-1116 the editor overlay above them; :591-600 the delete alert.
FocusScope {
    id: root

    property bool leanBack: appController.settings.leanBackMode
    property bool reduceMotion: appController.settings.reduceMotion

    readonly property var store: appController.profiles
    readonly property int profileCount: root.store.count
    readonly property bool canAddProfile: root.store.canAddProfile

    // ProfilePickerView.swift:495-497: management mode swaps the cards for
    // tiles and the capsule's label for Done.
    property bool managing: false

    // ProfilePickerView.swift:3-8: what the remote is on. `kind` is one of
    // "profile", "action", "add", or "manage"; `profileId` names the card for
    // the first two, and `action` is 0-3 for moveLeft, edit, delete, moveRight
    // (MarqueeTheme.swift:17-22), which is the only order the row is drawn in.
    property string focusKind: "profile"
    property string focusProfileId: ""
    property int focusAction: 1

    // ProfilePickerView.swift:1073-1084 and ContentView.swift:31-39: once a
    // choice is made the picker keeps its layout, stops taking input, and
    // fades out over the exit transition.
    readonly property bool exitInFlight: appController.profileExitInFlight
    readonly property string exitSelectionId: appController.profileExitSelectionId

    // ProfilePickerView.swift:498-505: the editor is a modal overlay carrying
    // the profile being edited, or none for a new one.
    property bool editorOpen: false
    property string editingProfileId: ""

    // ProfilePickerView.swift:507 and :591-600: one profile awaiting the
    // delete confirmation.
    property string pendingDeleteId: ""

    // ProfilePickerView.swift:535-543 counts the profile-filtered library.
    readonly property int movieCount: appController.library.titleCount
    readonly property int episodeCount: appController.shows.episodeCount
    readonly property string librarySummary: {
        const movies = root.movieCount === 1
            ? qsTr("%1 movie").arg(root.movieCount)
            : qsTr("%1 movies").arg(root.movieCount)
        const episodes = root.episodeCount === 1
            ? qsTr("%1 episode").arg(root.episodeCount)
            : qsTr("%1 episodes").arg(root.episodeCount)
        return movies + "  /  " + episodes
    }

    focus: true

    opacity: root.exitInFlight ? 0 : 1
    Behavior on opacity {
        // MarqueeTheme.swift:71 and :256: the exit fades over 0.24 seconds,
        // ease-in-out, whatever Reduce Motion says (ContentView.swift:33-36
        // animates it unconditionally).
        NumberAnimation {
            objectName: "profilePickerExitFade"
            duration: 240
            easing.type: Easing.InOutQuad
        }
    }

    // ProfilePickerView.swift:605-627: the base colour under an amethyst
    // wash top-leading to bottom-trailing, then a vertical black vignette.
    Rectangle {
        objectName: "profilePickerBackdrop"
        anchors.fill: parent
        color: Theme.background
    }

    Rectangle {
        anchors.fill: parent
        rotation: 0
        gradient: Gradient {
            orientation: Gradient.Vertical
            GradientStop { position: 0.0; color: Qt.rgba(0, 0, 0, 0.62) }
            GradientStop { position: 0.5; color: Qt.rgba(0, 0, 0, 0) }
            GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.68) }
        }
        z: 1
    }

    // The diagonal wash is painted below the vignette in the released
    // ZStack order (:607-616 before :617-625). A Rectangle gradient runs on
    // one axis only, so the diagonal is drawn.
    Canvas {
        objectName: "profilePickerWash"
        anchors.fill: parent
        z: 0

        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()

        onPaint: {
            const context = getContext("2d")
            context.reset()
            context.clearRect(0, 0, width, height)
            const wash = context.createLinearGradient(0, 0, width, height)
            wash.addColorStop(0, Qt.rgba(Theme.accentPrimary.r, Theme.accentPrimary.g,
                                         Theme.accentPrimary.b, 0.24))
            wash.addColorStop(0.5, Qt.rgba(0, 0, 0, 0))
            wash.addColorStop(1, Qt.rgba(0, 0, 0, 0.36))
            context.fillStyle = wash
            context.fillRect(0, 0, width, height)
        }
    }

    // :555-565 centres the header, the row, and the manage control in one
    // stack spaced 40/60, between two spacers.
    Column {
        id: stack
        objectName: "profilePickerStack"

        anchors.centerIn: parent
        width: parent.width
        spacing: Theme.scaled(40, 60, root.leanBack)
        z: 2

        // :634-648: MARQUEE in the title gradient at 34/52 with 8/12 tracking,
        // the prompt at 22/32 semibold, and the summary at 12/17 medium,
        // spaced 10/16.
        Column {
            id: headerBlock
            objectName: "profilePickerHeader"

            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Theme.scaled(10, 16, root.leanBack)

            GradientWordmark {
                objectName: "profilePickerWordmark"
                anchors.horizontalCenter: parent.horizontalCenter
                pointSize: Theme.scaled(34, 52, root.leanBack)
                tracking: Theme.scaled(8, 12, root.leanBack)
            }

            Text {
                objectName: "profilePickerPrompt"
                anchors.horizontalCenter: parent.horizontalCenter
                text: root.managing ? qsTr("Manage Profiles") : qsTr("Who's watching?")
                color: Theme.textPrimary
                font.pixelSize: Theme.scaled(22, 32, root.leanBack)
                font.weight: Font.DemiBold
            }

            Text {
                objectName: "profilePickerSummary"
                anchors.horizontalCenter: parent.horizontalCenter
                text: root.librarySummary
                color: Theme.textTertiary
                font.pixelSize: Theme.scaled(12, 17, root.leanBack)
                font.weight: Font.Medium
            }
        }

        // :652-662 is the selection row; :664-690 the management row that
        // replaces it. Both are one horizontal run of the profiles, then the
        // Add Profile item while there is room for another profile.
        Item {
            id: rowHost
            objectName: "profilePickerRow"

            anchors.horizontalCenter: parent.horizontalCenter
            width: root.managing ? parent.width : selectionRow.width
            height: root.managing ? 280 : selectionRow.height

            Row {
                id: selectionRow
                objectName: "profileSelectionRow"

                visible: !root.managing
                anchors.horizontalCenter: parent.horizontalCenter
                // :438-440: 24/38 between items.
                spacing: Theme.scaled(24, 38, root.leanBack)

                Repeater {
                    id: cardRepeater
                    objectName: "profileCards"
                    model: root.store

                    delegate: ProfileCard {
                        required property string profileId
                        required property string name
                        required property string avatarIcon
                        required property color avatarColor
                        required property string maturityLabel

                        objectName: "profileCard_" + profileId
                        leanBack: root.leanBack
                        reduceMotion: root.reduceMotion
                        // :435-437: the card column is 150/220 wide.
                        width: Theme.scaled(150, 220, root.leanBack)
                        title: name
                        subtitle: maturityLabel
                        symbol: avatarIcon
                        symbolColor: avatarColor
                        remoteFocused: root.focusKind === "profile"
                            && root.focusProfileId === profileId
                        // :737 and :766: the chosen card keeps its ring and
                        // focused chrome through the exit fade.
                        selected: root.exitSelectionId === profileId

                        onActivated: root.chooseProfile(profileId)
                    }
                }

                // :812-895: the Add Profile card, drawn on the surface layer
                // with the ultralight plus, and a blank subtitle line that
                // keeps its height level with the profiles' maturity labels.
                ProfileCard {
                    id: addCard
                    objectName: "profileAddCard"

                    visible: root.canAddProfile
                    leanBack: root.leanBack
                    reduceMotion: root.reduceMotion
                    width: Theme.scaled(150, 220, root.leanBack)
                    title: qsTr("Add Profile")
                    subtitle: " "
                    symbol: "plus.circle"
                    symbolColor: Theme.textTertiary
                    symbolStrokeRatio: 0.045
                    discColor: Theme.surfaceLayer
                    addStyle: true
                    remoteFocused: root.focusKind === "add"

                    onActivated: root.openEditor("")
                }
            }

            // :664-690 and :10-128: the management row resolves one tile
            // width and spacing from the available width, so five tiles fit
            // the 1100-point minimum.
            Row {
                id: managementRow
                objectName: "profileManagementRow"

                visible: root.managing
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: root.managementGeometry.spacing

                Repeater {
                    id: tileRepeater
                    objectName: "profileManagementTiles"
                    model: root.store

                    delegate: ProfileManagementTile {
                        required property string profileId
                        required property string name
                        required property string avatarIcon
                        required property color avatarColor
                        required property string maturityLabel
                        required property int index

                        objectName: "profileTile_" + profileId
                        width: root.managementGeometry.tileWidth
                        height: 280
                        title: name
                        subtitle: maturityLabel
                        symbol: avatarIcon
                        symbolColor: avatarColor
                        // MarqueeTheme.swift:24-34: the ends cannot move
                        // outward, and the last profile cannot be deleted.
                        canMoveLeft: index > 0
                        canMoveRight: index < root.profileCount - 1
                        canDelete: root.profileCount > 1
                        tileFocused: root.focusKind === "profile"
                            && root.focusProfileId === profileId
                        focusedAction: root.focusKind === "action"
                            && root.focusProfileId === profileId
                            ? root.focusAction : -1

                        onEditRequested: root.openEditor(profileId)
                        onDeleteRequested: root.pendingDeleteId = profileId
                        onMoveLeftRequested: root.moveProfile(profileId, -1)
                        onMoveRightRequested: root.moveProfile(profileId, 1)
                    }
                }

                ProfileCard {
                    objectName: "profileAddTile"

                    visible: root.canAddProfile
                    leanBack: root.leanBack
                    reduceMotion: root.reduceMotion
                    width: root.managementGeometry.tileWidth
                    height: 280
                    title: qsTr("Add Profile")
                    subtitle: " "
                    symbol: "plus.circle"
                    symbolColor: Theme.textTertiary
                    symbolStrokeRatio: 0.045
                    discColor: Theme.surfaceLayer
                    addStyle: true
                    // :872-883: in management the add item sits on its own
                    // 0.86 surface panel with the structural ring on focus.
                    managementPanel: true
                    remoteFocused: root.focusKind === "add"

                    onActivated: root.openEditor("")
                }
            }
        }

        // :899-935: the Manage Profiles / Done capsule, 8 points below the
        // row's own spacing.
        Item {
            objectName: "profileManageControl"
            anchors.horizontalCenter: parent.horizontalCenter
            width: manageCapsule.width
            height: manageCapsule.height + 8

            readonly property bool remoteFocused: root.focusKind === "manage"

            Rectangle {
                id: manageCapsule
                objectName: "profileManageCapsule"

                anchors.bottom: parent.bottom
                width: manageLabel.width + 2 * Theme.scaled(24, 36, root.leanBack)
                height: manageLabel.height + 2 * Theme.scaled(10, 16, root.leanBack)
                radius: height / 2
                color: "transparent"
                border.width: parent.remoteFocused ? 2 : 1
                border.color: parent.remoteFocused
                    ? Theme.structuralFocus
                    : Qt.rgba(Theme.textTertiary.r, Theme.textTertiary.g,
                              Theme.textTertiary.b, 0.4)

                Text {
                    id: manageLabel
                    objectName: "profileManageLabel"
                    anchors.centerIn: parent
                    text: root.managing ? qsTr("Done") : qsTr("Manage Profiles")
                    color: parent.parent.remoteFocused ? Theme.textPrimary : Theme.textSecondary
                    font.pixelSize: Theme.scaled(14, 20, root.leanBack)
                    font.weight: Font.Medium
                }

                TapHandler {
                    enabled: !root.exitInFlight
                    onTapped: root.toggleManaging()
                }
            }

            // :922-926: a soft structural glow under the focused capsule.
            SoftShadow {
                anchors.fill: manageCapsule
                radius: manageCapsule.radius
                visible: parent.remoteFocused
                shadowColor: Qt.rgba(Theme.structuralFocus.r, Theme.structuralFocus.g,
                                     Theme.structuralFocus.b, 0.25)
                blur: 10
                offsetY: 4
                z: -1
            }

            Accessible.role: Accessible.Button
            Accessible.name: root.managing ? qsTr("Done managing profiles") : qsTr("Manage profiles")
        }
    }

    // :1084-1116: the editor over a 0.7 black scrim that dismisses on tap,
    // entering at 0.9 scale with opacity.
    Item {
        id: editorOverlay
        objectName: "profileEditorOverlay"

        anchors.fill: parent
        visible: root.editorOpen || editorFade.running
        z: 10

        Rectangle {
            anchors.fill: parent
            color: Qt.rgba(0, 0, 0, 0.7)
            opacity: root.editorOpen ? 1 : 0
            Behavior on opacity {
                NumberAnimation { id: editorFade; duration: Theme.motionPage; easing.type: Easing.OutCubic }
            }
            TapHandler { onTapped: root.closeEditor() }
        }

        ProfileEditor {
            id: editor
            objectName: "profileEditor"

            anchors.centerIn: parent
            leanBack: root.leanBack
            reduceMotion: root.reduceMotion
            store: root.store
            editingProfileId: root.editingProfileId
            canDelete: root.editingProfileId.length > 0 && root.profileCount > 1
            active: root.editorOpen

            scale: root.editorOpen ? 1 : 0.9
            opacity: root.editorOpen ? 1 : 0
            Behavior on scale {
                enabled: !root.reduceMotion
                NumberAnimation { duration: Theme.motionPage; easing.type: Easing.OutCubic }
            }
            Behavior on opacity {
                NumberAnimation { duration: Theme.motionPage; easing.type: Easing.OutCubic }
            }

            onSaved: (profileId, name, avatarIcon, avatarColor, maturityLevel) => {
                if (profileId.length > 0) {
                    root.store.updateProfile(profileId, name, avatarIcon, avatarColor, maturityLevel)
                } else {
                    const created = root.store.addProfile(name, avatarIcon, avatarColor, maturityLevel)
                    if (created.length > 0) {
                        root.focusKind = "profile"
                        root.focusProfileId = created
                    }
                }
                appController.reconcileActiveProfile()
                root.closeEditor()
            }
            onDeleted: profileId => {
                root.deleteProfile(profileId)
                root.closeEditor()
            }
            onCancelled: root.closeEditor()
        }
    }

    // :591-600: "Delete <name>?" with the removal message, a destructive
    // Delete, and Cancel.
    ConfirmDialog {
        id: deleteDialog
        objectName: "profileDeleteDialog"

        anchors.fill: parent
        z: 11
        open: root.pendingDeleteId.length > 0
        title: qsTr("Delete %1?").arg(root.store.profileById(root.pendingDeleteId).name || "")
        message: qsTr("This removes the profile from Marquee.")
        confirmLabel: qsTr("Delete")
        destructive: true
        leanBack: root.leanBack

        onConfirmed: {
            const id = root.pendingDeleteId
            root.pendingDeleteId = ""
            root.deleteProfile(id)
        }
        onDismissed: root.pendingDeleteId = ""
    }

    // ProfilePickerView.swift:10-128 resolves the management tiles from the
    // width the row has: the released 220 tile and 24 spacing when they fit,
    // squeezed no narrower than 184 and 12 otherwise.
    readonly property var managementGeometry: {
        const count = root.profileCount + (root.canAddProfile ? 1 : 0)
        const usable = Math.max(0, rowHost.width - 2 * 32)
        if (count === 0) {
            return { tileWidth: 0, spacing: 0 }
        }
        const gaps = Math.max(0, count - 1)
        let spacing = 0
        if (gaps > 0) {
            const atMinimum = (usable - count * 184) / gaps
            spacing = Math.min(24, Math.max(12, atMinimum))
        }
        let tileWidth = (usable - gaps * spacing) / count
        tileWidth = Math.min(220, Math.max(0, tileWidth))
        if (gaps > 0 && tileWidth < 184) {
            spacing = Math.max(0, Math.min(spacing, (usable - count * 184) / gaps))
            tileWidth = Math.min(220, Math.max(0, (usable - gaps * spacing) / count))
        }
        return { tileWidth: tileWidth, spacing: spacing }
    }

    // ProfilePickerView.swift:132-141: the top row is every profile, then the
    // add item when one more is admitted.
    function topRowTargets() {
        const targets = []
        for (let index = 0; index < root.profileCount; ++index) {
            targets.push({ kind: "profile", profileId: root.store.profileAt(index).profileId })
        }
        if (root.canAddProfile) {
            targets.push({ kind: "add", profileId: "" })
        }
        return targets
    }

    // MarqueeTheme.swift:24-34: which of the four actions a profile offers.
    function enabledActions(profileId) {
        const index = root.store.indexOf(profileId)
        if (index < 0) {
            return []
        }
        const actions = []
        if (index > 0) actions.push(0)
        actions.push(1)
        if (root.profileCount > 1) actions.push(2)
        if (index < root.profileCount - 1) actions.push(3)
        return actions
    }

    // ProfilePickerView.swift:153-185: keep the focus on something that
    // exists, falling back to the first top-row item, then the manage control.
    function reconcileFocus() {
        const targets = root.topRowTargets()
        if (root.focusKind === "profile" && root.store.indexOf(root.focusProfileId) >= 0) {
            return
        }
        if (root.focusKind === "action" && root.store.indexOf(root.focusProfileId) >= 0) {
            if (root.managing && root.enabledActions(root.focusProfileId).indexOf(root.focusAction) >= 0) {
                return
            }
            root.focusKind = "profile"
            return
        }
        if (root.focusKind === "add" && root.canAddProfile) {
            return
        }
        if (root.focusKind === "manage") {
            return
        }
        if (targets.length > 0) {
            root.focusKind = targets[0].kind
            root.focusProfileId = targets[0].profileId
        } else {
            root.focusKind = "manage"
            root.focusProfileId = ""
        }
    }

    // ProfilePickerView.swift:187-235: Left and Right run along the top row
    // or, from a management action, along that profile's actions; Down from a
    // profile enters its first enabled action while managing, or reaches the
    // manage control; Up returns. Left and Right on the manage control wrap
    // into the far ends of the top row.
    function moveFocus(direction) {
        root.reconcileFocus()
        const targets = root.topRowTargets()
        const indexInTop = targets.findIndex(target =>
            target.kind === root.focusKind
            && (target.kind !== "profile" || target.profileId === root.focusProfileId))

        if (root.focusKind === "manage") {
            if (direction === "up") {
                if (root.managing && root.profileCount > 0) {
                    // Up from the capsule lands on the last profile's actions
                    // only from that profile; a fresh entry takes the row.
                    root.focusKind = "profile"
                    root.focusProfileId = targets[0].profileId
                } else if (targets.length > 0) {
                    root.focusKind = targets[0].kind
                    root.focusProfileId = targets[0].profileId
                }
                return true
            }
            if (direction === "left" && targets.length > 0) {
                const last = targets[targets.length - 1]
                root.focusKind = last.kind
                root.focusProfileId = last.profileId
                return true
            }
            if (direction === "right" && targets.length > 0) {
                root.focusKind = targets[0].kind
                root.focusProfileId = targets[0].profileId
                return true
            }
            return false
        }

        if (root.focusKind === "action") {
            const actions = root.enabledActions(root.focusProfileId)
            const position = actions.indexOf(root.focusAction)
            if (direction === "left" && position > 0) {
                root.focusAction = actions[position - 1]
                return true
            }
            if (direction === "right" && position < actions.length - 1) {
                root.focusAction = actions[position + 1]
                return true
            }
            if (direction === "up") {
                root.focusKind = "profile"
                return true
            }
            if (direction === "down") {
                root.focusKind = "manage"
                return true
            }
            return false
        }

        // A profile or the add item on the top row.
        if (direction === "left" && indexInTop > 0) {
            const target = targets[indexInTop - 1]
            root.focusKind = target.kind
            root.focusProfileId = target.profileId
            return true
        }
        if (direction === "right" && indexInTop >= 0 && indexInTop < targets.length - 1) {
            const target = targets[indexInTop + 1]
            root.focusKind = target.kind
            root.focusProfileId = target.profileId
            return true
        }
        if (direction === "down") {
            if (root.managing && root.focusKind === "profile") {
                const actions = root.enabledActions(root.focusProfileId)
                if (actions.length > 0) {
                    root.focusKind = "action"
                    root.focusAction = actions[0]
                    return true
                }
            }
            root.focusKind = "manage"
            return true
        }
        return false
    }

    // ProfilePickerView.swift:359-394: what Select does where the focus is.
    function activateFocus() {
        root.reconcileFocus()
        switch (root.focusKind) {
        case "profile":
            if (root.managing) {
                root.openEditor(root.focusProfileId)
            } else {
                root.chooseProfile(root.focusProfileId)
            }
            return
        case "action":
            switch (root.focusAction) {
            case 0: root.moveProfile(root.focusProfileId, -1); return
            case 1: root.openEditor(root.focusProfileId); return
            case 2: root.pendingDeleteId = root.focusProfileId; return
            case 3: root.moveProfile(root.focusProfileId, 1); return
            }
            return
        case "add":
            root.openEditor("")
            return
        case "manage":
            root.toggleManaging()
            return
        }
    }

    function chooseProfile(profileId) {
        if (root.exitInFlight || root.managing) {
            return
        }
        root.focusKind = "profile"
        root.focusProfileId = profileId
        appController.chooseProfile(profileId)
    }

    // ProfilePickerView.swift:1022-1031.
    function toggleManaging() {
        root.managing = !root.managing
        if (!root.managing && root.focusKind === "action") {
            root.focusKind = "profile"
        }
    }

    function openEditor(profileId) {
        root.editingProfileId = profileId
        root.editorOpen = true
        editor.forceActiveFocus()
    }

    function closeEditor() {
        root.editorOpen = false
        root.forceActiveFocus()
    }

    // ProfilePickerView.swift:1040-1051: the moved profile keeps the focus.
    function moveProfile(profileId, direction) {
        root.store.moveProfile(profileId, direction)
        root.focusKind = root.focusKind === "action" ? "action" : "profile"
        root.focusProfileId = profileId
    }

    // ProfilePickerView.swift:1053-1067 and :396-433: after a deletion the
    // focus stays on the same index when the deleted profile held it.
    function deleteProfile(profileId) {
        const deletedIndex = root.store.indexOf(profileId)
        const hadFocus = root.focusProfileId === profileId
        root.store.deleteProfile(profileId)
        if (hadFocus) {
            if (root.profileCount > 0) {
                const index = Math.min(deletedIndex, root.profileCount - 1)
                root.focusKind = "profile"
                root.focusProfileId = root.store.profileAt(index).profileId
            } else {
                root.focusKind = "manage"
                root.focusProfileId = ""
            }
        }
        appController.reconcileActiveProfile()
        root.reconcileFocus()
    }

    Connections {
        target: root.store
        function onCountChanged() { root.reconcileFocus() }
    }

    Component.onCompleted: {
        // ProfilePickerView.swift:511-521: the picker opens on the active
        // profile when there is one, else the first.
        const active = appController.activeProfileId
        if (active.length > 0 && root.store.indexOf(active) >= 0) {
            root.focusKind = "profile"
            root.focusProfileId = active
        }
        root.reconcileFocus()
    }

    // ProfilePickerView.swift:924-983: the whole remote map. Nothing is
    // accepted while the exit is in flight, and the editor owns its own keys.
    Keys.onPressed: event => {
        if (root.exitInFlight) {
            event.accepted = true
            return
        }
        if (root.editorOpen) {
            if (event.key === Qt.Key_Escape || event.key === Qt.Key_Back) {
                root.closeEditor()
                event.accepted = true
            }
            return
        }
        if (root.pendingDeleteId.length > 0) {
            return
        }
        if (event.isAutoRepeat
            && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                || event.key === Qt.Key_Escape || event.key === Qt.Key_Back)) {
            event.accepted = true
            return
        }
        switch (event.key) {
        case Qt.Key_Left:
            root.moveFocus("left")
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
        case Qt.Key_Escape:
        case Qt.Key_Back:
        case Qt.Key_Backspace:
            // :967-970: Back leaves management; otherwise the picker is the
            // root surface and the key is consumed here.
            if (root.managing) {
                root.toggleManaging()
            }
            event.accepted = true
            return
        default:
            event.accepted = false
        }
    }
}
