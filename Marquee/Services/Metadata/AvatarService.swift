import Foundation
import AppKit

// MARK: - Avatar Service

final class AvatarService {

    static let shared = AvatarService()

    private let apiKey = Configuration.tmdbAPIKey
    private let baseURL = Configuration.tmdbBaseURL
    private let imageBaseURL = "\(Configuration.tmdbImageBaseURL)/\(Configuration.avatarImageSize)"
    private let cacheDir: URL
    private let session = URLSession.shared

    private init() {
        let appSupport = Configuration.appSupportDirectory
            .appendingPathComponent("avatars")

        try? FileManager.default.createDirectory(
            at: appSupport,
            withIntermediateDirectories: true
        )
        cacheDir = appSupport
    }

    // MARK: - URL Building

    private func buildSearchURL(path: String, query: String) -> URL? {
        var components = URLComponents(string: baseURL + path)
        components?.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "query", value: query)
        ]
        return components?.url
    }

    // MARK: - Curated Avatars (show poster art)

    static let curatedAvatars: [(showName: String, label: String)] = [
        ("The Simpsons", "The Simpsons"),
        ("Bluey", "Bluey"),
        ("Futurama", "Futurama"),
        ("Bob's Burgers", "Bob's Burgers"),
        ("Avatar: The Last Airbender", "Avatar"),
        ("SpongeBob SquarePants", "SpongeBob"),
        ("Star Trek: The Next Generation", "TNG"),
        ("Star Trek: Deep Space Nine", "DS9"),
        ("Star Trek: Voyager", "Voyager"),
        ("Star Trek", "TOS"),
        ("Seinfeld", "Seinfeld"),
        ("The Office", "The Office"),
        ("Breaking Bad", "Breaking Bad"),
        ("Mad Men", "Mad Men"),
        ("Buffy the Vampire Slayer", "Buffy"),
        ("The X-Files", "X-Files"),
        ("The Mandalorian", "Mandalorian"),
        ("Outlander", "Outlander"),
        ("Friends", "Friends"),
        ("The Sopranos", "Sopranos"),
        ("Game of Thrones", "Westeros"),
        ("Stranger Things", "Stranger Things"),
        ("The Big Lebowski", "Lebowski"),
        ("Pulp Fiction", "Pulp Fiction"),
        ("The Lord of the Rings: The Rings of Power", "Rings of Power"),
        ("The Matrix", "Matrix"),
    ]

    // MARK: - Fetch All

    func cachedAvatars() -> [CharacterAvatar] {
        Self.curatedAvatars.compactMap { entry in
            cachedShowAvatar(showName: entry.showName, label: entry.label)
        }
    }

    func cachedAvatar(named name: String) -> CharacterAvatar? {
        guard let entry = Self.curatedAvatars.first(where: { $0.showName == name }) else {
            return nil
        }
        return cachedShowAvatar(showName: entry.showName, label: entry.label)
    }

    func fetchAllAvatars(allowNetwork: Bool = UserSettings.shared.onlineMetadataEnabled) async -> [CharacterAvatar] {
        var results = cachedAvatars()
        var seen = Set(results.map(\.name))

        guard allowNetwork else {
            return results
        }

        for entry in Self.curatedAvatars {
            guard !seen.contains(entry.showName) else { continue }
            if let avatar = await fetchShowAvatar(
                showName: entry.showName,
                label: entry.label,
                allowNetwork: true
            ) {
                results.append(avatar)
                seen.insert(avatar.name)
            }
        }
        return results
    }

    // MARK: - Fetch Show Poster

    func fetchShowAvatar(
        showName: String,
        label: String,
        allowNetwork: Bool = UserSettings.shared.onlineMetadataEnabled
    ) async -> CharacterAvatar? {
        if let cached = cachedShowAvatar(showName: showName, label: label) {
            return cached
        }

        guard allowNetwork else { return nil }
        guard UserSettings.shared.onlineMetadataEnabled else { return nil }

        guard let tvURL = buildSearchURL(path: "/search/tv", query: showName) else {
            MarqueeLogger.network.error("Failed to build TV search URL for avatar: \(showName)")
            return nil
        }

        if let result = await fetchPosterFromSearch(url: tvURL, cacheFile: cacheFile(for: showName)) {
            return CharacterAvatar(name: showName, role: label, image: result)
        }

        guard let movieURL = buildSearchURL(path: "/search/movie", query: showName) else {
            MarqueeLogger.network.error("Failed to build movie search URL for avatar: \(showName)")
            return nil
        }

        if let result = await fetchPosterFromSearch(url: movieURL, cacheFile: cacheFile(for: showName)) {
            return CharacterAvatar(name: showName, role: label, image: result)
        }

        MarqueeLogger.network.info("No avatar found for: \(showName)")
        return nil
    }

    // MARK: - Private

    private func cachedShowAvatar(showName: String, label: String) -> CharacterAvatar? {
        let cacheFile = cacheDir.appendingPathComponent("show_" + safeFilename(showName) + ".jpg")

        if let cached = NSImage(contentsOf: cacheFile) {
            return CharacterAvatar(name: showName, role: label, image: cached)
        }

        return nil
    }

    private func cacheFile(for showName: String) -> URL {
        cacheDir.appendingPathComponent("show_" + safeFilename(showName) + ".jpg")
    }

    private func fetchPosterFromSearch(url: URL, cacheFile: URL) async -> NSImage? {
        guard let (data, _) = try? await session.data(from: url) else {
            MarqueeLogger.network.error("Network request failed for avatar search: \(url.absoluteString)")
            return nil
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]],
              let first = results.first,
              let posterPath = first["poster_path"] as? String else { return nil }

        guard let imageData = await downloadImage(path: posterPath) else { return nil }
        guard let image = NSImage(data: imageData) else { return nil }

        try? imageData.write(to: cacheFile)
        return image
    }

    private func downloadImage(path: String) async -> Data? {
        let components = URLComponents(string: imageBaseURL + path)
        guard let url = components?.url else {
            MarqueeLogger.network.error("Failed to build image download URL for path: \(path)")
            return nil
        }
        guard let (data, _) = try? await session.data(from: url) else {
            MarqueeLogger.network.error("Failed to download avatar image: \(path)")
            return nil
        }
        return data
    }

    private func safeFilename(_ name: String) -> String {
        name.replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: ":", with: "")
            .lowercased()
    }
}

// MARK: - Character Avatar

struct CharacterAvatar: Identifiable {
    let name: String
    let role: String
    let image: NSImage

    var id: String { name }
}
