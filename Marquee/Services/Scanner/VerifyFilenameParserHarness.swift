//
//  VerifyFilenameParserHarness.swift
//  Marquee
//
//  DEBUG-only verification for movie and episode filename parsing.
//  Activated by `--verify-filename-parser`.
//
//  Exit codes: 0 = all scenarios pass, 1 = at least one failed.
//

#if DEBUG

import Foundation

enum VerifyFilenameParserHarness {
    static let launchArgument = "--verify-filename-parser"
    private static let buddhistCalendarLaunchArgument =
        "--verify-filename-parser-buddhist-calendar"

    /// Year plausibility depends on "today", so the scenarios pin a fixed
    /// reference date; `Blade Runner 2049 -> no year` must not flip once
    /// the real 2048 arrives.
    private static let referenceDate = DateComponents(
        calendar: Calendar(identifier: .gregorian),
        year: 2026, month: 1, day: 1
    ).date!

    static func runIfRequested() {
        if CommandLine.arguments.contains(buddhistCalendarLaunchArgument) {
            runBuddhistCalendarProbe()
        }
        guard CommandLine.arguments.contains(launchArgument) else { return }

        var results: [Outcome] = []
        results.append(wrap("hyphenatedTitlesSurviveCleaning", runHyphenatedTitles))
        results.append(wrap("releaseGroupSuffixStillStripped", runReleaseGroupStrip))
        results.append(wrap("releaseYearWinsOverTitleNumerals", runReleaseYearSelection))
        results.append(wrap("releaseYearBoundUsesGregorianCalendar", runGregorianYearBound))
        results.append(wrap("qualityAndSourceTokensStripped", runQualityTokens))
        results.append(wrap("episodeTitlesKeepHyphens", runEpisodeTitles))

        for result in results {
            let mark = result.passed ? "PASS" : "FAIL"
            let line = "verify-filename-parser: \(mark) \(result.name): \(result.detail)\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
        let passed = results.filter { $0.passed }.count
        let allPassed = passed == results.count
        let summary = "verify-filename-parser: outcome="
            + (allPassed ? "verified" : "failed")
            + " passed=\(passed)/\(results.count)\n"
        FileHandle.standardError.write(Data(summary.utf8))
        exit(allPassed ? 0 : 1)
    }

    // MARK: - Scenarios

    /// A hyphen inside a title is not a release-group separator. These
    /// filenames used to lose everything from the hyphen onward.
    private static func runHyphenatedTitles() throws -> String {
        try expectMovie("Spider-Man (2002).mp4", title: "Spider-Man", year: 2002)
        try expectMovie("X-Men (2000).mkv", title: "X-Men", year: 2000)
        try expectMovie("WALL-E (2008).mp4", title: "WALL-E", year: 2008)
        try expectMovie("Killer-Drones.mkv", title: "Killer-Drones", year: nil)
        try expectMovie(
            "The X-Files - Fight the Future (1998).mkv",
            title: "The X-Files - Fight the Future",
            year: 1998
        )
        try expectMovie(
            "Mission Impossible - Fallout (2018).mp4",
            title: "Mission Impossible - Fallout",
            year: 2018
        )
        return "hyphenated titles and spelled-out subtitles are preserved"
    }

    private static func runReleaseGroupStrip() throws -> String {
        try expectMovie("Some Movie - YIFY.mkv", title: "Some Movie", year: nil)
        try expectMovie("Some Movie - Sparks.mkv", title: "Some Movie", year: nil)
        try expectMovie("Another Movie -RARBG.mkv", title: "Another Movie", year: nil)
        // Known groups are stripped even unspaced or lowercase.
        try expectMovie("Movie-RARBG.mkv", title: "Movie", year: nil)
        try expectMovie("Movie - yify.mkv", title: "Movie", year: nil)
        // A trailing Roman numeral is a sequel number, not a release group.
        try expectMovie("Rocky - II.mkv", title: "Rocky - II", year: nil)
        return "release tags are removed, sequel numerals and hyphens stay"
    }

    private static func runReleaseYearSelection() throws -> String {
        try expectMovie(
            "Blade Runner 2049.2017.1080p.BluRay.x264-GROUP.mkv",
            title: "Blade Runner 2049",
            year: 2017
        )
        try expectMovie("2012.2009.1080p.mkv", title: "2012", year: 2009)
        try expectMovie("1917.2019.BluRay.mkv", title: "1917", year: 2019)
        try expectMovie("Blade Runner 2049 (2017).mkv", title: "Blade Runner 2049", year: 2017)
        // A year after an edition tag is edition metadata; the release year
        // is the last plausible year before the metadata tail.
        try expectMovie("The.Matrix.1999.REMASTERED.2008.mkv", title: "The Matrix", year: 1999)
        try expectMovie("The Matrix 1999 REMASTERED 2008.mkv", title: "The Matrix", year: 1999)
        return "the last plausible year before release metadata wins"
    }

    private static func runGregorianYearBound() throws -> String {
        #if os(macOS)
        guard let executableURL = Bundle.main.executableURL else {
            throw HarnessError.assertion("app executable is unavailable")
        }
        let process = Process()
        process.executableURL = executableURL
        process.arguments = [
            "-AppleLocale", "en_US@calendar=buddhist",
            buddhistCalendarLaunchArgument,
        ]
        try process.run()
        process.waitUntilExit()
        try expect(
            process.terminationReason == .exit && process.terminationStatus == 0,
            "Buddhist-calendar parser probe exited with status \(process.terminationStatus)"
        )
        #else
        let buddhistYear = Calendar(identifier: .buddhist)
            .component(.year, from: referenceDate)
        try expect(
            buddhistYear > 2049,
            "Buddhist reference year was \(buddhistYear), expected it above 2049"
        )
        try expectMovie("Blade Runner 2049.mkv", title: "Blade Runner 2049", year: nil)
        #endif
        return "release-year plausibility stays Gregorian under a Buddhist calendar"
    }

    private static func runBuddhistCalendarProbe() -> Never {
        let parsed = FilenameParser.parse("Blade Runner 2049.mkv", referenceDate: referenceDate)
        let passed = Calendar.current.identifier == .buddhist
            && parsed.title == "Blade Runner 2049"
            && parsed.year == nil
        exit(passed ? 0 : 1)
    }

    private static func runQualityTokens() throws -> String {
        try expectMovie(
            "The.Matrix.1999.1080p.BluRay.x264-RARBG.mkv",
            title: "The Matrix",
            year: 1999
        )
        try expectMovie("Movie Title 1080p BluRay.mp4", title: "Movie Title", year: nil)
        try expectMovie("Interstellar.mkv", title: "Interstellar", year: nil)
        return "resolution, source, and codec tails are removed"
    }

    private static func runEpisodeTitles() throws -> String {
        try expectEpisode(
            "Show - S01E02 - Spider-Man.mkv",
            showName: "Show",
            season: 1,
            episode: 2,
            episodeTitle: "Spider-Man"
        )
        try expectEpisode(
            "The.Office.S03E01.Gay.Witch.Hunt.1080p.mkv",
            showName: "The Office",
            season: 3,
            episode: 1,
            episodeTitle: "Gay Witch Hunt"
        )

        let folderParsed = FilenameParser.parseEpisodeFromFolder(
            "S01E01 Joe Pera Shows You Iron.mkv",
            seasonNumber: 1
        )
        guard let folderParsed else {
            throw HarnessError.assertion("season-folder episode should parse")
        }
        try expect(
            folderParsed.episodeNumber == 1 && folderParsed.episodeTitle == "Joe Pera Shows You Iron",
            "season-folder episode parsed as e\(folderParsed.episodeNumber) "
                + "title=\(folderParsed.episodeTitle ?? "nil")"
        )
        return "episode titles keep hyphenated words after cleaning"
    }

    // MARK: - Assertions

    private static func expectMovie(
        _ filename: String,
        title expectedTitle: String,
        year expectedYear: Int?
    ) throws {
        let parsed = FilenameParser.parse(filename, referenceDate: referenceDate)
        try expect(
            parsed.title == expectedTitle && parsed.year == expectedYear,
            "\(filename) parsed as title=\(parsed.title) "
                + "year=\(parsed.year.map(String.init) ?? "nil"), expected "
                + "title=\(expectedTitle) year=\(expectedYear.map(String.init) ?? "nil")"
        )
    }

    private static func expectEpisode(
        _ filename: String,
        showName: String,
        season: Int,
        episode: Int,
        episodeTitle: String?
    ) throws {
        guard let parsed = FilenameParser.parseEpisode(filename) else {
            throw HarnessError.assertion("\(filename) did not parse as an episode")
        }
        try expect(
            parsed.showName == showName
                && parsed.seasonNumber == season
                && parsed.episodeNumber == episode
                && parsed.episodeTitle == episodeTitle,
            "\(filename) parsed as show=\(parsed.showName) "
                + "s\(parsed.seasonNumber)e\(parsed.episodeNumber) "
                + "title=\(parsed.episodeTitle ?? "nil")"
        )
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition {
            throw HarnessError.assertion(message)
        }
    }

    private struct Outcome {
        let name: String
        let passed: Bool
        let detail: String
    }

    private static func wrap(_ name: String, _ body: () throws -> String) -> Outcome {
        do {
            return Outcome(name: name, passed: true, detail: try body())
        } catch {
            return Outcome(name: name, passed: false, detail: "\(error)")
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
