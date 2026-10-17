//
//  DurationProbe.swift
//  Marquee
//
//  Maintenance probe that fills missing `durationSeconds` values with
//  `AVURLAsset`. Normal startup scans deliberately do not invoke it because
//  broad media probing destabilizes playback on the supported Intel host.
//
//  Concurrency is bounded by `maxConcurrent` so a large library does not spawn
//  one AVAsset task per file. Failures leave `durationSeconds` nil for a later
//  explicit pass.
//

import Foundation
import AVFoundation

/// Narrow protocol so tests can swap a deterministic loader.
protocol DurationLoading: Sendable {
    func loadDuration(at fileURL: URL) async -> TimeInterval?
}

/// Default loader: `AVURLAsset.load(.duration)` with a finite-value check.
struct AVDurationLoader: DurationLoading {
    func loadDuration(at fileURL: URL) async -> TimeInterval? {
        let asset = AVURLAsset(url: fileURL)
        do {
            let duration = try await asset.load(.duration)
            let seconds = CMTimeGetSeconds(duration)
            return seconds.isFinite && seconds > 0 ? seconds : nil
        } catch {
            return nil
        }
    }
}

actor DurationProbe {

    public struct ProbeSummary: Sendable, Equatable {
        public var probed: Int = 0
        public var skipped: Int = 0
        public var failed: Int = 0
    }

    private let catalog: any CatalogStore
    private let loader: any DurationLoading
    private let maxConcurrent: Int

    init(
        catalog: any CatalogStore,
        loader: any DurationLoading = AVDurationLoader(),
        maxConcurrent: Int = 8
    ) {
        self.catalog = catalog
        self.loader = loader
        self.maxConcurrent = max(1, maxConcurrent)
    }

    /// One probe pass. Reads every `media_file` row, picks the rows
    /// with `durationSeconds == nil`, loads duration for each (capped
    /// at `maxConcurrent`), and upserts the result. Rows that fail to
    /// load stay nil; the next pass retries.
    @discardableResult
    func probeMissing() async throws -> ProbeSummary {
        var summary = ProbeSummary()
        let files = try await catalog.allMediaFiles()
        let needsProbe = files.filter { $0.durationSeconds == nil }
        summary.skipped = files.count - needsProbe.count
        if needsProbe.isEmpty { return summary }

        // Capture in locals so the TaskGroup closures don't capture
        // the actor.
        let loader = self.loader
        let cap = self.maxConcurrent

        // Bounded-concurrency task group: keep at most `cap` tasks
        // in flight, harvest results as they complete, and never let
        // a single slow file head-of-line block the whole pass.
        let probed: [(CatalogMediaFile, TimeInterval?)] = await withTaskGroup(
            of: (CatalogMediaFile, TimeInterval?).self
        ) { group in
            var iter = needsProbe.makeIterator()
            var inFlight = 0
            var results: [(CatalogMediaFile, TimeInterval?)] = []
            results.reserveCapacity(needsProbe.count)

            while inFlight < cap, let next = iter.next() {
                let file = next
                let url = URL(fileURLWithPath: file.absolutePathSnapshot)
                group.addTask {
                    let d = await loader.loadDuration(at: url)
                    return (file, d)
                }
                inFlight += 1
            }

            while let result = await group.next() {
                results.append(result)
                inFlight -= 1
                if let next = iter.next() {
                    let file = next
                    let url = URL(fileURLWithPath: file.absolutePathSnapshot)
                    group.addTask {
                        let d = await loader.loadDuration(at: url)
                        return (file, d)
                    }
                    inFlight += 1
                }
            }
            return results
        }

        var toUpsert: [CatalogMediaFile] = []
        toUpsert.reserveCapacity(probed.count)
        for (file, duration) in probed {
            guard let seconds = duration else {
                summary.failed += 1
                continue
            }
            toUpsert.append(CatalogMediaFile(
                id: file.id,
                volumeUUID: file.volumeUUID,
                relativePath: file.relativePath,
                absolutePathSnapshot: file.absolutePathSnapshot,
                fileExtension: file.fileExtension,
                fileSize: file.fileSize,
                modificationDate: file.modificationDate,
                durationSeconds: seconds,
                contentHash: file.contentHash,
                dateAdded: file.dateAdded
            ))
        }

        if !toUpsert.isEmpty {
            try await catalog.upsert(mediaFiles: toUpsert)
            summary.probed = toUpsert.count
        }
        return summary
    }
}
