//
//  VerifyProfilePickerHarness.swift
//  Marquee
//
//  DEBUG-only verification for the native profile picker surface.
//  Activated by `--verify-profile-picker`.
//

#if DEBUG

import AppKit
import Foundation
import SwiftUI

enum VerifyProfilePickerHarness {
    static let launchArgument = "--verify-profile-picker"
    private static let profilePickerPNGEnvironmentKey = "MARQUEE_VERIFY_PROFILE_PICKER_PNG"
    private static let qaOutputDirectoryArgument = "--qa-output-dir"
    private static let keyWindowWaitTimeout: TimeInterval = 1.0
    private static let keyWindowWaitPollNanoseconds: UInt64 = 20_000_000

    static func runIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains(launchArgument) else { return }

        do {
            let context = try prepareScenario(
                arguments: arguments,
                environment: ProcessInfo.processInfo.environment
            )
            Task { @MainActor in
                await runScenarioAndExit(context: context)
            }
        } catch {
            reportFailure(error)
        }
    }

    private struct ScenarioContext {
        let appState: AppState
        let profile: UserProfile
        let outputPNGURL: URL
        let completionArtifactURL: URL
    }

    @MainActor
    private static func runScenarioAndExit(context: ScenarioContext) async {
        do {
            let detail = try await runLiveScenario(context: context)
            try writeCompletionArtifact(at: context.completionArtifactURL)
            FileHandle.standardError.write(Data("verify-profile-picker: PASS rendersAndSelectsProfile: \(detail)\n".utf8))
            FileHandle.standardError.write(Data("verify-profile-picker: outcome=verified passed=9/9\n".utf8))
            exit(0)
        } catch {
            writeFailureArtifact(at: context.completionArtifactURL, error: error)
            reportFailure(error)
        }
    }

    private static func prepareScenario(
        arguments: [String],
        environment: [String: String]
    ) throws -> ScenarioContext {
        guard Thread.isMainThread else {
            throw HarnessError.assertion("profile picker harness must run on the main thread")
        }

        try verifyKidsSelectionHookOrdering()
        try verifyAdultSelectionDeferral()
        try verifyAdultSwitchRestoresFullLibrary()

        let appState = AppState(skipPersistenceForHarness: true)
        let store = ProfileStore.shared
        guard store.profiles.count >= 2 else {
            throw HarnessError.assertion("expected default profiles, got \(store.profiles.count)")
        }
        guard let kids = store.profiles.first(where: { $0.maturityLevel == .kids }) else {
            throw HarnessError.assertion("expected a kids profile")
        }
        try verifyCenteredRowLayout()
        try verifyProfileFocusRingGeometry()
        try verifyProfileExitTransitionPolicy()
        try verifyProfileManagementContracts()
        try verifyProfileWindowLifecycleWaitPolicy()
        try verifyArtifactPathResolution()

        let artifactPaths = try resolvedArtifactPaths(
            arguments: arguments,
            environment: environment
        )

        return ScenarioContext(
            appState: appState,
            profile: kids,
            outputPNGURL: artifactPaths.outputPNGURL,
            completionArtifactURL: artifactPaths.completionArtifactURL
        )
    }

    private static func verifyProfileManagementContracts() throws {
        try verifyProfileManagementGeometry()
        try verifyProfileManagementNavigation()

        for action in ProfileManagementAction.allCases {
            guard !action.accessibilityLabel.isEmpty,
                  !action.accessibilityHint.isEmpty else {
                throw HarnessError.assertion("\(action) lacks accessible text")
            }
        }
    }

    private static func verifyProfileManagementGeometry() throws {
        for profileCount in 1...5 {
            let itemCount = profileCount + (profileCount < 5 ? 1 : 0)
            let geometry = ProfilePickerManagementRowLayout.resolved(
                itemCount: itemCount,
                availableWidth: ProfilePickerManagementRowLayout.supportedMinimumWidth
            )
            guard geometry.fitsAvailableWidth else {
                throw HarnessError.assertion(
                    "management row clipped at 1100 points for \(profileCount) profiles: group=\(geometry.groupWidth) inset=\(geometry.horizontalInset)"
                )
            }
            guard geometry.tileWidth >= ProfilePickerManagementRowLayout.minimumTileWidth else {
                throw HarnessError.assertion(
                    "management tile shrank below its content width for \(profileCount) profiles: \(geometry.tileWidth)"
                )
            }
            guard geometry.tileWidth <= ProfileManagementLayoutPolicy.tileWidth,
                  geometry.spacing <= ProfileManagementLayoutPolicy.rowSpacing else {
                throw HarnessError.assertion(
                    "responsive management geometry exceeded its intended tile or spacing maximum"
                )
            }

            let actionGeometry = ProfilePickerManagementRowLayout.actionGeometry(
                tileWidth: geometry.tileWidth
            )
            let availableActionWidth = geometry.tileWidth
                - 2 * ProfilePickerManagementRowLayout.tileContentInset
            guard actionGeometry.width <= availableActionWidth + 0.5,
                  actionGeometry.buttonSize > 0 else {
                throw HarnessError.assertion(
                    "management actions overflowed a \(geometry.tileWidth)-point tile: \(actionGeometry.width)"
                )
            }
        }

        let narrow = ProfilePickerManagementRowLayout.resolved(
            itemCount: 5,
            availableWidth: 960
        )
        guard narrow.fitsAvailableWidth else {
            throw HarnessError.assertion("management row must remain bounded below the supported window width")
        }
    }

    /// Traversal contract for the picker's `FocusEngine` tree: top-row order and
    /// clamping, the wrap that only the manage control performs, and the
    /// profile-scoped entry and exit of the management row. These are the cases a
    /// positional engine gets wrong without seeded container entry, so they are
    /// asserted independently of the management-action walk above.
    private static func verifyProfilePickerFocusTreeTraversal() throws {
        let first = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
        let second = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000002")!
        let third = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000003")!
        let ids = [first, second, third]

        func moved(
            _ from: ProfilePickerRemoteFocus,
            _ command: RemoteCommand,
            canAddProfile: Bool = true,
            isManaging: Bool = false
        ) -> ProfilePickerRemoteFocus {
            ProfilePickerRemoteNavigationPolicy.movedFocus(
                from: from,
                command: command,
                profileIDs: ids,
                canAddProfile: canAddProfile,
                isManaging: isManaging
            )
        }

        // Top row traverses profiles then Add, and clamps at both ends.
        guard moved(.profile(first), .right) == .profile(second),
              moved(.profile(third), .right) == .addProfile,
              moved(.addProfile, .right) == .addProfile,
              moved(.profile(first), .left) == .profile(first) else {
            throw HarnessError.assertion("top row order or clamping regressed")
        }

        // Add disappears from the row when the profile limit is reached.
        guard moved(.profile(third), .right, canAddProfile: false) == .profile(third) else {
            throw HarnessError.assertion("top row should clamp at the last profile without Add")
        }

        // Only the manage control wraps, and it wraps to the opposite end.
        guard moved(.manageProfiles, .right) == .profile(first),
              moved(.manageProfiles, .left) == .addProfile else {
            throw HarnessError.assertion("manage control wrap regressed")
        }

        // Vertical moves stay scoped to the profile that owns the row: Down from
        // the third profile enters its own first enabled action, and Up returns
        // to that profile rather than a same-index neighbour.
        guard moved(.profile(third), .down, isManaging: true)
            == .managementAction(third, .moveLeft) else {
            throw HarnessError.assertion("Down did not enter the owning profile's first enabled action")
        }
        guard moved(.managementAction(third, .delete), .up, isManaging: true)
            == .profile(third) else {
            throw HarnessError.assertion("Up from a management action did not return to its owning profile")
        }

        // The first profile has no Move Left, so its row starts at Edit.
        guard moved(.profile(first), .down, isManaging: true)
            == .managementAction(first, .edit) else {
            throw HarnessError.assertion("Down ignored the owning profile's disabled actions")
        }

        // Without management the row is absent, so Down reaches the manage control.
        guard moved(.profile(second), .down) == .manageProfiles,
              moved(.addProfile, .down) == .manageProfiles else {
            throw HarnessError.assertion("Down should reach the manage control when not managing")
        }

        // Up from the manage control re-enters the top row at its head, and Down
        // from it stays put because nothing follows.
        guard moved(.manageProfiles, .up) == .profile(first),
              moved(.manageProfiles, .down) == .manageProfiles else {
            throw HarnessError.assertion("manage control vertical boundaries regressed")
        }

        // Up from the top row is a boundary, not a wrap into the manage control.
        guard moved(.profile(second), .up) == .profile(second) else {
            throw HarnessError.assertion("Up from the top row should hold focus")
        }
    }

    private static func verifyProfileManagementNavigation() throws {
        let first = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let second = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let third = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let ids = [first, second, third]

        var focus = ProfilePickerRemoteNavigationPolicy.movedFocus(
            from: .profile(second),
            command: .down,
            profileIDs: ids,
            canAddProfile: true,
            isManaging: true
        )
        guard focus == .managementAction(second, .moveLeft) else {
            throw HarnessError.assertion("manage Down did not enter the focused profile's first enabled action: \(focus)")
        }

        focus = ProfilePickerRemoteNavigationPolicy.movedFocus(
            from: focus,
            command: .right,
            profileIDs: ids,
            canAddProfile: true,
            isManaging: true
        )
        guard focus == .managementAction(second, .edit) else {
            throw HarnessError.assertion("manage Right did not advance to Edit: \(focus)")
        }
        guard ProfilePickerRemoteNavigationPolicy.activation(
            for: focus,
            profileIDs: ids,
            canAddProfile: true,
            isManaging: true
        ) == .editProfile(second) else {
            throw HarnessError.assertion("manage Select did not dispatch the production Edit activation")
        }

        focus = ProfilePickerRemoteNavigationPolicy.movedFocus(
            from: focus,
            command: .right,
            profileIDs: ids,
            canAddProfile: true,
            isManaging: true
        )
        guard focus == .managementAction(second, .delete),
              ProfilePickerRemoteNavigationPolicy.activation(
                for: focus,
                profileIDs: ids,
                canAddProfile: true,
                isManaging: true
              ) == .deleteProfile(second) else {
            throw HarnessError.assertion("manage Right/Select did not reach and dispatch Delete")
        }

        focus = ProfilePickerRemoteNavigationPolicy.movedFocus(
            from: focus,
            command: .left,
            profileIDs: ids,
            canAddProfile: true,
            isManaging: true
        )
        guard focus == .managementAction(second, .edit) else {
            throw HarnessError.assertion("manage Left did not return to Edit: \(focus)")
        }

        let moveRightFocus = ProfilePickerRemoteFocus.managementAction(second, .moveRight)
        guard ProfilePickerRemoteNavigationPolicy.activation(
            for: moveRightFocus,
            profileIDs: ids,
            canAddProfile: true,
            isManaging: true
        ) == .moveProfile(second, direction: 1) else {
            throw HarnessError.assertion("manage Select did not dispatch Move Right")
        }
        guard ProfilePickerRemoteNavigationPolicy.movedFocus(
            from: .managementAction(first, .edit),
            command: .left,
            profileIDs: ids,
            canAddProfile: true,
            isManaging: true
        ) == .managementAction(first, .edit) else {
            throw HarnessError.assertion("manage Left did not clamp at the first enabled action")
        }
        guard ProfilePickerRemoteNavigationPolicy.movedFocus(
            from: .managementAction(second, .edit),
            command: .down,
            profileIDs: ids,
            canAddProfile: true,
            isManaging: true
        ) == .manageProfiles else {
            throw HarnessError.assertion("manage action Down did not reach Done")
        }

        try verifyProfilePickerFocusTreeTraversal()

        guard ProfilePickerRemoteNavigationPolicy.activation(
            for: .profile(second),
            profileIDs: ids,
            canAddProfile: true,
            isManaging: false
        ) == .chooseProfile(second),
        ProfilePickerRemoteNavigationPolicy.activation(
            for: .profile(second),
            profileIDs: ids,
            canAddProfile: true,
            isManaging: true
        ) == .editProfile(second),
        ProfilePickerRemoteNavigationPolicy.activation(
            for: .addProfile,
            profileIDs: ids,
            canAddProfile: true,
            isManaging: true
        ) == .addProfile,
        ProfilePickerRemoteNavigationPolicy.activation(
            for: .manageProfiles,
            profileIDs: ids,
            canAddProfile: true,
            isManaging: true
        ) == .toggleManagement else {
            throw HarnessError.assertion("production Select activation mapping changed")
        }

        guard ProfilePickerRemoteNavigationPolicy.focusAfterReorder(
            movedProfileID: second,
            updatedProfileIDs: [first, third, second],
            canAddProfile: true,
            isManaging: true
        ) == .profile(second) else {
            throw HarnessError.assertion("reorder did not retain focus on the moved profile")
        }
        guard ProfilePickerRemoteNavigationPolicy.focusAfterDeletion(
            current: .profile(second),
            deletedProfileID: second,
            previousProfileIDs: ids,
            remainingProfileIDs: [first, third],
            canAddProfile: true,
            isManaging: true
        ) == .profile(third) else {
            throw HarnessError.assertion("deleting the focused profile did not choose its nearest surviving neighbor")
        }
        guard ProfilePickerRemoteNavigationPolicy.focusAfterDeletion(
            current: .managementAction(third, .edit),
            deletedProfileID: second,
            previousProfileIDs: ids,
            remainingProfileIDs: [first, third],
            canAddProfile: true,
            isManaging: true
        ) == .managementAction(third, .edit) else {
            throw HarnessError.assertion("deleting another profile did not retain the current management action")
        }
        guard ProfilePickerRemoteNavigationPolicy.reconciledFocus(
            .managementAction(first, .delete),
            profileIDs: [first],
            canAddProfile: true,
            isManaging: true
        ) == .profile(first) else {
            throw HarnessError.assertion("a disabled post-mutation action did not fall back to its profile tile")
        }
    }

    @MainActor
    private static func runLiveScenario(context: ScenarioContext) async throws -> String {
        let outputURL = context.outputPNGURL
        let exitOutputURL = outputURL.deletingPathExtension()
            .appendingPathExtension("exit.png")
        let (pngData, exitPNGData, adultPNGData, managePNGData) = try await verifyLiveRootTransition(
            appState: context.appState,
            profile: context.profile,
            outputURL: outputURL,
            exitOutputURL: exitOutputURL
        )
        guard pngData.count > 10_000 else {
            throw HarnessError.assertion("rendered PNG too small: \(pngData.count) bytes")
        }
        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            throw HarnessError.assertion("profile picker PNG missing at \(outputURL.path)")
        }
        guard exitPNGData.count > 10_000,
              exitPNGData == pngData,
              FileManager.default.fileExists(atPath: exitOutputURL.path) else {
            throw HarnessError.assertion("profile exit preview changed pixels before the opacity-only root fade")
        }
        guard adultPNGData.count > 10_000,
              managePNGData.count > 10_000,
              adultPNGData != pngData,
              managePNGData != pngData else {
            throw HarnessError.assertion("adult, kids, and Manage Profiles captures were not distinct complete renders")
        }

        guard context.appState.activeProfile?.id == context.profile.id else {
            throw HarnessError.assertion("active profile was not switched to Kids")
        }
        guard context.appState.showProfilePicker == false else {
            throw HarnessError.assertion("profile picker did not close after selection")
        }
        guard ProfileStore.shared.lastSelectedProfileID == context.profile.id else {
            throw HarnessError.assertion("profile selection was not persisted")
        }
        try await verifyLiveInputOwnershipTransition()

        return "kidsPNG=\(outputURL.path) adultPNG=\(outputURL.deletingPathExtension().appendingPathExtension("adult.png").path) managePNG=\(outputURL.deletingPathExtension().appendingPathExtension("manage.png").path) exitPNG=\(exitOutputURL.path) bytes=\(pngData.count)/\(exitPNGData.count)/\(adultPNGData.count)/\(managePNGData.count) selected=\(context.profile.name) kidsFocused=1 manageTiles=1 liveExitPixelIdentity=1 liveRootTransition=1 rootInputShield=1 liveSearchActivationBlocked=1 liveRemoteInputBlocked=1 inputRestored=1 centeredRowLayout=1-5"
    }

    private static func reportFailure(_ error: Error) -> Never {
        FileHandle.standardError.write(Data("verify-profile-picker: FAIL rendersAndSelectsProfile: \(error)\n".utf8))
        FileHandle.standardError.write(Data("verify-profile-picker: outcome=failed passed=0/9\n".utf8))
        exit(1)
    }

    private static func makeRecordingSession(events: @escaping (String) -> Void) -> ProfileSession {
        let session = ProfileSession()
        session.hooks = ProfileSessionHooks(
            setWatchStore: { _ in events("setWatchStore") },
            configurePlayer: { events("configurePlayer") },
            applyWatchProgress: { events("applyWatchProgress") },
            recomputeFilteredItems: { events("recomputeFilteredItems") },
            recomputeProgressRows: { events("recomputeProgressRows") },
            scheduleHomeArtworkPreheat: { _, _ in events("scheduleHomeArtworkPreheat") },
            beginBackgroundScanIfNeeded: { events("beginBackgroundScanIfNeeded") },
            filteredCounts: { (0, 0) }
        )
        return session
    }

    private static func verifyKidsSelectionHookOrdering() throws {
        guard let kids = ProfileStore.shared.profiles.first(where: { $0.maturityLevel == .kids }) else {
            throw HarnessError.assertion("expected a kids profile for hook ordering")
        }

        var events: [String] = []
        var pickerVisibleAtEvent: [String: Bool] = [:]
        var session: ProfileSession!
        session = makeRecordingSession { name in
            events.append(name)
            pickerVisibleAtEvent[name] = session.showProfilePicker
        }

        session.selectProfile(kids)

        let expected = [
            "setWatchStore",
            "configurePlayer",
            "applyWatchProgress",
            "recomputeFilteredItems",
            "scheduleHomeArtworkPreheat",
            "beginBackgroundScanIfNeeded"
        ]
        guard events == expected else {
            throw HarnessError.assertion("kids selection hook order diverged: \(events)")
        }
        guard pickerVisibleAtEvent["recomputeFilteredItems"] == true else {
            throw HarnessError.assertion("kids recompute must complete before the picker hides")
        }
        guard pickerVisibleAtEvent["beginBackgroundScanIfNeeded"] == false else {
            throw HarnessError.assertion("kids background scan must start after the picker hides")
        }
        guard session.showProfilePicker == false, session.activeProfile?.id == kids.id else {
            throw HarnessError.assertion("kids selection did not settle picker/profile state")
        }
    }

    private static func verifyAdultSelectionDeferral() throws {
        guard let adult = ProfileStore.shared.profiles.first(where: { $0.maturityLevel == .adult }) else {
            throw HarnessError.assertion("expected an adult profile for deferral ordering")
        }

        var events: [String] = []
        let session = makeRecordingSession { events.append($0) }

        session.selectProfile(adult)

        guard session.showProfilePicker == false else {
            throw HarnessError.assertion("adult selection must hide the picker synchronously")
        }
        guard events == ["scheduleHomeArtworkPreheat"] else {
            throw HarnessError.assertion("adult setup must defer past selectProfile return, got \(events)")
        }

        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, !events.contains("recomputeProgressRows") {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        guard events.contains("setWatchStore"),
              events.contains("configurePlayer"),
              events.contains("beginBackgroundScanIfNeeded"),
              events.contains("applyWatchProgress"),
              events.contains("recomputeFilteredItems"),
              events.contains("recomputeProgressRows") else {
            throw HarnessError.assertion("adult deferred setup did not complete: \(events)")
        }
        guard let setupIndex = events.firstIndex(of: "setWatchStore"),
              let recomputeIndex = events.firstIndex(of: "applyWatchProgress"),
              setupIndex < recomputeIndex else {
            throw HarnessError.assertion("adult deferred setup must precede the deferred recompute: \(events)")
        }
        guard let applyIndex = events.firstIndex(of: "applyWatchProgress"),
              let filterIndex = events.firstIndex(of: "recomputeFilteredItems"),
              let progressIndex = events.firstIndex(of: "recomputeProgressRows"),
              applyIndex < filterIndex, filterIndex < progressIndex else {
            throw HarnessError.assertion("adult deferred phase must re-filter for the new profile between watch progress and progress rows (kids->adult switch must not keep the kids-filtered library): \(events)")
        }
    }

    private static func verifyAdultSwitchRestoresFullLibrary() throws {
        let appState = AppState()
        let store = ProfileStore.shared
        guard let kids = store.profiles.first(where: { $0.maturityLevel == .kids }),
              let adult = store.profiles.first(where: { $0.maturityLevel == .adult }) else {
            throw HarnessError.assertion("expected kids and adult profiles for switch restoration")
        }

        let fullMovieCount = appState.library.libraryItems.count
        let fullTVCount = appState.library.tvItems.count

        appState.selectProfile(kids)
        let kidsMovieCount = appState.library.filteredLibraryItems.count
        let kidsTVCount = appState.library.filteredTVItems.count

        appState.switchProfile()
        guard appState.showProfilePicker else {
            throw HarnessError.assertion("switchProfile did not present the picker")
        }
        appState.selectProfile(adult)

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline,
              appState.library.filteredLibraryItems.count != fullMovieCount
                || appState.library.filteredTVItems.count != fullTVCount {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        guard appState.library.filteredLibraryItems.count == fullMovieCount,
              appState.library.filteredTVItems.count == fullTVCount else {
            throw HarnessError.assertion(
                "kids->adult switch did not restore the full library: movies \(appState.library.filteredLibraryItems.count)/\(fullMovieCount) tv \(appState.library.filteredTVItems.count)/\(fullTVCount) (kids saw \(kidsMovieCount)/\(kidsTVCount))"
            )
        }
        guard appState.library.browseSnapshot.searchIndex.revisionKey.hasPrefix("\(fullMovieCount):") else {
            throw HarnessError.assertion(
                "kids->adult switch left a filtered search index: revision \(appState.library.browseSnapshot.searchIndex.revisionKey) expected movie count \(fullMovieCount)"
            )
        }
    }

    private static func verifyCenteredRowLayout() throws {
        for itemCount in 1...5 {
            let compactWidth = ProfilePickerRowLayout.groupWidth(itemCount: itemCount, isLeanBack: false)
            let compactMax = ProfilePickerRowLayout.maxWidth(isLeanBack: false)
            guard compactWidth <= compactMax else {
                throw HarnessError.assertion("compact profile row width \(compactWidth) exceeds max \(compactMax) for \(itemCount) items")
            }

            let leanBackWidth = ProfilePickerRowLayout.groupWidth(itemCount: itemCount, isLeanBack: true)
            let leanBackMax = ProfilePickerRowLayout.maxWidth(isLeanBack: true)
            guard leanBackWidth <= leanBackMax else {
                throw HarnessError.assertion("lean-back profile row width \(leanBackWidth) exceeds max \(leanBackMax) for \(itemCount) items")
            }
        }
    }

    private static func verifyProfileFocusRingGeometry() throws {
        for isLeanBack in [false, true] {
            let tileDiameter = ProfilePickerAvatarLayout.tileDiameter(isLeanBack: isLeanBack)
            let ringOutset = ProfilePickerAvatarLayout.focusRingOutset(isLeanBack: isLeanBack)
            let ringDiameter = ProfilePickerAvatarLayout.focusRingDiameter(isLeanBack: isLeanBack)
            guard tileDiameter > 0, ringOutset > 0 else {
                throw HarnessError.assertion("profile tile and focus-ring outset must be positive")
            }
            guard abs(ringDiameter - (tileDiameter + 2 * ringOutset)) < 0.001 else {
                throw HarnessError.assertion(
                    "profile focus ring must hug the avatar outside its tile bounds: tile=\(tileDiameter) outset=\(ringOutset) ring=\(ringDiameter)"
                )
            }
        }
    }

    private static func verifyProfileExitTransitionPolicy() throws {
        guard ProfileExitTransitionPolicy.rootTransition == .opacityOnly,
              ProfileExitTransitionPolicy.scale == 1,
              ProfileExitTransitionPolicy.saturation == 1 else {
            throw HarnessError.assertion("profile exit must be an opacity-only in-place crossfade")
        }
        guard ProfileExitTransitionPolicy.retainsFocusedRing else {
            throw HarnessError.assertion("profile exit must retain the focused amethyst ring until replacement")
        }
        guard ProfileExitTransitionPolicy.duration >= 0.20,
              ProfileExitTransitionPolicy.duration <= 0.35 else {
            throw HarnessError.assertion("profile exit duration must remain one gentle tokenized beat")
        }
        guard ProfileExitTransitionPolicy.acceptsInput(isExitInFlight: false),
              !ProfileExitTransitionPolicy.acceptsInput(isExitInFlight: true) else {
            throw HarnessError.assertion("profile exit must lock pointer and KeyCatcher input while fading")
        }
    }

    @MainActor
    private static func verifyLiveInputOwnershipTransition() async throws {
        let size = NSSize(width: 960, height: 540)
        let appState = AppState(skipPersistenceForHarness: true)
        appState.router.focusSidebar()
        let rootHost = NSHostingView(
            rootView: ContentView(appState: appState)
                .frame(width: size.width, height: size.height)
        )
        rootHost.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = rootHost
        guard let visibleFrame = NSScreen.main?.visibleFrame else {
            throw HarnessError.assertion("profile input ownership window has no Aqua screen")
        }
        window.setFrame(
            NSRect(
                x: visibleFrame.midX - size.width / 2,
                y: visibleFrame.midY - size.height / 2,
                width: size.width,
                height: size.height
            ),
            display: false
        )
        guard window.frame.intersects(visibleFrame) else {
            throw HarnessError.assertion("profile input ownership window was not placed on the Aqua screen")
        }
        defer {
            window.orderOut(nil)
            window.close()
        }

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        try await Task.sleep(nanoseconds: 200_000_000)
        for candidate in NSApp.windows where candidate !== window {
            candidate.orderOut(nil)
        }
        window.makeKeyAndOrderFront(nil)
        try await waitForKeyWindow(window)
        rootHost.layoutSubtreeIfNeeded()

        try sendRemoteKey(.select, to: window)
        guard let exitSelectionID = appState.profileExitSelectionID else {
            throw HarnessError.assertion("live picker select did not start profile exit")
        }
        let routeDuringExit = appState.router.selectedItem
        let focusDuringExit = appState.router.focusedSidebarItem
        NotificationCenter.default.post(name: .marqueeActivateSearch, object: nil)
        await Task.yield()
        guard appState.router.selectedItem == routeDuringExit,
              appState.router.focusedSidebarItem == focusDuringExit else {
            throw HarnessError.assertion("search activation was not blocked during profile exit")
        }
        try sendRemoteKey(.down, to: window)
        guard appState.profileExitSelectionID == exitSelectionID,
              appState.router.selectedItem == routeDuringExit,
              appState.router.focusedSidebarItem == focusDuringExit else {
            throw HarnessError.assertion("key-window input was not blocked during profile exit")
        }

        try await Task.sleep(
            nanoseconds: UInt64((ProfileExitTransitionPolicy.duration + 0.08) * 1_000_000_000)
        )
        rootHost.layoutSubtreeIfNeeded()
        await Task.yield()
        guard !appState.isProfileExitInFlight else {
            throw HarnessError.assertion("profile exit token did not clear before input restoration proof")
        }
        for candidate in NSApp.windows where candidate !== window {
            candidate.orderOut(nil)
        }
        window.makeKeyAndOrderFront(nil)
        await Task.yield()
        let focusAfterExit = appState.router.focusedSidebarItem
        try sendRemoteKey(.down, to: window)
        await Task.yield()
        guard appState.router.focusedSidebarItem != focusAfterExit else {
            throw HarnessError.assertion("incoming app shell did not handle live remote input after profile exit")
        }
    }

    @MainActor
    private static func waitForKeyWindow(_ window: NSWindow) async throws {
        let deadline = Date().addingTimeInterval(keyWindowWaitTimeout)
        while shouldContinueKeyWindowWait(
            now: Date(),
            deadline: deadline,
            isKeyWindow: window.isKeyWindow
        ) {
            await Task.yield()
            try await Task.sleep(nanoseconds: keyWindowWaitPollNanoseconds)
        }
        guard window.isKeyWindow else {
            throw HarnessError.assertion(
                "profile input ownership window did not become key before \(keyWindowWaitTimeout)s: "
                + "appActive=\(NSApp.isActive) visible=\(window.isVisible) "
                + "occluded=\(window.occlusionState.contains(.visible) == false) main=\(window.isMainWindow) "
                + "windowNumber=\(window.windowNumber)"
            )
        }
    }

    private static func shouldContinueKeyWindowWait(
        now: Date,
        deadline: Date,
        isKeyWindow: Bool
    ) -> Bool {
        !isKeyWindow && now < deadline
    }

    private static func verifyProfileWindowLifecycleWaitPolicy() throws {
        guard keyWindowWaitTimeout > 0,
              keyWindowWaitPollNanoseconds > 0,
              Double(keyWindowWaitPollNanoseconds) / 1_000_000_000 < keyWindowWaitTimeout else {
            throw HarnessError.assertion("profile key-window wait must poll within a positive bounded deadline")
        }

        let start = Date(timeIntervalSinceReferenceDate: 10)
        let deadline = start.addingTimeInterval(keyWindowWaitTimeout)
        guard shouldContinueKeyWindowWait(now: start, deadline: deadline, isKeyWindow: false),
              !shouldContinueKeyWindowWait(now: deadline, deadline: deadline, isKeyWindow: false),
              !shouldContinueKeyWindowWait(now: start, deadline: deadline, isKeyWindow: true) else {
            throw HarnessError.assertion("profile key-window wait did not honor key state and deadline boundaries")
        }
    }

    @MainActor
    private static func verifyLiveRootTransition(
        appState: AppState,
        profile: UserProfile,
        outputURL: URL,
        exitOutputURL: URL
    ) async throws -> (before: Data, during: Data, adult: Data, manage: Data) {
        let size = NSSize(width: 960, height: 540)
        let picker = ProfilePickerView(
            appState: appState,
            library: appState.library,
            initialRemoteFocusProfileID: profile.id
        )
            .environment(\.leanBackMode, false)
            .frame(width: size.width, height: size.height)
        let pickerHost = NSHostingView(rootView: picker)
        pickerHost.frame = NSRect(origin: .zero, size: size)

        let root = ContentView(appState: appState)
            .frame(width: size.width, height: size.height)
        let rootHost = NSHostingView(rootView: root)
        rootHost.frame = NSRect(origin: .zero, size: size)

        let rootWindow = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        rootWindow.isReleasedWhenClosed = false
        rootWindow.contentView = rootHost
        rootWindow.orderBack(nil)
        defer {
            rootWindow.orderOut(nil)
            rootWindow.close()
        }

        pickerHost.layoutSubtreeIfNeeded()
        rootWindow.layoutIfNeeded()
        rootHost.layoutSubtreeIfNeeded()
        let before = try render(host: pickerHost, outputURL: outputURL)
        guard let adultProfile = ProfileStore.shared.profiles.first(where: { $0.maturityLevel == .adult }) else {
            throw HarnessError.assertion("adult profile missing for palette capture")
        }
        let adultPicker = ProfilePickerView(
            appState: appState,
            library: appState.library,
            initialRemoteFocusProfileID: adultProfile.id
        )
            .environment(\.leanBackMode, false)
            .frame(width: size.width, height: size.height)
        let adultHost = NSHostingView(rootView: adultPicker)
        adultHost.frame = NSRect(origin: .zero, size: size)
        adultHost.layoutSubtreeIfNeeded()
        let adult = try render(
            host: adultHost,
            outputURL: outputURL.deletingPathExtension().appendingPathExtension("adult.png")
        )

        let managePicker = ProfilePickerView(
            appState: appState,
            library: appState.library,
            initialRemoteFocusProfileID: profile.id,
            initiallyManaging: true
        )
            .environment(\.leanBackMode, false)
            .frame(width: size.width, height: size.height)
        let manageHost = NSHostingView(rootView: managePicker)
        manageHost.frame = NSRect(origin: .zero, size: size)
        manageHost.layoutSubtreeIfNeeded()
        let manage = try render(
            host: manageHost,
            outputURL: outputURL.deletingPathExtension().appendingPathExtension("manage.png")
        )
        let rootBefore = try render(
            host: rootHost,
            outputURL: outputURL.appendingPathExtension("root-before.png")
        )

        var selectionStarted = false
        withAnimation(MarqueeTheme.profileExitAnimation) {
            selectionStarted = appState.beginProfileExitSelection(profile)
        }
        guard selectionStarted,
              appState.isProfileExitInFlight,
              appState.profileExitSelectionID == profile.id,
              !appState.beginProfileExitSelection(profile) else {
            throw HarnessError.assertion("shared root profile-exit authority did not lock the full transition")
        }
        guard !ProfileExitTransitionPolicy.acceptsInput(
            isExitInFlight: appState.isProfileExitInFlight
        ) else {
            throw HarnessError.assertion("incoming app shell accepted input during the profile crossfade")
        }
        guard ProfileExitTransitionPolicy.retainsProfileInputOwnership(
            showProfilePicker: appState.showProfilePicker,
            isExitInFlight: appState.isProfileExitInFlight
        ) else {
            throw HarnessError.assertion("incoming app shell stole remote ownership during the profile crossfade")
        }

        try await Task.sleep(
            nanoseconds: UInt64(ProfileExitTransitionPolicy.duration / 2 * 1_000_000_000)
        )
        pickerHost.layoutSubtreeIfNeeded()
        rootHost.layoutSubtreeIfNeeded()
        let during = try render(host: pickerHost, outputURL: exitOutputURL)
        let rootDuring = try render(
            host: rootHost,
            outputURL: outputURL.appendingPathExtension("root-during.png")
        )
        guard during == before else {
            throw HarnessError.assertion("live outgoing picker changed pixels during profile/library mutation")
        }
        guard rootDuring != rootBefore else {
            throw HarnessError.assertion("live ContentView did not enter its picker-to-shell transition")
        }

        try await Task.sleep(
            nanoseconds: UInt64((ProfileExitTransitionPolicy.duration + 0.08) * 1_000_000_000)
        )
        rootHost.layoutSubtreeIfNeeded()
        let rootAfter = try render(
            host: rootHost,
            outputURL: outputURL.appendingPathExtension("root-after.png")
        )
        guard !appState.isProfileExitInFlight,
              appState.profileExitSelectionID == nil,
              appState.profileExitLibraryCounts == nil,
              rootAfter != rootBefore,
              ProfileExitTransitionPolicy.acceptsInput(isExitInFlight: appState.isProfileExitInFlight),
              !ProfileExitTransitionPolicy.retainsProfileInputOwnership(
                showProfilePicker: appState.showProfilePicker,
                isExitInFlight: appState.isProfileExitInFlight
        ) else {
            throw HarnessError.assertion("root input ownership did not restore after profile exit")
        }
        return (before, during, adult, manage)
    }

    @MainActor
    private static func sendRemoteKey(
        _ command: RemoteCommand,
        to window: NSWindow
    ) throws {
        let keyCode: UInt16
        let characters: String
        switch command {
        case .down:
            keyCode = 125
            characters = "\u{F701}"
        case .right:
            keyCode = 124
            characters = "\u{F703}"
        case .select:
            keyCode = 36
            characters = "\r"
        default:
            throw HarnessError.assertion("unsupported profile-exit input probe command \(command)")
        }
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ) else {
            throw HarnessError.assertion("could not create profile-exit input probe event")
        }
        NSApp.sendEvent(event)
    }

    private static func render(
        host: NSView,
        outputURL: URL
    ) throws -> Data {
        host.layoutSubtreeIfNeeded()

        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw HarnessError.assertion("could not allocate profile picker bitmap")
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw HarnessError.assertion("could not encode profile picker PNG")
        }
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: outputURL, options: .atomic)
        return data
    }

    private struct ArtifactPaths {
        let outputPNGURL: URL
        let completionArtifactURL: URL
    }

    private static func resolvedArtifactPaths(
        arguments: [String],
        environment: [String: String]
    ) throws -> ArtifactPaths {
        if let override = environment[profilePickerPNGEnvironmentKey],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let outputPNGURL = URL(fileURLWithPath: override)
            let baseName = outputPNGURL.deletingPathExtension().lastPathComponent
            return ArtifactPaths(
                outputPNGURL: outputPNGURL,
                completionArtifactURL: outputPNGURL.deletingLastPathComponent()
                    .appendingPathComponent("\(baseName)-result.txt")
            )
        }

        guard let outputDirectory = argumentValue(
            after: qaOutputDirectoryArgument,
            in: arguments
        )?.trimmingCharacters(in: .whitespacesAndNewlines),
              !outputDirectory.isEmpty else {
            throw HarnessError.assertion(
                "profile picker requires MARQUEE_VERIFY_PROFILE_PICKER_PNG or --qa-output-dir"
            )
        }

        let directoryURL = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        return ArtifactPaths(
            outputPNGURL: directoryURL.appendingPathComponent("profile-picker.png"),
            completionArtifactURL: directoryURL.appendingPathComponent("profile-picker-result.txt")
        )
    }

    private static func argumentValue(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }

    private static func verifyArtifactPathResolution() throws {
        let argumentDirectory = "/qa/profile-picker-argument"
        let argumentPaths = try resolvedArtifactPaths(
            arguments: [qaOutputDirectoryArgument, argumentDirectory],
            environment: [:]
        )
        guard argumentPaths.outputPNGURL.path == "\(argumentDirectory)/profile-picker.png",
              argumentPaths.completionArtifactURL.path == "\(argumentDirectory)/profile-picker-result.txt" else {
            throw HarnessError.assertion("--qa-output-dir did not resolve profile picker artifact names")
        }

        let fallbackPaths = try resolvedArtifactPaths(
            arguments: [qaOutputDirectoryArgument, argumentDirectory],
            environment: [profilePickerPNGEnvironmentKey: " \t"]
        )
        guard fallbackPaths.outputPNGURL == argumentPaths.outputPNGURL,
              fallbackPaths.completionArtifactURL == argumentPaths.completionArtifactURL else {
            throw HarnessError.assertion("an empty profile picker environment override blocked argument fallback")
        }

        let overridePath = "/qa/profile-picker-override.png"
        let overridePaths = try resolvedArtifactPaths(
            arguments: [qaOutputDirectoryArgument, argumentDirectory],
            environment: [profilePickerPNGEnvironmentKey: overridePath]
        )
        guard overridePaths.outputPNGURL.path == overridePath,
              overridePaths.completionArtifactURL.path == "/qa/profile-picker-override-result.txt" else {
            throw HarnessError.assertion("profile picker environment override did not retain precedence")
        }

        guard (try? resolvedArtifactPaths(arguments: [], environment: [:])) == nil,
              (try? resolvedArtifactPaths(
                arguments: [qaOutputDirectoryArgument],
                environment: [:]
              )) == nil else {
            throw HarnessError.assertion("profile picker artifact resolution accepted an undeclared channel")
        }
    }

    private static func writeCompletionArtifact(at url: URL?) throws {
        guard let url else { return }

        let content = "schema=marquee-profile-picker-result-v1\noutcome=verified\npassed=9/9\n"
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(content.utf8).write(to: url, options: .atomic)
    }

    private static func writeFailureArtifact(at url: URL?, error: Error) {
        guard let url else { return }

        let diagnostic = String(describing: error)
            .unicodeScalars
            .reduce(into: "") { result, scalar in
                if CharacterSet.controlCharacters.contains(scalar)
                    || CharacterSet.whitespacesAndNewlines.contains(scalar) {
                    if !result.hasSuffix(" ") {
                        result.append(" ")
                    }
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let content = "schema=marquee-profile-picker-result-v1\noutcome=failed\nmessage=\(diagnostic)\n"

        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(content.utf8).write(to: url, options: .atomic)
        } catch {
            FileHandle.standardError.write(
                Data("verify-profile-picker: could not write failure artifact: \(error)\n".utf8)
            )
        }
    }

    private enum HarnessError: Error, CustomStringConvertible {
        case assertion(String)

        var description: String {
            switch self {
            case .assertion(let message): return message
            }
        }
    }
}

#endif
