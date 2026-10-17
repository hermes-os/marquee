//
//  CatalogTypes.swift
//  Marquee
//
//  Durable schema-v4 catalog domain model.
//  See docs/ARCHITECTURE.md §"Catalog and library data flow" and
//  docs/ARCHITECTURE_DECISIONS.md ADR-002.
//
//  These value types are the canonical catalog model. Runtime projections
//  bridge them into the remaining MediaItem compatibility surfaces.
//

import Foundation

// MARK: - Strongly typed entity IDs (ADR-002)

/// Wraps a `String` so the compiler can prevent cross-entity ID confusion
/// (e.g., passing a `MovieID` where a `ShowID` is expected). All IDs are
/// derived from stable identity functions (see ADR-002) and are
/// deterministic across runs and machines.
public protocol CatalogID: Hashable, Codable, Sendable, RawRepresentable
where RawValue == String {}

public struct MovieID: CatalogID {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct ShowID: CatalogID {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct SeasonID: CatalogID {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct EpisodeID: CatalogID {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct MediaFileID: CatalogID {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct ArtworkAssetID: CatalogID {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct ProfileID: CatalogID {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct WatchStateID: CatalogID {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct ScanJobID: CatalogID {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct ScanEventID: CatalogID {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

// MARK: - Domain entities

/// A physical media file on disk, identified by a stable
/// `(volumeUUID, relativePath)` hash. See ADR-002 and `MediaIdentity`.
public struct CatalogMediaFile: Hashable, Codable, Sendable {
    public let id: MediaFileID
    public let volumeUUID: String
    public let relativePath: String
    public let absolutePathSnapshot: String
    public let fileExtension: String
    public let fileSize: Int64
    public let modificationDate: Date?
    public let durationSeconds: TimeInterval?
    /// Reserved for Phase 2 cross-volume reconciliation. Nil until lazily
    /// computed.
    public let contentHash: String?
    public let dateAdded: Date

    public init(
        id: MediaFileID,
        volumeUUID: String,
        relativePath: String,
        absolutePathSnapshot: String,
        fileExtension: String,
        fileSize: Int64,
        modificationDate: Date?,
        durationSeconds: TimeInterval?,
        contentHash: String?,
        dateAdded: Date
    ) {
        self.id = id
        self.volumeUUID = volumeUUID
        self.relativePath = relativePath
        self.absolutePathSnapshot = absolutePathSnapshot
        self.fileExtension = fileExtension
        self.fileSize = fileSize
        self.modificationDate = modificationDate
        self.durationSeconds = durationSeconds
        self.contentHash = contentHash
        self.dateAdded = dateAdded
    }
}

public struct CatalogMovie: Hashable, Codable, Sendable {
    public let id: MovieID
    public let primaryFile: MediaFileID
    public let title: String
    public let year: Int?
    public let tmdbID: Int?
    public let overview: String?
    public let runtimeMinutes: Int?
    public let certification: String?
    public let releaseDate: String?
    public let genres: [String]
    public let voteAverage: Double?
    public let director: String?
    public let voteCount: Int?
    public let popularity: Double?
    public let collectionID: Int?
    public let collectionName: String?

    public init(
        id: MovieID,
        primaryFile: MediaFileID,
        title: String,
        year: Int?,
        tmdbID: Int?,
        overview: String?,
        runtimeMinutes: Int?,
        certification: String?,
        releaseDate: String?,
        genres: [String],
        voteAverage: Double?,
        director: String?,
        voteCount: Int? = nil,
        popularity: Double? = nil,
        collectionID: Int? = nil,
        collectionName: String? = nil
    ) {
        self.id = id
        self.primaryFile = primaryFile
        self.title = title
        self.year = year
        self.tmdbID = tmdbID
        self.overview = overview
        self.runtimeMinutes = runtimeMinutes
        self.certification = certification
        self.releaseDate = releaseDate
        self.genres = genres
        self.voteAverage = voteAverage
        self.director = director
        self.voteCount = voteCount
        self.popularity = popularity
        self.collectionID = collectionID
        self.collectionName = collectionName
    }
}

public struct CatalogShow: Hashable, Codable, Sendable {
    public let id: ShowID
    public let title: String
    public let year: Int?
    public let tmdbID: Int?
    public let overview: String?
    public let certification: String?
    public let genres: [String]
    public let releaseDate: String?
    public let runtimeMinutes: Int?
    public let voteAverage: Double?
    public let director: String?

    public init(
        id: ShowID,
        title: String,
        year: Int?,
        tmdbID: Int?,
        overview: String?,
        certification: String?,
        genres: [String],
        releaseDate: String? = nil,
        runtimeMinutes: Int? = nil,
        voteAverage: Double? = nil,
        director: String? = nil
    ) {
        self.id = id
        self.title = title
        self.year = year
        self.tmdbID = tmdbID
        self.overview = overview
        self.certification = certification
        self.genres = genres
        self.releaseDate = releaseDate
        self.runtimeMinutes = runtimeMinutes
        self.voteAverage = voteAverage
        self.director = director
    }
}

public struct CatalogSeason: Hashable, Codable, Sendable {
    public let id: SeasonID
    public let showID: ShowID
    public let seasonNumber: Int

    public init(id: SeasonID, showID: ShowID, seasonNumber: Int) {
        self.id = id
        self.showID = showID
        self.seasonNumber = seasonNumber
    }
}

public struct CatalogEpisode: Hashable, Codable, Sendable {
    public let id: EpisodeID
    public let seasonID: SeasonID
    public let primaryFile: MediaFileID
    public let episodeNumber: Int
    public let title: String?
    public let overview: String?
    public let runtimeMinutes: Int?
    public let tmdbID: Int?
    public let certification: String?
    public let releaseDate: String?
    public let voteAverage: Double?

    public init(
        id: EpisodeID,
        seasonID: SeasonID,
        primaryFile: MediaFileID,
        episodeNumber: Int,
        title: String?,
        overview: String?,
        runtimeMinutes: Int?,
        tmdbID: Int? = nil,
        certification: String? = nil,
        releaseDate: String? = nil,
        voteAverage: Double? = nil
    ) {
        self.id = id
        self.seasonID = seasonID
        self.primaryFile = primaryFile
        self.episodeNumber = episodeNumber
        self.title = title
        self.overview = overview
        self.runtimeMinutes = runtimeMinutes
        self.tmdbID = tmdbID
        self.certification = certification
        self.releaseDate = releaseDate
        self.voteAverage = voteAverage
    }
}

public enum ArtworkKind: String, Codable, Sendable, Hashable {
    case poster
    case backdrop
    case thumbPoster
    case thumbBackdrop
    case logo
    case still
}

public enum ArtworkOwner: Hashable, Codable, Sendable {
    case movie(MovieID)
    case show(ShowID)
    case season(SeasonID)
    case episode(EpisodeID)
}

public struct CatalogArtworkAsset: Hashable, Codable, Sendable {
    public let id: ArtworkAssetID
    public let owner: ArtworkOwner
    public let kind: ArtworkKind
    public let localPath: String?
    public let remoteURL: String?
    public let sourceLabel: String

    public init(
        id: ArtworkAssetID,
        owner: ArtworkOwner,
        kind: ArtworkKind,
        localPath: String?,
        remoteURL: String?,
        sourceLabel: String
    ) {
        self.id = id
        self.owner = owner
        self.kind = kind
        self.localPath = localPath
        self.remoteURL = remoteURL
        self.sourceLabel = sourceLabel
    }
}

public enum WatchTarget: Hashable, Codable, Sendable {
    case movie(MovieID)
    case episode(EpisodeID)
}

public struct CatalogWatchState: Hashable, Codable, Sendable {
    public let id: WatchStateID
    public let profile: ProfileID
    public let target: WatchTarget
    public let positionSeconds: TimeInterval
    public let durationSeconds: TimeInterval?
    public let completed: Bool
    public let lastWatched: Date

    public init(
        id: WatchStateID,
        profile: ProfileID,
        target: WatchTarget,
        positionSeconds: TimeInterval,
        durationSeconds: TimeInterval?,
        completed: Bool,
        lastWatched: Date
    ) {
        self.id = id
        self.profile = profile
        self.target = target
        self.positionSeconds = positionSeconds
        self.durationSeconds = durationSeconds
        self.completed = completed
        self.lastWatched = lastWatched
    }
}

public enum ProfileKind: String, Codable, Sendable, Hashable {
    case adult
    case kid
}

public struct CatalogProfile: Hashable, Codable, Sendable {
    public let id: ProfileID
    public let displayName: String
    public let kind: ProfileKind
    public let maxCertification: String?
    public let createdAt: Date

    public init(
        id: ProfileID,
        displayName: String,
        kind: ProfileKind,
        maxCertification: String?,
        createdAt: Date
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.maxCertification = maxCertification
        self.createdAt = createdAt
    }
}

// MARK: - Scan jobs and events (Phase 2)

/// Lifecycle of a scan invocation. State transitions are linear:
/// `queued → running → (completed | failed | cancelled)`. The store
/// rejects any transition the scanner does not explicitly request — the
/// state field is never inferred from timestamps.
public enum ScanJobState: String, Codable, Sendable, Hashable {
    case queued
    case running
    case completed
    case failed
    case cancelled
}

/// A single scan invocation against one library root. The roadmap
/// requires scanner runs to be queued, observable, and resumable, so
/// every scan tick reads the latest `CatalogScanJob` row and writes its
/// progress counters back inside the same `withTransaction` block as
/// the catalog mutations it produced. Counters reflect what the
/// importer/scanner actually wrote on disk, not what the walk *saw* —
/// `filesObserved` is the only "saw it" counter.
public struct CatalogScanJob: Hashable, Codable, Sendable {
    public let id: ScanJobID
    public let rootPath: String
    public let volumeUUID: String
    public let state: ScanJobState
    public let createdAt: Date
    public let startedAt: Date?
    public let completedAt: Date?
    public let lastErrorMessage: String?
    public let filesObserved: Int
    public let filesAdded: Int
    public let filesUpdated: Int
    public let filesRemoved: Int

    public init(
        id: ScanJobID,
        rootPath: String,
        volumeUUID: String,
        state: ScanJobState,
        createdAt: Date,
        startedAt: Date?,
        completedAt: Date?,
        lastErrorMessage: String?,
        filesObserved: Int,
        filesAdded: Int,
        filesUpdated: Int,
        filesRemoved: Int
    ) {
        self.id = id
        self.rootPath = rootPath
        self.volumeUUID = volumeUUID
        self.state = state
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.lastErrorMessage = lastErrorMessage
        self.filesObserved = filesObserved
        self.filesAdded = filesAdded
        self.filesUpdated = filesUpdated
        self.filesRemoved = filesRemoved
    }
}

/// Categorisation of a `CatalogScanEvent`. Events are append-only audit
/// records, not control flow — the scanner does not read them back to
/// resume work. Their purpose is post-hoc reconciliation: a human or
/// follow-up tooling looks at `failed`, `volumeMissing`, `pathNotInRoot`
/// etc. to decide what to do next.
public enum ScanEventKind: String, Codable, Sendable, Hashable {
    case started
    case completed
    case failed
    case cancelled
    case fileSeen
    case fileAdded
    case fileUpdated
    case fileRemoved
    case fileSkipped
    case fileFailed
    case volumeMissing
    case pathNotInRoot
}

public struct CatalogScanEvent: Hashable, Codable, Sendable {
    public let id: ScanEventID
    public let jobID: ScanJobID
    public let kind: ScanEventKind
    public let timestamp: Date
    public let path: String?
    public let detail: String?

    public init(
        id: ScanEventID,
        jobID: ScanJobID,
        kind: ScanEventKind,
        timestamp: Date,
        path: String?,
        detail: String?
    ) {
        self.id = id
        self.jobID = jobID
        self.kind = kind
        self.timestamp = timestamp
        self.path = path
        self.detail = detail
    }
}

// MARK: - Enrichment composite (Phase 2E.4b)
//
// `replaceEnrichment(owner:core:cast:artwork:)` and the matching
// `enrichmentSnapshot()` shape used by the projection. See
// docs/ARCHITECTURE.md §"Catalog and library data flow".

/// Per-owner core row delivered to `replaceEnrichment`. Exactly one
/// `case` is valid for any given `ArtworkOwner`; mismatches are
/// rejected with `CatalogStoreError.ownerCoreMismatch` *before* the
/// transaction opens.
public enum CatalogEnrichmentCore: Sendable {
    case movie(CatalogMovie)
    case show(CatalogShow)
    case season(CatalogSeason)
    case episode(CatalogEpisode)
}

/// One denormalised `(person, cast_member)` row. The TMDB person id is
/// the durable key — `name`/`profilePath` are carried denormalised so
/// the projection's hash-join stays in memory and avoids SQL joins.
public struct CatalogCastEntry: Hashable, Codable, Sendable {
    public let personTMDBID: Int
    public let name: String
    public let profilePath: String?
    public let character: String
    public let ordinal: Int

    public init(
        personTMDBID: Int,
        name: String,
        profilePath: String?,
        character: String,
        ordinal: Int
    ) {
        self.personTMDBID = personTMDBID
        self.name = name
        self.profilePath = profilePath
        self.character = character
        self.ordinal = ordinal
    }
}

public struct CatalogMovieKeyword: Hashable, Codable, Sendable {
    public let movieID: MovieID
    public let keywordID: Int
    public let name: String

    public init(movieID: MovieID, keywordID: Int, name: String) {
        self.movieID = movieID
        self.keywordID = keywordID
        self.name = name
    }
}

public enum CatalogMovieEdgeType: String, Codable, Sendable, Hashable {
    case similar
    case recommendation
}

public struct CatalogMovieEdge: Hashable, Codable, Sendable {
    public let sourceMovieID: MovieID
    public let targetMovieID: MovieID
    public let edgeType: CatalogMovieEdgeType
    public let rank: Int
    public let score: Double?

    public init(
        sourceMovieID: MovieID,
        targetMovieID: MovieID,
        edgeType: CatalogMovieEdgeType,
        rank: Int,
        score: Double? = nil
    ) {
        self.sourceMovieID = sourceMovieID
        self.targetMovieID = targetMovieID
        self.edgeType = edgeType
        self.rank = rank
        self.score = score
    }
}

public struct CatalogMovieIntelligenceCoverageRow: Hashable, Codable, Sendable {
    public let movieID: MovieID
    public let title: String
    public let tmdbID: Int?
    public let keywordCount: Int
    public let collectionID: Int?
    public let collectionName: String?
    public let edgeCount: Int

    public init(
        movieID: MovieID,
        title: String,
        tmdbID: Int?,
        keywordCount: Int,
        collectionID: Int?,
        collectionName: String?,
        edgeCount: Int
    ) {
        self.movieID = movieID
        self.title = title
        self.tmdbID = tmdbID
        self.keywordCount = keywordCount
        self.collectionID = collectionID
        self.collectionName = collectionName
        self.edgeCount = edgeCount
    }
}

public struct CatalogMovieIntelligenceCoverageReport: Hashable, Codable, Sendable {
    public let rows: [CatalogMovieIntelligenceCoverageRow]

    public init(rows: [CatalogMovieIntelligenceCoverageRow]) {
        self.rows = rows
    }

    public var movieCount: Int { rows.count }
    public var moviesWithKeywords: Int { rows.filter { $0.keywordCount > 0 }.count }
    public var moviesWithCollection: Int { rows.filter { $0.collectionID != nil }.count }
    public var moviesWithEdges: Int { rows.filter { $0.edgeCount > 0 }.count }
    public var totalKeywords: Int { rows.reduce(0) { $0 + $1.keywordCount } }
    public var totalEdges: Int { rows.reduce(0) { $0 + $1.edgeCount } }
}

/// Bulk-snapshot read for `DefaultCatalogProjection`. Single read tx
/// against the catalog produces this; the projection then merges
/// matching rows onto its `MediaItem` output keyed by `MovieID` /
/// `ShowID` / `SeasonID` / `EpisodeID`.
public struct CatalogEnrichmentSnapshot: Sendable {
    public let movies: [MovieID: CatalogMovie]
    public let shows: [ShowID: CatalogShow]
    public let seasons: [SeasonID: CatalogSeason]
    public let episodes: [EpisodeID: CatalogEpisode]
    public let artworkByOwner: [ArtworkOwner: [CatalogArtworkAsset]]
    public let castByOwner: [ArtworkOwner: [CatalogCastEntry]]
    public let movieKeywordsByMovie: [MovieID: [CatalogMovieKeyword]]
    public let movieEdgesBySource: [MovieID: [CatalogMovieEdge]]

    public init(
        movies: [MovieID: CatalogMovie],
        shows: [ShowID: CatalogShow],
        seasons: [SeasonID: CatalogSeason],
        episodes: [EpisodeID: CatalogEpisode],
        artworkByOwner: [ArtworkOwner: [CatalogArtworkAsset]],
        castByOwner: [ArtworkOwner: [CatalogCastEntry]],
        movieKeywordsByMovie: [MovieID: [CatalogMovieKeyword]] = [:],
        movieEdgesBySource: [MovieID: [CatalogMovieEdge]] = [:]
    ) {
        self.movies = movies
        self.shows = shows
        self.seasons = seasons
        self.episodes = episodes
        self.artworkByOwner = artworkByOwner
        self.castByOwner = castByOwner
        self.movieKeywordsByMovie = movieKeywordsByMovie
        self.movieEdgesBySource = movieEdgesBySource
    }

    public static let empty = CatalogEnrichmentSnapshot(
        movies: [:],
        shows: [:],
        seasons: [:],
        episodes: [:],
        artworkByOwner: [:],
        castByOwner: [:],
        movieKeywordsByMovie: [:],
        movieEdgesBySource: [:]
    )
}

/// Shared pre-transaction validation for `replaceEnrichment`. Both
/// `SQLiteCatalogStore` and `InMemoryCatalogStore` call this *before*
/// taking the write gate so all-or-nothing semantics are honoured at
/// the API boundary, not inside the transaction body.
public enum CatalogEnrichmentValidator {

    public static func validate(
        owner: ArtworkOwner,
        core: CatalogEnrichmentCore,
        artwork: [CatalogArtworkAsset]
    ) throws {
        // 1. Owner / core case + id match.
        switch (owner, core) {
        case let (.movie(id), .movie(m)):
            guard m.id == id else {
                throw CatalogStoreError.ownerCoreMismatch(
                    "movie id mismatch: owner=\(id.rawValue) core=\(m.id.rawValue)"
                )
            }
        case let (.show(id), .show(s)):
            guard s.id == id else {
                throw CatalogStoreError.ownerCoreMismatch(
                    "show id mismatch: owner=\(id.rawValue) core=\(s.id.rawValue)"
                )
            }
        case let (.season(id), .season(sn)):
            guard sn.id == id else {
                throw CatalogStoreError.ownerCoreMismatch(
                    "season id mismatch: owner=\(id.rawValue) core=\(sn.id.rawValue)"
                )
            }
        case let (.episode(id), .episode(e)):
            guard e.id == id else {
                throw CatalogStoreError.ownerCoreMismatch(
                    "episode id mismatch: owner=\(id.rawValue) core=\(e.id.rawValue)"
                )
            }
        default:
            throw CatalogStoreError.ownerCoreMismatch(
                "owner/core case mismatch: \(ownerLabel(owner)) vs \(coreLabel(core))"
            )
        }

        // 2 + 3. Every artwork row must match owner AND be tmdb-sourced.
        for row in artwork {
            guard row.owner == owner else {
                throw CatalogStoreError.ownerCoreMismatch(
                    "artwork owner mismatch: row=\(ownerLabel(row.owner)) call=\(ownerLabel(owner))"
                )
            }
            guard row.sourceLabel == "tmdb" else {
                throw CatalogStoreError.ownerCoreMismatch(
                    "artwork sourceLabel must be 'tmdb' (was '\(row.sourceLabel)')"
                )
            }
        }
    }

    private static func ownerLabel(_ o: ArtworkOwner) -> String {
        switch o {
        case .movie(let id):   return "movie/\(id.rawValue)"
        case .show(let id):    return "show/\(id.rawValue)"
        case .season(let id):  return "season/\(id.rawValue)"
        case .episode(let id): return "episode/\(id.rawValue)"
        }
    }

    private static func coreLabel(_ c: CatalogEnrichmentCore) -> String {
        switch c {
        case .movie:   return "movie"
        case .show:    return "show"
        case .season:  return "season"
        case .episode: return "episode"
        }
    }
}
