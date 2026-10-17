//
//  VerifyProfilePickerFocusTreeHarness.swift
//  Marquee
//
//  DEBUG-only verification for the profile picker FocusEngine tree.
//  Activated by `--verify-profile-picker-focus-tree`.
//  This harness runs the pure traversal assertions without a live NSHostingView,
//  so it works on the Linux swiftc fallback.
//

#if DEBUG

import Foundation

enum VerifyProfilePickerFocusTreeHarness {
    static let launchArgument = "--verify-profile-picker-focus-tree"

    static func runIfRequested() {
        guard CommandLine.arguments.contains(launchArgument) else { return }

        do {
            try runScenario()
            FileHandle.standardError.write(Data("verify-profile-picker-focus-tree: PASS focusTreeTraversal: all assertions passed\n".utf8))
            FileHandle.standardError.write(Data("verify-profile-picker-focus-tree: outcome=verified passed=10/10\n".utf8))
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("verify-profile-picker-focus-tree: FAIL focusTreeTraversal: \(error)\n".utf8))
            FileHandle.standardError.write(Data("verify-profile-picker-focus-tree: outcome=failed passed=0/10\n".utf8))
            exit(1)
        }
    }

    private static func runScenario() throws {
        try verifyProfilePickerFocusTreeTraversal()
        try verifyProfileManagementNavigation()
    }

    // MARK: - Focus Tree Traversal (extracted from VerifyProfilePickerHarness)

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

    // MARK: - Management Navigation

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

    // MARK: - Error Type

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
