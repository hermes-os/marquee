import QtQuick
import Marquee 3.0

// Marquee/Features/Search/Views/SearchView.swift:109-231: the search route.
// A vertical scroll of the search bar with its suggestions (:234-288,
// :559-591), the remote keyboard when the remote has opened it (:290-296),
// and the results (:866-950) or one of the landing, pending, and empty states
// (:1255-1324), padded by the outer padding on the sides and bottom.
//
// Remote focus is one of :34-40's states: inactive (the sidebar has it),
// field, suggestions(index), keyboard(row, column), or results(index). Each
// command is routed by the released policy functions cited beside it.
FocusScope {
    id: root

    signal requestSidebarFocus()

    property bool leanBack: appController.settings.leanBackMode
    property bool kidsMode: appController.kidsMode
    property bool reduceMotion: appController.settings.reduceMotion
    readonly property var session: appController.search

    // SearchView.swift:34-40.
    readonly property string focusInactive: "inactive"
    readonly property string focusField: "field"
    readonly property string focusSuggestions: "suggestions"
    readonly property string focusKeyboard: "keyboard"
    readonly property string focusResults: "results"
    property string remoteFocus: root.focusField
    property int suggestionIndex: -1
    property int keyboardRow: -1
    property int keyboardColumn: -1
    property int resultIndex: -1
    // :24 and :622-628: the keyboard, once shown, stays until the field or
    // the sidebar takes over; :25 remembers where the keyboard cursor was.
    property bool keyboardPresented: false
    property int lastKeyboardRow: 1
    property int lastKeyboardColumn: 0
    // :17 and :167-169: suggestions show for a non-blank query while the
    // keyboard is away, and any edit clears a suggestion choice.
    property bool showSuggestions: false
    // :592-608: a chosen suggestion rewrites the query without the edit
    // handler pulling the remote back to the field.
    property bool applyingSuggestion: false

    readonly property string trimmedQuery: root.session.trimmedQuery
    readonly property bool hasQuery: root.trimmedQuery.length > 0
    readonly property var suggestions: root.session.suggestions
    readonly property bool hasVisibleSuggestions:
        root.showSuggestions && root.suggestions.length > 0
    readonly property int resultCount: root.session.totalCount

    // :92-98 and RemoteSearchKeyboardPolicy.swift:256-263: adaptive columns
    // of at least 130/200 points at the card gap.
    readonly property real minimumCardWidth: Theme.scaled(130, 200, root.leanBack)
    readonly property real resultSpacing: Theme.cardGap(root.leanBack)
    readonly property real outerPadding: Theme.outerPadding(root.leanBack)
    readonly property real sectionSpacing:
        Theme.scaled(Theme.sectionSpacingCompact, Theme.sectionSpacingLeanBack, root.leanBack)

    // ContentView.swift:167-173 and SearchView.swift:162-166: arriving on the
    // route puts the remote on the field.
    Component.onCompleted: enterFieldFocus()
    onActiveFocusChanged: {
        if (root.activeFocus && root.remoteFocus === root.focusInactive) {
            // :198-204: the sidebar handed the remote back.
            enterFieldFocus()
        }
    }

    function setQuery(text) {
        root.session.query = text
    }

    // SearchView.swift:167-176.
    Connections {
        target: root.session
        function onQueryChanged() {
            root.suggestionIndex = -1
            root.showSuggestions = root.hasQuery && !root.keyboardPresented
            if (root.remoteFocus === root.focusResults
                    || root.remoteFocus === root.focusSuggestions) {
                if (!root.applyingSuggestion) {
                    root.remoteFocus = root.focusField
                    root.resultIndex = -1
                }
            }
        }
    }

    // :619-625.
    function enterFieldFocus() {
        root.keyboardPresented = false
        root.remoteFocus = root.focusField
        root.showSuggestions = root.hasQuery
        root.suggestionIndex = -1
        root.resultIndex = -1
        root.keyboardRow = -1
        root.keyboardColumn = -1
        field.forceActiveFocus()
    }

    // :626-634 and :649-654.
    function enterKeyboardFocus(resetToInitial) {
        const focus = resetToInitial
            ? keyboard.initialFocus()
            : (root.keyboardRow >= 0
                ? { row: root.keyboardRow, column: root.keyboardColumn }
                : { row: root.lastKeyboardRow, column: root.lastKeyboardColumn })
        setKeyboardFocus(focus.row, focus.column)
        root.showSuggestions = false
        root.suggestionIndex = -1
    }

    function setKeyboardFocus(row, column) {
        field.focus = false
        root.lastKeyboardRow = row
        root.lastKeyboardColumn = column
        root.keyboardPresented = true
        root.keyboardRow = row
        root.keyboardColumn = column
        root.remoteFocus = root.focusKeyboard
        root.resultIndex = -1
        commands.forceActiveFocus()
    }

    // :655-668.
    function setSuggestionFocus(index) {
        if (root.suggestions.length === 0) {
            enterFieldFocus()
            return
        }
        field.focus = false
        root.keyboardPresented = false
        const clamped = Math.min(Math.max(0, index), root.suggestions.length - 1)
        root.remoteFocus = root.focusSuggestions
        root.showSuggestions = true
        root.suggestionIndex = clamped
        root.resultIndex = -1
        commands.forceActiveFocus()
    }

    // :669-675.
    function setResultFocus(index) {
        field.focus = false
        root.remoteFocus = root.focusResults
        root.resultIndex = index
        root.showSuggestions = false
        root.suggestionIndex = -1
        commands.forceActiveFocus()
        root.scrollResultIntoView(index)
    }

    // :638-648: the sidebar owns the remote.
    function enterInactiveFocus() {
        field.focus = false
        root.keyboardPresented = false
        root.remoteFocus = root.focusInactive
        root.showSuggestions = false
        root.suggestionIndex = -1
        root.resultIndex = -1
        root.keyboardRow = -1
        root.keyboardColumn = -1
    }

    function leaveToSidebar() {
        enterInactiveFocus()
        root.requestSidebarFocus()
    }

    // :984-1010, without the released deferral: results are evaluated
    // synchronously here, so the first result is either present or not.
    function focusFirstResult(fallbackToField) {
        if (root.hasQuery && root.resultCount > 0) {
            setResultFocus(0)
            return true
        }
        if (fallbackToField) {
            enterFieldFocus()
        }
        return false
    }

    // :592-608.
    function applySuggestion(index, focusResults) {
        if (index < 0 || index >= root.suggestions.length) {
            return
        }
        root.applyingSuggestion = true
        root.setQuery(root.suggestions[index])
        root.showSuggestions = false
        root.suggestionIndex = -1
        if (focusResults) {
            focusFirstResult(true)
        }
        root.applyingSuggestion = false
    }

    // :431-453 and RemoteSearchKeyboardPolicy.swift:93-108.
    function applyKeyboardKey(kind, value) {
        const text = root.session.query
        switch (kind) {
        case "done":
            root.keyboardPresented = false
            root.showSuggestions = false
            root.suggestionIndex = -1
            if (root.trimmedQuery.length === 0) {
                enterFieldFocus()
            } else {
                focusFirstResult(true)
            }
            return
        case "character":
            root.setQuery(text + value.toLowerCase())
            break
        case "space":
            if (!text.endsWith(" ")) {
                root.setQuery(text + " ")
            }
            break
        case "delete":
            if (text.length > 0) {
                root.setQuery(text.slice(0, -1))
            }
            break
        case "clear":
            root.setQuery("")
            break
        }
        root.keyboardPresented = true
        root.showSuggestions = false
        root.suggestionIndex = -1
        if (root.keyboardRow >= 0) {
            setKeyboardFocus(root.keyboardRow, root.keyboardColumn)
        } else {
            enterKeyboardFocus(false)
        }
    }

    // :352-381 with RemoteSearchKeyboardFlowPolicy.fieldDestination,
    // RemoteSearchKeyboardPolicy.swift:142-162.
    function handleFieldCommand(command) {
        switch (command) {
        case "down":
            if (root.hasVisibleSuggestions) {
                setSuggestionFocus(0)
            } else {
                enterKeyboardFocus(true)
            }
            return true
        case "select":
            enterKeyboardFocus(true)
            return true
        case "right":
            root.showSuggestions = false
            root.suggestionIndex = -1
            focusFirstResult(true)
            return true
        case "left":
        case "back":
            leaveToSidebar()
            return true
        }
        return false
    }

    // :383-404 with RemoteSearchKeyboardPolicy.move, :71-92.
    function handleKeyboardCommand(command) {
        switch (command) {
        case "back":
            enterFieldFocus()
            return true
        case "select": {
            const key = keyboard.keyAt(root.keyboardRow, root.keyboardColumn)
            if (key) {
                applyKeyboardKey(key.kind, key.value)
            }
            return true
        }
        }
        const moved = keyboard.move(root.keyboardRow, root.keyboardColumn, command)
        if (moved.exit === "field") {
            enterFieldFocus()
        } else if (moved.exit === "sidebar") {
            leaveToSidebar()
        } else if (moved.exit === "results") {
            focusFirstResult(true)
        } else {
            setKeyboardFocus(moved.row, moved.column)
        }
        return true
    }

    // :406-429 with SearchSuggestionNavigationPolicy, RemoteSearchKeyboardPolicy.swift:190-215.
    function handleSuggestionCommand(command) {
        const count = root.suggestions.length
        if (count === 0) {
            enterFieldFocus()
            return true
        }
        const index = Math.min(Math.max(0, root.suggestionIndex), count - 1)
        switch (command) {
        case "up":
            if (index === 0) {
                enterFieldFocus()
            } else {
                setSuggestionFocus(index - 1)
            }
            break
        case "down":
            if (index >= count - 1) {
                if (!focusFirstResult(false)) {
                    setSuggestionFocus(index)
                }
            } else {
                setSuggestionFocus(index + 1)
            }
            break
        case "select":
        case "right":
            applySuggestion(index, true)
            break
        case "left":
            leaveToSidebar()
            break
        case "back":
            enterFieldFocus()
            break
        }
        return true
    }

    // :518-539 and :1052-1090 with SearchResultGridNavigationPolicy,
    // RemoteSearchKeyboardPolicy.swift:268-313, over the one movie grid v3
    // has: left and up on their edges hand back to the field or keyboard,
    // right and down on theirs hold still.
    function handleResultCommand(command) {
        const count = root.resultCount
        const columns = resultsGrid.columns
        const index = root.resultIndex
        if (index < 0 || index >= count) {
            focusFirstResult(true)
            return true
        }
        switch (command) {
        case "select":
            root.activateResult(index)
            return true
        case "back":
            exitResults()
            return true
        case "left":
            if (index % columns === 0) {
                exitResults()
            } else {
                setResultFocus(index - 1)
            }
            return true
        case "right":
            if ((index + 1) % columns !== 0 && index + 1 < count) {
                setResultFocus(index + 1)
            }
            return true
        case "up":
            if (index < columns) {
                exitResults()
            } else {
                setResultFocus(index - columns)
            }
            return true
        case "down":
            // :288-291: a step past the last row leaves the section, which
            // with no show grid beneath it means holding still.
            if (index + columns < count) {
                setResultFocus(index + columns)
            }
            return true
        }
        return false
    }

    // RemoteSearchKeyboardFlowPolicy.resultExitDestination, :178-180.
    function exitResults() {
        if (root.keyboardPresented) {
            enterKeyboardFocus(false)
        } else {
            enterFieldFocus()
        }
    }

    // :1041-1051.
    function activateResult(index) {
        const mediaId = root.session.mediaIdAt(index)
        if (mediaId.length === 0) {
            return
        }
        Qt.callLater(appController.showMediaDetails, mediaId)
    }

    // :319-350: one entry for every remote command.
    function handleCommand(command) {
        switch (root.remoteFocus) {
        case root.focusInactive:
            return false
        case root.focusField:
            return handleFieldCommand(command)
        case root.focusSuggestions:
            return handleSuggestionCommand(command)
        case root.focusKeyboard:
            return handleKeyboardCommand(command)
        case root.focusResults:
            return handleResultCommand(command)
        }
        return false
    }

    function commandFor(key) {
        switch (key) {
        case Qt.Key_Left: return "left"
        case Qt.Key_Right: return "right"
        case Qt.Key_Up: return "up"
        case Qt.Key_Down: return "down"
        case Qt.Key_Return:
        case Qt.Key_Enter:
        case Qt.Key_Select: return "select"
        case Qt.Key_Escape:
        case Qt.Key_Back: return "back"
        }
        return ""
    }

    function scrollResultIntoView(index) {
        if (index < 0) {
            return
        }
        const row = Math.floor(index / resultsGrid.columns)
        const cellTop = resultsGrid.y + row * resultsGrid.cellHeight
        const cellBottom = cellTop + resultsGrid.cellHeight
        // :141-153 scrolls the focused card to the centre when its row
        // changes; the flick is held in range at either end.
        const target = cellTop - (flick.height - resultsGrid.cellHeight) / 2
        flick.contentY = Math.max(0, Math.min(target, flick.contentHeight - flick.height))
        if (cellBottom < flick.contentY || cellTop > flick.contentY + flick.height) {
            flick.contentY = Math.max(0, cellTop)
        }
    }

    Rectangle {
        anchors.fill: parent
        // :111.
        color: root.kidsMode ? Theme.kidsBackground : Theme.background
    }

    // :112-127: one vertical scroll of the stack.
    Flickable {
        id: flick
        objectName: "searchFlickable"
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Behavior on contentY {
            enabled: !root.reduceMotion
            NumberAnimation { duration: 220; easing.type: Easing.OutCubic }
        }

        Column {
            id: column
            x: root.outerPadding
            width: flick.width - 2 * root.outerPadding
            spacing: root.sectionSpacing
            bottomPadding: root.outerPadding

            // :234-288 the bar with its suggestions.
            Column {
                id: barStack
                objectName: "searchBar"
                width: parent.width
                topPadding: Theme.scaled(32, 48, root.leanBack)
                spacing: 0

                Rectangle {
                    id: bar
                    width: parent.width
                    height: Theme.scaled(22, 32, root.leanBack)
                        + 2 * Theme.scaled(10, 16, root.leanBack)
                    radius: 10
                    color: Theme.surfaceElevated
                    // :271-278.
                    border.width: 1
                    border.color: field.activeFocus
                        ? Qt.rgba(Theme.accentPrimary.r, Theme.accentPrimary.g,
                                  Theme.accentPrimary.b, 0.5)
                        : Qt.rgba(Theme.textTertiary.r, Theme.textTertiary.g,
                                  Theme.textTertiary.b, 0.3)

                    Row {
                        anchors.fill: parent
                        anchors.leftMargin: Theme.scaled(14, 22, root.leanBack)
                        anchors.rightMargin: Theme.scaled(14, 22, root.leanBack)
                        spacing: Theme.scaled(10, 15, root.leanBack)

                        MarqueeSymbol {
                            // :236-238.
                            anchors.verticalCenter: parent.verticalCenter
                            symbol: "magnifyingglass"
                            pointSize: Theme.scaled(15, 22, root.leanBack)
                            color: Theme.textTertiary
                        }

                        TextInput {
                            id: field
                            objectName: "searchField"
                            anchors.verticalCenter: parent.verticalCenter
                            width: parent.width - parent.spacing * 2
                                - Theme.scaled(15, 22, root.leanBack)
                                - (clearButton.visible ? clearButton.width : 0)
                            height: Theme.scaled(22, 32, root.leanBack)
                            verticalAlignment: TextInput.AlignVCenter
                            font.pixelSize: Theme.scaled(15, 22, root.leanBack)
                            color: Theme.textPrimary
                            selectionColor: Theme.accentPrimary
                            selectedTextColor: Theme.textPrimary
                            clip: true
                            text: root.session.query
                            onTextEdited: root.setQuery(text)
                            // :613-618: typing puts the remote on the field
                            // and dismisses the keyboard.
                            onActiveFocusChanged: {
                                if (activeFocus && root.remoteFocus !== root.focusField) {
                                    root.keyboardPresented = false
                                    root.remoteFocus = root.focusField
                                    root.showSuggestions = root.hasQuery
                                    root.suggestionIndex = -1
                                }
                            }

                            // :492-509: arrows, return, and escape typed in
                            // the field are remote commands.
                            Keys.onPressed: event => {
                                const command = root.commandFor(event.key)
                                if (command.length === 0) {
                                    return
                                }
                                event.accepted = root.handleCommand(command)
                            }

                            Text {
                                objectName: "searchPlaceholder"
                                anchors.fill: parent
                                verticalAlignment: Text.AlignVCenter
                                // :240.
                                text: qsTr("Search movies, shows, cast...")
                                visible: field.text.length === 0
                                color: Theme.textTertiary
                                font: field.font
                            }
                        }

                        Item {
                            id: clearButton
                            objectName: "searchClearButton"
                            anchors.verticalCenter: parent.verticalCenter
                            // :249-260.
                            visible: field.text.length > 0
                            width: Theme.scaled(14, 20, root.leanBack)
                            height: width

                            Rectangle {
                                anchors.fill: parent
                                radius: width / 2
                                color: Theme.textTertiary
                            }

                            MarqueeSymbol {
                                anchors.centerIn: parent
                                symbol: "xmark"
                                pointSize: parent.width * 0.55
                                color: Theme.surfaceElevated
                                strokeRatio: 0.18
                            }

                            TapHandler {
                                onTapped: {
                                    root.setQuery("")
                                    root.showSuggestions = false
                                    root.enterFieldFocus()
                                }
                            }
                        }
                    }
                }

                // :559-591.
                Column {
                    id: suggestionList
                    objectName: "searchSuggestions"
                    width: parent.width
                    topPadding: 4
                    visible: root.hasVisibleSuggestions
                    spacing: 0

                    Rectangle {
                        width: parent.width
                        height: suggestionRows.implicitHeight
                        radius: 8
                        color: Theme.surfaceLayer
                        clip: true

                        Column {
                            id: suggestionRows
                            width: parent.width
                            spacing: 0

                            Repeater {
                                model: root.suggestions

                                Rectangle {
                                    id: suggestionRow
                                    required property int index
                                    required property string modelData
                                    readonly property bool focused: index === root.suggestionIndex

                                    objectName: "searchSuggestion-" + index
                                    width: parent.width
                                    height: Theme.scaled(13, 19, root.leanBack) * 1.3
                                        + 2 * Theme.scaled(8, 13, root.leanBack)
                                    // :579-583.
                                    color: focused
                                        ? Qt.rgba(Theme.accentPrimary.r, Theme.accentPrimary.g,
                                                  Theme.accentPrimary.b, 0.15)
                                        : "transparent"

                                    Row {
                                        anchors.fill: parent
                                        anchors.leftMargin: Theme.scaled(14, 22, root.leanBack)
                                        anchors.rightMargin: Theme.scaled(14, 22, root.leanBack)
                                        spacing: Theme.scaled(10, 15, root.leanBack)

                                        MarqueeSymbol {
                                            anchors.verticalCenter: parent.verticalCenter
                                            symbol: "magnifyingglass"
                                            pointSize: Theme.scaled(11, 16, root.leanBack)
                                            color: Theme.textTertiary
                                        }

                                        Text {
                                            anchors.verticalCenter: parent.verticalCenter
                                            width: parent.width - parent.spacing
                                                - Theme.scaled(11, 16, root.leanBack)
                                            text: suggestionRow.modelData
                                            font.pixelSize: Theme.scaled(13, 19, root.leanBack)
                                            color: Theme.textPrimary
                                            elide: Text.ElideRight
                                        }
                                    }

                                    TapHandler {
                                        onTapped: root.applySuggestion(suggestionRow.index, false)
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // :116-120: the keyboard, when the remote has opened it.
            RemoteSearchKeyboard {
                id: keyboard
                objectName: "remoteSearchKeyboard"
                anchors.horizontalCenter: parent.horizontalCenter
                visible: root.keyboardPresented
                leanBack: root.leanBack
                focusRow: root.remoteFocus === root.focusKeyboard ? root.keyboardRow : -1
                focusColumn: root.remoteFocus === root.focusKeyboard ? root.keyboardColumn : -1
                onKeyPressed: (kind, value) => root.applyKeyboardKey(kind, value)
            }

            // :866-900.
            Item {
                id: resultsContent
                width: parent.width
                implicitHeight: root.hasQuery
                    ? (root.resultCount > 0 ? resultsSection.implicitHeight : emptyState.implicitHeight)
                    : landing.implicitHeight
                height: implicitHeight

                // :1255-1298.
                Column {
                    id: landing
                    objectName: "searchLanding"
                    width: parent.width
                    visible: !root.hasQuery
                    topPadding: Theme.scaled(72, 110, root.leanBack)
                    spacing: Theme.scaled(18, 28, root.leanBack)

                    Item {
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: Theme.scaled(34, 50, root.leanBack)
                        height: width

                        // :1257-1259: a light magnifying glass in the title gradient.
                        MarqueeSymbol {
                            id: landingGlyph
                            anchors.fill: parent
                            symbol: "magnifyingglass"
                            pointSize: parent.width
                            strokeRatio: 0.055
                            color: "white"
                            visible: false
                            layer.enabled: true
                        }

                        ShaderEffect {
                            anchors.fill: parent
                            property var source: landingGlyph
                            property color start: Theme.titleGradientStart
                            property color middle: Theme.titleGradientMiddle
                            property color end: Theme.titleGradientEnd
                            fragmentShader: "qrc:/qt/qml/Marquee/qml/shaders/wordmarkgradient.frag.qsb"
                        }
                    }

                    Column {
                        width: parent.width
                        spacing: Theme.scaled(6, 10, root.leanBack)

                        Text {
                            width: parent.width
                            text: qsTr("Search your library")
                            horizontalAlignment: Text.AlignHCenter
                            font.pixelSize: Theme.scaled(17, 25, root.leanBack)
                            font.weight: Font.DemiBold
                            color: Theme.textPrimary
                        }

                        Text {
                            width: parent.width
                            text: qsTr("Titles, shows, episodes, cast, directors, genres, years, and filenames.")
                            horizontalAlignment: Text.AlignHCenter
                            font.pixelSize: Theme.scaled(13, 19, root.leanBack)
                            color: Theme.textSecondary
                            wrapMode: Text.Wrap
                            maximumLineCount: 2
                            elide: Text.ElideRight
                        }
                    }

                    // :1270-1293: three sample capsules.
                    Row {
                        anchors.horizontalCenter: parent.horizontalCenter
                        spacing: Theme.scaled(8, 12, root.leanBack)

                        Repeater {
                            model: ["Alien", "Thriller", "Ridley"]

                            Rectangle {
                                id: sample
                                required property string modelData
                                objectName: "searchSample-" + modelData
                                width: sampleLabel.implicitWidth
                                    + 2 * Theme.scaled(12, 18, root.leanBack)
                                height: sampleLabel.implicitHeight
                                    + 2 * Theme.scaled(6, 9, root.leanBack)
                                radius: height / 2
                                color: Theme.surfaceLayer

                                Text {
                                    id: sampleLabel
                                    anchors.centerIn: parent
                                    text: sample.modelData
                                    font.pixelSize: Theme.scaled(12, 18, root.leanBack)
                                    font.weight: Font.Medium
                                    color: Theme.textSecondary
                                }

                                TapHandler {
                                    onTapped: {
                                        root.setQuery(sample.modelData)
                                        root.showSuggestions = false
                                        root.enterFieldFocus()
                                    }
                                }
                            }
                        }
                    }
                }

                // :1312-1324.
                Column {
                    id: emptyState
                    objectName: "searchEmptyState"
                    width: parent.width
                    visible: root.hasQuery && root.resultCount === 0
                    topPadding: Theme.scaled(80, 120, root.leanBack)
                    spacing: Theme.spacingMD

                    MarqueeSymbol {
                        anchors.horizontalCenter: parent.horizontalCenter
                        symbol: "magnifyingglass"
                        pointSize: Theme.scaled(36, 52, root.leanBack)
                        strokeRatio: 0.04
                        color: Qt.rgba(Theme.textTertiary.r, Theme.textTertiary.g,
                                       Theme.textTertiary.b, 0.5)
                    }

                    Text {
                        width: parent.width
                        text: qsTr("No results for '%1'").arg(root.trimmedQuery)
                        horizontalAlignment: Text.AlignHCenter
                        font.pixelSize: Theme.scaled(15, 22, root.leanBack)
                        font.weight: Font.Medium
                        color: Theme.textSecondary
                        elide: Text.ElideMiddle
                    }
                }

                // :878-896.
                Column {
                    id: resultsSection
                    objectName: "searchResults"
                    width: parent.width
                    visible: root.hasQuery && root.resultCount > 0
                    spacing: root.sectionSpacing

                    Text {
                        objectName: "searchResultsCount"
                        width: parent.width
                        // :906-910.
                        text: root.resultCount === 1
                            ? qsTr("1 result for '%1'").arg(root.trimmedQuery)
                            : qsTr("%1 results for '%2'").arg(root.resultCount).arg(root.trimmedQuery)
                        font.pixelSize: Theme.scaled(12, 17, root.leanBack)
                        color: Theme.textTertiary
                        elide: Text.ElideMiddle
                    }

                    Column {
                        width: parent.width
                        spacing: Theme.scaled(16, 22, root.leanBack)

                        // SectionHeader.swift:11-22.
                        Text {
                            objectName: "searchMoviesHeader"
                            text: root.kidsMode ? qsTr("Movies") : qsTr("MOVIES")
                            font.pixelSize: root.kidsMode
                                ? Theme.scaled(14, 20, root.leanBack)
                                : Theme.scaled(11, 16, root.leanBack)
                            font.weight: Font.Bold
                            font.letterSpacing: root.kidsMode ? 0 : 1.5
                            color: root.kidsMode ? Theme.kidsAccent : Theme.textSecondary
                        }

                        Grid {
                            id: resultsGrid
                            objectName: "searchResultsGrid"
                            width: parent.width
                            // :100-107 and RemoteSearchKeyboardPolicy.swift:256-263.
                            readonly property int columns_: Math.max(1, Math.floor(
                                (width + root.resultSpacing)
                                / (root.minimumCardWidth + root.resultSpacing)))
                            columns: columns_
                            columnSpacing: root.resultSpacing
                            rowSpacing: Theme.scaled(Theme.spacingMD, 24, root.leanBack)
                            // An adaptive GridItem divides the row evenly among
                            // as many items as the minimum admits, so every
                            // card widens to its column.
                            readonly property real cardWidth:
                                (width - (columns_ - 1) * root.resultSpacing) / columns_
                            readonly property real cellHeight:
                                Theme.posterFrameTopPadding(root.leanBack)
                                + cardWidth / Theme.posterAspect
                                + Theme.scaled(6, 10, root.leanBack)
                                + Theme.posterLabelHeight(root.leanBack)
                                + 2 * Theme.posterFocusHaloPadding(root.leanBack)
                                + rowSpacing

                            Repeater {
                                model: root.session

                                // SearchResultCardView.swift:28-42.
                                PosterCard {
                                    id: resultCard
                                    required property int index
                                    required property string mediaId
                                    required property int matchType
                                    required property string matchDetail
                                    required property string subtitle

                                    objectName: "searchResult-" + index
                                    artworkWidth: resultsGrid.cardWidth
                                    year: 0
                                    metadata: subtitle
                                    highlightMetadata: matchDetail
                                    // SearchResultCardView.swift:43-53.
                                    highlightColor: {
                                        switch (matchType) {
                                        case SearchSession.Title: return Theme.textTertiary
                                        case SearchSession.Cast:
                                        case SearchSession.Keyword: return Theme.accentBright
                                        default: return Theme.accentSecondary
                                        }
                                    }
                                    selected: root.remoteFocus === root.focusResults
                                        && root.resultIndex === index
                                    onActivated: {
                                        root.setResultFocus(index)
                                        root.activateResult(index)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // The remote commands while the field does not own the keyboard.
    Item {
        id: commands
        objectName: "searchCommands"
        focus: true

        Keys.onPressed: event => {
            const command = root.commandFor(event.key)
            if (command.length === 0) {
                return
            }
            event.accepted = root.handleCommand(command)
        }
    }
}
