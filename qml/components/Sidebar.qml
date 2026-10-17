import QtQuick
import QtQuick.Layouts
import Marquee 3.0

// Marquee/SharedViews/MarqueeSidebar.swift:50-139 composes the shell's
// leftmost column: the five route rows, the Play Something control, and the
// profile control on the surface layer, with no text labels.
FocusScope {
    id: root

    signal routeActivated(int route)
    signal playSomethingActivated()
    signal profileActivated()
    signal requestContentFocus()

    property int selectedRoute: NavigationController.Home
    property bool leanBack: appController.settings.leanBackMode
    property bool reduceMotion: appController.settings.reduceMotion
    property bool kidsMode: false
    property int focusedIndex: 0
    property bool remoteActive: activeFocus

    // MarqueeSidebar.swift:35, :130, :158, :161-163: one optional profile
    // supplies the control's label, its symbol, and its ink, or none of them.
    property string activeProfileName: ""
    property string activeProfileAvatarIcon: ""
    property color activeProfileAvatarColor: "transparent"
    readonly property bool hasActiveProfile: root.activeProfileName.length > 0

    // MarqueeSidebar.swift:6-24 defines the routes, their order, and their
    // symbols; the raw value is both the label and the help text.
    readonly property var entries: [
        { label: qsTr("Home"), symbol: "house.fill", route: NavigationController.Home },
        { label: qsTr("Search"), symbol: "magnifyingglass", route: NavigationController.Search },
        { label: qsTr("Movies"), symbol: "film", route: NavigationController.Movies },
        { label: qsTr("TV Shows"), symbol: "tv", route: NavigationController.Shows },
        { label: qsTr("Settings"), symbol: "gearshape", route: NavigationController.Settings }
    ]

    // AppRouter.swift:62-91 moves focus down through the routes to Play
    // Something and then to the profile control.
    readonly property int playSomethingIndex: root.entries.length
    readonly property int profileIndex: root.entries.length + 1

    // MarqueeSidebar.swift:42-48 and SidebarRow.swift:183-202 fix every
    // measurement this surface is built from.
    readonly property real symbolPointSize: Theme.scaled(14, 21, root.leanBack)
    readonly property real symbolFrameSize: Theme.scaled(22, 32, root.leanBack)
    readonly property real controlVerticalPadding: Theme.scaled(7, 12, root.leanBack)
    readonly property real controlHeight: root.symbolFrameSize + 2 * root.controlVerticalPadding
    readonly property real controlInset: Theme.scaled(8, 12, root.leanBack)
    readonly property real avatarDiameter: Theme.scaled(30, 44, root.leanBack)

    implicitWidth: Theme.scaled(56, 78, root.leanBack)

    // MarqueeSidebar.swift:137 lays the whole column on the surface layer,
    // or the kids surface layer under a kids profile.
    Rectangle {
        objectName: "sidebarSurface"
        anchors.fill: parent
        color: root.kidsMode ? Theme.kidsSurfaceLayer : Theme.surfaceLayer
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        Column {
            id: routeColumn

            objectName: "sidebarRouteColumn"
            Layout.fillWidth: true
            // MarqueeSidebar.swift:73 insets the route stack from the top and
            // :52 spaces the rows inside it.
            Layout.topMargin: Theme.scaled(18, 28, root.leanBack)
            spacing: Theme.scaled(2, 6, root.leanBack)

            Repeater {
                id: routeRepeater
                objectName: "sidebarRoutes"
                model: root.entries

                delegate: Item {
                    id: routeEntry

                    required property int index
                    required property var modelData

                    objectName: "sidebarRoute"
                    readonly property int route: modelData.route
                    readonly property bool selected: root.selectedRoute === modelData.route
                    readonly property bool remoteFocused:
                        root.remoteActive && root.focusedIndex === index

                    width: routeColumn.width
                    height: root.controlHeight

                    // SidebarRow.swift:191-201: the row's own background, the
                    // remote-focus ring over it, and the focused lift, which
                    // :199 withholds from the row that is already selected.
                    Rectangle {
                        objectName: "sidebarRouteSurface"

                        anchors.fill: parent
                        anchors.leftMargin: root.controlInset
                        anchors.rightMargin: root.controlInset
                        radius: Theme.sidebarControlRadius

                        color: routeEntry.remoteFocused
                            ? Qt.rgba(Theme.structuralFocus.r, Theme.structuralFocus.g,
                                      Theme.structuralFocus.b, 0.14)
                            : routeEntry.selected
                                ? Qt.rgba(Theme.accentPrimary.r, Theme.accentPrimary.g,
                                          Theme.accentPrimary.b, 0.20)
                                : "transparent"
                        border.width: routeEntry.remoteFocused ? 2 : 0
                        border.color: Theme.structuralFocus

                        scale: routeEntry.remoteFocused && !routeEntry.selected ? 1.03 : 1.0

                        // MarqueeTheme.swift:251 settles the hover spring in a
                        // quarter second, and :273-275 removes it under Reduce
                        // Motion.
                        Behavior on scale {
                            enabled: !root.reduceMotion
                            NumberAnimation {
                                objectName: "sidebarRouteScale"
                                duration: Theme.motionNormal
                                easing.type: Easing.OutCubic
                            }
                        }

                        // SidebarRow.swift:185-188 centres the symbol in its
                        // own frame inside the row.
                        Item {
                            objectName: "sidebarRouteSymbolFrame"
                            anchors.centerIn: parent
                            width: root.symbolFrameSize
                            height: root.symbolFrameSize

                            MarqueeSymbol {
                                objectName: "sidebarRouteSymbol"
                                anchors.centerIn: parent
                                symbol: routeEntry.modelData.symbol
                                pointSize: root.symbolPointSize
                                // SidebarRow.swift:211-216. Pointer hover is
                                // the fourth state and belongs to the open
                                // hover slice, not to this one.
                                color: routeEntry.remoteFocused
                                    ? Theme.structuralFocus
                                    : routeEntry.selected
                                        ? Theme.accentBright
                                        : Theme.textTertiary
                            }
                        }
                    }

                    TapHandler {
                        onTapped: root.routeActivated(routeEntry.route)
                    }

                    Accessible.name: routeEntry.modelData.label
                    Accessible.description: qsTr("Open %1").arg(routeEntry.modelData.label)
                    Accessible.role: Accessible.Button
                }
            }
        }

        // MarqueeSidebar.swift:75-106: the shuffle control, whose surface is
        // the primary accent at 0.14 until the remote is on it.
        Item {
            id: playSomething

            objectName: "sidebarPlaySomething"
            Layout.fillWidth: true
            implicitHeight: Theme.scaled(10, 16, root.leanBack) + root.controlHeight

            readonly property bool remoteFocused:
                root.remoteActive && root.focusedIndex === root.playSomethingIndex

            Rectangle {
                objectName: "sidebarPlaySomethingSurface"

                anchors.fill: parent
                anchors.leftMargin: root.controlInset
                anchors.rightMargin: root.controlInset
                anchors.topMargin: Theme.scaled(10, 16, root.leanBack)
                radius: Theme.sidebarControlRadius

                color: playSomething.remoteFocused
                    ? Theme.accentPrimary
                    : Qt.rgba(Theme.accentPrimary.r, Theme.accentPrimary.g,
                              Theme.accentPrimary.b, 0.14)
                // MarqueeSidebar.swift:92-98 strokes the ring only while the
                // remote is on the control.
                border.width: playSomething.remoteFocused ? 1 : 0
                border.color: Theme.structuralFocus

                scale: playSomething.remoteFocused ? 1.03 : 1.0

                Behavior on scale {
                    enabled: !root.reduceMotion
                    NumberAnimation {
                        objectName: "sidebarPlaySomethingScale"
                        duration: Theme.motionNormal
                        easing.type: Easing.OutCubic
                    }
                }

                Item {
                    objectName: "sidebarPlaySomethingSymbolFrame"
                    anchors.centerIn: parent
                    width: root.symbolFrameSize
                    height: root.symbolFrameSize

                    MarqueeSymbol {
                        objectName: "sidebarPlaySomethingSymbol"
                        anchors.centerIn: parent
                        symbol: "shuffle"
                        pointSize: root.symbolPointSize
                        // MarqueeSidebar.swift:78 inks the resting control in
                        // the secondary accent at 0.78 and the focused one in
                        // the primary text colour.
                        color: playSomething.remoteFocused
                            ? Theme.textPrimary
                            : Qt.rgba(Theme.accentSecondary.r, Theme.accentSecondary.g,
                                      Theme.accentSecondary.b, 0.78)
                    }
                }
            }

            TapHandler { onTapped: root.playSomethingActivated() }

            Accessible.name: qsTr("Play Something")
            Accessible.role: Accessible.Button
        }

        // MarqueeSidebar.swift:108 pushes the profile control to the bottom.
        Item { Layout.fillHeight: true }

        // MarqueeSidebar.swift:110-134 and :141-167: the profile control and
        // the avatar it shows.
        Item {
            id: profile

            objectName: "sidebarProfile"
            Layout.fillWidth: true
            implicitHeight: root.avatarDiameter + 2 * Theme.scaled(6, 10, root.leanBack)
                + Theme.scaled(12, 20, root.leanBack)

            readonly property bool remoteFocused:
                root.remoteActive && root.focusedIndex === root.profileIndex

            Rectangle {
                objectName: "sidebarProfileSurface"

                anchors.fill: parent
                anchors.leftMargin: root.controlInset
                anchors.rightMargin: root.controlInset
                anchors.bottomMargin: Theme.scaled(12, 20, root.leanBack)
                radius: Theme.sidebarControlRadius

                // MarqueeSidebar.swift:115-125: nothing at rest, the
                // structural focus at 0.14 under a 2-point ring on focus.
                color: profile.remoteFocused
                    ? Qt.rgba(Theme.structuralFocus.r, Theme.structuralFocus.g,
                              Theme.structuralFocus.b, 0.14)
                    : "transparent"
                border.width: profile.remoteFocused ? 2 : 0
                border.color: Theme.structuralFocus

                scale: profile.remoteFocused ? 1.03 : 1.0

                Behavior on scale {
                    enabled: !root.reduceMotion
                    NumberAnimation {
                        objectName: "sidebarProfileScale"
                        duration: Theme.motionNormal
                        easing.type: Easing.OutCubic
                    }
                }

                // MarqueeSidebar.swift:153-166 is the avatar shown when no
                // rendered character image is cached: the elevated surface as
                // a disc with the profile's own symbol over it. v3 has no
                // avatar image service, so this is the whole treatment.
                Rectangle {
                    objectName: "sidebarProfileAvatar"

                    anchors.centerIn: parent
                    width: root.avatarDiameter
                    height: width
                    radius: width / 2
                    color: Theme.surfaceElevated

                    MarqueeSymbol {
                        objectName: "sidebarProfileSymbol"
                        anchors.centerIn: parent
                        symbol: root.hasActiveProfile ? root.activeProfileAvatarIcon : ""
                        fallbackSymbol: "person.crop.circle"
                        pointSize: Theme.scaled(15, 22, root.leanBack)
                        color: root.hasActiveProfile
                            ? root.activeProfileAvatarColor
                            : (root.kidsMode ? Theme.kidsAccent : Theme.accentBright)
                    }
                }
            }

            TapHandler { onTapped: root.profileActivated() }

            // MarqueeSidebar.swift:130-131 labels the control with the active
            // profile's name, and always hints what it does.
            Accessible.name: root.hasActiveProfile ? root.activeProfileName : qsTr("Switch Profile")
            Accessible.description: qsTr("Switch Profile")
            Accessible.role: Accessible.Button
        }
    }

    Keys.onUpPressed: event => {
        focusedIndex = Math.max(0, focusedIndex - 1)
        event.accepted = true
    }
    Keys.onDownPressed: event => {
        focusedIndex = Math.min(root.profileIndex, focusedIndex + 1)
        event.accepted = true
    }
    Keys.onRightPressed: event => {
        root.requestContentFocus()
        event.accepted = true
    }
    Keys.onReturnPressed: event => activateFocused(event)
    Keys.onEnterPressed: event => activateFocused(event)

    function activateFocused(event) {
        if (focusedIndex < entries.length)
            routeActivated(entries[focusedIndex].route)
        else if (focusedIndex === root.playSomethingIndex)
            playSomethingActivated()
        else
            profileActivated()
        event.accepted = true
    }
}
