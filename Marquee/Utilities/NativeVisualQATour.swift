#if DEBUG

import AppKit
import Darwin
import Foundation
import SwiftUI

enum VisualQAPosterArtworkFixture {
    enum Shape: String, Codable, Hashable {
        case wide
        case tall
    }

    struct Specification: Codable, Equatable {
        let title: String
        let shape: Shape
        let pixelWidth: Int
        let pixelHeight: Int

        var pixelSize: CGSize {
            CGSize(width: CGFloat(pixelWidth), height: CGFloat(pixelHeight))
        }

        var fileName: String {
            "poster-\(shape.rawValue).png"
        }
    }

    struct CaptureContract: Codable, Equatable {
        let captureName: String
        let renderingContract: String
        let frameAspectRatio: Double
        let sources: [Specification]
    }

    static let captureName = "06a-movies-poster-fill-crop-contract"
    static let renderingContract = "fill-crop-clipped"
    static let specifications = [
        Specification(
            title: "Alien Horizon",
            shape: .wide,
            pixelWidth: 720,
            pixelHeight: 240
        ),
        Specification(
            title: "Alien Signal",
            shape: .tall,
            pixelWidth: 240,
            pixelHeight: 720
        ),
    ]

    static var captureContract: CaptureContract {
        CaptureContract(
            captureName: captureName,
            renderingContract: renderingContract,
            frameAspectRatio: Double(UniversalPosterCardArtworkLayout.frameAspectRatio),
            sources: specifications
        )
    }

    @MainActor
    static func writeArtwork(to outputDirectory: URL) throws -> [String: String] {
        let artworkDirectory = outputDirectory.appendingPathComponent("fixture-poster-artwork", isDirectory: true)
        try FileManager.default.createDirectory(
            at: artworkDirectory,
            withIntermediateDirectories: true
        )

        var pathsByTitle: [String: String] = [:]
        for specification in specifications {
            let image = renderedImage(for: specification)
            guard let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else {
                throw FixtureError.encodingFailed(specification.title)
            }
            let url = artworkDirectory.appendingPathComponent(specification.fileName)
            try png.write(to: url, options: .atomic)
            pathsByTitle[specification.title] = url.path
        }
        return pathsByTitle
    }

    @MainActor
    private static func renderedImage(for specification: Specification) -> NSImage {
        let image = NSImage(size: specification.pixelSize)
        image.lockFocus()

        let bounds = NSRect(origin: .zero, size: specification.pixelSize)
        let gradient = NSGradient(colors: [
            NSColor(red: 0.11, green: 0.08, blue: 0.19, alpha: 1),
            NSColor(red: 0.48, green: 0.37, blue: 0.66, alpha: 1),
            NSColor(red: 0.79, green: 0.66, blue: 0.30, alpha: 1),
        ])
        gradient?.draw(in: bounds, angle: specification.shape == .wide ? 0 : 90)

        NSColor(red: 0.96, green: 0.94, blue: 0.92, alpha: 0.92).setStroke()
        let outline = NSBezierPath(rect: bounds.insetBy(dx: 14, dy: 14))
        outline.lineWidth = 8
        outline.stroke()

        let label = specification.shape.rawValue.uppercased() as NSString
        let fontSize = min(specification.pixelSize.width, specification.pixelSize.height) * 0.18
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        let labelSize = label.size(withAttributes: attributes)
        label.draw(
            at: NSPoint(
                x: (specification.pixelSize.width - labelSize.width) / 2,
                y: (specification.pixelSize.height - labelSize.height) / 2
            ),
            withAttributes: attributes
        )

        image.unlockFocus()
        return image
    }

    private enum FixtureError: Error, CustomStringConvertible {
        case encodingFailed(String)

        var description: String {
            switch self {
            case .encodingFailed(let title):
                return "could not encode visual poster artwork fixture for \(title)"
            }
        }
    }
}

enum VisualQAEpisodeSeasonArtworkFixture {
    struct Key: Hashable, CustomStringConvertible {
        let season: Int
        let episode: Int

        var description: String {
            "S\(season)E\(episode)"
        }
    }

    struct Marker {
        let key: Key
        let color: NSColor

        var fileName: String {
            "episode-season-\(key.season)-episode-\(key.episode).png"
        }
    }

    static let markers = [
        Marker(
            key: Key(season: 1, episode: 1),
            color: NSColor(srgbRed: 0.90, green: 0.10, blue: 0.05, alpha: 1)
        ),
        Marker(
            key: Key(season: 1, episode: 2),
            color: NSColor(srgbRed: 0.92, green: 0.45, blue: 0.04, alpha: 1)
        ),
        Marker(
            key: Key(season: 1, episode: 3),
            color: NSColor(srgbRed: 0.88, green: 0.08, blue: 0.38, alpha: 1)
        ),
        Marker(
            key: Key(season: 1, episode: 4),
            color: NSColor(srgbRed: 0.60, green: 0.22, blue: 0.04, alpha: 1)
        ),
        Marker(
            key: Key(season: 1, episode: 5),
            color: NSColor(srgbRed: 0.98, green: 0.32, blue: 0.62, alpha: 1)
        ),
        Marker(
            key: Key(season: 1, episode: 6),
            color: NSColor(srgbRed: 0.66, green: 0.52, blue: 0.04, alpha: 1)
        ),
        Marker(
            key: Key(season: 1, episode: 7),
            color: NSColor(srgbRed: 0.72, green: 0.06, blue: 0.70, alpha: 1)
        ),
        Marker(
            key: Key(season: 2, episode: 1),
            color: NSColor(srgbRed: 0.04, green: 0.78, blue: 0.42, alpha: 1)
        ),
        Marker(
            key: Key(season: 2, episode: 2),
            color: NSColor(srgbRed: 0.03, green: 0.48, blue: 0.92, alpha: 1)
        ),
        Marker(
            key: Key(season: 2, episode: 3),
            color: NSColor(srgbRed: 0.08, green: 0.82, blue: 0.86, alpha: 1)
        ),
    ]

    @MainActor
    static func writeArtwork(to outputDirectory: URL) throws -> [Key: String] {
        let artworkDirectory = outputDirectory.appendingPathComponent(
            "fixture-episode-season-artwork",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: artworkDirectory,
            withIntermediateDirectories: true
        )

        var pathsByEpisode: [Key: String] = [:]
        for marker in markers {
            guard let bitmap = renderedBitmap(for: marker),
                  let png = bitmap.representation(using: .png, properties: [:]) else {
                throw FixtureError.encodingFailed(marker.key)
            }
            let url = artworkDirectory.appendingPathComponent(marker.fileName)
            try png.write(to: url, options: .atomic)
            pathsByEpisode[marker.key] = url.path
        }
        return pathsByEpisode
    }

    static func markerPixelCounts(in bitmap: NSBitmapImageRep) -> [Key: Int] {
        var counts = Dictionary(uniqueKeysWithValues: markers.map { ($0.key, 0) })
        let xStride = max(1, bitmap.pixelsWide / 640)
        let yStride = max(1, bitmap.pixelsHigh / 360)
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: yStride) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: xStride) {
                guard let color = bitmap.colorAt(x: x, y: y) else {
                    continue
                }
                for marker in markers where matches(color, marker: marker.color) {
                    counts[marker.key, default: 0] += 1
                }
            }
        }
        return counts
    }

    static func focusRingPixelCount(
        in bitmap: NSBitmapImageRep,
        firstEpisodeKey: Key
    ) -> Int {
        guard let marker = markers.first(where: { $0.key == firstEpisodeKey }),
              let markerBounds = boundsOfMarker(marker.color, in: bitmap) else {
            return 0
        }
        let focusColor = NSColor(
            srgbRed: CGFloat(StructuralFocusPalette.red),
            green: CGFloat(StructuralFocusPalette.green),
            blue: CGFloat(StructuralFocusPalette.blue),
            alpha: 1
        )
        // Anchor the crop to the rendered first-episode thumbnail, then scan
        // only to its right. The focused row's long horizontal border crosses
        // this region, while the season controls cannot contribute pixels.
        let xLowerBound = min(bitmap.pixelsWide, markerBounds.maxX + 20)
        let xUpperBound = min(bitmap.pixelsWide, Int(Double(bitmap.pixelsWide) * 0.98))
        let yLowerBound = max(0, markerBounds.minY - 20)
        let yUpperBound = min(bitmap.pixelsHigh, markerBounds.maxY + 21)
        guard xLowerBound < xUpperBound, yLowerBound < yUpperBound else { return 0 }

        var count = 0
        for y in yLowerBound..<yUpperBound {
            for x in xLowerBound..<xUpperBound {
                guard let color = bitmap.colorAt(x: x, y: y) else {
                    continue
                }
                if matches(color, marker: focusColor, tolerance: 0.14) {
                    count += 1
                }
            }
        }
        return count
    }

    private static func boundsOfMarker(
        _ marker: NSColor,
        in bitmap: NSBitmapImageRep
    ) -> (minX: Int, maxX: Int, minY: Int, maxY: Int)? {
        let xStride = max(1, bitmap.pixelsWide / 640)
        let yStride = max(1, bitmap.pixelsHigh / 360)
        var minX = bitmap.pixelsWide
        var maxX = -1
        var minY = bitmap.pixelsHigh
        var maxY = -1

        for y in stride(from: 0, to: bitmap.pixelsHigh, by: yStride) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: xStride) {
                guard let color = bitmap.colorAt(x: x, y: y),
                      matches(color, marker: marker) else {
                    continue
                }
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }

        guard maxX >= minX, maxY >= minY else { return nil }
        return (minX, maxX, minY, maxY)
    }

    @MainActor
    private static func renderedBitmap(for marker: Marker) -> NSBitmapImageRep? {
        let size = CGSize(width: 640, height: 360)
        // Draw into an explicitly sRGB-tagged bitmap so marker pixels are
        // numerically exact and display-independent. `lockFocus` renders
        // through the main display's profile, which clips marker channels
        // (e.g. Color LCD collapses the S1E1 green/blue components to zero)
        // and breaks exact-color validation whenever the display changes.
        guard let base = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width),
            pixelsHigh: Int(size.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let bitmap = base.retagging(with: .sRGB),
        let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context

        let bounds = NSRect(origin: .zero, size: size)
        marker.color.setFill()
        NSBezierPath(rect: bounds).fill()

        NSColor.white.withAlphaComponent(0.92).setStroke()
        let outline = NSBezierPath(rect: bounds.insetBy(dx: 14, dy: 14))
        outline.lineWidth = 8
        outline.stroke()

        let label = marker.key.description as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 72, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        let labelSize = label.size(withAttributes: attributes)
        label.draw(
            at: NSPoint(
                x: (size.width - labelSize.width) / 2,
                y: (size.height - labelSize.height) / 2
            ),
            withAttributes: attributes
        )

        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }

    private static func matches(
        _ observed: NSColor,
        marker: NSColor,
        tolerance: CGFloat = 0.10
    ) -> Bool {
        abs(observed.redComponent - marker.redComponent) < tolerance
            && abs(observed.greenComponent - marker.greenComponent) < tolerance
            && abs(observed.blueComponent - marker.blueComponent) < tolerance
    }

    private enum FixtureError: Error, CustomStringConvertible {
        case encodingFailed(Key)

        var description: String {
            switch self {
            case .encodingFailed(let key):
                return "could not encode visual episode artwork fixture for \(key)"
            }
        }
    }
}

@MainActor
final class NativeVisualQATour {
    static let shared = NativeVisualQATour()
    static let launchArgument = "--qa-visual-tour"
    static let timingLaunchArgument = "--qa-timing-tour"
    static let searchRemoteKeyboardLaunchArgument = "--qa-search-remote-keyboard-tour"

    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
            || ProcessInfo.processInfo.arguments.contains(timingLaunchArgument)
            || ProcessInfo.processInfo.arguments.contains(searchRemoteKeyboardLaunchArgument)
    }

    private static var isTimingOnlyRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(timingLaunchArgument)
            && !ProcessInfo.processInfo.arguments.contains(launchArgument)
            && !ProcessInfo.processInfo.arguments.contains(searchRemoteKeyboardLaunchArgument)
    }

    private static var isSearchRemoteKeyboardRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(searchRemoteKeyboardLaunchArgument)
    }

    typealias RouteHandler = (SidebarItem) -> Void
    typealias RemoteSender = (RemoteCommand) -> Void
    typealias MovieDetailOpener = (MediaItem) -> Void
    typealias ShowDetailOpener = (String) -> Void
    typealias DetailDismisser = () -> Void

    private var hasStarted = false
    private var installedFixtureTitles: [String] = []
    private var installedPosterArtworkContract: VisualQAPosterArtworkFixture.CaptureContract?

    private init() {}

    func startIfRequested(
        window: NSWindow,
        appState: AppState,
        setRoute: @escaping RouteHandler,
        sendRemote: @escaping RemoteSender,
        openMovieDetail: @escaping MovieDetailOpener,
        openShowDetail: @escaping ShowDetailOpener,
        dismissDetail: @escaping DetailDismisser
    ) {
        guard Self.isRequested, !hasStarted else { return }
        hasStarted = true

        Task { @MainActor in
            do {
                // Pin the window's backing store to sRGB so captures carry
                // identical pixel values on every display. Without this the
                // window server renders through the active display's color
                // profile and exact-color marker validation fails whenever
                // the main display changes (e.g. the TV becomes primary).
                window.colorSpace = .sRGB
                let config = try Self.configuration()
                installedFixtureTitles = []
                installedPosterArtworkContract = nil
                if !Self.isTimingOnlyRequested && !Self.isSearchRemoteKeyboardRequested {
                    appState.library.debugSimilarityIndexComputeDelayForHarness = 15.0
                }
                try installVisualTourFixtureIfNeeded(
                    appState,
                    outputDirectory: config.outputDirectory
                )
                let manifest: Manifest
                if Self.isSearchRemoteKeyboardRequested {
                    manifest = try await runSearchRemoteKeyboardOnly(
                        config: config,
                        window: window,
                        appState: appState,
                        setRoute: setRoute,
                        dismissDetail: dismissDetail
                    )
                } else if Self.isTimingOnlyRequested {
                    manifest = try await runTimingOnly(
                        config: config,
                        window: window,
                        appState: appState,
                        setRoute: setRoute,
                        openMovieDetail: openMovieDetail,
                        openShowDetail: openShowDetail,
                        dismissDetail: dismissDetail
                    )
                } else {
                    manifest = try await run(
                        config: config,
                        window: window,
                        appState: appState,
                        setRoute: setRoute,
                        sendRemote: sendRemote,
                        openMovieDetail: openMovieDetail,
                        openShowDetail: openShowDetail,
                        dismissDetail: dismissDetail
                    )
                }
                let manifestURL = try write(manifest: manifest, to: config.outputDirectory)
                if Self.isTimingOnlyRequested {
                    try validateTimingManifest(manifest)
                }
                let prefix = Self.isSearchRemoteKeyboardRequested
                    ? "native-search-remote-keyboard-qa"
                    : (Self.isTimingOnlyRequested ? "native-timing-qa" : "native-visual-qa")
                writeStderr("\(prefix): PASS manifest=\(manifestURL.path) captures=\(manifest.captures.count) probes=\(manifest.budgetProbes.count)")
                Darwin.exit(0)
            } catch {
                let prefix = Self.isSearchRemoteKeyboardRequested
                    ? "native-search-remote-keyboard-qa"
                    : (Self.isTimingOnlyRequested ? "native-timing-qa" : "native-visual-qa")
                writeStderr("\(prefix): FAIL \(error)")
                Darwin.exit(1)
            }
        }
    }

    private func runTimingOnly(
        config: Config,
        window: NSWindow,
        appState: AppState,
        setRoute: RouteHandler,
        openMovieDetail: MovieDetailOpener,
        openShowDetail: ShowDetailOpener,
        dismissDetail: DetailDismisser
    ) async throws -> Manifest {
        try FileManager.default.createDirectory(
            at: config.outputDirectory,
            withIntermediateDirectories: true
        )

        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        try await settle(1.2)

        var budgetProbes: [BudgetProbe] = []
        let signals = QASurfaceSignals()

        if !appState.showProfilePicker {
            appState.switchProfile()
            try await settle(0.1)
        }
        guard let adult = appState.profileStore.profiles.first(where: { $0.maturityLevel == .adult }),
              let kids = appState.profileStore.profiles.first(where: { $0.maturityLevel == .kids }) else {
            throw HarnessError.assertion("timing tour requires both adult and kids fixture profiles")
        }

        signals.reset()
        let adultSelectionStartedAt = Date()
        appState.selectProfile(adult)
        guard await settleUntil(timeout: 5.0, condition: {
            completedProfileSelectionDate(
                profileID: adult.id,
                startedAt: adultSelectionStartedAt,
                appState: appState,
                signals: signals
            ) != nil
        }), let adultSelectionCompletedAt = completedProfileSelectionDate(
            profileID: adult.id,
            startedAt: adultSelectionStartedAt,
            appState: appState,
            signals: signals
        ) else {
            throw HarnessError.assertion("adult profile selection never reached current filtered, interactive Home rows")
        }
        try recordLayoutBudgetProbe(
            window: window,
            name: "01-timing-adult-profile-select-1200ms",
            route: "home",
            detail: "Timing-only probe: adult profile selection should finish its deferred filtered recompute, transition, and expose a mounted interactive Home row by 1200ms (observed 451-1001ms across standalone and release-gate runs on Broadwell/macOS 12).",
            actionStartedAt: adultSelectionStartedAt,
            actionCompletedAt: adultSelectionCompletedAt,
            targetMS: 1_200,
            budgetProbes: &budgetProbes
        )
        try await settle(0.7)

        appState.switchProfile()
        try await settle(0.3)
        signals.reset()
        let kidsSelectionStartedAt = Date()
        appState.selectProfile(kids)
        guard await settleUntil(timeout: 5.0, condition: {
            !appState.isProfileExitInFlight && completedProfileSelectionDate(
                profileID: kids.id,
                startedAt: kidsSelectionStartedAt,
                appState: appState,
                signals: signals
            ) != nil
        }), let kidsSelectionCompletedAt = completedProfileSelectionDate(
            profileID: kids.id,
            startedAt: kidsSelectionStartedAt,
            appState: appState,
            signals: signals
        ) else {
            throw HarnessError.assertion("kids profile selection never reached current filtered, interactive Home rows")
        }
        try recordLayoutBudgetProbe(
            window: window,
            name: "01b-timing-kids-profile-select-800ms",
            route: "home",
            detail: "Timing-only probe: kids selection should finish the maturity-filtered snapshot and expose interactive Home rows by 800ms.",
            actionStartedAt: kidsSelectionStartedAt,
            actionCompletedAt: kidsSelectionCompletedAt,
            targetMS: 800,
            budgetProbes: &budgetProbes
        )
        try await settle(0.7)

        appState.switchProfile()
        try await settle(0.1)
        signals.reset()
        let finalAdultSelectionStartedAt = Date()
        appState.selectProfile(adult)
        guard await settleUntil(timeout: 5.0, condition: {
            completedProfileSelectionDate(
                profileID: adult.id,
                startedAt: finalAdultSelectionStartedAt,
                appState: appState,
                signals: signals
            ) != nil
        }) else {
            throw HarnessError.assertion("final adult profile restore never reached current filtered, interactive Home rows")
        }

        try await waitForBrowseSurface(appState)
        let similarityStartedAt = Date()

        try recordLayoutBudgetProbe(
            window: window,
            name: "02-timing-home-layout-now",
            route: "home",
            detail: "Timing-only probe: settled Home layout/display cost without PNG capture.",
            actionStartedAt: Date(),
            targetMS: 50,
            budgetProbes: &budgetProbes
        )

        signals.reset()
        let moviesStartedAt = Date()
        setRoute(.movies)
        guard await settleUntil(timeout: 2.0, condition: {
            signals.routeAppearances["movies"] != nil
        }) else {
            throw HarnessError.assertion("Movies route did not mount during its timing probe")
        }
        try recordLayoutBudgetProbe(
            window: window,
            name: "03-timing-movies-route-500ms",
            route: "movies",
            detail: "Timing-only probe: Movies route should appear by 500ms (condition-polled on surface onAppear; the heaviest grid mount measures 247-412ms across runs on Broadwell/macOS 12).",
            actionStartedAt: moviesStartedAt,
            actionCompletedAt: signals.routeAppearances["movies"],
            targetMS: 500,
            budgetProbes: &budgetProbes
        )

        signals.reset()
        let tvStartedAt = Date()
        setRoute(.tvShows)
        guard await settleUntil(timeout: 2.0, condition: {
            signals.routeAppearances["tv-shows"] != nil
        }) else {
            throw HarnessError.assertion("TV route did not mount during its timing probe")
        }
        try recordLayoutBudgetProbe(
            window: window,
            name: "04-timing-tv-route-350ms",
            route: "tv-shows",
            detail: "Timing-only probe: TV route should appear by 350ms (condition-polled on surface onAppear; mounts measure 150-300ms with run-to-run jitter on Broadwell/macOS 12).",
            actionStartedAt: tvStartedAt,
            actionCompletedAt: signals.routeAppearances["tv-shows"],
            targetMS: 350,
            budgetProbes: &budgetProbes
        )

        signals.reset()
        let searchRouteStartedAt = Date()
        setRoute(.search)
        guard await settleUntil(timeout: 2.0, condition: {
            signals.routeAppearances["search"] != nil
        }) else {
            throw HarnessError.assertion("Search route did not mount during its timing probe")
        }
        try recordLayoutBudgetProbe(
            window: window,
            name: "05-timing-search-route-250ms",
            route: "search",
            detail: "Timing-only probe: Search route should appear by 250ms (condition-polled on surface onAppear).",
            actionStartedAt: searchRouteStartedAt,
            actionCompletedAt: signals.routeAppearances["search"],
            targetMS: 250,
            budgetProbes: &budgetProbes
        )

        try await settle(0.20)
        signals.reset()
        let searchSeedStartedAt = Date()
        SearchInputBuffer.shared.seedForVisualQA(config.searchQuery)
        guard await settleUntil(timeout: 2.0, condition: {
            signals.searchPublications.contains(where: { $0.resultCount > 0 })
        }) else {
            throw HarnessError.assertion("Search did not publish non-empty results during its timing probe")
        }
        try recordLayoutBudgetProbe(
            window: window,
            name: "06-timing-search-results-100ms",
            route: "search",
            detail: "Timing-only probe: seeded in-memory indexed Search query '\(config.searchQuery)' should publish results by 100ms (condition-polled on publication).",
            actionStartedAt: searchSeedStartedAt,
            actionCompletedAt: signals.searchPublications.first(where: { $0.resultCount > 0 })?.publishedAt,
            targetMS: 100,
            budgetProbes: &budgetProbes
        )

        if let movie = firstMovieCandidate(searchQuery: config.searchQuery, appState: appState) {
            signals.reset()
            let movieDetailStartedAt = Date()
            openMovieDetail(movie)
            guard await settleUntil(timeout: 3.0, condition: {
                signals.detailsAppeared.contains("movie")
            }) else {
                throw HarnessError.assertion("Movie detail did not mount during its timing probe")
            }
            try recordLayoutBudgetProbe(
                window: window,
                name: "07-timing-movie-detail-500ms",
                route: "movie-detail",
                detail: "Timing-only probe: Movie detail for '\(movie.displayTitle)' should appear by 500ms (condition-polled on surface onAppear).",
                actionStartedAt: movieDetailStartedAt,
                targetMS: 500,
                budgetProbes: &budgetProbes
            )
            dismissDetail()
            try await settle(0.25)
        }

        if let showName = firstShowCandidate(searchQuery: config.searchQuery, appState: appState) {
            signals.reset()
            let showDetailStartedAt = Date()
            openShowDetail(showName)
            guard await settleUntil(timeout: 3.0, condition: {
                signals.detailsAppeared.contains("show")
            }) else {
                throw HarnessError.assertion("Show detail did not mount during its timing probe")
            }
            try recordLayoutBudgetProbe(
                window: window,
                name: "08-timing-show-detail-500ms",
                route: "show-detail",
                detail: "Timing-only probe: Show detail for '\(showName)' should appear by 500ms (condition-polled on surface onAppear).",
                actionStartedAt: showDetailStartedAt,
                targetMS: 500,
                budgetProbes: &budgetProbes
            )
            dismissDetail()
            try await settle(0.25)
        }

        _ = await settleUntil(timeout: 7.25) {
            appState.library.browseSnapshot.similarity != nil
        }
        let similarityObservedMS = milliseconds(from: similarityStartedAt, to: Date())
        budgetProbes.append(BudgetProbe(
            name: "02a-timing-similarity-index-7000ms",
            route: "home",
            targetMS: 7_000,
            observedMS: similarityObservedMS,
            withinTarget: appState.library.browseSnapshot.similarity != nil && similarityObservedMS <= 7_000,
            captureFile: nil,
            layoutMS: nil,
            totalMS: similarityObservedMS,
            detail: "Timing-only probe: background similarity-index compute should attach off the snapshot-build path without starving first interactions."
        ))

        try assertInstalledVisualFixtureStillPresent(appState)

        return Manifest(
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            buildVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            outputDirectory: config.outputDirectory.path,
            searchQuery: config.searchQuery,
            contentSummary: contentSummary(appState),
            captures: [],
            budgetProbes: budgetProbes,
            searchRemoteKeyboardSnapshots: [],
            visualFixtureInstalled: !installedFixtureTitles.isEmpty,
            visualFixtureTitles: installedFixtureTitles,
            posterArtworkContract: installedPosterArtworkContract
        )
    }

    private func validateTimingManifest(_ manifest: Manifest) throws {
        let expectedNames: Set<String> = [
            "01-timing-adult-profile-select-1200ms",
            "01b-timing-kids-profile-select-800ms",
            "02-timing-home-layout-now",
            "02a-timing-similarity-index-7000ms",
            "03-timing-movies-route-500ms",
            "04-timing-tv-route-350ms",
            "05-timing-search-route-250ms",
            "06-timing-search-results-100ms",
            "07-timing-movie-detail-500ms",
            "08-timing-show-detail-500ms",
        ]
        let actualNames = Set(manifest.budgetProbes.map(\.name))
        guard manifest.budgetProbes.count == expectedNames.count,
              actualNames == expectedNames else {
            throw HarnessError.assertion(
                "timing tour must emit exactly the ten required probes; expected=\(expectedNames.sorted()) actual=\(manifest.budgetProbes.map(\.name).sorted())"
            )
        }
        let missed = manifest.budgetProbes.filter { !$0.withinTarget }
        guard missed.isEmpty else {
            let detail = missed.map {
                "\($0.name)=\(Int($0.totalMS ?? $0.observedMS))ms/\(Int($0.targetMS))ms"
            }.joined(separator: ", ")
            throw HarnessError.assertion("timing budgets missed: \(detail)")
        }
    }

    private func run(
        config: Config,
        window: NSWindow,
        appState: AppState,
        setRoute: RouteHandler,
        sendRemote: RemoteSender,
        openMovieDetail: MovieDetailOpener,
        openShowDetail: ShowDetailOpener,
        dismissDetail: DetailDismisser
    ) async throws -> Manifest {
        try FileManager.default.createDirectory(
            at: config.outputDirectory,
            withIntermediateDirectories: true
        )

        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        let tourStartedAt = Date()
        try await settle(1.2)

        var captures: [Capture] = []
        let budgetProbes: [BudgetProbe] = []
        let signals = QASurfaceSignals()

        if appState.showProfilePicker {
            let profiles = appState.profileStore.profiles
            guard let adultIndex = profiles.firstIndex(where: { $0.maturityLevel == .adult }) else {
                throw HarnessError.assertion("no adult profile available for QA tour")
            }
            for _ in 0..<adultIndex {
                try sendSearchRemoteKeyEvent(.right, window: window)
                try await settle(0.05)
            }
            let profile = profiles[adultIndex]
            let profileBeforeCapture = try capture(
                window: window,
                outputDirectory: config.outputDirectory,
                name: "01-profile-picker",
                route: "profile-picker",
                detail: "Initial picker before selecting the default profile.",
                tourStartedAt: tourStartedAt,
                capturesWindowPresentation: true
            )
            captures.append(profileBeforeCapture)
            try sendSearchRemoteKeyEvent(.select, window: window)
            await settleUntil(timeout: 0.5) {
                appState.profileExitSelectionID == profile.id
            }
            guard appState.profileExitSelectionID == profile.id else {
                throw HarnessError.assertion("remote profile exit selection did not start for QA tour")
            }
            appState.deferProfileExitPresentationForVisualQA(selectionID: profile.id)
            await yieldMainQueueTurn()
            appState.startDeferredProfileExitPresentationForVisualQA(selectionID: profile.id)
            await yieldMainQueueTurn()
            appState.armProfileExitCompletionForVisualQA(selectionID: profile.id)
            try await settle(ProfileExitTransitionPolicy.duration / 2)
            guard appState.profileExitSelectionID == profile.id else {
                throw HarnessError.assertion("profile exit ownership ended before its midpoint")
            }
            let profileDuringCapture = try capture(
                window: window,
                outputDirectory: config.outputDirectory,
                name: "01a-profile-picker-exit-crossfade",
                route: "profile-picker-exit",
                detail: "During the real opacity-only profile exit while input ownership remains locked.",
                tourStartedAt: tourStartedAt,
                capturesWindowPresentation: true
            )
            guard try Data(contentsOf: URL(fileURLWithPath: profileBeforeCapture.file))
                != Data(contentsOf: URL(fileURLWithPath: profileDuringCapture.file)) else {
                throw HarnessError.assertion("profile exit presentation did not advance by its midpoint")
            }
            let profilePresentationDelta = try meanLuminanceDifference(
                firstFile: profileBeforeCapture.file,
                secondFile: profileDuringCapture.file
            )
            guard profilePresentationDelta >= 0.01 else {
                throw HarnessError.assertion(
                    "profile exit midpoint changed only by compositor noise: meanLuminanceDelta=\(profilePresentationDelta)"
                )
            }
            captures.append(profileDuringCapture)
            await settleUntil(timeout: 1.0) {
                appState.profileExitSelectionID == nil && !appState.showProfilePicker
            }
            guard appState.profileExitSelectionID == nil,
                  !appState.showProfilePicker else {
                throw HarnessError.assertion("profile exit did not complete before the settled Home capture")
            }
            await yieldMainQueueTurn()
            captures.append(try capture(
                window: window,
                outputDirectory: config.outputDirectory,
                name: "02-profile-selection-home",
                route: "home",
                detail: "Home immediately after the profile-selection transition completes.",
                tourStartedAt: tourStartedAt
            ))
            try await settle(1.1)
        }

        try await waitForBrowseSurface(appState)
        let nextEpisodeEvidence = try verifyNextEpisodeContract(
            searchQuery: config.searchQuery,
            appState: appState
        )
        let firstPublishComposition = BrowseCompositionIdentity(snapshot: appState.library.browseSnapshot)
        guard appState.library.browseSnapshot.similarity == nil else {
            throw HarnessError.assertion("first-publish Home capture occurred after similarity was already attached")
        }

        captures.append(try capture(
            window: window,
            outputDirectory: config.outputDirectory,
            name: "03-home-initial",
            route: "home",
            detail: contentSummary(appState),
            tourStartedAt: tourStartedAt
        ))

        sendRemote(.down)
        try await settle(0.35)
        sendRemote(.right)
        try await settle(0.45)
        captures.append(try capture(
            window: window,
            outputDirectory: config.outputDirectory,
            name: "04-home-focus-moved",
            route: "home",
            detail: "After down/right remote traversal from the home surface.",
            tourStartedAt: tourStartedAt
        ))
        sendRemote(.select)
        try await settle(0.70)
        captures.append(try capture(
            window: window,
            outputDirectory: config.outputDirectory,
            name: "04a-home-detail-open",
            route: "home-detail",
            detail: "Home focused row item opened through the shipped remote path.",
            tourStartedAt: tourStartedAt
        ))
        sendRemote(.back)
        try await settle(0.90)
        captures.append(try capture(
            window: window,
            outputDirectory: config.outputDirectory,
            name: "04b-home-detail-return-placement",
            route: "home",
            detail: "Home after detail dismissal; current focused row must be re-placed in the reading band.",
            tourStartedAt: tourStartedAt
        ))
        let homeReturn = try await requireCurrentReturnEvidence(route: .home, signals: signals)
        try await verifyManualPlayerDismissal(
            route: .home,
            baseline: homeReturn,
            appState: appState,
            signals: signals
        )
        captures.append(try capture(
            window: window,
            outputDirectory: config.outputDirectory,
            name: "04c-home-player-return-placement",
            route: "home",
            detail: "Home after a live PlayerController presented-to-dismissed publisher sequence.",
            tourStartedAt: tourStartedAt
        ))
        try await verifyEndedPlaybackDismissal(
            route: .home,
            baseline: homeReturn,
            appState: appState,
            signals: signals
        )
        captures.append(try capture(
            window: window,
            outputDirectory: config.outputDirectory,
            name: "04d-home-post-play-return-placement",
            route: "home",
            detail: "Home after live player-ended to post-play to final-dismissal publisher ordering.",
            tourStartedAt: tourStartedAt
        ))

        setRoute(.movies)
        try await settle(0.25)
        captures.append(try capture(
            window: window,
            outputDirectory: config.outputDirectory,
            name: "05-movies-route-early",
            route: "movies",
            detail: "Early Movies route state before the settled visual capture.",
            tourStartedAt: tourStartedAt
        ))
        try await settle(0.45)
        captures.append(try capture(
            window: window,
            outputDirectory: config.outputDirectory,
            name: "06-movies-initial",
            route: "movies",
            detail: "Movies route after programmatic route change.",
            tourStartedAt: tourStartedAt
        ))
        if let contract = installedPosterArtworkContract {
            captures.append(try capture(
                window: window,
                outputDirectory: config.outputDirectory,
                name: contract.captureName,
                route: "movies",
                detail: "Contract: wide and tall odd-aspect fixture art must fill-crop into identical 2:3 UniversalPosterCard frames with no letterboxing.",
                tourStartedAt: tourStartedAt
            ))
        }
        sendRemote(.down)
        try await settle(0.35)
        sendRemote(.right)
        try await settle(0.4)
        captures.append(try capture(
            window: window,
            outputDirectory: config.outputDirectory,
            name: "07-movies-focus-moved",
            route: "movies",
            detail: "Movies route after down/right remote traversal.",
            tourStartedAt: tourStartedAt
        ))
        sendRemote(.select)
        try await settle(0.70)
        captures.append(try capture(
            window: window,
            outputDirectory: config.outputDirectory,
            name: "07a-movies-detail-open",
            route: "movies-detail",
            detail: "Movies focused row item opened through the shipped remote path.",
            tourStartedAt: tourStartedAt
        ))
        sendRemote(.back)
        try await settle(0.90)
        captures.append(try capture(
            window: window,
            outputDirectory: config.outputDirectory,
            name: "07b-movies-detail-return-placement",
            route: "movies",
            detail: "Movies after detail dismissal; current focused row must be re-placed in the reading band.",
            tourStartedAt: tourStartedAt
        ))
        try await settle(1.20)
        captures.append(try capture(
            window: window,
            outputDirectory: config.outputDirectory,
            name: "07c-movies-detail-return-placement-late",
            route: "movies",
            detail: "Movies 1.2 seconds after detail dismissal; focused card and ring must remain present after placement settles.",
            tourStartedAt: tourStartedAt
        ))
        let moviesReturn = try await requireCurrentReturnEvidence(route: .movies, signals: signals)
        try await verifyManualPlayerDismissal(
            route: .movies,
            baseline: moviesReturn,
            appState: appState,
            signals: signals
        )
        captures.append(try capture(
            window: window,
            outputDirectory: config.outputDirectory,
            name: "07d-movies-player-return-placement",
            route: "movies",
            detail: "Movies after a live PlayerController presented-to-dismissed publisher sequence.",
            tourStartedAt: tourStartedAt
        ))
        try await verifyEndedPlaybackDismissal(
            route: .movies,
            baseline: moviesReturn,
            appState: appState,
            signals: signals
        )
        captures.append(try capture(
            window: window,
            outputDirectory: config.outputDirectory,
            name: "07e-movies-post-play-return-placement",
            route: "movies",
            detail: "Movies after live player-ended to post-play to final-dismissal publisher ordering.",
            tourStartedAt: tourStartedAt
        ))

        setRoute(.tvShows)
        try await settle(0.25)
        captures.append(try capture(
            window: window,
            outputDirectory: config.outputDirectory,
            name: "08-tv-route-early",
            route: "tv-shows",
            detail: "Early TV route state before the settled visual capture.",
            tourStartedAt: tourStartedAt
        ))
        try await settle(0.45)
        captures.append(try capture(
            window: window,
            outputDirectory: config.outputDirectory,
            name: "09-tv-initial",
            route: "tv-shows",
            detail: "TV route after programmatic route change.",
            tourStartedAt: tourStartedAt
        ))
        sendRemote(.down)
        try await settle(0.35)
        sendRemote(.right)
        try await settle(0.45)
        captures.append(try capture(
            window: window,
            outputDirectory: config.outputDirectory,
            name: "10-tv-focus-moved",
            route: "tv-shows",
            detail: "TV route after down/right remote traversal.",
            tourStartedAt: tourStartedAt
        ))
        sendRemote(.select)
        try await settle(0.70)
        captures.append(try capture(
            window: window,
            outputDirectory: config.outputDirectory,
            name: "10a-tv-detail-open",
            route: "tv-detail",
            detail: "TV focused row show opened through the shipped remote path.",
            tourStartedAt: tourStartedAt
        ))
        sendRemote(.back)
        try await settle(0.90)
        captures.append(try capture(
            window: window,
            outputDirectory: config.outputDirectory,
            name: "10b-tv-detail-return-placement",
            route: "tv-shows",
            detail: "TV after detail dismissal; current focused row must be re-placed in the reading band.",
            tourStartedAt: tourStartedAt
        ))
        let tvReturn = try await requireCurrentReturnEvidence(route: .tvShows, signals: signals)
        try await verifyManualPlayerDismissal(
            route: .tvShows,
            baseline: tvReturn,
            appState: appState,
            signals: signals
        )
        captures.append(try capture(
            window: window,
            outputDirectory: config.outputDirectory,
            name: "10c-tv-player-return-placement",
            route: "tv-shows",
            detail: "TV after a live PlayerController presented-to-dismissed publisher sequence.",
            tourStartedAt: tourStartedAt
        ))
        try await verifyEndedPlaybackDismissal(
            route: .tvShows,
            baseline: tvReturn,
            appState: appState,
            signals: signals
        )
        captures.append(try capture(
            window: window,
            outputDirectory: config.outputDirectory,
            name: "10d-tv-post-play-return-placement",
            route: "tv-shows",
            detail: "TV after live player-ended to post-play to final-dismissal publisher ordering.",
            tourStartedAt: tourStartedAt
        ))

        setRoute(.search)
        try await settle(0.25)
        captures.append(try capture(
            window: window,
            outputDirectory: config.outputDirectory,
            name: "11-search-route-early",
            route: "search",
            detail: "Early Search route state before entering a query.",
            tourStartedAt: tourStartedAt
        ))
        try await settle(0.20)
        SearchInputBuffer.shared.seedForVisualQA(config.searchQuery)
        try await settle(0.10)
        captures.append(try capture(
            window: window,
            outputDirectory: config.outputDirectory,
            name: "12-search-results-early",
            route: "search",
            detail: "Early Search results state for seeded query '\(config.searchQuery)'.",
            tourStartedAt: tourStartedAt
        ))
        try await settle(0.60)
        captures.append(try capture(
            window: window,
            outputDirectory: config.outputDirectory,
            name: "13-search-query",
            route: "search",
            detail: "Search route with seeded query '\(config.searchQuery)'.",
            tourStartedAt: tourStartedAt
        ))

        NotificationCenter.default.post(name: .marqueeQAVisualTourFocusFirstSearchResult, object: nil)
        try await settle(0.45)
        captures.append(try capture(
            window: window,
            outputDirectory: config.outputDirectory,
            name: "14-search-result-focus",
            route: "search",
            detail: "Search route after focusing the first visible result through the same focus path as keyboard traversal.",
            tourStartedAt: tourStartedAt
        ))

        if let movie = firstMovieCandidate(searchQuery: config.searchQuery, appState: appState) {
            openMovieDetail(movie)
            try await settle(0.50)
            captures.append(try capture(
                window: window,
                outputDirectory: config.outputDirectory,
                name: "15-movie-detail-early",
                route: "movie-detail",
                detail: "Early Movie detail state for '\(movie.displayTitle)'.",
                tourStartedAt: tourStartedAt
            ))
            try await settle(0.50)
            captures.append(try capture(
                window: window,
                outputDirectory: config.outputDirectory,
                name: "16-movie-detail-top",
                route: "movie-detail",
                detail: "Movie detail opened for '\(movie.displayTitle)'.",
                tourStartedAt: tourStartedAt
            ))
            for step in 1...4 {
                sendRemote(.down)
                try await settle(0.45)
                captures.append(try capture(
                    window: window,
                    outputDirectory: config.outputDirectory,
                    name: "16-ladder\(step)-movie-detail-focus",
                    route: "movie-detail",
                    detail: "Movie detail focus ladder, step \(step) down from the action buttons — every stop must be visibly focused (NATIVE-P1-004 abyss class).",
                    tourStartedAt: tourStartedAt
                ))
            }
            try await settle(0.45)
            captures.append(try capture(
                window: window,
                outputDirectory: config.outputDirectory,
                name: "17-movie-detail-focus-lower",
                route: "movie-detail",
                detail: "Movie detail after repeated down traversal from the action buttons.",
                tourStartedAt: tourStartedAt
            ))
            sendRemote(.select)
            try await settle(1.0)
            captures.append(try capture(
                window: window,
                outputDirectory: config.outputDirectory,
                name: "18-related-movie-open",
                route: "movie-detail",
                detail: "Movie detail after selecting the focused More Like movie link.",
                tourStartedAt: tourStartedAt
            ))
            dismissDetail()
            try await settle(0.45)
        }

        if let showName = firstShowCandidate(searchQuery: config.searchQuery, appState: appState) {
            let hasSeasonTransitionFixture = hasEpisodeSeasonArtworkFixture(
                showName: showName,
                appState: appState
            )
            openShowDetail(showName)
            try await settle(0.50)
            captures.append(try capture(
                window: window,
                outputDirectory: config.outputDirectory,
                name: "19-show-detail-early",
                route: "show-detail",
                detail: "Early Show detail state for '\(showName)'.",
                tourStartedAt: tourStartedAt
            ))
            try await settle(0.70)
            captures.append(try capture(
                window: window,
                outputDirectory: config.outputDirectory,
                name: "20-show-detail-top",
                route: "show-detail",
                detail: "Show detail opened for '\(showName)'.",
                tourStartedAt: tourStartedAt
            ))
            let episodeFocusEvidenceCount = signals.showEpisodeFocus.count
            NotificationCenter.default.post(name: .marqueeQAVisualTourFocusFirstShowEpisode, object: nil)
            guard await settleUntil(timeout: 2.0, condition: {
                signals.showEpisodeFocus.count > episodeFocusEvidenceCount
            }), let episodeEvidence = signals.showEpisodeFocus.last,
                  episodeEvidence.focusedIndex == 0,
                  episodeEvidence.episodeCount >= 3 else {
                throw HarnessError.assertion(
                    "show detail QA tour did not focus the first episode in a fixture with at least three episodes"
                )
            }
            try await settle(0.55)
            let seasonOneCapture = try capture(
                window: window,
                outputDirectory: config.outputDirectory,
                name: "21-show-detail-episode-list",
                route: "show-detail",
                detail: "Show detail with the first of \(episodeEvidence.episodeCount) Season 1 fixture episodes focused.",
                tourStartedAt: tourStartedAt
            )
            if hasSeasonTransitionFixture {
                try validateEpisodeSeasonCapture(
                    seasonOneCapture,
                    expectedSeason: 1,
                    absentSeason: 2
                )
            }
            captures.append(seasonOneCapture)

            if hasSeasonTransitionFixture {
                let seasonTwoEvidenceCount = signals.showEpisodeFocus.count
                sendRemote(.left)
                try await settle(0.15)
                sendRemote(.right)
                try await settle(0.15)
                sendRemote(.down)
                try await settle(0.55)
                NotificationCenter.default.post(
                    name: .marqueeQAVisualTourProbeShowEpisodeFocus,
                    object: nil
                )
                guard await settleUntil(timeout: 2.0, condition: {
                    signals.showEpisodeFocus.count > seasonTwoEvidenceCount
                }), let seasonTwoEvidence = signals.showEpisodeFocus.last,
                      seasonTwoEvidence.focusedIndex == 0,
                      seasonTwoEvidence.episodeCount == 3 else {
                    throw HarnessError.assertion(
                        "one Down did not focus the first episode in the three-episode Season 2 fixture"
                    )
                }
                try await settle(0.25)
                let seasonTwoCapture = try capture(
                    window: window,
                    outputDirectory: config.outputDirectory,
                    name: "21a-show-detail-season-2-episode-list",
                    route: "show-detail",
                    detail: "One remote season step and one Down must immediately show and focus Season 2 episode 1 without retained Season 1 rows.",
                    tourStartedAt: tourStartedAt
                )
                try validateEpisodeSeasonCapture(
                    seasonTwoCapture,
                    expectedSeason: 2,
                    absentSeason: 1
                )
                captures.append(seasonTwoCapture)

                let seasonOneReturnEvidenceCount = signals.showEpisodeFocus.count
                sendRemote(.left)
                try await settle(0.15)
                sendRemote(.left)
                try await settle(0.15)
                sendRemote(.down)
                try await settle(0.55)
                NotificationCenter.default.post(
                    name: .marqueeQAVisualTourProbeShowEpisodeFocus,
                    object: nil
                )
                guard await settleUntil(timeout: 2.0, condition: {
                    signals.showEpisodeFocus.count > seasonOneReturnEvidenceCount
                }), let seasonOneReturnEvidence = signals.showEpisodeFocus.last,
                      seasonOneReturnEvidence.focusedIndex == 0,
                      seasonOneReturnEvidence.episodeCount == 7 else {
                    throw HarnessError.assertion(
                        "one Down did not restore focus to the first episode in the seven-episode Season 1 fixture"
                    )
                }
                try await settle(0.25)
                let seasonOneReturnCapture = try capture(
                    window: window,
                    outputDirectory: config.outputDirectory,
                    name: "21b-show-detail-season-1-round-trip",
                    route: "show-detail",
                    detail: "The remote Season 2 to Season 1 round trip must immediately restore and focus Season 1 episode 1 without retained Season 2 rows.",
                    tourStartedAt: tourStartedAt
                )
                try validateEpisodeSeasonCapture(
                    seasonOneReturnCapture,
                    expectedSeason: 1,
                    absentSeason: 2
                )
                captures.append(seasonOneReturnCapture)
            }

            NotificationCenter.default.post(name: .marqueeQAVisualTourFocusFirstShowMoreLike, object: nil)
            try await settle(0.70)
            captures.append(try capture(
                window: window,
                outputDirectory: config.outputDirectory,
                name: "22-show-more-like-focus",
                route: "show-detail",
                detail: "Show detail after DEBUG QA focus moved to the first More Like show link.",
                tourStartedAt: tourStartedAt
            ))
            sendRemote(.select)
            try await settle(1.10)
            captures.append(try capture(
                window: window,
                outputDirectory: config.outputDirectory,
                name: "23-related-show-open",
                route: "show-detail",
                detail: "Show detail after selecting the focused More Like show link.",
                tourStartedAt: tourStartedAt
            ))
            dismissDetail()
            try await settle(0.45)
        }

        setRoute(.home)
        await settleUntil(timeout: 7.0) {
            appState.library.browseSnapshot.similarity != nil
        }
        guard appState.library.browseSnapshot.similarity != nil else {
            throw HarnessError.assertion("similarity index did not attach before the post-similarity Home capture")
        }
        let postSimilarityComposition = BrowseCompositionIdentity(snapshot: appState.library.browseSnapshot)
        guard postSimilarityComposition == firstPublishComposition else {
            throw HarnessError.assertion("published hero/Home composition changed when similarity attached")
        }
        try await settle(0.25)
        captures.append(try capture(
            window: window,
            outputDirectory: config.outputDirectory,
            name: "23a-home-post-similarity",
            route: "home",
            detail: "Home after background similarity attachment; hero and row identity/order match 03-home-initial.",
            tourStartedAt: tourStartedAt
        ))

        setRoute(.settings)
        try await settle(0.7)
        captures.append(try capture(
            window: window,
            outputDirectory: config.outputDirectory,
            name: "24-settings",
            route: "settings",
            detail: "Settings route after programmatic route change.",
            tourStartedAt: tourStartedAt
        ))

        let selectedPack = try await probeSoundPackMountAndPersistence(in: window)
        try await settle(0.2)
        captures.append(try capture(
            window: window,
            outputDirectory: config.outputDirectory,
            name: "24a-settings-sound-pack-picker",
            route: "settings",
            detail: "Sound pack picker mounted and focused; DEBUG binding probe persisted \(selectedPack.displayName). Physical remote interaction remains in A3.",
            tourStartedAt: tourStartedAt
        ))

        try assertInstalledVisualFixtureStillPresent(appState)

        return Manifest(
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            buildVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            outputDirectory: config.outputDirectory.path,
            searchQuery: config.searchQuery,
            contentSummary: contentSummary(appState),
            captures: captures,
            budgetProbes: budgetProbes,
            searchRemoteKeyboardSnapshots: [],
            visualFixtureInstalled: !installedFixtureTitles.isEmpty,
            visualFixtureTitles: installedFixtureTitles,
            posterArtworkContract: installedPosterArtworkContract,
            compositionStability: CompositionStabilityEvidence(
                firstPublish: firstPublishComposition,
                postSimilarity: postSimilarityComposition,
                identitiesMatch: true,
                firstCaptureName: "03-home-initial",
                postCaptureName: "23a-home-post-similarity"
            ),
            persistedSoundPack: selectedPack.rawValue,
            nextEpisodeEvidence: nextEpisodeEvidence
        )
    }

    private func verifyNextEpisodeContract(
        searchQuery: String,
        appState: AppState
    ) throws -> NextEpisodeEvidence {
        guard let showName = firstShowCandidate(searchQuery: searchQuery, appState: appState) else {
            throw HarnessError.assertion("Next Episode QA contract could not find a show")
        }
        let episodes = appState.library.episodes(forShow: showName)
        guard episodes.count >= 3,
              let firstEpisode = episodes.first,
              let nextEpisode = PlayerEpisodePlaybackPolicy.nextEpisode(
                  after: firstEpisode,
                  in: episodes
              ),
              let finalEpisode = episodes.last,
              nextEpisode.id != finalEpisode.id,
              PlayerEpisodePlaybackPolicy.nextEpisode(after: finalEpisode, in: episodes) == nil else {
            throw HarnessError.assertion(
                "Next Episode QA contract requires an ordered show fixture with at least three episodes"
            )
        }

        let midSeasonControls = PlayerHUDFocusPolicy.transportControls(
            capabilities: PlayerHUDCapabilities(
                hasSubtitles: false,
                hasMultipleAudioTracks: false,
                hasNextEpisode: true
            )
        )
        let finalEpisodeControls = PlayerHUDFocusPolicy.transportControls(
            capabilities: PlayerHUDCapabilities(
                hasSubtitles: false,
                hasMultipleAudioTracks: false,
                hasNextEpisode: false
            )
        )
        let filmControls = PlayerHUDFocusPolicy.transportControls(
            capabilities: PlayerHUDCapabilities(
                hasSubtitles: false,
                hasMultipleAudioTracks: false
            )
        )
        guard midSeasonControls.contains(.nextEpisode),
              !finalEpisodeControls.contains(.nextEpisode),
              !filmControls.contains(.nextEpisode) else {
            throw HarnessError.assertion(
                "Next Episode HUD control visibility did not match episodic and film availability"
            )
        }

        return NextEpisodeEvidence(
            showName: showName,
            currentEpisode: firstEpisode.episodeLabel,
            nextEpisode: nextEpisode.episodeLabel,
            finalEpisode: finalEpisode.episodeLabel,
            orderedEpisodeCount: episodes.count,
            midSeasonControlVisible: true,
            finalEpisodeControlVisible: false,
            filmControlVisible: false
        )
    }

    private func probeSoundPackMountAndPersistence(
        in window: NSWindow
    ) async throws -> AudioIdentitySoundPack {
        let selectedPack: AudioIdentitySoundPack = UserSettings.shared.soundPack == .hearth
            ? .nocturne
            : .hearth
        window.makeKeyAndOrderFront(nil)

        guard let contentView = window.contentView,
              let scrollView = descendants(of: contentView)
                .compactMap({ $0 as? NSScrollView })
                .max(by: { scrollableHeight($0) < scrollableHeight($1) }),
              scrollableHeight(scrollView) > 0 else {
            throw HarnessError.assertion("Settings did not expose a scrollable native viewport")
        }

        for fraction in [0.30, 0.45, 0.60, 0.75, 0.90] {
            let clipView = scrollView.contentView
            let target = NSPoint(
                x: clipView.bounds.origin.x,
                y: scrollableHeight(scrollView) * fraction
            )
            clipView.setBoundsOrigin(target)
            scrollView.reflectScrolledClipView(clipView)
            NotificationCenter.default.post(
                name: NSView.boundsDidChangeNotification,
                object: clipView
            )
            try await settle(0.10)
            NotificationCenter.default.post(
                name: .marqueeQASelectSoundPack,
                object: selectedPack.rawValue
            )
            try await settle(0.05)
            if UserSettings.shared.soundPack == selectedPack {
                break
            }
        }
        guard UserSettings.shared.soundPack == selectedPack else {
            throw HarnessError.assertion("Sound pack picker did not mount and consume the DEBUG binding command")
        }

        let clipView = scrollView.contentView
        let visiblePickerOffset = min(
            scrollableHeight(scrollView),
            clipView.bounds.origin.y + clipView.bounds.height * 0.28
        )
        clipView.setBoundsOrigin(
            NSPoint(x: clipView.bounds.origin.x, y: visiblePickerOffset)
        )
        scrollView.reflectScrolledClipView(clipView)
        NotificationCenter.default.post(
            name: NSView.boundsDidChangeNotification,
            object: clipView
        )
        try await settle(0.12)

        let settingsURL = Configuration.appSupportDirectory.appendingPathComponent("settings.json")
        let persisted = try JSONDecoder().decode(
            UserSettingsData.self,
            from: Data(contentsOf: settingsURL)
        )
        guard persisted.soundPack == selectedPack.rawValue,
              AudioIdentityPackResolver.resolve(persistedRawValue: persisted.soundPack) == selectedPack else {
            throw HarnessError.assertion("Sound pack binding did not round-trip through settings.json")
        }
        return selectedPack
    }

    private func descendants(of root: NSView) -> [NSView] {
        root.subviews.reduce(into: [root]) { result, child in
            result.append(contentsOf: descendants(of: child))
        }
    }

    private func scrollableHeight(_ scrollView: NSScrollView) -> CGFloat {
        guard let documentView = scrollView.documentView else { return 0 }
        return max(0, documentView.bounds.height - scrollView.contentView.bounds.height)
    }

    private func runSearchRemoteKeyboardOnly(
        config: Config,
        window: NSWindow,
        appState: AppState,
        setRoute: RouteHandler,
        dismissDetail: DetailDismisser
    ) async throws -> Manifest {
        try FileManager.default.createDirectory(
            at: config.outputDirectory,
            withIntermediateDirectories: true
        )

        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        let tourStartedAt = Date()
        SearchRemoteKeyboardTourProbe.shared.reset()
        try await settle(1.0)

        if appState.showProfilePicker {
            guard let profile = appState.profileStore.selectedProfile() ?? appState.profileStore.profiles.first else {
                throw HarnessError.assertion("no profile available for Search remote keyboard QA tour")
            }
            appState.selectProfile(profile)
            try await settle(0.8)
        }
        try await waitForBrowseSurface(appState)

        var captures: [Capture] = []
        let budgetProbes: [BudgetProbe] = []

        setRoute(.search)
        try await waitForSearchRemoteKeyboardMount()
        try await postSearchRemoteCommand(.left, window: window)
        try await settle(0.22)
        let staleFocusSnapshot = try await searchSnapshot(reason: "stale-focus-notification-sidebar-guard")
        try require(
            staleFocusSnapshot.focusOwner == "inactive",
            "Delayed Search focus notification reclaimed ownership after sidebar handoff: \(staleFocusSnapshot)"
        )
        try require(
            !staleFocusSnapshot.fieldFocused,
            "Delayed Search focus notification refocused the text field after sidebar handoff: \(staleFocusSnapshot)"
        )
        try require(
            !staleFocusSnapshot.keyboardVisible,
            "Sidebar handoff left the remote keyboard visible during stale-focus guard: \(staleFocusSnapshot)"
        )
        captures.append(try capture(
            window: window,
            outputDirectory: config.outputDirectory,
            name: "00-search-stale-focus-sidebar-guard",
            route: "search",
            detail: "Search stayed inactive after a delayed field-focus notification while the sidebar owned remote input.",
            tourStartedAt: tourStartedAt
        ))

        setRoute(.search)
        try await settle(0.55)
        let routeSnapshot = try await searchSnapshot(reason: "search-route-open")
        try require(routeSnapshot.focusOwner == "field", "Search route did not start with field ownership: \(routeSnapshot)")
        try require(!routeSnapshot.keyboardVisible, "Search route started with keyboard visible")
        captures.append(try capture(
            window: window,
            outputDirectory: config.outputDirectory,
            name: "01-search-route-field",
            route: "search",
            detail: "Search route opened with field remote ownership and no on-screen keyboard.",
            tourStartedAt: tourStartedAt
        ))

        try await postSearchRemoteCommand(.down, window: window)
        let keyboardSnapshot = try await searchSnapshot(reason: "remote-down-keyboard")
        try require(keyboardSnapshot.focusOwner == "keyboard", "Remote Down did not move Search to keyboard ownership: \(keyboardSnapshot)")
        try require(keyboardSnapshot.keyboardVisible, "Remote Down did not show the on-screen keyboard")
        try require(keyboardSnapshot.focusedKeyID == "char-q", "Remote Down did not focus Q: \(String(describing: keyboardSnapshot.focusedKeyID))")
        captures.append(try capture(
            window: window,
            outputDirectory: config.outputDirectory,
            name: "02-search-remote-keyboard-open",
            route: "search",
            detail: "Remote Down opened the on-screen keyboard and focused Q.",
            tourStartedAt: tourStartedAt
        ))

        try await typeAlienWithRemoteKeyboard(window: window)
        let typedSnapshot = try await searchSnapshot(reason: "remote-typed-alien")
        try require(typedSnapshot.query == "alien", "Remote keyboard did not type alien: \(typedSnapshot.query)")
        try require(typedSnapshot.keyboardVisible, "Keyboard disappeared before Done")
        try require(!typedSnapshot.suggestionsVisible, "Suggestions were visible while remote keyboard owned focus")
        captures.append(try capture(
            window: window,
            outputDirectory: config.outputDirectory,
            name: "03-search-remote-keyboard-typed",
            route: "search",
            detail: "Remote keyboard typed 'alien' with suggestions suppressed.",
            tourStartedAt: tourStartedAt
        ))

        try await settle(0.25)
        try await postSearchRemoteCommand(.down, window: window)
        let doneFocusSnapshot = try await searchSnapshot(reason: "remote-done-focused")
        try require(doneFocusSnapshot.focusedKeyID == "done", "Down from N did not clamp to Done: \(String(describing: doneFocusSnapshot.focusedKeyID))")
        try await postSearchRemoteCommand(.select, window: window)
        try await settle(0.35)
        let resultSnapshot = try await searchSnapshot(reason: "remote-done-results")
        try require(resultSnapshot.focusOwner == "results", "Done did not move to results: \(resultSnapshot)")
        try require(resultSnapshot.resultFocus != nil, "Done did not focus a visible result")
        try require(resultSnapshot.firstVisibleResultAvailable, "Done reached results without a visible result")
        captures.append(try capture(
            window: window,
            outputDirectory: config.outputDirectory,
            name: "04-search-remote-result-focus",
            route: "search",
            detail: "Done hid the keyboard and focused the first visible Search result.",
            tourStartedAt: tourStartedAt
        ))

        try await postSearchRemoteCommand(.select, window: window)
        try await settle(0.85)
        let detailOpenSnapshot = try await searchSnapshot(reason: "remote-result-detail-opened")
        try require(detailOpenSnapshot.detailPresented, "Remote Select did not present a detail surface: \(detailOpenSnapshot)")
        captures.append(try capture(
            window: window,
            outputDirectory: config.outputDirectory,
            name: "05-search-remote-detail-open",
            route: "search-detail",
            detail: "Remote Select on the focused Search result opened its detail surface.",
            tourStartedAt: tourStartedAt
        ))

        dismissDetail()
        try await settle(0.55)
        let returnSnapshot = try await searchSnapshot(reason: "detail-return-result-restored")
        try require(!returnSnapshot.detailPresented, "Detail dismiss did not clear detail presentation: \(returnSnapshot)")
        try require(returnSnapshot.focusOwner == "results", "Detail return did not restore result ownership: \(returnSnapshot)")
        try require(returnSnapshot.resultFocus != nil, "Detail return did not restore a result focus")
        captures.append(try capture(
            window: window,
            outputDirectory: config.outputDirectory,
            name: "06-search-remote-detail-return",
            route: "search",
            detail: "Detail dismiss restored the prior Search result focus.",
            tourStartedAt: tourStartedAt
        ))

        try await postSearchRemoteCommand(.left, window: window)
        try await settle(0.35)
        let fieldSnapshot = try await searchSnapshot(reason: "result-left-field-handoff")
        try require(fieldSnapshot.focusOwner == "field", "Left from leading result did not return to the Search field: \(fieldSnapshot)")
        try require(!fieldSnapshot.keyboardVisible, "Result-to-field handoff unexpectedly reopened the keyboard")
        try await postSearchRemoteCommand(.left, window: window)
        try await settle(0.35)
        let sidebarSnapshot = try await searchSnapshot(reason: "result-left-sidebar-handoff")
        try require(sidebarSnapshot.focusOwner == "inactive", "Left from the Search field did not release Search ownership: \(sidebarSnapshot)")
        try require(!sidebarSnapshot.keyboardVisible, "Sidebar handoff left the keyboard visible")
        try await postRemoteCommandWhileSearchInactive(.down, window: window)
        let sidebarOwnershipSnapshot = try await searchSnapshot(reason: "sidebar-down-search-inactive")
        try require(
            sidebarOwnershipSnapshot.focusOwner == "inactive",
            "Sidebar-owned Down returned ownership to Search: \(sidebarOwnershipSnapshot)"
        )
        captures.append(try capture(
            window: window,
            outputDirectory: config.outputDirectory,
            name: "07-search-sidebar-handoff",
            route: "search",
            detail: "Left from the leading Search result returned to the field; a second Left released Search input, and sidebar-owned Down did not reenter Search.",
            tourStartedAt: tourStartedAt
        ))

        setRoute(.search)
        try await settle(0.35)
        try await postSearchRemoteCommand(.select, window: window)
        let reopenedKeyboardSnapshot = try await searchSnapshot(reason: "remote-keyboard-reopened")
        try require(reopenedKeyboardSnapshot.focusedKeyID == "char-q", "Field Select did not reopen the remote keyboard at Q: \(String(describing: reopenedKeyboardSnapshot.focusedKeyID))")
        try await typePhysicalSearchText("matrix", window: window)
        try await settle(0.25)
        let physicalSnapshot = try await searchSnapshot(reason: "physical-typing-after-keyboard")
        let expectedPhysicalQuery = "\(reopenedKeyboardSnapshot.query)matrix"
        try require(physicalSnapshot.query == expectedPhysicalQuery, "Physical text simulation did not update query: \(physicalSnapshot.query)")
        try require(physicalSnapshot.focusOwner == "field", "Physical text simulation did not return ownership to field: \(physicalSnapshot)")
        try require(!physicalSnapshot.keyboardVisible, "Physical text simulation left remote keyboard visible")
        captures.append(try capture(
            window: window,
            outputDirectory: config.outputDirectory,
            name: "08-search-physical-typing",
            route: "search",
            detail: "Physical text entry appends through real key events after reopening the remote keyboard from field Select and returns focus to the field.",
            tourStartedAt: tourStartedAt
        ))

        guard let suggestionProbeQuery = firstSuggestionProbeQuery(appState: appState) else {
            throw HarnessError.assertion("No suggestion-bearing Search query was available for dropdown focus QA")
        }
        SearchInputBuffer.shared.seedForVisualQA(suggestionProbeQuery)
        NotificationCenter.default.post(name: .marqueeFocusSearchField, object: nil)
        try await settle(0.35)
        let seededSuggestionSnapshot = try await searchSnapshot(reason: "physical-seeded-suggestions")
        try require(
            seededSuggestionSnapshot.query == suggestionProbeQuery,
            "Seeded suggestion query did not reach Search: \(seededSuggestionSnapshot)"
        )
        try require(seededSuggestionSnapshot.suggestionsVisible, "Seeded query did not show suggestions: \(seededSuggestionSnapshot)")
        try await postSearchRemoteCommand(.down, window: window)
        let suggestionFocusSnapshot = try await searchSnapshot(reason: "remote-suggestion-focus")
        try require(suggestionFocusSnapshot.focusOwner == "suggestions", "Remote Down did not move into suggestions: \(suggestionFocusSnapshot)")
        try require(suggestionFocusSnapshot.suggestionFocus == 0, "Remote suggestion focus did not start at the first suggestion: \(suggestionFocusSnapshot)")
        captures.append(try capture(
            window: window,
            outputDirectory: config.outputDirectory,
            name: "09-search-suggestion-focus",
            route: "search",
            detail: "Remote Down moved from a physical search query into the visible suggestion dropdown.",
            tourStartedAt: tourStartedAt
        ))

        try await postSearchRemoteCommand(.select, window: window)
        try await settle(0.35)
        let suggestionResultSnapshot = try await searchSnapshot(reason: "remote-suggestion-select-results")
        try require(suggestionResultSnapshot.focusOwner == "results", "Remote Select on suggestion did not move to results: \(suggestionResultSnapshot)")
        try require(suggestionResultSnapshot.resultFocus != nil, "Suggestion selection did not focus a visible result: \(suggestionResultSnapshot)")
        try require(!suggestionResultSnapshot.suggestionsVisible, "Suggestion selection left dropdown visible: \(suggestionResultSnapshot)")
        captures.append(try capture(
            window: window,
            outputDirectory: config.outputDirectory,
            name: "10-search-suggestion-select-results",
            route: "search",
            detail: "Remote Select applied the focused suggestion and focused the resulting title cards.",
            tourStartedAt: tourStartedAt
        ))

        try assertInstalledVisualFixtureStillPresent(appState)

        return Manifest(
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            buildVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            outputDirectory: config.outputDirectory.path,
            searchQuery: "alien",
            contentSummary: contentSummary(appState),
            captures: captures,
            budgetProbes: budgetProbes,
            searchRemoteKeyboardSnapshots: SearchRemoteKeyboardTourProbe.shared.snapshots,
            visualFixtureInstalled: !installedFixtureTitles.isEmpty,
            visualFixtureTitles: installedFixtureTitles,
            posterArtworkContract: installedPosterArtworkContract
        )
    }

    private func installVisualTourFixtureIfNeeded(
        _ appState: AppState,
        outputDirectory: URL
    ) throws {
        let qaLibraryRoot = Configuration.appSupportDirectory
            .appendingPathComponent("visual-qa-library", isDirectory: true)
        let qaMoviesRoot = qaLibraryRoot.appendingPathComponent("Movies", isDirectory: true)
        let qaTVRoot = qaLibraryRoot.appendingPathComponent("TV", isDirectory: true)
        try FileManager.default.createDirectory(
            at: qaMoviesRoot,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: qaTVRoot,
            withIntermediateDirectories: true
        )
        appState.userSettings.moviesPaths = [qaMoviesRoot.path]
        appState.userSettings.tvShowsPaths = [qaTVRoot.path]

        guard !browseSurfaceHasContent(appState) else { return }
        let posterPathsByTitle = try VisualQAPosterArtworkFixture.writeArtwork(to: outputDirectory)
        let episodeStillPathsByEpisode = try VisualQAEpisodeSeasonArtworkFixture.writeArtwork(
            to: outputDirectory
        )
        let movies = Self.visualTourMovies(posterPathsByTitle: posterPathsByTitle)
        let episodes = Self.visualTourEpisodes(
            episodeStillPathsByEpisode: episodeStillPathsByEpisode
        )
        appState.library.debugSeedLibraryForVisualQATour(
            movies: movies,
            tvEpisodes: episodes
        )
        installedFixtureTitles = VisualQAPosterArtworkFixture.specifications.map(\.title)
            + [episodes.first?.showName].compactMap { $0 }
        installedPosterArtworkContract = VisualQAPosterArtworkFixture.captureContract
    }

    private func assertInstalledVisualFixtureStillPresent(_ appState: AppState) throws {
        guard !installedFixtureTitles.isEmpty else { return }
        let movieTitles = appState.library.filteredLibraryItems.map(\.displayTitle)
        let showNames = appState.library.browseSnapshot.showSummaries.map(\.showName)
        let episodeShowNames = appState.library.filteredTVItems.compactMap(\.showName)
        let availableTitles = Set(movieTitles + showNames + episodeShowNames)
        for title in installedFixtureTitles {
            guard availableTitles.contains(title) else {
                throw HarnessError.assertion("visual fixture title disappeared before QA completion: \(title)")
            }
        }
    }

    private static func visualTourMovies(
        posterPathsByTitle: [String: String] = [:]
    ) -> [MediaItem] {
        let now = Date()
        let specs: [(String, Int, [String], String, String, [String])] = [
            (
                "Alien Horizon",
                1979,
                ["Action", "Science Fiction", "Horror"],
                "A salvage crew finds a silent signal at the edge of settled space.",
                "Ridley Carter",
                ["Sigourney Vale", "Tom Skerritt"]
            ),
            (
                "Alien Signal",
                1986,
                ["Science Fiction", "Action"],
                "A rescue team follows a colony beacon into a nest of old machines.",
                "James Vale",
                ["Sigourney Vale", "Michael Biehn"]
            ),
            (
                "Starlight Drift",
                2014,
                ["Adventure", "Science Fiction"],
                "Explorers cross a collapsing corridor to bring their crew home.",
                "Ava Jensen",
                ["Mira Stone", "Cole Reyes"]
            ),
            (
                "Midnight Orchard",
                2020,
                ["Drama", "Mystery"],
                "A family reunion turns strange when the town's harvest lights return.",
                "Nia Cross",
                ["June Park", "Lena Ortiz"]
            ),
            (
                "Neon Rails",
                2018,
                ["Thriller", "Crime"],
                "A courier follows a stolen archive through the city's last night train.",
                "Marco Lin",
                ["Iris Chen", "Theo Ward"]
            ),
            (
                "Ocean of Glass",
                2009,
                ["Adventure", "Drama"],
                "A diver maps a flooded observatory before a storm seals the coast.",
                "Nia Cross",
                ["June Park", "Ari Bell"]
            ),
            (
                "Signal Below",
                2023,
                ["Science Fiction", "Mystery"],
                "A research station hears an alien code rising from under the ice.",
                "Ava Jensen",
                ["Mira Stone", "Iris Chen"]
            ),
            (
                "The Last Lantern",
                2016,
                ["Fantasy", "Adventure"],
                "A keeper carries one impossible light across a city without dawn.",
                "Eli Hart",
                ["Cole Reyes", "Ari Bell"]
            )
        ]

        return specs.enumerated().map { index, spec in
            makeVisualTourMovie(
                title: spec.0,
                year: spec.1,
                genres: spec.2,
                overview: spec.3,
                director: spec.4,
                castNames: spec.5,
                dateAdded: now.addingTimeInterval(TimeInterval(-index * 86_400)),
                posterImagePath: posterPathsByTitle[spec.0]
            )
        }
    }

    private static func visualTourEpisodes(
        episodeStillPathsByEpisode: [VisualQAEpisodeSeasonArtworkFixture.Key: String]
    ) -> [MediaItem] {
        let now = Date().addingTimeInterval(-720_000)
        let shows: [(String, [String], String, [String])] = [
            (
                "Alien Frontier",
                ["Science Fiction", "Adventure"],
                "A survey ship maps first contact on a border moon.",
                ["Mira Stone", "Theo Ward"]
            ),
            (
                "Signal City",
                ["Mystery", "Thriller"],
                "Detectives trace a broadcast that changes every listener.",
                ["Iris Chen", "Lena Ortiz"]
            ),
            (
                "Harbor Lights",
                ["Drama", "Adventure"],
                "A coastal crew rebuilds their town around a lost lighthouse.",
                ["June Park", "Cole Reyes"]
            )
        ]

        return shows.enumerated().flatMap { showIndex, show in
            let seasonEpisodeCounts = showIndex == 0
                ? [(season: 1, count: 7), (season: 2, count: 3)]
                : [(season: 1, count: 3)]
            return seasonEpisodeCounts.flatMap { fixtureSeason in
                (1...fixtureSeason.count).map { episode in
                    makeVisualTourEpisode(
                        showName: show.0,
                        title: "\(show.0) S\(fixtureSeason.season)E\(episode)",
                        season: fixtureSeason.season,
                        episode: episode,
                        genres: show.1,
                        overview: show.2,
                        castNames: show.3,
                        dateAdded: now.addingTimeInterval(
                            TimeInterval(
                                -(showIndex * 20 + fixtureSeason.season * 10 + episode) * 43_200
                            )
                        ),
                        localEpisodeStillPath: showIndex == 0
                            ? episodeStillPathsByEpisode[
                                VisualQAEpisodeSeasonArtworkFixture.Key(
                                    season: fixtureSeason.season,
                                    episode: episode
                                )
                            ]
                            : nil
                    )
                }
            }
        }
    }

    private static func makeVisualTourMovie(
        title: String,
        year: Int,
        genres: [String],
        overview: String,
        director: String,
        castNames: [String],
        dateAdded: Date,
        posterImagePath: String?
    ) -> MediaItem {
        MediaItem(
            filePath: "/tmp/marquee-visual-tour/movies/\(title).mkv",
            fileName: "\(title).mkv",
            title: title,
            year: year,
            fileExtension: "mkv",
            fileSize: 1_024,
            duration: 7_200,
            localGenres: genres,
            dateAdded: dateAdded,
            metadata: visualTourMetadata(
                title: title,
                overview: overview,
                genres: genres,
                director: director,
                castNames: castNames,
                runtime: 120,
                certification: title == "The Last Lantern" ? "G" : "PG-13"
            ),
            posterImagePath: posterImagePath
        )
    }

    private static func makeVisualTourEpisode(
        showName: String,
        title: String,
        season: Int,
        episode: Int,
        genres: [String],
        overview: String,
        castNames: [String],
        dateAdded: Date,
        localEpisodeStillPath: String? = nil
    ) -> MediaItem {
        MediaItem(
            filePath: "/tmp/marquee-visual-tour/tv/\(showName)/S\(season)E\(episode).mkv",
            fileName: "S\(season)E\(episode).mkv",
            title: title,
            year: 2024,
            fileExtension: "mkv",
            fileSize: 1_024,
            duration: 3_600,
            localGenres: genres,
            dateAdded: dateAdded,
            showName: showName,
            seasonNumber: season,
            episodeNumber: episode,
            episodeTitle: title,
            metadata: visualTourMetadata(
                title: showName,
                overview: overview,
                genres: genres,
                director: nil,
                castNames: castNames,
                runtime: 60,
                certification: showName == "Harbor Lights" ? "TV-G" : "TV-14"
            ),
            localEpisodeStillPath: localEpisodeStillPath
        )
    }

    private static func visualTourMetadata(
        title: String,
        overview: String,
        genres: [String],
        director: String?,
        castNames: [String],
        runtime: Int,
        certification: String
    ) -> TMDBMetadata {
        let stableID = visualTourStableID(for: title)
        return TMDBMetadata(
            tmdbID: stableID,
            overview: overview,
            genres: genres,
            cast: castNames.enumerated().map { index, name in
                TMDBMetadata.CastEntry(
                    name: name,
                    character: index == 0 ? "Lead" : "Supporting",
                    profilePath: nil,
                    tmdbPersonID: stableID + index + 1
                )
            },
            director: director,
            certification: certification,
            voteAverage: 7.8,
            voteCount: 1_200,
            keywords: genres.enumerated().map { index, genre in
                TMDBMetadata.Keyword(id: stableID + 100 + index, name: genre)
            },
            posterPath: nil,
            backdropPath: nil,
            releaseDate: nil,
            runtime: runtime
        )
    }

    private static func visualTourStableID(for title: String) -> Int {
        let folded = title.unicodeScalars.reduce(0) { partial, scalar in
            ((partial &* 31) &+ Int(scalar.value)) % 900_000
        }
        return folded + 10_000
    }

    private func waitForBrowseSurface(_ appState: AppState) async throws {
        for _ in 0..<60 {
            if !appState.showProfilePicker, browseSurfaceHasContent(appState) {
                return
            }
            try await settle(0.2)
        }
        throw HarnessError.assertion(
            "browse content did not become ready before QA capture: picker=\(appState.showProfilePicker) scanning=\(appState.library.isScanning) \(contentSummary(appState)) filteredMovies=\(appState.library.filteredLibraryItems.count) filteredTV=\(appState.library.filteredTVItems.count)"
        )
    }

    private func browseSurfaceHasContent(_ appState: AppState) -> Bool {
        !appState.library.filteredLibraryItems.isEmpty
            || !appState.library.filteredTVItems.isEmpty
            || !appState.library.browseSnapshot.homeRows.isEmpty
            || !appState.library.browseSnapshot.movieRows.isEmpty
            || !appState.library.browseSnapshot.showRows.isEmpty
            || !appState.library.browseSnapshot.showSummaries.isEmpty
    }

    private func capture(
        window: NSWindow,
        outputDirectory: URL,
        name: String,
        route: String,
        detail: String,
        tourStartedAt: Date,
        capturesWindowPresentation: Bool = false
    ) throws -> Capture {
        let captureStartedAt = Date()
        guard let contentView = window.contentView else {
            throw HarnessError.assertion("window has no content view for \(name)")
        }

        if !capturesWindowPresentation {
            contentView.layoutSubtreeIfNeeded()
            contentView.displayIfNeeded()
        }

        let bounds = contentView.bounds
        guard bounds.width >= 100, bounds.height >= 100 else {
            throw HarnessError.assertion("capture bounds too small for \(name): \(bounds)")
        }

        let bitmap: NSBitmapImageRep
        if capturesWindowPresentation {
            guard let image = CGWindowListCreateImage(
                .null,
                .optionIncludingWindow,
                CGWindowID(window.windowNumber),
                [.boundsIgnoreFraming]
            ) else {
                throw HarnessError.assertion("could not capture window presentation for \(name)")
            }
            bitmap = NSBitmapImageRep(cgImage: image)
        } else {
            guard let viewBitmap = contentView.bitmapImageRepForCachingDisplay(in: bounds) else {
                throw HarnessError.assertion("could not allocate bitmap for \(name)")
            }
            contentView.cacheDisplay(in: bounds, to: viewBitmap)
            bitmap = viewBitmap
        }
        try validateCaptureBitmap(bitmap, name: name)
        if name.contains("return-placement") {
            try validateReturnPlacementBitmap(bitmap, name: name)
        }

        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw HarnessError.assertion("could not encode PNG for \(name)")
        }
        guard data.count > 10_000 else {
            throw HarnessError.assertion("PNG for \(name) is too small to trust: \(data.count) bytes")
        }

        let fileName = "\(name).png"
        let url = outputDirectory.appendingPathComponent(fileName)
        try data.write(to: url, options: .atomic)

        return Capture(
            name: name,
            file: url.path,
            route: route,
            detail: detail,
            width: bitmap.pixelsWide,
            height: bitmap.pixelsHigh,
            bytes: data.count,
            elapsedMS: milliseconds(from: tourStartedAt, to: captureStartedAt),
            captureMS: milliseconds(from: captureStartedAt, to: Date())
        )
    }

    private func validateEpisodeSeasonCapture(
        _ capture: Capture,
        expectedSeason: Int,
        absentSeason: Int
    ) throws {
        let url = URL(fileURLWithPath: capture.file)
        guard let bitmap = NSBitmapImageRep(data: try Data(contentsOf: url)) else {
            throw HarnessError.assertion(
                "could not decode episode-season capture \(capture.name)"
            )
        }
        let counts = VisualQAEpisodeSeasonArtworkFixture.markerPixelCounts(in: bitmap)
        let requiredKeys = (1...3).map {
            VisualQAEpisodeSeasonArtworkFixture.Key(season: expectedSeason, episode: $0)
        }
        // Focus chrome color processing shifts most pixels in the selected
        // thumbnail; the measured first-row floor is still well above noise.
        let missingKeys = requiredKeys.filter { counts[$0, default: 0] < 150 }
        let absentCount = VisualQAEpisodeSeasonArtworkFixture.markers
            .filter { $0.key.season == absentSeason }
            .reduce(into: 0) { total, marker in
                total += counts[marker.key, default: 0]
            }
        let focusRingCount = VisualQAEpisodeSeasonArtworkFixture.focusRingPixelCount(
            in: bitmap,
            firstEpisodeKey: requiredKeys[0]
        )
        guard missingKeys.isEmpty, absentCount <= 40, focusRingCount >= 1_000 else {
            let requiredCounts = requiredKeys
                .map { "\($0)=\(counts[$0, default: 0])" }
                .joined(separator: ",")
            throw HarnessError.assertion(
                "episode-season capture \(capture.name) has stale or missing rendered rows: "
                    + "required=[\(requiredCounts)] "
                    + "season\(absentSeason)Pixels=\(absentCount) "
                    + "firstEpisodeFocusPixels=\(focusRingCount)"
            )
        }
    }

    private func meanLuminanceDifference(
        firstFile: String,
        secondFile: String
    ) throws -> Double {
        guard let first = NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: firstFile))),
              let second = NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: secondFile))),
              first.pixelsWide == second.pixelsWide,
              first.pixelsHigh == second.pixelsHigh else {
            throw HarnessError.assertion("profile exit captures could not be compared at matching dimensions")
        }

        let xStride = max(1, first.pixelsWide / 100)
        let yStride = max(1, first.pixelsHigh / 100)
        var totalDifference = 0.0
        var sampleCount = 0
        for y in stride(from: 0, to: first.pixelsHigh, by: yStride) {
            for x in stride(from: 0, to: first.pixelsWide, by: xStride) {
                guard let firstColor = first.colorAt(x: x, y: y),
                      let secondColor = second.colorAt(x: x, y: y) else {
                    continue
                }
                let firstLuminance = 0.2126 * Double(firstColor.redComponent)
                    + 0.7152 * Double(firstColor.greenComponent)
                    + 0.0722 * Double(firstColor.blueComponent)
                let secondLuminance = 0.2126 * Double(secondColor.redComponent)
                    + 0.7152 * Double(secondColor.greenComponent)
                    + 0.0722 * Double(secondColor.blueComponent)
                totalDifference += abs(firstLuminance - secondLuminance)
                sampleCount += 1
            }
        }
        guard sampleCount > 0 else {
            throw HarnessError.assertion("profile exit captures produced no comparable pixels")
        }
        return totalDifference / Double(sampleCount)
    }

    private func validateCaptureBitmap(_ bitmap: NSBitmapImageRep, name: String) throws {
        let width = bitmap.pixelsWide
        let height = bitmap.pixelsHigh
        let xStride = max(1, width / 80)
        let yStride = max(1, height / 80)
        var sampled = 0
        var lit = 0
        var minLuminance = 1.0
        var maxLuminance = 0.0

        for y in stride(from: 0, to: height, by: yStride) {
            for x in stride(from: 0, to: width, by: xStride) {
                guard let color = bitmap.colorAt(x: x, y: y) else { continue }
                sampled += 1
                let alpha = Double(color.alphaComponent)
                guard alpha > 0.05 else { continue }
                let luminance = 0.2126 * Double(color.redComponent)
                    + 0.7152 * Double(color.greenComponent)
                    + 0.0722 * Double(color.blueComponent)
                minLuminance = min(minLuminance, luminance)
                maxLuminance = max(maxLuminance, luminance)
                if luminance > 0.08 {
                    lit += 1
                }
            }
        }

        guard sampled > 0 else {
            throw HarnessError.assertion("capture \(name) sampled no pixels")
        }
        let litRatio = Double(lit) / Double(sampled)
        let contrast = maxLuminance - minLuminance
        guard litRatio >= 0.005, contrast >= 0.02 else {
            throw HarnessError.assertion(
                "capture \(name) appears blank or partial: litRatio=\(litRatio) contrast=\(contrast)"
            )
        }
    }

    private func validateReturnPlacementBitmap(_ bitmap: NSBitmapImageRep, name: String) throws {
        let width = bitmap.pixelsWide
        let height = bitmap.pixelsHigh
        let focusedCardXRange: Range<Int>
        if name.contains("-tv-") {
            focusedCardXRange = max(0, Int(Double(width) * 0.07))..<min(width, Int(Double(width) * 0.19))
        } else {
            focusedCardXRange = max(0, Int(Double(width) * 0.18))..<min(width, Int(Double(width) * 0.30))
        }
        let focusedCardYRange = max(0, Int(Double(height) * 0.34))..<min(height, Int(Double(height) * 0.76))
        let xStride = max(1, width / 320)
        let yStride = max(1, height / 180)
        var sampled = 0
        var contentPixels = 0
        var focusPixels = 0
        var nearWhitePixels = 0

        for y in stride(from: focusedCardYRange.lowerBound, to: focusedCardYRange.upperBound, by: yStride) {
            for x in stride(from: focusedCardXRange.lowerBound, to: focusedCardXRange.upperBound, by: xStride) {
                guard let color = bitmap.colorAt(x: x, y: y) else { continue }
                sampled += 1
                let red = Double(color.redComponent)
                let green = Double(color.greenComponent)
                let blue = Double(color.blueComponent)
                let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
                if luminance > 0.10 {
                    contentPixels += 1
                }
                if luminance > 0.18,
                   blue > green + 0.06,
                   blue > red + 0.04,
                   red > green {
                    focusPixels += 1
                }
                if luminance > 0.62,
                   abs(red - green) < 0.12,
                   abs(green - blue) < 0.12 {
                    nearWhitePixels += 1
                }
            }
        }

        guard sampled > 0 else {
            throw HarnessError.assertion("return capture \(name) sampled no content pixels")
        }
        let contentRatio = Double(contentPixels) / Double(sampled)
        guard contentRatio >= 0.12,
              focusPixels >= 12,
              nearWhitePixels >= 8 else {
            throw HarnessError.assertion(
                "return capture \(name) lacks expected focused-card geometry: contentRatio=\(contentRatio) focusPixels=\(focusPixels) nearWhitePixels=\(nearWhitePixels)"
            )
        }
    }

    private func recordLayoutBudgetProbe(
        window: NSWindow,
        name: String,
        route: String,
        detail: String,
        actionStartedAt: Date,
        actionCompletedAt: Date? = nil,
        targetMS: Double,
        budgetProbes: inout [BudgetProbe]
    ) throws {
        let beforeLayout = Date()
        let layoutMS = try measureLayoutDisplayCost(window: window, name: name)
        let observedMS = milliseconds(
            from: actionStartedAt,
            to: actionCompletedAt ?? beforeLayout
        )
        let totalMS = observedMS + layoutMS
        budgetProbes.append(BudgetProbe(
            name: name,
            route: route,
            targetMS: targetMS,
            observedMS: observedMS,
            withinTarget: totalMS <= targetMS,
            captureFile: nil,
            layoutMS: layoutMS,
            totalMS: totalMS,
            detail: detail
        ))
    }

    private func measureLayoutDisplayCost(window: NSWindow, name: String) throws -> Double {
        guard let contentView = window.contentView else {
            throw HarnessError.assertion("window has no content view for \(name)")
        }
        let layoutStartedAt = Date()
        contentView.layoutSubtreeIfNeeded()
        contentView.displayIfNeeded()
        return milliseconds(from: layoutStartedAt, to: Date())
    }

    private static func configuration() throws -> Config {
        let outputPath = argument(after: "--qa-output-dir")
            ?? ProcessInfo.processInfo.environment["MARQUEE_QA_OUTPUT_DIR"]
            ?? defaultOutputDirectory()
        let trimmedOutput = outputPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedOutput.isEmpty else {
            throw HarnessError.assertion("--qa-output-dir was empty")
        }

        let query = argument(after: "--qa-search-query")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Config(
            outputDirectory: URL(fileURLWithPath: expandedPath(trimmedOutput)),
            searchQuery: query?.isEmpty == false ? query! : "alien"
        )
    }

    private static func argument(after flag: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: flag) else { return nil }
        let valueIndex = arguments.index(after: index)
        guard arguments.indices.contains(valueIndex) else { return nil }
        return arguments[valueIndex]
    }

    private static func defaultOutputDirectory() -> String {
        let stamp = ISO8601DateFormatter()
            .string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("marquee-native-visual-tour-\(stamp)")
            .path
    }

    private static func expandedPath(_ path: String) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == "~" {
            return home
        }
        return home + String(path.dropFirst())
    }

    private func write(manifest: Manifest, to outputDirectory: URL) throws -> URL {
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        let url = outputDirectory.appendingPathComponent("manifest.json")
        try data.write(to: url, options: .atomic)
        return url
    }

    private func settle(_ seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func completedProfileSelectionDate(
        profileID: UUID,
        startedAt: Date,
        appState: AppState,
        signals: QASurfaceSignals
    ) -> Date? {
        guard let profileEvidence = appState.profileSession.debugSelectionCompletionEvidence,
              profileEvidence.profileID == profileID,
              profileEvidence.completedAt >= startedAt,
              let currentFirstRow = appState.library.browseSnapshot.homeRows.first,
              let interactiveEvidence = signals.homeRowsInteractive.first(where: {
                  $0.profileID == profileID
                      && $0.selectionCompletedAt == profileEvidence.completedAt
                      && $0.rowID == currentFirstRow.id
                      && $0.itemIDs == currentFirstRow.items.map(\.id)
                      && $0.rowCount > 0
                      && $0.itemCount > 0
                      && $0.completedAt >= startedAt
              }) else {
            return nil
        }
        return max(profileEvidence.completedAt, interactiveEvidence.completedAt)
    }

    private func yieldMainQueueTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }

    /// Polls a completion condition every ~16ms so budget probes measure
    /// the real action-to-usable latency instead of a fixed settle that
    /// gets counted against the target (NATIVE-P1-007). The return value makes
    /// event absence explicit so callers cannot accidentally record a false
    /// success after a timeout.
    @discardableResult
    private func settleUntil(
        timeout: TimeInterval,
        condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 16_000_000)
        }
        return condition()
    }

    private func requireCurrentReturnEvidence(
        route: BrowseSurfaceRoute,
        signals: QASurfaceSignals
    ) async throws -> BrowseReturnPlacementEvidence {
        await settleUntil(timeout: 2.0) {
            signals.returnPlacements.contains(where: { $0.route == route })
        }
        guard let evidence = signals.returnPlacements.last(where: { $0.route == route }),
              evidence.isCorrectlyPlaced else {
            throw HarnessError.assertion("missing direct return-placement evidence for \(route)")
        }
        return evidence
    }

    private func verifyManualPlayerDismissal(
        route: BrowseSurfaceRoute,
        baseline: BrowseReturnPlacementEvidence,
        appState: AppState,
        signals: QASurfaceSignals
    ) async throws {
        let placementCount = signals.returnPlacements.filter { $0.route == route }.count
        appState.playerController.isPlayerPresented = true
        await settleUntil(timeout: 1.0) {
            signals.presentationStates.last(where: { $0.route == route })?.playerVisible == true
        }
        guard signals.presentationStates.last(where: { $0.route == route })?.playerVisible == true else {
            throw HarnessError.assertion("\(route) did not observe live player presentation")
        }

        appState.playerController.isPlayerPresented = false
        await settleUntil(timeout: 2.0) {
            signals.returnPlacements.filter { $0.route == route }.count > placementCount
        }
        try assertLatestReturnEvidence(
            route: route,
            baseline: baseline,
            signals: signals,
            context: "manual player dismissal"
        )
    }

    private func verifyEndedPlaybackDismissal(
        route: BrowseSurfaceRoute,
        baseline: BrowseReturnPlacementEvidence,
        appState: AppState,
        signals: QASurfaceSignals
    ) async throws {
        guard appState.library.filteredLibraryItems.count >= 2 else {
            throw HarnessError.assertion("player-ended return proof requires two fixture movies")
        }
        let handoff = PostPlayHandoff(
            source: appState.library.filteredLibraryItems[0],
            candidate: appState.library.filteredLibraryItems[1]
        )
        let placementCount = signals.returnPlacements.filter { $0.route == route }.count

        appState.playerController.isPlayerPresented = true
        await settleUntil(timeout: 1.0) {
            signals.presentationStates.last(where: { $0.route == route })?.playerVisible == true
        }
        appState.postPlayHandoff = handoff
        await settleUntil(timeout: 1.0) {
            signals.presentationStates.last(where: { $0.route == route })?.postPlayID == handoff.id
        }
        appState.playerController.isPlayerPresented = false
        await settleUntil(timeout: 1.0) {
            guard let state = signals.presentationStates.last(where: { $0.route == route }) else {
                return false
            }
            return !state.playerVisible && state.postPlayID == handoff.id
        }
        guard signals.returnPlacements.filter({ $0.route == route }).count == placementCount else {
            throw HarnessError.assertion("\(route) placed before the post-play blocker dismissed")
        }

        appState.postPlayHandoff = nil
        await settleUntil(timeout: 2.0) {
            signals.returnPlacements.filter { $0.route == route }.count > placementCount
        }
        try assertLatestReturnEvidence(
            route: route,
            baseline: baseline,
            signals: signals,
            context: "post-play final dismissal"
        )
    }

    private func assertLatestReturnEvidence(
        route: BrowseSurfaceRoute,
        baseline: BrowseReturnPlacementEvidence,
        signals: QASurfaceSignals,
        context: String
    ) throws {
        guard let latest = signals.returnPlacements.last(where: { $0.route == route }),
              latest.focusID == baseline.focusID,
              latest.rowTitle == baseline.rowTitle,
              latest.isCorrectlyPlaced else {
            throw HarnessError.assertion(
                "\(route) \(context) changed focus identity/title or missed the reading band"
            )
        }
    }

    /// Records the DEBUG surface-appeared and search-publication signals
    /// posted by route/detail views so `settleUntil` conditions can wait on
    /// real SwiftUI mounts instead of wall-clock guesses.
    @MainActor
    private final class QASurfaceSignals {
        private(set) var routeAppearances: [String: Date] = [:]
        private(set) var detailsAppeared: [String] = []
        private(set) var searchPublications: [QASearchPublicationEvidence] = []
        private(set) var presentationStates: [BrowseSurfacePresentationState] = []
        private(set) var returnPlacements: [BrowseReturnPlacementEvidence] = []
        private(set) var homeRowsInteractive: [QAHomeRowsInteractiveEvidence] = []
        private(set) var showEpisodeFocus: [QAShowEpisodeFocusEvidence] = []
        private var observers: [NSObjectProtocol] = []

        init() {
            observers.append(NotificationCenter.default.addObserver(
                forName: .marqueeQARouteSurfaceAppeared, object: nil, queue: .main
            ) { [weak self] note in
                guard let route = note.object as? String else { return }
                let appearedAt = Date()
                Task { @MainActor [weak self] in
                    self?.routeAppearances[route] = appearedAt
                }
            })
            observers.append(NotificationCenter.default.addObserver(
                forName: .marqueeQADetailSurfaceAppeared, object: nil, queue: .main
            ) { [weak self] note in
                guard let kind = note.object as? String else { return }
                Task { @MainActor [weak self] in
                    self?.detailsAppeared.append(kind)
                }
            })
            observers.append(NotificationCenter.default.addObserver(
                forName: .marqueeQASearchResultsPublished, object: nil, queue: .main
            ) { [weak self] note in
                guard let evidence = note.object as? QASearchPublicationEvidence else { return }
                Task { @MainActor [weak self] in
                    self?.searchPublications.append(evidence)
                }
            })
            observers.append(NotificationCenter.default.addObserver(
                forName: .marqueeQABrowsePresentationObserved, object: nil, queue: .main
            ) { [weak self] note in
                guard let state = note.object as? BrowseSurfacePresentationState else { return }
                Task { @MainActor [weak self] in
                    self?.presentationStates.append(state)
                }
            })
            observers.append(NotificationCenter.default.addObserver(
                forName: .marqueeQABrowseReturnPlaced, object: nil, queue: .main
            ) { [weak self] note in
                guard let evidence = note.object as? BrowseReturnPlacementEvidence else { return }
                Task { @MainActor [weak self] in
                    self?.returnPlacements.append(evidence)
                }
            })
            observers.append(NotificationCenter.default.addObserver(
                forName: .marqueeQAHomeRowsInteractive, object: nil, queue: .main
            ) { [weak self] note in
                guard let evidence = note.object as? QAHomeRowsInteractiveEvidence else { return }
                Task { @MainActor [weak self] in
                    self?.homeRowsInteractive.append(evidence)
                }
            })
            observers.append(NotificationCenter.default.addObserver(
                forName: .marqueeQAVisualTourShowEpisodeFocused, object: nil, queue: .main
            ) { [weak self] note in
                guard let evidence = note.object as? QAShowEpisodeFocusEvidence else { return }
                Task { @MainActor [weak self] in
                    self?.showEpisodeFocus.append(evidence)
                }
            })
        }

        func reset() {
            routeAppearances.removeAll()
            detailsAppeared.removeAll()
            searchPublications.removeAll()
            presentationStates.removeAll()
            returnPlacements.removeAll()
            homeRowsInteractive.removeAll()
            showEpisodeFocus.removeAll()
        }

        deinit {
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }

    private func typeAlienWithRemoteKeyboard(window: NSWindow) async throws {
        let commands: [RemoteCommand] = [
            .down, .select,
            .right, .right, .right, .right, .right, .right, .right, .right, .select,
            .up, .left, .select,
            .left, .left, .left, .left, .left, .select,
            .down, .down, .right, .right, .right, .select
        ]
        for command in commands {
            try await postSearchRemoteCommand(command, window: window)
        }
    }

    private func postSearchRemoteCommand(_ command: RemoteCommand, window: NSWindow) async throws {
        let previousSnapshotCount = SearchRemoteKeyboardTourProbe.shared.snapshots.count
        let expectedReason = "remote-\(command)"
        try sendSearchRemoteKeyEvent(command, window: window)

        for _ in 0..<10 {
            try await settle(0.05)
            let snapshots = SearchRemoteKeyboardTourProbe.shared.snapshots
            guard snapshots.count > previousSnapshotCount else { continue }
            guard let snapshot = snapshots.last else { break }
            guard snapshot.reason == expectedReason else {
                throw HarnessError.assertion("Search remote command \(command) produced stale or unrelated snapshot \(snapshot.reason)")
            }
            guard snapshot.consumedCommand == true else {
                throw HarnessError.assertion("Search did not consume remote command \(command): \(snapshot)")
            }
            return
        }

        let latest = SearchRemoteKeyboardTourProbe.shared.latest
        throw HarnessError.assertion(
            "Search did not publish a fresh \(expectedReason) snapshot; previousCount=\(previousSnapshotCount) latest=\(String(describing: latest))"
        )
    }

    private func postRemoteCommandWhileSearchInactive(_ command: RemoteCommand, window: NSWindow) async throws {
        let previousSnapshotCount = SearchRemoteKeyboardTourProbe.shared.snapshots.count
        try sendSearchRemoteKeyEvent(command, window: window)
        try await settle(0.12)

        let snapshots = SearchRemoteKeyboardTourProbe.shared.snapshots
        guard snapshots.count > previousSnapshotCount,
              let snapshot = snapshots.last,
              snapshot.reason == "remote-\(command)" else {
            return
        }

        guard snapshot.consumedCommand != true else {
            throw HarnessError.assertion("Search consumed sidebar-owned remote command \(command): \(snapshot)")
        }
    }

    private func typePhysicalSearchText(_ text: String, window: NSWindow) async throws {
        for character in text {
            try sendKeyDown(
                window: window,
                keyCode: 0,
                characters: String(character),
                charactersIgnoringModifiers: String(character)
            )
            try await settle(0.03)
        }
    }

    private func sendSearchRemoteKeyEvent(_ command: RemoteCommand, window: NSWindow) throws {
        let spec = try SearchRemoteKeyEventSpec(command: command)
        try sendKeyDown(
            window: window,
            keyCode: spec.keyCode,
            characters: spec.characters,
            charactersIgnoringModifiers: spec.charactersIgnoringModifiers
        )
    }

    private func sendKeyDown(
        window: NSWindow,
        keyCode: UInt16,
        characters: String,
        charactersIgnoringModifiers: String
    ) throws {
        window.makeKeyAndOrderFront(nil)
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            isARepeat: false,
            keyCode: keyCode
        ) else {
            throw HarnessError.assertion("Could not synthesize keyDown for keyCode \(keyCode)")
        }
        NSApp.sendEvent(event)
    }

    private func searchSnapshot(reason: String) async throws -> SearchRemoteKeyboardProbeSnapshot {
        NotificationCenter.default.post(name: .marqueeQASearchStateProbe, object: reason)
        try await settle(0.05)
        guard let snapshot = SearchRemoteKeyboardTourProbe.shared.latest else {
            throw HarnessError.assertion("Search did not publish QA snapshot for \(reason)")
        }
        return snapshot
    }

    private func waitForSearchRemoteKeyboardMount() async throws {
        let reason = "search-route-mounted-for-sidebar-guard"
        for _ in 0..<40 {
            let previousSnapshotCount = SearchRemoteKeyboardTourProbe.shared.snapshots.count
            NotificationCenter.default.post(name: .marqueeQASearchStateProbe, object: reason)
            try await settle(0.05)
            let snapshots = SearchRemoteKeyboardTourProbe.shared.snapshots
            guard snapshots.count > previousSnapshotCount,
                  let snapshot = snapshots.last,
                  snapshot.reason == reason,
                  snapshot.keyMonitorInstalled,
                  snapshot.focusOwner == "field" else {
                continue
            }
            return
        }
        throw HarnessError.assertion("Search route did not mount its remote keyboard monitor with field ownership")
    }

    private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else {
            throw HarnessError.assertion(message)
        }
    }

    private func contentSummary(_ appState: AppState) -> String {
        "hero=\(appState.library.browseSnapshot.heroSpotlights.count) homeRows=\(appState.library.browseSnapshot.homeRows.count) movieRows=\(appState.library.browseSnapshot.movieRows.count) showRows=\(appState.library.browseSnapshot.showRows.count)"
    }

    private func milliseconds(from start: Date, to end: Date) -> Double {
        ((end.timeIntervalSince(start) * 1_000) * 10).rounded() / 10
    }

    private func firstMovieCandidate(searchQuery: String, appState: AppState) -> MediaItem? {
        let results = appState.library.browseSnapshot.searchIndex.search(searchQuery)
        if let movie = results.movies.first?.item {
            return movie
        }
        return appState.library.filteredLibraryItems.first
    }

    private func firstShowCandidate(searchQuery: String, appState: AppState) -> String? {
        let results = appState.library.browseSnapshot.searchIndex.search(searchQuery)
        if let showName = results.shows.first?.showName {
            return showName
        }
        return appState.library.browseSnapshot.showSummaries.first?.showName
    }

    private func hasEpisodeSeasonArtworkFixture(
        showName: String,
        appState: AppState
    ) -> Bool {
        let episodes = appState.library.filteredTVItems.filter { $0.showName == showName }
        return VisualQAEpisodeSeasonArtworkFixture.markers.allSatisfy { marker in
            episodes.contains { episode in
                episode.seasonNumber == marker.key.season
                    && episode.episodeNumber == marker.key.episode
                    && episode.localEpisodeStillPath?.hasSuffix(marker.fileName) == true
            }
        }
    }

    private func firstSuggestionProbeQuery(appState: AppState) -> String? {
        let index = appState.library.browseSnapshot.searchIndex
        var candidates: [String] = []
        var seen: Set<String> = []

        func appendCandidate(_ query: String) {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 2, seen.insert(trimmed).inserted else { return }
            candidates.append(trimmed)
        }

        func appendValue(_ value: String?) {
            guard let value else { return }
            let normalized = BrowseSemanticPolicy.normalizedText(value)
            guard normalized.count >= 2 else { return }

            for token in BrowseSemanticPolicy.tokens(inNormalizedText: normalized) where token.count >= 2 {
                appendCandidate(String(token.prefix(min(3, token.count))))
                if token.count > 3 {
                    appendCandidate(String(token.prefix(min(5, token.count))))
                }
                appendCandidate(token)
            }
            appendCandidate(normalized)
        }

        for movie in appState.library.filteredLibraryItems {
            appendValue(movie.displayTitle)
            movie.displayGenres.forEach { appendValue($0) }
            appendValue(movie.metadata?.director)
            movie.metadata?.cast.forEach { appendValue($0.name) }
        }

        for summary in appState.library.browseSnapshot.showSummaries {
            appendValue(summary.showName)
            summary.genres.forEach { appendValue($0) }
            appendValue(summary.representative.metadata?.director)
            summary.representative.metadata?.cast.forEach { appendValue($0.name) }
        }

        return candidates.first { !index.suggestions(for: $0).isEmpty }
    }

    private static func writeStderr(_ message: String) {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }

    private func writeStderr(_ message: String) {
        Self.writeStderr(message)
    }

    private struct Config {
        let outputDirectory: URL
        let searchQuery: String
    }

    private struct SearchRemoteKeyEventSpec {
        let keyCode: UInt16
        let characters: String
        let charactersIgnoringModifiers: String

        init(command: RemoteCommand) throws {
            switch command {
            case .up:
                keyCode = 126
                characters = "\u{F700}"
                charactersIgnoringModifiers = "\u{F700}"
            case .down:
                keyCode = 125
                characters = "\u{F701}"
                charactersIgnoringModifiers = "\u{F701}"
            case .left:
                keyCode = 123
                characters = "\u{F702}"
                charactersIgnoringModifiers = "\u{F702}"
            case .right:
                keyCode = 124
                characters = "\u{F703}"
                charactersIgnoringModifiers = "\u{F703}"
            case .select:
                keyCode = 36
                characters = "\r"
                charactersIgnoringModifiers = "\r"
            case .back:
                keyCode = 53
                characters = "\u{1B}"
                charactersIgnoringModifiers = "\u{1B}"
            }
        }
    }

    private struct Manifest: Codable {
        let generatedAt: String
        let appVersion: String
        let buildVersion: String
        let osVersion: String
        let outputDirectory: String
        let searchQuery: String
        let contentSummary: String
        let captures: [Capture]
        let budgetProbes: [BudgetProbe]
        let searchRemoteKeyboardSnapshots: [SearchRemoteKeyboardProbeSnapshot]
        let visualFixtureInstalled: Bool
        let visualFixtureTitles: [String]
        let posterArtworkContract: VisualQAPosterArtworkFixture.CaptureContract?
        var compositionStability: CompositionStabilityEvidence? = nil
        var persistedSoundPack: String? = nil
        var nextEpisodeEvidence: NextEpisodeEvidence? = nil
    }

    private struct NextEpisodeEvidence: Codable {
        let showName: String
        let currentEpisode: String
        let nextEpisode: String
        let finalEpisode: String
        let orderedEpisodeCount: Int
        let midSeasonControlVisible: Bool
        let finalEpisodeControlVisible: Bool
        let filmControlVisible: Bool
    }

    private struct CompositionStabilityEvidence: Codable {
        let firstPublish: BrowseCompositionIdentity
        let postSimilarity: BrowseCompositionIdentity
        let identitiesMatch: Bool
        let firstCaptureName: String
        let postCaptureName: String
    }

    private struct Capture: Codable {
        let name: String
        let file: String
        let route: String
        let detail: String
        let width: Int
        let height: Int
        let bytes: Int
        let elapsedMS: Double
        let captureMS: Double
    }

    private struct BudgetProbe: Codable {
        let name: String
        let route: String
        let targetMS: Double
        let observedMS: Double
        let withinTarget: Bool
        let captureFile: String?
        let layoutMS: Double?
        let totalMS: Double?
        let detail: String
    }

    private enum HarnessError: Error, CustomStringConvertible {
        case assertion(String)

        var description: String {
            switch self {
            case .assertion(let message): return message
            }
        }
    }
}

#endif
