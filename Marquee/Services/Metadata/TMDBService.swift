import Foundation

// MARK: - TMDB Service

actor TMDBService {

    static let shared = TMDBService()

    private let apiKey = Configuration.tmdbAPIKey
    private let baseURL = Configuration.tmdbBaseURL
    private let session = URLSession.shared

    private var detailsCache: [String: TMDBMetadata] = [:]
    private var seasonCache: [String: [EpisodeInfo]] = [:]
    private var persistentIDCache: [String: Int] = [:]
    private let idCacheURL = Configuration.appSupportDirectory.appendingPathComponent("tmdb-id-cache.json")
    private var pendingIDCacheSave: Task<Void, Never>?

    private init() {
        persistentIDCache = Self.loadPersistentIDCache(from: idCacheURL)
    }

    // MARK: - Persistent ID Cache

    private static func loadPersistentIDCache(from url: URL) -> [String: Int] {
        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: Int].self, from: data) else { return [:] }
        return dict
    }

    private func savePersistentIDCache() {
        guard let data = try? JSONEncoder().encode(persistentIDCache) else { return }
        try? data.write(to: idCacheURL, options: .atomic)
    }

    private func scheduleSaveIDCache() {
        pendingIDCacheSave?.cancel()
        pendingIDCacheSave = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 2_000_000_000)
            } catch {
                return
            }
            await self?.savePersistentIDCache()
        }
    }

    // MARK: - URL Building

    private func buildURL(path: String, queryItems: [URLQueryItem]) -> URL? {
        var components = URLComponents(string: baseURL + path)
        components?.queryItems = queryItems + [URLQueryItem(name: "api_key", value: apiKey)]
        return components?.url
    }

    private func fetchData(from url: URL, context: String) async -> Data? {
        guard let (data, response) = try? await session.data(from: url) else {
            MarqueeLogger.network.error("Network request failed for \(context)")
            return nil
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            switch http.statusCode {
            case 401:
                MarqueeLogger.network.error("TMDB auth failed (401), check API key, for \(context)")
            case 429:
                MarqueeLogger.network.error("TMDB rate limited (429) for \(context)")
            default:
                MarqueeLogger.network.error("TMDB HTTP \(http.statusCode) for \(context)")
            }
            return nil
        }
        return data
    }

    // MARK: - Full Movie Details

    func fetchMovieDetails(title: String, year: Int?) async -> TMDBMetadata? {
        guard UserSettings.shared.onlineMetadataEnabled else { return nil }

        let cacheKey = "details:\(title)|\(year ?? 0)"
        if let cached = detailsCache[cacheKey] {
            return cached
        }

        guard let movieID = await searchMovie(title: title, year: year) else { return nil }

        return await fetchMovieDetails(movieID: movieID, cacheKey: cacheKey)
    }

    func fetchMovieDetails(tmdbID movieID: Int) async -> TMDBMetadata? {
        guard UserSettings.shared.onlineMetadataEnabled else { return nil }

        let cacheKey = "details-id:\(movieID)"
        if let cached = detailsCache[cacheKey] {
            return cached
        }

        return await fetchMovieDetails(movieID: movieID, cacheKey: cacheKey)
    }

    private func fetchMovieDetails(movieID: Int, cacheKey: String) async -> TMDBMetadata? {
        guard let url = buildURL(
            path: "/movie/\(movieID)",
            queryItems: [
                URLQueryItem(
                    name: "append_to_response",
                    value: "credits,release_dates,keywords,similar,recommendations"
                )
            ]
        ) else {
            MarqueeLogger.network.error("Failed to build URL for movie details: \(movieID)")
            return nil
        }

        guard let data = await fetchData(from: url, context: "movie details: \(movieID)") else {
            return nil
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            MarqueeLogger.network.error("Failed to parse JSON for movie details: \(movieID)")
            return nil
        }

        let metadata = parseMovieJSON(json, movieID: movieID)
        detailsCache[cacheKey] = metadata
        return metadata
    }

    // MARK: - Full TV Details

    func fetchTVDetails(title: String, year: Int?) async -> TMDBMetadata? {
        guard UserSettings.shared.onlineMetadataEnabled else { return nil }

        let cacheKey = "tv-details:\(title)|\(year ?? 0)"
        if let cached = detailsCache[cacheKey] {
            return cached
        }

        guard let tvID = await searchTV(title: title, year: year) else { return nil }

        guard let url = buildURL(
            path: "/tv/\(tvID)",
            queryItems: [URLQueryItem(name: "append_to_response", value: "credits,content_ratings")]
        ) else {
            MarqueeLogger.network.error("Failed to build URL for TV details: \(tvID)")
            return nil
        }

        guard let data = await fetchData(from: url, context: "TV details: \(tvID)") else {
            return nil
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            MarqueeLogger.network.error("Failed to parse JSON for TV details: \(tvID)")
            return nil
        }

        let metadata = parseTVJSON(json, tvID: tvID)
        detailsCache[cacheKey] = metadata
        return metadata
    }

    // MARK: - Search Movie

    private func searchMovie(title: String, year: Int?) async -> Int? {
        let persistKey = "movie:\(normalize(title))|\(year ?? 0)"
        if let cachedID = persistentIDCache[persistKey] {
            return cachedID
        }

        var queryItems = [URLQueryItem(name: "query", value: title)]
        if let year = year {
            queryItems.append(URLQueryItem(name: "year", value: "\(year)"))
        }

        guard let url = buildURL(path: "/search/movie", queryItems: queryItems) else {
            MarqueeLogger.network.error("Failed to build search URL for movie: \(title)")
            return nil
        }

        guard let data = await fetchData(from: url, context: "movie search: \(title)") else {
            return nil
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else {
            MarqueeLogger.network.info("No TMDB results for movie: \(title)")
            return nil
        }

        guard let match = bestMatch(in: results, for: title, titleKey: "title", year: year, dateKey: "release_date") else {
            MarqueeLogger.network.info("No matching TMDB result for movie: \(title)")
            return nil
        }

        persistentIDCache[persistKey] = match
        scheduleSaveIDCache()
        return match
    }

    // MARK: - Search TV

    private func searchTV(title: String, year: Int?) async -> Int? {
        let persistKey = "tv:\(normalize(title))|\(year ?? 0)"
        if let cachedID = persistentIDCache[persistKey] {
            return cachedID
        }

        var queryItems = [URLQueryItem(name: "query", value: title)]
        if let year = year {
            queryItems.append(URLQueryItem(name: "first_air_date_year", value: "\(year)"))
        }

        guard let url = buildURL(path: "/search/tv", queryItems: queryItems) else {
            MarqueeLogger.network.error("Failed to build search URL for TV: \(title)")
            return nil
        }

        guard let data = await fetchData(from: url, context: "TV search: \(title)") else {
            return nil
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else {
            MarqueeLogger.network.info("No TMDB results for TV show: \(title)")
            return nil
        }

        guard let match = bestMatch(in: results, for: title, titleKey: "name", year: year, dateKey: "first_air_date") else {
            MarqueeLogger.network.info("No matching TMDB result for TV show: \(title)")
            return nil
        }

        persistentIDCache[persistKey] = match
        scheduleSaveIDCache()
        return match
    }

    // MARK: - Title Matching

    private func bestMatch(in results: [[String: Any]], for query: String, titleKey: String, year: Int?, dateKey: String) -> Int? {
        let queryNorm = normalize(query)
        let queryWords = Set(queryNorm.split(separator: " ").map(String.init))

        for result in results {
            guard let id = result["id"] as? Int,
                  let resultTitle = result[titleKey] as? String else { continue }
            if normalize(resultTitle) == queryNorm {
                return id
            }
        }

        for result in results {
            guard let id = result["id"] as? Int,
                  let resultTitle = result[titleKey] as? String else { continue }
            let resultWords = Set(normalize(resultTitle).split(separator: " ").map(String.init))
            if !queryWords.isEmpty, queryWords.isSubset(of: resultWords) {
                return id
            }
        }

        if let first = results.first, let id = first["id"] as? Int,
           let resultTitle = first[titleKey] as? String {
            let similarity = titleSimilarity(normalize(resultTitle), queryNorm)
            if similarity > 0.5 {
                return id
            }
            MarqueeLogger.network.info("Rejected TMDB match '\(resultTitle)' for query '\(query)' (similarity: \(String(format: "%.2f", similarity)))")
        }

        return nil
    }

    private func normalize(_ title: String) -> String {
        title.lowercased()
            .replacingOccurrences(of: #"^(the|a|an)\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "&", with: "and")
            .replacingOccurrences(of: #"[^\w\s]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private func titleSimilarity(_ a: String, _ b: String) -> Double {
        let aWords = Set(a.split(separator: " ").map(String.init))
        let bWords = Set(b.split(separator: " ").map(String.init))
        guard !aWords.isEmpty || !bWords.isEmpty else { return 0 }
        let intersection = aWords.intersection(bWords).count
        let union = aWords.union(bWords).count
        return Double(intersection) / Double(union)
    }

    // MARK: - JSON Parsing

    private func parseMovieJSON(_ json: [String: Any], movieID: Int) -> TMDBMetadata {
        let overview = json["overview"] as? String
        let voteAverage = json["vote_average"] as? Double
        let voteCount = json["vote_count"] as? Int
        let popularity = json["popularity"] as? Double
        let posterPath = json["poster_path"] as? String
        let backdropPath = json["backdrop_path"] as? String
        let releaseDate = json["release_date"] as? String
        let runtime = json["runtime"] as? Int
        let collection = json["belongs_to_collection"] as? [String: Any]
        let collectionID = collection?["id"] as? Int
        let collectionName = collection?["name"] as? String

        var genres: [String] = []
        if let genreArray = json["genres"] as? [[String: Any]] {
            genres = genreArray.compactMap { $0["name"] as? String }
        }

        var cast: [TMDBMetadata.CastEntry] = []
        var director: String?
        if let credits = json["credits"] as? [String: Any] {
            if let castArray = credits["cast"] as? [[String: Any]] {
                cast = castArray.prefix(Configuration.maxCastMembers).compactMap { entry in
                    guard let name = entry["name"] as? String,
                          let character = entry["character"] as? String else { return nil }
                    return TMDBMetadata.CastEntry(
                        name: name,
                        character: character,
                        profilePath: entry["profile_path"] as? String,
                        tmdbPersonID: entry["id"] as? Int
                    )
                }
            }
            if let crewArray = credits["crew"] as? [[String: Any]] {
                director = crewArray.first { ($0["job"] as? String) == "Director" }?["name"] as? String
            }
        }

        var certification: String?
        if let releaseDates = json["release_dates"] as? [String: Any],
           let results = releaseDates["results"] as? [[String: Any]] {
            for country in results {
                guard let iso = country["iso_3166_1"] as? String, iso == "US" else { continue }
                guard let dates = country["release_dates"] as? [[String: Any]] else { continue }
                for release in dates {
                    if let cert = release["certification"] as? String, !cert.isEmpty {
                        certification = cert
                        break
                    }
                }
                if certification != nil { break }
            }
        }

        var keywords: [TMDBMetadata.Keyword] = []
        if let keywordPayload = json["keywords"] as? [String: Any],
           let keywordRows = keywordPayload["keywords"] as? [[String: Any]] {
            keywords = keywordRows.compactMap { row in
                guard let id = row["id"] as? Int,
                      let name = row["name"] as? String,
                      !name.isEmpty else { return nil }
                return TMDBMetadata.Keyword(id: id, name: name)
            }
        }
        let similarIDs = Self.movieIDs(from: json["similar"])
        let recommendationIDs = Self.movieIDs(from: json["recommendations"])
        let movieEdges =
            similarIDs.enumerated().map { offset, id in
                TMDBMetadata.MovieEdge(
                    targetMovieID: String(id),
                    edgeType: CatalogMovieEdgeType.similar.rawValue,
                    rank: offset,
                    score: nil
                )
            }
            + recommendationIDs.enumerated().map { offset, id in
                TMDBMetadata.MovieEdge(
                    targetMovieID: String(id),
                    edgeType: CatalogMovieEdgeType.recommendation.rawValue,
                    rank: offset,
                    score: nil
                )
            }

        return TMDBMetadata(
            tmdbID: movieID,
            overview: overview,
            genres: genres,
            cast: cast,
            director: director,
            certification: certification,
            voteAverage: voteAverage,
            voteCount: voteCount,
            popularity: popularity,
            collectionID: collectionID,
            collectionName: collectionName,
            keywords: keywords,
            movieEdges: movieEdges,
            posterPath: posterPath,
            backdropPath: backdropPath,
            releaseDate: releaseDate,
            runtime: runtime
        )
    }

    private func parseTVJSON(_ json: [String: Any], tvID: Int) -> TMDBMetadata {
        let overview = json["overview"] as? String
        let voteAverage = json["vote_average"] as? Double
        let posterPath = json["poster_path"] as? String
        let backdropPath = json["backdrop_path"] as? String
        let firstAirDate = json["first_air_date"] as? String

        var runtime: Int?
        if let runtimes = json["episode_run_time"] as? [Int], let first = runtimes.first {
            runtime = first
        }

        var genres: [String] = []
        if let genreArray = json["genres"] as? [[String: Any]] {
            genres = genreArray.compactMap { $0["name"] as? String }
        }

        var cast: [TMDBMetadata.CastEntry] = []
        var creator: String?
        if let credits = json["credits"] as? [String: Any] {
            if let castArray = credits["cast"] as? [[String: Any]] {
                cast = castArray.prefix(Configuration.maxCastMembers).compactMap { entry in
                    guard let name = entry["name"] as? String,
                          let character = entry["character"] as? String else { return nil }
                    return TMDBMetadata.CastEntry(
                        name: name,
                        character: character,
                        profilePath: entry["profile_path"] as? String,
                        tmdbPersonID: entry["id"] as? Int
                    )
                }
            }
        }
        if let creators = json["created_by"] as? [[String: Any]],
           let first = creators.first {
            creator = first["name"] as? String
        }

        var certification: String?
        if let contentRatings = json["content_ratings"] as? [String: Any],
           let results = contentRatings["results"] as? [[String: Any]] {
            var usRatings: [String] = []
            for entry in results {
                guard let iso = entry["iso_3166_1"] as? String, iso == "US" else { continue }
                if let rating = entry["rating"] as? String, !rating.isEmpty {
                    usRatings.append(rating)
                }
            }
            certification = mostRestrictiveRating(usRatings)
        }

        return TMDBMetadata(
            tmdbID: tvID,
            overview: overview,
            genres: genres,
            cast: cast,
            director: creator,
            certification: certification,
            voteAverage: voteAverage,
            posterPath: posterPath,
            backdropPath: backdropPath,
            releaseDate: firstAirDate,
            runtime: runtime
        )
    }

    private static func movieIDs(from payload: Any?) -> [Int] {
        guard let dict = payload as? [String: Any],
              let rows = dict["results"] as? [[String: Any]] else { return [] }
        return rows.compactMap { $0["id"] as? Int }
    }

    // MARK: - Fetch Season Episodes

    struct EpisodeInfo {
        let episodeNumber: Int
        let name: String
        let overview: String?
        let stillPath: String?
        let id: Int?
        let airDate: String?
        let voteAverage: Double?
    }

    func fetchSeasonEpisodes(tvID: Int, seasonNumber: Int) async -> [EpisodeInfo] {
        guard UserSettings.shared.onlineMetadataEnabled else { return [] }

        let cacheKey = "season:\(tvID)|\(seasonNumber)"
        if let cached = seasonCache[cacheKey] {
            return cached
        }

        guard let url = buildURL(
            path: "/tv/\(tvID)/season/\(seasonNumber)",
            queryItems: []
        ) else {
            MarqueeLogger.network.error("Failed to build URL for season details: tv=\(tvID) s=\(seasonNumber)")
            return []
        }

        guard let data = await fetchData(from: url, context: "season details: tv=\(tvID) s=\(seasonNumber)") else {
            return []
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let episodes = json["episodes"] as? [[String: Any]] else {
            MarqueeLogger.network.error("Failed to parse season JSON: tv=\(tvID) s=\(seasonNumber)")
            return []
        }

        let results = episodes.compactMap { ep -> EpisodeInfo? in
            guard let epNumber = ep["episode_number"] as? Int,
                  let name = ep["name"] as? String else { return nil }
            return EpisodeInfo(
                episodeNumber: epNumber,
                name: name,
                overview: ep["overview"] as? String,
                stillPath: ep["still_path"] as? String,
                id: ep["id"] as? Int,
                airDate: ep["air_date"] as? String,
                voteAverage: ep["vote_average"] as? Double
            )
        }

        seasonCache[cacheKey] = results
        return results
    }

    // MARK: - Rating Helpers

    private func mostRestrictiveRating(_ ratings: [String]) -> String? {
        guard !ratings.isEmpty else { return nil }
        let order: [String: Int] = [
            "TV-Y": 0, "TV-Y7": 1, "TV-G": 2, "G": 3,
            "TV-PG": 4, "PG": 5,
            "TV-14": 6, "PG-13": 7,
            "TV-MA": 8, "R": 9, "NC-17": 10, "NR": 11
        ]
        return ratings.max { (order[$0] ?? 11) < (order[$1] ?? 11) }
    }
}
