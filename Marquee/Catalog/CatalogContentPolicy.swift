//
//  CatalogContentPolicy.swift
//  Marquee
//
//  Stateless content and sidecar policy used by catalog projection and
//  enrichment so a single change cannot drift those paths apart.
//
//  Scope:
//    - Folder-name + filename filters that decide which files are
//      treated as user-visible library entries (extras / featurettes /
//      tmp / `s01e01ex01`-style extras-with-anchor).
//    - Sidecar artwork discovery (poster.jpg, fanart.jpg, folder.jpg,
//      `<base> poster.jpg`, `<base>-poster.jpg`) at the movie-folder,
//      show-folder, season-folder, and per-episode still scopes.
//    - TV structure detection (season-folder regex, show-folder
//      derivation, show-folder name parse).
//    - Genre inference from the first subfolder under the configured
//      library root, gated by `knownGenres`.
//
//  Out of scope (intentionally):
//    - Scanner-only concerns (video extension filter and filesystem diffing).
//    - Duration probing and remote-provider transport.
//    - Projection-only concerns (volume-relative path resolution,
//      `matchingLibraryRoot`, watch-state attach).
//
//  Pure functions, no I/O caching, no state — safe to call from any
//  thread or actor. `find*SidecarImages` does hit the filesystem via
//  `FileManager.fileExists(atPath:)`, which both call sites already
//  did before this extraction; behavior is byte-for-byte preserved.
//

import Foundation

enum CatalogContentPolicy {

    // MARK: - Folder-policy filter

    /// Folder names whose contents are excluded from the library.
    /// Matches the union of the two pre-extraction sets: scanner
    /// previously checked `temp`/`tmp` separately from its `skipFolders`
    /// set; projection had them in a single set. Behaviorally identical
    /// — both are case-insensitive ancestor-component matches.
    static let excludedFolders: Set<String> = [
        "featurettes", "extras", "deleted scenes", "bonus",
        "behind the scenes", "special features", "interviews",
        "trailers", "samples", "temp", "tmp"
    ]

    /// True if any *ancestor folder* of `fileURL` is in `excludedFolders`.
    /// The file itself is excluded from the check — only folder
    /// ancestry counts.
    static func pathContainsExcludedFolder(_ fileURL: URL) -> Bool {
        let folders = fileURL.deletingLastPathComponent().pathComponents
            .map { $0.lowercased() }
        return folders.contains(where: { excludedFolders.contains($0) })
    }

    static func pathContainsExcludedFolder(_ absolutePath: String) -> Bool {
        pathContainsExcludedFolder(URL(fileURLWithPath: absolutePath))
    }

    /// True if the filename itself signals an extra: ` extra `,
    /// ` extras `, leading `extra `, or `s\d+ex\d+` (per-show extras
    /// anchor used by some Plex naming conventions).
    static func fileNameLooksLikeExtra(_ fileName: String) -> Bool {
        let lower = fileName.lowercased()
        if lower.contains(" extra ") || lower.contains(" extras ")
            || lower.hasPrefix("extra ") {
            return true
        }
        if lower.range(
            of: #"s\d+ex\d+"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil {
            return true
        }
        return false
    }

    static func fileNameLooksLikeExtra(_ fileURL: URL) -> Bool {
        fileNameLooksLikeExtra(fileURL.lastPathComponent)
    }

    static func fileNameLooksLikeExtraFromPath(_ absolutePath: String) -> Bool {
        fileNameLooksLikeExtra((absolutePath as NSString).lastPathComponent)
    }

    // MARK: - Sidecar artwork discovery

    static let imageExtensions = ["jpg", "jpeg", "png", "webp"]

    /// Look for sidecar poster + backdrop next to a video file. Search
    /// order (first hit wins per slot):
    /// poster: `poster.<ext>`, `folder.<ext>`, `<base> poster.<ext>`,
    ///         `<base>-poster.<ext>`
    /// backdrop: `fanart.<ext>`, `backdrop.<ext>`, `<base> fanart.<ext>`,
    ///           `<base> backdrop.<ext>`
    static func findSidecarImages(
        for videoURL: URL
    ) -> (posterPath: String?, backdropPath: String?) {
        let directory = videoURL.deletingLastPathComponent()
        let baseName = videoURL.deletingPathExtension().lastPathComponent
        let fm = FileManager.default

        var posterPath: String?
        var backdropPath: String?

        for ext in imageExtensions {
            if posterPath == nil {
                let path = directory.appendingPathComponent("poster.\(ext)").path
                if fm.fileExists(atPath: path) { posterPath = path }
            }
            if posterPath == nil {
                let path = directory.appendingPathComponent("folder.\(ext)").path
                if fm.fileExists(atPath: path) { posterPath = path }
            }
            if posterPath == nil {
                let path = directory.appendingPathComponent("\(baseName) poster.\(ext)").path
                if fm.fileExists(atPath: path) { posterPath = path }
            }
            if posterPath == nil {
                let path = directory.appendingPathComponent("\(baseName)-poster.\(ext)").path
                if fm.fileExists(atPath: path) { posterPath = path }
            }

            if backdropPath == nil {
                let path = directory.appendingPathComponent("fanart.\(ext)").path
                if fm.fileExists(atPath: path) { backdropPath = path }
            }
            if backdropPath == nil {
                let path = directory.appendingPathComponent("backdrop.\(ext)").path
                if fm.fileExists(atPath: path) { backdropPath = path }
            }
            if backdropPath == nil {
                let path = directory.appendingPathComponent("\(baseName) fanart.\(ext)").path
                if fm.fileExists(atPath: path) { backdropPath = path }
            }
            if backdropPath == nil {
                let path = directory.appendingPathComponent("\(baseName) backdrop.\(ext)").path
                if fm.fileExists(atPath: path) { backdropPath = path }
            }
        }

        return (posterPath, backdropPath)
    }

    /// Look for an episode-specific still next to the video file.
    /// This intentionally avoids folder-level names like `fanart.jpg` so
    /// one season backdrop cannot masquerade as every episode thumbnail.
    static func findEpisodeStillSidecar(for videoURL: URL) -> String? {
        let directory = videoURL.deletingLastPathComponent()
        let baseName = videoURL.deletingPathExtension().lastPathComponent
        let fm = FileManager.default

        for ext in imageExtensions {
            let candidates = [
                "\(baseName).\(ext)",
                "\(baseName)-still.\(ext)",
                "\(baseName) still.\(ext)",
                "\(baseName)-screenshot.\(ext)",
                "\(baseName) screenshot.\(ext)",
                "\(baseName)-thumb.\(ext)",
                "\(baseName) thumb.\(ext)"
            ]

            for candidate in candidates {
                let path = directory.appendingPathComponent(candidate).path
                if fm.fileExists(atPath: path) { return path }
            }
        }

        return nil
    }

    /// Show-folder sidecar discovery (no `<base>` variants).
    static func findShowSidecarImages(
        for showFolder: URL
    ) -> (posterPath: String?, backdropPath: String?) {
        findFolderSidecarImages(for: showFolder)
    }

    /// Season-folder sidecar discovery (no `<base>` variants).
    static func findSeasonSidecarImages(
        for seasonFolder: URL
    ) -> (posterPath: String?, backdropPath: String?) {
        findFolderSidecarImages(for: seasonFolder)
    }

    private static func findFolderSidecarImages(
        for folder: URL
    ) -> (posterPath: String?, backdropPath: String?) {
        let fm = FileManager.default
        var posterPath: String?
        var backdropPath: String?

        for ext in imageExtensions {
            if posterPath == nil {
                let path = folder.appendingPathComponent("poster.\(ext)").path
                if fm.fileExists(atPath: path) { posterPath = path }
            }
            if posterPath == nil {
                let path = folder.appendingPathComponent("folder.\(ext)").path
                if fm.fileExists(atPath: path) { posterPath = path }
            }
            if backdropPath == nil {
                let path = folder.appendingPathComponent("fanart.\(ext)").path
                if fm.fileExists(atPath: path) { backdropPath = path }
            }
            if backdropPath == nil {
                let path = folder.appendingPathComponent("backdrop.\(ext)").path
                if fm.fileExists(atPath: path) { backdropPath = path }
            }
        }

        return (posterPath, backdropPath)
    }

    // MARK: - TV structure detection

    /// Returns the season number if any path component matches
    /// `Season N` (case-insensitive, optional whitespace).
    static func seasonNumberFromPath(_ fileURL: URL) -> Int? {
        let regex = try? NSRegularExpression(pattern: #"^[Ss]eason\s*(\d+)$"#)
        for component in fileURL.pathComponents {
            let nsRange = NSRange(component.startIndex..., in: component)
            if let match = regex?.firstMatch(in: component, range: nsRange),
               let numRange = Range(match.range(at: 1), in: component) {
                return Int(component[numRange])
            }
        }
        return nil
    }

    /// Walks `fileURL`'s components looking for the first `Season N`
    /// folder, then returns the URL of the folder *above* it (the show
    /// folder) rebased onto `rootDirectory`. Falls back to two
    /// directories up from the file if no `Season N` component is
    /// present.
    static func showFolderURL(
        for fileURL: URL,
        rootDirectory: URL
    ) -> URL {
        let seasonPattern = try? NSRegularExpression(pattern: #"^[Ss]eason\s*\d+$"#)
        let components = fileURL.pathComponents

        for (idx, comp) in components.enumerated() {
            let nsRange = NSRange(comp.startIndex..., in: comp)
            if let match = seasonPattern?.firstMatch(in: comp, range: nsRange),
               match.range.length == nsRange.length,
               idx > 0 {
                var showURL = rootDirectory
                let rootCount = rootDirectory.pathComponents.count
                if idx - 1 >= rootCount {
                    for i in rootCount..<idx {
                        showURL = showURL.appendingPathComponent(components[i])
                    }
                }
                return showURL
            }
        }

        let seasonDir = fileURL.deletingLastPathComponent()
        return seasonDir.deletingLastPathComponent()
    }

    /// Parses a show folder name like `The Wire (2002)` → (`The Wire`,
    /// 2002). Show folders use the Plex standard `Title (YYYY)` shape,
    /// so we parse it directly here rather than routing through
    /// `FilenameParser.parse`, whose release-tag and quality cleaning
    /// exists for file names, not folder names.
    static func parseShowFolderName(_ showFolder: URL) -> (name: String, year: Int?)? {
        let folderName = showFolder.lastPathComponent
        let pattern = #"^(.+?)\s*\((\d{4})\)\s*$"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(
               in: folderName,
               range: NSRange(folderName.startIndex..., in: folderName)
           ),
           let titleRange = Range(match.range(at: 1), in: folderName),
           let yearRange = Range(match.range(at: 2), in: folderName) {
            let title = String(folderName[titleRange])
                .trimmingCharacters(in: .whitespaces)
            let year = Int(folderName[yearRange])
            return (name: title, year: year)
        }

        let trimmed = folderName.trimmingCharacters(in: .whitespaces)
        return (name: trimmed, year: nil)
    }

    // MARK: - Genre inference

    static let knownGenres: Set<String> = [
        "action", "adventure", "animation", "anime", "biography",
        "comedy", "crime", "documentary", "drama", "family",
        "fantasy", "film noir", "history", "horror", "kids",
        "holiday", "music", "musical", "mystery", "romance", "sci-fi",
        "science fiction", "sport", "sports", "suspense", "thriller",
        "war", "western"
    ]

    /// If the first subfolder under `rootDirectory` (i.e. the immediate
    /// child folder containing the file) is a known genre name,
    /// returns it capitalized. Otherwise nil.
    static func inferGenre(
        for fileURL: URL,
        rootDirectory: URL
    ) -> String? {
        let rootComponents = rootDirectory.pathComponents
        let fileComponents = fileURL.pathComponents

        guard fileComponents.count > rootComponents.count + 1 else { return nil }

        let firstSubfolder = fileComponents[rootComponents.count]

        if knownGenres.contains(firstSubfolder.lowercased()) {
            return firstSubfolder.capitalized
        }
        return nil
    }

    static func localGenres(
        folderGenre: String?,
        offlineTitleGenres: [String]
    ) -> [String] {
        uniqueGenres((folderGenre.map { [$0] } ?? []) + offlineTitleGenres)
    }

    static func localMovieGenres(
        folderGenre: String?,
        movieTitle title: String
    ) -> [String] {
        localGenres(
            folderGenre: folderGenre,
            offlineTitleGenres: inferOfflineMovieGenres(forMovieTitle: title)
        )
    }

    static func inferOfflineMovieGenres(forMovieTitle title: String) -> [String] {
        let key = normalizedOfflineLookupTitle(title)
        var inferred: [String] = []

        if containsAny(key, animatedMovieSignals) {
            inferred.append("Animation")
        }
        if containsAny(key, adventureMovieSignals) {
            inferred.append("Adventure")
        }
        if containsAny(key, comedyMovieSignals) {
            inferred.append("Comedy")
        }
        if containsAny(key, fantasyMovieSignals) {
            inferred.append("Fantasy")
        }
        if containsAny(key, scienceFictionMovieSignals) {
            inferred.append("Science Fiction")
        }
        if containsAny(key, sportsMovieSignals) {
            inferred.append("Sports")
        }
        if containsAny(key, musicMovieSignals) {
            inferred.append("Music")
        }
        if containsAny(key, holidayMovieSignals) {
            inferred.append("Holiday")
        }
        if containsAny(key, dramaMovieSignals) {
            inferred.append("Drama")
        }

        return uniqueGenres(inferred)
    }

    static func inferOfflineTVGenres(forShowTitle title: String) -> [String] {
        let key = normalizedOfflineLookupTitle(title)
        if let mapped = offlineTVGenreMap[key] {
            return mapped
        }

        var inferred: [String] = []
        if key.contains("star trek") {
            inferred += ["Science Fiction", "Adventure"]
        }
        if key.contains("science")
            || key.contains("history")
            || key.contains("ancient")
            || key.contains("declassified")
            || key.contains("files") {
            inferred.append("Documentary")
        }
        if key.contains("school") || key.contains("kids") {
            inferred += ["Kids", "Family"]
        }
        if key.contains("animated") {
            inferred.append("Animation")
        }
        return uniqueGenres(inferred)
    }

    private static let animatedMovieSignals = [
        "abominable", "aladdin", "alvin and the chipmunks", "bambi",
        "beauty and the beast", "bee movie", "big hero 6", "boss baby",
        "brave", "bug s life", "cars", "castle in the sky", "cinderella",
        "coco", "croods", "despicable me", "dumbo", "elemental", "encanto",
        "emperor s new groove", "fantastic mr fox", "finding dory",
        "finding nemo", "frozen", "ice age", "incredibles", "inside out",
        "iron giant", "jungle book", "klaus", "kung fu panda", "lion king",
        "lilo stitch", "little mermaid", "luca", "madagascar", "megamind",
        "minions", "mitchells vs the machines", "moana", "monsters inc",
        "monsters university", "monsters vs aliens", "my neighbor totoro",
        "onward", "over the hedge", "penguins of madagascar",
        "princess mononoke", "puss in boots", "ralph breaks the internet",
        "ratatouille", "rise of the guardians", "shrek", "soul",
        "spirited away", "spirit stallion", "tangled", "the bad guys",
        "the wild robot", "toy story", "treasure planet", "trolls", "turbo",
        "turning red", "up", "wall e", "wallace gromit", "wreck it ralph",
        "zootopia"
    ]

    private static let adventureMovieSignals = [
        "alice in wonderland", "aliens in the attic", "borrowers",
        "castle in the sky", "chronicles of narnia", "duma", "escape from",
        "explorers", "goonies", "gulliver", "honey i shrunk",
        "how to train your dragon", "hugo", "indian in the cupboard",
        "jumanji", "mighty joe young", "nim s island", "neverending story",
        "oz the great", "pagemaster", "peter pan", "princess bride",
        "rocketeer", "spy kids", "stardust", "swiss family robinson",
        "the water horse", "treasure planet", "zathura"
    ]

    private static let comedyMovieSignals = [
        "alvin and the chipmunks", "baby s day out", "bean", "bee movie",
        "charlie and the chocolate factory", "dennis the menace",
        "despicable me", "elf", "freaky friday", "game plan",
        "home alone", "honey i", "jingle all the way", "little rascals",
        "major payne", "matilda", "minions", "mousehunt", "mr bean",
        "mrs doubtfire", "paddington", "problem child", "richie rich",
        "school of rock", "shrek", "tooth fairy"
    ]

    private static let fantasyMovieSignals = [
        "alice in wonderland", "casper", "chronicles of narnia",
        "enchanted", "hocus pocus", "hook", "how the grinch",
        "indian in the cupboard", "lemony snicket", "neverending story",
        "oz the great", "pagemaster", "peter pan", "princess bride",
        "santa clause", "spiderwick", "stardust", "tooth fairy",
        "wizard of oz"
    ]

    private static let scienceFictionMovieSignals = [
        "aliens in the attic", "escape from planet earth", "e t",
        "explorers", "iron giant", "megamind", "monsters vs aliens",
        "treasure planet", "wall e", "zathura"
    ]

    private static let sportsMovieSignals = [
        "cars", "game plan", "hoosiers", "little giants", "sandlot",
        "space jam", "turbo"
    ]

    private static let musicMovieSignals = [
        "aladdin", "beauty and the beast", "coco", "encanto", "frozen",
        "lion king", "mary poppins", "moana", "music man", "little mermaid",
        "sound of music", "trolls"
    ]

    private static let holidayMovieSignals = [
        "christmas", "elf", "frozen", "grinch", "home alone",
        "it s a wonderful life", "jingle all the way", "klaus",
        "santa clause"
    ]

    private static let dramaMovieSignals = [
        "a little princess", "children of heaven", "free willy", "jack",
        "old yeller", "secondhand lions", "sound of music", "wonder"
    ]

    private static let offlineTVGenreMap: [String: [String]] = [
        "american godfathers the five families": ["Documentary", "Crime"],
        "ancient aliens": ["Documentary", "History"],
        "bill nye the science guy": ["Kids", "Family", "Documentary"],
        "bluey": ["Kids", "Animation", "Family"],
        "captain planet and the planeteers": ["Kids", "Animation", "Family", "Adventure"],
        "fallout": ["Drama", "Action", "Science Fiction"],
        "fosters home for imaginary friends": ["Kids", "Animation", "Comedy", "Family"],
        "game of thrones": ["Drama", "Fantasy"],
        "hey arnold": ["Kids", "Animation", "Comedy", "Family"],
        "holy marvels with dennis quaid": ["Documentary", "History"],
        "hunting hitler": ["Documentary", "History"],
        "joe pera talks with you": ["Comedy"],
        "king of the hill": ["Animation", "Comedy"],
        "outlander": ["Drama", "Romance"],
        "secrets declassified with david duchovny": ["Documentary", "History"],
        "seinfeld": ["Comedy"],
        "star trek deep space nine": ["Science Fiction", "Adventure", "Drama"],
        "star trek the next generation": ["Science Fiction", "Adventure", "Drama"],
        "star trek the original series": ["Science Fiction", "Adventure", "Drama"],
        "the magic school bus": ["Kids", "Animation", "Family", "Documentary"],
        "the office us": ["Comedy"],
        "the simpsons": ["Animation", "Comedy"],
        "the why files": ["Documentary", "Mystery"],
        "the x files": ["Drama", "Mystery", "Science Fiction"],
        "tuttle twins": ["Kids", "Animation", "Family"]
    ]

    private static func normalizedOfflineLookupTitle(_ title: String) -> String {
        let withoutYear = title.replacingOccurrences(
            of: #"\s*\(\d{4}\)\s*$"#,
            with: "",
            options: .regularExpression
        )
        let withoutPossessives = withoutYear.replacingOccurrences(
            of: #"['’]"#,
            with: "",
            options: .regularExpression
        )
        let scalars = withoutPossessives.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(scalars)
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private static func containsAny(_ key: String, _ signals: [String]) -> Bool {
        signals.contains { key.contains($0) }
    }

    private static func uniqueGenres(_ genres: [String]) -> [String] {
        var seen: Set<String> = []
        return genres.compactMap { rawGenre in
            let genre = rawGenre.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !genre.isEmpty else { return nil }
            let key = genre.lowercased()
            guard seen.insert(key).inserted else { return nil }
            return genre
        }
    }
}
