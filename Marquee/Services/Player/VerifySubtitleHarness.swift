//
//  VerifySubtitleHarness.swift
//  Marquee
//
//  DEBUG-only verification for sidecar subtitle discovery and SRT parsing.
//  Activated by `--verify-subtitles`.
//

#if DEBUG

import Foundation

enum VerifySubtitleHarness {
    static let launchArgument = "--verify-subtitles"

    static func runIfRequested() {
        guard CommandLine.arguments.contains(launchArgument) else { return }

        let results = [
            scenarioParsesStandardCues(),
            scenarioSplitsCuesOnWhitespaceOnlySeparator(),
            scenarioKeepsNonBreakingSpaceLineInsideCue(),
            scenarioEndsCueAtInteriorSpaceOnlyLine(),
            scenarioDecodesUTF16LittleEndianFile(),
            scenarioDecodesUTF16BigEndianFile(),
            scenarioDropsMalformedBlocks(),
            scenarioOrdersEntriesByStartTime(),
            scenarioReturnsNoEntriesForUnreadableFile(),
            scenarioDiscoversSeparatedSidecars(),
            scenarioScansAliasedSubtitleDirectoryOnce()
        ]

        for result in results {
            let status = result.passed ? "PASS" : "FAIL"
            emit("verify-subtitles: \(status) \(result.name): \(result.detail)")
        }

        let passed = results.filter(\.passed).count
        if passed == results.count {
            emit("verify-subtitles: outcome=verified passed=\(passed)/\(results.count)")
            exit(0)
        } else {
            emit("verify-subtitles: outcome=failed passed=\(passed)/\(results.count)")
            exit(1)
        }
    }

    // MARK: - SRT Parsing

    private static func scenarioParsesStandardCues() -> ScenarioResult {
        let name = "parsesStandardCues"
        let srt = [
            "1",
            "00:00:01,000 --> 00:00:02,500",
            "<i>Hello</i>",
            "there",
            "",
            "2",
            "00:01:00,250 --> 00:01:02,000",
            "World",
            ""
        ].joined(separator: "\r\n")

        do {
            let entries = try parse(srt, name: name)
            guard entries.count == 2 else {
                return fail(name, "expected 2 entries, got \(entries.count)")
            }
            guard entries[0].startTime == 1.0, entries[0].endTime == 2.5,
                  entries[1].startTime == 60.25, entries[1].endTime == 62.0 else {
                return fail(name, "timestamps=\(describe(entries))")
            }
            guard entries[0].text == "Hello\nthere", entries[1].text == "World" else {
                return fail(name, "text=\(describe(entries))")
            }
            return pass(name, "CRLF cues parsed with tags stripped and multi-line text preserved")
        } catch {
            return fail(name, "\(error)")
        }
    }

    private static func scenarioSplitsCuesOnWhitespaceOnlySeparator() -> ScenarioResult {
        let name = "splitsCuesOnWhitespaceOnlySeparator"
        let srt = [
            "1",
            "00:00:01,000 --> 00:00:02,000",
            "Hello",
            "   ",
            "2",
            "00:00:03,000 --> 00:00:04,000",
            "World",
            ""
        ].joined(separator: "\n")

        do {
            let entries = try parse(srt, name: name)
            guard entries.count == 2 else {
                return fail(name, "expected 2 entries, got \(entries.count): \(describe(entries))")
            }
            guard entries[0].text == "Hello", entries[1].text == "World" else {
                return fail(name, "text=\(describe(entries))")
            }
            return pass(name, "a separator line carrying spaces still ends the cue")
        } catch {
            return fail(name, "\(error)")
        }
    }

    private static func scenarioKeepsNonBreakingSpaceLineInsideCue() -> ScenarioResult {
        let name = "keepsNonBreakingSpaceLineInsideCue"
        let srt = [
            "1",
            "00:00:01,000 --> 00:00:02,000",
            "Hello",
            "\u{00A0}",
            "World",
            "",
            "2",
            "00:00:03,000 --> 00:00:04,000",
            "Next",
            ""
        ].joined(separator: "\n")

        do {
            let entries = try parse(srt, name: name)
            guard entries.count == 2 else {
                return fail(name, "expected 2 entries, got \(entries.count): \(describe(entries))")
            }
            guard entries[0].text == "Hello\n\u{00A0}\nWorld", entries[1].text == "Next" else {
                return fail(name, "text=\(describe(entries))")
            }
            return pass(name, "a non-breaking-space line is cue content, not a separator")
        } catch {
            return fail(name, "\(error)")
        }
    }

    private static func scenarioEndsCueAtInteriorSpaceOnlyLine() -> ScenarioResult {
        let name = "endsCueAtInteriorSpaceOnlyLine"
        let srt = [
            "1",
            "00:00:01,000 --> 00:00:02,000",
            "Hello",
            " ",
            "World",
            "",
            "2",
            "00:00:03,000 --> 00:00:04,000",
            "Next",
            ""
        ].joined(separator: "\n")

        do {
            let entries = try parse(srt, name: name)
            guard entries.count == 2 else {
                return fail(name, "expected 2 entries, got \(entries.count): \(describe(entries))")
            }
            guard entries[0].text == "Hello", entries[1].text == "Next" else {
                return fail(name, "text=\(describe(entries))")
            }
            return pass(name, "a space-only line ends the cue and the timestampless remainder is dropped")
        } catch {
            return fail(name, "\(error)")
        }
    }

    private static func scenarioDecodesUTF16LittleEndianFile() -> ScenarioResult {
        utf16Scenario(
            name: "decodesUTF16LittleEndianFile",
            bom: [0xFF, 0xFE],
            encoding: .utf16LittleEndian
        )
    }

    private static func scenarioDecodesUTF16BigEndianFile() -> ScenarioResult {
        utf16Scenario(
            name: "decodesUTF16BigEndianFile",
            bom: [0xFE, 0xFF],
            encoding: .utf16BigEndian
        )
    }

    private static func utf16Scenario(
        name: String,
        bom: [UInt8],
        encoding: String.Encoding
    ) -> ScenarioResult {
        let srt = [
            "1",
            "00:00:05,000 --> 00:00:06,000",
            "¿Dónde estás?",
            ""
        ].joined(separator: "\n")

        do {
            let directory = try makeDirectory(name: name)
            defer { try? FileManager.default.removeItem(at: directory) }

            let url = directory.appendingPathComponent("cue.srt")
            guard let body = srt.data(using: encoding) else {
                return fail(name, "could not encode UTF-16 fixture")
            }
            var data = Data(bom)
            data.append(body)
            try data.write(to: url)

            let entries = SRTParser.parse(fileAt: url.path)
            guard entries.count == 1 else {
                return fail(name, "expected 1 entry, got \(entries.count)")
            }
            guard entries[0].text == "¿Dónde estás?", entries[0].startTime == 5.0 else {
                return fail(name, "entry=\(describe(entries))")
            }
            return pass(name, "UTF-16 sidecars decode instead of falling back to mojibake")
        } catch {
            return fail(name, "\(error)")
        }
    }

    private static func scenarioDropsMalformedBlocks() -> ScenarioResult {
        let name = "dropsMalformedBlocks"
        let malformedBlocks: [(shape: String, lines: [String])] = [
            ("header text", ["Downloaded from example"]),
            ("hex timestamp", ["1", "00:00:0X,000 --> 00:00:02,000", "Bad timestamp"]),
            ("inf timestamp", ["1", "00:00:inf,000 --> 00:00:02,000", "Not a number"]),
            ("bare nan timestamp", ["1", "00:00:nan --> 00:00:02,000", "NaN start would poison the sort"]),
            ("negative timestamp field", ["1", "00:00:-1,000 --> 00:00:02,000", "Signed field"]),
            ("plus-signed timestamp field", ["1", "00:00:+1,000 --> 00:00:02,000", "Signed field"]),
            ("empty text", ["1", "00:00:01,000 --> 00:00:02,000"])
        ]

        for malformed in malformedBlocks {
            let srt = (malformed.lines + [
                "",
                "2",
                "00:00:05,000 --> 00:00:06,000",
                "Good",
                ""
            ]).joined(separator: "\n")

            do {
                let entries = try parse(srt, name: name)
                guard entries.count == 1, entries[0].text == "Good", entries[0].startTime == 5.0 else {
                    return fail(name, "\(malformed.shape): expected only the well-formed cue, got \(describe(entries))")
                }
            } catch {
                return fail(name, "\(malformed.shape): \(error)")
            }
        }
        return pass(name, "each of \(malformedBlocks.count) malformed block shapes is skipped on its own")
    }

    private static func scenarioOrdersEntriesByStartTime() -> ScenarioResult {
        let name = "ordersEntriesByStartTime"
        let srt = [
            "2",
            "00:00:09,000 --> 00:00:10,000",
            "Second",
            "",
            "1",
            "00:00:07,000 --> 00:00:08,000",
            "First",
            ""
        ].joined(separator: "\n")

        do {
            let entries = try parse(srt, name: name)
            guard entries.map(\.text) == ["First", "Second"] else {
                return fail(name, "order=\(describe(entries))")
            }
            return pass(name, "out-of-order cues are sorted for the overlay's binary search")
        } catch {
            return fail(name, "\(error)")
        }
    }

    private static func scenarioReturnsNoEntriesForUnreadableFile() -> ScenarioResult {
        let name = "returnsNoEntriesForUnreadableFile"
        do {
            let directory = try makeDirectory(name: name)
            defer { try? FileManager.default.removeItem(at: directory) }

            let missing = directory.appendingPathComponent("absent.srt").path
            let entries = SRTParser.parse(fileAt: missing)
            guard entries.isEmpty else {
                return fail(name, "expected no entries, got \(entries.count)")
            }
            return pass(name, "a missing sidecar parses to no entries")
        } catch {
            return fail(name, "\(error)")
        }
    }

    // MARK: - Discovery

    private static func scenarioDiscoversSeparatedSidecars() -> ScenarioResult {
        let name = "discoversSeparatedSidecars"
        do {
            let directory = try makeDirectory(name: name)
            defer { try? FileManager.default.removeItem(at: directory) }

            let subs = directory.appendingPathComponent("Subs", isDirectory: true)
            try FileManager.default.createDirectory(at: subs, withIntermediateDirectories: true)

            let video = directory.appendingPathComponent("Example (2024).mkv")
            try Data().write(to: video)
            try Data().write(to: directory.appendingPathComponent("Example (2024).en.srt"))
            try Data().write(to: subs.appendingPathComponent("Example (2024).fre.ass"))
            try Data().write(to: directory.appendingPathComponent("Example (2024)2.srt"))
            try Data().write(to: directory.appendingPathComponent("Unrelated.srt"))

            let discovered = SubtitleDiscovery.discover(forVideoAt: video.path)
                .sorted { $0.path < $1.path }
            let summary = discovered.map { "\(URL(fileURLWithPath: $0.path).lastPathComponent)=\($0.displayName)" }
            guard discovered.count == 2 else {
                return fail(name, "expected 2 sidecars, got \(summary)")
            }
            guard discovered[0].language == "English", discovered[0].format == .srt,
                  discovered[1].language == "French", discovered[1].format == .ass else {
                return fail(name, "unexpected matches: \(summary)")
            }
            return pass(name, "matched \(summary.joined(separator: ", ")) and rejected unseparated and unrelated names")
        } catch {
            return fail(name, "\(error)")
        }
    }

    private static func scenarioScansAliasedSubtitleDirectoryOnce() -> ScenarioResult {
        let name = "scansAliasedSubtitleDirectoryOnce"
        do {
            let directory = try makeDirectory(name: name)
            defer { try? FileManager.default.removeItem(at: directory) }

            // The real directory sits outside the candidate names, so the scan
            // reaches it only through the two symlinks; deduplication must
            // resolve them to pass even on a case-sensitive volume.
            let store = directory.appendingPathComponent("sidecar-store", isDirectory: true)
            try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
            for alias in ["Subs", "subtitles"] {
                try FileManager.default.createSymbolicLink(
                    at: directory.appendingPathComponent(alias),
                    withDestinationURL: store
                )
            }

            let video = directory.appendingPathComponent("Example (2024).mkv")
            try Data().write(to: video)
            try Data().write(to: store.appendingPathComponent("Example (2024).en.srt"))

            let discovered = SubtitleDiscovery.discover(forVideoAt: video.path)
            let summary = discovered.map { "\(URL(fileURLWithPath: $0.path).lastPathComponent)=\($0.displayName)" }
            guard discovered.count == 1 else {
                return fail(name, "expected 1 sidecar, got \(summary)")
            }
            guard discovered[0].language == "English", discovered[0].format == .srt else {
                return fail(name, "unexpected match: \(summary)")
            }
            return pass(name, "a subtitle directory reachable under two candidate names is scanned once")
        } catch {
            return fail(name, "\(error)")
        }
    }

    // MARK: - Helpers

    private static func parse(_ contents: String, name: String) throws -> [SubtitleEntry] {
        let directory = try makeDirectory(name: name)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("cue.srt")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return SRTParser.parse(fileAt: url.path)
    }

    private static func makeDirectory(name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("marquee-subtitles-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func describe(_ entries: [SubtitleEntry]) -> String {
        entries.map { "[\($0.startTime)-\($0.endTime)]\($0.text.debugDescription)" }.joined(separator: " ")
    }

    private static func emit(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    private static func pass(_ name: String, _ detail: String) -> ScenarioResult {
        ScenarioResult(name: name, passed: true, detail: detail)
    }

    private static func fail(_ name: String, _ detail: String) -> ScenarioResult {
        ScenarioResult(name: name, passed: false, detail: detail)
    }

    private struct ScenarioResult {
        let name: String
        let passed: Bool
        let detail: String
    }
}

#endif
