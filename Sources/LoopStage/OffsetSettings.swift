import Foundation

enum LoopFadeMode: String, Codable, CaseIterable, Identifiable {
    case fast = "Fast"
    case slow = "Slow"
    case toLoopEnd = "To Loop End"

    var id: String { rawValue }
}

struct OffsetProfile: Codable, Equatable {
    var videoStartOffsetMilliseconds: Double = -35
    var audioStopOffsetMilliseconds: Double = 0
    var crossfadeMilliseconds: Double = 45
    var loopFadeOutMilliseconds: Double = 180
    var loopFadeMode: LoopFadeMode = .toLoopEnd
}

enum OffsetProfileStore {
    static func load(audioDeviceID: String?, videoDeviceID: String?) -> OffsetProfile {
        let defaults = UserDefaults.standard
        if let key = key(audioDeviceID: audioDeviceID, videoDeviceID: videoDeviceID),
           let data = defaults.data(forKey: key),
           let profile = try? JSONDecoder().decode(OffsetProfile.self, from: data) {
            return profile
        }
        if let data = defaults.data(forKey: defaultKey),
           let profile = try? JSONDecoder().decode(OffsetProfile.self, from: data) {
            return profile
        }
        return OffsetProfile()
    }

    static func save(_ profile: OffsetProfile, audioDeviceID: String?, videoDeviceID: String?) {
        guard let data = try? JSONEncoder().encode(profile) else { return }
        let defaults = UserDefaults.standard
        defaults.set(data, forKey: defaultKey)
        if let key = key(audioDeviceID: audioDeviceID, videoDeviceID: videoDeviceID) {
            defaults.set(data, forKey: key)
        }
    }

    private static let defaultKey = "Loopera.offsetProfile.default"

    private static func key(audioDeviceID: String?, videoDeviceID: String?) -> String? {
        let audio = audioDeviceID?.isEmpty == false ? audioDeviceID! : "no-audio"
        let video = videoDeviceID?.isEmpty == false ? videoDeviceID! : "no-video"
        return "Loopera.offsetProfile.\(audio).\(video)"
    }
}
