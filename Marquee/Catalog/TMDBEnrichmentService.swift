//
//  TMDBEnrichmentService.swift
//  Marquee
//
//  Actor that optionally enriches catalog rows from TMDB.
//
//  See docs/ARCHITECTURE.md §"Catalog and library data flow" and
//  docs/ARCHITECTURE_DECISIONS.md ADR-003.
//
//  The actor depends on two narrow protocols (`TMDBMetadataFetching`
//  and `ArtworkDownloading`) declared in `EnrichmentProtocols.swift`
//  rather than the concrete singletons. Production callers continue to
//  use `TMDBService.shared` / `ImageCacheService.shared` via
//  default-valued init parameters; tests inject deterministic fakes.
//
//  `LibraryState` schedules the actor after eligible scans; targeted tests in
//  `VerifyEnrichmentActorHarness.swift` drive `enrichMissing()` directly.
//

import Foundation

actor TMDBEnrichmentService {

    public struct EnrichmentSummary: Sendable, Equatable {
        public var moviesEnriched: Int = 0
        public var showsEnriched: Int = 0
        public var seasonsEnriched: Int = 0
        public var episodesEnriched: Int = 0
        public var skipped: Int = 0
        public var failed: Int = 0
    }

    private let catalog: any CatalogStore
    private let tmdb: any TMDBMetadataFetching
    private let imageCache: any ArtworkDownloading

    init(
        catalog: any CatalogStore,
        tmdb: any TMDBMetadataFetching = TMDBService.shared,
        imageCache: any ArtworkDownloading = ImageCacheService.shared
    ) {
        self.catalog = catalog
        self.tmdb = tmdb
        self.imageCache = imageCache
    }

    // MARK: - Public surface

    /// One enrichment pass over every `media_file` row. Owners that
    /// pass `ownerNeedsEnrichment` are skipped. Show + season writes
    /// are guarded by per-pass sets so multi-episode shows do not
    /// re-enrich the show row N times.
    @discardableResult
    func enrichMissing() async throws -> EnrichmentSummary {
        var summary = EnrichmentSummary()
        let snapshot = try await catalog.enrichmentSnapshot()
        let files = try await catalog.allMediaFiles()

        var enrichedShowsThisPass: Set<ShowID> = []
        var enrichedSeasonsThisPass: Set<SeasonID> = []
        var showTMDBIDs: [ShowID: Int] = [:]
        var movieIDsByTMDB = Self.movieIDsByTMDB(from: snapshot.movies)
        var addedMovieTMDBIDs: Set<Int> = []
        var pendingMovieIntelligence: [PendingMovieIntelligence] = []

        for file in files {
            let fileURL = URL(fileURLWithPath: file.absolutePathSnapshot)
            let fileName = fileURL.lastPathComponent
            let seasonFolderNumber = CatalogContentPolicy.seasonNumberFromPath(fileURL)

            if let seasonNumber = seasonFolderNumber {
                let parsed: FilenameParser.ParsedEpisode? = {
                    if let ep = FilenameParser.parseEpisode(fileName) { return ep }
                    return FilenameParser.parseEpisodeFromFolder(
                        fileName,
                        seasonNumber: seasonNumber
                    )
                }()
                guard let ep = parsed else {
                    summary.skipped += 1
                    continue
                }

                let showFolder = fileURL
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                let folderInfo = CatalogContentPolicy.parseShowFolderName(showFolder)
                let showName: String = {
                    if let n = folderInfo?.name, !n.isEmpty { return n }
                    return ep.showName.isEmpty ? "Unknown Show" : ep.showName
                }()
                let showYear = folderInfo?.year ?? ep.year

                let showID = MediaIdentity.showID(title: showName, year: showYear)
                let seasonID = MediaIdentity.seasonID(
                    show: showID,
                    seasonNumber: ep.seasonNumber
                )
                let episodeID = MediaIdentity.episodeID(
                    season: seasonID,
                    episodeNumber: ep.episodeNumber,
                    primaryFile: file.id
                )

                let showResult = await enrichShowIfNeeded(
                    showID: showID,
                    showName: showName,
                    showYear: showYear,
                    snapshot: snapshot,
                    enrichedShowsThisPass: &enrichedShowsThisPass,
                    showTMDBIDs: &showTMDBIDs,
                    summary: &summary
                )
                guard showResult.continueProcessing else { continue }

                await enrichSeasonIfNeeded(
                    seasonID: seasonID,
                    showID: showID,
                    seasonNumber: ep.seasonNumber,
                    snapshot: snapshot,
                    enrichedSeasonsThisPass: &enrichedSeasonsThisPass,
                    summary: &summary
                )

                await enrichEpisodeIfNeeded(
                    file: file,
                    episodeID: episodeID,
                    seasonID: seasonID,
                    seasonNumber: ep.seasonNumber,
                    episodeNumber: ep.episodeNumber,
                    episodeTitle: ep.episodeTitle,
                    showTMDBID: showResult.tmdbID,
                    snapshot: snapshot,
                    summary: &summary
                )
            } else {
                let parsed = FilenameParser.parse(fileName)
                let movieID = MediaIdentity.movieID(primaryFile: file.id)
                let owner = ArtworkOwner.movie(movieID)
                if !Self.ownerNeedsEnrichment(owner, snapshot: snapshot) {
                    summary.skipped += 1
                    continue
                }
                let existingMovie = snapshot.movies[movieID]
                guard let m = await fetchMovieMetadata(
                    parsedTitle: parsed.title,
                    parsedYear: parsed.year,
                    existingMovie: existingMovie
                ) else {
                    summary.failed += 1
                    continue
                }
                let catalogTMDBID = existingMovie?.tmdbID ?? m.tmdbID
                await imageCache.downloadAndCacheImages(
                    tmdbID: catalogTMDBID,
                    posterPath: m.posterPath,
                    backdropPath: m.backdropPath,
                    forceRedownload: false
                )
                let core = CatalogMovie(
                    id: movieID,
                    primaryFile: file.id,
                    title: existingMovie?.title ?? parsed.title,
                    year: existingMovie?.year ?? parsed.year,
                    tmdbID: catalogTMDBID,
                    overview: m.overview,
                    runtimeMinutes: m.runtime,
                    certification: m.certification,
                    releaseDate: m.releaseDate,
                    genres: m.genres,
                    voteAverage: m.voteAverage,
                    director: m.director,
                    voteCount: m.voteCount,
                    popularity: m.popularity,
                    collectionID: m.collectionID,
                    collectionName: m.collectionName
                )
                let cast = makeCast(from: m.cast)
                let artwork = makePosterBackdropArtwork(
                    owner: owner,
                    tmdbID: catalogTMDBID,
                    posterPath: m.posterPath,
                    backdropPath: m.backdropPath
                )
                let keywords = makeKeywords(movieID: movieID, from: m.keywords)
                let edges = Self.makeMovieEdges(
                    source: movieID,
                    metadata: m,
                    movieIDsByTMDB: movieIDsByTMDB
                )
                do {
                    try await catalog.withTransaction { tx in
                        try await tx.replaceEnrichment(
                            owner: owner,
                            core: .movie(core),
                            cast: cast,
                            artwork: artwork
                        )
                        try await tx.replaceMovieIntelligence(
                            movieID: movieID,
                            voteCount: m.voteCount,
                            popularity: m.popularity,
                            collectionID: m.collectionID,
                            collectionName: m.collectionName,
                            keywords: keywords,
                            edges: edges
                        )
                    }
                    summary.moviesEnriched += 1
                    if Self.addMovieID(movieID, tmdbID: catalogTMDBID, to: &movieIDsByTMDB) {
                        addedMovieTMDBIDs.insert(catalogTMDBID)
                    }
                    pendingMovieIntelligence.append(
                        PendingMovieIntelligence(
                            movieID: movieID,
                            metadata: m,
                            keywords: keywords,
                            initialEdges: edges
                        )
                    )
                } catch {
                    summary.failed += 1
                }
            }
        }
        summary.failed += await reconcileMovieEdges(
            pending: pendingMovieIntelligence,
            movieIDsByTMDB: movieIDsByTMDB
        )
        summary.failed += await refreshExistingMovieIntelligenceAfterTMDBMapChange(
            snapshot: snapshot,
            movieIDsByTMDB: movieIDsByTMDB,
            skipMovieIDs: Set(pendingMovieIntelligence.map(\.movieID)),
            addedTMDBIDs: addedMovieTMDBIDs
        )
        return summary
    }

    // MARK: - Completeness predicate

    /// An owner is *not* enriched (returns `true`) when:
    ///  1. The matching slot in the snapshot is missing, OR
    ///  2. Any artwork_asset for that owner has a non-nil
    ///     `remoteURL` but a nil `localPath`.
    ///
    /// Documented on the spec: this is the gate that makes
    /// `enrichMissing` retry transient image-cache failures while
    /// leaving fully enriched owners alone (zero TMDB calls, zero
    /// catalog writes on subsequent passes).
    static func ownerNeedsEnrichment(
        _ owner: ArtworkOwner,
        snapshot: CatalogEnrichmentSnapshot
    ) -> Bool {
        let exists: Bool
        switch owner {
        case .movie(let id):   exists = snapshot.movies[id] != nil
        case .show(let id):    exists = snapshot.shows[id] != nil
        case .season(let id):  exists = snapshot.seasons[id] != nil
        case .episode(let id): exists = snapshot.episodes[id] != nil
        }
        if !exists { return true }
        if case .movie(let id) = owner, let movie = snapshot.movies[id] {
            if !Self.movieHasD2Intelligence(movie, movieID: id, snapshot: snapshot) {
                return true
            }
        }
        for asset in (snapshot.artworkByOwner[owner] ?? []) {
            if asset.remoteURL != nil && asset.localPath == nil {
                return true
            }
        }
        return false
    }

    private static func movieHasD2Intelligence(
        _ movie: CatalogMovie,
        movieID: MovieID,
        snapshot: CatalogEnrichmentSnapshot
    ) -> Bool {
        movie.voteCount != nil
            || movie.popularity != nil
            || movie.collectionID != nil
            || !(snapshot.movieKeywordsByMovie[movieID] ?? []).isEmpty
            || !(snapshot.movieEdgesBySource[movieID] ?? []).isEmpty
    }

    // MARK: - Per-step helpers

    private struct ShowResult {
        let continueProcessing: Bool
        let tmdbID: Int?
    }

    private struct PendingMovieIntelligence {
        let movieID: MovieID
        let metadata: TMDBMetadata
        let keywords: [CatalogMovieKeyword]
        let initialEdges: [CatalogMovieEdge]
    }

    private func fetchMovieMetadata(
        parsedTitle: String,
        parsedYear: Int?,
        existingMovie: CatalogMovie?
    ) async -> TMDBMetadata? {
        if let tmdbID = existingMovie?.tmdbID {
            return await tmdb.fetchMovieDetails(tmdbID: tmdbID)
        }
        return await tmdb.fetchMovieDetails(title: parsedTitle, year: parsedYear)
    }

    private func enrichShowIfNeeded(
        showID: ShowID,
        showName: String,
        showYear: Int?,
        snapshot: CatalogEnrichmentSnapshot,
        enrichedShowsThisPass: inout Set<ShowID>,
        showTMDBIDs: inout [ShowID: Int],
        summary: inout EnrichmentSummary
    ) async -> ShowResult {
        if enrichedShowsThisPass.contains(showID) {
            return ShowResult(continueProcessing: true, tmdbID: showTMDBIDs[showID])
        }
        let owner = ArtworkOwner.show(showID)
        if !Self.ownerNeedsEnrichment(owner, snapshot: snapshot) {
            // Already complete at snapshot start. Carry the existing
            // tmdbID forward so episode enrichment in the same pass
            // can reach `fetchSeasonEpisodes` without redoing the show
            // search. Mark in `enrichedShowsThisPass` so subsequent
            // episodes of the same show short-circuit here.
            enrichedShowsThisPass.insert(showID)
            let tmdbID = snapshot.shows[showID]?.tmdbID
            if let id = tmdbID { showTMDBIDs[showID] = id }
            return ShowResult(continueProcessing: true, tmdbID: tmdbID)
        }
        guard let s = await tmdb.fetchTVDetails(title: showName, year: showYear) else {
            summary.failed += 1
            return ShowResult(continueProcessing: false, tmdbID: nil)
        }
        await imageCache.downloadAndCacheImages(
            tmdbID: s.tmdbID,
            posterPath: s.posterPath,
            backdropPath: s.backdropPath,
            forceRedownload: false
        )
        let core = CatalogShow(
            id: showID,
            title: showName,
            year: showYear,
            tmdbID: s.tmdbID,
            overview: s.overview,
            certification: s.certification,
            genres: s.genres,
            releaseDate: s.releaseDate,
            runtimeMinutes: s.runtime,
            voteAverage: s.voteAverage,
            director: s.director
        )
        let cast = makeCast(from: s.cast)
        let artwork = makePosterBackdropArtwork(
            owner: owner,
            tmdbID: s.tmdbID,
            posterPath: s.posterPath,
            backdropPath: s.backdropPath
        )
        do {
            try await catalog.replaceEnrichment(
                owner: owner,
                core: .show(core),
                cast: cast,
                artwork: artwork
            )
            summary.showsEnriched += 1
            enrichedShowsThisPass.insert(showID)
            showTMDBIDs[showID] = s.tmdbID
            return ShowResult(continueProcessing: true, tmdbID: s.tmdbID)
        } catch {
            summary.failed += 1
            return ShowResult(continueProcessing: false, tmdbID: nil)
        }
    }

    private func enrichSeasonIfNeeded(
        seasonID: SeasonID,
        showID: ShowID,
        seasonNumber: Int,
        snapshot: CatalogEnrichmentSnapshot,
        enrichedSeasonsThisPass: inout Set<SeasonID>,
        summary: inout EnrichmentSummary
    ) async {
        if enrichedSeasonsThisPass.contains(seasonID) { return }
        let owner = ArtworkOwner.season(seasonID)
        if !Self.ownerNeedsEnrichment(owner, snapshot: snapshot) {
            enrichedSeasonsThisPass.insert(seasonID)
            return
        }
        let core = CatalogSeason(id: seasonID, showID: showID, seasonNumber: seasonNumber)
        do {
            try await catalog.replaceEnrichment(
                owner: owner,
                core: .season(core),
                cast: [],
                artwork: []
            )
            summary.seasonsEnriched += 1
            enrichedSeasonsThisPass.insert(seasonID)
        } catch {
            summary.failed += 1
        }
    }

    private func enrichEpisodeIfNeeded(
        file: CatalogMediaFile,
        episodeID: EpisodeID,
        seasonID: SeasonID,
        seasonNumber: Int,
        episodeNumber: Int,
        episodeTitle: String?,
        showTMDBID: Int?,
        snapshot: CatalogEnrichmentSnapshot,
        summary: inout EnrichmentSummary
    ) async {
        let owner = ArtworkOwner.episode(episodeID)
        if !Self.ownerNeedsEnrichment(owner, snapshot: snapshot) {
            summary.skipped += 1
            return
        }
        guard let tmdbShowID = showTMDBID else {
            summary.failed += 1
            return
        }
        let episodes = await tmdb.fetchSeasonEpisodes(
            tvID: tmdbShowID,
            seasonNumber: seasonNumber
        )
        guard let info = episodes.first(where: { $0.episodeNumber == episodeNumber }) else {
            summary.failed += 1
            return
        }
        var artwork: [CatalogArtworkAsset] = []
        if let stillPath = info.stillPath {
            // `downloadEpisodeStill` returns the *thumbnail* local
            // path (or nil on failure). The completeness predicate
            // only retries when remoteURL is non-nil and localPath is
            // nil — partial failures bubble through the next pass.
            let stillLocal = await imageCache.downloadEpisodeStill(
                tmdbID: tmdbShowID,
                seasonNumber: seasonNumber,
                episodeNumber: episodeNumber,
                stillPath: stillPath
            )
            artwork.append(CatalogArtworkAsset(
                id: MediaIdentity.artworkID(
                    owner: owner,
                    kind: .still,
                    sourceLabel: "tmdb"
                ),
                owner: owner,
                kind: .still,
                localPath: stillLocal,
                remoteURL: stillPath,
                sourceLabel: "tmdb"
            ))
        }
        let core = CatalogEpisode(
            id: episodeID,
            seasonID: seasonID,
            primaryFile: file.id,
            episodeNumber: episodeNumber,
            title: episodeTitle ?? info.name,
            overview: info.overview,
            runtimeMinutes: nil,
            tmdbID: info.id,
            certification: nil,
            releaseDate: info.airDate,
            voteAverage: info.voteAverage
        )
        do {
            try await catalog.replaceEnrichment(
                owner: owner,
                core: .episode(core),
                cast: [],
                artwork: artwork
            )
            summary.episodesEnriched += 1
        } catch {
            summary.failed += 1
        }
    }

    // MARK: - Builders

    /// Map TMDB cast entries → `CatalogCastEntry`. Drops entries with
    /// no TMDB person id (the relational schema requires it; legacy
    /// `LibraryCache` JSON without the field still decodes per
    /// `TMDBMetadata.CastEntry.tmdbPersonID`'s docs). Ordinals are
    /// re-numbered after the drop so the resulting array is dense.
    private func makeCast(
        from entries: [TMDBMetadata.CastEntry]
    ) -> [CatalogCastEntry] {
        var result: [CatalogCastEntry] = []
        result.reserveCapacity(entries.count)
        var ordinal = 0
        for entry in entries {
            guard let pid = entry.tmdbPersonID else { continue }
            result.append(CatalogCastEntry(
                personTMDBID: pid,
                name: entry.name,
                profilePath: entry.profilePath,
                character: entry.character,
                ordinal: ordinal
            ))
            ordinal += 1
        }
        return result
    }

    private func makeKeywords(
        movieID: MovieID,
        from entries: [TMDBMetadata.Keyword]
    ) -> [CatalogMovieKeyword] {
        entries.map {
            CatalogMovieKeyword(movieID: movieID, keywordID: $0.id, name: $0.name)
        }
    }

    private static func movieIDsByTMDB(
        from movies: [MovieID: CatalogMovie]
    ) -> [Int: [MovieID]] {
        var result: [Int: [MovieID]] = [:]
        for (movieID, movie) in movies {
            guard let tmdbID = movie.tmdbID else { continue }
            addMovieID(movieID, tmdbID: tmdbID, to: &result)
        }
        return result
    }

    @discardableResult
    private static func addMovieID(
        _ movieID: MovieID,
        tmdbID: Int,
        to map: inout [Int: [MovieID]]
    ) -> Bool {
        if map[tmdbID]?.contains(movieID) == true {
            return false
        }
        map[tmdbID, default: []].append(movieID)
        map[tmdbID]?.sort { $0.rawValue < $1.rawValue }
        return true
    }

    private static func makeMovieEdges(
        source: MovieID,
        metadata: TMDBMetadata,
        movieIDsByTMDB: [Int: [MovieID]]
    ) -> [CatalogMovieEdge] {
        var rows: [CatalogMovieEdge] = []
        var seen: Set<String> = []

        for edge in metadata.movieEdges {
            guard let tmdbTargetID = Int(edge.targetMovieID),
                  let edgeType = CatalogMovieEdgeType(rawValue: edge.edgeType)
            else { continue }
            let targets = movieIDsByTMDB[tmdbTargetID] ?? []
            for target in targets where target != source {
                let key = "\(target.rawValue)|\(edgeType.rawValue)"
                guard seen.insert(key).inserted else { continue }
                rows.append(CatalogMovieEdge(
                    sourceMovieID: source,
                    targetMovieID: target,
                    edgeType: edgeType,
                    rank: edge.rank,
                    score: edge.score
                ))
            }
        }

        return rows.sorted {
            if $0.edgeType == $1.edgeType {
                if $0.rank == $1.rank {
                    return $0.targetMovieID.rawValue < $1.targetMovieID.rawValue
                }
                return $0.rank < $1.rank
            }
            return $0.edgeType.rawValue < $1.edgeType.rawValue
        }
    }

    private func reconcileMovieEdges(
        pending: [PendingMovieIntelligence],
        movieIDsByTMDB: [Int: [MovieID]]
    ) async -> Int {
        var failures = 0
        for item in pending {
            let reconciledEdges = Self.makeMovieEdges(
                source: item.movieID,
                metadata: item.metadata,
                movieIDsByTMDB: movieIDsByTMDB
            )
            guard reconciledEdges != item.initialEdges else { continue }
            do {
                try await catalog.replaceMovieIntelligence(
                    movieID: item.movieID,
                    voteCount: item.metadata.voteCount,
                    popularity: item.metadata.popularity,
                    collectionID: item.metadata.collectionID,
                    collectionName: item.metadata.collectionName,
                    keywords: item.keywords,
                    edges: reconciledEdges
                )
            } catch {
                failures += 1
            }
        }
        return failures
    }

    private func refreshExistingMovieIntelligenceAfterTMDBMapChange(
        snapshot: CatalogEnrichmentSnapshot,
        movieIDsByTMDB: [Int: [MovieID]],
        skipMovieIDs: Set<MovieID>,
        addedTMDBIDs: Set<Int>
    ) async -> Int {
        guard !addedTMDBIDs.isEmpty else { return 0 }

        var failures = 0
        let candidates = snapshot.movies.values.sorted {
            if $0.title == $1.title {
                return $0.id.rawValue < $1.id.rawValue
            }
            return $0.title < $1.title
        }

        for movie in candidates {
            guard movie.tmdbID != nil,
                  !skipMovieIDs.contains(movie.id),
                  Self.movieHasD2Intelligence(movie, movieID: movie.id, snapshot: snapshot)
            else { continue }

            guard let tmdbID = movie.tmdbID,
                  let metadata = await tmdb.fetchMovieDetails(tmdbID: tmdbID) else {
                failures += 1
                continue
            }

            let keywords = makeKeywords(movieID: movie.id, from: metadata.keywords)
            let edges = Self.makeMovieEdges(
                source: movie.id,
                metadata: metadata,
                movieIDsByTMDB: movieIDsByTMDB
            )
            do {
                try await catalog.replaceMovieIntelligence(
                    movieID: movie.id,
                    voteCount: metadata.voteCount,
                    popularity: metadata.popularity,
                    collectionID: metadata.collectionID,
                    collectionName: metadata.collectionName,
                    keywords: keywords,
                    edges: edges
                )
            } catch {
                failures += 1
            }
        }
        return failures
    }

    /// Build the `[.poster, .backdrop]` artwork rows for a movie or
    /// show owner. `localPath` is the *thumbnail* path per the
    /// `ArtworkDownloading` cache contract — full-size paths are not
    /// tracked by `artwork_asset` in 2E.4b.
    private func makePosterBackdropArtwork(
        owner: ArtworkOwner,
        tmdbID: Int,
        posterPath: String?,
        backdropPath: String?
    ) -> [CatalogArtworkAsset] {
        var rows: [CatalogArtworkAsset] = []
        if let p = posterPath {
            rows.append(CatalogArtworkAsset(
                id: MediaIdentity.artworkID(
                    owner: owner,
                    kind: .poster,
                    sourceLabel: "tmdb"
                ),
                owner: owner,
                kind: .poster,
                localPath: imageCache.cachedThumbPosterPath(tmdbID: tmdbID),
                remoteURL: p,
                sourceLabel: "tmdb"
            ))
        }
        if let b = backdropPath {
            rows.append(CatalogArtworkAsset(
                id: MediaIdentity.artworkID(
                    owner: owner,
                    kind: .backdrop,
                    sourceLabel: "tmdb"
                ),
                owner: owner,
                kind: .backdrop,
                localPath: imageCache.cachedThumbBackdropPath(tmdbID: tmdbID),
                remoteURL: b,
                sourceLabel: "tmdb"
            ))
        }
        return rows
    }
}
