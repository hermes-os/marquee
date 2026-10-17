//
//  VerifyEnrichmentActorHarness.swift
//  Marquee
//
//  Phase 2E.4b step (b) — actor-level scenarios that pin the
//  TMDBEnrichmentService retry contract:
//    A. enrichmentRetriesIncompleteArtwork
//    B. enrichmentSkipsCompleteOwners (B.1 movie + B.2 TV episode)
//    C. enrichmentRepairsFullPresentThumbMissing
//
//  Driven via FakeTMDBMetadataFetching + FakeArtworkDownloading
//  injected at actor construction. Memory-store catalog backing.
//  No global state.
//
//  DEBUG-only — gated by `#if DEBUG`. Activated by
//  `--verify-enrichment-actor`.
//
//  Exit codes: 0 = all pass, 1 = at least one scenario failed,
//  2 = internal error.
//

#if DEBUG

import Foundation

public enum VerifyEnrichmentActorHarness {

    public static let launchArgument = "--verify-enrichment-actor"

    public static func runIfRequested() {
        guard CommandLine.arguments.contains(launchArgument) else { return }

        let semaphore = DispatchSemaphore(value: 0)
        let result = ExitCodeBox()

        Task.detached {
            do {
                let code = try await runHarness()
                result.set(code)
            } catch {
                let line = "verify-enrichment-actor: error: \(error)\n"
                FileHandle.standardError.write(Data(line.utf8))
                result.set(2)
            }
            semaphore.signal()
        }

        semaphore.wait()
        exit(result.value)
    }

    private final class ExitCodeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Int32 = 2
        func set(_ code: Int32) { lock.lock(); stored = code; lock.unlock() }
        var value: Int32 { lock.lock(); defer { lock.unlock() }; return stored }
    }

    private struct Outcome {
        let name: String
        let passed: Bool
        let detail: String
    }

    private static func runHarness() async throws -> Int32 {
        var results: [Outcome] = []

        results.append(await wrap("enrichmentRetriesIncompleteArtwork") {
            try await runRetriesIncompleteArtwork()
        })
        results.append(await wrap("enrichmentSkipsCompleteOwners") {
            try await runSkipsCompleteOwners()
        })
        results.append(await wrap("enrichmentRepairsFullPresentThumbMissing") {
            try await runRepairsFullPresentThumbMissing()
        })
        results.append(await wrap("movieIntelligenceRoundTrip") {
            try await runMovieIntelligenceRoundTrip()
        })
        results.append(await wrap("movieEdgesReconcileAfterPass") {
            try await runMovieEdgesReconcileAfterPass()
        })
        results.append(await wrap("movieEdgesReconcileAfterDelayedTarget") {
            try await runMovieEdgesReconcileAfterDelayedTarget()
        })
        results.append(await wrap("movieIntelligenceBackfillPreservesStoredTMDBID") {
            try await runMovieIntelligenceBackfillPreservesStoredTMDBID()
        })

        for r in results {
            let mark = r.passed ? "PASS" : "FAIL"
            let line = "verify-enrichment-actor: \(mark) \(r.name): \(r.detail)\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
        let passed = results.filter { $0.passed }.count
        let allPassed = passed == results.count
        let summary = "verify-enrichment-actor: outcome="
            + (allPassed ? "verified" : "failed")
            + " passed=\(passed)/\(results.count)\n"
        FileHandle.standardError.write(Data(summary.utf8))
        return allPassed ? 0 : 1
    }

    private static func wrap(
        _ name: String,
        _ body: () async throws -> String
    ) async -> Outcome {
        do {
            let detail = try await body()
            return Outcome(name: name, passed: true, detail: detail)
        } catch {
            return Outcome(name: name, passed: false, detail: "\(error)")
        }
    }

    // MARK: - Fixtures

    private static let volumeUUID = "actor-verify"

    private static func makeMovieFile(
        relativePath: String = "Movies/Test Movie (2024)/Test Movie (2024).mkv"
    ) -> CatalogMediaFile {
        let id = MediaIdentity.mediaFileID(
            volumeUUID: volumeUUID,
            relativePath: relativePath
        )
        return CatalogMediaFile(
            id: id,
            volumeUUID: volumeUUID,
            relativePath: relativePath,
            absolutePathSnapshot: "/tmp/marquee-actor/\(relativePath)",
            fileExtension: "mkv",
            fileSize: 1,
            modificationDate: Date(timeIntervalSince1970: 0),
            durationSeconds: nil,
            contentHash: nil,
            dateAdded: Date(timeIntervalSince1970: 0)
        )
    }

    private static func makeEpisodeFile(
        relativePath: String = "TV/My Show (2020)/Season 1/My Show - s01e01.mkv"
    ) -> CatalogMediaFile {
        let id = MediaIdentity.mediaFileID(
            volumeUUID: volumeUUID,
            relativePath: relativePath
        )
        return CatalogMediaFile(
            id: id,
            volumeUUID: volumeUUID,
            relativePath: relativePath,
            absolutePathSnapshot: "/tmp/marquee-actor/\(relativePath)",
            fileExtension: "mkv",
            fileSize: 1,
            modificationDate: Date(timeIntervalSince1970: 0),
            durationSeconds: nil,
            contentHash: nil,
            dateAdded: Date(timeIntervalSince1970: 0)
        )
    }

    // MARK: - Scenario A: retries incomplete artwork

    private static func runRetriesIncompleteArtwork() async throws -> String {
        let store = InMemoryCatalogStore()
        let file = makeMovieFile()
        try await store.upsert(mediaFile: file)

        let movieID = MediaIdentity.movieID(primaryFile: file.id)
        let owner = ArtworkOwner.movie(movieID)
        let tmdbID = 100

        let tmdb = FakeTMDBMetadataFetching()
        tmdb.setMovie(
            title: "Test Movie",
            year: 2024,
            metadata: TMDBMetadata(
                tmdbID: tmdbID,
                overview: "A test.",
                genres: ["Drama"],
                cast: [
                    .init(name: "Alice", character: "Hero",   profilePath: "/a.jpg", tmdbPersonID: 1),
                    .init(name: "Bob",   character: "Villain", profilePath: nil,     tmdbPersonID: 2),
                ],
                director: "Dir",
                certification: "PG",
                voteAverage: 7.0,
                voteCount: 100,
                popularity: 12.5,
                posterPath: "/p.jpg",
                backdropPath: "/b.jpg",
                releaseDate: "2024-01-01",
                runtime: 100
            )
        )

        let cache = FakeArtworkDownloading()
        // Phase 1: poster fails (no thumb), backdrop succeeds.
        // Phase 2: both succeed.
        cache.setPhases(tmdbID: tmdbID, phases: [
            FakeArtworkDownloading.CacheState(
                posterFull: "/full/p", posterThumb: nil,
                backdropFull: "/full/b", backdropThumb: "/thumb/b"
            ),
            FakeArtworkDownloading.CacheState(
                posterFull: "/full/p", posterThumb: "/thumb/p",
                backdropFull: "/full/b", backdropThumb: "/thumb/b"
            ),
        ])

        let actor = TMDBEnrichmentService(catalog: store, tmdb: tmdb, imageCache: cache)

        // Run 1
        _ = try await actor.enrichMissing()
        let snap1 = try await store.enrichmentSnapshot()
        let art1 = (snap1.artworkByOwner[owner] ?? [])
            .sorted { $0.kind.rawValue < $1.kind.rawValue }
        guard art1.count == 2 else {
            throw HarnessError("run1 expected 2 artwork rows, got \(art1.count)")
        }
        guard let backdrop1 = art1.first(where: { $0.kind == .backdrop }),
              let poster1 = art1.first(where: { $0.kind == .poster }) else {
            throw HarnessError("run1 missing kinds")
        }
        guard backdrop1.localPath == "/thumb/b" else {
            throw HarnessError("run1 backdrop local_path expected '/thumb/b' got \(backdrop1.localPath ?? "nil")")
        }
        guard poster1.localPath == nil else {
            throw HarnessError("run1 poster local_path expected nil got \(poster1.localPath ?? "nil")")
        }
        guard TMDBEnrichmentService.ownerNeedsEnrichment(owner, snapshot: snap1) else {
            throw HarnessError("run1 owner should still need enrichment")
        }

        // Run 2
        _ = try await actor.enrichMissing()
        let snap2 = try await store.enrichmentSnapshot()
        let art2 = (snap2.artworkByOwner[owner] ?? [])
            .sorted { $0.kind.rawValue < $1.kind.rawValue }
        guard art2.count == 2,
              let poster2 = art2.first(where: { $0.kind == .poster }),
              let _ = art2.first(where: { $0.kind == .backdrop }) else {
            throw HarnessError("run2 expected 2 artwork rows")
        }
        guard poster2.localPath == "/thumb/p" else {
            throw HarnessError("run2 poster local_path expected '/thumb/p' got \(poster2.localPath ?? "nil")")
        }
        guard !TMDBEnrichmentService.ownerNeedsEnrichment(owner, snapshot: snap2) else {
            throw HarnessError("run2 owner should be complete")
        }
        // No duplicate cast rows: full-replace per owner means 2 cast,
        // 2 person across both runs (not 4 cast).
        let cast = (snap2.castByOwner[owner] ?? [])
        guard cast.count == 2 else {
            throw HarnessError("run2 expected 2 cast rows (no duplicates), got \(cast.count)")
        }

        return "run1 incomplete, run2 complete; cast not duplicated"
    }

    // MARK: - Scenario B: skips complete owners

    private static func runSkipsCompleteOwners() async throws -> String {
        try await runSkipsCompleteOwnersMovie()
        try await runSkipsCompleteOwnersEpisode()
        return "movie + tv episode both skip cleanly"
    }

    private static func runSkipsCompleteOwnersMovie() async throws {
        let store = InMemoryCatalogStore()
        let file = makeMovieFile()
        try await store.upsert(mediaFile: file)

        let movieID = MediaIdentity.movieID(primaryFile: file.id)
        let owner = ArtworkOwner.movie(movieID)
        let movie = CatalogMovie(
            id: movieID,
            primaryFile: file.id,
            title: "Test Movie",
            year: 2024,
            tmdbID: 100,
            overview: nil,
            runtimeMinutes: 100,
            certification: nil,
            releaseDate: nil,
            genres: [],
            voteAverage: nil,
            director: nil
        )
        let artwork = [
            CatalogArtworkAsset(
                id: MediaIdentity.artworkID(owner: owner, kind: .poster, sourceLabel: "tmdb"),
                owner: owner, kind: .poster,
                localPath: "/seed/p", remoteURL: "/p.jpg", sourceLabel: "tmdb"
            ),
            CatalogArtworkAsset(
                id: MediaIdentity.artworkID(owner: owner, kind: .backdrop, sourceLabel: "tmdb"),
                owner: owner, kind: .backdrop,
                localPath: "/seed/b", remoteURL: "/b.jpg", sourceLabel: "tmdb"
            ),
        ]
        try await store.replaceEnrichment(
            owner: owner, core: .movie(movie), cast: [], artwork: artwork
        )
        try await store.replaceMovieIntelligence(
            movieID: movieID,
            voteCount: 10,
            popularity: 1.0,
            collectionID: nil,
            collectionName: nil,
            keywords: [],
            edges: []
        )

        let preSnap = try await store.enrichmentSnapshot()
        let tmdb = FakeTMDBMetadataFetching()
        let cache = FakeArtworkDownloading()
        let actor = TMDBEnrichmentService(catalog: store, tmdb: tmdb, imageCache: cache)
        _ = try await actor.enrichMissing()
        let postSnap = try await store.enrichmentSnapshot()

        guard tmdb.totalCalls == 0 else {
            throw HarnessError("B.1 expected fetcher calls = 0, got \(tmdb.totalCalls)")
        }
        guard cache.totalCalls == 0 else {
            throw HarnessError("B.1 expected downloader calls = 0, got \(cache.totalCalls)")
        }
        guard snapshotsEqual(preSnap, postSnap) else {
            throw HarnessError("B.1 snapshot drift")
        }
    }

    private static func runSkipsCompleteOwnersEpisode() async throws {
        let store = InMemoryCatalogStore()
        let file = makeEpisodeFile()
        try await store.upsert(mediaFile: file)

        let showID = MediaIdentity.showID(title: "My Show", year: 2020)
        let seasonID = MediaIdentity.seasonID(show: showID, seasonNumber: 1)
        let episodeID = MediaIdentity.episodeID(
            season: seasonID, episodeNumber: 1, primaryFile: file.id
        )

        let show = CatalogShow(
            id: showID, title: "My Show", year: 2020,
            tmdbID: 200, overview: nil, certification: nil, genres: [],
            releaseDate: nil, runtimeMinutes: nil, voteAverage: nil, director: nil
        )
        let showOwner = ArtworkOwner.show(showID)
        let showArt = [
            CatalogArtworkAsset(
                id: MediaIdentity.artworkID(owner: showOwner, kind: .poster, sourceLabel: "tmdb"),
                owner: showOwner, kind: .poster,
                localPath: "/seed/sp", remoteURL: "/sp.jpg", sourceLabel: "tmdb"
            ),
            CatalogArtworkAsset(
                id: MediaIdentity.artworkID(owner: showOwner, kind: .backdrop, sourceLabel: "tmdb"),
                owner: showOwner, kind: .backdrop,
                localPath: "/seed/sb", remoteURL: "/sb.jpg", sourceLabel: "tmdb"
            ),
        ]
        try await store.replaceEnrichment(
            owner: showOwner, core: .show(show), cast: [], artwork: showArt
        )

        let season = CatalogSeason(id: seasonID, showID: showID, seasonNumber: 1)
        try await store.replaceEnrichment(
            owner: .season(seasonID), core: .season(season), cast: [], artwork: []
        )

        let episode = CatalogEpisode(
            id: episodeID, seasonID: seasonID, primaryFile: file.id,
            episodeNumber: 1, title: "Pilot", overview: nil, runtimeMinutes: nil,
            tmdbID: 300, certification: nil, releaseDate: "2020-01-01", voteAverage: 7.0
        )
        let episodeOwner = ArtworkOwner.episode(episodeID)
        let episodeArt = [
            CatalogArtworkAsset(
                id: MediaIdentity.artworkID(owner: episodeOwner, kind: .still, sourceLabel: "tmdb"),
                owner: episodeOwner, kind: .still,
                localPath: "/seed/still", remoteURL: "/still.jpg", sourceLabel: "tmdb"
            ),
        ]
        try await store.replaceEnrichment(
            owner: episodeOwner, core: .episode(episode), cast: [], artwork: episodeArt
        )

        let preSnap = try await store.enrichmentSnapshot()
        let tmdb = FakeTMDBMetadataFetching()
        let cache = FakeArtworkDownloading()
        let actor = TMDBEnrichmentService(catalog: store, tmdb: tmdb, imageCache: cache)
        _ = try await actor.enrichMissing()
        let postSnap = try await store.enrichmentSnapshot()

        guard tmdb.totalCalls == 0 else {
            throw HarnessError("B.2 expected fetcher calls = 0, got \(tmdb.totalCalls)")
        }
        guard cache.totalCalls == 0 else {
            throw HarnessError("B.2 expected downloader calls = 0, got \(cache.totalCalls)")
        }
        guard snapshotsEqual(preSnap, postSnap) else {
            throw HarnessError("B.2 snapshot drift")
        }
    }

    // MARK: - Scenario C: thumb-missing repair

    private static func runRepairsFullPresentThumbMissing() async throws -> String {
        let store = InMemoryCatalogStore()
        let file = makeMovieFile()
        try await store.upsert(mediaFile: file)

        let movieID = MediaIdentity.movieID(primaryFile: file.id)
        let owner = ArtworkOwner.movie(movieID)
        let tmdbID = 100

        let tmdb = FakeTMDBMetadataFetching()
        tmdb.setMovie(
            title: "Test Movie",
            year: 2024,
            metadata: TMDBMetadata(
                tmdbID: tmdbID,
                overview: nil,
                genres: [],
                cast: [],
                director: nil,
                certification: nil,
                voteAverage: nil,
                voteCount: 1,
                popularity: 1,
                posterPath: "/p.jpg",
                backdropPath: "/b.jpg",
                releaseDate: nil,
                runtime: nil
            )
        )

        let cache = FakeArtworkDownloading()
        // Initial state: full present, thumb missing. The fake's
        // download mirrors the spec's repair contract: the next call
        // produces the missing thumbs, which is exactly the production
        // behavior the new gate enforces.
        cache.setInitialState(tmdbID: tmdbID, FakeArtworkDownloading.CacheState(
            posterFull: "/full/p", posterThumb: nil,
            backdropFull: "/full/b", backdropThumb: nil
        ))
        cache.setPhases(tmdbID: tmdbID, phases: [
            FakeArtworkDownloading.CacheState(
                posterFull: "/full/p", posterThumb: "/thumb/p",
                backdropFull: "/full/b", backdropThumb: "/thumb/b"
            ),
        ])

        let actor = TMDBEnrichmentService(catalog: store, tmdb: tmdb, imageCache: cache)

        // Run 1
        _ = try await actor.enrichMissing()
        guard cache.downloadCallCount == 1 else {
            throw HarnessError("C run1 expected 1 download call, got \(cache.downloadCallCount)")
        }
        guard cache.lastForceRedownload == false else {
            throw HarnessError("C run1 expected forceRedownload=false, got \(String(describing: cache.lastForceRedownload))")
        }
        let snap1 = try await store.enrichmentSnapshot()
        let art1 = snap1.artworkByOwner[owner] ?? []
        guard art1.allSatisfy({ $0.localPath != nil }) else {
            throw HarnessError("C run1 expected all artwork local_path non-nil")
        }
        guard !TMDBEnrichmentService.ownerNeedsEnrichment(owner, snapshot: snap1) else {
            throw HarnessError("C run1 owner should be complete")
        }

        // Run 2 — no-op rerun.
        _ = try await actor.enrichMissing()
        guard cache.downloadCallCount == 1 else {
            throw HarnessError("C run2 expected download counter unchanged at 1, got \(cache.downloadCallCount)")
        }

        return "run1 repaired thumbs, run2 no-op"
    }

    // MARK: - Scenario D: movie intelligence round-trip

    private static func runMovieIntelligenceRoundTrip() async throws -> String {
        let store = InMemoryCatalogStore()
        let file = makeMovieFile()
        try await store.upsert(mediaFile: file)

        let sourceID = MediaIdentity.movieID(primaryFile: file.id)
        let targetID = MovieID(rawValue: "target-local-movie")
        let target = CatalogMovie(
            id: targetID,
            primaryFile: MediaFileID(rawValue: "target-file"),
            title: "Target Movie",
            year: 2020,
            tmdbID: 200,
            overview: nil,
            runtimeMinutes: nil,
            certification: nil,
            releaseDate: nil,
            genres: [],
            voteAverage: nil,
            director: nil,
            voteCount: 20,
            popularity: 2.0
        )
        try await store.upsert(movie: target)

        let tmdb = FakeTMDBMetadataFetching()
        tmdb.setMovie(
            title: "Test Movie",
            year: 2024,
            metadata: TMDBMetadata(
                tmdbID: 100,
                overview: "A heist.",
                genres: ["Crime"],
                cast: [],
                director: "Director",
                certification: "PG-13",
                voteAverage: 8.1,
                voteCount: 1234,
                popularity: 55.5,
                collectionID: 77,
                collectionName: "Fixture Collection",
                keywords: [
                    .init(id: 10, name: "heist"),
                    .init(id: 11, name: "neo-noir"),
                ],
                movieEdges: [
                    .init(
                        targetMovieID: "200",
                        edgeType: CatalogMovieEdgeType.similar.rawValue,
                        rank: 0,
                        score: nil
                    ),
                    .init(
                        targetMovieID: "200",
                        edgeType: CatalogMovieEdgeType.recommendation.rawValue,
                        rank: 0,
                        score: nil
                    ),
                    .init(
                        targetMovieID: "999",
                        edgeType: CatalogMovieEdgeType.similar.rawValue,
                        rank: 1,
                        score: nil
                    ),
                ],
                posterPath: nil,
                backdropPath: nil,
                releaseDate: "2024-01-01",
                runtime: 99
            )
        )

        let actor = TMDBEnrichmentService(
            catalog: store,
            tmdb: tmdb,
            imageCache: FakeArtworkDownloading()
        )
        _ = try await actor.enrichMissing()

        let snap = try await store.enrichmentSnapshot()
        guard let movie = snap.movies[sourceID] else {
            throw HarnessError("D source movie missing after enrich")
        }
        guard movie.voteCount == 1234,
              movie.popularity == 55.5,
              movie.collectionID == 77,
              movie.collectionName == "Fixture Collection" else {
            throw HarnessError("D movie intelligence fields did not round-trip")
        }
        let keywords = snap.movieKeywordsByMovie[sourceID] ?? []
        guard keywords.map(\.name).sorted() == ["heist", "neo-noir"] else {
            throw HarnessError("D keywords mismatch: \(keywords)")
        }
        let edges = snap.movieEdgesBySource[sourceID] ?? []
        let edgeTypes = Set(edges.map(\.edgeType))
        guard edges.count == 2,
              edgeTypes == Set([.similar, .recommendation]),
              edges.allSatisfy({ $0.targetMovieID == targetID }) else {
            throw HarnessError("D edges mismatch: \(edges)")
        }

        let report = try await store.movieIntelligenceCoverageReport()
        guard let row = report.rows.first(where: { $0.movieID == sourceID }),
              row.keywordCount == 2,
              row.collectionID == 77,
              row.edgeCount == 2 else {
            throw HarnessError("D coverage row missing or wrong: \(report.rows)")
        }

        let metadata = DefaultCatalogProjection.makeMovieMetadata(
            movie: movie,
            cast: [],
            artwork: [],
            keywords: keywords,
            edges: edges
        )
        guard metadata?.keywords.count == 2,
              metadata?.collectionID == 77,
              metadata?.movieEdges.count == 2 else {
            throw HarnessError("D projected metadata missing D2 fields")
        }

        return "fields, keywords, local edges, coverage, projection metadata"
    }

    private static func runMovieEdgesReconcileAfterPass() async throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "marquee-edge-reconcile-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try SQLiteCatalogStore(
            path: dir.appendingPathComponent("catalog.sqlite").path
        )
        let sourceFile = makeMovieFile(
            relativePath: "Movies/Alpha Source (2024)/Alpha Source (2024).mkv"
        )
        let targetFile = makeMovieFile(
            relativePath: "Movies/Zeta Target (2024)/Zeta Target (2024).mkv"
        )
        try await store.upsert(mediaFiles: [sourceFile, targetFile])

        let tmdb = FakeTMDBMetadataFetching()
        tmdb.setMovie(
            title: "Alpha Source",
            year: 2024,
            metadata: TMDBMetadata(
                tmdbID: 100,
                overview: nil,
                genres: [],
                cast: [],
                director: nil,
                certification: nil,
                voteAverage: nil,
                voteCount: 10,
                popularity: 1.0,
                keywords: [.init(id: 1, name: "source")],
                movieEdges: [
                    .init(
                        targetMovieID: "200",
                        edgeType: CatalogMovieEdgeType.similar.rawValue,
                        rank: 0,
                        score: nil
                    ),
                ],
                posterPath: nil,
                backdropPath: nil,
                releaseDate: "2024-01-01",
                runtime: nil
            )
        )
        tmdb.setMovie(
            title: "Zeta Target",
            year: 2024,
            metadata: TMDBMetadata(
                tmdbID: 200,
                overview: nil,
                genres: [],
                cast: [],
                director: nil,
                certification: nil,
                voteAverage: nil,
                voteCount: 20,
                popularity: 2.0,
                posterPath: nil,
                backdropPath: nil,
                releaseDate: "2024-01-01",
                runtime: nil
            )
        )

        let actor = TMDBEnrichmentService(
            catalog: store,
            tmdb: tmdb,
            imageCache: FakeArtworkDownloading()
        )
        _ = try await actor.enrichMissing()

        let sourceID = MediaIdentity.movieID(primaryFile: sourceFile.id)
        let targetID = MediaIdentity.movieID(primaryFile: targetFile.id)
        let snap = try await store.enrichmentSnapshot()
        let edges = snap.movieEdgesBySource[sourceID] ?? []
        guard edges.count == 1,
              edges[0].targetMovieID == targetID,
              edges[0].edgeType == .similar else {
            throw HarnessError("source-before-target edge missing: \(edges)")
        }
        return "source-before-target movie edge reconciled after pass"
    }

    private static func runMovieEdgesReconcileAfterDelayedTarget() async throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "marquee-delayed-edge-reconcile-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try SQLiteCatalogStore(
            path: dir.appendingPathComponent("catalog.sqlite").path
        )
        let sourceFile = makeMovieFile(
            relativePath: "Movies/Alpha Source (2024)/Alpha Source (2024).mkv"
        )
        let targetFile = makeMovieFile(
            relativePath: "Movies/Zeta Target (2024)/Zeta Target (2024).mkv"
        )
        try await store.upsert(mediaFile: sourceFile)

        let tmdb = FakeTMDBMetadataFetching()
        tmdb.setMovie(
            title: "Alpha Source",
            year: 2024,
            metadata: TMDBMetadata(
                tmdbID: 100,
                overview: nil,
                genres: [],
                cast: [],
                director: nil,
                certification: nil,
                voteAverage: nil,
                voteCount: 10,
                popularity: 1.0,
                keywords: [.init(id: 1, name: "source")],
                movieEdges: [
                    .init(
                        targetMovieID: "200",
                        edgeType: CatalogMovieEdgeType.similar.rawValue,
                        rank: 0,
                        score: nil
                    ),
                ],
                posterPath: nil,
                backdropPath: nil,
                releaseDate: "2024-01-01",
                runtime: nil
            )
        )
        tmdb.setMovie(
            title: "Zeta Target",
            year: 2024,
            metadata: TMDBMetadata(
                tmdbID: 200,
                overview: nil,
                genres: [],
                cast: [],
                director: nil,
                certification: nil,
                voteAverage: nil,
                voteCount: 20,
                popularity: 2.0,
                posterPath: nil,
                backdropPath: nil,
                releaseDate: "2024-01-01",
                runtime: nil
            )
        )

        let actor = TMDBEnrichmentService(
            catalog: store,
            tmdb: tmdb,
            imageCache: FakeArtworkDownloading()
        )
        _ = try await actor.enrichMissing()

        let sourceID = MediaIdentity.movieID(primaryFile: sourceFile.id)
        let targetID = MediaIdentity.movieID(primaryFile: targetFile.id)
        let snap1 = try await store.enrichmentSnapshot()
        guard (snap1.movieEdgesBySource[sourceID] ?? []).isEmpty else {
            throw HarnessError("delayed-target setup expected no source edges after pass1")
        }

        try await store.upsert(mediaFile: targetFile)
        _ = try await actor.enrichMissing()

        let snap2 = try await store.enrichmentSnapshot()
        let edges = snap2.movieEdgesBySource[sourceID] ?? []
        guard edges.count == 1,
              edges[0].targetMovieID == targetID,
              edges[0].edgeType == .similar else {
            throw HarnessError("delayed-target edge missing after pass2: \(edges)")
        }
        return "delayed target movie edge reconciled on later pass"
    }

    private static func runMovieIntelligenceBackfillPreservesStoredTMDBID() async throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "marquee-stored-id-backfill-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try SQLiteCatalogStore(
            path: dir.appendingPathComponent("catalog.sqlite").path
        )
        let file = makeMovieFile(
            relativePath: "Movies/Rematched Filename (1999)/Rematched Filename (1999).mkv"
        )
        try await store.upsert(mediaFile: file)

        let movieID = MediaIdentity.movieID(primaryFile: file.id)
        let existing = CatalogMovie(
            id: movieID,
            primaryFile: file.id,
            title: "Curated Canonical Title",
            year: 1984,
            tmdbID: 4242,
            overview: "Existing overview",
            runtimeMinutes: 101,
            certification: "PG",
            releaseDate: "1984-10-26",
            genres: ["Drama"],
            voteAverage: 7.7,
            director: "Existing Director"
        )
        try await store.replaceEnrichment(
            owner: .movie(movieID),
            core: .movie(existing),
            cast: [],
            artwork: []
        )

        let tmdb = FakeTMDBMetadataFetching()
        tmdb.setMovie(
            title: "Rematched Filename",
            year: 1999,
            metadata: TMDBMetadata(
                tmdbID: 9999,
                overview: "Wrong title search result",
                genres: ["Wrong"],
                cast: [],
                director: nil,
                certification: nil,
                voteAverage: nil,
                voteCount: 9,
                popularity: 9.9,
                keywords: [.init(id: 9, name: "wrong")],
                posterPath: nil,
                backdropPath: nil,
                releaseDate: "1999-01-01",
                runtime: nil
            )
        )
        tmdb.setMovie(
            tmdbID: 4242,
            metadata: TMDBMetadata(
                tmdbID: 4242,
                overview: "Stored id result",
                genres: ["Drama"],
                cast: [],
                director: "Stored Director",
                certification: "PG",
                voteAverage: 8.2,
                voteCount: 4242,
                popularity: 42.42,
                keywords: [.init(id: 42, name: "stored-id")],
                posterPath: nil,
                backdropPath: nil,
                releaseDate: "1984-10-26",
                runtime: 101
            )
        )

        let actor = TMDBEnrichmentService(
            catalog: store,
            tmdb: tmdb,
            imageCache: FakeArtworkDownloading()
        )
        _ = try await actor.enrichMissing()

        let snap = try await store.enrichmentSnapshot()
        guard let movie = snap.movies[movieID] else {
            throw HarnessError("stored-id backfill movie missing")
        }
        guard movie.tmdbID == 4242,
              movie.title == "Curated Canonical Title",
              movie.year == 1984 else {
            throw HarnessError("stored-id backfill rematched catalog identity: \(movie)")
        }
        guard movie.voteCount == 4242,
              movie.popularity == 42.42 else {
            throw HarnessError("stored-id D2 fields did not come from stored id: \(movie)")
        }
        let keywords = snap.movieKeywordsByMovie[movieID] ?? []
        guard keywords.map(\.name) == ["stored-id"] else {
            throw HarnessError("stored-id keywords mismatch: \(keywords)")
        }
        guard tmdb.movieIDCallCount == 1,
              tmdb.movieTitleCallCount == 0 else {
            throw HarnessError(
                "stored-id backfill used wrong TMDB path: "
                + "idCalls=\(tmdb.movieIDCallCount) titleCalls=\(tmdb.movieTitleCallCount)"
            )
        }
        return "existing movie refreshed by stored TMDB id without rematch"
    }

    // MARK: - Snapshot equality

    private static func snapshotsEqual(
        _ a: CatalogEnrichmentSnapshot,
        _ b: CatalogEnrichmentSnapshot
    ) -> Bool {
        guard a.movies == b.movies,
              a.shows == b.shows,
              a.seasons == b.seasons,
              a.episodes == b.episodes else {
            return false
        }
        guard a.artworkByOwner.keys == b.artworkByOwner.keys else { return false }
        for key in a.artworkByOwner.keys {
            let ax = (a.artworkByOwner[key] ?? []).sorted { $0.id.rawValue < $1.id.rawValue }
            let bx = (b.artworkByOwner[key] ?? []).sorted { $0.id.rawValue < $1.id.rawValue }
            if ax != bx { return false }
        }
        guard a.castByOwner.keys == b.castByOwner.keys else { return false }
        for key in a.castByOwner.keys {
            let ax = (a.castByOwner[key] ?? []).sorted { $0.ordinal < $1.ordinal }
            let bx = (b.castByOwner[key] ?? []).sorted { $0.ordinal < $1.ordinal }
            if ax != bx { return false }
        }
        guard a.movieKeywordsByMovie == b.movieKeywordsByMovie,
              a.movieEdgesBySource == b.movieEdgesBySource else {
            return false
        }
        return true
    }

    private struct HarnessError: Error, CustomStringConvertible {
        let description: String
        init(_ msg: String) { self.description = msg }
    }
}

// MARK: - Fakes

/// Deterministic stand-in for `TMDBService.shared`. No global state.
private final class FakeTMDBMetadataFetching: TMDBMetadataFetching, @unchecked Sendable {

    private let lock = NSLock()
    private var movieByKey: [String: TMDBMetadata] = [:]
    private var movieByID: [Int: TMDBMetadata] = [:]
    private var tvByKey: [String: TMDBMetadata] = [:]
    private var seasonByKey: [String: [TMDBService.EpisodeInfo]] = [:]
    private var movieCalls = 0
    private var movieIDCalls = 0
    private var tvCalls = 0
    private var seasonCalls = 0

    var totalCalls: Int {
        withLock { movieCalls + movieIDCalls + tvCalls + seasonCalls }
    }
    var movieTitleCallCount: Int {
        withLock { movieCalls }
    }
    var movieIDCallCount: Int {
        withLock { movieIDCalls }
    }

    func setMovie(title: String, year: Int?, metadata: TMDBMetadata) {
        withLock {
            movieByKey[Self.key(title: title, year: year)] = metadata
            movieByID[metadata.tmdbID] = metadata
        }
    }

    func setMovie(tmdbID: Int, metadata: TMDBMetadata) {
        withLock {
            movieByID[tmdbID] = metadata
        }
    }

    func setTV(title: String, year: Int?, metadata: TMDBMetadata) {
        withLock {
            tvByKey[Self.key(title: title, year: year)] = metadata
        }
    }

    func setSeasonEpisodes(tvID: Int, seasonNumber: Int, episodes: [TMDBService.EpisodeInfo]) {
        withLock {
            seasonByKey["\(tvID)|\(seasonNumber)"] = episodes
        }
    }

    func fetchMovieDetails(title: String, year: Int?) async -> TMDBMetadata? {
        withLock {
            movieCalls += 1
            return movieByKey[Self.key(title: title, year: year)]
        }
    }

    func fetchMovieDetails(tmdbID: Int) async -> TMDBMetadata? {
        withLock {
            movieIDCalls += 1
            return movieByID[tmdbID]
        }
    }

    func fetchTVDetails(title: String, year: Int?) async -> TMDBMetadata? {
        withLock {
            tvCalls += 1
            return tvByKey[Self.key(title: title, year: year)]
        }
    }

    func fetchSeasonEpisodes(tvID: Int, seasonNumber: Int) async -> [TMDBService.EpisodeInfo] {
        withLock {
            seasonCalls += 1
            return seasonByKey["\(tvID)|\(seasonNumber)"] ?? []
        }
    }

    private static func key(title: String, year: Int?) -> String {
        "\(title)|\(year ?? -1)"
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

/// Deterministic stand-in for `ImageCacheService.shared`. Models the
/// `(full, thumb)` pair per tmdbID and accepts a per-call phase
/// sequence so tests can drive transient failures and recoveries.
private final class FakeArtworkDownloading: ArtworkDownloading, @unchecked Sendable {

    struct CacheState: Sendable {
        var posterFull: String?
        var posterThumb: String?
        var backdropFull: String?
        var backdropThumb: String?
    }

    private let lock = NSLock()
    private var states: [Int: CacheState] = [:]
    private var phaseQueue: [Int: [CacheState]] = [:]
    private var downloadCalls = 0
    private var stillCalls = 0
    private var lastForce: Bool?

    var totalCalls: Int {
        withLock { downloadCalls + stillCalls }
    }
    var downloadCallCount: Int {
        withLock { downloadCalls }
    }
    var lastForceRedownload: Bool? {
        withLock { lastForce }
    }

    func setInitialState(tmdbID: Int, _ state: CacheState) {
        withLock {
            states[tmdbID] = state
        }
    }

    /// Each call to `downloadAndCacheImages` for `tmdbID` advances one
    /// phase. After the last phase the state is held steady (mirrors
    /// the production `cachedThumb*Path` lookups returning the last
    /// successful download).
    func setPhases(tmdbID: Int, phases: [CacheState]) {
        withLock {
            phaseQueue[tmdbID] = phases
        }
    }

    func cachedPosterPath(tmdbID: Int) -> String? {
        withLock { states[tmdbID]?.posterFull }
    }

    func cachedBackdropPath(tmdbID: Int) -> String? {
        withLock { states[tmdbID]?.backdropFull }
    }

    func cachedThumbPosterPath(tmdbID: Int) -> String? {
        withLock { states[tmdbID]?.posterThumb }
    }

    func cachedThumbBackdropPath(tmdbID: Int) -> String? {
        withLock { states[tmdbID]?.backdropThumb }
    }

    func downloadAndCacheImages(
        tmdbID: Int,
        posterPath: String?,
        backdropPath: String?,
        forceRedownload: Bool
    ) async {
        withLock {
            downloadCalls += 1
            lastForce = forceRedownload
            if var phases = phaseQueue[tmdbID], !phases.isEmpty {
                states[tmdbID] = phases.removeFirst()
                phaseQueue[tmdbID] = phases
            }
        }
    }

    func downloadEpisodeStill(
        tmdbID: Int,
        seasonNumber: Int,
        episodeNumber: Int,
        stillPath: String
    ) async -> String? {
        withLock {
            stillCalls += 1
            return nil
        }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

#endif
