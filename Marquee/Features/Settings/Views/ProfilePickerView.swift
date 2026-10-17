import SwiftUI

// MARK: - Profile Picker View

enum ProfilePickerRemoteFocus: Equatable {
    case profile(UUID)
    case managementAction(UUID, ProfileManagementRemoteAction)
    case addProfile
    case manageProfiles
}

enum ProfilePickerRemoteActivation: Equatable {
    case chooseProfile(UUID)
    case editProfile(UUID)
    case deleteProfile(UUID)
    case moveProfile(UUID, direction: Int)
    case addProfile
    case toggleManagement
}

struct ProfilePickerManagementActionGeometry: Equatable {
    let buttonSize: CGFloat
    let spacing: CGFloat

    var width: CGFloat {
        4 * buttonSize + 3 * spacing
    }
}

struct ProfilePickerManagementRowGeometry: Equatable {
    let availableWidth: CGFloat
    let horizontalInset: CGFloat
    let itemCount: Int
    let tileWidth: CGFloat
    let spacing: CGFloat

    var groupWidth: CGFloat {
        guard itemCount > 0 else { return 0 }
        return CGFloat(itemCount) * tileWidth
            + CGFloat(itemCount - 1) * spacing
    }

    var fitsAvailableWidth: Bool {
        groupWidth + 2 * horizontalInset <= availableWidth + 0.5
    }
}

enum ProfilePickerManagementRowLayout {
    static let supportedMinimumWidth: CGFloat = 1100
    static let horizontalInset: CGFloat = 32
    static let minimumTileWidth: CGFloat = 184
    static let minimumSpacing: CGFloat = 12
    static let tileContentInset: CGFloat = 16

    static func resolved(
        itemCount: Int,
        availableWidth: CGFloat
    ) -> ProfilePickerManagementRowGeometry {
        let count = max(0, itemCount)
        guard count > 0 else {
            return ProfilePickerManagementRowGeometry(
                availableWidth: max(0, availableWidth),
                horizontalInset: horizontalInset,
                itemCount: 0,
                tileWidth: 0,
                spacing: 0
            )
        }

        let width = max(0, availableWidth)
        let usableWidth = max(0, width - 2 * horizontalInset)
        let gaps = max(0, count - 1)
        var spacing: CGFloat = 0

        if gaps > 0 {
            let spacingAtMinimumTileWidth = (
                usableWidth - CGFloat(count) * minimumTileWidth
            ) / CGFloat(gaps)
            spacing = min(
                ProfileManagementLayoutPolicy.rowSpacing,
                max(minimumSpacing, spacingAtMinimumTileWidth)
            )
        }

        var tileWidth = (
            usableWidth - CGFloat(gaps) * spacing
        ) / CGFloat(count)
        tileWidth = min(ProfileManagementLayoutPolicy.tileWidth, max(0, tileWidth))

        // Widths below the supported minimum still stay bounded rather than
        // forcing the row past its container. The supported 1100-point layout
        // retains at least `minimumTileWidth` for all five targets.
        if gaps > 0, tileWidth < minimumTileWidth {
            spacing = max(
                0,
                min(
                    spacing,
                    (usableWidth - CGFloat(count) * minimumTileWidth) / CGFloat(gaps)
                )
            )
            tileWidth = min(
                ProfileManagementLayoutPolicy.tileWidth,
                max(0, (usableWidth - CGFloat(gaps) * spacing) / CGFloat(count))
            )
        }

        return ProfilePickerManagementRowGeometry(
            availableWidth: width,
            horizontalInset: horizontalInset,
            itemCount: count,
            tileWidth: tileWidth,
            spacing: spacing
        )
    }

    static func actionGeometry(tileWidth: CGFloat) -> ProfilePickerManagementActionGeometry {
        let usableWidth = max(0, tileWidth - 2 * tileContentInset)
        let minimumButtonSize = min(26, usableWidth / 4)
        let spacing = min(
            ProfileManagementLayoutPolicy.actionSpacing,
            max(0, (usableWidth - 4 * minimumButtonSize) / 3)
        )
        let buttonSize = min(32, max(0, (usableWidth - 3 * spacing) / 4))
        return ProfilePickerManagementActionGeometry(
            buttonSize: buttonSize,
            spacing: spacing
        )
    }
}

enum ProfilePickerRemoteNavigationPolicy {
    static func topRowTargets(
        profileIDs: [UUID],
        canAddProfile: Bool
    ) -> [ProfilePickerRemoteFocus] {
        var targets = profileIDs.map(ProfilePickerRemoteFocus.profile)
        if canAddProfile {
            targets.append(.addProfile)
        }
        return targets
    }

    static func enabledManagementActions(
        for profileID: UUID,
        profileIDs: [UUID]
    ) -> [ProfileManagementRemoteAction] {
        guard let index = profileIDs.firstIndex(of: profileID) else { return [] }
        return ProfileManagementRemoteNavigationPolicy.enabledActions(
            profileIndex: index,
            profileCount: profileIDs.count
        )
    }

    static func reconciledFocus(
        _ current: ProfilePickerRemoteFocus?,
        profileIDs: [UUID],
        canAddProfile: Bool,
        isManaging: Bool
    ) -> ProfilePickerRemoteFocus {
        if let current {
            switch current {
            case .profile(let id):
                if profileIDs.contains(id) {
                    return current
                }
            case .managementAction(let id, let action):
                if profileIDs.contains(id) {
                    let actions = enabledManagementActions(for: id, profileIDs: profileIDs)
                    if isManaging, actions.contains(action) {
                        return current
                    }
                    return .profile(id)
                }
            case .addProfile:
                if canAddProfile {
                    return current
                }
            case .manageProfiles:
                return current
            }
        }

        return topRowTargets(
            profileIDs: profileIDs,
            canAddProfile: canAddProfile
        ).first ?? .manageProfiles
    }

    static func movedFocus(
        from current: ProfilePickerRemoteFocus?,
        command: RemoteCommand,
        profileIDs: [UUID],
        canAddProfile: Bool,
        isManaging: Bool
    ) -> ProfilePickerRemoteFocus {
        let focus = reconciledFocus(
            current,
            profileIDs: profileIDs,
            canAddProfile: canAddProfile,
            isManaging: isManaging
        )
        let topRow = topRowTargets(
            profileIDs: profileIDs,
            canAddProfile: canAddProfile
        )

        guard let direction = focusDirection(for: command) else { return focus }

        // Left and right on the manage control wrap into the opposite end of the
        // top row. The engine stops at a container edge, so the picker maps that
        // boundary rather than teaching every engine surface to wrap.
        if focus == .manageProfiles, direction == .left || direction == .right {
            guard !topRow.isEmpty else { return .manageProfiles }
            return direction == .left ? topRow[topRow.count - 1] : topRow[0]
        }

        let owner = managementOwner(for: focus, isManaging: isManaging)
        let actions = owner.map { enabledManagementActions(for: $0, profileIDs: profileIDs) } ?? []

        guard let origin = focusNode(for: focus, topRow: topRow, actions: actions) else {
            return topRow.first ?? .manageProfiles
        }

        // Seeded entry keeps vertical moves scoped to the profile that owns the
        // management row: remembered children outrank the engine's positional
        // hint, so Down enters that profile's first enabled action and Up
        // returns to that same profile rather than a same-index neighbour.
        var state = FocusEngineState(focused: origin)
        if let owner,
           !actions.isEmpty,
           let ownerIndex = topRow.firstIndex(of: .profile(owner)) {
            state.rememberedChildByContainer[FocusIDs.topRow] = FocusIDs.topRowItem(ownerIndex)
            state.rememberedChildByContainer[FocusIDs.actions] = FocusIDs.action(0)
        }

        let tree = focusTree(topRow: topRow, actions: actions)
        let moved = FocusEngine(root: tree).move(direction, state: state).state.focused
        guard moved != origin else { return focus }

        return resolvedFocus(for: moved, topRow: topRow, actions: actions, owner: owner) ?? focus
    }

    // MARK: - Engine Tree

    private enum FocusIDs {
        static let root: FocusNodeID = "profile-picker-root"
        static let topRow: FocusNodeID = "profile-picker-top-row"
        static let actions: FocusNodeID = "profile-picker-actions"
        static let manageProfiles: FocusNodeID = "profile-picker-manage"

        static func topRowItem(_ index: Int) -> FocusNodeID {
            FocusNodeID("profile-picker-top:\(index)")
        }

        static func action(_ index: Int) -> FocusNodeID {
            FocusNodeID("profile-picker-action:\(index)")
        }
    }

    private static func focusDirection(for command: RemoteCommand) -> FocusDirection? {
        switch command {
        case .left: return .left
        case .right: return .right
        case .up: return .up
        case .down: return .down
        case .select, .back: return nil
        }
    }

    /// The management row belongs to one profile, so it joins the tree only
    /// while that profile or one of its actions holds focus.
    private static func managementOwner(
        for focus: ProfilePickerRemoteFocus,
        isManaging: Bool
    ) -> UUID? {
        guard isManaging else { return nil }
        switch focus {
        case .profile(let id): return id
        case .managementAction(let id, _): return id
        case .addProfile, .manageProfiles: return nil
        }
    }

    private static func focusTree(
        topRow: [ProfilePickerRemoteFocus],
        actions: [ProfileManagementRemoteAction]
    ) -> FocusNode {
        var children: [FocusNode] = []
        if !topRow.isEmpty {
            children.append(
                FocusNode(
                    FocusIDs.topRow,
                    kind: .container(.grid(columns: topRow.count)),
                    children: topRow.indices.map {
                        FocusNode(FocusIDs.topRowItem($0), kind: .leaf)
                    }
                )
            )
        }
        if !actions.isEmpty {
            children.append(
                FocusNode(
                    FocusIDs.actions,
                    kind: .container(.grid(columns: actions.count)),
                    children: actions.indices.map {
                        FocusNode(FocusIDs.action($0), kind: .leaf)
                    }
                )
            )
        }
        children.append(FocusNode(FocusIDs.manageProfiles, kind: .leaf))
        return FocusNode(FocusIDs.root, kind: .container(.vertical), children: children)
    }

    private static func focusNode(
        for focus: ProfilePickerRemoteFocus,
        topRow: [ProfilePickerRemoteFocus],
        actions: [ProfileManagementRemoteAction]
    ) -> FocusNodeID? {
        switch focus {
        case .profile, .addProfile:
            guard let index = topRow.firstIndex(of: focus) else { return nil }
            return FocusIDs.topRowItem(index)
        case .managementAction(_, let action):
            guard let index = actions.firstIndex(of: action) else { return nil }
            return FocusIDs.action(index)
        case .manageProfiles:
            return FocusIDs.manageProfiles
        }
    }

    private static func resolvedFocus(
        for node: FocusNodeID,
        topRow: [ProfilePickerRemoteFocus],
        actions: [ProfileManagementRemoteAction],
        owner: UUID?
    ) -> ProfilePickerRemoteFocus? {
        if node == FocusIDs.manageProfiles { return .manageProfiles }
        if let index = topRow.indices.first(where: { FocusIDs.topRowItem($0) == node }) {
            return topRow[index]
        }
        if let owner,
           let index = actions.indices.first(where: { FocusIDs.action($0) == node }) {
            return .managementAction(owner, actions[index])
        }
        return nil
    }

    static func activation(
        for current: ProfilePickerRemoteFocus?,
        profileIDs: [UUID],
        canAddProfile: Bool,
        isManaging: Bool
    ) -> ProfilePickerRemoteActivation? {
        guard let current else { return nil }
        switch current {
        case .profile(let id):
            guard profileIDs.contains(id) else { return nil }
            return isManaging ? .editProfile(id) : .chooseProfile(id)
        case .managementAction(let id, let action):
            guard isManaging,
                  enabledManagementActions(for: id, profileIDs: profileIDs).contains(action) else {
                return nil
            }
            switch action {
            case .moveLeft:
                return .moveProfile(id, direction: -1)
            case .edit:
                return .editProfile(id)
            case .delete:
                return .deleteProfile(id)
            case .moveRight:
                return .moveProfile(id, direction: 1)
            }
        case .addProfile:
            return canAddProfile ? .addProfile : nil
        case .manageProfiles:
            return .toggleManagement
        }
    }

    static func focusAfterReorder(
        movedProfileID: UUID,
        updatedProfileIDs: [UUID],
        canAddProfile: Bool,
        isManaging: Bool
    ) -> ProfilePickerRemoteFocus {
        guard updatedProfileIDs.contains(movedProfileID) else {
            return reconciledFocus(
                nil,
                profileIDs: updatedProfileIDs,
                canAddProfile: canAddProfile,
                isManaging: isManaging
            )
        }
        return .profile(movedProfileID)
    }

    static func focusAfterDeletion(
        current: ProfilePickerRemoteFocus?,
        deletedProfileID: UUID,
        previousProfileIDs: [UUID],
        remainingProfileIDs: [UUID],
        canAddProfile: Bool,
        isManaging: Bool
    ) -> ProfilePickerRemoteFocus {
        let focusedProfileID: UUID? = {
            switch current {
            case .some(.profile(let id)), .some(.managementAction(let id, _)):
                return id
            case .some(.addProfile), .some(.manageProfiles), .none:
                return nil
            }
        }()

        if focusedProfileID == deletedProfileID {
            if let deletedIndex = previousProfileIDs.firstIndex(of: deletedProfileID),
               !remainingProfileIDs.isEmpty {
                return .profile(
                    remainingProfileIDs[min(deletedIndex, remainingProfileIDs.count - 1)]
                )
            }
            return reconciledFocus(
                nil,
                profileIDs: remainingProfileIDs,
                canAddProfile: canAddProfile,
                isManaging: isManaging
            )
        }

        return reconciledFocus(
            current,
            profileIDs: remainingProfileIDs,
            canAddProfile: canAddProfile,
            isManaging: isManaging
        )
    }
}

enum ProfilePickerRowLayout {
    static func cardWidth(isLeanBack: Bool) -> CGFloat {
        MarqueeTheme.scaled(150, leanBack: 220, isLeanBack: isLeanBack)
    }

    static func itemSpacing(isLeanBack: Bool) -> CGFloat {
        MarqueeTheme.scaled(24, leanBack: 38, isLeanBack: isLeanBack)
    }

    static func maxWidth(isLeanBack: Bool) -> CGFloat {
        MarqueeTheme.scaled(920, leanBack: 1280, isLeanBack: isLeanBack)
    }

    static func groupWidth(itemCount: Int, isLeanBack: Bool) -> CGFloat {
        guard itemCount > 0 else { return 0 }
        return CGFloat(itemCount) * cardWidth(isLeanBack: isLeanBack)
            + CGFloat(itemCount - 1) * itemSpacing(isLeanBack: isLeanBack)
    }
}

enum ProfilePickerAvatarLayout {
    static func tileDiameter(isLeanBack: Bool) -> CGFloat {
        MarqueeTheme.scaled(130, leanBack: 190, isLeanBack: isLeanBack)
    }

    static func focusRingOutset(isLeanBack: Bool) -> CGFloat {
        MarqueeTheme.scaled(4, leanBack: 6, isLeanBack: isLeanBack)
    }

    static func focusRingDiameter(isLeanBack: Bool) -> CGFloat {
        tileDiameter(isLeanBack: isLeanBack)
            + 2 * focusRingOutset(isLeanBack: isLeanBack)
    }

    static func focusRingLineWidth(isLeanBack: Bool) -> CGFloat {
        MarqueeTheme.scaled(2.5, leanBack: 3.5, isLeanBack: isLeanBack)
    }
}

struct ProfilePickerView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var library: LibraryState
    @ObservedObject private var profileStore = ProfileStore.shared

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.leanBackMode) private var leanBackMode
    @State private var hoveredID: UUID?
    @State private var isManaging: Bool = false
    @State private var editingProfile: UserProfile?
    @State private var showingEditor: Bool = false
    @State private var characterAvatars: [CharacterAvatar] = []
    @State private var avatarsLoaded: Bool = false
    @State private var remoteFocus: ProfilePickerRemoteFocus?
    @State private var isExitCommitted = false
    @State private var profilePendingDeletion: UserProfile?
    init(
        appState: AppState,
        library: LibraryState,
        initialRemoteFocusProfileID: UUID? = nil
    ) {
        self.appState = appState
        self.library = library
        _remoteFocus = State(
            initialValue: initialRemoteFocusProfileID.map(ProfilePickerRemoteFocus.profile)
        )
    }

    #if DEBUG
    init(
        appState: AppState,
        library: LibraryState,
        initialRemoteFocusProfileID: UUID?,
        initiallyManaging: Bool
    ) {
        self.appState = appState
        self.library = library
        _remoteFocus = State(
            initialValue: initialRemoteFocusProfileID.map(ProfilePickerRemoteFocus.profile)
        )
        _isManaging = State(initialValue: initiallyManaging)
    }
    #endif

    private var profiles: [UserProfile] {
        profileStore.profiles
    }

    private var canAddProfile: Bool {
        profiles.count < 5
    }

    private var profileIDs: [UUID] {
        profiles.map(\.id)
    }

    private var librarySummary: String {
        let movieCount = appState.profileExitLibraryCounts?.movies
            ?? library.filteredLibraryItems.count
        let episodeCount = appState.profileExitLibraryCounts?.episodes
            ?? library.filteredTVItems.count
        let movieLabel = "\(movieCount) movie\(movieCount == 1 ? "" : "s")"
        let episodeLabel = "\(episodeCount) episode\(episodeCount == 1 ? "" : "s")"
        return "\(movieLabel)  /  \(episodeLabel)"
    }

    private var topRowFocusTargets: [ProfilePickerRemoteFocus] {
        ProfilePickerRemoteNavigationPolicy.topRowTargets(
            profileIDs: profileIDs,
            canAddProfile: canAddProfile
        )
    }

    var body: some View {
        ZStack {
            pickerBackdrop

            VStack(spacing: MarqueeTheme.scaled(40, leanBack: 60, isLeanBack: leanBackMode)) {
                Spacer()

                headerBlock

                profileRow

                manageProfilesButton

                Spacer()
            }

            if showingEditor {
                profileEditorOverlay
            }

            KeyCatcher(onKeyDown: handleRemoteKey)
                .frame(width: 0, height: 0)
        }
        .allowsHitTesting(!isExitCommitted)
        .onAppear {
            AudioIdentityService.shared.playLaunchIdentIfNeeded()
            reconcileRemoteFocus()
            guard !avatarsLoaded else { return }
            avatarsLoaded = true
            characterAvatars = AvatarService.shared.cachedAvatars()
            guard UserSettings.shared.onlineMetadataEnabled else { return }
            Task {
                let fetched = await AvatarService.shared.fetchAllAvatars(allowNetwork: true)
                await MainActor.run { characterAvatars = fetched }
            }
        }
        .onReceive(profileStore.$profiles) { _ in
            reconcileRemoteFocus()
        }
        .alert(item: $profilePendingDeletion) { profile in
            Alert(
                title: Text("Delete \(profile.name)?"),
                message: Text("This removes the profile from Marquee."),
                primaryButton: .destructive(Text("Delete")) {
                    deleteProfile(profile)
                },
                secondaryButton: .cancel()
            )
        }
    }

    // MARK: - Header

    private var pickerBackdrop: some View {
        ZStack {
            MarqueeTheme.background
            LinearGradient(
                colors: [
                    MarqueeTheme.accentPrimary.opacity(0.24),
                    Color.clear,
                    Color.black.opacity(0.36),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            LinearGradient(
                colors: [
                    Color.black.opacity(0.62),
                    Color.clear,
                    Color.black.opacity(0.68),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }

    private var headerBlock: some View {
        VStack(spacing: MarqueeTheme.scaled(10, leanBack: 16, isLeanBack: leanBackMode)) {
            Text("MARQUEE")
                .font(.system(size: MarqueeTheme.scaled(34, leanBack: 52, isLeanBack: leanBackMode), weight: .bold))
                .tracking(MarqueeTheme.scaled(8, leanBack: 12, isLeanBack: leanBackMode))
                .foregroundStyle(MarqueeTheme.titleGradient)

            Text(isManaging ? "Manage Profiles" : "Who's watching?")
                .font(.system(size: MarqueeTheme.scaled(22, leanBack: 32, isLeanBack: leanBackMode), weight: .semibold))
                .foregroundColor(MarqueeTheme.textPrimary)

            Text(librarySummary)
                .font(.system(size: MarqueeTheme.scaled(12, leanBack: 17, isLeanBack: leanBackMode), weight: .medium))
                .foregroundColor(MarqueeTheme.textTertiary)
        }
    }

    // MARK: - Profile Card

    @ViewBuilder
    private var profileRow: some View {
        if isManaging {
            GeometryReader { proxy in
                managementProfileRow(availableWidth: proxy.size.width)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
            .frame(height: ProfileManagementLayoutPolicy.tileHeight)
        } else {
            selectionProfileRow
        }
    }

    private var selectionProfileRow: some View {
        HStack(
            alignment: .top,
            spacing: ProfilePickerRowLayout.itemSpacing(isLeanBack: leanBackMode)
        ) {
            ForEach(profiles) { profile in
                profileCard(profile)
                    .frame(width: ProfilePickerRowLayout.cardWidth(isLeanBack: leanBackMode))
            }

            if canAddProfile {
                addProfileButton
                    .frame(width: ProfilePickerRowLayout.cardWidth(isLeanBack: leanBackMode))
            }
        }
        .frame(maxWidth: ProfilePickerRowLayout.maxWidth(isLeanBack: leanBackMode), alignment: .center)
    }

    private func managementProfileRow(availableWidth: CGFloat) -> some View {
        let layout = ProfilePickerManagementRowLayout.resolved(
            itemCount: topRowFocusTargets.count,
            availableWidth: availableWidth
        )
        return HStack(alignment: .top, spacing: layout.spacing) {
            ForEach(profiles) { profile in
                profileManagementTile(profile, tileWidth: layout.tileWidth)
            }

            if canAddProfile {
                addProfileButton
                    .frame(
                        width: layout.tileWidth,
                        height: ProfileManagementLayoutPolicy.addTileHeight
                    )
            }
        }
        .frame(width: layout.groupWidth, alignment: .center)
    }

    private func profileManagementTile(_ profile: UserProfile, tileWidth: CGFloat) -> some View {
        let avatarImage = profile.characterAvatarName.flatMap { name in
            characterAvatars.first(where: { $0.name == name })?.image
        }
        let profileIndex = profiles.firstIndex(where: { $0.id == profile.id })
        let actionGeometry = ProfilePickerManagementRowLayout.actionGeometry(
            tileWidth: tileWidth
        )

        return ProfileManagementTile(
            profile: profile,
            avatarImage: avatarImage,
            isFocused: remoteFocus == .profile(profile.id),
            canMoveLeft: profileIndex.map { $0 > 0 } ?? false,
            canMoveRight: profileIndex.map { $0 < profiles.count - 1 } ?? false,
            canDelete: profiles.count > 1,
            focusedAction: {
                guard case .managementAction(let focusedID, let action) = remoteFocus,
                      focusedID == profile.id else { return nil }
                return action
            }(),
            actionButtonSize: actionGeometry.buttonSize,
            actionSpacing: actionGeometry.spacing,
            onEdit: { presentEditor(for: profile) },
            onDelete: { profilePendingDeletion = profile },
            onMoveLeft: { moveProfile(profile, direction: -1) },
            onMoveRight: { moveProfile(profile, direction: 1) }
        )
        .frame(
            width: tileWidth,
            height: ProfileManagementLayoutPolicy.tileHeight
        )
    }

    private func profileCard(_ profile: UserProfile) -> some View {
        let isHovered = hoveredID == profile.id
        let isRemoteFocused = remoteFocus == .profile(profile.id)
        let isSelected = appState.profileExitSelectionID == profile.id
        let focusColor = MarqueeTheme.structuralFocus
        let tileDiameter = ProfilePickerAvatarLayout.tileDiameter(isLeanBack: leanBackMode)
        let focusRingDiameter = ProfilePickerAvatarLayout.focusRingDiameter(isLeanBack: leanBackMode)
        let focusRingLineWidth = ProfilePickerAvatarLayout.focusRingLineWidth(isLeanBack: leanBackMode)

        return Button(action: {
            chooseProfile(profile, source: "card")
        }) {
            VStack(spacing: MarqueeTheme.scaled(10, leanBack: 16, isLeanBack: leanBackMode)) {
                ZStack {
                    Circle()
                        .fill(MarqueeTheme.surfaceElevated)
                        .frame(width: tileDiameter, height: tileDiameter)

                    if let charName = profile.characterAvatarName,
                       let charAvatar = characterAvatars.first(where: { $0.name == charName }) {
                        Image(nsImage: charAvatar.image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: tileDiameter, height: tileDiameter)
                            .clipShape(Circle())
                    } else {
                        Image(systemName: profile.avatar.icon)
                            .font(.system(size: MarqueeTheme.scaled(44, leanBack: 64, isLeanBack: leanBackMode), weight: .medium))
                            .foregroundColor(profile.avatar.color)
                    }

                }
                .overlay {
                    if isRemoteFocused || (isSelected && ProfileExitTransitionPolicy.retainsFocusedRing) {
                        Circle()
                            .stroke(focusColor.opacity(0.95), lineWidth: focusRingLineWidth)
                            .frame(width: focusRingDiameter, height: focusRingDiameter)
                            .shadow(color: focusColor.opacity(0.65), radius: 18)
                    }
                }
                .scaleEffect(
                    (isRemoteFocused ? 1.06 : (isHovered ? 1.02 : 1.0))
                        * (isSelected ? ProfileExitTransitionPolicy.scale : 1)
                )
                .saturation(isSelected ? ProfileExitTransitionPolicy.saturation : 1)
                .shadow(
                    color: Color.black.opacity((isRemoteFocused || isSelected) ? 0.62 : (isHovered ? 0.3 : 0.2)),
                    radius: (isRemoteFocused || isSelected) ? 22 : (isHovered ? 8 : 4),
                    y: (isRemoteFocused || isSelected) ? 14 : (isHovered ? 4 : 2)
                )
                .shadow(
                    color: focusColor.opacity((isRemoteFocused || isSelected) ? 0.45 : 0),
                    radius: (isRemoteFocused || isSelected) ? 24 : 0,
                    y: 0
                )

                Text(profile.name)
                    .font(.system(size: MarqueeTheme.scaled(15, leanBack: 22, isLeanBack: leanBackMode), weight: .medium))
                    .foregroundColor((isRemoteFocused || isHovered) ? MarqueeTheme.textPrimary : MarqueeTheme.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)

                Text(profile.maturityLevel.label)
                    .font(.system(size: MarqueeTheme.scaled(11, leanBack: 16, isLeanBack: leanBackMode)))
                    .foregroundColor(MarqueeTheme.textTertiary)
            }
        }
        .buttonStyle(.plain)
        .animation(MarqueeTheme.motion(MarqueeTheme.cardHoverAnimation, reduceMotion: reduceMotion), value: isHovered)
        .animation(MarqueeTheme.motion(MarqueeTheme.selectionFadeAnimation, reduceMotion: reduceMotion), value: isSelected)
        .onHover { hovering in
            hoveredID = hovering ? profile.id : nil
        }
        .accessibilityLabel("\(profile.name), \(profile.maturityLevel.label)")
        .accessibilityHint("Use this profile")
    }

    // MARK: - Add Profile Button

    @State private var addHovered: Bool = false

    private var addProfileButton: some View {
        let isRemoteFocused = remoteFocus == .addProfile
        let tileDiameter = ProfilePickerAvatarLayout.tileDiameter(isLeanBack: leanBackMode)
        let focusRingDiameter = ProfilePickerAvatarLayout.focusRingDiameter(isLeanBack: leanBackMode)
        let focusRingLineWidth = ProfilePickerAvatarLayout.focusRingLineWidth(isLeanBack: leanBackMode)

        return Button(action: {
            editingProfile = nil
            withAnimation(MarqueeTheme.motion(MarqueeTheme.modalPresentationAnimation, reduceMotion: reduceMotion)) {
                showingEditor = true
            }
        }) {
            VStack(spacing: MarqueeTheme.scaled(10, leanBack: 16, isLeanBack: leanBackMode)) {
                ZStack {
                    Circle()
                        .fill(MarqueeTheme.surfaceLayer)
                        .frame(width: tileDiameter, height: tileDiameter)

                    Image(systemName: "plus.circle")
                        .font(.system(size: MarqueeTheme.scaled(44, leanBack: 64, isLeanBack: leanBackMode), weight: .ultraLight))
                        .foregroundColor(MarqueeTheme.textTertiary)
                }
                .overlay {
                    if isRemoteFocused {
                        Circle()
                            .stroke(MarqueeTheme.structuralFocus, lineWidth: focusRingLineWidth)
                            .frame(width: focusRingDiameter, height: focusRingDiameter)
                    }
                }
                .scaleEffect(isRemoteFocused ? 1.06 : (addHovered ? 1.02 : 1.0))
                .shadow(
                    color: Color.black.opacity(isRemoteFocused ? 0.58 : (addHovered ? 0.24 : 0)),
                    radius: isRemoteFocused ? 22 : (addHovered ? 8 : 0),
                    y: isRemoteFocused ? 14 : (addHovered ? 4 : 0)
                )
                .shadow(
                    color: MarqueeTheme.structuralFocus.opacity(isRemoteFocused ? 0.45 : 0),
                    radius: isRemoteFocused ? 24 : 0,
                    y: 0
                )

                Text("Add Profile")
                    .font(.system(size: MarqueeTheme.scaled(15, leanBack: 22, isLeanBack: leanBackMode), weight: .medium))
                    .foregroundColor((isRemoteFocused || addHovered) ? MarqueeTheme.textSecondary : MarqueeTheme.textTertiary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)

                Text(" ")
                    .font(.system(size: MarqueeTheme.scaled(11, leanBack: 16, isLeanBack: leanBackMode)))
            }
            .frame(maxWidth: .infinity, maxHeight: isManaging ? .infinity : nil)
            .background(
                RoundedRectangle(cornerRadius: MarqueeTheme.cornerRadiusMD)
                    .fill(MarqueeTheme.surfaceLayer.opacity(isManaging ? 0.86 : 0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: MarqueeTheme.cornerRadiusMD)
                    .strokeBorder(
                        isManaging && isRemoteFocused ? MarqueeTheme.structuralFocus : Color.clear,
                        lineWidth: isManaging && isRemoteFocused ? 2.5 : 0
                    )
            )
        }
        .buttonStyle(.plain)
        .animation(MarqueeTheme.motion(MarqueeTheme.cardHoverAnimation, reduceMotion: reduceMotion), value: addHovered)
        .onHover { hovering in addHovered = hovering }
        .accessibilityLabel(ProfileManagementAction.add.accessibilityLabel)
        .accessibilityHint(ProfileManagementAction.add.accessibilityHint)
    }

    // MARK: - Manage Button

    private var manageProfilesButton: some View {
        let isRemoteFocused = remoteFocus == .manageProfiles

        return Button(action: toggleManageProfiles) {
            Text(isManaging ? "Done" : "Manage Profiles")
                .font(.system(size: MarqueeTheme.scaled(14, leanBack: 20, isLeanBack: leanBackMode), weight: .medium))
                .foregroundColor(isRemoteFocused ? MarqueeTheme.textPrimary : MarqueeTheme.textSecondary)
                .padding(.horizontal, MarqueeTheme.scaled(24, leanBack: 36, isLeanBack: leanBackMode))
                .padding(.vertical, MarqueeTheme.scaled(10, leanBack: 16, isLeanBack: leanBackMode))
                .background(
                    Capsule()
                        .strokeBorder(
                            isRemoteFocused ? MarqueeTheme.structuralFocus : MarqueeTheme.textTertiary.opacity(0.4),
                            lineWidth: isRemoteFocused ? 2 : 1
                        )
                )
                .shadow(
                    color: isRemoteFocused ? MarqueeTheme.structuralFocus.opacity(0.25) : Color.clear,
                    radius: isRemoteFocused ? 10 : 0,
                    y: isRemoteFocused ? 4 : 0
                )
        }
        .buttonStyle(.plain)
        .padding(.top, 8)
        .accessibilityLabel(
            isManaging
                ? ProfileManagementAction.done.accessibilityLabel
                : "Manage profiles"
        )
        .accessibilityHint(
            isManaging
                ? ProfileManagementAction.done.accessibilityHint
                : "Shows profile editing controls"
        )
    }

    // MARK: - Remote Navigation

    private func handleRemoteKey(_ event: MarqueeKeyEvent) -> Bool {
        if isExitCommitted {
            return appState.isProfileExitInFlight
        }
        guard ProfileExitTransitionPolicy.acceptsInput(isExitInFlight: appState.isProfileExitInFlight) else {
            return true
        }
        guard let command = event.key?.remoteCommand else {
            return false
        }

        if showingEditor {
            if command == .back {
                AudioIdentityService.shared.playFeedback(for: .back)
                withAnimation { showingEditor = false }
                return true
            }
            return false
        }

        if event.isRepeat && (command == .select || command == .back) {
            return true
        }

        reconcileRemoteFocus()
        let previousFocus = remoteFocus

        if command == .select || command == .back {
            AudioIdentityService.shared.playFeedback(for: command)
        }

        switch command {
        case .left, .right, .up, .down:
            remoteFocus = ProfilePickerRemoteNavigationPolicy.movedFocus(
                from: remoteFocus,
                command: command,
                profileIDs: profileIDs,
                canAddProfile: canAddProfile,
                isManaging: isManaging
            )
        case .select:
            activateRemoteFocus()
        case .back:
            if isManaging {
                toggleManageProfiles()
            }
        }

        if command != .select && command != .back {
            let didNavigate = remoteFocus != previousFocus
            AudioIdentityService.shared.playFeedback(
                for: command,
                didNavigate: didNavigate,
                didReachBoundary: !didNavigate
            )
        }

        return true
    }

    private func reconcileRemoteFocus() {
        remoteFocus = ProfilePickerRemoteNavigationPolicy.reconciledFocus(
            remoteFocus,
            profileIDs: profileIDs,
            canAddProfile: canAddProfile,
            isManaging: isManaging
        )
    }

    private func activateRemoteFocus() {
        guard let activation = ProfilePickerRemoteNavigationPolicy.activation(
            for: remoteFocus,
            profileIDs: profileIDs,
            canAddProfile: canAddProfile,
            isManaging: isManaging
        ) else { return }

        switch activation {
        case .chooseProfile(let id):
            guard let profile = profiles.first(where: { $0.id == id }) else { return }
            chooseProfile(profile, source: "remote")
        case .editProfile(let id):
            guard let profile = profiles.first(where: { $0.id == id }) else { return }
            presentEditor(for: profile)
        case .deleteProfile(let id):
            guard let profile = profiles.first(where: { $0.id == id }) else { return }
            profilePendingDeletion = profile
        case .moveProfile(let id, let direction):
            guard let profile = profiles.first(where: { $0.id == id }) else { return }
            moveProfile(profile, direction: direction)
        case .addProfile:
            editingProfile = nil
            withAnimation(MarqueeTheme.motion(MarqueeTheme.modalPresentationAnimation, reduceMotion: reduceMotion)) {
                showingEditor = true
            }
        case .toggleManagement:
            toggleManageProfiles()
        }
    }

    private func toggleManageProfiles() {
        withAnimation(MarqueeTheme.motion(MarqueeTheme.quickControlAnimation, reduceMotion: reduceMotion)) {
            isManaging.toggle()
        }
        if !isManaging,
           case .managementAction(let id, _) = remoteFocus {
            remoteFocus = .profile(id)
        }
    }

    private func presentEditor(for profile: UserProfile) {
        editingProfile = profile
        withAnimation(MarqueeTheme.motion(MarqueeTheme.modalPresentationAnimation, reduceMotion: reduceMotion)) {
            showingEditor = true
        }
    }

    private func moveProfile(_ profile: UserProfile, direction: Int) {
        withAnimation(MarqueeTheme.motion(MarqueeTheme.reorderAnimation, reduceMotion: reduceMotion)) {
            profileStore.moveProfile(id: profile.id, direction: direction)
        }
        remoteFocus = ProfilePickerRemoteNavigationPolicy.focusAfterReorder(
            movedProfileID: profile.id,
            updatedProfileIDs: profileIDs,
            canAddProfile: canAddProfile,
            isManaging: isManaging
        )
    }

    private func deleteProfile(_ profile: UserProfile) {
        let previousProfileIDs = profileIDs
        let previousFocus = remoteFocus
        profileStore.deleteProfile(id: profile.id)
        remoteFocus = ProfilePickerRemoteNavigationPolicy.focusAfterDeletion(
            current: previousFocus,
            deletedProfileID: profile.id,
            previousProfileIDs: previousProfileIDs,
            remainingProfileIDs: profileIDs,
            canAddProfile: canAddProfile,
            isManaging: isManaging
        )
        appState.reconcileActiveProfile()
    }

    private func chooseProfile(_ profile: UserProfile, source: String) {
        var selectionStarted = false
        withAnimation(MarqueeTheme.profileExitAnimation) {
            selectionStarted = appState.beginProfileExitSelection(profile)
            if selectionStarted {
                isExitCommitted = true
            }
        }
        guard selectionStarted else { return }
        MarqueeLogger.general.info("profile \(source, privacy: .public) selected id=\(profile.id.uuidString, privacy: .public) maturity=\(profile.maturityLevel.rawValue, privacy: .public)")
    }

    // MARK: - Editor Overlay

    private var profileEditorOverlay: some View {
        ZStack {
            Color.black.opacity(0.7)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation { showingEditor = false }
                }

            ProfileEditorView(
                existingProfile: editingProfile,
                characterAvatars: characterAvatars,
                onSave: { profile in
                    if editingProfile != nil {
                        profileStore.updateProfile(profile)
                    } else {
                        profileStore.addProfile(profile)
                    }
                    appState.reconcileActiveProfile()
                    withAnimation { showingEditor = false }
                },
                onDelete: editingProfile != nil && profiles.count > 1 ? { profile in
                    profileStore.deleteProfile(id: profile.id)
                    appState.reconcileActiveProfile()
                    withAnimation { showingEditor = false }
                } : nil,
                onCancel: {
                    withAnimation { showingEditor = false }
                }
            )
            .transition(.scale(scale: 0.9).combined(with: .opacity))
        }
    }
}

private struct ProfileManagementTile: View {
    let profile: UserProfile
    let avatarImage: NSImage?
    let isFocused: Bool
    let canMoveLeft: Bool
    let canMoveRight: Bool
    let canDelete: Bool
    let focusedAction: ProfileManagementRemoteAction?
    let actionButtonSize: CGFloat
    let actionSpacing: CGFloat
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onMoveLeft: () -> Void
    let onMoveRight: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(MarqueeTheme.surfaceElevated)

                if let avatarImage {
                    Image(nsImage: avatarImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .clipShape(Circle())
                } else {
                    Image(systemName: profile.avatar.icon)
                        .font(.system(size: 48, weight: .medium))
                        .foregroundColor(profile.avatar.color)
                }
            }
            .frame(width: 128, height: 128)

            VStack(spacing: 4) {
                Text(profile.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(MarqueeTheme.textPrimary)
                    .lineLimit(1)
                Text(profile.maturityLevel.label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(MarqueeTheme.textTertiary)
            }

            HStack(spacing: actionSpacing) {
                actionButton(
                    icon: "chevron.left",
                    label: "Move \(profile.name) left",
                    hint: "Moves this profile earlier",
                    enabled: canMoveLeft,
                    isFocused: focusedAction == .moveLeft,
                    action: onMoveLeft
                )
                actionButton(
                    icon: "pencil",
                    label: "Edit \(profile.name)",
                    hint: ProfileManagementAction.edit.accessibilityHint,
                    enabled: true,
                    isFocused: focusedAction == .edit,
                    action: onEdit
                )
                actionButton(
                    icon: "trash",
                    label: "Delete \(profile.name)",
                    hint: ProfileManagementAction.delete.accessibilityHint,
                    enabled: canDelete,
                    isFocused: focusedAction == .delete,
                    destructive: true,
                    action: onDelete
                )
                actionButton(
                    icon: "chevron.right",
                    label: "Move \(profile.name) right",
                    hint: "Moves this profile later",
                    enabled: canMoveRight,
                    isFocused: focusedAction == .moveRight,
                    action: onMoveRight
                )
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: MarqueeTheme.cornerRadiusMD)
                .fill(MarqueeTheme.surfaceLayer.opacity(0.86))
        )
        .overlay(
            RoundedRectangle(cornerRadius: MarqueeTheme.cornerRadiusMD)
                .strokeBorder(
                    isFocused ? MarqueeTheme.structuralFocus : Color.white.opacity(0.05),
                    lineWidth: isFocused ? 2.5 : 1
                )
        )
        .shadow(
            color: isFocused ? MarqueeTheme.structuralFocus.opacity(0.34) : Color.black.opacity(0.24),
            radius: isFocused ? 18 : 6,
            y: isFocused ? 8 : 3
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Manage \(profile.name), \(profile.maturityLevel.label)")
    }

    private func actionButton(
        icon: String,
        label: String,
        hint: String,
        enabled: Bool,
        isFocused: Bool,
        destructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: destructive ? .destructive : nil, action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(
                    destructive
                        ? Color.red.opacity(enabled ? 0.9 : 0.3)
                        : MarqueeTheme.textSecondary.opacity(enabled ? 1 : 0.3)
                )
                .frame(width: actionButtonSize, height: actionButtonSize)
                .background(Circle().fill(MarqueeTheme.surfaceElevated))
                .overlay(
                    Circle()
                        .strokeBorder(
                            isFocused ? MarqueeTheme.structuralFocus : Color.clear,
                            lineWidth: isFocused ? 2 : 0
                        )
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
        .accessibilityHint(hint)
    }
}

// MARK: - Profile Editor View

struct ProfileEditorView: View {
    let existingProfile: UserProfile?
    let characterAvatars: [CharacterAvatar]
    let onSave: (UserProfile) -> Void
    let onDelete: ((UserProfile) -> Void)?
    let onCancel: () -> Void

    @State private var name: String = ""
    @State private var selectedAvatar: ProfileAvatar = ProfileAvatar.catalog[0]
    @State private var selectedCharacterName: String?
    @State private var maturityLevel: MaturityLevel = .adult
    @State private var showDeleteConfirm: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.leanBackMode) private var leanBackMode

    private var isEditing: Bool { existingProfile != nil }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool { !trimmedName.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(isEditing ? "Edit Profile" : "New Profile")
                    .font(.system(size: MarqueeTheme.scaled(22, leanBack: 31, isLeanBack: leanBackMode), weight: .bold))
                    .foregroundColor(MarqueeTheme.textPrimary)
                Spacer()
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: MarqueeTheme.scaled(14, leanBack: 20, isLeanBack: leanBackMode), weight: .bold))
                        .foregroundColor(MarqueeTheme.textTertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(MarqueeTheme.scaled(24, leanBack: 34, isLeanBack: leanBackMode))

            Divider().background(MarqueeTheme.surfaceLayer)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: MarqueeTheme.scaled(28, leanBack: 40, isLeanBack: leanBackMode)) {
                    nameField
                    avatarGrid
                    maturityPicker
                }
                .padding(MarqueeTheme.scaled(24, leanBack: 34, isLeanBack: leanBackMode))
            }

            Divider().background(MarqueeTheme.surfaceLayer)

            // Actions
            HStack(spacing: MarqueeTheme.scaled(12, leanBack: 18, isLeanBack: leanBackMode)) {
                if let onDelete = onDelete, let profile = existingProfile {
                    if showDeleteConfirm {
                        Text("Delete this profile?")
                            .font(.system(size: MarqueeTheme.scaled(13, leanBack: 18, isLeanBack: leanBackMode)))
                            .foregroundColor(.red)
                        Button("Yes, Delete") {
                            onDelete(profile)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: MarqueeTheme.scaled(13, leanBack: 18, isLeanBack: leanBackMode), weight: .semibold))
                        .foregroundColor(.red)
                        Button("Cancel") {
                            showDeleteConfirm = false
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: MarqueeTheme.scaled(13, leanBack: 18, isLeanBack: leanBackMode)))
                        .foregroundColor(MarqueeTheme.textSecondary)
                    } else {
                        Button("Delete Profile") {
                            showDeleteConfirm = true
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: MarqueeTheme.scaled(13, leanBack: 18, isLeanBack: leanBackMode)))
                        .foregroundColor(.red.opacity(0.8))
                    }
                }

                Spacer()

                Button("Cancel") { onCancel() }
                    .buttonStyle(.plain)
                    .font(.system(size: MarqueeTheme.scaled(14, leanBack: 20, isLeanBack: leanBackMode), weight: .medium))
                    .foregroundColor(MarqueeTheme.textSecondary)

                Button(action: saveProfile) {
                    Text("Save")
                        .font(.system(size: MarqueeTheme.scaled(14, leanBack: 20, isLeanBack: leanBackMode), weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, MarqueeTheme.scaled(24, leanBack: 34, isLeanBack: leanBackMode))
                        .padding(.vertical, MarqueeTheme.scaled(8, leanBack: 13, isLeanBack: leanBackMode))
                        .background(
                            Capsule().fill(
                                !canSave
                                    ? MarqueeTheme.accentPrimary.opacity(0.3)
                                    : MarqueeTheme.accentPrimary
                            )
                        )
                }
                .buttonStyle(.plain)
                .disabled(!canSave)
            }
            .padding(MarqueeTheme.scaled(24, leanBack: 34, isLeanBack: leanBackMode))
        }
        .frame(
            width: MarqueeTheme.scaled(520, leanBack: 760, isLeanBack: leanBackMode),
            height: MarqueeTheme.scaled(560, leanBack: 760, isLeanBack: leanBackMode)
        )
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(MarqueeTheme.surfaceElevated)
                .shadow(color: Color.black.opacity(0.5), radius: 24, y: 8)
        )
        .onAppear {
            if let profile = existingProfile {
                name = profile.name
                selectedAvatar = profile.avatar
                selectedCharacterName = profile.characterAvatarName
                maturityLevel = profile.maturityLevel
            }
        }
    }

    // MARK: - Name Field

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Name")
                .font(.system(size: MarqueeTheme.scaled(13, leanBack: 18, isLeanBack: leanBackMode), weight: .semibold))
                .foregroundColor(MarqueeTheme.textSecondary)

            TextField("", text: $name)
                .textFieldStyle(.plain)
                .font(.system(size: MarqueeTheme.scaled(16, leanBack: 23, isLeanBack: leanBackMode)))
                .foregroundColor(MarqueeTheme.textPrimary)
                .padding(MarqueeTheme.scaled(12, leanBack: 18, isLeanBack: leanBackMode))
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(MarqueeTheme.surfaceLayer)
                )
        }
    }

    // MARK: - Avatar Grid

    private var avatarGrid: some View {
        VStack(alignment: .leading, spacing: MarqueeTheme.scaled(16, leanBack: 24, isLeanBack: leanBackMode)) {
            if !characterAvatars.isEmpty {
                Text("Characters")
                    .font(.system(size: MarqueeTheme.scaled(13, leanBack: 18, isLeanBack: leanBackMode), weight: .semibold))
                    .foregroundColor(MarqueeTheme.textSecondary)

                LazyVGrid(columns: Array(repeating: GridItem(.fixed(avatarGridCellSize), spacing: avatarGridSpacing), count: 8), spacing: avatarGridSpacing) {
                    ForEach(characterAvatars) { character in
                        characterAvatarCell(character)
                    }
                }
            }

            Text("Icons")
                .font(.system(size: MarqueeTheme.scaled(13, leanBack: 18, isLeanBack: leanBackMode), weight: .semibold))
                .foregroundColor(MarqueeTheme.textSecondary)

            LazyVGrid(columns: Array(repeating: GridItem(.fixed(avatarGridCellSize), spacing: avatarGridSpacing), count: 8), spacing: avatarGridSpacing) {
                ForEach(ProfileAvatar.catalog) { avatar in
                    avatarCell(avatar)
                }
            }
        }
    }

    private var avatarGridCellSize: CGFloat {
        MarqueeTheme.scaled(56, leanBack: 78, isLeanBack: leanBackMode)
    }

    private var avatarGridSpacing: CGFloat {
        MarqueeTheme.scaled(10, leanBack: 14, isLeanBack: leanBackMode)
    }

    @State private var hoveredAvatar: String?
    @State private var hoveredCharacter: String?

    private func characterAvatarCell(_ character: CharacterAvatar) -> some View {
        let isSelected = selectedCharacterName == character.name
        let isHovered = hoveredCharacter == character.name

        return Button(action: {
            selectedCharacterName = character.name
            selectedAvatar = ProfileAvatar.catalog[0]
        }) {
            ZStack {
                Image(nsImage: character.image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(
                        width: MarqueeTheme.scaled(52, leanBack: 72, isLeanBack: leanBackMode),
                        height: MarqueeTheme.scaled(52, leanBack: 72, isLeanBack: leanBackMode)
                    )
                    .clipShape(Circle())
            }
            .overlay(
                Circle()
                    .strokeBorder(
                        isSelected ? MarqueeTheme.accentPrimary : (isHovered ? MarqueeTheme.textTertiary : Color.clear),
                        lineWidth: isSelected ? 2.5 : 1
                    )
            )
            .scaleEffect(isHovered ? 1.1 : 1.0)
            .animation(MarqueeTheme.motion(MarqueeTheme.quickControlAnimation, reduceMotion: reduceMotion), value: isHovered)
            .help("\(character.name) - \(character.role)")
        }
        .buttonStyle(.plain)
        .onHover { h in hoveredCharacter = h ? character.name : nil }
    }

    private func avatarCell(_ avatar: ProfileAvatar) -> some View {
        let isSelected = selectedAvatar == avatar
        let isHovered = hoveredAvatar == avatar.icon

        return Button(action: {
            selectedAvatar = avatar
            selectedCharacterName = nil
        }) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? MarqueeTheme.accentPrimary.opacity(0.2) : MarqueeTheme.surfaceLayer)
                    .frame(
                        width: MarqueeTheme.scaled(52, leanBack: 72, isLeanBack: leanBackMode),
                        height: MarqueeTheme.scaled(52, leanBack: 72, isLeanBack: leanBackMode)
                    )

                Image(systemName: avatar.icon)
                    .font(.system(size: MarqueeTheme.scaled(22, leanBack: 32, isLeanBack: leanBackMode), weight: .medium))
                    .foregroundColor(avatar.color)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        isSelected ? MarqueeTheme.accentPrimary : (isHovered ? MarqueeTheme.textTertiary : Color.clear),
                        lineWidth: isSelected ? 2 : 1
                    )
            )
            .scaleEffect(isHovered ? 1.1 : 1.0)
            .animation(MarqueeTheme.motion(MarqueeTheme.quickControlAnimation, reduceMotion: reduceMotion), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { h in hoveredAvatar = h ? avatar.icon : nil }
    }

    // MARK: - Maturity Picker

    private var maturityPicker: some View {
        VStack(alignment: .leading, spacing: MarqueeTheme.scaled(12, leanBack: 18, isLeanBack: leanBackMode)) {
            Text("Content Rating")
                .font(.system(size: MarqueeTheme.scaled(13, leanBack: 18, isLeanBack: leanBackMode), weight: .semibold))
                .foregroundColor(MarqueeTheme.textSecondary)

            HStack(spacing: MarqueeTheme.scaled(8, leanBack: 12, isLeanBack: leanBackMode)) {
                ForEach(MaturityLevel.allCases, id: \.rawValue) { level in
                    Button(action: { maturityLevel = level }) {
                        VStack(spacing: 4) {
                            Text(level.label)
                                .font(.system(size: MarqueeTheme.scaled(13, leanBack: 18, isLeanBack: leanBackMode), weight: maturityLevel == level ? .semibold : .regular))
                            Text(level.ratingExamples)
                                .font(.system(size: MarqueeTheme.scaled(10, leanBack: 14, isLeanBack: leanBackMode)))
                                .foregroundColor(MarqueeTheme.textTertiary)
                        }
                        .foregroundColor(maturityLevel == level ? .white : MarqueeTheme.textSecondary)
                        .padding(.horizontal, MarqueeTheme.scaled(16, leanBack: 24, isLeanBack: leanBackMode))
                        .padding(.vertical, MarqueeTheme.scaled(8, leanBack: 13, isLeanBack: leanBackMode))
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(maturityLevel == level ? MarqueeTheme.accentPrimary : MarqueeTheme.surfaceLayer)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Save

    private func saveProfile() {
        guard canSave else { return }
        if var profile = existingProfile {
            profile.name = trimmedName
            profile.avatar = selectedAvatar
            profile.characterAvatarName = selectedCharacterName
            profile.maturityLevel = maturityLevel
            onSave(profile)
        } else {
            let profile = UserProfile(name: trimmedName, avatar: selectedAvatar, maturityLevel: maturityLevel, characterAvatarName: selectedCharacterName)
            onSave(profile)
        }
    }
}
