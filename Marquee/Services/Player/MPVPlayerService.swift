import AppKit
import AVFoundation
import Combine
import Darwin
import Foundation
import IOKit.pwr_mgt
import Libmpv
import os

// MARK: - MPVPlayerService

final class PlaybackClockModel: ObservableObject {
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0

    private var lastPublishedTime: Double = 0
    private var lastPublishedDuration: Double = 0
    private let minimumTimeDelta: Double = 0.20

    func update(currentTime: Double, duration: Double) {
        if Thread.isMainThread {
            apply(currentTime: currentTime, duration: duration)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.apply(currentTime: currentTime, duration: duration)
            }
        }
    }

    private func apply(currentTime: Double, duration: Double) {
        let durationChanged = abs(duration - lastPublishedDuration) > 0.01
        let timeChanged = abs(currentTime - lastPublishedTime) >= minimumTimeDelta
            || currentTime == 0
            || currentTime < lastPublishedTime

        guard durationChanged || timeChanged else { return }

        lastPublishedDuration = duration
        lastPublishedTime = currentTime
        self.duration = duration
        self.currentTime = currentTime
    }
}

class MPVPlayerService: ObservableObject, PlayerServiceProtocol {

    // MARK: - Published State

    let clock = PlaybackClockModel()
    private(set) var currentTime: Double = 0 {
        didSet { clock.update(currentTime: currentTime, duration: duration) }
    }
    private(set) var duration: Double = 0 {
        didSet { clock.update(currentTime: currentTime, duration: duration) }
    }
    @Published private(set) var isPaused: Bool = true {
        didSet { updateDisplaySleepAssertion() }
    }
    @Published private(set) var volume: Double = 100
    @Published private(set) var isMuted: Bool = false
    @Published private(set) var subtitlesEnabled: Bool = true
    @Published private(set) var hasSubtitles: Bool = false
    @Published private(set) var availableAudioTracks: [AudioTrack] = []
    @Published private(set) var currentAudioTrack: AudioTrack? = nil
    @Published private(set) var playbackSpeed: Float = 1.0
    @Published private(set) var availableSubtitleTracks: [SubtitleTrack] = []
    @Published private(set) var currentSubtitleTrack: SubtitleTrack? = nil
    @Published private(set) var currentSubtitleEntries: [SubtitleEntry] = []
    @Published private(set) var lifecycleState: PlaybackLifecycleState = .idle {
        didSet { updateDisplaySleepAssertion() }
    }
    @Published private(set) var playbackErrorMessage: String? = nil
    @Published private(set) var preparationMessage: String? = nil
    @Published private(set) var playbackNotice: String? = nil
    @Published private(set) var playbackBackendDescription: String = "none"
    @Published private(set) var supportsPlaybackSpeed: Bool = true

    // MARK: - Callbacks

    var onPlaybackEnded: (() -> Void)?

    // MARK: - mpv state

    private(set) var mpv: OpaquePointer?
    private(set) var renderContext: OpaquePointer?
    fileprivate weak var renderView: MPVOGLView?
    private enum PlaybackBackend {
        case none
        case avFoundationDirect
        case avFoundationPrepared
        case externalFFplay
        case ffmpegEmbedded
        case mpv

        var description: String {
            switch self {
            case .none:
                return "none"
            case .avFoundationDirect:
                return "avfoundation"
            case .avFoundationPrepared:
                return "prepared-avfoundation"
            case .externalFFplay:
                return "external-ffplay"
            case .ffmpegEmbedded:
                return "ffmpeg-embedded"
            case .mpv:
                return "mpv"
            }
        }

        var usesAVFoundation: Bool {
            switch self {
            case .avFoundationDirect, .avFoundationPrepared:
                return true
            case .none, .externalFFplay, .ffmpegEmbedded, .mpv:
                return false
            }
        }
    }
    private enum PlaybackRoute {
        case avFoundation
        case preparedAVFoundation
        case externalFFplay
        case ffmpegEmbedded
        case mpv
        case unsupported
    }
    private var activeBackend: PlaybackBackend = .none
    private var displaySleepAssertionID = IOPMAssertionID(0)
    private let displaySleepAssertionLock = NSLock()
    private var isInitialized = false
    private let mpvQueue = DispatchQueue(label: "com.marquee.mpv.serial", qos: .userInteractive)
    private let mpvQueueKey = DispatchSpecificKey<Void>()
    private var stateMachine = PlaybackStateMachine()
    private var pendingLoadPath: String?
    private var loadGeneration = 0
    private var awaitingStartFile = false
    private var emittedPlaybackEndedGeneration: Int?
    private var isStopping = false
    private var externalSubtitleTracks: [SubtitleTrack] = []
    private let avPlayer = AVPlayer()
    private var avTimeObserver: Any?
    private var avEndObserver: Any?
    private var avCancellables = Set<AnyCancellable>()
    private var avItemCancellables = Set<AnyCancellable>()
    private var avSavedSpeed: Float = 1.0
    private let remuxQueue = DispatchQueue(label: "com.marquee.player.prepare", qos: .utility)
    private let preparationLock = NSLock()
    private var activePreparation: FFmpegPreparationRun?
    private var remuxedPlaybackURL: URL?
    private var externalPlayerProcess: Process?
    private var externalPlayerStderr = BoundedPipeCapture(maxBytes: 128 * 1024)
    private var externalPlaybackTimer: Timer?
    private var externalPlaybackPath: String?
    private var externalPlaybackSubtitles: [SubtitleTrack] = []
    private var externalPlaybackStartOffset: Double = 0
    private var externalPlaybackStartedAt: Date?
    private var externalPauseStartedAt: Date?
    private var externalPlaybackIsRelaunching = false
    private var embeddedVideoProcess: Process?
    private var embeddedVideoStderr = BoundedPipeCapture(maxBytes: 64 * 1024)
    private let embeddedFrameQueue = DispatchQueue(label: "com.marquee.player.ffmpeg-frames", qos: .userInteractive)
    private var embeddedPlaybackPath: String?
    private var embeddedPlaybackSubtitles: [SubtitleTrack] = []
    private var embeddedPlaybackStartOffset: Double = 0
    private var embeddedPlaybackTimer: Timer?
    private var embeddedPlaybackHasAudio = true
    private var embeddedAudioOutputActive = false
    private var embeddedPresenter: EmbeddedPlaybackPresenter?
    private var embeddedAwaitingDrain = false
    private var embeddedFrameRateCache: (path: String, fps: Double)?
    private var embeddedPlaybackRunID = 0
    private let embeddedDurationProbeLock = NSLock()
    private var embeddedDurationProbeEpoch = 0
    private var embeddedDurationProbeHandle: EmbeddedDurationProbeHandle?
    private var subtitleSelectionGeneration = 0

#if DEBUG
    private var subtitleParseDelayForHarness: TimeInterval = 0
#endif

    private let maxPreparedMediaCacheBytes: UInt64 = 50 * 1024 * 1024 * 1024
    private let targetPreparedMediaCacheBytes: UInt64 = 40 * 1024 * 1024 * 1024
    private let minimumPreparedMediaFreeBytes: UInt64 = 5 * 1024 * 1024 * 1024
    private let maxPreparationDuration: TimeInterval = 30 * 60
    private let maxProbeDuration: TimeInterval = 8

    // MARK: - Init / Deinit

    init() {
        mpvQueue.setSpecific(key: mpvQueueKey, value: ())
        setupAVPlayerObservers()
        applyLifecycleEvent(.prepare)
    }

    deinit {
        shutdown()
    }

    // MARK: - AVFoundation Backend

    private func setupAVPlayerObservers() {
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        avTimeObserver = avPlayer.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { [weak self] time in
            guard time.seconds.isFinite else { return }
            self?.currentTime = time.seconds
        }

        avPlayer.publisher(for: \.rate)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] rate in
                guard let self, self.activeBackend.usesAVFoundation else { return }
                self.isPaused = (rate == 0)
            }
            .store(in: &avCancellables)

        avPlayer.publisher(for: \.volume)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] volume in
                guard let self, self.activeBackend.usesAVFoundation else { return }
                self.volume = Double(volume) * 100.0
            }
            .store(in: &avCancellables)

        avPlayer.publisher(for: \.isMuted)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isMuted in
                guard let self, self.activeBackend.usesAVFoundation else { return }
                self.isMuted = isMuted
            }
            .store(in: &avCancellables)
    }

    private func setActiveBackend(_ backend: PlaybackBackend) {
        activeBackend = backend
        playbackBackendDescription = backend.description
        supportsPlaybackSpeed = true
        MarqueeLogger.player.info("playback backend=\(backend.description, privacy: .public)")
    }

    private func playbackRoute(for path: String) -> PlaybackRoute {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "mp4", "m4v", "mov":
            return avContainerRequiresMultiformatBridge(path) ? multiformatBridgeRoute() : .avFoundation
        case "avi", "mkv", "m2ts", "mpeg", "mpg", "ts", "vob", "webm":
            if shouldUseExternalWindowFallback() {
                return .externalFFplay
            }
            if shouldUsePreparedAVFoundationFallback() || shouldUsePreparedStreamCopyBridge() {
                return .preparedAVFoundation
            }
            if shouldUseInProcessMpvFallback() {
                return shouldUseDirectMpv(for: path) ? .mpv : .unsupported
            }
            return shouldUseEmbeddedBridge() ? .ffmpegEmbedded : .unsupported
        default:
            return .unsupported
        }
    }

    private func multiformatBridgeRoute() -> PlaybackRoute {
        if shouldUseExternalWindowFallback() {
            return .externalFFplay
        }
        if shouldUsePreparedAVFoundationFallback() || shouldUsePreparedStreamCopyBridge() {
            return .preparedAVFoundation
        }
        return shouldUseEmbeddedBridge() ? .ffmpegEmbedded : .unsupported
    }

    private func avContainerRequiresMultiformatBridge(_ path: String) -> Bool {
        let asset = AVAsset(url: URL(fileURLWithPath: path))
        let videoTracks = asset.tracks(withMediaType: .video)

        guard let codec = avContainerPrimaryVideoCodecFourCC(videoTracks: videoTracks) else {
            return false
        }

        let requiresBridge = codec == "hvc1" || codec == "hev1"
        if requiresBridge {
            MarqueeLogger.player.info("routing AV container through multiformat bridge codec=\(codec, privacy: .public)")
        }
        return requiresBridge
    }

    private func avContainerPrimaryVideoCodecFourCC(videoTracks: [AVAssetTrack]) -> String? {
        guard let videoTrack = videoTracks.first,
              let rawFormatDescription = videoTrack.formatDescriptions.first else {
            return nil
        }
        guard CFGetTypeID(rawFormatDescription as CFTypeRef) == CMFormatDescriptionGetTypeID() else {
            return nil
        }
        let formatDescription = rawFormatDescription as! CMFormatDescription
        return fourCCString(CMFormatDescriptionGetMediaSubType(formatDescription))
    }

    private func fourCCString(_ code: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xff),
            UInt8((code >> 16) & 0xff),
            UInt8((code >> 8) & 0xff),
            UInt8(code & 0xff)
        ]
        return String(bytes: bytes, encoding: .ascii)?.lowercased() ?? ""
    }

    private func shouldUseDirectMpv(for path: String) -> Bool {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "mkv":
            return true
        default:
            return false
        }
    }

    private func shouldUsePreparedAVFoundationFallback() -> Bool {
        ProcessInfo.processInfo.environment["MARQUEE_ENABLE_PREPARED_AVFOUNDATION"] == "1"
    }

    private func shouldUsePreparedStreamCopyBridge() -> Bool {
        ProcessInfo.processInfo.environment["MARQUEE_ENABLE_PREPARED_STREAMCOPY_BRIDGE"] == "1"
    }

    private func shouldAllowPreparedTranscodeFallback() -> Bool {
        ProcessInfo.processInfo.environment["MARQUEE_ENABLE_PREPARED_TRANSCODE"] == "1"
    }

    private func shouldUseInProcessMpvFallback() -> Bool {
        ProcessInfo.processInfo.environment["MARQUEE_ENABLE_INPROCESS_MPV"] == "1"
    }

    private func shouldUseEmbeddedBridge() -> Bool {
        ProcessInfo.processInfo.environment["MARQUEE_DISABLE_EMBEDDED_BRIDGE"] != "1"
    }

    private func shouldUseExternalWindowFallback() -> Bool {
        ProcessInfo.processInfo.environment["MARQUEE_ENABLE_EXTERNAL_FFPLAY_WINDOW"] == "1"
    }

    private func loadAVFoundationFile(
        path: String,
        sidecarSubtitles: [SubtitleTrack],
        markLoadRequested: Bool = true,
        backend: PlaybackBackend = .avFoundationDirect,
        fallbackToEmbeddedBridge: Bool = false
    ) {
        stopExternalPlayer(markStopping: false)
        stopEmbeddedFFmpegPlayback(markStopping: false)
        shutdownMpv()
        setActiveBackend(backend)
        awaitingStartFile = false
        preparationMessage = nil
        renderView?.showAVPlayer(avPlayer)
        applyLifecycleEvent(.rendererReady)
        if markLoadRequested {
            applyLifecycleEvent(.loadRequested)
        }

        avItemCancellables.removeAll()
        if let avEndObserver {
            NotificationCenter.default.removeObserver(avEndObserver)
            self.avEndObserver = nil
        }

        let item = AVPlayerItem(url: URL(fileURLWithPath: path))
        avEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.applyLifecycleEvent(.ended)
            self.emitPlaybackEndedIfNeeded(source: "avplayer-ended")
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.advanceSubtitleSelectionGeneration()
            self.currentTime = 0
            self.duration = 0
            self.playbackSpeed = 1.0
            self.avSavedSpeed = 1.0
            self.availableAudioTracks = []
            self.currentAudioTrack = nil
            self.availableSubtitleTracks = sidecarSubtitles
            self.currentSubtitleTrack = nil
            self.currentSubtitleEntries = []
            self.subtitlesEnabled = false
            self.hasSubtitles = !sidecarSubtitles.isEmpty
            self.isMuted = false
        }

        let generation = loadGeneration

        item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak item] status in
                guard let self, let item else { return }
                switch status {
                case .readyToPlay:
                    break
                case .failed:
                    let error = item.error?.localizedDescription ?? "AVFoundation could not open this file."
                    self.handleAVFoundationLoadFailure(
                        path: path,
                        error: error,
                        generation: generation,
                        sidecarSubtitles: sidecarSubtitles,
                        fallbackToEmbeddedBridge: fallbackToEmbeddedBridge
                    )
                    return
                case .unknown:
                    return
                @unknown default:
                    self.failPlayback("Unable to load this video. AVFoundation returned an unknown item status.")
                    return
                }
                let duration = item.duration.seconds
                if duration.isFinite {
                    self.duration = duration
                }
                self.refreshAVTrackLists(for: item, sidecarSubtitles: sidecarSubtitles)
                self.applyLifecycleEvent(.fileLoaded)
            }
            .store(in: &avItemCancellables)

#if DEBUG
        if ProcessInfo.processInfo.environment["MARQUEE_FORCE_AVFOUNDATION_FAILURE"] == "1" {
            DispatchQueue.main.async { [weak self] in
                self?.handleAVFoundationLoadFailure(
                    path: path,
                    error: "forced AVFoundation failure",
                    generation: generation,
                    sidecarSubtitles: sidecarSubtitles,
                    fallbackToEmbeddedBridge: fallbackToEmbeddedBridge
                )
            }
            return
        }
#endif

        avPlayer.replaceCurrentItem(with: item)
        avPlayer.play()
        scheduleAVLoadWatchdog(generation: loadGeneration, path: path)
        MarqueeLogger.player.info("AVFoundation loadFile path=\(path, privacy: .public)")
    }

    private func handleAVFoundationLoadFailure(
        path: String,
        error: String,
        generation: Int,
        sidecarSubtitles: [SubtitleTrack],
        fallbackToEmbeddedBridge: Bool
    ) {
        guard generation == loadGeneration else { return }
        if fallbackToEmbeddedBridge {
            evaluateAVFoundationFailureFallback(
                path: path,
                error: error,
                generation: generation,
                sidecarSubtitles: sidecarSubtitles
            )
            return
        }
        failPlayback("Unable to load this video. \(error)")
    }

    private func evaluateAVFoundationFailureFallback(
        path: String,
        error: String,
        generation: Int,
        sidecarSubtitles: [SubtitleTrack]
    ) {
        guard shouldUseEmbeddedBridge(),
              let ffmpegURL = locateEmbeddedFFmpeg(),
              let ffprobeURL = locateFFprobe(ffmpegURL: ffmpegURL) else {
            failPlayback("Unable to load this video. \(error)")
            return
        }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let canFallback = self.avContainerHasAttachedPictureAndPlayableVideoStream(path: path, ffprobeURL: ffprobeURL)
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      generation == self.loadGeneration,
                      !self.isStopping else { return }
                if canFallback {
                    MarqueeLogger.player.error("AVFoundation failed; falling back to embedded bridge path=\(path, privacy: .public) error=\(error, privacy: .public)")
                    self.loadEmbeddedFFmpegFile(
                        sourcePath: path,
                        generation: generation,
                        sidecarSubtitles: sidecarSubtitles
                    )
                    return
                }
                self.failPlayback("Unable to load this video. \(error)")
            }
        }
    }

    private func avContainerHasAttachedPictureAndPlayableVideoStream(path: String, ffprobeURL: URL) -> Bool {
        guard let probe = probeVideoStreams(path: path, ffprobeURL: ffprobeURL) else {
            return false
        }
        return probe.hasAttachedPicture && probe.hasPlayableNonAttachedVideo
    }

    private func probeVideoStreams(path: String, ffprobeURL: URL) -> FFprobeVideoStreams? {
        let process = Process()
        process.executableURL = ffprobeURL
        process.arguments = [
            "-v", "error",
            "-select_streams", "v",
            "-show_entries", "stream=codec_type,codec_name:stream_disposition=attached_pic",
            "-of", "json",
            path
        ]
        guard let cacheDir = try? PlaybackCache.ensureDirectory(forSourcePath: path) else {
            return nil
        }
        configureProcess(process, playbackCacheDirectory: cacheDir)
        let stdout = BoundedPipeCapture(maxBytes: 64 * 1024)
        process.standardOutput = stdout.pipe
        process.standardError = FileHandle.nullDevice
        stdout.start()
        defer { stdout.stop() }

        do {
            try process.run()
        } catch {
            return nil
        }

        let deadline = Date().addingTimeInterval(maxProbeDuration)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.03)
        }
        if process.isRunning {
            terminatePreparationProcess(process)
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        return try? JSONDecoder().decode(FFprobeVideoStreams.self, from: stdout.data())
    }

    private func failUnsupportedContainer(path: String) {
        stopAVFoundation()
        stopExternalPlayer(markStopping: false)
        stopEmbeddedFFmpegPlayback(markStopping: false)
        shutdownMpv()
        setActiveBackend(.none)
        preparationMessage = nil
        awaitingStartFile = false
        pendingLoadPath = nil
        let ext = URL(fileURLWithPath: path).pathExtension.uppercased()
        let message = "\(ext.isEmpty ? "This file" : ext) cannot be decoded by the local playback backend."

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.advanceSubtitleSelectionGeneration()
            self.currentTime = 0
            self.duration = 0
            self.availableAudioTracks = []
            self.currentAudioTrack = nil
            self.availableSubtitleTracks = []
            self.currentSubtitleTrack = nil
            self.currentSubtitleEntries = []
            self.subtitlesEnabled = false
            self.hasSubtitles = false
            self.failPlayback(message)
        }
        MarqueeLogger.player.error("blocked unsupported container path=\(path, privacy: .public)")
    }

    private func loadRemuxedAVFoundationFile(
        sourcePath: String,
        generation: Int,
        sidecarSubtitles: [SubtitleTrack]
    ) {
        guard let ffmpegURL = locateFFmpeg() else {
            failUnsupportedContainer(path: sourcePath)
            return
        }
        let preparation = beginPreparation(generation: generation)

        stopAVFoundation()
        stopExternalPlayer(markStopping: false)
        stopEmbeddedFFmpegPlayback(markStopping: false)
        shutdownMpv()
        setActiveBackend(.avFoundationPrepared)
        awaitingStartFile = false
        renderView?.showAVPlayer(avPlayer)
        applyLifecycleEvent(.rendererReady)
        applyLifecycleEvent(.loadRequested)
        isMuted = false

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.advanceSubtitleSelectionGeneration()
            self.playbackSpeed = 1.0
            self.availableSubtitleTracks = sidecarSubtitles
            self.currentSubtitleTrack = nil
            self.currentSubtitleEntries = []
            self.subtitlesEnabled = false
            self.hasSubtitles = !sidecarSubtitles.isEmpty
            self.preparationMessage = "Preparing \(URL(fileURLWithPath: sourcePath).pathExtension.uppercased()) for playback..."
        }

        remuxQueue.async { [weak self] in
            guard let self else { return }
            do {
                try preparation.throwIfCancelled()
                let strategy = try self.preparationStrategy(
                    ffmpegURL: ffmpegURL,
                    sourcePath: sourcePath,
                    preparation: preparation
                )
                let outputURL = try self.remuxedPlaybackURL(for: sourcePath, strategy: strategy)
                try preparation.throwIfCancelled()
                if FileManager.default.fileExists(atPath: outputURL.path),
                   self.fileSize(at: outputURL) > self.maxPreparedMediaOutputBytes {
                    try? FileManager.default.removeItem(at: outputURL)
                }
                if !FileManager.default.fileExists(atPath: outputURL.path) {
                    try self.runFFmpegPreparation(
                        ffmpegURL: ffmpegURL,
                        sourcePath: sourcePath,
                        outputURL: outputURL,
                        strategy: strategy,
                        preparation: preparation
                    )
                }
                try preparation.throwIfCancelled()

                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          generation == self.loadGeneration,
                          self.isActivePreparation(preparation),
                          !self.isStopping else { return }
                    self.finishPreparation(preparation)
                    self.preparationMessage = nil
                    self.remuxedPlaybackURL = outputURL
                    self.loadAVFoundationFile(
                        path: outputURL.path,
                        sidecarSubtitles: sidecarSubtitles,
                        markLoadRequested: false,
                        backend: .avFoundationPrepared,
                        fallbackToEmbeddedBridge: self.shouldUseEmbeddedBridge()
                    )
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          generation == self.loadGeneration,
                          self.isActivePreparation(preparation),
                          !self.isStopping else { return }
                    self.finishPreparation(preparation)
                    self.preparationMessage = nil
                    if self.shouldFallbackToEmbeddedBridge(afterPreparationError: error) {
                        MarqueeLogger.player.error("prepared playback failed; falling back to embedded bridge path=\(sourcePath, privacy: .public) error=\(String(describing: error), privacy: .public)")
                        self.loadEmbeddedFFmpegFile(
                            sourcePath: sourcePath,
                            generation: generation,
                            sidecarSubtitles: sidecarSubtitles
                        )
                        return
                    }
                    if !(error is FFmpegPreparationCancelled) {
                        self.failPlayback("Unable to prepare this video for playback. \(error.localizedDescription)")
                    }
                }
            }
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

    private func locateFFprobe(ffmpegURL: URL) -> URL? {
        let environment = ProcessInfo.processInfo.environment
        let candidates = [
            environment["MARQUEE_FFPROBE_PATH"],
            ffmpegURL.deletingLastPathComponent().appendingPathComponent("ffprobe").path,
            "/usr/local/bin/ffprobe",
            "/opt/homebrew/bin/ffprobe",
            "/usr/bin/ffprobe"
        ].compactMap { $0 }

        return candidates
            .map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private func preparationStrategy(
        ffmpegURL: URL,
        sourcePath: String,
        preparation: FFmpegPreparationRun
    ) throws -> FFmpegPreparationStrategy {
        guard let ffprobeURL = locateFFprobe(ffmpegURL: ffmpegURL),
              let codecs = try probeCodecs(
                ffprobeURL: ffprobeURL,
                sourcePath: sourcePath,
                preparation: preparation
              ),
              let streamCopyStrategy = codecs.streamCopyStrategyForMP4 else {
            if shouldAllowPreparedTranscodeFallback() {
                return .transcode
            }
            throw RemuxError.streamCopyUnavailable("This file cannot be stream-copied into an AVFoundation-compatible MP4.")
        }
        return streamCopyStrategy
    }

    private func shouldFallbackToEmbeddedBridge(afterPreparationError error: Error) -> Bool {
        guard shouldUseEmbeddedBridge(), !(error is FFmpegPreparationCancelled) else {
            return false
        }
        if case RemuxError.streamCopyUnavailable = error {
            return true
        }
        return false
    }

    private func probeCodecs(
        ffprobeURL: URL,
        sourcePath: String,
        preparation: FFmpegPreparationRun
    ) throws -> FFprobeCodecs? {
        do {
            let cacheDir = try PlaybackCache.ensureDirectory(forSourcePath: sourcePath)
            let result = try runPreparationProcess(
                executableURL: ffprobeURL,
                arguments: [
                    "-v", "error",
                    "-show_entries", "stream=codec_type,codec_name",
                    "-of", "json",
                    sourcePath
                ],
                label: "ffprobe",
                preparation: preparation,
                timeout: maxProbeDuration,
                stdoutLimit: 1024 * 1024,
                stderrLimit: 64 * 1024,
                workingDirectory: cacheDir
            )
            guard result.terminationStatus == 0 else {
                let message = result.stderrText.ifNotEmpty ?? "status \(result.terminationStatus)"
                MarqueeLogger.player.error("ffprobe failed: \(message, privacy: .public)")
                return nil
            }
            return try JSONDecoder().decode(FFprobeCodecs.self, from: result.stdout)
        } catch is FFmpegPreparationCancelled {
            throw FFmpegPreparationCancelled()
        } catch {
            MarqueeLogger.player.error("ffprobe failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private func remuxedPlaybackURL(for sourcePath: String, strategy: FFmpegPreparationStrategy) throws -> URL {
        let attributes = try FileManager.default.attributesOfItem(atPath: sourcePath)
        let size = attributes[.size] as? UInt64 ?? 0
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let cacheDir = try preparedMediaCacheDirectory(for: sourcePath)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        let key = stableHash("\(sourcePath)|\(size)|\(modified)|\(strategy.rawValue)")
        let outputURL = cacheDir.appendingPathComponent("\(key).mp4")
        prunePreparedMediaCache(in: cacheDir, keeping: outputURL)
        return outputURL
    }

    private func preparedMediaCacheDirectory(for sourcePath: String) throws -> URL {
        if let override = ProcessInfo.processInfo.environment["MARQUEE_PREPARED_MEDIA_CACHE_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }

        return try PlaybackCache.ensureDirectory(forSourcePath: sourcePath)
    }

    private var maxPreparedMediaOutputBytes: UInt64 {
        let raw = ProcessInfo.processInfo.environment["MARQUEE_MAX_PREPARED_OUTPUT_BYTES"]
        if let raw, let value = UInt64(raw), value > 0 {
            return value
        }
        return maxPreparedMediaCacheBytes
    }

    private var requiredPreparedMediaFreeBytes: UInt64 {
        let raw = ProcessInfo.processInfo.environment["MARQUEE_MIN_PREPARED_FREE_BYTES"]
        if let raw, let value = UInt64(raw) {
            return value
        }
        return minimumPreparedMediaFreeBytes
    }

    private func stableHash(_ string: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private func runFFmpegPreparation(
        ffmpegURL: URL,
        sourcePath: String,
        outputURL: URL,
        strategy: FFmpegPreparationStrategy,
        preparation: FFmpegPreparationRun
    ) throws {
        try preparation.throwIfCancelled()
        let temporaryOutputURL = outputURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(outputURL.deletingPathExtension().lastPathComponent).partial.mp4")
        try? FileManager.default.removeItem(at: temporaryOutputURL)
        try validatePreparedMediaBudget(sourcePath: sourcePath, outputURL: outputURL, strategy: strategy)

        do {
            let result = try runPreparationProcess(
                executableURL: ffmpegURL,
                arguments: ffmpegArguments(
                    strategy: strategy,
                    sourcePath: sourcePath,
                    outputPath: temporaryOutputURL.path
                ),
                label: "ffmpeg",
                preparation: preparation,
                timeout: maxPreparationDuration,
                stdoutLimit: 64 * 1024,
                stderrLimit: 256 * 1024,
                monitoredOutputURL: temporaryOutputURL,
                maxOutputBytes: maxPreparedMediaOutputBytes,
                minimumAvailableBytes: requiredPreparedMediaFreeBytes,
                workingDirectory: outputURL.deletingLastPathComponent()
            )
            try preparation.throwIfCancelled()

            if result.terminationStatus != 0 && strategy.isStreamCopy && shouldAllowPreparedTranscodeFallback() {
                try? FileManager.default.removeItem(at: temporaryOutputURL)
                try preparation.throwIfCancelled()
                try runFFmpegPreparation(
                    ffmpegURL: ffmpegURL,
                    sourcePath: sourcePath,
                    outputURL: outputURL,
                    strategy: .transcode,
                    preparation: preparation
                )
                return
            }

            guard result.terminationStatus == 0 else {
                let message = result.stderrText.ifNotEmpty
                throw RemuxError.ffmpegFailed(message ?? "ffmpeg exited with status \(result.terminationStatus)")
            }
            try validatePreparedOutputSize(at: temporaryOutputURL)

            try? FileManager.default.removeItem(at: outputURL)
            try FileManager.default.moveItem(at: temporaryOutputURL, to: outputURL)
            prunePreparedMediaCache(in: outputURL.deletingLastPathComponent(), keeping: outputURL)
        } catch {
            try? FileManager.default.removeItem(at: temporaryOutputURL)
            throw error
        }
    }

    private func runPreparationProcess(
        executableURL: URL,
        arguments: [String],
        label: String,
        preparation: FFmpegPreparationRun,
        timeout: TimeInterval,
        stdoutLimit: Int,
        stderrLimit: Int,
        monitoredOutputURL: URL? = nil,
        maxOutputBytes: UInt64? = nil,
        minimumAvailableBytes: UInt64? = nil,
        workingDirectory: URL? = nil
    ) throws -> BoundedProcessResult {
        try preparation.throwIfCancelled()

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        if let workingDirectory {
            configureProcess(process, playbackCacheDirectory: workingDirectory)
        }

        let stdout = BoundedPipeCapture(maxBytes: stdoutLimit)
        let stderr = BoundedPipeCapture(maxBytes: stderrLimit)
        process.standardOutput = stdout.pipe
        process.standardError = stderr.pipe

        stdout.start()
        stderr.start()
        preparation.bind(process)
        defer {
            preparation.clear(process)
            stdout.stop()
            stderr.stop()
        }

        do {
            try process.run()
        } catch {
            throw RemuxError.ffmpegFailed("Unable to start \(label): \(error.localizedDescription)")
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if preparation.isCancelled {
                terminatePreparationProcess(process)
                throw FFmpegPreparationCancelled()
            }

            if Date() >= deadline {
                terminatePreparationProcess(process)
                throw RemuxError.ffmpegFailed("\(label) exceeded \(Int(timeout)) seconds")
            }

            try enforcePreparedMediaBounds(
                process: process,
                label: label,
                outputURL: monitoredOutputURL,
                maxOutputBytes: maxOutputBytes,
                minimumAvailableBytes: minimumAvailableBytes
            )

            Thread.sleep(forTimeInterval: 0.1)
        }
        Thread.sleep(forTimeInterval: 0.05)

        return BoundedProcessResult(
            terminationStatus: process.terminationStatus,
            stdout: stdout.data(),
            stderr: stderr.data()
        )
    }

    private func validatePreparedMediaBudget(
        sourcePath: String,
        outputURL: URL,
        strategy: FFmpegPreparationStrategy
    ) throws {
        let cacheDir = outputURL.deletingLastPathComponent()
        prunePreparedMediaCache(in: cacheDir, keeping: outputURL)

        guard let available = availableBytes(onVolumeFor: cacheDir) else { return }
        let sourceSize = ((try? FileManager.default.attributesOfItem(atPath: sourcePath)[.size]) as? UInt64) ?? 0
        let outputBudget = estimatedPreparedOutputBudget(sourceSize: sourceSize, strategy: strategy)
        let required = requiredPreparedMediaFreeBytes + outputBudget

        guard available >= required else {
            throw RemuxError.ffmpegFailed("Not enough free disk space to prepare this video. Available: \(formatBytes(available)); required: \(formatBytes(required)).")
        }
    }

    private func estimatedPreparedOutputBudget(
        sourceSize: UInt64,
        strategy: FFmpegPreparationStrategy
    ) -> UInt64 {
        let maxOutput = maxPreparedMediaOutputBytes
        switch strategy {
        case .streamCopyH264, .streamCopyHEVC:
            let streamCopySlack: UInt64 = 1 * 1024 * 1024 * 1024
            return min(maxOutput, sourceSize + streamCopySlack)
        case .transcode:
            let minimumTranscodeBudget: UInt64 = 2 * 1024 * 1024 * 1024
            let doubledSource = sourceSize > UInt64.max / 2 ? UInt64.max : sourceSize * 2
            return min(maxOutput, max(minimumTranscodeBudget, doubledSource))
        }
    }

    private func enforcePreparedMediaBounds(
        process: Process,
        label: String,
        outputURL: URL?,
        maxOutputBytes: UInt64?,
        minimumAvailableBytes: UInt64?
    ) throws {
        if let outputURL, let maxOutputBytes {
            let size = fileSize(at: outputURL)
            if size > maxOutputBytes {
                terminatePreparationProcess(process)
                throw RemuxError.ffmpegFailed("\(label) output exceeded the prepared-media limit of \(formatBytes(maxOutputBytes))")
            }
        }

        if let outputURL, let minimumAvailableBytes,
           let available = availableBytes(onVolumeFor: outputURL.deletingLastPathComponent()),
           available < minimumAvailableBytes {
            terminatePreparationProcess(process)
            throw RemuxError.ffmpegFailed("Stopping \(label) because free disk space fell below \(formatBytes(minimumAvailableBytes))")
        }
    }

    private func validatePreparedOutputSize(at url: URL) throws {
        let size = fileSize(at: url)
        let maxOutput = maxPreparedMediaOutputBytes
        guard size <= maxOutput else {
            throw RemuxError.ffmpegFailed("Prepared video exceeded the per-file cache limit of \(formatBytes(maxOutput))")
        }
    }

    private func fileSize(at url: URL) -> UInt64 {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? UInt64
        return size ?? 0
    }

    private func availableBytes(onVolumeFor url: URL) -> UInt64? {
        let keys: Set<URLResourceKey> = [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        if let important = values.volumeAvailableCapacityForImportantUsage, important > 0 {
            return UInt64(important)
        }
        if let capacity = values.volumeAvailableCapacity, capacity > 0 {
            return UInt64(capacity)
        }
        return nil
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }

    private func configureProcess(_ process: Process, playbackCacheDirectory: URL) {
        process.currentDirectoryURL = playbackCacheDirectory
        process.environment = PlaybackCache.processEnvironment(directory: playbackCacheDirectory)
    }

    private func terminatePreparationProcess(_ process: Process) {
        guard process.isRunning else { return }

        process.terminate()
        let terminateDeadline = Date().addingTimeInterval(1.5)
        while process.isRunning && Date() < terminateDeadline {
            Thread.sleep(forTimeInterval: 0.05)
        }

        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            let killDeadline = Date().addingTimeInterval(2.0)
            while process.isRunning && Date() < killDeadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }

        waitForProcessExitAfterTermination(process)
    }

    private func waitForProcessExitAfterTermination(_ process: Process) {
        // `Process.waitUntilExit()` can block indefinitely on Monterey after
        // a helper has already transitioned to not-running. The terminate/kill
        // polling above is the bounded cleanup contract; do not re-enter an
        // unbounded Foundation wait here.
        if process.isRunning {
            MarqueeLogger.player.error("helper process still running after bounded termination pid=\(process.processIdentifier, privacy: .public)")
        }
    }

    private func prunePreparedMediaCache(in cacheDir: URL, keeping protectedURL: URL) {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentAccessDateKey, .creationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: cacheDir,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return }

        var entries: [(url: URL, size: UInt64, date: Date)] = []
        var totalSize: UInt64 = 0

        for file in files where file.pathExtension.lowercased() == "mp4" {
            guard let values = try? file.resourceValues(forKeys: Set(keys)) else { continue }
            let size = UInt64(values.fileSize ?? 0)
            totalSize += size
            guard file != protectedURL else { continue }
            entries.append((
                url: file,
                size: size,
                date: values.contentAccessDate ?? values.creationDate ?? .distantPast
            ))
        }

        guard totalSize > maxPreparedMediaCacheBytes else { return }

        for entry in entries.sorted(by: { $0.date < $1.date }) {
            try? FileManager.default.removeItem(at: entry.url)
            totalSize = totalSize > entry.size ? totalSize - entry.size : 0
            if totalSize <= targetPreparedMediaCacheBytes {
                break
            }
        }
    }

    private func ffmpegArguments(
        strategy: FFmpegPreparationStrategy,
        sourcePath: String,
        outputPath: String
    ) -> [String] {
        var args = [
            "-hide_banner",
            "-loglevel", "error",
            "-y",
            "-i", sourcePath,
            "-map", "0:v:0",
            "-map", "0:a?",
            "-sn"
        ]

        switch strategy {
        case .streamCopyH264:
            args += ["-c", "copy"]

        case .streamCopyHEVC:
            args += [
                "-c", "copy",
                "-tag:v", "hvc1"
            ]

        case .transcode:
            args += [
                "-c:v", "libx264",
                "-preset", "veryfast",
                "-crf", "21",
                "-pix_fmt", "yuv420p",
                "-c:a", "aac",
                "-b:a", "192k"
            ]
        }

        args += [outputPath]
        return args
    }

    private func beginPreparation(generation: Int) -> FFmpegPreparationRun {
        cancelActivePreparation()
        let preparation = FFmpegPreparationRun(generation: generation)
        preparationLock.lock()
        activePreparation = preparation
        preparationLock.unlock()
        return preparation
    }

    private func isActivePreparation(_ preparation: FFmpegPreparationRun) -> Bool {
        preparationLock.lock()
        let isActive = activePreparation === preparation
        preparationLock.unlock()
        return isActive
    }

    private func finishPreparation(_ preparation: FFmpegPreparationRun) {
        preparationLock.lock()
        if activePreparation === preparation {
            activePreparation = nil
        }
        preparationLock.unlock()
    }

    private func cancelActivePreparation() {
        preparationLock.lock()
        let preparation = activePreparation
        activePreparation = nil
        preparationLock.unlock()

        // Synchronous on purpose: the next load generation must not start until the old ffmpeg is gone; cancel()'s wait is SIGTERM-bounded.
        preparation?.cancel()
    }

    private func refreshAVTrackLists(for item: AVPlayerItem, sidecarSubtitles: [SubtitleTrack]) {
        var audio: [AudioTrack] = []
        if let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: .audible) {
            for (index, option) in group.options.enumerated() {
                let languageCode = option.locale?.languageCode
                let languageName = languageCode.flatMap { Locale.current.localizedString(forLanguageCode: $0) }
                audio.append(AudioTrack(
                    id: "av-audio-\(index)",
                    displayName: languageName ?? option.displayName,
                    languageCode: languageCode
                ))
            }
        }

        var subtitles: [SubtitleTrack] = []
        if let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: .legible) {
            for (index, option) in group.options.enumerated() {
                let languageCode = option.locale?.languageCode
                let languageName = languageCode.flatMap { Locale.current.localizedString(forLanguageCode: $0) }
                subtitles.append(SubtitleTrack(
                    id: "av-subtitle-\(index)",
                    displayName: languageName ?? option.displayName,
                    isExternal: false,
                    externalPath: nil
                ))
            }
        }
        subtitles.append(contentsOf: sidecarSubtitles)

        availableAudioTracks = audio
        availableSubtitleTracks = subtitles
        hasSubtitles = !subtitles.isEmpty
        if let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: .audible),
           let selected = item.currentMediaSelection.selectedMediaOption(in: group) {
            currentAudioTrack = audio.first { selected.displayName.contains($0.displayName) || $0.displayName.contains(selected.displayName) }
                ?? audio.first
        } else {
            currentAudioTrack = audio.first
        }
    }

    private func stopAVFoundation() {
        avPlayer.pause()
        avPlayer.replaceCurrentItem(with: nil)
        if let avEndObserver {
            NotificationCenter.default.removeObserver(avEndObserver)
            self.avEndObserver = nil
        }
        avItemCancellables.removeAll()
    }

    // MARK: - Crash-Isolated External Playback

    private func locateFFplay() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        if environment["MARQUEE_DISABLE_EXTERNAL_FFPLAY"] == "1" {
            return nil
        }

        let executableDir = Bundle.main.executableURL?.deletingLastPathComponent().path
        let resourceDir = Bundle.main.resourceURL?.path
        let candidates = [
            environment["MARQUEE_FFPLAY_PATH"],
            executableDir.map { "\($0)/ffplay" },
            resourceDir.map { "\($0)/ffplay" },
            "/usr/local/bin/ffplay",
            "/opt/homebrew/bin/ffplay"
        ].compactMap { $0 }

        return candidates
            .map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private func locateExternalFFprobe(ffplayURL: URL) -> URL? {
        let environment = ProcessInfo.processInfo.environment
        let candidates = [
            environment["MARQUEE_FFPROBE_PATH"],
            ffplayURL.deletingLastPathComponent().appendingPathComponent("ffprobe").path,
            "/usr/local/bin/ffprobe",
            "/opt/homebrew/bin/ffprobe"
        ].compactMap { $0 }

        return candidates
            .map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private func probeExternalDuration(sourcePath: String, ffplayURL: URL) -> Double? {
        guard let ffprobeURL = locateExternalFFprobe(ffplayURL: ffplayURL) else { return nil }

        let process = Process()
        process.executableURL = ffprobeURL
        process.arguments = [
            "-v", "error",
            "-show_entries", "format=duration",
            "-of", "default=noprint_wrappers=1:nokey=1",
            sourcePath
        ]
        guard let cacheDir = try? PlaybackCache.ensureDirectory(forSourcePath: sourcePath) else {
            return nil
        }
        configureProcess(process, playbackCacheDirectory: cacheDir)

        let stdout = BoundedPipeCapture(maxBytes: 64 * 1024)
        let stderr = BoundedPipeCapture(maxBytes: 16 * 1024)
        process.standardOutput = stdout.pipe
        process.standardError = stderr.pipe
        stdout.start()
        stderr.start()
        defer {
            stdout.stop()
            stderr.stop()
        }

        do {
            try process.run()
        } catch {
            MarqueeLogger.player.error("external ffprobe failed to start: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        let deadline = Date().addingTimeInterval(maxProbeDuration)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.03)
        }
        if process.isRunning {
            terminatePreparationProcess(process)
            return nil
        }
        guard process.terminationStatus == 0 else {
            let detail = String(data: stderr.data(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "status \(process.terminationStatus)"
            MarqueeLogger.player.error("external ffprobe failed: \(detail, privacy: .public)")
            return nil
        }

        let raw = String(data: stdout.data(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw, let value = Double(raw), value.isFinite, value > 0 else { return nil }
        return value
    }

    private func loadExternalFFplayFile(
        sourcePath: String,
        generation: Int,
        sidecarSubtitles: [SubtitleTrack]
    ) {
        stopAVFoundation()
        stopEmbeddedFFmpegPlayback(markStopping: false)
        shutdownMpv()
        setActiveBackend(.externalFFplay)
        awaitingStartFile = false
        preparationMessage = "Opening crash-isolated player..."
        renderView?.showMpvSurface()
        applyLifecycleEvent(.rendererReady)
        applyLifecycleEvent(.loadRequested)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.advanceSubtitleSelectionGeneration()
            self.currentTime = 0
            self.duration = 0
            self.playbackSpeed = 1.0
            self.availableAudioTracks = []
            self.currentAudioTrack = nil
            self.availableSubtitleTracks = sidecarSubtitles
            self.currentSubtitleTrack = nil
            self.currentSubtitleEntries = []
            self.subtitlesEnabled = false
            self.hasSubtitles = !sidecarSubtitles.isEmpty
            self.isMuted = false
        }

        guard startExternalFFplayProcess(
            sourcePath: sourcePath,
            generation: generation,
            sidecarSubtitles: sidecarSubtitles,
            startOffset: 0
        ) else {
            return
        }

        preparationMessage = nil
        applyLifecycleEvent(.fileLoaded)
    }

    @discardableResult
    private func startExternalFFplayProcess(
        sourcePath: String,
        generation: Int,
        sidecarSubtitles: [SubtitleTrack],
        startOffset: Double
    ) -> Bool {
        guard let executableURL = locateFFplay() else {
            failPlayback("Unable to play this format without remuxing because ffplay was not found. Install ffmpeg/ffplay or set MARQUEE_FFPLAY_PATH.")
            return false
        }
        let cacheDir: URL
        do {
            cacheDir = try PlaybackCache.requireFreeBytes(forSourcePath: sourcePath)
        } catch {
            failPlayback(error.localizedDescription)
            return false
        }

        stopExternalPlayer(markStopping: false)
        externalPlaybackPath = sourcePath
        externalPlaybackSubtitles = sidecarSubtitles
        externalPlaybackStartOffset = max(0, startOffset)
        externalPauseStartedAt = nil
        let filename = URL(fileURLWithPath: sourcePath).lastPathComponent
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ffplayArguments(
            sourcePath: sourcePath,
            startOffset: externalPlaybackStartOffset,
            title: filename
        )
        configureProcess(process, playbackCacheDirectory: cacheDir)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice

        let stderr = BoundedPipeCapture(maxBytes: 128 * 1024)
        process.standardError = stderr.pipe
        externalPlayerStderr = stderr
        stderr.start()

        process.terminationHandler = { [weak self, weak process] terminated in
            guard let self, let process else { return }
            DispatchQueue.main.async {
                self.handleExternalFFplayTermination(process: process, status: terminated.terminationStatus)
            }
        }

        do {
            try process.run()
        } catch {
            stderr.stop()
            failPlayback("Unable to start crash-isolated player. \(error.localizedDescription)")
            return false
        }

        externalPlayerProcess = process
        externalPlaybackStartedAt = Date()
        externalPlaybackTimer?.invalidate()
        externalPlaybackTimer = nil

        externalPlaybackTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refreshExternalPlaybackClock()
        }
        isPaused = false
        isMuted = false
        currentTime = externalPlaybackStartOffset
        probeExternalDurationInBackground(sourcePath: sourcePath, ffplayURL: executableURL, generation: generation)
        MarqueeLogger.player.info("external ffplay started pid=\(process.processIdentifier, privacy: .public) path=\(sourcePath, privacy: .public)")
        return generation == loadGeneration
    }

    private func probeExternalDurationInBackground(sourcePath: String, ffplayURL: URL, generation: Int) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self,
                  let probedDuration = self.probeExternalDuration(sourcePath: sourcePath, ffplayURL: ffplayURL) else { return }

            DispatchQueue.main.async { [weak self] in
                guard let self,
                      generation == self.loadGeneration,
                      self.activeBackend == .externalFFplay,
                      self.externalPlaybackPath == sourcePath else { return }
                self.duration = probedDuration
            }
        }
    }

    private func ffplayArguments(
        sourcePath: String,
        startOffset: Double,
        title: String
    ) -> [String] {
        var args = [
            "-hide_banner",
            "-loglevel", "warning",
            "-autoexit"
        ]
        args += [
            "-alwaysontop",
            "-window_title", "Marquee - \(title)",
            "-x", "1280",
            "-y", "720"
        ]
        args += [
            "-volume", String(Int(max(0, min(100, volume))))
        ]
        if startOffset > 0 {
            args += ["-ss", String(format: "%.3f", startOffset)]
        }
        args += ["-i", sourcePath]
        return args
    }

    private func handleExternalFFplayTermination(process: Process, status: Int32) {
        guard externalPlayerProcess === process else { return }
        externalPlayerStderr.stop()
        externalPlaybackTimer?.invalidate()
        externalPlaybackTimer = nil
        externalPlayerProcess = nil

        if externalPlaybackIsRelaunching {
            return
        }

        if isStopping || status == SIGTERM || status == SIGKILL {
            applyLifecycleEvent(.stop)
            return
        }

        if status == 0 {
            applyLifecycleEvent(.ended)
            emitPlaybackEndedIfNeeded(source: "external-ffplay-ended")
            return
        }

        let stderr = externalPlayerStderr.data()
        let detail = String(data: stderr, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .ifNotEmpty
        failPlayback("The crash-isolated video player exited unexpectedly. Marquee stayed open.\(detail.map { " \($0)" } ?? "")")
    }

    private func refreshExternalPlaybackClock() {
        guard activeBackend == .externalFFplay,
              externalPlayerProcess?.isRunning == true,
              externalPauseStartedAt == nil,
              let startedAt = externalPlaybackStartedAt else { return }
        currentTime = externalPlaybackStartOffset + Date().timeIntervalSince(startedAt) * Double(playbackSpeed)
    }

    private func seekExternalFFplay(to seconds: Double) {
        guard let path = externalPlaybackPath else { return }
        let wasPaused = isPaused
        applyLifecycleEvent(.seekRequested)
        externalPlaybackIsRelaunching = true
        if let process = externalPlayerProcess {
            externalPlayerProcess = nil
            terminateExternalPlayerProcess(process)
        }
        externalPlaybackIsRelaunching = false

        let started = startExternalFFplayProcess(
            sourcePath: path,
            generation: loadGeneration,
            sidecarSubtitles: externalPlaybackSubtitles,
            startOffset: seconds
        )
        guard started else { return }
        currentTime = seconds
        applyLifecycleEvent(.seekCompleted)
        if wasPaused {
            setPaused(true)
        }
    }

    private func stopExternalPlayer(markStopping: Bool = true) {
        if markStopping {
            isStopping = true
        }
        externalPlaybackTimer?.invalidate()
        externalPlaybackTimer = nil
        externalPauseStartedAt = nil
        externalPlaybackStartedAt = nil
        externalPlayerStderr.stop()

        guard let process = externalPlayerProcess else { return }
        externalPlayerProcess = nil
        terminateExternalPlayerProcess(process)
    }

    private func terminateExternalPlayerProcess(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        // A SIGSTOP'd (paused) process cannot act on SIGTERM until it is
        // continued; without this, tearing down a paused bridge stalls the
        // caller for the full deadline and ends in SIGKILL.
        kill(process.processIdentifier, SIGCONT)

        let terminateDeadline = Date().addingTimeInterval(1.0)
        while process.isRunning && Date() < terminateDeadline {
            Thread.sleep(forTimeInterval: 0.03)
        }

        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
    }

    // MARK: - Embedded FFmpeg Bridge

    private var embeddedFrameWidth: Int { 960 }
    private var embeddedFrameHeight: Int { 540 }
    private var embeddedFrameByteCount: Int { embeddedFrameWidth * embeddedFrameHeight * 4 }

    private func loadEmbeddedFFmpegFile(
        sourcePath: String,
        generation: Int,
        sidecarSubtitles: [SubtitleTrack]
    ) {
        stopAVFoundation()
        stopExternalPlayer(markStopping: false)
        stopEmbeddedFFmpegPlayback(markStopping: false)
        shutdownMpv()
        setActiveBackend(.ffmpegEmbedded)
        awaitingStartFile = false
        preparationMessage = "Opening embedded player..."
        isMuted = false
        // Reset speed before the presenter captures it: the async state
        // reset below runs after the synchronous launch, and a fresh film
        // must never inherit the previous session's rate.
        playbackSpeed = 1.0
        renderView?.showExternalFrameSurface()
        applyLifecycleEvent(.rendererReady)
        applyLifecycleEvent(.loadRequested)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.advanceSubtitleSelectionGeneration()
            self.currentTime = 0
            self.duration = 0
            self.playbackSpeed = 1.0
            self.availableAudioTracks = []
            self.currentAudioTrack = nil
            self.availableSubtitleTracks = sidecarSubtitles
            self.currentSubtitleTrack = nil
            self.currentSubtitleEntries = []
            self.subtitlesEnabled = false
            self.hasSubtitles = !sidecarSubtitles.isEmpty
            self.isMuted = false
        }

        guard startEmbeddedFFmpegPlayback(
            sourcePath: sourcePath,
            generation: generation,
            sidecarSubtitles: sidecarSubtitles,
            startOffset: 0
        ) else { return }

        preparationMessage = nil
        applyLifecycleEvent(.fileLoaded)
    }

    @discardableResult
    private func startEmbeddedFFmpegPlayback(
        sourcePath: String,
        generation: Int,
        sidecarSubtitles: [SubtitleTrack],
        startOffset: Double,
        preserveSurface: Bool = false
    ) -> Bool {
        guard let ffmpegURL = locateEmbeddedFFmpeg() else {
            failPlayback("Unable to play this format because ffmpeg was not found. Install ffmpeg or set MARQUEE_FFMPEG_PATH.")
            return false
        }
        let cacheDir: URL
        do {
            cacheDir = try PlaybackCache.requireFreeBytes(forSourcePath: sourcePath)
        } catch {
            failPlayback(error.localizedDescription)
            return false
        }

        let sourceHasAudio = embeddedPlaybackHasAudio
        stopEmbeddedFFmpegPlayback(markStopping: false, clearSurface: !preserveSurface)
        embeddedPlaybackHasAudio = sourceHasAudio
        embeddedPlaybackRunID += 1
        let runID = embeddedPlaybackRunID
        embeddedPlaybackPath = sourcePath
        embeddedPlaybackSubtitles = sidecarSubtitles
        embeddedPlaybackStartOffset = max(0, startOffset)
        embeddedAwaitingDrain = false

        // The bridge decodes without realtime throttling; the presenter's
        // synchronizer clock paces it through pipe backpressure. Video
        // timestamps are frame index over a forced-CFR rate, so the source's
        // real rate is probed before launch. Audio PCM travels through a
        // FIFO in the POSIX temp dir because the playback cache is on exFAT,
        // which cannot host FIFOs. If audio cannot be prepared, the bridge
        // must launch without the audio mapping — ffmpeg would block forever
        // opening a FIFO no one reads.
        setPlaybackNotice(nil)
        let frameRate = probeEmbeddedFrameRate(sourcePath: sourcePath, ffmpegURL: ffmpegURL)
        var audioFIFOPath: String?
        var presenter: EmbeddedPlaybackPresenter?
        if embeddedPlaybackHasAudio {
            let fifoURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("marquee-embedded-audio-\(getpid())-\(runID).fifo")
            let candidate = EmbeddedPlaybackPresenter(
                fifoURL: fifoURL,
                startOffset: embeddedPlaybackStartOffset,
                frameRate: frameRate,
                initialRate: playbackSpeed
            )
            if candidate.start(initialVolume: Float(max(0, min(100, volume)) / 100.0), muted: isMuted) {
                presenter = candidate
                audioFIFOPath = fifoURL.path
            } else {
                MarqueeLogger.player.error("embedded audio unavailable; continuing without audio")
                setPlaybackNotice("Audio is unavailable on this output. Playing video only.")
            }
        }
        if presenter == nil {
            let silent = EmbeddedPlaybackPresenter(
                fifoURL: nil,
                startOffset: embeddedPlaybackStartOffset,
                frameRate: frameRate,
                initialRate: playbackSpeed
            )
            _ = silent.start(initialVolume: 0, muted: true)
            presenter = silent
        }
        presenter?.onAudioFailed = { [weak self] in
            self?.setPlaybackNotice("Audio output stopped responding. Video is still playing.")
        }
        embeddedPresenter = presenter
        embeddedAudioOutputActive = audioFIFOPath != nil

        let videoProcess = Process()
        configureGuardedFFmpegProcess(
            videoProcess,
            ffmpegURL: ffmpegURL,
            ffmpegArguments: ffmpegEmbeddedArguments(
                sourcePath: sourcePath,
                startOffset: embeddedPlaybackStartOffset,
                frameRate: frameRate,
                audioFIFOPath: audioFIFOPath
            ),
            workingDirectory: cacheDir
        )
        videoProcess.standardInput = FileHandle.nullDevice
        let videoPipe = Pipe()
        videoProcess.standardOutput = videoPipe
        let videoStderr = BoundedPipeCapture(maxBytes: 64 * 1024)
        videoProcess.standardError = videoStderr.pipe
        embeddedVideoStderr = videoStderr
        videoStderr.start()

        videoProcess.terminationHandler = { [weak self, weak videoProcess] terminated in
            guard let self, let videoProcess else { return }
            DispatchQueue.main.async {
                self.handleEmbeddedFFmpegTermination(process: videoProcess, status: terminated.terminationStatus)
            }
        }

        do {
            try videoProcess.run()
        } catch {
            videoStderr.stop()
            embeddedPresenter?.stop()
            embeddedPresenter = nil
            embeddedAudioOutputActive = false
            failPlayback("Unable to start embedded player. \(error.localizedDescription)")
            return false
        }

        embeddedVideoProcess = videoProcess
        if let layer = renderView?.embeddedSampleBufferLayer {
            presenter?.attachDisplayLayer(layer)
        }
        presenter?.onFirstVideoFrame = { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.embeddedPlaybackRunID == runID else { return }
                self.renderView?.noteEmbeddedFramesEnqueued()
            }
        }
        embeddedPlaybackTimer?.invalidate()
        embeddedPlaybackTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refreshEmbeddedPlaybackClock()
        }
        isPaused = false
        currentTime = embeddedPlaybackStartOffset
        if let presenter {
            readEmbeddedVideoFrames(
                from: videoPipe,
                generation: generation,
                runID: runID,
                process: videoProcess,
                presenter: presenter
            )
        }
        let durationProbeEpoch = currentEmbeddedDurationProbeEpoch()
        probeEmbeddedDurationInBackground(
            sourcePath: sourcePath,
            ffmpegURL: ffmpegURL,
            generation: generation,
            runID: runID,
            epoch: durationProbeEpoch
        )
        return generation == loadGeneration
    }

    private func configureGuardedFFmpegProcess(
        _ process: Process,
        ffmpegURL: URL,
        ffmpegArguments: [String],
        workingDirectory: URL
    ) {
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = guardedFFmpegArguments(
            parentPID: getpid(),
            ffmpegURL: ffmpegURL,
            ffmpegArguments: ffmpegArguments
        )
        configureProcess(process, playbackCacheDirectory: workingDirectory)
    }

    private func guardedFFmpegArguments(
        parentPID: pid_t,
        ffmpegURL: URL,
        ffmpegArguments: [String]
    ) -> [String] {
        let script = """
        parent_pid="$1"
        shift
        ffmpeg_path="$1"
        shift

        target_pid="$$"

        (
          while kill -0 "$target_pid" 2>/dev/null; do
            if ! kill -0 "$parent_pid" 2>/dev/null; then
              kill -TERM "$target_pid" 2>/dev/null || true
              sleep 0.25
              kill -KILL "$target_pid" 2>/dev/null || true
              exit 143
            fi
            sleep 0.25
          done
        ) &

        exec "$ffmpeg_path" "$@"
        """

        return [
            "-c",
            script,
            "marquee-ffmpeg-guard",
            String(parentPID),
            ffmpegURL.path
        ] + ffmpegArguments
    }

    private func locateEmbeddedFFmpeg() -> URL? {
        if ProcessInfo.processInfo.environment["MARQUEE_DISABLE_EXTERNAL_FFMPEG"] == "1" {
            return nil
        }
        return locateFFmpeg()
    }

    private func ffmpegEmbeddedArguments(
        sourcePath: String,
        startOffset: Double,
        frameRate: Double,
        audioFIFOPath: String?
    ) -> [String] {
        // No `-re`: the presenter paces the process through pipe
        // backpressure, and the `fps` filter forces constant frame rate so
        // each raw frame's timestamp is exactly its index over `frameRate`.
        var args = [
            "-hide_banner",
            "-loglevel", "error",
            "-nostdin",
            "-y"
        ]
        if startOffset > 0 {
            args += ["-ss", String(format: "%.3f", startOffset)]
        }
        args += [
            "-i", sourcePath,
            "-map", "0:V:0",
            "-an",
            "-sn",
            "-vf", "scale=\(embeddedFrameWidth):\(embeddedFrameHeight):force_original_aspect_ratio=decrease,pad=\(embeddedFrameWidth):\(embeddedFrameHeight):(ow-iw)/2:(oh-ih)/2,setsar=1,fps=\(String(format: "%.6f", frameRate))",
            "-pix_fmt", "bgra",
            "-f", "rawvideo",
            "-"
        ]
        if let audioFIFOPath {
            args += [
                "-map", "0:a:0?",
                "-vn",
                "-sn",
                "-ac", "\(EmbeddedPlaybackPresenter.channelCount)",
                "-ar", "\(Int(EmbeddedPlaybackPresenter.sampleRate))",
                "-f", "f32le",
                audioFIFOPath
            ]
        }
        return args
    }

    /// Probes the source's average video frame rate so raw-frame timestamps
    /// can be derived from frame index. Cached per path because seek and
    /// resume relaunch the bridge against the same file.
    private func probeEmbeddedFrameRate(sourcePath: String, ffmpegURL: URL) -> Double {
        if let cached = embeddedFrameRateCache, cached.path == sourcePath {
            return cached.fps
        }
        let fallback = 24.0
        guard let ffprobeURL = locateFFprobe(ffmpegURL: ffmpegURL) else { return fallback }

        let process = Process()
        process.executableURL = ffprobeURL
        process.arguments = [
            "-v", "error",
            "-select_streams", "V:0",
            "-show_entries", "stream=avg_frame_rate,r_frame_rate",
            "-of", "default=noprint_wrappers=1",
            sourcePath
        ]
        guard let cacheDir = try? PlaybackCache.ensureDirectory(forSourcePath: sourcePath) else {
            return fallback
        }
        configureProcess(process, playbackCacheDirectory: cacheDir)
        let stdout = BoundedPipeCapture(maxBytes: 4 * 1024)
        process.standardOutput = stdout.pipe
        process.standardError = FileHandle.nullDevice
        stdout.start()
        defer { stdout.stop() }
        do {
            try process.run()
        } catch {
            return fallback
        }
        // Local-file probes return in well under a second; a short deadline
        // keeps the pre-launch wait bounded (the fallback rate is benign —
        // the fps filter still emits a correct timeline, just resampled).
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.03)
        }
        if process.isRunning {
            terminatePreparationProcess(process)
            return fallback
        }
        guard process.terminationStatus == 0,
              let text = String(data: stdout.data(), encoding: .utf8) else { return fallback }

        // Keyed "name=num/den" lines; prefer the average rate, which matches
        // frame count over duration, regardless of ffprobe's output order.
        var parsed: [String: Double] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let pair = line.split(separator: "=", maxSplits: 1)
            guard pair.count == 2 else { continue }
            let parts = pair[1].split(separator: "/")
            let value: Double?
            if parts.count == 2, let num = Double(parts[0]), let den = Double(parts[1]), den > 0 {
                value = num / den
            } else {
                value = Double(pair[1])
            }
            if let value, value >= 5, value <= 120 {
                parsed[String(pair[0])] = value
            }
        }
        let fps = parsed["avg_frame_rate"] ?? parsed["r_frame_rate"] ?? fallback
        embeddedFrameRateCache = (sourcePath, fps)
        return fps
    }

    private func setPlaybackNotice(_ message: String?) {
        if Thread.isMainThread {
            playbackNotice = message
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.playbackNotice = message
            }
        }
    }

    private func readEmbeddedVideoFrames(
        from pipe: Pipe,
        generation: Int,
        runID: Int,
        process: Process,
        presenter: EmbeddedPlaybackPresenter
    ) {
        let handle = pipe.fileHandleForReading
        let frameBytes = embeddedFrameByteCount
        let width = embeddedFrameWidth
        let height = embeddedFrameHeight
        embeddedFrameQueue.async {
            // Reads run to end-of-pipe rather than process liveness so the
            // buffered tail is never dropped, and intake gating is the
            // backpressure that paces the bridge.
            while true {
                if presenter.isStopped { return }
                if !presenter.shouldAcceptMoreVideo() {
                    usleep(10_000)
                    continue
                }
                let reachedEnd = autoreleasepool { () -> Bool in
                    let data = handle.readData(ofLength: frameBytes)
                    guard data.count == frameBytes else { return true }
                    presenter.ingestVideoFrame(data, width: width, height: height)
                    return false
                }
                if reachedEnd {
                    presenter.markVideoEOF()
                    return
                }
            }
        }
    }

    private func clearEmbeddedFrameSurface() {
        if Thread.isMainThread {
            renderView?.clearExternalFrameSurface()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.renderView?.clearExternalFrameSurface()
            }
        }
    }

    private func probeEmbeddedDurationInBackground(
        sourcePath: String,
        ffmpegURL: URL,
        generation: Int,
        runID: Int,
        epoch: Int
    ) {
        guard let ffprobeURL = locateFFprobe(ffmpegURL: ffmpegURL) else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            guard self.isEmbeddedDurationProbeCurrent(generation: generation, runID: runID) else { return }
            let process = Process()
            process.executableURL = ffprobeURL
            process.arguments = [
                "-v", "error",
                "-show_entries", "format=duration",
                "-of", "default=noprint_wrappers=1:nokey=1",
                sourcePath
            ]
            guard let cacheDir = try? PlaybackCache.ensureDirectory(forSourcePath: sourcePath) else {
                return
            }
            self.configureProcess(process, playbackCacheDirectory: cacheDir)
            let stdout = BoundedPipeCapture(maxBytes: 64 * 1024)
            process.standardOutput = stdout.pipe
            process.standardError = FileHandle.nullDevice
            stdout.start()
            defer { stdout.stop() }
            let handle = EmbeddedDurationProbeHandle(
                generation: generation,
                runID: runID,
                epoch: epoch,
                process: process
            )
            guard self.bindEmbeddedDurationProbe(handle) else {
                return
            }
            defer {
                self.clearEmbeddedDurationProbe(handle)
            }
            do {
                guard try self.runEmbeddedDurationProbe(handle) else {
                    return
                }
            } catch {
                return
            }
            guard self.isEmbeddedDurationProbeCurrent(generation: generation, runID: runID) else {
                self.terminatePreparationProcess(process)
                return
            }
            let deadline = Date().addingTimeInterval(self.maxProbeDuration)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.03)
            }
            if process.isRunning {
                self.terminatePreparationProcess(process)
                return
            }
            let raw = String(data: stdout.data(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let raw, let value = Double(raw), value.isFinite, value > 0 else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      generation == self.loadGeneration,
                      runID == self.embeddedPlaybackRunID,
                      self.activeBackend == .ffmpegEmbedded,
                      self.embeddedPlaybackPath == sourcePath else { return }
                self.duration = value
            }
        }
    }

    private func currentEmbeddedDurationProbeEpoch() -> Int {
        embeddedDurationProbeLock.lock()
        let epoch = embeddedDurationProbeEpoch
        embeddedDurationProbeLock.unlock()
        return epoch
    }

    private func isEmbeddedDurationProbeCurrent(generation: Int, runID: Int) -> Bool {
        let check = {
            generation == self.loadGeneration
                && runID == self.embeddedPlaybackRunID
                && self.activeBackend == .ffmpegEmbedded
        }
        if Thread.isMainThread {
            return check()
        }
        return DispatchQueue.main.sync(execute: check)
    }

    private func bindEmbeddedDurationProbe(_ handle: EmbeddedDurationProbeHandle) -> Bool {
        guard isEmbeddedDurationProbeCurrent(generation: handle.generation, runID: handle.runID) else {
            return false
        }

        var previousHandle: EmbeddedDurationProbeHandle?
        embeddedDurationProbeLock.lock()
        if handle.epoch == embeddedDurationProbeEpoch {
            previousHandle = embeddedDurationProbeHandle
            previousHandle?.cancelled = true
            embeddedDurationProbeHandle = handle
        } else {
            handle.cancelled = true
        }
        embeddedDurationProbeLock.unlock()

        if let previousHandle, previousHandle !== handle {
            terminatePreparationProcess(previousHandle.process)
        }

        return !handle.cancelled
    }

    private func runEmbeddedDurationProbe(_ handle: EmbeddedDurationProbeHandle) throws -> Bool {
        embeddedDurationProbeLock.lock()
        guard embeddedDurationProbeHandle === handle,
              handle.epoch == embeddedDurationProbeEpoch,
              !handle.cancelled else {
            embeddedDurationProbeLock.unlock()
            return false
        }

        do {
            try handle.process.run()
        } catch {
            if embeddedDurationProbeHandle === handle {
                embeddedDurationProbeHandle = nil
            }
            embeddedDurationProbeLock.unlock()
            throw error
        }

        embeddedDurationProbeLock.unlock()
        return true
    }

    private func clearEmbeddedDurationProbe(_ handle: EmbeddedDurationProbeHandle) {
        embeddedDurationProbeLock.lock()
        if embeddedDurationProbeHandle === handle {
            embeddedDurationProbeHandle = nil
        }
        embeddedDurationProbeLock.unlock()
    }

    private func stopEmbeddedDurationProbe() {
        embeddedDurationProbeLock.lock()
        embeddedDurationProbeEpoch += 1
        let handle = embeddedDurationProbeHandle
        handle?.cancelled = true
        embeddedDurationProbeHandle = nil
        embeddedDurationProbeLock.unlock()

        if let handle {
            terminatePreparationProcess(handle.process)
        }
    }

    private func handleEmbeddedFFmpegTermination(process: Process, status: Int32) {
        guard embeddedVideoProcess === process else { return }
        if isStopping || status == SIGTERM || status == SIGKILL {
            embeddedVideoProcess = nil
            embeddedVideoStderr.stop()
            embeddedAudioOutputActive = false
            return
        }

        let stderr = embeddedVideoStderr.data()
        embeddedVideoProcess = nil
        embeddedVideoStderr.stop()
        embeddedAudioOutputActive = false

        if status == 0 {
            // The bridge finishes writing while up to a lead's worth of
            // audio and video is still queued on the clock; let the refresh
            // timer end playback once the tail has actually played.
            embeddedAwaitingDrain = true
            refreshEmbeddedPlaybackClock()
            return
        }
        if embeddedPlaybackHasAudio,
           embeddedAudioExitIndicatesMissingAudio(stderr),
           let path = embeddedPlaybackPath {
            embeddedPlaybackHasAudio = false
            MarqueeLogger.player.info("embedded playback source has no audio stream")
            _ = startEmbeddedFFmpegPlayback(
                sourcePath: path,
                generation: loadGeneration,
                sidecarSubtitles: embeddedPlaybackSubtitles,
                startOffset: currentTime,
                preserveSurface: true
            )
            return
        }
        failEmbeddedPlayback("The embedded playback process exited unexpectedly. Marquee stayed open.")
    }

    private func embeddedAudioExitIndicatesMissingAudio(_ stderr: Data) -> Bool {
        let text = String(data: stderr, encoding: .utf8)?
            .lowercased() ?? ""
        return text.contains("output file does not contain any stream")
            || text.contains("output file #0 does not contain any stream")
            || text.contains("matches no streams")
    }

    private func failEmbeddedPlayback(_ message: String) {
        stopEmbeddedFFmpegPlayback(markStopping: false)
        failPlayback(message)
    }

    private func refreshEmbeddedPlaybackClock() {
        guard activeBackend == .ffmpegEmbedded,
              let presenter = embeddedPresenter else { return }

        // The synchronizer is the only clock: exact under pause, seek, and
        // rate changes, and identical to what sidecar subtitles align to.
        currentTime = presenter.currentSeconds
        presenter.recoverDisplayLayerIfNeeded()

        // Natural end waits for the queued tail to play out; the process
        // exits well before the last buffered frame is due.
        if embeddedAwaitingDrain, presenter.didDrainToEnd {
            embeddedAwaitingDrain = false
            stopEmbeddedFFmpegPlayback(markStopping: false)
            applyLifecycleEvent(.ended)
            emitPlaybackEndedIfNeeded(source: "ffmpeg-embedded-ended")
        }
    }

    private func seekEmbeddedFFmpeg(to seconds: Double) {
        guard let path = embeddedPlaybackPath else { return }
        let wasPaused = isPaused
        let target = max(0, seconds)
        applyLifecycleEvent(.seekRequested)
        _ = startEmbeddedFFmpegPlayback(
            sourcePath: path,
            generation: loadGeneration,
            sidecarSubtitles: embeddedPlaybackSubtitles,
            startOffset: target,
            preserveSurface: true
        )
        currentTime = target
        applyLifecycleEvent(.seekCompleted)
        if wasPaused {
            setPaused(true)
        }
    }

    private func stopEmbeddedFFmpegPlayback(markStopping: Bool = true, clearSurface: Bool = true) {
        if markStopping {
            isStopping = true
        }
        embeddedPlaybackRunID += 1
        stopEmbeddedDurationProbe()
        embeddedPlaybackTimer?.invalidate()
        embeddedPlaybackTimer = nil
        embeddedPresenter?.stop()
        embeddedPresenter = nil
        embeddedAwaitingDrain = false
        embeddedPlaybackPath = nil
        embeddedPlaybackSubtitles = []
        embeddedPlaybackHasAudio = true
        embeddedAudioOutputActive = false
        if clearSurface {
            clearEmbeddedFrameSurface()
        }
        embeddedVideoStderr.stop()

        let video = embeddedVideoProcess
        embeddedVideoProcess = nil
        if let video {
            terminateExternalPlayerProcess(video)
        }
    }

    // MARK: - mpv Backend

    @discardableResult
    private func ensureMpvCreated() -> Bool {
        if mpv != nil { return true }
        configureMoltenVKEnvironment()
        guard let handle = mpv_create() else {
            MarqueeLogger.player.error("mpv_create failed")
            return false
        }
        mpv = handle
        requestLogMessages(ProcessInfo.processInfo.environment["MARQUEE_MPV_LOG_LEVEL"] ?? "warn")
        configureIsolatedMpv()
        return true
    }

    private func shutdownMpv() {
        guard let handle = mpv else { return }
        let context = renderContext
        mpv = nil
        renderContext = nil
        isInitialized = false

        let freeContext = {
            if let context {
                mpv_render_context_set_update_callback(context, nil, nil)
                mpv_render_context_free(context)
            }
        }
        if Thread.isMainThread {
            freeContext()
        } else {
            DispatchQueue.main.sync(execute: freeContext)
        }

        let teardown = {
            mpv_set_wakeup_callback(handle, nil, nil)
            _ = mpv_command_string(handle, "quit")

            let deadline = Date().addingTimeInterval(2.0)
            var sawShutdown = false
            while Date() < deadline {
                guard let event = mpv_wait_event(handle, 0.05) else { continue }
                let id = event.pointee.event_id
                if id == MPV_EVENT_NONE { continue }
                if id == MPV_EVENT_SHUTDOWN {
                    sawShutdown = true
                    break
                }
            }

            if sawShutdown {
                mpv_destroy(handle)
            } else {
                mpv_terminate_destroy(handle)
            }
        }

        if DispatchQueue.getSpecific(key: mpvQueueKey) != nil {
            teardown()
        } else {
            mpvQueue.sync(execute: teardown)
        }
    }

    // MARK: - Render View Teardown

    /// Called from `MPVOGLView.viewWillMove(toWindow: nil)` so the service no
    /// longer references the layer after the SwiftUI/AppKit view disappears.
    func detachRenderView() {
        renderView = nil
        clearRenderUpdateCallback()
        stopEmbeddedBeforeRenderDetach()
        stopMpvBeforeRenderDetach()
    }

    // MARK: - mpv Configuration

    private func configureMoltenVKEnvironment() {
        setenv("MVK_CONFIG_USE_MTLHEAP", "0", 1)
        setenv("MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS", "0", 1)
    }

    private func configureIsolatedMpv() {
        // Keep embedded playback deterministic: no user config, no Lua UI scripts,
        // no network helpers, no standalone mpv input stack.
        setFlagOption("config", false)
        setFlagOption("load-scripts", false)
        setFlagOption("osc", false)
        setFlagOption("ytdl", false)
        setFlagOption("load-stats-overlay", false)
        setFlagOption("load-console", false)
        setOption("load-auto-profiles", "no")
        setFlagOption("load-positioning", false)
        setFlagOption("load-commands", false)
        setFlagOption("load-select", false)
        setFlagOption("load-context-menu", false)
        setFlagOption("input-default-bindings", false)
        setFlagOption("input-builtin-bindings", false)
        setFlagOption("input-vo-keyboard", false)
        setFlagOption("input-media-keys", false)
        setFlagOption("terminal", false)
        setFlagOption("cookies", false)
        setOption("title", "Marquee")
        setOption("force-media-title", "Marquee")

        // MoltenVK `wid` playback and OpenGL render contexts both crashed in
        // native GPU/driver code on older Intel Macs. Render non-AV containers
        // into app-owned memory through mpv's software render API instead.
        setOption("vo", mpvOptionOverride("MARQUEE_MPV_VO", defaultValue: "libmpv"))
        setOption("ao", mpvOptionOverride("MARQUEE_MPV_AO", defaultValue: "null"))
        setOption("profile", "sw-fast")
        setOption("hwdec", "no")
        setOption("vd-lavc-dr", "no")
        setOption("vd-lavc-threads", "1")
        setOption("sws-fast", "yes")
        setOption("scale", "bilinear")
        setOption("cscale", "bilinear")
        setOption("dscale", "bilinear")
        setOption("dither-depth", "no")
        setOption("temporal-dither", "no")
        setOption("correct-downscaling", "no")
        setOption("sigmoid-upscaling", "no")
        setOption("linear-downscaling", "no")
        setOption("interpolation", "no")
        setOption("deband", "no")
        setOption("blend-subtitles", "no")
        setOption("icc-profile-auto", "no")
        setOption("use-embedded-icc-profile", "no")
        setOption("tone-mapping", "clip")
        setOption("gamut-mapping-mode", "clip")
        setOption("target-colorspace-hint", "no")
        setOption("keep-open", "no")
        setOption("idle", "yes")
        setOption("force-window", "no")
        setOption("audio-channels", "auto-safe")
        setOption("subs-fallback", "yes")
        setOption("subs-match-os-language", "yes")
        setOption("network-timeout", "3")
        setOption("autoload-files", "no")

        // DIAGNOSTIC 2026-04-28: disable subtitles to isolate libass heap-corruption crash
        // seen in update_subtitles → ass_process_chunk → strdup. If Wonder.mp4 plays
        // with these set, libass is the trigger and we iterate from there.
        setOption("sid", "no")
        setOption("sub-auto", "no")
    }

    private func enforceRuntimeIsolation() {
        setFlagProperty("osc", false)
        setFlagProperty("ytdl", false)
        setFlagProperty("load-stats-overlay", false)
        setFlagProperty("load-console", false)
        setStringProperty("load-auto-profiles", "no")
        setFlagProperty("load-positioning", false)
        setFlagProperty("load-commands", false)
        setFlagProperty("load-select", false)
        setFlagProperty("load-context-menu", false)
        setFlagProperty("load-scripts", false)
    }

    private func mpvOptionOverride(_ environmentKey: String, defaultValue: String) -> String {
        guard let value = ProcessInfo.processInfo.environment[environmentKey],
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return defaultValue
        }
        MarqueeLogger.player.info("mpv option override \(environmentKey, privacy: .public)=\(value, privacy: .public)")
        return value
    }

    private func logIsolationState() {
        let clients = getString("client-list") ?? "unavailable"
        let autoProfiles = getString("load-auto-profiles") ?? "unavailable"
        MarqueeLogger.player.info("mpv client-list after init: \(clients, privacy: .public)")
        MarqueeLogger.player.info("mpv load-auto-profiles after init: \(autoProfiles, privacy: .public)")

        if clients.contains("auto_profiles") || clients.contains("@auto_profiles") {
            MarqueeLogger.player.error("mpv auto_profiles client is still loaded after isolation")
        }
        if clients.contains("@osc") || clients.contains("osc.lua") {
            MarqueeLogger.player.error("mpv osc client is still loaded after isolation")
        }
        if autoProfiles != "no" && autoProfiles != "0" {
            MarqueeLogger.player.error("mpv load-auto-profiles is \(autoProfiles, privacy: .public), expected no")
        }
    }

    // MARK: - Render Attachment

    func attachRenderView(_ view: MPVOGLView) {
        if let renderView, renderView !== view {
            return
        }
        renderView = view

        if activeBackend.usesAVFoundation {
            view.showAVPlayer(avPlayer)
            applyLifecycleEvent(.rendererReady)
            return
        }

        if activeBackend == .ffmpegEmbedded {
            view.showExternalFrameSurface(clearExistingFrame: false)
            // A run can start before the render view exists; late attach
            // hands the layer to the live presenter so playback never runs
            // audio-over-black.
            embeddedPresenter?.attachDisplayLayer(view.embeddedSampleBufferLayer)
            applyLifecycleEvent(.rendererReady)
            return
        }

        guard activeBackend == .mpv else { return }
        guard ensureMpvCreated(), let mpv else { return }
        view.showMpvSurface()

        if !isInitialized {
            let initStatus = mpv_initialize(mpv)
            if initStatus < 0 {
                MarqueeLogger.player.error("mpv_initialize failed: \(String(cString: mpv_error_string(initStatus)))")
                return
            }
            isInitialized = true
            enforceRuntimeIsolation()
            logIsolationState()
            observeProperties()
            installWakeupCallback(on: mpv)
        }

        if renderContext == nil {
            guard createSoftwareRenderContext(mpv: mpv) else { return }
        } else if let renderContext {
            installRenderUpdateCallback(on: renderContext)
        }

        mpvQueue.async { [weak self] in
            self?.applyLifecycleEvent(.rendererReady)
        }

        if let pending = pendingLoadPath {
            pendingLoadPath = nil
            let generation = loadGeneration
            MarqueeLogger.player.info("attachRenderView flushing pending loadFile path=\(pending, privacy: .public)")
            enqueueLoadFile(url: pending, generation: generation)
        }
    }

    private func createSoftwareRenderContext(mpv: OpaquePointer) -> Bool {
        var ctx: OpaquePointer?
        MPV_RENDER_API_TYPE_SW.withCString { apiPtr in
            let api = UnsafeMutableRawPointer(mutating: apiPtr)
            var renderParams = [
                mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: api),
                mpv_render_param()
            ]
            let status = mpv_render_context_create(&ctx, mpv, &renderParams)
            if status < 0 {
                MarqueeLogger.player.error("mpv_render_context_create failed: \(String(cString: mpv_error_string(status)))")
            }
        }

        guard let ctx else { return false }
        renderContext = ctx
        installRenderUpdateCallback(on: ctx)
        return true
    }

    private func installRenderUpdateCallback(on renderContext: OpaquePointer) {
        let serviceCtx = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        mpv_render_context_set_update_callback(renderContext, mpvUpdate, serviceCtx)
    }

    private func clearRenderUpdateCallback() {
        guard let renderContext else { return }
        mpv_render_context_set_update_callback(renderContext, nil, nil)
    }

    private func freeRenderContext() {
        guard let renderContext else { return }
        clearRenderUpdateCallback()
        mpv_render_context_free(renderContext)
        self.renderContext = nil
    }

    private func installWakeupCallback(on mpv: OpaquePointer) {
        let callbackContext = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        mpv_set_wakeup_callback(mpv, mpvWakeup, callbackContext)
    }

    // MARK: - Property Observation

    private func observeProperties() {
        guard let mpv else { return }
        mpv_observe_property(mpv, 0, "time-pos", MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 0, "duration", MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 0, "pause", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 0, "volume", MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 0, "mute", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 0, "speed", MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 0, "current-tracks/audio/id", MPV_FORMAT_INT64)
        mpv_observe_property(mpv, 0, "current-tracks/sub/id", MPV_FORMAT_INT64)
        mpv_observe_property(mpv, 0, "sub-visibility", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 0, "eof-reached", MPV_FORMAT_FLAG)
    }

    // MARK: - Event Loop

    fileprivate func readEvents() {
        mpvQueue.async { [weak self] in
            guard let self else { return }
            while let mpv = self.mpv {
                guard let event = mpv_wait_event(mpv, 0) else { break }
                let id = event.pointee.event_id
                if id == MPV_EVENT_NONE { break }
                self.handleEvent(event)
                if id == MPV_EVENT_SHUTDOWN { break }
            }
        }
    }

    private func handleEvent(_ event: UnsafeMutablePointer<mpv_event>) {
        switch event.pointee.event_id {
        case MPV_EVENT_PROPERTY_CHANGE:
            let dataPtr = OpaquePointer(event.pointee.data)
            guard let prop = UnsafePointer<mpv_event_property>(dataPtr)?.pointee else { return }
            let name = String(cString: prop.name)
            handlePropertyChange(name: name, format: prop.format, data: prop.data)

        case MPV_EVENT_END_FILE:
            let dataPtr = OpaquePointer(event.pointee.data)
            var isEOF = false
            var isError = false
            if let endFile = UnsafePointer<mpv_event_end_file>(dataPtr)?.pointee {
                let reason = endFile.reason
                isEOF = reason.rawValue == 0
                isError = reason.rawValue == 4
                let errCode = endFile.error
                let errStr = errCode != 0 ? String(cString: mpv_error_string(errCode)) : "ok"
                MarqueeLogger.player.error("MPV_EVENT_END_FILE reason=\(reason.rawValue, privacy: .public) error=\(errStr, privacy: .public)")
            }
            DispatchQueue.main.async { [weak self] in
                self?.awaitingStartFile = false
            }
            if isEOF {
                applyLifecycleEvent(.ended)
                emitPlaybackEndedIfNeeded(source: "end-file")
            } else if isError {
                applyLifecycleEvent(.fail("end-file"))
            } else {
                applyLifecycleEvent(.stop)
            }

        case MPV_EVENT_LOG_MESSAGE:
            let dataPtr = OpaquePointer(event.pointee.data)
            if let msg = UnsafePointer<mpv_event_log_message>(dataPtr)?.pointee {
                let prefix = String(cString: msg.prefix)
                let level = String(cString: msg.level)
                let text = String(cString: msg.text).trimmingCharacters(in: .newlines)
                MarqueeLogger.player.info("mpv [\(level, privacy: .public)] \(prefix, privacy: .public): \(text, privacy: .public)")
            }

        case MPV_EVENT_START_FILE:
            DispatchQueue.main.async { [weak self] in
                self?.awaitingStartFile = false
            }
            applyLifecycleEvent(.startFile)
            MarqueeLogger.player.info("mpv event: start-file")

        case MPV_EVENT_FILE_LOADED:
            DispatchQueue.main.async { [weak self] in
                self?.awaitingStartFile = false
            }
            applyLifecycleEvent(.fileLoaded)
            MarqueeLogger.player.info("mpv event: file-loaded")

        case MPV_EVENT_HOOK:
            let dataPtr = OpaquePointer(event.pointee.data)
            if let hook = UnsafePointer<mpv_event_hook>(dataPtr)?.pointee {
                let name = hook.name.map { String(cString: $0) } ?? "unknown"
                MarqueeLogger.player.error("mpv hook received on app client: \(name, privacy: .public); continuing")
                if let mpv {
                    let status = mpv_hook_continue(mpv, hook.id)
                    if status < 0 {
                        MarqueeLogger.player.error("mpv_hook_continue failed: \(String(cString: mpv_error_string(status)))")
                    }
                }
            }

        case MPV_EVENT_SHUTDOWN:
            MarqueeLogger.player.info("mpv shutdown")

        default:
            let id = event.pointee.event_id
            if let cstr = mpv_event_name(id) {
                let name = String(cString: cstr)
                MarqueeLogger.player.info("mpv event: \(name, privacy: .public) (\(id.rawValue, privacy: .public))")
            }
        }
    }

    private func handlePropertyChange(name: String, format: mpv_format, data: UnsafeMutableRawPointer?) {
        switch name {
        case "time-pos":
            if format == MPV_FORMAT_DOUBLE, let v = data?.assumingMemoryBound(to: Double.self).pointee {
                DispatchQueue.main.async { [weak self] in self?.currentTime = v }
            }
        case "duration":
            if format == MPV_FORMAT_DOUBLE, let v = data?.assumingMemoryBound(to: Double.self).pointee {
                DispatchQueue.main.async { [weak self] in self?.duration = v }
            }
        case "pause":
            if format == MPV_FORMAT_FLAG, let v = data?.assumingMemoryBound(to: Int32.self).pointee {
                DispatchQueue.main.async { [weak self] in self?.isPaused = (v != 0) }
            }
        case "volume":
            if format == MPV_FORMAT_DOUBLE, let v = data?.assumingMemoryBound(to: Double.self).pointee {
                DispatchQueue.main.async { [weak self] in self?.volume = v }
            }
        case "mute":
            if format == MPV_FORMAT_FLAG, let v = data?.assumingMemoryBound(to: Int32.self).pointee {
                DispatchQueue.main.async { [weak self] in self?.isMuted = (v != 0) }
            }
        case "speed":
            if format == MPV_FORMAT_DOUBLE, let v = data?.assumingMemoryBound(to: Double.self).pointee {
                DispatchQueue.main.async { [weak self] in self?.playbackSpeed = Float(v) }
            }
        case "sub-visibility":
            if format == MPV_FORMAT_FLAG, let v = data?.assumingMemoryBound(to: Int32.self).pointee {
                DispatchQueue.main.async { [weak self] in self?.subtitlesEnabled = (v != 0) }
            }
        case "eof-reached":
            // Keep this as a secondary EOF signal for mpv builds that update the
            // property before emitting END_FILE.
            if format == MPV_FORMAT_FLAG, let v = data?.assumingMemoryBound(to: Int32.self).pointee, v != 0 {
                applyLifecycleEvent(.ended)
                emitPlaybackEndedIfNeeded(source: "eof-reached")
            }
        case "current-tracks/audio/id", "current-tracks/sub/id":
            self.refreshCurrentTracks()
        default:
            break
        }
    }

    // MARK: - Track Refresh

    // Both of these run on the event queue. mpv property reads are safe there
    // (no main-thread mp_dispatch_lock deadlock). UI assignments are bounced to main.
    private func refreshTrackLists() {
        guard let json = getString("track-list"),
              let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }

        var audio: [AudioTrack] = []
        let subs: [SubtitleTrack] = externalSubtitleTracks

        for track in arr {
            guard let type = track["type"] as? String,
                  let id = track["id"] as? Int else { continue }
            let lang = track["lang"] as? String
            let title = track["title"] as? String
            let codec = track["codec"] as? String

            let displayName: String = {
                var parts: [String] = []
                if let title, !title.isEmpty {
                    parts.append(title)
                } else if let lang {
                    parts.append(Locale.current.localizedString(forLanguageCode: lang) ?? lang)
                } else {
                    parts.append("Track \(id)")
                }
                if let codec, !codec.isEmpty {
                    parts.append("(\(codec))")
                }
                return parts.joined(separator: " ")
            }()

            switch type {
            case "audio":
                audio.append(AudioTrack(id: "\(id)", displayName: displayName, languageCode: lang))
            case "sub":
                // Embedded subtitles still route through libass inside the patched
                // libmpv build, which is a known heap-corruption path. Keep the
                // user-facing subtitle menu limited to sidecar SRT overlay tracks
                // until that native path is proven stable.
                continue
            default:
                break
            }
        }

        let aid = getInt64("aid")
        let sid = getInt64("sid")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.availableAudioTracks = audio
            self.availableSubtitleTracks = subs
            self.hasSubtitles = !subs.isEmpty
            self.currentAudioTrack = audio.first { $0.id == "\(aid)" }
            if self.currentSubtitleTrack?.isExternal != true {
                self.currentSubtitleTrack = subs.first { $0.id == "\(sid)" }
            }
        }
    }

    private func refreshCurrentTracks() {
        let aid = getInt64("aid")
        let sid = getInt64("sid")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.currentAudioTrack = self.availableAudioTracks.first { $0.id == "\(aid)" }
            if self.currentSubtitleTrack?.isExternal != true {
                self.currentSubtitleTrack = self.availableSubtitleTracks.first { $0.id == "\(sid)" }
            }
        }
    }

    // MARK: - PlayerServiceProtocol Commands

    func loadFile(_ path: String) {
        guard FileManager.default.fileExists(atPath: path) else {
            MarqueeLogger.player.error("loadFile missing local file path=\(path, privacy: .public)")
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.playbackErrorMessage = nil
        }
        cancelActivePreparation()
        loadGeneration += 1
        awaitingStartFile = true
        isStopping = false
        emittedPlaybackEndedGeneration = nil

        let url = URL(fileURLWithPath: path).absoluteString
        let generation = loadGeneration
        let sidecarSubtitles = externalSRTSubtitleTracks(forVideoAt: path)

        switch playbackRoute(for: path) {
        case .avFoundation:
            loadAVFoundationFile(
                path: path,
                sidecarSubtitles: sidecarSubtitles,
                fallbackToEmbeddedBridge: shouldUseEmbeddedBridge()
            )
            return
        case .preparedAVFoundation:
            loadRemuxedAVFoundationFile(
                sourcePath: path,
                generation: generation,
                sidecarSubtitles: sidecarSubtitles
            )
            return
        case .externalFFplay:
            loadExternalFFplayFile(
                sourcePath: path,
                generation: generation,
                sidecarSubtitles: sidecarSubtitles
            )
            return
        case .ffmpegEmbedded:
            loadEmbeddedFFmpegFile(
                sourcePath: path,
                generation: generation,
                sidecarSubtitles: sidecarSubtitles
            )
            return
        case .mpv:
            loadMpvFile(
                sourcePath: path,
                url: url,
                generation: generation,
                sidecarSubtitles: sidecarSubtitles,
                backend: .mpv
            )
            return
        case .unsupported:
            failUnsupportedContainer(path: path)
            return
        }
    }

    private func loadMpvFile(
        sourcePath: String,
        url: String,
        generation: Int,
        sidecarSubtitles: [SubtitleTrack],
        backend: PlaybackBackend
    ) {
        stopAVFoundation()
        stopExternalPlayer(markStopping: false)
        stopEmbeddedFFmpegPlayback(markStopping: false)
        setActiveBackend(backend)
        guard ensureMpvCreated() else {
            failUnsupportedContainer(path: sourcePath)
            return
        }
        if let renderView {
            attachRenderView(renderView)
        }
        let isReadyToLoad = isInitialized && renderView != nil

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.advanceSubtitleSelectionGeneration()
            self.playbackSpeed = 1.0
            self.availableSubtitleTracks = sidecarSubtitles
            self.currentSubtitleTrack = nil
            self.currentSubtitleEntries = []
            self.subtitlesEnabled = false
            self.hasSubtitles = !sidecarSubtitles.isEmpty
        }

        mpvQueue.async { [weak self] in
            guard let self else { return }
            self.externalSubtitleTracks = sidecarSubtitles
            if self.isInitialized {
                self.enforceRuntimeIsolation()
            }
            self.applyLifecycleEvent(.loadRequested)
        }

        MarqueeLogger.player.info("loadFile url=\(url, privacy: .public) exists=true mpv=\(self.mpv != nil, privacy: .public) render=\(isReadyToLoad, privacy: .public)")
        if isReadyToLoad {
            enqueueLoadFile(url: url, generation: generation)
        } else {
            pendingLoadPath = url
            MarqueeLogger.player.info("loadFile deferred until Metal render view attaches")
        }
    }

    func togglePause() {
        setPaused(!isPaused)
    }

    /// Set pause state unconditionally. Used by dismiss to mute audio before
    /// the view is torn down so the user doesn't hear a tail of audio after
    /// the loader covers the player.
    func setPaused(_ paused: Bool) {
        if activeBackend.usesAVFoundation {
            if paused {
                avPlayer.pause()
                isPaused = true
                applyLifecycleEvent(.pause)
            } else {
                avPlayer.rate = avSavedSpeed
                isPaused = false
                applyLifecycleEvent(.resume)
            }
            return
        }

        if activeBackend == .externalFFplay {
            setExternalPlayerPaused(paused, updateLifecycle: true)
            return
        }

        if activeBackend == .ffmpegEmbedded {
            setEmbeddedFFmpegPaused(paused, updateLifecycle: true)
            return
        }

        setMpvPaused(paused, updateLifecycle: true)
    }

    private func setExternalPlayerPaused(_ paused: Bool, updateLifecycle: Bool) {
        guard let process = externalPlayerProcess, process.isRunning else { return }
        if paused {
            guard externalPauseStartedAt == nil else { return }
            refreshExternalPlaybackClock()
            externalPauseStartedAt = Date()
            kill(process.processIdentifier, SIGSTOP)
            isPaused = true
            if updateLifecycle {
                applyLifecycleEvent(.pause)
            }
        } else {
            guard externalPauseStartedAt != nil else { return }
            externalPlaybackStartOffset = currentTime
            externalPlaybackStartedAt = Date()
            externalPauseStartedAt = nil
            kill(process.processIdentifier, SIGCONT)
            isPaused = false
            if updateLifecycle {
                applyLifecycleEvent(.resume)
            }
        }
    }

    private func setMpvPaused(_ paused: Bool, updateLifecycle: Bool) {
        mpvQueue.async { [weak self] in
            guard let self, let mpv = self.mpv else { return }
            var flag: Int32 = paused ? 1 : 0
            let status = mpv_set_property(mpv, "pause", MPV_FORMAT_FLAG, &flag)
            if status >= 0, updateLifecycle {
                self.applyLifecycleEvent(paused ? .pause : .resume)
            }
        }
    }

    private func setEmbeddedFFmpegPaused(_ paused: Bool, updateLifecycle: Bool) {
        // Pause is a clock stop, not a process signal: the synchronizer rate
        // drops to zero, frame and audio intake stop being consumed, and the
        // bridge blocks on its own pipes. Resume restarts the clock in
        // place — the process, its decode state, and the picture all hold.
        guard let presenter = embeddedPresenter, presenter.isPaused != paused else { return }
        presenter.setPaused(paused)
        refreshEmbeddedPlaybackClock()
        isPaused = paused
        if updateLifecycle {
            applyLifecycleEvent(paused ? .pause : .resume)
        }
    }

    func seek(to seconds: Double) {
        let target = clampedSeekTime(seconds)

        if activeBackend.usesAVFoundation {
            applyLifecycleEvent(.seekRequested)
            let time = CMTime(seconds: target, preferredTimescale: 600)
            avPlayer.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                self?.applyLifecycleEvent(.seekCompleted)
            }
            return
        }

        if activeBackend == .externalFFplay {
            seekExternalFFplay(to: target)
            return
        }

        if activeBackend == .ffmpegEmbedded {
            seekEmbeddedFFmpeg(to: target)
            return
        }

        seekMpv(amount: target, flags: "absolute+exact")
    }

    func seekRelative(_ seconds: Double) {
        if activeBackend.usesAVFoundation {
            let current = avPlayer.currentTime().seconds
            seek(to: max(0, current + seconds))
            return
        }

        if activeBackend == .externalFFplay {
            seekExternalFFplay(to: max(0, currentTime + seconds))
            return
        }

        if activeBackend == .ffmpegEmbedded {
            seekEmbeddedFFmpeg(to: max(0, currentTime + seconds))
            return
        }

        seekMpv(amount: seconds, flags: "relative+keyframes")
    }

    func beginInteractiveScrub() {
        guard activeBackend == .mpv else { return }
        mpvQueue.async { [weak self] in
            self?.setStringProperty("hr-seek", "no")
        }
    }

    func previewInteractiveScrub(to seconds: Double) {
        currentTime = clampedSeekTime(seconds)
    }

    func finishInteractiveScrub(to seconds: Double, resumePlayback: Bool = false) {
        let target = clampedSeekTime(seconds)
        if activeBackend.usesAVFoundation {
            applyLifecycleEvent(.seekRequested)
            let time = CMTime(seconds: target, preferredTimescale: 600)
            avPlayer.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                guard let self else { return }
                self.applyLifecycleEvent(.seekCompleted)
                if resumePlayback {
                    self.setPaused(false)
                }
            }
            return
        }

        if activeBackend == .mpv {
            seekMpv(amount: target, flags: "absolute+exact")
            mpvQueue.async { [weak self] in
                self?.setStringProperty("hr-seek", "absolute")
            }
            if resumePlayback {
                setPaused(false)
            }
        } else {
            seek(to: target)
            if resumePlayback {
                setPaused(false)
            }
        }
    }

    func setVolume(_ value: Double) {
        if activeBackend.usesAVFoundation {
            avPlayer.volume = Float(max(0, min(100, value)) / 100.0)
            return
        }

        if activeBackend == .externalFFplay {
            volume = max(0, min(100, value))
            return
        }

        if activeBackend == .ffmpegEmbedded {
            volume = max(0, min(100, value))
            embeddedPresenter?.volume = Float(max(0, min(100, volume)) / 100.0)
            return
        }

        mpvQueue.async { [weak self] in
            guard let self, let mpv = self.mpv else { return }
            var v = max(0, min(100, value))
            mpv_set_property(mpv, "volume", MPV_FORMAT_DOUBLE, &v)
        }
    }

    private func clampedSeekTime(_ seconds: Double) -> Double {
        guard seconds.isFinite else { return 0 }
        let lowerBounded = max(0, seconds)
        guard duration.isFinite, duration > 0 else { return lowerBounded }
        return min(lowerBounded, duration)
    }

    private func seekMpv(amount: Double, flags: String) {
        mpvQueue.async { [weak self] in
            guard let self else { return }
            self.applyLifecycleEvent(.seekRequested)
            self.commandAsync("seek", args: [String(amount), flags])
            self.applyLifecycleEvent(.seekCompleted)
        }
    }

    func toggleMute() {
        if activeBackend.usesAVFoundation {
            avPlayer.isMuted.toggle()
            return
        }

        if activeBackend == .externalFFplay {
            isMuted.toggle()
            return
        }

        if activeBackend == .ffmpegEmbedded {
            isMuted.toggle()
            embeddedPresenter?.isMuted = isMuted
            return
        }

        let muted = isMuted
        mpvQueue.async { [weak self] in
            guard let self, let mpv = self.mpv else { return }
            var flag: Int32 = muted ? 0 : 1
            mpv_set_property(mpv, "mute", MPV_FORMAT_FLAG, &flag)
        }
    }

    func toggleSubtitles() {
        if subtitlesEnabled {
            selectSubtitleTrack(nil)
        } else if let firstTrack = availableSubtitleTracks.first {
            selectSubtitleTrack(firstTrack)
        }
    }

    func selectSubtitleTrack(_ track: SubtitleTrack?) {
        let selectionGeneration = advanceSubtitleSelectionGeneration()
        guard let track else {
            if activeBackend.usesAVFoundation {
                if let item = avPlayer.currentItem,
                   let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: .legible) {
                    item.select(nil, in: group)
                }
                DispatchQueue.main.async { [weak self] in
                    self?.currentSubtitleTrack = nil
                    self?.currentSubtitleEntries = []
                    self?.subtitlesEnabled = false
                }
                return
            }

            DispatchQueue.main.async { [weak self] in
                self?.currentSubtitleTrack = nil
                self?.currentSubtitleEntries = []
                self?.subtitlesEnabled = false
            }
            mpvQueue.async { [weak self] in
                guard let self, let mpv = self.mpv else { return }
                mpv_set_property_string(mpv, "sid", "no")
                var off: Int32 = 0
                mpv_set_property(mpv, "sub-visibility", MPV_FORMAT_FLAG, &off)
            }
            return
        }

        if track.isExternal, let path = track.externalPath {
            if activeBackend.usesAVFoundation,
               let item = avPlayer.currentItem,
               let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: .legible) {
                item.select(nil, in: group)
            }

#if DEBUG
            let parseDelay = subtitleParseDelayForHarness
#else
            let parseDelay: TimeInterval = 0
#endif
            DispatchQueue.global(qos: .utility).async { [weak self] in
                if parseDelay > 0 {
                    Thread.sleep(forTimeInterval: parseDelay)
                }
                let entries = SRTParser.parse(fileAt: path)
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          self.subtitleSelectionGeneration == selectionGeneration else { return }
                    self.currentSubtitleTrack = track
                    self.currentSubtitleEntries = entries
                    self.subtitlesEnabled = true
                    self.hasSubtitles = true
                }
            }
            return
        }

        if activeBackend.usesAVFoundation {
            guard let item = avPlayer.currentItem,
                  let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: .legible),
                  let index = availableSubtitleTracks.filter({ !$0.isExternal }).firstIndex(of: track),
                  group.options.indices.contains(index) else { return }
            item.select(group.options[index], in: group)
            currentSubtitleEntries = []
            currentSubtitleTrack = track
            subtitlesEnabled = true
            return
        }

        mpvQueue.async { [weak self] in
            guard let self, let mpv = self.mpv, var id = Int64(track.id) else { return }
            mpv_set_property(mpv, "sid", MPV_FORMAT_INT64, &id)
            var on: Int32 = 1
            mpv_set_property(mpv, "sub-visibility", MPV_FORMAT_FLAG, &on)
        }
    }

    @discardableResult
    private func advanceSubtitleSelectionGeneration() -> Int {
        subtitleSelectionGeneration &+= 1
        return subtitleSelectionGeneration
    }

    func selectAudioTrack(_ track: AudioTrack) {
        if activeBackend.usesAVFoundation {
            guard let item = avPlayer.currentItem,
                  let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: .audible),
                  let index = availableAudioTracks.firstIndex(of: track),
                  group.options.indices.contains(index) else { return }
            item.select(group.options[index], in: group)
            currentAudioTrack = track
            return
        }

        mpvQueue.async { [weak self] in
            guard let self, let mpv = self.mpv, var id = Int64(track.id) else { return }
            mpv_set_property(mpv, "aid", MPV_FORMAT_INT64, &id)
        }
    }

    func setPlaybackSpeed(_ speed: Float) {
        if activeBackend.usesAVFoundation {
            let clamped = max(0.5, min(3.0, speed))
            avSavedSpeed = clamped
            playbackSpeed = clamped
            if avPlayer.rate != 0 {
                avPlayer.rate = clamped
            }
            return
        }

        if activeBackend == .externalFFplay {
            refreshExternalPlaybackClock()
            externalPlaybackStartOffset = currentTime
            externalPlaybackStartedAt = Date()
            playbackSpeed = max(0.5, min(3.0, speed))
            return
        }

        if activeBackend == .ffmpegEmbedded {
            // The synchronizer clock retimes in place: renderers follow the
            // rate and the audio renderer pitch-corrects. The bridge decodes
            // as fast as backpressure allows, so speed needs no relaunch.
            let clamped = max(0.5, min(2.0, speed))
            playbackSpeed = clamped
            embeddedPresenter?.setPlaybackRate(clamped)
            return
        }

        mpvQueue.async { [weak self] in
            guard let self, let mpv = self.mpv else { return }
            var v = Double(max(0.5, min(3.0, speed)))
            mpv_set_property(mpv, "speed", MPV_FORMAT_DOUBLE, &v)
        }
    }

    func stop() {
        isStopping = true
        awaitingStartFile = false
        cancelActivePreparation()
        preparationMessage = nil
        if activeBackend.usesAVFoundation {
            stopAVFoundation()
            applyLifecycleEvent(.stop)
            return
        }

        if activeBackend == .externalFFplay {
            stopExternalPlayer()
            applyLifecycleEvent(.stop)
            return
        }

        if activeBackend == .ffmpegEmbedded {
            stopEmbeddedFFmpegPlayback()
            applyLifecycleEvent(.stop)
            return
        }

        mpvQueue.async { [self] in
            self.command("stop")
            self.applyLifecycleEvent(.stop)
        }
    }

    private func stopEmbeddedBeforeRenderDetach() {
        guard activeBackend == .ffmpegEmbedded else { return }
        stopEmbeddedFFmpegPlayback()
        applyLifecycleEvent(.stop)
    }

    private func stopMpvBeforeRenderDetach() {
        guard activeBackend == .mpv, mpv != nil else { return }
        isStopping = true
        awaitingStartFile = false

        let stopWork = { [self] in
            self.command("stop")
            self.applyLifecycleEvent(.stop)
        }

        if DispatchQueue.getSpecific(key: mpvQueueKey) != nil {
            stopWork()
        } else {
            mpvQueue.sync(execute: stopWork)
        }
    }

    func shutdown() {
        cancelActivePreparation()
        if let avTimeObserver {
            avPlayer.removeTimeObserver(avTimeObserver)
            self.avTimeObserver = nil
        }
        stopAVFoundation()
        stopExternalPlayer()
        stopEmbeddedFFmpegPlayback()
        shutdownMpv()
        setActiveBackend(.none)
        preparationMessage = nil
        setPlaybackNotice(nil)
        renderView = nil

        displaySleepAssertionLock.lock()
        if displaySleepAssertionID != 0 {
            IOPMAssertionRelease(displaySleepAssertionID)
            displaySleepAssertionID = 0
        }
        displaySleepAssertionLock.unlock()
    }

#if DEBUG
    func verifyInjectSubtitleTracksForHarness(_ tracks: [SubtitleTrack]) {
        advanceSubtitleSelectionGeneration()
        availableSubtitleTracks = tracks
        currentSubtitleTrack = nil
        currentSubtitleEntries = []
        subtitlesEnabled = false
        hasSubtitles = !tracks.isEmpty
    }

    func verifySetSubtitleParseDelayForHarness(_ delay: TimeInterval) {
        subtitleParseDelayForHarness = delay
    }

    var verifyBackendDescriptionForHarness: String {
        playbackBackendDescription
    }

    var verifyExternalPlayerIsRunningForHarness: Bool {
        activeBackend == .externalFFplay && externalPlayerProcess?.isRunning == true
    }

    var verifyEmbeddedBridgeHasRunningProcessForHarness: Bool {
        embeddedVideoProcess?.isRunning == true
    }

    var verifyEmbeddedAudioProcessIsRunningForHarness: Bool {
        activeBackend == .ffmpegEmbedded
            && embeddedAudioOutputActive
            && embeddedVideoProcess?.isRunning == true
            && embeddedPresenter?.verifyAudioIsActiveForHarness == true
    }

    var verifyEmbeddedAudioArgumentsForHarness: [String] {
        embeddedVideoProcess?.arguments ?? []
    }

    var verifyEmbeddedBridgeProcessIdentifierForHarness: Int32? {
        guard activeBackend == .ffmpegEmbedded,
              let process = embeddedVideoProcess,
              process.isRunning else { return nil }
        return process.processIdentifier
    }

    var verifyDisplaySleepAssertionHeldForHarness: Bool {
        displaySleepAssertionLock.lock()
        defer { displaySleepAssertionLock.unlock() }
        return displaySleepAssertionID != 0
    }

    var verifyEmbeddedLastFrameVisibleForHarness: Bool {
        embeddedPresenter?.verifyLastFrameVisibleForHarness == true
    }

    var verifyEmbeddedAudioPipelineActiveForHarness: Bool {
        embeddedPresenter?.verifyAudioIsActiveForHarness == true
    }

    var verifyEmbeddedAudioPipelineDegradedForHarness: Bool {
        embeddedPresenter?.verifyAudioFailedForHarness == true
    }

    var verifyEmbeddedClockIsAnchoredForHarness: Bool {
        embeddedPresenter?.verifyClockIsAnchoredForHarness == true
    }
#endif

    // MARK: - Lifecycle / Queued Operations

    private func enqueueLoadFile(url: String, generation: Int) {
        mpvQueue.async { [weak self] in
            guard let self else { return }
            var speed: Double = 1.0
            if let mpv = self.mpv {
                mpv_set_property(mpv, "speed", MPV_FORMAT_DOUBLE, &speed)
            }
            self.enforceRuntimeIsolation()
            self.command("loadfile", args: [url, "replace"])
            self.scheduleStartFileWatchdog(generation: generation, url: url)
        }
    }

    private func applyLifecycleEvent(_ event: PlaybackLifecycleEvent) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.applyLifecycleEvent(event)
            }
            return
        }

        do {
            let next = try stateMachine.apply(event)
            lifecycleState = next
        } catch {
            MarqueeLogger.player.error("playback lifecycle rejected \(String(describing: event), privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Display Sleep Assertion

    /// AVFoundation prevents display idle-dim on its own, but the ffmpeg
    /// bridge and mpv backends render into plain layers the OS considers
    /// idle. Hold a display-sleep assertion whenever any backend is actively
    /// presenting so the screen no longer dims mid-film and pops back on
    /// remote input.
    private func updateDisplaySleepAssertion() {
        displaySleepAssertionLock.lock()
        defer { displaySleepAssertionLock.unlock() }

        let shouldHold = !isPaused
            && (lifecycleState == .playing || lifecycleState == .seeking)

        if shouldHold, displaySleepAssertionID == 0 {
            var assertionID = IOPMAssertionID(0)
            let status = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Marquee video playback" as CFString,
                &assertionID
            )
            if status == kIOReturnSuccess {
                displaySleepAssertionID = assertionID
            } else {
                MarqueeLogger.player.error("display sleep assertion failed status=\(status)")
            }
        } else if !shouldHold, displaySleepAssertionID != 0 {
            IOPMAssertionRelease(displaySleepAssertionID)
            displaySleepAssertionID = 0
        }
    }

    private func failPlayback(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.playbackErrorMessage = message
        }
        applyLifecycleEvent(.fail(message))
        MarqueeLogger.player.error("playback failed: \(message, privacy: .public)")
    }

    private func emitPlaybackEndedIfNeeded(source: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  !self.isStopping,
                  self.emittedPlaybackEndedGeneration != self.loadGeneration else { return }

            self.emittedPlaybackEndedGeneration = self.loadGeneration
            MarqueeLogger.player.info("playback ended via \(source, privacy: .public)")
            self.onPlaybackEnded?()
        }
    }

    private func externalSRTSubtitleTracks(forVideoAt path: String) -> [SubtitleTrack] {
        SubtitleDiscovery.discover(forVideoAt: path)
            .filter { $0.format == .srt }
            .enumerated()
            .map { index, subtitle in
                SubtitleTrack(
                    id: "external-srt-\(index)",
                    displayName: subtitle.displayName,
                    isExternal: true,
                    externalPath: subtitle.path
                )
            }
    }

    // MARK: - mpv Helpers

    private func requestLogMessages(_ minLevel: String) {
        guard let mpv else { return }
        let status = mpv_request_log_messages(mpv, minLevel)
        if status < 0 {
            MarqueeLogger.player.error("mpv_request_log_messages \(minLevel) failed: \(String(cString: mpv_error_string(status)))")
        }
    }

    private func setOption(_ name: String, _ value: String) {
        guard let mpv else { return }
        let status = mpv_set_option_string(mpv, name, value)
        if status < 0 {
            MarqueeLogger.player.error("set_option \(name)=\(value) failed: \(String(cString: mpv_error_string(status)))")
        }
    }

    private func setFlagOption(_ name: String, _ enabled: Bool) {
        guard let mpv else { return }
        var value: Int32 = enabled ? 1 : 0
        let status = mpv_set_option(mpv, name, MPV_FORMAT_FLAG, &value)
        if status < 0 {
            MarqueeLogger.player.error("set_option \(name)=\(enabled, privacy: .public) failed: \(String(cString: mpv_error_string(status)))")
        }
    }

    private func setFlagProperty(_ name: String, _ enabled: Bool) {
        guard let mpv else { return }
        var value: Int32 = enabled ? 1 : 0
        let status = mpv_set_property(mpv, name, MPV_FORMAT_FLAG, &value)
        if status < 0 {
            MarqueeLogger.player.error("set_property \(name)=\(enabled, privacy: .public) failed: \(String(cString: mpv_error_string(status)))")
        }
    }

    private func setStringProperty(_ name: String, _ value: String) {
        guard let mpv else { return }
        let status = mpv_set_property_string(mpv, name, value)
        if status < 0 {
            MarqueeLogger.player.error("set_property \(name)=\(value) failed: \(String(cString: mpv_error_string(status)))")
        }
    }

    @discardableResult
    private func command(_ name: String, args: [String?] = []) -> Int32 {
        guard let mpv else { return MPV_ERROR_UNINITIALIZED.rawValue }
        var allArgs: [String?] = [name]
        allArgs.append(contentsOf: args)
        var cargs: [UnsafePointer<CChar>?] = allArgs.map { s in
            guard let s else { return nil }
            return UnsafePointer(strdup(s))
        }
        cargs.append(nil)
        defer {
            for ptr in cargs where ptr != nil {
                free(UnsafeMutablePointer(mutating: ptr!))
            }
        }
        let status = mpv_command(mpv, &cargs)
        let argsJoined = args.compactMap { $0 }.joined(separator: " ")
        if status < 0 {
            let err = String(cString: mpv_error_string(status))
            MarqueeLogger.player.error("command \(name, privacy: .public) [\(argsJoined, privacy: .public)] failed: \(err, privacy: .public)")
        } else {
            MarqueeLogger.player.info("command \(name, privacy: .public) [\(argsJoined, privacy: .public)] OK")
        }
        return status
    }

    @discardableResult
    private func commandAsync(_ name: String, args: [String]) -> Int32 {
        guard let mpv else { return MPV_ERROR_UNINITIALIZED.rawValue }
        let allArgs = [name] + args
        var cargs: [UnsafePointer<CChar>?] = allArgs.map { UnsafePointer(strdup($0)) }
        cargs.append(nil)
        defer {
            for ptr in cargs where ptr != nil {
                free(UnsafeMutablePointer(mutating: ptr!))
            }
        }

        let status = cargs.withUnsafeMutableBufferPointer { buffer in
            mpv_command_async(mpv, 0, buffer.baseAddress)
        }
        if status < 0 {
            let err = String(cString: mpv_error_string(status))
            let argsJoined = args.joined(separator: " ")
            MarqueeLogger.player.error("async command \(name, privacy: .public) [\(argsJoined, privacy: .public)] failed: \(err, privacy: .public)")
        }
        return status
    }

    private func getString(_ name: String) -> String? {
        guard let mpv else { return nil }
        guard let cstr = mpv_get_property_string(mpv, name) else { return nil }
        defer { mpv_free(cstr) }
        return String(cString: cstr)
    }

    private func getInt64(_ name: String) -> Int64 {
        guard let mpv else { return -1 }
        var v: Int64 = -1
        mpv_get_property(mpv, name, MPV_FORMAT_INT64, &v)
        return v
    }

    private func scheduleStartFileWatchdog(generation: Int, url: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self,
                  self.awaitingStartFile,
                  self.loadGeneration == generation else { return }

            self.mpvQueue.async { [weak self] in
                guard let self else { return }
                let clients = self.getString("client-list") ?? "unavailable"
                let autoProfiles = self.getString("load-auto-profiles") ?? "unavailable"
                MarqueeLogger.player.error("mpv loadfile has not reached start-file after 3s url=\(url, privacy: .public) client-list=\(clients, privacy: .public) load-auto-profiles=\(autoProfiles, privacy: .public)")
            }
        }
    }

    private func scheduleAVLoadWatchdog(generation: Int, path: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 12.0) { [weak self] in
            guard let self,
                  self.activeBackend.usesAVFoundation,
                  self.loadGeneration == generation,
                  self.stateMachine.state == .loading else { return }

            let filename = URL(fileURLWithPath: path).lastPathComponent
            self.failPlayback("Unable to load \(filename). AVFoundation did not report the file ready in time.")
        }
    }
}

private final class FFmpegPreparationRun {
    let generation: Int

    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        let value = cancelled
        lock.unlock()
        return value
    }

    init(generation: Int) {
        self.generation = generation
    }

    func bind(_ process: Process) {
        lock.lock()
        self.process = process
        let shouldTerminate = cancelled
        lock.unlock()

        if shouldTerminate && process.isRunning {
            terminate(process)
        }
    }

    func clear(_ process: Process) {
        lock.lock()
        if self.process === process {
            self.process = nil
        }
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let process = self.process
        lock.unlock()

        if let process, process.isRunning {
            terminate(process)
        }
    }

    func throwIfCancelled() throws {
        if isCancelled {
            throw FFmpegPreparationCancelled()
        }
    }

    private func terminate(_ process: Process) {
        guard process.isRunning else { return }

        process.terminate()
        let terminateDeadline = Date().addingTimeInterval(1.5)
        while process.isRunning && Date() < terminateDeadline {
            Thread.sleep(forTimeInterval: 0.05)
        }

        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            let killDeadline = Date().addingTimeInterval(2.0)
            while process.isRunning && Date() < killDeadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }

        waitForProcessExitAfterTermination(process)
    }

    private func waitForProcessExitAfterTermination(_ process: Process) {
        guard !process.isRunning else { return }
        process.waitUntilExit()
    }
}

private final class EmbeddedDurationProbeHandle {
    let generation: Int
    let runID: Int
    let epoch: Int
    let process: Process
    var cancelled = false

    init(generation: Int, runID: Int, epoch: Int, process: Process) {
        self.generation = generation
        self.runID = runID
        self.epoch = epoch
        self.process = process
    }
}

private struct BoundedProcessResult {
    let terminationStatus: Int32
    let stdout: Data
    let stderr: Data

    var stderrText: String {
        String(data: stderr, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

private final class BoundedPipeCapture {
    let pipe = Pipe()

    private let lock = NSLock()
    private let maxBytes: Int
    private var captured = Data()

    init(maxBytes: Int) {
        self.maxBytes = max(0, maxBytes)
    }

    func start() {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            self?.append(chunk)
        }
    }

    func stop() {
        pipe.fileHandleForReading.readabilityHandler = nil
    }

    func data() -> Data {
        lock.lock()
        let value = captured
        lock.unlock()
        return value
    }

    private func append(_ chunk: Data) {
        guard maxBytes > 0 else { return }

        lock.lock()
        let remainingCapacity = maxBytes - captured.count
        if remainingCapacity > 0 {
            captured.append(contentsOf: chunk.prefix(remainingCapacity))
        }
        lock.unlock()
    }
}

private extension String {
    var ifNotEmpty: String? {
        isEmpty ? nil : self
    }
}

private struct FFmpegPreparationCancelled: LocalizedError {
    var errorDescription: String? {
        "Playback preparation was cancelled."
    }
}

private enum FFmpegPreparationStrategy: Equatable {
    case streamCopyH264
    case streamCopyHEVC
    case transcode

    var rawValue: String {
        switch self {
        case .streamCopyH264:
            return "streamCopyH264"
        case .streamCopyHEVC:
            return "streamCopyHEVC"
        case .transcode:
            return "transcode"
        }
    }

    var isStreamCopy: Bool {
        switch self {
        case .streamCopyH264, .streamCopyHEVC:
            return true
        case .transcode:
            return false
        }
    }
}

private struct FFprobeVideoStreams: Decodable {
    let streams: [Stream]

    var hasAttachedPicture: Bool {
        streams.contains { stream in
            stream.codecType == "video" && stream.disposition?.attachedPic == 1
        }
    }

    var hasPlayableNonAttachedVideo: Bool {
        streams.contains { stream in
            stream.codecType == "video"
                && stream.disposition?.attachedPic != 1
                && ["h264", "hevc"].contains(stream.codecName)
        }
    }

    struct Stream: Decodable {
        let codecType: String
        let codecName: String
        let disposition: Disposition?

        enum CodingKeys: String, CodingKey {
            case codecType = "codec_type"
            case codecName = "codec_name"
            case disposition
        }
    }

    struct Disposition: Decodable {
        let attachedPic: Int?

        enum CodingKeys: String, CodingKey {
            case attachedPic = "attached_pic"
        }
    }
}

private struct FFprobeCodecs: Decodable {
    let streams: [Stream]

    var streamCopyStrategyForMP4: FFmpegPreparationStrategy? {
        guard let video = streams.first(where: { $0.codecType == "video" }),
              ["h264", "hevc"].contains(video.codecName) else {
            return nil
        }

        let audioStreams = streams.filter { $0.codecType == "audio" }
        let mp4AudioCodecs: Set<String> = ["aac", "ac3", "eac3", "mp3", "alac"]
        guard audioStreams.allSatisfy({ mp4AudioCodecs.contains($0.codecName) }) else {
            return nil
        }

        switch video.codecName {
        case "h264":
            return .streamCopyH264
        case "hevc":
            return .streamCopyHEVC
        default:
            return nil
        }
    }

    struct Stream: Decodable {
        let codecType: String
        let codecName: String

        enum CodingKeys: String, CodingKey {
            case codecType = "codec_type"
            case codecName = "codec_name"
        }
    }
}

private enum RemuxError: LocalizedError {
    case ffmpegFailed(String)
    case streamCopyUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .ffmpegFailed(let message):
            return message
        case .streamCopyUnavailable(let message):
            return message
        }
    }
}

// MARK: - C Callbacks

private func mpvWakeup(_ ctx: UnsafeMutableRawPointer?) {
    guard let ctx else { return }
    let service = Unmanaged<MPVPlayerService>.fromOpaque(ctx).takeUnretainedValue()
    service.readEvents()
}

private func mpvUpdate(_ ctx: UnsafeMutableRawPointer?) {
    guard let ctx else { return }
    let service = Unmanaged<MPVPlayerService>.fromOpaque(ctx).takeUnretainedValue()
    DispatchQueue.main.async {
        service.renderView?.requestMpvRedraw()
    }
}
