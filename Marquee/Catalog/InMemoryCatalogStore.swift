//
//  InMemoryCatalogStore.swift
//  Marquee
//
//  In-memory, actor-isolated `CatalogStore` used by deterministic harnesses.
//  Production persistence is provided by `SQLiteCatalogStore`.
//

import Foundation

public actor InMemoryCatalogStore: CatalogStore {

    public let schemaVersion: Int = CatalogSchema.currentVersion

    // MARK: - Storage

    private var mediaFiles: [MediaFileID: CatalogMediaFile] = [:]
    private var movies: [MovieID: CatalogMovie] = [:]
    private var shows: [ShowID: CatalogShow] = [:]
    private var seasons: [SeasonID: CatalogSeason] = [:]
    private var episodes: [EpisodeID: CatalogEpisode] = [:]
    private var artwork: [ArtworkAssetID: CatalogArtworkAsset] = [:]
    private var watchStates: [WatchStateID: CatalogWatchState] = [:]
    private var profiles: [ProfileID: CatalogProfile] = [:]
    private var scanJobs: [ScanJobID: CatalogScanJob] = [:]
    private var scanEvents: [ScanEventID: CatalogScanEvent] = [:]
    private var movieKeywords: [MovieID: [CatalogMovieKeyword]] = [:]
    private var movieEdgesBySource: [MovieID: [CatalogMovieEdge]] = [:]

    // Phase 2E.4b: relational cast model. `persons` keyed by TMDB
    // person id; `castMembers` keyed by the synthesised cast_member
    // row id. Snapshot/restore covers both so a thrown enrichment tx
    // restores the prior state of the relational graph as well.
    private struct CastMemberRow: Hashable {
        let id: String
        let owner: ArtworkOwner
        let personTMDBID: Int
        let character: String
        let ordinal: Int
    }
    private var persons: [Int: (name: String, profilePath: String?)] = [:]
    private var castMembers: [String: CastMemberRow] = [:]

    public init() {}

    // MARK: - Transactions
    //
    // The in-memory store mirrors the SQLite contract: snapshot on
    // entry, restore on throw. To honor the protocol's concurrent-write
    // guarantee — that unrelated writes from other tasks queue behind an
    // active transaction rather than being silently included in the
    // snapshot boundary — every mutating method routes through the same
    // write gate the SQLite store uses, and the same TaskLocal-plus-
    // actor-token pairing prevents inherited child tasks from bypassing
    // the gate after the transaction ends.

    @TaskLocal
    private static var inheritedTransactionToken: UUID?

    private var activeTransactionToken: UUID?

    private var writeGateLocked = false
    private var writeGateWaiters: [CheckedContinuation<Void, Never>] = []

    private var isInsideOwnTransaction: Bool {
        guard
            let inherited = Self.inheritedTransactionToken,
            let active = activeTransactionToken
        else { return false }
        return inherited == active
    }

    private func acquireWriteGate() async {
        if !writeGateLocked {
            writeGateLocked = true
            return
        }
        await withCheckedContinuation { cont in
            writeGateWaiters.append(cont)
        }
    }

    private func releaseWriteGate() {
        if !writeGateWaiters.isEmpty {
            let next = writeGateWaiters.removeFirst()
            next.resume()
            // Gate stays locked: ownership is handed off to the resumed
            // waiter without flapping the boolean.
        } else {
            writeGateLocked = false
        }
    }

    /// Acquires the write gate unless the caller is already inside this
    /// store's own transaction (in which case the gate is held by
    /// `withTransaction`). Returns `true` when the caller now owns the
    /// gate and is responsible for releasing it. Callers MUST pair
    /// every successful `acquireWriteAccess()` with `releaseWriteAccess(true)`
    /// in a `defer`, including on throw, to avoid stalling other writers.
    ///
    /// Split into separate acquire/release rather than a closure helper
    /// so mutating actor state (`dict[key] = value`) inside each upsert
    /// method does not cross a closure boundary that the Swift
    /// concurrency model treats as an `inout` escape.
    private func acquireWriteAccess() async -> Bool {
        if isInsideOwnTransaction { return false }
        await acquireWriteGate()
        return true
    }

    private func releaseWriteAccess(_ acquired: Bool) {
        if acquired { releaseWriteGate() }
    }

    private struct Snapshot {
        let mediaFiles: [MediaFileID: CatalogMediaFile]
        let movies: [MovieID: CatalogMovie]
        let shows: [ShowID: CatalogShow]
        let seasons: [SeasonID: CatalogSeason]
        let episodes: [EpisodeID: CatalogEpisode]
        let artwork: [ArtworkAssetID: CatalogArtworkAsset]
        let watchStates: [WatchStateID: CatalogWatchState]
        let profiles: [ProfileID: CatalogProfile]
        let scanJobs: [ScanJobID: CatalogScanJob]
        let scanEvents: [ScanEventID: CatalogScanEvent]
        let persons: [Int: (name: String, profilePath: String?)]
        let castMembers: [String: CastMemberRow]
        let movieKeywords: [MovieID: [CatalogMovieKeyword]]
        let movieEdgesBySource: [MovieID: [CatalogMovieEdge]]
    }

    private func snapshot() -> Snapshot {
        Snapshot(
            mediaFiles: mediaFiles,
            movies: movies,
            shows: shows,
            seasons: seasons,
            episodes: episodes,
            artwork: artwork,
            watchStates: watchStates,
            profiles: profiles,
            scanJobs: scanJobs,
            scanEvents: scanEvents,
            persons: persons,
            castMembers: castMembers,
            movieKeywords: movieKeywords,
            movieEdgesBySource: movieEdgesBySource
        )
    }

    private func restore(_ s: Snapshot) {
        mediaFiles = s.mediaFiles
        movies = s.movies
        shows = s.shows
        seasons = s.seasons
        episodes = s.episodes
        artwork = s.artwork
        watchStates = s.watchStates
        profiles = s.profiles
        scanJobs = s.scanJobs
        scanEvents = s.scanEvents
        persons = s.persons
        castMembers = s.castMembers
        movieKeywords = s.movieKeywords
        movieEdgesBySource = s.movieEdgesBySource
    }

    public func withTransaction<T: Sendable>(
        _ work: @Sendable (any CatalogStore) async throws -> T
    ) async throws -> T {
        if isInsideOwnTransaction {
            throw CatalogStoreError.nestedTransactionNotSupported
        }
        await acquireWriteGate()

        let token = UUID()
        activeTransactionToken = token
        defer {
            activeTransactionToken = nil
            releaseWriteGate()
        }

        let saved = snapshot()
        do {
            return try await Self.$inheritedTransactionToken.withValue(token) {
                try await work(self)
            }
        } catch {
            restore(saved)
            throw error
        }
    }

    // MARK: - Media files

    public func upsert(mediaFile: CatalogMediaFile) async throws {
        let acquired = await acquireWriteAccess()
        defer { releaseWriteAccess(acquired) }
        mediaFiles[mediaFile.id] = mediaFile
    }

    public func upsert(mediaFiles batch: [CatalogMediaFile]) async throws {
        let acquired = await acquireWriteAccess()
        defer { releaseWriteAccess(acquired) }
        for f in batch { mediaFiles[f.id] = f }
    }

    public func mediaFile(id: MediaFileID) async throws -> CatalogMediaFile? {
        mediaFiles[id]
    }

    public func allMediaFiles() async throws -> [CatalogMediaFile] {
        Array(mediaFiles.values)
    }

    public func deleteMediaFile(id: MediaFileID) async throws {
        let acquired = await acquireWriteAccess()
        defer { releaseWriteAccess(acquired) }
        mediaFiles.removeValue(forKey: id)
    }

    // MARK: - Movies

    public func upsert(movie: CatalogMovie) async throws {
        let acquired = await acquireWriteAccess()
        defer { releaseWriteAccess(acquired) }
        movies[movie.id] = moviePreservingIntelligence(movie)
    }

    public func upsert(movies batch: [CatalogMovie]) async throws {
        let acquired = await acquireWriteAccess()
        defer { releaseWriteAccess(acquired) }
        for m in batch { movies[m.id] = moviePreservingIntelligence(m) }
    }

    public func movie(id: MovieID) async throws -> CatalogMovie? {
        movies[id]
    }

    public func allMovies() async throws -> [CatalogMovie] {
        Array(movies.values)
    }

    public func deleteMovie(id: MovieID) async throws {
        let acquired = await acquireWriteAccess()
        defer { releaseWriteAccess(acquired) }
        movies.removeValue(forKey: id)
        movieKeywords.removeValue(forKey: id)
        movieEdgesBySource.removeValue(forKey: id)
        for source in Array(movieEdgesBySource.keys) {
            movieEdgesBySource[source]?.removeAll { $0.targetMovieID == id }
        }
    }

    private func moviePreservingIntelligence(_ movie: CatalogMovie) -> CatalogMovie {
        let existing = movies[movie.id]
        return CatalogMovie(
            id: movie.id,
            primaryFile: movie.primaryFile,
            title: movie.title,
            year: movie.year,
            tmdbID: movie.tmdbID,
            overview: movie.overview,
            runtimeMinutes: movie.runtimeMinutes,
            certification: movie.certification,
            releaseDate: movie.releaseDate,
            genres: movie.genres,
            voteAverage: movie.voteAverage,
            director: movie.director,
            voteCount: existing?.voteCount,
            popularity: existing?.popularity,
            collectionID: existing?.collectionID,
            collectionName: existing?.collectionName
        )
    }

    // MARK: - Shows / Seasons / Episodes

    public func upsert(show: CatalogShow) async throws {
        let acquired = await acquireWriteAccess()
        defer { releaseWriteAccess(acquired) }
        shows[show.id] = show
    }

    public func upsert(shows batch: [CatalogShow]) async throws {
        let acquired = await acquireWriteAccess()
        defer { releaseWriteAccess(acquired) }
        for s in batch { shows[s.id] = s }
    }

    public func show(id: ShowID) async throws -> CatalogShow? {
        shows[id]
    }

    public func allShows() async throws -> [CatalogShow] {
        Array(shows.values)
    }

    public func upsert(season: CatalogSeason) async throws {
        let acquired = await acquireWriteAccess()
        defer { releaseWriteAccess(acquired) }
        seasons[season.id] = season
    }

    public func upsert(seasons batch: [CatalogSeason]) async throws {
        let acquired = await acquireWriteAccess()
        defer { releaseWriteAccess(acquired) }
        for s in batch { seasons[s.id] = s }
    }

    public func seasons(of show: ShowID) async throws -> [CatalogSeason] {
        seasons.values.filter { $0.showID == show }
    }

    public func upsert(episode: CatalogEpisode) async throws {
        let acquired = await acquireWriteAccess()
        defer { releaseWriteAccess(acquired) }
        episodes[episode.id] = episode
    }

    public func upsert(episodes batch: [CatalogEpisode]) async throws {
        let acquired = await acquireWriteAccess()
        defer { releaseWriteAccess(acquired) }
        for e in batch { episodes[e.id] = e }
    }

    public func episode(id: EpisodeID) async throws -> CatalogEpisode? {
        episodes[id]
    }

    public func episodes(of season: SeasonID) async throws -> [CatalogEpisode] {
        episodes.values.filter { $0.seasonID == season }
    }

    // MARK: - Artwork

    public func upsert(artwork asset: CatalogArtworkAsset) async throws {
        let acquired = await acquireWriteAccess()
        defer { releaseWriteAccess(acquired) }
        artwork[asset.id] = asset
    }

    public func upsert(artwork batch: [CatalogArtworkAsset]) async throws {
        let acquired = await acquireWriteAccess()
        defer { releaseWriteAccess(acquired) }
        for a in batch { artwork[a.id] = a }
    }

    public func artwork(for owner: ArtworkOwner) async throws -> [CatalogArtworkAsset] {
        artwork.values.filter { $0.owner == owner }
    }

    // MARK: - Enrichment (Phase 2E.4b)

    public func replaceEnrichment(
        owner: ArtworkOwner,
        core: CatalogEnrichmentCore,
        cast: [CatalogCastEntry],
        artwork artworkRows: [CatalogArtworkAsset]
    ) async throws {
        // Validate before mutation so a contract violation throws
        // without touching state. Mirrors SQLite's pre-tx validation.
        try CatalogEnrichmentValidator.validate(
            owner: owner,
            core: core,
            artwork: artworkRows
        )

        let acquired = await acquireWriteAccess()
        defer { releaseWriteAccess(acquired) }

        let saved = snapshot()
        do {
            // 1. Upsert persons (denormalised name + profile path).
            for entry in cast {
                persons[entry.personTMDBID] = (
                    name: entry.name,
                    profilePath: entry.profilePath
                )
            }

            // 2. Delete cast_member rows for owner (full-replace).
            castMembers = castMembers.filter { $0.value.owner != owner }

            // 3. Delete TMDB-scoped artwork rows for owner.
            artwork = artwork.filter { (_, asset) in
                !(asset.owner == owner && asset.sourceLabel == "tmdb")
            }

            // 4. Upsert the core entity row.
            try applyCoreUpsert(owner: owner, core: core)

            // 5. Insert cast_member rows with synthesised IDs.
            for entry in cast {
                let id = MediaIdentity.castMemberID(
                    owner: owner,
                    ordinal: entry.ordinal
                )
                if castMembers[id] != nil {
                    // Duplicate (owner, ordinal) inside one call — caller bug.
                    throw CatalogStoreError.ioFailure(
                        "duplicate cast_member id for owner/ordinal: \(id)"
                    )
                }
                castMembers[id] = CastMemberRow(
                    id: id,
                    owner: owner,
                    personTMDBID: entry.personTMDBID,
                    character: entry.character,
                    ordinal: entry.ordinal
                )
            }

            // 6. Insert artwork rows (validator already confirmed owner +
            //    sourceLabel == "tmdb" for every row).
            for asset in artworkRows {
                artwork[asset.id] = asset
            }
        } catch {
            restore(saved)
            throw error
        }
    }

    private func applyCoreUpsert(
        owner: ArtworkOwner,
        core: CatalogEnrichmentCore
    ) throws {
        switch (owner, core) {
        case (.movie(let id), .movie(let movie)):
            guard movie.id == id else {
                throw CatalogStoreError.ownerCoreMismatch(
                    "movie owner id != core movie id"
                )
            }
            movies[id] = moviePreservingIntelligence(movie)
        case (.show(let id), .show(let show)):
            guard show.id == id else {
                throw CatalogStoreError.ownerCoreMismatch(
                    "show owner id != core show id"
                )
            }
            shows[id] = show
        case (.season(let id), .season(let season)):
            guard season.id == id else {
                throw CatalogStoreError.ownerCoreMismatch(
                    "season owner id != core season id"
                )
            }
            seasons[id] = season
        case (.episode(let id), .episode(let episode)):
            guard episode.id == id else {
                throw CatalogStoreError.ownerCoreMismatch(
                    "episode owner id != core episode id"
                )
            }
            episodes[id] = episode
        default:
            // Validator already rejects owner/core case mismatch, so
            // reaching this branch indicates a validator regression.
            throw CatalogStoreError.ownerCoreMismatch(
                "owner/core case mismatch slipped past validator"
            )
        }
    }

    public func replaceMovieIntelligence(
        movieID: MovieID,
        voteCount: Int?,
        popularity: Double?,
        collectionID: Int?,
        collectionName: String?,
        keywords: [CatalogMovieKeyword],
        edges: [CatalogMovieEdge]
    ) async throws {
        guard keywords.allSatisfy({ $0.movieID == movieID }) else {
            throw CatalogStoreError.ownerCoreMismatch("keyword movie id mismatch")
        }
        guard edges.allSatisfy({ $0.sourceMovieID == movieID }) else {
            throw CatalogStoreError.ownerCoreMismatch("edge source movie id mismatch")
        }
        let keywordIDs = keywords.map(\.keywordID)
        guard Set(keywordIDs).count == keywordIDs.count else {
            throw CatalogStoreError.ownerCoreMismatch("duplicate movie keyword id")
        }
        guard edges.allSatisfy({ $0.rank >= 0 }) else {
            throw CatalogStoreError.ownerCoreMismatch("negative movie edge rank")
        }
        let edgeKeys = edges.map {
            "\($0.sourceMovieID.rawValue)|\($0.targetMovieID.rawValue)|\($0.edgeType.rawValue)"
        }
        guard Set(edgeKeys).count == edgeKeys.count else {
            throw CatalogStoreError.ownerCoreMismatch("duplicate movie edge")
        }

        let acquired = await acquireWriteAccess()
        defer { releaseWriteAccess(acquired) }
        guard let existing = movies[movieID] else { throw CatalogStoreError.notFound }
        guard edges.allSatisfy({ movies[$0.targetMovieID] != nil }) else {
            throw CatalogStoreError.notFound
        }

        movies[movieID] = CatalogMovie(
            id: existing.id,
            primaryFile: existing.primaryFile,
            title: existing.title,
            year: existing.year,
            tmdbID: existing.tmdbID,
            overview: existing.overview,
            runtimeMinutes: existing.runtimeMinutes,
            certification: existing.certification,
            releaseDate: existing.releaseDate,
            genres: existing.genres,
            voteAverage: existing.voteAverage,
            director: existing.director,
            voteCount: voteCount,
            popularity: popularity,
            collectionID: collectionID,
            collectionName: collectionName
        )
        movieKeywords[movieID] = keywords.sorted {
            if $0.name.caseInsensitiveCompare($1.name) == .orderedSame {
                return $0.keywordID < $1.keywordID
            }
            return $0.name.caseInsensitiveCompare($1.name) == .orderedAscending
        }
        movieEdgesBySource[movieID] = edges.sorted {
            if $0.edgeType == $1.edgeType {
                if $0.rank == $1.rank {
                    return $0.targetMovieID.rawValue < $1.targetMovieID.rawValue
                }
                return $0.rank < $1.rank
            }
            return $0.edgeType.rawValue < $1.edgeType.rawValue
        }
    }

    public func enrichmentSnapshot() async throws -> CatalogEnrichmentSnapshot {
        // Group cast and artwork by owner. Cast entries are denormalised
        // back into `CatalogCastEntry` form by joining against `persons`.
        var castByOwner: [ArtworkOwner: [CatalogCastEntry]] = [:]
        for row in castMembers.values {
            let person = persons[row.personTMDBID]
            let entry = CatalogCastEntry(
                personTMDBID: row.personTMDBID,
                name: person?.name ?? "",
                profilePath: person?.profilePath,
                character: row.character,
                ordinal: row.ordinal
            )
            castByOwner[row.owner, default: []].append(entry)
        }
        // Stable ordinal ordering so projection consumers read in a
        // deterministic order regardless of dictionary iteration.
        for key in castByOwner.keys {
            castByOwner[key]?.sort { $0.ordinal < $1.ordinal }
        }

        var artworkByOwner: [ArtworkOwner: [CatalogArtworkAsset]] = [:]
        for asset in artwork.values {
            artworkByOwner[asset.owner, default: []].append(asset)
        }

        return CatalogEnrichmentSnapshot(
            movies: movies,
            shows: shows,
            seasons: seasons,
            episodes: episodes,
            artworkByOwner: artworkByOwner,
            castByOwner: castByOwner,
            movieKeywordsByMovie: movieKeywords,
            movieEdgesBySource: movieEdgesBySource
        )
    }

    public func movieIntelligenceCoverageReport() async throws -> CatalogMovieIntelligenceCoverageReport {
        let rows = movies.values.sorted {
            if $0.title.caseInsensitiveCompare($1.title) == .orderedSame {
                return $0.id.rawValue < $1.id.rawValue
            }
            return $0.title.caseInsensitiveCompare($1.title) == .orderedAscending
        }.map { movie in
            CatalogMovieIntelligenceCoverageRow(
                movieID: movie.id,
                title: movie.title,
                tmdbID: movie.tmdbID,
                keywordCount: movieKeywords[movie.id]?.count ?? 0,
                collectionID: movie.collectionID,
                collectionName: movie.collectionName,
                edgeCount: movieEdgesBySource[movie.id]?.count ?? 0
            )
        }
        return CatalogMovieIntelligenceCoverageReport(rows: rows)
    }

    // MARK: - Watch state

    public func upsert(watchState: CatalogWatchState) async throws {
        let acquired = await acquireWriteAccess()
        defer { releaseWriteAccess(acquired) }
        watchStates[watchState.id] = watchState
    }

    public func upsert(watchStates batch: [CatalogWatchState]) async throws {
        let acquired = await acquireWriteAccess()
        defer { releaseWriteAccess(acquired) }
        for w in batch { watchStates[w.id] = w }
    }

    public func watchState(
        profile: ProfileID,
        target: WatchTarget
    ) async throws -> CatalogWatchState? {
        let id = MediaIdentity.watchStateID(profile: profile, target: target)
        return watchStates[id]
    }

    public func watchStates(profile: ProfileID) async throws -> [CatalogWatchState] {
        watchStates.values.filter { $0.profile == profile }
    }

    // MARK: - Profiles

    public func upsert(profile: CatalogProfile) async throws {
        let acquired = await acquireWriteAccess()
        defer { releaseWriteAccess(acquired) }
        profiles[profile.id] = profile
    }

    // MARK: - Scan jobs and events

    public func upsert(scanJob: CatalogScanJob) async throws {
        let acquired = await acquireWriteAccess()
        defer { releaseWriteAccess(acquired) }
        // `rootPath` and `createdAt` are part of the job's identity per
        // the SQLite store's `ON CONFLICT(id) DO UPDATE` SET list — they
        // are not in it, so the existing row's values survive. Mirror
        // here so a scanner upsert across `queued → running → completed`
        // cannot accidentally rewrite identity through a re-bound row.
        if let existing = scanJobs[scanJob.id] {
            scanJobs[scanJob.id] = CatalogScanJob(
                id: existing.id,
                rootPath: existing.rootPath,
                volumeUUID: scanJob.volumeUUID,
                state: scanJob.state,
                createdAt: existing.createdAt,
                startedAt: scanJob.startedAt,
                completedAt: scanJob.completedAt,
                lastErrorMessage: scanJob.lastErrorMessage,
                filesObserved: scanJob.filesObserved,
                filesAdded: scanJob.filesAdded,
                filesUpdated: scanJob.filesUpdated,
                filesRemoved: scanJob.filesRemoved
            )
        } else {
            scanJobs[scanJob.id] = scanJob
        }
    }

    public func scanJob(id: ScanJobID) async throws -> CatalogScanJob? {
        scanJobs[id]
    }

    public func allScanJobs() async throws -> [CatalogScanJob] {
        // Match SQLite's `ORDER BY created_at` so callers see the same
        // queue ordering across stores.
        scanJobs.values.sorted { $0.createdAt < $1.createdAt }
    }

    public func append(scanEvent: CatalogScanEvent) async throws {
        let acquired = await acquireWriteAccess()
        defer { releaseWriteAccess(acquired) }
        // Append-only contract (CatalogStore.swift): a duplicate
        // `ScanEventID` indicates a generator bug, not a re-emit.
        // SQLite surfaces this as a primary-key constraint failure;
        // in-memory rejects it explicitly so store parity holds.
        guard scanEvents[scanEvent.id] == nil else {
            throw CatalogStoreError.ioFailure(
                "duplicate scan event id: \(scanEvent.id.rawValue)"
            )
        }
        // Parent-job invariant: SQLite enforces this through
        // `scan_event.job_id REFERENCES scan_job(id) NOT NULL`. Mirror it
        // here so an orphan event is rejected by both stores identically.
        guard scanJobs[scanEvent.jobID] != nil else {
            throw CatalogStoreError.ioFailure(
                "scan event references missing scan job: \(scanEvent.jobID.rawValue)"
            )
        }
        scanEvents[scanEvent.id] = scanEvent
    }

    public func append(scanEvents batch: [CatalogScanEvent]) async throws {
        let acquired = await acquireWriteAccess()
        defer { releaseWriteAccess(acquired) }
        // Validate the whole batch before any mutation so a violation
        // mid-batch does not leave the store half-written. Catches:
        //   - duplicate IDs against existing rows
        //   - duplicate IDs within the batch itself
        //   - orphan events referencing a missing scan job (FK parity
        //     with SQLite)
        var seen = Set<ScanEventID>()
        for e in batch {
            guard scanEvents[e.id] == nil, seen.insert(e.id).inserted else {
                throw CatalogStoreError.ioFailure(
                    "duplicate scan event id: \(e.id.rawValue)"
                )
            }
            guard scanJobs[e.jobID] != nil else {
                throw CatalogStoreError.ioFailure(
                    "scan event references missing scan job: \(e.jobID.rawValue)"
                )
            }
        }
        for e in batch { scanEvents[e.id] = e }
    }

    public func scanEvents(of job: ScanJobID) async throws -> [CatalogScanEvent] {
        // Match SQLite's `ORDER BY timestamp, id`: timestamp is the
        // primary axis, event ID breaks ties so the order is total and
        // reproducible across stores.
        scanEvents.values
            .filter { $0.jobID == job }
            .sorted { lhs, rhs in
                if lhs.timestamp != rhs.timestamp {
                    return lhs.timestamp < rhs.timestamp
                }
                return lhs.id.rawValue < rhs.id.rawValue
            }
    }

    public func profile(id: ProfileID) async throws -> CatalogProfile? {
        profiles[id]
    }

    public func allProfiles() async throws -> [CatalogProfile] {
        Array(profiles.values)
    }

    // MARK: - Diagnostics

    public func countsSnapshot() async throws -> CatalogCounts {
        CatalogCounts(
            mediaFiles: mediaFiles.count,
            movies: movies.count,
            shows: shows.count,
            seasons: seasons.count,
            episodes: episodes.count,
            artwork: artwork.count,
            watchStates: watchStates.count,
            profiles: profiles.count,
            scanJobs: scanJobs.count,
            scanEvents: scanEvents.count
        )
    }
}
