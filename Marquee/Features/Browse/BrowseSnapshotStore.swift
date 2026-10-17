import Foundation

// MARK: - Browse Snapshot Models

struct BrowseMediaRow: Identifiable {
    let id: String
    let title: String
    let items: [MediaItem]
}

struct BrowseCompositionIdentity: Codable, Equatable {
    struct Row: Codable, Equatable {
        let id: String
        let itemIDs: [String]
    }

    let heroIDs: [String]
    let homeRows: [Row]

    init(snapshot: BrowseSnapshot) {
        heroIDs = snapshot.heroSpotlights.map(\.id)
        homeRows = snapshot.homeRows.map { row in
            Row(id: row.id, itemIDs: row.items.map { $0.id.uuidString })
        }
    }
}

struct BrowseShowSummary: Identifiable {
    var id: String { showName }

    let showName: String
    let representative: MediaItem
    let episodes: [MediaItem]
    let upNext: MediaItem?
    let seasonCount: Int
    let genres: [String]

    var posterPath: String? {
        representative.gridShowPosterPath
    }

    var upNextLabel: String? {
        upNext?.episodeLabel
    }
}

struct BrowseShowRow: Identifiable {
    let id: String
    let title: String
    let shows: [BrowseShowSummary]
}

struct BrowseTasteProfile {
    let completedFilePaths: Set<String>

    func contains(_ item: MediaItem) -> Bool {
        completedFilePaths.contains(item.filePath)
    }
}

struct BrowsePersonMediaRow: Identifiable {
    let id: String
    let title: String
    let items: [MediaItem]
}

enum PlaybackExitReason {
    case ended
    case dismissed
}

struct BrowseSnapshot {
    let heroSpotlights: [HeroSpotlight]
    let homeRows: [BrowseMediaRow]
    let movieRows: [BrowseMediaRow]
    let showRows: [BrowseShowRow]
    let showSummaries: [BrowseShowSummary]
    let searchIndex: BrowseSearchIndex
    let similarity: BrowseSimilarityIndex?
    let tasteProfile: BrowseTasteProfile?

    static let empty = BrowseSnapshot(
        heroSpotlights: [],
        homeRows: [],
        movieRows: [],
        showRows: [],
        showSummaries: [],
        searchIndex: BrowseSearchIndex(movies: [], shows: []),
        similarity: nil,
        tasteProfile: nil
    )

    var showNames: [String] {
        showSummaries.map(\.showName)
    }

    func showSummary(named showName: String) -> BrowseShowSummary? {
        showSummaries.first { $0.showName == showName }
    }

    func withSimilarity(_ similarity: BrowseSimilarityIndex?) -> BrowseSnapshot {
        let nextHeroSpotlights: [HeroSpotlight]
        if let similarity {
            let items = heroCandidateItems()
            let tasteModel = BrowseTasteModel(tasteProfile: tasteProfile, sourceItems: tasteSourceItems())
            nextHeroSpotlights = items.isEmpty
                ? heroSpotlights
                : HeroSpotlightBuilder.build(from: items, similarity: similarity, tasteModel: tasteModel)
        } else {
            nextHeroSpotlights = heroSpotlights
        }
        let nextHomeRows = similarity.map {
            BrowseSnapshotBuilder.homeRowsWithTaste(
                movies: movieCandidateItems(),
                showSummaries: showSummaries,
                tasteProfile: tasteProfile,
                similarity: $0
            )
        } ?? homeRows

        return BrowseSnapshot(
            heroSpotlights: nextHeroSpotlights,
            homeRows: nextHomeRows,
            movieRows: movieRows,
            showRows: showRows,
            showSummaries: showSummaries,
            searchIndex: searchIndex,
            similarity: similarity,
            tasteProfile: tasteProfile
        )
    }

    func attachingSimilarityPreservingComposition(
        _ similarity: BrowseSimilarityIndex?
    ) -> BrowseSnapshot {
        BrowseSnapshot(
            heroSpotlights: heroSpotlights,
            homeRows: homeRows,
            movieRows: movieRows,
            showRows: showRows,
            showSummaries: showSummaries,
            searchIndex: searchIndex,
            similarity: similarity,
            tasteProfile: tasteProfile
        )
    }

    func similarMovies(
        to item: MediaItem,
        in candidates: [MediaItem],
        limit: Int = 10
    ) -> [MediaItem] {
        BrowseRecommendationEngine.similarMovies(
            to: item,
            in: candidates,
            similarity: similarity,
            limit: limit
        )
    }

    func similarShows(
        to summary: BrowseShowSummary,
        limit: Int = 10
    ) -> [BrowseShowSummary] {
        BrowseRecommendationEngine.similarShows(
            to: summary,
            in: showSummaries,
            similarity: similarity,
            limit: limit
        )
    }

    func similarShowNames(
        to showName: String,
        limit: Int = 10
    ) -> [String] {
        guard let summary = showSummary(named: showName) else { return [] }
        return similarShows(to: summary, limit: limit).map(\.showName)
    }

    private func heroCandidateItems() -> [MediaItem] {
        var items: [MediaItem] = []
        var seenIDs = Set<UUID>()

        func append(_ item: MediaItem) {
            guard !seenIDs.contains(item.id) else { return }
            seenIDs.insert(item.id)
            items.append(item)
        }

        if let allMovies = movieRows.first(where: { $0.id == "all-movies" })?.items {
            allMovies.forEach(append)
        } else if let allMovies = homeRows.first(where: { $0.id == "all-movies" })?.items {
            allMovies.forEach(append)
        }
        showSummaries.map(\.representative).forEach(append)

        if items.isEmpty {
            heroSpotlights.map(\.item).forEach(append)
        }

        return items
    }

    private func movieCandidateItems() -> [MediaItem] {
        if let allMovies = movieRows.first(where: { $0.id == "all-movies" })?.items {
            return allMovies
        }
        if let allMovies = homeRows.first(where: { $0.id == "all-movies" })?.items {
            return allMovies
        }
        return heroSpotlights.map(\.item).filter { $0.isMovie }
    }

    private func tasteSourceItems() -> [MediaItem] {
        movieCandidateItems() + showSummaries.flatMap(\.episodes)
    }
}

/// Stable invalidation token for detail content cached outside the snapshot.
/// Catalog rebuilds replace the search revision, while the background
/// similarity pass attaches without rebuilding that catalog revision.
struct BrowseSnapshotDetailRevision: Equatable {
    let catalogRevision: String
    let hasSimilarity: Bool

    init(snapshot: BrowseSnapshot) {
        catalogRevision = snapshot.searchIndex.revisionKey
        hasSimilarity = snapshot.similarity != nil
    }
}

// MARK: - Hero Spotlight Card Model

struct HeroSpotlight: Identifiable {
    let id: String
    let item: MediaItem
    let category: String
    let icon: String
}

// MARK: - Taste Model

struct BrowseTasteModel {
    static let affinityCeiling = 260.0

    private let completedFilePaths: Set<String>
    private let completedItemIDs: Set<UUID>
    private let genreWeights: [String: Double]
    private let directorWeights: [String: Double]
    private let castWeights: [String: Double]
    private let keywordWeights: [String: Double]

    init?(tasteProfile: BrowseTasteProfile?, sourceItems: [MediaItem]) {
        guard let tasteProfile, !tasteProfile.completedFilePaths.isEmpty else { return nil }
        let completedItems = sourceItems.filter { tasteProfile.contains($0) }
        guard !completedItems.isEmpty else { return nil }

        completedFilePaths = tasteProfile.completedFilePaths
        completedItemIDs = Set(completedItems.map(\.id))

        var genres: [String: Double] = [:]
        var directors: [String: Double] = [:]
        var cast: [String: Double] = [:]
        var keywords: [String: Double] = [:]

        for item in completedItems {
            for genre in item.displayGenres {
                Self.addWeight(80, for: genre, into: &genres)
            }
            if let director = item.metadata?.director {
                Self.addWeight(90, for: director, into: &directors)
            }
            for (index, entry) in (item.metadata?.cast ?? []).prefix(5).enumerated() {
                Self.addWeight(max(30, 75 - Double(index) * 10), for: entry.name, into: &cast)
            }
            for keyword in item.metadata?.keywords ?? [] {
                Self.addWeight(95, for: keyword.name, into: &keywords)
            }
        }

        genreWeights = genres
        directorWeights = directors
        castWeights = cast
        keywordWeights = keywords
    }

    func isCompleted(_ item: MediaItem) -> Bool {
        completedFilePaths.contains(item.filePath) || completedItemIDs.contains(item.id)
    }

    func isUnwatched(_ item: MediaItem) -> Bool {
        !isCompleted(item) && !item.isWatched
    }

    func completedSeeds(from items: [MediaItem], limit: Int) -> [MediaItem] {
        items
            .filter(isCompleted)
            .sorted { lhs, rhs in
                if lhs.effectiveDate != rhs.effectiveDate {
                    return lhs.effectiveDate > rhs.effectiveDate
                }
                return BrowseSemanticPolicy.compareMoviesForBrowsing(lhs, rhs)
            }
            .prefix(limit)
            .map { $0 }
    }

    func rankedCandidates(_ items: [MediaItem], limit: Int) -> [MediaItem] {
        Array(items.sorted { lhs, rhs in
            let lhsScore = affinityScore(for: lhs)
            let rhsScore = affinityScore(for: rhs)
            if lhsScore != rhsScore { return lhsScore > rhsScore }

            let lhsVote = lhs.metadata?.voteAverage ?? 0
            let rhsVote = rhs.metadata?.voteAverage ?? 0
            if lhsVote != rhsVote { return lhsVote > rhsVote }

            if lhs.effectiveDate != rhs.effectiveDate {
                return lhs.effectiveDate > rhs.effectiveDate
            }
            return BrowseSemanticPolicy.compareMoviesForBrowsing(lhs, rhs)
        }.prefix(limit))
    }

    func heroBoost(for item: MediaItem) -> Double {
        guard isUnwatched(item) else { return 0 }
        return clampedAffinityScore(for: item)
    }

    /// Ledger weights accumulate without bound as the watch history grows, so
    /// every consumer that mixes affinity with other signals ranks against the
    /// same ceiling instead of letting one candidate dominate the mix.
    func clampedAffinityScore(for item: MediaItem) -> Double {
        min(Self.affinityCeiling, affinityScore(for: item))
    }

    func affinityScore(for item: MediaItem) -> Double {
        var score = 0.0
        for genre in item.displayGenres {
            score += genreWeights[Self.normalized(genre)] ?? 0
        }
        if let director = item.metadata?.director {
            score += directorWeights[Self.normalized(director)] ?? 0
        }
        for entry in item.metadata?.cast ?? [] {
            score += castWeights[Self.normalized(entry.name)] ?? 0
        }
        for keyword in item.metadata?.keywords ?? [] {
            score += keywordWeights[Self.normalized(keyword.name)] ?? 0
        }
        return score
    }

    private static func normalized(_ value: String) -> String {
        BrowseSemanticPolicy.normalizedText(value)
    }

    private static func addWeight(_ weight: Double, for value: String, into weights: inout [String: Double]) {
        let key = normalized(value)
        guard !key.isEmpty else { return }
        weights[key, default: 0] += weight
    }
}

// MARK: - Lean-back Delight

enum BrowseLeanBackDelightPolicy {
    static let playSomethingRowID = "play-something"
    static let summerBlockbustersRowID = "seasonal-summer-blockbusters"
    static let octoberHorrorRowID = "seasonal-october-horror"

    static func playSomethingRow(
        movies: [MediaItem],
        showSummaries: [BrowseShowSummary],
        tasteModel: BrowseTasteModel?,
        salt: String = "home",
        limit: Int = 12
    ) -> BrowseMediaRow? {
        let items = Array(playSomethingCandidates(
            movies: movies,
            showSummaries: showSummaries,
            tasteModel: tasteModel,
            salt: salt
        ).prefix(limit))
        guard !items.isEmpty else { return nil }
        return BrowseMediaRow(
            id: playSomethingRowID,
            title: "Play Something",
            items: items
        )
    }

    static func playSomethingPick(
        movies: [MediaItem],
        showSummaries: [BrowseShowSummary],
        tasteProfile: BrowseTasteProfile?,
        salt: String
    ) -> MediaItem? {
        let tasteModel = BrowseTasteModel(
            tasteProfile: tasteProfile,
            sourceItems: movies + showSummaries.flatMap(\.episodes)
        )
        return playSomethingCandidates(
            movies: movies,
            showSummaries: showSummaries,
            tasteModel: tasteModel,
            salt: salt
        ).first
    }

    static func playSomethingCandidates(
        movies: [MediaItem],
        showSummaries: [BrowseShowSummary],
        tasteModel: BrowseTasteModel?,
        salt: String
    ) -> [MediaItem] {
        let candidates = playableCandidates(movies: movies, showSummaries: showSummaries)
            .filter { item in
                if let tasteModel {
                    return tasteModel.isUnwatched(item)
                }
                return !item.isWatched
            }
        return weightedShuffle(candidates, tasteModel: tasteModel, salt: salt)
    }

    static func nextInFranchise(after item: MediaItem, in movies: [MediaItem]) -> MediaItem? {
        let sameCollection: [MediaItem]
        if let collectionID = item.metadata?.collectionID {
            sameCollection = movies.filter { $0.metadata?.collectionID == collectionID }
        } else if let collectionName = normalizedNonEmpty(item.metadata?.collectionName) {
            sameCollection = movies.filter {
                normalizedNonEmpty($0.metadata?.collectionName) == collectionName
            }
        } else if let franchiseKey = BrowseSemanticPolicy.franchiseKey(for: item) {
            sameCollection = movies.filter {
                BrowseSemanticPolicy.franchiseKey(for: $0) == franchiseKey
            }
        } else {
            sameCollection = []
        }

        let ordered = sameCollection.sorted(by: compareFranchiseOrder)
        guard let currentIndex = ordered.firstIndex(where: { $0.id == item.id }) else { return nil }
        let nextIndex = currentIndex + 1
        guard ordered.indices.contains(nextIndex) else { return nil }
        return ordered[nextIndex]
    }

    static func postPlayHandoffCandidate(
        after item: MediaItem,
        dismissal: PlaybackExitReason,
        movies: [MediaItem],
        similarity: BrowseSimilarityIndex?
    ) -> MediaItem? {
        guard dismissal == .ended else { return nil }
        return BrowseRecommendationEngine.similarMovies(
            to: item,
            in: movies,
            similarity: similarity,
            limit: 1
        ).first
    }

    static func seasonalRows(
        movies: [MediaItem],
        date: Date,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> [BrowseMediaRow] {
        guard !movies.isEmpty else { return [] }
        let month = calendar.dateComponents([.month], from: date).month

        if month == 10 {
            let horror = sortedSeasonalMovies(
                movies.filter(isOctoberHorror),
                date: date,
                rowSalt: octoberHorrorRowID
            )
            if horror.count >= 2 {
                return [BrowseMediaRow(id: octoberHorrorRowID, title: "October Horror", items: horror)]
            }
        }

        if let month, (6...8).contains(month) {
            let blockbusters = sortedSeasonalMovies(
                movies.filter(isSummerBlockbuster),
                date: date,
                rowSalt: summerBlockbustersRowID
            )
            if blockbusters.count >= 2 {
                return [BrowseMediaRow(id: summerBlockbustersRowID, title: "Summer Blockbusters", items: blockbusters)]
            }
        }

        return []
    }

    static func personRows(
        for item: MediaItem,
        in candidates: [MediaItem],
        limit: Int = 10
    ) -> [BrowsePersonMediaRow] {
        var rows: [BrowsePersonMediaRow] = []
        let sourceID = item.id

        if let director = trimmedNonEmpty(item.metadata?.director) {
            let matches = rankedPersonMatches(
                candidates.filter {
                    $0.id != sourceID
                        && normalizedNonEmpty($0.metadata?.director) == normalizedNonEmpty(director)
                },
                source: item,
                limit: limit
            )
            if !matches.isEmpty {
                rows.append(BrowsePersonMediaRow(
                    id: "director-\(stableRowFragment(director))",
                    title: "More from \(director)",
                    items: matches
                ))
            }
        }

        for member in item.metadata?.cast.prefix(5) ?? [] {
            let actorKey = BrowseSemanticPolicy.normalizedText(member.name)
            guard !actorKey.isEmpty else { continue }
            let matches = rankedPersonMatches(
                candidates.filter { candidate in
                    guard candidate.id != sourceID else { return false }
                    return (candidate.metadata?.cast ?? []).contains {
                        BrowseSemanticPolicy.normalizedText($0.name) == actorKey
                    }
                },
                source: item,
                limit: limit
            )
            if !matches.isEmpty {
                rows.append(BrowsePersonMediaRow(
                    id: "cast-\(stableRowFragment(member.name))",
                    title: "Also with \(member.name)",
                    items: matches
                ))
                break
            }
        }

        return rows
    }

    private static func playableCandidates(
        movies: [MediaItem],
        showSummaries: [BrowseShowSummary]
    ) -> [MediaItem] {
        var results = movies
        results += showSummaries.compactMap { summary in
            summary.upNext ?? summary.episodes.first
        }
        var seen = Set<UUID>()
        return results.filter { seen.insert($0.id).inserted }
    }

    private static func weightedShuffle(
        _ items: [MediaItem],
        tasteModel: BrowseTasteModel?,
        salt: String
    ) -> [MediaItem] {
        let scored: [(item: MediaItem, key: Double)] = items
            .map { item -> (item: MediaItem, key: Double) in
                let weight = playWeight(for: item, tasteModel: tasteModel)
                let random = deterministicUnitInterval("\(item.id.uuidString)|\(salt)")
                return (item: item, key: pow(random, 1.0 / max(weight, 1.0)))
            }
        return scored.sorted { lhs, rhs in
                if lhs.key != rhs.key { return lhs.key > rhs.key }
                return BrowseSemanticPolicy.compareMoviesForBrowsing(lhs.item, rhs.item)
            }
            .map(\.item)
    }

    private static func playWeight(for item: MediaItem, tasteModel: BrowseTasteModel?) -> Double {
        var weight = 1.0
        weight += (tasteModel?.clampedAffinityScore(for: item) ?? 0) / 30.0
        weight += (item.metadata?.voteAverage ?? 0) / 2.0
        weight += min(4.0, (item.metadata?.popularity ?? 0) / 25.0)
        if item.displayBackdropPath != nil { weight += 1.0 }
        if item.displayPosterPath != nil { weight += 0.5 }
        return weight
    }

    private static func sortedSeasonalMovies(_ movies: [MediaItem], date: Date, rowSalt: String) -> [MediaItem] {
        let newestDate = movies.map(\.effectiveDate).max()
        let salt = "\(rowSalt)-\(dateKey(date))"
        return movies
            .map { item in
                (
                    item: item,
                    score: BrowseSemanticPolicy.heroScore(for: item, newestDate: newestDate)
                        + deterministicUnitInterval("\(item.id.uuidString)|\(salt)")
                )
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return BrowseSemanticPolicy.compareMoviesForBrowsing(lhs.item, rhs.item)
            }
            .map(\.item)
    }

    private static func isOctoberHorror(_ item: MediaItem) -> Bool {
        let haystack = semanticHaystack(for: item)
        return item.displayGenres.map(BrowseSemanticPolicy.normalizedText).contains("horror")
            || haystack.contains("halloween")
            || haystack.contains("haunted")
            || haystack.contains("ghost")
    }

    private static func isSummerBlockbuster(_ item: MediaItem) -> Bool {
        let genres = Set(item.displayGenres.map(BrowseSemanticPolicy.normalizedText))
        let blockbusterGenres: Set<String> = [
            "action", "adventure", "science fiction", "sci fi", "fantasy"
        ]
        guard !genres.intersection(blockbusterGenres).isEmpty else { return false }
        let voteCount = item.metadata?.voteCount ?? 0
        let popularity = item.metadata?.popularity ?? 0
        let voteAverage = item.metadata?.voteAverage ?? 0
        return voteCount >= 100 || popularity >= 10 || voteAverage >= 7.0
    }

    private static func rankedPersonMatches(
        _ matches: [MediaItem],
        source: MediaItem,
        limit: Int
    ) -> [MediaItem] {
        matches
            .map { item in
                (
                    item: item,
                    score: personMatchScore(item, source: source)
                )
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return BrowseSemanticPolicy.compareMoviesForBrowsing(lhs.item, rhs.item)
            }
            .prefix(limit)
            .map(\.item)
    }

    private static func personMatchScore(_ item: MediaItem, source: MediaItem) -> Double {
        var score = BrowseSemanticPolicy.heroScore(for: item, newestDate: nil)
        let sourceGenres = Set(source.displayGenres.map(BrowseSemanticPolicy.normalizedText))
        let itemGenres = Set(item.displayGenres.map(BrowseSemanticPolicy.normalizedText))
        score += Double(sourceGenres.intersection(itemGenres).count) * 80
        if item.year != nil, source.year != nil {
            score -= Double(abs((item.year ?? 0) - (source.year ?? 0)))
        }
        return score
    }

    private static func compareFranchiseOrder(_ lhs: MediaItem, _ rhs: MediaItem) -> Bool {
        let lhsDate = lhs.metadata?.releaseDate ?? lhs.displayYear ?? ""
        let rhsDate = rhs.metadata?.releaseDate ?? rhs.displayYear ?? ""
        if lhsDate != rhsDate { return lhsDate < rhsDate }
        return BrowseSemanticPolicy.compareMoviesForBrowsing(lhs, rhs)
    }

    private static func semanticHaystack(for item: MediaItem) -> String {
        let parts = [item.displayTitle, item.metadata?.overview ?? ""] + item.displayGenres
        return parts.map(BrowseSemanticPolicy.normalizedText).joined(separator: " ")
    }

    private static func trimmedNonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func normalizedNonEmpty(_ value: String?) -> String? {
        guard let value = trimmedNonEmpty(value) else { return nil }
        let normalized = BrowseSemanticPolicy.normalizedText(value)
        return normalized.isEmpty ? nil : normalized
    }

    private static func stableRowFragment(_ value: String) -> String {
        let normalized = BrowseSemanticPolicy.normalizedText(value)
        let fragment = normalized.replacingOccurrences(of: " ", with: "-")
        return fragment.isEmpty ? "unknown" : fragment
    }

    private static func dateKey(_ date: Date) -> String {
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(components.year ?? 0)-\(components.month ?? 0)-\(components.day ?? 0)"
    }

    private static func deterministicUnitInterval(_ value: String) -> Double {
        let hash = stableHash(value)
        return (Double(hash % 1_000_000) + 1.0) / 1_000_001.0
    }

    private static func stableHash(_ value: String) -> UInt64 {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }
}

// MARK: - Hero Spotlight Builder

enum HeroSpotlightBuilder {

    static func build(
        from items: [MediaItem],
        holidayScores: [UUID: Int]? = nil,
        similarity: BrowseSimilarityIndex? = nil,
        tasteModel: BrowseTasteModel? = nil
    ) -> [HeroSpotlight] {
        guard !items.isEmpty else { return [] }
        var spotlights: [HeroSpotlight] = []
        var usedIDs: Set<UUID> = []
        var usedMovieIDs: Set<UUID> = []
        var usedShowNames: Set<String> = []
        var usedHeroProfiles: [HeroContentProfile] = []

        func remember(_ item: MediaItem) {
            usedIDs.insert(item.id)
            usedHeroProfiles.append(HeroContentProfile(item: item))
            if let showName = item.showName {
                usedShowNames.insert(showName)
            } else {
                usedMovieIDs.insert(item.id)
            }
        }

        func isTooSimilarToUsed(_ item: MediaItem) -> Bool {
            guard let similarity else { return false }
            let profile = HeroContentProfile(item: item)
            if usedHeroProfiles.contains(where: { usedProfile in
                usedProfile.isMixedMediaCompared(to: profile)
                    && usedProfile.isNearDuplicate(of: profile)
            }) {
                return true
            }

            if let showName = item.showName {
                return usedShowNames.contains { usedShowName in
                    similarity.rankedShowNames(for: usedShowName).prefix(4).contains(showName)
                        || similarity.rankedShowNames(for: showName).prefix(4).contains(usedShowName)
                }
            }

            return usedMovieIDs.contains { usedID in
                similarity.rankedMovieIDs(for: usedID).prefix(4).contains(item.id)
                    || similarity.rankedMovieIDs(for: item.id).prefix(4).contains(usedID)
            }
        }

        func firstAvailable(in candidates: [MediaItem]) -> MediaItem? {
            candidates.first { !usedIDs.contains($0.id) && !isTooSimilarToUsed($0) }
                ?? candidates.first { !usedIDs.contains($0.id) }
        }

        func appendSpotlight(item: MediaItem, category: String, icon: String, idPrefix: String) {
            spotlights.append(HeroSpotlight(
                id: "\(idPrefix)-\(item.id.uuidString)",
                item: item,
                category: category,
                icon: icon
            ))
            remember(item)
        }

        let continuing = items
            .filter { $0.hasProgress }
            .sorted { ($0.lastPlayedDate ?? .distantPast) > ($1.lastPlayedDate ?? .distantPast) }
        if let next = continuing.first {
            appendSpotlight(item: next, category: "Continue Watching", icon: "play.circle", idPrefix: "continue")
        }

        let newestDate = items.map(\.effectiveDate).max()
        let qualityRanked = items
            .map { (
                item: $0,
                score: BrowseSemanticPolicy.heroScore(for: $0, newestDate: newestDate)
                    + (tasteModel?.heroBoost(for: $0) ?? 0),
                key: BrowseSemanticPolicy.movieBrowseSortKey(for: $0)
            ) }
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return BrowseSemanticPolicy.compareMovieBrowseSortKeys($0.key, $1.key)
            }
            .map(\.item)

        if let pick = firstAvailable(in: qualityRanked) {
            appendSpotlight(item: pick, category: "Featured", icon: "sparkles", idPrefix: "featured")
        }

        let holiday = qualityRanked
            .filter {
                (holidayScores?[$0.id] ?? BrowseSemanticPolicy.holidayScore(for: $0)) > 0
                    && !usedIDs.contains($0.id)
            }
        if let holidayPick = firstAvailable(in: holiday) {
            appendSpotlight(item: holidayPick, category: "Holiday Pick", icon: "gift", idPrefix: "holiday")
        }

        let recentlyAdded = items
            .filter { !usedIDs.contains($0.id) }
            .map { (
                item: $0,
                score: BrowseSemanticPolicy.heroScore(for: $0, newestDate: newestDate)
            ) }
            .sorted {
                if $0.item.effectiveDate != $1.item.effectiveDate {
                    return $0.item.effectiveDate > $1.item.effectiveDate
                }
                return $0.score > $1.score
            }
            .map(\.item)
        if let newest = firstAvailable(in: recentlyAdded) {
            appendSpotlight(item: newest, category: "Recently Added", icon: "plus.square.on.square", idPrefix: "recently-added")
        }

        let classics = qualityRanked
            .filter { ($0.year ?? 9999) < 2000 && !usedIDs.contains($0.id) }
        if let classic = firstAvailable(in: classics) {
            appendSpotlight(item: classic, category: "From the Vault", icon: "clock.arrow.circlepath", idPrefix: "vault")
        }

        while spotlights.count < 5 {
            guard let item = firstAvailable(in: qualityRanked) else { break }
            appendSpotlight(item: item, category: "Smart Pick", icon: "wand.and.stars", idPrefix: "smart-pick")
        }

        return spotlights
    }

    private struct HeroContentProfile {
        let isShow: Bool
        let franchiseKey: String?
        let director: String?
        let topCastNames: Set<String>
        let genres: Set<String>

        init(item: MediaItem) {
            isShow = item.showName != nil
            franchiseKey = BrowseSemanticPolicy.franchiseKey(for: item.browseTitle)
            director = item.metadata?.director.map(BrowseSemanticPolicy.normalizedText).flatMap {
                $0.isEmpty ? nil : $0
            }
            topCastNames = Set(
                (item.metadata?.cast ?? [])
                    .prefix(2)
                    .map { BrowseSemanticPolicy.normalizedText($0.name) }
                    .filter { !$0.isEmpty }
            )
            genres = Set(item.displayGenres.map(BrowseSemanticPolicy.normalizedText).filter { !$0.isEmpty })
        }

        func isMixedMediaCompared(to other: HeroContentProfile) -> Bool {
            isShow != other.isShow
        }

        func isNearDuplicate(of other: HeroContentProfile) -> Bool {
            if let franchiseKey, franchiseKey == other.franchiseKey {
                return true
            }
            if !topCastNames.intersection(other.topCastNames).isEmpty {
                return true
            }
            if let director, director == other.director, !genres.intersection(other.genres).isEmpty {
                return true
            }
            return false
        }
    }
}

// MARK: - Search Index

enum BrowseSearchMatchType: Int, Comparable {
    case title = 0
    case collection = 1
    case director = 2
    case cast = 3
    case keyword = 4
    case genre = 5
    case overview = 6
    case fileName = 7

    static func < (lhs: BrowseSearchMatchType, rhs: BrowseSearchMatchType) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct BrowseSearchHit: Identifiable {
    let id: String
    let item: MediaItem
    let matchType: BrowseSearchMatchType
    let matchDetail: String?
    let score: Int
}

struct BrowseShowSearchHit: Identifiable {
    let id: String
    let showName: String
    let item: MediaItem
    let seasonCount: Int
    let matchType: BrowseSearchMatchType
    let matchDetail: String?
    let score: Int
}

struct BrowseSearchResults {
    let movies: [BrowseSearchHit]
    let shows: [BrowseShowSearchHit]

    static let empty = BrowseSearchResults(movies: [], shows: [])

    var totalCount: Int {
        movies.count + shows.count
    }
}

struct BrowseSearchIndex {
    struct WorkerEvaluation {
        let suggestions: [String]
        fileprivate let results: WorkerResults
    }

    struct WorkerSnapshot {
        fileprivate let movieItems: [IndexedMovie]
        fileprivate let showSummaries: [IndexedShow]
        fileprivate let suggestionValues: [IndexedSuggestion]
        fileprivate let suggestionQueriesByNormalizedValue: [String: String]
        let revisionKey: String

        fileprivate init(
            movieItems: [IndexedMovie],
            showSummaries: [IndexedShow],
            suggestionValues: [IndexedSuggestion],
            suggestionQueriesByNormalizedValue: [String: String]
        ) {
            self.movieItems = movieItems
            self.showSummaries = showSummaries
            self.suggestionValues = suggestionValues
            self.suggestionQueriesByNormalizedValue = suggestionQueriesByNormalizedValue
            revisionKey = "\(movieItems.count):\(showSummaries.count):\(suggestionValues.count):\(UUID().uuidString)"
        }

        func evaluate(
            _ rawQuery: String,
            isCancelled: () -> Bool = { false }
        ) -> WorkerEvaluation? {
            guard !isCancelled() else { return nil }
            let suggestions = suggestions(for: rawQuery, isCancelled: isCancelled)
            guard let results = search(rawQuery, isCancelled: isCancelled) else { return nil }
            return WorkerEvaluation(suggestions: suggestions, results: results)
        }

        func suggestions(
            for rawQuery: String,
            limit: Int = 8,
            isCancelled: () -> Bool = { false }
        ) -> [String] {
            let query = BrowseSearchIndex.normalized(rawQuery)
            guard query.count >= 2 else { return [] }
            var results: [String] = []
            results.reserveCapacity(limit)

            for (index, suggestion) in suggestionValues.enumerated() {
                if index.isMultiple(of: 32), isCancelled() { return [] }
                guard suggestion.normalizedValue.contains(query) else { continue }
                results.append(suggestion.value)
                if results.count >= limit { break }
            }
            return results
        }

        private func search(
            _ rawQuery: String,
            isCancelled: () -> Bool
        ) -> WorkerResults? {
            let resolvedQuery = resolvedSearchQuery(for: rawQuery)
            let scopedQuery = BrowseSearchIndex.scopedSearchQuery(from: resolvedQuery)
            let query = BrowseSearchIndex.normalized(scopedQuery.value)
            let queryTokens = BrowseSemanticPolicy.tokens(inNormalizedText: query)
            let overviewQueryTokens = BrowseSemanticPolicy.overviewTokens(inNormalizedText: query)
            guard !query.isEmpty else { return .empty }
            let scope: SearchScope = query.count == 1 && scopedQuery.scope == .any
                ? .titleOnly
                : scopedQuery.scope

            guard let nonFuzzyResults = searchPass(
                query: query,
                queryTokens: queryTokens,
                overviewQueryTokens: overviewQueryTokens,
                scope: scope,
                allowsEditDistanceOne: false,
                isCancelled: isCancelled
            ) else { return nil }
            guard nonFuzzyResults.totalCount == 0 else { return nonFuzzyResults }
            guard !isCancelled() else { return nil }
            return searchPass(
                query: query,
                queryTokens: queryTokens,
                overviewQueryTokens: overviewQueryTokens,
                scope: scope,
                allowsEditDistanceOne: true,
                isCancelled: isCancelled
            )
        }

        private func searchPass(
            query: String,
            queryTokens: [String],
            overviewQueryTokens: [String],
            scope: SearchScope,
            allowsEditDistanceOne: Bool,
            isCancelled: () -> Bool
        ) -> WorkerResults? {
            var movies: [WorkerMovieHit] = []
            movies.reserveCapacity(min(movieItems.count, 96))
            for (index, indexedMovie) in movieItems.enumerated() {
                if index.isMultiple(of: 16), isCancelled() { return nil }
                guard let match = indexedMovie.match(
                    query: query,
                    queryTokens: queryTokens,
                    overviewQueryTokens: overviewQueryTokens,
                    scope: scope,
                    allowsEditDistanceOne: allowsEditDistanceOne
                ) else { continue }
                movies.append(WorkerMovieHit(
                    itemID: indexedMovie.itemID,
                    matchType: match.type,
                    matchDetail: match.detail,
                    score: match.score,
                    browseSortKey: indexedMovie.browseSortKey
                ))
            }
            guard !isCancelled() else { return nil }
            movies.sort { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                if lhs.matchType != rhs.matchType { return lhs.matchType < rhs.matchType }
                return BrowseSemanticPolicy.compareMovieBrowseSortKeys(
                    lhs.browseSortKey,
                    rhs.browseSortKey
                )
            }

            var shows: [WorkerShowHit] = []
            shows.reserveCapacity(min(showSummaries.count, 64))
            for (index, indexedShow) in showSummaries.enumerated() {
                if index.isMultiple(of: 16), isCancelled() { return nil }
                guard let match = indexedShow.match(
                    query: query,
                    queryTokens: queryTokens,
                    overviewQueryTokens: overviewQueryTokens,
                    scope: scope,
                    allowsEditDistanceOne: allowsEditDistanceOne
                ) else { continue }
                shows.append(WorkerShowHit(
                    showName: indexedShow.showName,
                    representativeItemID: indexedShow.representativeItemID,
                    seasonCount: indexedShow.seasonCount,
                    matchType: match.type,
                    matchDetail: match.detail,
                    score: match.score
                ))
            }
            guard !isCancelled() else { return nil }
            shows.sort { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                if lhs.matchType != rhs.matchType { return lhs.matchType < rhs.matchType }
                return lhs.showName.localizedCaseInsensitiveCompare(rhs.showName) == .orderedAscending
            }

            return WorkerResults(movies: movies, shows: shows)
        }

        private func resolvedSearchQuery(for rawQuery: String) -> String {
            let normalizedQuery = BrowseSearchIndex.normalized(rawQuery)
            guard !normalizedQuery.isEmpty else { return rawQuery }
            return suggestionQueriesByNormalizedValue[normalizedQuery] ?? rawQuery
        }
    }

    fileprivate struct WorkerResults {
        let movies: [WorkerMovieHit]
        let shows: [WorkerShowHit]

        static let empty = WorkerResults(movies: [], shows: [])

        var totalCount: Int { movies.count + shows.count }
    }

    fileprivate struct WorkerMovieHit {
        let itemID: UUID
        let matchType: BrowseSearchMatchType
        let matchDetail: String?
        let score: Int
        let browseSortKey: BrowseSemanticPolicy.MovieBrowseSortKey
    }

    fileprivate struct WorkerShowHit {
        let showName: String
        let representativeItemID: UUID
        let seasonCount: Int
        let matchType: BrowseSearchMatchType
        let matchDetail: String?
        let score: Int
    }

    private let worker: WorkerSnapshot
    private let movieItemsByID: [UUID: MediaItem]
    private let showSummariesByName: [String: BrowseShowSummary]

    init(movies: [MediaItem], shows: [BrowseShowSummary]) {
        let movieItems = movies.map(IndexedMovie.init)
        let showSummaries = shows.map(IndexedShow.init)
        let suggestions = Self.buildSuggestions(movies: movies, shows: shows)
        worker = WorkerSnapshot(
            movieItems: movieItems,
            showSummaries: showSummaries,
            suggestionValues: suggestions,
            suggestionQueriesByNormalizedValue: Self.buildSuggestionLookup(suggestions)
        )
        movieItemsByID = movies.reduce(into: [:]) { result, item in
            result[item.id] = item
        }
        showSummariesByName = shows.reduce(into: [:]) { result, summary in
            result[summary.showName] = summary
        }
    }

    /// Reuses the per-movie tokenization from a previously built index when
    /// the new movie set is a subset of the same item instances (maturity
    /// filtering). Show entries and suggestions are rebuilt from the filtered
    /// inputs — show summaries change shape under filtering and suggestions
    /// carry no per-item provenance.
    init(filteringMoviesFrom existing: BrowseSearchIndex, movies: [MediaItem], shows: [BrowseShowSummary]) {
        let allowedMovieIDs = Set(movies.map(\.id))
        let movieItems = existing.worker.movieItems.filter { allowedMovieIDs.contains($0.itemID) }
        let showSummaries = shows.map(IndexedShow.init)
        let suggestions = Self.buildSuggestions(movies: movies, shows: shows)
        worker = WorkerSnapshot(
            movieItems: movieItems,
            showSummaries: showSummaries,
            suggestionValues: suggestions,
            suggestionQueriesByNormalizedValue: Self.buildSuggestionLookup(suggestions)
        )
        movieItemsByID = movies.reduce(into: [:]) { result, item in
            result[item.id] = item
        }
        showSummariesByName = shows.reduce(into: [:]) { result, summary in
            result[summary.showName] = summary
        }
    }

    var revisionKey: String {
        worker.revisionKey
    }

    var workerSnapshot: WorkerSnapshot {
        worker
    }

    func suggestions(for rawQuery: String, limit: Int = 8) -> [String] {
        worker.suggestions(for: rawQuery, limit: limit)
    }

    func search(_ rawQuery: String) -> BrowseSearchResults {
        guard let evaluation = worker.evaluate(rawQuery) else { return .empty }
        return materialize(evaluation.results)
    }

    func materialize(_ evaluation: WorkerEvaluation) -> BrowseSearchResults {
        materialize(evaluation.results)
    }

    private func materialize(_ results: WorkerResults) -> BrowseSearchResults {
        let movies = results.movies.compactMap { match -> BrowseSearchHit? in
            guard let item = movieItemsByID[match.itemID] else { return nil }
            return BrowseSearchHit(
                id: "movie-\(match.itemID.uuidString)-\(match.matchType.rawValue)",
                item: item,
                matchType: match.matchType,
                matchDetail: match.matchDetail,
                score: match.score
            )
        }
        let shows = results.shows.compactMap { match -> BrowseShowSearchHit? in
            guard let summary = showSummariesByName[match.showName],
                  summary.representative.id == match.representativeItemID else { return nil }
            return BrowseShowSearchHit(
                id: "show-\(match.showName)-\(match.matchType.rawValue)",
                showName: match.showName,
                item: summary.representative,
                seasonCount: match.seasonCount,
                matchType: match.matchType,
                matchDetail: match.matchDetail,
                score: match.score
            )
        }
        return BrowseSearchResults(movies: movies, shows: shows)
    }

    fileprivate struct IndexedSuggestion {
        let value: String
        let normalizedValue: String
        let searchQuery: String

    }

    fileprivate enum SearchScope {
        case any
        case titleOnly
        case collection
        case director
        case cast
        case keyword
        case genre
    }

    private struct ScopedSearchQuery {
        let scope: SearchScope
        let value: String
    }

    private static func scopedSearchQuery(from rawQuery: String) -> ScopedSearchQuery {
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPrefix = trimmed.lowercased()
        let prefixes: [(String, SearchScope)] = [
            ("collection:", .collection),
            ("director:", .director),
            ("cast:", .cast),
            ("keyword:", .keyword),
            ("genre:", .genre),
        ]

        for (prefix, scope) in prefixes where normalizedPrefix.hasPrefix(prefix) {
            let valueStart = trimmed.index(trimmed.startIndex, offsetBy: prefix.count)
            let value = String(trimmed[valueStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
            return ScopedSearchQuery(scope: scope, value: value)
        }

        return ScopedSearchQuery(scope: .any, value: trimmed)
    }

    fileprivate struct IndexedMovie {
        let itemID: UUID
        let browseSortKey: BrowseSemanticPolicy.MovieBrowseSortKey
        private let normalizedTitle: String
        private let titleTokens: [String]
        private let franchiseKey: String?
        private let normalizedCollection: String?
        private let collectionTokens: [String]
        private let normalizedDirector: String?
        private let directorTokens: [String]
        private let normalizedCast: [(display: String, normalized: String, tokens: [String])]
        private let normalizedKeywords: [(display: String, normalized: String, tokens: [String])]
        private let normalizedGenres: [(normalized: String, tokens: [String])]
        private let normalizedOverview: String?
        private let overviewTokens: [String]
        private let overviewTokenSet: Set<String>
        private let normalizedFileName: String
        private let fileNameTokens: [String]

        init(_ item: MediaItem) {
            itemID = item.id
            browseSortKey = BrowseSemanticPolicy.movieBrowseSortKey(for: item)
            normalizedTitle = BrowseSearchIndex.normalized(item.displayTitle)
            titleTokens = BrowseSemanticPolicy.tokens(inNormalizedText: normalizedTitle)
            franchiseKey = BrowseSemanticPolicy.franchiseKey(for: item)
            normalizedCollection = item.metadata?.collectionName.map(BrowseSearchIndex.normalized)
            collectionTokens = normalizedCollection.map(BrowseSemanticPolicy.tokens(inNormalizedText:)) ?? []
            normalizedDirector = item.metadata?.director.map(BrowseSearchIndex.normalized)
            directorTokens = normalizedDirector.map(BrowseSemanticPolicy.tokens(inNormalizedText:)) ?? []
            normalizedCast = item.metadata?.cast.map { member in
                let normalized = BrowseSearchIndex.normalized(member.name)
                return (
                    display: member.name,
                    normalized: normalized,
                    tokens: BrowseSemanticPolicy.tokens(inNormalizedText: normalized)
                )
            } ?? []
            normalizedKeywords = item.metadata?.keywords.compactMap { keyword in
                let trimmed = keyword.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                let normalized = BrowseSearchIndex.normalized(trimmed)
                guard !normalized.isEmpty else { return nil }
                return (
                    display: trimmed,
                    normalized: normalized,
                    tokens: BrowseSemanticPolicy.tokens(inNormalizedText: normalized)
                )
            } ?? []
            normalizedGenres = item.displayGenres.map { genre in
                let normalized = BrowseSearchIndex.normalized(genre)
                return (
                    normalized: normalized,
                    tokens: BrowseSemanticPolicy.tokens(inNormalizedText: normalized)
                )
            }
            normalizedOverview = item.metadata?.overview.map(BrowseSearchIndex.normalized)
            let overviewTokens = normalizedOverview.map(BrowseSemanticPolicy.overviewTokens(inNormalizedText:)) ?? []
            self.overviewTokens = overviewTokens
            overviewTokenSet = Set(overviewTokens)
            normalizedFileName = BrowseSearchIndex.normalized(item.fileName)
            fileNameTokens = BrowseSemanticPolicy.tokens(inNormalizedText: normalizedFileName)
        }

        func match(
            query: String,
            queryTokens: [String],
            overviewQueryTokens: [String],
            scope: SearchScope,
            allowsEditDistanceOne: Bool
        ) -> (type: BrowseSearchMatchType, detail: String?, score: Int)? {
            if scope == .any || scope == .titleOnly {
                if let score = BrowseSemanticPolicy.searchScore(
                    query: query,
                    queryTokens: queryTokens,
                    normalizedText: normalizedTitle,
                    tokens: titleTokens,
                    franchiseKey: scope == .any ? franchiseKey : nil,
                    baseScore: 900,
                    allowsSubstring: scope == .any,
                    allowsEditDistanceOne: scope == .any && allowsEditDistanceOne
                ) {
                    return (.title, nil, score)
                }
                if scope == .titleOnly { return nil }
            }

            if scope == .any || scope == .collection {
                if let normalizedCollection,
                   let score = BrowseSemanticPolicy.searchScore(
                    query: query,
                    queryTokens: queryTokens,
                    normalizedText: normalizedCollection,
                    tokens: collectionTokens,
                    franchiseKey: nil,
                    baseScore: 760,
                    allowsEditDistanceOne: allowsEditDistanceOne
                   ) {
                    return (.collection, "Collection match", score)
                }
                if scope == .collection { return nil }
            }

            if scope == .any || scope == .director {
                if let normalizedDirector,
                   let score = BrowseSemanticPolicy.searchScore(
                    query: query,
                    queryTokens: queryTokens,
                    normalizedText: normalizedDirector,
                    tokens: directorTokens,
                    franchiseKey: nil,
                    baseScore: 650,
                    allowsEditDistanceOne: allowsEditDistanceOne
                   ) {
                    return (.director, "Director match", score)
                }
                if scope == .director { return nil }
            }

            if scope == .any || scope == .cast {
                for member in normalizedCast {
                    if let score = BrowseSemanticPolicy.searchScore(
                        query: query,
                        queryTokens: queryTokens,
                        normalizedText: member.normalized,
                        tokens: member.tokens,
                        franchiseKey: nil,
                        baseScore: 540,
                        allowsEditDistanceOne: allowsEditDistanceOne
                    ) {
                        return (.cast, "Cast: \(member.display)", score)
                    }
                }
                if scope == .cast { return nil }
            }

            if scope == .any || scope == .keyword {
                for keyword in normalizedKeywords {
                    if let score = BrowseSemanticPolicy.searchScore(
                        query: query,
                        queryTokens: queryTokens,
                        normalizedText: keyword.normalized,
                        tokens: keyword.tokens,
                        franchiseKey: nil,
                        baseScore: 460,
                        allowsEditDistanceOne: allowsEditDistanceOne
                    ) {
                        return (.keyword, "Theme: \(keyword.display)", score)
                    }
                }
                if scope == .keyword { return nil }
            }

            if scope == .any || scope == .genre {
                for genre in normalizedGenres {
                    if let score = BrowseSemanticPolicy.searchScore(
                        query: query,
                        queryTokens: queryTokens,
                        normalizedText: genre.normalized,
                        tokens: genre.tokens,
                        franchiseKey: nil,
                        baseScore: 420,
                        allowsEditDistanceOne: allowsEditDistanceOne
                    ) {
                        return (.genre, "Genre match", score)
                    }
                }
                if scope == .genre { return nil }
            }

            if scope == .any {
                if let score = overviewSearchScore(overviewQueryTokens: overviewQueryTokens) {
                    return (.overview, "Overview match", score)
                }

                if let score = BrowseSemanticPolicy.searchScore(
                    query: query,
                    queryTokens: queryTokens,
                    normalizedText: normalizedFileName,
                    tokens: fileNameTokens,
                    franchiseKey: franchiseKey,
                    baseScore: 320,
                    allowsEditDistanceOne: allowsEditDistanceOne
                ) {
                    return (.fileName, "File name match", score)
                }
            }

            return nil
        }

        private func overviewSearchScore(overviewQueryTokens: [String]) -> Int? {
            guard let normalizedOverview, !overviewTokens.isEmpty else { return nil }
            guard !overviewQueryTokens.isEmpty else { return nil }
            if overviewQueryTokens.count == 1 {
                let queryTerm = overviewQueryTokens[0]
                return overviewTokenSet.contains(queryTerm) ? 300 + 72 : nil
            }
            let overviewQuery = overviewQueryTokens.joined(separator: " ")

            return BrowseSemanticPolicy.searchScore(
                query: overviewQuery,
                queryTokens: overviewQueryTokens,
                normalizedText: normalizedOverview,
                tokens: overviewTokens,
                franchiseKey: nil,
                baseScore: 300,
                allowsCompactMatch: false,
                allowsSubstring: false,
                allowsEditDistanceOne: false
            )
        }
    }

    fileprivate struct IndexedShow {
        let showName: String
        let representativeItemID: UUID
        let seasonCount: Int
        private let normalizedShowName: String
        private let showNameTokens: [String]
        private let showFranchiseKey: String?
        private let normalizedEpisodeTitles: [(normalized: String, tokens: [String])]
        private let normalizedGenres: [(normalized: String, tokens: [String])]
        private let normalizedOverview: String?
        private let overviewTokens: [String]
        private let overviewTokenSet: Set<String>
        private let representative: IndexedMovie

        init(_ summary: BrowseShowSummary) {
            showName = summary.showName
            representativeItemID = summary.representative.id
            seasonCount = summary.seasonCount
            normalizedShowName = BrowseSearchIndex.normalized(summary.showName)
            showNameTokens = BrowseSemanticPolicy.tokens(inNormalizedText: normalizedShowName)
            showFranchiseKey = BrowseSemanticPolicy.franchiseKey(for: summary.showName)
            normalizedEpisodeTitles = summary.episodes.map { episode in
                let normalized = BrowseSearchIndex.normalized(episode.displayEpisodeTitle)
                return (
                    normalized: normalized,
                    tokens: BrowseSemanticPolicy.tokens(inNormalizedText: normalized)
                )
            }
            normalizedGenres = summary.genres.map { genre in
                let normalized = BrowseSearchIndex.normalized(genre)
                return (
                    normalized: normalized,
                    tokens: BrowseSemanticPolicy.tokens(inNormalizedText: normalized)
                )
            }
            let episodeOverviews = summary.episodes.compactMap { episode in
                episode.metadata?.overview.map(BrowseSearchIndex.normalized)
            }
            let normalizedOverview = episodeOverviews.joined(separator: " ")
            self.normalizedOverview = normalizedOverview.isEmpty ? nil : normalizedOverview
            let overviewTokens = BrowseSemanticPolicy.overviewTokens(inNormalizedText: normalizedOverview)
            self.overviewTokens = overviewTokens
            overviewTokenSet = Set(overviewTokens)
            representative = IndexedMovie(summary.representative)
        }

        func match(
            query: String,
            queryTokens: [String],
            overviewQueryTokens: [String],
            scope: SearchScope,
            allowsEditDistanceOne: Bool
        ) -> (type: BrowseSearchMatchType, detail: String?, score: Int)? {
            if scope == .any || scope == .titleOnly {
                if let score = BrowseSemanticPolicy.searchScore(
                    query: query,
                    queryTokens: queryTokens,
                    normalizedText: normalizedShowName,
                    tokens: showNameTokens,
                    franchiseKey: scope == .any ? showFranchiseKey : nil,
                    baseScore: 900,
                    allowsSubstring: scope == .any,
                    allowsEditDistanceOne: scope == .any && allowsEditDistanceOne
                ) {
                    return (.title, nil, score)
                }

                for episodeTitle in normalizedEpisodeTitles {
                    if let score = BrowseSemanticPolicy.searchScore(
                        query: query,
                        queryTokens: queryTokens,
                        normalizedText: episodeTitle.normalized,
                        tokens: episodeTitle.tokens,
                        franchiseKey: nil,
                        baseScore: 700,
                        allowsSubstring: scope == .any,
                        allowsEditDistanceOne: scope == .any && allowsEditDistanceOne
                    ) {
                        return (.title, "Episode title match", score)
                    }
                }
                if scope == .titleOnly { return nil }
            }

            let metadataMatch = representative.match(
                query: query,
                queryTokens: queryTokens,
                overviewQueryTokens: overviewQueryTokens,
                scope: scope,
                allowsEditDistanceOne: allowsEditDistanceOne
            )

            if scope != .any {
                if let metadataMatch {
                    return metadataMatch
                }

                if scope == .genre {
                    for genre in normalizedGenres {
                        if let score = BrowseSemanticPolicy.searchScore(
                            query: query,
                            queryTokens: queryTokens,
                            normalizedText: genre.normalized,
                            tokens: genre.tokens,
                            franchiseKey: nil,
                            baseScore: 420,
                            allowsEditDistanceOne: allowsEditDistanceOne
                        ) {
                            return (.genre, "Genre match", score)
                        }
                    }
                }

                return nil
            }

            let overviewMatch = overviewSearchScore(overviewQueryTokens: overviewQueryTokens)
                .map { (type: BrowseSearchMatchType.overview, detail: "Overview match", score: $0) }

            if let metadataMatch, let overviewMatch {
                let overviewIsBetter = overviewMatch.score > metadataMatch.score
                    || (
                        overviewMatch.score == metadataMatch.score
                        && overviewMatch.type < metadataMatch.type
                    )
                if overviewIsBetter {
                    return overviewMatch
                }
                return metadataMatch
            }
            if let metadataMatch {
                return metadataMatch
            }
            if let overviewMatch {
                return overviewMatch
            }

            for genre in normalizedGenres {
                if let score = BrowseSemanticPolicy.searchScore(
                    query: query,
                    queryTokens: queryTokens,
                    normalizedText: genre.normalized,
                    tokens: genre.tokens,
                    franchiseKey: nil,
                    baseScore: 420,
                    allowsEditDistanceOne: allowsEditDistanceOne
                ) {
                    return (.genre, "Genre match", score)
                }
            }

            return nil
        }

        private func overviewSearchScore(overviewQueryTokens: [String]) -> Int? {
            guard let normalizedOverview, !overviewTokens.isEmpty else { return nil }
            guard !overviewQueryTokens.isEmpty else { return nil }
            if overviewQueryTokens.count == 1 {
                let queryTerm = overviewQueryTokens[0]
                return overviewTokenSet.contains(queryTerm) ? 300 + 72 : nil
            }
            let overviewQuery = overviewQueryTokens.joined(separator: " ")

            return BrowseSemanticPolicy.searchScore(
                query: overviewQuery,
                queryTokens: overviewQueryTokens,
                normalizedText: normalizedOverview,
                tokens: overviewTokens,
                franchiseKey: nil,
                baseScore: 300,
                allowsCompactMatch: false,
                allowsSubstring: false,
                allowsEditDistanceOne: false
            )
        }
    }

    private enum SuggestionSource {
        case movie
        case show
    }

    private struct SuggestionBucket {
        let display: String
        var movieCount: Int
        var showCount: Int

        var totalCount: Int { movieCount + showCount }

        var mediaCountText: String {
            if movieCount > 0 && showCount > 0 {
                return "\(totalCount) titles"
            }
            if showCount > 0 {
                return "\(showCount) show\(showCount == 1 ? "" : "s")"
            }
            return "\(movieCount) film\(movieCount == 1 ? "" : "s")"
        }
    }

    private static func buildSuggestionLookup(_ suggestions: [IndexedSuggestion]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: suggestions.map { ($0.normalizedValue, $0.searchQuery) })
    }

    private static func buildSuggestions(
        movies: [MediaItem],
        shows: [BrowseShowSummary]
    ) -> [IndexedSuggestion] {
        var values: [IndexedSuggestion] = []
        var seen: Set<String> = []
        var directors: [String: SuggestionBucket] = [:]
        var castMembers: [String: SuggestionBucket] = [:]
        var collections: [String: SuggestionBucket] = [:]
        var keywords: [String: SuggestionBucket] = [:]

        func append(_ value: String?, searchQuery: String? = nil) {
            guard let value else { return }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let key = normalized(trimmed)
            guard !key.isEmpty, seen.insert(key).inserted else { return }
            values.append(IndexedSuggestion(
                value: trimmed,
                normalizedValue: key,
                searchQuery: searchQuery ?? trimmed
            ))
        }

        func record(_ value: String?, in buckets: inout [String: SuggestionBucket], source: SuggestionSource) {
            guard let value else { return }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let key = normalized(trimmed)
            guard !key.isEmpty else { return }
            if var existing = buckets[key] {
                switch source {
                case .movie:
                    existing.movieCount += 1
                case .show:
                    existing.showCount += 1
                }
                buckets[key] = existing
            } else {
                let movieCount = source == .movie ? 1 : 0
                let showCount = source == .show ? 1 : 0
                buckets[key] = SuggestionBucket(
                    display: trimmed,
                    movieCount: movieCount,
                    showCount: showCount
                )
            }
        }

        func appendEntitySuggestions(
            _ buckets: [String: SuggestionBucket],
            label: String,
            scopePrefix: String
        ) {
            for bucket in buckets.values {
                append(
                    "\(bucket.display) — \(label), \(bucket.mediaCountText)",
                    searchQuery: "\(scopePrefix):\(bucket.display)"
                )
            }
        }

        for movie in movies {
            append(movie.displayTitle)
            movie.displayGenres.forEach { append($0) }
            record(movie.metadata?.director, in: &directors, source: .movie)
            record(movie.metadata?.collectionName, in: &collections, source: .movie)

            var castKeys: Set<String> = []
            movie.metadata?.cast.forEach { member in
                let key = normalized(member.name)
                guard castKeys.insert(key).inserted else { return }
                record(member.name, in: &castMembers, source: .movie)
            }

            var keywordKeys: Set<String> = []
            movie.metadata?.keywords.forEach { keyword in
                let key = normalized(keyword.name)
                guard keywordKeys.insert(key).inserted else { return }
                record(keyword.name, in: &keywords, source: .movie)
            }
        }

        for summary in shows {
            append(summary.showName)
            summary.genres.forEach { append($0) }
            record(summary.representative.metadata?.director, in: &directors, source: .show)

            var castKeys: Set<String> = []
            summary.representative.metadata?.cast.forEach { member in
                let key = normalized(member.name)
                guard castKeys.insert(key).inserted else { return }
                record(member.name, in: &castMembers, source: .show)
            }
        }

        appendEntitySuggestions(directors, label: "Director", scopePrefix: "director")
        appendEntitySuggestions(castMembers, label: "Actor", scopePrefix: "cast")
        appendEntitySuggestions(collections, label: "Collection", scopePrefix: "collection")
        appendEntitySuggestions(keywords, label: "Theme", scopePrefix: "keyword")

        return values.sorted {
            $0.value.localizedCaseInsensitiveCompare($1.value) == .orderedAscending
        }
    }

    private static func normalized(_ value: String) -> String {
        BrowseSemanticPolicy.normalizedText(value)
    }
}

// MARK: - Browse Semantics

enum BrowseSemanticPolicy {
    static func normalizedText(_ value: String) -> String {
        let folded = value
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
        var normalized = ""
        var lastWasSpace = true

        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                normalized.unicodeScalars.append(scalar)
                lastWasSpace = false
            } else if !lastWasSpace {
                normalized.append(" ")
                lastWasSpace = true
            }
        }

        return normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func tokens(inNormalizedText value: String) -> [String] {
        value.split(separator: " ").map(String.init)
    }

    static func tokens(_ value: String) -> [String] {
        tokens(inNormalizedText: normalizedText(value))
    }

    static func overviewTokens(inNormalizedText value: String) -> [String] {
        tokens(inNormalizedText: value).filter(isMeaningfulOverviewToken)
    }

    static func overviewTokens(_ value: String) -> [String] {
        overviewTokens(inNormalizedText: normalizedText(value))
    }

    static func franchiseKey(for item: MediaItem) -> String? {
        franchiseKey(for: item.displayTitle)
    }

    static func franchiseKey(for title: String) -> String? {
        let normalized = normalizedText(title)
        let titleTokens = tokens(inNormalizedText: normalized)
        guard !titleTokens.isEmpty else { return nil }

        let compact = titleTokens.joined()
        let compactRules: [(needle: String, key: String)] = [
            ("kingsman", "kingsman"),
            ("harrypotter", "harry potter"),
            ("starwars", "star wars"),
            ("missionimpossible", "mission impossible"),
            ("fastfurious", "fast furious"),
            ("jurassicpark", "jurassic"),
            ("jurassicworld", "jurassic"),
            ("lordoftherings", "middle earth"),
            ("thehobbit", "middle earth"),
            ("spiderman", "spider man"),
            ("spiderverse", "spider man"),
            ("darkknight", "batman"),
            ("batman", "batman"),
            ("xmen", "x men"),
            ("avengers", "avengers"),
            ("guardiansofthegalaxy", "guardians of the galaxy"),
        ]

        if let match = compactRules.first(where: { compact.contains($0.needle) }) {
            return match.key
        }

        let meaningful = titleTokens.filter { !["a", "an", "the"].contains($0) }
        guard let first = meaningful.first else { return nil }
        if first.count >= 5 {
            return first
        }
        if meaningful.count >= 2 {
            return meaningful.prefix(2).joined(separator: " ")
        }
        return nil
    }

    static func searchScore(
        query: String,
        queryTokens: [String],
        normalizedText: String,
        tokens: [String],
        franchiseKey: String?,
        baseScore: Int,
        allowsCompactMatch: Bool = true,
        allowsSubstring: Bool = true,
        allowsEditDistanceOne: Bool = true
    ) -> Int? {
        guard !query.isEmpty else { return nil }
        let compactQuery = queryTokens.joined()

        if normalizedText == query {
            return baseScore + 120
        }

        if allowsCompactMatch, tokens.joined() == compactQuery {
            return baseScore + 120
        }

        if let franchiseKey {
            let normalizedFranchise = Self.normalizedText(franchiseKey)
            let compactFranchise = Self.tokens(inNormalizedText: normalizedFranchise).joined()
            if compactFranchise == compactQuery {
                return baseScore + 105
            }
            if compactFranchise.hasPrefix(compactQuery) || compactFranchise.contains(compactQuery) {
                return baseScore + 92
            }
        }

        if queryTokens.count > 1,
           containsQueryTokensInOrder(queryTokens, in: tokens, prefixRequired: true) {
            return baseScore + 88
        }

        if tokens.contains(where: { $0.hasPrefix(query) }) {
            return baseScore + 72
        }

        if allowsEditDistanceOne,
           queryTokens.count > 1,
           containsQueryTokensInOrder(
            queryTokens,
            in: tokens,
            prefixRequired: true,
            allowEditDistanceOne: true
           ) {
            return baseScore + 44
        }

        if allowsEditDistanceOne,
           queryTokens.count == 1,
           query.count >= 4,
           tokens.contains(where: { isEditDistanceOne(query, $0) }) {
            return baseScore + 36
        }

        if allowsSubstring {
            if normalizedText.hasPrefix(query) || normalizedText.contains(" \(query)") {
                return baseScore + 58
            }

            if query.count >= 2, normalizedText.contains(query) {
                return baseScore + 24
            }

            if queryTokens.count > 1,
               containsQueryTokensInOrder(queryTokens, in: tokens, prefixRequired: false) {
                return baseScore + 18
            }
        }

        return nil
    }

    private static func containsQueryTokensInOrder(
        _ queryTokens: [String],
        in tokens: [String],
        prefixRequired: Bool,
        allowEditDistanceOne: Bool = false
    ) -> Bool {
        guard !queryTokens.isEmpty else { return false }
        var tokenIndex = tokens.startIndex
        for queryToken in queryTokens {
            var found = false
            while tokenIndex < tokens.endIndex {
                let candidateToken = tokens[tokenIndex]
                tokenIndex = tokens.index(after: tokenIndex)
                if tokenMatches(
                    queryToken,
                    in: candidateToken,
                    prefixRequired: prefixRequired,
                    allowEditDistanceOne: allowEditDistanceOne
                ) {
                    found = true
                    break
                }
            }
            if !found { return false }
        }
        return true
    }

    private static func tokenMatches(
        _ queryToken: String,
        in token: String,
        prefixRequired: Bool,
        allowEditDistanceOne: Bool
    ) -> Bool {
        if prefixRequired ? token.hasPrefix(queryToken) : token.contains(queryToken) {
            return true
        }
        guard allowEditDistanceOne else { return false }
        return isEditDistanceOne(queryToken, token)
    }

    private static func isEditDistanceOne(_ lhs: String, _ rhs: String) -> Bool {
        guard lhs != rhs else { return false }
        let lhsCharacters = Array(lhs)
        let rhsCharacters = Array(rhs)
        guard min(lhsCharacters.count, rhsCharacters.count) >= 4 else { return false }
        let countDelta = abs(lhsCharacters.count - rhsCharacters.count)
        guard countDelta <= 1 else { return false }

        if lhsCharacters.count == rhsCharacters.count {
            let mismatches = zip(lhsCharacters, rhsCharacters).filter { $0.0 != $0.1 }.count
            return mismatches == 1
        }

        let shorter = lhsCharacters.count < rhsCharacters.count ? lhsCharacters : rhsCharacters
        let longer = lhsCharacters.count < rhsCharacters.count ? rhsCharacters : lhsCharacters
        var shortIndex = 0
        var longIndex = 0
        var edits = 0

        while shortIndex < shorter.count && longIndex < longer.count {
            if shorter[shortIndex] == longer[longIndex] {
                shortIndex += 1
                longIndex += 1
            } else {
                edits += 1
                guard edits <= 1 else { return false }
                longIndex += 1
            }
        }

        return true
    }

    struct MovieBrowseSortKey {
        let family: String
        let year: Int?
        let title: String
    }

    /// Precomputed once per item before sorting: `franchiseKey` and
    /// `normalizedText` do diacritic folding and scalar iteration, which is
    /// far too expensive to recompute inside every sort comparison
    /// (NATIVE-C2: buildMovieRows dominated profile-select at ~800ms).
    static func movieBrowseSortKey(for item: MediaItem) -> MovieBrowseSortKey {
        MovieBrowseSortKey(
            family: franchiseKey(for: item) ?? normalizedText(item.displayTitle),
            year: item.year,
            title: item.displayTitle
        )
    }

    static func compareMovieBrowseSortKeys(_ lhs: MovieBrowseSortKey, _ rhs: MovieBrowseSortKey) -> Bool {
        if lhs.family != rhs.family {
            return lhs.family.localizedCaseInsensitiveCompare(rhs.family) == .orderedAscending
        }
        if lhs.year != rhs.year {
            return (lhs.year ?? Int.max) < (rhs.year ?? Int.max)
        }
        return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
    }

    static func compareMoviesForBrowsing(_ lhs: MediaItem, _ rhs: MediaItem) -> Bool {
        compareMovieBrowseSortKeys(movieBrowseSortKey(for: lhs), movieBrowseSortKey(for: rhs))
    }

    static func sortedMoviesForBrowsing(_ items: [MediaItem]) -> [MediaItem] {
        items
            .map { (item: $0, key: movieBrowseSortKey(for: $0)) }
            .sorted { compareMovieBrowseSortKeys($0.key, $1.key) }
            .map(\.item)
    }

    static func isHolidayMovie(_ item: MediaItem) -> Bool {
        holidayScore(for: item) > 0
    }

    static func sortedHolidayMovies(_ items: [MediaItem]) -> [MediaItem] {
        sortedHolidayMovies(items, scores: nil)
    }

    static func sortedHolidayMovies(_ items: [MediaItem], scores: [UUID: Int]?) -> [MediaItem] {
        items
            .map { (item: $0, score: scores?[$0.id] ?? holidayScore(for: $0), key: movieBrowseSortKey(for: $0)) }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return compareMovieBrowseSortKeys(lhs.key, rhs.key)
            }
            .map(\.item)
    }

    static func holidayScore(for item: MediaItem) -> Int {
        let title = normalizedText(item.displayTitle)
        let genres = item.displayGenres.map(normalizedText)
        let overview = item.metadata?.overview.map(normalizedText) ?? ""
        let haystack = ([title, overview] + genres).joined(separator: " ")

        let directSignals = [
            "christmas", "xmas", "holiday", "santa", "claus", "noel",
            "hanukkah", "chanukah", "kwanzaa", "thanksgiving", "halloween"
        ]
        if directSignals.contains(where: { haystack.contains($0) }) {
            return 100
        }

        let knownHolidayTitles = [
            "home alone",
            "elf",
            "scrooged",
            "polar express",
            "miracle on 34th street",
            "its a wonderful life",
            "nightmare before christmas",
        ]
        if knownHolidayTitles.contains(where: { title.contains($0) }) {
            return 86
        }

        return 0
    }

    static func heroScore(for item: MediaItem, newestDate: Date?) -> Double {
        var score = (item.metadata?.voteAverage ?? 0) * 100
        if item.displayBackdropPath != nil {
            score += 180
        }
        if item.displayPosterPath != nil {
            score += 50
        }
        if let duration = item.duration {
            if duration >= 4_500 { score += 30 }
            if duration < 1_200 { score -= 180 }
        }
        if let newestDate {
            let age = max(0, newestDate.timeIntervalSince(item.effectiveDate))
            let thirtyDays: TimeInterval = 60 * 60 * 24 * 30
            score += max(0, 70 - (age / thirtyDays) * 70)
        }
        return score
    }

    private static let overviewStopwords: Set<String> = [
        "about", "after", "again", "against", "along", "also",
        "and", "are", "away", "because", "been", "but", "can",
        "for", "from", "has", "have", "her", "his", "into",
        "its", "new", "not", "off", "one", "out", "over",
        "she", "the", "their", "them", "then", "they", "this",
        "through", "two", "who", "will", "with", "when",
    ]

    private static func isMeaningfulOverviewToken(_ token: String) -> Bool {
        token.count >= 3 && !overviewStopwords.contains(token)
    }
}

// MARK: - Recommendations

enum BrowseRecommendationEngine {
    static func similarMovies(
        to item: MediaItem,
        in candidates: [MediaItem],
        similarity: BrowseSimilarityIndex?,
        limit: Int = 10
    ) -> [MediaItem] {
        guard limit > 0 else { return [] }
        guard let similarity else {
            return similarMovies(to: item, in: candidates, limit: limit)
        }

        let candidatesByID = candidates.reduce(into: [UUID: MediaItem]()) { partial, candidate in
            partial[candidate.id] = candidate
        }
        var seenIDs: Set<UUID> = [item.id]
        var results: [MediaItem] = []

        for id in similarity.rankedMovieIDs(for: item.id) {
            guard let candidate = candidatesByID[id],
                  !seenIDs.contains(candidate.id) else { continue }
            results.append(candidate)
            seenIDs.insert(candidate.id)
            if results.count == limit { return results }
        }

        for candidate in similarMovies(to: item, in: candidates, limit: limit) {
            guard !seenIDs.contains(candidate.id) else { continue }
            results.append(candidate)
            seenIDs.insert(candidate.id)
            if results.count == limit { break }
        }

        return results
    }

    static func similarMovies(
        to item: MediaItem,
        in candidates: [MediaItem],
        limit: Int = 10
    ) -> [MediaItem] {
        rankedMovies(to: item, in: candidates)
            .prefix(limit)
            .map(\.item)
    }

    static func similarShows(
        to summary: BrowseShowSummary,
        in candidates: [BrowseShowSummary],
        similarity: BrowseSimilarityIndex?,
        limit: Int = 10
    ) -> [BrowseShowSummary] {
        guard limit > 0 else { return [] }
        guard let similarity else {
            return similarShows(to: summary, in: candidates, limit: limit)
        }

        let candidatesByName = candidates.reduce(into: [String: BrowseShowSummary]()) { partial, candidate in
            partial[candidate.showName] = candidate
        }
        var seenNames: Set<String> = [summary.showName]
        var results: [BrowseShowSummary] = []

        for name in similarity.rankedShowNames(for: summary.showName) {
            guard let candidate = candidatesByName[name],
                  !seenNames.contains(candidate.showName) else { continue }
            results.append(candidate)
            seenNames.insert(candidate.showName)
            if results.count == limit { return results }
        }

        for candidate in similarShows(to: summary, in: candidates, limit: limit) {
            guard !seenNames.contains(candidate.showName) else { continue }
            results.append(candidate)
            seenNames.insert(candidate.showName)
            if results.count == limit { break }
        }

        return results
    }

    static func similarShows(
        to summary: BrowseShowSummary,
        in candidates: [BrowseShowSummary],
        limit: Int = 10
    ) -> [BrowseShowSummary] {
        let ranked = candidates.compactMap { candidate -> (summary: BrowseShowSummary, score: Int)? in
            guard candidate.showName != summary.showName else { return nil }
            let score = similarityScore(
                sourceTitle: summary.showName,
                sourceItem: summary.representative,
                candidateTitle: candidate.showName,
                candidateItem: candidate.representative
            )
            guard score > 0 else { return nil }
            return (candidate, score)
        }
        .sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.summary.showName.localizedCaseInsensitiveCompare(rhs.summary.showName) == .orderedAscending
        }

        return ranked.prefix(limit).map(\.summary)
    }

    private static func rankedMovies(
        to item: MediaItem,
        in candidates: [MediaItem]
    ) -> [(item: MediaItem, score: Int)] {
        candidates.compactMap { candidate -> (item: MediaItem, score: Int)? in
            guard candidate.id != item.id else { return nil }
            let score = similarityScore(
                sourceTitle: item.displayTitle,
                sourceItem: item,
                candidateTitle: candidate.displayTitle,
                candidateItem: candidate
            )
            guard score > 0 else { return nil }
            return (candidate, score)
        }
        .sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return BrowseSemanticPolicy.compareMoviesForBrowsing(lhs.item, rhs.item)
        }
    }

    private static func similarityScore(
        sourceTitle: String,
        sourceItem: MediaItem,
        candidateTitle: String,
        candidateItem: MediaItem
    ) -> Int {
        var score = 0

        let sourceFamily = BrowseSemanticPolicy.franchiseKey(for: sourceTitle)
        let candidateFamily = BrowseSemanticPolicy.franchiseKey(for: candidateTitle)
        if let sourceFamily, sourceFamily == candidateFamily {
            score += 1_000
            if let sourceYear = sourceItem.year, let candidateYear = candidateItem.year {
                score += max(0, 80 - abs(candidateYear - sourceYear) * 4)
            }
        }

        let sourceGenres = Set(sourceItem.displayGenres.map(BrowseSemanticPolicy.normalizedText))
        let candidateGenres = Set(candidateItem.displayGenres.map(BrowseSemanticPolicy.normalizedText))
        let sharedGenres = sourceGenres.intersection(candidateGenres)
        score += sharedGenres.reduce(0) { partial, genre in
            partial + genreWeight(genre)
        }

        if let sourceDirector = sourceItem.metadata?.director,
           let candidateDirector = candidateItem.metadata?.director,
           BrowseSemanticPolicy.normalizedText(sourceDirector) == BrowseSemanticPolicy.normalizedText(candidateDirector) {
            score += 160
        }

        let sourceCast = Set((sourceItem.metadata?.cast ?? []).map { BrowseSemanticPolicy.normalizedText($0.name) })
        let candidateCast = Set((candidateItem.metadata?.cast ?? []).map { BrowseSemanticPolicy.normalizedText($0.name) })
        score += min(160, sourceCast.intersection(candidateCast).count * 32)

        if let sourceDecade = sourceItem.decade,
           let candidateDecade = candidateItem.decade,
           sourceDecade == candidateDecade {
            score += 20
        }

        if BrowseSemanticPolicy.isHolidayMovie(sourceItem),
           BrowseSemanticPolicy.isHolidayMovie(candidateItem) {
            score += 120
        }

        return score
    }

    private static func genreWeight(_ genre: String) -> Int {
        switch genre {
        case "science fiction", "sci fi", "fantasy", "animation", "family", "horror", "mystery":
            return 70
        case "adventure", "comedy", "thriller", "crime", "music", "musical":
            return 46
        case "action", "drama":
            return 28
        default:
            return 36
        }
    }
}

// MARK: - Similarity Index

struct BrowseSimilarityIndex {
    private let movieIDsBySourceID: [UUID: [UUID]]
    private let showNamesBySourceName: [String: [String]]

    struct PreparedInput {
        fileprivate let movieProfiles: [SimilarityProfile<UUID>]
        fileprivate let showProfiles: [SimilarityProfile<String>]
    }

    static func prepareInput(
        movies: [MediaItem],
        showSummaries: [BrowseShowSummary]
    ) -> PreparedInput {
        PreparedInput(
            movieProfiles: movies.map(movieProfile),
            showProfiles: showSummaries.map(showProfile)
        )
    }

    static func build(
        movies: [MediaItem],
        showSummaries: [BrowseShowSummary],
        limit: Int = 12
    ) -> BrowseSimilarityIndex {
        build(
            preparedInput: prepareInput(movies: movies, showSummaries: showSummaries),
            limit: limit
        )
    }

    static func build(
        preparedInput: PreparedInput,
        limit: Int = 12
    ) -> BrowseSimilarityIndex {
        return BrowseSimilarityIndex(
            movieIDsBySourceID: rankedIDsBySource(profiles: preparedInput.movieProfiles, limit: limit),
            showNamesBySourceName: rankedIDsBySource(profiles: preparedInput.showProfiles, limit: limit)
        )
    }

    func rankedMovieIDs(for sourceID: UUID) -> [UUID] {
        movieIDsBySourceID[sourceID] ?? []
    }

    func rankedShowNames(for sourceName: String) -> [String] {
        showNamesBySourceName[sourceName] ?? []
    }

    private static func rankedIDsBySource<ID: Hashable>(
        profiles: [SimilarityProfile<ID>],
        limit: Int
    ) -> [ID: [ID]] {
        guard profiles.count > 1, limit > 0 else { return [:] }
        let genreWeights = makeGenreWeights(for: profiles)
        var ranked: [ID: [ID]] = [:]
        ranked.reserveCapacity(profiles.count)

        for source in profiles {
            var topCandidates: [SimilarityCandidate<ID>] = []
            topCandidates.reserveCapacity(limit)

            for candidate in profiles {
                guard candidate.id != source.id else { continue }
                let score = similarityScore(
                    source: source,
                    candidate: candidate,
                    genreWeights: genreWeights
                )
                guard score > 0 else { continue }
                insert(
                    SimilarityCandidate<ID>(profile: candidate, score: score),
                    into: &topCandidates,
                    source: source,
                    limit: limit
                )
            }

            ranked[source.id] = topCandidates.map { $0.profile.id }
        }

        return ranked
    }

    private static func similarityScore<ID>(
        source: SimilarityProfile<ID>,
        candidate: SimilarityProfile<ID>,
        genreWeights: [String: Double]
    ) -> Double {
        var baseScore = 0.0

        if let sourceFamily = source.franchiseKey,
           sourceFamily == candidate.franchiseKey {
            baseScore += 260
            if let sourceYear = source.year, let candidateYear = candidate.year {
                baseScore += max(0, 55 - Double(abs(candidateYear - sourceYear)) * 2.5)
            }
        }

        if let sourceDirector = source.director,
           sourceDirector == candidate.director {
            baseScore += 150
        }

        baseScore += castOverlapScore(source: source, candidate: candidate)

        let sharedGenres = source.genres.intersection(candidate.genres)
        for genre in sharedGenres {
            baseScore += genreWeights[genre] ?? 24
        }

        baseScore += overviewSimilarity(source: source, candidate: candidate) * 90

        guard baseScore > 0 else { return 0 }

        var score = baseScore
        if let sourceVote = source.voteAverage,
           let candidateVote = candidate.voteAverage {
            score += max(0, 22 - abs(sourceVote - candidateVote) * 3.0)
        }
        score += qualityPrior(for: candidate)

        return score
    }

    private static func castOverlapScore<ID>(
        source: SimilarityProfile<ID>,
        candidate: SimilarityProfile<ID>
    ) -> Double {
        var score = 0.0
        for (person, sourceRank) in source.castRankByName {
            guard let candidateRank = candidate.castRankByName[person] else { continue }
            let bestRank = min(sourceRank, candidateRank)
            let worstRank = max(sourceRank, candidateRank)
            score += max(18, 135 - Double(bestRank) * 22 - Double(worstRank) * 8)
        }
        return min(score, 240)
    }

    private static func overviewSimilarity<ID>(
        source: SimilarityProfile<ID>,
        candidate: SimilarityProfile<ID>
    ) -> Double {
        guard !source.overviewTokens.isEmpty, !candidate.overviewTokens.isEmpty else {
            return 0
        }
        let shared = source.overviewTokens.intersection(candidate.overviewTokens).count
        guard shared > 0 else { return 0 }
        let denominator = sqrt(Double(source.overviewTokens.count * candidate.overviewTokens.count))
        guard denominator > 0 else { return 0 }
        return Double(shared) / denominator
    }

    private static func makeGenreWeights<ID>(
        for profiles: [SimilarityProfile<ID>]
    ) -> [String: Double] {
        var documentFrequency: [String: Int] = [:]
        for profile in profiles {
            for genre in profile.genres {
                documentFrequency[genre, default: 0] += 1
            }
        }

        let total = Double(max(profiles.count, 1))
        return documentFrequency.mapValues { count in
            let idf = log((total + 1) / (Double(count) + 1))
            return min(96, 18 + idf * 72)
        }
    }

    private static func compare<ID>(
        _ lhs: SimilarityCandidate<ID>,
        _ rhs: SimilarityCandidate<ID>,
        source: SimilarityProfile<ID>
    ) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        let lhsQualityPrior = qualityPrior(for: lhs.profile)
        let rhsQualityPrior = qualityPrior(for: rhs.profile)
        if lhsQualityPrior != rhsQualityPrior {
            return lhsQualityPrior > rhsQualityPrior
        }
        if lhs.profile.effectiveDate != rhs.profile.effectiveDate {
            return lhs.profile.effectiveDate > rhs.profile.effectiveDate
        }
        let lhsYearDistance = yearDistance(lhs.profile.year, from: source.year)
        let rhsYearDistance = yearDistance(rhs.profile.year, from: source.year)
        if lhsYearDistance != rhsYearDistance {
            return lhsYearDistance < rhsYearDistance
        }
        return lhs.profile.deterministicRank < rhs.profile.deterministicRank
    }

    private static func insert<ID>(
        _ candidate: SimilarityCandidate<ID>,
        into topCandidates: inout [SimilarityCandidate<ID>],
        source: SimilarityProfile<ID>,
        limit: Int
    ) {
        if topCandidates.count == limit,
           let weakest = topCandidates.last,
           !compare(candidate, weakest, source: source) {
            return
        }

        let index = topCandidates.firstIndex {
            compare(candidate, $0, source: source)
        } ?? topCandidates.endIndex
        topCandidates.insert(candidate, at: index)
        if topCandidates.count > limit {
            topCandidates.removeLast()
        }
    }

    private static func movieProfile(_ item: MediaItem) -> SimilarityProfile<UUID> {
        SimilarityProfile<UUID>(
            id: item.id,
            item: item,
            title: item.displayTitle,
            deterministicRank: item.id.uuidString
        )
    }

    private static func showProfile(_ summary: BrowseShowSummary) -> SimilarityProfile<String> {
        SimilarityProfile<String>(
            id: summary.showName,
            item: summary.representative,
            title: summary.showName,
            deterministicRank: summary.representative.id.uuidString
        )
    }

    private static func qualityPrior<ID>(for profile: SimilarityProfile<ID>) -> Double {
        (profile.voteAverage ?? 0) * 8
    }

    private static func yearDistance(_ year: Int?, from sourceYear: Int?) -> Int {
        guard let year, let sourceYear else { return Int.max }
        return abs(year - sourceYear)
    }

    private struct SimilarityCandidate<ID: Hashable> {
        let profile: SimilarityProfile<ID>
        let score: Double
    }

    fileprivate struct SimilarityProfile<ID: Hashable> {
        let id: ID
        let year: Int?
        let effectiveDate: Date
        let franchiseKey: String?
        let director: String?
        let genres: Set<String>
        let castRankByName: [String: Int]
        let overviewTokens: Set<String>
        let voteAverage: Double?
        let deterministicRank: String

        init(
            id: ID,
            item: MediaItem,
            title: String,
            deterministicRank: String
        ) {
            self.id = id
            year = item.year
            effectiveDate = item.effectiveDate
            franchiseKey = BrowseSemanticPolicy.franchiseKey(for: title)
            director = Self.normalizedNonEmpty(item.metadata?.director)
            genres = Set(item.displayGenres.map(BrowseSemanticPolicy.normalizedText))
            castRankByName = Self.castRanks(item.metadata?.cast ?? [])
            overviewTokens = Self.overviewTokens(item.metadata?.overview)
            voteAverage = item.metadata?.voteAverage
            self.deterministicRank = deterministicRank
        }

        private static func castRanks(_ cast: [TMDBMetadata.CastEntry]) -> [String: Int] {
            var ranks: [String: Int] = [:]
            for (index, entry) in cast.enumerated() {
                let key = BrowseSemanticPolicy.normalizedText(entry.name)
                guard !key.isEmpty, ranks[key] == nil else { continue }
                ranks[key] = index
            }
            return ranks
        }

        private static func normalizedNonEmpty(_ value: String?) -> String? {
            guard let normalized = value.map(BrowseSemanticPolicy.normalizedText),
                  !normalized.isEmpty else { return nil }
            return normalized
        }

        private static func overviewTokens(_ overview: String?) -> Set<String> {
            guard let overview else { return [] }
            return Set(BrowseSemanticPolicy.overviewTokens(overview))
        }
    }
}

// MARK: - Snapshot Builder

enum BrowseSnapshotBuilder {

    static func build(
        movies: [MediaItem],
        tvEpisodes: [MediaItem],
        reusingMovieSearchEntriesFrom previousIndex: BrowseSearchIndex? = nil,
        tasteProfile: BrowseTasteProfile? = nil,
        seasonalDate: Date = Date()
    ) -> BrowseSnapshot {
        let showSummaries = buildShowSummaries(from: tvEpisodes)
        let showRepresentatives = showSummaries.map(\.representative)
        let allDisplayItems = movies + showRepresentatives
        let tasteModel = BrowseTasteModel(tasteProfile: tasteProfile, sourceItems: movies + tvEpisodes)
        let holidayScores = allDisplayItems.reduce(into: [UUID: Int]()) {
            $0[$1.id] = BrowseSemanticPolicy.holidayScore(for: $1)
        }

        let homeRows = buildHomeRows(
            movies: movies,
            showSummaries: showSummaries,
            allDisplayItems: allDisplayItems,
            holidayScores: holidayScores,
            tasteModel: tasteModel,
            seasonalDate: seasonalDate
        )
        let movieRows = buildMovieRows(from: movies, holidayScores: holidayScores)
        let showRows = buildShowRows(from: showSummaries)
        let heroSpotlights = HeroSpotlightBuilder.build(
            from: allDisplayItems,
            holidayScores: holidayScores,
            tasteModel: tasteModel
        )
        let searchIndex = previousIndex.map { BrowseSearchIndex(filteringMoviesFrom: $0, movies: movies, shows: showSummaries) }
            ?? BrowseSearchIndex(movies: movies, shows: showSummaries)

        return BrowseSnapshot(
            heroSpotlights: heroSpotlights,
            homeRows: homeRows,
            movieRows: movieRows,
            showRows: showRows,
            showSummaries: showSummaries,
            searchIndex: searchIndex,
            similarity: nil,
            tasteProfile: tasteProfile
        )
    }

    static func refreshProgressRows(
        movies: [MediaItem],
        tvEpisodes: [MediaItem],
        existing: BrowseSnapshot,
        tasteProfile: BrowseTasteProfile? = nil,
        seasonalDate: Date = Date()
    ) -> BrowseSnapshot {
        guard !existing.showSummaries.isEmpty || !tvEpisodes.isEmpty else {
            return build(
                movies: movies,
                tvEpisodes: tvEpisodes,
                tasteProfile: tasteProfile,
                seasonalDate: seasonalDate
            ).withSimilarity(existing.similarity)
        }

        let showSummaries = refreshShowSummaries(existing.showSummaries, fallbackEpisodes: tvEpisodes)
        let tasteModel = BrowseTasteModel(tasteProfile: tasteProfile, sourceItems: movies + tvEpisodes)

        return BrowseSnapshot(
            heroSpotlights: refreshHeroSpotlights(
                movies: movies,
                showSummaries: showSummaries,
                similarity: existing.similarity,
                tasteModel: tasteModel
            ),
            homeRows: homeRowsAfterProgressRefresh(
                existing: existing.homeRows,
                movies: movies,
                showSummaries: showSummaries,
                tasteModel: tasteModel,
                similarity: existing.similarity,
                seasonalDate: seasonalDate
            ),
            movieRows: existing.movieRows,
            showRows: refreshShowRows(existing.showRows, summaries: showSummaries),
            showSummaries: showSummaries,
            searchIndex: existing.searchIndex,
            similarity: existing.similarity,
            tasteProfile: tasteProfile
        )
    }

    private static func refreshShowSummaries(
        _ existing: [BrowseShowSummary],
        fallbackEpisodes: [MediaItem]
    ) -> [BrowseShowSummary] {
        guard !existing.isEmpty else {
            return buildShowSummaries(from: fallbackEpisodes)
        }

        return existing.map { summary in
            BrowseShowSummary(
                showName: summary.showName,
                representative: summary.representative,
                episodes: summary.episodes,
                upNext: upNextEpisode(from: summary.episodes),
                seasonCount: summary.seasonCount,
                genres: summary.genres
            )
        }
    }

    private static func refreshShowRows(
        _ existing: [BrowseShowRow],
        summaries: [BrowseShowSummary]
    ) -> [BrowseShowRow] {
        guard !existing.isEmpty else {
            return buildShowRows(from: summaries)
        }

        let summaryByName = Dictionary(uniqueKeysWithValues: summaries.map { ($0.showName, $0) })
        return existing.compactMap { row in
            let shows = row.shows.compactMap { summaryByName[$0.showName] }
            guard !shows.isEmpty else { return nil }
            return BrowseShowRow(id: row.id, title: row.title, shows: shows)
        }
    }

    private static func homeRowsAfterProgressRefresh(
        existing: [BrowseMediaRow],
        movies: [MediaItem],
        showSummaries: [BrowseShowSummary],
        tasteModel: BrowseTasteModel?,
        similarity: BrowseSimilarityIndex?,
        seasonalDate: Date = Date()
    ) -> [BrowseMediaRow] {
        guard !existing.isEmpty else {
            let allDisplayItems = movies + showSummaries.map(\.representative)
            return buildHomeRows(
                movies: movies,
                showSummaries: showSummaries,
                allDisplayItems: allDisplayItems,
                tasteModel: tasteModel,
                similarity: similarity,
                seasonalDate: seasonalDate
            )
        }
        return homeRowsWithTaste(
            movies: movies,
            showSummaries: showSummaries,
            tasteModel: tasteModel,
            similarity: similarity,
            seasonalDate: seasonalDate
        )
    }

    private static func refreshHeroSpotlights(
        movies: [MediaItem],
        showSummaries: [BrowseShowSummary],
        similarity: BrowseSimilarityIndex?,
        tasteModel: BrowseTasteModel?
    ) -> [HeroSpotlight] {
        HeroSpotlightBuilder.build(
            from: movies + showSummaries.map(\.representative),
            similarity: similarity,
            tasteModel: tasteModel
        )
    }

    static func homeRowsWithTaste(
        movies: [MediaItem],
        showSummaries: [BrowseShowSummary],
        tasteProfile: BrowseTasteProfile?,
        similarity: BrowseSimilarityIndex?,
        seasonalDate: Date = Date()
    ) -> [BrowseMediaRow] {
        let tasteModel = BrowseTasteModel(
            tasteProfile: tasteProfile,
            sourceItems: movies + showSummaries.flatMap(\.episodes)
        )
        return homeRowsWithTaste(
            movies: movies,
            showSummaries: showSummaries,
            tasteModel: tasteModel,
            similarity: similarity,
            seasonalDate: seasonalDate
        )
    }

    private static func homeRowsWithTaste(
        movies: [MediaItem],
        showSummaries: [BrowseShowSummary],
        tasteModel: BrowseTasteModel?,
        similarity: BrowseSimilarityIndex?,
        seasonalDate: Date = Date()
    ) -> [BrowseMediaRow] {
        buildHomeRows(
            movies: movies,
            showSummaries: showSummaries,
            allDisplayItems: movies + showSummaries.map(\.representative),
            tasteModel: tasteModel,
            similarity: similarity,
            seasonalDate: seasonalDate
        )
    }

    private static func buildHomeRows(
        movies: [MediaItem],
        showSummaries: [BrowseShowSummary],
        allDisplayItems: [MediaItem],
        holidayScores: [UUID: Int]? = nil,
        tasteModel: BrowseTasteModel? = nil,
        similarity: BrowseSimilarityIndex? = nil,
        seasonalDate: Date = Date()
    ) -> [BrowseMediaRow] {
        guard !movies.isEmpty || !showSummaries.isEmpty else { return [] }

        var rows: [BrowseMediaRow] = []

        let continueWatching = continueWatchingItems(movies: movies, showSummaries: showSummaries)
        if !continueWatching.isEmpty {
            rows.append(BrowseMediaRow(id: "continue-watching", title: "Continue Watching", items: continueWatching))
        }

        let watched = recentlyWatchedItems(movies: movies, showSummaries: showSummaries)
        if !watched.isEmpty {
            rows.append(BrowseMediaRow(id: "recently-watched", title: "Recently Watched", items: watched))
        }

        if let playSomething = BrowseLeanBackDelightPolicy.playSomethingRow(
            movies: movies,
            showSummaries: showSummaries,
            tasteModel: tasteModel
        ) {
            rows.append(playSomething)
        }

        rows += tasteRows(
            movies: movies,
            tasteModel: tasteModel,
            similarity: similarity
        )

        rows += BrowseLeanBackDelightPolicy.seasonalRows(movies: movies, date: seasonalDate)

        let recentlyAdded = allDisplayItems.sorted { $0.effectiveDate > $1.effectiveDate }
        if !recentlyAdded.isEmpty {
            rows.append(BrowseMediaRow(id: "recently-added", title: "Recently Added", items: recentlyAdded))
        }

        let holidayCandidates = movies.filter {
            (holidayScores?[$0.id] ?? BrowseSemanticPolicy.holidayScore(for: $0)) > 0
        }
        let holidayMovies = BrowseSemanticPolicy.sortedHolidayMovies(holidayCandidates, scores: holidayScores)
        if holidayMovies.count >= 2 {
            rows.append(BrowseMediaRow(id: "holiday-movies", title: "Holiday Movies", items: holidayMovies))
        }

        for group in decadeGroups(from: movies) {
            rows.append(BrowseMediaRow(id: "decade-\(group.decade)s", title: "The \(group.decade)s", items: group.items))
        }

        if !movies.isEmpty {
            rows.append(BrowseMediaRow(id: "all-movies", title: "All Movies", items: movies))
        }

        return rows
    }

    private enum BrowseTasteRowsPolicy {
        static let rankedRowLimit = 12
        static let minimumSmallRowCount = 2
        static let hiddenGemMinimumVoteAverage = 7.5
        static let hiddenGemMinimumVoteCount = 50
        static let shortTonightRuntimeLimitSeconds: TimeInterval = 100 * 60
        static let completedSeedLimit = 3
        static let becauseYouWatchedRowLimit = 12
        static let becauseYouWatchedMinimumCount = 4
    }

    private static func tasteRows(
        movies: [MediaItem],
        tasteModel: BrowseTasteModel?,
        similarity: BrowseSimilarityIndex?
    ) -> [BrowseMediaRow] {
        guard let tasteModel else { return [] }

        var rows: [BrowseMediaRow] = []
        rows += becauseYouWatchedRows(
            movies: movies,
            tasteModel: tasteModel,
            similarity: similarity
        )

        let hiddenGems = movies.filter { item in
            guard tasteModel.isUnwatched(item) else { return false }
            guard (item.metadata?.voteAverage ?? 0) >= BrowseTasteRowsPolicy.hiddenGemMinimumVoteAverage else { return false }
            guard (item.metadata?.voteCount ?? 0) >= BrowseTasteRowsPolicy.hiddenGemMinimumVoteCount else { return false }
            return true
        }
        let rankedHiddenGems = tasteModel.rankedCandidates(hiddenGems, limit: BrowseTasteRowsPolicy.rankedRowLimit)
        if rankedHiddenGems.count >= BrowseTasteRowsPolicy.minimumSmallRowCount {
            rows.append(BrowseMediaRow(id: "hidden-gems", title: "Hidden Gems", items: rankedHiddenGems))
        }

        let shortTonight = movies.filter { item in
            guard tasteModel.isUnwatched(item) else { return false }
            guard let runtime = runtimeSeconds(for: item),
                  runtime <= BrowseTasteRowsPolicy.shortTonightRuntimeLimitSeconds else { return false }
            return true
        }
        let rankedShortTonight = tasteModel.rankedCandidates(shortTonight, limit: BrowseTasteRowsPolicy.rankedRowLimit)
        if rankedShortTonight.count >= BrowseTasteRowsPolicy.minimumSmallRowCount {
            rows.append(BrowseMediaRow(id: "short-tonight", title: "Short Tonight", items: rankedShortTonight))
        }

        return rows
    }

    private static func becauseYouWatchedRows(
        movies: [MediaItem],
        tasteModel: BrowseTasteModel,
        similarity: BrowseSimilarityIndex?
    ) -> [BrowseMediaRow] {
        return tasteModel.completedSeeds(from: movies, limit: BrowseTasteRowsPolicy.completedSeedLimit).compactMap { seed in
            let items = BrowseRecommendationEngine.similarMovies(
                to: seed,
                in: movies,
                similarity: similarity,
                limit: movies.count
            )
            .filter(tasteModel.isUnwatched)
            .prefix(BrowseTasteRowsPolicy.becauseYouWatchedRowLimit)
            guard items.count >= BrowseTasteRowsPolicy.becauseYouWatchedMinimumCount else { return nil }
            return BrowseMediaRow(
                id: "because-you-watched-\(seed.id.uuidString)",
                title: "Because You Watched \(seed.displayTitle)",
                items: Array(items)
            )
        }
    }

    private static func runtimeSeconds(for item: MediaItem) -> TimeInterval? {
        if let duration = item.duration, duration > 0 {
            return duration
        }
        if let runtime = item.metadata?.runtime, runtime > 0 {
            return TimeInterval(runtime * 60)
        }
        return nil
    }

    private static func continueWatchingItems(
        movies: [MediaItem],
        showSummaries: [BrowseShowSummary]
    ) -> [MediaItem] {
        var results = movies.filter { $0.hasProgress }
        results += showSummaries.compactMap { summary in
            guard let upNext = summary.upNext, upNext.hasProgress else { return nil }
            return upNext
        }
        return results.sorted {
            ($0.lastPlayedDate ?? .distantPast) > ($1.lastPlayedDate ?? .distantPast)
        }
    }

    private static func recentlyWatchedItems(
        movies: [MediaItem],
        showSummaries: [BrowseShowSummary]
    ) -> [MediaItem] {
        var results = movies.filter { $0.isWatched && $0.lastPlayedDate != nil }
        results += showSummaries.compactMap { summary in
            summary.episodes
                .filter { $0.isWatched && $0.lastPlayedDate != nil }
                .sorted { ($0.lastPlayedDate ?? .distantPast) > ($1.lastPlayedDate ?? .distantPast) }
                .first
        }
        return results.sorted {
            ($0.lastPlayedDate ?? .distantPast) > ($1.lastPlayedDate ?? .distantPast)
        }
    }

    private static func buildMovieRows(from movies: [MediaItem], holidayScores: [UUID: Int]? = nil) -> [BrowseMediaRow] {
        guard !movies.isEmpty else { return [] }
        var grouped: [String: [MediaItem]] = [:]
        for item in movies {
            let genres = item.displayGenres
            for genre in genres.isEmpty ? ["Other"] : genres {
                grouped[genre, default: []].append(item)
            }
        }

        let allItemIDs = Set(movies.map(\.id))
        var rows: [BrowseMediaRow] = []
        let sortedAll = BrowseSemanticPolicy.sortedMoviesForBrowsing(movies)

        let holidayCandidates = movies.filter {
            (holidayScores?[$0.id] ?? BrowseSemanticPolicy.holidayScore(for: $0)) > 0
        }
        let holidayMovies = BrowseSemanticPolicy.sortedHolidayMovies(holidayCandidates, scores: holidayScores)
        if holidayMovies.count >= 2 {
            rows.append(BrowseMediaRow(id: "holiday-movies", title: "Holiday Movies", items: holidayMovies))
        }

        rows += grouped
            .filter {
                $0.key != "Other"
                    && !$0.value.isEmpty
                    && Set($0.value.map(\.id)) != allItemIDs
            }
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { genre, items in
                let rowIDs = Set(items.map(\.id))
                return BrowseMediaRow(
                    id: "genre-\(genre)",
                    title: genre,
                    items: sortedAll.filter { rowIDs.contains($0.id) }
                )
            }

        rows.append(BrowseMediaRow(id: "all-movies", title: "All Movies", items: sortedAll))
        return rows
    }

    private static func buildShowRows(from summaries: [BrowseShowSummary]) -> [BrowseShowRow] {
        guard !summaries.isEmpty else { return [] }

        var grouped: [String: [BrowseShowSummary]] = [:]
        for summary in summaries {
            let genres = summary.genres
            for genre in genres.isEmpty ? ["Other"] : genres {
                grouped[genre, default: []].append(summary)
            }
        }

        var rows = grouped
            .filter { $0.key != "Other" && !$0.value.isEmpty }
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { genre, shows in
                BrowseShowRow(
                    id: "genre-\(genre)",
                    title: genre,
                    shows: shows.sorted {
                        $0.showName.localizedCaseInsensitiveCompare($1.showName) == .orderedAscending
                    }
                )
            }

        rows.append(BrowseShowRow(id: "all-shows", title: "All Shows", shows: summaries))
        return rows
    }

    private static func buildShowSummaries(from episodes: [MediaItem]) -> [BrowseShowSummary] {
        var grouped: [String: [MediaItem]] = [:]
        for episode in episodes {
            guard let showName = episode.showName else { continue }
            grouped[showName, default: []].append(episode)
        }

        return grouped
            .map { showName, episodes in
                let sortedEpisodes = sortEpisodes(episodes)
                let representative = sortedEpisodes[0]
                return BrowseShowSummary(
                    showName: showName,
                    representative: representative,
                    episodes: sortedEpisodes,
                    upNext: upNextEpisode(from: sortedEpisodes),
                    seasonCount: Set(sortedEpisodes.compactMap(\.seasonNumber)).count,
                    genres: representative.displayGenres
                )
            }
            .sorted {
                $0.showName.localizedCaseInsensitiveCompare($1.showName) == .orderedAscending
            }
    }

    private static func sortEpisodes(_ episodes: [MediaItem]) -> [MediaItem] {
        episodes.sorted {
            if $0.seasonNumber != $1.seasonNumber {
                return ($0.seasonNumber ?? 0) < ($1.seasonNumber ?? 0)
            }
            return ($0.episodeNumber ?? 0) < ($1.episodeNumber ?? 0)
        }
    }

    private static func upNextEpisode(from episodes: [MediaItem]) -> MediaItem? {
        if let lastIndex = episodes.lastIndex(where: { $0.isWatched || $0.hasProgress }) {
            if episodes[lastIndex].hasProgress {
                return episodes[lastIndex]
            }
            let nextIndex = lastIndex + 1
            if nextIndex < episodes.count {
                return episodes[nextIndex]
            }
            return nil
        }
        return episodes.first
    }

    private static func decadeGroups(from movies: [MediaItem]) -> [(decade: Int, items: [MediaItem])] {
        var grouped: [Int: [MediaItem]] = [:]
        for item in movies {
            guard let decade = item.decade else { continue }
            grouped[decade, default: []].append(item)
        }

        return grouped
            .filter { $0.value.count >= 2 }
            .sorted { $0.key > $1.key }
            .map { decade, items in
                (
                    decade: decade,
                    items: items.sorted {
                        $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                    }
                )
            }
    }
}
