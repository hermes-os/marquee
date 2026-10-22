import QtQuick
import Marquee 3.0

// ProfilePickerView.swift:735-810 draws one profile card: a 130/190 disc on
// the elevated surface carrying the profile's symbol at 44/64 medium in its
// own colour, the structural focus ring 4/6 outside the disc at 2.5/3.5 with
// its glow, a 1.06 focus scale (1.02 on hover), the black drop shadow and the
// structural glow under the focused disc, then the name at 15/22 medium and
// the maturity label at 11/16, spaced 10/16. :816-895 draws the Add Profile
// card from the same parts on the surface layer with the ultralight plus.
Item {
    id: root

    property bool leanBack: false
    property bool reduceMotion: false

    property string title: ""
    property string subtitle: ""
    property string symbol: ""
    property color symbolColor: Theme.textPrimary
    property real symbolStrokeRatio: 0.09
    property color discColor: Theme.surfaceElevated
    property bool remoteFocused: false
    property bool selected: false
    property bool hovered: false
    // The Add Profile treatment: dimmer labels, no glow ring colour change.
    property bool addStyle: false
    // ProfilePickerView.swift:872-883: while managing, the add item sits on
    // a 0.86 surface panel with a 2.5 structural ring on focus.
    property bool managementPanel: false

    signal activated()

    readonly property real discDiameter: Theme.scaled(130, 190, root.leanBack)
    readonly property real ringOutset: Theme.scaled(4, 6, root.leanBack)
    readonly property real ringDiameter: root.discDiameter + 2 * root.ringOutset
    readonly property real ringLineWidth: Theme.scaled(2.5, 3.5, root.leanBack)
    readonly property bool emphasised: root.remoteFocused || root.selected

    implicitHeight: column.height

    Rectangle {
        objectName: "profileCardPanel"
        anchors.fill: parent
        radius: Theme.radiusMD
        visible: root.managementPanel
        color: Qt.rgba(Theme.surfaceLayer.r, Theme.surfaceLayer.g, Theme.surfaceLayer.b, 0.86)
        border.width: root.remoteFocused ? 2.5 : 0
        border.color: Theme.structuralFocus
    }

    Column {
        id: column
        objectName: "profileCardColumn"

        anchors.horizontalCenter: parent.horizontalCenter
        anchors.verticalCenter: root.managementPanel ? parent.verticalCenter : undefined
        anchors.top: root.managementPanel ? undefined : parent.top
        width: parent.width
        spacing: Theme.scaled(10, 16, root.leanBack)

        Item {
            id: discFrame
            objectName: "profileCardDiscFrame"

            anchors.horizontalCenter: parent.horizontalCenter
            width: root.ringDiameter
            height: root.ringDiameter

            // :777-790: the black shadow deepens on focus or selection, and
            // the structural glow appears under the focused disc.
            SoftShadow {
                objectName: "profileCardShadow"
                anchors.centerIn: parent
                width: root.discDiameter
                height: root.discDiameter
                radius: root.discDiameter / 2
                shadowColor: Qt.rgba(0, 0, 0, root.emphasised
                    ? (root.addStyle ? 0.58 : 0.62)
                    : (root.hovered ? (root.addStyle ? 0.24 : 0.3) : (root.addStyle ? 0 : 0.2)))
                blur: root.emphasised ? 22 : (root.hovered ? 8 : (root.addStyle ? 0 : 4))
                offsetY: root.emphasised ? 14 : (root.hovered ? 4 : (root.addStyle ? 0 : 2))
                scale: discScale.scale
            }

            SoftShadow {
                objectName: "profileCardGlow"
                anchors.centerIn: parent
                width: root.discDiameter
                height: root.discDiameter
                radius: root.discDiameter / 2
                visible: root.emphasised
                shadowColor: Qt.rgba(Theme.structuralFocus.r, Theme.structuralFocus.g,
                                     Theme.structuralFocus.b, 0.45)
                blur: 24
                offsetY: 0
                scale: discScale.scale
            }

            Item {
                id: discScale
                anchors.fill: parent
                // :772-775: 1.06 under remote focus, 1.02 under hover.
                scale: root.remoteFocused ? 1.06 : (root.hovered ? 1.02 : 1.0)
                Behavior on scale {
                    enabled: !root.reduceMotion
                    // MarqueeTheme.swift:246's card hover spring, response
                    // 0.25 damping 0.7.
                    NumberAnimation { duration: Theme.motionNormal; easing.type: Easing.OutCubic }
                }

                Rectangle {
                    id: disc
                    objectName: "profileCardDisc"

                    anchors.centerIn: parent
                    width: root.discDiameter
                    height: root.discDiameter
                    radius: width / 2
                    color: root.discColor

                    MarqueeSymbol {
                        objectName: "profileCardSymbol"
                        anchors.centerIn: parent
                        symbol: root.symbol
                        fallbackSymbol: "person.crop.circle"
                        pointSize: Theme.scaled(44, 64, root.leanBack)
                        color: root.symbolColor
                        strokeRatio: root.symbolStrokeRatio
                    }
                }

                // :766-771: the ring, 0.95 structural focus, with an 18-point
                // structural glow of its own at 0.65.
                Item {
                    objectName: "profileCardRing"
                    anchors.fill: parent
                    visible: root.remoteFocused || root.selected

                    SoftShadow {
                        anchors.fill: parent
                        radius: parent.width / 2
                        visible: !root.addStyle
                        shadowColor: Qt.rgba(Theme.structuralFocus.r, Theme.structuralFocus.g,
                                             Theme.structuralFocus.b, 0.65)
                        blur: 18
                        offsetY: 0
                    }

                    Rectangle {
                        anchors.fill: parent
                        radius: width / 2
                        color: "transparent"
                        border.width: root.ringLineWidth
                        border.color: Qt.rgba(Theme.structuralFocus.r, Theme.structuralFocus.g,
                                              Theme.structuralFocus.b, root.addStyle ? 1 : 0.95)
                    }
                }
            }
        }

        // :792-796 and :885-890.
        Text {
            objectName: "profileCardTitle"
            width: parent.width
            text: root.title
            color: root.addStyle
                ? ((root.remoteFocused || root.hovered) ? Theme.textSecondary : Theme.textTertiary)
                : ((root.remoteFocused || root.hovered) ? Theme.textPrimary : Theme.textSecondary)
            font.pixelSize: Theme.scaled(15, 22, root.leanBack)
            font.weight: Font.Medium
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            maximumLineCount: 2
            elide: Text.ElideRight
        }

        // :798-800 and :892-893.
        Text {
            objectName: "profileCardSubtitle"
            width: parent.width
            text: root.subtitle
            color: Theme.textTertiary
            font.pixelSize: Theme.scaled(11, 16, root.leanBack)
            horizontalAlignment: Text.AlignHCenter
        }
    }

    // ProfilePickerView.swift:805-807: hover only tints. The remote's focus
    // moves by key or click, so a pointer resting under a card cannot choose.
    HoverHandler {
        onHoveredChanged: root.hovered = hovered
    }

    TapHandler {
        onTapped: root.activated()
    }

    Accessible.role: Accessible.Button
    Accessible.name: root.addStyle ? qsTr("Add profile") : root.title + ", " + root.subtitle
    Accessible.description: root.addStyle ? qsTr("Creates a new profile") : qsTr("Use this profile")
}
