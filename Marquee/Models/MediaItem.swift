import Foundation
import AppKit
import CryptoKit

// MARK: - MediaItem

final class MediaItem: Identifiable, ObservableObject {
    let id: UUID
    let filePath: String
    let fileName: String
    let title: String
    let year: Int?
    let fileExtension: String
    let fileSize: Int64
    let duration: TimeInterval?
    let genre: String?
    let localGenres: [String]
    let dateAdded: Date
    let fileModificationDate: Date?

    // MARK: - TV Episode Fields

    let showName: String?
    let seasonNumber: Int?
    let episodeNumber: Int?
    private(set) var episodeTitle: String?
    private(set) var contentRating: String?

    // MARK: - TMDB Metadata

    private(set) var tmdbID: Int?
    private(set) var metadata: TMDBMetadata?

    // MARK: - Image Paths (local file system)

    private(set) var posterImagePath: String?
    private(set) var backdropImagePath: String?
    private(set) var thumbPosterPath: String?
    private(set) var thumbBackdropPath: String?
    private(set) var showPosterPath: String?
    private(set) var showBackdropPath: String?
    private(set) var showThumbPosterPath: String?
    private(set) var showThumbBackdropPath: String?
    private(set) var seasonPosterPath: String?
    private(set) var seasonBackdropPath: String?
    private(set) var localEpisodeStillPath: String?

    // MARK: - Watch State

    @Published var isWatched: Bool = false
    @Published var lastPlayedDate: Date?
    @Published var playbackPosition: Double = 0

    init(
        filePath: String,
        fileName: String,
        title: String,
        year: Int?,
        fileExtension: String,
        fileSize: Int64,
        duration: TimeInterval? = nil,
        genre: String? = nil,
        localGenres: [String] = [],
        dateAdded: Date = Date(),
        fileModificationDate: Date? = nil,
        showName: String? = nil,
        seasonNumber: Int? = nil,
        episodeNumber: Int? = nil,
        episodeTitle: String? = nil,
        contentRating: String? = nil,
        tmdbID: Int? = nil,
        metadata: TMDBMetadata? = nil,
        posterImagePath: String? = nil,
        backdropImagePath: String? = nil,
        thumbPosterPath: String? = nil,
        thumbBackdropPath: String? = nil,
        showPosterPath: String? = nil,
        showBackdropPath: String? = nil,
        showThumbPosterPath: String? = nil,
        showThumbBackdropPath: String? = nil,
        seasonPosterPath: String? = nil,
        seasonBackdropPath: String? = nil,
        localEpisodeStillPath: String? = nil
    ) {
        self.id = Self.stableID(forFilePath: filePath)
        self.filePath = filePath
        self.fileName = fileName
        self.title = title
        self.year = year
        self.fileExtension = fileExtension
        self.fileSize = fileSize
        self.duration = duration
        self.genre = genre
        self.localGenres = localGenres
        self.dateAdded = dateAdded
        self.fileModificationDate = fileModificationDate
        self.showName = showName
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
        self.episodeTitle = episodeTitle
        self.contentRating = contentRating
        self.tmdbID = tmdbID
        self.metadata = metadata
        self.posterImagePath = posterImagePath
        self.backdropImagePath = backdropImagePath
        self.thumbPosterPath = thumbPosterPath
        self.thumbBackdropPath = thumbBackdropPath
        self.showPosterPath = showPosterPath
        self.showBackdropPath = showBackdropPath
        self.showThumbPosterPath = showThumbPosterPath
        self.showThumbBackdropPath = showThumbBackdropPath
        self.seasonPosterPath = seasonPosterPath
        self.seasonBackdropPath = seasonBackdropPath
        self.localEpisodeStillPath = localEpisodeStillPath
    }

    // MARK: - Stable Identity

    private static func stableID(forFilePath filePath: String) -> UUID {
        let digest = Insecure.MD5.hash(data: Data(filePath.utf8))
        let bytes = Array(digest)
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    // MARK: - Display Helpers

    var displayTitle: String { title }

    var browseTitle: String {
        showName ?? displayTitle
    }

    var displayYear: String? {
        guard let year = year else { return nil }
        return String(year)
    }

    var displayRuntime: String? {
        guard let duration = duration, duration > 0 else { return nil }
        let totalMinutes = Int(duration / 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    var displayGenres: [String] {
        let candidates: [String]
        if let genres = metadata?.genres, !genres.isEmpty {
            let metadataGenres = Self.uniqueGenres(genres)
            if Self.isGenericFamilyGenreList(metadataGenres), !localGenres.isEmpty {
                candidates = metadataGenres + localGenres
            } else {
                candidates = metadataGenres
            }
        } else if !localGenres.isEmpty {
            candidates = localGenres
        } else if let genre {
            candidates = [genre]
        } else {
            candidates = []
        }

        return Self.uniqueGenres(candidates)
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

    private static func isGenericFamilyGenreList(_ genres: [String]) -> Bool {
        guard !genres.isEmpty else { return false }
        let generic = Set(["family", "kids", "kids & family", "children"])
        return genres.allSatisfy { generic.contains($0.lowercased()) }
    }

    var formatBadge: String {
        fileExtension.uppercased()
    }

    var displayPosterPath: String? {
        if isEpisode {
            return showPosterPath ?? seasonPosterPath ?? posterImagePath ?? showThumbPosterPath ?? thumbPosterPath
        }
        return posterImagePath ?? thumbPosterPath
    }

    var displayBackdropPath: String? {
        if isEpisode {
            return showBackdropPath ?? seasonBackdropPath ?? backdropImagePath ?? showThumbBackdropPath ?? thumbBackdropPath
        }
        return backdropImagePath ?? thumbBackdropPath
    }

    var gridPosterPath: String? {
        if isEpisode {
            return showPosterPath ?? seasonPosterPath ?? posterImagePath ?? showThumbPosterPath ?? thumbPosterPath
        }
        return posterImagePath ?? thumbPosterPath
    }

    var gridBackdropPath: String? {
        if isEpisode {
            return localEpisodeStillPath ?? thumbBackdropPath ?? backdropImagePath
        }
        return backdropImagePath ?? thumbBackdropPath
    }

    var decade: Int? {
        guard let year = year else { return nil }
        return (year / 10) * 10
    }

    var hasProgress: Bool {
        playbackPosition > 0 && !isWatched
    }

    var effectiveDate: Date {
        fileModificationDate ?? dateAdded
    }

    // MARK: - TV Helpers

    var isEpisode: Bool { showName != nil }
    var isMovie: Bool { showName == nil }

    var episodeLabel: String {
        guard let s = seasonNumber, let e = episodeNumber else { return "" }
        return "S\(s) E\(e)"
    }

    var displayEpisodeTitle: String {
        episodeTitle ?? "Episode \(episodeNumber ?? 0)"
    }

    var continueWatchingLabel: String {
        guard let show = showName else { return displayTitle }
        return "\(show) \u{00B7} \(episodeLabel)"
    }

    var maturityLevel: MaturityLevel {
        MaturityLevel.classify(
            certification: metadata?.certification ?? contentRating,
            genres: displayGenres
        )
    }

    var displayShowPosterPath: String? {
        showPosterPath ?? seasonPosterPath ?? showThumbPosterPath
    }

    var displayShowBackdropPath: String? {
        showBackdropPath ?? seasonBackdropPath ?? backdropImagePath ?? showThumbBackdropPath ?? thumbBackdropPath
    }

    var gridShowPosterPath: String? {
        showPosterPath ?? seasonPosterPath ?? showThumbPosterPath
    }

}
