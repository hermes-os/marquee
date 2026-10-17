import Foundation

// MARK: - AudioTrack

struct AudioTrack: Identifiable, Equatable {
    let id: String
    let displayName: String
    let languageCode: String?
}

// MARK: - SubtitleTrack

struct SubtitleTrack: Identifiable, Equatable {
    let id: String
    let displayName: String
    let isExternal: Bool
    let externalPath: String?
}

// MARK: - SubtitleEntry

struct SubtitleEntry {
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String
}

// MARK: - PlayerServiceProtocol

protocol PlayerServiceProtocol {
    var currentTime: Double { get }
    var duration: Double { get }
    var isPaused: Bool { get }
    var volume: Double { get }
    var isMuted: Bool { get }
    var subtitlesEnabled: Bool { get }
    var hasSubtitles: Bool { get }
    var availableAudioTracks: [AudioTrack] { get }
    var currentAudioTrack: AudioTrack? { get }
    var playbackSpeed: Float { get }

    var availableSubtitleTracks: [SubtitleTrack] { get }
    var currentSubtitleTrack: SubtitleTrack? { get }
    var currentSubtitleEntries: [SubtitleEntry] { get }

    func loadFile(_ path: String)
    func togglePause()
    func seek(to seconds: Double)
    func seekRelative(_ seconds: Double)
    func setVolume(_ value: Double)
    func toggleMute()
    func toggleSubtitles()
    func selectSubtitleTrack(_ track: SubtitleTrack?)
    func selectAudioTrack(_ track: AudioTrack)
    func setPlaybackSpeed(_ speed: Float)
    func stop()
}
