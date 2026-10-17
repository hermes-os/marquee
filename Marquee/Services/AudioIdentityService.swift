import AVFoundation
import Foundation

protocol AudioIdentityPlaying: AnyObject {
    var currentTime: TimeInterval { get set }
    var isPlaying: Bool { get }

    @discardableResult
    func play() -> Bool

    func stop()
}

extension AVAudioPlayer: AudioIdentityPlaying {}

struct AudioIdentitySettingsSnapshot {
    let interfaceSoundsEnabled: Bool
    let launchIdentEnabled: Bool
    let soundPack: AudioIdentitySoundPack?

    init(
        interfaceSoundsEnabled: Bool,
        launchIdentEnabled: Bool,
        soundPack: AudioIdentitySoundPack? = nil
    ) {
        self.interfaceSoundsEnabled = interfaceSoundsEnabled
        self.launchIdentEnabled = launchIdentEnabled
        self.soundPack = soundPack
    }
}

enum AudioIdentitySoundPack: String, Codable, CaseIterable, Identifiable {
    case velvet
    case hearth
    case nocturne

    var id: String { rawValue }

    var displayName: String {
        rawValue.capitalized
    }
}

enum AudioIdentityPickerPolicy {
    static let title = "Sound pack"
    static let accessibilityHint = "Selects the launch and interface sound set"
    static var options: [AudioIdentitySoundPack] { AudioIdentitySoundPack.allCases }
}

enum AudioIdentityPackResolver {
    static func resolve(persistedRawValue: String?) -> AudioIdentitySoundPack? {
        persistedRawValue.flatMap(AudioIdentitySoundPack.init(rawValue:))
    }
}

enum AudioIdentityAssetCatalog {
    static let manifestName = "CuratedPacks"
    static let manifestExtension = "sha256"

    static func curatedSubdirectory(in bundle: Bundle) -> String? {
        guard let manifestURL = bundle.url(
            forResource: manifestName,
            withExtension: manifestExtension,
            subdirectory: "Sounds"
        ),
        let contents = try? String(contentsOf: manifestURL, encoding: .utf8) else {
            return nil
        }

        let lines = contents.split(whereSeparator: { $0.isNewline })
        guard lines.count == AudioIdentitySoundPack.allCases.count * AudioIdentityCue.allCases.count else {
            return nil
        }
        var directories = Set<String>()
        for line in lines {
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            guard fields.count == 2,
                  fields[0].count == 64,
                  fields[0].allSatisfy({ $0.isHexDigit }) else { return nil }
            let relativePath = String(fields[1])
            guard !relativePath.hasPrefix("/"), !relativePath.contains("..") else { return nil }
            let components = relativePath.split(separator: "/", omittingEmptySubsequences: true)
            guard components.count == 2,
                  components[0].hasPrefix("CuratedPacks-") else { return nil }
            directories.insert(String(components[0]))
        }
        guard directories.count == 1, let directory = directories.first else { return nil }
        return "Sounds/\(directory)"
    }
}

enum AudioIdentityCue: CaseIterable, Hashable {
    case launchIdent
    case focus
    case select
    case back
    case boundary

    static let interfaceCues: [AudioIdentityCue] = [
        .focus,
        .select,
        .back,
        .boundary,
    ]

    var assetName: String {
        switch self {
        case .launchIdent: return "launch-ident"
        case .focus: return "focus-tick"
        case .select: return "select-tick"
        case .back: return "back-tick"
        case .boundary: return "boundary-tick"
        }
    }

    func assetName(for pack: AudioIdentitySoundPack) -> String {
        "\(pack.rawValue)-\(candidateAssetSuffix)"
    }

    var assetExtension: String {
        self == .launchIdent ? "m4a" : "wav"
    }

    var fixedGain: Float {
        switch self {
        case .launchIdent: return 0.24
        case .focus: return 0.12
        case .select: return 0.18
        case .back: return 0.15
        case .boundary: return 0.20
        }
    }

    func fixedGain(for pack: AudioIdentitySoundPack) -> Float {
        switch self {
        case .launchIdent: return 0.20
        case .focus: return 0.10
        case .select: return 0.14
        case .back: return 0.09
        case .boundary: return 0.05
        }
    }

    func assetExtension(for pack: AudioIdentitySoundPack) -> String { "wav" }

    private var candidateAssetSuffix: String {
        switch self {
        case .launchIdent: return "launch"
        case .focus: return "focus"
        case .select: return "select"
        case .back: return "back"
        case .boundary: return "boundary"
        }
    }
}

struct AudioIdentitySuppressionContext {
    let isPlayerPresented: Bool
    let launchArguments: [String]
    let interfaceSoundsEnabled: Bool
    let launchIdentEnabled: Bool
}

enum AudioIdentitySuppressionPolicy {
    static func allows(
        _ cue: AudioIdentityCue,
        in context: AudioIdentitySuppressionContext
    ) -> Bool {
        guard !context.isPlayerPresented else { return false }
        guard !isAutomationLaunch(context.launchArguments) else { return false }

        switch cue {
        case .launchIdent:
            return context.launchIdentEnabled
        case .focus, .select, .back, .boundary:
            return context.interfaceSoundsEnabled
        }
    }

    static func isAutomationLaunch(_ arguments: [String]) -> Bool {
        arguments.contains { argument in
            argument.hasPrefix("--verify-") || argument.hasPrefix("--qa-")
        }
    }
}

struct AudioIdentityThrottle {
    let minimumInterval: TimeInterval = 0.05
    private var lastPlaybackTime: TimeInterval?

    mutating func shouldPlay(at time: TimeInterval) -> Bool {
        if let lastPlaybackTime,
           time >= lastPlaybackTime,
           time - lastPlaybackTime < minimumInterval {
            return false
        }
        lastPlaybackTime = time
        return true
    }
}

struct LaunchIdentOncePolicy {
    private var hasAttempted = false

    mutating func consumeAttempt() -> Bool {
        guard !hasAttempted else { return false }
        hasAttempted = true
        return true
    }
}

enum AudioIdentityFeedbackPolicy {
    static func cue(
        for command: RemoteCommand,
        didNavigate: Bool,
        focusEvents: [FocusEngineEvent] = [],
        didReachBoundary: Bool = false
    ) -> AudioIdentityCue? {
        switch command {
        case .select:
            return .select
        case .back:
            return .back
        case .up, .down, .left, .right:
            if didReachBoundary || focusEvents.contains(where: isBoundaryEvent) {
                return .boundary
            }
            if didNavigate || focusEvents.contains(where: isNavigationEvent) {
                return .focus
            }
            return nil
        }
    }

    private static func isBoundaryEvent(_ event: FocusEngineEvent) -> Bool {
        if case .boundaryHit = event { return true }
        return false
    }

    private static func isNavigationEvent(_ event: FocusEngineEvent) -> Bool {
        switch event {
        case .focusChanged, .stepperActivated:
            return true
        case .boundaryHit, .restored:
            return false
        }
    }
}

final class AudioIdentityService {
    static let shared = AudioIdentityService()

    private let launchArguments: [String]
    private let settingsProvider: () -> AudioIdentitySettingsSnapshot
    private let uptimeProvider: () -> TimeInterval
    private var legacyPlayers: [AudioIdentityCue: AudioIdentityPlaying] = [:]
    private var curatedPlayers: [AudioIdentitySoundPack: [AudioIdentityCue: AudioIdentityPlaying]] = [:]
    private var throttle = AudioIdentityThrottle()
    private var launchOnce = LaunchIdentOncePolicy()
    private var isPlayerPresented: () -> Bool = { false }

    var preloadedCueCount: Int {
        legacyPlayers.count + curatedPlayers.values.reduce(0) { $0 + $1.count }
    }

    private init(
        bundle: Bundle = .main,
        launchArguments: [String] = CommandLine.arguments,
        settingsProvider: @escaping () -> AudioIdentitySettingsSnapshot = {
            let settings = UserSettings.shared
            return AudioIdentitySettingsSnapshot(
                interfaceSoundsEnabled: settings.interfaceSoundsEnabled,
                launchIdentEnabled: settings.launchIdentEnabled,
                soundPack: settings.soundPack
            )
        },
        uptimeProvider: @escaping () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        }
    ) {
        self.launchArguments = launchArguments
        self.settingsProvider = settingsProvider
        self.uptimeProvider = uptimeProvider
        for cue in AudioIdentityCue.allCases {
            guard let url = bundle.url(
                forResource: cue.assetName,
                withExtension: cue.assetExtension,
                subdirectory: "Sounds"
            ) else {
                MarqueeLogger.general.error("Missing audio identity asset: \(cue.assetName, privacy: .public).\(cue.assetExtension, privacy: .public)")
                continue
            }
            do {
                let player = try AVAudioPlayer(contentsOf: url)
                player.volume = cue.fixedGain
                player.prepareToPlay()
                legacyPlayers[cue] = player
            } catch {
                MarqueeLogger.general.error("Failed to preload \(cue.assetName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        if let curatedSubdirectory = AudioIdentityAssetCatalog.curatedSubdirectory(in: bundle) {
            for pack in AudioIdentitySoundPack.allCases {
                var packPlayers: [AudioIdentityCue: AudioIdentityPlaying] = [:]
                for cue in AudioIdentityCue.allCases {
                    guard let url = bundle.url(
                        forResource: cue.assetName(for: pack),
                        withExtension: cue.assetExtension(for: pack),
                        subdirectory: curatedSubdirectory
                    ) else {
                        MarqueeLogger.general.error("Missing curated audio asset: \(pack.rawValue, privacy: .public)/\(cue.assetName(for: pack), privacy: .public)")
                        continue
                    }
                    do {
                        let player = try AVAudioPlayer(contentsOf: url)
                        player.volume = cue.fixedGain(for: pack)
                        player.prepareToPlay()
                        packPlayers[cue] = player
                    } catch {
                        MarqueeLogger.general.error("Failed to preload curated \(pack.rawValue, privacy: .public)/\(cue.assetName(for: pack), privacy: .public): \(error.localizedDescription, privacy: .public)")
                    }
                }
                curatedPlayers[pack] = packPlayers
            }
        }
    }

    #if DEBUG
    init(
        preloadedPlayers: [AudioIdentityCue: AudioIdentityPlaying],
        preloadedPackPlayers: [AudioIdentitySoundPack: [AudioIdentityCue: AudioIdentityPlaying]] = [:],
        launchArguments: [String],
        settingsProvider: @escaping () -> AudioIdentitySettingsSnapshot,
        uptimeProvider: @escaping () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        }
    ) {
        legacyPlayers = preloadedPlayers
        curatedPlayers = preloadedPackPlayers
        self.launchArguments = launchArguments
        self.settingsProvider = settingsProvider
        self.uptimeProvider = uptimeProvider
    }
    #endif

    func configurePlayerPresentation(_ provider: @escaping () -> Bool) {
        requireMainThread()
        isPlayerPresented = provider
    }

    func playerPresentationDidChange(_ isPresented: Bool) {
        requireMainThread()
        guard isPresented else { return }
        let allPlayers = Array(legacyPlayers.values)
            + curatedPlayers.values.flatMap { $0.values }
        for player in allPlayers where player.isPlaying {
            player.stop()
        }
    }

    func playLaunchIdentIfNeeded() {
        guard !AudioIdentitySuppressionPolicy.isAutomationLaunch(launchArguments) else { return }
        requireMainThread()
        guard launchOnce.consumeAttempt() else { return }
        play(.launchIdent)
    }

    func playFeedback(
        for command: RemoteCommand,
        didNavigate: Bool = false,
        focusEvents: [FocusEngineEvent] = [],
        didReachBoundary: Bool = false
    ) {
        guard let cue = AudioIdentityFeedbackPolicy.cue(
            for: command,
            didNavigate: didNavigate,
            focusEvents: focusEvents,
            didReachBoundary: didReachBoundary
        ) else { return }
        play(cue)
    }

    func play(_ cue: AudioIdentityCue) {
        guard !AudioIdentitySuppressionPolicy.isAutomationLaunch(launchArguments) else { return }
        requireMainThread()
        let settings = settingsProvider()
        let context = AudioIdentitySuppressionContext(
            isPlayerPresented: isPlayerPresented(),
            launchArguments: launchArguments,
            interfaceSoundsEnabled: settings.interfaceSoundsEnabled,
            launchIdentEnabled: settings.launchIdentEnabled
        )
        guard AudioIdentitySuppressionPolicy.allows(cue, in: context) else { return }
        if cue != .launchIdent {
            guard throttle.shouldPlay(at: uptimeProvider()) else { return }
        }
        let player = settings.soundPack.flatMap { curatedPlayers[$0]?[cue] }
            ?? legacyPlayers[cue]
        guard let player else { return }
        player.currentTime = 0
        player.play()
    }

    private func requireMainThread() {
        precondition(Thread.isMainThread, "Audio identity playback must stay on the main thread")
    }
}

extension FocusDirection {
    var remoteCommand: RemoteCommand {
        switch self {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        }
    }
}
