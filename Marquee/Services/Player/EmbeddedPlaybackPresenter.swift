import AVFoundation
import CoreMedia
import Foundation
import os

// MARK: - Embedded Playback Presenter

/// Owns the clock for the embedded ffmpeg bridge and renders its audio.
///
/// The bridge decodes without realtime throttling; pacing comes entirely from
/// this presenter. `AVSampleBufferRenderSynchronizer` is the master clock:
/// pause is rate 0, playback speed is the synchronizer rate, and the reported
/// position is the synchronizer's time, so position, pause, and speed are
/// exact rather than inferred from wall-clock arithmetic.
///
/// Audio arrives as interleaved float32 stereo 48kHz PCM through a FIFO and
/// is enqueued on an `AVSampleBufferAudioRenderer` with sample-accurate
/// timestamps; the renderer owns device routing and time-pitch at non-1x
/// rates. Video frames arrive in decode order from the raw frame pipe; each
/// frame's timestamp is its index over the forced-CFR frame rate, intake is
/// gated to a bounded lead over the clock (which backpressures the single
/// ffmpeg process through its pipes), and frames are enqueued on an
/// `AVSampleBufferDisplayLayer` that presents them against the same clock.
///
/// The FIFO must live on a POSIX filesystem (temporary directory), never the
/// exFAT playback cache.
final class EmbeddedPlaybackPresenter {

    static let sampleRate: Double = 48_000
    static let channelCount = 2

    /// FIFO the bridge writes PCM into; nil for silent sources.
    let fifoURL: URL?

    /// Called once if the audio renderer fails; playback continues on the
    /// synchronizer clock without audio.
    var onAudioFailed: (() -> Void)?

    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private var audioRenderer: AVSampleBufferAudioRenderer?
    private var audioFormat: CMAudioFormatDescription?
    private let startOffset: Double
    private let frameRate: Double
    private let readQueue = DispatchQueue(label: "com.marquee.player.embedded-audio", qos: .userInteractive)
    private let stateLock = NSLock()

    private var cancelled = false
    private var anchored = false
    private var desiredRate: Float
    private var pausedFlag: Bool
    private var audioFailed = false
    private var audioSamplesEnqueued: Int64 = 0
    private var videoFramesIngested: Int64 = 0
    private var lastEnqueuedSeconds: Double?
    private var lastEnqueuedFrameData: Data?
    private var videoEOFFlag = false
    private var displayLayer: AVSampleBufferDisplayLayer?
    private var videoFormat: CMVideoFormatDescription?
    private var pixelBufferPool: CVPixelBufferPool?
    private var pooledGeometry: (width: Int, height: Int)?

    /// Called on the intake thread when the first video frame is enqueued.
    var onFirstVideoFrame: (() -> Void)?

    private let bytesPerInterleavedFrame = MemoryLayout<Float32>.size * channelCount
    /// ~100ms of audio per enqueued sample buffer.
    private let audioFramesPerBuffer = 4_800
    /// Media-seconds of video the intake may hold beyond the clock. Bounds
    /// both memory (IOSurface-backed BGRA frames queued on the layer) and
    /// the bridge's decode lead: once the gate closes, ffmpeg blocks
    /// writing the frame pipe.
    private let videoLeadSeconds: Double = 0.4

    init(fifoURL: URL?, startOffset: Double, frameRate: Double, initialRate: Float) {
        self.fifoURL = fifoURL
        self.startOffset = max(0, startOffset)
        self.frameRate = max(1, frameRate)
        self.desiredRate = max(0.25, initialRate)
        self.pausedFlag = false
    }

    /// Creates the FIFO and begins draining audio. Returns false when audio
    /// was requested but cannot be prepared; callers must then launch the
    /// bridge without an audio mapping so ffmpeg never blocks on a
    /// writer-less FIFO open. Video-only presenting always succeeds.
    func start(initialVolume: Float, muted: Bool) -> Bool {
        guard let fifoURL else { return true }

        var streamDescription = AudioStreamBasicDescription(
            mSampleRate: Self.sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(bytesPerInterleavedFrame),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(bytesPerInterleavedFrame),
            mChannelsPerFrame: UInt32(Self.channelCount),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &streamDescription,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &format
        ) == noErr, let format else {
            MarqueeLogger.player.error("embedded audio format description creation failed")
            return false
        }

        unlink(fifoURL.path)
        guard mkfifo(fifoURL.path, 0o600) == 0 else {
            MarqueeLogger.player.error("embedded audio fifo creation failed errno=\(errno)")
            return false
        }

        let renderer = AVSampleBufferAudioRenderer()
        renderer.volume = max(0, min(1, initialVolume))
        renderer.isMuted = muted
        renderer.audioTimePitchAlgorithm = .timeDomain
        synchronizer.addRenderer(renderer)
        audioRenderer = renderer
        audioFormat = format

        readQueue.async { [weak self] in
            self?.drainFIFO()
        }
        return true
    }

    // MARK: - Clock

    /// Seconds of media position on the synchronizer clock. Before the first
    /// video frame anchors the clock this is exactly the start offset, so
    /// bridge startup latency never leaks into the reported position.
    var currentSeconds: Double {
        stateLock.lock()
        let isAnchored = anchored
        stateLock.unlock()
        guard isAnchored else { return startOffset }
        let seconds = CMTimeGetSeconds(synchronizer.currentTime())
        return seconds.isFinite ? max(0, seconds) : startOffset
    }

    var isPaused: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return pausedFlag
    }

    /// Rate 0 pauses in place; any other rate plays at that speed. The
    /// bridge process is untouched — its pipes simply stop being drained.
    func setPaused(_ paused: Bool) {
        // Decide and apply under one lock: an anchor or rate change racing
        // between the two would leave the clock contradicting `pausedFlag`.
        stateLock.lock()
        pausedFlag = paused
        if anchored {
            synchronizer.setRate(paused ? 0 : desiredRate, time: synchronizer.currentTime())
        }
        stateLock.unlock()
    }

    func setPlaybackRate(_ rate: Float) {
        let clamped = max(0.25, min(4, rate))
        stateLock.lock()
        desiredRate = clamped
        if anchored && !pausedFlag {
            synchronizer.setRate(clamped, time: synchronizer.currentTime())
        }
        stateLock.unlock()
    }

    var playbackRate: Float {
        stateLock.lock()
        defer { stateLock.unlock() }
        return desiredRate
    }

    private func currentAudioRenderer() -> AVSampleBufferAudioRenderer? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return audioRenderer
    }

    var volume: Float {
        get { currentAudioRenderer()?.volume ?? 0 }
        set { currentAudioRenderer()?.volume = max(0, min(1, newValue)) }
    }

    var isMuted: Bool {
        get { currentAudioRenderer()?.isMuted ?? true }
        set { currentAudioRenderer()?.isMuted = newValue }
    }

    // MARK: - Video intake and presentation

    /// Attaches the view's sample-buffer layer to the synchronizer for this
    /// run. Pending frames from a previous run are flushed; the displayed
    /// image is kept so seek and resume never flash black.
    func attachDisplayLayer(_ layer: AVSampleBufferDisplayLayer) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !cancelled, displayLayer == nil else { return }
        layer.flush()
        synchronizer.addRenderer(layer)
        displayLayer = layer
    }

    /// Whether the frame reader may pull another frame from the pipe.
    /// Returning false is the backpressure that paces ffmpeg: the reader
    /// sleeps, the pipe fills, and the process blocks on write.
    func shouldAcceptMoreVideo() -> Bool {
        stateLock.lock()
        let cancelledNow = cancelled
        let lastQueuedSeconds = lastEnqueuedSeconds
        let isAnchored = anchored
        let layer = displayLayer
        stateLock.unlock()
        if cancelledNow { return false }
        if let layer, !layer.isReadyForMoreMediaData { return false }
        guard isAnchored, let lastQueuedSeconds else { return true }
        return lastQueuedSeconds - currentSeconds < videoLeadSeconds
    }

    /// The layer can wedge after display sleep or decode hiccups; a flush
    /// resumes it. Polled by the service's clock timer so a wedged layer
    /// never silently freezes video under continuing audio.
    func recoverDisplayLayerIfNeeded() {
        stateLock.lock()
        let layer = displayLayer
        stateLock.unlock()
        guard let layer else { return }
        if layer.status == .failed || layer.requiresFlushToResumeDecoding {
            MarqueeLogger.player.error("embedded display layer required recovery; flushing")
            layer.flush()
        }
    }

    /// Wraps a decoded frame in a timestamped sample buffer and enqueues it
    /// on the display layer; the timestamp is the frame index over the
    /// forced-CFR rate. The first frame anchors and starts the clock.
    func ingestVideoFrame(_ data: Data, width: Int, height: Int) {
        stateLock.lock()
        if cancelled {
            stateLock.unlock()
            return
        }
        let index = videoFramesIngested
        videoFramesIngested += 1
        let seconds = startOffset + Double(index) / frameRate
        // Ingest-time bookkeeping drives pacing and end-of-stream drain even
        // when no layer is attached, so a headless run still ends cleanly.
        lastEnqueuedSeconds = seconds
        let hasLayer = displayLayer != nil
        if !anchored {
            anchored = true
            synchronizer.setRate(
                pausedFlag ? 0 : desiredRate,
                time: CMTime(seconds: startOffset, preferredTimescale: 48_000)
            )
        }
        stateLock.unlock()

        guard hasLayer,
              let sampleBuffer = makeVideoSampleBuffer(
                  data: data,
                  width: width,
                  height: height,
                  seconds: seconds
              ) else { return }

        // Enqueue while holding the lock: a stop() must never interleave
        // between the cancelled check and the enqueue, or it would paint a
        // stale frame onto a surface the service just cleared. The layer's
        // enqueue is thread-safe and cheap, and the only contended readers
        // are sub-millisecond state snapshots. Visibility signals fire only
        // for frames that actually reached the layer.
        stateLock.lock()
        if cancelled {
            stateLock.unlock()
            return
        }
        guard let layer = displayLayer else {
            stateLock.unlock()
            return
        }
        let isFirstEnqueue = lastEnqueuedFrameData == nil
        lastEnqueuedFrameData = data
        layer.enqueue(sampleBuffer)
        stateLock.unlock()
        if isFirstEnqueue {
            onFirstVideoFrame?()
        }
    }

    private func makeVideoSampleBuffer(
        data: Data,
        width: Int,
        height: Int,
        seconds: Double
    ) -> CMSampleBuffer? {
        stateLock.lock()
        var pool = pixelBufferPool
        let pooledWidth = pooledGeometry?.width
        let pooledHeight = pooledGeometry?.height
        stateLock.unlock()
        if pool != nil, pooledWidth != width || pooledHeight != height {
            // Geometry is fixed by the service today; if that ever changes,
            // reusing the old pool would overflow the copy. Rebuild instead.
            pool = nil
        }
        if pool == nil {
            let attributes: [CFString: Any] = [
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ]
            var poolOut: CVPixelBufferPool?
            guard CVPixelBufferPoolCreate(
                kCFAllocatorDefault,
                nil,
                attributes as CFDictionary,
                &poolOut
            ) == kCVReturnSuccess, let created = poolOut else { return nil }
            stateLock.lock()
            pixelBufferPool = created
            pooledGeometry = (width, height)
            stateLock.unlock()
            pool = created
        }
        guard let pool else { return nil }

        var pixelBufferOut: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(
            kCFAllocatorDefault,
            pool,
            &pixelBufferOut
        ) == kCVReturnSuccess, let pixelBuffer = pixelBufferOut else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            let destStride = CVPixelBufferGetBytesPerRow(pixelBuffer)
            let sourceStride = width * 4
            data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                guard let source = bytes.baseAddress else { return }
                if destStride == sourceStride {
                    memcpy(base, source, sourceStride * height)
                } else {
                    for row in 0..<height {
                        memcpy(
                            base + row * destStride,
                            source + row * sourceStride,
                            sourceStride
                        )
                    }
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        // An explicit colorspace makes interpretation identical on every
        // compositing path; untagged frames were the root of the HUD-linked
        // brightness shifts.
        if let srgb = CGColorSpace(name: CGColorSpace.sRGB) {
            CVBufferSetAttachment(
                pixelBuffer,
                kCVImageBufferCGColorSpaceKey,
                srgb,
                .shouldPropagate
            )
        }

        var formatOut: CMVideoFormatDescription?
        stateLock.lock()
        var format = videoFormat
        stateLock.unlock()
        if format == nil || CMVideoFormatDescriptionMatchesImageBuffer(format!, imageBuffer: pixelBuffer) == false {
            guard CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescriptionOut: &formatOut
            ) == noErr, let created = formatOut else { return nil }
            stateLock.lock()
            videoFormat = created
            stateLock.unlock()
            format = created
        }
        guard let format else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(frameRate.rounded())),
            presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 48_000),
            decodeTimeStamp: .invalid
        )
        var sampleBufferOut: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: format,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBufferOut
        ) == noErr else { return nil }
        return sampleBufferOut
    }

    func markVideoEOF() {
        stateLock.lock()
        videoEOFFlag = true
        stateLock.unlock()
    }

    var isStopped: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return cancelled
    }

    /// True once the bridge finished writing and the clock has played out
    /// everything that was queued; the service then ends playback without
    /// cutting off the buffered tail.
    var didDrainToEnd: Bool {
        stateLock.lock()
        let eof = videoEOFFlag
        let lastQueued = lastEnqueuedSeconds
        stateLock.unlock()
        guard eof else { return false }
        guard let lastQueued else { return true }
        return currentSeconds >= lastQueued - (0.5 / frameRate)
    }

    func stop() {
        stateLock.lock()
        cancelled = true
        let layer = displayLayer
        displayLayer = nil
        stateLock.unlock()

        // The drain loop polls non-blocking reads, so this barrier returns
        // within one poll interval and guarantees no enqueue is in flight
        // when the renderer flushes.
        readQueue.sync {}

        synchronizer.setRate(0, time: synchronizer.currentTime())
        if let layer {
            // Discard queued-but-undue frames while keeping the displayed
            // image, so seek and resume hold the picture; the service clears
            // the surface separately when playback truly ends.
            layer.flush()
            synchronizer.removeRenderer(layer, at: .invalid)
        }
        stateLock.lock()
        let renderer = audioRenderer
        audioRenderer = nil
        stateLock.unlock()
        if let renderer {
            renderer.stopRequestingMediaData()
            renderer.flush()
            synchronizer.removeRenderer(renderer, at: .invalid)
        }
        if let fifoURL {
            unlink(fifoURL.path)
        }
    }

    // MARK: - FIFO drain

    private func isCancelled() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return cancelled
    }

    private func drainFIFO() {
        guard let fifoURL else { return }
        var descriptor: Int32 = -1
        while descriptor < 0 {
            if isCancelled() { return }
            descriptor = open(fifoURL.path, O_RDONLY | O_NONBLOCK)
            if descriptor < 0 {
                usleep(20_000)
            }
        }
        defer { close(descriptor) }

        let chunkBytes = audioFramesPerBuffer * bytesPerInterleavedFrame
        var pending = Data(capacity: chunkBytes * 2)
        var scratch = [UInt8](repeating: 0, count: 65_536)
        var sawData = false

        while !isCancelled() {
            guard let renderer = currentAudioRenderer(), !isAudioFailed() else { return }
            if renderer.status == .failed {
                handleAudioFailure(renderer.error)
                return
            }
            if !renderer.isReadyForMoreMediaData {
                usleep(10_000)
                continue
            }

            let bytesRead = scratch.withUnsafeMutableBytes { buffer -> Int in
                read(descriptor, buffer.baseAddress, buffer.count)
            }
            if bytesRead > 0 {
                sawData = true
                pending.append(contentsOf: scratch.prefix(bytesRead))
                while pending.count >= chunkBytes {
                    enqueueAudio(pending.prefix(chunkBytes), on: renderer)
                    pending.removeFirst(chunkBytes)
                }
            } else if bytesRead == 0 {
                // A FIFO read returns zero both before the writer attaches
                // and after it closes; only the latter is end-of-stream.
                if sawData {
                    let remainder = pending.count - (pending.count % bytesPerInterleavedFrame)
                    if remainder > 0 {
                        enqueueAudio(pending.prefix(remainder), on: renderer)
                    }
                    return
                }
                usleep(20_000)
            } else if errno == EAGAIN {
                usleep(5_000)
            } else if errno != EINTR {
                MarqueeLogger.player.error("embedded audio fifo read failed errno=\(errno)")
                return
            }
        }
    }

    private func enqueueAudio(_ interleaved: Data, on renderer: AVSampleBufferAudioRenderer) {
        guard let audioFormat else { return }
        let frames = interleaved.count / bytesPerInterleavedFrame
        guard frames > 0 else { return }

        stateLock.lock()
        let startSample = audioSamplesEnqueued
        audioSamplesEnqueued += Int64(frames)
        stateLock.unlock()

        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: interleaved.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: interleaved.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == noErr, let blockBuffer else { return }
        let copyStatus = interleaved.withUnsafeBytes { bytes -> OSStatus in
            guard let base = bytes.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: interleaved.count
            )
        }
        guard copyStatus == noErr else { return }

        let pts = CMTime(
            value: CMTimeValue(Double(startSample) + startOffset * Self.sampleRate),
            timescale: CMTimeScale(Self.sampleRate)
        )
        var sampleBuffer: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: audioFormat,
            sampleCount: frames,
            presentationTimeStamp: pts,
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else { return }

        renderer.enqueue(sampleBuffer)
        if renderer.status == .failed {
            handleAudioFailure(renderer.error)
        }
    }

    private func isAudioFailed() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return audioFailed
    }

    private func handleAudioFailure(_ error: Error?) {
        stateLock.lock()
        if audioFailed {
            stateLock.unlock()
            return
        }
        audioFailed = true
        let renderer = audioRenderer
        audioRenderer = nil
        stateLock.unlock()

        let message = error?.localizedDescription ?? "unknown"
        MarqueeLogger.player.error("embedded audio renderer failed: \(message, privacy: .public); continuing without audio")
        if let renderer {
            renderer.flush()
            synchronizer.removeRenderer(renderer, at: .invalid)
        }
        onAudioFailed?()
    }

#if DEBUG
    var verifyIsRunningForHarness: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return !cancelled
    }

    var verifyAudioIsActiveForHarness: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return !audioFailed && audioRenderer != nil
    }

    var verifyAudioFailedForHarness: Bool {
        isAudioFailed()
    }

    var verifyClockIsAnchoredForHarness: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return anchored
    }

    var verifyLastFrameVisibleForHarness: Bool {
        stateLock.lock()
        let frame = lastEnqueuedFrameData
        stateLock.unlock()
        guard let frame, frame.count >= 4 else { return false }
        var index = 0
        while index + 3 < frame.count {
            let blue = frame[index]
            let green = frame[index + 1]
            let red = frame[index + 2]
            if red > 8 || green > 8 || blue > 8 {
                return true
            }
            index += 4
        }
        return false
    }
#endif
}
