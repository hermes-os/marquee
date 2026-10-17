import Combine
import SwiftUI
import UniformTypeIdentifiers

@main
struct MarqueeApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    init() {
        #if DEBUG
        VerifySearchInputBufferHarness.runIfRequested()
        VerifySearchResultsUpdatePolicyHarness.runIfRequested()
        VerifySearchRemoteKeyboardHarness.runIfRequested()
        VerifySearchFieldResponderSyncHarness.runIfRequested()
        VerifySearchKeyboardEventRoutingHarness.runIfRequested()
        VerifySearchSessionHarness.runIfRequested()
        #endif
        #if DEBUG && !QA_NO_HARNESSES
        VerifyDiagnosticsHarness.runIfRequested()
        VerifyPlaybackHarness.runIfRequested()
        VerifySubtitleHarness.runIfRequested()
        VerifyLegacyImportHarness.runIfRequested()
        VerifyTransactionHarness.runIfRequested()
        VerifyVolumeRegistryHarness.runIfRequested()
        VerifyScannerHarness.runIfRequested()
        VerifyProjectionHarness.runIfRequested()
        VerifyEnrichmentHarness.runIfRequested()
        VerifyEnrichmentActorHarness.runIfRequested()
        VerifyDurationProbeHarness.runIfRequested()
        VerifyRemoteInputHarness.runIfRequested()
        VerifyProfilePickerFocusTreeHarness.runIfRequested()
        VerifyProfilePickerHarness.runIfRequested()
        VerifyBrowseSnapshotHarness.runIfRequested()
        VerifyFocusEngineHarness.runIfRequested()
        VerifyDetailFocusHarness.runIfRequested()
        VerifyAudioIdentityHarness.runIfRequested()
        VerifyImagePipelineHarness.runIfRequested()
        VerifyScanRequestGateHarness.runIfRequested()
        VerifyFilenameParserHarness.runIfRequested()
        VerifyVisualQAFixtureHarness.runIfRequested()
        VerifyConfigurationHarness.runIfRequested()
        #endif
        AppDelegate.appStateRef = nil
    }

    var body: some Scene {
        WindowGroup {
            ContentView(appState: appState)
                .preferredColorScheme(.dark)
                .onAppear {
                    AppDelegate.appStateRef = appState
                }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Open...") {
                    openFile()
                }
                .keyboardShortcut("o", modifiers: .command)
            }
            CommandGroup(after: .textEditing) {
                Button("Search Library") {
                    guard ProfileExitTransitionPolicy.acceptsInput(
                        isExitInFlight: appState.isProfileExitInFlight
                    ) else { return }
                    SearchInputBuffer.shared.beginCapture()
                    NotificationCenter.default.post(name: .marqueeActivateSearch, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)
            }
        }
    }

    // MARK: - File Opening

    private func openFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = videoContentTypes

        guard panel.runModal() == .OK, let url = panel.url else { return }
        appState.playFile(at: url.path)
    }

    private var videoContentTypes: [UTType] {
        [
            UTType(filenameExtension: "mp4"),
            UTType(filenameExtension: "m4v"),
            UTType(filenameExtension: "mov"),
            UTType(filenameExtension: "avi"),
            UTType(filenameExtension: "ts"),
            UTType(filenameExtension: "mpg"),
            UTType(filenameExtension: "mpeg"),
            UTType(filenameExtension: "m2ts"),
            UTType(filenameExtension: "vob"),
            UTType(filenameExtension: "mkv"),
            UTType(filenameExtension: "webm"),
        ].compactMap { $0 }
    }
}

// MARK: - Notification Names
