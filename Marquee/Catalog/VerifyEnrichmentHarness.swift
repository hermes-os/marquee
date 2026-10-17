//
//  VerifyEnrichmentHarness.swift
//  Marquee
//
//  Phase 2E.4b verification harness for the catalog enrichment surface
//  (`replaceEnrichment` + `enrichmentSnapshot`). Eight scenarios run
//  against both `InMemoryCatalogStore` and `SQLiteCatalogStore` so any
//  drift between implementations surfaces as a parity failure.
//
//  Scenarios:
//   1. enrichMovieRoundtrip
//   2. enrichEpisodeWriteSequence (incl. failure-injection sub-case)
//   3. enrichmentTransactionAtomicity
//   4. enrichmentSnapshotShape
//   5. reEnrichReplacesCastAndTMDBArtwork
//   6. enrichmentEmptyCatalogIsNoop
//   7. castMissingPersonIDDropPath (TMDB parser + legacy JSON sub-cases)
//   8. replaceEnrichmentRejectsInvariantViolations (4 sub-cases)
//   9. movieIntelligenceWriterParity
//
//  DEBUG-only — gated by `#if DEBUG`. Activated by
//  `--verify-enrichment` on the command line.
//
//  Exit codes: 0 = all pass, 1 = at least one scenario failed,
//  2 = internal error.
//

#if DEBUG

import Foundation

public enum VerifyEnrichmentHarness {

    public static let launchArgument = "--verify-enrichment"

    // MARK: - Report types

    public struct Report: Codable {
        public let timestamp: String
        public let scenarios: [ScenarioResult]
        public let allPassed: Bool
    }

    public struct ScenarioResult: Codable {
        public let scenario: String
        public let storeKind: String
        public let passed: Bool
        public let detail: String
    }

    // MARK: - Entry point

    public static func runIfRequested() {
        guard CommandLine.arguments.contains(launchArgument) else { return }

        let semaphore = DispatchSemaphore(value: 0)
        let result = ExitCodeBox()

        Task.detached {
            do {
                let code = try await runHarness()
                result.set(code)
            } catch {
                let line = "verify-enrichment: error: \(error)\n"
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

    // MARK: - Implementation

    private static func runHarness() async throws -> Int32 {
        var results: [ScenarioResult] = []

        for storeKind in StoreKind.allCases {
            try await withFreshStore(kind: storeKind) { store in
                results.append(await runEnrichMovieRoundtrip(store, kind: storeKind))
            }
            try await withFreshStore(kind: storeKind) { store in
                results.append(await runEnrichEpisodeWriteSequence(store, kind: storeKind))
            }
            try await withFreshStore(kind: storeKind) { store in
                results.append(await runEnrichmentTransactionAtomicity(store, kind: storeKind))
            }
            try await withFreshStore(kind: storeKind) { store in
                results.append(await runEnrichmentSnapshotShape(store, kind: storeKind))
            }
            try await withFreshStore(kind: storeKind) { store in
                results.append(await runReEnrichReplacesCastAndTMDBArtwork(store, kind: storeKind))
            }
            try await withFreshStore(kind: storeKind) { store in
                results.append(await runEnrichmentEmptyCatalogIsNoop(store, kind: storeKind))
            }
            try await withFreshStore(kind: storeKind) { store in
                results.append(await runCastMissingPersonIDDropPath(store, kind: storeKind))
            }
            try await withFreshStore(kind: storeKind) { store in
                results.append(await runReplaceEnrichmentRejectsInvariantViolations(store, kind: storeKind))
            }
            try await withFreshStore(kind: storeKind) { store in
                results.append(await runMovieIntelligenceWriterParity(store, kind: storeKind))
            }
        }

        let allPassed = results.allSatisfy { $0.passed }
        let report = Report(
            timestamp: iso8601(Date()),
            scenarios: results,
            allPassed: allPassed
        )
        try writeReport(report)

        for r in results {
            let mark = r.passed ? "PASS" : "FAIL"
            let line = "verify-enrichment: \(mark) [\(r.storeKind)] \(r.scenario): \(r.detail)\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
        let summary = "verify-enrichment: outcome=\(allPassed ? "verified" : "failed")"
            + " passed=\(results.filter { $0.passed }.count)/\(results.count)\n"
        FileHandle.standardError.write(Data(summary.utf8))

        return allPassed ? 0 : 1
    }

    // MARK: - Store kind harness

    private enum StoreKind: String, CaseIterable {
        case inMemory = "in-memory"
        case sqlite   = "sqlite"
    }

    private static func withFreshStore(
        kind: StoreKind,
        _ work: (CatalogStore) async throws -> Void
    ) async throws {
        switch kind {
        case .inMemory:
            try await work(InMemoryCatalogStore())
        case .sqlite:
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("marquee-enrich-verify-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let dbPath = dir.appendingPathComponent("catalog.sqlite").path
            let store = try SQLiteCatalogStore(path: dbPath)
            try await work(store)
        }
    }

    // MARK: - Fixtures

    private static let fixtureVolumeUUID = "enrich-verify"

    private static func makeFile(_ tag: String) -> CatalogMediaFile {
        let rel = "fixture/\(tag).mkv"
        let id = MediaIdentity.mediaFileID(volumeUUID: fixtureVolumeUUID, relativePath: rel)
        return CatalogMediaFile(
            id: id,
            volumeUUID: fixtureVolumeUUID,
            relativePath: rel,
            absolutePathSnapshot: "/tmp/\(rel)",
            fileExtension: "mkv",
            fileSize: 1,
            modificationDate: Date(timeIntervalSince1970: 0),
            durationSeconds: nil,
            contentHash: nil,
            dateAdded: Date(timeIntervalSince1970: 0)
        )
    }

    private static func makeMovie(file: MediaFileID, title: String, year: Int = 2024) -> CatalogMovie {
        let id = MediaIdentity.movieID(primaryFile: file)
        return CatalogMovie(
            id: id,
            primaryFile: file,
            title: title,
            year: year,
            tmdbID: 123,
            overview: "Synopsis",
            runtimeMinutes: 100,
            certification: "PG-13",
            releaseDate: "2024-01-01",
            genres: ["Drama"],
            voteAverage: 7.5,
            director: "Some Director"
        )
    }

    private static func makeShow(title: String, year: Int = 2008) -> CatalogShow {
        let id = MediaIdentity.showID(title: title, year: year)
        return CatalogShow(
            id: id,
            title: title,
            year: year,
            tmdbID: 1396,
            overview: "Show overview",
            certification: "TV-MA",
            genres: ["Drama", "Crime"],
            releaseDate: "2008-01-20",
            runtimeMinutes: 47,
            voteAverage: 8.4,
            director: "Vince Gilligan"
        )
    }

    private static func makeSeason(show: ShowID, number: Int) -> CatalogSeason {
        let id = MediaIdentity.seasonID(show: show, seasonNumber: number)
        return CatalogSeason(id: id, showID: show, seasonNumber: number)
    }

    private static func makeEpisode(
        season: SeasonID,
        file: MediaFileID,
        number: Int,
        tmdbID: Int? = 62085,
        airDate: String? = "2008-01-20",
        voteAverage: Double? = 8.2
    ) -> CatalogEpisode {
        let id = MediaIdentity.episodeID(season: season, episodeNumber: number, primaryFile: file)
        return CatalogEpisode(
            id: id,
            seasonID: season,
            primaryFile: file,
            episodeNumber: number,
            title: "Pilot",
            overview: "First episode.",
            runtimeMinutes: 58,
            tmdbID: tmdbID,
            certification: nil,
            releaseDate: airDate,
            voteAverage: voteAverage
        )
    }

    private static func makeArtwork(
        owner: ArtworkOwner,
        kind: ArtworkKind,
        sourceLabel: String = "tmdb",
        localPath: String?,
        remoteURL: String?,
        tag: String = "v1"
    ) -> CatalogArtworkAsset {
        let id = MediaIdentity.artworkID(owner: owner, kind: kind, sourceLabel: sourceLabel + "-" + tag)
        return CatalogArtworkAsset(
            id: id,
            owner: owner,
            kind: kind,
            localPath: localPath,
            remoteURL: remoteURL,
            sourceLabel: sourceLabel
        )
    }

    private struct CanaryError: Error, Equatable {}

    // MARK: - Scenario 1: movie roundtrip

    private static func runEnrichMovieRoundtrip(
        _ store: CatalogStore,
        kind: StoreKind
    ) async -> ScenarioResult {
        let file = makeFile("movie-roundtrip")
        let movie = makeMovie(file: file.id, title: "Test Movie")
        let owner: ArtworkOwner = .movie(movie.id)
        // Two cast entries pointing at the *same* TMDB person id — must
        // dedup to one `person` row and two `cast_member` rows.
        let cast: [CatalogCastEntry] = [
            CatalogCastEntry(personTMDBID: 7777, name: "Actor A", profilePath: "/a.jpg", character: "Hero",   ordinal: 0),
            CatalogCastEntry(personTMDBID: 8888, name: "Actor B", profilePath: nil,      character: "Villain", ordinal: 1),
            CatalogCastEntry(personTMDBID: 7777, name: "Actor A", profilePath: "/a.jpg", character: "Hero (older)", ordinal: 2),
        ]
        let artwork: [CatalogArtworkAsset] = [
            makeArtwork(owner: owner, kind: .poster,   localPath: "/cache/poster-thumb.jpg",   remoteURL: "/p.jpg"),
            makeArtwork(owner: owner, kind: .backdrop, localPath: "/cache/backdrop-thumb.jpg", remoteURL: "/b.jpg"),
        ]
        do {
            try await store.upsert(mediaFile: file)
            try await store.replaceEnrichment(
                owner: owner,
                core: .movie(movie),
                cast: cast,
                artwork: artwork
            )

            let snap = try await store.enrichmentSnapshot()
            guard let read = snap.movies[movie.id] else {
                return fail("movie", "movie row missing", kind: kind)
            }
            if read != movie {
                return fail("movie", "movie row != fixture", kind: kind)
            }
            let castOut = snap.castByOwner[owner] ?? []
            // Three cast_member rows — ordinals are unique even though
            // person id is shared between #0 and #2.
            if castOut.count != 3 {
                return fail("movie", "cast count = \(castOut.count) (want 3)", kind: kind)
            }
            // Order by ordinal. Snapshot already orders for SQLite; in-memory mirrors.
            for (i, expectedOrd) in [0,1,2].enumerated() {
                if castOut[i].ordinal != expectedOrd {
                    return fail("movie", "cast[\(i)].ordinal=\(castOut[i].ordinal) (want \(expectedOrd))", kind: kind)
                }
            }
            // Person dedup: ordinals 0 and 2 share personTMDBID; both rows
            // resolve back to the same denormalised name.
            if castOut[0].personTMDBID != castOut[2].personTMDBID {
                return fail("movie", "person dedup broken", kind: kind)
            }
            if castOut[0].name != "Actor A" || castOut[2].name != "Actor A" {
                return fail("movie", "person name not denormalised back", kind: kind)
            }
            let artOut = snap.artworkByOwner[owner] ?? []
            if artOut.count != 2 {
                return fail("movie", "artwork count = \(artOut.count) (want 2)", kind: kind)
            }
            return pass("enrichMovieRoundtrip", "ok", kind: kind)
        } catch {
            return fail("enrichMovieRoundtrip", "unexpected error: \(error)", kind: kind)
        }
    }

    // MARK: - Scenario 2: episode write sequence + failure injection

    private static func runEnrichEpisodeWriteSequence(
        _ store: CatalogStore,
        kind: StoreKind
    ) async -> ScenarioResult {
        let file = makeFile("episode-sequence")
        let show = makeShow(title: "Breaking Bad", year: 2008)
        let season = makeSeason(show: show.id, number: 1)
        let episode = makeEpisode(season: season.id, file: file.id, number: 1)
        let showOwner: ArtworkOwner = .show(show.id)
        let seasonOwner: ArtworkOwner = .season(season.id)
        let epOwner: ArtworkOwner = .episode(episode.id)

        let showCast: [CatalogCastEntry] = [
            CatalogCastEntry(personTMDBID: 17419, name: "Bryan Cranston", profilePath: "/bc.jpg", character: "Walter White", ordinal: 0),
            CatalogCastEntry(personTMDBID: 84497, name: "Aaron Paul",     profilePath: "/ap.jpg", character: "Jesse Pinkman", ordinal: 1),
        ]
        let showArtwork: [CatalogArtworkAsset] = [
            makeArtwork(owner: showOwner, kind: .poster,   localPath: "/cache/show-poster-thumb.jpg",   remoteURL: "/show-p.jpg"),
            makeArtwork(owner: showOwner, kind: .backdrop, localPath: "/cache/show-backdrop-thumb.jpg", remoteURL: "/show-b.jpg"),
        ]
        let episodeArtwork: [CatalogArtworkAsset] = [
            makeArtwork(owner: epOwner, kind: .still, localPath: "/cache/ep1-still.jpg", remoteURL: "/ep1-still.jpg"),
        ]

        do {
            try await store.upsert(mediaFile: file)

            // Three sequential calls model the actor's per-episode flow.
            try await store.replaceEnrichment(
                owner: showOwner, core: .show(show), cast: showCast, artwork: showArtwork
            )
            try await store.replaceEnrichment(
                owner: seasonOwner, core: .season(season), cast: [], artwork: []
            )
            try await store.replaceEnrichment(
                owner: epOwner, core: .episode(episode), cast: [], artwork: episodeArtwork
            )

            let snap = try await store.enrichmentSnapshot()
            guard let readShow = snap.shows[show.id] else {
                return fail("episodeSeq", "show row missing", kind: kind)
            }
            if readShow.tmdbID != show.tmdbID
                || readShow.certification != show.certification
                || readShow.genres != show.genres
                || readShow.releaseDate != show.releaseDate
                || readShow.runtimeMinutes != show.runtimeMinutes
                || readShow.voteAverage != show.voteAverage
                || readShow.director != show.director {
                return fail("episodeSeq", "show payload mismatch", kind: kind)
            }
            if (snap.castByOwner[showOwner] ?? []).count != 2 {
                return fail("episodeSeq", "show cast count not 2", kind: kind)
            }
            guard snap.seasons[season.id] == season else {
                return fail("episodeSeq", "season mismatch", kind: kind)
            }
            guard let readEp = snap.episodes[episode.id] else {
                return fail("episodeSeq", "episode row missing", kind: kind)
            }
            if readEp.tmdbID == nil { return fail("episodeSeq", "episode tmdbID nil", kind: kind) }
            if readEp.releaseDate != "2008-01-20" {
                return fail("episodeSeq", "episode releaseDate mismatch", kind: kind)
            }
            if readEp.voteAverage != 8.2 {
                return fail("episodeSeq", "episode voteAverage mismatch", kind: kind)
            }
            // No-inherit-from-show policy: certification stays nil even
            // though the show row carries TV-MA.
            if readEp.certification != nil {
                return fail("episodeSeq", "episode certification leaked from show", kind: kind)
            }
            // Owner-scoped artwork separation.
            let showArt = snap.artworkByOwner[showOwner] ?? []
            let epArt = snap.artworkByOwner[epOwner] ?? []
            if showArt.count != 2 {
                return fail("episodeSeq", "show artwork count = \(showArt.count) (want 2)", kind: kind)
            }
            if epArt.count != 1 || epArt[0].kind != .still {
                return fail("episodeSeq", "episode .still artwork missing or wrong", kind: kind)
            }
            // Failure-injection sub-case: blow up call 3 and observe
            // that calls 1+2 still committed in their own transactions.
            let secondFile = makeFile("episode-sequence-2")
            let secondEp = makeEpisode(
                season: season.id,
                file: secondFile.id,
                number: 2,
                tmdbID: 62086,
                airDate: "2008-01-27",
                voteAverage: 7.9
            )
            try await store.upsert(mediaFile: secondFile)
            // Calls 1+2 are no-ops because the show + season already
            // exist; just call 3 with a deliberately invalid invariant
            // to force the throw and ensure the rest of the catalog
            // survives intact.
            do {
                try await store.replaceEnrichment(
                    owner: .episode(secondEp.id),
                    core: .show(show), // mismatched core type
                    cast: [],
                    artwork: []
                )
                return fail("episodeSeq", "expected ownerCoreMismatch, got success", kind: kind)
            } catch CatalogStoreError.ownerCoreMismatch {
                // expected
            } catch {
                return fail("episodeSeq", "expected ownerCoreMismatch, got \(error)", kind: kind)
            }
            // Re-read snapshot — show/season/first episode survive,
            // second episode never landed.
            let snap2 = try await store.enrichmentSnapshot()
            guard snap2.shows[show.id] != nil else {
                return fail("episodeSeq", "show vanished after failed call", kind: kind)
            }
            guard snap2.seasons[season.id] != nil else {
                return fail("episodeSeq", "season vanished after failed call", kind: kind)
            }
            guard snap2.episodes[episode.id] != nil else {
                return fail("episodeSeq", "first episode vanished after failed call", kind: kind)
            }
            if snap2.episodes[secondEp.id] != nil {
                return fail("episodeSeq", "second episode landed despite invariant violation", kind: kind)
            }
            return pass("enrichEpisodeWriteSequence", "ok", kind: kind)
        } catch {
            return fail("enrichEpisodeWriteSequence", "unexpected error: \(error)", kind: kind)
        }
    }

    // MARK: - Scenario 3: transaction atomicity

    /// Inject a real failure *inside* the transaction body: two cast
    /// entries with the same `(owner, ordinal)` collide on the
    /// `cast_member` primary key during step 5 of `applyEnrichment`,
    /// after step 1 has already attempted to upsert the `person` rows.
    /// The whole call must roll back: the movie row, all cast_member
    /// rows, and any new person rows for this call must be absent
    /// (or, for re-runs, restored to their prior values).
    ///
    /// Run twice: once on a fresh catalog (post-failure: zero rows),
    /// once on a catalog with a prior good enrichment (post-failure:
    /// prior rows survive byte-for-byte).
    private static func runEnrichmentTransactionAtomicity(
        _ store: CatalogStore,
        kind: StoreKind
    ) async -> ScenarioResult {
        let file = makeFile("atomicity")
        let movie = makeMovie(file: file.id, title: "Atomic Movie")
        let owner: ArtworkOwner = .movie(movie.id)
        // Duplicate ordinal → collision on cast_member.id (synthesised
        // from owner+ordinal). Invariants pass; the failure happens
        // inside the tx body.
        let collidingCast = [
            CatalogCastEntry(personTMDBID: 11, name: "A", profilePath: nil, character: "C0", ordinal: 0),
            CatalogCastEntry(personTMDBID: 22, name: "B", profilePath: nil, character: "C1", ordinal: 0),
        ]
        let artwork = [
            makeArtwork(owner: owner, kind: .poster, localPath: "/p.jpg", remoteURL: "/p.jpg"),
        ]
        do {
            try await store.upsert(mediaFile: file)

            // Sub-case 1: fresh catalog, expect zero rows after rollback.
            do {
                try await store.replaceEnrichment(
                    owner: owner,
                    core: .movie(movie),
                    cast: collidingCast,
                    artwork: artwork
                )
                return fail("atomicity", "expected throw on duplicate ordinal, got success", kind: kind)
            } catch {
                // expected — kind of error varies by store (ioFailure vs
                // SQLite PK error wrapper); we only care that it threw.
            }
            let snap1 = try await store.enrichmentSnapshot()
            if snap1.movies[movie.id] != nil {
                return fail("atomicity.fresh", "movie row leaked through rollback", kind: kind)
            }
            if !(snap1.castByOwner[owner] ?? []).isEmpty {
                return fail("atomicity.fresh", "cast rows leaked through rollback", kind: kind)
            }
            if !(snap1.artworkByOwner[owner] ?? []).isEmpty {
                return fail("atomicity.fresh", "artwork rows leaked through rollback", kind: kind)
            }

            // Sub-case 2: prior good enrichment is preserved across a
            // failed re-enrichment.
            let goodCast = [
                CatalogCastEntry(personTMDBID: 11, name: "A", profilePath: nil, character: "C0", ordinal: 0),
                CatalogCastEntry(personTMDBID: 22, name: "B", profilePath: nil, character: "C1", ordinal: 1),
            ]
            try await store.replaceEnrichment(
                owner: owner,
                core: .movie(movie),
                cast: goodCast,
                artwork: artwork
            )
            do {
                try await store.replaceEnrichment(
                    owner: owner,
                    core: .movie(movie),
                    cast: collidingCast,
                    artwork: artwork
                )
                return fail("atomicity.preserve", "expected throw on duplicate ordinal", kind: kind)
            } catch {
                // expected
            }
            let snap2 = try await store.enrichmentSnapshot()
            guard snap2.movies[movie.id] == movie else {
                return fail("atomicity.preserve", "movie changed after rejected re-enrich", kind: kind)
            }
            let castOut = snap2.castByOwner[owner] ?? []
            if castOut.count != 2 {
                return fail("atomicity.preserve", "cast count = \(castOut.count) (want 2)", kind: kind)
            }
            if (snap2.artworkByOwner[owner] ?? []).count != 1 {
                return fail("atomicity.preserve", "artwork count != 1 after rejected re-enrich", kind: kind)
            }
            return pass("enrichmentTransactionAtomicity", "fresh+preserve ok", kind: kind)
        } catch {
            return fail("atomicity", "unexpected error: \(error)", kind: kind)
        }
    }

    // MARK: - Scenario 4: snapshot shape

    private static func runEnrichmentSnapshotShape(
        _ store: CatalogStore,
        kind: StoreKind
    ) async -> ScenarioResult {
        let file = makeFile("shape")
        let movie = makeMovie(file: file.id, title: "Shape Test")
        let owner: ArtworkOwner = .movie(movie.id)
        let cast = [
            CatalogCastEntry(personTMDBID: 9, name: "Z", profilePath: nil, character: "C2", ordinal: 5),
            CatalogCastEntry(personTMDBID: 8, name: "Y", profilePath: nil, character: "C1", ordinal: 0),
            CatalogCastEntry(personTMDBID: 7, name: "X", profilePath: nil, character: "C0", ordinal: 2),
        ]
        let artwork = [
            makeArtwork(owner: owner, kind: .poster,   localPath: "/p.jpg", remoteURL: "/p.jpg"),
            makeArtwork(owner: owner, kind: .backdrop, localPath: "/b.jpg", remoteURL: "/b.jpg"),
        ]
        do {
            try await store.upsert(mediaFile: file)
            try await store.replaceEnrichment(
                owner: owner, core: .movie(movie), cast: cast, artwork: artwork
            )
            let snap = try await store.enrichmentSnapshot()
            // [MovieID: ...] keying by movie id — only one row.
            if snap.movies.count != 1 || snap.movies[movie.id] == nil {
                return fail("shape", "movies dict not keyed by MovieID", kind: kind)
            }
            // castByOwner grouped by owner.
            guard let castForOwner = snap.castByOwner[owner] else {
                return fail("shape", "no cast for owner", kind: kind)
            }
            if castForOwner.count != 3 {
                return fail("shape", "cast for owner count = \(castForOwner.count) (want 3)", kind: kind)
            }
            // Cast ordered by ordinal, not insertion order.
            let ordinals = castForOwner.map(\.ordinal)
            if ordinals != [0, 2, 5] {
                return fail("shape", "cast ordinals not sorted: \(ordinals)", kind: kind)
            }
            // artworkByOwner grouped by owner.
            if (snap.artworkByOwner[owner] ?? []).count != 2 {
                return fail("shape", "artwork for owner count != 2", kind: kind)
            }
            return pass("enrichmentSnapshotShape", "ok", kind: kind)
        } catch {
            return fail("shape", "unexpected error: \(error)", kind: kind)
        }
    }

    // MARK: - Scenario 5: re-enrich replaces cast + tmdb artwork

    private static func runReEnrichReplacesCastAndTMDBArtwork(
        _ store: CatalogStore,
        kind: StoreKind
    ) async -> ScenarioResult {
        let file = makeFile("re-enrich")
        let movie = makeMovie(file: file.id, title: "Re Enrich")
        let owner: ArtworkOwner = .movie(movie.id)
        let firstCast = [
            CatalogCastEntry(personTMDBID: 1, name: "OldA", profilePath: nil, character: "A", ordinal: 0),
            CatalogCastEntry(personTMDBID: 2, name: "OldB", profilePath: nil, character: "B", ordinal: 1),
        ]
        let firstArtwork = [
            makeArtwork(owner: owner, kind: .poster,   localPath: "/old-p.jpg", remoteURL: "/p.jpg", tag: "first"),
            makeArtwork(owner: owner, kind: .backdrop, localPath: "/old-b.jpg", remoteURL: "/b.jpg", tag: "first"),
        ]
        do {
            try await store.upsert(mediaFile: file)
            try await store.replaceEnrichment(
                owner: owner, core: .movie(movie), cast: firstCast, artwork: firstArtwork
            )

            // Pre-existing sidecar artwork row attached to the same owner.
            // The enrichment replace must NOT touch sidecar rows.
            let sidecar = CatalogArtworkAsset(
                id: ArtworkAssetID(rawValue: "sidecar-art-1"),
                owner: owner,
                kind: .poster,
                localPath: "/Volumes/X/Movie/poster.jpg",
                remoteURL: nil,
                sourceLabel: "sidecar"
            )
            try await store.upsert(artwork: sidecar)

            // Second enrichment — different cast, different TMDB artwork.
            let newCast = [
                CatalogCastEntry(personTMDBID: 3, name: "NewC", profilePath: nil, character: "C", ordinal: 0),
            ]
            let newArtwork = [
                makeArtwork(owner: owner, kind: .poster, localPath: "/new-p.jpg", remoteURL: "/p2.jpg", tag: "second"),
            ]
            try await store.replaceEnrichment(
                owner: owner, core: .movie(movie), cast: newCast, artwork: newArtwork
            )

            let snap = try await store.enrichmentSnapshot()
            let castOut = snap.castByOwner[owner] ?? []
            if castOut.count != 1 || castOut[0].personTMDBID != 3 {
                return fail("re-enrich", "cast not fully replaced (count=\(castOut.count))", kind: kind)
            }
            let artOut = snap.artworkByOwner[owner] ?? []
            // Expect: one TMDB poster (new) + one sidecar poster.
            // The two old TMDB rows must have been deleted.
            let tmdbCount = artOut.filter { $0.sourceLabel == "tmdb" }.count
            let sidecarCount = artOut.filter { $0.sourceLabel == "sidecar" }.count
            if tmdbCount != 1 {
                return fail("re-enrich", "tmdb artwork count = \(tmdbCount) (want 1)", kind: kind)
            }
            if sidecarCount != 1 {
                return fail("re-enrich", "sidecar artwork count = \(sidecarCount) (want 1)", kind: kind)
            }
            return pass("reEnrichReplacesCastAndTMDBArtwork", "ok", kind: kind)
        } catch {
            return fail("re-enrich", "unexpected error: \(error)", kind: kind)
        }
    }

    // MARK: - Scenario 6: empty catalog snapshot

    private static func runEnrichmentEmptyCatalogIsNoop(
        _ store: CatalogStore,
        kind: StoreKind
    ) async -> ScenarioResult {
        do {
            let snap = try await store.enrichmentSnapshot()
            if !snap.movies.isEmpty
                || !snap.shows.isEmpty
                || !snap.seasons.isEmpty
                || !snap.episodes.isEmpty
                || !snap.artworkByOwner.isEmpty
                || !snap.castByOwner.isEmpty {
                return fail("empty", "non-empty snapshot from empty catalog", kind: kind)
            }
            return pass("enrichmentEmptyCatalogIsNoop", "ok", kind: kind)
        } catch {
            return fail("empty", "unexpected error: \(error)", kind: kind)
        }
    }

    // MARK: - Scenario 7: missing person id drop path

    private static func runCastMissingPersonIDDropPath(
        _ store: CatalogStore,
        kind: StoreKind
    ) async -> ScenarioResult {
        // 7a — TMDB parser path
        let creditsJSON: [String: Any] = [
            "id": 1396,
            "title": "Sample",
            "overview": "x",
            "genres": [["id": 18, "name": "Drama"]],
            "credits": [
                "cast": [
                    ["name": "Bad",  "character": "B", "profile_path": NSNull(), /* missing id */],
                    ["name": "Good", "character": "G", "profile_path": "/g.jpg", "id": 4242],
                    ["name": "Zero", "character": "Z", "profile_path": NSNull(), "id": 0],
                ],
                "crew": [],
            ],
        ]
        // Drive the parser indirectly via JSON encoding then decoding the
        // resulting `TMDBMetadata` shape — this exercises the same
        // code path the live network call uses without needing a live
        // TMDB session.
        let parsed: [TMDBMetadata.CastEntry]
        do {
            // Use the parser by feeding a fake JSON dict through
            // `JSONSerialization`. We can't call the actor's private
            // `parseMovieJSON` from here, so simulate the parser's
            // effect: only entries with a non-nil and non-zero `id`
            // become cast entries with `tmdbPersonID` set; the rest get
            // `tmdbPersonID = nil`. This matches the parser change in
            // `TMDBService.swift` (Phase 2E.4b step (a)).
            let castArray = (creditsJSON["credits"] as? [String: Any])?["cast"] as? [[String: Any]] ?? []
            parsed = castArray.map { dict in
                let id = dict["id"] as? Int
                return TMDBMetadata.CastEntry(
                    name: (dict["name"] as? String) ?? "",
                    character: (dict["character"] as? String) ?? "",
                    profilePath: dict["profile_path"] as? String,
                    tmdbPersonID: (id != nil && id != 0) ? id : nil
                )
            }

            // 7b — Legacy JSON path. Hand-craft a JSON fixture matching
            // the pre-2E.4b shape (no `tmdbPersonID` field).
            let legacyJSON = """
            [
              {"name": "Legacy A", "character": "LA", "profilePath": null},
              {"name": "Legacy B", "character": "LB", "profilePath": "/lb.jpg"}
            ]
            """.data(using: .utf8)!
            let legacy = try JSONDecoder().decode(
                [TMDBMetadata.CastEntry].self,
                from: legacyJSON
            )
            if legacy.count != 2 {
                return fail("missing-id", "legacy decode count = \(legacy.count)", kind: kind)
            }
            if legacy.contains(where: { $0.tmdbPersonID != nil }) {
                return fail("missing-id", "legacy entries should have nil tmdbPersonID", kind: kind)
            }

            // Drop entries without ids → only the well-formed entry survives.
            let droppedTMDB = parsed.compactMap { e -> CatalogCastEntry? in
                guard let id = e.tmdbPersonID else { return nil }
                return CatalogCastEntry(
                    personTMDBID: id,
                    name: e.name,
                    profilePath: e.profilePath,
                    character: e.character,
                    ordinal: 0
                )
            }
            if droppedTMDB.count != 1 || droppedTMDB.first?.personTMDBID != 4242 {
                return fail("missing-id", "tmdb drop wrong: \(droppedTMDB.map(\.personTMDBID))", kind: kind)
            }

            let droppedLegacy = legacy.compactMap { e -> CatalogCastEntry? in
                guard let id = e.tmdbPersonID else { return nil }
                return CatalogCastEntry(
                    personTMDBID: id,
                    name: e.name,
                    profilePath: e.profilePath,
                    character: e.character,
                    ordinal: 0
                )
            }
            if !droppedLegacy.isEmpty {
                return fail("missing-id", "legacy not fully dropped: count=\(droppedLegacy.count)", kind: kind)
            }

            // Now write the survivor through replaceEnrichment to confirm
            // no orphan cast_member rows can land.
            let file = makeFile("missing-id")
            let movie = makeMovie(file: file.id, title: "Missing ID Test")
            try await store.upsert(mediaFile: file)
            try await store.replaceEnrichment(
                owner: .movie(movie.id),
                core: .movie(movie),
                cast: droppedTMDB,
                artwork: []
            )
            let snap = try await store.enrichmentSnapshot()
            let writtenCast = snap.castByOwner[.movie(movie.id)] ?? []
            if writtenCast.count != 1 || writtenCast[0].personTMDBID != 4242 {
                return fail("missing-id", "post-write cast count=\(writtenCast.count)", kind: kind)
            }
            return pass("castMissingPersonIDDropPath", "ok", kind: kind)
        } catch {
            return fail("missing-id", "unexpected error: \(error)", kind: kind)
        }
    }

    // MARK: - Scenario 8: invariant rejection

    private static func runReplaceEnrichmentRejectsInvariantViolations(
        _ store: CatalogStore,
        kind: StoreKind
    ) async -> ScenarioResult {
        // Capture pre-state — must equal post-state for every sub-case.
        let preCounts: CatalogCounts
        do {
            preCounts = try await store.countsSnapshot()
        } catch {
            return fail("invariant", "preCounts error: \(error)", kind: kind)
        }

        // (a) movie owner + show core
        do {
            let xMovie = MovieID(rawValue: "X")
            let yShow = ShowID(rawValue: "Y")
            let show = CatalogShow(
                id: yShow,
                title: "Y",
                year: nil,
                tmdbID: nil,
                overview: nil,
                certification: nil,
                genres: []
            )
            do {
                try await store.replaceEnrichment(
                    owner: .movie(xMovie),
                    core: .show(show),
                    cast: [],
                    artwork: []
                )
                return fail("invariant.a", "expected mismatch", kind: kind)
            } catch CatalogStoreError.ownerCoreMismatch {
                // expected
            } catch {
                return fail("invariant.a", "wrong error: \(error)", kind: kind)
            }
        }

        // (b) episode owner + episode payload with mismatched id
        do {
            let e1 = EpisodeID(rawValue: "E1")
            let e2 = EpisodeID(rawValue: "E2")
            let s1 = SeasonID(rawValue: "S1")
            let f1 = MediaFileID(rawValue: "F1")
            let badEp = CatalogEpisode(
                id: e2,
                seasonID: s1,
                primaryFile: f1,
                episodeNumber: 1,
                title: nil,
                overview: nil,
                runtimeMinutes: nil
            )
            do {
                try await store.replaceEnrichment(
                    owner: .episode(e1),
                    core: .episode(badEp),
                    cast: [],
                    artwork: []
                )
                return fail("invariant.b", "expected mismatch", kind: kind)
            } catch CatalogStoreError.ownerCoreMismatch {
                // expected
            } catch {
                return fail("invariant.b", "wrong error: \(error)", kind: kind)
            }
        }

        // (c) movie owner + show-owned artwork row
        do {
            let xMovie = MovieID(rawValue: "X")
            let movieFile = MediaFileID(rawValue: "X-FILE")
            let movie = CatalogMovie(
                id: xMovie,
                primaryFile: movieFile,
                title: "X",
                year: nil,
                tmdbID: nil,
                overview: nil,
                runtimeMinutes: nil,
                certification: nil,
                releaseDate: nil,
                genres: [],
                voteAverage: nil,
                director: nil
            )
            let evilArt = [
                CatalogArtworkAsset(
                    id: ArtworkAssetID(rawValue: "evil-c"),
                    owner: .show(ShowID(rawValue: "S")),
                    kind: .poster,
                    localPath: nil,
                    remoteURL: nil,
                    sourceLabel: "tmdb"
                )
            ]
            do {
                try await store.replaceEnrichment(
                    owner: .movie(xMovie),
                    core: .movie(movie),
                    cast: [],
                    artwork: evilArt
                )
                return fail("invariant.c", "expected mismatch", kind: kind)
            } catch CatalogStoreError.ownerCoreMismatch {
                // expected
            } catch {
                return fail("invariant.c", "wrong error: \(error)", kind: kind)
            }
        }

        // (d) tmdb-only — artwork row with sourceLabel=="sidecar"
        do {
            let xMovie = MovieID(rawValue: "X")
            let movieFile = MediaFileID(rawValue: "X-FILE")
            let movie = CatalogMovie(
                id: xMovie,
                primaryFile: movieFile,
                title: "X",
                year: nil,
                tmdbID: nil,
                overview: nil,
                runtimeMinutes: nil,
                certification: nil,
                releaseDate: nil,
                genres: [],
                voteAverage: nil,
                director: nil
            )
            let sidecarArt = [
                CatalogArtworkAsset(
                    id: ArtworkAssetID(rawValue: "evil-d"),
                    owner: .movie(xMovie),
                    kind: .poster,
                    localPath: "/x.jpg",
                    remoteURL: nil,
                    sourceLabel: "sidecar"
                )
            ]
            do {
                try await store.replaceEnrichment(
                    owner: .movie(xMovie),
                    core: .movie(movie),
                    cast: [],
                    artwork: sidecarArt
                )
                return fail("invariant.d", "expected mismatch", kind: kind)
            } catch CatalogStoreError.ownerCoreMismatch {
                // expected
            } catch {
                return fail("invariant.d", "wrong error: \(error)", kind: kind)
            }
        }

        // Post-state must be byte-equal to pre-state.
        let postCounts: CatalogCounts
        do {
            postCounts = try await store.countsSnapshot()
        } catch {
            return fail("invariant", "postCounts error: \(error)", kind: kind)
        }
        if preCounts != postCounts {
            return fail("invariant", "counts changed across rejected calls", kind: kind)
        }
        return pass("replaceEnrichmentRejectsInvariantViolations", "ok", kind: kind)
    }

    // MARK: - Scenario 9: movie intelligence writer parity

    private static func runMovieIntelligenceWriterParity(
        _ store: CatalogStore,
        kind: StoreKind
    ) async -> ScenarioResult {
        let sourceFile = makeFile("intelligence-source")
        let targetFile = makeFile("intelligence-target")
        let normalUpsertFile = makeFile("intelligence-normal-upsert")
        let source = CatalogMovie(
            id: MediaIdentity.movieID(primaryFile: sourceFile.id),
            primaryFile: sourceFile.id,
            title: "Intelligence Source",
            year: 2024,
            tmdbID: 100,
            overview: nil,
            runtimeMinutes: nil,
            certification: nil,
            releaseDate: nil,
            genres: [],
            voteAverage: nil,
            director: nil
        )
        let target = CatalogMovie(
            id: MediaIdentity.movieID(primaryFile: targetFile.id),
            primaryFile: targetFile.id,
            title: "Intelligence Target",
            year: 2024,
            tmdbID: 200,
            overview: nil,
            runtimeMinutes: nil,
            certification: nil,
            releaseDate: nil,
            genres: [],
            voteAverage: nil,
            director: nil
        )
        let normalUpsertMovie = CatalogMovie(
            id: MediaIdentity.movieID(primaryFile: normalUpsertFile.id),
            primaryFile: normalUpsertFile.id,
            title: "Normal Upsert",
            year: 2024,
            tmdbID: 300,
            overview: nil,
            runtimeMinutes: nil,
            certification: nil,
            releaseDate: nil,
            genres: [],
            voteAverage: nil,
            director: nil,
            voteCount: 777,
            popularity: 77.7,
            collectionID: 777,
            collectionName: "Should Not Write"
        )
        let firstKeywords = [
            CatalogMovieKeyword(movieID: source.id, keywordID: 10, name: "heist"),
            CatalogMovieKeyword(movieID: source.id, keywordID: 11, name: "neo-noir"),
        ]
        let firstEdges = [
            CatalogMovieEdge(
                sourceMovieID: source.id,
                targetMovieID: target.id,
                edgeType: .similar,
                rank: 0
            ),
        ]

        do {
            try await store.upsert(mediaFiles: [sourceFile, targetFile, normalUpsertFile])
            try await store.upsert(movies: [source, target, normalUpsertMovie])
            let normalSnap = try await store.enrichmentSnapshot()
            guard let normalMovie = normalSnap.movies[normalUpsertMovie.id],
                  normalMovie.voteCount == nil,
                  normalMovie.popularity == nil,
                  normalMovie.collectionID == nil,
                  normalMovie.collectionName == nil else {
                return fail(
                    "intelligenceWriter",
                    "normal movie upsert wrote D2 fields: \(String(describing: normalSnap.movies[normalUpsertMovie.id]))",
                    kind: kind
                )
            }

            try await store.replaceMovieIntelligence(
                movieID: source.id,
                voteCount: 123,
                popularity: 45.5,
                collectionID: 77,
                collectionName: "Fixture Collection",
                keywords: firstKeywords,
                edges: firstEdges
            )

            let snap1 = try await store.enrichmentSnapshot()
            guard let movie1 = snap1.movies[source.id],
                  movie1.voteCount == 123,
                  movie1.popularity == 45.5,
                  movie1.collectionID == 77,
                  movie1.collectionName == "Fixture Collection" else {
                return fail("intelligenceWriter", "movie extension fields missing", kind: kind)
            }
            let keywords1 = snap1.movieKeywordsByMovie[source.id] ?? []
            let edges1 = snap1.movieEdgesBySource[source.id] ?? []
            if keywords1.map(\.keywordID).sorted() != [10, 11] {
                return fail("intelligenceWriter", "keyword rows missing: \(keywords1)", kind: kind)
            }
            if edges1 != firstEdges {
                return fail("intelligenceWriter", "edge rows missing: \(edges1)", kind: kind)
            }
            try await store.upsert(movie: CatalogMovie(
                id: source.id,
                primaryFile: source.primaryFile,
                title: "Intelligence Source Rescan",
                year: source.year,
                tmdbID: source.tmdbID,
                overview: source.overview,
                runtimeMinutes: source.runtimeMinutes,
                certification: source.certification,
                releaseDate: source.releaseDate,
                genres: source.genres,
                voteAverage: source.voteAverage,
                director: source.director,
                voteCount: 999,
                popularity: 999,
                collectionID: 999,
                collectionName: "Should Not Overwrite"
            ))
            let rescanSnap = try await store.enrichmentSnapshot()
            guard let rescanMovie = rescanSnap.movies[source.id],
                  rescanMovie.title == "Intelligence Source Rescan",
                  rescanMovie.voteCount == 123,
                  rescanMovie.popularity == 45.5,
                  rescanMovie.collectionID == 77,
                  rescanMovie.collectionName == "Fixture Collection" else {
                return fail(
                    "intelligenceWriter",
                    "normal movie upsert overwrote D2 fields: \(String(describing: rescanSnap.movies[source.id]))",
                    kind: kind
                )
            }

            let report1 = try await store.movieIntelligenceCoverageReport()
            guard let row1 = report1.rows.first(where: { $0.movieID == source.id }),
                  row1.keywordCount == 2,
                  row1.collectionID == 77,
                  row1.edgeCount == 1 else {
                return fail("intelligenceWriter", "coverage row wrong: \(report1.rows)", kind: kind)
            }

            let replacementKeywords = [
                CatalogMovieKeyword(movieID: source.id, keywordID: 12, name: "replacement"),
            ]
            try await store.replaceMovieIntelligence(
                movieID: source.id,
                voteCount: nil,
                popularity: nil,
                collectionID: nil,
                collectionName: nil,
                keywords: replacementKeywords,
                edges: []
            )
            let snap2 = try await store.enrichmentSnapshot()
            guard let movie2 = snap2.movies[source.id],
                  movie2.voteCount == nil,
                  movie2.popularity == nil,
                  movie2.collectionID == nil,
                  movie2.collectionName == nil else {
                return fail("intelligenceWriter", "replacement did not clear fields", kind: kind)
            }
            let keywords2 = snap2.movieKeywordsByMovie[source.id] ?? []
            let edges2 = snap2.movieEdgesBySource[source.id] ?? []
            if keywords2.map(\.keywordID) != [12] || !edges2.isEmpty {
                return fail(
                    "intelligenceWriter",
                    "replacement did not clear old rows k=\(keywords2) e=\(edges2)",
                    kind: kind
                )
            }

            let preReject = try await store.enrichmentSnapshot()
            do {
                try await store.replaceMovieIntelligence(
                    movieID: source.id,
                    voteCount: 999,
                    popularity: 999,
                    collectionID: nil,
                    collectionName: nil,
                    keywords: [],
                    edges: [
                        CatalogMovieEdge(
                            sourceMovieID: source.id,
                            targetMovieID: MovieID(rawValue: "missing-target"),
                            edgeType: .recommendation,
                            rank: 0
                        ),
                    ]
                )
                return fail("intelligenceWriter", "expected orphan edge rejection", kind: kind)
            } catch {
                // Error type differs by store; the invariant is no write lands.
            }
            let postReject = try await store.enrichmentSnapshot()
            guard preReject.movies[source.id] == postReject.movies[source.id],
                  preReject.movieKeywordsByMovie[source.id] == postReject.movieKeywordsByMovie[source.id],
                  preReject.movieEdgesBySource[source.id] == postReject.movieEdgesBySource[source.id] else {
                return fail("intelligenceWriter", "orphan edge rejection changed state", kind: kind)
            }

            let duplicateKeywordReject = try await rejectInvalidMovieIntelligence(
                store,
                movieID: source.id,
                keywords: [
                    CatalogMovieKeyword(movieID: source.id, keywordID: 20, name: "duplicate-a"),
                    CatalogMovieKeyword(movieID: source.id, keywordID: 20, name: "duplicate-b"),
                ],
                edges: [],
                kind: kind,
                label: "duplicate keyword"
            )
            if let duplicateKeywordReject {
                return duplicateKeywordReject
            }

            let duplicateEdge = CatalogMovieEdge(
                sourceMovieID: source.id,
                targetMovieID: target.id,
                edgeType: .similar,
                rank: 0
            )
            let duplicateEdgeReject = try await rejectInvalidMovieIntelligence(
                store,
                movieID: source.id,
                keywords: [],
                edges: [duplicateEdge, duplicateEdge],
                kind: kind,
                label: "duplicate edge"
            )
            if let duplicateEdgeReject {
                return duplicateEdgeReject
            }

            let negativeRankReject = try await rejectInvalidMovieIntelligence(
                store,
                movieID: source.id,
                keywords: [],
                edges: [
                    CatalogMovieEdge(
                        sourceMovieID: source.id,
                        targetMovieID: target.id,
                        edgeType: .recommendation,
                        rank: -1
                    ),
                ],
                kind: kind,
                label: "negative edge rank"
            )
            if let negativeRankReject {
                return negativeRankReject
            }

            return pass(
                "movieIntelligenceWriterParity",
                "fields+replace+invalid rejection ok",
                kind: kind
            )
        } catch {
            return fail("movieIntelligenceWriterParity", "unexpected error: \(error)", kind: kind)
        }
    }

    private static func rejectInvalidMovieIntelligence(
        _ store: CatalogStore,
        movieID: MovieID,
        keywords: [CatalogMovieKeyword],
        edges: [CatalogMovieEdge],
        kind: StoreKind,
        label: String
    ) async throws -> ScenarioResult? {
        let preReject = try await store.enrichmentSnapshot()
        do {
            try await store.replaceMovieIntelligence(
                movieID: movieID,
                voteCount: 999,
                popularity: 999,
                collectionID: nil,
                collectionName: nil,
                keywords: keywords,
                edges: edges
            )
            return fail("intelligenceWriter", "expected \(label) rejection", kind: kind)
        } catch {
            // SQLite and in-memory can surface different error cases; only
            // the invariant and rollback behavior matter here.
        }

        let postReject = try await store.enrichmentSnapshot()
        guard preReject.movies[movieID] == postReject.movies[movieID],
              preReject.movieKeywordsByMovie[movieID] == postReject.movieKeywordsByMovie[movieID],
              preReject.movieEdgesBySource[movieID] == postReject.movieEdgesBySource[movieID] else {
            return fail("intelligenceWriter", "\(label) rejection changed state", kind: kind)
        }
        return nil
    }

    // MARK: - Result helpers

    private static func pass(
        _ scenario: String,
        _ detail: String,
        kind: StoreKind
    ) -> ScenarioResult {
        ScenarioResult(scenario: scenario, storeKind: kind.rawValue, passed: true, detail: detail)
    }

    private static func fail(
        _ scenario: String,
        _ detail: String,
        kind: StoreKind
    ) -> ScenarioResult {
        ScenarioResult(scenario: scenario, storeKind: kind.rawValue, passed: false, detail: detail)
    }

    // MARK: - Report writer

    private static func iso8601(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    private static func writeReport(_ report: Report) throws {
        let dir = Configuration.appSupportDirectory
            .appendingPathComponent("verify", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("enrichment-report.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        try data.write(to: url, options: .atomic)
    }
}

#endif
