import Foundation

// MARK: - Maturity Level

enum MaturityLevel: Int, Comparable, Codable, CaseIterable {
    case kids = 0
    case family = 1
    case teen = 2
    case adult = 3

    static func < (lhs: MaturityLevel, rhs: MaturityLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var label: String {
        switch self {
        case .kids: return "Kids"
        case .family: return "Family"
        case .teen: return "Teen"
        case .adult: return "Adult"
        }
    }

    var ratingExamples: String {
        switch self {
        case .kids: return "G, PG, TV-Y"
        case .family: return "G, PG"
        case .teen: return "PG-13, TV-14"
        case .adult: return "R, TV-MA"
        }
    }

    static func classify(certification: String?, genres: [String]) -> MaturityLevel {
        let normalizedGenres = genres.compactMap { genre -> String? in
            let normalized = genre.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return normalized.isEmpty ? nil : normalized
        }
        let hasFamily = normalizedGenres.contains { genre in
            genre == "family" || genre == "kids & family" || genre == "children"
        }
        let hasKidsGenre = normalizedGenres.contains { genre in
            genre == "kids" || genre == "children" || genre == "preschool"
        }
        let hasAnimation = normalizedGenres.contains("animation") || normalizedGenres.contains("animated")
        let matureGenres: Set<String> = ["horror", "crime", "thriller", "war"]
        let hasMature = normalizedGenres.contains { matureGenres.contains($0) }

        let kidsSignal = hasKidsGenre || (hasFamily && hasAnimation)

        if let cert = certification, !cert.isEmpty {
            let normalizedCertification = cert
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
                .replacingOccurrences(of: "RATED ", with: "")
            switch normalizedCertification {
            case "TV-Y", "TV-Y7", "TV-Y7-FV", "TV-G":
                return .kids
            case "G":
                return .kids
            case "PG", "TV-PG":
                if kidsSignal { return .kids }
                if hasFamily || hasAnimation { return .family }
                return .teen
            case "PG-13", "TV-14":
                return .teen
            case "R", "NC-17", "TV-MA", "NR":
                return .adult
            default:
                if kidsSignal { return .kids }
                if hasFamily { return .family }
                return .adult
            }
        }

        if !normalizedGenres.isEmpty {
            if kidsSignal { return .kids }
            if hasFamily { return .family }
            if hasMature { return .adult }
            return .teen
        }

        return .adult
    }
}
