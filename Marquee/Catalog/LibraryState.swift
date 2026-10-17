import SwiftUI

// MARK: - Library State

final class LibraryState: ObservableObject {

    @Published var libraryItems: [MediaItem] = []
    @Published var tvItems: [MediaItem] = []
    @Published var isScanning: Bool = false
    @Published private(set) var browseSnapshot: BrowseSnapshot = .empty
    @Published private(set) var scanStatusText: String?
    @Published private(set) var hasQueuedScan: Bool = false

    private(set) var filteredLibraryItems: [MediaItem] = []
    private(set) var filteredTVItems: [MediaItem] = []
    private var snapshotSourceMovieIdentity: [ObjectIdentifier] = []
    private var snapshotSourceTVIdentity: [ObjectIdentifier] = []

    private(set) var catalogStore: (any CatalogStore)?
    private(set) var watchStore: WatchProgressStore?

    private let currentProfile: () -> UserProfile?
    private let isProfilePickerVisible: () -> Bool
    private let userSettings = UserSettings.shared
    private var scanGate = ScanRequestGate()
    // Phase 2E.2: lazy because `SystemVolumeRegistry.init` is async and
    // `LibraryState.init` is sync. Built on first catalog-population call
    // from inside the `scanLibrary` Task.
    private var volumeRegistry: (any VolumeRegistry)?
    private var watchStateAppliedPaths = Set<String>()
    private var hasRequestedInitialScan = false
    private var hasRestoredProjectedLibraryCache = false
    private var currentScanAllowsOnlineMetadata = false
    private var queuedScanAllowsOnlineMetadata = false
    private var homeArtworkPreheatGeneration = 0
    private var similarityIndexGeneration = 0
    private let similarityIndexLaunchDelay: TimeInterval = 4.0
    #if DEBUG
    var debugSimilarityIndexBuilderForHarness: ((BrowseSimilarityIndex.PreparedInput) -> BrowseSimilarityIndex)?
    var debugSimilarityIndexEventHandlerForHarness: ((SimilarityIndexDebugEvent) -> Void)?
    var debugSimilarityIndexComputeDelayForHarness: TimeInterval?
    private var debugVisualQAFixtureSuppressesScans = false
    private var debugScanInvalidationGeneration = 0
    #endif
    private lazy var directoryWatcher = DirectoryWatcher { [weak self] in
        self?.scanLibrary()
    }

    init(
        currentProfile: @escaping () -> UserProfile?,
        isProfilePickerVisible: @escaping () -> Bool,
        openPersistentStore: Bool = true,
        restoreProjectedCache: Bool = true
    ) {
        self.currentProfile = currentProfile
        self.isProfilePickerVisible = isProfilePickerVisible
        if openPersistentStore {
            do {
                catalogStore = try SQLiteCatalogStore(path: SQLiteCatalogStore.defaultPath)
            } catch {
                print("[Marquee] Catalog store failed to open: \(error)")
            }
        }
        if restoreProjectedCache {
            restoreProjectedLibraryCache()
        }
    }

    #if DEBUG
    convenience init(
        currentProfile: @escaping () -> UserProfile?,
        isProfilePickerVisible: @escaping () -> Bool,
        skipPersistenceForHarness: Bool
    ) {
        self.init(
            currentProfile: currentProfile,
            isProfilePickerVisible: isProfilePickerVisible,
            openPersistentStore: !skipPersistenceForHarness,
            restoreProjectedCache: !skipPersistenceForHarness
        )
    }
    #endif

    func setWatchStore(_ store: WatchProgressStore?) {
        watchStore = store
    }

    var moviesPaths: [String] {
        userSettings.moviesPaths
    }

    var tvShowsPaths: [String] {
        userSettings.tvShowsPaths
    }

    private func restoreProjectedLibraryCache() {
        guard let restored = ProjectedLibraryCache.load() else {
            MarqueeLogger.scanner.info("projected library cache unavailable")
            return
        }

        libraryItems = restored.movies
        tvItems = restored.tvEpisodes
        hasRestoredProjectedLibraryCache = true
        recomputeFilteredItems()
        MarqueeLogger.scanner.info(
            "projected library cache restored source=\(restored.source, privacy: .public) movies=\(restored.movies.count, privacy: .public) tv=\(restored.tvEpisodes.count, privacy: .public)"
        )
    }

    // MARK: - Phase 2E.2: Catalog Population

    /// Lazily constructs the production `SystemVolumeRegistry` on
    /// first use. Called from inside the `scanLibrary` Task so the
    /// async init does not block LibraryState's synchronous init at app
    /// launch.
    private func ensureVolumeRegistry() async -> any VolumeRegistry {
        if let existing = volumeRegistry { return existing }
        let fresh = await SystemVolumeRegistry()
        volumeRegistry = fresh
        return fresh
    }

    /// Populates the SQLite catalog at the configured app support
    /// data root by running `DiffScanner` over `rootPath`. This is a durable
    /// write path — it inserts scan jobs, scan events, and media-file
    /// rows, and deletes media-file rows whose backing files vanished
    /// since the last scan. As of 2E.4d the catalog is the only source
    /// of truth for the UI; the legacy `MediaScannerService` and
    /// `LibraryCache` JSON have been retired.
    ///
    /// Errors are logged via `MarqueeLogger.scanner` and swallowed so
    /// a catalog write failure does not break the scan loop.
    private func populateCatalogScan(rootPath: String, role: String) async {
        guard let store = catalogStore else { return }
        let volumes = await ensureVolumeRegistry()

        let diffScanner = DiffScanner(catalog: store, volumes: volumes)
        do {
            // Per `DiffScanner.scan`'s contract, in-flight failures
            // land in `job.state` (`.failed` / `.cancelled`) rather
            // than as a thrown error. Branch on the state so a job
            // that recorded a failure is logged at error level — not
            // misreported as a successful scan with zeroed counters.
            let job = try await diffScanner.scan(rootPath: rootPath)
            switch job.state {
            case .completed:
                MarqueeLogger.scanner.info(
                    "catalog populate \(role, privacy: .public) state=completed observed=\(job.filesObserved) added=\(job.filesAdded) updated=\(job.filesUpdated) removed=\(job.filesRemoved)"
                )
            case .failed, .cancelled, .queued, .running:
                MarqueeLogger.scanner.error(
                    "catalog populate \(role, privacy: .public) state=\(job.state.rawValue, privacy: .public) observed=\(job.filesObserved) added=\(job.filesAdded) updated=\(job.filesUpdated) removed=\(job.filesRemoved) lastError=\(job.lastErrorMessage ?? "<none>", privacy: .public)"
                )
            }
        } catch {
            MarqueeLogger.scanner.error(
                "catalog populate \(role, privacy: .public) threw before job completion: \(String(describing: error), privacy: .public)"
            )
        }
    }

    // MARK: - Phase 2E.4c: TMDB Enrichment

    /// Run one `DurationProbe.probeMissing()` pass over the catalog.
    /// Sits between `populateCatalogScan` and `enrichCatalogPostPopulate`
    /// so the projection picks up `durationSeconds` at the same time as
    /// TMDB metadata. Plugs the parity gap left by `DiffScanner` (which
    /// inserts new `media_file` rows with `durationSeconds = nil`) now
    /// that `MediaScannerService.loadDuration` is no longer in the
    /// scan path. Per-file failures stay nil and retry next pass.
    private func runDurationProbe() async {
        guard let store = catalogStore else { return }
        let probe = DurationProbe(catalog: store)
        do {
            let summary = try await probe.probeMissing()
            MarqueeLogger.scanner.info(
                "duration probe: probed=\(summary.probed, privacy: .public) skipped=\(summary.skipped, privacy: .public) failed=\(summary.failed, privacy: .public)"
            )
        } catch {
            MarqueeLogger.scanner.error(
                "duration probe threw: \(String(describing: error), privacy: .public)"
            )
        }
    }

    private func enrichCatalogPostPopulate(allowOnlineMetadata: Bool) async {
        guard let store = catalogStore else { return }
        guard allowOnlineMetadata, UserSettings.shared.onlineMetadataEnabled else {
            MarqueeLogger.network.info(
                "Skipping catalog TMDB enrichment; online metadata is disabled or scan is local-only"
            )
            return
        }
        let service = TMDBEnrichmentService(catalog: store)
        do {
            let summary = try await service.enrichMissing()
            MarqueeLogger.network.info(
                "catalog enrichment pass: movies=\(summary.moviesEnriched, privacy: .public) shows=\(summary.showsEnriched, privacy: .public) seasons=\(summary.seasonsEnriched, privacy: .public) episodes=\(summary.episodesEnriched, privacy: .public) skipped=\(summary.skipped, privacy: .public) failed=\(summary.failed, privacy: .public)"
            )
        } catch {
            MarqueeLogger.network.error(
                "catalog enrichment pass threw: \(String(describing: error), privacy: .public)"
            )
        }
    }

    // MARK: - Phase 2E.4a: Catalog-Authoritative Projection

    /// Hydrate `libraryItems` / `tvItems` at scan start from the
    /// catalog projection. The catalog has been authoritative since
    /// 2E.4a; the legacy `LibraryCache` JSON fallback was retired in
    /// 2E.4d (d.2). On cold start (no catalog rows yet) the UI shows
    /// empty until populate + probe + enrich + project finishes.
    private func hydrateFromCatalog(moviesRoots: [String], tvRoots: [String]) async {
        guard let store = catalogStore else { return }
        let volumes = await ensureVolumeRegistry()
        let roots = moviesRoots + tvRoots
        let projection = DefaultCatalogProjection(
            catalog: store,
            volumes: volumes,
            libraryRoots: roots
        )
        let projected: (movies: [MediaItem], tv: [MediaItem])?
        do {
            let items = try await projection.projectMediaItems()
            if items.isEmpty {
                projected = nil
            } else {
                let bucketed = self.bucketByRoot(items, moviesRoots: moviesRoots, tvRoots: tvRoots)
                projected = bucketed
                MarqueeLogger.scanner.info(
                    "catalog hydrate: items=\(items.count, privacy: .public) movies=\(bucketed.movies.count, privacy: .public) tv=\(bucketed.tv.count, privacy: .public)"
                )
            }
        } catch {
            MarqueeLogger.scanner.error(
                "catalog hydrate threw: \(String(describing: error), privacy: .public)"
            )
            projected = nil
        }

        guard let p = projected else { return }
        await MainActor.run {
            #if DEBUG
            guard self.debugScanIsCurrentForPublish() else { return }
            #endif
            self.libraryItems = p.movies
            self.tvItems = p.tv
            self.applyWatchProgress()
            self.recomputeFilteredItems()
        }
    }

    /// Phase 2E.4d final-assign step. After every library root has
    /// populated the catalog and `DurationProbe` + `TMDBEnrichmentService`
    /// have filled in the gaps, re-project from the catalog and bucket
    /// by library-root prefix to preserve the movies/tv split.
    ///
    /// 2E.4d retired the in-process scanner; the catalog is the only
    /// source of truth. On projection error there is no fallback — the
    /// caller keeps the hydrated state from `hydrateFromCatalog`, which
    /// is the most recent good projection.
    private func projectFromCatalog(moviesRoots: [String], tvRoots: [String]) async -> (movies: [MediaItem], tv: [MediaItem])? {
        guard let store = catalogStore else { return nil }
        let volumes = await ensureVolumeRegistry()
        let roots = moviesRoots + tvRoots
        let projection = DefaultCatalogProjection(
            catalog: store,
            volumes: volumes,
            libraryRoots: roots
        )
        do {
            let projected = try await projection.projectMediaItems()
            let bucketed = self.bucketByRoot(projected, moviesRoots: moviesRoots, tvRoots: tvRoots)
            #if DEBUG
            let shouldPublish = await MainActor.run { self.debugScanIsCurrentForPublish() }
            guard shouldPublish else { return nil }
            #endif
            ProjectedLibraryCache.save(movies: bucketed.movies, tvEpisodes: bucketed.tv)
            MarqueeLogger.scanner.info(
                "catalog projected final: movies=\(bucketed.movies.count, privacy: .public) tv=\(bucketed.tv.count, privacy: .public)"
            )
            return bucketed
        } catch {
            MarqueeLogger.scanner.error(
                "catalog projection final threw: \(String(describing: error), privacy: .public)"
            )
            return nil
        }
    }

    /// Splits a flat projection list into movies vs TV by checking
    /// each item's `filePath` against the configured library roots.
    /// When a path matches roots in both lists (rare overlap), the
    /// deeper-prefix root wins — TV takes priority on a tie because
    /// the typical overlap pattern is a movies root that contains a
    /// nested TV folder, not the reverse. Items not under any root
    /// are dropped (already filtered by `matchingLibraryRoot` inside
    /// the projection, but the check is repeated here defensively).
    private func bucketByRoot(_ items: [MediaItem], moviesRoots: [String], tvRoots: [String]) -> (movies: [MediaItem], tv: [MediaItem]) {
        var movies: [MediaItem] = []
        var tv: [MediaItem] = []
        for item in items {
            let path = item.filePath
            let movieMatch = deepestRootLength(path: path, roots: moviesRoots)
            let tvMatch = deepestRootLength(path: path, roots: tvRoots)
            if tvMatch >= movieMatch && tvMatch > 0 {
                tv.append(item)
            } else if movieMatch > 0 {
                movies.append(item)
            }
        }
        return (movies, tv)
    }

    private func deepestRootLength(path: String, roots: [String]) -> Int {
        var best = 0
        for root in roots {
            if path == root || path.hasPrefix(root + "/") {
                if root.count > best { best = root.count }
            }
        }
        return best
    }

    func scanLibrary(allowOnlineMetadata: Bool = false) {
        #if DEBUG
        guard !debugVisualQAFixtureSuppressesScans else {
            MarqueeLogger.scanner.info("scan request ignored while visual QA fixture is installed")
            return
        }
        #endif
        let shouldAllowOnlineMetadata = allowOnlineMetadata && userSettings.onlineMetadataEnabled
        switch scanGate.request() {
        case .start:
            #if DEBUG
            debugScanInvalidationGeneration += 1
            let debugGeneration = debugScanInvalidationGeneration
            #endif
            currentScanAllowsOnlineMetadata = shouldAllowOnlineMetadata
            queuedScanAllowsOnlineMetadata = false
            isScanning = true
            hasQueuedScan = false
            scanStatusText = shouldAllowOnlineMetadata
                ? "Refreshing library and metadata..."
                : "Updating library index..."
            Task { [weak self] in
                #if DEBUG
                await self?.runCatalogScanLoop(debugGeneration: debugGeneration)
                #else
                await self?.runCatalogScanLoop()
                #endif
            }
        case .queued:
            queuedScanAllowsOnlineMetadata = queuedScanAllowsOnlineMetadata || shouldAllowOnlineMetadata
            hasQueuedScan = true
            scanStatusText = "Finishing current scan, then checking updates..."
            MarqueeLogger.scanner.info("scan request queued while scan is active")
        }
    }

    func beginBackgroundScanIfNeeded() {
        guard !hasRequestedInitialScan else { return }
        hasRequestedInitialScan = true

        if hasRestoredProjectedLibraryCache && (!libraryItems.isEmpty || !tvItems.isEmpty) {
            startWatchingLibraryPaths()
            MarqueeLogger.scanner.info("initial scan skipped; restored projected library cache is available")
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, !self.isProfilePickerVisible() else { return }
            self.scanLibrary(allowOnlineMetadata: false)
        }
    }

    private func runCatalogScanLoop(debugGeneration: Int? = nil) async {
        while true {
            #if DEBUG
            let shouldContinue = await MainActor.run {
                self.debugScanIsCurrentForPublish(debugGeneration: debugGeneration)
            }
            guard shouldContinue else { break }
            #endif
            let allowsOnlineMetadata = await MainActor.run {
                self.currentScanAllowsOnlineMetadata
            }
            await runCatalogScanPass(
                allowOnlineMetadata: allowsOnlineMetadata,
                debugGeneration: debugGeneration
            )

            let completion = await MainActor.run { () -> ScanCompletionDecision in
                #if DEBUG
                guard self.debugScanIsCurrentForPublish(debugGeneration: debugGeneration) else { return .idle }
                #endif
                let decision = self.scanGate.finishPass()
                switch decision {
                case .runAgain:
                    self.currentScanAllowsOnlineMetadata = self.queuedScanAllowsOnlineMetadata
                    self.queuedScanAllowsOnlineMetadata = false
                    self.hasQueuedScan = false
                    self.scanStatusText = self.currentScanAllowsOnlineMetadata
                        ? "Refreshing library and metadata..."
                        : "Checking library updates..."
                    MarqueeLogger.scanner.info("running queued follow-up scan")
                case .idle:
                    self.currentScanAllowsOnlineMetadata = false
                    self.queuedScanAllowsOnlineMetadata = false
                    self.isScanning = false
                    self.hasQueuedScan = false
                    self.scanStatusText = nil
                }
                return decision
            }

            if completion == .idle {
                break
            }
        }
    }

    private func runCatalogScanPass(allowOnlineMetadata: Bool, debugGeneration: Int? = nil) async {
        // Snapshot library roots on the main actor once per scan.
        // UserSettings' path arrays are mutated on the main thread
        // (Settings UI); reading them from this background Task would
        // race the arrays' copy-on-write storage.
        let (moviesRoots, tvRoots) = await MainActor.run {
            (self.moviesPaths, self.tvShowsPaths)
        }

        // Paint the most recent catalog projection immediately so
        // the UI is not empty during populate + probe + enrich.
        await self.hydrateFromCatalog(moviesRoots: moviesRoots, tvRoots: tvRoots)
        #if DEBUG
        guard await MainActor.run(body: { self.debugScanIsCurrentForPublish(debugGeneration: debugGeneration) }) else {
            return
        }
        #endif

        let fm = FileManager.default

        // Phase 2E.4d: catalog-only flow. DiffScanner is the only
        // file walker; MediaScannerService and LibraryCache are
        // gone. For each configured root that exists on disk,
        // populate the catalog. DurationProbe + TMDBEnrichmentService
        // run once across the whole catalog after every root has
        // been populated.
        for moviesPath in moviesRoots {
            if fm.fileExists(atPath: moviesPath) {
                await self.populateCatalogScan(rootPath: moviesPath, role: "movies")
            }
        }
        for tvPath in tvRoots {
            if fm.fileExists(atPath: tvPath) {
                await self.populateCatalogScan(rootPath: tvPath, role: "tv")
            }
        }

        // DurationProbe disabled at startup. AVURLAsset.load(.duration)
        // on hundreds of mkvs spawns CoreMedia/AudioToolbox objects
        // (AVFigAssetInspectorLoader, FigCustomURLHandling, etc.)
        // that thrash the same heap libmpv uses. On Broadwell + macOS
        // 12 this caused mid-playback aborts (~2s in) with no .ips
        // because the libmpv worker died first. Duration is cosmetic
        // (runtime label) and is filled by mpv on playback. If a
        // backfill pass is needed later, run it idle — never during
        // scanLibrary.
        // await self.runDurationProbe()

        #if DEBUG
        guard await MainActor.run(body: { self.debugScanIsCurrentForPublish(debugGeneration: debugGeneration) }) else {
            return
        }
        #endif

        // TMDB enrichment: gated on `onlineMetadataEnabled`. Per-item
        // failures land in the summary and get logged; never throws.
        await self.enrichCatalogPostPopulate(allowOnlineMetadata: allowOnlineMetadata)

        let projected = await self.projectFromCatalog(moviesRoots: moviesRoots, tvRoots: tvRoots)

        await MainActor.run {
            #if DEBUG
            guard self.debugScanIsCurrentForPublish(debugGeneration: debugGeneration) else { return }
            #endif
            if let p = projected {
                self.libraryItems = p.movies
                self.tvItems = p.tv
                self.applyWatchProgress()
                self.recomputeFilteredItems()
            }

            // TODO: stopgap — pre-cache artwork from external drives
            ArtworkCache.shared.populateCache(
                movieItems: self.libraryItems,
                tvItems: self.tvItems
            )

            self.startWatchingLibraryPaths()
        }
    }

    // MARK: - Directory Watch

    func startWatchingLibraryPaths() {
        directoryWatcher.watch(paths: moviesPaths + tvShowsPaths)
    }

    func stopWatchingLibraryPaths() {
        directoryWatcher.stop()
    }

    // MARK: - Watch Progress

    func applyWatchProgress() {
        var itemByPath: [String: MediaItem] = [:]
        itemByPath.reserveCapacity(libraryItems.count + tvItems.count)
        for item in libraryItems {
            itemByPath[item.filePath] = item
        }
        for item in tvItems {
            itemByPath[item.filePath] = item
        }

        for path in watchStateAppliedPaths {
            guard let item = itemByPath[path] else { continue }
            item.playbackPosition = 0
            item.lastPlayedDate = nil
            item.isWatched = false
        }
        watchStateAppliedPaths.removeAll()

        guard let store = watchStore else {
            return
        }

        for entry in store.allActiveEntries() {
            guard let item = itemByPath[entry.filePath] else { continue }
            item.playbackPosition = entry.position
            item.lastPlayedDate = entry.lastPlayed
            item.isWatched = false
            watchStateAppliedPaths.insert(entry.filePath)
        }

        for entry in store.allCompletedEntries() {
            guard let item = itemByPath[entry.filePath] else { continue }
            item.playbackPosition = 0
            item.lastPlayedDate = entry.lastPlayed
            item.isWatched = true
            watchStateAppliedPaths.insert(entry.filePath)
        }
    }

    func applyWatchProgressForItem(at path: String) {
        guard let store = watchStore else { return }
        guard let item = (libraryItems + tvItems).first(where: { $0.filePath == path }) else { return }

        if let entry = store.progress(for: path) {
            item.playbackPosition = entry.position
            item.lastPlayedDate = entry.lastPlayed
            item.isWatched = false
            watchStateAppliedPaths.insert(path)
        } else if let completed = store.completedProgress(for: path) {
            item.playbackPosition = 0
            item.lastPlayedDate = completed.lastPlayed
            item.isWatched = true
            watchStateAppliedPaths.insert(path)
        } else {
            item.playbackPosition = 0
            item.lastPlayedDate = nil
            item.isWatched = false
            watchStateAppliedPaths.remove(path)
        }
        recomputeProgressRows()
    }

    private func currentTasteProfile() -> BrowseTasteProfile? {
        guard let completedFilePaths = watchStore?.completedTitleFilePaths(),
              !completedFilePaths.isEmpty else { return nil }
        return BrowseTasteProfile(completedFilePaths: completedFilePaths)
    }

    // MARK: - Profile Filtering

    func recomputeFilteredItems() {
        let signpostID = MarqueeSignpost.begin("recompute-filtered")
        defer { MarqueeSignpost.end("recompute-filtered", signpostID) }
        if let profile = currentProfile() {
            filteredLibraryItems = libraryItems.filter { profile.allows(item: $0) }
            filteredTVItems = tvItems.filter { profile.allows(item: $0) }
        } else {
            filteredLibraryItems = libraryItems
            filteredTVItems = tvItems
        }
        invalidateTVCache()

        // When the filtered sets contain the exact same item instances the
        // current snapshot was built from (adult profile select over the
        // init-restored library, watch-history clears), a full rebuild only
        // recreates identical rows. Refresh the progress-sensitive surfaces
        // instead; any instance replacement (scan reprojection, enrichment)
        // changes identity and takes the full rebuild path.
        let movieIdentity = filteredLibraryItems.map(ObjectIdentifier.init)
        let tvIdentity = filteredTVItems.map(ObjectIdentifier.init)
        if movieIdentity == snapshotSourceMovieIdentity, tvIdentity == snapshotSourceTVIdentity {
            let needsSimilarityIndex = browseSnapshot.similarity == nil
            browseSnapshot = BrowseSnapshotBuilder.refreshProgressRows(
                movies: filteredLibraryItems,
                tvEpisodes: filteredTVItems,
                existing: browseSnapshot,
                tasteProfile: currentTasteProfile()
            )
            if needsSimilarityIndex {
                scheduleSimilarityIndexCompute(
                    movieIdentity: movieIdentity,
                    tvIdentity: tvIdentity
                )
            }
            return
        }

        // Maturity filtering yields a subset of the same instances the
        // current snapshot indexed; reuse its per-movie search tokenization
        // instead of re-normalizing the whole library.
        let previousMovieIdentity = Set(snapshotSourceMovieIdentity)
        let isMovieSubset = !previousMovieIdentity.isEmpty
            && movieIdentity.allSatisfy { previousMovieIdentity.contains($0) }
        browseSnapshot = BrowseSnapshotBuilder.build(
            movies: filteredLibraryItems,
            tvEpisodes: filteredTVItems,
            reusingMovieSearchEntriesFrom: isMovieSubset ? browseSnapshot.searchIndex : nil,
            tasteProfile: currentTasteProfile()
        )
        snapshotSourceMovieIdentity = movieIdentity
        snapshotSourceTVIdentity = tvIdentity
        scheduleSimilarityIndexCompute(
            movieIdentity: movieIdentity,
            tvIdentity: tvIdentity
        )
    }

    func recomputeProgressRows() {
        let signpostID = MarqueeSignpost.begin("recompute-progress-rows")
        browseSnapshot = BrowseSnapshotBuilder.refreshProgressRows(
            movies: filteredLibraryItems,
            tvEpisodes: filteredTVItems,
            existing: browseSnapshot,
            tasteProfile: currentTasteProfile()
        )
        scheduleHomeArtworkPreheat(delay: 2.0)
        MarqueeSignpost.end("recompute-progress-rows", signpostID)
    }

    func scheduleHomeArtworkPreheat(delay: TimeInterval = 1.0, allowWhileProfilePicker: Bool = false) {
        homeArtworkPreheatGeneration += 1
        let generation = homeArtworkPreheatGeneration
        let heroItems = browseSnapshot.heroSpotlights.map(\.item)
        let firstRowItems = Array(browseSnapshot.homeRows.prefix(2).flatMap(\.items).prefix(10))
        guard !heroItems.isEmpty || !firstRowItems.isEmpty else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self,
                  generation == self.homeArtworkPreheatGeneration,
                  allowWhileProfilePicker || !self.isProfilePickerVisible() else { return }
            ArtworkCache.shared.populateHomeArtwork(
                heroItems: heroItems,
                firstRowItems: firstRowItems
            )
        }
    }

    private func scheduleSimilarityIndexCompute(
        movieIdentity: [ObjectIdentifier],
        tvIdentity: [ObjectIdentifier]
    ) {
        similarityIndexGeneration += 1
        let generation = similarityIndexGeneration
        let movies = filteredLibraryItems
        let showSummaries = browseSnapshot.showSummaries
        guard movies.count + showSummaries.count > 1 else { return }
        #if DEBUG
        let delay = debugSimilarityIndexComputeDelayForHarness ?? similarityIndexLaunchDelay
        #else
        let delay = similarityIndexLaunchDelay
        #endif
        #if DEBUG
        let buildIndex = debugSimilarityIndexBuilderForHarness ?? {
            BrowseSimilarityIndex.build(preparedInput: $0)
        }
        let eventHandler = debugSimilarityIndexEventHandlerForHarness
        #endif

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            #if DEBUG
            let preflightDropReason = self.similarityIndexDropReason(
                generation: generation,
                movieIdentity: movieIdentity,
                tvIdentity: tvIdentity
            )
            guard preflightDropReason == nil else {
                eventHandler?(SimilarityIndexDebugEvent(
                    generation: generation,
                    durationMS: 0,
                    attached: false,
                    dropReason: preflightDropReason
                ))
                return
            }
            #else
            guard generation == self.similarityIndexGeneration,
                  movieIdentity == self.snapshotSourceMovieIdentity,
                  tvIdentity == self.snapshotSourceTVIdentity,
                  !self.isProfilePickerVisible() else { return }
            #endif
            let preparedInput = BrowseSimilarityIndex.prepareInput(
                movies: movies,
                showSummaries: showSummaries
            )

            DispatchQueue.global(qos: .utility).async {
                let startedAt = Date()
                let signpostID = MarqueeSignpost.begin("similarity-index")
                #if DEBUG
                let index = buildIndex(preparedInput)
                #else
                let index = BrowseSimilarityIndex.build(preparedInput: preparedInput)
                #endif
                MarqueeSignpost.end("similarity-index", signpostID)
                let durationMS = Date().timeIntervalSince(startedAt) * 1000

                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    #if DEBUG
                    let dropReason = self.similarityIndexDropReason(
                        generation: generation,
                        movieIdentity: movieIdentity,
                        tvIdentity: tvIdentity
                    )
                    guard dropReason == nil else {
                        eventHandler?(SimilarityIndexDebugEvent(
                            generation: generation,
                            durationMS: durationMS,
                            attached: false,
                            dropReason: dropReason
                        ))
                        return
                    }
                    #else
                    guard generation == self.similarityIndexGeneration,
                          movieIdentity == self.snapshotSourceMovieIdentity,
                          tvIdentity == self.snapshotSourceTVIdentity,
                          !self.isProfilePickerVisible() else { return }
                    #endif
                    self.browseSnapshot = self.browseSnapshot
                        .attachingSimilarityPreservingComposition(index)
                    #if DEBUG
                    eventHandler?(SimilarityIndexDebugEvent(
                        generation: generation,
                        durationMS: durationMS,
                        attached: true,
                        dropReason: nil
                    ))
                    #endif
                }
            }
        }
    }

    #if DEBUG
    func debugScheduleSimilarityIndexComputeForHarness(
        movieIdentity: [ObjectIdentifier],
        tvIdentity: [ObjectIdentifier]
    ) {
        scheduleSimilarityIndexCompute(movieIdentity: movieIdentity, tvIdentity: tvIdentity)
    }

    func debugSeedLibraryForVisualQATour(
        movies: [MediaItem],
        tvEpisodes: [MediaItem]
    ) {
        debugVisualQAFixtureSuppressesScans = true
        debugScanInvalidationGeneration += 1
        scanGate = ScanRequestGate()
        hasRequestedInitialScan = true
        currentScanAllowsOnlineMetadata = false
        queuedScanAllowsOnlineMetadata = false
        isScanning = false
        hasQueuedScan = false
        scanStatusText = nil
        watchStateAppliedPaths.removeAll()
        libraryItems = movies
        tvItems = tvEpisodes
        recomputeFilteredItems()
        scheduleHomeArtworkPreheat(delay: 0.1, allowWhileProfilePicker: true)
    }

    private func debugScanIsCurrentForPublish(debugGeneration: Int? = nil) -> Bool {
        if debugVisualQAFixtureSuppressesScans {
            return false
        }
        guard let debugGeneration else { return true }
        return debugGeneration == debugScanInvalidationGeneration
    }

    func debugForceActiveScanForVisualQAHarness() {
        _ = scanGate.request()
        isScanning = true
        hasQueuedScan = false
        scanStatusText = "Updating library index..."
    }

    var debugScanStateForVisualQAHarness: (gateRunning: Bool, pending: Bool, queued: Bool, scanning: Bool) {
        (
            gateRunning: scanGate.isRunning,
            pending: scanGate.pendingRescan,
            queued: hasQueuedScan,
            scanning: isScanning
        )
    }

    struct SimilarityIndexDebugEvent {
        let generation: Int
        let durationMS: Double
        let attached: Bool
        let dropReason: SimilarityIndexDebugDropReason?
    }

    enum SimilarityIndexDebugDropReason {
        case generation
        case sourceIdentity
        case profilePickerVisible
    }

    private func similarityIndexDropReason(
        generation: Int,
        movieIdentity: [ObjectIdentifier],
        tvIdentity: [ObjectIdentifier]
    ) -> SimilarityIndexDebugDropReason? {
        if generation != similarityIndexGeneration {
            return .generation
        }
        if movieIdentity != snapshotSourceMovieIdentity || tvIdentity != snapshotSourceTVIdentity {
            return .sourceIdentity
        }
        if isProfilePickerVisible() {
            return .profilePickerVisible
        }
        return nil
    }
    #endif

    // MARK: - TV Show Grouping (Cached)

    private var _showNameCache: [String]?
    private var _episodesByShow: [String: [MediaItem]]?
    private var _seasonsByShow: [String: [Int]]?
    private var _episodesByShowSeason: [String: [MediaItem]]?

    private func invalidateTVCache() {
        _showNameCache = nil
        _episodesByShow = nil
        _seasonsByShow = nil
        _episodesByShowSeason = nil
    }

    var showNames: [String] {
        if let cached = _showNameCache { return cached }
        let names = Set(filteredTVItems.compactMap { $0.showName })
        let sorted = names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        _showNameCache = sorted
        return sorted
    }

    func episodes(forShow showName: String) -> [MediaItem] {
        if let cached = _episodesByShow?[showName] { return cached }
        let result = filteredTVItems.filter { $0.showName == showName }
            .sorted {
                if $0.seasonNumber != $1.seasonNumber {
                    return ($0.seasonNumber ?? 0) < ($1.seasonNumber ?? 0)
                }
                return ($0.episodeNumber ?? 0) < ($1.episodeNumber ?? 0)
            }
        if _episodesByShow == nil { _episodesByShow = [:] }
        _episodesByShow?[showName] = result
        return result
    }

    func seasons(forShow showName: String) -> [Int] {
        if let cached = _seasonsByShow?[showName] { return cached }
        let nums = Set(episodes(forShow: showName).compactMap { $0.seasonNumber })
        let result = nums.sorted()
        if _seasonsByShow == nil { _seasonsByShow = [:] }
        _seasonsByShow?[showName] = result
        return result
    }

    func episodes(forShow showName: String, season: Int) -> [MediaItem] {
        let key = "\(showName)|\(season)"
        if let cached = _episodesByShowSeason?[key] { return cached }
        let result = episodes(forShow: showName)
            .filter { $0.seasonNumber == season }
            .sorted { ($0.episodeNumber ?? 0) < ($1.episodeNumber ?? 0) }
        if _episodesByShowSeason == nil { _episodesByShowSeason = [:] }
        _episodesByShowSeason?[key] = result
        return result
    }

    func representativeEpisode(forShow showName: String) -> MediaItem? {
        episodes(forShow: showName).first
    }

    func upNextEpisode(forShow showName: String) -> MediaItem? {
        let eps = episodes(forShow: showName)
        if let lastIndex = eps.lastIndex(where: { $0.isWatched || $0.hasProgress }) {
            if eps[lastIndex].hasProgress {
                return eps[lastIndex]
            }
            let nextIndex = lastIndex + 1
            if nextIndex < eps.count {
                return eps[nextIndex]
            }
            return nil
        }
        return eps.first
    }

    // MARK: - Watch History

    func clearWatchHistory() {
        watchStore?.clearAll()
        applyWatchProgress()
        libraryItems = Array(libraryItems)
        tvItems = Array(tvItems)
        recomputeFilteredItems()
    }
}

#if DEBUG
enum VerifyVisualQAFixtureHarness {
    static let launchArgument = "--verify-visual-qa-fixture"

    static func runIfRequested() {
        guard CommandLine.arguments.contains(launchArgument) else { return }

        do {
            let detail = try runScenario()
            FileHandle.standardError.write(Data("verify-visual-qa-fixture: PASS fixtureContract: \(detail)\n".utf8))
            FileHandle.standardError.write(Data("verify-visual-qa-fixture: outcome=verified passed=4/4\n".utf8))
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("verify-visual-qa-fixture: FAIL fixtureContract: \(error)\n".utf8))
            FileHandle.standardError.write(Data("verify-visual-qa-fixture: outcome=failed passed=0/4\n".utf8))
            exit(1)
        }
    }

    private static func runScenario() throws -> String {
        try fixtureResetsActiveScanGate()
        try fixtureSuppressesFollowUpScanRequest()
        try fixtureArtworkContractCoversWideAndTallSources()
        try fixtureUniversalCardSilhouetteIsStable()
        return "visual QA fixtures invalidate active scans, suppress delayed scans, and contract-test wide plus tall poster fill-crop capture with fixed universal-card silhouettes"
    }

    private static func fixtureResetsActiveScanGate() throws {
        let state = makeState()
        state.debugForceActiveScanForVisualQAHarness()

        state.debugSeedLibraryForVisualQATour(
            movies: [makeMovie("Visual Fixture Movie")],
            tvEpisodes: [makeEpisode("Visual Fixture Show")]
        )

        let scanState = state.debugScanStateForVisualQAHarness
        try expect(!scanState.gateRunning, "visual fixture should reset active scan gate")
        try expect(!scanState.pending, "visual fixture should clear pending scan requests")
        try expect(!scanState.queued, "visual fixture should clear queued scan UI state")
        try expect(!scanState.scanning, "visual fixture should publish idle scan state")
    }

    private static func fixtureSuppressesFollowUpScanRequest() throws {
        let state = makeState()
        let movie = makeMovie("Suppressed Fixture Movie")
        let episode = makeEpisode("Suppressed Fixture Show")
        state.debugSeedLibraryForVisualQATour(movies: [movie], tvEpisodes: [episode])

        state.scanLibrary(allowOnlineMetadata: false)

        let scanState = state.debugScanStateForVisualQAHarness
        try expect(!scanState.gateRunning, "visual fixture should suppress a delayed scan request")
        try expect(!scanState.scanning, "suppressed delayed scan should not publish scanning")
        try expect(state.libraryItems.map(\.displayTitle) == [movie.displayTitle], "fixture movies should remain installed")
        try expect(state.tvItems.map(\.displayTitle) == [episode.displayTitle], "fixture episodes should remain installed")
    }

    private static func fixtureArtworkContractCoversWideAndTallSources() throws {
        let specifications = VisualQAPosterArtworkFixture.specifications
        let shapes = Set(specifications.map(\.shape))
        try expect(shapes == Set([.wide, .tall]), "poster artwork fixture should include both wide and tall sources")

        guard let wide = specifications.first(where: { $0.shape == .wide }),
              let tall = specifications.first(where: { $0.shape == .tall }) else {
            throw HarnessError.assertion("poster artwork fixture specifications are incomplete")
        }
        try expect(wide.pixelSize.width >= wide.pixelSize.height * 2, "wide poster fixture should be deliberately odd-aspect")
        try expect(tall.pixelSize.height >= tall.pixelSize.width * 2, "tall poster fixture should be deliberately odd-aspect")
        try expect(
            abs(UniversalPosterCardArtworkLayout.frameAspectRatio - (2.0 / 3.0)) < 0.001,
            "UniversalPosterCard should own one fixed 2:3 poster frame"
        )
        try expect(
            abs(UniversalPosterCardArtworkLayout.frameHeight(forWidth: 150) - 225) < 0.001,
            "standard UniversalPosterCard artwork should resolve to a 150x225 poster frame"
        )
        try expect(
            abs(UniversalPosterCardArtworkLayout.frameHeight(forWidth: 120) - 180) < 0.001,
            "detail UniversalPosterCard artwork should preserve the same 2:3 frame"
        )
        try expect(
            VisualQAPosterArtworkFixture.captureName == "06a-movies-poster-fill-crop-contract",
            "odd-aspect poster fixtures should have a dedicated capture contract"
        )
        try expect(
            VisualQAPosterArtworkFixture.renderingContract == "fill-crop-clipped",
            "poster capture contract should require fill-crop clipping"
        )
    }

    private static func fixtureUniversalCardSilhouetteIsStable() throws {
        let titleLineHeight: CGFloat = 16
        let metadataLineHeight: CGFloat = 13
        let spacing: CGFloat = 2
        let reservedHeight = UniversalPosterCardLabelLayout.reservedHeight(
            titleLineHeight: titleLineHeight,
            metadataLineHeight: metadataLineHeight,
            spacing: spacing
        )
        try expect(
            UniversalPosterCardLabelLayout.titleLineCapacity == 2,
            "universal cards should reserve two title lines"
        )
        try expect(
            UniversalPosterCardLabelLayout.metadataLineCapacity == 2,
            "universal cards should reserve two metadata lines for movie, episode, and show adapters"
        )
        try expect(
            abs(reservedHeight - 62) < 0.001,
            "fixed universal-card label block should reserve 62 points for the compact fixture, got \(reservedHeight)"
        )
        let accessibilityTitleLineHeight = UniversalPosterCardLabelLayout.scaledLineHeight(
            fontSize: 20.8,
            baseFontSize: 13,
            baseLineHeight: 16
        )
        let accessibilityMetadataLineHeight = UniversalPosterCardLabelLayout.scaledLineHeight(
            fontSize: 17.6,
            baseFontSize: 11,
            baseLineHeight: 13
        )
        let accessibilityReservedHeight = UniversalPosterCardLabelLayout.reservedHeight(
            titleLineHeight: accessibilityTitleLineHeight,
            metadataLineHeight: accessibilityMetadataLineHeight,
            spacing: 3.2
        )
        try expect(
            abs(accessibilityReservedHeight - 99.2) < 0.001,
            "accessibility-scaled universal-card label block should grow with its scaled fonts, got \(accessibilityReservedHeight)"
        )
    }

    private static func makeState() -> LibraryState {
        LibraryState(
            currentProfile: { nil },
            isProfilePickerVisible: { false },
            skipPersistenceForHarness: true
        )
    }

    private static func makeMovie(_ title: String) -> MediaItem {
        MediaItem(
            filePath: "/tmp/marquee-visual-fixture/movies/\(title).mkv",
            fileName: "\(title).mkv",
            title: title,
            year: 2026,
            fileExtension: "mkv",
            fileSize: 1024,
            duration: 7_200,
            localGenres: ["Science Fiction"],
            dateAdded: Date(timeIntervalSince1970: 2_026)
        )
    }

    private static func makeEpisode(_ showName: String) -> MediaItem {
        MediaItem(
            filePath: "/tmp/marquee-visual-fixture/tv/\(showName)/S01E01.mkv",
            fileName: "S01E01.mkv",
            title: "Pilot",
            year: 2026,
            fileExtension: "mkv",
            fileSize: 1024,
            duration: 3_600,
            localGenres: ["Drama"],
            dateAdded: Date(timeIntervalSince1970: 2_026),
            showName: showName,
            seasonNumber: 1,
            episodeNumber: 1,
            episodeTitle: "Pilot"
        )
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition {
            throw HarnessError.assertion(message)
        }
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
