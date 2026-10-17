//
//  MediaIdentity.swift
//  Marquee
//
//  Pure, deterministic catalog identity strategy.
//  See docs/ARCHITECTURE_DECISIONS.md ADR-002.
//

import Foundation
import CryptoKit

/// Pure, deterministic identity functions for catalog entities.
///
/// These functions are intentionally free of file-system access and
/// platform side effects so they can be unit-tested with string fixtures
/// alone.
public enum MediaIdentity {

    // MARK: - Primary identity

    /// Produces a stable `MediaFileID` from `(volumeUUID, relativePath)`.
    /// Re-running with the same inputs always returns the same ID.
    public static func mediaFileID(
        volumeUUID: String,
        relativePath: String
    ) -> MediaFileID {
        let normalizedVolume = normalizeVolumeUUID(volumeUUID)
        let normalizedPath = normalizeRelativePath(relativePath)
        let payload = "v1|file|\(normalizedVolume)|\(normalizedPath)"
        return MediaFileID(rawValue: shortHash(payload))
    }

    /// Movie identity is derived from the primary file ID. This means the
    /// movie record survives metadata edits but is reset only when the
    /// underlying file identity changes.
    public static func movieID(primaryFile: MediaFileID) -> MovieID {
        let payload = "v1|movie|\(primaryFile.rawValue)"
        return MovieID(rawValue: shortHash(payload))
    }

    /// Show identity is derived from a normalized title + optional year.
    /// Two physical files of the same show converge to the same `ShowID`
    /// regardless of which file is scanned first.
    public static func showID(title: String, year: Int?) -> ShowID {
        let normalizedTitle = normalizeTitle(title)
        let yearPart = year.map(String.init) ?? "_"
        let payload = "v1|show|\(normalizedTitle)|\(yearPart)"
        return ShowID(rawValue: shortHash(payload))
    }

    public static func seasonID(show: ShowID, seasonNumber: Int) -> SeasonID {
        let payload = "v1|season|\(show.rawValue)|\(seasonNumber)"
        return SeasonID(rawValue: shortHash(payload))
    }

    public static func episodeID(
        season: SeasonID,
        episodeNumber: Int,
        primaryFile: MediaFileID
    ) -> EpisodeID {
        // File is part of identity so two encodes of the same episode
        // (e.g., 1080p + 4K) get separate IDs until reconciliation.
        let payload = "v1|episode|\(season.rawValue)|\(episodeNumber)|\(primaryFile.rawValue)"
        return EpisodeID(rawValue: shortHash(payload))
    }

    public static func artworkID(
        owner: ArtworkOwner,
        kind: ArtworkKind,
        sourceLabel: String
    ) -> ArtworkAssetID {
        let ownerKey: String
        switch owner {
        case .movie(let id):    ownerKey = "movie|\(id.rawValue)"
        case .show(let id):     ownerKey = "show|\(id.rawValue)"
        case .season(let id):   ownerKey = "season|\(id.rawValue)"
        case .episode(let id):  ownerKey = "episode|\(id.rawValue)"
        }
        let payload = "v1|art|\(ownerKey)|\(kind.rawValue)|\(sourceLabel)"
        return ArtworkAssetID(rawValue: shortHash(payload))
    }

    public static func watchStateID(
        profile: ProfileID,
        target: WatchTarget
    ) -> WatchStateID {
        let targetKey: String
        switch target {
        case .movie(let id):   targetKey = "movie|\(id.rawValue)"
        case .episode(let id): targetKey = "episode|\(id.rawValue)"
        }
        let payload = "v1|watch|\(profile.rawValue)|\(targetKey)"
        return WatchStateID(rawValue: shortHash(payload))
    }

    public static func profileID(displayName: String, kind: ProfileKind) -> ProfileID {
        let payload = "v1|profile|\(normalizeTitle(displayName))|\(kind.rawValue)"
        return ProfileID(rawValue: shortHash(payload))
    }

    /// Cast-member row ID. `replaceEnrichment` always deletes-then-inserts
    /// for the owner, so the only collision risk is two cast entries with
    /// the same `(owner, ordinal)` in one call — which is a caller bug.
    /// Hashing `(owner, ordinal)` instead of `(owner, ordinal, person)`
    /// surfaces that bug at insert time via the primary-key constraint
    /// rather than letting the row land silently.
    public static func castMemberID(
        owner: ArtworkOwner,
        ordinal: Int
    ) -> String {
        let ownerKey: String
        switch owner {
        case .movie(let id):    ownerKey = "movie|\(id.rawValue)"
        case .show(let id):     ownerKey = "show|\(id.rawValue)"
        case .season(let id):   ownerKey = "season|\(id.rawValue)"
        case .episode(let id):  ownerKey = "episode|\(id.rawValue)"
        }
        let payload = "v1|cast|\(ownerKey)|\(ordinal)"
        return shortHash(payload)
    }

    // MARK: - Normalization (also pure)

    /// Volume UUIDs are case-insensitive on macOS. Lowercase + trim.
    static func normalizeVolumeUUID(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Relative paths are normalized to forward-slash, no leading slash,
    /// no trailing slash. Case is preserved (HFS+ is case-insensitive but
    /// APFS preserves case; we do not gamble on the volume's policy).
    static func normalizeRelativePath(_ raw: String) -> String {
        var path = raw
        // Defensive: convert backslashes (won't happen on macOS, but
        // makes the function safe for cross-platform tests).
        path = path.replacingOccurrences(of: "\\", with: "/")
        // Trim leading/trailing slashes and whitespace.
        while path.hasPrefix("/") { path.removeFirst() }
        while path.hasSuffix("/") { path.removeLast() }
        path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return path
    }

    /// Title normalization for show identity. Lowercase, strip
    /// punctuation and runs of whitespace.
    static func normalizeTitle(_ raw: String) -> String {
        let lowered = raw.lowercased()
        let kept = lowered.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) {
                return Character(scalar)
            }
            return " "
        }
        let collapsed = String(kept).split(separator: " ").joined(separator: " ")
        return collapsed
    }

    // MARK: - Hash

    /// SHA-256 of `payload`, truncated to 24 hex chars (96 bits). At our
    /// scale that's effectively collision-free and short enough to read
    /// in logs.
    static func shortHash(_ payload: String) -> String {
        let data = Data(payload.utf8)
        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(24))
    }
}
