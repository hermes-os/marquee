//
//  VerifyPlaybackHarness.swift
//  Marquee
//
//  DEBUG-only verification for the playback lifecycle state machine.
//  Activated by `--verify-playback-state`.
//

#if DEBUG

import AppKit
import AVFoundation
import Darwin
import Foundation

enum VerifyPlaybackHarness {
    static let launchArgument = "--verify-playback-state"
    static let playbackCacheLaunchArgument = "--verify-playback-cache"
    static let runtimeLaunchArgument = "--verify-player-runtime"
    static let runtimeLoadOnlyArgument = "--verify-player-runtime-load-only"
    static let runtimePlayToEndArgument = "--verify-player-runtime-play-to-end"
    static let runtimeExpectFailureArgument = "--verify-player-runtime-expect-failure"
    static let runtimeExpectedBackendArgument = "--verify-player-runtime-expect-backend"
    static let runtimeCancelPreparationArgument = "--verify-player-runtime-cancel-preparation"
    static let runtimeRequireVideoFrameArgument = "--verify-player-runtime-require-video-frame"
    static let runtimeRequireAVDirectSurfaceArgument = "--verify-player-runtime-require-av-direct-surface"
    static let runtimeExpectEmbeddedCleanupArgument = "--verify-player-runtime-expect-embedded-helper-cleanup"
    static let runtimeRequireAudioHelperArgument = "--verify-player-runtime-require-audio-helper"
    static let runtimeRequireSidecarSubtitleArgument = "--verify-player-runtime-require-sidecar-subtitle"
    static let runtimeSecondPathArgument = "--verify-player-runtime-second-path"
    static let runtimeRequireSurfaceClearAfterFailedReloadArgument = "--verify-player-runtime-require-surface-clear-after-failed-reload"
    static let runtimeRequireRapidSeekStopClearArgument = "--verify-player-runtime-require-rapid-seek-stop-clear"
    static let runtimeRequireRapidReloadStopProbeCleanupArgument = "--verify-player-runtime-require-rapid-reload-stop-probe-cleanup"
    static let runtimeRequireStereoDownmixArgument = "--verify-player-runtime-require-stereo-downmix"
    static let runtimeSelfSigkillAfterLoadArgument = "--verify-player-runtime-self-sigkill-after-load"
    static let runtimeExerciseEmbeddedAudioControlsArgument = "--verify-player-runtime-exercise-embedded-audio-controls"
    static let runtimeExerciseInteractiveScrubArgument = "--verify-player-runtime-exercise-interactive-scrub"

    static func runIfRequested() {
        if CommandLine.arguments.contains(playbackCacheLaunchArgument) {
            runPlaybackCacheVerification()
        }

        if let runtimePath = runtimePlaybackPath() {
            runRuntimePlayback(path: runtimePath)
        }

        guard CommandLine.arguments.contains(launchArgument) else { return }

        let results = [
            scenarioHappyPath(),
            scenarioIllegalDirectFileLoaded(),
            scenarioSeekReturnsToPaused(),
            scenarioResumeSeekWhileLoading(),
            scenarioStopFromLoading(),
            scenarioReplaceWhilePlaying(),
            scenarioSubtitleToggleSelectsFirstSidecar(),
            scenarioStaleSidecarParseCannotReenable(),
            scenarioPlaybackSessionRejectsMissingFile(),
            scenarioPlaybackSessionRejectsMissingItem(),
            scenarioPostPlayHandoffEndedVsDismissed(),
            scenarioPostPlayHandoffClearsOnProfileBoundary(),
            scenarioPostPlayHandoffDismissalIsIdentityScoped(),
            scenarioRawFilePlaybackClearsItemCompletionIdentity(),
            scenarioPlaybackSessionIdleControlsAreSafe(),
            scenarioNextEpisodePlaybackSelection()
        ]

        for result in results {
            let status = result.passed ? "PASS" : "FAIL"
            FileHandle.standardError.write(Data("verify-playback-state: \(status) \(result.name): \(result.detail)\n".utf8))
        }

        let passed = results.filter(\.passed).count
        if passed == results.count {
            FileHandle.standardError.write(Data("verify-playback-state: outcome=verified passed=\(passed)/\(results.count)\n".utf8))
            exit(0)
        } else {
            FileHandle.standardError.write(Data("verify-playback-state: outcome=failed passed=\(passed)/\(results.count)\n".utf8))
            exit(1)
        }
    }

    private static func runPlaybackCacheVerification() {
        let results = [
            scenarioPlaybackCacheUsesMediaRoot(),
            scenarioPlaybackCacheUsesSidecarRootOverride(),
            scenarioPlaybackCacheRejectsLiveSidecarChildOverride(),
            scenarioPlaybackCacheRejectsLiveCacheOverride(),
            scenarioPlaybackCacheHarnessAvoidsLiveSidecar(),
            scenarioPlaybackCacheSetsProcessTempEnvironment(),
            scenarioPlaybackCacheCleansAbandonedPartials(),
            scenarioPlaybackCacheRejectsLowSpace()
        ]

        for result in results {
            let status = result.passed ? "PASS" : "FAIL"
            emit("verify-playback-cache: \(status) \(result.name): \(result.detail)")
        }

        let passed = results.filter(\.passed).count
        if passed == results.count {
            emit("verify-playback-cache: outcome=verified passed=\(passed)/\(results.count)")
            exit(0)
        } else {
            emit("verify-playback-cache: outcome=failed passed=\(passed)/\(results.count)")
            exit(1)
        }
    }

    private static func scenarioPlaybackCacheUsesMediaRoot() -> ScenarioResult {
        let source = "/Volumes/Media/Tape-Machine/MOVIES/Action/Example (2024)/Example.mkv"
        let expected = "/Volumes/Media/Tape-Machine/.marquee/playback-cache"
        let actual = PlaybackCache.directory(forSourcePath: source, environment: [:]).path
        guard actual == expected else {
            return fail("playbackCacheUsesMediaRoot", "actual=\(actual) expected=\(expected)")
        }
        return pass("playbackCacheUsesMediaRoot", actual)
    }

    private static func scenarioPlaybackCacheUsesSidecarRootOverride() -> ScenarioResult {
        #if DEBUG
        let source = "/Volumes/Media/Tape-Machine/MOVIES/Action/Example (2024)/Example.mkv"
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("marquee-playback-cache-sidecar-root-\(UUID().uuidString)", isDirectory: true)
        let expected = root
            .appendingPathComponent("playback-cache", isDirectory: true)
            .standardizedFileURL.path
        let env = [Configuration.sidecarRootOverrideEnvironmentKey: root.path]
        let actual = PlaybackCache.directory(forSourcePath: source, environment: env)
            .standardizedFileURL.path
        let processEnv = PlaybackCache.processEnvironment(base: env, forSourcePath: source)
        guard actual == expected,
              processEnv["TMPDIR"] == expected,
              processEnv["TMP"] == expected,
              processEnv["TEMP"] == expected else {
            return fail("playbackCacheUsesSidecarRootOverride", "actual=\(actual) expected=\(expected) env=\(processEnv)")
        }
        return pass("playbackCacheUsesSidecarRootOverride", expected)
        #else
        return pass("playbackCacheUsesSidecarRootOverride", "debug-only")
        #endif
    }

    private static func scenarioPlaybackCacheRejectsLiveSidecarChildOverride() -> ScenarioResult {
        #if DEBUG
        let source = "/Volumes/Media/Tape-Machine/TV/Example/Season 1/Example S01E01.webm"
        let liveChild = Configuration.liveMediaSidecarDirectory
            .appendingPathComponent("verify-reports", isDirectory: true)
        let env = [Configuration.sidecarRootOverrideEnvironmentKey: liveChild.path]
        let actual = PlaybackCache.directory(forSourcePath: source, environment: env)
            .standardizedFileURL.path
        let live = Configuration.liveMediaSidecarDirectory
            .appendingPathComponent("playback-cache", isDirectory: true)
            .standardizedFileURL.path
        let liveRoot = Configuration.liveMediaSidecarDirectory.standardizedFileURL.path
        guard actual != live, !actual.hasPrefix(liveRoot + "/") else {
            return fail("playbackCacheRejectsLiveSidecarChildOverride", "actual=\(actual) liveRoot=\(liveRoot)")
        }
        return pass("playbackCacheRejectsLiveSidecarChildOverride", actual)
        #else
        return pass("playbackCacheRejectsLiveSidecarChildOverride", "debug-only")
        #endif
    }

    private static func scenarioPlaybackCacheRejectsLiveCacheOverride() -> ScenarioResult {
        #if DEBUG
        let source = "/Volumes/Media/Tape-Machine/TV/Example/Season 1/Example S01E01.webm"
        let liveRoot = Configuration.liveMediaSidecarDirectory.standardizedFileURL.path
        let liveCache = Configuration.liveMediaSidecarDirectory
            .appendingPathComponent("playback-cache", isDirectory: true)
        let env = [PlaybackCache.playbackCacheEnvironmentKey: liveCache.path]
        let actual = PlaybackCache.directory(forSourcePath: source, environment: env)
            .standardizedFileURL.path
        guard actual != liveCache.standardizedFileURL.path,
              !actual.hasPrefix(liveRoot + "/") else {
            return fail("playbackCacheRejectsLiveCacheOverride", "actual=\(actual) liveRoot=\(liveRoot)")
        }

        let processEnv = PlaybackCache.processEnvironment(base: env, forSourcePath: source)
        guard processEnv["TMPDIR"] == actual,
              processEnv["TMP"] == actual,
              processEnv["TEMP"] == actual,
              processEnv[PlaybackCache.playbackCacheEnvironmentKey] == actual else {
            return fail("playbackCacheRejectsLiveCacheOverride", "actual=\(actual) env=\(processEnv)")
        }

        return pass("playbackCacheRejectsLiveCacheOverride", actual)
        #else
        return pass("playbackCacheRejectsLiveCacheOverride", "debug-only")
        #endif
    }

    private static func scenarioPlaybackCacheHarnessAvoidsLiveSidecar() -> ScenarioResult {
        #if DEBUG
        let source = "/Volumes/Media/Tape-Machine/TV/Example/Season 1/Example S01E01.webm"
        let actual = PlaybackCache.directory(forSourcePath: source)
            .standardizedFileURL.path
        let live = Configuration.liveMediaSidecarDirectory
            .appendingPathComponent("playback-cache", isDirectory: true)
            .standardizedFileURL.path
        guard actual != live else {
            return fail("playbackCacheHarnessAvoidsLiveSidecar", "actual=\(actual)")
        }
        guard !Configuration.debugSidecarURLIsLiveOrChild(URL(fileURLWithPath: actual, isDirectory: true)) else {
            return fail("playbackCacheHarnessAvoidsLiveSidecar", "actual=\(actual)")
        }

        if let sidecarRoot = ProcessInfo.processInfo.environment[Configuration.sidecarRootOverrideEnvironmentKey],
           !sidecarRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let expected = (Configuration.debugResolvedSidecarRootOverrideDirectory() ?? URL(fileURLWithPath: sidecarRoot, isDirectory: true))
                .appendingPathComponent("playback-cache", isDirectory: true)
                .standardizedFileURL.path
            guard actual == expected else {
                return fail("playbackCacheHarnessAvoidsLiveSidecar", "actual=\(actual) expected=\(expected)")
            }
        }

        let processEnv = PlaybackCache.processEnvironment(forSourcePath: source)
        guard processEnv["TMPDIR"] == actual,
              processEnv["TMP"] == actual,
              processEnv["TEMP"] == actual else {
            return fail("playbackCacheHarnessAvoidsLiveSidecar", "actual=\(actual) env=\(processEnv)")
        }

        return pass("playbackCacheHarnessAvoidsLiveSidecar", actual)
        #else
        return pass("playbackCacheHarnessAvoidsLiveSidecar", "debug-only")
        #endif
    }

    private static func scenarioPlaybackCacheSetsProcessTempEnvironment() -> ScenarioResult {
        let source = "/Volumes/Media/Tape-Machine/TV/Example/Season 1/Example S01E01.webm"
        let env = PlaybackCache.processEnvironment(base: ["EXISTING": "1"], forSourcePath: source)
        let expected = "/Volumes/Media/Tape-Machine/.marquee/playback-cache"
        guard env["TMPDIR"] == expected,
              env["TMP"] == expected,
              env["TEMP"] == expected,
              env["EXISTING"] == "1" else {
            return fail("playbackCacheSetsProcessTempEnvironment", "env=\(env)")
        }
        return pass("playbackCacheSetsProcessTempEnvironment", expected)
    }

    private static func scenarioPlaybackCacheCleansAbandonedPartials() -> ScenarioResult {
        do {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("marquee-playback-cache-harness-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let partial = root.appendingPathComponent("dead.partial.mp4")
            let temp = root.appendingPathComponent("dead.tmp")
            let complete = root.appendingPathComponent("keep.mp4")
            try Data([0]).write(to: partial)
            try Data([1]).write(to: temp)
            try Data([2]).write(to: complete)

            PlaybackCache.cleanUpAbandonedFiles(in: root)

            let partialExists = FileManager.default.fileExists(atPath: partial.path)
            let tempExists = FileManager.default.fileExists(atPath: temp.path)
            let completeExists = FileManager.default.fileExists(atPath: complete.path)
            guard !partialExists, !tempExists, completeExists else {
                return fail("playbackCacheCleansAbandonedPartials", "partial=\(partialExists) temp=\(tempExists) complete=\(completeExists)")
            }
            return pass("playbackCacheCleansAbandonedPartials", root.path)
        } catch {
            return fail("playbackCacheCleansAbandonedPartials", "\(error)")
        }
    }

    private static func scenarioPlaybackCacheRejectsLowSpace() -> ScenarioResult {
        do {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("marquee-playback-cache-space-harness-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            do {
                try PlaybackCache.requireFreeBytes(in: root, minimumBytes: UInt64.max)
                return fail("playbackCacheRejectsLowSpace", "requireFreeBytes accepted impossible budget")
            } catch PlaybackCacheError.insufficientSpace {
                return pass("playbackCacheRejectsLowSpace", root.path)
            } catch {
                return fail("playbackCacheRejectsLowSpace", "\(error)")
            }
        } catch {
            return fail("playbackCacheRejectsLowSpace", "\(error)")
        }
    }

    private static func scenarioHappyPath() -> ScenarioResult {
        do {
            var machine = PlaybackStateMachine()
            try machine.apply(.prepare)
            try machine.apply(.rendererReady)
            try machine.apply(.loadRequested)
            try machine.apply(.startFile)
            try machine.apply(.fileLoaded)
            try machine.apply(.pause)
            try machine.apply(.resume)
            try machine.apply(.ended)
            try machine.apply(.stop)
            return pass("happyPath", "idle -> stopped accepted through playback")
        } catch {
            return fail("happyPath", "\(error)")
        }
    }

    private static func scenarioIllegalDirectFileLoaded() -> ScenarioResult {
        var machine = PlaybackStateMachine()
        do {
            try machine.apply(.fileLoaded)
            return fail("illegalDirectFileLoaded", "fileLoaded from idle was accepted")
        } catch {
            return pass("illegalDirectFileLoaded", "fileLoaded from idle rejected")
        }
    }

    private static func scenarioSeekReturnsToPaused() -> ScenarioResult {
        do {
            var machine = PlaybackStateMachine()
            try machine.apply(.prepare)
            try machine.apply(.rendererReady)
            try machine.apply(.loadRequested)
            try machine.apply(.fileLoaded)
            try machine.apply(.pause)
            try machine.apply(.seekRequested)
            try machine.apply(.seekCompleted)
            guard machine.state == .paused else {
                return fail("seekReturnsToPaused", "state=\(machine.state)")
            }
            return pass("seekReturnsToPaused", "paused seek completed back to paused")
        } catch {
            return fail("seekReturnsToPaused", "\(error)")
        }
    }

    private static func scenarioStopFromLoading() -> ScenarioResult {
        do {
            var machine = PlaybackStateMachine()
            try machine.apply(.prepare)
            try machine.apply(.loadRequested)
            try machine.apply(.stop)
            guard machine.state == .stopped else {
                return fail("stopFromLoading", "state=\(machine.state)")
            }
            return pass("stopFromLoading", "loading can be stopped during teardown")
        } catch {
            return fail("stopFromLoading", "\(error)")
        }
    }

    private static func scenarioResumeSeekWhileLoading() -> ScenarioResult {
        do {
            var machine = PlaybackStateMachine()
            try machine.apply(.prepare)
            try machine.apply(.loadRequested)
            try machine.apply(.seekRequested)
            try machine.apply(.seekCompleted)
            guard machine.state == .loading else {
                return fail("resumeSeekWhileLoading", "state=\(machine.state)")
            }
            return pass("resumeSeekWhileLoading", "resume seek before file-loaded keeps loading state")
        } catch {
            return fail("resumeSeekWhileLoading", "\(error)")
        }
    }

    private static func scenarioReplaceWhilePlaying() -> ScenarioResult {
        do {
            var machine = PlaybackStateMachine()
            try machine.apply(.prepare)
            try machine.apply(.rendererReady)
            try machine.apply(.loadRequested)
            try machine.apply(.fileLoaded)
            try machine.apply(.rendererReady)
            try machine.apply(.loadRequested)
            guard machine.state == .loading else {
                return fail("replaceWhilePlaying", "state=\(machine.state)")
            }
            return pass("replaceWhilePlaying", "already-playing media can be replaced cleanly")
        } catch {
            return fail("replaceWhilePlaying", "\(error)")
        }
    }

    private static func scenarioSubtitleToggleSelectsFirstSidecar() -> ScenarioResult {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("marquee-subtitle-toggle-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let srt = root.appendingPathComponent("sample.en.srt")
            try """
            1
            00:00:01,000 --> 00:00:02,000
            First caption

            """.write(to: srt, atomically: true, encoding: .utf8)

            let track = SubtitleTrack(
                id: "external-srt-0",
                displayName: "English (SRT)",
                isExternal: true,
                externalPath: srt.path
            )

            let service = MPVPlayerService()
            defer { service.shutdown() }
            service.verifyInjectSubtitleTracksForHarness([track])
            service.toggleSubtitles()
            let enabled = spinRunLoop(timeout: 2) {
                service.subtitlesEnabled
                    && service.currentSubtitleTrack == track
                    && service.currentSubtitleEntries.count == 1
            }
            guard enabled else {
                return fail("subtitleToggleSelectsFirstSidecar", "enable failed track=\(String(describing: service.currentSubtitleTrack)) entries=\(service.currentSubtitleEntries.count) enabled=\(service.subtitlesEnabled)")
            }

            service.toggleSubtitles()
            let disabled = spinRunLoop(timeout: 1) {
                !service.subtitlesEnabled
                    && service.currentSubtitleTrack == nil
                    && service.currentSubtitleEntries.isEmpty
            }
            guard disabled else {
                return fail("subtitleToggleSelectsFirstSidecar", "disable failed track=\(String(describing: service.currentSubtitleTrack)) entries=\(service.currentSubtitleEntries.count) enabled=\(service.subtitlesEnabled)")
            }

            return pass("subtitleToggleSelectsFirstSidecar", "keyboard-style toggle selects first sidecar and disables cleanly")
        } catch {
            return fail("subtitleToggleSelectsFirstSidecar", "\(error)")
        }
    }

    private static func scenarioStaleSidecarParseCannotReenable() -> ScenarioResult {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("marquee-subtitle-stale-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let srt = root.appendingPathComponent("sample.en.srt")
            try """
            1
            00:00:01,000 --> 00:00:02,000
            First caption

            """.write(to: srt, atomically: true, encoding: .utf8)

            let track = SubtitleTrack(
                id: "external-srt-stale",
                displayName: "English (SRT)",
                isExternal: true,
                externalPath: srt.path
            )

            let service = MPVPlayerService()
            defer { service.shutdown() }
            service.verifySetSubtitleParseDelayForHarness(0.25)
            service.verifyInjectSubtitleTracksForHarness([track])
            service.selectSubtitleTrack(track)
            service.selectSubtitleTrack(nil)

            _ = spinRunLoop(timeout: 0.75) { false }
            guard !service.subtitlesEnabled,
                  service.currentSubtitleTrack == nil,
                  service.currentSubtitleEntries.isEmpty else {
                return fail("staleSidecarParseCannotReenable", "stale parse restored track=\(String(describing: service.currentSubtitleTrack)) entries=\(service.currentSubtitleEntries.count) enabled=\(service.subtitlesEnabled)")
            }

            return pass("staleSidecarParseCannotReenable", "disabled selection ignored stale external parse completion")
        } catch {
            return fail("staleSidecarParseCannotReenable", "\(error)")
        }
    }

    private static func scenarioPlaybackSessionRejectsMissingFile() -> ScenarioResult {
        let session = PlaybackSession()
        var reported: AppError?
        session.onError = { reported = $0 }
        session.playFile(at: "/nonexistent/marquee-playback-session-harness.mkv")
        guard case .fileNotFound = reported else {
            return fail("playbackSessionRejectsMissingFile", "error=\(String(describing: reported))")
        }
        guard !session.playerController.isPlayerPresented,
              session.playerController.playerService == nil else {
            return fail("playbackSessionRejectsMissingFile", "player state mutated for missing file")
        }
        return pass("playbackSessionRejectsMissingFile", "missing file routed to onError without presenting")
    }

    private static func scenarioPlaybackSessionRejectsMissingItem() -> ScenarioResult {
        let session = PlaybackSession()
        var reported: AppError?
        session.onError = { reported = $0 }
        let item = MediaItem(
            filePath: "/nonexistent/marquee-playback-session-harness-item.mkv",
            fileName: "marquee-playback-session-harness-item.mkv",
            title: "Harness Item",
            year: 2026,
            fileExtension: "mkv",
            fileSize: 1
        )
        session.playItem(item)
        guard case .fileNotFound = reported else {
            return fail("playbackSessionRejectsMissingItem", "error=\(String(describing: reported))")
        }
        guard !session.playerController.isPlayerPresented,
              session.playerController.playerService == nil else {
            return fail("playbackSessionRejectsMissingItem", "player state mutated for missing item")
        }
        return pass("playbackSessionRejectsMissingItem", "missing item routed to onError without presenting")
    }

    private static func scenarioPostPlayHandoffEndedVsDismissed() -> ScenarioResult {
        let source = playbackHarnessMovie(
            title: "Moon Archive",
            year: 2018,
            genres: ["Science Fiction"],
            director: "Nia Orbit",
            cast: [TMDBMetadata.CastEntry(name: "Lena Star", character: "Lead", profilePath: nil, tmdbPersonID: 401)]
        )
        let neighbor = playbackHarnessMovie(
            title: "Quiet Orbit",
            year: 2021,
            genres: ["Science Fiction"],
            director: "Nia Orbit",
            cast: [TMDBMetadata.CastEntry(name: "Lena Star", character: "Lead", profilePath: nil, tmdbPersonID: 401)]
        )
        let unrelated = playbackHarnessMovie(
            title: "Brief Sonata",
            year: 2020,
            genres: ["Music"],
            director: "Ada Tone",
            cast: []
        )
        let movies = [source, neighbor, unrelated]
        let similarity = BrowseSimilarityIndex.build(movies: movies, showSummaries: [])
        let ended = BrowseLeanBackDelightPolicy.postPlayHandoffCandidate(
            after: source,
            dismissal: .ended,
            movies: movies,
            similarity: similarity
        )
        let dismissed = BrowseLeanBackDelightPolicy.postPlayHandoffCandidate(
            after: source,
            dismissal: .dismissed,
            movies: movies,
            similarity: similarity
        )
        guard ended?.id == neighbor.id else {
            return fail("postPlayHandoffEndedVsDismissed", "ended candidate=\(String(describing: ended?.displayTitle))")
        }
        guard dismissed == nil else {
            return fail("postPlayHandoffEndedVsDismissed", "dismissed candidate=\(String(describing: dismissed?.displayTitle))")
        }
        return pass("postPlayHandoffEndedVsDismissed", "ended surfaces top neighbor; dismissed stays quiet")
    }

    private static func scenarioPostPlayHandoffClearsOnProfileBoundary() -> ScenarioResult {
        let appState = AppState(skipPersistenceForHarness: true)
        let source = playbackHarnessMovie(
            title: "Late Orbit",
            year: 2018,
            genres: ["Drama"],
            director: "Nia Orbit",
            cast: []
        )
        let adultOnlyCandidate = playbackHarnessMovie(
            title: "After Midnight Orbit",
            year: 2021,
            genres: ["Drama"],
            director: "Nia Orbit",
            cast: []
        )
        appState.postPlayHandoff = PostPlayHandoff(source: source, candidate: adultOnlyCandidate)

        appState.switchProfile()

        guard appState.postPlayHandoff == nil else {
            return fail("postPlayHandoffClearsOnProfileBoundary", "switch profile preserved stale handoff")
        }
        return pass("postPlayHandoffClearsOnProfileBoundary", "profile boundaries clear stale handoff state")
    }

    private static func scenarioPostPlayHandoffDismissalIsIdentityScoped() -> ScenarioResult {
        let appState = AppState(skipPersistenceForHarness: true)
        let source = playbackHarnessMovie(
            title: "Moon Archive",
            year: 2018,
            genres: ["Science Fiction"],
            director: "Nia Orbit",
            cast: []
        )
        let oldCandidate = playbackHarnessMovie(
            title: "Quiet Orbit",
            year: 2021,
            genres: ["Science Fiction"],
            director: "Nia Orbit",
            cast: []
        )
        let newerCandidate = playbackHarnessMovie(
            title: "Solar Harbor",
            year: 2022,
            genres: ["Science Fiction"],
            director: "Nia Orbit",
            cast: []
        )
        let oldHandoff = PostPlayHandoff(source: source, candidate: oldCandidate)
        let newerHandoff = PostPlayHandoff(source: source, candidate: newerCandidate)

        appState.postPlayHandoff = newerHandoff
        appState.dismissPostPlayHandoff(id: oldHandoff.id)

        guard appState.postPlayHandoff?.id == newerHandoff.id else {
            return fail("postPlayHandoffDismissalIsIdentityScoped", "old dismiss cleared newer handoff")
        }
        appState.dismissPostPlayHandoff(id: newerHandoff.id)
        guard appState.postPlayHandoff == nil else {
            return fail("postPlayHandoffDismissalIsIdentityScoped", "current dismiss did not clear handoff")
        }
        return pass("postPlayHandoffDismissalIsIdentityScoped", "stale dismiss requests cannot clear newer handoffs")
    }

    private static func scenarioRawFilePlaybackClearsItemCompletionIdentity() -> ScenarioResult {
        do {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("marquee-raw-playback-identity-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let itemURL = root.appendingPathComponent("library-item.mp4")
            let rawURL = root.appendingPathComponent("raw-drop.mp4")
            try Data([0]).write(to: itemURL)
            try Data([1]).write(to: rawURL)

            var completedItems: [MediaItem] = []
            let controller = PlayerController()
            controller.configure(
                watchStore: nil,
                onItemProgressUpdated: { _ in },
                onPlaybackCompleted: { completedItems.append($0) }
            )
            let item = MediaItem(
                filePath: itemURL.path,
                fileName: itemURL.lastPathComponent,
                title: "Library Identity",
                year: 2026,
                fileExtension: itemURL.pathExtension,
                fileSize: 1
            )

            controller.playItem(item)
            controller.playFile(at: rawURL.path)
            controller.playerService?.onPlaybackEnded?()

            guard completedItems.isEmpty else {
                return fail("rawFilePlaybackClearsItemCompletionIdentity", "raw playback completed stale item \(completedItems.map { $0.displayTitle })")
            }
            guard controller.currentPlayingItem == nil else {
                return fail("rawFilePlaybackClearsItemCompletionIdentity", "raw playback retained \(String(describing: controller.currentPlayingItem?.displayTitle))")
            }
            controller.closePlayer()
            return pass("rawFilePlaybackClearsItemCompletionIdentity", "raw playback carries no library completion identity")
        } catch {
            return fail("rawFilePlaybackClearsItemCompletionIdentity", "\(error)")
        }
    }

    private static func scenarioPlaybackSessionIdleControlsAreSafe() -> ScenarioResult {
        let session = PlaybackSession()
        session.dismissPlayer()
        guard !session.playerController.isPlayerPresented,
              !session.playerController.isTransitioning else {
            return fail("playbackSessionIdleControlsAreSafe", "idle dismiss mutated presentation state")
        }
        session.closePlayer()
        guard !session.playerController.isPlayerPresented,
              session.playerController.playerService == nil else {
            return fail("playbackSessionIdleControlsAreSafe", "idle close left player state dirty")
        }
        return pass("playbackSessionIdleControlsAreSafe", "idle dismiss is a guarded no-op; idle close stays clean")
    }

    private static func scenarioNextEpisodePlaybackSelection() -> ScenarioResult {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("marquee-next-episode-harness-\(UUID().uuidString)", isDirectory: true)
        let controller = PlayerController()
        defer {
            controller.closePlayer()
            _ = spinRunLoop(timeout: 1) { controller.playerService == nil }
            try? FileManager.default.removeItem(at: root)
        }

        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let paths = (1...3).map { root.appendingPathComponent("episode-\($0).mp4") }
            for path in paths {
                try Data([0]).write(to: path)
            }

            let episodes = paths.enumerated().map { index, path in
                playbackHarnessEpisode(
                    filePath: path.path,
                    season: 1,
                    episode: index + 1
                )
            }
            let movie = playbackHarnessMovie(
                title: "Harness Film",
                year: 2026,
                genres: [],
                director: nil,
                cast: []
            )
            let orphanEpisode = playbackHarnessEpisode(
                filePath: root.appendingPathComponent("orphan.mp4").path,
                season: 1,
                episode: 9
            )
            guard PlayerEpisodePlaybackPolicy.nextEpisode(after: movie, in: episodes) == nil,
                  PlayerEpisodePlaybackPolicy.nextEpisode(after: orphanEpisode, in: episodes) == nil else {
                return fail("nextEpisodePlaybackSelection", "non-episode or unknown item exposed a following episode")
            }

            controller.configure(
                watchStore: nil,
                onItemProgressUpdated: { _ in },
                findNextEpisode: { currentItem in
                    PlayerEpisodePlaybackPolicy.nextEpisode(
                        after: currentItem,
                        in: episodes
                    )
                }
            )

            controller.playItem(episodes[0])
            guard controller.nextEpisode?.id == episodes[1].id else {
                return fail("nextEpisodePlaybackSelection", "first episode did not expose episode 2")
            }

            controller.playNextEpisode()
            guard controller.currentPlayingItem?.id == episodes[1].id,
                  controller.nextEpisode?.id == episodes[2].id else {
                return fail("nextEpisodePlaybackSelection", "Next Episode did not advance to episode 2 with episode 3 available")
            }

            controller.playItem(episodes[2])
            guard controller.nextEpisode == nil else {
                return fail("nextEpisodePlaybackSelection", "final episode still exposed a following episode")
            }
            return pass("nextEpisodePlaybackSelection", "mid-season selection advances once and final episode is terminal")
        } catch {
            return fail("nextEpisodePlaybackSelection", String(describing: error))
        }
    }

    private static func pass(_ name: String, _ detail: String) -> ScenarioResult {
        ScenarioResult(name: name, passed: true, detail: detail)
    }

    private static func fail(_ name: String, _ detail: String) -> ScenarioResult {
        ScenarioResult(name: name, passed: false, detail: detail)
    }

    private static func playbackHarnessMovie(
        title: String,
        year: Int,
        genres: [String],
        director: String?,
        cast: [TMDBMetadata.CastEntry]
    ) -> MediaItem {
        MediaItem(
            filePath: "/tmp/marquee-playback-harness-\(title).mkv",
            fileName: "\(title).mkv",
            title: title,
            year: year,
            fileExtension: "mkv",
            fileSize: 1,
            localGenres: genres,
            metadata: TMDBMetadata(
                tmdbID: year,
                overview: nil,
                genres: genres,
                cast: cast,
                director: director,
                certification: nil,
                voteAverage: 8.0,
                voteCount: 200,
                posterPath: nil,
                backdropPath: nil,
                releaseDate: nil,
                runtime: nil
            )
        )
    }

    private static func playbackHarnessEpisode(
        filePath: String,
        season: Int,
        episode: Int
    ) -> MediaItem {
        let fileName = URL(fileURLWithPath: filePath).lastPathComponent
        return MediaItem(
            filePath: filePath,
            fileName: fileName,
            title: "Harness S\(season)E\(episode)",
            year: 2026,
            fileExtension: "mp4",
            fileSize: 1,
            showName: "Harness Series",
            seasonNumber: season,
            episodeNumber: episode,
            episodeTitle: "Episode \(episode)"
        )
    }

    private static func runtimePlaybackPath() -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: runtimeLaunchArgument),
              CommandLine.arguments.indices.contains(index + 1) else {
            return nil
        }
        return CommandLine.arguments[index + 1]
    }

    private static func runRuntimePlayback(path: String) {
        guard FileManager.default.fileExists(atPath: path) else {
            emit("verify-player-runtime: FAIL missing file: \(path)")
            exit(1)
        }

        emit("verify-player-runtime: step=create-service")
        let service = MPVPlayerService()
        emit("verify-player-runtime: step=create-window")
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 960, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Marquee Runtime Verification"

        let view = MPVOGLView(frame: window.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 960, height: 540))
        view.autoresizingMask = [.width, .height]
        view.playerService = service
        window.contentView = view
        window.makeKeyAndOrderFront(nil)

        emit("verify-player-runtime: step=load-file")
        service.loadFile(path)

        if CommandLine.arguments.contains(runtimeCancelPreparationArgument) {
            emit("verify-player-runtime: step=wait-preparing")
            let fakeFFmpegPIDPath = ProcessInfo.processInfo.environment["MARQUEE_FAKE_FFMPEG_PID_FILE"]
            let preparing = spinRunLoop(timeout: 5) {
                service.preparationMessage != nil
                    && service.verifyBackendDescriptionForHarness == "prepared-avfoundation"
                    && (fakeFFmpegPIDPath == nil
                        || FileManager.default.fileExists(atPath: fakeFFmpegPIDPath!))
            }
            guard preparing else {
                cleanupRuntimePlayback(service: service, view: view, window: window)
                emit("verify-player-runtime: FAIL timed out waiting for preparation to start; backend=\(service.verifyBackendDescriptionForHarness)")
                exit(1)
            }

            emit("verify-player-runtime: step=cancel-preparation")
            cleanupRuntimePlayback(service: service, view: view, window: window, pauseFirst: false)
            if let fakeFFmpegPIDPath {
                let terminated = waitForPIDExitFile(path: fakeFFmpegPIDPath, timeout: 6)
                guard terminated else {
                    emit("verify-player-runtime: FAIL fake ffmpeg still running after cancellation")
                    exit(1)
                }
            }
            emit("verify-player-runtime: PASS cancelled preparation during teardown")
            exit(0)
        }

        if CommandLine.arguments.contains(runtimeExpectFailureArgument) {
            emit("verify-player-runtime: step=wait-failed")
            let failed = spinRunLoop(timeout: 15) {
                service.lifecycleState == .failed
            }
            guard failed else {
                cleanupRuntimePlayback(service: service, view: view, window: window)
                emit("verify-player-runtime: FAIL expected controlled playback failure; state=\(service.lifecycleState) duration=\(service.duration)")
                exit(1)
            }

            if CommandLine.arguments.contains(runtimeExpectEmbeddedCleanupArgument) {
                emit("verify-player-runtime: step=verify-embedded-helper-cleanup")
                let internalStopped = spinRunLoop(timeout: 2) {
                    !service.verifyEmbeddedBridgeHasRunningProcessForHarness
                }
                let pidFile = ProcessInfo.processInfo.environment["MARQUEE_VERIFY_TERMINATED_PID_FILE"]
                let helperStopped = pidFile.map { waitForPIDExitFile(path: $0, timeout: 6) } ?? true
                guard internalStopped, helperStopped else {
                    cleanupRuntimePlayback(service: service, view: view, window: window)
                    emit("verify-player-runtime: FAIL embedded helper remained running after companion failure internalStopped=\(internalStopped) helperStopped=\(helperStopped)")
                    exit(1)
                }
            }

            cleanupRuntimePlayback(service: service, view: view, window: window)
            emit("verify-player-runtime: PASS controlled playback failure without process crash")
            exit(0)
        }

        let expectedBackend = expectedBackendDescription(for: path)
        emit("verify-player-runtime: step=wait-loaded")
        let loadTimeout: TimeInterval = expectedBackend == "prepared-avfoundation" ? 180 : 30
        let loaded = spinRunLoop(timeout: loadTimeout) {
            service.lifecycleState == .playing
        }
        guard loaded else {
            cleanupRuntimePlayback(service: service, view: view, window: window)
            emit("verify-player-runtime: FAIL timed out waiting for playback to load; state=\(service.lifecycleState) duration=\(service.duration)")
            exit(1)
        }
        let backend = service.verifyBackendDescriptionForHarness
        guard backend == expectedBackend || defaultPreparedExpectationAllowsEmbeddedFallback(expected: expectedBackend, actual: backend) else {
            let backend = service.verifyBackendDescriptionForHarness
            cleanupRuntimePlayback(service: service, view: view, window: window)
            emit("verify-player-runtime: FAIL unexpected backend \(backend) for \(path)")
            exit(1)
        }
        let unpaused = spinRunLoop(timeout: 1) {
            service.lifecycleState == .playing && !service.isPaused
        }
        guard unpaused else {
            let state = service.lifecycleState
            cleanupRuntimePlayback(service: service, view: view, window: window)
            emit("verify-player-runtime: FAIL playback loaded but pause state was stale; state=\(state) isPaused=\(service.isPaused)")
            exit(1)
        }
        _ = spinRunLoop(timeout: 0.35) { false }
        guard !service.isPaused else {
            cleanupRuntimePlayback(service: service, view: view, window: window)
            emit("verify-player-runtime: FAIL playback pause state changed after load settled")
            exit(1)
        }

        if CommandLine.arguments.contains(runtimeRequireAVDirectSurfaceArgument) {
            emit("verify-player-runtime: step=verify-av-direct-surface")
            guard service.verifyBackendDescriptionForHarness == "avfoundation"
                    || service.verifyBackendDescriptionForHarness == "prepared-avfoundation" else {
                cleanupRuntimePlayback(service: service, view: view, window: window)
                emit("verify-player-runtime: FAIL AV direct surface requested for backend \(service.verifyBackendDescriptionForHarness)")
                exit(1)
            }

            let hasDirectSurface = spinRunLoop(timeout: 2) {
                view.verifyAVPlayerSurfaceUsesDirectPolicyForHarness()
            }
            guard hasDirectSurface else {
                cleanupRuntimePlayback(service: service, view: view, window: window)
                emit("verify-player-runtime: FAIL AVPlayer surface was not hosted directly")
                exit(1)
            }
        }

        if CommandLine.arguments.contains(runtimeRequireAudioHelperArgument) {
            emit("verify-player-runtime: step=verify-audio-helper")
            let hasAudioHelper = spinRunLoop(timeout: 2) {
                service.verifyEmbeddedAudioProcessIsRunningForHarness
            }
            guard hasAudioHelper else {
                cleanupRuntimePlayback(service: service, view: view, window: window)
                emit("verify-player-runtime: FAIL embedded audio helper was not running after load; state=\(service.lifecycleState)")
                exit(1)
            }
        }

        if CommandLine.arguments.contains(runtimeRequireStereoDownmixArgument) {
            emit("verify-player-runtime: step=verify-stereo-downmix")
            let args = service.verifyEmbeddedAudioArgumentsForHarness
            guard argumentList(args, containsOption: "-ac", value: "2") else {
                cleanupRuntimePlayback(service: service, view: view, window: window)
                emit("verify-player-runtime: FAIL embedded audio helper did not force stereo downmix args=\(args.joined(separator: " "))")
                exit(1)
            }
        }

        if CommandLine.arguments.contains(runtimeSelfSigkillAfterLoadArgument) {
            guard let videoPIDFile = ProcessInfo.processInfo.environment["MARQUEE_FAKE_EMBEDDED_VIDEO_PID_FILE"],
                  let audioPIDFile = ProcessInfo.processInfo.environment["MARQUEE_FAKE_EMBEDDED_AUDIO_PID_FILE"],
                  !videoPIDFile.isEmpty,
                  !audioPIDFile.isEmpty else {
                cleanupRuntimePlayback(service: service, view: view, window: window)
                emit("verify-player-runtime: FAIL missing embedded helper pid files before self SIGKILL")
                exit(1)
            }
            let pidFiles = [
                videoPIDFile,
                audioPIDFile
            ]
            let pidFilesReady = pidFiles.allSatisfy { waitForPIDFile(path: $0, timeout: 2) }
            guard pidFilesReady else {
                cleanupRuntimePlayback(service: service, view: view, window: window)
                emit("verify-player-runtime: FAIL timed out waiting for embedded helper pid files before self SIGKILL")
                exit(1)
            }
            emit("verify-player-runtime: step=self-sigkill-after-load")
            fflush(nil)
            kill(getpid(), SIGKILL)
        }

        if CommandLine.arguments.contains(runtimeRequireVideoFrameArgument) {
            emit("verify-player-runtime: step=verify-video-frame")
            let hasFrame: Bool
            if service.verifyBackendDescriptionForHarness == "external-ffplay" {
                let started = spinRunLoop(timeout: 5) {
                    service.verifyExternalPlayerIsRunningForHarness
                }
                _ = spinRunLoop(timeout: 0.75) { false }
                hasFrame = started && service.verifyExternalPlayerIsRunningForHarness
            } else if service.verifyBackendDescriptionForHarness == "avfoundation"
                        || service.verifyBackendDescriptionForHarness == "prepared-avfoundation" {
                hasFrame = spinRunLoop(timeout: 5) {
                    view.verifyAVPlayerSurfaceUsesDirectPolicyForHarness()
                }
            } else {
                hasFrame = spinRunLoop(timeout: 5) {
                    view.verifySoftwareSurfaceHasVisibleFrameForHarness()
                }
            }
            guard hasFrame else {
                cleanupRuntimePlayback(service: service, view: view, window: window)
                emit("verify-player-runtime: FAIL playback loaded but no video-capable playback surface was active")
                exit(1)
            }
        }

        if CommandLine.arguments.contains(runtimeExerciseEmbeddedAudioControlsArgument) {
            emit("verify-player-runtime: step=exercise-embedded-audio-controls")
            guard service.verifyBackendDescriptionForHarness == "ffmpeg-embedded" else {
                cleanupRuntimePlayback(service: service, view: view, window: window)
                emit("verify-player-runtime: FAIL embedded audio controls requested for backend \(service.verifyBackendDescriptionForHarness)")
                exit(1)
            }
            guard let initialPID = service.verifyEmbeddedBridgeProcessIdentifierForHarness else {
                cleanupRuntimePlayback(service: service, view: view, window: window)
                emit("verify-player-runtime: FAIL missing embedded bridge process before audio controls")
                exit(1)
            }

            // Audio now renders in-app, so volume and mute are mixer
            // operations. Any bridge restart here is a regression: it would
            // reintroduce the audio gap and picture freeze on every change.
            for value in [80.0, 62.0, 44.0, 66.0] {
                service.setVolume(value)
                _ = spinRunLoop(timeout: 0.05) { false }
            }

            guard service.verifyEmbeddedBridgeProcessIdentifierForHarness == initialPID,
                  service.verifyEmbeddedAudioProcessIsRunningForHarness,
                  service.lifecycleState == .playing,
                  !service.isPaused else {
                let currentPID = String(describing: service.verifyEmbeddedBridgeProcessIdentifierForHarness)
                cleanupRuntimePlayback(service: service, view: view, window: window)
                emit("verify-player-runtime: FAIL volume change disturbed embedded playback initialPID=\(initialPID) currentPID=\(currentPID) state=\(service.lifecycleState) paused=\(service.isPaused)")
                exit(1)
            }

            service.toggleMute()
            _ = spinRunLoop(timeout: 0.3) { false }
            guard service.isMuted,
                  service.verifyEmbeddedBridgeProcessIdentifierForHarness == initialPID,
                  service.lifecycleState == .playing,
                  !service.isPaused else {
                cleanupRuntimePlayback(service: service, view: view, window: window)
                emit("verify-player-runtime: FAIL mute restarted or disturbed the embedded bridge")
                exit(1)
            }

            service.toggleMute()
            _ = spinRunLoop(timeout: 0.3) { false }
            guard !service.isMuted,
                  service.verifyEmbeddedBridgeProcessIdentifierForHarness == initialPID,
                  service.verifyEmbeddedAudioProcessIsRunningForHarness,
                  service.lifecycleState == .playing,
                  !service.isPaused else {
                cleanupRuntimePlayback(service: service, view: view, window: window)
                emit("verify-player-runtime: FAIL unmute restarted or disturbed the embedded bridge")
                exit(1)
            }

            // The synchronizer is the position authority; prove it anchored
            // and advances, and that audio never failed. There is no
            // wall-clock fallback left for this assertion to pass on.
            let clockMark = service.currentTime
            let clockAdvanced = spinRunLoop(timeout: 4) {
                service.currentTime > clockMark + 0.3
            }
            guard clockAdvanced,
                  service.verifyEmbeddedClockIsAnchoredForHarness,
                  !service.verifyEmbeddedAudioPipelineDegradedForHarness else {
                let degraded = service.verifyEmbeddedAudioPipelineDegradedForHarness
                let anchored = service.verifyEmbeddedClockIsAnchoredForHarness
                let now = service.currentTime
                cleanupRuntimePlayback(service: service, view: view, window: window)
                emit("verify-player-runtime: FAIL embedded clock not live mark=\(clockMark) now=\(now) anchored=\(anchored) degraded=\(degraded)")
                exit(1)
            }

            // Pause must freeze the clock in place without touching the
            // bridge process; the restart-per-pause era is over.
            service.setPaused(true)
            _ = spinRunLoop(timeout: 0.3) { false }
            let pausedMark = service.currentTime
            _ = spinRunLoop(timeout: 0.6) { false }
            let pausedDrift = abs(service.currentTime - pausedMark)
            guard service.isPaused,
                  pausedDrift < 0.15,
                  service.verifyEmbeddedBridgeProcessIdentifierForHarness == initialPID else {
                let currentPID = String(describing: service.verifyEmbeddedBridgeProcessIdentifierForHarness)
                cleanupRuntimePlayback(service: service, view: view, window: window)
                emit("verify-player-runtime: FAIL pause did not freeze the embedded clock in place drift=\(pausedDrift) initialPID=\(initialPID) currentPID=\(currentPID)")
                exit(1)
            }

            service.setPaused(false)
            let resumeMark = service.currentTime
            let resumed = spinRunLoop(timeout: 4) {
                service.currentTime > resumeMark + 0.3
            }
            guard resumed,
                  !service.isPaused,
                  service.verifyEmbeddedBridgeProcessIdentifierForHarness == initialPID else {
                let currentPID = String(describing: service.verifyEmbeddedBridgeProcessIdentifierForHarness)
                cleanupRuntimePlayback(service: service, view: view, window: window)
                emit("verify-player-runtime: FAIL resume did not restart the embedded clock in place initialPID=\(initialPID) currentPID=\(currentPID)")
                exit(1)
            }

            // Speed is a synchronizer rate change; media time must outrun
            // wall time without any relaunch.
            service.setPlaybackSpeed(2.0)
            let speedMark = service.currentTime
            let speedWallStart = Date()
            _ = spinRunLoop(timeout: 1.6) { false }
            let speedMediaDelta = service.currentTime - speedMark
            let speedWallDelta = Date().timeIntervalSince(speedWallStart)
            service.setPlaybackSpeed(1.0)
            guard speedWallDelta > 0,
                  speedMediaDelta > speedWallDelta * 1.3,
                  service.verifyEmbeddedBridgeProcessIdentifierForHarness == initialPID else {
                let currentPID = String(describing: service.verifyEmbeddedBridgeProcessIdentifierForHarness)
                cleanupRuntimePlayback(service: service, view: view, window: window)
                emit("verify-player-runtime: FAIL 2x speed did not outrun wall time media=\(speedMediaDelta) wall=\(speedWallDelta) initialPID=\(initialPID) currentPID=\(currentPID)")
                exit(1)
            }

            let frameVisible = spinRunLoop(timeout: 2) {
                view.verifySoftwareSurfaceHasVisibleFrameForHarness()
            }
            guard frameVisible,
                  service.verifyEmbeddedBridgeProcessIdentifierForHarness == initialPID,
                  !service.verifyEmbeddedAudioPipelineDegradedForHarness else {
                cleanupRuntimePlayback(service: service, view: view, window: window)
                emit("verify-player-runtime: FAIL embedded controls left playback unhealthy frameVisible=\(frameVisible)")
                exit(1)
            }
        }

        if CommandLine.arguments.contains(runtimeRequireSurfaceClearAfterFailedReloadArgument) {
            guard let secondPath = runtimeSecondPlaybackPath() else {
                cleanupRuntimePlayback(service: service, view: view, window: window)
                emit("verify-player-runtime: FAIL missing second path for stale-frame clearing check")
                exit(1)
            }

            emit("verify-player-runtime: step=load-second-file")
            service.loadFile(secondPath)
            let failed = spinRunLoop(timeout: 15) {
                service.lifecycleState == .failed
            }
            guard failed else {
                cleanupRuntimePlayback(service: service, view: view, window: window)
                emit("verify-player-runtime: FAIL second embedded load did not fail as expected; state=\(service.lifecycleState)")
                exit(1)
            }

            emit("verify-player-runtime: step=verify-surface-cleared")
            let cleared = spinRunLoop(timeout: 2) {
                view.verifyExternalFrameSurfaceIsClearForHarness()
            }
            guard cleared else {
                cleanupRuntimePlayback(service: service, view: view, window: window)
                emit("verify-player-runtime: FAIL embedded surface kept stale frame after failed reload")
                exit(1)
            }

            cleanupRuntimePlayback(service: service, view: view, window: window, pauseFirst: false)
            emit("verify-player-runtime: PASS stale embedded frame cleared after failed reload")
            exit(0)
        }

        if CommandLine.arguments.contains(runtimeRequireRapidSeekStopClearArgument) {
            emit("verify-player-runtime: step=rapid-seek")
            service.seek(to: 0.4)
            let seekCompleted = spinRunLoop(timeout: 2) {
                service.lifecycleState == .playing || service.lifecycleState == .paused || service.lifecycleState == .failed
            }
            guard seekCompleted, service.lifecycleState != .failed else {
                let state = service.lifecycleState
                cleanupRuntimePlayback(service: service, view: view, window: window)
                emit("verify-player-runtime: FAIL rapid seek did not stay healthy; state=\(state)")
                exit(1)
            }

            emit("verify-player-runtime: step=rapid-stop")
            service.stop()
            let stopped = spinRunLoop(timeout: 3) {
                service.lifecycleState == .stopped && !service.verifyEmbeddedBridgeHasRunningProcessForHarness
            }
            _ = spinRunLoop(timeout: 0.4) { false }
            let cleared = view.verifyExternalFrameSurfaceIsClearForHarness()
            guard stopped, cleared else {
                cleanupRuntimePlayback(service: service, view: view, window: window, pauseFirst: false)
                emit("verify-player-runtime: FAIL embedded rapid seek/stop left stale frame or helper stopped=\(stopped) cleared=\(cleared) state=\(service.lifecycleState)")
                exit(1)
            }

            cleanupRuntimePlayback(service: service, view: view, window: window, pauseFirst: false)
            emit("verify-player-runtime: PASS embedded rapid seek/stop cleared frame and helpers")
            exit(0)
        }

        if CommandLine.arguments.contains(runtimeRequireRapidReloadStopProbeCleanupArgument) {
            guard let secondPath = runtimeSecondPlaybackPath() else {
                cleanupRuntimePlayback(service: service, view: view, window: window)
                emit("verify-player-runtime: FAIL missing second path for rapid reload/stop probe cleanup")
                exit(1)
            }

            if let probePIDPath = ProcessInfo.processInfo.environment["MARQUEE_FAKE_FFPROBE_PID_FILE"] {
                let probeStarted = spinRunLoop(timeout: 2) {
                    FileManager.default.fileExists(atPath: probePIDPath)
                }
                guard probeStarted else {
                    cleanupRuntimePlayback(service: service, view: view, window: window)
                    emit("verify-player-runtime: FAIL embedded duration probe did not start before rapid reload")
                    exit(1)
                }
            }

            emit("verify-player-runtime: step=rapid-reload-for-probe-cleanup")
            service.loadFile(secondPath)
            _ = spinRunLoop(timeout: 0.05) { false }
            emit("verify-player-runtime: step=rapid-stop-after-reload")
            service.stop()
            let stopped = spinRunLoop(timeout: 4) {
                service.lifecycleState == .stopped && !service.verifyEmbeddedBridgeHasRunningProcessForHarness
            }
            guard stopped else {
                cleanupRuntimePlayback(service: service, view: view, window: window, pauseFirst: false)
                emit("verify-player-runtime: FAIL rapid reload/stop did not stop embedded playback; state=\(service.lifecycleState)")
                exit(1)
            }

            cleanupRuntimePlayback(service: service, view: view, window: window, pauseFirst: false)
            emit("verify-player-runtime: PASS rapid reload/stop completed with probe cleanup path exercised")
            exit(0)
        }

        if CommandLine.arguments.contains(runtimeRequireSidecarSubtitleArgument) {
            emit("verify-player-runtime: step=verify-sidecar-subtitle")
            let subtitlesDiscovered = spinRunLoop(timeout: 2) {
                service.availableSubtitleTracks.contains { $0.isExternal }
            }
            guard subtitlesDiscovered,
                  let track = service.availableSubtitleTracks.first(where: { $0.isExternal }) else {
                cleanupRuntimePlayback(service: service, view: view, window: window)
                emit("verify-player-runtime: FAIL no sidecar subtitle track discovered for embedded playback")
                exit(1)
            }

            let startTime = service.currentTime
            service.selectSubtitleTrack(track)
            let subtitleSelected = spinRunLoop(timeout: 2) {
                service.subtitlesEnabled
                    && service.currentSubtitleTrack == track
                    && !service.currentSubtitleEntries.isEmpty
            }
            let timeAdvanced = spinRunLoop(timeout: 3) {
                service.currentTime > startTime + 0.1
            }
            guard subtitleSelected, timeAdvanced else {
                cleanupRuntimePlayback(service: service, view: view, window: window)
                emit("verify-player-runtime: FAIL sidecar subtitle runtime check failed selected=\(subtitleSelected) advanced=\(timeAdvanced) entries=\(service.currentSubtitleEntries.count) currentTime=\(service.currentTime)")
                exit(1)
            }
        }

        if CommandLine.arguments.contains(runtimeExerciseInteractiveScrubArgument) {
            emit("verify-player-runtime: step=interactive-scrub")
            let target = min(max(service.duration / 2, 1), 10)
            let wasPlaying = service.lifecycleState == .playing && !service.isPaused
            service.setPaused(true)
            let pausedForScrub = spinRunLoop(timeout: 2) {
                service.lifecycleState == .paused || service.lifecycleState == .failed
            }
            guard pausedForScrub, service.lifecycleState == .paused else {
                let state = service.lifecycleState
                cleanupRuntimePlayback(service: service, view: view, window: window)
                emit("verify-player-runtime: FAIL interactive scrub did not pause before seeking; state=\(state)")
                exit(1)
            }

            service.beginInteractiveScrub()
            service.previewInteractiveScrub(to: target)
            service.finishInteractiveScrub(to: target, resumePlayback: wasPlaying)
            let resumedAfterScrub = spinRunLoop(timeout: 3) {
                service.lifecycleState == .playing || service.lifecycleState == .failed
            }
            guard resumedAfterScrub, service.lifecycleState == .playing, !service.isPaused else {
                let state = service.lifecycleState
                cleanupRuntimePlayback(service: service, view: view, window: window)
                emit("verify-player-runtime: FAIL interactive scrub did not resume after seek completion; state=\(state) isPaused=\(service.isPaused)")
                exit(1)
            }
            emit("verify-player-runtime: PASS interactive scrub finished seek then resumed playback")
        }

        if CommandLine.arguments.contains(runtimePlayToEndArgument) {
            // Natural end is deferred until the clock plays out the queued
            // tail; prove it still arrives and tears the bridge down.
            emit("verify-player-runtime: step=play-to-end")
            let ended = spinRunLoop(timeout: 20) {
                service.lifecycleState == .ended
            }
            guard ended, !service.verifyEmbeddedBridgeHasRunningProcessForHarness else {
                let state = service.lifecycleState
                cleanupRuntimePlayback(service: service, view: view, window: window, pauseFirst: false)
                emit("verify-player-runtime: FAIL playback did not reach a clean natural end; state=\(state)")
                exit(1)
            }
            emit("verify-player-runtime: step=cleanup-play-to-end")
            cleanupRuntimePlayback(service: service, view: view, window: window, pauseFirst: false)
            emit("verify-player-runtime: PASS played to natural end and tore the bridge down")
            exit(0)
        }

        if CommandLine.arguments.contains(runtimeLoadOnlyArgument) {
            emit("verify-player-runtime: step=settle-loaded")
            _ = spinRunLoop(timeout: 1) { false }
            guard service.lifecycleState == .playing else {
                cleanupRuntimePlayback(service: service, view: view, window: window, pauseFirst: false)
                emit("verify-player-runtime: FAIL playback did not remain healthy after settle; state=\(service.lifecycleState)")
                exit(1)
            }
            emit("verify-player-runtime: step=cleanup-load-only")
            cleanupRuntimePlayback(service: service, view: view, window: window, pauseFirst: false)
            emit("verify-player-runtime: PASS loaded real file and settled without control commands")
            exit(0)
        }

        emit("verify-player-runtime: step=pause")
        service.setPaused(true)
        _ = spinRunLoop(timeout: 1) { service.isPaused }
        emit("verify-player-runtime: step=seek")
        service.seek(to: min(max(service.duration / 2, 1), 10))
        let seekCompleted = spinRunLoop(timeout: 2) {
            service.lifecycleState == .paused || service.lifecycleState == .failed
        }
        guard seekCompleted, service.lifecycleState == .paused else {
            let state = service.lifecycleState
            cleanupRuntimePlayback(service: service, view: view, window: window)
            emit("verify-player-runtime: FAIL playback did not complete paused seek; state=\(state)")
            exit(1)
        }
        emit("verify-player-runtime: step=resume")
        service.setPaused(false)
        let resumed = spinRunLoop(timeout: 2) {
            service.lifecycleState == .playing || service.lifecycleState == .failed
        }
        guard resumed, service.lifecycleState == .playing else {
            let state = service.lifecycleState
            cleanupRuntimePlayback(service: service, view: view, window: window)
            emit("verify-player-runtime: FAIL playback did not resume cleanly after controls; state=\(state)")
            exit(1)
        }
        emit("verify-player-runtime: step=cleanup")
        cleanupRuntimePlayback(service: service, view: view, window: window)
        emit("verify-player-runtime: PASS loaded real file, exercised pause/seek/resume/stop, and detached render view")
        exit(0)
    }

    private static func cleanupRuntimePlayback(service: MPVPlayerService, view: MPVOGLView, window: NSWindow, pauseFirst: Bool = true) {
        if pauseFirst {
            emit("verify-player-runtime: cleanup=pause")
            service.setPaused(true)
            _ = spinRunLoop(timeout: 0.3) { service.isPaused }
        }
        emit("verify-player-runtime: cleanup=detach-view")
        view.removeFromSuperview()
        emit("verify-player-runtime: cleanup=close-window")
        window.close()
        _ = spinRunLoop(timeout: 0.35) { true }
        emit("verify-player-runtime: cleanup=stop")
        service.stop()
        _ = spinRunLoop(timeout: 0.5) { true }
        emit("verify-player-runtime: cleanup=shutdown")
        service.shutdown()
        emit("verify-player-runtime: cleanup=done")
    }

    private static func expectedBackendDescription(for path: String) -> String {
        if let expected = explicitExpectedBackendDescription() {
            return expected
        }

        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "mp4", "m4v", "mov":
            if avContainerRequiresEmbeddedBridge(path) {
                return expectedMultiformatBridgeBackend()
            }
            return "avfoundation"
        case "mkv":
            if ProcessInfo.processInfo.environment["MARQUEE_ENABLE_EXTERNAL_FFPLAY_WINDOW"] == "1" {
                return "external-ffplay"
            }
            if preparedStreamCopyBridgeIsEnabled() {
                return "prepared-avfoundation"
            }
            if ProcessInfo.processInfo.environment["MARQUEE_ENABLE_INPROCESS_MPV"] == "1" {
                return "mpv"
            }
            return ProcessInfo.processInfo.environment["MARQUEE_DISABLE_EMBEDDED_BRIDGE"] == "1"
                ? "unsupported"
                : "ffmpeg-embedded"
        case "avi", "m2ts", "mpeg", "mpg", "ts", "vob", "webm":
            return expectedMultiformatBridgeBackend()
        default:
            return "unsupported"
        }
    }

    private static func expectedMultiformatBridgeBackend() -> String {
        if ProcessInfo.processInfo.environment["MARQUEE_ENABLE_EXTERNAL_FFPLAY_WINDOW"] == "1" {
            return "external-ffplay"
        }
        if preparedStreamCopyBridgeIsEnabled() {
            return "prepared-avfoundation"
        }
        if ProcessInfo.processInfo.environment["MARQUEE_DISABLE_EMBEDDED_BRIDGE"] == "1" {
            return "unsupported"
        }
        return "ffmpeg-embedded"
    }

    private static func preparedStreamCopyBridgeIsEnabled() -> Bool {
        ProcessInfo.processInfo.environment["MARQUEE_ENABLE_PREPARED_AVFOUNDATION"] == "1"
            || ProcessInfo.processInfo.environment["MARQUEE_ENABLE_PREPARED_STREAMCOPY_BRIDGE"] == "1"
    }

    private static func defaultPreparedExpectationAllowsEmbeddedFallback(expected: String, actual: String) -> Bool {
        explicitExpectedBackendDescription() == nil
            && expected == "prepared-avfoundation"
            && actual == "ffmpeg-embedded"
            && ProcessInfo.processInfo.environment["MARQUEE_DISABLE_EMBEDDED_BRIDGE"] != "1"
    }

    private static func argumentList(_ args: [String], containsOption option: String, value: String) -> Bool {
        args.indices.contains { index in
            args[index] == option
                && args.indices.contains(index + 1)
                && args[index + 1] == value
        }
    }

    private static func avContainerRequiresEmbeddedBridge(_ path: String) -> Bool {
        let asset = AVAsset(url: URL(fileURLWithPath: path))
        let videoTracks = asset.tracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first,
              let rawFormatDescription = videoTrack.formatDescriptions.first else {
            return false
        }
        guard CFGetTypeID(rawFormatDescription as CFTypeRef) == CMFormatDescriptionGetTypeID() else {
            return false
        }
        let formatDescription = rawFormatDescription as! CMFormatDescription
        let codec = fourCCString(CMFormatDescriptionGetMediaSubType(formatDescription))
        return codec == "hvc1" || codec == "hev1"
    }

    private static func fourCCString(_ code: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xff),
            UInt8((code >> 16) & 0xff),
            UInt8((code >> 8) & 0xff),
            UInt8(code & 0xff)
        ]
        return String(bytes: bytes, encoding: .ascii)?.lowercased() ?? ""
    }

    private static func explicitExpectedBackendDescription() -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: runtimeExpectedBackendArgument),
              CommandLine.arguments.indices.contains(index + 1) else {
            return nil
        }
        return CommandLine.arguments[index + 1]
    }

    private static func runtimeSecondPlaybackPath() -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: runtimeSecondPathArgument),
              CommandLine.arguments.indices.contains(index + 1) else {
            return nil
        }
        return CommandLine.arguments[index + 1]
    }

    private static func spinRunLoop(timeout: TimeInterval, until predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return predicate()
    }

    private static func waitForPIDExitFile(path: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let pid = readPIDFile(path: path) else {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
                continue
            }
            if kill(pid, 0) != 0 {
                return true
            }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return false
    }

    private static func waitForPIDFile(path: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if readPIDFile(path: path) != nil {
                return true
            }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return readPIDFile(path: path) != nil
    }

    private static func readPIDFile(path: String) -> pid_t? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }
        return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func emit(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    private struct ScenarioResult {
        let name: String
        let passed: Bool
        let detail: String
    }
}

#endif
