import CoreAudio
import Foundation

struct AudioOutputDevice: Identifiable, Equatable {
    let id: String
    let name: String
}

@MainActor
final class AudioOutputController: ObservableObject {
    @Published private(set) var devices: [AudioOutputDevice] = []
    @Published var selectedDeviceID: String?

    init() {
        refresh()
    }

    func refresh() {
        devices = Self.fetchOutputDevices()
        if let selectedDeviceID, !devices.contains(where: { $0.id == selectedDeviceID }) {
            self.selectedDeviceID = nil
        }
    }

    func selectSystemOutput() {
        selectedDeviceID = nil
    }

    func select(_ id: String) {
        guard devices.contains(where: { $0.id == id }) else {
            refresh()
            return
        }
        selectedDeviceID = id
    }

    private nonisolated static func fetchOutputDevices() -> [AudioOutputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize) == noErr else {
            return []
        }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = Array(repeating: AudioDeviceID(), count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceIDs) == noErr else {
            return []
        }

        return deviceIDs.compactMap { deviceID in
            guard hasOutputStreams(deviceID),
                  let uid = stringProperty(kAudioDevicePropertyDeviceUID, deviceID: deviceID),
                  let name = stringProperty(kAudioObjectPropertyName, deviceID: deviceID)
            else { return nil }

            return AudioOutputDevice(id: uid, name: name)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private nonisolated static func hasOutputStreams(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr else {
            return false
        }
        return dataSize > 0
    }

    private nonisolated static func stringProperty(_ selector: AudioObjectPropertySelector, deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "" as CFString
        var dataSize = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &value) == noErr else {
            return nil
        }
        return value as String
    }
}
