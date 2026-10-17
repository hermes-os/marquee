//
//  DiffScanner.swift
//  Marquee
//
//  Bounded, resumable filesystem scanner that
//  writes through `CatalogStore` only. Walks one library root, diffs
//  against the catalog by `(size, mtime)`, and applies changes in
//  bounded batches inside `withTransaction`.
//
//  See docs/ARCHITECTURE.md §"Catalog and library data flow" and
//  docs/ARCHITECTURE_DECISIONS.md ADR-002 for the identity rules.
//
//  Walk phase happens off-transaction (slow filesystem I/O). Diff phase
//  is pure in-memory set arithmetic. Only the apply phase holds a write
//  lock — and only for one batch at a time, so a long scan does not
//  starve concurrent UI reads or other writes.
//

import Foundation

// MARK: - Configuration

/// Tunables for `DiffScanner`. The defaults are sized for typical home
/// theater libraries (a few thousand files); tests override them.
public struct DiffScannerConfig: Sendable {

    /// Maximum number of file mutations applied per `withTransaction`
    /// block. Smaller batches release the write lock more often;
    /// larger batches amortize transaction overhead.
    public var batchSize: Int

    /// Lowercased file extensions the scanner treats as media. Anything
    /// outside this set is ignored without a scan event so the audit
    /// log stays focused on actual library content.
    public var videoExtensions: Set<String>

    /// When true, the scanner emits a `.fileSeen` event for every file
    /// the walk encountered — useful for debugging the diff but very
    /// noisy for normal scans.
    public var emitFileSeen: Bool

    public init(
        batchSize: Int = 250,
        videoExtensions: Set<String> = DiffScannerConfig.defaultVideoExtensions,
        emitFileSeen: Bool = false
    ) {
        // A non-positive batch size would hang the apply loop forever
        // because `end = min(index + batchSize, ...)` never advances
        // `index`. Fail loudly at construction so the misconfiguration
        // is obvious and never reaches the scanner.
        precondition(
            batchSize > 0,
            "DiffScannerConfig.batchSize must be >= 1 (got \(batchSize))"
        )
        self.batchSize = batchSize
        self.videoExtensions = videoExtensions
        self.emitFileSeen = emitFileSeen
    }

    public static let `default` = DiffScannerConfig()

    /// Formats accepted by the scanner, including the extensions written by
    /// the legacy importer. Keep this aligned with playback routing.
    public static let defaultVideoExtensions: Set<String> = [
        "mkv", "mp4", "m4v", "mov", "avi", "wmv", "flv",
        "webm", "ts", "m2ts", "mpg", "mpeg", "vob"
    ]
}

// MARK: - Errors

public enum DiffScannerError: Error, Equatable {
    case rootDoesNotExist(String)
    case rootIsNotDirectory(String)
    /// The root path was resolved but not against any currently-mounted
    /// volume. The scanner refuses to attribute files to a synthesized
    /// volume — that is the legacy-import-v1 mistake we are migrating
    /// away from.
    case rootNotInVolume(String)
}

// MARK: - Scanner

/// Walks a library root, diffs the result against the catalog, and
/// applies the difference through `CatalogStore.withTransaction`.
///
/// One `DiffScanner` instance can scan any number of roots over its
/// lifetime, but never two concurrently — the actor isolation
/// guarantees serialization.
public actor DiffScanner {

    private let catalog: any CatalogStore
    private let volumes: any VolumeRegistry
    private let config: DiffScannerConfig
    private let clock: @Sendable () -> Date
    private let idGen: @Sendable () -> String

    public init(
        catalog: any CatalogStore,
        volumes: any VolumeRegistry,
        config: DiffScannerConfig = .default,
        clock: @escaping @Sendable () -> Date = { Date() },
        idGenerator: @escaping @Sendable () -> String = { UUID().uuidString }
    ) {
        self.catalog = catalog
        self.volumes = volumes
        self.config = config
        self.clock = clock
        self.idGen = idGen_passthrough(idGenerator)
    }

    /// Performs one full scan of `rootPath`. Returns the final
    /// `CatalogScanJob` row reflecting the terminal state. Throws only
    /// if the scan could not be started (root missing, not in a known
    /// volume); in-flight failures land in the `failed` event + job
    /// state, not as a thrown error, so the caller observes the same
    /// surface for both clean and dirty terminations.
    @discardableResult
    public func scan(rootPath: String) async throws -> CatalogScanJob {
        let absoluteRoot = (rootPath as NSString).standardizingPath

        // Pre-flight checks happen before we mint a job. Failing to
        // mint a job here means the scanner has no place to write
        // events, so the caller has to learn through a thrown error.
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: absoluteRoot, isDirectory: &isDirectory
        ) else {
            throw DiffScannerError.rootDoesNotExist(absoluteRoot)
        }
        guard isDirectory.boolValue else {
            throw DiffScannerError.rootIsNotDirectory(absoluteRoot)
        }

        let rootURL = URL(fileURLWithPath: absoluteRoot, isDirectory: true)
        let resolved: (volume: VolumeDescriptor, relativePath: String)
        do {
            resolved = try await volumes.resolve(url: rootURL)
        } catch {
            throw DiffScannerError.rootNotInVolume(absoluteRoot)
        }
        let volumeUUID = resolved.volume.uuid
        let rootRelative = resolved.relativePath

        // Mint the job in `queued` state, then transition to `running`
        // before the walk so observers see progress.
        let now = clock()
        let job = CatalogScanJob(
            id: ScanJobID(rawValue: idGen()),
            rootPath: absoluteRoot,
            volumeUUID: volumeUUID,
            state: .queued,
            createdAt: now,
            startedAt: nil,
            completedAt: nil,
            lastErrorMessage: nil,
            filesObserved: 0,
            filesAdded: 0,
            filesUpdated: 0,
            filesRemoved: 0
        )
        try await catalog.upsert(scanJob: job)

        // Transition to running + emit started — single tx so an
        // observer never sees `running` without the matching event.
        let started = clock()
        try await catalog.withTransaction { tx in
            try await tx.upsert(scanJob: CatalogScanJob(
                id: job.id,
                rootPath: job.rootPath,
                volumeUUID: job.volumeUUID,
                state: .running,
                createdAt: job.createdAt,
                startedAt: started,
                completedAt: nil,
                lastErrorMessage: nil,
                filesObserved: 0,
                filesAdded: 0,
                filesUpdated: 0,
                filesRemoved: 0
            ))
            try await tx.append(scanEvent: self.makeEvent(
                jobID: job.id,
                kind: .started,
                ts: started,
                path: absoluteRoot,
                detail: nil
            ))
        }

        // Walk + diff happen outside the write lock.
        do {
            let walked = try walk(
                rootURL: rootURL,
                volumeMountPath: resolved.volume.mountPath
            )
            let existing = try await loadExistingMediaFiles(
                volumeUUID: volumeUUID,
                rootRelative: rootRelative
            )
            let diff = computeDiff(
                walked: walked,
                existing: existing,
                volumeUUID: volumeUUID,
                rootRelative: rootRelative
            )

            var counters = Counters()
            counters.observed = walked.count

            try await applyDiff(
                jobID: job.id,
                rootRelative: rootRelative,
                diff: diff,
                counters: &counters
            )

            // Final transition to completed in a single tx — counters
            // and the .completed event commit together.
            let completed = clock()
            let finalJob = CatalogScanJob(
                id: job.id,
                rootPath: job.rootPath,
                volumeUUID: job.volumeUUID,
                state: .completed,
                createdAt: job.createdAt,
                startedAt: started,
                completedAt: completed,
                lastErrorMessage: nil,
                filesObserved: counters.observed,
                filesAdded: counters.added,
                filesUpdated: counters.updated,
                filesRemoved: counters.removed
            )
            // Bind counter snapshot to an immutable let before crossing
            // into the @Sendable closure — the var binding cannot be
            // captured directly under strict concurrency.
            let finalCounters = counters
            let completedEvent = self.makeEvent(
                jobID: job.id,
                kind: .completed,
                ts: completed,
                path: absoluteRoot,
                detail:
                    "observed=\(finalCounters.observed)" +
                    " added=\(finalCounters.added)" +
                    " updated=\(finalCounters.updated)" +
                    " removed=\(finalCounters.removed)"
            )
            try await catalog.withTransaction { tx in
                try await tx.upsert(scanJob: finalJob)
                try await tx.append(scanEvent: completedEvent)
            }
            return finalJob

        } catch is CancellationError {
            return try await markCancelled(job: job, startedAt: started)
        } catch {
            return try await markFailed(
                job: job,
                startedAt: started,
                error: error
            )
        }
    }

    // MARK: - Walk

    /// One entry per file the walk surfaces. Path is volume-relative,
    /// canonical (forward slash, no leading slash) so it lines up with
    /// `MediaIdentity.mediaFileID` without further normalization.
    private struct WalkedFile {
        let relativePath: String
        let absolutePath: String
        let fileExtension: String
        let size: Int64
        let modificationDate: Date?
    }

    /// Synchronous walk. Runs off the actor (via `nonisolated`) so the
    /// I/O does not block other actor work — the `actor` boundary
    /// already serializes the rest.
    ///
    /// `volumeMountPath` is the absolute mount path of the volume the
    /// `rootURL` belongs to. Every walked file is converted to a
    /// volume-relative path by stripping that prefix — the same rule
    /// `VolumeRegistry.deepestMatch` uses on resolve, so paths the
    /// scanner writes line up exactly with paths the importer wrote.
    private nonisolated func walk(
        rootURL: URL,
        volumeMountPath: String
    ) throws -> [WalkedFile] {
        let fm = FileManager.default
        let resourceKeys: [URLResourceKey] = [
            .isRegularFileKey,
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .contentModificationDateKey
        ]
        guard let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        // Standardize the mount once. The registry already normalizes
        // mount paths on insert, but doing it here keeps the helper
        // correct even if a future registry forgets.
        let canonicalMount = (volumeMountPath as NSString).standardizingPath

        var results: [WalkedFile] = []
        var seenRealPaths = Set<String>()

        for case let url as URL in enumerator {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: Set(resourceKeys))
            // Symlinks are skipped wholesale: they create the only
            // realistic infinite-loop hazard for a recursive walk, and
            // a media library doesn't need them. We do not chase the
            // target to ingest its real path either — that surprised
            // users in the legacy scanner.
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            if values.isDirectory == true {
                continue
            }
            guard values.isRegularFile == true else { continue }

            let ext = url.pathExtension.lowercased()
            guard config.videoExtensions.contains(ext) else { continue }

            // Canonicalize the path so `URL("/foo/bar")` and a path
            // that arrives via `/private/var/...` (TMPDIR resolves
            // symlinks on macOS) collapse before we compare against
            // the mount prefix or the relative-path map.
            let canonical = (url.standardized.path as NSString)
                .standardizingPath
            if !seenRealPaths.insert(canonical).inserted { continue }

            // Strip the mount prefix to get the volume-relative form
            // the catalog stores. If the file is not under the mount
            // (e.g. the mount table changed mid-walk, or the volume
            // entry's mountPath is wrong) skip the file rather than
            // attribute it to the wrong volume.
            guard let relative = pathRelative(
                toMount: canonicalMount,
                of: canonical
            ) else { continue }

            let canonicalURL = URL(fileURLWithPath: canonical)
            let canonicalValues = (try? canonicalURL.resourceValues(
                forKeys: Set(resourceKeys)
            )) ?? values

            results.append(WalkedFile(
                relativePath: relative,
                absolutePath: canonical,
                fileExtension: ext,
                size: Int64(canonicalValues.fileSize ?? 0),
                modificationDate: canonicalValues.contentModificationDate
            ))
        }
        return results
    }

    /// Strips `mount` from `absolutePath` and returns the canonical
    /// volume-relative form (forward slash, no leading slash, no
    /// trailing slash). Returns `nil` when `absolutePath` is not under
    /// `mount` — the scanner treats that as "skip the file" rather
    /// than synthesize a path.
    ///
    /// Intentionally mirrors `VolumeRegistry.deepestMatch`'s prefix
    /// rule so the scanner and the registry never disagree on what
    /// "volume-relative" means.
    private nonisolated func pathRelative(
        toMount mount: String,
        of absolutePath: String
    ) -> String? {
        let suffix: String
        if mount == "/" {
            suffix = String(absolutePath.drop(while: { $0 == "/" }))
        } else if absolutePath == mount {
            suffix = ""
        } else if absolutePath.hasPrefix(mount + "/") {
            suffix = String(absolutePath.dropFirst(mount.count + 1))
        } else {
            return nil
        }
        return MediaIdentity.normalizeRelativePath(suffix)
    }

    // MARK: - Diff

    private struct Diff {
        var toAdd: [CatalogMediaFile]
        var toUpdate: [CatalogMediaFile]
        var toRemove: [CatalogMediaFile]
    }

    /// Loads only the catalog media files that could plausibly belong
    /// to this scan: same `volumeUUID` AND relative path under the
    /// root's volume-relative prefix. The catalog protocol only
    /// surfaces `allMediaFiles()` today, so we filter in memory — the
    /// roadmap calls out a `mediaFiles(under:)` API as future work
    /// once index plans are tuned.
    private func loadExistingMediaFiles(
        volumeUUID: String,
        rootRelative: String
    ) async throws -> [String: CatalogMediaFile] {
        let all = try await catalog.allMediaFiles()
        var byPath: [String: CatalogMediaFile] = [:]
        for f in all where f.volumeUUID == volumeUUID
                            && pathIsUnder(rootRelative, candidate: f.relativePath) {
            byPath[f.relativePath] = f
        }
        return byPath
    }

    private nonisolated func pathIsUnder(
        _ rootRelative: String,
        candidate: String
    ) -> Bool {
        if rootRelative.isEmpty { return true }
        if candidate == rootRelative { return true }
        return candidate.hasPrefix(rootRelative + "/")
    }

    /// Tolerance used when comparing modification dates across the
    /// scanner / store boundary. `SQLiteCatalogStore` persists mtimes
    /// as `Double` seconds-since-1970, and a roundtrip through
    /// `Date(timeIntervalSince1970:)` introduces ULP-scale rounding
    /// noise (≈170ns at the current epoch — the ULP of a Double
    /// near 7.9×10⁸ seconds). `InMemoryCatalogStore` keeps the `Date`
    /// instance verbatim, so without a tolerance the scanner reports
    /// false-positive `fileUpdated`s only against SQLite — the
    /// production write path. 1µs is two orders of magnitude wider
    /// than the worst-case Double noise and three orders narrower
    /// than realistic file mtime intervals on a media library, so
    /// real touches still register while roundtrip noise does not.
    nonisolated static let mtimeEqualityTolerance: TimeInterval = 0.000_001

    nonisolated static func mtimeChanged(
        prior: Date?,
        observed: Date?
    ) -> Bool {
        switch (prior, observed) {
        case (nil, nil):
            return false
        case (nil, _), (_, nil):
            return true
        case let (p?, o?):
            return abs(p.timeIntervalSince1970 - o.timeIntervalSince1970)
                > mtimeEqualityTolerance
        }
    }

    private func computeDiff(
        walked: [WalkedFile],
        existing: [String: CatalogMediaFile],
        volumeUUID: String,
        rootRelative: String
    ) -> Diff {
        var toAdd: [CatalogMediaFile] = []
        var toUpdate: [CatalogMediaFile] = []
        var seenPaths = Set<String>()

        let now = clock()
        for w in walked {
            seenPaths.insert(w.relativePath)
            let id = MediaIdentity.mediaFileID(
                volumeUUID: volumeUUID,
                relativePath: w.relativePath
            )
            if let prior = existing[w.relativePath] {
                if prior.fileSize != w.size
                    || Self.mtimeChanged(
                        prior: prior.modificationDate,
                        observed: w.modificationDate
                    ) {
                    // Preserve `dateAdded` and `contentHash` (Phase 2
                    // hash policy lives elsewhere) so a benign mtime
                    // bump does not overwrite either field.
                    toUpdate.append(CatalogMediaFile(
                        id: prior.id,
                        volumeUUID: prior.volumeUUID,
                        relativePath: prior.relativePath,
                        absolutePathSnapshot: w.absolutePath,
                        fileExtension: w.fileExtension,
                        fileSize: w.size,
                        modificationDate: w.modificationDate,
                        durationSeconds: prior.durationSeconds,
                        contentHash: prior.contentHash,
                        dateAdded: prior.dateAdded
                    ))
                }
            } else {
                toAdd.append(CatalogMediaFile(
                    id: id,
                    volumeUUID: volumeUUID,
                    relativePath: w.relativePath,
                    absolutePathSnapshot: w.absolutePath,
                    fileExtension: w.fileExtension,
                    fileSize: w.size,
                    modificationDate: w.modificationDate,
                    durationSeconds: nil,
                    contentHash: nil,
                    dateAdded: now
                ))
            }
        }

        let toRemove = existing.values.filter { !seenPaths.contains($0.relativePath) }
        _ = rootRelative
        return Diff(toAdd: toAdd, toUpdate: toUpdate, toRemove: Array(toRemove))
    }

    // MARK: - Apply

    private struct Counters {
        var observed: Int = 0
        var added: Int = 0
        var updated: Int = 0
        var removed: Int = 0
    }

    /// Applies the computed diff in chunks of `batchSize`. Each chunk
    /// is one `withTransaction` so a failure rolls back exactly that
    /// chunk's writes. Earlier chunks stay committed — the next scan
    /// resumes from the partial state and diffs forward.
    private func applyDiff(
        jobID: ScanJobID,
        rootRelative: String,
        diff: Diff,
        counters: inout Counters
    ) async throws {
        // Adds first, then updates, then removes. Order does not
        // matter for correctness (each row stands alone), but a
        // consistent order makes scan logs easier to read against the
        // counters, and keeps removals last so a renamed-file scenario
        // shows the new row before the old row vanishes.
        try await applyMutations(
            jobID: jobID,
            mutations: diff.toAdd.map { Mutation.add($0) },
            counters: &counters
        )
        try await applyMutations(
            jobID: jobID,
            mutations: diff.toUpdate.map { Mutation.update($0) },
            counters: &counters
        )
        try await applyMutations(
            jobID: jobID,
            mutations: diff.toRemove.map { Mutation.remove($0) },
            counters: &counters
        )
        _ = rootRelative
    }

    private enum Mutation {
        case add(CatalogMediaFile)
        case update(CatalogMediaFile)
        case remove(CatalogMediaFile)
    }

    private func applyMutations(
        jobID: ScanJobID,
        mutations: [Mutation],
        counters: inout Counters
    ) async throws {
        var index = 0
        while index < mutations.count {
            try Task.checkCancellation()
            let end = min(index + config.batchSize, mutations.count)
            let chunk = Array(mutations[index..<end])
            index = end

            // Build the upsert/delete plan and the matching event list
            // off-tx. Inside the tx we only call store APIs.
            var addsBatch: [CatalogMediaFile] = []
            var updatesBatch: [CatalogMediaFile] = []
            var removesBatch: [CatalogMediaFile] = []
            var events: [CatalogScanEvent] = []
            let now = clock()
            for m in chunk {
                switch m {
                case .add(let f):
                    addsBatch.append(f)
                    events.append(makeEvent(
                        jobID: jobID,
                        kind: .fileAdded,
                        ts: now,
                        path: f.relativePath,
                        detail: "size=\(f.fileSize)"
                    ))
                case .update(let f):
                    updatesBatch.append(f)
                    events.append(makeEvent(
                        jobID: jobID,
                        kind: .fileUpdated,
                        ts: now,
                        path: f.relativePath,
                        detail: "size=\(f.fileSize)"
                    ))
                case .remove(let f):
                    removesBatch.append(f)
                    events.append(makeEvent(
                        jobID: jobID,
                        kind: .fileRemoved,
                        ts: now,
                        path: f.relativePath,
                        detail: nil
                    ))
                }
            }

            // Snapshot counters for the in-progress job row so we can
            // commit the count delta in the same tx. Rebind every
            // mutable local to an immutable let before crossing the
            // @Sendable boundary — the closure cannot capture vars
            // under strict concurrency.
            let snapshot = counters
            let nextCounters = Counters(
                observed: snapshot.observed,
                added: snapshot.added + addsBatch.count,
                updated: snapshot.updated + updatesBatch.count,
                removed: snapshot.removed + removesBatch.count
            )
            let adds = addsBatch
            let updates = updatesBatch
            let removes = removesBatch
            let evts = events
            // Pre-bake fallback timestamps so the closure does not have
            // to call back through the actor for `clock()`.
            let fallbackTs = clock()

            try await catalog.withTransaction { tx in
                if !adds.isEmpty {
                    try await tx.upsert(mediaFiles: adds)
                }
                if !updates.isEmpty {
                    try await tx.upsert(mediaFiles: updates)
                }
                for f in removes {
                    try await tx.deleteMediaFile(id: f.id)
                }
                try await tx.append(scanEvents: evts)
                // Re-read the canonical job row so we don't clobber
                // immutable identity fields and so we keep the latest
                // observed counter, which may already be ahead of the
                // local snapshot if a peer batch beat us in.
                let canonical = try await tx.scanJob(id: jobID)
                let liveStartedAt = canonical?.startedAt ?? fallbackTs
                try await tx.upsert(scanJob: CatalogScanJob(
                    id: jobID,
                    rootPath: canonical?.rootPath ?? "",
                    volumeUUID: canonical?.volumeUUID ?? "",
                    state: .running,
                    createdAt: canonical?.createdAt ?? fallbackTs,
                    startedAt: liveStartedAt,
                    completedAt: nil,
                    lastErrorMessage: nil,
                    filesObserved: snapshot.observed,
                    filesAdded: nextCounters.added,
                    filesUpdated: nextCounters.updated,
                    filesRemoved: nextCounters.removed
                ))
            }
            counters = nextCounters
        }
    }

    // MARK: - Terminal transitions

    private func markCancelled(
        job: CatalogScanJob,
        startedAt: Date
    ) async throws -> CatalogScanJob {
        let ts = clock()
        let finalJob = CatalogScanJob(
            id: job.id,
            rootPath: job.rootPath,
            volumeUUID: job.volumeUUID,
            state: .cancelled,
            createdAt: job.createdAt,
            startedAt: startedAt,
            completedAt: ts,
            lastErrorMessage: nil,
            filesObserved: 0,
            filesAdded: 0,
            filesUpdated: 0,
            filesRemoved: 0
        )
        try await catalog.withTransaction { tx in
            // Re-read to preserve counters from the last committed
            // batch — a cancellation mid-run shouldn't zero out
            // already-applied work.
            if let live = try await tx.scanJob(id: job.id) {
                try await tx.upsert(scanJob: CatalogScanJob(
                    id: live.id,
                    rootPath: live.rootPath,
                    volumeUUID: live.volumeUUID,
                    state: .cancelled,
                    createdAt: live.createdAt,
                    startedAt: live.startedAt ?? startedAt,
                    completedAt: ts,
                    lastErrorMessage: nil,
                    filesObserved: live.filesObserved,
                    filesAdded: live.filesAdded,
                    filesUpdated: live.filesUpdated,
                    filesRemoved: live.filesRemoved
                ))
            } else {
                try await tx.upsert(scanJob: finalJob)
            }
            try await tx.append(scanEvent: self.makeEvent(
                jobID: job.id,
                kind: .cancelled,
                ts: ts,
                path: job.rootPath,
                detail: nil
            ))
        }
        return (try await catalog.scanJob(id: job.id)) ?? finalJob
    }

    private func markFailed(
        job: CatalogScanJob,
        startedAt: Date,
        error: Error
    ) async throws -> CatalogScanJob {
        let ts = clock()
        let message = "\(error)"
        try await catalog.withTransaction { tx in
            if let live = try await tx.scanJob(id: job.id) {
                try await tx.upsert(scanJob: CatalogScanJob(
                    id: live.id,
                    rootPath: live.rootPath,
                    volumeUUID: live.volumeUUID,
                    state: .failed,
                    createdAt: live.createdAt,
                    startedAt: live.startedAt ?? startedAt,
                    completedAt: ts,
                    lastErrorMessage: message,
                    filesObserved: live.filesObserved,
                    filesAdded: live.filesAdded,
                    filesUpdated: live.filesUpdated,
                    filesRemoved: live.filesRemoved
                ))
            } else {
                try await tx.upsert(scanJob: CatalogScanJob(
                    id: job.id,
                    rootPath: job.rootPath,
                    volumeUUID: job.volumeUUID,
                    state: .failed,
                    createdAt: job.createdAt,
                    startedAt: startedAt,
                    completedAt: ts,
                    lastErrorMessage: message,
                    filesObserved: 0,
                    filesAdded: 0,
                    filesUpdated: 0,
                    filesRemoved: 0
                ))
            }
            try await tx.append(scanEvent: self.makeEvent(
                jobID: job.id,
                kind: .failed,
                ts: ts,
                path: job.rootPath,
                detail: message
            ))
        }
        // Best-effort read of the canonical row; fall back to a
        // synthesized failed shell so callers always see the failed
        // state even if the catalog lost the row.
        return (try await catalog.scanJob(id: job.id)) ?? CatalogScanJob(
            id: job.id,
            rootPath: job.rootPath,
            volumeUUID: job.volumeUUID,
            state: .failed,
            createdAt: job.createdAt,
            startedAt: startedAt,
            completedAt: ts,
            lastErrorMessage: message,
            filesObserved: 0,
            filesAdded: 0,
            filesUpdated: 0,
            filesRemoved: 0
        )
    }

    // MARK: - Event minting

    private func makeEvent(
        jobID: ScanJobID,
        kind: ScanEventKind,
        ts: Date,
        path: String?,
        detail: String?
    ) -> CatalogScanEvent {
        CatalogScanEvent(
            id: ScanEventID(rawValue: idGen()),
            jobID: jobID,
            kind: kind,
            timestamp: ts,
            path: path,
            detail: detail
        )
    }
}

// MARK: - Helpers

/// Identity wrapper so the scanner can store the closure as a constant
/// without the compiler tripping over `@escaping` vs `@Sendable`
/// inference at the property level.
private func idGen_passthrough(
    _ closure: @escaping @Sendable () -> String
) -> @Sendable () -> String { closure }
