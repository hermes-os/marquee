import Foundation
import AVFoundation
import Combine
import os

// MARK: - AVPlayerService
// TODO: [M4 Migration] Replace with MPVPlayerService using @Observable + LibMPV for MKV/WebM support

class AVPlayerService: ObservableObject, PlayerServiceProtocol {

    // MARK: - Published State

    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var isPaused: Bool = true
    @Published private(set) var volume: Double = 100
    @Published private(set) var isMuted: Bool = false
    @Published private(set) var subtitlesEnabled: Bool = false
    @Published private(set) var hasSubtitles: Bool = false
    @Published private(set) var availableAudioTracks: [AudioTrack] = []
    @Published private(set) var currentAudioTrack: AudioTrack? = nil
    @Published private(set) var playbackSpeed: Float = 1.0
    @Published private(set) var availableSubtitleTracks: [SubtitleTrack] = []
    @Published private(set) var currentSubtitleTrack: SubtitleTrack? = nil
    @Published private(set) var currentSubtitleEntries: [SubtitleEntry] = []

    // MARK: - Callbacks

    var onPlaybackEnded: (() -> Void)?

    // MARK: - AVPlayer

    private(set) var player = AVPlayer()
    private var timeObserver: Any?
    private var endObserver: Any?
    private var cancellables = Set<AnyCancellable>()
    private var savedSpeed: Float = 1.0
    private var currentVideoPath: String?
    private var discoveredSubtitles: [DiscoveredSubtitle] = []

    // MARK: - Init

    init() {
        setupObservers()
    }

    deinit {
        if let timeObserver = timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        if let endObserver = endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
    }

    // MARK: - Observers

    private func setupObservers() {
        let interval = CMTime(seconds: 0.005, preferredTimescale: 200_000)
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { [weak self] time in
            guard let self = self else { return }
            self.currentTime = time.seconds
        }

        player.publisher(for: \.rate)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] rate in
                self?.isPaused = (rate == 0)
            }
            .store(in: &cancellables)

        player.publisher(for: \.volume)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] vol in
                self?.volume = Double(vol) * 100.0
            }
            .store(in: &cancellables)

        player.publisher(for: \.isMuted)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] muted in
                self?.isMuted = muted
            }
            .store(in: &cancellables)
    }

    // MARK: - Commands

    func loadFile(_ path: String) {
        if let endObserver = endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }

        let url = URL(fileURLWithPath: path)
        let item = AVPlayerItem(url: url)

        item.publisher(for: \.duration)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] dur in
                if dur.isNumeric {
                    self?.duration = dur.seconds
                }
            }
            .store(in: &cancellables)

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            self?.onPlaybackEnded?()
        }

        subtitlesEnabled = false
        hasSubtitles = false
        availableAudioTracks = []
        currentAudioTrack = nil
        availableSubtitleTracks = []
        currentSubtitleTrack = nil
        currentSubtitleEntries = []
        playbackSpeed = 1.0
        savedSpeed = 1.0
        currentVideoPath = path
        discoveredSubtitles = SubtitleDiscovery.discover(forVideoAt: path)

        item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard status == .readyToPlay else { return }
                self?.buildSubtitleTrackList(for: item)
                self?.enumerateAudioTracks(for: item)
            }
            .store(in: &cancellables)

        player.replaceCurrentItem(with: item)
        player.play()
    }

    func togglePause() {
        if player.rate == 0 {
            player.rate = savedSpeed
        } else {
            player.pause()
        }
    }

    func seek(to seconds: Double) {
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func seekRelative(_ seconds: Double) {
        let current = player.currentTime().seconds
        seek(to: max(0, current + seconds))
    }

    func setVolume(_ value: Double) {
        player.volume = Float(max(0, min(100, value)) / 100.0)
    }

    func toggleMute() {
        player.isMuted.toggle()
    }

    func toggleSubtitles() {
        if subtitlesEnabled {
            selectSubtitleTrack(nil)
        } else if let firstTrack = availableSubtitleTracks.first {
            selectSubtitleTrack(firstTrack)
        }
    }

    func selectSubtitleTrack(_ track: SubtitleTrack?) {
        guard let track = track else {
            if let item = player.currentItem,
               let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: .legible) {
                item.select(nil, in: group)
            }
            currentSubtitleTrack = nil
            currentSubtitleEntries = []
            subtitlesEnabled = false
            MarqueeLogger.player.info("Subtitles disabled")
            return
        }

        if track.isExternal, let externalPath = track.externalPath {
            if let item = player.currentItem,
               let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: .legible) {
                item.select(nil, in: group)
            }

            let entries = SRTParser.parse(fileAt: externalPath)
            currentSubtitleEntries = entries
            currentSubtitleTrack = track
            subtitlesEnabled = true
            hasSubtitles = true
            MarqueeLogger.player.info("Loaded external subtitle: \(track.displayName) (\(entries.count) entries)")
        } else {
            currentSubtitleEntries = []

            guard let item = player.currentItem,
                  let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: .legible) else { return }

            let trackIndex = availableSubtitleTracks
                .filter { !$0.isExternal }
                .firstIndex(of: track) ?? 0

            if trackIndex < group.options.count {
                item.select(group.options[trackIndex], in: group)
            }

            currentSubtitleTrack = track
            subtitlesEnabled = true
            MarqueeLogger.player.info("Selected embedded subtitle: \(track.displayName)")
        }
    }

    // MARK: - Audio Track Selection

    func selectAudioTrack(_ track: AudioTrack) {
        guard let item = player.currentItem,
              let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: .audible) else { return }

        if let option = group.options.first(where: { $0.displayName == track.displayName }) {
            item.select(option, in: group)
            currentAudioTrack = track
            MarqueeLogger.player.info("Selected audio track: \(track.displayName)")
        }
    }

    // MARK: - Playback Speed

    func setPlaybackSpeed(_ speed: Float) {
        let clampedSpeed = max(0.5, min(3.0, speed))
        savedSpeed = clampedSpeed
        playbackSpeed = clampedSpeed
        if player.rate != 0 {
            player.rate = clampedSpeed
        }
        MarqueeLogger.player.info("Playback speed set to \(clampedSpeed)x")
    }

    // MARK: - Stop

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    // MARK: - Audio Track Enumeration

    private func enumerateAudioTracks(for item: AVPlayerItem) {
        guard let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: .audible) else {
            MarqueeLogger.player.debug("No audible media selection group found")
            return
        }

        var tracks: [AudioTrack] = []
        for (index, option) in group.options.enumerated() {
            let locale = option.locale
            let languageCode = locale?.languageCode
            let languageName = locale.flatMap { Locale.current.localizedString(forLanguageCode: $0.languageCode ?? "") }

            var formatInfo = ""
            if let formatDescriptions = option.propertyList() as? [String: Any],
               let codecName = formatDescriptions["MediaSubType"] as? String {
                formatInfo = codecName
            }

            let channelDescription = audioChannelDescription(for: option)

            var displayParts: [String] = []
            if let name = languageName {
                displayParts.append(name)
            } else {
                displayParts.append(option.displayName)
            }

            var details: [String] = []
            if !formatInfo.isEmpty {
                details.append(formatInfo)
            }
            if let channels = channelDescription {
                details.append(channels)
            }
            if !details.isEmpty {
                displayParts.append("(\(details.joined(separator: " ")))")
            }

            let track = AudioTrack(
                id: "\(index)-\(option.displayName)",
                displayName: displayParts.joined(separator: " "),
                languageCode: languageCode
            )
            tracks.append(track)
        }

        availableAudioTracks = tracks
        MarqueeLogger.player.info("Found \(tracks.count) audio track(s)")

        if let selectedOption = item.currentMediaSelection.selectedMediaOption(in: group) {
            currentAudioTrack = tracks.first { $0.displayName.contains(selectedOption.displayName) }
                ?? tracks.first
        } else {
            currentAudioTrack = tracks.first
        }

        autoSelectPreferredAudio()
    }

    private func audioChannelDescription(for option: AVMediaSelectionOption) -> String? {
        let name = option.displayName.lowercased()
        if name.contains("5.1") || name.contains("surround") {
            return "5.1"
        } else if name.contains("7.1") {
            return "7.1"
        } else if name.contains("stereo") || name.contains("2ch") {
            return "Stereo"
        } else if name.contains("mono") || name.contains("1ch") {
            return "Mono"
        }
        return nil
    }

    // MARK: - Subtitle Track Enumeration

    private func buildSubtitleTrackList(for item: AVPlayerItem) {
        var tracks: [SubtitleTrack] = []

        if let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: .legible) {
            for (index, option) in group.options.enumerated() {
                let locale = option.locale
                let languageName = locale.flatMap {
                    Locale.current.localizedString(forLanguageCode: $0.languageCode ?? "")
                }

                let displayName = languageName ?? option.displayName
                let track = SubtitleTrack(
                    id: "embedded-\(index)",
                    displayName: displayName,
                    isExternal: false,
                    externalPath: nil
                )
                tracks.append(track)
            }
        }

        for (index, discovered) in discoveredSubtitles.enumerated() {
            let track = SubtitleTrack(
                id: "external-\(index)",
                displayName: discovered.displayName,
                isExternal: true,
                externalPath: discovered.path
            )
            tracks.append(track)
        }

        availableSubtitleTracks = tracks
        hasSubtitles = !tracks.isEmpty

        MarqueeLogger.player.info("Built subtitle track list: \(tracks.count) track(s) (\(tracks.filter(\.isExternal).count) external)")

        autoSelectPreferredSubtitle()
    }

    // MARK: - Auto-Select Preferred Tracks

    private func autoSelectPreferredSubtitle() {
        let preferred = UserSettings.shared.defaultSubtitleLanguage
        guard preferred != "None", !availableSubtitleTracks.isEmpty else { return }

        if let match = availableSubtitleTracks.first(where: {
            $0.displayName.localizedCaseInsensitiveContains(preferred)
        }) {
            selectSubtitleTrack(match)
            MarqueeLogger.player.info("Auto-selected subtitle track: \(match.displayName) (preferred: \(preferred))")
        }
    }

    private func autoSelectPreferredAudio() {
        let preferred = UserSettings.shared.defaultAudioLanguage
        guard !preferred.isEmpty, !availableAudioTracks.isEmpty else { return }

        if let match = availableAudioTracks.first(where: {
            $0.displayName.localizedCaseInsensitiveContains(preferred)
        }) {
            selectAudioTrack(match)
            MarqueeLogger.player.info("Auto-selected audio track: \(match.displayName) (preferred: \(preferred))")
        }
    }
}
