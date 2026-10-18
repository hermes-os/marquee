//
//  VerifyBrowseSnapshotHarness.swift
//  Marquee
//
//  DEBUG-only verification for precomputed browse rows and local search index.
//  Activated by `--verify-browse-snapshots`.
//

#if DEBUG

import Foundation

enum VerifyBrowseSnapshotHarness {
    static let launchArgument = "--verify-browse-snapshots"

    // Seasonal home rows depend on the calendar month, so row-list assertions pin a
    // mid-March noon (no seasonal row) built in the same local calendar the policy reads.
    private static let nonSeasonalDate = DateComponents(
        calendar: Calendar(identifier: .gregorian),
        year: 2026,
        month: 3,
        day: 15,
        hour: 12
    ).date!

    static func runIfRequested() {
        guard CommandLine.arguments.contains(launchArgument) else { return }

        do {
            let detail = try runScenario()
            FileHandle.standardError.write(Data("verify-browse-snapshots: PASS buildsRowsAndSearchIndex: \(detail)\n".utf8))
            FileHandle.standardError.write(Data("verify-browse-snapshots: outcome=verified passed=1/1\n".utf8))
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("verify-browse-snapshots: FAIL buildsRowsAndSearchIndex: \(error)\n".utf8))
            FileHandle.standardError.write(Data("verify-browse-snapshots: outcome=failed passed=0/1\n".utf8))
            exit(1)
        }
    }

    private static func runScenario() throws -> String {
        let movieA = makeMovie(
            title: "Alien",
            year: 1979,
            genres: ["Science Fiction", "Horror"],
            position: 1800,
            lastPlayed: Date(timeIntervalSince1970: 2_000),
            dateAdded: Date(timeIntervalSince1970: 1_000),
            director: "Ridley Scott",
            cast: [
                TMDBMetadata.CastEntry(
                    name: "Sigourney Weaver",
                    character: "Ripley",
                    profilePath: nil,
                    tmdbPersonID: 1
                )
            ]
        )
        let movieB = makeMovie(
            title: "Arrival",
            year: 2016,
            genres: ["Science Fiction"],
            position: 0,
            lastPlayed: nil,
            dateAdded: Date(timeIntervalSince1970: 3_000)
        )
        let movieC = makeMovie(
            title: "Annihilation",
            year: 2018,
            genres: ["Science Fiction", "Horror"],
            position: 0,
            lastPlayed: nil,
            dateAdded: Date(timeIntervalSince1970: 2_500)
        )
        let episode1 = makeEpisode(
            show: "Severance",
            title: "Good News About Hell",
            season: 1,
            episode: 1,
            genres: ["Thriller"],
            position: 0,
            watched: true,
            lastPlayed: Date(timeIntervalSince1970: 4_000),
            dateAdded: Date(timeIntervalSince1970: 1_500)
        )
        let episode2 = makeEpisode(
            show: "Severance",
            title: "Half Loop",
            season: 1,
            episode: 2,
            genres: ["Thriller"],
            position: 300,
            watched: false,
            lastPlayed: Date(timeIntervalSince1970: 5_000),
            dateAdded: Date(timeIntervalSince1970: 2_500)
        )

        let snapshot = BrowseSnapshotBuilder.build(
            movies: [movieA, movieB, movieC],
            tvEpisodes: [episode1, episode2],
            seasonalDate: nonSeasonalDate
        )

        try assert(snapshot.homeRows.map(\.id) == [
            "continue-watching",
            "recently-watched",
            "play-something",
            "recently-added",
            "decade-2010s",
            "all-movies",
        ], "unexpected home row order: \(snapshot.homeRows.map(\.id))")
        try assert(snapshot.homeRows.first?.items.map(\.browseTitle) == ["Severance", "Alien"],
               "continue row should combine movies and up-next shows")
        try assert(snapshot.movieRows.map(\.id) == ["genre-Horror", "all-movies"],
               "movie rows should drop all-item genres and append all movies")
        try assert(snapshot.showRows.map(\.id) == ["genre-Thriller", "all-shows"],
               "show rows should group by representative genre")

        let suggestions = snapshot.searchIndex.suggestions(for: "sci")
        try assert(suggestions == ["Science Fiction"], "expected genre suggestion, got \(suggestions)")

        let search = snapshot.searchIndex.search("sever")
        try assert(search.shows.map(\.showName) == ["Severance"],
               "expected Severance show result, got \(search.shows.map(\.showName))")
        try assert(search.movies.isEmpty, "show search should not invent movie matches")

        let castSearch = snapshot.searchIndex.search("ridley")
        try assert(castSearch.movies.map { $0.item.displayTitle } == ["Alien"],
               "expected director match for Alien")
        try assert(castSearch.movies.first?.matchDetail == "Director match",
               "expected director match detail")

        movieB.playbackPosition = 120
        movieB.lastPlayedDate = Date(timeIntervalSince1970: 6_000)
        let refreshed = BrowseSnapshotBuilder.refreshProgressRows(
            movies: [movieA, movieB, movieC],
            tvEpisodes: [episode1, episode2],
            existing: snapshot,
            seasonalDate: nonSeasonalDate
        )
        try assert(refreshed.movieRows.map(\.id) == snapshot.movieRows.map(\.id),
               "progress refresh should preserve movie row structure")
        try assert(refreshed.showRows.map(\.id) == snapshot.showRows.map(\.id),
               "progress refresh should preserve show row structure")
        try assert(refreshed.homeRows.first?.id == "continue-watching",
               "progress refresh should keep continue watching first")
        try assert(refreshed.homeRows.first?.items.first?.displayTitle == "Arrival",
               "progress refresh should update continue watching order")
        try assert(refreshed.showRows.last?.shows.first?.upNextLabel == "S1 E2",
               "progress refresh should preserve show up-next labels")
        try assert(refreshed.heroSpotlights.first?.id.hasPrefix("continue-") == true,
               "progress refresh should keep Continue Watching leading the hero carousel")
        let rebuilt = BrowseSnapshotBuilder.build(
            movies: [movieA, movieB, movieC],
            tvEpisodes: [episode1, episode2],
            seasonalDate: nonSeasonalDate
        )
        try assert(refreshed.heroSpotlights.first?.category == rebuilt.heroSpotlights.first?.category,
               "progress refresh and full rebuild should agree on the leading hero spotlight")

        try verifyCompetentSearchRanking()
        try verifyFranchiseAwareGenreRows()
        try verifyHolidayMovieRow()
        try verifyHeroQualityRanking()
        try verifyMoreLikeThisRanking()
        try verifySearchV2ExistingDataContracts()
        try verifySearchD2EntityContracts()
        try verifySimilarityIndexContracts()
        try verifyDurableCompletionLedgerContracts()
        try verifyTasteLayerContracts()
        try verifyLeanBackDelightContracts()
        try verifyFilteredSearchIndexReuse()

        return "homeRows=\(snapshot.homeRows.count), movieRows=\(snapshot.movieRows.count), showRows=\(snapshot.showRows.count), suggestions=\(suggestions.count), refreshedRows=\(refreshed.homeRows.count), semanticRanking=verified, filteredIndexReuse=verified"
    }

    private static func verifyDurableCompletionLedgerContracts() throws {
        let profileID = UUID(uuidString: "12C1B6A3-BB66-45EF-A301-5D2C7DD3012C")!
        let otherProfileID = UUID(uuidString: "2EE9E4D7-0845-4D7E-903B-9EBA19F1BA22")!
        let migrationProfileID = UUID(uuidString: "A0D28A0D-8A35-45F6-9E93-6E83A6C74B14")!
        let expiredMigrationProfileID = UUID(uuidString: "E8349F9E-D346-4E0F-91C2-545F59513D95")!
        let fromStartProfileID = UUID(uuidString: "5C1AB024-F7C5-48B0-BB50-06A48E5D83D1")!
        let expiredPath = "/tmp/movies/Durable Ledger Expired.mkv"
        let freshPath = "/tmp/movies/Durable Ledger Fresh.mkv"
        let migrationPath = "/tmp/movies/Durable Ledger Migration.mkv"
        let expiredMigrationPath = "/tmp/movies/Durable Ledger Expired Migration.mkv"
        let appSupport = Configuration.appSupportDirectory
        let completedURL = appSupport.appendingPathComponent("watch-completed-\(profileID.uuidString).json")
        let ledgerURL = appSupport.appendingPathComponent("watch-completion-ledger-\(profileID.uuidString).json")
        let migrationCompletedURL = appSupport.appendingPathComponent("watch-completed-\(migrationProfileID.uuidString).json")
        let migrationLedgerURL = appSupport.appendingPathComponent("watch-completion-ledger-\(migrationProfileID.uuidString).json")
        let expiredMigrationCompletedURL = appSupport.appendingPathComponent("watch-completed-\(expiredMigrationProfileID.uuidString).json")
        let expiredMigrationLedgerURL = appSupport.appendingPathComponent("watch-completion-ledger-\(expiredMigrationProfileID.uuidString).json")
        let fromStartCompletedURL = appSupport.appendingPathComponent("watch-completed-\(fromStartProfileID.uuidString).json")
        let fromStartLedgerURL = appSupport.appendingPathComponent("watch-completion-ledger-\(fromStartProfileID.uuidString).json")

        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: completedURL)
        try? FileManager.default.removeItem(at: ledgerURL)
        try? FileManager.default.removeItem(at: migrationCompletedURL)
        try? FileManager.default.removeItem(at: migrationLedgerURL)
        try? FileManager.default.removeItem(at: expiredMigrationCompletedURL)
        try? FileManager.default.removeItem(at: expiredMigrationLedgerURL)
        try? FileManager.default.removeItem(at: fromStartCompletedURL)
        try? FileManager.default.removeItem(at: fromStartLedgerURL)

        let expiredEntry = WatchProgressEntry(
            filePath: expiredPath,
            position: 1_000,
            duration: 1_000,
            lastPlayed: Date(timeIntervalSinceNow: -16 * 24 * 60 * 60)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        try encoder.encode([expiredPath: expiredEntry]).write(to: completedURL, options: .atomic)
        try encoder.encode([expiredPath]).write(to: ledgerURL, options: .atomic)

        let store = WatchProgressStore.forProfile(profileID)
        defer {
            store.clearAll()
            try? FileManager.default.removeItem(at: completedURL)
            try? FileManager.default.removeItem(at: ledgerURL)
        }

        try assert(store.completedProgress(for: expiredPath) == nil,
                   "15-day completed progress should expire before affinity reads it")
        try assert(store.completedTitleFilePaths() == Set([expiredPath]),
                   "durable completion ledger should survive completed-progress expiry")

        store.save(filePath: freshPath, position: 970, duration: 1_000)
        try assert(store.completedTitleFilePaths().isSuperset(of: [expiredPath, freshPath]),
                   "completion saves should append file paths to the durable completion ledger")
        store.remove(filePath: freshPath)
        try assert(store.completedProgress(for: freshPath) == nil,
                   "per-title progress reset should clear rolling completed progress")
        try assert(store.completedTitleFilePaths().isSuperset(of: [expiredPath, freshPath]),
                   "per-title progress reset should preserve the durable completion ledger")
        store.clearAll()
        try assert(store.completedTitleFilePaths().isEmpty,
                   "clearAll should empty the durable completion ledger")

        let otherStore = WatchProgressStore.forProfile(otherProfileID)
        defer { otherStore.clearAll() }
        try assert(!otherStore.completedTitleFilePaths().contains(expiredPath),
                   "durable completion ledgers must stay isolated per profile")

        let migrationEntry = WatchProgressEntry(
            filePath: migrationPath,
            position: 1_000,
            duration: 1_000,
            lastPlayed: Date()
        )
        try encoder.encode([migrationPath: migrationEntry]).write(to: migrationCompletedURL, options: .atomic)
        let migratedStore = WatchProgressStore.forProfile(migrationProfileID)
        defer {
            migratedStore.clearAll()
            try? FileManager.default.removeItem(at: migrationCompletedURL)
            try? FileManager.default.removeItem(at: migrationLedgerURL)
        }
        try assert(migratedStore.completedTitleFilePaths().contains(migrationPath),
                   "first-run ledger should seed from existing completed progress before the 15-day window prunes it")

        let expiredMigrationEntry = WatchProgressEntry(
            filePath: expiredMigrationPath,
            position: 1_000,
            duration: 1_000,
            lastPlayed: Date(timeIntervalSinceNow: -16 * 24 * 60 * 60)
        )
        try encoder.encode([expiredMigrationPath: expiredMigrationEntry]).write(to: expiredMigrationCompletedURL, options: .atomic)
        let expiredMigratedStore = WatchProgressStore.forProfile(expiredMigrationProfileID)
        defer {
            expiredMigratedStore.clearAll()
            try? FileManager.default.removeItem(at: expiredMigrationCompletedURL)
            try? FileManager.default.removeItem(at: expiredMigrationLedgerURL)
        }
        try assert(expiredMigratedStore.completedProgress(for: expiredMigrationPath) == nil,
                   "expired legacy completed progress should still expire from rolling progress reads")
        try assert(expiredMigratedStore.completedTitleFilePaths().contains(expiredMigrationPath),
                   "first-run ledger should seed from expired legacy completed progress before pruning it")

        let fromStartItem = makeMovie(
            title: "Durable Ledger Replay",
            year: 2020,
            genres: ["Drama"],
            position: 0,
            lastPlayed: nil,
            dateAdded: Date(timeIntervalSince1970: 800)
        )
        let fromStartStore = WatchProgressStore.forProfile(fromStartProfileID)
        defer {
            fromStartStore.clearAll()
            try? FileManager.default.removeItem(at: fromStartCompletedURL)
            try? FileManager.default.removeItem(at: fromStartLedgerURL)
        }
        let state = LibraryState(
            currentProfile: { nil },
            isProfilePickerVisible: { false },
            skipPersistenceForHarness: true
        )
        state.setWatchStore(fromStartStore)
        state.libraryItems = [fromStartItem]
        state.recomputeFilteredItems()

        fromStartStore.save(filePath: fromStartItem.filePath, position: 970, duration: 1_000)
        state.applyWatchProgressForItem(at: fromStartItem.filePath)
        try assert(fromStartItem.isWatched && fromStartItem.lastPlayedDate != nil,
                   "completed progress should mark the in-memory item watched")
        try assert(state.browseSnapshot.homeRows.first(where: { $0.id == "recently-watched" })?.items.contains(where: { $0.filePath == fromStartItem.filePath }) == true,
                   "completed progress should place the item in Recently Watched")

        fromStartStore.remove(filePath: fromStartItem.filePath)
        state.applyWatchProgressForItem(at: fromStartItem.filePath)
        try assert(!fromStartItem.isWatched && fromStartItem.playbackPosition == 0 && fromStartItem.lastPlayedDate == nil,
                   "from-start progress reset should clear stale in-memory watch state")
        try assert(state.browseSnapshot.homeRows.first(where: { $0.id == "recently-watched" })?.items.contains(where: { $0.filePath == fromStartItem.filePath }) != true,
                   "from-start progress reset should remove the item from Recently Watched")
        try assert(fromStartStore.completedTitleFilePaths().contains(fromStartItem.filePath),
                   "from-start progress reset should not erase the durable taste ledger")
    }

    private static func verifyTasteLayerContracts() throws {
        let completed = makeMovie(
            title: "Moon Archive",
            year: 2018,
            genres: ["Science Fiction"],
            position: 0,
            lastPlayed: nil,
            dateAdded: Date(timeIntervalSince1970: 100),
            director: "Nia Orbit",
            cast: [cast("Lena Star", id: 401)],
            voteAverage: 8.0,
            voteCount: 300,
            keywords: [keyword(301, "Space Colony")]
        )
        let affinityHiddenGem = makeMovie(
            title: "Quiet Orbit",
            year: 2021,
            genres: ["Science Fiction"],
            position: 0,
            lastPlayed: nil,
            dateAdded: Date(timeIntervalSince1970: 200),
            cast: [cast("Lena Star", id: 401)],
            voteAverage: 7.7,
            voteCount: 90,
            keywords: [keyword(301, "Space Colony")]
        )
        let qualityOnlyGem = makeMovie(
            title: "Velvet Trial",
            year: 2020,
            genres: ["Drama"],
            position: 0,
            lastPlayed: nil,
            dateAdded: Date(timeIntervalSince1970: 300),
            voteAverage: 8.8,
            voteCount: 420
        )
        let affinityShort = makeMovie(
            title: "Ninety Minute Stars",
            year: 2022,
            genres: ["Science Fiction"],
            position: 0,
            lastPlayed: nil,
            dateAdded: Date(timeIntervalSince1970: 400),
            cast: [cast("Lena Star", id: 401)],
            voteAverage: 7.0,
            voteCount: 55,
            keywords: [keyword(301, "Space Colony")],
            duration: 5_400
        )
        let qualityOnlyShort = makeMovie(
            title: "Brief Sonata",
            year: 2019,
            genres: ["Music"],
            position: 0,
            lastPlayed: nil,
            dateAdded: Date(timeIntervalSince1970: 500),
            voteAverage: 8.5,
            voteCount: 120,
            duration: 5_100
        )
        let becauseCandidates = (1...4).map { index in
            makeMovie(
                title: "Orbit Neighbor \(index)",
                year: 2020 + index,
                genres: ["Science Fiction"],
                position: 0,
                lastPlayed: nil,
                dateAdded: Date(timeIntervalSince1970: 600 + Double(index)),
                cast: [cast("Lena Star", id: 401)],
                voteAverage: 7.2,
                voteCount: 80
            )
        }
        let filteredOutAdultTitle = makeMovie(
            title: "Filtered Adult Orbit",
            year: 2024,
            genres: ["Science Fiction"],
            position: 0,
            lastPlayed: nil,
            dateAdded: Date(timeIntervalSince1970: 700),
            cast: [cast("Lena Star", id: 401)],
            voteAverage: 9.0,
            voteCount: 900
        )

        let visibleMovies = [
            completed,
            affinityHiddenGem,
            qualityOnlyGem,
            affinityShort,
            qualityOnlyShort,
        ] + becauseCandidates
        let tasteProfile = BrowseTasteProfile(
            completedFilePaths: Set([completed.filePath, filteredOutAdultTitle.filePath])
        )
        let snapshot = BrowseSnapshotBuilder.build(
            movies: visibleMovies,
            tvEpisodes: [],
            tasteProfile: tasteProfile
        )

        let hiddenTitles = snapshot.homeRows
            .first(where: { $0.id == "hidden-gems" })?
            .items
            .map(\.displayTitle) ?? []
        try assert(hiddenTitles.first == "Quiet Orbit",
                   "Hidden Gems should be affinity-ranked from the local completion set, got \(hiddenTitles)")
        try assert(!hiddenTitles.contains("Moon Archive") && !hiddenTitles.contains("Filtered Adult Orbit"),
                   "Hidden Gems must exclude completed or filtered-out titles, got \(hiddenTitles)")

        let shortTitles = snapshot.homeRows
            .first(where: { $0.id == "short-tonight" })?
            .items
            .map(\.displayTitle) ?? []
        try assert(shortTitles.first == "Ninety Minute Stars",
                   "Short Tonight should be affinity-ranked, got \(shortTitles)")
        try assert(!shortTitles.contains("Moon Archive") && !shortTitles.contains("Filtered Adult Orbit"),
                   "Short Tonight must exclude completed or filtered-out titles, got \(shortTitles)")

        let firstPublishBecauseRow = snapshot.homeRows.first { $0.id.hasPrefix("because-you-watched-") }
        try assert(firstPublishBecauseRow != nil,
                   "persisted completion history should materialize Because You Watched on the first publish")

        let similarity = BrowseSimilarityIndex.build(movies: visibleMovies, showSummaries: [])
        let compositionPreserved = snapshot.attachingSimilarityPreservingComposition(similarity)
        try assert(BrowseCompositionIdentity(snapshot: compositionPreserved) == BrowseCompositionIdentity(snapshot: snapshot),
                   "background similarity attachment should preserve the first-publish Home composition")

        let attached = snapshot.withSimilarity(similarity)
        let becauseRow = attached.homeRows.first { $0.id.hasPrefix("because-you-watched-") }
        let becauseTitles = becauseRow?.items.map(\.displayTitle) ?? []
        try assert((becauseRow?.title ?? "").contains("Moon Archive"),
                   "Because-row title should name the local completed seed")
        let expectedNeighbors = Set((1...4).map { "Orbit Neighbor \($0)" })
        try assert(becauseTitles.count >= 4 && expectedNeighbors.isSubset(of: Set(becauseTitles)),
                   "Because You Watched rows should use D1 neighbors minus completed titles, got \(becauseTitles)")
        try assert(!becauseTitles.contains("Moon Archive") && !becauseTitles.contains("Filtered Adult Orbit"),
                   "Because You Watched rows must draw only from the filtered visible pool, got \(becauseTitles)")
    }

    private static func verifyLeanBackDelightContracts() throws {
        let completed = makeMovie(
            title: "Moon Archive",
            year: 2018,
            genres: ["Science Fiction"],
            position: 0,
            lastPlayed: nil,
            dateAdded: Date(timeIntervalSince1970: 100),
            director: "Nia Orbit",
            cast: [cast("Lena Star", id: 401)],
            voteAverage: 8.0,
            voteCount: 300,
            keywords: [keyword(301, "Space Colony")]
        )
        let affinityPick = makeMovie(
            title: "Quiet Orbit",
            year: 2021,
            genres: ["Science Fiction", "Adventure"],
            position: 0,
            lastPlayed: nil,
            dateAdded: Date(timeIntervalSince1970: 200),
            director: "Nia Orbit",
            cast: [cast("Lena Star", id: 401)],
            voteAverage: 8.2,
            voteCount: 220,
            keywords: [keyword(301, "Space Colony")]
        )
        let adultPick = makeMovie(
            title: "Filtered Adult Orbit",
            year: 2024,
            genres: ["Horror"],
            position: 0,
            lastPlayed: nil,
            dateAdded: Date(timeIntervalSince1970: 300),
            cast: [cast("Lena Star", id: 401)],
            voteAverage: 9.0,
            voteCount: 900
        )
        let summerAction = makeMovie(
            title: "Skyline Chase",
            year: 2022,
            genres: ["Action", "Adventure"],
            position: 0,
            lastPlayed: nil,
            dateAdded: Date(timeIntervalSince1970: 400),
            voteAverage: 7.4,
            voteCount: 500
        )
        let secondSummerAction = makeMovie(
            title: "Solar Run",
            year: 2023,
            genres: ["Action", "Science Fiction"],
            position: 0,
            lastPlayed: nil,
            dateAdded: Date(timeIntervalSince1970: 500),
            voteAverage: 7.2,
            voteCount: 450
        )

        let snapshot = BrowseSnapshotBuilder.build(
            movies: [completed, affinityPick, adultPick, summerAction, secondSummerAction],
            tvEpisodes: [],
            tasteProfile: BrowseTasteProfile(completedFilePaths: [completed.filePath, adultPick.filePath]),
            seasonalDate: DateComponents(
                calendar: Calendar(identifier: .gregorian),
                year: 2026,
                month: 7,
                day: 4
            ).date!
        )
        let rowIDs = snapshot.homeRows.map(\.id)
        try assert(rowIDs.contains("play-something"),
                   "D5 should add a Play Something home affordance, got rows \(rowIDs)")
        try assert(rowIDs.contains("seasonal-summer-blockbusters"),
                   "D5 should add a deterministic summer lane in July, got rows \(rowIDs)")
        let playSomethingTitles = snapshot.homeRows
            .first(where: { $0.id == "play-something" })?
            .items
            .map(\.displayTitle) ?? []
        try assert(!playSomethingTitles.contains("Moon Archive") && !playSomethingTitles.contains("Filtered Adult Orbit"),
                   "Play Something must use the durable completion ledger for unwatched pools, got \(playSomethingTitles)")
        try assert(playSomethingTitles.contains("Quiet Orbit"),
                   "Play Something should keep affinity-eligible unwatched candidates, got \(playSomethingTitles)")
        try verifyPlaySomethingKidsPoolSafety()
        try verifyPlaySomethingSaltVariation()
        try verifyPlaySomethingAffinityCeiling()
        try verifyPlaySomethingVariesAcrossLaunches()

        let summerRowsA = BrowseLeanBackDelightPolicy.seasonalRows(
            movies: [summerAction, secondSummerAction],
            date: DateComponents(
                calendar: Calendar(identifier: .gregorian),
                year: 2026,
                month: 7,
                day: 4
            ).date!
        )
        let summerRowsB = BrowseLeanBackDelightPolicy.seasonalRows(
            movies: [secondSummerAction, summerAction],
            date: DateComponents(
                calendar: Calendar(identifier: .gregorian),
                year: 2026,
                month: 7,
                day: 4
            ).date!
        )
        try assert(summerRowsA.first?.items.map(\.displayTitle) == summerRowsB.first?.items.map(\.displayTitle),
                   "seasonal rows should be deterministic per date regardless of input order")

        let franchiseOne = makeMovie(
            title: "Saga One",
            year: 2001,
            genres: ["Adventure"],
            position: 0,
            lastPlayed: nil,
            dateAdded: Date(timeIntervalSince1970: 600),
            collectionID: 77,
            collectionName: "Saga Collection"
        )
        let franchiseTwo = makeMovie(
            title: "Saga Two",
            year: 2004,
            genres: ["Adventure"],
            position: 0,
            lastPlayed: nil,
            dateAdded: Date(timeIntervalSince1970: 700),
            collectionID: 77,
            collectionName: "Saga Collection"
        )
        let franchisePrequel = makeMovie(
            title: "Saga Zero",
            year: 1999,
            genres: ["Adventure"],
            position: 0,
            lastPlayed: nil,
            dateAdded: Date(timeIntervalSince1970: 800),
            collectionID: 77,
            collectionName: "Saga Collection"
        )
        let nextFranchiseTitle = BrowseLeanBackDelightPolicy.nextInFranchise(
            after: franchiseOne,
            in: [franchiseTwo, franchiseOne, franchisePrequel]
        )?.displayTitle
        try assert(nextFranchiseTitle == "Saga Two",
                   "next-in-franchise should follow collection release order, got \(String(describing: nextFranchiseTitle))")

        let personRows = BrowseLeanBackDelightPolicy.personRows(
            for: completed,
            in: [completed, affinityPick, summerAction],
            limit: 10
        )
        try assert(personRows.first?.title == "More from Nia Orbit",
                   "detail person rows should prefer director rows, got \(personRows.map(\.title))")
        try assert(personRows.first?.items.map(\.displayTitle) == ["Quiet Orbit"],
                   "director person row should contain matching unwatched local items, got \(personRows.first?.items.map(\.displayTitle) ?? [])")
        try assert(!ShowDetailPersonRowsPolicy.shouldRender(rowCount: personRows.count, hasSelectionHandler: false),
                   "TV Shows route must not render inert show-detail person rows without a selection handler")
        try assert(ShowDetailPersonRowsPolicy.shouldRender(rowCount: personRows.count, hasSelectionHandler: true),
                   "show-detail person rows should render when selection can open the chosen media")

        let similarity = BrowseSimilarityIndex.build(
            movies: [completed, affinityPick, summerAction],
            showSummaries: []
        )
        let endedHandoff = BrowseLeanBackDelightPolicy.postPlayHandoffCandidate(
            after: completed,
            dismissal: .ended,
            movies: [completed, affinityPick, summerAction],
            similarity: similarity
        )?.displayTitle
        let dismissedHandoff = BrowseLeanBackDelightPolicy.postPlayHandoffCandidate(
            after: completed,
            dismissal: .dismissed,
            movies: [completed, affinityPick, summerAction],
            similarity: similarity
        )
        try assert(endedHandoff == "Quiet Orbit",
                   "post-play handoff should surface the top D1 neighbor on ended playback, got \(String(describing: endedHandoff))")
        try assert(dismissedHandoff == nil,
                   "post-play handoff must not surface after user dismissal")
    }

    private static func verifyPlaySomethingKidsPoolSafety() throws {
        let kidsProfile = UserProfile(
            name: "Kids",
            avatar: ProfileAvatar(icon: "sparkles", colorHex: "FFB84C"),
            maturityLevel: .kids
        )
        let kidsMovie = makeMovie(
            title: "Pajama Comet",
            year: 2020,
            genres: ["Animation", "Family"],
            position: 0,
            lastPlayed: nil,
            dateAdded: Date(timeIntervalSince1970: 100),
            certification: "G"
        )
        let adultMovie = makeMovie(
            title: "Midnight Blood Moon",
            year: 2021,
            genres: ["Horror"],
            position: 0,
            lastPlayed: nil,
            dateAdded: Date(timeIntervalSince1970: 200),
            certification: "R"
        )
        let activeProfile: UserProfile? = kidsProfile
        let state = LibraryState(
            currentProfile: { activeProfile },
            isProfilePickerVisible: { false },
            skipPersistenceForHarness: true
        )
        state.debugSimilarityIndexComputeDelayForHarness = 0
        state.libraryItems = [kidsMovie, adultMovie]
        state.tvItems = []
        state.recomputeFilteredItems()

        try assert(state.libraryItems.contains(where: { $0.displayTitle == "Midnight Blood Moon" && $0.maturityLevel == .adult }),
                   "harness must keep an adult-rated title in the full library set")
        try assert(!state.filteredLibraryItems.contains(where: { $0.displayTitle == "Midnight Blood Moon" }),
                   "kids profile should filter the adult-rated full-library title before Play Something")

        let rowTitles = state.browseSnapshot.homeRows
            .first(where: { $0.id == BrowseLeanBackDelightPolicy.playSomethingRowID })?
            .items
            .map(\.displayTitle) ?? []
        try assert(rowTitles.contains("Pajama Comet"),
                   "kids-safe Play Something row item should remain available, got \(rowTitles)")
        try assert(!rowTitles.contains("Midnight Blood Moon"),
                   "kids Play Something row must not include adult full-library titles, got \(rowTitles)")

        let candidates = BrowseLeanBackDelightPolicy.playSomethingCandidates(
            movies: state.filteredLibraryItems,
            showSummaries: state.browseSnapshot.showSummaries,
            tasteModel: BrowseTasteModel(
                tasteProfile: state.browseSnapshot.tasteProfile,
                sourceItems: state.filteredLibraryItems + state.browseSnapshot.showSummaries.flatMap(\.episodes)
            ),
            salt: "kids-pool-safety"
        )
        let candidateTitles = candidates.map(\.displayTitle)
        try assert(candidateTitles.contains("Pajama Comet"),
                   "kids-safe Play Something candidate should remain available, got \(candidateTitles)")
        try assert(!candidateTitles.contains("Midnight Blood Moon"),
                   "Play Something candidates must never pull adult full-library titles for kids profiles, got \(candidateTitles)")

        let pickTitle = BrowseLeanBackDelightPolicy.playSomethingPick(
            movies: state.filteredLibraryItems,
            showSummaries: state.browseSnapshot.showSummaries,
            tasteProfile: state.browseSnapshot.tasteProfile,
            salt: "kids-pool-safety"
        )?.displayTitle
        try assert(pickTitle == "Pajama Comet",
                   "Play Something pick must return the kids-safe title and never an adult full-library title, got \(String(describing: pickTitle))")
    }

    private static func verifyPlaySomethingSaltVariation() throws {
        let movieA = makeMovie(
            title: "Salt Test Alpha",
            year: 2020,
            genres: ["Drama"],
            position: 0,
            lastPlayed: nil,
            dateAdded: Date(timeIntervalSince1970: 100)
        )
        let movieB = makeMovie(
            title: "Salt Test Beta",
            year: 2021,
            genres: ["Drama"],
            position: 0,
            lastPlayed: nil,
            dateAdded: Date(timeIntervalSince1970: 200)
        )

        let pickA = BrowseLeanBackDelightPolicy.playSomethingPick(
            movies: [movieA, movieB],
            showSummaries: [],
            tasteProfile: nil,
            salt: "salt-0"
        )?.displayTitle
        let pickB = BrowseLeanBackDelightPolicy.playSomethingPick(
            movies: [movieA, movieB],
            showSummaries: [],
            tasteProfile: nil,
            salt: "salt-1000"
        )?.displayTitle

        try assert(pickA != pickB,
                   "Play Something should vary across salts with equal-weight candidates, got \(String(describing: pickA)) and \(String(describing: pickB))")
    }

    private static func verifyPlaySomethingAffinityCeiling() throws {
        let ledger = (1...40).map { index in
            makeMovie(
                title: "Ledger Watch \(index)",
                year: 2000 + index,
                genres: ["Science Fiction"],
                position: 0,
                lastPlayed: nil,
                dateAdded: Date(timeIntervalSince1970: Double(index)),
                director: "Nia Orbit",
                keywords: [keyword(301, "Space Colony")]
            )
        }
        let ledgerTwin = makeMovie(
            title: "Ledger Twin",
            year: 2023,
            genres: ["Science Fiction"],
            position: 0,
            lastPlayed: nil,
            dateAdded: Date(timeIntervalSince1970: 1_000),
            director: "Nia Orbit",
            keywords: [keyword(301, "Space Colony")]
        )
        let peers = (1...20).map { index in
            makeMovie(
                title: "Ledger Peer \(index)",
                year: 2010 + index,
                genres: [],
                position: 0,
                lastPlayed: nil,
                dateAdded: Date(timeIntervalSince1970: Double(2_000 + index))
            )
        }

        let tasteProfile = BrowseTasteProfile(completedFilePaths: Set(ledger.map(\.filePath)))
        let picks = (0..<40).compactMap { index in
            BrowseLeanBackDelightPolicy.playSomethingPick(
                movies: ledger + [ledgerTwin] + peers,
                showSummaries: [],
                tasteProfile: tasteProfile,
                salt: "affinity-ceiling-\(index)"
            )?.displayTitle
        }

        try assert(picks.count == 40,
                   "every salt should produce a Play Something pick, got \(picks.count)")
        try assert(!picks.contains(where: { $0.hasPrefix("Ledger Watch") }),
                   "Play Something must never pick a completed ledger title, got \(picks)")

        let distinct = Set(picks)
        try assert(distinct.count >= 8,
                   "a heavy watch ledger must not collapse Play Something onto one affinity favorite, got \(distinct.count) distinct picks across 40 salts: \(picks)")
        try assert(distinct.contains("Ledger Twin"),
                   "the affinity favorite should still win some salts, got \(distinct.sorted())")
    }

    /// `verifyPlaySomethingSaltVariation` covers the policy layer. This covers
    /// the call site that carried the field defect: a launch-scoped salt made
    /// every session's first press reproduce one pick.
    private static func verifyPlaySomethingVariesAcrossLaunches() throws {
        let catalog = (0..<12).map { index in
            makeMovie(
                title: "Launch Candidate \(index)",
                year: 2000 + index,
                genres: ["Drama"],
                position: 0,
                lastPlayed: nil,
                dateAdded: Date(timeIntervalSince1970: 10_000 + Double(index))
            )
        }

        var firstPresses: [String] = []
        for _ in 0..<10 {
            let state = AppState(skipPersistenceForHarness: true)
            state.library.debugSimilarityIndexComputeDelayForHarness = 0
            state.library.libraryItems = catalog
            state.library.tvItems = []
            state.library.recomputeFilteredItems()
            guard let pick = state.nextPlaySomethingPick() else {
                throw HarnessError.assertion("Play Something returned no pick for an all-unwatched catalog")
            }
            firstPresses.append(pick.displayTitle)
        }

        try assert(Set(firstPresses).count > 1,
                   "each launch's first Play Something press must not reproduce one pick, got \(firstPresses)")
    }

    private static func verifyFilteredSearchIndexReuse() throws {
        let alien = makeMovie(
            title: "Alien",
            year: 1979,
            genres: ["Science Fiction", "Horror"],
            position: 0,
            lastPlayed: nil,
            dateAdded: Date(timeIntervalSince1970: 1_000),
            director: "Ridley Scott",
            cast: [
                TMDBMetadata.CastEntry(
                    name: "Sigourney Weaver",
                    character: "Ripley",
                    profilePath: nil,
                    tmdbPersonID: 1
                )
            ]
        )
        let arrival = makeMovie(
            title: "Arrival",
            year: 2016,
            genres: ["Science Fiction"],
            position: 0,
            lastPlayed: nil,
            dateAdded: Date(timeIntervalSince1970: 2_000),
            director: "Denis Villeneuve"
        )
        let episode = makeEpisode(
            show: "Severance",
            title: "Good News About Hell",
            season: 1,
            episode: 1,
            genres: ["Thriller"],
            position: 0,
            watched: false,
            lastPlayed: nil,
            dateAdded: Date(timeIntervalSince1970: 1_500)
        )

        let full = BrowseSnapshotBuilder.build(movies: [alien, arrival], tvEpisodes: [episode])
        let reused = BrowseSnapshotBuilder.build(
            movies: [alien],
            tvEpisodes: [episode],
            reusingMovieSearchEntriesFrom: full.searchIndex
        )
        let scratch = BrowseSnapshotBuilder.build(movies: [alien], tvEpisodes: [episode])

        try assert(reused.searchIndex.revisionKey != scratch.searchIndex.revisionKey,
               "independently rebuilt indexes must have distinct revisions even when their counts and content match")
        for query in ["a", "alien", "weaver", "sever", "sci"] {
            let reusedHits = reused.searchIndex.search(query)
            let scratchHits = scratch.searchIndex.search(query)
            try assert(reusedHits.movies.map(\.id) == scratchHits.movies.map(\.id)
                    && reusedHits.shows.map(\.id) == scratchHits.shows.map(\.id),
                   "filtered index reuse diverged from scratch build for query '\(query)'")
        }
        try assert(reused.searchIndex.search("arrival").movies.isEmpty,
               "excluded title must not remain searchable through reused entries")
        try assert(reused.searchIndex.search("villeneuve").movies.isEmpty,
               "excluded title's director must not remain searchable through reused entries")
        try assert(!reused.searchIndex.suggestions(for: "arr").contains("Arrival"),
               "excluded title must not remain in rebuilt suggestions")

        let matrix = makeMovie(
            title: "The Matrix",
            year: 1999,
            genres: ["Science Fiction"],
            position: 0,
            lastPlayed: nil,
            dateAdded: Date(timeIntervalSince1970: 3_000)
        )
        let sameCountReplacement = BrowseSnapshotBuilder.build(
            movies: [matrix],
            tvEpisodes: [episode]
        )
        try assert(sameCountReplacement.searchIndex.revisionKey != scratch.searchIndex.revisionKey,
               "same-count catalog replacements must invalidate the search revision")
        try assert(
            BrowseSnapshotDetailRevision(snapshot: sameCountReplacement)
                != BrowseSnapshotDetailRevision(snapshot: scratch),
            "detail deferred caches must invalidate on same-count catalog replacement"
        )
        try assert(sameCountReplacement.searchIndex.search("matrix").movies.first?.item.id == matrix.id,
               "same-count replacement should resolve hits from the replacement catalog")
        try assert(sameCountReplacement.searchIndex.search("alien").movies.isEmpty,
               "same-count replacement must not retain results from the previous catalog")

        let similarity = BrowseSimilarityIndex.build(
            movies: [alien],
            showSummaries: scratch.showSummaries
        )
        let withSimilarity = scratch.attachingSimilarityPreservingComposition(similarity)
        try assert(
            BrowseSnapshotDetailRevision(snapshot: withSimilarity)
                != BrowseSnapshotDetailRevision(snapshot: scratch),
            "detail deferred caches must invalidate when similarity attaches without a catalog replacement"
        )
    }

    private static func verifyCompetentSearchRanking() throws {
        let completeUnknown = makeMovie(
            title: "A Complete Unknown",
            year: 2024,
            genres: ["Drama", "Music"],
            position: 0,
            lastPlayed: nil,
            dateAdded: Date(timeIntervalSince1970: 10)
        )
        let secretService = makeMovie(
            title: "Kingsman: The Secret Service",
            year: 2014,
            genres: ["Action", "Adventure", "Comedy"],
            position: 0,
            lastPlayed: nil,
            dateAdded: Date(timeIntervalSince1970: 20)
        )
        let goldenCircle = makeMovie(
            title: "Kingsman: The Golden Circle",
            year: 2017,
            genres: ["Action", "Adventure", "Comedy"],
            position: 0,
            lastPlayed: nil,
            dateAdded: Date(timeIntervalSince1970: 30)
        )
        let kingsMan = makeMovie(
            title: "The King's Man",
            year: 2021,
            genres: ["Action", "Adventure"],
            position: 0,
            lastPlayed: nil,
            dateAdded: Date(timeIntervalSince1970: 40)
        )

        let snapshot = BrowseSnapshotBuilder.build(
            movies: [completeUnknown, goldenCircle, kingsMan, secretService],
            tvEpisodes: []
        )

        let oneLetterSearch = snapshot.searchIndex.search("k").movies.map { $0.item.displayTitle }
        try assert(oneLetterSearch.first == "Kingsman: The Secret Service",
                   "single-letter search should prefer title/franchise word-start hits over weak substrings, got \(oneLetterSearch)")
        try assert(!oneLetterSearch.contains("A Complete Unknown"),
                   "single-letter search should not scan unrelated metadata fields, got \(oneLetterSearch)")

        let fullSearch = snapshot.searchIndex.search("kingsman").movies.map { $0.item.displayTitle }
        try assert(fullSearch.prefix(3) == [
            "Kingsman: The Secret Service",
            "Kingsman: The Golden Circle",
            "The King's Man",
        ], "full Kingsman search should return franchise titles first, got \(fullSearch)")
        try assert(!fullSearch.contains("A Complete Unknown"),
                   "full Kingsman search should not retain stale unrelated results, got \(fullSearch)")
    }

    private static func verifyFranchiseAwareGenreRows() throws {
        let movies = [
            makeMovie(title: "Kingsman: The Golden Circle", year: 2017, genres: ["Action"], position: 0, lastPlayed: nil, dateAdded: Date(timeIntervalSince1970: 10)),
            makeMovie(title: "Knives Out", year: 2019, genres: ["Action"], position: 0, lastPlayed: nil, dateAdded: Date(timeIntervalSince1970: 20)),
            makeMovie(title: "The King's Man", year: 2021, genres: ["Action"], position: 0, lastPlayed: nil, dateAdded: Date(timeIntervalSince1970: 30)),
            makeMovie(title: "Kingsman: The Secret Service", year: 2014, genres: ["Action"], position: 0, lastPlayed: nil, dateAdded: Date(timeIntervalSince1970: 40)),
            makeMovie(title: "Die Hard", year: 1988, genres: ["Action"], position: 0, lastPlayed: nil, dateAdded: Date(timeIntervalSince1970: 50)),
            makeMovie(title: "A Complete Unknown", year: 2024, genres: ["Drama", "Music"], position: 0, lastPlayed: nil, dateAdded: Date(timeIntervalSince1970: 60)),
        ]
        let snapshot = BrowseSnapshotBuilder.build(movies: movies, tvEpisodes: [])
        guard let actionRow = snapshot.movieRows.first(where: { $0.title == "Action" }) else {
            throw HarnessError.assertion("missing Action row")
        }

        let titles = actionRow.items.map(\.displayTitle)
        let familyIndexes = titles.enumerated()
            .filter { BrowseSemanticPolicy.franchiseKey(for: $0.element) == "kingsman" }
            .map(\.offset)
        try assert(familyIndexes.count == 3, "expected three Kingsman-family titles in Action row, got titles=\(titles)")
        try assert((familyIndexes.max() ?? -1) - (familyIndexes.min() ?? -1) == 2,
                   "franchise titles should stay contiguous in genre rows, got titles=\(titles)")
    }

    private static func verifyHolidayMovieRow() throws {
        let snapshot = BrowseSnapshotBuilder.build(
            movies: [
                makeMovie(title: "Home Alone", year: 1990, genres: ["Comedy", "Family"], position: 0, lastPlayed: nil, dateAdded: Date(timeIntervalSince1970: 10)),
                makeMovie(title: "National Lampoon's Christmas Vacation", year: 1989, genres: ["Comedy"], position: 0, lastPlayed: nil, dateAdded: Date(timeIntervalSince1970: 20)),
                makeMovie(title: "Die Hard", year: 1988, genres: ["Action"], position: 0, lastPlayed: nil, dateAdded: Date(timeIntervalSince1970: 30)),
            ],
            tvEpisodes: []
        )

        let holidayTitles = snapshot.movieRows
            .first(where: { $0.id == "holiday-movies" })?
            .items
            .map(\.displayTitle) ?? []
        try assert(holidayTitles == ["National Lampoon's Christmas Vacation", "Home Alone"],
                   "expected curated Holiday Movies row, got \(holidayTitles)")
    }

    private static func verifyHeroQualityRanking() throws {
        let weakNewest = makeMovie(
            title: "Random Phone Clip",
            year: 2026,
            genres: ["Comedy"],
            position: 0,
            lastPlayed: nil,
            dateAdded: Date(timeIntervalSince1970: 3_000),
            voteAverage: 3.1,
            backdropPath: nil
        )
        let feature = makeMovie(
            title: "Mad Max: Fury Road",
            year: 2015,
            genres: ["Action", "Adventure"],
            position: 0,
            lastPlayed: nil,
            dateAdded: Date(timeIntervalSince1970: 1_000),
            voteAverage: 8.1,
            backdropPath: "/tmp/fury-road-backdrop.jpg"
        )

        let spotlights = HeroSpotlightBuilder.build(from: [weakNewest, feature])
        try assert(spotlights.first?.item.displayTitle == "Mad Max: Fury Road",
                   "hero should prefer high-quality artwork-backed feature over newest weak item, got \(spotlights.map { $0.item.displayTitle })")
    }

    private static func verifySearchV2ExistingDataContracts() throws {
        let titleHit = makeMovie(
            title: "Signal Harbor",
            year: 2020,
            genres: ["Drama"],
            position: 0,
            lastPlayed: nil,
            dateAdded: Date(timeIntervalSince1970: 10)
        )
        let directorHit = makeMovie(
            title: "North Passage",
            year: 2021,
            genres: ["Drama"],
            position: 0,
            lastPlayed: nil,
            dateAdded: Date(timeIntervalSince1970: 20),
            director: "Signal Harbor"
        )
        let castHit = makeMovie(
            title: "Current Witness",
            year: 2022,
            genres: ["Drama"],
            position: 0,
            lastPlayed: nil,
            dateAdded: Date(timeIntervalSince1970: 30),
            cast: [cast("Signal Harbor", id: 301)]
        )
        let genreHit = makeMovie(
            title: "Genre Vessel",
            year: 2023,
            genres: ["Signal Harbor"],
            position: 0,
            lastPlayed: nil,
            dateAdded: Date(timeIntervalSince1970: 40)
        )
        let overviewHit = makeMovie(
            title: "Quiet Orbit",
            year: 2024,
            genres: ["Drama"],
            position: 0,
            lastPlayed: nil,
            dateAdded: Date(timeIntervalSince1970: 50),
            overview: "A signal harbor keeps the crew alive after the storm."
        )

        let snapshot = BrowseSnapshotBuilder.build(
            movies: [overviewHit, genreHit, castHit, directorHit, titleHit],
            tvEpisodes: []
        )
        let weightedTitles = snapshot.searchIndex.search("signal harbor").movies.map { $0.item.displayTitle }
        try assert(weightedTitles.prefix(5) == [
            "Signal Harbor",
            "North Passage",
            "Current Witness",
            "Genre Vessel",
            "Quiet Orbit",
        ], "search v2 should weight title > people > genre > overview, got \(weightedTitles)")

        let overviewOnly = snapshot.searchIndex.search("storm").movies.map { $0.item.displayTitle }
        try assert(overviewOnly == ["Quiet Orbit"],
                   "overview tokens should be searchable without keywords/entities, got \(overviewOnly)")

        let overviewPhraseWithStopword = snapshot.searchIndex.search("the storm").movies.map { $0.item.displayTitle }
        try assert(overviewPhraseWithStopword == ["Quiet Orbit"],
                   "overview phrase queries should ignore stopwords without losing meaningful tokens, got \(overviewPhraseWithStopword)")

        let commonOverviewTerm = snapshot.searchIndex.search("the").movies.map { $0.item.displayTitle }
        try assert(!commonOverviewTerm.contains("Quiet Orbit"),
                   "common overview terms should not surface overview-only matches, got \(commonOverviewTerm)")

        let overviewOnlyCommonTerm = BrowseSnapshotBuilder.build(
            movies: [overviewHit],
            tvEpisodes: []
        ).searchIndex.search("the").movies.map { $0.item.displayTitle }
        try assert(overviewOnlyCommonTerm.isEmpty,
                   "common overview terms should not match an overview-only index, got \(overviewOnlyCommonTerm)")

        let showOverviewEpisode = makeMovie(
            title: "Fog Line",
            year: 2025,
            genres: ["Mystery"],
            position: 0,
            lastPlayed: nil,
            dateAdded: Date(timeIntervalSince1970: 55),
            overview: "A lighthouse crew decodes an aurora cipher before dawn.",
            showName: "Beacon House"
        )
        let showOverviewLaterEpisode = makeMovie(
            title: "Lantern Room",
            year: 2025,
            genres: ["Mystery"],
            position: 0,
            lastPlayed: nil,
            dateAdded: Date(timeIntervalSince1970: 56),
            overview: "The keeper uncovers a midnight kelp map below the stairs.",
            showName: "Beacon House",
            episodeNumber: 2
        )
        let showSnapshot = BrowseSnapshotBuilder.build(
            movies: [],
            tvEpisodes: [showOverviewEpisode, showOverviewLaterEpisode]
        )
        let showOverviewOnly = showSnapshot.searchIndex.search("aurora").shows.map { $0.showName }
        try assert(showOverviewOnly == ["Beacon House"],
                   "show representative overviews should be searchable, got \(showOverviewOnly)")
        let showLaterOverviewOnly = showSnapshot.searchIndex.search("kelp").shows.map { $0.showName }
        try assert(showLaterOverviewOnly == ["Beacon House"],
                   "show non-representative episode overviews should be searchable, got \(showLaterOverviewOnly)")
        let showCommonOverviewTerm = showSnapshot.searchIndex.search("the").shows.map { $0.showName }
        try assert(!showCommonOverviewTerm.contains("Beacon House"),
                   "common overview terms should not surface show overview-only matches, got \(showCommonOverviewTerm)")

        let typoMovie = makeMovie(
            title: "Alien",
            year: 1979,
            genres: ["Science Fiction"],
            position: 0,
            lastPlayed: nil,
            dateAdded: Date(timeIntervalSince1970: 60),
            director: "Ridley Scott"
        )
        let typoNeighbor = makeMovie(
            title: "Alian",
            year: 2025,
            genres: ["Science Fiction"],
            position: 0,
            lastPlayed: nil,
            dateAdded: Date(timeIntervalSince1970: 70)
        )
        let typoSnapshot = BrowseSnapshotBuilder.build(movies: [typoMovie, typoNeighbor], tvEpisodes: [])
        let exactTitles = typoSnapshot.searchIndex.search("alien").movies.map { $0.item.displayTitle }
        try assert(exactTitles == ["Alien"],
                   "typo tolerance should not broaden exact searches, got \(exactTitles)")

        let typoTitles = typoSnapshot.searchIndex.search("ridly scot").movies.map { $0.item.displayTitle }
        try assert(typoTitles == ["Alien"],
                   "edit-distance-1 typo tolerance should match people fields, got \(typoTitles)")
    }

    private static func verifySearchD2EntityContracts() throws {
        let alien = makeMovie(
            title: "Alien",
            year: 1979,
            genres: ["Science Fiction", "Horror"],
            position: 0,
            lastPlayed: nil,
            dateAdded: Date(timeIntervalSince1970: 10),
            director: "Ridley Scott",
            keywords: [keyword(100, "Space")]
        )
        let bladeRunner = makeMovie(
            title: "Blade Runner",
            year: 1982,
            genres: ["Science Fiction"],
            position: 0,
            lastPlayed: nil,
            dateAdded: Date(timeIntervalSince1970: 20),
            director: "Ridley Scott",
            collectionID: 263,
            collectionName: "Blade Runner Collection",
            keywords: [keyword(101, "Cyberpunk")]
        )
        let bladeRunner2049 = makeMovie(
            title: "Blade Runner 2049",
            year: 2017,
            genres: ["Science Fiction"],
            position: 0,
            lastPlayed: nil,
            dateAdded: Date(timeIntervalSince1970: 30),
            director: "Denis Villeneuve",
            collectionID: 263,
            collectionName: "Blade Runner Collection",
            keywords: [keyword(101, "Cyberpunk")]
        )
        let americanGangster = makeMovie(
            title: "American Gangster",
            year: 2007,
            genres: ["Crime"],
            position: 0,
            lastPlayed: nil,
            dateAdded: Date(timeIntervalSince1970: 40),
            director: "Ridley Scott",
            keywords: [keyword(102, "Heist")]
        )
        let matchstickMen = makeMovie(
            title: "Matchstick Men",
            year: 2003,
            genres: ["Comedy", "Crime"],
            position: 0,
            lastPlayed: nil,
            dateAdded: Date(timeIntervalSince1970: 50),
            director: "Ridley Scott",
            keywords: [keyword(102, "Heist")]
        )
        let genreOnlyPeer = makeMovie(
            title: "Theme Drift",
            year: 2024,
            genres: ["Heist"],
            position: 0,
            lastPlayed: nil,
            dateAdded: Date(timeIntervalSince1970: 60)
        )
        let slowHorsesEpisode = makeMovie(
            title: "Slow Horses: Old Scores",
            year: 2024,
            genres: ["Drama"],
            position: 0,
            lastPlayed: nil,
            dateAdded: Date(timeIntervalSince1970: 70),
            director: "Saul Metzstein",
            cast: [cast("Gary Oldman", id: 501)],
            showName: "Slow Horses"
        )

        let snapshot = BrowseSnapshotBuilder.build(
            movies: [alien, bladeRunner, bladeRunner2049, americanGangster, matchstickMen, genreOnlyPeer],
            tvEpisodes: [slowHorsesEpisode]
        )

        let directorSuggestion = "Ridley Scott — Director, 4 films"
        try assert(snapshot.searchIndex.suggestions(for: "ridley").contains(directorSuggestion),
                   "expected entity-aware director suggestion shape")
        let directorScopedTitles = snapshot.searchIndex.search(directorSuggestion).movies.map { $0.item.displayTitle }
        try assert(directorScopedTitles.count == 4
                   && directorScopedTitles.contains("Alien")
                   && directorScopedTitles.contains("American Gangster")
                   && directorScopedTitles.contains("Blade Runner")
                   && directorScopedTitles.contains("Matchstick Men"),
                   "director entity suggestion should run a scoped director query, got \(directorScopedTitles)")
        try assert(!directorScopedTitles.contains("Blade Runner 2049"),
                   "director entity suggestion must not include same-collection non-director matches")

        let keywordSuggestion = "Heist — Theme, 2 films"
        try assert(snapshot.searchIndex.suggestions(for: "hei").contains(keywordSuggestion),
                   "expected keyword/theme suggestion shape")
        let keywordScopedTitles = snapshot.searchIndex.search(keywordSuggestion).movies.map { $0.item.displayTitle }
        try assert(keywordScopedTitles.count == 2
                   && keywordScopedTitles.contains("American Gangster")
                   && keywordScopedTitles.contains("Matchstick Men"),
                   "keyword suggestion should run a scoped keyword query, got \(keywordScopedTitles)")
        try assert(!keywordScopedTitles.contains("Theme Drift"),
                   "keyword entity suggestion must not include genre-only matches")

        let collectionSuggestion = "Blade Runner Collection — Collection, 2 films"
        try assert(snapshot.searchIndex.suggestions(for: "blade").contains(collectionSuggestion),
                   "expected collection suggestion shape")
        let collectionScopedTitles = snapshot.searchIndex.search(collectionSuggestion).movies.map { $0.item.displayTitle }
        try assert(collectionScopedTitles == ["Blade Runner", "Blade Runner 2049"],
                   "collection suggestion should run a scoped collection query, got \(collectionScopedTitles)")

        let keywordWeightedTitles = snapshot.searchIndex.search("heist").movies.map { $0.item.displayTitle }
        let keywordWeightedPrefix = Array(keywordWeightedTitles.prefix(2))
        try assert(keywordWeightedPrefix.count == 2
                   && keywordWeightedPrefix.contains("American Gangster")
                   && keywordWeightedPrefix.contains("Matchstick Men"),
                   "raw keyword searches should rank keyword fields ahead of genre-only matches, got \(keywordWeightedTitles)")

        let showDirectorSuggestion = "Saul Metzstein — Director, 1 show"
        try assert(snapshot.searchIndex.suggestions(for: "saul").contains(showDirectorSuggestion),
                   "expected show representative director suggestion shape")
        let showDirectorScopedNames = snapshot.searchIndex.search(showDirectorSuggestion).shows.map { $0.item.showName }
        try assert(showDirectorScopedNames == ["Slow Horses"],
                   "show director suggestion should run a scoped director query, got \(showDirectorScopedNames)")
        try assert(snapshot.searchIndex.search(showDirectorSuggestion).movies.isEmpty,
                   "show director suggestion should not include movies when only shows match")

        let showActorSuggestion = "Gary Oldman — Actor, 1 show"
        try assert(snapshot.searchIndex.suggestions(for: "gary").contains(showActorSuggestion),
                   "expected show representative actor suggestion shape")
        let showActorScopedNames = snapshot.searchIndex.search(showActorSuggestion).shows.map { $0.item.showName }
        try assert(showActorScopedNames == ["Slow Horses"],
                   "show actor suggestion should run a scoped cast query, got \(showActorScopedNames)")
        try assert(snapshot.searchIndex.search(showActorSuggestion).movies.isEmpty,
                   "show actor suggestion should not include movies when only shows match")
    }

    private static func verifyMoreLikeThisRanking() throws {
        let target = makeMovie(
            title: "Kingsman: The Secret Service",
            year: 2014,
            genres: ["Action", "Adventure", "Comedy"],
            position: 0,
            lastPlayed: nil,
            dateAdded: Date(timeIntervalSince1970: 10),
            voteAverage: 7.7,
            backdropPath: "/tmp/kingsman.jpg"
        )
        let sequel = makeMovie(
            title: "Kingsman: The Golden Circle",
            year: 2017,
            genres: ["Action", "Adventure", "Comedy"],
            position: 0,
            lastPlayed: nil,
            dateAdded: Date(timeIntervalSince1970: 20),
            voteAverage: 6.7,
            backdropPath: "/tmp/golden-circle.jpg"
        )
        let prequel = makeMovie(
            title: "The King's Man",
            year: 2021,
            genres: ["Action", "Adventure"],
            position: 0,
            lastPlayed: nil,
            dateAdded: Date(timeIntervalSince1970: 30),
            voteAverage: 6.3,
            backdropPath: "/tmp/kings-man.jpg"
        )
        let genericAction = makeMovie(
            title: "Die Hard",
            year: 1988,
            genres: ["Action"],
            position: 0,
            lastPlayed: nil,
            dateAdded: Date(timeIntervalSince1970: 40),
            voteAverage: 8.2,
            backdropPath: "/tmp/die-hard.jpg"
        )

        let recommendations = BrowseRecommendationEngine.similarMovies(
            to: target,
            in: [genericAction, prequel, sequel, target],
            limit: 4
        ).map(\.displayTitle)

        try assert(recommendations.prefix(2) == [
            "Kingsman: The Golden Circle",
            "The King's Man",
        ], "More Like This should rank franchise/sequel titles ahead of generic genre overlap, got \(recommendations)")
    }

    private static func verifySimilarityIndexContracts() throws {
        try verifySimilarityIndexLeadActorRanking()
        try verifySimilarityIndexRareGenreRanking()
        try verifySimilarityIndexQualityRanking()
        try verifySimilarityIndexExcludesZeroOverlap()
        try verifySimilarityIndexIgnoresBlankDirectors()
        try verifySimilarityIndexOverviewRanking()
        try verifySimilarityIndexShowRanking()
        try verifySimilarityConsumerAccessors()
        try verifySimilarityIndexDeterministicTiebreak()
        try verifySnapshotBuildKeepsSimilarityOffPath()
        try verifySimilarityIndexHeroVarietyAfterAttach()
        try verifySimilarityIndexProductionAttachContracts()
    }

    private static func verifySimilarityIndexLeadActorRanking() throws {
        let source = makeMovie(
            title: "Galaxy Fright",
            year: 1980,
            genres: ["Horror"],
            position: 0,
            lastPlayed: nil,
            dateAdded: Date(timeIntervalSince1970: 100),
            cast: [cast("Sigourney Weaver", id: 1)],
            voteAverage: 7.8
        )
        let leadActor = makeMovie(
            title: "Working Orbit",
            year: 1988,
            genres: ["Drama"],
            position: 0,
            lastPlayed: nil,
            dateAdded: Date(timeIntervalSince1970: 200),
            cast: [cast("Sigourney Weaver", id: 1)],
            voteAverage: 7.2
        )
        let genreOnly = makeMovie(
            title: "Basement Howl",
            year: 1981,
            genres: ["Horror"],
            position: 0,
            lastPlayed: nil,
            dateAdded: Date(timeIntervalSince1970: 300),
            voteAverage: 7.9
        )

        let ranked = rankedMovieTitles(
            source: source,
            candidates: [genreOnly, leadActor, source]
        )
        try assert(ranked.first == "Working Orbit",
                   "shared lead actor should outrank genre-only overlap, got \(ranked)")
    }

    private static func verifySimilarityIndexRareGenreRanking() throws {
        let source = makeMovie(
            title: "Neon Alibi",
            year: 1955,
            genres: ["Film-Noir", "Drama"],
            position: 0,
            lastPlayed: nil,
            dateAdded: Date(timeIntervalSince1970: 100),
            voteAverage: 8.0
        )
        let rareGenre = makeMovie(
            title: "Night Ledger",
            year: 1954,
            genres: ["Film-Noir"],
            position: 0,
            lastPlayed: nil,
            dateAdded: Date(timeIntervalSince1970: 200),
            voteAverage: 7.0
        )
        let commonGenre = makeMovie(
            title: "Family Trial",
            year: 2004,
            genres: ["Drama"],
            position: 0,
            lastPlayed: nil,
            dateAdded: Date(timeIntervalSince1970: 300),
            voteAverage: 8.4
        )
        let dramaFillers = (1...5).map {
            makeMovie(
                title: "Drama Filler \($0)",
                year: 2000 + $0,
                genres: ["Drama"],
                position: 0,
                lastPlayed: nil,
                dateAdded: Date(timeIntervalSince1970: TimeInterval(400 + $0)),
                voteAverage: 6.5
            )
        }

        let ranked = rankedMovieTitles(
            source: source,
            candidates: [commonGenre, rareGenre, source] + dramaFillers
        )
        try assert(ranked.first == "Night Ledger",
                   "rare genre should outrank common genre despite lower rating, got \(ranked)")
    }

    private static func verifySimilarityIndexQualityRanking() throws {
        let source = makeMovie(
            title: "Signal Room",
            year: 2014,
            genres: ["Thriller"],
            position: 0,
            lastPlayed: nil,
            dateAdded: Date(timeIntervalSince1970: 100),
            voteAverage: 7.4
        )
        let lowVote = makeMovie(
            title: "Signal Below",
            year: 2015,
            genres: ["Thriller"],
            position: 0,
            lastPlayed: nil,
            dateAdded: Date(timeIntervalSince1970: 500),
            voteAverage: 4.9
        )
        let highVote = makeMovie(
            title: "Signal Above",
            year: 2013,
            genres: ["Thriller"],
            position: 0,
            lastPlayed: nil,
            dateAdded: Date(timeIntervalSince1970: 200),
            voteAverage: 8.3
        )

        let ranked = rankedMovieTitles(
            source: source,
            candidates: [lowVote, highVote, source]
        )
        try assert(ranked.first == "Signal Above",
                   "high-vote peer should outrank low-vote peer absent another signal, got \(ranked)")
    }

    private static func verifySimilarityIndexExcludesZeroOverlap() throws {
        let source = makeMovie(
            title: "Midnight Signal",
            year: 2019,
            genres: ["Thriller"],
            position: 0,
            lastPlayed: nil,
            dateAdded: Date(timeIntervalSince1970: 100),
            voteAverage: 7.0
        )
        let unrelated = makeMovie(
            title: "Sunny Cakewalk",
            year: 1995,
            genres: ["Comedy"],
            position: 0,
            lastPlayed: nil,
            dateAdded: Date(timeIntervalSince1970: 200),
            voteAverage: 9.4
        )

        let ranked = rankedMovieTitles(source: source, candidates: [unrelated, source])
        try assert(!ranked.contains("Sunny Cakewalk"),
                   "zero-overlap candidates should not be admitted by rating quality alone, got \(ranked)")
    }

    private static func verifySimilarityIndexIgnoresBlankDirectors() throws {
        let source = makeMovie(
            title: "Silent Harbor",
            year: 2018,
            genres: ["Mystery"],
            position: 0,
            lastPlayed: nil,
            dateAdded: Date(timeIntervalSince1970: 100),
            director: "   ",
            voteAverage: 7.1
        )
        let unrelated = makeMovie(
            title: "Sunny Cakewalk",
            year: 1995,
            genres: ["Comedy"],
            position: 0,
            lastPlayed: nil,
            dateAdded: Date(timeIntervalSince1970: 200),
            director: "",
            voteAverage: 9.4
        )

        let ranked = rankedMovieTitles(source: source, candidates: [unrelated, source])
        try assert(!ranked.contains("Sunny Cakewalk"),
                   "blank normalized directors should not create a hard director match, got \(ranked)")
    }

    private static func verifySimilarityIndexOverviewRanking() throws {
        let source = makeMovie(
            title: "Red Horizon",
            year: 2015,
            genres: ["Drama"],
            position: 0,
            lastPlayed: nil,
            dateAdded: Date(timeIntervalSince1970: 100),
            overview: "An astronaut stranded on a red planet waits for a rescue mission through dust.",
            voteAverage: 7.0
        )
        let overviewPeer = makeMovie(
            title: "Dust Rescue",
            year: 2017,
            genres: ["Comedy"],
            position: 0,
            lastPlayed: nil,
            dateAdded: Date(timeIntervalSince1970: 200),
            overview: "A stranded astronaut on a distant planet plans a rescue mission through dust.",
            voteAverage: 6.5
        )
        let genreOnly = makeMovie(
            title: "Kitchen Drama",
            year: 2020,
            genres: ["Drama"],
            position: 0,
            lastPlayed: nil,
            dateAdded: Date(timeIntervalSince1970: 300),
            voteAverage: 8.0
        )

        let ranked = rankedMovieTitles(source: source, candidates: [genreOnly, overviewPeer, source])
        try assert(ranked.first == "Dust Rescue",
                   "shared overview tokens should outrank a thin genre-only match, got \(ranked)")
    }

    private static func verifySimilarityIndexShowRanking() throws {
        let source = showSummary(
            name: "Deep Orbit",
            representative: makeMovie(
                title: "Deep Orbit Pilot",
                year: 2015,
                genres: ["Science Fiction"],
                position: 0,
                lastPlayed: nil,
                dateAdded: Date(timeIntervalSince1970: 100),
                cast: [cast("Shohreh Aghdashloo", id: 10)],
                voteAverage: 8.0
            )
        )
        let sharedCast = showSummary(
            name: "Night Station",
            representative: makeMovie(
                title: "Night Station Pilot",
                year: 2018,
                genres: ["Drama"],
                position: 0,
                lastPlayed: nil,
                dateAdded: Date(timeIntervalSince1970: 200),
                cast: [cast("Shohreh Aghdashloo", id: 10)],
                voteAverage: 7.4
            )
        )
        let genreOnly = showSummary(
            name: "Bright Orbit",
            representative: makeMovie(
                title: "Bright Orbit Pilot",
                year: 2020,
                genres: ["Science Fiction"],
                position: 0,
                lastPlayed: nil,
                dateAdded: Date(timeIntervalSince1970: 300),
                voteAverage: 8.6
            )
        )

        let ranked = rankedShowNames(source: source, candidates: [genreOnly, sharedCast, source])
        try assert(ranked.first == "Night Station",
                   "show similarity should rank shared cast ahead of genre-only overlap, got \(ranked)")
    }

    private static func verifySimilarityConsumerAccessors() throws {
        let source = makeMovie(
            title: "Lead Source",
            year: 2018,
            genres: ["Drama"],
            position: 0,
            lastPlayed: nil,
            dateAdded: Date(timeIntervalSince1970: 100),
            cast: [cast("Avery Lead", id: 70)],
            voteAverage: 7.0
        )
        let legacyGenrePick = makeMovie(
            title: "Drama Decade",
            year: 2017,
            genres: ["Drama"],
            position: 0,
            lastPlayed: nil,
            dateAdded: Date(timeIntervalSince1970: 200),
            voteAverage: 8.0
        )
        let indexLeadPick = makeMovie(
            title: "Lead Match",
            year: 1995,
            genres: ["Comedy"],
            position: 0,
            lastPlayed: nil,
            dateAdded: Date(timeIntervalSince1970: 300),
            cast: [cast("Avery Lead", id: 70)],
            voteAverage: 7.0
        )
        let movies = [legacyGenrePick, indexLeadPick, source]
        let snapshot = BrowseSnapshotBuilder.build(movies: movies, tvEpisodes: [])
        let fallbackTitles = snapshot.similarMovies(to: source, in: movies, limit: 2).map(\.displayTitle)
        try assert(fallbackTitles.first == "Drama Decade",
                   "nil similarity should preserve legacy movie ordering, got \(fallbackTitles)")

        let indexedMovieTitles = snapshot
            .withSimilarity(BrowseSimilarityIndex.build(movies: movies, showSummaries: []))
            .similarMovies(to: source, in: movies, limit: 2)
            .map(\.displayTitle)
        try assert(indexedMovieTitles.first == "Lead Match",
                   "attached similarity index should drive movie More Like ordering, got \(indexedMovieTitles)")

        let sourceShow = showSummary(
            name: "Lead Source Show",
            representative: makeMovie(
                title: "Lead Source Pilot",
                year: 2018,
                genres: ["Drama"],
                position: 0,
                lastPlayed: nil,
                dateAdded: Date(timeIntervalSince1970: 100),
                cast: [cast("Avery Lead", id: 70)],
                voteAverage: 7.0
            )
        )
        let legacyShowPick = showSummary(
            name: "Drama Decade Show",
            representative: makeMovie(
                title: "Drama Decade Pilot",
                year: 2017,
                genres: ["Drama"],
                position: 0,
                lastPlayed: nil,
                dateAdded: Date(timeIntervalSince1970: 200),
                voteAverage: 8.0
            )
        )
        let indexShowPick = showSummary(
            name: "Lead Match Show",
            representative: makeMovie(
                title: "Lead Match Pilot",
                year: 1995,
                genres: ["Comedy"],
                position: 0,
                lastPlayed: nil,
                dateAdded: Date(timeIntervalSince1970: 300),
                cast: [cast("Avery Lead", id: 70)],
                voteAverage: 7.0
            )
        )
        let shows = [legacyShowPick, indexShowPick, sourceShow]
        let showSnapshot = BrowseSnapshot(
            heroSpotlights: [],
            homeRows: [],
            movieRows: [],
            showRows: [],
            showSummaries: shows,
            searchIndex: BrowseSearchIndex(movies: [], shows: shows),
            similarity: nil,
            tasteProfile: nil
        )
        let fallbackShows = showSnapshot.similarShowNames(to: sourceShow.showName, limit: 2)
        try assert(fallbackShows.first == "Drama Decade Show",
                   "nil similarity should preserve legacy show ordering, got \(fallbackShows)")

        let indexedShows = showSnapshot
            .withSimilarity(BrowseSimilarityIndex.build(movies: [], showSummaries: shows))
            .similarShowNames(to: sourceShow.showName, limit: 2)
        try assert(indexedShows.first == "Lead Match Show",
                   "attached similarity index should drive show More Like ordering, got \(indexedShows)")
    }

    private static func verifySimilarityIndexDeterministicTiebreak() throws {
        let source = makeMovie(
            title: "Quest Source",
            year: 2020,
            genres: ["Adventure"],
            position: 0,
            lastPlayed: nil,
            dateAdded: Date(timeIntervalSince1970: 100),
            voteAverage: nil
        )
        let titles = [
            "Alpha Trail",
            "Bravo Trail",
            "Charlie Trail",
            "Delta Trail",
            "Echo Trail",
            "Foxtrot Trail",
            "Golf Trail",
            "Hotel Trail",
        ]
        let candidates = titles.map { title in
            makeMovie(
                title: title,
                year: 2020,
                genres: ["Adventure"],
                position: 0,
                lastPlayed: nil,
                dateAdded: Date(timeIntervalSince1970: 200),
                voteAverage: nil
            )
        }

        let rankedIDs = Array(rankedMovieIDs(source: source, candidates: candidates + [source]).prefix(8))
        let expectedIDs = candidates
            .map(\.id)
            .sorted { $0.uuidString < $1.uuidString }
        try assert(rankedIDs == expectedIDs,
                   "true similarity ties should fall back to deterministic UUID order")
    }

    private static func verifySnapshotBuildKeepsSimilarityOffPath() throws {
        let movie = makeMovie(
            title: "Off Path",
            year: 2024,
            genres: ["Drama"],
            position: 0,
            lastPlayed: nil,
            dateAdded: Date(timeIntervalSince1970: 100)
        )
        let snapshot = BrowseSnapshotBuilder.build(movies: [movie], tvEpisodes: [])
        try assert(snapshot.similarity == nil,
                   "snapshot builder should leave similarity nil until background compute attaches it")

        let index = BrowseSimilarityIndex.build(movies: [movie], showSummaries: [])
        let attached = BrowseSnapshot.empty.withSimilarity(index)
        let refreshed = BrowseSnapshotBuilder.refreshProgressRows(
            movies: [movie],
            tvEpisodes: [],
            existing: attached
        )
        try assert(refreshed.similarity != nil,
                   "progress refresh should preserve an already attached similarity index")
        try assert(!refreshed.heroSpotlights.isEmpty,
                   "progress refresh fallback should rebuild stale empty snapshots")
    }

    private static func verifySimilarityIndexHeroVarietyAfterAttach() throws {
        let continuing = makeMovie(
            title: "Atlas One",
            year: 2020,
            genres: ["Action", "Adventure"],
            position: 1_200,
            lastPlayed: Date(timeIntervalSince1970: 5_000),
            dateAdded: Date(timeIntervalSince1970: 100),
            cast: [cast("Mira Lead", id: 101)],
            voteAverage: 8.2,
            backdropPath: "/tmp/atlas-one.jpg"
        )
        let tooSimilar = makeMovie(
            title: "Atlas Two",
            year: 2021,
            genres: ["Drama"],
            position: 0,
            lastPlayed: nil,
            dateAdded: Date(timeIntervalSince1970: 200),
            cast: [cast("Mira Lead", id: 101)],
            voteAverage: 9.5,
            backdropPath: "/tmp/atlas-two.jpg"
        )
        let diverse = makeMovie(
            title: "Crimson Garden",
            year: 2022,
            genres: ["Romance"],
            position: 0,
            lastPlayed: nil,
            dateAdded: Date(timeIntervalSince1970: 300),
            cast: [cast("Una Different", id: 202)],
            voteAverage: 8.8,
            backdropPath: "/tmp/crimson-garden.jpg"
        )

        let snapshot = BrowseSnapshotBuilder.build(
            movies: [tooSimilar, diverse, continuing],
            tvEpisodes: []
        )
        try assert(snapshot.similarity == nil,
                   "first-publish snapshot should not carry a similarity index")
        try assert(snapshot.heroSpotlights.first?.item.id == continuing.id,
                   "fallback hero should keep the active continue-watching item first")
        try assert(snapshot.heroSpotlights.dropFirst().first?.item.id == tooSimilar.id,
                   "nil-index hero should preserve legacy quality ordering for fallback")

        let index = BrowseSimilarityIndex.build(
            movies: [tooSimilar, diverse, continuing],
            showSummaries: []
        )
        let attached = snapshot.withSimilarity(index)
        try assert(attached.heroSpotlights.dropFirst().first?.item.id == diverse.id,
                   "similarity-attached hero should skip a near-duplicate featured pick when a diverse quality pick exists, got \(attached.heroSpotlights.map { $0.item.displayTitle })")

        let compositionPreserved = snapshot.attachingSimilarityPreservingComposition(index)
        try assert(
            BrowseCompositionIdentity(snapshot: compositionPreserved)
                == BrowseCompositionIdentity(snapshot: snapshot),
            "production similarity attachment changed published hero/Home identity or order"
        )
        try assert(
            compositionPreserved.similarMovies(to: continuing, in: [tooSimilar, diverse]).first?.id == tooSimilar.id,
            "composition-preserving attachment did not expose the similarity index to recommendations"
        )

        let mixedContinue = makeMovie(
            title: "Atlas One",
            year: 2020,
            genres: ["Action", "Adventure"],
            position: 1_200,
            lastPlayed: Date(timeIntervalSince1970: 5_000),
            dateAdded: Date(timeIntervalSince1970: 100),
            cast: [cast("Mira Lead", id: 101)],
            voteAverage: 8.2
        )
        let tooSimilarShowRepresentative = makeMovie(
            title: "Atlas Pilot",
            year: 2021,
            genres: ["Drama"],
            position: 0,
            lastPlayed: nil,
            dateAdded: Date(timeIntervalSince1970: 200),
            cast: [cast("Mira Lead", id: 101)],
            voteAverage: 9.5,
            showName: "Atlas Dispatch"
        )
        let mixedDiverse = makeMovie(
            title: "Crimson Garden",
            year: 2022,
            genres: ["Romance"],
            position: 0,
            lastPlayed: nil,
            dateAdded: Date(timeIntervalSince1970: 300),
            cast: [cast("Una Different", id: 202)],
            voteAverage: 8.8
        )
        let mixedShow = showSummary(
            name: "Atlas Dispatch",
            representative: tooSimilarShowRepresentative
        )
        let mixedSnapshot = BrowseSnapshotBuilder.build(
            movies: [mixedDiverse, mixedContinue],
            tvEpisodes: [tooSimilarShowRepresentative]
        )
        try assert(mixedSnapshot.heroSpotlights.dropFirst().first?.item.id == tooSimilarShowRepresentative.id,
                   "nil-index mixed hero should preserve legacy quality ordering")

        let mixedAttached = mixedSnapshot.withSimilarity(
            BrowseSimilarityIndex.build(movies: [mixedDiverse, mixedContinue], showSummaries: [mixedShow])
        )
        try assert(mixedAttached.heroSpotlights.dropFirst().first?.item.id == mixedDiverse.id,
                   "similarity-attached hero should skip a near-duplicate mixed movie/show pick when a diverse quality pick exists, got \(mixedAttached.heroSpotlights.map { $0.item.browseTitle })")
    }

    private static func verifySimilarityIndexProductionAttachContracts() throws {
        try verifySimilarityIndexBackgroundAttach()
        try verifySimilarityIndexDropsStaleGeneration()
        try verifySimilarityIndexDropsSourceIdentityMismatch()
        try verifySimilarityIndexDoesNotPrepareWhileProfilePickerVisible()
        try verifySimilarityIndexReschedulesAfterPickerDropOnSameIdentityRefresh()
    }

    private static func verifySimilarityIndexBackgroundAttach() throws {
        let source = makeMovie(
            title: "Attach Source",
            year: 2020,
            genres: ["Drama"],
            position: 0,
            lastPlayed: nil,
            dateAdded: Date(timeIntervalSince1970: 100),
            voteAverage: 7.0
        )
        let peer = makeMovie(
            title: "Attach Peer",
            year: 2021,
            genres: ["Drama"],
            position: 0,
            lastPlayed: nil,
            dateAdded: Date(timeIntervalSince1970: 200),
            voteAverage: 7.2
        )
        let state = makeLibraryState()
        var events: [LibraryState.SimilarityIndexDebugEvent] = []
        state.debugSimilarityIndexBuilderForHarness = { preparedInput in
            Thread.sleep(forTimeInterval: 0.05)
            return BrowseSimilarityIndex.build(preparedInput: preparedInput)
        }
        state.debugSimilarityIndexEventHandlerForHarness = { events.append($0) }

        state.libraryItems = [source, peer]
        state.tvItems = []
        state.recomputeFilteredItems()

        try assert(state.browseSnapshot.similarity == nil,
                   "full snapshot build should publish before background similarity attaches")
        try assert(waitUntil(timeout: 2.0, condition: { state.browseSnapshot.similarity != nil }),
                   "background similarity index did not attach")
        guard let attachEvent = events.first(where: { $0.attached }) else {
            throw HarnessError.assertion("background similarity attach did not emit a timing event")
        }
        try assert(attachEvent.durationMS >= 0,
                   "similarity-index timing event should record non-negative duration")
        try assert(state.browseSnapshot.similarity?.rankedMovieIDs(for: source.id).contains(peer.id) == true,
                   "attached similarity index should serve ranked movie IDs")
    }

    private static func verifySimilarityIndexDropsStaleGeneration() throws {
        let firstSource = makeMovie(
            title: "First Source",
            year: 2020,
            genres: ["Drama"],
            position: 0,
            lastPlayed: nil,
            dateAdded: Date(timeIntervalSince1970: 100),
            voteAverage: 7.0
        )
        let firstPeer = makeMovie(
            title: "First Peer",
            year: 2021,
            genres: ["Drama"],
            position: 0,
            lastPlayed: nil,
            dateAdded: Date(timeIntervalSince1970: 200),
            voteAverage: 7.2
        )
        let secondSource = makeMovie(
            title: "Second Source",
            year: 1980,
            genres: ["Horror"],
            position: 0,
            lastPlayed: nil,
            dateAdded: Date(timeIntervalSince1970: 300),
            voteAverage: 7.4
        )
        let secondPeer = makeMovie(
            title: "Second Peer",
            year: 1981,
            genres: ["Horror"],
            position: 0,
            lastPlayed: nil,
            dateAdded: Date(timeIntervalSince1970: 400),
            voteAverage: 7.5
        )
        let state = makeLibraryState()
        let lock = NSLock()
        var buildCount = 0
        var events: [LibraryState.SimilarityIndexDebugEvent] = []
        // The first build is held until the harness has invalidated its
        // generation, so the drop is always observed after background scoring.
        // A fixed sleep raced the invalidation under load: if the build finished
        // first it attached instead of dropping, and no post-scoring drop event
        // was ever emitted.
        let releaseFirstBuild = DispatchSemaphore(value: 0)
        state.debugSimilarityIndexBuilderForHarness = { preparedInput in
            lock.lock()
            buildCount += 1
            let currentBuild = buildCount
            lock.unlock()
            if currentBuild == 1 {
                releaseFirstBuild.wait()
            }
            return BrowseSimilarityIndex.build(preparedInput: preparedInput)
        }
        state.debugSimilarityIndexEventHandlerForHarness = { events.append($0) }

        state.libraryItems = [firstSource, firstPeer]
        state.tvItems = []
        state.recomputeFilteredItems()
        try assert(waitUntil(timeout: 2.0, condition: {
            lock.lock()
            let didStart = buildCount > 0
            lock.unlock()
            return didStart
        }), "first similarity build should start before stale-generation invalidation")
        state.libraryItems = [secondSource, secondPeer]
        // `scheduleSimilarityIndexCompute` bumps the generation synchronously, so
        // once this returns the first build is guaranteed to be stale.
        state.recomputeFilteredItems()
        releaseFirstBuild.signal()

        try assert(waitUntil(timeout: 3.0, condition: {
            events.contains(where: { $0.dropReason == .generation && $0.durationMS > 0 })
                && events.contains(where: { $0.attached })
        }), "stale similarity generation should drop after background scoring instead of attaching")
        let finalRanked = state.browseSnapshot.similarity?.rankedMovieIDs(for: secondSource.id) ?? []
        try assert(finalRanked.contains(secondPeer.id),
                   "latest similarity generation should attach for the current snapshot")
        try assert(state.browseSnapshot.similarity?.rankedMovieIDs(for: firstSource.id).isEmpty == true,
                   "stale similarity generation should not reattach old source IDs")
    }

    private static func verifySimilarityIndexDropsSourceIdentityMismatch() throws {
        let source = makeMovie(
            title: "Identity Source",
            year: 2020,
            genres: ["Drama"],
            position: 0,
            lastPlayed: nil,
            dateAdded: Date(timeIntervalSince1970: 100),
            voteAverage: 7.0
        )
        let peer = makeMovie(
            title: "Identity Peer",
            year: 2021,
            genres: ["Drama"],
            position: 0,
            lastPlayed: nil,
            dateAdded: Date(timeIntervalSince1970: 200),
            voteAverage: 7.2
        )
        let state = makeLibraryState()
        var events: [LibraryState.SimilarityIndexDebugEvent] = []
        state.debugSimilarityIndexEventHandlerForHarness = { events.append($0) }
        state.libraryItems = [source, peer]
        state.tvItems = []
        state.recomputeFilteredItems()
        try assert(waitUntil(timeout: 2.0, condition: { state.browseSnapshot.similarity != nil }),
                   "initial similarity index should attach before source-identity guard check")

        events.removeAll()
        let wrongSource = makeMovie(
            title: "Wrong Identity",
            year: 1970,
            genres: ["Comedy"],
            position: 0,
            lastPlayed: nil,
            dateAdded: Date(timeIntervalSince1970: 300)
        )
        state.debugScheduleSimilarityIndexComputeForHarness(
            movieIdentity: [ObjectIdentifier(wrongSource)],
            tvIdentity: []
        )
        try assert(waitUntil(timeout: 2.0, condition: {
            events.contains(where: { $0.dropReason == .sourceIdentity })
        }), "source-identity mismatch should drop the background similarity index")
        try assert(state.browseSnapshot.similarity?.rankedMovieIDs(for: source.id).contains(peer.id) == true,
                   "source-identity drop should preserve the already attached current index")
    }

    private static func verifySimilarityIndexDoesNotPrepareWhileProfilePickerVisible() throws {
        let source = makeMovie(
            title: "Picker Source",
            year: 2020,
            genres: ["Drama"],
            position: 0,
            lastPlayed: nil,
            dateAdded: Date(timeIntervalSince1970: 100),
            voteAverage: 7.0
        )
        let peer = makeMovie(
            title: "Picker Peer",
            year: 2021,
            genres: ["Drama"],
            position: 0,
            lastPlayed: nil,
            dateAdded: Date(timeIntervalSince1970: 200),
            voteAverage: 7.2
        )
        var pickerVisible = false
        let state = LibraryState(
            currentProfile: { nil },
            isProfilePickerVisible: { pickerVisible },
            skipPersistenceForHarness: true
        )
        state.debugSimilarityIndexComputeDelayForHarness = 0
        var buildCount = 0
        var events: [LibraryState.SimilarityIndexDebugEvent] = []
        state.debugSimilarityIndexBuilderForHarness = { preparedInput in
            buildCount += 1
            return BrowseSimilarityIndex.build(preparedInput: preparedInput)
        }
        state.debugSimilarityIndexEventHandlerForHarness = { events.append($0) }

        state.libraryItems = [source, peer]
        state.tvItems = []
        state.recomputeFilteredItems()
        pickerVisible = true

        try assert(waitUntil(timeout: 0.25, condition: {
            events.contains(where: { $0.dropReason == .profilePickerVisible })
        }), "profile-picker-visible similarity work should emit an explicit drop event")
        try assert(buildCount == 0,
                   "similarity index should not prepare on the main actor while the profile picker is visible")
        try assert(state.browseSnapshot.similarity == nil,
                   "profile-picker-visible similarity work should not attach to the snapshot")
    }

    private static func verifySimilarityIndexReschedulesAfterPickerDropOnSameIdentityRefresh() throws {
        let source = makeMovie(
            title: "Same Identity Source",
            year: 2020,
            genres: ["Drama"],
            position: 0,
            lastPlayed: nil,
            dateAdded: Date(timeIntervalSince1970: 100),
            voteAverage: 7.0
        )
        let peer = makeMovie(
            title: "Same Identity Peer",
            year: 2021,
            genres: ["Drama"],
            position: 0,
            lastPlayed: nil,
            dateAdded: Date(timeIntervalSince1970: 200),
            voteAverage: 7.2
        )
        var pickerVisible = false
        let state = LibraryState(
            currentProfile: { nil },
            isProfilePickerVisible: { pickerVisible },
            skipPersistenceForHarness: true
        )
        var events: [LibraryState.SimilarityIndexDebugEvent] = []
        state.debugSimilarityIndexEventHandlerForHarness = { events.append($0) }

        state.debugSimilarityIndexComputeDelayForHarness = 3600
        state.libraryItems = [source, peer]
        state.tvItems = []
        state.recomputeFilteredItems()
        try assert(state.browseSnapshot.similarity == nil,
                   "restored-cache-like snapshot should start without an attached similarity index")

        pickerVisible = true
        state.debugSimilarityIndexComputeDelayForHarness = 0
        state.debugScheduleSimilarityIndexComputeForHarness(
            movieIdentity: [ObjectIdentifier(source), ObjectIdentifier(peer)],
            tvIdentity: []
        )
        try assert(waitUntil(timeout: 0.25, condition: {
            events.contains(where: { $0.dropReason == .profilePickerVisible })
        }), "profile-picker-visible same-identity work should drop before preparing")

        events.removeAll()
        pickerVisible = false
        state.recomputeFilteredItems()
        try assert(waitUntil(timeout: 0.5, condition: {
            state.browseSnapshot.similarity?.rankedMovieIDs(for: source.id).contains(peer.id) == true
        }), "same-identity refresh should reschedule similarity after a picker-visible drop; events=\(events.map { "g\($0.generation):attached=\($0.attached):drop=\(String(describing: $0.dropReason))" })")
        try assert(events.contains(where: { $0.attached }),
                   "same-identity refresh should emit an attach event after rescheduling")
    }

    private static func rankedMovieTitles(source: MediaItem, candidates: [MediaItem]) -> [String] {
        rankedMovieIDs(source: source, candidates: candidates).compactMap { id in
            candidates.first(where: { $0.id == id })?.displayTitle
        }
    }

    private static func rankedMovieIDs(source: MediaItem, candidates: [MediaItem]) -> [UUID] {
        let showSummaries: [BrowseShowSummary] = []
        let index = BrowseSimilarityIndex.build(movies: candidates, showSummaries: showSummaries)
        return index.rankedMovieIDs(for: source.id)
    }

    private static func rankedShowNames(
        source: BrowseShowSummary,
        candidates: [BrowseShowSummary]
    ) -> [String] {
        let index = BrowseSimilarityIndex.build(movies: [], showSummaries: candidates)
        return index.rankedShowNames(for: source.showName)
    }

    private static func makeLibraryState() -> LibraryState {
        let state = LibraryState(
            currentProfile: { nil },
            isProfilePickerVisible: { false },
            skipPersistenceForHarness: true
        )
        state.debugSimilarityIndexComputeDelayForHarness = 0
        return state
    }

    private static func waitUntil(timeout: TimeInterval, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    private static func makeMovie(
        title: String,
        year: Int,
        genres: [String],
        position: Double,
        lastPlayed: Date?,
        dateAdded: Date,
        director: String? = nil,
        cast: [TMDBMetadata.CastEntry] = [],
        overview: String? = nil,
        voteAverage: Double? = nil,
        voteCount: Int? = nil,
        backdropPath: String? = nil,
        collectionID: Int? = nil,
        collectionName: String? = nil,
        keywords: [TMDBMetadata.Keyword] = [],
        certification: String? = nil,
        showName: String? = nil,
        episodeNumber: Int = 1,
        duration: TimeInterval = 7_200
    ) -> MediaItem {
        let item = MediaItem(
            filePath: "/tmp/movies/\(title).mkv",
            fileName: "\(title).mkv",
            title: title,
            year: year,
            fileExtension: "mkv",
            fileSize: 1024,
            duration: duration,
            localGenres: genres,
            dateAdded: dateAdded,
            showName: showName,
            seasonNumber: showName == nil ? nil : 1,
            episodeNumber: showName == nil ? nil : episodeNumber,
            episodeTitle: showName == nil ? nil : title,
            metadata: TMDBMetadata(
                tmdbID: 1,
                overview: overview,
                genres: genres,
                cast: cast,
                director: director,
                certification: certification,
                voteAverage: voteAverage,
                voteCount: voteCount,
                collectionID: collectionID,
                collectionName: collectionName,
                keywords: keywords,
                posterPath: nil,
                backdropPath: backdropPath,
                releaseDate: nil,
                runtime: nil
            )
        )
        item.playbackPosition = position
        item.lastPlayedDate = lastPlayed
        item.isWatched = false
        return item
    }

    private static func cast(_ name: String, id: Int) -> TMDBMetadata.CastEntry {
        TMDBMetadata.CastEntry(
            name: name,
            character: "Lead",
            profilePath: nil,
            tmdbPersonID: id
        )
    }

    private static func keyword(_ id: Int, _ name: String) -> TMDBMetadata.Keyword {
        TMDBMetadata.Keyword(id: id, name: name)
    }

    private static func showSummary(name: String, representative: MediaItem) -> BrowseShowSummary {
        BrowseShowSummary(
            showName: name,
            representative: representative,
            episodes: [representative],
            upNext: representative,
            seasonCount: 1,
            genres: representative.displayGenres
        )
    }

    private static func makeEpisode(
        show: String,
        title: String,
        season: Int,
        episode: Int,
        genres: [String],
        position: Double,
        watched: Bool,
        lastPlayed: Date?,
        dateAdded: Date
    ) -> MediaItem {
        let item = MediaItem(
            filePath: "/tmp/tv/\(show)/S\(season)E\(episode).mkv",
            fileName: "S\(season)E\(episode).mkv",
            title: title,
            year: 2022,
            fileExtension: "mkv",
            fileSize: 1024,
            duration: 3600,
            localGenres: genres,
            dateAdded: dateAdded,
            showName: show,
            seasonNumber: season,
            episodeNumber: episode,
            episodeTitle: title
        )
        item.playbackPosition = position
        item.lastPlayedDate = lastPlayed
        item.isWatched = watched
        return item
    }

    private static func assert(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() {
            throw HarnessError.assertion(message)
        }
    }

    private enum HarnessError: Error, CustomStringConvertible {
        case assertion(String)

        var description: String {
            switch self {
            case .assertion(let message): return message
            }
        }
    }
}

#endif
