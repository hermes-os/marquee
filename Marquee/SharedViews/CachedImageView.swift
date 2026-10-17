import SwiftUI
import AppKit

enum CachedImageLoadState: Equatable {
    case loading
    case ready
    case terminalFallback
}

struct CachedImageLoadStateMachine {
    struct Request: Equatable {
        let path: String?
        let width: Int
        let height: Int

        init(path: String?, thumbnailPixelSize: CGSize?) {
            self.path = path
            width = thumbnailPixelSize.map { max(0, Int($0.width.rounded(.up))) } ?? 0
            height = thumbnailPixelSize.map { max(0, Int($0.height.rounded(.up))) } ?? 0
        }
    }

    private(set) var request: Request?
    private(set) var generation = 0
    private(set) var state: CachedImageLoadState = .terminalFallback

    @discardableResult
    mutating func begin(request: Request) -> Int {
        generation &+= 1
        self.request = request
        state = request.path == nil ? .terminalFallback : .loading
        return generation
    }

    @discardableResult
    mutating func complete(
        request: Request,
        generation: Int,
        imageAvailable: Bool
    ) -> Bool {
        guard self.generation == generation,
              self.request == request else { return false }
        state = imageAvailable ? .ready : .terminalFallback
        return true
    }

    mutating func cancel(generation: Int) {
        guard self.generation == generation else { return }
        self.generation &+= 1
        state = .terminalFallback
    }
}

struct CachedImagePlaceholderPresentation: Equatable {
    let iconOpacity: Double
    let wordmarkOpacity: Double

    static func resolve(
        explicitIconOpacity: Double?,
        isTerminalFallback: Bool
    ) -> CachedImagePlaceholderPresentation {
        CachedImagePlaceholderPresentation(
            iconOpacity: explicitIconOpacity ?? (isTerminalFallback ? 0.32 : 0.18),
            wordmarkOpacity: explicitIconOpacity ?? 0.34
        )
    }
}

// MARK: - Cached Image View

struct CachedImageView: View {
    let path: String?
    var contentMode: SwiftUI.ContentMode = .fill
    var thumbnailPixelSize: CGSize?
    var placeholderFillOpacity: Double = 1.0
    var placeholderIconOpacity: Double?
    var onLoadStateChange: (CachedImageLoadState) -> Void = { _ in }

    @State private var image: NSImage?
    @State private var loadedIdentity: ImageRequestIdentity?
    @State private var loadToken: ImageLoadToken?
    @State private var loadFailed: Bool = false
    @State private var loadStateMachine = CachedImageLoadStateMachine()
    @Environment(\.leanBackMode) private var leanBackMode

    var body: some View {
        Group {
            if let image = image,
               loadedIdentity == requestIdentity,
               image.size.width > 0,
               image.size.height > 0 {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                placeholder
            }
        }
        .clipped()
        .onAppear { loadImage() }
        .onChange(of: path) { _ in loadImage() }
        .onChange(of: thumbnailPixelSize) { _ in loadImage() }
        .onDisappear {
            loadToken?.cancel()
            loadToken = nil
        }
    }

    private var placeholder: some View {
        let isTerminalFallback = path == nil || loadFailed
        let presentation = CachedImagePlaceholderPresentation.resolve(
            explicitIconOpacity: placeholderIconOpacity,
            isTerminalFallback: isTerminalFallback
        )

        return RoundedRectangle(cornerRadius: 8)
            .fill(MarqueeTheme.surfaceElevated.opacity(placeholderFillOpacity))
            .overlay(
                VStack(spacing: MarqueeTheme.scaled(6, leanBack: 9, isLeanBack: leanBackMode)) {
                    Image(systemName: isTerminalFallback ? "film" : "photo")
                        .font(.system(size: MarqueeTheme.scaled(22, leanBack: 32, isLeanBack: leanBackMode), weight: .ultraLight))
                        .foregroundColor(MarqueeTheme.textTertiary.opacity(presentation.iconOpacity))
                    Text("MARQUEE")
                        .font(.system(size: MarqueeTheme.scaled(8, leanBack: 11, isLeanBack: leanBackMode), weight: .semibold))
                        .tracking(MarqueeTheme.scaled(1.8, leanBack: 2.4, isLeanBack: leanBackMode))
                        .foregroundColor(MarqueeTheme.accentSecondary.opacity(presentation.wordmarkOpacity))
                }
        )
    }

    private var requestIdentity: ImageRequestIdentity {
        ImageRequestIdentity(path: path, thumbnailPixelSize: thumbnailPixelSize)
    }

    private func loadImage() {
        loadToken?.cancel()
        loadToken = nil
        loadFailed = false
        image = nil
        loadedIdentity = nil

        let stateRequest = CachedImageLoadStateMachine.Request(
            path: path,
            thumbnailPixelSize: thumbnailPixelSize
        )
        let loadGeneration = loadStateMachine.begin(request: stateRequest)
        onLoadStateChange(loadStateMachine.state)

        guard let requestedPath = path else {
            return
        }

        let requestedThumbnailSize = thumbnailPixelSize
        let requestedIdentity = requestIdentity

        if let cached = ImageDecodePipeline.shared.memoryCachedImage(
            path: requestedPath,
            thumbnailPixelSize: requestedThumbnailSize
        ) {
            guard loadStateMachine.complete(
                request: stateRequest,
                generation: loadGeneration,
                imageAvailable: true
            ) else { return }
            image = cached
            loadedIdentity = requestedIdentity
            onLoadStateChange(loadStateMachine.state)
            return
        }

        loadToken = ImageDecodePipeline.shared.load(
            path: requestedPath,
            thumbnailPixelSize: requestedThumbnailSize
        ) { loaded in
            guard self.path == requestedPath,
                  self.thumbnailPixelSize == requestedThumbnailSize,
                  self.requestIdentity == requestedIdentity else { return }
            guard self.loadStateMachine.complete(
                request: stateRequest,
                generation: loadGeneration,
                imageAvailable: loaded != nil
            ) else { return }
            self.image = loaded
            self.loadedIdentity = loaded == nil ? nil : requestedIdentity
            self.loadFailed = loaded == nil
            self.onLoadStateChange(self.loadStateMachine.state)
        }
    }
}

private struct ImageRequestIdentity: Equatable {
    let path: String?
    let width: Int
    let height: Int

    init(path: String?, thumbnailPixelSize: CGSize?) {
        self.path = path
        self.width = thumbnailPixelSize.map { max(0, Int($0.width.rounded(.up))) } ?? 0
        self.height = thumbnailPixelSize.map { max(0, Int($0.height.rounded(.up))) } ?? 0
    }
}

// MARK: - Image Decode Pipeline

final class ImageLoadToken {
    private let lock = NSLock()
    private var isCancelled = false
    private var cancelHandler: (() -> Void)?

    init(cancelHandler: @escaping () -> Void) {
        self.cancelHandler = cancelHandler
    }

    func cancel() {
        let handler: (() -> Void)?
        lock.lock()
        if isCancelled {
            handler = nil
        } else {
            isCancelled = true
            handler = cancelHandler
            cancelHandler = nil
        }
        lock.unlock()
        handler?()
    }

    deinit {
        cancel()
    }
}

final class ImageDecodePipeline {
    typealias ResolvePath = (String, CGSize?) -> String
    typealias DecodeImage = (String) -> NSImage?

    static let shared = ImageDecodePipeline(
        resolvePath: { path, thumbnailSize in
            if let thumbnailSize {
                return ArtworkCache.shared.thumbnailPath(for: path, pixelSize: thumbnailSize)
            }
            return ArtworkCache.shared.localPath(for: path)
        },
        decode: { resolvedPath in
            guard let loaded = NSImage(contentsOfFile: resolvedPath),
                  loaded.size.width > 0,
                  loaded.size.height > 0 else {
                return nil
            }
            return loaded
        }
    )

    private struct RequestKey: Hashable {
        let sourcePath: String
        let width: Int
        let height: Int

        init(path: String, thumbnailPixelSize: CGSize?) {
            sourcePath = path
            width = thumbnailPixelSize.map { max(0, Int($0.width.rounded(.up))) } ?? 0
            height = thumbnailPixelSize.map { max(0, Int($0.height.rounded(.up))) } ?? 0
        }

        var cacheKey: String {
            "\(sourcePath)|\(width)x\(height)"
        }
    }

    private struct Completion {
        let id: UUID
        let callbackQueue: DispatchQueue
        let body: (NSImage?) -> Void
    }

    private final class InFlight {
        var completions: [UUID: Completion] = [:]
    }

    private let resolvePath: ResolvePath
    private let decode: DecodeImage
    private let workQueue: DispatchQueue
    private let lock = NSLock()
    private var inFlight: [RequestKey: InFlight] = [:]
    private let metricsLock = NSLock()
    private var cacheHitCount = 0
    private var cacheMissCount = 0
    private var decodeSuccessCount = 0
    private var decodeFailureCount = 0
    private var totalDecodeSeconds: TimeInterval = 0

    private init(
        resolvePath: @escaping ResolvePath,
        decode: @escaping DecodeImage,
        workQueue: DispatchQueue = DispatchQueue(label: "com.marquee.image-decode", qos: .userInitiated, attributes: .concurrent)
    ) {
        self.resolvePath = resolvePath
        self.decode = decode
        self.workQueue = workQueue
    }

    func diagnostics() -> ImagePipelineDiagnostics {
        metricsLock.lock()
        let hits = cacheHitCount
        let misses = cacheMissCount
        let successes = decodeSuccessCount
        let failures = decodeFailureCount
        let totalSeconds = totalDecodeSeconds
        metricsLock.unlock()

        let decodeCount = successes + failures
        return ImagePipelineDiagnostics(
            memoryCacheCount: ImageMemoryCache.shared.approximateCount,
            cacheHits: hits,
            cacheMisses: misses,
            decodeSuccesses: successes,
            decodeFailures: failures,
            averageDecodeMilliseconds: decodeCount > 0
                ? (totalSeconds / Double(decodeCount)) * 1000.0
                : 0,
            memoryPressureClears: ImageMemoryCache.shared.memoryPressureClearCount
        )
    }

    func memoryCachedImage(path: String, thumbnailPixelSize: CGSize?) -> NSImage? {
        let key = RequestKey(path: path, thumbnailPixelSize: thumbnailPixelSize)
        return ImageMemoryCache.shared.get(key.cacheKey)
    }

    func load(
        path: String,
        thumbnailPixelSize: CGSize?,
        callbackQueue: DispatchQueue = .main,
        completion: @escaping (NSImage?) -> Void
    ) -> ImageLoadToken {
        let key = RequestKey(path: path, thumbnailPixelSize: thumbnailPixelSize)
        let completionID = UUID()
        let completionBox = Completion(id: completionID, callbackQueue: callbackQueue, body: completion)

        lock.lock()
        if let existing = inFlight[key] {
            existing.completions[completionID] = completionBox
            lock.unlock()
            return ImageLoadToken { [weak self] in
                self?.cancel(completionID: completionID, for: key)
            }
        }

        let fresh = InFlight()
        fresh.completions[completionID] = completionBox
        inFlight[key] = fresh
        lock.unlock()

        workQueue.async { [weak self] in
            self?.performLoad(path: path, thumbnailPixelSize: thumbnailPixelSize, key: key)
        }

        return ImageLoadToken { [weak self] in
            self?.cancel(completionID: completionID, for: key)
        }
    }

    private func performLoad(path: String, thumbnailPixelSize: CGSize?, key: RequestKey) {
        let resolvedPath = resolvePath(path, thumbnailPixelSize)
        let image: NSImage?
        if let cached = ImageMemoryCache.shared.get(key.cacheKey) {
            recordCacheHit()
            image = cached
        } else if let cached = ImageMemoryCache.shared.get(resolvedPath) {
            recordCacheHit()
            image = cached
            ImageMemoryCache.shared.set(cached, for: key.cacheKey)
        } else {
            recordCacheMiss()
            let start = CFAbsoluteTimeGetCurrent()
            if let loaded = decode(resolvedPath) {
                recordDecode(seconds: CFAbsoluteTimeGetCurrent() - start, succeeded: true)
                image = loaded
                ImageMemoryCache.shared.set(loaded, for: resolvedPath)
                ImageMemoryCache.shared.set(loaded, for: key.cacheKey)
            } else {
                recordDecode(seconds: CFAbsoluteTimeGetCurrent() - start, succeeded: false)
                image = nil
            }
        }

        let completions: [Completion]
        lock.lock()
        if let request = inFlight.removeValue(forKey: key) {
            completions = Array(request.completions.values)
        } else {
            completions = []
        }
        lock.unlock()

        for completion in completions {
            completion.callbackQueue.async {
                completion.body(image)
            }
        }
    }

    private func cancel(completionID: UUID, for key: RequestKey) {
        lock.lock()
        if let request = inFlight[key] {
            request.completions.removeValue(forKey: completionID)
            if request.completions.isEmpty {
                inFlight.removeValue(forKey: key)
            }
        }
        lock.unlock()
    }

    private func recordCacheHit() {
        metricsLock.lock()
        cacheHitCount += 1
        metricsLock.unlock()
    }

    private func recordCacheMiss() {
        metricsLock.lock()
        cacheMissCount += 1
        metricsLock.unlock()
    }

    private func recordDecode(seconds: TimeInterval, succeeded: Bool) {
        metricsLock.lock()
        totalDecodeSeconds += max(0, seconds)
        if succeeded {
            decodeSuccessCount += 1
        } else {
            decodeFailureCount += 1
        }
        metricsLock.unlock()
    }

    #if DEBUG
    static func makeForHarness(
        resolvePath: @escaping ResolvePath,
        decode: @escaping DecodeImage
    ) -> ImageDecodePipeline {
        ImageDecodePipeline(
            resolvePath: resolvePath,
            decode: decode,
            workQueue: DispatchQueue(label: "com.marquee.image-decode.verify", qos: .userInitiated, attributes: .concurrent)
        )
    }
    #endif
}

struct ImagePipelineDiagnostics: Codable {
    let memoryCacheCount: Int
    let cacheHits: Int
    let cacheMisses: Int
    let decodeSuccesses: Int
    let decodeFailures: Int
    let averageDecodeMilliseconds: Double
    let memoryPressureClears: Int
}

// MARK: - Image Memory Cache

final class ImageMemoryCache {
    static let shared = ImageMemoryCache()

    private let cache = NSCache<NSString, NSImage>()
    private let lock = NSLock()
    private var keys = Set<String>()
    private var pressureClearCount = 0
    private var pressureSource: DispatchSourceMemoryPressure?

    private init() {
        cache.countLimit = 200
        cache.totalCostLimit = 300 * 1024 * 1024
        installMemoryPressureHandler()
    }

    var approximateCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return keys.count
    }

    var memoryPressureClearCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pressureClearCount
    }

    func get(_ key: String) -> NSImage? {
        cache.object(forKey: key as NSString)
    }

    func set(_ image: NSImage, for key: String) {
        let cost = Int(image.size.width * image.size.height * 4)
        cache.setObject(image, forKey: key as NSString, cost: cost)
        lock.lock()
        keys.insert(key)
        lock.unlock()
    }

    func remove(_ key: String) {
        cache.removeObject(forKey: key as NSString)
        lock.lock()
        keys.remove(key)
        lock.unlock()
    }

    func removeAll() {
        cache.removeAllObjects()
        lock.lock()
        keys.removeAll()
        lock.unlock()
    }

    private func installMemoryPressureHandler() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            self?.clearForMemoryPressure()
        }
        source.resume()
        pressureSource = source
    }

    private func clearForMemoryPressure() {
        cache.removeAllObjects()
        lock.lock()
        keys.removeAll()
        pressureClearCount += 1
        lock.unlock()
        MarqueeLogger.cache.info("Image memory cache cleared under memory pressure")
    }
}
