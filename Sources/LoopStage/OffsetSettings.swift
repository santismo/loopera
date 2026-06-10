import Foundation

enum LoopFadeMode: String, Codable, CaseIterable, Identifiable {
    case fast = "Fast"
    case slow = "Slow"
    case toLoopEnd = "To Loop End"

    var id: String { rawValue }
}

struct OffsetProfile: Codable, Equatable {
    var videoStartOffsetMilliseconds: Double = 0
    var audioStopOffsetMilliseconds: Double = 0
    var crossfadeMilliseconds: Double = 45
    var loopFadeOutMilliseconds: Double = 180
    var loopFadeMode: LoopFadeMode = .toLoopEnd
    var renderAudioOffsetMilliseconds: Double = 0
    var openRenderedPerformanceWhenDone = false
}

enum OffsetProfileStore {
    static func load(audioDeviceID: String?, videoDeviceID: String?) -> OffsetProfile {
        let defaults = UserDefaults.standard
        if let key = key(audioDeviceID: audioDeviceID, videoDeviceID: videoDeviceID),
           let data = defaults.data(forKey: key),
           let profile = try? JSONDecoder().decode(OffsetProfile.self, from: data) {
            return migrateDefaultVideoOffsetIfNeeded(profile)
        }
        if let data = defaults.data(forKey: defaultKey),
           let profile = try? JSONDecoder().decode(OffsetProfile.self, from: data) {
            return migrateDefaultVideoOffsetIfNeeded(profile)
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
    private static let previousDefaultVideoStartOffsetMilliseconds = -35.0
    private static let previousAdjustedVideoStartOffsetMilliseconds = -75.0
    private static let currentDefaultVideoStartOffsetMilliseconds = 0.0

    private static func migrateDefaultVideoOffsetIfNeeded(_ profile: OffsetProfile) -> OffsetProfile {
        guard abs(profile.videoStartOffsetMilliseconds - previousDefaultVideoStartOffsetMilliseconds) < 0.001 ||
            abs(profile.videoStartOffsetMilliseconds - previousAdjustedVideoStartOffsetMilliseconds) < 0.001
        else {
            return profile
        }
        var migrated = profile
        migrated.videoStartOffsetMilliseconds = currentDefaultVideoStartOffsetMilliseconds
        return migrated
    }

    private static func key(audioDeviceID: String?, videoDeviceID: String?) -> String? {
        let audio = audioDeviceID?.isEmpty == false ? audioDeviceID! : "no-audio"
        let video = videoDeviceID?.isEmpty == false ? videoDeviceID! : "no-video"
        return "Loopera.offsetProfile.\(audio).\(video)"
    }
}
