import Foundation

// MARK: - SubtitleFormat

enum SubtitleFormat: String, CaseIterable {
    case srt
    case ass
    case ssa
    case vtt

    var displayLabel: String {
        rawValue.uppercased()
    }

    static let supportedExtensions: Set<String> = Set(allCases.map(\.rawValue))
}

// MARK: - DiscoveredSubtitle

struct DiscoveredSubtitle {
    let path: String
    let language: String?
    let format: SubtitleFormat
    let displayName: String
}

// MARK: - SubtitleDiscovery

enum SubtitleDiscovery {

    // MARK: - Public

    static func discover(forVideoAt path: String) -> [DiscoveredSubtitle] {
        let videoURL = URL(fileURLWithPath: path)
        let videoBaseName = videoURL.deletingPathExtension().lastPathComponent
        let parentDirectory = videoURL.deletingLastPathComponent()

        var results: [DiscoveredSubtitle] = []

        let directoriesToScan = gatherScanDirectories(parent: parentDirectory)

        for directory in directoriesToScan {
            let candidates = subtitleFiles(in: directory)
            for candidate in candidates {
                guard let match = matchSubtitle(candidate, videoBaseName: videoBaseName) else {
                    continue
                }
                results.append(match)
            }
        }

        MarqueeLogger.player.info("Discovered \(results.count) external subtitle(s) for \(videoBaseName)")
        return results
    }

    // MARK: - Directory Scanning

    private static func gatherScanDirectories(parent: URL) -> [URL] {
        var directories = [parent]
        var seenIdentities: Set<String> = [scanIdentity(of: parent)]

        let subfolderNames = ["Subs", "subs", "Subtitles", "subtitles"]
        let fileManager = FileManager.default

        for name in subfolderNames {
            let subURL = parent.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: subURL.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            // Scan the resolved directory: enumerating through the symlink
            // itself yields nothing on some Foundation implementations.
            let resolved = subURL.standardizedFileURL.resolvingSymlinksInPath()
            if seenIdentities.insert(scanIdentity(of: resolved)).inserted {
                directories.append(resolved)
            }
        }

        return directories
    }

    /// On a case-insensitive volume the Subs/subs probes hit the same directory,
    /// and a symlink alias reaches it under yet another name; scanning it more
    /// than once would duplicate every sidecar in the picker. Path strings are
    /// case-preserving, so identity comes from the file system itself.
    private static func scanIdentity(of url: URL) -> String {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        if let attributes = try? FileManager.default.attributesOfItem(atPath: resolved.path),
           let device = attributes[.systemNumber] as? NSNumber,
           let inode = attributes[.systemFileNumber] as? NSNumber {
            return "\(device.uint64Value):\(inode.uint64Value)"
        }
        return resolved.path
    }

    private static func subtitleFiles(in directory: URL) -> [URL] {
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        return contents.filter { url in
            SubtitleFormat.supportedExtensions.contains(url.pathExtension.lowercased())
        }
    }

    // MARK: - Matching

    private static func matchSubtitle(_ fileURL: URL, videoBaseName: String) -> DiscoveredSubtitle? {
        let fileName = fileURL.deletingPathExtension().lastPathComponent
        let ext = fileURL.pathExtension.lowercased()

        guard let format = SubtitleFormat(rawValue: ext) else { return nil }

        guard fileName.lowercased().hasPrefix(videoBaseName.lowercased()) else {
            return nil
        }

        let suffix = String(fileName.dropFirst(videoBaseName.count))
        if let firstSuffixChar = suffix.first {
            let separators: Set<Character> = [".", "_", "-", " "]
            guard separators.contains(firstSuffixChar) else { return nil }
        }
        let language = parseLanguageCode(from: suffix)

        let displayName = buildDisplayName(language: language, format: format)

        return DiscoveredSubtitle(
            path: fileURL.path,
            language: language,
            format: format,
            displayName: displayName
        )
    }

    // MARK: - Language Code Parsing

    private static func parseLanguageCode(from suffix: String) -> String? {
        let trimmed = suffix.trimmingCharacters(in: CharacterSet(charactersIn: "._ -"))
        guard !trimmed.isEmpty else { return nil }

        let components = trimmed.components(separatedBy: CharacterSet(charactersIn: "._- "))
        guard let code = components.first, !code.isEmpty else { return nil }

        let lowered = code.lowercased()

        if let name = iso639_1Map[lowered] {
            return name
        }
        if let name = iso639_2Map[lowered] {
            return name
        }

        return nil
    }

    private static func buildDisplayName(language: String?, format: SubtitleFormat) -> String {
        if let language = language {
            return "\(language) (\(format.displayLabel))"
        }
        return "External (\(format.displayLabel))"
    }

    // MARK: - Language Code Maps

    private static let iso639_1Map: [String: String] = [
        "en": "English",
        "es": "Spanish",
        "fr": "French",
        "de": "German",
        "it": "Italian",
        "pt": "Portuguese",
        "ru": "Russian",
        "ja": "Japanese",
        "ko": "Korean",
        "zh": "Chinese",
        "ar": "Arabic",
        "hi": "Hindi",
        "nl": "Dutch",
        "sv": "Swedish",
        "no": "Norwegian",
        "da": "Danish",
        "fi": "Finnish",
        "pl": "Polish",
        "cs": "Czech",
        "hu": "Hungarian",
        "ro": "Romanian",
        "tr": "Turkish",
        "el": "Greek",
        "he": "Hebrew",
        "th": "Thai",
        "vi": "Vietnamese",
        "id": "Indonesian",
        "ms": "Malay",
        "uk": "Ukrainian",
        "bg": "Bulgarian",
        "hr": "Croatian",
        "sk": "Slovak",
        "sl": "Slovenian",
        "sr": "Serbian",
        "lt": "Lithuanian",
        "lv": "Latvian",
        "et": "Estonian",
    ]

    private static let iso639_2Map: [String: String] = [
        "eng": "English",
        "spa": "Spanish",
        "fre": "French",
        "fra": "French",
        "ger": "German",
        "deu": "German",
        "ita": "Italian",
        "por": "Portuguese",
        "rus": "Russian",
        "jpn": "Japanese",
        "kor": "Korean",
        "chi": "Chinese",
        "zho": "Chinese",
        "ara": "Arabic",
        "hin": "Hindi",
        "dut": "Dutch",
        "nld": "Dutch",
        "swe": "Swedish",
        "nor": "Norwegian",
        "dan": "Danish",
        "fin": "Finnish",
        "pol": "Polish",
        "cze": "Czech",
        "ces": "Czech",
        "hun": "Hungarian",
        "rum": "Romanian",
        "ron": "Romanian",
        "tur": "Turkish",
        "gre": "Greek",
        "ell": "Greek",
        "heb": "Hebrew",
        "tha": "Thai",
        "vie": "Vietnamese",
        "ind": "Indonesian",
        "may": "Malay",
        "msa": "Malay",
        "ukr": "Ukrainian",
        "bul": "Bulgarian",
        "hrv": "Croatian",
        "slo": "Slovak",
        "slk": "Slovak",
        "slv": "Slovenian",
        "srp": "Serbian",
        "lit": "Lithuanian",
        "lav": "Latvian",
        "est": "Estonian",
    ]
}
