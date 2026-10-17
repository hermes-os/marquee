//
//  SQLiteCatalogStore.swift
//  Marquee
//
//  Runtime `CatalogStore` backed by system sqlite3 with a versioned schema.
//

import Foundation

public actor SQLiteCatalogStore: CatalogStore {

    public nonisolated let schemaVersion: Int = CatalogSchema.currentVersion

    private let conn: SQLiteConnection

    public init(path: String) throws {
        self.conn = try SQLiteConnection(path: path)
        try Self.migrate(conn)
    }

    // MARK: - Write-gate state
    //
    // The actor's mailbox alone does not protect transactional atomicity:
    // when the closure passed to `withTransaction` awaits, the actor
    // services other messages on the same connection, which would couple
    // unrelated writes into the in-flight transaction. The gate
    // serialises *write* access — reads bypass it.
    //
    // To let the closure's own writes pass through the gate without
    // re-acquiring, we tag the closure's task tree with a per-transaction
    // UUID via `@TaskLocal` AND store the same UUID on the actor for the
    // lifetime of the transaction. A write bypasses the gate only when
    // **both** values match. The actor-side token is cleared at
    // commit/rollback, so a child task that inherits the TaskLocal but
    // writes after the transaction ends will find the actor token
    // already nil — equality fails, the bypass is denied, and the write
    // takes the gate like any other caller.

    /// Per-transaction UUID set by `withTransaction.withValue` so the
    /// closure's task tree carries it across `await` boundaries.
    /// Inheriting child tasks see the same value, but matching alone is
    /// not sufficient to bypass the gate — see `isInsideOwnTransaction`.
    @TaskLocal
    private static var inheritedTransactionToken: UUID?

    /// Token of the currently-active transaction on this actor, or `nil`
    /// outside a transaction. Cleared before the gate is released so
    /// late-arriving inherited-task writes cannot bypass.
    private var activeTransactionToken: UUID?

    private var writeGateLocked = false
    private var writeGateWaiters: [CheckedContinuation<Void, Never>] = []

    /// True only when the caller's task tree carries a token that still
    /// matches the actor's active transaction. Both halves are required;
    /// a stale TaskLocal alone (e.g. a child task running after commit)
    /// no longer matches because the actor cleared its side.
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

    /// Runs `work` while holding the write gate. Inside an active
    /// transaction owned by this task, the gate is already held and the
    /// closure runs immediately. Throws from `work` propagate; the gate
    /// is always released.
    private func withWriteAccess<T>(_ work: () throws -> T) async throws -> T {
        if isInsideOwnTransaction {
            return try work()
        }
        await acquireWriteGate()
        defer { releaseWriteGate() }
        return try work()
    }

    /// Variant for batch upserts. Outside a caller-managed transaction
    /// the batch wraps itself in `BEGIN IMMEDIATE`/`COMMIT` so the call
    /// is all-or-nothing without forcing the caller to nest a
    /// `withTransaction`. Inside one, the work runs as part of the
    /// caller's transaction.
    private func withBatchWriteAccess(_ work: () throws -> Void) async throws {
        if isInsideOwnTransaction {
            try work()
            return
        }
        await acquireWriteGate()
        defer { releaseWriteGate() }
        try conn.beginImmediate()
        do {
            try work()
            try conn.commit()
        } catch {
            try? conn.rollback()
            throw error
        }
    }

    // MARK: - Default store location

    public static var defaultPath: String {
        Configuration.appSupportDirectory
            .appendingPathComponent("MediaLibrary.sqlite")
            .path
    }

    // MARK: - Migration

    private static func migrate(_ conn: SQLiteConnection) throws {
        let current = try conn.userVersion
        if current > CatalogSchema.currentVersion {
            throw CatalogStoreError.schemaMismatch(
                found: current,
                expected: CatalogSchema.currentVersion
            )
        }
        if current < 1 {
            try conn.execute(Self.migrationV1)
            try conn.setUserVersion(1)
        }
        if current < 2 {
            try conn.execute(Self.migrationV2)
            try conn.setUserVersion(2)
        }
        if current < 3 {
            // V3 migration is wrapped in BEGIN IMMEDIATE / COMMIT with
            // `PRAGMA user_version = 3` as the *last* statement before
            // COMMIT. That ordering means a partial migration cannot
            // leave the DB on v2 with v3 columns or vice versa: either
            // the whole transaction commits (column adds + version
            // bump together) or the whole thing rolls back.
            try Self.applyMigrationV3(conn)
        }
        if current < 4 {
            // V4 follows the same atomic contract: movie extension columns,
            // keyword/edge tables, indexes, and `user_version = 4` land in
            // one transaction or not at all.
            try Self.applyMigrationV4(conn)
        }
    }

    /// PRAGMA table_info(<table>) → set of column names. Used by
    /// `applyMigrationV3` / `applyMigrationV4` so repeated
    /// `ALTER TABLE ADD COLUMN` calls
    /// are skipped if a previous run partially landed (defensive
    /// against legacy migrations that bumped `user_version` separately).
    private static func tableColumns(
        _ conn: SQLiteConnection,
        table: String
    ) throws -> Set<String> {
        let rows = try conn.query(
            "PRAGMA table_info(\(table))",
            map: { stmt in stmt.text(1) }
        )
        return Set(rows)
    }

    private static func applyMigrationV3(_ conn: SQLiteConnection) throws {
        let showCols = try tableColumns(conn, table: "show")
        let episodeCols = try tableColumns(conn, table: "episode")

        var statements: [String] = []

        // Relational person + cast_member tables. `cast_member.id` is
        // a synthesised hash of `(owner, ordinal)` so a duplicate
        // ordinal in one `replaceEnrichment` call surfaces as a PK
        // collision rather than landing silently. The composite index
        // matches the projection's read path: `ORDER BY owner_type,
        // owner_id, ordinal`.
        statements.append("""
        CREATE TABLE IF NOT EXISTS person (
            id INTEGER PRIMARY KEY,
            name TEXT NOT NULL,
            profile_path TEXT
        )
        """)
        statements.append("""
        CREATE TABLE IF NOT EXISTS cast_member (
            id TEXT PRIMARY KEY,
            owner_type TEXT NOT NULL,
            owner_id TEXT NOT NULL,
            person_id INTEGER NOT NULL REFERENCES person(id),
            character TEXT NOT NULL,
            ordinal INTEGER NOT NULL
        )
        """)
        statements.append("""
        CREATE INDEX IF NOT EXISTS cast_member_owner_idx
            ON cast_member(owner_type, owner_id, ordinal)
        """)

        // Show metadata required for the projection to reconstruct
        // `ShowDetailView` state directly from the catalog.
        if !showCols.contains("release_date") {
            statements.append("ALTER TABLE show ADD COLUMN release_date TEXT")
        }
        if !showCols.contains("runtime_minutes") {
            statements.append("ALTER TABLE show ADD COLUMN runtime_minutes INTEGER")
        }
        if !showCols.contains("vote_average") {
            statements.append("ALTER TABLE show ADD COLUMN vote_average REAL")
        }
        if !showCols.contains("director") {
            statements.append("ALTER TABLE show ADD COLUMN director TEXT")
        }

        // Episode: tmdb_id (per-episode TMDB id, distinct from the
        // show's tmdb_id), plus the per-episode metadata fields.
        if !episodeCols.contains("tmdb_id") {
            statements.append("ALTER TABLE episode ADD COLUMN tmdb_id INTEGER")
        }
        if !episodeCols.contains("certification") {
            statements.append("ALTER TABLE episode ADD COLUMN certification TEXT")
        }
        if !episodeCols.contains("release_date") {
            statements.append("ALTER TABLE episode ADD COLUMN release_date TEXT")
        }
        if !episodeCols.contains("vote_average") {
            statements.append("ALTER TABLE episode ADD COLUMN vote_average REAL")
        }

        let body = statements.joined(separator: ";\n") + ";"
        let wrapped = """
        BEGIN IMMEDIATE;
        \(body)
        PRAGMA user_version = 3;
        COMMIT;
        """
        do {
            try conn.execute(wrapped)
        } catch {
            try? conn.execute("ROLLBACK")
            throw error
        }
    }

    private static func applyMigrationV4(_ conn: SQLiteConnection) throws {
        let movieCols = try tableColumns(conn, table: "movie")
        var statements: [String] = []

        if !movieCols.contains("vote_count") {
            statements.append("ALTER TABLE movie ADD COLUMN vote_count INTEGER")
        }
        if !movieCols.contains("popularity") {
            statements.append("ALTER TABLE movie ADD COLUMN popularity REAL")
        }
        if !movieCols.contains("collection_id") {
            statements.append("ALTER TABLE movie ADD COLUMN collection_id INTEGER")
        }
        if !movieCols.contains("collection_name") {
            statements.append("ALTER TABLE movie ADD COLUMN collection_name TEXT")
        }

        statements.append("""
        CREATE TABLE IF NOT EXISTS movie_keyword (
            movie_id TEXT NOT NULL REFERENCES movie(id) ON DELETE CASCADE,
            keyword_id INTEGER NOT NULL,
            name TEXT NOT NULL COLLATE NOCASE,
            PRIMARY KEY (movie_id, keyword_id)
        )
        """)
        statements.append("""
        CREATE TABLE IF NOT EXISTS movie_edge (
            source_movie_id TEXT NOT NULL REFERENCES movie(id) ON DELETE CASCADE,
            target_movie_id TEXT NOT NULL REFERENCES movie(id) ON DELETE CASCADE,
            edge_type TEXT NOT NULL CHECK (edge_type IN ('similar', 'recommendation')),
            rank INTEGER NOT NULL CHECK (rank >= 0),
            score REAL,
            PRIMARY KEY (source_movie_id, target_movie_id, edge_type)
        )
        """)
        statements.append("""
        CREATE INDEX IF NOT EXISTS movie_tmdb_id_idx
            ON movie(tmdb_id)
            WHERE tmdb_id IS NOT NULL
        """)
        statements.append("""
        CREATE INDEX IF NOT EXISTS movie_collection_idx
            ON movie(collection_id, release_date, title)
            WHERE collection_id IS NOT NULL
        """)
        statements.append("""
        CREATE INDEX IF NOT EXISTS movie_keyword_name_idx
            ON movie_keyword(name COLLATE NOCASE)
        """)
        statements.append("""
        CREATE INDEX IF NOT EXISTS movie_keyword_movie_idx
            ON movie_keyword(movie_id)
        """)
        statements.append("""
        CREATE INDEX IF NOT EXISTS movie_edge_source_type_rank_idx
            ON movie_edge(source_movie_id, edge_type, rank)
        """)
        statements.append("""
        CREATE INDEX IF NOT EXISTS movie_edge_target_type_idx
            ON movie_edge(target_movie_id, edge_type)
        """)

        let body = statements.joined(separator: ";\n") + ";"
        let wrapped = """
        BEGIN IMMEDIATE;
        \(body)
        PRAGMA user_version = 4;
        COMMIT;
        """
        do {
            try conn.execute(wrapped)
        } catch {
            try? conn.execute("ROLLBACK")
            throw error
        }
    }

    private static let migrationV1 = """
    CREATE TABLE IF NOT EXISTS media_file (
        id TEXT PRIMARY KEY,
        volume_uuid TEXT NOT NULL,
        relative_path TEXT NOT NULL,
        absolute_path_snapshot TEXT NOT NULL,
        file_extension TEXT NOT NULL,
        file_size INTEGER NOT NULL,
        modification_date REAL,
        duration_seconds REAL,
        content_hash TEXT,
        date_added REAL NOT NULL
    );

    CREATE TABLE IF NOT EXISTS movie (
        id TEXT PRIMARY KEY,
        primary_file TEXT NOT NULL,
        title TEXT NOT NULL,
        year INTEGER,
        tmdb_id INTEGER,
        overview TEXT,
        runtime_minutes INTEGER,
        certification TEXT,
        release_date TEXT,
        genres_json TEXT NOT NULL DEFAULT '[]',
        vote_average REAL,
        director TEXT
    );

    CREATE TABLE IF NOT EXISTS show (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        year INTEGER,
        tmdb_id INTEGER,
        overview TEXT,
        certification TEXT,
        genres_json TEXT NOT NULL DEFAULT '[]'
    );

    CREATE TABLE IF NOT EXISTS season (
        id TEXT PRIMARY KEY,
        show_id TEXT NOT NULL,
        season_number INTEGER NOT NULL
    );

    CREATE TABLE IF NOT EXISTS episode (
        id TEXT PRIMARY KEY,
        season_id TEXT NOT NULL,
        primary_file TEXT NOT NULL,
        episode_number INTEGER NOT NULL,
        title TEXT,
        overview TEXT,
        runtime_minutes INTEGER
    );

    CREATE TABLE IF NOT EXISTS artwork_asset (
        id TEXT PRIMARY KEY,
        owner_type TEXT NOT NULL,
        owner_id TEXT NOT NULL,
        kind TEXT NOT NULL,
        local_path TEXT,
        remote_url TEXT,
        source_label TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS watch_state (
        id TEXT PRIMARY KEY,
        profile_id TEXT NOT NULL,
        target_type TEXT NOT NULL,
        target_id TEXT NOT NULL,
        position_seconds REAL NOT NULL,
        duration_seconds REAL,
        completed INTEGER NOT NULL DEFAULT 0,
        last_watched REAL NOT NULL
    );

    CREATE TABLE IF NOT EXISTS profile (
        id TEXT PRIMARY KEY,
        display_name TEXT NOT NULL,
        kind TEXT NOT NULL,
        max_certification TEXT,
        created_at REAL NOT NULL
    );
    """

    // Phase 2 — scan_job and scan_event. Real FK on scan_event.job_id
    // because the relationship is not polymorphic. ON DELETE CASCADE so
    // dropping a job removes its audit trail; jobs are cheap to recreate
    // and an orphaned event row is meaningless. Indices serve the two
    // expected access patterns: filter jobs by state for queue display,
    // fetch events by job for the post-hoc audit view.
    private static let migrationV2 = """
    CREATE TABLE IF NOT EXISTS scan_job (
        id TEXT PRIMARY KEY,
        root_path TEXT NOT NULL,
        volume_uuid TEXT NOT NULL,
        state TEXT NOT NULL,
        created_at REAL NOT NULL,
        started_at REAL,
        completed_at REAL,
        last_error_message TEXT,
        files_observed INTEGER NOT NULL DEFAULT 0,
        files_added INTEGER NOT NULL DEFAULT 0,
        files_updated INTEGER NOT NULL DEFAULT 0,
        files_removed INTEGER NOT NULL DEFAULT 0
    );

    CREATE INDEX IF NOT EXISTS scan_job_state_idx
        ON scan_job(state);

    CREATE TABLE IF NOT EXISTS scan_event (
        id TEXT PRIMARY KEY,
        job_id TEXT NOT NULL REFERENCES scan_job(id) ON DELETE CASCADE,
        kind TEXT NOT NULL,
        timestamp REAL NOT NULL,
        path TEXT,
        detail TEXT
    );

    CREATE INDEX IF NOT EXISTS scan_event_job_idx
        ON scan_event(job_id);
    """

    // MARK: - Transactions

    public func withTransaction<T: Sendable>(
        _ work: @Sendable (any CatalogStore) async throws -> T
    ) async throws -> T {
        if isInsideOwnTransaction {
            throw CatalogStoreError.nestedTransactionNotSupported
        }
        await acquireWriteGate()

        let token = UUID()
        activeTransactionToken = token
        // Always clear the actor-side token and release the gate before
        // returning, regardless of commit/rollback outcome. This is the
        // half of the bypass check inheriting child tasks cannot see, so
        // clearing it here is what stops late writes from bypassing.
        defer {
            activeTransactionToken = nil
            releaseWriteGate()
        }

        try conn.beginImmediate()
        do {
            let result = try await Self.$inheritedTransactionToken.withValue(token) {
                try await work(self)
            }
            try conn.commit()
            return result
        } catch {
            // Best-effort rollback; if it fails the connection is
            // already in a bad state and the original error is more
            // useful to the caller.
            try? conn.rollback()
            throw error
        }
    }

    // MARK: - Media files

    public func upsert(mediaFile f: CatalogMediaFile) async throws {
        try await withWriteAccess {
            try conn.run(Self.mediaFileUpsertSQL, Self.bindings(for: f))
        }
    }

    public func upsert(mediaFiles batch: [CatalogMediaFile]) async throws {
        try await withBatchWriteAccess {
            try conn.runMany(
                Self.mediaFileUpsertSQL,
                batch.map(Self.bindings(for:))
            )
        }
    }

    public func mediaFile(id: MediaFileID) async throws -> CatalogMediaFile? {
        try conn.queryOne(
            "SELECT * FROM media_file WHERE id = ?",
            [.text(id.rawValue)],
            map: Self.readMediaFile
        )
    }

    public func allMediaFiles() async throws -> [CatalogMediaFile] {
        try conn.query("SELECT * FROM media_file", map: Self.readMediaFile)
    }

    public func deleteMediaFile(id: MediaFileID) async throws {
        try await withWriteAccess {
            try conn.run("DELETE FROM media_file WHERE id = ?", [.text(id.rawValue)])
        }
    }

    // MARK: - Movies

    public func upsert(movie m: CatalogMovie) async throws {
        try await withWriteAccess {
            try conn.run(Self.movieUpsertSQL, Self.bindings(for: m))
        }
    }

    public func upsert(movies batch: [CatalogMovie]) async throws {
        try await withBatchWriteAccess {
            try conn.runMany(
                Self.movieUpsertSQL,
                batch.map(Self.bindings(for:))
            )
        }
    }

    public func movie(id: MovieID) async throws -> CatalogMovie? {
        try conn.queryOne(
            "SELECT * FROM movie WHERE id = ?",
            [.text(id.rawValue)],
            map: Self.readMovie
        )
    }

    public func allMovies() async throws -> [CatalogMovie] {
        try conn.query("SELECT * FROM movie", map: Self.readMovie)
    }

    public func deleteMovie(id: MovieID) async throws {
        try await withWriteAccess {
            try conn.run("DELETE FROM movie WHERE id = ?", [.text(id.rawValue)])
        }
    }

    // MARK: - Shows

    public func upsert(show s: CatalogShow) async throws {
        try await withWriteAccess {
            try conn.run(Self.showUpsertSQL, Self.bindings(for: s))
        }
    }

    public func upsert(shows batch: [CatalogShow]) async throws {
        try await withBatchWriteAccess {
            try conn.runMany(
                Self.showUpsertSQL,
                batch.map(Self.bindings(for:))
            )
        }
    }

    public func show(id: ShowID) async throws -> CatalogShow? {
        try conn.queryOne(
            "SELECT * FROM show WHERE id = ?",
            [.text(id.rawValue)],
            map: Self.readShow
        )
    }

    public func allShows() async throws -> [CatalogShow] {
        try conn.query("SELECT * FROM show", map: Self.readShow)
    }

    // MARK: - Seasons

    public func upsert(season s: CatalogSeason) async throws {
        try await withWriteAccess {
            try conn.run(Self.seasonUpsertSQL, Self.bindings(for: s))
        }
    }

    public func upsert(seasons batch: [CatalogSeason]) async throws {
        try await withBatchWriteAccess {
            try conn.runMany(
                Self.seasonUpsertSQL,
                batch.map(Self.bindings(for:))
            )
        }
    }

    public func seasons(of show: ShowID) async throws -> [CatalogSeason] {
        try conn.query(
            "SELECT * FROM season WHERE show_id = ?",
            [.text(show.rawValue)],
            map: Self.readSeason
        )
    }

    // MARK: - Episodes

    public func upsert(episode e: CatalogEpisode) async throws {
        try await withWriteAccess {
            try conn.run(Self.episodeUpsertSQL, Self.bindings(for: e))
        }
    }

    public func upsert(episodes batch: [CatalogEpisode]) async throws {
        try await withBatchWriteAccess {
            try conn.runMany(
                Self.episodeUpsertSQL,
                batch.map(Self.bindings(for:))
            )
        }
    }

    public func episode(id: EpisodeID) async throws -> CatalogEpisode? {
        try conn.queryOne(
            "SELECT * FROM episode WHERE id = ?",
            [.text(id.rawValue)],
            map: Self.readEpisode
        )
    }

    public func episodes(of season: SeasonID) async throws -> [CatalogEpisode] {
        try conn.query(
            "SELECT * FROM episode WHERE season_id = ?",
            [.text(season.rawValue)],
            map: Self.readEpisode
        )
    }

    // MARK: - Artwork

    public func upsert(artwork a: CatalogArtworkAsset) async throws {
        try await withWriteAccess {
            try conn.run(Self.artworkUpsertSQL, Self.bindings(for: a))
        }
    }

    public func upsert(artwork batch: [CatalogArtworkAsset]) async throws {
        try await withBatchWriteAccess {
            try conn.runMany(
                Self.artworkUpsertSQL,
                batch.map(Self.bindings(for:))
            )
        }
    }

    public func artwork(for owner: ArtworkOwner) async throws -> [CatalogArtworkAsset] {
        let (ownerType, ownerID) = Self.encodeOwner(owner)
        return try conn.query(
            "SELECT * FROM artwork_asset WHERE owner_type = ? AND owner_id = ?",
            [.text(ownerType), .text(ownerID)],
            map: Self.readArtwork
        )
    }

    // MARK: - Watch state

    public func upsert(watchState w: CatalogWatchState) async throws {
        try await withWriteAccess {
            try conn.run(Self.watchStateUpsertSQL, Self.bindings(for: w))
        }
    }

    public func upsert(watchStates batch: [CatalogWatchState]) async throws {
        try await withBatchWriteAccess {
            try conn.runMany(
                Self.watchStateUpsertSQL,
                batch.map(Self.bindings(for:))
            )
        }
    }

    public func watchState(
        profile: ProfileID,
        target: WatchTarget
    ) async throws -> CatalogWatchState? {
        let id = MediaIdentity.watchStateID(profile: profile, target: target)
        return try conn.queryOne(
            "SELECT * FROM watch_state WHERE id = ?",
            [.text(id.rawValue)],
            map: Self.readWatchState
        )
    }

    public func watchStates(profile: ProfileID) async throws -> [CatalogWatchState] {
        try conn.query(
            "SELECT * FROM watch_state WHERE profile_id = ?",
            [.text(profile.rawValue)],
            map: Self.readWatchState
        )
    }

    // MARK: - Profiles

    public func upsert(profile p: CatalogProfile) async throws {
        try await withWriteAccess {
            try conn.run(Self.profileUpsertSQL, Self.bindings(for: p))
        }
    }

    public func profile(id: ProfileID) async throws -> CatalogProfile? {
        try conn.queryOne(
            "SELECT * FROM profile WHERE id = ?",
            [.text(id.rawValue)],
            map: Self.readProfile
        )
    }

    public func allProfiles() async throws -> [CatalogProfile] {
        try conn.query("SELECT * FROM profile", map: Self.readProfile)
    }

    // MARK: - Scan jobs

    public func upsert(scanJob j: CatalogScanJob) async throws {
        try await withWriteAccess {
            try conn.run(Self.scanJobUpsertSQL, Self.bindings(for: j))
        }
    }

    public func scanJob(id: ScanJobID) async throws -> CatalogScanJob? {
        try conn.queryOne(
            "SELECT * FROM scan_job WHERE id = ?",
            [.text(id.rawValue)],
            map: Self.readScanJob
        )
    }

    public func allScanJobs() async throws -> [CatalogScanJob] {
        try conn.query(
            "SELECT * FROM scan_job ORDER BY created_at",
            map: Self.readScanJob
        )
    }

    // MARK: - Scan events

    public func append(scanEvent e: CatalogScanEvent) async throws {
        try await withWriteAccess {
            try conn.run(Self.scanEventInsertSQL, Self.bindings(for: e))
        }
    }

    public func append(scanEvents batch: [CatalogScanEvent]) async throws {
        try await withBatchWriteAccess {
            try conn.runMany(
                Self.scanEventInsertSQL,
                batch.map(Self.bindings(for:))
            )
        }
    }

    public func scanEvents(of job: ScanJobID) async throws -> [CatalogScanEvent] {
        try conn.query(
            "SELECT * FROM scan_event WHERE job_id = ? ORDER BY timestamp, id",
            [.text(job.rawValue)],
            map: Self.readScanEvent
        )
    }

    // MARK: - Diagnostics

    public func countsSnapshot() async throws -> CatalogCounts {
        CatalogCounts(
            mediaFiles: try conn.queryCount("SELECT count(*) FROM media_file"),
            movies:     try conn.queryCount("SELECT count(*) FROM movie"),
            shows:      try conn.queryCount("SELECT count(*) FROM show"),
            seasons:    try conn.queryCount("SELECT count(*) FROM season"),
            episodes:   try conn.queryCount("SELECT count(*) FROM episode"),
            artwork:    try conn.queryCount("SELECT count(*) FROM artwork_asset"),
            watchStates: try conn.queryCount("SELECT count(*) FROM watch_state"),
            profiles:   try conn.queryCount("SELECT count(*) FROM profile"),
            scanJobs:   try conn.queryCount("SELECT count(*) FROM scan_job"),
            scanEvents: try conn.queryCount("SELECT count(*) FROM scan_event")
        )
    }

    // MARK: - Enrichment composite (Phase 2E.4b)

    public func replaceEnrichment(
        owner: ArtworkOwner,
        core: CatalogEnrichmentCore,
        cast: [CatalogCastEntry],
        artwork: [CatalogArtworkAsset]
    ) async throws {
        // Pre-tx invariants — throw before tx opens, no DB writes attempted.
        try CatalogEnrichmentValidator.validate(
            owner: owner,
            core: core,
            artwork: artwork
        )

        try await withBatchWriteAccess {
            try Self.applyEnrichment(
                conn: conn,
                owner: owner,
                core: core,
                cast: cast,
                artwork: artwork
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

        try await withBatchWriteAccess {
            try Self.applyMovieIntelligence(
                conn: conn,
                movieID: movieID,
                voteCount: voteCount,
                popularity: popularity,
                collectionID: collectionID,
                collectionName: collectionName,
                keywords: keywords,
                edges: edges
            )
        }
    }

    public func enrichmentSnapshot() async throws -> CatalogEnrichmentSnapshot {
        // Single read-only pass. The actor's mailbox already serialises
        // accesses on this connection so a concurrent write cannot
        // observe the sequence mid-flight; no explicit BEGIN needed.

        let movieRows = try conn.query("SELECT * FROM movie", map: Self.readMovie)
        var movies: [MovieID: CatalogMovie] = [:]
        movies.reserveCapacity(movieRows.count)
        for row in movieRows { movies[row.id] = row }

        let showRows = try conn.query("SELECT * FROM show", map: Self.readShow)
        var shows: [ShowID: CatalogShow] = [:]
        shows.reserveCapacity(showRows.count)
        for row in showRows { shows[row.id] = row }

        let seasonRows = try conn.query("SELECT * FROM season", map: Self.readSeason)
        var seasons: [SeasonID: CatalogSeason] = [:]
        seasons.reserveCapacity(seasonRows.count)
        for row in seasonRows { seasons[row.id] = row }

        let episodeRows = try conn.query("SELECT * FROM episode", map: Self.readEpisode)
        var episodes: [EpisodeID: CatalogEpisode] = [:]
        episodes.reserveCapacity(episodeRows.count)
        for row in episodeRows { episodes[row.id] = row }

        let artworkRows = try conn.query("SELECT * FROM artwork_asset", map: Self.readArtwork)
        var artworkByOwner: [ArtworkOwner: [CatalogArtworkAsset]] = [:]
        for row in artworkRows {
            artworkByOwner[row.owner, default: []].append(row)
        }

        // Build person lookup, then hash-join with cast_member rows.
        struct PersonRow { let id: Int; let name: String; let profilePath: String? }
        let personRows = try conn.query(
            "SELECT id, name, profile_path FROM person",
            map: { stmt in
                PersonRow(
                    id: stmt.int(0),
                    name: stmt.text(1),
                    profilePath: stmt.optionalText(2)
                )
            }
        )
        var personByID: [Int: (name: String, profilePath: String?)] = [:]
        personByID.reserveCapacity(personRows.count)
        for p in personRows { personByID[p.id] = (p.name, p.profilePath) }

        struct CastRow {
            let ownerType: String
            let ownerID: String
            let personID: Int
            let character: String
            let ordinal: Int
        }
        let castRows = try conn.query(
            """
            SELECT owner_type, owner_id, person_id, character, ordinal
            FROM cast_member
            ORDER BY owner_type, owner_id, ordinal
            """,
            map: { stmt in
                CastRow(
                    ownerType: stmt.text(0),
                    ownerID: stmt.text(1),
                    personID: stmt.int(2),
                    character: stmt.text(3),
                    ordinal: stmt.int(4)
                )
            }
        )
        var castByOwner: [ArtworkOwner: [CatalogCastEntry]] = [:]
        for row in castRows {
            let owner = Self.decodeOwner(type: row.ownerType, id: row.ownerID)
            let person = personByID[row.personID]
            // If a person row went missing (shouldn't happen — FK
            // enforces it) we fall back to "" / nil so the projection
            // can still render without a crash. Logged once in Debug.
            #if DEBUG
            if person == nil {
                let line = "enrichmentSnapshot: cast_member references missing person_id=\(row.personID)\n"
                FileHandle.standardError.write(Data(line.utf8))
            }
            #endif
            let entry = CatalogCastEntry(
                personTMDBID: row.personID,
                name: person?.name ?? "",
                profilePath: person?.profilePath,
                character: row.character,
                ordinal: row.ordinal
            )
            castByOwner[owner, default: []].append(entry)
        }

        let keywordRows = try conn.query(
            """
            SELECT movie_id, keyword_id, name
            FROM movie_keyword
            ORDER BY movie_id, name COLLATE NOCASE, keyword_id
            """,
            map: { stmt in
                CatalogMovieKeyword(
                    movieID: MovieID(rawValue: stmt.text(0)),
                    keywordID: stmt.int(1),
                    name: stmt.text(2)
                )
            }
        )
        var keywordsByMovie: [MovieID: [CatalogMovieKeyword]] = [:]
        for row in keywordRows {
            keywordsByMovie[row.movieID, default: []].append(row)
        }

        let edgeRows = try conn.query(
            """
            SELECT source_movie_id, target_movie_id, edge_type, rank, score
            FROM movie_edge
            ORDER BY source_movie_id, edge_type, rank, target_movie_id
            """,
            map: { stmt in
                CatalogMovieEdge(
                    sourceMovieID: MovieID(rawValue: stmt.text(0)),
                    targetMovieID: MovieID(rawValue: stmt.text(1)),
                    edgeType: CatalogMovieEdgeType(rawValue: stmt.text(2)) ?? .similar,
                    rank: stmt.int(3),
                    score: stmt.optionalDouble(4)
                )
            }
        )
        var edgesBySource: [MovieID: [CatalogMovieEdge]] = [:]
        for row in edgeRows {
            edgesBySource[row.sourceMovieID, default: []].append(row)
        }

        return CatalogEnrichmentSnapshot(
            movies: movies,
            shows: shows,
            seasons: seasons,
            episodes: episodes,
            artworkByOwner: artworkByOwner,
            castByOwner: castByOwner,
            movieKeywordsByMovie: keywordsByMovie,
            movieEdgesBySource: edgesBySource
        )
    }

    public func movieIntelligenceCoverageReport() async throws -> CatalogMovieIntelligenceCoverageReport {
        struct Row {
            let id: MovieID
            let title: String
            let tmdbID: Int?
            let collectionID: Int?
            let collectionName: String?
        }
        let rows = try conn.query(
            """
            SELECT id, title, tmdb_id, collection_id, collection_name
            FROM movie
            ORDER BY title COLLATE NOCASE, id
            """,
            map: { stmt in
                Row(
                    id: MovieID(rawValue: stmt.text(0)),
                    title: stmt.text(1),
                    tmdbID: stmt.optionalInt(2),
                    collectionID: stmt.optionalInt(3),
                    collectionName: stmt.optionalText(4)
                )
            }
        )
        let coverage = try rows.map { row in
            let keywordCount = try conn.queryCount(
                "SELECT count(*) FROM movie_keyword WHERE movie_id = ?",
                [.text(row.id.rawValue)]
            )
            let edgeCount = try conn.queryCount(
                "SELECT count(*) FROM movie_edge WHERE source_movie_id = ?",
                [.text(row.id.rawValue)]
            )
            return CatalogMovieIntelligenceCoverageRow(
                movieID: row.id,
                title: row.title,
                tmdbID: row.tmdbID,
                keywordCount: keywordCount,
                collectionID: row.collectionID,
                collectionName: row.collectionName,
                edgeCount: edgeCount
            )
        }
        return CatalogMovieIntelligenceCoverageReport(rows: coverage)
    }
}

// MARK: - Upsert SQL + bindings
//
// Statement strings live next to their binding builders so the column
// list, placeholder count, and binding order stay in lock-step. The
// batch upsert APIs prepare these statements once and reuse them across
// rows; the single upsert APIs use them too so there is exactly one
// definition per entity.

extension SQLiteCatalogStore {

    fileprivate static let mediaFileUpsertSQL = """
        INSERT OR REPLACE INTO media_file
        (id, volume_uuid, relative_path, absolute_path_snapshot,
         file_extension, file_size, modification_date,
         duration_seconds, content_hash, date_added)
        VALUES (?,?,?,?,?,?,?,?,?,?)
        """

    fileprivate static func bindings(for f: CatalogMediaFile) -> [SQLValue] {
        [
            .text(f.id.rawValue),
            .text(f.volumeUUID),
            .text(f.relativePath),
            .text(f.absolutePathSnapshot),
            .text(f.fileExtension),
            .int(Int(f.fileSize)),
            f.modificationDate.map { .double($0.timeIntervalSince1970) } ?? .null,
            f.durationSeconds.map { .double($0) } ?? .null,
            f.contentHash.map { .text($0) } ?? .null,
            .double(f.dateAdded.timeIntervalSince1970),
        ]
    }

    fileprivate static let movieUpsertSQL = """
        INSERT INTO movie
        (id, primary_file, title, year, tmdb_id, overview,
         runtime_minutes, certification, release_date,
         genres_json, vote_average, director)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
            primary_file = excluded.primary_file,
            title = excluded.title,
            year = excluded.year,
            tmdb_id = excluded.tmdb_id,
            overview = excluded.overview,
            runtime_minutes = excluded.runtime_minutes,
            certification = excluded.certification,
            release_date = excluded.release_date,
            genres_json = excluded.genres_json,
            vote_average = excluded.vote_average,
            director = excluded.director
        """

    fileprivate static func bindings(for m: CatalogMovie) -> [SQLValue] {
        let genresJSON = encodeGenres(m.genres)
        return [
            .text(m.id.rawValue),
            .text(m.primaryFile.rawValue),
            .text(m.title),
            m.year.map { .int($0) } ?? .null,
            m.tmdbID.map { .int($0) } ?? .null,
            m.overview.map { .text($0) } ?? .null,
            m.runtimeMinutes.map { .int($0) } ?? .null,
            m.certification.map { .text($0) } ?? .null,
            m.releaseDate.map { .text($0) } ?? .null,
            .text(genresJSON),
            m.voteAverage.map { .double($0) } ?? .null,
            m.director.map { .text($0) } ?? .null,
        ]
    }

    fileprivate static let showUpsertSQL = """
        INSERT OR REPLACE INTO show
        (id, title, year, tmdb_id, overview, certification, genres_json,
         release_date, runtime_minutes, vote_average, director)
        VALUES (?,?,?,?,?,?,?,?,?,?,?)
        """

    fileprivate static func bindings(for s: CatalogShow) -> [SQLValue] {
        let genresJSON = encodeGenres(s.genres)
        return [
            .text(s.id.rawValue),
            .text(s.title),
            s.year.map { .int($0) } ?? .null,
            s.tmdbID.map { .int($0) } ?? .null,
            s.overview.map { .text($0) } ?? .null,
            s.certification.map { .text($0) } ?? .null,
            .text(genresJSON),
            s.releaseDate.map { .text($0) } ?? .null,
            s.runtimeMinutes.map { .int($0) } ?? .null,
            s.voteAverage.map { .double($0) } ?? .null,
            s.director.map { .text($0) } ?? .null,
        ]
    }

    fileprivate static let seasonUpsertSQL = """
        INSERT OR REPLACE INTO season (id, show_id, season_number)
        VALUES (?,?,?)
        """

    fileprivate static func bindings(for s: CatalogSeason) -> [SQLValue] {
        [
            .text(s.id.rawValue),
            .text(s.showID.rawValue),
            .int(s.seasonNumber),
        ]
    }

    fileprivate static let episodeUpsertSQL = """
        INSERT OR REPLACE INTO episode
        (id, season_id, primary_file, episode_number, title, overview, runtime_minutes,
         tmdb_id, certification, release_date, vote_average)
        VALUES (?,?,?,?,?,?,?,?,?,?,?)
        """

    fileprivate static func bindings(for e: CatalogEpisode) -> [SQLValue] {
        [
            .text(e.id.rawValue),
            .text(e.seasonID.rawValue),
            .text(e.primaryFile.rawValue),
            .int(e.episodeNumber),
            e.title.map { .text($0) } ?? .null,
            e.overview.map { .text($0) } ?? .null,
            e.runtimeMinutes.map { .int($0) } ?? .null,
            e.tmdbID.map { .int($0) } ?? .null,
            e.certification.map { .text($0) } ?? .null,
            e.releaseDate.map { .text($0) } ?? .null,
            e.voteAverage.map { .double($0) } ?? .null,
        ]
    }

    fileprivate static let artworkUpsertSQL = """
        INSERT OR REPLACE INTO artwork_asset
        (id, owner_type, owner_id, kind, local_path, remote_url, source_label)
        VALUES (?,?,?,?,?,?,?)
        """

    fileprivate static func bindings(for a: CatalogArtworkAsset) -> [SQLValue] {
        let (ownerType, ownerID) = encodeOwner(a.owner)
        return [
            .text(a.id.rawValue),
            .text(ownerType),
            .text(ownerID),
            .text(a.kind.rawValue),
            a.localPath.map { .text($0) } ?? .null,
            a.remoteURL.map { .text($0) } ?? .null,
            .text(a.sourceLabel),
        ]
    }

    fileprivate static let watchStateUpsertSQL = """
        INSERT OR REPLACE INTO watch_state
        (id, profile_id, target_type, target_id,
         position_seconds, duration_seconds, completed, last_watched)
        VALUES (?,?,?,?,?,?,?,?)
        """

    fileprivate static func bindings(for w: CatalogWatchState) -> [SQLValue] {
        let (targetType, targetID) = encodeTarget(w.target)
        return [
            .text(w.id.rawValue),
            .text(w.profile.rawValue),
            .text(targetType),
            .text(targetID),
            .double(w.positionSeconds),
            w.durationSeconds.map { .double($0) } ?? .null,
            .int(w.completed ? 1 : 0),
            .double(w.lastWatched.timeIntervalSince1970),
        ]
    }

    fileprivate static let profileUpsertSQL = """
        INSERT OR REPLACE INTO profile
        (id, display_name, kind, max_certification, created_at)
        VALUES (?,?,?,?,?)
        """

    fileprivate static func bindings(for p: CatalogProfile) -> [SQLValue] {
        [
            .text(p.id.rawValue),
            .text(p.displayName),
            .text(p.kind.rawValue),
            p.maxCertification.map { .text($0) } ?? .null,
            .double(p.createdAt.timeIntervalSince1970),
        ]
    }

    // Update-in-place upsert. `INSERT OR REPLACE` deletes the existing
    // row before inserting, which would cascade through
    // `scan_event.job_id ON DELETE CASCADE` and wipe the job's
    // append-only audit trail. Using `ON CONFLICT(id) DO UPDATE` mutates
    // the existing row so child events survive state transitions.
    // `created_at` and `root_path` are intentionally not in the SET list:
    // the caller's binding for those fields is honoured on first insert
    // and ignored on update — they are part of the job's identity.
    fileprivate static let scanJobUpsertSQL = """
        INSERT INTO scan_job
        (id, root_path, volume_uuid, state,
         created_at, started_at, completed_at, last_error_message,
         files_observed, files_added, files_updated, files_removed)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
            volume_uuid = excluded.volume_uuid,
            state = excluded.state,
            started_at = excluded.started_at,
            completed_at = excluded.completed_at,
            last_error_message = excluded.last_error_message,
            files_observed = excluded.files_observed,
            files_added = excluded.files_added,
            files_updated = excluded.files_updated,
            files_removed = excluded.files_removed
        """

    fileprivate static func bindings(for j: CatalogScanJob) -> [SQLValue] {
        [
            .text(j.id.rawValue),
            .text(j.rootPath),
            .text(j.volumeUUID),
            .text(j.state.rawValue),
            .double(j.createdAt.timeIntervalSince1970),
            j.startedAt.map { .double($0.timeIntervalSince1970) } ?? .null,
            j.completedAt.map { .double($0.timeIntervalSince1970) } ?? .null,
            j.lastErrorMessage.map { .text($0) } ?? .null,
            .int(j.filesObserved),
            .int(j.filesAdded),
            .int(j.filesUpdated),
            .int(j.filesRemoved),
        ]
    }

    // Append-only insert. Events have unique IDs (ScanEventID); a
    // collision indicates a generator bug rather than a re-emit, so
    // INSERT (not INSERT OR REPLACE) preserves the audit trail by
    // surfacing the duplicate as an error.
    fileprivate static let scanEventInsertSQL = """
        INSERT INTO scan_event
        (id, job_id, kind, timestamp, path, detail)
        VALUES (?,?,?,?,?,?)
        """

    fileprivate static func bindings(for e: CatalogScanEvent) -> [SQLValue] {
        [
            .text(e.id.rawValue),
            .text(e.jobID.rawValue),
            .text(e.kind.rawValue),
            .double(e.timestamp.timeIntervalSince1970),
            e.path.map { .text($0) } ?? .null,
            e.detail.map { .text($0) } ?? .null,
        ]
    }

    private static func encodeGenres(_ genres: [String]) -> String {
        (try? JSONEncoder().encode(genres))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }
}

// MARK: - Row readers

extension SQLiteCatalogStore {

    private static func readMediaFile(_ r: Statement) -> CatalogMediaFile {
        CatalogMediaFile(
            id: MediaFileID(rawValue: r.text(0)),
            volumeUUID: r.text(1),
            relativePath: r.text(2),
            absolutePathSnapshot: r.text(3),
            fileExtension: r.text(4),
            fileSize: Int64(r.int(5)),
            modificationDate: r.optionalDate(6),
            durationSeconds: r.optionalDouble(7),
            contentHash: r.optionalText(8),
            dateAdded: r.date(9)
        )
    }

    private static func readMovie(_ r: Statement) -> CatalogMovie {
        let genresJSON = r.text(9)
        let genres = (try? JSONDecoder().decode(
            [String].self, from: Data(genresJSON.utf8)
        )) ?? []
        return CatalogMovie(
            id: MovieID(rawValue: r.text(0)),
            primaryFile: MediaFileID(rawValue: r.text(1)),
            title: r.text(2),
            year: r.optionalInt(3),
            tmdbID: r.optionalInt(4),
            overview: r.optionalText(5),
            runtimeMinutes: r.optionalInt(6),
            certification: r.optionalText(7),
            releaseDate: r.optionalText(8),
            genres: genres,
            voteAverage: r.optionalDouble(10),
            director: r.optionalText(11),
            voteCount: r.optionalInt(12),
            popularity: r.optionalDouble(13),
            collectionID: r.optionalInt(14),
            collectionName: r.optionalText(15)
        )
    }

    private static func readShow(_ r: Statement) -> CatalogShow {
        let genresJSON = r.text(6)
        let genres = (try? JSONDecoder().decode(
            [String].self, from: Data(genresJSON.utf8)
        )) ?? []
        return CatalogShow(
            id: ShowID(rawValue: r.text(0)),
            title: r.text(1),
            year: r.optionalInt(2),
            tmdbID: r.optionalInt(3),
            overview: r.optionalText(4),
            certification: r.optionalText(5),
            genres: genres,
            releaseDate: r.optionalText(7),
            runtimeMinutes: r.optionalInt(8),
            voteAverage: r.optionalDouble(9),
            director: r.optionalText(10)
        )
    }

    private static func readSeason(_ r: Statement) -> CatalogSeason {
        CatalogSeason(
            id: SeasonID(rawValue: r.text(0)),
            showID: ShowID(rawValue: r.text(1)),
            seasonNumber: r.int(2)
        )
    }

    private static func readEpisode(_ r: Statement) -> CatalogEpisode {
        CatalogEpisode(
            id: EpisodeID(rawValue: r.text(0)),
            seasonID: SeasonID(rawValue: r.text(1)),
            primaryFile: MediaFileID(rawValue: r.text(2)),
            episodeNumber: r.int(3),
            title: r.optionalText(4),
            overview: r.optionalText(5),
            runtimeMinutes: r.optionalInt(6),
            tmdbID: r.optionalInt(7),
            certification: r.optionalText(8),
            releaseDate: r.optionalText(9),
            voteAverage: r.optionalDouble(10)
        )
    }

    private static func readArtwork(_ r: Statement) -> CatalogArtworkAsset {
        CatalogArtworkAsset(
            id: ArtworkAssetID(rawValue: r.text(0)),
            owner: decodeOwner(type: r.text(1), id: r.text(2)),
            kind: ArtworkKind(rawValue: r.text(3)) ?? .poster,
            localPath: r.optionalText(4),
            remoteURL: r.optionalText(5),
            sourceLabel: r.text(6)
        )
    }

    private static func readWatchState(_ r: Statement) -> CatalogWatchState {
        CatalogWatchState(
            id: WatchStateID(rawValue: r.text(0)),
            profile: ProfileID(rawValue: r.text(1)),
            target: decodeTarget(type: r.text(2), id: r.text(3)),
            positionSeconds: r.double(4),
            durationSeconds: r.optionalDouble(5),
            completed: r.bool(6),
            lastWatched: r.date(7)
        )
    }

    private static func readProfile(_ r: Statement) -> CatalogProfile {
        CatalogProfile(
            id: ProfileID(rawValue: r.text(0)),
            displayName: r.text(1),
            kind: ProfileKind(rawValue: r.text(2)) ?? .adult,
            maxCertification: r.optionalText(3),
            createdAt: r.date(4)
        )
    }

    private static func readScanJob(_ r: Statement) -> CatalogScanJob {
        CatalogScanJob(
            id: ScanJobID(rawValue: r.text(0)),
            rootPath: r.text(1),
            volumeUUID: r.text(2),
            state: ScanJobState(rawValue: r.text(3)) ?? .queued,
            createdAt: r.date(4),
            startedAt: r.optionalDate(5),
            completedAt: r.optionalDate(6),
            lastErrorMessage: r.optionalText(7),
            filesObserved: r.int(8),
            filesAdded: r.int(9),
            filesUpdated: r.int(10),
            filesRemoved: r.int(11)
        )
    }

    private static func readScanEvent(_ r: Statement) -> CatalogScanEvent {
        CatalogScanEvent(
            id: ScanEventID(rawValue: r.text(0)),
            jobID: ScanJobID(rawValue: r.text(1)),
            kind: ScanEventKind(rawValue: r.text(2)) ?? .fileSeen,
            timestamp: r.date(3),
            path: r.optionalText(4),
            detail: r.optionalText(5)
        )
    }
}

// MARK: - Enum encoding helpers

extension SQLiteCatalogStore {

    private static func encodeOwner(_ owner: ArtworkOwner) -> (String, String) {
        switch owner {
        case .movie(let id):   return ("movie", id.rawValue)
        case .show(let id):    return ("show", id.rawValue)
        case .season(let id):  return ("season", id.rawValue)
        case .episode(let id): return ("episode", id.rawValue)
        }
    }

    private static func decodeOwner(type: String, id: String) -> ArtworkOwner {
        switch type {
        case "movie":   return .movie(MovieID(rawValue: id))
        case "show":    return .show(ShowID(rawValue: id))
        case "season":  return .season(SeasonID(rawValue: id))
        case "episode": return .episode(EpisodeID(rawValue: id))
        default:
            assertionFailure("Unknown artwork owner_type in DB: \(type)")
            return .movie(MovieID(rawValue: id))
        }
    }

    private static func encodeTarget(_ target: WatchTarget) -> (String, String) {
        switch target {
        case .movie(let id):   return ("movie", id.rawValue)
        case .episode(let id): return ("episode", id.rawValue)
        }
    }

    // MARK: - Enrichment transaction body

    /// Applies the per-owner enrichment write inside the caller's
    /// transaction. Must be called only after
    /// `CatalogEnrichmentValidator.validate` has passed.
    fileprivate static func applyEnrichment(
        conn: SQLiteConnection,
        owner: ArtworkOwner,
        core: CatalogEnrichmentCore,
        cast: [CatalogCastEntry],
        artwork: [CatalogArtworkAsset]
    ) throws {
        let (ownerType, ownerID) = encodeOwner(owner)

        // 1. UPSERT each person from `cast` by id (= TMDB person id).
        if !cast.isEmpty {
            let personSQL = """
            INSERT INTO person (id, name, profile_path) VALUES (?,?,?)
            ON CONFLICT(id) DO UPDATE SET
                name = excluded.name,
                profile_path = excluded.profile_path
            """
            try conn.runMany(personSQL, cast.map { c in
                [
                    .int(c.personTMDBID),
                    .text(c.name),
                    c.profilePath.map { .text($0) } ?? .null,
                ]
            })
        }

        // 2. DELETE cast_member rows for this owner.
        try conn.run(
            "DELETE FROM cast_member WHERE owner_type = ? AND owner_id = ?",
            [.text(ownerType), .text(ownerID)]
        )

        // 3. DELETE TMDB-sourced artwork rows for this owner. Sidecar
        // rows (`source_label != 'tmdb'`) are intentionally untouched.
        try conn.run(
            """
            DELETE FROM artwork_asset
            WHERE owner_type = ? AND owner_id = ? AND source_label = 'tmdb'
            """,
            [.text(ownerType), .text(ownerID)]
        )

        // 4. UPSERT the matching core row.
        switch core {
        case .movie(let m):
            try conn.run(movieUpsertSQL, bindings(for: m))
        case .show(let s):
            try conn.run(showUpsertSQL, bindings(for: s))
        case .season(let sn):
            try conn.run(seasonUpsertSQL, bindings(for: sn))
        case .episode(let e):
            try conn.run(episodeUpsertSQL, bindings(for: e))
        }

        // 5. INSERT cast_member rows in caller-supplied ordinal order.
        if !cast.isEmpty {
            let castSQL = """
            INSERT INTO cast_member
            (id, owner_type, owner_id, person_id, character, ordinal)
            VALUES (?,?,?,?,?,?)
            """
            try conn.runMany(castSQL, cast.map { c in
                let castID = MediaIdentity.castMemberID(
                    owner: owner,
                    ordinal: c.ordinal
                )
                return [
                    .text(castID),
                    .text(ownerType),
                    .text(ownerID),
                    .int(c.personTMDBID),
                    .text(c.character),
                    .int(c.ordinal),
                ]
            })
        }

        // 6. INSERT artwork_asset rows.
        if !artwork.isEmpty {
            try conn.runMany(
                artworkUpsertSQL,
                artwork.map { bindings(for: $0) }
            )
        }
    }

    fileprivate static func applyMovieIntelligence(
        conn: SQLiteConnection,
        movieID: MovieID,
        voteCount: Int?,
        popularity: Double?,
        collectionID: Int?,
        collectionName: String?,
        keywords: [CatalogMovieKeyword],
        edges: [CatalogMovieEdge]
    ) throws {
        guard try conn.queryCount(
            "SELECT count(*) FROM movie WHERE id = ?",
            [.text(movieID.rawValue)]
        ) == 1 else {
            throw CatalogStoreError.notFound
        }
        for targetID in Set(edges.map(\.targetMovieID)) {
            guard try conn.queryCount(
                "SELECT count(*) FROM movie WHERE id = ?",
                [.text(targetID.rawValue)]
            ) == 1 else {
                throw CatalogStoreError.notFound
            }
        }

        try conn.run(
            """
            UPDATE movie
            SET vote_count = ?,
                popularity = ?,
                collection_id = ?,
                collection_name = ?
            WHERE id = ?
            """,
            [
                voteCount.map { .int($0) } ?? .null,
                popularity.map { .double($0) } ?? .null,
                collectionID.map { .int($0) } ?? .null,
                collectionName.map { .text($0) } ?? .null,
                .text(movieID.rawValue),
            ]
        )

        try conn.run(
            "DELETE FROM movie_keyword WHERE movie_id = ?",
            [.text(movieID.rawValue)]
        )
        if !keywords.isEmpty {
            try conn.runMany(
                """
                INSERT INTO movie_keyword (movie_id, keyword_id, name)
                VALUES (?,?,?)
                """,
                keywords.map { keyword in
                    [
                        .text(keyword.movieID.rawValue),
                        .int(keyword.keywordID),
                        .text(keyword.name),
                    ]
                }
            )
        }

        try conn.run(
            "DELETE FROM movie_edge WHERE source_movie_id = ?",
            [.text(movieID.rawValue)]
        )
        if !edges.isEmpty {
            try conn.runMany(
                """
                INSERT INTO movie_edge
                (source_movie_id, target_movie_id, edge_type, rank, score)
                VALUES (?,?,?,?,?)
                """,
                edges.map { edge in
                    [
                        .text(edge.sourceMovieID.rawValue),
                        .text(edge.targetMovieID.rawValue),
                        .text(edge.edgeType.rawValue),
                        .int(edge.rank),
                        edge.score.map { .double($0) } ?? .null,
                    ]
                }
            )
        }
    }

    private static func decodeTarget(type: String, id: String) -> WatchTarget {
        switch type {
        case "movie":   return .movie(MovieID(rawValue: id))
        case "episode": return .episode(EpisodeID(rawValue: id))
        default:
            assertionFailure("Unknown watch target_type in DB: \(type)")
            return .movie(MovieID(rawValue: id))
        }
    }
}
