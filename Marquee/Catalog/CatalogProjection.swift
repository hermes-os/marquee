//
//  CatalogProjection.swift
//  Marquee
//
//  Projection layer. Reads `CatalogMediaFile` rows from the durable
//  catalog and produces the `MediaItem` shape the UI consumes.
//
//  The projection is authoritative for `libraryItems` / `tvItems`. The UI
//  restores a `ProjectedLibraryCache` for cold-start paint, hydrates from the
//  catalog at scan start, then re-projects after `DiffScanner` and optional
//  TMDB enrichment complete.
//
//  Scope of this layer:
//    - Read `CatalogMediaFile` rows via `CatalogStore.allMediaFiles()`.
//    - Resolve each row's current absolute path via `VolumeRegistry`,
//      falling back to `absolutePathSnapshot` if the volume is offline.
//    - Filter extras / featurettes / temp / sample folders according to the
//      current content policy. The catalog stores those rows because policy
//      can change without a rescan; projection enforces it on read.
//    - Run `FilenameParser` for title / year / season / episode.
//    - Walk sidecar artwork (poster.jpg, fanart.jpg, folder.jpg, plus
//      `<base> poster.jpg` / `<base>-poster.jpg` variants) for movie,
//      show-folder, and season-folder scopes.
//    - Infer genre from the first subfolder under the matching library
//      root, if it is in `CatalogContentPolicy.knownGenres`.
//    - Reuse `CatalogMediaFile.durationSeconds` when available without
//      probing media during projection.
//
//  Watch state is still keyed by absolute file path in
//  `WatchProgressStore` (per profile, JSON-backed). Projection emits
//  items with default watch state; `LibraryState.applyWatchProgress` (or
//  `attachWatchState(items:from:)` for non-LibraryState consumers) applies
//  it as a separate pass.
//

import Foundation

// MARK: - Protocol

/// Reads catalog rows and emits the legacy `MediaItem` array shape.
protocol CatalogProjection: AnyObject, Sendable {
    /// Project the entire catalog into `MediaItem` form. Sorted by
    /// case-insensitive title. Items are emitted with default watch
    /// state; apply `Self.attachWatchState(items:from:)` separately if
    /// a `WatchProgressStore` is available.
    func projectMediaItems() async throws -> [MediaItem]
}

// MARK: - Projected Library Cache

enum ProjectedLibraryCache {
    private static let version = 1

    private static var cacheURL: URL {
        Configuration.appSupportDirectory
            .appendingPathComponent("projected-library-cache.json")
    }

    private static var legacyMoviesURL: URL {
        Configuration.appSupportDirectory
            .appendingPathComponent("library-cache-movies.json")
    }

    private static var legacyTVURL: URL {
        Configuration.appSupportDirectory
            .appendingPathComponent("library-cache-tv.json")
    }

    struct RestoredLibrary {
        let movies: [MediaItem]
        let tvEpisodes: [MediaItem]
        let source: String
    }

    private struct Payload: Codable {
        let version: Int
        let generatedAt: Date
        let movies: [ItemSnapshot]
        let tvEpisodes: [ItemSnapshot]
    }

    private struct LegacyPayloadItem: Codable {
        let filePath: String
        let fileName: String
        let title: String
        let year: Int?
        let fileExtension: String
        let fileSize: Int64
        let duration: TimeInterval?
        let genre: String?
        let localGenres: [String]?
        let dateAdded: Date
        let fileModificationDate: Date?
        let showName: String?
        let seasonNumber: Int?
        let episodeNumber: Int?
        let episodeTitle: String?
        let contentRating: String?
        let tmdbID: Int?
        let metadata: TMDBMetadata?
        let posterImagePath: String?
        let backdropImagePath: String?
        let thumbPosterPath: String?
        let thumbBackdropPath: String?
        let showPosterPath: String?
        let showBackdropPath: String?
        let showThumbPosterPath: String?
        let showThumbBackdropPath: String?
        let seasonPosterPath: String?
        let seasonBackdropPath: String?
        let localEpisodeStillPath: String?

        func mediaItem() -> MediaItem {
            MediaItem(
                filePath: filePath,
                fileName: fileName,
                title: title,
                year: year,
                fileExtension: fileExtension,
                fileSize: fileSize,
                duration: duration,
                genre: genre,
                localGenres: localGenres ?? [],
                dateAdded: dateAdded,
                fileModificationDate: fileModificationDate,
                showName: showName,
                seasonNumber: seasonNumber,
                episodeNumber: episodeNumber,
                episodeTitle: episodeTitle,
                contentRating: contentRating,
                tmdbID: tmdbID,
                metadata: metadata,
                posterImagePath: posterImagePath,
                backdropImagePath: backdropImagePath,
                thumbPosterPath: thumbPosterPath,
                thumbBackdropPath: thumbBackdropPath,
                showPosterPath: showPosterPath,
                showBackdropPath: showBackdropPath,
                showThumbPosterPath: showThumbPosterPath,
                showThumbBackdropPath: showThumbBackdropPath,
                seasonPosterPath: seasonPosterPath,
                seasonBackdropPath: seasonBackdropPath,
                localEpisodeStillPath: localEpisodeStillPath
            )
        }
    }

    private struct ItemSnapshot: Codable {
        let filePath: String
        let fileName: String
        let title: String
        let year: Int?
        let fileExtension: String
        let fileSize: Int64
        let duration: TimeInterval?
        let genre: String?
        let localGenres: [String]
        let dateAdded: Date
        let fileModificationDate: Date?
        let showName: String?
        let seasonNumber: Int?
        let episodeNumber: Int?
        let episodeTitle: String?
        let contentRating: String?
        let tmdbID: Int?
        let metadata: TMDBMetadata?
        let posterImagePath: String?
        let backdropImagePath: String?
        let thumbPosterPath: String?
        let thumbBackdropPath: String?
        let showPosterPath: String?
        let showBackdropPath: String?
        let showThumbPosterPath: String?
        let showThumbBackdropPath: String?
        let seasonPosterPath: String?
        let seasonBackdropPath: String?
        let localEpisodeStillPath: String?

        init(_ item: MediaItem) {
            filePath = item.filePath
            fileName = item.fileName
            title = item.title
            year = item.year
            fileExtension = item.fileExtension
            fileSize = item.fileSize
            duration = item.duration
            genre = item.genre
            localGenres = item.localGenres
            dateAdded = item.dateAdded
            fileModificationDate = item.fileModificationDate
            showName = item.showName
            seasonNumber = item.seasonNumber
            episodeNumber = item.episodeNumber
            episodeTitle = item.isEpisode ? item.displayEpisodeTitle : nil
            contentRating = item.contentRating
            tmdbID = item.tmdbID
            metadata = item.metadata
            posterImagePath = item.posterImagePath
            backdropImagePath = item.backdropImagePath
            thumbPosterPath = item.thumbPosterPath
            thumbBackdropPath = item.thumbBackdropPath
            showPosterPath = item.showPosterPath
            showBackdropPath = item.showBackdropPath
            showThumbPosterPath = item.showThumbPosterPath
            showThumbBackdropPath = item.showThumbBackdropPath
            seasonPosterPath = item.seasonPosterPath
            seasonBackdropPath = item.seasonBackdropPath
            localEpisodeStillPath = item.localEpisodeStillPath
        }

        func mediaItem() -> MediaItem {
            MediaItem(
                filePath: filePath,
                fileName: fileName,
                title: title,
                year: year,
                fileExtension: fileExtension,
                fileSize: fileSize,
                duration: duration,
                genre: genre,
                localGenres: localGenres,
                dateAdded: dateAdded,
                fileModificationDate: fileModificationDate,
                showName: showName,
                seasonNumber: seasonNumber,
                episodeNumber: episodeNumber,
                episodeTitle: episodeTitle,
                contentRating: contentRating,
                tmdbID: tmdbID,
                metadata: metadata,
                posterImagePath: posterImagePath,
                backdropImagePath: backdropImagePath,
                thumbPosterPath: thumbPosterPath,
                thumbBackdropPath: thumbBackdropPath,
                showPosterPath: showPosterPath,
                showBackdropPath: showBackdropPath,
                showThumbPosterPath: showThumbPosterPath,
                showThumbBackdropPath: showThumbBackdropPath,
                seasonPosterPath: seasonPosterPath,
                seasonBackdropPath: seasonBackdropPath,
                localEpisodeStillPath: localEpisodeStillPath
            )
        }
    }

    static func load() -> RestoredLibrary? {
        if let restored = loadProjectedCache() {
            return restored
        }
        return loadLegacyCaches()
    }

    static func save(movies: [MediaItem], tvEpisodes: [MediaItem]) {
        let payload = Payload(
            version: version,
            generatedAt: Date(),
            movies: movies.map(ItemSnapshot.init),
            tvEpisodes: tvEpisodes.map(ItemSnapshot.init)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(
                at: Configuration.appSupportDirectory,
                withIntermediateDirectories: true
            )
            try encoder.encode(payload).write(to: cacheURL, options: .atomic)
        } catch {
            MarqueeLogger.scanner.error(
                "projected library cache save failed: \(String(describing: error), privacy: .public)"
            )
        }
    }

    private static func loadProjectedCache() -> RestoredLibrary? {
        do {
            let data = try Data(contentsOf: cacheURL)
            let payload = try JSONDecoder().decode(Payload.self, from: data)
            guard payload.version == version else { return nil }
            return RestoredLibrary(
                movies: payload.movies.map { $0.mediaItem() },
                tvEpisodes: payload.tvEpisodes.map { $0.mediaItem() },
                source: cacheURL.lastPathComponent
            )
        } catch {
            return nil
        }
    }

    private static func loadLegacyCaches() -> RestoredLibrary? {
        do {
            let moviesData = try Data(contentsOf: legacyMoviesURL)
            let tvData = try Data(contentsOf: legacyTVURL)
            let decoder = JSONDecoder()
            let movies = try decoder.decode([LegacyPayloadItem].self, from: moviesData)
            let tvEpisodes = try decoder.decode([LegacyPayloadItem].self, from: tvData)
            guard !movies.isEmpty || !tvEpisodes.isEmpty else { return nil }
            return RestoredLibrary(
                movies: movies.map { $0.mediaItem() },
                tvEpisodes: tvEpisodes.map { $0.mediaItem() },
                source: "legacy library cache"
            )
        } catch {
            return nil
        }
    }
}

// MARK: - Watch-state attachment

extension CatalogProjection {

    /// Mirror of `LibraryState.applyWatchProgress`. Kept as a free function
    /// on the protocol so any consumer of `[MediaItem]` from the
    /// projection can apply watch state without coupling to LibraryState.
    /// `WatchProgressStore` is keyed by absolute `filePath`, so the
    /// caller must hand items whose `filePath` matches the path the
    /// store recorded against.
    internal static func attachWatchState(
        items: [MediaItem],
        from store: WatchProgressStore
    ) {
        for item in items {
            if let entry = store.progress(for: item.filePath) {
                item.playbackPosition = entry.position
                item.lastPlayedDate = entry.lastPlayed
                item.isWatched = false
            } else if let completed = store.completedProgress(for: item.filePath) {
                item.playbackPosition = 0
                item.lastPlayedDate = completed.lastPlayed
                item.isWatched = true
            } else {
                item.playbackPosition = 0
                item.lastPlayedDate = nil
                item.isWatched = false
            }
        }
    }
}

// MARK: - Default implementation

/// Production implementation. Constructed once per scan-library pass.
actor DefaultCatalogProjection: CatalogProjection {

    private let catalog: any CatalogStore
    private let volumes: any VolumeRegistry
    private let libraryRoots: [String]

    init(
        catalog: any CatalogStore,
        volumes: any VolumeRegistry,
        libraryRoots: [String]
    ) {
        self.catalog = catalog
        self.volumes = volumes
        // Roots are kept verbatim. `NSString.standardizingPath` would
        // strip a `/private/` prefix (e.g. realpath-resolved temp dirs
        // and certain NAS mounts), which silently breaks
        // `matchingLibraryRoot` when a row's resolved absolute path
        // retains that prefix. Production NSOpenPanel paths are
        // already canonical, so passing them through unchanged is a
        // no-op in the common case and a correctness fix in the
        // edge case.
        self.libraryRoots = libraryRoots
    }

    func projectMediaItems() async throws -> [MediaItem] {
        let rows = try await catalog.allMediaFiles()
        // Single bulk read of catalog enrichment keyed by owner id. The
        // projection then hash-joins each row's identity-derived owner
        // against the snapshot to graft TMDB metadata + downloaded
        // artwork onto the emitted `MediaItem`. When a row has no
        // matching snapshot entry (catalog populated but enrichment
        // pass has not yet run for that file), we fall back to
        // filename-derived defaults so the UI sees a usable item.
        let snapshot = try await catalog.enrichmentSnapshot()
        var items: [MediaItem] = []
        items.reserveCapacity(rows.count)

        for row in rows {
            let absolutePath = await resolveAbsolutePath(for: row)

            // Library-root scope. The catalog is durable across config
            // changes, so it can hold rows from library roots the user
            // has since removed (or from legacy imports that predate
            // the current settings). Projection's job is to represent
            // the *currently configured* library. Rows that do not resolve
            // under any configured root are dropped so stale imports or
            // removed roots cannot reappear in the UI.
            guard let libraryRoot = matchingLibraryRoot(for: absolutePath) else {
                continue
            }

            // Folder-policy filter. Catalog stores extras rows because
            // the policy can change without a rescan; projection
            // enforces it on read so the UI never sees them.
            if CatalogContentPolicy.pathContainsExcludedFolder(absolutePath) { continue }
            if CatalogContentPolicy.fileNameLooksLikeExtraFromPath(absolutePath) { continue }

            let fileURL = URL(fileURLWithPath: absolutePath)
            let fileName = fileURL.lastPathComponent
            let ext = (fileURL.pathExtension as NSString).lowercased

            let sidecar = CatalogContentPolicy.findSidecarImages(for: fileURL)
            let genre = CatalogContentPolicy.inferGenre(
                for: fileURL,
                rootDirectory: URL(fileURLWithPath: libraryRoot)
            )

            let seasonFolderNumber = CatalogContentPolicy.seasonNumberFromPath(fileURL)
            let parsedEpisode: FilenameParser.ParsedEpisode? = {
                if let ep = FilenameParser.parseEpisode(fileName) { return ep }
                if let sn = seasonFolderNumber {
                    return FilenameParser.parseEpisodeFromFolder(
                        fileName,
                        seasonNumber: sn
                    )
                }
                return nil
            }()

            let item: MediaItem
            if seasonFolderNumber != nil, let episode = parsedEpisode {
                let rootURL = URL(fileURLWithPath: libraryRoot)
                let showFolder = CatalogContentPolicy.showFolderURL(
                    for: fileURL,
                    rootDirectory: rootURL
                )
                let showSidecar = CatalogContentPolicy.findShowSidecarImages(for: showFolder)
                let seasonFolder = fileURL.deletingLastPathComponent()
                let seasonSidecar = CatalogContentPolicy.findSeasonSidecarImages(for: seasonFolder)
                let episodeStillSidecar = CatalogContentPolicy.findEpisodeStillSidecar(for: fileURL)
                let showFolderName = CatalogContentPolicy.parseShowFolderName(showFolder)

                let resolvedShowName: String = {
                    if let folderName = showFolderName?.name, !folderName.isEmpty {
                        return folderName
                    }
                    if !episode.showName.isEmpty { return episode.showName }
                    return "Unknown Show"
                }()
                let resolvedYear = showFolderName?.year ?? episode.year

                // Identity derivation mirrors `TMDBEnrichmentService`.
                // Both sides hash the same `(title, year)` and the same
                // `(season, episode, file)` so the projection's lookup
                // key is byte-equal to whatever the actor wrote.
                let showID = MediaIdentity.showID(
                    title: resolvedShowName,
                    year: resolvedYear
                )
                let seasonID = MediaIdentity.seasonID(
                    show: showID,
                    seasonNumber: episode.seasonNumber
                )
                let episodeID = MediaIdentity.episodeID(
                    season: seasonID,
                    episodeNumber: episode.episodeNumber,
                    primaryFile: row.id
                )
                let catShow = snapshot.shows[showID]
                let catEpisode = snapshot.episodes[episodeID]
                let showCast = snapshot.castByOwner[.show(showID)] ?? []
                let showArtwork = snapshot.artworkByOwner[.show(showID)] ?? []
                let episodeArtwork = snapshot.artworkByOwner[.episode(episodeID)] ?? []

                let showTMDBPoster = showArtwork.first {
                    $0.kind == .poster && $0.sourceLabel == "tmdb"
                }?.localPath
                let showTMDBBackdrop = showArtwork.first {
                    $0.kind == .backdrop && $0.sourceLabel == "tmdb"
                }?.localPath
                let episodeStill = episodeArtwork.first {
                    $0.kind == .still && $0.sourceLabel == "tmdb"
                }?.localPath

                let displayShowName = catShow?.title ?? resolvedShowName
                let displayYear = catShow?.year ?? resolvedYear
                let displayEpisodeTitle = episode.episodeTitle ?? catEpisode?.title
                let localGenres = CatalogContentPolicy.localGenres(
                    folderGenre: genre,
                    offlineTitleGenres: CatalogContentPolicy.inferOfflineTVGenres(
                        forShowTitle: displayShowName
                    )
                )
                let metadata = catShow.flatMap {
                    Self.makeShowMetadata(
                        show: $0,
                        cast: showCast,
                        artwork: showArtwork
                    )
                }
                let contentRating = catShow?.certification

                item = MediaItem(
                    filePath: absolutePath,
                    fileName: fileName,
                    title: displayShowName,
                    year: displayYear,
                    fileExtension: ext,
                    fileSize: row.fileSize,
                    duration: row.durationSeconds,
                    genre: localGenres.first ?? genre,
                    localGenres: localGenres,
                    dateAdded: row.dateAdded,
                    fileModificationDate: row.modificationDate,
                    showName: displayShowName,
                    seasonNumber: episode.seasonNumber,
                    episodeNumber: episode.episodeNumber,
                    episodeTitle: displayEpisodeTitle,
                    contentRating: contentRating,
                    tmdbID: catShow?.tmdbID,
                    metadata: metadata,
                    posterImagePath: sidecar.posterPath,
                    backdropImagePath: sidecar.backdropPath,
                    thumbPosterPath: nil,
                    thumbBackdropPath: episodeStill,
                    showPosterPath: showSidecar.posterPath,
                    showBackdropPath: showSidecar.backdropPath,
                    showThumbPosterPath: showTMDBPoster,
                    showThumbBackdropPath: showTMDBBackdrop,
                    seasonPosterPath: seasonSidecar.posterPath,
                    seasonBackdropPath: seasonSidecar.backdropPath,
                    localEpisodeStillPath: episodeStillSidecar
                )
            } else if seasonFolderNumber != nil {
                // Inside a season folder but the filename did not parse
                // as an episode. Legacy scanner drops these silently;
                // matching that behavior keeps parity.
                continue
            } else {
                let parsed = FilenameParser.parse(fileName)
                let movieID = MediaIdentity.movieID(primaryFile: row.id)
                let catMovie = snapshot.movies[movieID]
                let catCast = snapshot.castByOwner[.movie(movieID)] ?? []
                let catArtwork = snapshot.artworkByOwner[.movie(movieID)] ?? []
                let catKeywords = snapshot.movieKeywordsByMovie[movieID] ?? []
                let catEdges = snapshot.movieEdgesBySource[movieID] ?? []

                let tmdbPoster = catArtwork.first {
                    $0.kind == .poster && $0.sourceLabel == "tmdb"
                }?.localPath
                let tmdbBackdrop = catArtwork.first {
                    $0.kind == .backdrop && $0.sourceLabel == "tmdb"
                }?.localPath

                let displayTitle = catMovie?.title ?? parsed.title
                let displayYear = catMovie?.year ?? parsed.year
                let localGenres = CatalogContentPolicy.localMovieGenres(
                    folderGenre: genre,
                    movieTitle: displayTitle
                )
                let metadata = catMovie.flatMap {
                    Self.makeMovieMetadata(
                        movie: $0,
                        cast: catCast,
                        artwork: catArtwork,
                        keywords: catKeywords,
                        edges: catEdges
                    )
                }

                item = MediaItem(
                    filePath: absolutePath,
                    fileName: fileName,
                    title: displayTitle,
                    year: displayYear,
                    fileExtension: ext,
                    fileSize: row.fileSize,
                    duration: row.durationSeconds,
                    genre: localGenres.first ?? genre,
                    localGenres: localGenres,
                    dateAdded: row.dateAdded,
                    fileModificationDate: row.modificationDate,
                    contentRating: catMovie?.certification,
                    tmdbID: catMovie?.tmdbID,
                    metadata: metadata,
                    posterImagePath: sidecar.posterPath,
                    backdropImagePath: sidecar.backdropPath,
                    thumbPosterPath: tmdbPoster,
                    thumbBackdropPath: tmdbBackdrop
                )
            }
            items.append(item)
        }

        return items.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    // MARK: - Metadata reconstruction

    /// Reconstruct a `TMDBMetadata` value for a movie row from its
    /// catalog enrichment. Returns `nil` when the movie row has no
    /// `tmdbID` — `TMDBMetadata.tmdbID` is non-optional, and an
    /// enrichment row without a TMDB id has nothing meaningful to
    /// surface as metadata.
    static func makeMovieMetadata(
        movie: CatalogMovie,
        cast: [CatalogCastEntry],
        artwork: [CatalogArtworkAsset],
        keywords: [CatalogMovieKeyword] = [],
        edges: [CatalogMovieEdge] = []
    ) -> TMDBMetadata? {
        guard let tmdbID = movie.tmdbID else { return nil }
        let entries = cast
            .sorted { $0.ordinal < $1.ordinal }
            .map {
                TMDBMetadata.CastEntry(
                    name: $0.name,
                    character: $0.character,
                    profilePath: $0.profilePath,
                    tmdbPersonID: $0.personTMDBID
                )
            }
        let posterRemote = artwork.first {
            $0.kind == .poster && $0.sourceLabel == "tmdb"
        }?.remoteURL
        let backdropRemote = artwork.first {
            $0.kind == .backdrop && $0.sourceLabel == "tmdb"
        }?.remoteURL
        return TMDBMetadata(
            tmdbID: tmdbID,
            overview: movie.overview,
            genres: movie.genres,
            cast: entries,
            director: movie.director,
            certification: movie.certification,
            voteAverage: movie.voteAverage,
            voteCount: movie.voteCount,
            popularity: movie.popularity,
            collectionID: movie.collectionID,
            collectionName: movie.collectionName,
            keywords: keywords.map {
                TMDBMetadata.Keyword(id: $0.keywordID, name: $0.name)
            },
            movieEdges: edges.map {
                TMDBMetadata.MovieEdge(
                    targetMovieID: $0.targetMovieID.rawValue,
                    edgeType: $0.edgeType.rawValue,
                    rank: $0.rank,
                    score: $0.score
                )
            },
            posterPath: posterRemote,
            backdropPath: backdropRemote,
            releaseDate: movie.releaseDate,
            runtime: movie.runtimeMinutes
        )
    }

    /// Reconstruct a `TMDBMetadata` value for a TV episode row from
    /// the show-level enrichment. The episode row's own metadata
    /// (`releaseDate`, `voteAverage`, `tmdbID`) lives on
    /// `CatalogEpisode` and is consumed elsewhere; this helper
    /// surfaces *show* metadata on the episode's `MediaItem`, which is what
    /// `ShowDetailView` reads. Show cast is surfaced here; per-episode guest
    /// cast is not currently modeled.
    static func makeShowMetadata(
        show: CatalogShow,
        cast: [CatalogCastEntry],
        artwork: [CatalogArtworkAsset]
    ) -> TMDBMetadata? {
        guard let tmdbID = show.tmdbID else { return nil }
        let entries = cast
            .sorted { $0.ordinal < $1.ordinal }
            .map {
                TMDBMetadata.CastEntry(
                    name: $0.name,
                    character: $0.character,
                    profilePath: $0.profilePath,
                    tmdbPersonID: $0.personTMDBID
                )
            }
        let posterRemote = artwork.first {
            $0.kind == .poster && $0.sourceLabel == "tmdb"
        }?.remoteURL
        let backdropRemote = artwork.first {
            $0.kind == .backdrop && $0.sourceLabel == "tmdb"
        }?.remoteURL
        return TMDBMetadata(
            tmdbID: tmdbID,
            overview: show.overview,
            genres: show.genres,
            cast: entries,
            director: show.director,
            certification: show.certification,
            voteAverage: show.voteAverage,
            posterPath: posterRemote,
            backdropPath: backdropRemote,
            releaseDate: show.releaseDate,
            runtime: show.runtimeMinutes
        )
    }

    // MARK: - Path resolution

    /// Resolve a row to a current absolute path. Prefers the live
    /// `mountPath + relativePath` from the volume registry so a remount
    /// at a different path still produces a working item; falls back to
    /// `absolutePathSnapshot` only when the volume is offline.
    private func resolveAbsolutePath(for row: CatalogMediaFile) async -> String {
        if let descriptor = await volumes.volume(byUUID: row.volumeUUID) {
            let mount = descriptor.mountPath
            if mount == "/" {
                return "/" + row.relativePath
            }
            return mount + "/" + row.relativePath
        }
        return row.absolutePathSnapshot
    }

    /// Find the configured library root that contains `absolutePath`,
    /// preferring the deepest match. Returns `nil` if no root covers
    /// the path — in which case genre inference is skipped.
    private func matchingLibraryRoot(for absolutePath: String) -> String? {
        var best: String?
        var bestLen = -1
        for root in libraryRoots {
            if absolutePath == root || absolutePath.hasPrefix(root + "/") {
                if root.count > bestLen {
                    best = root
                    bestLen = root.count
                }
            }
        }
        return best
    }

}
