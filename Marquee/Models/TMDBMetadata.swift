import Foundation

// MARK: - TMDB Metadata

struct TMDBMetadata: Codable {
    let tmdbID: Int
    let overview: String?
    let genres: [String]
    let cast: [CastEntry]
    let director: String?
    let certification: String?
    let voteAverage: Double?
    let voteCount: Int?
    let popularity: Double?
    let collectionID: Int?
    let collectionName: String?
    let keywords: [Keyword]
    let movieEdges: [MovieEdge]
    let posterPath: String?
    let backdropPath: String?
    let releaseDate: String?
    let runtime: Int?

    struct CastEntry: Codable {
        let name: String
        let character: String
        let profilePath: String?
        /// TMDB person id, when the parser found one. Optional so old
        /// `LibraryCache` JSON snapshots written before Phase 2E.4b
        /// still decode — those payloads predate the field. Re-scans
        /// fill it in. Cast entries without a TMDB id are dropped on
        /// the way into the catalog (the relational `person`/
        /// `cast_member` schema requires the id) — the field stays
        /// optional only for JSON back-compat, not as a long-term shape.
        let tmdbPersonID: Int?
    }

    struct Keyword: Codable, Hashable {
        let id: Int
        let name: String
    }

    struct MovieEdge: Codable, Hashable {
        /// TMDB fetches carry the target TMDB id as a decimal string.
        /// Catalog projection carries the resolved local MovieID raw value.
        let targetMovieID: String
        let edgeType: String
        let rank: Int
        let score: Double?
    }

    init(
        tmdbID: Int,
        overview: String?,
        genres: [String],
        cast: [CastEntry],
        director: String?,
        certification: String?,
        voteAverage: Double?,
        voteCount: Int? = nil,
        popularity: Double? = nil,
        collectionID: Int? = nil,
        collectionName: String? = nil,
        keywords: [Keyword] = [],
        movieEdges: [MovieEdge] = [],
        posterPath: String?,
        backdropPath: String?,
        releaseDate: String?,
        runtime: Int?
    ) {
        self.tmdbID = tmdbID
        self.overview = overview
        self.genres = genres
        self.cast = cast
        self.director = director
        self.certification = certification
        self.voteAverage = voteAverage
        self.voteCount = voteCount
        self.popularity = popularity
        self.collectionID = collectionID
        self.collectionName = collectionName
        self.keywords = keywords
        self.movieEdges = movieEdges
        self.posterPath = posterPath
        self.backdropPath = backdropPath
        self.releaseDate = releaseDate
        self.runtime = runtime
    }

    private enum CodingKeys: String, CodingKey {
        case tmdbID
        case overview
        case genres
        case cast
        case director
        case certification
        case voteAverage
        case voteCount
        case popularity
        case collectionID
        case collectionName
        case keywords
        case movieEdges
        case posterPath
        case backdropPath
        case releaseDate
        case runtime
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tmdbID = try c.decode(Int.self, forKey: .tmdbID)
        overview = try c.decodeIfPresent(String.self, forKey: .overview)
        genres = try c.decodeIfPresent([String].self, forKey: .genres) ?? []
        cast = try c.decodeIfPresent([CastEntry].self, forKey: .cast) ?? []
        director = try c.decodeIfPresent(String.self, forKey: .director)
        certification = try c.decodeIfPresent(String.self, forKey: .certification)
        voteAverage = try c.decodeIfPresent(Double.self, forKey: .voteAverage)
        voteCount = try c.decodeIfPresent(Int.self, forKey: .voteCount)
        popularity = try c.decodeIfPresent(Double.self, forKey: .popularity)
        collectionID = try c.decodeIfPresent(Int.self, forKey: .collectionID)
        collectionName = try c.decodeIfPresent(String.self, forKey: .collectionName)
        keywords = try c.decodeIfPresent([Keyword].self, forKey: .keywords) ?? []
        movieEdges = try c.decodeIfPresent([MovieEdge].self, forKey: .movieEdges) ?? []
        posterPath = try c.decodeIfPresent(String.self, forKey: .posterPath)
        backdropPath = try c.decodeIfPresent(String.self, forKey: .backdropPath)
        releaseDate = try c.decodeIfPresent(String.self, forKey: .releaseDate)
        runtime = try c.decodeIfPresent(Int.self, forKey: .runtime)
    }
}
