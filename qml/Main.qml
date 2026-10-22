import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Marquee 3.0

ApplicationWindow {
    id: window
    objectName: "marqueeWindow"

    width: 1920
    height: 1080
    minimumWidth: 1100
    minimumHeight: 700
    visible: true
    color: Theme.background
    title: qsTr("Marquee")

    Component.onCompleted: {
        if (appController.startFullscreen) {
            showFullScreen()
        } else {
            showNormal()
        }
        // Playback only follows the route from here: a `--play` start has
        // the player route up before the window is shown, and the window
        // must first take the state the start options chose so that closing
        // the player can return to it.
        playbackFullscreen.active = Qt.binding(() => window.playerShowing)
        // ContentView.swift:30 and :117: the remote starts on the picker
        // when it is up, otherwise on the sidebar.
        if (profilePickerLoader.item) {
            profilePickerLoader.item.forceActiveFocus()
        } else if (window.playerShowing) {
            // `--play` opens the player before the shell is composed.
            playerLayer.forceActiveFocus()
        } else {
            sidebar.forceActiveFocus()
        }
    }

    Shortcut {
        sequence: "F11"
        onActivated: playbackFullscreen.toggle()
    }

    // Playback takes the window fullscreen and gives it back when the player
    // closes if it is still fullscreen and the viewer did not toggle it; F11
    // and the HUD control go through toggle() so the viewer's choice is told
    // from ours.
    PlaybackFullscreen {
        id: playbackFullscreen
        objectName: "playbackFullscreen"
        window: window
    }

    // ContentView.swift:29-40 and :41-43: the profile picker is a layer over
    // the whole window with no sidebar, kept up through its own exit fade
    // while the shell is already composed beneath it. The shell only takes
    // input once the picker is gone (:83-87).
    readonly property bool pickerShowing: appController.navigation.route === NavigationController.ProfilePicker
        || appController.profileExitInFlight
    readonly property bool shellShowing: appController.navigation.route !== NavigationController.ProfilePicker
    // ContentView.swift:52-62 presents the player as a layer over the whole
    // shell, sidebar included, so the shell's chrome is not drawn while it is
    // up and the picture and the HUD take the full window width.
    readonly property bool playerShowing: appController.navigation.route === NavigationController.Player
    onPlayerShowingChanged: {
        // Closing the player: the remote goes back to the content, where the
        // player held it when it sat inside the shell.
        if (!playerShowing && shellShowing && !appController.profileExitInFlight) {
            contentFocus.forceActiveFocus()
        }
    }

    RowLayout {
        id: shell
        objectName: "shell"
        anchors.fill: parent
        spacing: 0
        visible: window.shellShowing && !window.playerShowing
        enabled: window.shellShowing && !appController.profileExitInFlight

        // Window-attached Keys never enter Qt Quick key delivery; back keys
        // must sit on an Item above both focus scopes in the bubble chain.
        Keys.onPressed: event => {
            if (event.key === Qt.Key_Escape
                || event.key === Qt.Key_Back
                || event.key === Qt.Key_Backspace) {
                appController.navigation.goBack()
                event.accepted = true
            }
        }

        Sidebar {
            id: sidebar
            objectName: "sidebar"
            Layout.fillHeight: true
            Layout.preferredWidth: implicitWidth
            // TVShowsDetailView.swift:110-116 presents a show over the TV
            // Shows tab, so the tab stays lit while a show detail is up.
            selectedRoute: appController.navigation.route === NavigationController.ShowDetail
                ? NavigationController.Shows
                : appController.navigation.route
            activeProfileName: appController.activeProfileName
            activeProfileAvatarIcon: appController.activeProfileAvatarIcon
            activeProfileAvatarColor: appController.activeProfileAvatarColor
            kidsMode: appController.kidsMode
            onRouteActivated: route => appController.navigation.openRoute(route)
            onPlaySomethingActivated: appController.playSomething()
            onProfileActivated: appController.navigation.showProfilePicker()
            onRequestContentFocus: contentFocus.forceActiveFocus()
        }

        FocusScope {
            id: contentFocus
            objectName: "contentFocus"
            Layout.fillWidth: true
            Layout.fillHeight: true
            focus: true
            Keys.onLeftPressed: event => {
                sidebar.forceActiveFocus()
                event.accepted = true
            }

            Loader {
                id: screenLoader
                objectName: "screenLoader"
                anchors.fill: parent
                focus: true
                activeFocusOnTab: false
                sourceComponent: {
                    switch (appController.navigation.route) {
                    // The player is its own layer above the shell (see
                    // playerLayer), so no browse screen is kept under it.
                    case NavigationController.Player: return null
                    case NavigationController.Details: return detailsComponent
                    case NavigationController.ShowDetail: return showDetailComponent
                    case NavigationController.Movies: return moviesComponent
                    case NavigationController.Shows: return showsComponent
                    case NavigationController.Search: return searchComponent
                    case NavigationController.Settings: return settingsComponent
                    case NavigationController.Home: return homeComponent
                    default: return welcomeComponent
                    }
                }
            }
        }
    }

    Component {
        id: homeComponent
        HomeScreen {
            // HomeDetailView.swift:329 and :1008 run the same `playSomething()`
            // the sidebar's control does (ContentView.swift:207).
            onPlaySomethingActivated: appController.playSomething()
        }
    }

    Component {
        id: moviesComponent
        MoviesScreen {
            onRequestSidebarFocus: sidebar.forceActiveFocus()
        }
    }

    Component {
        id: showsComponent
        ShowsScreen {
            onRequestSidebarFocus: sidebar.forceActiveFocus()
        }
    }
    Component {
        id: showDetailComponent
        ShowDetailScreen {
            showName: appController.navigation.selectedMediaId
            onRequestSidebarFocus: sidebar.forceActiveFocus()
        }
    }
    Component {
        id: searchComponent
        SearchScreen {
            onRequestSidebarFocus: sidebar.forceActiveFocus()
        }
    }

    Component {
        id: settingsComponent
        SettingsScreen {
            onRequestSidebarFocus: sidebar.forceActiveFocus()
        }
    }

    Component {
        id: welcomeComponent
        WelcomeScreen {
            title: routeTitle(appController.navigation.route)
        }
    }

    Component {
        id: detailsComponent
        DetailsScreen { }
    }

    Component {
        id: playerComponent
        PlayerScreen {
            title: appController.player.title
            subtitle: appController.player.subtitle
            onFullscreenRequested: playbackFullscreen.toggle()
        }
    }

    // ContentView.swift:52-62: the player layer, above the shell and below
    // the profile picker, across the whole window.
    FocusScope {
        id: playerLayer
        objectName: "playerLayer"
        anchors.fill: parent
        z: 3
        visible: window.playerShowing

        // The back keys the shell handles for every other route. The player
        // answers them itself; a chorded one is the only kind it leaves.
        Keys.onPressed: event => {
            if (event.key === Qt.Key_Escape
                || event.key === Qt.Key_Back
                || event.key === Qt.Key_Backspace) {
                appController.navigation.goBack()
                event.accepted = true
            }
        }

        Loader {
            id: playerLoader
            objectName: "playerLoader"
            anchors.fill: parent
            focus: true
            active: window.playerShowing
            sourceComponent: playerComponent
        }
    }

    // ContentView.swift:30-39: the picker layer, z above the shell, present
    // for the route and through the exit fade that follows a choice.
    Loader {
        id: profilePickerLoader
        objectName: "profilePickerLoader"
        anchors.fill: parent
        active: window.pickerShowing
        z: 4
        sourceComponent: ProfilePickerScreen { }
        onLoaded: item.forceActiveFocus()
    }

    Connections {
        target: appController
        // Once the exit fade has ended the shell owns the remote again, on
        // Home's content: ContentView.swift:391-407 leaves the sidebar
        // without remote focus, so the browse surface is the remote's owner
        // (FocusCoordinator.swift:42-47) and the first Return opens a card
        // rather than the sidebar's control the viewer last stood on.
        function onProfileExitInFlightChanged() {
            if (!appController.profileExitInFlight && window.shellShowing
                && !window.playerShowing) {
                sidebar.resetFocusedIndex()
                contentFocus.forceActiveFocus()
            }
        }
    }

    Connections {
        target: appController.navigation
        function onRouteChanged() {
            if (appController.navigation.route === NavigationController.ProfilePicker) {
                sidebar.resetFocusedIndex()
                if (profilePickerLoader.item) {
                    profilePickerLoader.item.forceActiveFocus()
                }
            } else if (appController.navigation.route === NavigationController.Player) {
                // The player layer takes the remote whole; it is not in the
                // shell's scopes, so the shell fallback below must not run.
                playerLayer.forceActiveFocus()
            } else if (!appController.profileExitInFlight && !sidebar.activeFocus
                       && !contentFocus.activeFocus) {
                // The shell composes under a route change that skipped the
                // picker's exit fade; the remote starts on the sidebar as
                // ContentView.swift:117 has it.
                sidebar.forceActiveFocus()
            }
        }
    }

    ErrorToast {
        objectName: "errorToast"
        anchors.top: parent.top
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.topMargin: 24
        visible: appController.hasError
        title: appController.errorTitle
        message: appController.errorMessage
        onDismissed: appController.dismissError()
        z: 100
    }

    function routeTitle(route) {
        switch (route) {
        case NavigationController.ProfilePicker: return qsTr("Profiles")
        case NavigationController.Home: return qsTr("Home")
        case NavigationController.Search: return qsTr("Search")
        case NavigationController.Movies: return qsTr("Movies")
        case NavigationController.Shows: return qsTr("TV Shows")
        case NavigationController.Settings: return qsTr("Settings")
        case NavigationController.Details: return qsTr("Details")
        case NavigationController.ShowDetail: return appController.navigation.selectedMediaId
        case NavigationController.Player: return qsTr("Player")
        default: return qsTr("Home")
        }
    }
}
