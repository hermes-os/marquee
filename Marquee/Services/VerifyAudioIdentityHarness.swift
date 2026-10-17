import AVFoundation
import Foundation

#if DEBUG
enum VerifyAudioIdentityHarness {
    static let launchArgument = "--verify-audio-identity"
    private static let checkCount = 9

    static func runIfRequested() {
        guard CommandLine.arguments.contains(launchArgument) else { return }

        do {
            let detail = try runScenario()
            FileHandle.standardError.write(Data("verify-audio-identity: PASS \(detail)\n".utf8))
            FileHandle.standardError.write(Data("verify-audio-identity: outcome=verified passed=\(checkCount)/\(checkCount)\n".utf8))
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("verify-audio-identity: FAIL \(error)\n".utf8))
            FileHandle.standardError.write(Data("verify-audio-identity: outcome=failed passed=0/\(checkCount)\n".utf8))
            exit(1)
        }
    }

    private static func runScenario() throws -> String {
        try verifySuppressionMatrix()
        try verifyServicePolicyWiring()
        try verifyPlayerPresentationLifecycle()
        try verifyThrottlePolicy()
        try verifyLaunchOncePolicy()
        try verifyFeedbackMapping()
        try verifySettingsPersistence()
        try verifyAssetsAndPreloading()
        try verifySoundPackContracts()
        return "suppression matrix, service wiring, player lifecycle, throttle, launch-once, FocusEngine boundary, persistence, preloading, and sound-pack contracts verified"
    }

    private static func verifySoundPackContracts() throws {
        try assert(
            AudioIdentityPickerPolicy.options.map(\.displayName) == ["Velvet", "Hearth", "Nocturne"],
            "sound pack picker must expose exactly Velvet, Hearth, and Nocturne"
        )
        try assert(AudioIdentityPickerPolicy.title == "Sound pack",
                   "native settings picker must expose the Sound pack label")
        try assert(!AudioIdentityPickerPolicy.accessibilityHint.isEmpty,
                   "native settings picker must expose an accessibility hint")
        guard let curatedSubdirectory = AudioIdentityAssetCatalog.curatedSubdirectory(in: .main) else {
            throw HarnessError.assertion("curated pack manifest did not resolve one bundle directory")
        }
        for pack in AudioIdentitySoundPack.allCases {
            try assert(
                AudioIdentityPackResolver.resolve(persistedRawValue: pack.rawValue) == pack,
                "persisted sound pack did not resolve: \(pack)"
            )
            let assetNames = AudioIdentityCue.allCases.map { $0.assetName(for: pack) }
            try assert(Set(assetNames).count == AudioIdentityCue.allCases.count,
                       "\(pack) does not resolve five distinct cue assets")
            try assert(assetNames.allSatisfy { $0.hasPrefix(pack.rawValue + "-") },
                       "\(pack) cue assets do not use the pack prefix: \(assetNames)")

            let interfaceGains = AudioIdentityCue.interfaceCues.map { $0.fixedGain(for: pack) }
            let boundaryGain = AudioIdentityCue.boundary.fixedGain(for: pack)
            try assert(interfaceGains.dropLast().allSatisfy { boundaryGain < $0 },
                       "\(pack) boundary gain must be lower than every other interface cue")

            var metricsByCue: [AudioIdentityCue: AudioMetrics] = [:]
            for cue in AudioIdentityCue.allCases {
                guard let url = Bundle.main.url(
                    forResource: cue.assetName(for: pack),
                    withExtension: cue.assetExtension(for: pack),
                    subdirectory: curatedSubdirectory
                ) else {
                    throw HarnessError.assertion("missing bundled curated asset \(pack.rawValue)/\(cue.assetName(for: pack))")
                }
                let metrics = try audioMetrics(at: url)
                metricsByCue[cue] = metrics
                try assert(metrics.sampleRate == 44_100, "\(pack)/\(cue) must be 44.1 kHz")
                try assert(metrics.channelCount == 1, "\(pack)/\(cue) must be mono")
                try assert(metrics.bitDepth == 16 && !metrics.isFloat,
                           "\(pack)/\(cue) must be signed 16-bit PCM")
                if cue == .launchIdent {
                    try assert((2.0...3.5).contains(metrics.duration),
                               "\(pack) launch duration out of range: \(metrics.duration)")
                } else {
                    try assert((0.020...0.080).contains(metrics.duration),
                               "\(pack)/\(cue) duration out of range: \(metrics.duration)")
                }
                try assert(metrics.peakDBFS <= -12,
                           "\(pack)/\(cue) raw peak exceeds -12 dBFS: \(metrics.peakDBFS)")
                try assert(metrics.rmsDBFS <= -24,
                           "\(pack)/\(cue) raw RMS exceeds -24 dBFS: \(metrics.rmsDBFS)")
                let effectivePeak = metrics.peakDBFS
                    + 20 * log10(Double(cue.fixedGain(for: pack)))
                try assert(effectivePeak <= -24,
                           "\(pack)/\(cue) effective peak exceeds -24 dBFS: \(effectivePeak)")
            }
            guard let boundary = metricsByCue[.boundary] else {
                throw HarnessError.assertion("\(pack) boundary metrics missing")
            }
            for cue in [AudioIdentityCue.focus, .select, .back] {
                guard let comparison = metricsByCue[cue] else {
                    throw HarnessError.assertion("\(pack)/\(cue) metrics missing")
                }
                try assert(boundary.peakDBFS <= comparison.peakDBFS - 3,
                           "\(pack) boundary peak is not 3 dB below \(cue)")
                try assert(boundary.rmsDBFS <= comparison.rmsDBFS - 3,
                           "\(pack) boundary RMS is not 3 dB below \(cue)")
            }
        }

        let preserved = UserSettingsData(
            moviesPaths: ["/tmp/movies"],
            tvShowsPaths: ["/tmp/tv"],
            defaultSubtitleLanguage: "Spanish",
            defaultAudioLanguage: "French",
            subtitleScale: 1.5,
            hardwareDecodingEnabled: false,
            autoPlayNextEpisode: false,
            onlineMetadataEnabled: false,
            interfaceSoundsEnabled: false,
            launchIdentEnabled: false,
            soundPack: "future-pack"
        )
        let decoded = try JSONDecoder().decode(
            UserSettingsData.self,
            from: JSONEncoder().encode(preserved)
        )
        try assert(decoded.soundPack == "future-pack",
                   "unknown pack value was discarded during settings decode")
        try assert(decoded.moviesPaths == ["/tmp/movies"],
                   "unknown pack decode discarded unrelated settings")
        try assert(AudioIdentityPackResolver.resolve(persistedRawValue: decoded.soundPack) == nil,
                   "unknown pre-approval pack should remain unresolved until a shipping default is approved")

        var selectedPack: AudioIdentitySoundPack? = .velvet
        var uptime = 20.0
        let legacyPlayer = RecordingAudioIdentityPlayer()
        let velvetPlayer = RecordingAudioIdentityPlayer()
        let hearthPlayer = RecordingAudioIdentityPlayer()
        let service = AudioIdentityService(
            preloadedPlayers: [.select: legacyPlayer],
            preloadedPackPlayers: [
                .velvet: [.select: velvetPlayer],
                .hearth: [.select: hearthPlayer],
            ],
            launchArguments: ["Marquee"],
            settingsProvider: {
                AudioIdentitySettingsSnapshot(
                    interfaceSoundsEnabled: true,
                    launchIdentEnabled: true,
                    soundPack: selectedPack
                )
            },
            uptimeProvider: { uptime }
        )
        service.play(.select)
        try assert(velvetPlayer.playCount == 1 && hearthPlayer.playCount == 0,
                   "persisted Velvet selection did not resolve at play time")
        selectedPack = .hearth
        uptime += 0.05
        service.play(.select)
        try assert(velvetPlayer.playCount == 1 && hearthPlayer.playCount == 1,
                   "live pack switch did not resolve without recreating the service")
        selectedPack = nil
        uptime += 0.05
        service.play(.select)
        try assert(legacyPlayer.playCount == 1,
                   "missing pre-approval pack did not retain the legacy fallback")
    }

    private struct AudioMetrics {
        let sampleRate: Double
        let channelCount: Int
        let bitDepth: Int
        let isFloat: Bool
        let duration: TimeInterval
        let peakDBFS: Double
        let rmsDBFS: Double
    }

    private static func audioMetrics(at url: URL) throws -> AudioMetrics {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frameCapacity = AVAudioFrameCount(file.length)
        guard frameCapacity > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else {
            throw HarnessError.assertion("could not allocate audio metrics buffer for \(url.lastPathComponent)")
        }
        try file.read(into: buffer)
        guard let channelData = buffer.floatChannelData else {
            throw HarnessError.assertion("audio metrics require float processing data for \(url.lastPathComponent)")
        }

        var peak: Double = 0
        var sumSquares: Double = 0
        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(format.channelCount)
        for channel in 0..<channelCount {
            let samples = channelData[channel]
            for frame in 0..<frameLength {
                let sample = Double(samples[frame])
                peak = max(peak, abs(sample))
                sumSquares += sample * sample
            }
        }
        let sampleCount = max(1, frameLength * channelCount)
        let rms = sqrt(sumSquares / Double(sampleCount))
        let settings = file.fileFormat.settings
        let bitDepth = (settings[AVLinearPCMBitDepthKey] as? NSNumber)?.intValue ?? 0
        let isFloat = (settings[AVLinearPCMIsFloatKey] as? NSNumber)?.boolValue ?? false
        return AudioMetrics(
            sampleRate: file.fileFormat.sampleRate,
            channelCount: Int(file.fileFormat.channelCount),
            bitDepth: bitDepth,
            isFloat: isFloat,
            duration: Double(file.length) / file.fileFormat.sampleRate,
            peakDBFS: peak > 0 ? 20 * log10(peak) : -.infinity,
            rmsDBFS: rms > 0 ? 20 * log10(rms) : -.infinity
        )
    }

    private static func verifySuppressionMatrix() throws {
        let normal = AudioIdentitySuppressionContext(
            isPlayerPresented: false,
            launchArguments: ["Marquee"],
            interfaceSoundsEnabled: true,
            launchIdentEnabled: true
        )
        for cue in AudioIdentityCue.allCases {
            try assert(AudioIdentitySuppressionPolicy.allows(cue, in: normal), "normal launch should allow \(cue)")
        }

        let player = AudioIdentitySuppressionContext(
            isPlayerPresented: true,
            launchArguments: ["Marquee"],
            interfaceSoundsEnabled: true,
            launchIdentEnabled: true
        )
        for cue in AudioIdentityCue.allCases {
            try assert(!AudioIdentitySuppressionPolicy.allows(cue, in: player), "player should suppress \(cue)")
        }

        let automationArguments = [
            "--verify-audio-identity",
            "--verify-remote-input",
            "--verify-future-contract",
            "--qa-visual-tour",
            "--qa-output-dir",
            "--qa-future-tour",
        ]
        for argument in automationArguments {
            let context = AudioIdentitySuppressionContext(
                isPlayerPresented: false,
                launchArguments: ["Marquee", argument],
                interfaceSoundsEnabled: true,
                launchIdentEnabled: true
            )
            for cue in AudioIdentityCue.allCases {
                try assert(!AudioIdentitySuppressionPolicy.allows(cue, in: context), "\(argument) should suppress \(cue)")
            }
        }

        let interfaceDisabled = AudioIdentitySuppressionContext(
            isPlayerPresented: false,
            launchArguments: ["Marquee"],
            interfaceSoundsEnabled: false,
            launchIdentEnabled: true
        )
        try assert(AudioIdentitySuppressionPolicy.allows(.launchIdent, in: interfaceDisabled), "interface toggle should not disable launch ident")
        for cue in AudioIdentityCue.interfaceCues {
            try assert(!AudioIdentitySuppressionPolicy.allows(cue, in: interfaceDisabled), "interface toggle should suppress \(cue)")
        }

        let launchDisabled = AudioIdentitySuppressionContext(
            isPlayerPresented: false,
            launchArguments: ["Marquee"],
            interfaceSoundsEnabled: true,
            launchIdentEnabled: false
        )
        try assert(!AudioIdentitySuppressionPolicy.allows(.launchIdent, in: launchDisabled), "launch toggle should suppress ident")
        for cue in AudioIdentityCue.interfaceCues {
            try assert(AudioIdentitySuppressionPolicy.allows(cue, in: launchDisabled), "launch toggle should not suppress \(cue)")
        }
    }

    private static func verifyPlayerPresentationLifecycle() throws {
        let launchPlayer = RecordingAudioIdentityPlayer()
        let selectPlayer = RecordingAudioIdentityPlayer()
        let service = AudioIdentityService(
            preloadedPlayers: [
                .launchIdent: launchPlayer,
                .select: selectPlayer,
            ],
            launchArguments: ["Marquee"],
            settingsProvider: {
                AudioIdentitySettingsSnapshot(
                    interfaceSoundsEnabled: true,
                    launchIdentEnabled: true
                )
            }
        )

        service.play(.launchIdent)
        service.play(.select)
        try assert(launchPlayer.isPlaying, "launch ident should start before player presentation")
        try assert(selectPlayer.isPlaying, "select cue should start before player presentation")

        service.playerPresentationDidChange(true)
        try assert(!launchPlayer.isPlaying, "player presentation should stop an active launch ident")
        try assert(!selectPlayer.isPlaying, "player presentation should stop an active interface cue")
        try assert(launchPlayer.stopCount == 1, "launch ident should be stopped exactly once")
        try assert(selectPlayer.stopCount == 1, "interface cue should be stopped exactly once")
    }

    private static func verifyServicePolicyWiring() throws {
        let enabledSettings = {
            AudioIdentitySettingsSnapshot(
                interfaceSoundsEnabled: true,
                launchIdentEnabled: true
            )
        }

        let automationPlayer = RecordingAudioIdentityPlayer()
        let automationService = AudioIdentityService(
            preloadedPlayers: [.select: automationPlayer],
            launchArguments: ["Marquee", "--qa-future-tour"],
            settingsProvider: enabledSettings
        )
        automationService.play(.select)
        try assert(automationPlayer.playCount == 0, "automation launch should stop before the player is invoked")

        let presentedPlayer = RecordingAudioIdentityPlayer()
        let presentedService = AudioIdentityService(
            preloadedPlayers: [.select: presentedPlayer],
            launchArguments: ["Marquee"],
            settingsProvider: enabledSettings
        )
        presentedService.configurePlayerPresentation { true }
        presentedService.play(.select)
        try assert(presentedPlayer.playCount == 0, "presented player should stop before the cue player is invoked")

        let disabledInterfacePlayer = RecordingAudioIdentityPlayer()
        let disabledLaunchPlayer = RecordingAudioIdentityPlayer()
        let disabledService = AudioIdentityService(
            preloadedPlayers: [
                .select: disabledInterfacePlayer,
                .launchIdent: disabledLaunchPlayer,
            ],
            launchArguments: ["Marquee"],
            settingsProvider: {
                AudioIdentitySettingsSnapshot(
                    interfaceSoundsEnabled: false,
                    launchIdentEnabled: false
                )
            }
        )
        disabledService.play(.select)
        disabledService.play(.launchIdent)
        try assert(disabledInterfacePlayer.playCount == 0, "interface toggle should stop before the cue player is invoked")
        try assert(disabledLaunchPlayer.playCount == 0, "launch toggle should stop before the ident player is invoked")

        var uptime = 10.0
        let firstThrottlePlayer = RecordingAudioIdentityPlayer()
        let secondThrottlePlayer = RecordingAudioIdentityPlayer()
        let throttleService = AudioIdentityService(
            preloadedPlayers: [
                .select: firstThrottlePlayer,
                .focus: secondThrottlePlayer,
            ],
            launchArguments: ["Marquee"],
            settingsProvider: enabledSettings,
            uptimeProvider: { uptime }
        )
        throttleService.play(.select)
        throttleService.play(.focus)
        try assert(firstThrottlePlayer.playCount == 1, "first service-level interface cue should play")
        try assert(secondThrottlePlayer.playCount == 0, "service should suppress an interface cue inside 50ms")
        uptime = 10.05
        throttleService.play(.focus)
        try assert(secondThrottlePlayer.playCount == 1, "service should allow an interface cue at 50ms")
    }

    private static func verifyThrottlePolicy() throws {
        var throttle = AudioIdentityThrottle()
        try assert(throttle.minimumInterval == 0.05, "throttle interval should be exactly 50ms")
        try assert(throttle.shouldPlay(at: 10.0), "first interface cue should play")
        try assert(!throttle.shouldPlay(at: 10.049), "49ms repeat should be suppressed")
        try assert(throttle.shouldPlay(at: 10.05), "50ms repeat should play")
    }

    private static func verifyLaunchOncePolicy() throws {
        var policy = LaunchIdentOncePolicy()
        try assert(policy.consumeAttempt(), "first cold-launch ident attempt should be accepted")
        try assert(!policy.consumeAttempt(), "second cold-launch ident attempt should be rejected")
    }

    private static func verifyFeedbackMapping() throws {
        try assert(
            AudioIdentityFeedbackPolicy.cue(for: .select, didNavigate: false) == .select,
            "select should map to its distinct cue"
        )
        try assert(
            AudioIdentityFeedbackPolicy.cue(for: .back, didNavigate: false) == .back,
            "back should map to its distinct cue"
        )
        try assert(
            AudioIdentityFeedbackPolicy.cue(for: .right, didNavigate: true) == .focus,
            "successful traversal should map to focus tick"
        )
        try assert(
            AudioIdentityFeedbackPolicy.cue(
                for: .left,
                didNavigate: false,
                focusEvents: [.boundaryHit("edge", .left)]
            ) == .boundary,
            "FocusEngine boundaryHit should map to the distinct boundary cue"
        )
    }

    private static func verifySettingsPersistence() throws {
        try assert(UserSettingsData.defaults.interfaceSoundsEnabled == true, "interface sounds should default on")
        try assert(UserSettingsData.defaults.launchIdentEnabled == true, "launch ident should default on")

        let fixture = UserSettingsData(
            moviesPaths: ["/tmp/movies"],
            tvShowsPaths: ["/tmp/tv"],
            defaultSubtitleLanguage: "None",
            defaultAudioLanguage: "English",
            subtitleScale: 1.35,
            hardwareDecodingEnabled: true,
            autoPlayNextEpisode: true,
            onlineMetadataEnabled: false,
            interfaceSoundsEnabled: false,
            launchIdentEnabled: false
        )
        let encoded = try JSONEncoder().encode(fixture)
        let decoded = try JSONDecoder().decode(UserSettingsData.self, from: encoded)
        try assert(decoded.interfaceSoundsEnabled == false, "interface sound choice should survive relaunch decoding")
        try assert(decoded.launchIdentEnabled == false, "launch ident choice should survive relaunch decoding")
    }

    private static func verifyAssetsAndPreloading() throws {
        for cue in AudioIdentityCue.allCases {
            guard let url = Bundle.main.url(
                forResource: cue.assetName,
                withExtension: cue.assetExtension,
                subdirectory: "Sounds"
            ) else {
                throw HarnessError.assertion("missing bundled asset for \(cue)")
            }
            let player = try AVAudioPlayer(contentsOf: url)
            if cue == .launchIdent {
                try assert((2.0...3.5).contains(player.duration), "launch ident should be 2-3.5s, got \(player.duration)")
            } else {
                try assert(player.duration > 0 && player.duration < 0.08, "\(cue) should be under 80ms, got \(player.duration)")
            }
            try assert(cue.fixedGain > 0 && cue.fixedGain <= 0.35, "\(cue) gain should stay modest, got \(cue.fixedGain)")
        }

        try assert(
            AudioIdentityService.shared.preloadedCueCount
                == AudioIdentityCue.allCases.count * (AudioIdentitySoundPack.allCases.count + 1),
            "service should preload five legacy cues plus every curated pack cue"
        )
    }

    private static func assert(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw HarnessError.assertion(message) }
    }

    private enum HarnessError: Error, CustomStringConvertible {
        case assertion(String)

        var description: String {
            switch self {
            case .assertion(let message):
                return message
            }
        }
    }

    private final class RecordingAudioIdentityPlayer: AudioIdentityPlaying {
        var currentTime: TimeInterval = 0
        private(set) var isPlaying = false
        private(set) var playCount = 0
        private(set) var stopCount = 0

        @discardableResult
        func play() -> Bool {
            isPlaying = true
            playCount += 1
            return true
        }

        func stop() {
            isPlaying = false
            stopCount += 1
        }
    }
}
#endif
