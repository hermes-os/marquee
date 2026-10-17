import Foundation

// MARK: - SRTParser

enum SRTParser {

    // MARK: - Public

    static func parse(fileAt path: String) -> [SubtitleEntry] {
        guard let content = readFileContent(at: path) else {
            MarqueeLogger.player.error("Failed to read subtitle file at \(path)")
            return []
        }

        let cleaned = stripBOM(content)
        let blocks = splitIntoBlocks(cleaned)
        var entries: [SubtitleEntry] = []

        for block in blocks {
            if let entry = parseBlock(block) {
                entries.append(entry)
            }
        }

        entries.sort { $0.startTime < $1.startTime }

        MarqueeLogger.player.info("Parsed \(entries.count) subtitle entries from \(URL(fileURLWithPath: path).lastPathComponent)")
        return entries
    }

    // MARK: - File Reading

    private static func readFileContent(at path: String) -> String? {
        let url = URL(fileURLWithPath: path)

        guard let data = try? Data(contentsOf: url) else { return nil }

        if hasUTF16BOM(data), let utf16 = String(data: data, encoding: .utf16) {
            return utf16
        }

        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }

        if let latin1 = String(data: data, encoding: .isoLatin1) {
            MarqueeLogger.player.info("Subtitle file decoded with Latin-1 fallback: \(url.lastPathComponent)")
            return latin1
        }

        return nil
    }

    /// UTF-16 subtitle files are invalid UTF-8, so without this they decode as
    /// Latin-1 mojibake whose timestamps never match.
    private static func hasUTF16BOM(_ data: Data) -> Bool {
        guard data.count >= 2 else { return false }
        let first = data[data.startIndex]
        let second = data[data.startIndex + 1]
        return (first == 0xFF && second == 0xFE) || (first == 0xFE && second == 0xFF)
    }

    // MARK: - BOM Stripping

    private static func stripBOM(_ text: String) -> String {
        if text.hasPrefix("\u{FEFF}") {
            return String(text.dropFirst())
        }
        return text
    }

    // MARK: - Block Splitting

    private static func splitIntoBlocks(_ text: String) -> [String] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var blocks: [String] = []
        var current: [String] = []

        // Separator lines carrying stray spaces are common in the wild; splitting
        // on a literal "\n\n" merges the following cue into this one's text.
        func endBlock() {
            let block = current.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !block.isEmpty {
                blocks.append(block)
            }
            current.removeAll()
        }

        // Only ASCII blanks separate cues; `.whitespaces` includes U+00A0, which
        // appears as deliberate cue content and must not truncate the block.
        for line in normalized.components(separatedBy: "\n") {
            if line.allSatisfy({ $0 == " " || $0 == "\t" }) {
                endBlock()
            } else {
                current.append(line)
            }
        }
        endBlock()

        return blocks
    }

    // MARK: - Block Parsing

    private static func parseBlock(_ block: String) -> SubtitleEntry? {
        let lines = block.components(separatedBy: "\n")

        guard lines.count >= 2 else { return nil }

        var timestampLineIndex: Int?
        for (index, line) in lines.enumerated() {
            if line.contains("-->") {
                timestampLineIndex = index
                break
            }
        }

        guard let tsIndex = timestampLineIndex else { return nil }

        guard let (startTime, endTime) = parseTimestampLine(lines[tsIndex]) else {
            return nil
        }

        let textLines = lines.dropFirst(tsIndex + 1)
        let rawText = textLines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !rawText.isEmpty else { return nil }

        let cleanedText = stripHTMLTags(rawText)

        return SubtitleEntry(startTime: startTime, endTime: endTime, text: cleanedText)
    }

    // MARK: - Timestamp Parsing

    private static func parseTimestampLine(_ line: String) -> (TimeInterval, TimeInterval)? {
        let parts = line.components(separatedBy: "-->")
        guard parts.count == 2 else { return nil }

        let startStr = parts[0].trimmingCharacters(in: .whitespaces)
        let endStr = parts[1].trimmingCharacters(in: .whitespaces)

        guard let start = parseTimestamp(startStr),
              let end = parseTimestamp(endStr) else {
            return nil
        }

        return (start, end)
    }

    private static func parseTimestamp(_ timestamp: String) -> TimeInterval? {
        let cleaned = timestamp.replacingOccurrences(of: ",", with: ".")

        let components = cleaned.components(separatedBy: ":")
        guard components.count == 3 else { return nil }

        guard let hours = decimalValue(components[0]),
              let minutes = decimalValue(components[1]),
              let seconds = decimalValue(components[2]) else {
            return nil
        }

        return hours * 3600.0 + minutes * 60.0 + seconds
    }

    /// `Double(_:)` accepts hex floats, `inf`, and `nan`, so a corrupt field such
    /// as `00:00:0X,000` would otherwise become a silently wrong cue time.
    private static func decimalValue(_ field: String) -> TimeInterval? {
        let trimmed = field.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.components(separatedBy: ".")
        guard parts.count <= 2,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }) else {
            return nil
        }
        return Double(trimmed)
    }

    // MARK: - HTML Tag Stripping

    private static let htmlTagPattern: NSRegularExpression? = {
        try? NSRegularExpression(pattern: "<[^>]+>", options: [])
    }()

    private static func stripHTMLTags(_ text: String) -> String {
        guard let regex = htmlTagPattern else { return text }

        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
    }
}
