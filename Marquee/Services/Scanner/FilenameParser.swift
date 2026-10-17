import Foundation

// MARK: - FilenameParser

enum FilenameParser {
    private static let cleanTitleRegexes: [NSRegularExpression] = [
        #"\s*\(?\d{3,4}p\b[^)]*\)?"#,
        #"\s*\(?(?:x26[45]|h\.?26[45]|[Hh][Ee][Vv][Cc]|AVC|AAC|AC3|DTS|FLAC)\s*[^)]*\)?"#,
        #"\s*\(?(?:DVD|Blu-?[Rr]ay|BDRip|WEB[-.]?DL|HDRip|WEBRip|HDTV)\s*[^)]*\)?"#,
        #"\s*[\[\(][^\]\)]+[\]\)]$"#,
        // Known release-group handles lose the tag whatever the dash spacing
        // or case (`Movie-RARBG`, `Movie - yify`).
        #"(?i)\s*-\s*(?:yify|yts(?:\.[a-z]{2})?|rarbg|etrg|ettv|eztv|evo|fgt|axxo|anoxmous)$"#,
        // Dictionary-like group names require a spaced dash so title words
        // such as `Killer-Drones` survive.
        #"(?i)\s+-\s*(?:sparks|geckos|amiable|drones)$"#,
        // Generic release-group suffix. The dash must be spaced and the tag
        // uppercase, so hyphenated titles (`Spider-Man`, `WALL-E`) and
        // spelled-out subtitles (`- Fallout`) survive. Trailing Roman
        // numerals are sequel numbers (`Rocky - II`), not release groups.
        #"\s+-\s*(?![IVXLCDM]+$)[A-Z0-9]{2,}$"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    private static let episodeRegexes: [NSRegularExpression] = [
        // Show - S01E01E02 - Episode Title
        #"^(.+?)\s*-\s*[Ss](\d{1,2})[Ee](\d{1,4})[Ee]\d{1,2}\s*-\s*(.+)$"#,
        // Show - S01E01 - Episode Title
        #"^(.+?)\s*-\s*[Ss](\d{1,2})[Ee](\d{1,4})\s*-\s*(.+)$"#,
        // Show - S01E01
        #"^(.+?)\s*-\s*[Ss](\d{1,2})[Ee](\d{1,4})\s*$"#,
        // Show.S01E01E02 Episode Title / Show S01E01E02 Episode Title
        #"^(.+?)[.\s_][Ss](\d{1,2})[Ee](\d{1,4})[Ee]\d{1,2}(?:[.\s_-]+(.+))?$"#,
        // Show.S01E01 Episode Title / Show S01E01
        #"^(.+?)[.\s_][Ss](\d{1,2})[Ee](\d{1,4})(?:[.\s_-]+(.+))?$"#,
        // Show - S01 E01 (space between S and E)
        #"^(.+?)\s*-\s*[Ss](\d{1,2})\s+[Ee](\d{1,4})\s*-\s*(.+)$"#,
        // Show S01 E01 (space between S and E, no dashes)
        #"^(.+?)[.\s_][Ss](\d{1,2})\s+[Ee](\d{1,4})"#,
        // Show - 1x01 - Episode Title
        #"^(.+?)\s*-\s*(\d{1,2})x(\d{2,3})\s*-\s*(.+)$"#,
        // Show - 1x01
        #"^(.+?)\s*-\s*(\d{1,2})x(\d{2,3})\s*$"#,
        // Show.1x01 / Show 1x01
        #"^(.+?)[.\s_](\d{1,2})x(\d{2,3})"#,
        // Show Season 1 Episode 01 [optional extra numbering]
        #"^(.+?)\s+[Ss]eason\s+(\d{1,2})\s+[Ee]pisode\s+(\d{1,4})"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    private static let prefixedEpisodeRegex = try! NSRegularExpression(
        pattern: #"^[Ss](\d{1,2})[Ee](\d{1,4})(?:[.\s_-]+(.+))?$"#
    )

    private static let bareEpisodeRegex = try! NSRegularExpression(
        pattern: #"^(.+?)\s+(\d{1})(\d{2})(?:\s+(.+))?$"#
    )

    private static let plexMovieRegex = try! NSRegularExpression(
        pattern: #"^(.+?)\s*\((\d{4})\)$"#
    )

    private static let dottedMovieRegex = try! NSRegularExpression(
        pattern: #"[.\s_](\d{4})(?=[.\s_]|$)"#
    )

    /// Release metadata (resolution, source, codec, or edition tags) ends
    /// the title-and-year region of a scene-style name; a year after it is
    /// edition metadata (`The.Matrix.1999.REMASTERED.2008`), not the
    /// release year.
    private static let releaseMetadataRegex = try! NSRegularExpression(
        pattern: #"(?i)[.\s_\-(](?:\d{3,4}p|x26[45]|h\.?26[45]|hevc|avc|aac|ac3|dts|flac|blu-?ray|bd-?rip|web-?(?:dl|rip)|hd-?rip|hdtv|dvd(?:rip)?|remaster(?:ed)?|extended|unrated|theatrical|director'?s|remux|proper|repack|internal|limited|imax|criterion)(?=[.\s_\-)]|$)"#
    )

    /// A release year cannot be far in the future, so a later four-digit
    /// token belongs to the title (`Blade Runner 2049.2017` is the 2017
    /// release of `Blade Runner 2049`).
    private static func isPlausibleReleaseYear(_ year: Int, at referenceDate: Date) -> Bool {
        year >= 1888
            && year <= Calendar(identifier: .gregorian).component(.year, from: referenceDate) + 1
    }

    // MARK: - Parsed Result

    struct ParsedFilename {
        let title: String
        let year: Int?
    }

    struct ParsedEpisode {
        let showName: String
        let seasonNumber: Int
        let episodeNumber: Int
        let episodeTitle: String?
        let year: Int?
    }

    // MARK: - Title Cleaning

    private static func cleanTitle(_ title: String) -> String {
        var cleaned = title
        for regex in cleanTitleRegexes {
            cleaned = replaceMatches(in: cleaned, regex: regex)
        }
        return cleaned.trimmingCharacters(in: .whitespaces)
    }

    private static func replaceMatches(
        in value: String,
        regex: NSRegularExpression,
        template: String = ""
    ) -> String {
        let range = NSRange(value.startIndex..., in: value)
        return regex.stringByReplacingMatches(
            in: value,
            options: [],
            range: range,
            withTemplate: template
        )
    }

    private static func cleanEpisodeTitle(_ title: String) -> String {
        let normalized = title
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "_", with: " ")
        return cleanTitle(normalized)
    }

    // MARK: - Episode Parse

    static func parseEpisode(_ filename: String) -> ParsedEpisode? {
        let name = (filename as NSString).deletingPathExtension

        for regex in episodeRegexes {
            let nsRange = NSRange(name.startIndex..., in: name)
            guard let match = regex.firstMatch(in: name, range: nsRange) else { continue }

            guard let showRange = Range(match.range(at: 1), in: name),
                  let seasonRange = Range(match.range(at: 2), in: name),
                  let episodeRange = Range(match.range(at: 3), in: name) else { continue }

            let rawShow = String(name[showRange])
                .replacingOccurrences(of: ".", with: " ")
                .replacingOccurrences(of: "_", with: " ")
                .trimmingCharacters(in: .whitespaces)

            guard let season = Int(name[seasonRange]),
                  let episode = Int(name[episodeRange]) else { continue }

            var episodeTitle: String?
            if match.numberOfRanges > 4 {
                if let titleRange = Range(match.range(at: 4), in: name) {
                    let raw = String(name[titleRange]).trimmingCharacters(in: .whitespaces)
                    let cleaned = cleanEpisodeTitle(raw)
                    episodeTitle = cleaned.isEmpty ? nil : cleaned
                }
            }

            return ParsedEpisode(
                showName: rawShow,
                seasonNumber: season,
                episodeNumber: episode,
                episodeTitle: episodeTitle,
                year: nil
            )
        }

        return nil
    }

    // MARK: - Episode Parse from Season Folder Context

    static func parseEpisodeFromFolder(_ filename: String, seasonNumber: Int) -> ParsedEpisode? {
        let name = (filename as NSString).deletingPathExtension

        // SXXEXX [Title] — filename leads with the season/episode code and
        // the show name is implicit from the parent folder.
        // e.g. "S01E01 Joe Pera Shows You Iron" inside "Joe Pera Talks
        // With You (2018)/Season 1/".
        if let match = prefixedEpisodeRegex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) {

            guard let sRange = Range(match.range(at: 1), in: name),
                  let eRange = Range(match.range(at: 2), in: name) else { return nil }

            guard let season = Int(name[sRange]),
                  let episode = Int(name[eRange]),
                  season == seasonNumber else { return nil }

            var episodeTitle: String?
            if match.numberOfRanges > 3,
               let titleRange = Range(match.range(at: 3), in: name) {
                let raw = String(name[titleRange]).trimmingCharacters(in: .whitespaces)
                let cleaned = cleanEpisodeTitle(raw)
                episodeTitle = cleaned.isEmpty ? nil : cleaned
            }

            return ParsedEpisode(
                showName: "",
                seasonNumber: season,
                episodeNumber: episode,
                episodeTitle: episodeTitle,
                year: nil
            )
        }

        // Show Name NNN where first digit(s) = season, remaining = episode
        // e.g. "Foster's Home 501 Title" where season folder says Season 5
        if let match = bareEpisodeRegex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) {

            guard let showRange = Range(match.range(at: 1), in: name),
                  let sRange = Range(match.range(at: 2), in: name),
                  let eRange = Range(match.range(at: 3), in: name) else { return nil }

            let rawShow = String(name[showRange])
                .replacingOccurrences(of: ".", with: " ")
                .replacingOccurrences(of: "_", with: " ")
                .trimmingCharacters(in: .whitespaces)

            guard let season = Int(name[sRange]),
                  let episode = Int(name[eRange]),
                  season == seasonNumber else { return nil }

            var episodeTitle: String?
            if match.numberOfRanges > 4,
               let titleRange = Range(match.range(at: 4), in: name) {
                let raw = String(name[titleRange]).trimmingCharacters(in: .whitespaces)
                let cleaned = cleanEpisodeTitle(raw)
                episodeTitle = cleaned.isEmpty ? nil : cleaned
            }

            return ParsedEpisode(
                showName: rawShow,
                seasonNumber: season,
                episodeNumber: episode,
                episodeTitle: episodeTitle,
                year: nil
            )
        }

        return nil
    }

    // MARK: - Movie Parse

    static func parse(_ filename: String, referenceDate: Date = Date()) -> ParsedFilename {
        let nameWithoutExtension = (filename as NSString).deletingPathExtension

        // Pattern: "Title (Year)" — Plex standard
        let nsRange = NSRange(nameWithoutExtension.startIndex..., in: nameWithoutExtension)
        if let result = plexMovieRegex.firstMatch(in: nameWithoutExtension, range: nsRange) {
            let titleRange = Range(result.range(at: 1), in: nameWithoutExtension)
            let yearRange = Range(result.range(at: 2), in: nameWithoutExtension)
            if let titleRange = titleRange {
                let rawTitle = String(nameWithoutExtension[titleRange]).trimmingCharacters(in: .whitespaces)
                let title = cleanTitle(rawTitle)
                let year = yearRange.flatMap { Int(nameWithoutExtension[$0]) }
                return ParsedFilename(title: title.isEmpty ? rawTitle : title, year: year)
            }
        }

        // Pattern: "Title.Year" or "Title Year" with dots/underscores as
        // spaces. The scan stops at the first release-metadata token so an
        // edition year after it (`...1999.REMASTERED.2008`) is not chosen;
        // within that bound the last plausible year wins so numerals that
        // are part of the title keep their place ahead of the release year.
        // When the only plausible year sits inside the metadata tail, the
        // first one is still better than none.
        let metadataBound = releaseMetadataRegex
            .firstMatch(in: nameWithoutExtension, range: nsRange)?
            .range.location ?? nsRange.length
        let plausibleYearMatches = dottedMovieRegex
            .matches(in: nameWithoutExtension, range: nsRange)
            .filter { match in
                guard let yearRange = Range(match.range(at: 1), in: nameWithoutExtension),
                      let year = Int(nameWithoutExtension[yearRange]) else { return false }
                return isPlausibleReleaseYear(year, at: referenceDate)
            }
        let releaseYearMatch = plausibleYearMatches.last { $0.range.location < metadataBound }
            ?? plausibleYearMatches.first
        if let result = releaseYearMatch,
           let separatorRange = Range(result.range, in: nameWithoutExtension),
           let yearRange = Range(result.range(at: 1), in: nameWithoutExtension) {
            let rawTitle = String(nameWithoutExtension[..<separatorRange.lowerBound])
                .replacingOccurrences(of: ".", with: " ")
                .replacingOccurrences(of: "_", with: " ")
                .trimmingCharacters(in: .whitespaces)
            if !rawTitle.isEmpty {
                let title = cleanTitle(rawTitle)
                let year = Int(nameWithoutExtension[yearRange])
                return ParsedFilename(title: title.isEmpty ? rawTitle : title, year: year)
            }
        }

        // Fallback: use filename as title, clean up dots/underscores
        let cleaned = nameWithoutExtension
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespaces)
        let fallback = cleanTitle(cleaned)
        return ParsedFilename(title: fallback.isEmpty ? cleaned : fallback, year: nil)
    }
}
