//
//  LegacyJSONImporter.swift
//  Marquee
//
//  One-way migration reader for retired `LibraryCache` JSON files
//  (`library-cache-movies.json`, `library-cache-tv.json`) and upsert the
//  records into a `CatalogStore`.
//
//  Idempotent by construction: every entity is keyed by deterministic IDs
//  derived from `MediaIdentity`, so re-running the importer over the same
//  source files produces no duplicates.
//
//  This importer does not mutate legacy JSON. The SQLite catalog remains the
//  runtime authority before, during, and after import.
//

import Foundation

/// JSON shape of the retired `LibraryCache` files. The cache itself was
/// removed in Phase 2E.4d (d.3), but the importer keeps this struct so a
/// user upgrading from a pre-2E.4d build can still migrate any legacy
/// JSON sitting in their Application Support directory into the catalog.
struct CachedMediaItem: Codable {
    let filePath: String
    let fileName: String
    let title: String
    let year: Int?
    let fileExtension: String
    let fileSize: Int64
    let duration: TimeInterval?
    let genre: String?
    let dateAdded: Date
    let fileModificationDate: Date?
    let showName: String?
    let seasonNumber: Int?
    let episodeNumber: Int?
    let episodeTitle: String?
    let contentRating: String?

    let tmdbID: Int?
    let overview: String?
    let genres: [String]?
    let cast: [TMDBMetadata.CastEntry]?
    let director: String?
    let certification: String?
    let voteAverage: Double?
    let releaseDate: String?
    let tmdbRuntime: Int?

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
}

public struct LegacyJSONImporter {

    /// The volume UUID we attribute imported files to. The legacy cache
    /// only stored absolute paths and did not track volume identity, so
    /// we synthesize a stable label for imported rows. Normal scanner rows use
    /// the real mounted-volume UUID.
    public let attributedVolumeUUID: String

    public init(attributedVolumeUUID: String = "legacy-import-v1") {
        self.attributedVolumeUUID = attributedVolumeUUID
    }

    public struct ImportSummary: Equatable, Sendable, Codable {
        public var moviesRead: Int = 0
        public var tvRead: Int = 0
        public var mediaFilesWritten: Int = 0
        public var moviesWritten: Int = 0
        public var showsWritten: Int = 0
        public var seasonsWritten: Int = 0
        public var episodesWritten: Int = 0
        public var artworkWritten: Int = 0
    }

    /// Reads `library-cache-movies.json` and `library-cache-tv.json` from
    /// the given directory and upserts records into `store`.
    /// Missing files are skipped silently. Returns counts for diagnostics.
    ///
    /// Implementation:
    ///   1. Decode JSON outside the transaction (potentially slow I/O).
    ///   2. Build the entity batches in memory (no actor hops).
    ///   3. Open one `withTransaction` and write all batches atomically.
    /// If any single batch fails, the entire import rolls back so the
    /// catalog never observes a half-imported library.
    public func importLibraryCache(
        from cacheDirectory: URL,
        into store: CatalogStore
    ) async throws -> ImportSummary {
        var summary = ImportSummary()

        let moviesURL = cacheDirectory.appendingPathComponent("library-cache-movies.json")
        let tvURL     = cacheDirectory.appendingPathComponent("library-cache-tv.json")

        let movieEntries = try decodeIfPresent(moviesURL) ?? []
        let tvEntries    = try decodeIfPresent(tvURL) ?? []
        summary.moviesRead = movieEntries.count
        summary.tvRead     = tvEntries.count

        if movieEntries.isEmpty && tvEntries.isEmpty {
            return summary
        }

        let batches = buildBatches(
            movieEntries: movieEntries,
            tvEntries: tvEntries,
            summary: &summary
        )

        try await store.withTransaction { tx in
            try await tx.upsert(mediaFiles: batches.mediaFiles)
            try await tx.upsert(movies:     batches.movies)
            try await tx.upsert(shows:      batches.shows)
            try await tx.upsert(seasons:    batches.seasons)
            try await tx.upsert(episodes:   batches.episodes)
            try await tx.upsert(artwork:    batches.artwork)
        }

        return summary
    }

    // MARK: - Batch builder

    private struct Batches {
        var mediaFiles: [CatalogMediaFile] = []
        var movies: [CatalogMovie] = []
        var shows: [CatalogShow] = []
        var seasons: [CatalogSeason] = []
        var episodes: [CatalogEpisode] = []
        var artwork: [CatalogArtworkAsset] = []
    }

    /// Builds entity batches and updates `summary` counts in lock-step
    /// with the original importer (one increment per upsert attempt,
    /// matching the existing `VerifyImportHarness` expectations even
    /// though the catalog dedupes by primary key).
    private func buildBatches(
        movieEntries: [CachedMediaItem],
        tvEntries: [CachedMediaItem],
        summary: inout ImportSummary
    ) -> Batches {
        var batches = Batches()

        for entry in movieEntries {
            let file = makeMediaFile(from: entry)
            batches.mediaFiles.append(file)
            summary.mediaFilesWritten += 1

            let movieID = MediaIdentity.movieID(primaryFile: file.id)
            batches.movies.append(CatalogMovie(
                id: movieID,
                primaryFile: file.id,
                title: entry.title,
                year: entry.year,
                tmdbID: entry.tmdbID,
                overview: entry.overview,
                runtimeMinutes: entry.tmdbRuntime,
                certification: entry.certification ?? entry.contentRating,
                releaseDate: entry.releaseDate,
                genres: entry.genres ?? (entry.genre.map { [$0] } ?? []),
                voteAverage: entry.voteAverage,
                director: entry.director
            ))
            summary.moviesWritten += 1

            appendArtwork(
                into: &batches,
                owner: .movie(movieID),
                poster: entry.posterImagePath,
                backdrop: entry.backdropImagePath,
                thumbPoster: entry.thumbPosterPath,
                thumbBackdrop: entry.thumbBackdropPath,
                summary: &summary
            )
        }

        for entry in tvEntries {
            let file = makeMediaFile(from: entry)
            batches.mediaFiles.append(file)
            summary.mediaFilesWritten += 1

            let showTitle = entry.showName ?? entry.title
            let showID = MediaIdentity.showID(title: showTitle, year: entry.year)
            batches.shows.append(CatalogShow(
                id: showID,
                title: showTitle,
                year: entry.year,
                tmdbID: entry.tmdbID,
                overview: entry.overview,
                certification: entry.certification ?? entry.contentRating,
                genres: entry.genres ?? (entry.genre.map { [$0] } ?? [])
            ))
            summary.showsWritten += 1

            let seasonNumber = entry.seasonNumber ?? 0
            let seasonID = MediaIdentity.seasonID(show: showID, seasonNumber: seasonNumber)
            batches.seasons.append(CatalogSeason(
                id: seasonID,
                showID: showID,
                seasonNumber: seasonNumber
            ))
            summary.seasonsWritten += 1

            if let episodeNumber = entry.episodeNumber {
                let episodeID = MediaIdentity.episodeID(
                    season: seasonID,
                    episodeNumber: episodeNumber,
                    primaryFile: file.id
                )
                batches.episodes.append(CatalogEpisode(
                    id: episodeID,
                    seasonID: seasonID,
                    primaryFile: file.id,
                    episodeNumber: episodeNumber,
                    title: entry.episodeTitle,
                    overview: entry.overview,
                    runtimeMinutes: entry.tmdbRuntime
                ))
                summary.episodesWritten += 1
            }

            appendArtwork(
                into: &batches,
                owner: .show(showID),
                poster: entry.showPosterPath,
                backdrop: entry.showBackdropPath,
                thumbPoster: entry.showThumbPosterPath,
                thumbBackdrop: entry.showThumbBackdropPath,
                summary: &summary
            )
            appendArtwork(
                into: &batches,
                owner: .season(seasonID),
                poster: entry.seasonPosterPath,
                backdrop: entry.seasonBackdropPath,
                thumbPoster: nil,
                thumbBackdrop: nil,
                summary: &summary
            )
        }

        return batches
    }

    private func appendArtwork(
        into batches: inout Batches,
        owner: ArtworkOwner,
        poster: String?,
        backdrop: String?,
        thumbPoster: String?,
        thumbBackdrop: String?,
        summary: inout ImportSummary
    ) {
        let pairs: [(ArtworkKind, String?)] = [
            (.poster, poster),
            (.backdrop, backdrop),
            (.thumbPoster, thumbPoster),
            (.thumbBackdrop, thumbBackdrop),
        ]
        for (kind, path) in pairs {
            guard let path = path, !path.isEmpty else { continue }
            let id = MediaIdentity.artworkID(
                owner: owner,
                kind: kind,
                sourceLabel: "legacy-cache"
            )
            batches.artwork.append(CatalogArtworkAsset(
                id: id,
                owner: owner,
                kind: kind,
                localPath: path,
                remoteURL: nil,
                sourceLabel: "legacy-cache"
            ))
            summary.artworkWritten += 1
        }
    }

    // MARK: - Building a CatalogMediaFile from a legacy entry

    private func makeMediaFile(from entry: CachedMediaItem) -> CatalogMediaFile {
        let relativePath = relativePathForLegacyImport(absolute: entry.filePath)
        let id = MediaIdentity.mediaFileID(
            volumeUUID: attributedVolumeUUID,
            relativePath: relativePath
        )
        return CatalogMediaFile(
            id: id,
            volumeUUID: attributedVolumeUUID,
            relativePath: relativePath,
            absolutePathSnapshot: entry.filePath,
            fileExtension: entry.fileExtension,
            fileSize: entry.fileSize,
            modificationDate: entry.fileModificationDate,
            durationSeconds: entry.duration,
            contentHash: nil,
            dateAdded: entry.dateAdded
        )
    }

    /// Legacy entries store absolute paths only. We synthesize a stable
    /// "relative" path by stripping the leading slash. The result is
    /// stable for the same absolute path, which is what the identity
    /// function requires.
    private func relativePathForLegacyImport(absolute: String) -> String {
        MediaIdentity.normalizeRelativePath(absolute)
    }

    // MARK: - JSON I/O

    private func decodeIfPresent(_ url: URL) throws -> [CachedMediaItem]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return nil }
        let decoder = JSONDecoder()
        return try decoder.decode([CachedMediaItem].self, from: data)
    }
}
