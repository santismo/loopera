import Foundation

enum LoopSlotState: Equatable {
    case empty
    case listening
    case armed
    case recording
    case recorded
}

struct LoopSlot: Identifiable, Equatable {
    let id = UUID()
    let index: Int
    var triggerKey: String
    var url: URL?
    var createdAt: Date?
    var duration: TimeInterval = 0
    var startOffset: TimeInterval = 0
    var state: LoopSlotState = .empty
    var isMuted = false
    var isPlaying = true
    var customPosition: CGPointUnit?
    var scale: Double = 1
    var shape: LoopSlotShape = .circle

    var isMaster: Bool {
        index == 1
    }

    init(index: Int) {
        self.index = index
        self.triggerKey = Self.defaultKey(for: index)
    }

    static func defaultKey(for index: Int) -> String {
        switch index {
        case 1...9:
            return "\(index)"
        case 10:
            return "0"
        case 11:
            return "-"
        case 12:
            return "+"
        case 13:
            return "q"
        case 14:
            return "w"
        case 15:
            return "e"
        case 16:
            return "r"
        default:
            return "\(index)"
        }
    }
}

enum LoopSlotShape: String, CaseIterable, Identifiable, Codable {
    case circle = "Circle"
    case roundedSquare = "Square"
    case capsule = "Capsule"
    case diamond = "Diamond"
    case hexagon = "Hex"

    var id: String { rawValue }
}

struct CGPointUnit: Equatable, Codable {
    var x: Double
    var y: Double
}

enum StageLayout: String, CaseIterable, Identifiable, Codable {
    case clock = "Clock"
    case border = "Border"
    case grid = "Grid"

    var id: String { rawValue }
}
