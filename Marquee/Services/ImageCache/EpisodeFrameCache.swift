import Foundation
import AVFoundation
import AppKit
import CryptoKit

// MARK: - Episode Frame Cache
//
// Captures a single representative frame per episode video file using
// AVAssetImageGenerator and persists it as a JPEG on the media drive
// (`<appSupport>/frames/<sha256(filePath)>.jpg`).
//
// Used only by `EpisodeRow` — must not replace TMDB show posters or
// movie posters elsewhere. Lookup is cheap once cached: a stat on
// the cache file path. First miss enqueues a one-shot capture; the
// view re-asks on the next render once the cache file exists.

extension Notification.Name {
    /// Posted on the main thread after a frame has been written to disk.
    /// `userInfo[EpisodeFrameCache.filePathKey]` contains the source video path.
    static let episodeFrameCaptured = Notification.Name("com.marquee.episode-frame-captured")
}

final class EpisodeFrameCache {

    static let shared = EpisodeFrameCache()
    static let filePathKey = "filePath"

    private let frameDir: URL
    private let queue = DispatchQueue(label: "com.marquee.episode-frames", qos: .utility)
    private var inFlight: Set<String> = []
    private let inFlightLock = NSLock()

    /// Capture timestamp expressed as a fraction of total duration.
    /// 12% gets us past the cold-open studio cards on most shows.
    private let captureFraction: Double = 0.12

    /// Width to render the cached JPEG. EpisodeRow shows the thumb at
    /// 200×112pt. Render at 2x to stay sharp on retina without paying
    /// for a full-res frame.
    private let outputWidth: CGFloat = 400
    private let captureTimeout: TimeInterval = 12

    private init() {
        let base = Configuration.appSupportDirectory
        frameDir = base.appendingPathComponent("frames", isDirectory: true)
        try? FileManager.default.createDirectory(at: frameDir, withIntermediateDirectories: true)
    }

    // MARK: - Public API

    /// Synchronous lookup: returns the cached frame path if it exists,
    /// otherwise nil. If `triggerCaptureIfMissing` is true a background
    /// capture is scheduled.
    func cachedFramePath(
        forVideoAt path: String,
        duration: TimeInterval? = nil,
        triggerCaptureIfMissing: Bool = true
    ) -> String? {
        let cacheURL = cacheURL(forVideoAt: path)
        if FileManager.default.fileExists(atPath: cacheURL.path) {
            return cacheURL.path
        }
        if triggerCaptureIfMissing {
            scheduleCapture(forVideoAt: path, duration: duration)
        }
        return nil
    }

    // MARK: - Internal

    private func cacheURL(forVideoAt path: String) -> URL {
        let digest = SHA256.hash(data: Data(path.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return frameDir.appendingPathComponent("\(hex).jpg")
    }

    private func scheduleCapture(forVideoAt path: String, duration: TimeInterval?) {
        inFlightLock.lock()
        if inFlight.contains(path) {
            inFlightLock.unlock()
            return
        }
        inFlight.insert(path)
        inFlightLock.unlock()

        queue.async { [weak self] in
            guard let self = self else { return }
            defer {
                self.inFlightLock.lock()
                self.inFlight.remove(path)
                self.inFlightLock.unlock()
            }
            self.capture(forVideoAt: path, duration: duration)
        }
    }

    private func capture(forVideoAt path: String, duration: TimeInterval?) {
        let fileURL = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else { return }
        let cacheURL = self.cacheURL(forVideoAt: path)
        if FileManager.default.fileExists(atPath: cacheURL.path) { return }

        let captureSeconds = captureSecond(for: duration)
        if locateFFmpeg() != nil {
            if captureWithFFmpeg(
                sourcePath: path,
                outputURL: cacheURL,
                at: captureSeconds
            ) {
                notifyFrameCaptured(for: path)
            }
            return
        }

        let asset = AVURLAsset(url: fileURL, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: false
        ])

        let captureTime = CMTime(seconds: captureSeconds, preferredTimescale: 600)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1.0, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1.0, preferredTimescale: 600)
        generator.maximumSize = CGSize(width: outputWidth, height: outputWidth) // bounding box; aspect preserved

        var actualTime = CMTime.zero
        do {
            let cgImage = try generator.copyCGImage(at: captureTime, actualTime: &actualTime)
            let nsImage = NSImage(cgImage: cgImage, size: .zero)
            guard let jpegData = nsImage.jpegData(compressionQuality: 0.78) else { return }
            try jpegData.write(to: cacheURL, options: .atomic)
            notifyFrameCaptured(for: path)
        } catch {
            // Silent on failure: empty thumbnail is better than crash.
            // Common cases: codec the frame extractor can't decode (rare),
            // or asset that's still being copied.
        }
    }

    private func captureSecond(for duration: TimeInterval?) -> TimeInterval {
        guard let duration, duration.isFinite, duration > 4 else { return 10 }
        let proportional = max(2, duration * captureFraction)
        return min(proportional, max(0.5, duration - 1))
    }

    private func captureWithFFmpeg(sourcePath: String, outputURL: URL, at seconds: TimeInterval) -> Bool {
        guard let ffmpegURL = locateFFmpeg() else { return false }

        let tempURL = frameDir.appendingPathComponent(
            "\(outputURL.deletingPathExtension().lastPathComponent).\(UUID().uuidString).partial.jpg"
        )
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let process = Process()
        process.executableURL = ffmpegURL
        process.arguments = [
            "-hide_banner",
            "-nostdin",
            "-loglevel", "error",
            "-ss", String(format: "%.3f", seconds),
            "-i", sourcePath,
            "-frames:v", "1",
            "-vf", "scale=\(Int(outputWidth)):-2",
            "-q:v", "3",
            "-y",
            tempURL.path
        ]
        process.currentDirectoryURL = frameDir
        var environment = ProcessInfo.processInfo.environment
        environment["TMPDIR"] = frameDir.path
        process.environment = environment

        let stderr = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            MarqueeLogger.cache.debug("Episode frame ffmpeg failed to start: \(error.localizedDescription)")
            return false
        }

        // Drain stderr on a dedicated thread so a chatty ffmpeg cannot
        // fill the pipe buffer and block on write while we poll
        // process.isRunning. readDataToEndOfFile returns once the child
        // closes its stderr (on exit or termination).
        var stderrData = Data()
        let stderrGroup = DispatchGroup()
        DispatchQueue.global(qos: .utility).async(group: stderrGroup) {
            stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        }

        let deadline = Date().addingTimeInterval(captureTimeout)
        while process.isRunning {
            if Date() >= deadline {
                process.terminate()
                let stopDeadline = Date().addingTimeInterval(0.5)
                while process.isRunning && Date() < stopDeadline {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                MarqueeLogger.cache.debug("Episode frame ffmpeg timed out for: \(sourcePath)")
                return false
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        stderrGroup.wait()

        guard process.terminationStatus == 0,
              FileManager.default.fileExists(atPath: tempURL.path),
              ((try? FileManager.default.attributesOfItem(atPath: tempURL.path)[.size] as? NSNumber)?.int64Value ?? 0) > 0 else {
            let detail = String(data: stderrData, encoding: .utf8) ?? ""
            if !detail.isEmpty {
                MarqueeLogger.cache.debug("Episode frame ffmpeg failed: \(detail)")
            }
            return false
        }

        do {
            try? FileManager.default.removeItem(at: outputURL)
            try FileManager.default.moveItem(at: tempURL, to: outputURL)
            return true
        } catch {
            MarqueeLogger.cache.debug("Episode frame cache write failed: \(error.localizedDescription)")
            return false
        }
    }

    private func locateFFmpeg() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        let candidates = [
            environment["MARQUEE_FFMPEG_PATH"],
            "/usr/local/bin/ffmpeg",
            "/opt/homebrew/bin/ffmpeg",
            "/usr/bin/ffmpeg"
        ].compactMap { $0 }

        return candidates
            .map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private func notifyFrameCaptured(for path: String) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .episodeFrameCaptured,
                object: nil,
                userInfo: [EpisodeFrameCache.filePathKey: path]
            )
        }
    }
}

// MARK: - NSImage JPEG helper

private extension NSImage {
    func jpegData(compressionQuality: CGFloat) -> Data? {
        guard let tiff = self.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: compressionQuality])
    }
}
