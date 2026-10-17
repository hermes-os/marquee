//
//  CatalogStore.swift
//  Marquee
//
//  Persistence abstraction for the schema-v4 catalog.
//  See docs/ARCHITECTURE.md §"Catalog and library data flow" and
//  docs/ARCHITECTURE_DECISIONS.md ADR-002.
//

import Foundation

/// The read/write surface of the durable catalog. Concrete implementations
/// are responsible for persistence; callers depend only on this protocol.
///
/// `SQLiteCatalogStore` is the runtime implementation;
/// `InMemoryCatalogStore` provides deterministic harness coverage.
public protocol CatalogStore: AnyObject, Sendable {

    // MARK: - Media files

    func upsert(mediaFile: CatalogMediaFile) async throws
    func mediaFile(id: MediaFileID) async throws -> CatalogMediaFile?
    func allMediaFiles() async throws -> [CatalogMediaFile]
    func deleteMediaFile(id: MediaFileID) async throws

    // MARK: - Movies

    func upsert(movie: CatalogMovie) async throws
    func movie(id: MovieID) async throws -> CatalogMovie?
    func allMovies() async throws -> [CatalogMovie]
    func deleteMovie(id: MovieID) async throws

    // MARK: - Shows / Seasons / Episodes

    func upsert(show: CatalogShow) async throws
    func show(id: ShowID) async throws -> CatalogShow?
    func allShows() async throws -> [CatalogShow]

    func upsert(season: CatalogSeason) async throws
    func seasons(of show: ShowID) async throws -> [CatalogSeason]

    func upsert(episode: CatalogEpisode) async throws
    func episode(id: EpisodeID) async throws -> CatalogEpisode?
    func episodes(of season: SeasonID) async throws -> [CatalogEpisode]

    // MARK: - Artwork

    func upsert(artwork: CatalogArtworkAsset) async throws
    func artwork(for owner: ArtworkOwner) async throws -> [CatalogArtworkAsset]

    // MARK: - Watch state

    func upsert(watchState: CatalogWatchState) async throws
    func watchState(
        profile: ProfileID,
        target: WatchTarget
    ) async throws -> CatalogWatchState?
    func watchStates(profile: ProfileID) async throws -> [CatalogWatchState]

    // MARK: - Profiles

    func upsert(profile: CatalogProfile) async throws
    func profile(id: ProfileID) async throws -> CatalogProfile?
    func allProfiles() async throws -> [CatalogProfile]

    // MARK: - Scan jobs and events
    //
    // Jobs are mutable rows keyed by `ScanJobID`; the scanner upserts
    // the same row across its `queued → running → terminal` transitions
    // and updates the counter fields in lock-step with the catalog
    // writes from the same tick.
    //
    // `rootPath` and `createdAt` are immutable identity fields. On
    // conflicting `upsert(scanJob:)` calls, implementations MUST keep
    // the values from the original insert and ignore the values bound
    // by the caller. SQLite enforces this through the `ON CONFLICT(id)
    // DO UPDATE` SET list (those columns are excluded); the in-memory
    // store mirrors the rule. A scanner that wants a different
    // root/start time must allocate a new `ScanJobID`.
    //
    // Result ordering: `allScanJobs()` and `scanEvents(of:)` return
    // rows in chronological order (`created_at` for jobs, `timestamp`
    // then `id` for events). Implementations MUST sort accordingly so
    // queue/audit consumers can render directly without resorting.
    //
    // Events are append-only. Implementations MUST reject:
    //   - duplicate `ScanEventID` (a duplicate is a generator bug, not
    //     a re-emit; uniqueness is enforced by the primary key)
    //   - any `CatalogScanEvent` whose `jobID` does not match a row
    //     already written via `upsert(scanJob:)` — the SQLite store
    //     enforces this through a NOT NULL foreign key, and the
    //     in-memory store mirrors the check before mutation
    //
    // There is intentionally no API to mutate or delete an event:
    // `scan_event.job_id ON DELETE CASCADE` only affects the case where
    // an entire job is deleted, which is not exposed in the protocol
    // surface. Job upsert MUST be update-in-place, not REPLACE, so the
    // audit trail survives state transitions.

    func upsert(scanJob: CatalogScanJob) async throws
    func scanJob(id: ScanJobID) async throws -> CatalogScanJob?
    func allScanJobs() async throws -> [CatalogScanJob]

    func append(scanEvent: CatalogScanEvent) async throws
    func append(scanEvents: [CatalogScanEvent]) async throws
    func scanEvents(of job: ScanJobID) async throws -> [CatalogScanEvent]

    // MARK: - Transactions

    /// Runs `work` inside a single atomic write unit. Throws from the
    /// closure roll back all writes performed via the closure's store
    /// parameter. On success, all writes commit together.
    ///
    /// Contract:
    ///   - Implementations pin the transaction to a single store
    ///     instance. Calling another store's API from inside the closure
    ///     does not participate in this transaction.
    ///   - Nested transactions are rejected with
    ///     `CatalogStoreError.nestedTransactionNotSupported`.
    ///   - While a transaction is in flight, concurrent writes from
    ///     other tasks on the same store are queued until the
    ///     transaction commits or rolls back; this prevents unrelated
    ///     writes from being silently coupled to the caller's commit
    ///     boundary.
    ///   - Reads from inside the closure see this transaction's own
    ///     uncommitted writes (read-your-writes).
    ///   - Long-running async work inside the closure (network I/O,
    ///     unrelated actor calls) extends the write lock and is
    ///     discouraged. Callers should prepare data outside the
    ///     transaction and use the closure only to write.
    func withTransaction<T: Sendable>(
        _ work: @Sendable (any CatalogStore) async throws -> T
    ) async throws -> T

    // MARK: - Batch upserts

    /// Atomic batch writes. Each call upserts the entire batch as a
    /// single unit. When called outside `withTransaction`, the batch
    /// runs inside an internal transaction so the call is all-or-nothing.
    /// When called inside `withTransaction`, the batch participates in
    /// the caller's transaction.
    ///
    /// Implementations should prepare the SQL statement once and reuse
    /// it across rows so amortised per-row cost is bind+step only.
    func upsert(mediaFiles: [CatalogMediaFile]) async throws
    func upsert(movies: [CatalogMovie]) async throws
    func upsert(shows: [CatalogShow]) async throws
    func upsert(seasons: [CatalogSeason]) async throws
    func upsert(episodes: [CatalogEpisode]) async throws
    func upsert(artwork: [CatalogArtworkAsset]) async throws
    func upsert(watchStates: [CatalogWatchState]) async throws

    // MARK: - Enrichment composite (Phase 2E.4b)
    //
    // `replaceEnrichment` is a *full replace per owner* scoped to TMDB-
    // sourced rows: the cast_member rows for the owner are deleted-
    // then-rewritten, and `artwork_asset` rows for the owner with
    // `source_label='tmdb'` are deleted-then-rewritten. Sidecar artwork
    // rows (`source_label='sidecar'` etc.) are NOT touched, so the
    // operation preserves authoritative sidecars and is safe to repeat.
    //
    // Pre-transaction invariants — all checked before the tx opens, all
    // failures throw `CatalogStoreError.ownerCoreMismatch(...)` and
    // perform NO writes:
    //
    //   1. `core` case matches `owner` case AND the embedded id
    //      matches the owner id.
    //   2. Every `artwork` row has `.owner == owner`.
    //   3. Every `artwork` row has `sourceLabel == "tmdb"`.
    //
    // The combination of (2)+(3) keeps the per-source delete contract
    // honest: re-enriching the same owner produces a deterministic
    // post-state regardless of how many times it runs.
    //
    // The transaction body, in order, is:
    //
    //   1. UPSERT each person from `cast` by id (= TMDB person id).
    //      Names/profile paths follow the latest call.
    //   2. DELETE FROM cast_member WHERE owner_type=? AND owner_id=?
    //   3. DELETE FROM artwork_asset
    //        WHERE owner_type=? AND owner_id=? AND source_label='tmdb'
    //   4. UPSERT the matching movie/show/season/episode row from `core`.
    //   5. INSERT cast_member rows in caller-supplied ordinal order.
    //   6. INSERT artwork_asset rows.
    //   7. COMMIT (or ROLLBACK on any failure).

    func replaceEnrichment(
        owner: ArtworkOwner,
        core: CatalogEnrichmentCore,
        cast: [CatalogCastEntry],
        artwork: [CatalogArtworkAsset]
    ) async throws

    /// Full replace for D2 movie intelligence rows owned by one source movie.
    /// The movie row must already exist. Normal `upsert(movie:)` calls must
    /// preserve these extension fields; this method is the writer that updates
    /// them and replaces the movie's keyword/edge rows atomically.
    func replaceMovieIntelligence(
        movieID: MovieID,
        voteCount: Int?,
        popularity: Double?,
        collectionID: Int?,
        collectionName: String?,
        keywords: [CatalogMovieKeyword],
        edges: [CatalogMovieEdge]
    ) async throws

    /// Bulk-snapshot read for the projection. Runs nine SELECTs inside
    /// a single read transaction:
    ///
    ///   1. SELECT … FROM movie
    ///   2. SELECT … FROM show
    ///   3. SELECT … FROM season
    ///   4. SELECT … FROM episode
    ///   5. SELECT … FROM artwork_asset
    ///   6. SELECT … FROM cast_member ORDER BY owner_type, owner_id, ordinal
    ///   7. SELECT id, name, profile_path FROM person
    ///   8. SELECT … FROM movie_keyword
    ///   9. SELECT … FROM movie_edge
    ///
    /// Implementations build a `[Int: (name, profilePath)]` map from (7)
    /// then in-memory hash-join (6) to produce `CatalogCastEntry` values
    /// with name + profilePath denormalised in. No SQL joins are run.
    func enrichmentSnapshot() async throws -> CatalogEnrichmentSnapshot

    /// Per-movie D2 coverage report for keywords, collections, and local
    /// edges. This is diagnostics-only and must not include profile/watch
    /// or affinity-derived data.
    func movieIntelligenceCoverageReport() async throws -> CatalogMovieIntelligenceCoverageReport

    // MARK: - Schema lifecycle

    /// Schema version this store reports. Bumped on every breaking
    /// migration in lockstep via `CatalogSchema.currentVersion` so the
    /// SQLite and in-memory stores cannot drift. See that constant for
    /// the version history.
    var schemaVersion: Int { get async }

    /// Counts per entity. Useful for diagnostics and importer
    /// idempotency checks. Implementations should compute these directly
    /// from storage rather than caching.
    func countsSnapshot() async throws -> CatalogCounts
}

public struct CatalogCounts: Hashable, Codable, Sendable {
    public let mediaFiles: Int
    public let movies: Int
    public let shows: Int
    public let seasons: Int
    public let episodes: Int
    public let artwork: Int
    public let watchStates: Int
    public let profiles: Int
    public let scanJobs: Int
    public let scanEvents: Int

    public init(
        mediaFiles: Int,
        movies: Int,
        shows: Int,
        seasons: Int,
        episodes: Int,
        artwork: Int,
        watchStates: Int,
        profiles: Int,
        scanJobs: Int,
        scanEvents: Int
    ) {
        self.mediaFiles = mediaFiles
        self.movies = movies
        self.shows = shows
        self.seasons = seasons
        self.episodes = episodes
        self.artwork = artwork
        self.watchStates = watchStates
        self.profiles = profiles
        self.scanJobs = scanJobs
        self.scanEvents = scanEvents
    }
}

/// Single source of truth for the catalog schema version. Every
/// concrete `CatalogStore` reports this value through `schemaVersion`,
/// so a missed bump on one store cannot drift past the other. Bump
/// here in lockstep with the SQLite migration step.
///
/// v1 — Phase 1 baseline (media_file, movie, show, season, episode,
///       artwork_asset, watch_state, profile)
/// v2 — Phase 2: + scan_job, scan_event
/// v3 — Phase 2E.4b: + person, cast_member; show/episode get
///       releaseDate/runtimeMinutes/voteAverage/director (show) and
///       tmdbID/certification/releaseDate/voteAverage (episode);
///       `replaceEnrichment` / `enrichmentSnapshot` API.
/// v4 — Catalog-intelligence D2: + movie vote_count/popularity/
///       collection_id/collection_name, movie_keyword, movie_edge.
public enum CatalogSchema {
    public static let currentVersion: Int = 4
}

public enum CatalogStoreError: Error, Equatable {
    case notFound
    case schemaMismatch(found: Int, expected: Int)
    case ioFailure(String)
    /// `withTransaction` was called from inside another transaction on
    /// the same store. The catalog API is intentionally non-nesting to
    /// keep transaction boundaries auditable.
    case nestedTransactionNotSupported
    /// `replaceEnrichment(owner:core:cast:artwork:)` was called with a
    /// `core` whose case does not match `owner`, or with a `cast` /
    /// `artwork` array containing rows that do not match `owner` /
    /// are not TMDB-sourced. The full invariant set is documented on
    /// the protocol method. No DB writes are attempted — the
    /// validator runs *before* the transaction opens.
    case ownerCoreMismatch(String)
}
