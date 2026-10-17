import Foundation
import os

// MARK: - User Settings

final class UserSettings: ObservableObject {

    static let shared = UserSettings()

    // MARK: - Library Paths

    @Published var moviesPaths: [String] {
        didSet { save() }
    }

    @Published var tvShowsPaths: [String] {
        didSet { save() }
    }

    // MARK: - Playback

    @Published var defaultSubtitleLanguage: String {
        didSet { save() }
    }

    @Published var defaultAudioLanguage: String {
        didSet { save() }
    }

    @Published var subtitleScale: Double {
        didSet { save() }
    }

    @Published var hardwareDecodingEnabled: Bool {
        didSet { save() }
    }

    @Published var autoPlayNextEpisode: Bool {
        didSet { save() }
    }

    @Published var onlineMetadataEnabled: Bool {
        didSet { save() }
    }

    // MARK: - Sound

    @Published var interfaceSoundsEnabled: Bool {
        didSet { save() }
    }

    @Published var launchIdentEnabled: Bool {
        didSet { save() }
    }

    @Published var soundPack: AudioIdentitySoundPack? {
        didSet { save() }
    }

    // MARK: - Persistence

    private static var settingsURL: URL {
        let appSupport = Configuration.appSupportDirectory

        try? FileManager.default.createDirectory(
            at: appSupport,
            withIntermediateDirectories: true
        )

        return appSupport.appendingPathComponent("settings.json")
    }

    // MARK: - Init

    private init() {
        let defaults = UserSettingsData.defaults
        let loaded = UserSettings.loadFromDisk()

        moviesPaths = loaded?.moviesPaths ?? defaults.moviesPaths
        tvShowsPaths = loaded?.tvShowsPaths ?? defaults.tvShowsPaths
        defaultSubtitleLanguage = loaded?.defaultSubtitleLanguage ?? defaults.defaultSubtitleLanguage
        defaultAudioLanguage = loaded?.defaultAudioLanguage ?? defaults.defaultAudioLanguage
        subtitleScale = loaded?.subtitleScale ?? defaults.subtitleScale ?? 1.35
        hardwareDecodingEnabled = loaded?.hardwareDecodingEnabled ?? defaults.hardwareDecodingEnabled
        autoPlayNextEpisode = loaded?.autoPlayNextEpisode ?? defaults.autoPlayNextEpisode
        onlineMetadataEnabled = loaded?.onlineMetadataEnabled ?? defaults.onlineMetadataEnabled ?? false
        interfaceSoundsEnabled = loaded?.interfaceSoundsEnabled ?? defaults.interfaceSoundsEnabled ?? true
        launchIdentEnabled = loaded?.launchIdentEnabled ?? defaults.launchIdentEnabled ?? true
        soundPack = AudioIdentityPackResolver.resolve(persistedRawValue: loaded?.soundPack)
    }

    // MARK: - Save / Load

    private func save() {
        let data = UserSettingsData(
            moviesPaths: moviesPaths,
            tvShowsPaths: tvShowsPaths,
            defaultSubtitleLanguage: defaultSubtitleLanguage,
            defaultAudioLanguage: defaultAudioLanguage,
            subtitleScale: subtitleScale,
            hardwareDecodingEnabled: hardwareDecodingEnabled,
            autoPlayNextEpisode: autoPlayNextEpisode,
            onlineMetadataEnabled: onlineMetadataEnabled,
            interfaceSoundsEnabled: interfaceSoundsEnabled,
            launchIdentEnabled: launchIdentEnabled,
            soundPack: soundPack?.rawValue
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        guard let jsonData = try? encoder.encode(data) else { return }
        do {
            try jsonData.write(to: UserSettings.settingsURL, options: .atomic)
        } catch {
            MarqueeLogger.general.error("Failed to save settings: \(error.localizedDescription)")
        }
    }

    private static func loadFromDisk() -> UserSettingsData? {
        let data: Data
        do {
            data = try Data(contentsOf: settingsURL)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return nil
        } catch {
            MarqueeLogger.general.error("Failed to read settings file: \(error.localizedDescription)")
            return nil
        }
        do {
            return try JSONDecoder().decode(UserSettingsData.self, from: data)
        } catch {
            MarqueeLogger.general.error("Failed to decode settings: \(error.localizedDescription)")
            return nil
        }
    }
}

// MARK: - Codable Data Container

struct UserSettingsData: Codable {
    var moviesPaths: [String]
    var tvShowsPaths: [String]
    var defaultSubtitleLanguage: String
    var defaultAudioLanguage: String
    var subtitleScale: Double?
    var hardwareDecodingEnabled: Bool
    var autoPlayNextEpisode: Bool
    var onlineMetadataEnabled: Bool?
    var interfaceSoundsEnabled: Bool?
    var launchIdentEnabled: Bool?
    var soundPack: String? = nil

    static var defaults: UserSettingsData {
        let moviesDir = NSHomeDirectory() + "/Movies"
        let fm = FileManager.default

        var defaultMovies = [moviesDir]
        if let mediaRoot = Configuration.mediaRootDirectory {
            let movies = mediaRoot.appendingPathComponent("MOVIES", isDirectory: true).path
            if fm.fileExists(atPath: movies) {
                defaultMovies.insert(movies, at: 0)
            }
        }

        var defaultTV: [String] = []
        if let mediaRoot = Configuration.mediaRootDirectory {
            let tv = mediaRoot.appendingPathComponent("TV", isDirectory: true).path
            if fm.fileExists(atPath: tv) {
                defaultTV.append(tv)
            }
        }

        return UserSettingsData(
            moviesPaths: defaultMovies,
            tvShowsPaths: defaultTV,
            defaultSubtitleLanguage: "None",
            defaultAudioLanguage: "English",
            subtitleScale: 1.35,
            hardwareDecodingEnabled: true,
            autoPlayNextEpisode: true,
            onlineMetadataEnabled: true,
            interfaceSoundsEnabled: true,
            launchIdentEnabled: true,
            soundPack: nil
        )
    }
}

// MARK: - Language Options

extension UserSettings {

    static let subtitleLanguages: [String] = [
        "None",
        "English",
        "Spanish",
        "French",
        "German",
        "Italian",
        "Portuguese",
        "Japanese",
        "Korean",
        "Chinese",
        "Russian",
        "Arabic",
        "Hindi",
        "Dutch",
        "Swedish",
        "Norwegian",
        "Danish",
        "Finnish",
        "Polish",
        "Turkish",
    ]

    static let audioLanguages: [String] = [
        "English",
        "Spanish",
        "French",
        "German",
        "Italian",
        "Portuguese",
        "Japanese",
        "Korean",
        "Chinese",
        "Russian",
        "Arabic",
        "Hindi",
        "Dutch",
        "Swedish",
        "Norwegian",
        "Danish",
        "Finnish",
        "Polish",
        "Turkish",
    ]
}
