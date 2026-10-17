import AppKit
import AVFoundation
import Libmpv

// MARK: - Player Surface View

/// Container that can present either AVFoundation video or mpv's software
/// render-context output without changing SwiftUI call sites.
final class MPVOGLView: NSView {

    weak var playerService: MPVPlayerService? {
        didSet {
            softwareSurface.playerService = playerService
        }
    }

    private let softwareSurface = MPVSoftwareSurfaceView()
    private let externalFrameSurface = FFmpegFrameSurfaceView()
    private let avPlayerLayer = AVPlayerLayer()
    private var didAttach = false
    private var redrawScheduled = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureSubviews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureSubviews()
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        softwareSurface.frame = bounds
        externalFrameSurface.frame = bounds
        avPlayerLayer.frame = bounds
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !didAttach, let service = playerService else { return }
        service.attachRenderView(self)
        didAttach = true
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil && didAttach {
            redrawScheduled = false
            softwareSurface.isHidden = true
            externalFrameSurface.clearFrame()
            playerService?.detachRenderView()
            didAttach = false
        }
    }

    func requestMpvRedraw() {
        if Thread.isMainThread {
            scheduleMpvRedraw()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.scheduleMpvRedraw()
            }
        }
    }

    private func scheduleMpvRedraw() {
        guard !redrawScheduled, !softwareSurface.isHidden, window != nil else { return }
        redrawScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.redrawScheduled = false
            self.softwareSurface.renderNextFrame()
        }
    }

    func showMpvSurface() {
        avPlayerLayer.player = nil
        externalFrameSurface.clearFrame()
        externalFrameSurface.isHidden = true
        softwareSurface.isHidden = false
        requestMpvRedraw()
    }

    func showAVPlayer(_ player: AVPlayer) {
        redrawScheduled = false
        softwareSurface.isHidden = true
        externalFrameSurface.clearFrame()
        externalFrameSurface.isHidden = true
        wantsLayer = true
        if avPlayerLayer.superlayer == nil {
            layer?.addSublayer(avPlayerLayer)
        }
        avPlayerLayer.player = player
        avPlayerLayer.frame = bounds
    }

    func showExternalFrameSurface(clearExistingFrame: Bool = true) {
        redrawScheduled = false
        avPlayerLayer.player = nil
        softwareSurface.isHidden = true
        if clearExistingFrame {
            externalFrameSurface.clearFrame()
        }
        externalFrameSurface.isHidden = false
    }

    /// The platform presenter layer for the embedded bridge; the playback
    /// service attaches this to its render synchronizer per run.
    var embeddedSampleBufferLayer: AVSampleBufferDisplayLayer {
        externalFrameSurface.displayLayer
    }

    func noteEmbeddedFramesEnqueued() {
        externalFrameSurface.noteFramesEnqueuedForHarness()
    }

    func clearExternalFrameSurface() {
        externalFrameSurface.clearFrame()
    }

    private func configureSubviews() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.isOpaque = true

        softwareSurface.frame = bounds
        softwareSurface.autoresizingMask = [.width, .height]
        softwareSurface.playerService = playerService
        addSubview(softwareSurface)

        externalFrameSurface.frame = bounds
        externalFrameSurface.autoresizingMask = [.width, .height]
        addSubview(externalFrameSurface)

        avPlayerLayer.backgroundColor = NSColor.black.cgColor
        avPlayerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(avPlayerLayer)
        showMpvSurface()
    }

#if DEBUG
    func verifyAVPlayerSurfaceUsesDirectPolicyForHarness() -> Bool {
        avPlayerLayer.player != nil
            && avPlayerLayer.superlayer === layer
            && avPlayerLayer.frame == bounds
    }

    func verifySoftwareSurfaceHasVisibleFrameForHarness() -> Bool {
        if !externalFrameSurface.isHidden {
            // The sample-buffer layer does not expose pixels; the presenter
            // keeps the last enqueued frame's bytes for this check.
            return playerService?.verifyEmbeddedLastFrameVisibleForHarness == true
        }
        return softwareSurface.verifyHasVisibleFrameForHarness()
    }

    func verifyExternalFrameSurfaceIsClearForHarness() -> Bool {
        externalFrameSurface.verifyIsClearForHarness()
    }
#endif
}

// MARK: - mpv Software Surface

private final class MPVSoftwareSurfaceView: NSView {

    weak var playerService: MPVPlayerService?
    private var pixelBuffer: UnsafeMutableRawPointer?
    private var pixelBufferByteCount = 0
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureLayer()
    }

    deinit {
        pixelBuffer?.deallocate()
    }

    func renderNextFrame() {
        guard window != nil, !isHidden else { return }
        guard let renderContext = playerService?.renderContext else {
            return
        }
        let updateFlags = mpv_render_context_update(renderContext)
        guard (updateFlags & 1) != 0 || layer?.contents == nil else { return }

        let targetSize = renderTargetSize()
        guard targetSize.width > 0, targetSize.height > 0 else { return }

        let width = targetSize.width
        let height = targetSize.height
        let stride = alignedStride(forWidth: width)
        let byteCount = stride * height
        ensurePixelBuffer(byteCount: byteCount)
        guard let pixelBuffer else { return }

        var size = [CInt(width), CInt(height)]
        var strideValue = stride
        size.withUnsafeMutableBufferPointer { sizeBuffer in
            guard let sizePointer = sizeBuffer.baseAddress else { return }
            withUnsafeMutablePointer(to: &strideValue) { stridePointer in
                "rgb0".withCString { format in
                    var params = [
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_SIZE, data: UnsafeMutableRawPointer(sizePointer)),
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_FORMAT, data: UnsafeMutableRawPointer(mutating: format)),
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_STRIDE, data: UnsafeMutableRawPointer(stridePointer)),
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_POINTER, data: pixelBuffer),
                        mpv_render_param()
                    ]
                    let status = mpv_render_context_render(renderContext, &params)
                    guard status >= 0 else { return }

                    updateLayerContents(width: width, height: height, stride: stride, byteCount: byteCount)
                    mpv_render_context_report_swap(renderContext)
                }
            }
        }
    }

    private func updateLayerContents(width: Int, height: Int, stride: Int, byteCount: Int) {
        guard let pixelBuffer else { return }
        let frameData = Data(bytes: pixelBuffer, count: byteCount)
        guard let provider = CGDataProvider(data: frameData as CFData) else { return }
        let bitmapInfo = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        )
        guard let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: stride,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ) else { return }
        layer?.contents = image
    }

    private func configureLayer() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.isOpaque = true
        layer?.contentsGravity = .resizeAspect
        layer?.magnificationFilter = .linear
        layer?.minificationFilter = .linear
    }

    private func renderTargetSize() -> (width: Int, height: Int) {
        let backingScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        let rawWidth = max(Int(bounds.width * backingScale), 1)
        let rawHeight = max(Int(bounds.height * backingScale), 1)
        let maxLongEdge = 1280.0
        let longEdge = max(Double(rawWidth), Double(rawHeight))
        guard longEdge > maxLongEdge else {
            return (rawWidth, rawHeight)
        }

        let scale = maxLongEdge / longEdge
        return (
            max(Int(Double(rawWidth) * scale), 1),
            max(Int(Double(rawHeight) * scale), 1)
        )
    }

    private func alignedStride(forWidth width: Int) -> Int {
        let minimum = width * 4
        return ((minimum + 63) / 64) * 64
    }

    private func ensurePixelBuffer(byteCount: Int) {
        guard byteCount != pixelBufferByteCount else { return }
        pixelBuffer?.deallocate()
        pixelBuffer = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 64)
        pixelBufferByteCount = byteCount
    }

#if DEBUG
    func verifyHasVisibleFrameForHarness() -> Bool {
        renderNextFrame()
        guard let contents = layer?.contents,
              CFGetTypeID(contents as CFTypeRef) == CGImage.typeID else {
            return false
        }

        let image = contents as! CGImage
        guard
              let dataProvider = image.dataProvider,
              let data = dataProvider.data,
              let bytes = CFDataGetBytePtr(data) else {
            return false
        }

        let length = CFDataGetLength(data)
        guard length >= 4 else { return false }

        var index = 0
        while index + 3 < length {
            let red = bytes[index]
            let green = bytes[index + 1]
            let blue = bytes[index + 2]
            if red > 8 || green > 8 || blue > 8 {
                return true
            }
            index += 4
        }
        return false
    }
#endif
}

// MARK: - External FFmpeg Frame Surface

/// Hosts the platform's sample-buffer presenter for the embedded bridge.
/// Frames are timestamped `CMSampleBuffer`s enqueued by
/// `EmbeddedPlaybackPresenter`; the layer owns presentation timing, color
/// management, and late-frame policy, so appearance cannot depend on
/// WindowServer compositing or main-thread load.
private final class FFmpegFrameSurfaceView: NSView {
    let displayLayer = AVSampleBufferDisplayLayer()
    private var clearedForHarness = true

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureLayer()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        CATransaction.commit()
    }

    func noteFramesEnqueuedForHarness() {
        clearedForHarness = false
    }

    func clearFrame() {
        displayLayer.flushAndRemoveImage()
        clearedForHarness = true
    }

    private func configureLayer() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.isOpaque = true
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
        displayLayer.frame = bounds
        layer?.addSublayer(displayLayer)
        isHidden = true
    }

#if DEBUG
    func verifyIsClearForHarness() -> Bool {
        clearedForHarness
    }
#endif
}
