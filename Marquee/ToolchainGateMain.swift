import Foundation

@main
struct MarqueeToolchainGate {
    static func main() async {
        VerifyFocusEngineHarness.runIfRequested()
        VerifyDetailFocusHarness.runIfRequested()
        VerifyRemoteInputHarness.runIfRequested()
        VerifyRemoteInputHarness.runPolicyOnlyIfRequested()
        VerifyConfigurationHarness.runIfRequested()
        VerifyDiagnosticsHarness.runIfRequested()
        VerifyScanRequestGateHarness.runIfRequested()
        VerifyLegacyImportHarness.runIfRequested()
        VerifyTransactionHarness.runIfRequested()
        VerifyScannerHarness.runIfRequested()
        VerifyProjectionHarness.runIfRequested()
        VerifyEnrichmentHarness.runIfRequested()
        VerifyEnrichmentActorHarness.runIfRequested()
        VerifyVolumeRegistryHarness.runIfRequested()
        VerifyDurationProbeHarness.runIfRequested()
        VerifyFilenameParserHarness.runIfRequested()
        VerifySearchInputBufferHarness.runIfRequested()
        VerifySearchResultsUpdatePolicyHarness.runIfRequested()
        VerifySearchRemoteKeyboardHarness.runIfRequested()
        VerifySearchFieldResponderSyncHarness.runIfRequested()
        VerifySearchKeyboardEventRoutingHarness.runIfRequested()
        VerifySearchSessionHarness.runIfRequested()
        VerifyPlaybackHarness.runIfRequested()
        VerifySubtitleHarness.runIfRequested()
        VerifyImagePipelineHarness.runIfRequested()
        VerifyAudioIdentityHarness.runIfRequested()
        VerifyVisualQAFixtureHarness.runIfRequested()
        VerifyBrowseSnapshotHarness.runIfRequested()
        VerifyProfilePickerHarness.runIfRequested()
        VerifyProfilePickerFocusTreeHarness.runIfRequested()

        if CommandLine.arguments.contains(VerifyProfilePickerHarness.launchArgument) {
            // The profile-picker harness exits from a MainActor task; keep the
            // process alive until it does.
            while true { try? await Task.sleep(nanoseconds: 1_000_000_000) }
        }

        FileHandle.standardError.write(Data(
            "marquee-toolchain-gate: no recognized harness argument\n".utf8
        ))
        exit(2)
    }
}
