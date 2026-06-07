import Foundation

struct LayoutPreset: Codable {
    var selectedVideoDeviceID: String
    var selectedAudioDeviceIDs: [String]
    var selectedAudioChannelPairStart: Int?
    var selectedAudioOutputDeviceID: String?
    var stageLayout: StageLayout
    var canvasScale: Double
    var livePreviewZoom: Double?
    var livePreviewShape: LoopSlotShape?
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
    static var directoryURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Loopera", isDirectory: true)
            .appendingPathComponent("Layouts", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static func url(for name: String) -> URL {
        directoryURL.appendingPathComponent(fileName(for: name)).appendingPathExtension("json")
    }

    static func savedNames() -> [String] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        return urls
            .filter { $0.pathExtension == "json" }
            .map { displayName(for: $0.deletingPathExtension().lastPathComponent) }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private static func fileName(for name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = trimmed.isEmpty ? "Default" : trimmed
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        let scalars = source.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let collapsed = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? "Default" : collapsed
    }

    private static func displayName(for fileName: String) -> String {
        fileName.replacingOccurrences(of: "-", with: " ")
    }
}
