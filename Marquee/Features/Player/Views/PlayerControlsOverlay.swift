import SwiftUI

// MARK: - PlayerControlsOverlay

enum PlayerHUDControl: CaseIterable, Hashable {
    case back
    case canvas
    case restart
    case skipBack
    case playPause
    case skipForward
    case nextEpisode
    case subtitles
    case audioTrack
    case speed
    case fullscreen
}

struct PlayerHUDCapabilities: Equatable {
    let hasSubtitles: Bool
    let hasMultipleAudioTracks: Bool
    let hasNextEpisode: Bool
    /// The embedded bridge cannot retime its realtime-paced output, so the
    /// speed control is hidden there rather than offered and ignored.
    let canChangeSpeed: Bool

    init(hasSubtitles: Bool, hasMultipleAudioTracks: Bool, hasNextEpisode: Bool = false, canChangeSpeed: Bool = true) {
        self.hasSubtitles = hasSubtitles
        self.hasMultipleAudioTracks = hasMultipleAudioTracks
        self.hasNextEpisode = hasNextEpisode
        self.canChangeSpeed = canChangeSpeed
    }
}

enum PlayerHUDFocusIDs {
    static let root: FocusNodeID = "player-hud-root"
    static let back: FocusNodeID = "player-hud-back"
    static let canvas: FocusNodeID = "player-hud-canvas"
    static let transport: FocusNodeID = "player-hud-transport"
    static let restart: FocusNodeID = "player-hud-restart"
    static let nextEpisode: FocusNodeID = "player-hud-next-episode"
    static let skipBack: FocusNodeID = "player-hud-skip-back"
    static let playPause: FocusNodeID = "player-hud-play-pause"
    static let skipForward: FocusNodeID = "player-hud-skip-forward"
    static let subtitles: FocusNodeID = "player-hud-subtitles"
    static let audioTrack: FocusNodeID = "player-hud-audio-track"
    static let speed: FocusNodeID = "player-hud-speed"
    static let fullscreen: FocusNodeID = "player-hud-fullscreen"

    static func id(for control: PlayerHUDControl) -> FocusNodeID {
        switch control {
        case .back: return back
        case .canvas: return canvas
        case .restart: return restart
        case .nextEpisode: return nextEpisode
        case .skipBack: return skipBack
        case .playPause: return playPause
        case .skipForward: return skipForward
        case .subtitles: return subtitles
        case .audioTrack: return audioTrack
        case .speed: return speed
        case .fullscreen: return fullscreen
        }
    }

    static func control(for id: FocusNodeID) -> PlayerHUDControl? {
        switch id {
        case back: return .back
        case canvas: return .canvas
        case restart: return .restart
        case nextEpisode: return .nextEpisode
        case skipBack: return .skipBack
        case playPause: return .playPause
        case skipForward: return .skipForward
        case subtitles: return .subtitles
        case audioTrack: return .audioTrack
        case speed: return .speed
        case fullscreen: return .fullscreen
        default: return nil
        }
    }
}

enum PlayerHUDFocusPolicy {
    static var initialState: FocusEngineState {
        FocusEngineState(focused: PlayerHUDFocusIDs.canvas)
    }

    static func transportControls(capabilities: PlayerHUDCapabilities) -> [PlayerHUDControl] {
        var controls: [PlayerHUDControl] = [
            .restart,
            .skipBack,
            .playPause,
            .skipForward,
        ]
        if capabilities.hasNextEpisode {
            controls.append(.nextEpisode)
        }
        if capabilities.hasSubtitles {
            controls.append(.subtitles)
        }
        if capabilities.hasMultipleAudioTracks {
            controls.append(.audioTrack)
        }
        if capabilities.canChangeSpeed {
            controls.append(.speed)
        }
        controls.append(.fullscreen)
        return controls
    }

    static func tree(capabilities: PlayerHUDCapabilities) -> FocusNode {
        let transportChildren = transportControls(capabilities: capabilities).map { control in
            FocusNode(
                PlayerHUDFocusIDs.id(for: control),
                kind: .leaf,
                guides: [.up: PlayerHUDFocusIDs.canvas]
            )
        }

        return FocusNode(
            PlayerHUDFocusIDs.root,
            kind: .container(.vertical),
            preferredFocus: PlayerHUDFocusIDs.canvas,
            children: [
                FocusNode(
                    PlayerHUDFocusIDs.back,
                    kind: .leaf,
                    guides: [.down: PlayerHUDFocusIDs.canvas]
                ),
                FocusNode(
                    PlayerHUDFocusIDs.canvas,
                    kind: .leaf,
                    guides: [
                        .up: PlayerHUDFocusIDs.back,
                        .down: PlayerHUDFocusIDs.transport,
                    ]
                ),
                FocusNode(
                    PlayerHUDFocusIDs.transport,
                    kind: .container(.horizontal),
                    preferredFocus: PlayerHUDFocusIDs.playPause,
                    children: transportChildren
                ),
            ]
        )
    }

    static func normalized(
        _ state: FocusEngineState,
        capabilities: PlayerHUDCapabilities
    ) -> FocusEngineState {
        let available = Set(
            [PlayerHUDControl.back, .canvas]
                + transportControls(capabilities: capabilities)
        )
        guard let control = PlayerHUDFocusIDs.control(for: state.focused),
              available.contains(control) else {
            return initialState
        }
        return state
    }

    static func move(
        _ direction: FocusDirection,
        state: FocusEngineState,
        capabilities: PlayerHUDCapabilities
    ) -> FocusEngineState {
        let normalizedState = normalized(state, capabilities: capabilities)
        return FocusEngine(root: tree(capabilities: capabilities))
            .move(direction, state: normalizedState)
            .state
    }
}

enum PlayerHUDChromeMetrics {
    static let compactControlSize: CGFloat = 48
    static let leanBackControlSize: CGFloat = 68
    static let compactRingLineWidth: CGFloat = 3
    static let leanBackRingLineWidth: CGFloat = 4
    static let focusScale: CGFloat = 1.07
    static let glowRadius: CGFloat = 30
}

private struct PlayerHUDControlFocusModifier: ViewModifier {
    let isFocused: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.leanBackMode) private var leanBackMode

    private var controlSize: CGFloat {
        leanBackMode
            ? PlayerHUDChromeMetrics.leanBackControlSize
            : PlayerHUDChromeMetrics.compactControlSize
    }

    private var ringLineWidth: CGFloat {
        leanBackMode
            ? PlayerHUDChromeMetrics.leanBackRingLineWidth
            : PlayerHUDChromeMetrics.compactRingLineWidth
    }

    func body(content: Content) -> some View {
        content
            .frame(width: controlSize, height: controlSize)
            .background(
                RoundedRectangle(cornerRadius: controlSize * 0.24, style: .continuous)
                    .fill(
                        isFocused
                            ? MarqueeTheme.structuralFocus.opacity(0.28)
                            : Color.black.opacity(0.52)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: controlSize * 0.24, style: .continuous)
                    .stroke(Color.white.opacity(isFocused ? 0.22 : 0.10), lineWidth: 1)
            )
            .focusChrome(
                isFocused,
                cornerRadius: controlSize * 0.24,
                focusScale: PlayerHUDChromeMetrics.focusScale,
                glowRadius: PlayerHUDChromeMetrics.glowRadius,
                ringLineWidth: ringLineWidth
            )
            .animation(
                MarqueeTheme.motion(MarqueeTheme.cardFocusAnimation, reduceMotion: reduceMotion),
                value: isFocused
            )
    }
}

extension View {
    func playerHUDFocused(_ isFocused: Bool) -> some View {
        modifier(PlayerHUDControlFocusModifier(isFocused: isFocused))
    }
}

struct PlayerControlsOverlay: View {

    @ObservedObject var playerService: MPVPlayerService
    @ObservedObject private var clock: PlaybackClockModel
    var focusedControl: PlayerHUDControl? = nil
    var onNextEpisode: (() -> Void)? = nil

    @Environment(\.leanBackMode) private var leanBackMode

    private static let speedSteps: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0]

    init(
        playerService: MPVPlayerService,
        clock: PlaybackClockModel,
        focusedControl: PlayerHUDControl? = nil,
        onNextEpisode: (() -> Void)? = nil
    ) {
        self.playerService = playerService
        self.focusedControl = focusedControl
        self.onNextEpisode = onNextEpisode
        _clock = ObservedObject(wrappedValue: clock)
    }

    var body: some View {
        VStack(spacing: 0) {
            seekBar
            controlsBar
        }
        .padding(.horizontal, MarqueeTheme.scaled(MarqueeTheme.spacingLG, leanBack: 40, isLeanBack: leanBackMode))
        .padding(.bottom, MarqueeTheme.scaled(MarqueeTheme.spacingMD, leanBack: 28, isLeanBack: leanBackMode))
        .background(controlsBackground)
    }

    // MARK: - Seek Bar

    private var seekBar: some View {
        GeometryReader { geometry in
            let progress = clock.duration > 0
                ? clock.currentTime / clock.duration
                : 0

            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(MarqueeTheme.textTertiary.opacity(0.3))
                    .frame(height: seekBarHeight)

                Rectangle()
                    .fill(MarqueeTheme.accentSecondary)
                    .frame(width: geometry.size.width * progress, height: seekBarHeight)
            }
            .clipShape(Capsule())
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let fraction = max(0, min(1, value.location.x / geometry.size.width))
                        let seekTime = fraction * clock.duration
                        playerService.seek(to: seekTime)
                    }
            )
        }
        .frame(height: MarqueeTheme.scaled(24, leanBack: 38, isLeanBack: leanBackMode))
        .padding(.bottom, MarqueeTheme.scaled(MarqueeTheme.spacingSM, leanBack: 14, isLeanBack: leanBackMode))
    }

    private var seekBarHeight: CGFloat {
        MarqueeTheme.scaled(4, leanBack: 7, isLeanBack: leanBackMode)
    }

    // MARK: - Controls Bar

    private var controlsBar: some View {
        HStack(spacing: MarqueeTheme.scaled(MarqueeTheme.spacingMD, leanBack: 24, isLeanBack: leanBackMode)) {
            playbackControls
            timeDisplay
            Spacer()
            trackAndSpeedControls
            volumeControl
            fullscreenButton
        }
    }

    // MARK: - Playback Controls Group

    private var playbackControls: some View {
        HStack(spacing: MarqueeTheme.scaled(MarqueeTheme.spacingMD, leanBack: 24, isLeanBack: leanBackMode)) {
            restartButton
            skipBackButton
            playPauseButton
            skipForwardButton
            if onNextEpisode != nil {
                nextEpisodeButton
            }
        }
    }

    // MARK: - Track & Speed Controls Group

    private var trackAndSpeedControls: some View {
        HStack(spacing: MarqueeTheme.scaled(MarqueeTheme.spacingMD, leanBack: 24, isLeanBack: leanBackMode)) {
            if playerService.hasSubtitles {
                subtitleButton
            }
            if playerService.availableAudioTracks.count > 1 {
                audioTrackButton
            }
            if playerService.supportsPlaybackSpeed {
                speedButton
            }
        }
    }

    // MARK: - Skip Buttons

    private var nextEpisodeButton: some View {
        Button(action: { onNextEpisode?() }) {
            ZStack {
                Image(systemName: "forward.end")
                    .font(.system(size: MarqueeTheme.scaled(16, leanBack: 24, isLeanBack: leanBackMode), weight: .medium))
                    .foregroundColor(MarqueeTheme.textPrimary)
            }
        }
        .buttonStyle(.plain)
        .playerHUDFocused(focusedControl == .nextEpisode)
    }

    private var restartButton: some View {
        Button(action: { playerService.seek(to: 0) }) {
            ZStack {
                Image(systemName: "backward.end")
                    .font(.system(size: MarqueeTheme.scaled(16, leanBack: 24, isLeanBack: leanBackMode), weight: .medium))
                    .foregroundColor(MarqueeTheme.textPrimary)
            }
        }
        .buttonStyle(.plain)
        .playerHUDFocused(focusedControl == .restart)
    }

    private var skipBackButton: some View {
        Button(action: { playerService.seekRelative(-10) }) {
            ZStack {
                Image(systemName: "gobackward.10")
                    .font(.system(size: MarqueeTheme.scaled(16, leanBack: 24, isLeanBack: leanBackMode), weight: .medium))
                    .foregroundColor(MarqueeTheme.textPrimary)
            }
        }
        .buttonStyle(.plain)
        .playerHUDFocused(focusedControl == .skipBack)
    }

    private var skipForwardButton: some View {
        Button(action: { playerService.seekRelative(30) }) {
            ZStack {
                Image(systemName: "goforward.30")
                    .font(.system(size: MarqueeTheme.scaled(16, leanBack: 24, isLeanBack: leanBackMode), weight: .medium))
                    .foregroundColor(MarqueeTheme.textPrimary)
            }
        }
        .buttonStyle(.plain)
        .playerHUDFocused(focusedControl == .skipForward)
    }

    // MARK: - Play/Pause

    private var playPauseButton: some View {
        Button(action: { playerService.togglePause() }) {
            Image(systemName: playerService.isPaused ? "play.fill" : "pause.fill")
                .font(.system(size: MarqueeTheme.scaled(22, leanBack: 34, isLeanBack: leanBackMode), weight: .semibold))
                .foregroundColor(MarqueeTheme.textPrimary)
        }
        .buttonStyle(.plain)
        .playerHUDFocused(focusedControl == .playPause)
    }

    // MARK: - Time Display

    private var timeDisplay: some View {
        HStack(spacing: MarqueeTheme.scaled(4, leanBack: 7, isLeanBack: leanBackMode)) {
            Text(clock.currentTime.formattedPlaybackTime)
            Text("/")
                .foregroundColor(MarqueeTheme.textTertiary)
            Text(clock.duration.formattedPlaybackTime)
        }
        .font(.system(size: MarqueeTheme.scaled(12, leanBack: 17, isLeanBack: leanBackMode), weight: .medium, design: .monospaced))
        .foregroundColor(MarqueeTheme.textSecondary)
    }

    // MARK: - Subtitles

    private var subtitleButton: some View {
        Menu {
            Button(action: { playerService.selectSubtitleTrack(nil) }) {
                HStack {
                    Text("Off")
                    if playerService.currentSubtitleTrack == nil {
                        Spacer()
                        Image(systemName: "checkmark")
                    }
                }
            }

            Divider()

            ForEach(playerService.availableSubtitleTracks) { track in
                Button(action: { playerService.selectSubtitleTrack(track) }) {
                    HStack {
                        Text(track.displayName)
                        if track == playerService.currentSubtitleTrack {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            Image(systemName: playerService.subtitlesEnabled ? "captions.bubble.fill" : "captions.bubble")
                .font(.system(size: MarqueeTheme.scaled(16, leanBack: 24, isLeanBack: leanBackMode)))
                .foregroundColor(playerService.subtitlesEnabled ? MarqueeTheme.accentSecondary : MarqueeTheme.textPrimary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .playerHUDFocused(focusedControl == .subtitles)
    }

    // MARK: - Audio Track

    private var audioTrackButton: some View {
        Menu {
            ForEach(playerService.availableAudioTracks) { track in
                Button(action: { playerService.selectAudioTrack(track) }) {
                    HStack {
                        Text(track.displayName)
                        if track == playerService.currentAudioTrack {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "speaker.wave.2")
                .font(.system(size: MarqueeTheme.scaled(16, leanBack: 24, isLeanBack: leanBackMode)))
                .foregroundColor(MarqueeTheme.textPrimary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .playerHUDFocused(focusedControl == .audioTrack)
    }

    // MARK: - Playback Speed

    private var speedButton: some View {
        Menu {
            ForEach(Self.speedSteps, id: \.self) { speed in
                Button(action: { playerService.setPlaybackSpeed(speed) }) {
                    HStack {
                        Text(speedLabel(speed))
                        if playerService.playbackSpeed == speed {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            Text(speedLabel(playerService.playbackSpeed))
                .font(.system(size: MarqueeTheme.scaled(12, leanBack: 17, isLeanBack: leanBackMode), weight: .semibold, design: .monospaced))
                .foregroundColor(
                    playerService.playbackSpeed != 1.0
                        ? MarqueeTheme.accentSecondary
                        : MarqueeTheme.textPrimary
                )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .playerHUDFocused(focusedControl == .speed)
    }

    private func speedLabel(_ speed: Float) -> String {
        if speed == Float(Int(speed)) {
            return "\(Int(speed))x"
        }
        return String(format: "%.2gx", speed)
    }

    // MARK: - Volume

    private var volumeControl: some View {
        HStack(spacing: MarqueeTheme.scaled(MarqueeTheme.spacingXS, leanBack: 8, isLeanBack: leanBackMode)) {
            Button(action: { playerService.toggleMute() }) {
                Image(systemName: volumeIcon)
                    .font(.system(size: MarqueeTheme.scaled(16, leanBack: 24, isLeanBack: leanBackMode)))
                    .foregroundColor(MarqueeTheme.textPrimary)
            }
            .buttonStyle(.plain)

            Slider(
                value: Binding(
                    get: { playerService.volume },
                    set: { playerService.setVolume($0) }
                ),
                in: 0...100
            )
            .frame(width: MarqueeTheme.scaled(80, leanBack: 130, isLeanBack: leanBackMode))
        }
    }

    private var volumeIcon: String {
        if playerService.isMuted || playerService.volume == 0 {
            return "speaker.slash.fill"
        } else if playerService.volume < 33 {
            return "speaker.wave.1.fill"
        } else if playerService.volume < 66 {
            return "speaker.wave.2.fill"
        } else {
            return "speaker.wave.3.fill"
        }
    }

    // MARK: - Fullscreen

    private var fullscreenButton: some View {
        Button(action: {
            NSApplication.shared.keyWindow?.toggleFullScreen(nil)
        }) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: MarqueeTheme.scaled(16, leanBack: 24, isLeanBack: leanBackMode)))
                .foregroundColor(MarqueeTheme.textPrimary)
        }
        .buttonStyle(.plain)
        .playerHUDFocused(focusedControl == .fullscreen)
    }

    // MARK: - Background

    private var controlsBackground: some View {
        LinearGradient(
            colors: [.clear, Color.black.opacity(0.8)],
            startPoint: .top,
            endPoint: .bottom
        )
        .allowsHitTesting(false)
    }

}
