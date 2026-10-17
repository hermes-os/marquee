//
//  VerifyImportHarness.swift
//  Marquee
//
//  Phase 1 verification harness for `LegacyJSONImporter`.
//
//  DEBUG-ONLY. The entire body of this file is gated by `#if DEBUG` so the
//  harness is excluded from Release builds — it must never ship to users.
//  See call site in `MarqueeApp.init()` for the matching guard.
//
//  Activated by the `--verify-legacy-import` launch argument. The harness:
//    1. Decodes the legacy `library-cache-{movies,tv}.json` files.
//    2. Runs `LegacyJSONImporter` into a fresh `InMemoryCatalogStore`.
//    3. Re-runs the importer against the same data to verify idempotency.
//    4. Spot-checks input → catalog round-trip for a sample of entries.
//    5. Writes a JSON report to `build/reports/legacy-import-verify-<iso>.json`.
//    6. Calls `exit(0)` on success, `exit(1)` on a verification failure,
//       `exit(2)` on an internal error.
//
//  The harness is read-only against `~/Library/Application Support/Marquee`.
//  The catalog is in-memory and is dropped at process exit. No SQLite store
//  is opened. Existing app launch flow is unaffected when the launch arg is
//  absent.
//

#if DEBUG

import Foundation

public enum VerifyLegacyImportHarness {

    public static let launchArgument = "--verify-legacy-import"

    // MARK: - Report types

    public struct Report: Codable {
        public let timestamp: String
        public let cacheDirectory: String
        public let inputCounts: InputCounts
        public let firstRunSummary: LegacyJSONImporter.ImportSummary
        public let firstRunCatalogCounts: CatalogCounts
        public let secondRunSummary: LegacyJSONImporter.ImportSummary
        public let secondRunCatalogCounts: CatalogCounts
        public let idempotent: Bool
        public let sampleChecks: [SampleCheck]
        public let dataLossChecks: [String]
        public let setBasedCheck: SetBasedCheck
        public let countsCheck: CountsCheck
        public let readbackChecks: [ReadbackCheck]
        public let outcome: String
        public let success: Bool
    }

    public struct SetBasedCheck: Codable {
        public let expectedDistinctMediaFileIDs: Int
        public let observedMediaFileIDs: Int
        public let missingFromCatalog: Int
        public let unexpectedInCatalog: Int
        public let allExpectedPresent: Bool
    }

    public struct InputCounts: Codable {
        public let moviesEntries: Int
        public let tvEntries: Int
        public let distinctMoviePaths: Int
        public let distinctTVPaths: Int
        public let distinctCombinedPaths: Int
    }

    public struct SampleCheck: Codable {
        public let kind: String
        public let sourcePath: String
        public let resolvedMediaFileID: String
        public let foundInCatalog: Bool
        public let titleEcho: String?
    }

    public struct ExpectedCounts: Codable, Equatable {
        public let mediaFiles: Int
        public let movies: Int
        public let shows: Int
        public let seasons: Int
        public let episodes: Int
        public let artwork: Int
    }

    public struct CountsCheck: Codable {
        public let expected: ExpectedCounts
        public let observed: CatalogCounts
        public let mismatches: [String]
        public let allMatch: Bool
    }

    public struct ReadbackCheck: Codable {
        public let kind: String
        public let entityID: String
        public let assertion: String
        public let passed: Bool
        public let detail: String?
    }

    // MARK: - Entry point

    /// Runs the verify flow if the launch arg is present. Calls `exit()` on
    /// completion in that case. Returns immediately if the arg is absent.
    ///
    /// Implementation note: this is invoked from `MarqueeApp.init()` on the
    /// main thread before SwiftUI scenes are constructed. We bridge to async
    /// work via `Task.detached` and a `DispatchSemaphore` so the main thread
    /// blocks until the harness completes, then `exit()`s. The bridge is
    /// deliberate — it keeps the harness fully synchronous from the launch
    /// perspective and ensures the SwiftUI app never starts. This is
    /// acceptable only because the harness is `#if DEBUG` and is the entire
    /// process lifetime when invoked.
    public static func runIfRequested() {
        guard CommandLine.arguments.contains(launchArgument) else { return }

        let semaphore = DispatchSemaphore(value: 0)
        let result = ExitCodeBox()

        Task.detached {
            do {
                let code = try await runHarness()
                result.set(code)
            } catch {
                let line = "verify-legacy-import: error: \(error)\n"
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

    private static let attributedVolumeUUID = "verify-legacy-import"

    /// Resolves the legacy cache directory. Defaults to the app's real
    /// Application Support path; honors the `MARQUEE_LEGACY_CACHE_DIR`
    /// environment variable so tests and ad-hoc verifications can target a
    /// fixture directory without copying files into the user's home.
    private static func resolveCacheDir() -> URL {
        if let override = ProcessInfo.processInfo.environment["MARQUEE_LEGACY_CACHE_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Marquee")
    }

    private static func runHarness() async throws -> Int32 {
        let cacheDir = resolveCacheDir()

        let movies = (try decodeCache(at: cacheDir.appendingPathComponent("library-cache-movies.json"))) ?? []
        let tv = (try decodeCache(at: cacheDir.appendingPathComponent("library-cache-tv.json"))) ?? []

        let distinctMoviePaths = Set(movies.map { $0.filePath }).count
        let distinctTVPaths = Set(tv.map { $0.filePath }).count
        let distinctTotal = Set((movies + tv).map { $0.filePath }).count

        let inputCounts = InputCounts(
            moviesEntries: movies.count,
            tvEntries: tv.count,
            distinctMoviePaths: distinctMoviePaths,
            distinctTVPaths: distinctTVPaths,
            distinctCombinedPaths: distinctTotal
        )

        // No-input guard: an absent or empty legacy cache cannot prove
        // round-trip correctness. Refuse to declare success.
        if movies.isEmpty && tv.isEmpty {
            let outcome = "no-input"
            let emptySet = SetBasedCheck(
                expectedDistinctMediaFileIDs: 0,
                observedMediaFileIDs: 0,
                missingFromCatalog: 0,
                unexpectedInCatalog: 0,
                allExpectedPresent: false
            )
            let emptyExpected = ExpectedCounts(
                mediaFiles: 0, movies: 0, shows: 0,
                seasons: 0, episodes: 0, artwork: 0
            )
            let emptyObserved = try await InMemoryCatalogStore().countsSnapshot()
            let emptyCountsCheck = CountsCheck(
                expected: emptyExpected,
                observed: emptyObserved,
                mismatches: ["no input — counts comparison skipped"],
                allMatch: false
            )
            let report = Report(
                timestamp: Self.iso8601(Date()),
                cacheDirectory: cacheDir.path,
                inputCounts: inputCounts,
                firstRunSummary: LegacyJSONImporter.ImportSummary(),
                firstRunCatalogCounts: emptyObserved,
                secondRunSummary: LegacyJSONImporter.ImportSummary(),
                secondRunCatalogCounts: emptyObserved,
                idempotent: false,
                sampleChecks: [],
                dataLossChecks: ["no legacy cache input found at \(cacheDir.path)"],
                setBasedCheck: emptySet,
                countsCheck: emptyCountsCheck,
                readbackChecks: [],
                outcome: outcome,
                success: false
            )
            try writeReport(report)
            let line = "verify-legacy-import: outcome=no-input cacheDir=\(cacheDir.path)\n"
            FileHandle.standardError.write(Data(line.utf8))
            return 1
        }

        let store = InMemoryCatalogStore()
        let importer = LegacyJSONImporter(attributedVolumeUUID: attributedVolumeUUID)

        let firstSummary = try await importer.importLibraryCache(from: cacheDir, into: store)
        let firstCounts = try await store.countsSnapshot()

        let secondSummary = try await importer.importLibraryCache(from: cacheDir, into: store)
        let secondCounts = try await store.countsSnapshot()
        let idempotent = (firstCounts == secondCounts)

        let samples = try await collectSampleChecks(
            movies: movies,
            tv: tv,
            store: store
        )

        // Set-based proof of presence: every distinct input path must
        // resolve to a `MediaFileID` that the store also contains.
        let expectedIDs = expectedMediaFileIDs(movies: movies, tv: tv)
        let observedIDs = Set(try await store.allMediaFiles().map { $0.id })
        let missing = expectedIDs.subtracting(observedIDs)
        let unexpected = observedIDs.subtracting(expectedIDs)
        let setCheck = SetBasedCheck(
            expectedDistinctMediaFileIDs: expectedIDs.count,
            observedMediaFileIDs: observedIDs.count,
            missingFromCatalog: missing.count,
            unexpectedInCatalog: unexpected.count,
            allExpectedPresent: missing.isEmpty
        )

        // Expected per-entity counts derived by replaying the importer's
        // identity rules against the input. Compared to the catalog's
        // observed counts to catch dropped entity classes (e.g. a regression
        // that imports media files but no movies/shows/episodes).
        let expectedCounts = computeExpectedCounts(movies: movies, tv: tv)
        let countsCheck = compareCounts(expected: expectedCounts, observed: firstCounts)

        // Read-back: pick representative entities and confirm their stored
        // fields match the legacy input. Guards against silent corruption
        // (e.g. entity rows present but with empty/wrong titles/relations).
        let readbackChecks = try await collectReadbackChecks(
            movies: movies,
            tv: tv,
            store: store
        )

        var checks: [String] = []
        checks.append("input distinct movie paths: \(distinctMoviePaths)")
        checks.append("input distinct tv paths: \(distinctTVPaths)")
        checks.append("input distinct combined paths: \(distinctTotal)")
        checks.append("catalog mediaFiles after import: \(firstCounts.mediaFiles)")
        checks.append("expected distinct MediaFileIDs: \(setCheck.expectedDistinctMediaFileIDs)")
        checks.append("observed MediaFileIDs in catalog: \(setCheck.observedMediaFileIDs)")
        checks.append("missing from catalog: \(setCheck.missingFromCatalog)")
        checks.append("unexpected in catalog: \(setCheck.unexpectedInCatalog)")
        checks.append("set-based: every expected ID present: \(setCheck.allExpectedPresent)")
        checks.append("entity counts match expected: \(countsCheck.allMatch)")
        for mismatch in countsCheck.mismatches {
            checks.append("counts mismatch: \(mismatch)")
        }
        checks.append("readback checks passed: \(readbackChecks.allSatisfy { $0.passed })")

        let allSamplesFound = samples.allSatisfy { $0.foundInCatalog }
        checks.append("all sample checks found in catalog: \(allSamplesFound)")

        let allReadbackPassed = readbackChecks.allSatisfy { $0.passed }
        let success = idempotent
            && setCheck.allExpectedPresent
            && setCheck.unexpectedInCatalog == 0
            && allSamplesFound
            && countsCheck.allMatch
            && allReadbackPassed
        let outcome = success ? "verified" : "failed"

        let report = Report(
            timestamp: Self.iso8601(Date()),
            cacheDirectory: cacheDir.path,
            inputCounts: inputCounts,
            firstRunSummary: firstSummary,
            firstRunCatalogCounts: firstCounts,
            secondRunSummary: secondSummary,
            secondRunCatalogCounts: secondCounts,
            idempotent: idempotent,
            sampleChecks: samples,
            dataLossChecks: checks,
            setBasedCheck: setCheck,
            countsCheck: countsCheck,
            readbackChecks: readbackChecks,
            outcome: outcome,
            success: success
        )

        try writeReport(report)

        let line = "verify-legacy-import: outcome=\(outcome) idempotent=\(idempotent)"
            + " movies=\(inputCounts.moviesEntries) tv=\(inputCounts.tvEntries)"
            + " expected=\(setCheck.expectedDistinctMediaFileIDs)"
            + " observed=\(setCheck.observedMediaFileIDs)"
            + " missing=\(setCheck.missingFromCatalog)"
            + " unexpected=\(setCheck.unexpectedInCatalog)"
            + " countsMatch=\(countsCheck.allMatch)"
            + " readback=\(allReadbackPassed)\n"
        FileHandle.standardError.write(Data(line.utf8))

        return success ? 0 : 1
    }

    /// Computes the set of `MediaFileID`s that the importer is expected to
    /// produce, using the same identity rules the importer uses internally.
    /// One ID per distinct legacy `filePath`.
    private static func expectedMediaFileIDs(
        movies: [CachedMediaItem],
        tv: [CachedMediaItem]
    ) -> Set<MediaFileID> {
        var ids = Set<MediaFileID>()
        for path in Set((movies + tv).map { $0.filePath }) {
            let rel = MediaIdentity.normalizeRelativePath(path)
            ids.insert(MediaIdentity.mediaFileID(
                volumeUUID: attributedVolumeUUID,
                relativePath: rel
            ))
        }
        return ids
    }

    /// Replays the importer's identity logic over the input to derive how
    /// many distinct entities the catalog should hold after a successful
    /// import. Compared against `CatalogCounts` to detect dropped or
    /// duplicated entity classes.
    ///
    /// Coupling note: this function intentionally mirrors the identity
    /// rules in `LegacyJSONImporter` and `MediaIdentity`. If those rules
    /// change (e.g., a new entity is written, or an existing entity's key
    /// derivation changes), this function MUST be updated in the same
    /// commit, otherwise the harness will start reporting spurious
    /// expected/observed mismatches.
    private static func computeExpectedCounts(
        movies: [CachedMediaItem],
        tv: [CachedMediaItem]
    ) -> ExpectedCounts {
        var fileIDs = Set<MediaFileID>()
        var movieIDs = Set<MovieID>()
        var showIDs = Set<ShowID>()
        var seasonIDs = Set<SeasonID>()
        var episodeIDs = Set<EpisodeID>()
        var artworkIDs = Set<ArtworkAssetID>()

        func fileID(_ path: String) -> MediaFileID {
            MediaIdentity.mediaFileID(
                volumeUUID: attributedVolumeUUID,
                relativePath: MediaIdentity.normalizeRelativePath(path)
            )
        }
        func recordArt(_ owner: ArtworkOwner, _ pairs: [(ArtworkKind, String?)]) {
            for (kind, path) in pairs {
                guard let path = path, !path.isEmpty else { continue }
                artworkIDs.insert(MediaIdentity.artworkID(
                    owner: owner, kind: kind, sourceLabel: "legacy-cache"
                ))
            }
        }

        for entry in movies {
            let fid = fileID(entry.filePath)
            fileIDs.insert(fid)
            let mid = MediaIdentity.movieID(primaryFile: fid)
            movieIDs.insert(mid)
            recordArt(.movie(mid), [
                (.poster, entry.posterImagePath),
                (.backdrop, entry.backdropImagePath),
                (.thumbPoster, entry.thumbPosterPath),
                (.thumbBackdrop, entry.thumbBackdropPath),
            ])
        }

        for entry in tv {
            let fid = fileID(entry.filePath)
            fileIDs.insert(fid)
            let title = entry.showName ?? entry.title
            let sid = MediaIdentity.showID(title: title, year: entry.year)
            showIDs.insert(sid)
            let seasonNumber = entry.seasonNumber ?? 0
            let seasonID = MediaIdentity.seasonID(show: sid, seasonNumber: seasonNumber)
            seasonIDs.insert(seasonID)
            if let epNum = entry.episodeNumber {
                episodeIDs.insert(MediaIdentity.episodeID(
                    season: seasonID, episodeNumber: epNum, primaryFile: fid
                ))
            }
            recordArt(.show(sid), [
                (.poster, entry.showPosterPath),
                (.backdrop, entry.showBackdropPath),
                (.thumbPoster, entry.showThumbPosterPath),
                (.thumbBackdrop, entry.showThumbBackdropPath),
            ])
            recordArt(.season(seasonID), [
                (.poster, entry.seasonPosterPath),
                (.backdrop, entry.seasonBackdropPath),
            ])
        }

        return ExpectedCounts(
            mediaFiles: fileIDs.count,
            movies: movieIDs.count,
            shows: showIDs.count,
            seasons: seasonIDs.count,
            episodes: episodeIDs.count,
            artwork: artworkIDs.count
        )
    }

    private static func compareCounts(
        expected: ExpectedCounts,
        observed: CatalogCounts
    ) -> CountsCheck {
        var mismatches: [String] = []
        if observed.mediaFiles != expected.mediaFiles {
            mismatches.append("mediaFiles: expected=\(expected.mediaFiles) observed=\(observed.mediaFiles)")
        }
        if observed.movies != expected.movies {
            mismatches.append("movies: expected=\(expected.movies) observed=\(observed.movies)")
        }
        if observed.shows != expected.shows {
            mismatches.append("shows: expected=\(expected.shows) observed=\(observed.shows)")
        }
        if observed.seasons != expected.seasons {
            mismatches.append("seasons: expected=\(expected.seasons) observed=\(observed.seasons)")
        }
        if observed.episodes != expected.episodes {
            mismatches.append("episodes: expected=\(expected.episodes) observed=\(observed.episodes)")
        }
        if observed.artwork != expected.artwork {
            mismatches.append("artwork: expected=\(expected.artwork) observed=\(observed.artwork)")
        }
        return CountsCheck(
            expected: expected,
            observed: observed,
            mismatches: mismatches,
            allMatch: mismatches.isEmpty
        )
    }

    /// Reads representative entities back out of the store and confirms key
    /// fields agree with the legacy input. Each check is independent; the
    /// list is empty for cases where the input has no entries of that kind
    /// (e.g. movies-only fixture skips show/season/episode readback).
    private static func collectReadbackChecks(
        movies: [CachedMediaItem],
        tv: [CachedMediaItem],
        store: CatalogStore
    ) async throws -> [ReadbackCheck] {
        var checks: [ReadbackCheck] = []

        // Movie readback: title + primary file relativePath
        if let entry = movies.first {
            let relPath = MediaIdentity.normalizeRelativePath(entry.filePath)
            let fid = MediaIdentity.mediaFileID(
                volumeUUID: attributedVolumeUUID, relativePath: relPath
            )
            let mid = MediaIdentity.movieID(primaryFile: fid)
            let movie = try await store.movie(id: mid)
            let titleMatches = movie?.title == entry.title
            let fileLink = movie?.primaryFile == fid
            checks.append(ReadbackCheck(
                kind: "movie",
                entityID: mid.rawValue,
                assertion: "movie.title == legacy.title && movie.primaryFile == fileID",
                passed: movie != nil && titleMatches && fileLink,
                detail: movie.map {
                    "title=\($0.title) primaryFile=\($0.primaryFile.rawValue)"
                } ?? "movie not found"
            ))

            // Movie artwork readback: at least one artwork present if input
            // declared any non-empty image path.
            let inputHasArt =
                (entry.posterImagePath?.isEmpty == false) ||
                (entry.backdropImagePath?.isEmpty == false) ||
                (entry.thumbPosterPath?.isEmpty == false) ||
                (entry.thumbBackdropPath?.isEmpty == false)
            if inputHasArt {
                let art = try await store.artwork(for: .movie(mid))
                let kinds = art.map { $0.kind.rawValue }.sorted().joined(separator: ",")
                checks.append(ReadbackCheck(
                    kind: "artwork",
                    entityID: mid.rawValue,
                    assertion: "store.artwork(for: .movie) is non-empty when input has art",
                    passed: !art.isEmpty,
                    detail: "found=\(art.count) kinds=\(kinds)"
                ))
            }
        }

        // TV readback: pick first entry that has an episode number
        if let entry = tv.first(where: { $0.episodeNumber != nil }) {
            let relPath = MediaIdentity.normalizeRelativePath(entry.filePath)
            let fid = MediaIdentity.mediaFileID(
                volumeUUID: attributedVolumeUUID, relativePath: relPath
            )
            let showTitle = entry.showName ?? entry.title
            let sid = MediaIdentity.showID(title: showTitle, year: entry.year)
            let seasonNumber = entry.seasonNumber ?? 0
            let seasonID = MediaIdentity.seasonID(show: sid, seasonNumber: seasonNumber)
            let episodeID = MediaIdentity.episodeID(
                season: seasonID,
                episodeNumber: entry.episodeNumber!,
                primaryFile: fid
            )

            let show = try await store.show(id: sid)
            checks.append(ReadbackCheck(
                kind: "show",
                entityID: sid.rawValue,
                assertion: "show.title == legacy.showName ?? legacy.title",
                passed: show?.title == showTitle,
                detail: show.map { "title=\($0.title) year=\($0.year ?? -1)" } ?? "show not found"
            ))

            let seasons = try await store.seasons(of: sid)
            let seasonHit = seasons.first { $0.seasonNumber == seasonNumber }
            checks.append(ReadbackCheck(
                kind: "season",
                entityID: seasonID.rawValue,
                assertion: "store.seasons(of: show) contains seasonNumber",
                passed: seasonHit != nil,
                detail: "seasons=\(seasons.map { $0.seasonNumber }.sorted())"
            ))

            let episode = try await store.episode(id: episodeID)
            let epNumberMatches = episode?.episodeNumber == entry.episodeNumber
            let epSeasonMatches = episode?.seasonID == seasonID
            checks.append(ReadbackCheck(
                kind: "episode",
                entityID: episodeID.rawValue,
                assertion: "episode.episodeNumber == legacy && episode.seasonID == derivedSeasonID",
                passed: episode != nil && epNumberMatches && epSeasonMatches,
                detail: episode.map {
                    "title=\($0.title ?? "<nil>") epNum=\($0.episodeNumber)"
                } ?? "episode not found"
            ))
        }

        return checks
    }

    private static func collectSampleChecks(
        movies: [CachedMediaItem],
        tv: [CachedMediaItem],
        store: InMemoryCatalogStore
    ) async throws -> [SampleCheck] {
        var samples: [SampleCheck] = []

        for entry in movies.prefix(5) {
            let relPath = MediaIdentity.normalizeRelativePath(entry.filePath)
            let id = MediaIdentity.mediaFileID(
                volumeUUID: attributedVolumeUUID,
                relativePath: relPath
            )
            let file = try await store.mediaFile(id: id)
            samples.append(SampleCheck(
                kind: "movie",
                sourcePath: entry.filePath,
                resolvedMediaFileID: id.rawValue,
                foundInCatalog: file != nil,
                titleEcho: entry.title
            ))
        }

        for entry in tv.prefix(5) {
            let relPath = MediaIdentity.normalizeRelativePath(entry.filePath)
            let id = MediaIdentity.mediaFileID(
                volumeUUID: attributedVolumeUUID,
                relativePath: relPath
            )
            let file = try await store.mediaFile(id: id)
            samples.append(SampleCheck(
                kind: "episode",
                sourcePath: entry.filePath,
                resolvedMediaFileID: id.rawValue,
                foundInCatalog: file != nil,
                titleEcho: entry.episodeTitle ?? entry.title
            ))
        }

        return samples
    }

    private static func decodeCache(at url: URL) throws -> [CachedMediaItem]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return nil }
        return try JSONDecoder().decode([CachedMediaItem].self, from: data)
    }

    // MARK: - Report I/O

    private static func writeReport(_ report: Report) throws {
        let dir = try resolveReportsDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let stamp = iso8601(Date()).replacingOccurrences(of: ":", with: "-")
        let url = dir.appendingPathComponent("legacy-import-verify-\(stamp).json")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)
        try data.write(to: url, options: .atomic)

        let line = "verify-legacy-import: wrote \(url.path)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    private static func resolveReportsDir() throws -> URL {
        let env = ProcessInfo.processInfo.environment
        if let override = env["MARQUEE_VERIFY_REPORTS_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }

        let fm = FileManager.default
        var dir = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
        for _ in 0..<8 {
            let marker = dir.appendingPathComponent("Marquee.xcodeproj")
            if fm.fileExists(atPath: marker.path) {
                return dir
                    .appendingPathComponent("build", isDirectory: true)
                    .appendingPathComponent("reports", isDirectory: true)
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }

        return fm.temporaryDirectory
            .appendingPathComponent("marquee-verify-reports", isDirectory: true)
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

#endif // DEBUG
