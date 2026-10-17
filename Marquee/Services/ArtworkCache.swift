import Foundation
import AppKit
import ImageIO
import os

// MARK: - Artwork Cache
// TODO: stopgap — remove when cluster migration lands

final class ArtworkCache {

    static let shared = ArtworkCache()
    static let gridPosterThumbnailPixelSize = CGSize(width: 360, height: 540)
    static let leanBackPosterThumbnailPixelSize = CGSize(width: 520, height: 780)
    static let homeHeroBackdropThumbnailPixelSize = CGSize(width: 1200, height: 675)
    static let heroBackdropThumbnailPixelSize = CGSize(width: 1280, height: 720)
    private static let homeBackdropPreloadLimit = 3
    private static let homePosterPreloadLimit = 10

    private let cacheDir: URL
    private let thumbnailDir: URL
    private let fm = FileManager.default

    private init() {
        cacheDir = Configuration.artworkCacheDirectory
        thumbnailDir = cacheDir.appendingPathComponent("thumbnails")
        try? fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: thumbnailDir, withIntermediateDirectories: true)
    }

    // MARK: - Public API

    /// Returns a local cache path for the given image path.
    /// If the path is already local (app support, caches), returns it unchanged.
    /// If it's on an external/slow volume, copies to local cache and returns the cached path.
    func localPath(for originalPath: String) -> String {
        guard isExternalPath(originalPath) else { return originalPath }

        let cacheKey = stableKey(for: "\(originalPath)|\(sourceFingerprint(for: originalPath))")
        let cachedURL = cacheDir.appendingPathComponent(cacheKey)

        if fm.fileExists(atPath: cachedURL.path) {
            return cachedURL.path
        }

        guard fm.fileExists(atPath: originalPath) else {
            return originalPath
        }

        do {
            try fm.copyItem(atPath: originalPath, toPath: cachedURL.path)
            MarqueeLogger.cache.debug("Cached artwork: \(cacheKey)")
        } catch {
            MarqueeLogger.cache.error("Failed to cache artwork \(cacheKey): \(error.localizedDescription)")
            return originalPath
        }

        return cachedURL.path
    }

    /// Returns a downsampled local thumbnail path for grid/list art.
    /// This keeps SwiftUI cells from loading full-resolution poster files.
    func thumbnailPath(for originalPath: String, pixelSize: CGSize) -> String {
        let sourcePath = localPath(for: originalPath)
        guard fm.fileExists(atPath: sourcePath) else { return sourcePath }

        let width = max(1, Int(pixelSize.width.rounded(.up)))
        let height = max(1, Int(pixelSize.height.rounded(.up)))
        let cacheKey = thumbnailKey(for: sourcePath, width: width, height: height)
        let cachedURL = thumbnailDir.appendingPathComponent(cacheKey)

        if fm.fileExists(atPath: cachedURL.path) {
            return cachedURL.path
        }

        guard let thumbnail = downsampleImage(at: sourcePath, maxPixelSize: max(width, height)) else {
            return sourcePath
        }

        saveJPEG(thumbnail, to: cachedURL)
        return fm.fileExists(atPath: cachedURL.path) ? cachedURL.path : sourcePath
    }

    /// Pre-populate first-row grid thumbnails. Runs on a background queue.
    /// Idempotent — skips thumbnails that are already cached.
    // TODO: stopgap
    func populateCache(movieItems: [MediaItem], tvItems: [MediaItem]) {
        DispatchQueue.global(qos: .utility).async { [self] in
            let start = CFAbsoluteTimeGetCurrent()
            var count = 0

            for path in firstRowPosterPaths(movieItems: movieItems, tvItems: tvItems) {
                count += thumbnailIfNeeded(path, pixelSize: Self.gridPosterThumbnailPixelSize)
            }

            let elapsed = CFAbsoluteTimeGetCurrent() - start
            MarqueeLogger.cache.info("Artwork thumbnail cache preheated: \(count) files in \(String(format: "%.1f", elapsed))s")
        }
    }

    /// Pre-populate the artwork needed for the first home paint.
    /// Runs on a background queue and skips thumbnails already on disk.
    func populateHomeArtwork(heroItems: [MediaItem], firstRowItems: [MediaItem]) {
        DispatchQueue.global(qos: .utility).async { [self] in
            let start = CFAbsoluteTimeGetCurrent()
            var count = 0
            let countLock = NSLock()
            var jobs: [(String?, CGSize)] = []

            for item in heroItems.prefix(Self.homeBackdropPreloadLimit) {
                jobs.append((item.displayBackdropPath, Self.homeHeroBackdropThumbnailPixelSize))
                jobs.append((item.displayPosterPath, Self.gridPosterThumbnailPixelSize))
            }

            for item in firstRowItems.prefix(Self.homePosterPreloadLimit) {
                jobs.append((item.gridPosterPath, Self.gridPosterThumbnailPixelSize))
            }

            for job in jobs {
                let created = preloadThumbnail(job.0, pixelSize: job.1)
                if created > 0 {
                    countLock.lock()
                    count += created
                    countLock.unlock()
                }
            }

            let elapsed = CFAbsoluteTimeGetCurrent() - start
            let elapsedText = String(format: "%.1f", elapsed)
            MarqueeLogger.cache.info("Home artwork cache preheated: \(count, privacy: .public) files in \(elapsedText, privacy: .public)s")
        }
    }

    /// Preload the poster thumbnails about to be painted by a narrow result set.
    /// This warms memory for already-cached thumbnails and creates missing
    /// thumbnails off the main thread without expanding the visible UI.
    func preloadVisiblePosters(paths: [String?], pixelSize: CGSize, label: String) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let start = CFAbsoluteTimeGetCurrent()
            var count = 0

            for path in paths {
                count += preloadThumbnail(path, pixelSize: pixelSize)
            }

            let elapsed = CFAbsoluteTimeGetCurrent() - start
            let elapsedText = String(format: "%.1f", elapsed)
            MarqueeLogger.cache.info("Visible poster cache preheated for \(label, privacy: .public): \(count, privacy: .public) files in \(elapsedText, privacy: .public)s")
        }
    }

    /// Wipe the entire artwork cache. Call on library path change.
    // TODO: stopgap
    func resetArtworkCache() {
        try? fm.removeItem(at: cacheDir)
        try? fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: thumbnailDir, withIntermediateDirectories: true)
        MarqueeLogger.cache.info("Artwork cache reset")
    }

    // MARK: - Private

    private func isExternalPath(_ path: String) -> Bool {
        let localSupport = Configuration.localAppSupportDirectory.path
        let cachesDir = Configuration.appCacheDirectory.path
        let tempDir = NSTemporaryDirectory()

        if path.hasPrefix(localSupport) { return false }
        if path.hasPrefix(cachesDir) { return false }
        if path.hasPrefix(tempDir) { return false }
        if path.hasPrefix(NSHomeDirectory()) { return false }

        return true
    }

    private func stableKey(for path: String) -> String {
        let ext = (path as NSString).pathExtension
        return "\(hashKey(for: path)).\(ext.isEmpty ? "jpg" : ext)"
    }

    private func thumbnailKey(for path: String, width: Int, height: Int) -> String {
        let source = "\(path)|\(sourceFingerprint(for: path))|\(width)x\(height)"
        return "\(hashKey(for: source)).jpg"
    }

    private func hashKey(for value: String) -> String {
        var hash: UInt64 = 5381
        for byte in value.utf8 {
            hash = ((hash &<< 5) &+ hash) &+ UInt64(byte)
        }
        return String(hash, radix: 16)
    }

    private func sourceFingerprint(for path: String) -> String {
        guard let attributes = try? fm.attributesOfItem(atPath: path) else {
            return "missing"
        }
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        return "\(Int(modified))-\(size)"
    }

    private func firstRowPosterPaths(movieItems: [MediaItem], tvItems: [MediaItem]) -> [String] {
        var paths: [String] = []
        paths.reserveCapacity(32)

        for item in movieItems.prefix(24) {
            if let path = item.gridPosterPath {
                paths.append(path)
            }
        }

        var seenShows = Set<String>()
        for item in tvItems {
            guard let showName = item.showName, seenShows.insert(showName).inserted else { continue }
            if let path = item.gridShowPosterPath {
                paths.append(path)
            }
            if seenShows.count >= 24 { break }
        }

        return paths
    }

    private func thumbnailIfNeeded(_ path: String?, pixelSize: CGSize) -> Int {
        guard let path else { return 0 }
        let sourcePath = localPath(for: path)
        let width = max(1, Int(pixelSize.width.rounded(.up)))
        let height = max(1, Int(pixelSize.height.rounded(.up)))
        let cacheKey = thumbnailKey(for: sourcePath, width: width, height: height)
        let cachedURL = thumbnailDir.appendingPathComponent(cacheKey)

        guard !fm.fileExists(atPath: cachedURL.path) else { return 0 }
        guard fm.fileExists(atPath: sourcePath) else { return 0 }
        guard let thumbnail = downsampleImage(at: sourcePath, maxPixelSize: max(width, height)) else { return 0 }

        saveJPEG(thumbnail, to: cachedURL)
        return fm.fileExists(atPath: cachedURL.path) ? 1 : 0
    }

    private func preloadThumbnail(_ path: String?, pixelSize: CGSize) -> Int {
        guard let path else { return 0 }
        let sourcePath = localPath(for: path)
        let width = max(1, Int(pixelSize.width.rounded(.up)))
        let height = max(1, Int(pixelSize.height.rounded(.up)))
        let cacheKey = thumbnailKey(for: sourcePath, width: width, height: height)
        let cachedURL = thumbnailDir.appendingPathComponent(cacheKey)

        let created = thumbnailIfNeeded(path, pixelSize: pixelSize)
        let resolvedPath = fm.fileExists(atPath: cachedURL.path) ? cachedURL.path : sourcePath
        guard let image = NSImage(contentsOfFile: resolvedPath),
              image.size.width > 0,
              image.size.height > 0 else {
            return created
        }

        ImageMemoryCache.shared.set(image, for: resolvedPath)
        ImageMemoryCache.shared.set(image, for: "\(path)|\(width)x\(height)")
        return created
    }

    private func downsampleImage(at path: String, maxPixelSize: Int) -> NSImage? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, nil) else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        return NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        )
    }

    private func saveJPEG(_ image: NSImage, to url: URL) {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return
        }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let data = bitmap.representation(
            using: .jpeg,
            properties: [.compressionFactor: 0.86]
        ) else {
            return
        }

        do {
            try data.write(to: url, options: .atomic)
        } catch {
            MarqueeLogger.cache.error("Failed to save artwork thumbnail \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }
}
