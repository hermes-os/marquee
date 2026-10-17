import SwiftUI
import AppKit

// MARK: - PlayerView

struct PlayerView: View {

    @ObservedObject var playerService: MPVPlayerService
    @ObservedObject private var clock: PlaybackClockModel
    let currentItem: MediaItem?
    let hasNextEpisode: Bool
    let onNextEpisode: () -> Void
    let onClose: () -> Void

    private static let speedSteps: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0]

    @State private var showControls: Bool = true
    @State private var hideTask: Task<Void, Never>?
    @State private var mouseMonitor: Any?
    @State private var seekHoldTask: Task<Void, Never>?
    @State private var scrubTask: Task<Void, Never>?
    @State private var activeSeekDirection: Int?
    @State private var isScrubbing: Bool = false
    @State private var wasPausedBeforeScrub: Bool = false
    @State private var scrubTargetTime: Double?
    @State private var hudFocusState = PlayerHUDFocusPolicy.initialState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.leanBackMode) private var leanBackMode

    init(
        playerService: MPVPlayerService,
        currentItem: MediaItem? = nil,
        hasNextEpisode: Bool = false,
        onNextEpisode: @escaping () -> Void = {},
        onClose: @escaping () -> Void
    ) {
        self.playerService = playerService
        self.currentItem = currentItem
        self.hasNextEpisode = hasNextEpisode
        self.onNextEpisode = onNextEpisode
        self.onClose = onClose
        _clock = ObservedObject(wrappedValue: playerService.clock)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VideoSurfaceView(playerService: playerService)
                .ignoresSafeArea()

            SubtitleOverlayView(
                entries: playerService.subtitlesEnabled ? playerService.currentSubtitleEntries : [],
                currentTime: clock.currentTime
            )

            if playerService.lifecycleState == .failed {
                PlayerFailureOverlay(
                    message: playerService.playbackErrorMessage ?? "Unable to play this video.",
                    onClose: onClose
                )
            } else if let message = playerService.preparationMessage ?? startupOverlayMessage {
                PlayerStartupOverlay(
                    artworkPath: currentItem?.displayBackdropPath ?? currentItem?.displayPosterPath,
                    message: message
                )
            } else if playerService.playbackBackendDescription == "external-ffplay" {
                PlayerExternalPlaybackOverlay()
            }

            controlsLayer

            KeyCatcher(
                onKeyDown: handleKeyDown,
                onKeyUp: handleKeyUp
            )
            .frame(width: 0, height: 0)
        }
        .frame(minWidth: 640, minHeight: 360)
        .onAppear {
            MarqueeMode.set(.playing)
            normalizeHUDFocus()
            scheduleHideControls()
            installMonitors()
        }
        .onChange(of: playerService.hasSubtitles) { _ in
            normalizeHUDFocus()
        }
        .onChange(of: playerService.availableAudioTracks.count) { _ in
            normalizeHUDFocus()
        }
        .onChange(of: playerService.supportsPlaybackSpeed) { _ in
            normalizeHUDFocus()
        }
        .onDisappear {
            MarqueeMode.set(.browsing)
            hideTask?.cancel()
            cancelSeekTracking(resumePlayback: false)
            if isCursorHidden {
                NSCursor.unhide()
            }
            removeMonitors()
        }
    }

    // MARK: - Controls Layer

    private var startupOverlayMessage: String? {
        guard playerService.playbackBackendDescription != "none",
              playerService.playbackBackendDescription != "external-ffplay",
              playerService.lifecycleState != .failed,
              playerService.lifecycleState != .stopped else {
            return nil
        }

        switch playerService.lifecycleState {
        case .loading, .ready, .preparing:
            return "Opening video..."
        case .playing:
            return clock.currentTime < 0.35 ? "Starting playback..." : nil
        case .idle, .paused, .seeking, .ended, .failed, .stopped:
            return nil
        }
    }

    private var controlsLayer: some View {
        ZStack {
            if showControls || playerService.lifecycleState == .failed {
                ZStack {
                    // Top bar with close button
                    VStack {
                        topBar
                        Spacer()
                    }

                    // Bottom controls
                    VStack {
                        Spacer()
                        PlayerControlsOverlay(
                            playerService: playerService,
                            clock: clock,
                            focusedControl: focusedHUDControl,
                            onNextEpisode: hasNextEpisode ? onNextEpisode : nil
                        )
                    }

                    if let notice = playerService.playbackNotice {
                        VStack {
                            HStack {
                                Spacer()
                                PlayerNoticeBadge(message: notice)
                            }
                            Spacer()
                        }
                    }
                }
                .transition(.opacity)
            }
        }
        // Animation is driven explicitly via `withAnimation` in
        // scheduleHideControls / revealControls. The `.animation(value:)`
        // modifier was causing faint repeated fade-ins because PlayerView's
        // body re-evaluates on every mpv property tick (~60Hz from time-pos),
        // and SwiftUI was re-considering the opacity transition each pass
        // even though `showControls` had not changed.
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: MarqueeTheme.scaled(10, leanBack: 16, isLeanBack: leanBackMode)) {
                Button(action: onClose) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: MarqueeTheme.scaled(16, leanBack: 24, isLeanBack: leanBackMode), weight: .semibold))
                        .foregroundColor(.white)
                        .frame(
                            width: MarqueeTheme.scaled(36, leanBack: 58, isLeanBack: leanBackMode),
                            height: MarqueeTheme.scaled(36, leanBack: 58, isLeanBack: leanBackMode)
                        )
                        .background(
                            Circle()
                                .fill(Color.black.opacity(0.5))
                        )
                }
                .buttonStyle(.plain)
                .playerHUDFocused(focusedHUDControl == .back)

                titleBlock
            }

            Spacer()
        }
        .padding(.top, MarqueeTheme.scaled(16, leanBack: 28, isLeanBack: leanBackMode))
        .padding(.horizontal, MarqueeTheme.scaled(20, leanBack: 36, isLeanBack: leanBackMode))
    }

    @ViewBuilder
    private var titleBlock: some View {
        if let item = currentItem {
            VStack(alignment: .leading, spacing: MarqueeTheme.scaled(2, leanBack: 4, isLeanBack: leanBackMode)) {
                Text(item.showName ?? item.displayTitle)
                    .font(.system(size: MarqueeTheme.scaled(18, leanBack: 27, isLeanBack: leanBackMode), weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)

                if item.isEpisode {
                    Text(item.episodeLabel.isEmpty
                        ? item.displayEpisodeTitle
                        : "\(item.episodeLabel) \u{00B7} \(item.displayEpisodeTitle)")
                        .font(.system(size: MarqueeTheme.scaled(13, leanBack: 19, isLeanBack: leanBackMode), weight: .medium))
                        .foregroundColor(.white.opacity(0.78))
                        .lineLimit(1)
                }
            }
            .shadow(color: .black.opacity(0.7), radius: 6, y: 1)
        }
    }

    // MARK: - Auto-Hide

    @State private var isCursorHidden: Bool = false

    private func scheduleHideControls() {
        hideTask?.cancel()
        guard playerService.lifecycleState != .failed else {
            showControls = true
            if isCursorHidden {
                NSCursor.unhide()
                isCursorHidden = false
            }
            return
        }
        if !showControls {
            withAnimation(MarqueeTheme.motion(MarqueeTheme.quietDismissAnimation, reduceMotion: reduceMotion)) {
                showControls = true
            }
        }
        if isCursorHidden {
            NSCursor.unhide()
            isCursorHidden = false
        }
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(MarqueeTheme.motion(MarqueeTheme.quietDismissAnimation, reduceMotion: reduceMotion)) {
                    showControls = false
                    hudFocusState = PlayerHUDFocusPolicy.initialState
                }
                if !isCursorHidden {
                    NSCursor.hide()
                    isCursorHidden = true
                }
            }
        }
    }

    private func revealControls() {
        if !showControls {
            withAnimation(MarqueeTheme.motion(MarqueeTheme.quietDismissAnimation, reduceMotion: reduceMotion)) {
                showControls = true
            }
        }
        if isCursorHidden {
            NSCursor.unhide()
            isCursorHidden = false
        }
        scheduleHideControls()
    }

    // MARK: - Speed Stepping

    private func stepSpeed(direction: Int) {
        let steps = Self.speedSteps
        let currentIndex = steps.firstIndex(of: playerService.playbackSpeed)
            ?? steps.firstIndex(of: 1.0)
            ?? 2
        let newIndex = max(0, min(steps.count - 1, currentIndex + direction))
        playerService.setPlaybackSpeed(steps[newIndex])
    }

    // MARK: - Event Monitors

    private func installMonitors() {
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { event in
            revealControls()
            return event
        }
    }

    private func removeMonitors() {
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMonitor = nil
        }
    }

    // MARK: - Key Handling

    private func handleKeyDown(_ event: MarqueeKeyEvent) -> Bool {
        guard let key = event.key else { return false }

        switch key {
        case .select:
            activateHUDControl(focusedHUDControl)
            revealControls()
            return true
        case .left:
            if focusedHUDControl != .canvas {
                moveHUDFocus(.left)
                revealControls()
                return true
            }
            beginTapOrHoldSeek(direction: -1)
            revealControls()
            return true
        case .right:
            if focusedHUDControl != .canvas {
                moveHUDFocus(.right)
                revealControls()
                return true
            }
            beginTapOrHoldSeek(direction: 1)
            revealControls()
            return true
        case .down:
            moveHUDFocus(.down)
            revealControls()
            return true
        case .up:
            moveHUDFocus(.up)
            // HDMI audio is controlled by Roku ECP in Hammerspoon.
            // Capture these so macOS does not try to adjust local volume.
            revealControls()
            return true
        case .escape:
            onClose()
            return true
        case .subtitles:
            playerService.toggleSubtitles()
            revealControls()
            return true
        case .fullscreen:
            NSApplication.shared.keyWindow?.toggleFullScreen(nil)
            revealControls()
            return true
        case .mute:
            playerService.toggleMute()
            revealControls()
            return true
        case .speedDown:
            stepSpeed(direction: -1)
            revealControls()
            return true
        case .speedUp:
            stepSpeed(direction: 1)
            revealControls()
            return true
        }
    }

    private func handleKeyUp(_ event: MarqueeKeyEvent) -> Bool {
        guard let key = event.key else { return false }

        switch key {
        case .left:
            if activeSeekDirection == -1 {
                finishTapOrHoldSeek(direction: -1)
            }
            return true
        case .right:
            if activeSeekDirection == 1 {
                finishTapOrHoldSeek(direction: 1)
            }
            return true
        case .up, .down, .select, .escape, .subtitles, .fullscreen, .mute, .speedDown, .speedUp:
            return true
        }
    }

    private var hudCapabilities: PlayerHUDCapabilities {
        PlayerHUDCapabilities(
            hasSubtitles: playerService.hasSubtitles,
            hasMultipleAudioTracks: playerService.availableAudioTracks.count > 1,
            hasNextEpisode: hasNextEpisode,
            canChangeSpeed: playerService.supportsPlaybackSpeed
        )
    }

    private var focusedHUDControl: PlayerHUDControl {
        PlayerHUDFocusIDs.control(for: hudFocusState.focused) ?? .canvas
    }

    private func normalizeHUDFocus() {
        hudFocusState = PlayerHUDFocusPolicy.normalized(
            hudFocusState,
            capabilities: hudCapabilities
        )
    }

    private func moveHUDFocus(_ direction: FocusDirection) {
        hudFocusState = PlayerHUDFocusPolicy.move(
            direction,
            state: hudFocusState,
            capabilities: hudCapabilities
        )
    }

    private func activateHUDControl(_ control: PlayerHUDControl) {
        switch control {
        case .back:
            onClose()
        case .canvas:
            playerService.togglePause()
        case .restart:
            playerService.seek(to: 0)
        case .nextEpisode:
            onNextEpisode()
        case .skipBack:
            playerService.seekRelative(-10)
        case .playPause:
            playerService.togglePause()
        case .skipForward:
            playerService.seekRelative(30)
        case .subtitles:
            if playerService.hasSubtitles {
                playerService.toggleSubtitles()
            }
        case .audioTrack:
            selectNextAudioTrack()
        case .speed:
            stepSpeed(direction: 1)
        case .fullscreen:
            NSApplication.shared.keyWindow?.toggleFullScreen(nil)
        }
    }

    private func selectNextAudioTrack() {
        let tracks = playerService.availableAudioTracks
        guard tracks.count > 1 else { return }
        let currentIndex: Int
        if let currentTrack = playerService.currentAudioTrack,
           let index = tracks.firstIndex(of: currentTrack) {
            currentIndex = index
        } else {
            currentIndex = 0
        }
        let nextIndex = (currentIndex + 1) % tracks.count
        playerService.selectAudioTrack(tracks[nextIndex])
    }

    private func beginTapOrHoldSeek(direction: Int) {
        guard activeSeekDirection == nil else { return }
        activeSeekDirection = direction
        seekHoldTask?.cancel()
        seekHoldTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                startScrubbing(direction: direction)
            }
        }
    }

    private func finishTapOrHoldSeek(direction: Int) {
        guard activeSeekDirection == direction else { return }
        if isScrubbing {
            finishScrubbing()
        } else {
            seekHoldTask?.cancel()
            playerService.seekRelative(direction < 0 ? -10 : 30)
            activeSeekDirection = nil
        }
        revealControls()
    }

    private func startScrubbing(direction: Int) {
        guard activeSeekDirection == direction, !isScrubbing else { return }
        isScrubbing = true
        wasPausedBeforeScrub = playerService.isPaused
        scrubTargetTime = playerService.currentTime
        playerService.setPaused(true)
        playerService.beginInteractiveScrub()
        scrubTask?.cancel()
        scrubTask = Task { @MainActor in
            var tick = 0
            var target = scrubTargetTime ?? playerService.currentTime
            while !Task.isCancelled {
                let delta: Double
                switch tick {
                case 0..<10:
                    delta = 1
                case 10..<25:
                    delta = 2
                case 25..<45:
                    delta = 5
                default:
                    delta = 10
                }
                target = clampedScrubTarget(target + Double(direction) * delta)
                scrubTargetTime = target
                playerService.previewInteractiveScrub(to: target)
                revealControls()
                tick += 1
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    private func finishScrubbing() {
        let target = scrubTargetTime ?? playerService.currentTime
        seekHoldTask?.cancel()
        seekHoldTask = nil
        scrubTask?.cancel()
        scrubTask = nil

        playerService.finishInteractiveScrub(to: target, resumePlayback: !wasPausedBeforeScrub)

        activeSeekDirection = nil
        isScrubbing = false
        scrubTargetTime = nil
    }

    private func cancelSeekTracking(resumePlayback: Bool) {
        seekHoldTask?.cancel()
        seekHoldTask = nil
        scrubTask?.cancel()
        scrubTask = nil

        if resumePlayback, isScrubbing, !wasPausedBeforeScrub {
            playerService.setPaused(false)
        }

        activeSeekDirection = nil
        isScrubbing = false
        scrubTargetTime = nil
    }

    private func clampedScrubTarget(_ target: Double) -> Double {
        let lowerBounded = max(0, target)
        guard playerService.duration.isFinite, playerService.duration > 0 else {
            return lowerBounded
        }
        return min(lowerBounded, playerService.duration)
    }
}

private struct PlayerNoticeBadge: View {
    let message: String

    @Environment(\.leanBackMode) private var leanBackMode

    var body: some View {
        HStack(spacing: MarqueeTheme.scaled(6, leanBack: 9, isLeanBack: leanBackMode)) {
            Image(systemName: "speaker.slash.fill")
            Text(message)
        }
        .font(.system(size: MarqueeTheme.scaled(12, leanBack: 17, isLeanBack: leanBackMode), weight: .medium))
        .foregroundStyle(.white.opacity(0.9))
        .padding(.horizontal, MarqueeTheme.scaled(12, leanBack: 18, isLeanBack: leanBackMode))
        .padding(.vertical, MarqueeTheme.scaled(7, leanBack: 11, isLeanBack: leanBackMode))
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        )
        .padding(.top, MarqueeTheme.scaled(16, leanBack: 28, isLeanBack: leanBackMode))
        .padding(.trailing, MarqueeTheme.scaled(20, leanBack: 36, isLeanBack: leanBackMode))
    }
}

private struct PlayerFailureOverlay: View {
    let message: String
    let onClose: () -> Void

    @Environment(\.leanBackMode) private var leanBackMode

    var body: some View {
        VStack(spacing: MarqueeTheme.scaled(16, leanBack: 24, isLeanBack: leanBackMode)) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: MarqueeTheme.scaled(34, leanBack: 50, isLeanBack: leanBackMode), weight: .semibold))
                .foregroundStyle(.yellow)

            Text("Playback unavailable")
                .font(.system(size: MarqueeTheme.scaled(22, leanBack: 32, isLeanBack: leanBackMode), weight: .semibold))
                .foregroundStyle(.white)

            Text(message)
                .font(.system(size: MarqueeTheme.scaled(14, leanBack: 20, isLeanBack: leanBackMode)))
                .foregroundStyle(.white.opacity(0.82))
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .frame(maxWidth: MarqueeTheme.scaled(520, leanBack: 760, isLeanBack: leanBackMode))

            Button(action: onClose) {
                Text("Close")
                    .font(.system(size: MarqueeTheme.scaled(14, leanBack: 20, isLeanBack: leanBackMode), weight: .semibold))
                    .foregroundStyle(.black)
                    .frame(
                        width: MarqueeTheme.scaled(120, leanBack: 180, isLeanBack: leanBackMode),
                        height: MarqueeTheme.scaled(34, leanBack: 52, isLeanBack: leanBackMode)
                    )
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
        }
        .padding(MarqueeTheme.scaled(28, leanBack: 42, isLeanBack: leanBackMode))
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        )
        .padding(MarqueeTheme.scaled(32, leanBack: 48, isLeanBack: leanBackMode))
    }
}

private struct PlayerPreparationOverlay: View {
    let message: String
    @Environment(\.leanBackMode) private var leanBackMode

    var body: some View {
        VStack(spacing: MarqueeTheme.scaled(12, leanBack: 18, isLeanBack: leanBackMode)) {
            ProgressView()
                .controlSize(.small)
                .tint(.white)

            Text(message)
                .font(.system(size: MarqueeTheme.scaled(14, leanBack: 20, isLeanBack: leanBackMode), weight: .medium))
                .foregroundStyle(.white.opacity(0.86))
        }
        .padding(.horizontal, MarqueeTheme.scaled(22, leanBack: 34, isLeanBack: leanBackMode))
        .padding(.vertical, MarqueeTheme.scaled(16, leanBack: 24, isLeanBack: leanBackMode))
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        )
    }
}

private struct PlayerStartupOverlay: View {
    let artworkPath: String?
    let message: String

    var body: some View {
        ZStack {
            if let artworkPath {
                CachedImageView(
                    path: artworkPath,
                    contentMode: .fill,
                    thumbnailPixelSize: ArtworkCache.heroBackdropThumbnailPixelSize
                )
                .ignoresSafeArea()
                .scaleEffect(1.04)
                .blur(radius: 16)
                .overlay(Color.black.opacity(0.62))

                LinearGradient(
                    colors: [
                        Color.black.opacity(0.78),
                        Color.black.opacity(0.48),
                        Color.black.opacity(0.82),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
            }

            PlayerPreparationOverlay(message: message)
        }
        .transition(.opacity)
    }
}

private struct PlayerExternalPlaybackOverlay: View {
    @Environment(\.leanBackMode) private var leanBackMode

    var body: some View {
        VStack(spacing: MarqueeTheme.scaled(10, leanBack: 16, isLeanBack: leanBackMode)) {
            Image(systemName: "rectangle.on.rectangle")
                .font(.system(size: MarqueeTheme.scaled(28, leanBack: 42, isLeanBack: leanBackMode), weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))

            Text("Playing in external video window")
                .font(.system(size: MarqueeTheme.scaled(16, leanBack: 24, isLeanBack: leanBackMode), weight: .semibold))
                .foregroundStyle(.white)

            Text("This keeps unsupported containers crash-isolated while Marquee stays open.")
                .font(.system(size: MarqueeTheme.scaled(13, leanBack: 19, isLeanBack: leanBackMode)))
                .foregroundStyle(.white.opacity(0.78))
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .frame(maxWidth: MarqueeTheme.scaled(360, leanBack: 520, isLeanBack: leanBackMode))
        }
        .padding(.horizontal, MarqueeTheme.scaled(22, leanBack: 34, isLeanBack: leanBackMode))
        .padding(.vertical, MarqueeTheme.scaled(18, leanBack: 28, isLeanBack: leanBackMode))
        .background(.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        )
    }
}
