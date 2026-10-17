import QtQuick
import "SymbolPaths.js" as SymbolPaths
import Marquee 3.0

// The SF Symbols the released sidebar names, drawn as paths because SF
// Symbols are not available on this platform. Marquee/SharedViews/
// MarqueeSidebar.swift:15-23 names the five route symbols, :76 the Play
// Something symbol, and :158 the symbol the profile control falls back to.
// Each is drawn inside a square of the point size the call site's font
// carries, which is the extent the released `Image(systemName:)` occupies
// inside whatever frame it is centred in.
//
// MovieCard.swift:329-331's `film.fill` belongs to a poster's own geometry
// and is drawn by PosterArt.qml against it, not shared with these.
Item {
    id: root

    property string symbol: ""
    // MarqueeSidebar.swift:158 names the symbol shown when there is no
    // profile symbol to draw. Marquee/Models/UserProfile.swift:17-48 lists
    // thirty catalog symbols that have no paths here yet, so a name this
    // component cannot draw resolves to the same released fallback.
    property string fallbackSymbol: ""
    property color color: Theme.textPrimary
    // The point size the released view sets on the symbol's font.
    property real pointSize: 14
    // SidebarRow.swift:183 and MarqueeSidebar.swift:77, :159 all draw at
    // `.medium` weight, whose stroke is about a ninth of the point size.
    property real strokeRatio: 0.09

    readonly property var drawableSymbols: [
        "house.fill",
        "magnifyingglass",
        "film",
        "tv",
        "gearshape",
        "shuffle",
        "person.crop.circle"
    ]

    // The shell's own symbols are painted below; the profile avatars and
    // editing glyphs come from SymbolPaths.js.
    function drawable(name) {
        return root.drawableSymbols.indexOf(name) >= 0 || SymbolPaths.canPaint(name)
    }

    readonly property string resolvedSymbol:
        root.drawable(root.symbol) ? root.symbol : root.fallbackSymbol
    readonly property bool hasPath: root.drawable(root.resolvedSymbol)
    readonly property real strokeWidth: Math.max(1, root.pointSize * root.strokeRatio)

    implicitWidth: root.pointSize
    implicitHeight: root.pointSize

    Canvas {
        id: canvas

        objectName: "marqueeSymbolCanvas"
        anchors.fill: parent
        antialiasing: true

        // A canvas does not track the bindings its paint reads.
        readonly property string painted: root.resolvedSymbol
        readonly property color ink: root.color
        readonly property real stroke: root.strokeWidth

        onPaintedChanged: requestPaint()
        onInkChanged: requestPaint()
        onStrokeChanged: requestPaint()
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()

        // `house.fill` is the one filled symbol here; the rest carry no
        // `.fill` suffix and are drawn as outlines.
        function paintHouse(context, size) {
            context.beginPath()
            context.moveTo(0.50 * size, 0.03 * size)
            context.lineTo(0.98 * size, 0.44 * size)
            context.lineTo(0.86 * size, 0.44 * size)
            context.lineTo(0.86 * size, 0.95 * size)
            context.lineTo(0.14 * size, 0.95 * size)
            context.lineTo(0.14 * size, 0.44 * size)
            context.lineTo(0.02 * size, 0.44 * size)
            context.closePath()
            context.fill()
        }

        function paintMagnifyingGlass(context, size) {
            context.beginPath()
            context.arc(0.40 * size, 0.40 * size, 0.29 * size, 0, 2 * Math.PI)
            context.moveTo(0.61 * size, 0.61 * size)
            context.lineTo(0.90 * size, 0.90 * size)
            context.stroke()
        }

        function paintFilm(context, size) {
            const inset = 0.07 * size
            const extent = size - 2 * inset
            context.beginPath()
            context.roundedRect(inset, inset, extent, extent, 0.10 * size, 0.10 * size)
            context.moveTo(0.28 * size, inset)
            context.lineTo(0.28 * size, size - inset)
            context.moveTo(0.72 * size, inset)
            context.lineTo(0.72 * size, size - inset)
            // The sprocket ticks that fill both perforation columns.
            for (let tick = 0; tick < 2; ++tick) {
                const y = (0.34 + 0.32 * tick) * size
                context.moveTo(inset, y)
                context.lineTo(0.28 * size, y)
                context.moveTo(0.72 * size, y)
                context.lineTo(size - inset, y)
            }
            context.stroke()
        }

        function paintTv(context, size) {
            context.beginPath()
            context.roundedRect(0.05 * size, 0.13 * size, 0.90 * size, 0.58 * size,
                                0.10 * size, 0.10 * size)
            context.moveTo(0.26 * size, 0.90 * size)
            context.lineTo(0.74 * size, 0.90 * size)
            context.stroke()
        }

        function paintGearShape(context, size) {
            const centre = 0.5 * size
            const ring = 0.33 * size
            const tooth = 0.44 * size
            context.beginPath()
            context.arc(centre, centre, ring, 0, 2 * Math.PI)
            context.moveTo(centre + 0.13 * size, centre)
            context.arc(centre, centre, 0.13 * size, 0, 2 * Math.PI)
            for (let index = 0; index < 8; ++index) {
                const angle = index * Math.PI / 4
                context.moveTo(centre + ring * Math.cos(angle), centre + ring * Math.sin(angle))
                context.lineTo(centre + tooth * Math.cos(angle), centre + tooth * Math.sin(angle))
            }
            context.stroke()
        }

        // Two crossing paths, each ending in an arrowhead on the trailing
        // edge, which is what `shuffle` draws.
        function paintShuffle(context, size) {
            context.beginPath()
            for (let path = 0; path < 2; ++path) {
                const near = (path === 0 ? 0.26 : 0.74) * size
                const far = (path === 0 ? 0.74 : 0.26) * size
                context.moveTo(0.06 * size, near)
                context.lineTo(0.26 * size, near)
                context.lineTo(0.74 * size, far)
                context.lineTo(0.90 * size, far)
                context.moveTo(0.78 * size, far - 0.11 * size)
                context.lineTo(0.90 * size, far)
                context.lineTo(0.78 * size, far + 0.11 * size)
            }
            context.stroke()
        }

        // `person.crop.circle` is a person cropped by the circle that
        // encloses it, so the silhouette is drawn inside that clip rather
        // than merely centred on it.
        function paintPersonCropCircle(context, size) {
            const centre = 0.5 * size
            const enclosing = 0.44 * size
            context.beginPath()
            context.arc(centre, centre, enclosing, 0, 2 * Math.PI)
            context.stroke()

            context.save()
            context.beginPath()
            context.arc(centre, centre, enclosing - context.lineWidth / 2, 0, 2 * Math.PI)
            context.clip()
            context.beginPath()
            context.moveTo(centre + 0.15 * size, 0.40 * size)
            context.arc(centre, 0.40 * size, 0.15 * size, 0, 2 * Math.PI)
            context.moveTo(centre - 0.27 * size, size)
            context.arc(centre, 0.98 * size, 0.27 * size, Math.PI, 2 * Math.PI)
            context.stroke()
            context.restore()
        }

        onPaint: {
            const context = getContext("2d")
            context.reset()
            context.clearRect(0, 0, width, height)
            if (!root.hasPath || width <= 0 || height <= 0) {
                return
            }

            const size = Math.min(width, height)
            context.translate((width - size) / 2, (height - size) / 2)
            context.strokeStyle = root.color
            context.fillStyle = root.color
            context.lineWidth = root.strokeWidth
            context.lineJoin = "round"
            context.lineCap = "round"

            switch (root.resolvedSymbol) {
            case "house.fill":
                paintHouse(context, size)
                break
            case "magnifyingglass":
                paintMagnifyingGlass(context, size)
                break
            case "film":
                paintFilm(context, size)
                break
            case "tv":
                paintTv(context, size)
                break
            case "gearshape":
                paintGearShape(context, size)
                break
            case "shuffle":
                paintShuffle(context, size)
                break
            case "person.crop.circle":
                paintPersonCropCircle(context, size)
                break
            default:
                if (SymbolPaths.canPaint(root.resolvedSymbol)) {
                    SymbolPaths.paint(root.resolvedSymbol, context, size)
                }
                break
            }
        }
    }
}
