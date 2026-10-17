import SwiftUI
import AppKit

// MARK: - Settings Detail View

struct SettingsDetailView: View {
    @ObservedObject var library: LibraryState
    var remoteEscapeEnabled: Bool = true
    var onRemoteBackAtRoot: () -> Void = {}

    @ObservedObject private var settings = UserSettings.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.leanBackMode) private var leanBackMode

    @State private var showClearConfirmation: Bool = false
    @State private var showClearCacheConfirmation: Bool = false
    @State private var imageCacheSize: String = "Not measured"
    @State private var isCalculatingImageCacheSize: Bool = false
    @State private var cacheSizeGeneration: Int = 0
    @State private var cacheCleared: Bool = false
    @State private var historyCleared: Bool = false
    @State private var diagnosticsExportedPath: String?
    @State private var diagnosticsExportFailed: String?
    @State private var isExportingDiagnostics: Bool = false
    @FocusState private var soundPackPickerFocused: Bool

    var body: some View {
        ZStack {
            MarqueeTheme.background.ignoresSafeArea()

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: MarqueeTheme.scaled(28, leanBack: 40, isLeanBack: leanBackMode)) {
                    settingsHeader
                    settingsOverview
                    librarySection
                    playbackSection
                    soundSection
                    storageSection
                    aboutSection
                }
                .frame(maxWidth: MarqueeTheme.scaled(1280, leanBack: 1720, isLeanBack: leanBackMode), alignment: .leading)
                .padding(.horizontal, MarqueeTheme.outerPadding(isLeanBack: leanBackMode))
                .padding(.bottom, MarqueeTheme.scaled(100, leanBack: 150, isLeanBack: leanBackMode))
            }
        }
        .onExitCommand(perform: handleRemoteExit)
        .overlay(alignment: .topLeading) {
            if remoteEscapeEnabled {
                SettingsRemoteEscapeCatcher(onExit: handleRemoteExit)
                    .frame(width: 1, height: 1)
            }
        }
    }

    private func handleRemoteExit() {
        AudioIdentityService.shared.playFeedback(for: .back)
        onRemoteBackAtRoot()
    }

    private var settingsHeader: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: MarqueeTheme.scaled(8, leanBack: 12, isLeanBack: leanBackMode)) {
                Text("Settings")
                    .font(.system(size: MarqueeTheme.scaled(32, leanBack: 46, isLeanBack: leanBackMode), weight: .bold))
                    .foregroundColor(MarqueeTheme.textPrimary)

                Text("Tune library, playback, and maintenance without interrupting the screening room.")
                    .font(.system(size: MarqueeTheme.scaled(13, leanBack: 19, isLeanBack: leanBackMode), weight: .medium))
                    .foregroundColor(MarqueeTheme.textSecondary)
                    .lineLimit(2)
            }

            Spacer()

            HStack(spacing: MarqueeTheme.scaled(8, leanBack: 12, isLeanBack: leanBackMode)) {
                Image(systemName: library.isScanning ? "arrow.triangle.2.circlepath" : "checkmark.seal.fill")
                    .font(.system(size: MarqueeTheme.scaled(14, leanBack: 20, isLeanBack: leanBackMode), weight: .semibold))
                    .foregroundColor(library.isScanning ? MarqueeTheme.accentSecondary : MarqueeTheme.accentBright)

                Text(library.isScanning ? "Scan active" : "Library ready")
                    .font(.system(size: MarqueeTheme.scaled(12, leanBack: 17, isLeanBack: leanBackMode), weight: .semibold))
                    .foregroundColor(MarqueeTheme.textSecondary)
            }
            .padding(.horizontal, MarqueeTheme.scaled(12, leanBack: 18, isLeanBack: leanBackMode))
            .padding(.vertical, MarqueeTheme.scaled(7, leanBack: 11, isLeanBack: leanBackMode))
            .background(
                Capsule()
                    .fill(MarqueeTheme.surfaceElevated.opacity(0.9))
            )
        }
        .padding(.top, MarqueeTheme.scaled(30, leanBack: 46, isLeanBack: leanBackMode))
    }

    private var settingsOverview: some View {
        LazyVGrid(
            columns: [
                GridItem(
                    .adaptive(minimum: MarqueeTheme.scaled(210, leanBack: 300, isLeanBack: leanBackMode)),
                    spacing: MarqueeTheme.scaled(12, leanBack: 18, isLeanBack: leanBackMode)
                )
            ],
            alignment: .leading,
            spacing: MarqueeTheme.scaled(12, leanBack: 18, isLeanBack: leanBackMode)
        ) {
            settingsMetric(
                icon: "film",
                title: "Movies",
                value: "\(library.filteredLibraryItems.count)",
                accent: MarqueeTheme.accentSecondary
            )

            settingsMetric(
                icon: "tv",
                title: "Episodes",
                value: "\(library.filteredTVItems.count)",
                accent: MarqueeTheme.accentBright
            )

            settingsMetric(
                icon: "folder",
                title: "Sources",
                value: "\(settings.moviesPaths.count + settings.tvShowsPaths.count)",
                accent: MarqueeTheme.textSecondary
            )

            settingsMetric(
                icon: "externaldrive",
                title: "Image Cache",
                value: imageCacheOverviewValue,
                accent: MarqueeTheme.accentSecondary.opacity(0.9)
            )
        }
    }

    private func settingsMetric(icon: String, title: String, value: String, accent: Color) -> some View {
        HStack(spacing: MarqueeTheme.scaled(12, leanBack: 18, isLeanBack: leanBackMode)) {
            Image(systemName: icon)
                .font(.system(size: MarqueeTheme.scaled(16, leanBack: 24, isLeanBack: leanBackMode), weight: .semibold))
                .foregroundColor(accent)
                .frame(
                    width: MarqueeTheme.scaled(34, leanBack: 50, isLeanBack: leanBackMode),
                    height: MarqueeTheme.scaled(34, leanBack: 50, isLeanBack: leanBackMode)
                )
                .background(
                    Circle()
                        .fill(accent.opacity(0.13))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: MarqueeTheme.scaled(11, leanBack: 16, isLeanBack: leanBackMode), weight: .semibold))
                    .foregroundColor(MarqueeTheme.textTertiary)
                    .textCase(.uppercase)

                Text(value)
                    .font(.system(size: MarqueeTheme.scaled(15, leanBack: 22, isLeanBack: leanBackMode), weight: .semibold))
                    .foregroundColor(MarqueeTheme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            Spacer(minLength: 0)
        }
        .padding(MarqueeTheme.scaled(14, leanBack: 20, isLeanBack: leanBackMode))
        .frame(maxWidth: .infinity, minHeight: MarqueeTheme.scaled(72, leanBack: 104, isLeanBack: leanBackMode), alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: MarqueeTheme.cornerRadiusMD)
                .fill(MarqueeTheme.surfaceLayer.opacity(0.88))
        )
        .overlay(
            RoundedRectangle(cornerRadius: MarqueeTheme.cornerRadiusMD)
                .strokeBorder(Color.white.opacity(0.045), lineWidth: 1)
        )
    }

    // MARK: - Library Section

    private var librarySection: some View {
        settingsSection(
            title: "Library",
            subtitle: "Choose the folders Marquee watches and decide when metadata enrichment is allowed.",
            icon: "folder.fill",
            accent: MarqueeTheme.accentSecondary
        ) {
            VStack(alignment: .leading, spacing: 24) {
                folderList(
                    title: "Movies Folders",
                    paths: $settings.moviesPaths
                )

                Divider()
                    .background(MarqueeTheme.textTertiary.opacity(0.3))

                folderList(
                    title: "TV Shows Folders",
                    paths: $settings.tvShowsPaths
                )

                Divider()
                    .background(MarqueeTheme.textTertiary.opacity(0.3))

                settingsToggleRow(
                    title: "Online Metadata",
                    subtitle: "Fetch TMDB details and artwork during library scans.",
                    isOn: $settings.onlineMetadataEnabled
                )

                Divider()
                    .background(MarqueeTheme.textTertiary.opacity(0.3))

                rescanButton
            }
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: MarqueeTheme.cornerRadiusMD)
                    .fill(MarqueeTheme.surfaceLayer)
            )
        }
    }

    private func folderList(title: String, paths: Binding<[String]>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(MarqueeTheme.textPrimary)

            if paths.wrappedValue.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "folder.badge.questionmark")
                        .font(.system(size: 13))
                        .foregroundColor(MarqueeTheme.textTertiary)
                    Text("No folders configured. Add a folder to get started.")
                        .font(.system(size: 13))
                        .foregroundColor(MarqueeTheme.textTertiary)
                }
                .padding(.vertical, 8)
            } else {
                VStack(spacing: 6) {
                    ForEach(Array(paths.wrappedValue.enumerated()), id: \.offset) { index, path in
                        folderRow(path: path) {
                            paths.wrappedValue.remove(at: index)
                        }
                    }
                }
            }

            Button(action: { addFolder(to: paths) }) {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                    Text("Add Folder")
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundColor(MarqueeTheme.accentBright)
            }
            .buttonStyle(.plain)
        }
    }

    private func folderRow(path: String, onRemove: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill")
                .font(.system(size: 12))
                .foregroundColor(MarqueeTheme.accentSecondary)

            Text(path)
                .font(.system(size: 13))
                .foregroundColor(MarqueeTheme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            Button(action: onRemove) {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 14))
                    .foregroundColor(MarqueeTheme.textTertiary)
            }
            .buttonStyle(.plain)
            .help("Remove this folder")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: MarqueeTheme.cornerRadiusSM)
                .fill(MarqueeTheme.surfaceElevated)
        )
    }

    private func addFolder(to paths: Binding<[String]>) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select a media folder"
        panel.prompt = "Add Folder"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.path
        if !paths.wrappedValue.contains(path) {
            paths.wrappedValue.append(path)
        }
    }

    private var rescanButton: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Rescan Library")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(MarqueeTheme.textPrimary)
                Text("Re-scan all configured folders for media files.")
                    .font(.system(size: 12))
                    .foregroundColor(MarqueeTheme.textSecondary)
                if let status = library.scanStatusText {
                    Text(status)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(library.hasQueuedScan ? MarqueeTheme.accentSecondary : MarqueeTheme.textTertiary)
                }
            }

            Spacer()

            Button(action: {
                library.scanLibrary(allowOnlineMetadata: true)
            }) {
                HStack(spacing: 6) {
                    if library.isScanning {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.7)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    Text(rescanButtonTitle)
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundColor(MarqueeTheme.textPrimary)
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .background(
                    Capsule().fill(MarqueeTheme.surfaceElevated)
                )
            }
            .buttonStyle(.plain)
            .disabled(library.hasQueuedScan)
        }
    }

    private var rescanButtonTitle: String {
        if library.hasQueuedScan { return "Queued" }
        if library.isScanning { return "Queue Scan" }
        return "Rescan"
    }

    // MARK: - Playback Section

    private var playbackSection: some View {
        settingsSection(
            title: "Playback",
            subtitle: "Set the defaults that shape every movie night before the player opens.",
            icon: "play.rectangle.fill",
            accent: MarqueeTheme.accentBright
        ) {
            VStack(alignment: .leading, spacing: 0) {
                settingsToggleRow(
                    title: "Hardware Decoding",
                    subtitle: "Use VideoToolbox for hardware-accelerated video decoding.",
                    isOn: $settings.hardwareDecodingEnabled
                )

                Divider()
                    .background(MarqueeTheme.textTertiary.opacity(0.3))
                    .padding(.horizontal, 20)

                settingsToggleRow(
                    title: "Auto-play Next Episode",
                    subtitle: "Automatically play the next episode when the current one ends.",
                    isOn: $settings.autoPlayNextEpisode
                )

                Divider()
                    .background(MarqueeTheme.textTertiary.opacity(0.3))
                    .padding(.horizontal, 20)

                settingsPickerRow(
                    title: "Default Subtitle Language",
                    selection: $settings.defaultSubtitleLanguage,
                    options: UserSettings.subtitleLanguages
                )

                Divider()
                    .background(MarqueeTheme.textTertiary.opacity(0.3))
                    .padding(.horizontal, 20)

                subtitleSizeRow

                Divider()
                    .background(MarqueeTheme.textTertiary.opacity(0.3))
                    .padding(.horizontal, 20)

                settingsPickerRow(
                    title: "Default Audio Language",
                    selection: $settings.defaultAudioLanguage,
                    options: UserSettings.audioLanguages
                )
            }
            .background(
                RoundedRectangle(cornerRadius: MarqueeTheme.cornerRadiusMD)
                    .fill(MarqueeTheme.surfaceLayer)
            )
        }
    }

    private func settingsToggleRow(title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(MarqueeTheme.textPrimary)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(MarqueeTheme.textSecondary)
            }

            Spacer()

            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .tint(MarqueeTheme.accentPrimary)
                .labelsHidden()
        }
        .padding(20)
    }

    // MARK: - Sound Section

    private var soundSection: some View {
        settingsSection(
            title: "Sound",
            subtitle: "Keep remote feedback quiet, distinct, and separate from playback.",
            icon: "speaker.wave.2.fill",
            accent: MarqueeTheme.accentPrimary
        ) {
            VStack(alignment: .leading, spacing: 0) {
                settingsToggleRow(
                    title: "Interface sounds",
                    subtitle: "Play focus, selection, back, and boundary feedback.",
                    isOn: $settings.interfaceSoundsEnabled
                )

                Divider()
                    .background(MarqueeTheme.textTertiary.opacity(0.3))
                    .padding(.horizontal, 20)

                settingsToggleRow(
                    title: "Launch ident",
                    subtitle: "Play the Marquee ident once when the profile picker opens at launch.",
                    isOn: $settings.launchIdentEnabled
                )

                Divider()
                    .background(MarqueeTheme.textTertiary.opacity(0.3))
                    .padding(.horizontal, 20)

                soundPackPickerRow
            }
            .background(
                RoundedRectangle(cornerRadius: MarqueeTheme.cornerRadiusMD)
                    .fill(MarqueeTheme.surfaceLayer)
            )
        }
    }

    private var soundPackPickerRow: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                Text(AudioIdentityPickerPolicy.title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(MarqueeTheme.textPrimary)
                Text("Choose one complete set of launch and remote-feedback cues.")
                    .font(.system(size: 12))
                    .foregroundColor(MarqueeTheme.textSecondary)
            }

            Spacer()

            Picker(AudioIdentityPickerPolicy.title, selection: $settings.soundPack) {
                Text("Choose a pack").tag(nil as AudioIdentitySoundPack?)
                ForEach(AudioIdentityPickerPolicy.options) { pack in
                    Text(pack.displayName).tag(Optional(pack))
                }
            }
            .labelsHidden()
            .frame(width: 180)
            .tint(MarqueeTheme.structuralFocus)
            .accentColor(MarqueeTheme.structuralFocus)
            .focused($soundPackPickerFocused)
            .accessibilityLabel(AudioIdentityPickerPolicy.title)
            .accessibilityHint(AudioIdentityPickerPolicy.accessibilityHint)
            .onChange(of: settings.soundPack) { _ in
                AudioIdentityService.shared.play(.select)
            }
            #if DEBUG
            .onReceive(NotificationCenter.default.publisher(for: .marqueeQASelectSoundPack)) { notification in
                guard let rawValue = notification.object as? String,
                      let pack = AudioIdentitySoundPack(rawValue: rawValue) else { return }
                soundPackPickerFocused = true
                settings.soundPack = pack
            }
            #endif
        }
        .padding(20)
    }

    private var subtitleSizeRow: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Subtitle Size")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(MarqueeTheme.textPrimary)
                Text("Scales sidecar subtitle overlays during playback.")
                    .font(.system(size: 12))
                    .foregroundColor(MarqueeTheme.textSecondary)
            }

            Spacer()

            Slider(value: $settings.subtitleScale, in: 0.8...2.2, step: 0.05)
                .tint(MarqueeTheme.accentPrimary)
                .frame(width: 180)

            Text("\(Int((settings.subtitleScale * 100).rounded()))%")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(MarqueeTheme.textTertiary)
                .frame(width: 46, alignment: .trailing)
        }
        .padding(20)
    }

    private func settingsPickerRow(title: String, selection: Binding<String>, options: [String]) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(MarqueeTheme.textPrimary)

            Spacer()

            Picker("", selection: selection) {
                ForEach(options, id: \.self) { language in
                    Text(language).tag(language)
                }
            }
            .labelsHidden()
            .frame(width: 160)
        }
        .padding(20)
    }

    // MARK: - Storage Section

    private var storageSection: some View {
        settingsSection(
            title: "Storage",
            subtitle: "Inspect local cache state, clear private history, and export diagnostics when needed.",
            icon: "internaldrive.fill",
            accent: MarqueeTheme.textSecondary
        ) {
            VStack(alignment: .leading, spacing: 0) {
                imageCacheRow
                Divider()
                    .background(MarqueeTheme.textTertiary.opacity(0.3))
                    .padding(.horizontal, 20)
                watchHistoryRow
                Divider()
                    .background(MarqueeTheme.textTertiary.opacity(0.3))
                    .padding(.horizontal, 20)
                diagnosticsRow
            }
            .background(
                RoundedRectangle(cornerRadius: MarqueeTheme.cornerRadiusMD)
                    .fill(MarqueeTheme.surfaceLayer)
            )
        }
    }

    private var imageCacheRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Image Cache")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(MarqueeTheme.textPrimary)
                Text(imageCacheDiagnosticsSummary)
                    .font(.system(size: 12))
                    .foregroundColor(MarqueeTheme.textSecondary)
            }

            Spacer()

            Text(imageCacheSize)
                .font(.system(size: 12))
                .foregroundColor(MarqueeTheme.textTertiary)
                .padding(.trailing, 12)

            Button(action: calculateImageCacheSize) {
                if isCalculatingImageCacheSize {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.66)
                        .frame(width: 24, height: 24)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(MarqueeTheme.textSecondary)
                        .frame(width: 24, height: 24)
                }
            }
            .buttonStyle(.plain)
            .disabled(isCalculatingImageCacheSize)
            .help("Measure image cache size")
            .padding(.trailing, 8)

            if showClearCacheConfirmation {
                HStack(spacing: 8) {
                    Button(action: {
                        clearImageCache()
                        withAnimation(MarqueeTheme.motion(MarqueeTheme.quickControlAnimation, reduceMotion: reduceMotion)) {
                            showClearCacheConfirmation = false
                        }
                    }) {
                        Text("Clear")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Color.red.opacity(0.8)))
                    }
                    .buttonStyle(.plain)

                    Button(action: {
                        withAnimation(MarqueeTheme.motion(MarqueeTheme.quickControlAnimation, reduceMotion: reduceMotion)) {
                            showClearCacheConfirmation = false
                        }
                    }) {
                        Text("Cancel")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(MarqueeTheme.textSecondary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(MarqueeTheme.surfaceElevated))
                    }
                    .buttonStyle(.plain)
                }
                .transition(.opacity)
            } else if cacheCleared {
                Text("Cleared")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(MarqueeTheme.accentSecondary)
                    .transition(.opacity)
            } else {
                Button(action: {
                    withAnimation(MarqueeTheme.motion(MarqueeTheme.quickControlAnimation, reduceMotion: reduceMotion)) {
                        showClearCacheConfirmation = true
                    }
                }) {
                    Text("Clear Cache")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(MarqueeTheme.textPrimary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(MarqueeTheme.surfaceElevated))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(20)
    }

    private var imageCacheDiagnosticsSummary: String {
        let diagnostics = ImageDecodePipeline.shared.diagnostics()
        return "Disk \(imageCacheSize.lowercased()). Memory \(diagnostics.memoryCacheCount) decoded images. Hits \(diagnostics.cacheHits), misses \(diagnostics.cacheMisses), decode failures \(diagnostics.decodeFailures)."
    }

    private var imageCacheOverviewValue: String {
        if isCalculatingImageCacheSize { return "Measuring..." }
        if imageCacheSize != "Not measured" { return imageCacheSize }

        let diagnostics = ImageDecodePipeline.shared.diagnostics()
        if diagnostics.memoryCacheCount > 0 {
            return "\(diagnostics.memoryCacheCount) images"
        }
        return "Ready"
    }

    private var watchHistoryRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Watch History")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(MarqueeTheme.textPrimary)
                Text("Clears Continue Watching, Recently Watched, and all saved playback positions.")
                    .font(.system(size: 12))
                    .foregroundColor(MarqueeTheme.textSecondary)
            }

            Spacer()

            if showClearConfirmation {
                HStack(spacing: 8) {
                    Button(action: {
                        library.clearWatchHistory()
                        withAnimation(MarqueeTheme.motion(MarqueeTheme.quickControlAnimation, reduceMotion: reduceMotion)) {
                            showClearConfirmation = false
                            historyCleared = true
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                            withAnimation(MarqueeTheme.motion(MarqueeTheme.quickControlAnimation, reduceMotion: reduceMotion)) {
                                historyCleared = false
                            }
                        }
                    }) {
                        Text("Clear")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Color.red.opacity(0.8)))
                    }
                    .buttonStyle(.plain)

                    Button(action: {
                        withAnimation(MarqueeTheme.motion(MarqueeTheme.quickControlAnimation, reduceMotion: reduceMotion)) {
                            showClearConfirmation = false
                        }
                    }) {
                        Text("Cancel")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(MarqueeTheme.textSecondary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(MarqueeTheme.surfaceElevated))
                    }
                    .buttonStyle(.plain)
                }
                .transition(.opacity)
            } else if historyCleared {
                Text("Cleared")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(MarqueeTheme.accentSecondary)
                    .transition(.opacity)
            } else {
                Button(action: {
                    withAnimation(MarqueeTheme.motion(MarqueeTheme.quickControlAnimation, reduceMotion: reduceMotion)) {
                        showClearConfirmation = true
                    }
                }) {
                    Text("Clear History")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(MarqueeTheme.textPrimary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(MarqueeTheme.surfaceElevated))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(20)
    }

    private var diagnosticsRow: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Crash Diagnostics")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(MarqueeTheme.textPrimary)
                Text("Exports recent Marquee crash reports and app details for debugging.")
                    .font(.system(size: 12))
                    .foregroundColor(MarqueeTheme.textSecondary)

                if let path = diagnosticsExportedPath {
                    Text("Saved: \(path)")
                        .font(.system(size: 11))
                        .foregroundColor(MarqueeTheme.accentSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.top, 3)
                } else if let error = diagnosticsExportFailed {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundColor(.red.opacity(0.85))
                        .lineLimit(2)
                        .padding(.top, 3)
                }
            }

            Spacer()

            Button(action: exportDiagnostics) {
                HStack(spacing: 6) {
                    if isExportingDiagnostics {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.7)
                    } else {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    Text(isExportingDiagnostics ? "Exporting..." : "Export")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundColor(MarqueeTheme.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .background(Capsule().fill(MarqueeTheme.surfaceElevated))
            }
            .buttonStyle(.plain)
            .disabled(isExportingDiagnostics)
        }
        .padding(20)
    }

    // MARK: - About Section

    private var aboutSection: some View {
        settingsSection(
            title: "About",
            subtitle: "Build identity for the local macOS screening room.",
            icon: "sparkles",
            accent: MarqueeTheme.accentSecondary
        ) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 16) {
                    Text("Marquee")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(MarqueeTheme.titleGradient)

                    Spacer()

                    Text("Version \(appVersion)")
                        .font(.system(size: 13))
                        .foregroundColor(MarqueeTheme.textTertiary)
                }

                Text("Premium Home Theater")
                    .font(.system(size: 13))
                    .foregroundColor(MarqueeTheme.textSecondary)
            }
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: MarqueeTheme.cornerRadiusMD)
                    .fill(MarqueeTheme.surfaceLayer)
            )
        }
    }

    private func settingsSection<Content: View>(
        title: String,
        subtitle: String,
        icon: String,
        accent: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: MarqueeTheme.scaled(12, leanBack: 18, isLeanBack: leanBackMode)) {
            HStack(alignment: .top, spacing: MarqueeTheme.scaled(12, leanBack: 18, isLeanBack: leanBackMode)) {
                Image(systemName: icon)
                    .font(.system(size: MarqueeTheme.scaled(14, leanBack: 21, isLeanBack: leanBackMode), weight: .semibold))
                    .foregroundColor(accent)
                    .frame(
                        width: MarqueeTheme.scaled(30, leanBack: 44, isLeanBack: leanBackMode),
                        height: MarqueeTheme.scaled(30, leanBack: 44, isLeanBack: leanBackMode)
                    )
                    .background(
                        RoundedRectangle(cornerRadius: MarqueeTheme.cornerRadiusMD)
                            .fill(accent.opacity(0.13))
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: MarqueeTheme.scaled(18, leanBack: 26, isLeanBack: leanBackMode), weight: .bold))
                        .foregroundColor(MarqueeTheme.textPrimary)

                    Text(subtitle)
                        .font(.system(size: MarqueeTheme.scaled(12, leanBack: 17, isLeanBack: leanBackMode), weight: .medium))
                        .foregroundColor(MarqueeTheme.textSecondary)
                        .lineLimit(2)
                }
            }

            content()
                .overlay(
                    RoundedRectangle(cornerRadius: MarqueeTheme.cornerRadiusMD)
                        .strokeBorder(Color.white.opacity(0.045), lineWidth: 1)
                )
        }
    }

    // MARK: - Helpers

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    // MARK: - Image Cache Management

    private func calculateImageCacheSize() {
        guard !isCalculatingImageCacheSize else { return }
        isCalculatingImageCacheSize = true
        cacheSizeGeneration += 1
        let generation = cacheSizeGeneration

        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            let appSupport = Configuration.appSupportDirectory
            let appCache = Configuration.appCacheDirectory

            let dirs = [
                appSupport.appendingPathComponent("images"),
                appSupport.appendingPathComponent("thumbs"),
                appCache.appendingPathComponent("images"),
                appCache.appendingPathComponent("thumbs"),
                Configuration.artworkCacheDirectory,
            ]

            var totalBytes: Int64 = 0
            for dir in dirs {
                if let enumerator = fm.enumerator(
                    at: dir,
                    includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) {
                    for case let fileURL as URL in enumerator {
                        let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                        guard values?.isRegularFile == true else { continue }
                        if let size = values?.fileSize {
                            totalBytes += Int64(size)
                        }
                    }
                }
            }

            let formatted = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
            DispatchQueue.main.async {
                guard generation == cacheSizeGeneration else { return }
                imageCacheSize = formatted
                isCalculatingImageCacheSize = false
            }
        }
    }

    private func clearImageCache() {
        cacheSizeGeneration += 1
        isCalculatingImageCacheSize = false

        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            let appSupport = Configuration.appSupportDirectory
            let appCache = Configuration.appCacheDirectory

            let dirs = [
                appSupport.appendingPathComponent("images"),
                appSupport.appendingPathComponent("thumbs"),
                appCache.appendingPathComponent("images"),
                appCache.appendingPathComponent("thumbs"),
            ]

            for dir in dirs {
                if let contents = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                    for file in contents {
                        try? fm.removeItem(at: file)
                    }
                }
            }
            ArtworkCache.shared.resetArtworkCache()
            ImageMemoryCache.shared.removeAll()

            DispatchQueue.main.async {
                imageCacheSize = "Zero KB"
                cacheCleared = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    withAnimation(MarqueeTheme.motion(MarqueeTheme.quickControlAnimation, reduceMotion: reduceMotion)) {
                        cacheCleared = false
                    }
                }
            }
        }
    }

    private func exportDiagnostics() {
        diagnosticsExportedPath = nil
        diagnosticsExportFailed = nil
        isExportingDiagnostics = true

        DispatchQueue.global(qos: .utility).async {
            do {
                let url = try DiagnosticsCollector.writeSnapshot()
                DispatchQueue.main.async {
                    diagnosticsExportedPath = url.path
                    isExportingDiagnostics = false
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            } catch {
                DispatchQueue.main.async {
                    diagnosticsExportFailed = "Export failed: \(error.localizedDescription)"
                    isExportingDiagnostics = false
                }
            }
        }
    }
}

#if DEBUG
extension Notification.Name {
    static let marqueeQASelectSoundPack = Notification.Name("marquee.qa.select-sound-pack")
}
#endif

private struct SettingsRemoteEscapeCatcher: NSViewRepresentable {
    var onExit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onExit: onExit)
    }

    func makeNSView(context: Context) -> SettingsRemoteEscapeCatcherView {
        let view = SettingsRemoteEscapeCatcherView()
        context.coordinator.view = view
        context.coordinator.installMonitorIfNeeded()
        return view
    }

    func updateNSView(_ nsView: SettingsRemoteEscapeCatcherView, context: Context) {
        context.coordinator.onExit = onExit
        context.coordinator.view = nsView
        context.coordinator.installMonitorIfNeeded()
    }

    static func dismantleNSView(_ nsView: SettingsRemoteEscapeCatcherView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    final class Coordinator {
        var onExit: () -> Void
        weak var view: SettingsRemoteEscapeCatcherView?
        private var monitor: Any?

        init(onExit: @escaping () -> Void) {
            self.onExit = onExit
        }

        deinit {
            removeMonitor()
        }

        func installMonitorIfNeeded() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.shouldHandle(event) else {
                    return event
                }

                let reservedModifiers: NSEvent.ModifierFlags = [.command, .control, .option]
                guard event.modifierFlags.intersection(reservedModifiers).isEmpty else {
                    return event
                }

                guard event.keyCode == 53 || event.keyCode == 123 else {
                    return event
                }

                self.onExit()
                return nil
            }
        }

        func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        private func shouldHandle(_ event: NSEvent) -> Bool {
            guard let view, let window = view.window, window.isKeyWindow else { return false }
            if let eventWindow = event.window, eventWindow !== window {
                return false
            }
            return view.isVisibleInHierarchy
        }
    }
}

private final class SettingsRemoteEscapeCatcherView: NSView {
    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

private extension NSView {
    var isVisibleInHierarchy: Bool {
        if isHidden { return false }
        var ancestor = superview
        while let view = ancestor {
            if view.isHidden { return false }
            ancestor = view.superview
        }
        return true
    }
}
