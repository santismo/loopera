import Foundation

struct LayoutPreset: Codable {
    var selectedVideoDeviceID: String
    var selectedAudioDeviceIDs: [String]
    var selectedAudioChannelPairStart: Int?
    var selectedAudioOutputDeviceID: String?
    var stageLayout: StageLayout
    var canvasScale: Double
    var threshold: Double
    var thresholdLeadMilliseconds: Double?
    var tempoBPM: Double?
    var slots: [SlotPreset]
}

struct SlotPreset: Codable {
    var index: Int
    var triggerKey: String
    var customPosition: CGPointUnit?
    var scale: Double
    var shape: LoopSlotShape
}

enum LayoutPresetStore {
    static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Loopera", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("DefaultLayout.json")
    }
}
