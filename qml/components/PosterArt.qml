import QtQuick
import Marquee 3.0

// Marquee/SharedViews/MovieCard.swift:204-224 stacks the poster surface: the
// elevated surface fill, the fallback artwork, then the artwork itself, so a
// title with no sidecar, an undecodable one, or a sidecar with transparent
// pixels shows the fallback beneath. MovieCard.swift:161-163 then clips the
// whole surface to the rounded rectangle before the focus chrome is applied
// outside it. Qt clips items to rectangles only, so every layer that reaches
// the corners paints itself inside the rounded path instead: the fill is the
// rounded rectangle, the gradient and the artwork clip their own canvases to
// it, and the symbol, the caption, and the focus wash and badge stay inside
// the arc zone by their own geometry. Artwork comes from the user's own
// library, so a sidecar can be truncated or not an image at all; a recycled
// delegate showing another title tries again.
Rectangle {
    id: root

    // Marquee/SharedViews/CachedImageView.swift:4-8 names the three states an
    // artwork request can be in.
    enum LoadState { Loading, Ready, TerminalFallback }

    required property url source
    property string title: ""
    property string badge: ""
    // UniversalPosterCard.swift:112, :212: the symbol the fallback artwork
    // draws. Movies pass `film.fill`; ShowCard.swift:21 passes `tv.fill`.
    property string symbol: "film.fill"
    property bool leanBack: appController.settings.leanBackMode

    // CachedImageView.swift:23-25: the request the surface is showing, the
    // generation that began it, and the state it reached. v3 loads the sidecar
    // at its natural size, so a request is its source alone rather than a path
    // and a thumbnail pixel size.
    property url loadRequest: ""
    property int loadGeneration: 0
    property int loadState: PosterArt.LoadState.TerminalFallback

    property bool artworkFailed: false

    // CachedImageView.swift:100-102 restarts the request whenever the surface
    // is pointed at different artwork. Clearing the retry latch re-evaluates
    // the image item's source binding inside this handler, and artwork already
    // in Qt's pixmap cache reaches `Ready` there and emits no later status
    // change, so the generation is recorded first and the request is settled
    // from the item's own state once the binding has caught up.
    onSourceChanged: {
        image.requestGeneration = root.beginRequest(root.source)
        artworkFailed = false
        image.settleRequest()
    }

    // CachedImageView.swift:100 begins the first request when the view
    // appears. A source bound at creation may already have settled the image
    // item before any handler ran.
    Component.onCompleted: {
        if (root.loadGeneration === 0) {
            image.requestGeneration = root.beginRequest(root.source)
        }
        image.settleRequest()
    }

    // CachedImageView.swift:27-33. A request with no artwork is terminal at
    // once; one with artwork is loading until it completes.
    function beginRequest(requestSource) {
        root.loadGeneration += 1
        root.loadRequest = requestSource
        root.loadState = String(requestSource).length === 0
            ? PosterArt.LoadState.TerminalFallback
            : PosterArt.LoadState.Loading
        return root.loadGeneration
    }

    // CachedImageView.swift:35-45. A completion is refused unless it still
    // belongs to the request on screen, so a load that finishes after the
    // surface moved to another title can neither paint that title's artwork
    // nor clear its loading state.
    function completeRequest(requestSource, generation, imageAvailable) {
        if (generation !== root.loadGeneration
                || String(requestSource) !== String(root.loadRequest)) {
            return false
        }
        root.loadState = imageAvailable
            ? PosterArt.LoadState.Ready
            : PosterArt.LoadState.TerminalFallback
        return true
    }

    // CachedImageView.swift:75-76 lets the call site configure the placeholder,
    // and :58-66 resolves the ink it does not name: the elevated surface fill
    // at full opacity, 0.18 while a request is in flight against 0.32 once it
    // has ended without artwork, over a 0.34 wordmark. An explicit icon
    // opacity in the released view replaces both inks, so the two settings a
    // call site can make are three properties here.
    //
    // The defaults are MovieDetailView.swift:288-292's call, which names none
    // of them: the fill masks whatever the call site put beneath while the
    // request is in flight. MovieCard.swift:215-222 passes 0 and 0 instead, so
    // PosterCard.qml zeroes all three and a browse card keeps showing its
    // fallback artwork while it reads its sidecar.
    //
    // v3 resolves only the loading ink, because the placeholder shows only
    // while a request is in flight: the terminal presentation is already the
    // fallback artwork's own `film.fill` at 0.24 (MovieCard.swift:329-331).
    property real placeholderFillOpacity: 1.0
    property real placeholderIconOpacity: 0.18
    property real placeholderWordmarkOpacity: 0.34

    height: width / Theme.posterAspect
    radius: Theme.radiusMD
    // MovieCard.swift:206-207 fills the rounded surface with the elevated
    // surface colour.
    color: Theme.surfaceElevated
    clip: true

    // The rounded path every corner-reaching layer paints within, in the
    // canvas's own coordinates.
    function clipToSurface(context, width, height) {
        const corner = Math.max(0, Math.min(root.radius, Math.min(width, height) / 2))
        context.beginPath()
        context.moveTo(corner, 0)
        context.lineTo(width - corner, 0)
        context.arcTo(width, 0, width, corner, corner)
        context.lineTo(width, height - corner)
        context.arcTo(width, height, width - corner, height, corner)
        context.lineTo(corner, height)
        context.arcTo(0, height, 0, height - corner, corner)
        context.lineTo(0, corner)
        context.arcTo(0, 0, corner, 0, corner)
        context.closePath()
        context.clip()
    }

    // MovieCard.swift:309-351: PosterFallbackArtwork, drawn beneath whatever
    // artwork loads over it.
    Item {
        id: fallback
        objectName: "posterFallback"
        anchors.fill: parent

        Canvas {
            objectName: "posterFallbackGradient"
            anchors.fill: parent
            antialiasing: true

            // A top-leading to bottom-trailing gradient of the surface layer
            // at 0.96, the primary accent at 0.22, and the elevated surface at
            // 0.98; SwiftUI spaces three colours at 0, 0.5, and 1.
            onPaint: {
                const context = getContext("2d")
                context.reset()
                context.clearRect(0, 0, width, height)
                root.clipToSurface(context, width, height)
                const gradient = context.createLinearGradient(0, 0, width, height)
                gradient.addColorStop(0, Qt.rgba(Theme.surfaceLayer.r, Theme.surfaceLayer.g,
                                                 Theme.surfaceLayer.b, 0.96))
                gradient.addColorStop(0.5, Qt.rgba(Theme.accentPrimary.r, Theme.accentPrimary.g,
                                                   Theme.accentPrimary.b, 0.22))
                gradient.addColorStop(1, Qt.rgba(Theme.surfaceElevated.r, Theme.surfaceElevated.g,
                                                 Theme.surfaceElevated.b, 0.98))
                context.fillStyle = gradient
                context.fillRect(0, 0, width, height)
            }

            onWidthChanged: requestPaint()
            onHeightChanged: requestPaint()
        }

        // The `film.fill` symbol at 34/52 points, ultralight, in the tertiary
        // text colour at 0.24: a film frame with sprocket holes, drawn here
        // because SF Symbols are not available on this platform. `tv.fill`
        // is the same symbol slot for show cards: a filled screen on a stand.
        Canvas {
            objectName: "posterFallbackSymbol"
            anchors.centerIn: parent
            width: Theme.scaled(34, 52, root.leanBack)
            height: width * 0.72

            // The context keeps its state between paints, so the erase mode
            // used for the holes is confined to a saved state and the frame
            // is always painted source-over, whatever the previous paint left.
            onPaint: {
                const context = getContext("2d")
                context.globalCompositeOperation = "source-over"
                context.clearRect(0, 0, width, height)
                context.fillStyle = Qt.rgba(Theme.textTertiary.r, Theme.textTertiary.g,
                                            Theme.textTertiary.b, 0.24)
                if (root.symbol === "tv.fill") {
                    const screenHeight = height * 0.78
                    context.beginPath()
                    context.roundedRect(0, 0, width, screenHeight, width * 0.08, width * 0.08)
                    context.fill()
                    context.fillRect(width * 0.2, height - height * 0.14,
                                     width * 0.6, height * 0.14)
                    return
                }
                const inset = width * 0.04
                context.beginPath()
                context.roundedRect(inset, inset, width - 2 * inset, height - 2 * inset,
                                    width * 0.08, width * 0.08)
                context.fill()
                context.save()
                context.globalCompositeOperation = "destination-out"
                context.fillStyle = "#ffffff"
                const holeSize = width * 0.09
                const holeInset = width * 0.1
                for (let index = 0; index < 4; ++index) {
                    const x = holeInset + index * (width - 2 * holeInset - holeSize) / 3
                    context.fillRect(x, holeInset, holeSize, holeSize)
                    context.fillRect(x, height - holeInset - holeSize, holeSize, holeSize)
                }
                context.fillRect(holeInset, holeInset + holeSize * 1.6,
                                 width - 2 * holeInset, height - 2 * holeInset - holeSize * 3.2)
                context.restore()
            }

            onWidthChanged: requestPaint()
            onHeightChanged: requestPaint()
            Connections {
                target: root
                function onSymbolChanged() { requestPaint() }
            }
        }

        Column {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.margins: Theme.scaled(12, 18, root.leanBack)
            spacing: Theme.scaled(6, 9, root.leanBack)

            Text {
                objectName: "posterFallbackBadge"
                width: parent.width
                visible: root.badge.length > 0
                text: root.badge.toUpperCase()
                color: Qt.rgba(Theme.accentSecondary.r, Theme.accentSecondary.g,
                               Theme.accentSecondary.b, 0.78)
                font.pixelSize: Theme.scaled(9, 13, root.leanBack)
                font.weight: Font.Bold
                font.family: "monospace"
            }

            Text {
                objectName: "posterFallbackTitle"
                width: parent.width
                text: root.title
                color: Qt.rgba(Theme.textPrimary.r, Theme.textPrimary.g, Theme.textPrimary.b, 0.92)
                font.pixelSize: Theme.scaled(13, 19, root.leanBack)
                font.weight: Font.Bold
                wrapMode: Text.Wrap
                maximumLineCount: 4
                elide: Text.ElideRight
                horizontalAlignment: Text.AlignLeft
            }
        }
    }

    // CachedImageView.swift:86-129 draws a placeholder inside the artwork's own
    // layer whenever no image is showing for the current request, over whatever
    // the call site put beneath it. In v3 that is the fallback artwork above,
    // which already carries :120's `film` treatment for a request that ended
    // with no artwork; the state this surface had no treatment for is the one
    // still in flight, so the placeholder paints :120's `photo` treatment while
    // a request is loading and hands the surface back to the fallback the
    // moment it is not. How much of the fallback that covers is the call site's
    // to set, above: the details poster masks it as MovieDetailView.swift:288
    // does, and a browse card leaves it showing as MovieCard.swift:215-222
    // does. A request with no artwork at all never loads: MovieCard.swift:215
    // and MovieDetailView.swift:283 create the artwork layer only for a title
    // that has a sidecar.
    Item {
        id: placeholder
        objectName: "posterPlaceholder"
        anchors.fill: parent

        visible: root.loadState === PosterArt.LoadState.Loading

        // CachedImageView.swift:116-117 fills the placeholder's own rounded
        // rectangle with the elevated surface colour before :118-128 overlays
        // the symbol and wordmark, so a call site that leaves the fill at its
        // default hides whatever it stacked beneath while the request is in
        // flight; MovieCard.swift:220 passes 0 and keeps its fallback artwork
        // visible throughout.
        Rectangle {
            objectName: "posterPlaceholderFill"
            anchors.fill: parent
            radius: root.radius
            color: Theme.surfaceElevated
            opacity: root.placeholderFillOpacity
        }

        // CachedImageView.swift:119-127 centres the symbol above the wordmark,
        // spaced 6/9 points apart.
        Column {
            anchors.centerIn: parent
            spacing: Theme.scaled(6, 9, root.leanBack)

            // CachedImageView.swift:120-122 draws `photo` at 22/32 points,
            // ultralight, in the tertiary text colour at the loading opacity.
            // SF Symbols are not available on this platform, so it is stroked
            // here as an outlined frame holding a horizon and a sun, against
            // the filled film frame the fallback beneath draws.
            Canvas {
                id: placeholderSymbol
                objectName: "posterPlaceholderSymbol"
                anchors.horizontalCenter: parent.horizontalCenter
                width: Theme.scaled(22, 32, root.leanBack)
                height: width
                antialiasing: true

                // A canvas does not track the bindings its paint reads, and
                // the ink is the call site's to set.
                readonly property real ink: root.placeholderIconOpacity
                onInkChanged: requestPaint()

                onPaint: {
                    const context = getContext("2d")
                    context.reset()
                    context.clearRect(0, 0, width, height)
                    context.strokeStyle = Qt.rgba(Theme.textTertiary.r, Theme.textTertiary.g,
                                                  Theme.textTertiary.b, root.placeholderIconOpacity)
                    context.lineWidth = Math.max(1, width * 0.05)
                    context.lineJoin = "round"
                    context.lineCap = "round"
                    const inset = width * 0.08
                    const frameHeight = height * 0.76
                    const top = (height - frameHeight) / 2
                    context.beginPath()
                    context.roundedRect(inset, top, width - 2 * inset, frameHeight,
                                        width * 0.1, width * 0.1)
                    const base = top + frameHeight * 0.78
                    context.moveTo(inset + width * 0.06, base)
                    context.lineTo(width * 0.42, top + frameHeight * 0.38)
                    context.lineTo(width - inset - width * 0.06, base)
                    const sunRadius = width * 0.07
                    context.moveTo(width * 0.72 + sunRadius, top + frameHeight * 0.28)
                    context.arc(width * 0.72, top + frameHeight * 0.28, sunRadius, 0, 2 * Math.PI)
                    context.stroke()
                }

                onWidthChanged: requestPaint()
                onHeightChanged: requestPaint()
            }

            // CachedImageView.swift:123-126: the wordmark at 8/11 points,
            // semibold, tracked 1.8/2.4 points, in the secondary accent.
            Text {
                objectName: "posterPlaceholderWordmark"
                anchors.horizontalCenter: parent.horizontalCenter
                text: "MARQUEE"
                color: Qt.rgba(Theme.accentSecondary.r, Theme.accentSecondary.g,
                               Theme.accentSecondary.b, root.placeholderWordmarkOpacity)
                font.pixelSize: Theme.scaled(8, 11, root.leanBack)
                font.weight: Font.DemiBold
                font.letterSpacing: Theme.scaled(1.8, 2.4, root.leanBack)
            }
        }
    }

    // MovieCard.swift:214-222 draws the artwork over the fallback with no
    // placeholder of its own; a missing or undecodable sidecar draws nothing.
    // The image item loads and reports the artwork but paints nothing; the
    // canvas beneath draws what it loaded, filling the surface as
    // `PreserveAspectCrop` would, inside the rounded path.
    Image {
        id: image
        objectName: "posterArt"
        anchors.fill: parent
        visible: false

        // The generation the surface was on when this load began, so a
        // completion is matched against the request that started it.
        property int requestGeneration: 0

        source: root.artworkFailed ? "" : root.source
        asynchronous: true
        cache: true

        // CachedImageView.swift:175-186 settles a request from what the load
        // produced, and :88-91 treats a decoded image with no extent as no
        // image at all. The item's own source binding is re-evaluated after
        // the surface's `onSourceChanged` handler returns, so a settle asked
        // for before it caught up would judge this request by the previous
        // one's outcome; only the artwork the item actually holds may settle
        // the request that asked for it.
        function settleRequest() {
            if (String(image.source) !== String(root.loadRequest)
                    || (status !== Image.Ready && status !== Image.Error)) {
                return
            }
            root.completeRequest(image.source, image.requestGeneration,
                                 status === Image.Ready
                                     && image.implicitWidth > 0
                                     && image.implicitHeight > 0)
        }

        onStatusChanged: {
            // Setting `artworkFailed` re-evaluates this item's own source
            // binding and re-enters this handler before the assignment
            // returns, so the request is settled first, from the artwork this
            // handler was entered for, and only then is the source cleared.
            image.settleRequest()
            if (status === Image.Error) {
                root.artworkFailed = true
            }
            artwork.requestPaint()
        }
    }

    Canvas {
        id: artwork
        objectName: "posterArtwork"
        anchors.fill: parent
        antialiasing: true

        readonly property bool ready: image.status === Image.Ready
            && image.implicitWidth > 0 && image.implicitHeight > 0

        onPaint: {
            const context = getContext("2d")
            context.reset()
            context.clearRect(0, 0, width, height)
            if (!artwork.ready) {
                return
            }
            const source = String(image.source)
            if (!isImageLoaded(source)) {
                // The image item has already put the artwork in the pixmap
                // cache, so the canvas's own load is usually complete at once
                // and reports nothing; only a load still in flight announces
                // itself through imageLoaded, which requests this paint again.
                loadImage(source)
                if (!isImageLoaded(source)) {
                    return
                }
            }
            root.clipToSurface(context, width, height)
            const sourceWidth = image.implicitWidth
            const sourceHeight = image.implicitHeight
            const frameAspect = width / height
            const sourceAspect = sourceWidth / sourceHeight
            let cropX = 0
            let cropY = 0
            let cropWidth = sourceWidth
            let cropHeight = sourceHeight
            if (sourceAspect > frameAspect) {
                cropWidth = sourceHeight * frameAspect
                cropX = (sourceWidth - cropWidth) / 2
            } else {
                cropHeight = sourceWidth / frameAspect
                cropY = (sourceHeight - cropHeight) / 2
            }
            context.drawImage(source, cropX, cropY, cropWidth, cropHeight, 0, 0, width, height)
        }

        onReadyChanged: requestPaint()
        onImageLoaded: requestPaint()
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
    }
}
