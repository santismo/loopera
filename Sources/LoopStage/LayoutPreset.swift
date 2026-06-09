import Foundation

struct LayoutPreset: Codable {
    var selectedVideoDeviceID: String
    var videoInputMode: VideoInputMode?
    var selectedAudioDeviceIDs: [String]
    var selectedAudioChannelPairStart: Int?
    var selectedAudioOutputDeviceID: String?
    var stageLayout: StageLayout
    var canvasMode: StageCanvasMode?
    var canvasScale: Double
    var livePreviewZoom: Double?
    var livePreviewShape: LoopSlotShape?
    var threshold: Double
    var thresholdLeadMilliseconds: Double?
    var tempoBPM: Double?
    var slots: [SlotPreset]
}

enum StageCanvasMode: String, CaseIterable, Identifiable, Codable {
    case landscape = "Landscape"
    case portrait = "Portrait"

    var id: String { rawValue }

    var aspectRatio: Double {
        switch self {
        case .landscape:
            return 16.0 / 9.0
        case .portrait:
            return 9.0 / 16.0
        }
    }
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
        existingURL(for: name) ??
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

    static func exists(name: String) -> Bool {
        existingURL(for: name) != nil
    }

    private static func existingURL(for name: String) -> URL? {
        let normalizedName = normalizedDisplayName(name)
        let preferred = directoryURL.appendingPathComponent(fileName(for: name)).appendingPathExtension("json")
        if FileManager.default.fileExists(atPath: preferred.path) {
            return preferred
        }

        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        return urls.first { url in
            guard url.pathExtension == "json" else { return false }
            let storedName = url.deletingPathExtension().lastPathComponent
            return normalizedDisplayName(storedName) == normalizedName ||
                normalizedDisplayName(displayName(for: storedName)) == normalizedName
        }
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

    private static func normalizedDisplayName(_ name: String) -> String {
        name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .lowercased()
    }
}
