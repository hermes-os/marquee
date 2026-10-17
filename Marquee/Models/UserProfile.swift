import Foundation
import SwiftUI
import os

// MARK: - Profile Avatar

struct ProfileAvatar: Identifiable, Codable, Equatable {
    let icon: String
    let colorHex: String

    var id: String { icon }

    var color: Color {
        Color(hex: colorHex)
    }

    static let catalog: [ProfileAvatar] = [
        ProfileAvatar(icon: "hare.fill", colorHex: "FF6B6B"),
        ProfileAvatar(icon: "tortoise.fill", colorHex: "4ECDC4"),
        ProfileAvatar(icon: "cat.fill", colorHex: "FFB347"),
        ProfileAvatar(icon: "dog.fill", colorHex: "87CEEB"),
        ProfileAvatar(icon: "bird.fill", colorHex: "DDA0DD"),
        ProfileAvatar(icon: "fish.fill", colorHex: "48D1CC"),
        ProfileAvatar(icon: "ant.fill", colorHex: "F0E68C"),
        ProfileAvatar(icon: "ladybug.fill", colorHex: "FF6347"),
        ProfileAvatar(icon: "leaf.fill", colorHex: "90EE90"),
        ProfileAvatar(icon: "flame.fill", colorHex: "FF4500"),
        ProfileAvatar(icon: "bolt.fill", colorHex: "FFD700"),
        ProfileAvatar(icon: "moon.fill", colorHex: "B0C4DE"),
        ProfileAvatar(icon: "sun.max.fill", colorHex: "FFA500"),
        ProfileAvatar(icon: "cloud.fill", colorHex: "87CEFA"),
        ProfileAvatar(icon: "snowflake", colorHex: "ADD8E6"),
        ProfileAvatar(icon: "star.fill", colorHex: "FFD700"),
        ProfileAvatar(icon: "heart.fill", colorHex: "FF69B4"),
        ProfileAvatar(icon: "crown.fill", colorHex: "DAA520"),
        ProfileAvatar(icon: "theatermasks.fill", colorHex: "9E86FF"),
        ProfileAvatar(icon: "gamecontroller.fill", colorHex: "00CED1"),
        ProfileAvatar(icon: "headphones", colorHex: "FF8C00"),
        ProfileAvatar(icon: "music.note", colorHex: "DA70D6"),
        ProfileAvatar(icon: "paintbrush.fill", colorHex: "FF1493"),
        ProfileAvatar(icon: "eye.fill", colorHex: "20B2AA"),
        ProfileAvatar(icon: "camera.fill", colorHex: "778899"),
        ProfileAvatar(icon: "airplane", colorHex: "6495ED"),
        ProfileAvatar(icon: "globe.americas.fill", colorHex: "3CB371"),
        ProfileAvatar(icon: "mountain.2.fill", colorHex: "708090"),
        ProfileAvatar(icon: "trophy.fill", colorHex: "FFD700"),
        ProfileAvatar(icon: "face.smiling", colorHex: "FFD93D"),
    ]
}

// MARK: - User Profile

struct UserProfile: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var avatar: ProfileAvatar
    var characterAvatarName: String?
    var maturityLevel: MaturityLevel

    var icon: String { avatar.icon }

    init(name: String, avatar: ProfileAvatar, maturityLevel: MaturityLevel, characterAvatarName: String? = nil) {
        self.id = UUID()
        self.name = name
        self.avatar = avatar
        self.maturityLevel = maturityLevel
        self.characterAvatarName = characterAvatarName
    }

    func allows(item: MediaItem) -> Bool {
        switch maturityLevel {
        case .adult:
            return true
        case .kids:
            return item.maturityLevel <= .family
        case .family, .teen:
            return item.maturityLevel <= maturityLevel
        }
    }
}

// MARK: - Profile Store

final class ProfileStore: ObservableObject {

    static let shared = ProfileStore()

    private let fileURL: URL
    @Published private(set) var profiles: [UserProfile] = []
    @Published private(set) var lastSelectedProfileID: UUID?

    private init() {
        let appSupport = Configuration.appSupportDirectory

        try? FileManager.default.createDirectory(
            at: appSupport,
            withIntermediateDirectories: true
        )

        fileURL = appSupport.appendingPathComponent("profiles.json")
        load()

        if profiles.isEmpty {
            profiles = Self.defaultProfiles
            save()
        }
    }

    // MARK: - Defaults

    private static let defaultProfiles: [UserProfile] = [
        UserProfile(name: "Main", avatar: ProfileAvatar(icon: "theatermasks.fill", colorHex: "9E86FF"), maturityLevel: .adult),
        UserProfile(name: "Kids", avatar: ProfileAvatar(icon: "hare.fill", colorHex: "FF6B6B"), maturityLevel: .kids),
    ]

    // MARK: - CRUD

    func addProfile(_ profile: UserProfile) {
        profiles.append(profile)
        save()
    }

    func updateProfile(_ profile: UserProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index] = profile
        save()
    }

    func moveProfile(id: UUID, direction: Int) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        let newIndex = index + direction
        guard newIndex >= 0, newIndex < profiles.count else { return }
        profiles.swapAt(index, newIndex)
        save()
    }

    func deleteProfile(id: UUID) {
        profiles.removeAll { $0.id == id }
        if lastSelectedProfileID == id {
            lastSelectedProfileID = profiles.first?.id
        }
        save()
    }

    func selectProfile(id: UUID) {
        lastSelectedProfileID = id
        save()
    }

    func selectedProfile() -> UserProfile? {
        if let id = lastSelectedProfileID {
            return profiles.first { $0.id == id }
        }
        return profiles.first
    }

    // MARK: - Persistence

    private struct StoredData: Codable {
        let profiles: [UserProfile]
        let lastSelectedProfileID: UUID?
    }

    private func load() {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return
        } catch {
            MarqueeLogger.general.error("Failed to read profiles file: \(error.localizedDescription)")
            return
        }
        do {
            let stored = try JSONDecoder().decode(StoredData.self, from: data)
            profiles = stored.profiles
            lastSelectedProfileID = stored.lastSelectedProfileID
        } catch {
            MarqueeLogger.general.error("Failed to decode profiles: \(error.localizedDescription)")
        }
    }

    private func save() {
        let stored = StoredData(profiles: profiles, lastSelectedProfileID: lastSelectedProfileID)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(stored) else { return }
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            MarqueeLogger.general.error("Failed to save profiles: \(error.localizedDescription)")
        }
    }
}
