import Foundation
import AppKit

// MARK: - Image Cache Service

final class ImageCacheService {

    static let shared = ImageCacheService()

    private let imageDir: URL
    private let thumbDir: URL

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config)
    }()

    private let thumbPosterWidth: CGFloat = 300
    private let thumbBackdropWidth: CGFloat = 800

    private init() {
        let appCache = Configuration.appCacheDirectory

        imageDir = appCache.appendingPathComponent("images")
        thumbDir = appCache.appendingPathComponent("thumbs")

        try? FileManager.default.createDirectory(at: imageDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: thumbDir, withIntermediateDirectories: true)
    }

    // MARK: - Path Lookups

    func cachedPosterPath(tmdbID: Int) -> String? {
        let path = imageDir.appendingPathComponent("\(tmdbID)-poster.jpg").path
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    func cachedBackdropPath(tmdbID: Int) -> String? {
        let path = imageDir.appendingPathComponent("\(tmdbID)-backdrop.jpg").path
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    func cachedThumbPosterPath(tmdbID: Int) -> String? {
        let path = thumbDir.appendingPathComponent("\(tmdbID)-poster-thumb.jpg").path
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    func cachedThumbBackdropPath(tmdbID: Int) -> String? {
        let path = thumbDir.appendingPathComponent("\(tmdbID)-backdrop-thumb.jpg").path
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    // MARK: - Download and Cache

    func downloadAndCacheImages(tmdbID: Int, posterPath: String?, backdropPath: String?, forceRedownload: Bool = false) async {
        guard UserSettings.shared.onlineMetadataEnabled else { return }

        await withTaskGroup(of: Void.self) { group in
            if let posterPath = posterPath,
               forceRedownload
                || cachedPosterPath(tmdbID: tmdbID) == nil
                || cachedThumbPosterPath(tmdbID: tmdbID) == nil {
                group.addTask {
                    await self.downloadAndSave(
                        tmdbPath: posterPath,
                        size: Configuration.posterDownloadSize,
                        saveTo: self.imageDir.appendingPathComponent("\(tmdbID)-poster.jpg"),
                        thumbSaveTo: self.thumbDir.appendingPathComponent("\(tmdbID)-poster-thumb.jpg"),
                        thumbWidth: self.thumbPosterWidth
                    )
                }
            }

            if let backdropPath = backdropPath,
               forceRedownload
                || cachedBackdropPath(tmdbID: tmdbID) == nil
                || cachedThumbBackdropPath(tmdbID: tmdbID) == nil {
                group.addTask {
                    await self.downloadAndSave(
                        tmdbPath: backdropPath,
                        size: Configuration.backdropDownloadSize,
                        saveTo: self.imageDir.appendingPathComponent("\(tmdbID)-backdrop.jpg"),
                        thumbSaveTo: self.thumbDir.appendingPathComponent("\(tmdbID)-backdrop-thumb.jpg"),
                        thumbWidth: self.thumbBackdropWidth
                    )
                }
            }
        }
    }

    func downloadEpisodeStill(tmdbID: Int, seasonNumber: Int, episodeNumber: Int, stillPath: String) async -> String? {
        let key = "\(tmdbID)-s\(seasonNumber)e\(episodeNumber)"
        let saveTo = imageDir.appendingPathComponent("\(key)-still.jpg")
        let thumbSaveTo = thumbDir.appendingPathComponent("\(key)-still-thumb.jpg")

        if FileManager.default.fileExists(atPath: thumbSaveTo.path) {
            return thumbSaveTo.path
        }

        guard UserSettings.shared.onlineMetadataEnabled else { return nil }

        await downloadAndSave(
            tmdbPath: stillPath,
            size: Configuration.backdropDownloadSize,
            saveTo: saveTo,
            thumbSaveTo: thumbSaveTo,
            thumbWidth: thumbBackdropWidth
        )

        return FileManager.default.fileExists(atPath: thumbSaveTo.path) ? thumbSaveTo.path : nil
    }

    func generateThumbFromSidecar(sidecarPath: String, tmdbID: Int, type: String) -> String? {
        let thumbPath = thumbDir.appendingPathComponent("\(tmdbID)-\(type)-thumb.jpg")
        guard !FileManager.default.fileExists(atPath: thumbPath.path) else {
            return thumbPath.path
        }
        guard let image = NSImage(contentsOfFile: sidecarPath) else {
            MarqueeLogger.cache.error("Failed to load sidecar image at: \(sidecarPath)")
            return nil
        }
        let targetWidth = type == "poster" ? thumbPosterWidth : thumbBackdropWidth
        guard let resized = downsample(image: image, toWidth: targetWidth) else {
            MarqueeLogger.cache.error("Failed to generate thumbnail from sidecar: \(sidecarPath)")
            return nil
        }
        saveJPEG(resized, to: thumbPath)
        return thumbPath.path
    }

    func saveThumbnailFromFrame(_ image: NSImage, identifier: String) -> String? {
        let thumbPath = thumbDir.appendingPathComponent("\(identifier)-frame-thumb.jpg")
        guard !FileManager.default.fileExists(atPath: thumbPath.path) else {
            return thumbPath.path
        }
        guard let resized = downsample(image: image, toWidth: thumbPosterWidth) else {
            MarqueeLogger.cache.error("Failed to generate frame thumbnail for: \(identifier)")
            return nil
        }
        saveJPEG(resized, to: thumbPath)
        return thumbPath.path
    }

    // MARK: - Private

    private func downloadAndSave(tmdbPath: String, size: String, saveTo: URL, thumbSaveTo: URL, thumbWidth: CGFloat) async {
        let components = URLComponents(string: "\(Configuration.tmdbImageBaseURL)/\(size)\(tmdbPath)")
        guard let url = components?.url else {
            MarqueeLogger.cache.error("Failed to build image URL for: \(tmdbPath)")
            return
        }
        guard let (data, _) = try? await session.data(from: url) else {
            MarqueeLogger.cache.error("Failed to download image: \(tmdbPath)")
            return
        }
        guard let image = NSImage(data: data) else {
            MarqueeLogger.cache.error("Failed to create image from downloaded data: \(tmdbPath)")
            return
        }

        saveJPEG(image, to: saveTo)

        if let thumb = downsample(image: image, toWidth: thumbWidth) {
            saveJPEG(thumb, to: thumbSaveTo)
        }
    }

    private func downsample(image: NSImage, toWidth targetWidth: CGFloat) -> NSImage? {
        var proposedRect = NSRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
            return nil
        }

        let originalWidth = CGFloat(cgImage.width)
        let originalHeight = CGFloat(cgImage.height)
        guard originalWidth > 0, originalHeight > 0 else { return nil }

        let scale = targetWidth / originalWidth
        let pixelWidth = max(1, Int(targetWidth.rounded()))
        let pixelHeight = max(1, Int((originalHeight * scale).rounded()))

        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))

        guard let scaledImage = context.makeImage() else { return nil }
        return NSImage(cgImage: scaledImage, size: NSSize(width: pixelWidth, height: pixelHeight))
    }

    private func saveJPEG(_ image: NSImage, to url: URL) {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else { return }
        try? jpeg.write(to: url)
    }
}
