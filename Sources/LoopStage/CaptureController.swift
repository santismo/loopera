@preconcurrency import AVFoundation
import Foundation

@MainActor
final class CaptureController: NSObject, ObservableObject {
    @Published private(set) var session = AVCaptureSession()
    @Published var slots: [LoopSlot] = (1...12).map { LoopSlot(index: $0) }
    @Published private(set) var isConfigured = false
    @Published private(set) var isRecording = false
    @Published var status = "Requesting camera and microphone access..."
    @Published private(set) var videoDevices: [AVCaptureDevice] = []
    @Published private(set) var audioDevices: [AVCaptureDevice] = []
    @Published var selectedDeviceID: String = ""
    @Published var selectedAudioDeviceIDs: Set<String> = []
    @Published var selectedAudioChannelPairStart: Int = 0
    @Published private(set) var detectedAudioInputChannelCount: Int = 2
    @Published var recordingLength: Double = 4
    @Published var inputLevel: Double = 0
    @Published var threshold: Double = 0.006
    @Published var thresholdLeadMilliseconds: Double = 80
    @Published var tempoBPM: Double?
    @Published var selectedSlotIndex: Int?
    @Published var crossfadeMilliseconds: Double = 35
    @Published private(set) var loopPlaybackTimes: [Int: TimeInterval] = [:]
    @Published private(set) var loopPlaybackTimeUpdatedAt = Date()
    @Published private(set) var videoFormatStatus = ""

    private let movieOutput = AVCaptureMovieFileOutput()
    private let audioMeterOutput = AVCaptureAudioDataOutput()
    private let audioMeterQueue = DispatchQueue(label: "Loopera.AudioMeter")
    private let audioLoopEngine = AudioLoopEngine()
    private var stopTask: Task<Void, Never>?
    private var captureStartDate: Date?
    private var pendingStartDate: Date?
    private var thresholdDate: Date?
    private var captureStartPTS: CMTime?
    private var thresholdPTS: CMTime?
    private var recordingSlotIndex: Int?
    private var completedAudioDurations: [Int: TimeInterval] = [:]
    private var completedVideoEndTrims: [Int: TimeInterval] = [:]
    private var pendingStopOnMasterBoundary = false
    private var pendingStopTrimEndSeconds: TimeInterval = 0
    private var quantizeTask: Task<Void, Never>?
    private var reconfigureTask: Task<Void, Never>?
    private var previousMasterPhase: Double?
    private nonisolated(unsafe) var audioChannelPairStartForCapture = 0
    private let lastAudioDeviceIDKey = "Loopera.lastAudioDeviceID"
    private let lastAudioChannelPairStartKey = "Loopera.lastAudioChannelPairStart"

    private struct CapturedStereoInput {
        var buffer: AudioLoopEngine.InputBuffer
        var channelCount: Int
    }

    var masterDuration: TimeInterval? {
        slots.first(where: { $0.index == 1 })?.duration.nonZero
    }

    override init() {
        super.init()
        refreshDevices()
        selectedDeviceID = videoDevices.first?.uniqueID ?? ""
        if let savedAudioID = UserDefaults.standard.string(forKey: lastAudioDeviceIDKey),
           audioDevices.contains(where: { $0.uniqueID == savedAudioID }) {
            selectedAudioDeviceIDs = [savedAudioID]
        } else if let defaultAudioID = audioDevices.first?.uniqueID {
            selectedAudioDeviceIDs = [defaultAudioID]
        }
        let savedPair = UserDefaults.standard.integer(forKey: lastAudioChannelPairStartKey)
        selectedAudioChannelPairStart = max(0, savedPair - (savedPair % 2))
        audioChannelPairStartForCapture = selectedAudioChannelPairStart
        audioMeterOutput.setSampleBufferDelegate(self, queue: audioMeterQueue)
        audioLoopEngine.start()
    }

    func requestAccessAndStart() {
        Task {
            let cameraAllowed = await AVCaptureDevice.requestAccess(for: .video)
            let micAllowed = await AVCaptureDevice.requestAccess(for: .audio)

            guard cameraAllowed, micAllowed else {
                status = "Camera and microphone permissions are required."
                return
            }

            refreshDevices()
            configureSession()
            startSession()
            startQuantizeLoop()
        }
    }

    func refreshDevices() {
        videoDevices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .continuityCamera, .external],
            mediaType: .video,
            position: .unspecified
        ).devices

        audioDevices = AVCaptureDevice.devices(for: .audio)

        if selectedDeviceID.isEmpty || !videoDevices.contains(where: { $0.uniqueID == selectedDeviceID }) {
            selectedDeviceID = videoDevices.first?.uniqueID ?? ""
        }

        selectedAudioDeviceIDs = selectedAudioDeviceIDs.filter { selectedID in
            audioDevices.contains(where: { $0.uniqueID == selectedID })
        }
        if selectedAudioDeviceIDs.isEmpty, let defaultAudioID = audioDevices.first?.uniqueID {
            if let savedAudioID = UserDefaults.standard.string(forKey: lastAudioDeviceIDKey),
               audioDevices.contains(where: { $0.uniqueID == savedAudioID }) {
                selectedAudioDeviceIDs = [savedAudioID]
            } else {
                selectedAudioDeviceIDs = [defaultAudioID]
            }
        }

        status = "Found \(videoDevices.count) camera input(s), \(audioDevices.count) audio input(s)."
    }

    func selectDevice(_ uniqueID: String) {
        guard videoDevices.contains(where: { $0.uniqueID == uniqueID }) else {
            refreshDevices()
            return
        }
        selectedDeviceID = uniqueID
        guard isConfigured else { return }
        status = "Camera selected. Applying..."
        scheduleSessionReconfigure()
    }

    func setAudioDevice(_ uniqueID: String, enabled: Bool) {
        guard audioDevices.contains(where: { $0.uniqueID == uniqueID }) else {
            refreshDevices()
            return
        }
        if enabled {
            selectedAudioDeviceIDs = [uniqueID]
            selectAudioChannelPair(start: 0)
            detectedAudioInputChannelCount = 2
            UserDefaults.standard.set(uniqueID, forKey: lastAudioDeviceIDKey)
        } else {
            selectedAudioDeviceIDs = []
        }
        guard isConfigured else { return }
        status = "Audio input selection changed. Applying..."
        scheduleSessionReconfigure()
    }

    func selectAudioChannelPair(start: Int) {
        let normalized = max(0, start - (start % 2))
        selectedAudioChannelPairStart = normalized
        audioChannelPairStartForCapture = normalized
        UserDefaults.standard.set(normalized, forKey: lastAudioChannelPairStartKey)
        status = "Audio input pair \(normalized + 1)/\(normalized + 2) selected."
    }

    var audioChannelPairStarts: [Int] {
        let channelCount = max(2, detectedAudioInputChannelCount)
        return stride(from: 0, to: channelCount, by: 2).map { $0 }
    }

    func handleTriggerKey(_ key: String) {
        guard let slot = slots.first(where: { $0.triggerKey == key }) else { return }
        handleSlot(slot.index)
    }

    func handleSlot(_ number: Int) {
        guard let slotPosition = slots.firstIndex(where: { $0.index == number }) else { return }

        switch slots[slotPosition].state {
        case .recorded:
            if selectedSlotIndex == number {
                selectedSlotIndex = nil
                status = "Unselected slot \(number)."
            } else {
                selectedSlotIndex = number
                status = "Selected slot \(number)."
            }
        case .empty:
            selectedSlotIndex = number
            if number == 1 {
                startListening(slot: 1)
            } else {
                armSlaveSlot(number)
            }
        case .listening, .armed:
            selectedSlotIndex = selectedSlotIndex == number ? nil : number
            if slots[slotPosition].state == .listening,
               isRecording,
               recordingSlotIndex == number,
               thresholdDate == nil {
                recordingSlotIndex = nil
                movieOutput.stopRecording()
                isRecording = false
            }
            if slots[slotPosition].state == .armed,
               isRecording,
               recordingSlotIndex == number {
                recordingSlotIndex = nil
                movieOutput.stopRecording()
                isRecording = false
            }
            slots[slotPosition].state = .empty
            status = "Slot \(number) disarmed."
        case .recording:
            selectedSlotIndex = number
            stopRecordingQuantized()
        }
    }

    func handleSpace() {
        if isRecording {
            if let recordingSlotIndex,
               let slotPosition = slots.firstIndex(where: { $0.index == recordingSlotIndex }),
               slots[slotPosition].state == .armed {
                status = "Slot \(recordingSlotIndex) is waiting for the master start."
                return
            }
            stopRecordingQuantized()
            return
        }

        guard let selectedSlotIndex, let slotPosition = slots.firstIndex(where: { $0.index == selectedSlotIndex }) else {
            return
        }

        guard slots[slotPosition].state == .recorded else { return }
        slots[slotPosition].isPlaying.toggle()
        audioLoopEngine.setPlaying(slot: selectedSlotIndex, isPlaying: slots[slotPosition].isPlaying)
        status = slots[slotPosition].isPlaying ? "Slot \(selectedSlotIndex) playing." : "Slot \(selectedSlotIndex) stopped."
    }

    func toggleMuteSelected() {
        guard let selectedSlotIndex, let slotPosition = slots.firstIndex(where: { $0.index == selectedSlotIndex }) else { return }
        guard slots[slotPosition].state == .recorded else { return }
        slots[slotPosition].isMuted.toggle()
        audioLoopEngine.setMuted(slot: selectedSlotIndex, isMuted: slots[slotPosition].isMuted)
        status = slots[slotPosition].isMuted ? "Slot \(selectedSlotIndex) muted." : "Slot \(selectedSlotIndex) unmuted."
    }

    func restartAudioLoop(_ number: Int) {
        guard let slot = slots.first(where: { $0.index == number }),
              slot.state == .recorded,
              slot.isPlaying
        else { return }
        audioLoopEngine.restart(slot: number)
    }

    func deleteSelected() {
        guard let selectedSlotIndex else { return }
        clearSlot(selectedSlotIndex)
    }

    func clearSlot(_ number: Int) {
        guard let slotPosition = slots.firstIndex(where: { $0.index == number }) else { return }
        slots[slotPosition].url = nil
        slots[slotPosition].createdAt = nil
        slots[slotPosition].duration = 0
        slots[slotPosition].startOffset = 0
        slots[slotPosition].state = .empty
        slots[slotPosition].isMuted = false
        slots[slotPosition].isPlaying = true
        audioLoopEngine.clear(slot: number)
        loopPlaybackTimes[number] = nil
        status = "Cleared slot \(number)."
    }

    func clearLoops() {
        for index in slots.indices {
            slots[index].url = nil
            slots[index].createdAt = nil
            slots[index].duration = 0
            slots[index].startOffset = 0
            slots[index].state = .empty
            slots[index].isMuted = false
            slots[index].isPlaying = true
        }
        selectedSlotIndex = nil
        loopPlaybackTimes.removeAll()
        audioLoopEngine.clearAll()
        status = "Cleared loops."
    }

    func toggleAllPlayback() {
        let recordedIndices = slots.indices.filter { slots[$0].state == .recorded }
        guard !recordedIndices.isEmpty else {
            status = "No recorded loops to play."
            return
        }

        let shouldPlay = !recordedIndices.contains { slots[$0].isPlaying }
        for index in recordedIndices {
            slots[index].isPlaying = shouldPlay
            if shouldPlay {
                audioLoopEngine.restart(slot: slots[index].index)
                loopPlaybackTimes[slots[index].index] = 0
            } else {
                audioLoopEngine.setPlaying(slot: slots[index].index, isPlaying: false)
            }
        }
        loopPlaybackTimeUpdatedAt = Date()
        status = shouldPlay ? "Playing all loops." : "Stopped all loops."
    }

    func setCustomPosition(slot number: Int, position: CGPointUnit) {
        guard let slotPosition = slots.firstIndex(where: { $0.index == number }) else { return }
        slots[slotPosition].customPosition = position
    }

    func setScaleForSelected(_ scale: Double) {
        guard let selectedSlotIndex, let slotPosition = slots.firstIndex(where: { $0.index == selectedSlotIndex }) else { return }
        slots[slotPosition].scale = scale
    }

    func setShapeForSelected(_ shape: LoopSlotShape) {
        guard let selectedSlotIndex, let slotPosition = slots.firstIndex(where: { $0.index == selectedSlotIndex }) else { return }
        slots[slotPosition].shape = shape
    }

    func setTriggerKeyForSelected(_ key: String) {
        guard let selectedSlotIndex, let slotPosition = slots.firstIndex(where: { $0.index == selectedSlotIndex }) else { return }

        for index in slots.indices where slots[index].triggerKey == key {
            slots[index].triggerKey = LoopSlot.defaultKey(for: slots[index].index)
        }

        slots[slotPosition].triggerKey = key
        status = "Slot \(selectedSlotIndex) key set to \(key)."
    }

    func addSlot() {
        let nextIndex = (slots.map(\.index).max() ?? 0) + 1
        slots.append(LoopSlot(index: nextIndex))
        selectedSlotIndex = nextIndex
        status = "Added slot \(nextIndex)."
    }

    func removeSelectedSlot() {
        guard let selectedSlotIndex else { return }
        guard selectedSlotIndex != 1 else {
            status = "Master slot 1 cannot be removed."
            return
        }
        guard let index = slots.firstIndex(where: { $0.index == selectedSlotIndex }) else { return }
        slots.remove(at: index)
        self.selectedSlotIndex = nil
        status = "Removed slot \(selectedSlotIndex)."
    }

    func slotPresets() -> [SlotPreset] {
        slots.map { slot in
            SlotPreset(
                index: slot.index,
                triggerKey: slot.triggerKey,
                customPosition: slot.customPosition,
                scale: slot.scale,
                shape: slot.shape
            )
        }
    }

    func applySlotPresets(_ presets: [SlotPreset]) {
        for preset in presets {
            guard let index = slots.firstIndex(where: { $0.index == preset.index }) else { continue }
            slots[index].triggerKey = preset.triggerKey
            slots[index].customPosition = preset.customPosition
            slots[index].scale = preset.scale
            slots[index].shape = preset.shape
        }
        status = "Loaded slot layout."
    }

    func applyDevicePreset(videoDeviceID: String, audioDeviceIDs: [String], audioChannelPairStart: Int?) {
        refreshDevices()
        if videoDevices.contains(where: { $0.uniqueID == videoDeviceID }) {
            selectedDeviceID = videoDeviceID
        }
        selectedAudioDeviceIDs = Set(audioDeviceIDs.filter { presetID in
            audioDevices.contains(where: { $0.uniqueID == presetID })
        })
        if selectedAudioDeviceIDs.count > 1, let firstID = selectedAudioDeviceIDs.first {
            selectedAudioDeviceIDs = [firstID]
        }
        selectAudioChannelPair(start: audioChannelPairStart ?? 0)
        if let selectedAudioID = selectedAudioDeviceIDs.first {
            UserDefaults.standard.set(selectedAudioID, forKey: lastAudioDeviceIDKey)
        }
        if isConfigured {
            scheduleSessionReconfigure()
        }
    }

    func detectTempoFromMaster() {
        guard let master = slots.first(where: { $0.index == 1 && $0.state == .recorded }), master.duration > 0 else {
            status = "Record master slot 1 before tempo detect."
            return
        }

        let detected = min(240, max(40, 240 / master.duration))
        tempoBPM = detected
        status = "Tempo detected from master: \(Int(detected.rounded())) BPM."
    }

    func updateInputMeter(rms: Double, peak: Double, presentationTime: CMTime) {
        if isRecording, recordingSlotIndex == 1, captureStartPTS == nil {
            captureStartPTS = presentationTime
        }

        inputLevel = min(1, max(inputLevel * 0.72, rms * 4.5, peak))
    }

    private func markThresholdCrossed(presentationTime: CMTime) {
        guard let masterPosition = slots.firstIndex(where: { $0.index == 1 }),
              slots[masterPosition].state == .listening,
              isRecording,
              recordingSlotIndex == 1,
              thresholdDate == nil
        else { return }

        thresholdPTS = presentationTime
        thresholdDate = Date()
        pendingStartDate = thresholdDate
        slots[masterPosition].state = .recording
        status = "Recording slot 1..."
    }

    private func startRecording(slot number: Int, fixedLength: TimeInterval? = nil) {
        guard isConfigured, !isRecording, let slotPosition = slots.firstIndex(where: { $0.index == number }) else { return }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Loopera-\(number)-\(UUID().uuidString)")
            .appendingPathExtension("mov")

        captureStartDate = Date()
        pendingStartDate = captureStartDate
        thresholdDate = nil
        captureStartPTS = nil
        thresholdPTS = nil
        pendingStopOnMasterBoundary = false
        pendingStopTrimEndSeconds = 0
        recordingSlotIndex = number
        slots[slotPosition].state = .recording
        audioLoopEngine.beginRecording(slot: number, usePreBuffer: false)
        movieOutput.startRecording(to: outputURL, recordingDelegate: self)
        isRecording = true
        status = "Recording slot \(number)..."

        stopTask?.cancel()
        if fixedLength != nil {
            let seconds = fixedLength ?? recordingLength
            stopTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                await MainActor.run {
                    self?.stopRecordingNow()
                }
            }
        }
    }

    private func armSlaveSlot(_ number: Int) {
        guard let slotPosition = slots.firstIndex(where: { $0.index == number }) else { return }
        guard masterDuration != nil else {
            slots[slotPosition].state = .armed
            status = "Slot \(number) armed. It will start when master exists."
            return
        }
        guard isConfigured, !isRecording else {
            slots[slotPosition].state = .armed
            status = "Slot \(number) armed for the next master start."
            return
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Loopera-\(number)-armed-\(UUID().uuidString)")
            .appendingPathExtension("mov")

        captureStartDate = Date()
        pendingStartDate = nil
        thresholdDate = nil
        captureStartPTS = nil
        thresholdPTS = nil
        pendingStopOnMasterBoundary = false
        pendingStopTrimEndSeconds = 0
        recordingSlotIndex = number
        slots[slotPosition].state = .armed
        movieOutput.startRecording(to: outputURL, recordingDelegate: self)
        isRecording = true
        status = "Slot \(number) armed for the next master start."
    }

    private func startListening(slot number: Int) {
        guard isConfigured, !isRecording, let slotPosition = slots.firstIndex(where: { $0.index == number }) else { return }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Loopera-\(number)-listen-\(UUID().uuidString)")
            .appendingPathExtension("mov")

        captureStartDate = Date()
        pendingStartDate = nil
        thresholdDate = nil
        captureStartPTS = nil
        thresholdPTS = nil
        pendingStopOnMasterBoundary = false
        pendingStopTrimEndSeconds = 0
        recordingSlotIndex = number
        slots[slotPosition].state = .listening
        audioLoopEngine.armThreshold(slot: number, preBufferMilliseconds: thresholdLeadMilliseconds)
        movieOutput.startRecording(to: outputURL, recordingDelegate: self)
        isRecording = true
        status = "Slot 1 listening for threshold."
    }

    private func stopRecordingQuantized() {
        guard isRecording else { return }
        guard recordingSlotIndex != 1, masterDuration != nil else {
            stopRecordingNow()
            return
        }

        stopTask?.cancel()
        let masterPhase = audioLoopEngine.phase(slot: 1) ?? 0
        let masterDuration = masterDuration ?? 0
        let sincePreviousBoundary = masterPhase * masterDuration
        let untilNextBoundary = (1 - masterPhase) * masterDuration

        if sincePreviousBoundary <= untilNextBoundary, sincePreviousBoundary > 0 {
            pendingStopTrimEndSeconds = sincePreviousBoundary
            pendingStopOnMasterBoundary = false
            stopRecordingNow()
        } else {
            pendingStopTrimEndSeconds = 0
            pendingStopOnMasterBoundary = true
            status = "Slot \(recordingSlotIndex ?? 0) will close on master boundary."
        }
    }

    private func stopRecordingNow() {
        guard isRecording else { return }
        stopTask?.cancel()
        stopTask = nil
        if let recordingSlotIndex {
            let trimEndSeconds = pendingStopTrimEndSeconds
            let duration = audioLoopEngine.finishRecording(slot: recordingSlotIndex, trimEndSeconds: trimEndSeconds)
            completedAudioDurations[recordingSlotIndex] = duration
            completedVideoEndTrims[recordingSlotIndex] = trimEndSeconds
            if duration != nil {
                audioLoopEngine.restart(slot: recordingSlotIndex, offsetSeconds: trimEndSeconds)
            }
        }
        pendingStopOnMasterBoundary = false
        pendingStopTrimEndSeconds = 0
        movieOutput.stopRecording()
        status = "Finishing loop..."
    }

    private func configureSession() {
        session.stopRunning()
        session.beginConfiguration()
        session.sessionPreset = .high
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }

        do {
            let videoDevice = videoDevices.first(where: { $0.uniqueID == selectedDeviceID }) ?? videoDevices.first
            if let videoDevice {
                let videoInput = try AVCaptureDeviceInput(device: videoDevice)
                if session.canAddInput(videoInput) {
                    session.addInput(videoInput)
                    selectedDeviceID = videoDevice.uniqueID
                }
                updateVideoFormatStatus(for: videoDevice)
            }

            for audioDevice in audioDevices where selectedAudioDeviceIDs.contains(audioDevice.uniqueID) {
                do {
                    let audioInput = try AVCaptureDeviceInput(device: audioDevice)
                    if session.canAddInput(audioInput) {
                        session.addInput(audioInput)
                    } else {
                        status = "Could not add audio input: \(audioDevice.localizedName)."
                    }
                } catch {
                    status = "Skipped audio input \(audioDevice.localizedName): \(error.localizedDescription)"
                }
            }

            if session.canAddOutput(movieOutput) {
                session.addOutput(movieOutput)
            }
            if session.canAddOutput(audioMeterOutput) {
                session.addOutput(audioMeterOutput)
            }

            session.commitConfiguration()
            isConfigured = true
            if status.hasPrefix("Skipped") || status.hasPrefix("Could not add") {
                return
            }
            status = "Ready. \(audioDeviceStatus) \(videoFormatStatus)"
        } catch {
            session.commitConfiguration()
            status = "Capture setup failed: \(error.localizedDescription)"
        }
    }

    private func updateVideoFormatStatus(for device: AVCaptureDevice) {
        let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let maxFrameRate = device.activeFormat.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
        guard dimensions.width > 0, dimensions.height > 0 else {
            videoFormatStatus = ""
            return
        }
        videoFormatStatus = "Video: \(dimensions.width)x\(dimensions.height) @ \(Int(maxFrameRate.rounded())) fps."
    }

    private func startSession() {
        let captureSession = session
        DispatchQueue.global(qos: .userInitiated).async {
            guard !captureSession.isRunning else { return }
            captureSession.startRunning()
        }
    }

    private func scheduleSessionReconfigure() {
        reconfigureTask?.cancel()
        reconfigureTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            await MainActor.run {
                guard let self else { return }
                self.configureSession()
                self.startSession()
            }
        }
    }

    private var audioDeviceStatus: String {
        let selected = audioDevices.filter { selectedAudioDeviceIDs.contains($0.uniqueID) }
        switch selected.count {
        case 0:
            return "No audio inputs selected."
        case 1:
            return "Audio: \(selected[0].localizedName)."
        default:
            return "Audio: \(selected.count) inputs selected."
        }
    }

    private func startQuantizeLoop() {
        quantizeTask?.cancel()
        quantizeTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(10))
                await MainActor.run {
                    self?.tick()
                }
            }
        }
    }

    private func tick() {
        updateLoopPlaybackTimes()

        guard let master = slots.first(where: { $0.index == 1 && $0.state == .recorded }), master.duration > 0 else {
            return
        }

        let masterPhase = audioLoopEngine.phase(slot: 1)
            ?? Date().timeIntervalSince(master.createdAt ?? Date()).truncatingRemainder(dividingBy: master.duration) / master.duration
        let crossedBoundary = didMasterCrossBoundary(currentPhase: masterPhase)

        if isRecording, pendingStopOnMasterBoundary, crossedBoundary {
            pendingStopTrimEndSeconds = max(0, master.duration * masterPhase)
            stopRecordingNow()
            return
        }

        if let recordingSlotIndex,
           isRecording,
           let slotPosition = slots.firstIndex(where: { $0.index == recordingSlotIndex }),
           slots[slotPosition].state == .armed,
           crossedBoundary {
            let preRoll = max(0, master.duration * masterPhase)
            pendingStartDate = Date().addingTimeInterval(-preRoll)
            slots[slotPosition].state = .recording
            audioLoopEngine.beginRecording(slot: recordingSlotIndex, preRollSeconds: preRoll)
            status = "Recording slot \(recordingSlotIndex)..."
            return
        }

        guard !isRecording else { return }
        if crossedBoundary, let armedPosition = slots.firstIndex(where: { $0.state == .armed && $0.index != 1 }) {
            armSlaveSlot(slots[armedPosition].index)
        }
    }

    private func didMasterCrossBoundary(currentPhase: Double) -> Bool {
        defer { previousMasterPhase = currentPhase }
        guard let previousMasterPhase else { return currentPhase < 0.03 }
        return previousMasterPhase > 0.85 && currentPhase < 0.15
    }

    private func updateLoopPlaybackTimes() {
        var times: [Int: TimeInterval] = [:]
        for slot in slots where slot.state == .recorded && slot.duration > 0 {
            if let phase = audioLoopEngine.phase(slot: slot.index) {
                times[slot.index] = phase * slot.duration
            }
        }
        loopPlaybackTimes = times
        loopPlaybackTimeUpdatedAt = Date()
    }
}

extension CaptureController: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        Task { @MainActor in
            isRecording = false

            guard let recordingSlotIndex, let slotPosition = slots.firstIndex(where: { $0.index == recordingSlotIndex }) else {
                return
            }

            if let error {
                slots[slotPosition].state = .empty
                status = "Recording failed: \(error.localizedDescription)"
                return
            }

            if slots[slotPosition].state == .listening, thresholdDate == nil {
                slots[slotPosition].state = .empty
                status = "Slot \(recordingSlotIndex) disarmed before threshold."
                self.recordingSlotIndex = nil
                return
            }

            if slots[slotPosition].state == .empty ||
                (slots[slotPosition].state == .armed && completedAudioDurations[recordingSlotIndex] == nil) {
                self.recordingSlotIndex = nil
                return
            }

            let assetDuration = await measuredDuration(for: outputFileURL)
            let engineDuration = completedAudioDurations[recordingSlotIndex]
            let duration = engineDuration
                ?? assetDuration.map { max(0.25, $0) }
                ?? Date().timeIntervalSince(pendingStartDate ?? Date())
            let endTrim = completedVideoEndTrims[recordingSlotIndex] ?? 0
            let startOffset = videoStartOffset(assetDuration: assetDuration, loopDuration: duration, endTrim: endTrim)
            slots[slotPosition].url = outputFileURL
            slots[slotPosition].createdAt = Date()
            slots[slotPosition].startOffset = startOffset
            slots[slotPosition].duration = max(0.25, duration)
            slots[slotPosition].state = .recorded
            slots[slotPosition].isPlaying = true
            slots[slotPosition].isMuted = false
            if let phase = audioLoopEngine.phase(slot: recordingSlotIndex) {
                loopPlaybackTimes[recordingSlotIndex] = phase * slots[slotPosition].duration
            }
            selectedSlotIndex = nil
            status = "Slot \(recordingSlotIndex) captured."
            completedAudioDurations[recordingSlotIndex] = nil
            completedVideoEndTrims[recordingSlotIndex] = nil
            self.recordingSlotIndex = nil
        }
    }

    private func measuredDuration(for url: URL) async -> TimeInterval? {
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration).seconds
            return duration.isFinite && duration > 0 ? duration : nil
        } catch {
            return nil
        }
    }

    private func videoStartOffset(assetDuration: TimeInterval?, loopDuration: TimeInterval, endTrim: TimeInterval) -> TimeInterval {
        guard let assetDuration, assetDuration.isFinite, assetDuration > 0, loopDuration.isFinite, loopDuration > 0 else {
            return 0
        }
        let videoEnd = max(0, assetDuration - max(0, endTrim))
        return max(0, videoEnd - loopDuration)
    }

    private func loopStartOffset() -> TimeInterval {
        guard recordingSlotIndex == 1,
              let captureStartDate,
              let thresholdDate,
              thresholdDate > captureStartDate
        else { return 0 }

        if let captureStartPTS,
           let thresholdPTS,
           thresholdPTS.isValid,
           captureStartPTS.isValid,
           thresholdPTS >= captureStartPTS {
            let mediaOffset = CMTimeSubtract(thresholdPTS, captureStartPTS).seconds
            if mediaOffset.isFinite {
                return max(0, mediaOffset - thresholdLeadMilliseconds / 1000)
            }
        }

        return max(0, thresholdDate.timeIntervalSince(captureStartDate) - thresholdLeadMilliseconds / 1000)
    }
}

extension CaptureController: AVCaptureAudioDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let capturedInput = Self.stereoInputBuffer(
            from: sampleBuffer,
            channelPairStart: audioChannelPairStartForCapture
        ), !capturedInput.buffer.isEmpty else {
            Task { @MainActor in
                inputLevel *= 0.82
            }
            return
        }

        let pts = sampleBuffer.presentationTimeStamp

        Task { @MainActor in
            detectedAudioInputChannelCount = max(2, capturedInput.channelCount)
            if selectedAudioChannelPairStart >= detectedAudioInputChannelCount {
                selectAudioChannelPair(start: 0)
            }
            let analysis = audioLoopEngine.processInput(
                samples: capturedInput.buffer,
                threshold: Float(threshold),
                preBufferMilliseconds: thresholdLeadMilliseconds
            )
            updateInputMeter(rms: analysis.rms, peak: analysis.peak, presentationTime: pts)
            if case .thresholdCrossed = analysis.event {
                markThresholdCrossed(presentationTime: pts)
            }
        }
    }

    private nonisolated static func stereoInputBuffer(
        from sampleBuffer: CMSampleBuffer,
        channelPairStart: Int
    ) -> CapturedStereoInput? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        else { return nil }

        let asbd = streamDescription.pointee
        guard asbd.mFormatID == kAudioFormatLinearPCM else { return nil }

        var neededSize = 0
        var retainedBlockBuffer: CMBlockBuffer?
        let sizingStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &neededSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            blockBufferOut: &retainedBlockBuffer
        )
        guard sizingStatus == noErr, neededSize > 0 else { return nil }

        let flags = asbd.mFormatFlags
        let isFloat = (flags & kAudioFormatFlagIsFloat) != 0
        let isSignedInteger = (flags & kAudioFormatFlagIsSignedInteger) != 0
        let bits = Int(asbd.mBitsPerChannel)
        let channels = max(1, Int(asbd.mChannelsPerFrame))
        let isNonInterleaved = (flags & kAudioFormatFlagIsNonInterleaved) != 0

        var rawBufferList = [UInt8](repeating: 0, count: neededSize)
        return rawBufferList.withUnsafeMutableBytes { rawBytes in
            guard let baseAddress = rawBytes.baseAddress else { return nil }
            let audioBufferList = baseAddress.assumingMemoryBound(to: AudioBufferList.self)
            var blockBuffer: CMBlockBuffer?
            let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                sampleBuffer,
                bufferListSizeNeededOut: nil,
                bufferListOut: audioBufferList,
                bufferListSize: neededSize,
                blockBufferAllocator: kCFAllocatorDefault,
                blockBufferMemoryAllocator: kCFAllocatorDefault,
                flags: 0,
                blockBufferOut: &blockBuffer
            )
            guard status == noErr else { return nil }

            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let channelSamples = buffers.compactMap { buffer -> [Float]? in
                guard let data = buffer.mData, buffer.mDataByteSize > 0 else { return nil }
                return convertBuffer(
                    data: data,
                    byteCount: Int(buffer.mDataByteSize),
                    isFloat: isFloat,
                    isSignedInteger: isSignedInteger,
                    bits: bits
                )
            }
            guard !channelSamples.isEmpty else { return nil }
            let channelCount = isNonInterleaved || channelSamples.count > 1 ? channelSamples.count : channels

            if isNonInterleaved || channelSamples.count > 1 {
                return CapturedStereoInput(
                    buffer: stereoPlanarPair(channelSamples, channelPairStart: channelPairStart),
                    channelCount: channelCount
                )
            }

            return CapturedStereoInput(
                buffer: stereoInterleavedPair(samples: channelSamples[0], channels: channels, channelPairStart: channelPairStart),
                channelCount: channelCount
            )
        }
    }

    private nonisolated static func convertBuffer(
        data: UnsafeMutableRawPointer,
        byteCount: Int,
        isFloat: Bool,
        isSignedInteger: Bool,
        bits: Int
    ) -> [Float]? {
        if isFloat && bits == 32 {
            let count = byteCount / MemoryLayout<Float>.size
            let samples = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count)
            return samples.map { sanitize($0) }
        }

        if isFloat && bits == 64 {
            let count = byteCount / MemoryLayout<Double>.size
            let samples = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Double.self), count: count)
            return samples.map { sanitize(Float($0)) }
        }

        if isSignedInteger && bits == 8 {
            let count = byteCount / MemoryLayout<Int8>.size
            let samples = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Int8.self), count: count)
            return samples.map { sanitize(Float($0) / Float(Int8.max)) }
        }

        if isSignedInteger && bits == 16 {
            let count = byteCount / MemoryLayout<Int16>.size
            let samples = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Int16.self), count: count)
            return samples.map { sanitize(Float($0) / Float(Int16.max)) }
        }

        if isSignedInteger && bits == 24 {
            let bytes = data.assumingMemoryBound(to: UInt8.self)
            let count = byteCount / 3
            var output: [Float] = []
            output.reserveCapacity(count)
            for index in 0..<count {
                let base = index * 3
                var value = Int32(bytes[base]) | (Int32(bytes[base + 1]) << 8) | (Int32(bytes[base + 2]) << 16)
                if (value & 0x0080_0000) != 0 {
                    value |= ~0x00FF_FFFF
                }
                output.append(sanitize(Float(value) / 8_388_607))
            }
            return output
        }

        if isSignedInteger && bits == 32 {
            let count = byteCount / MemoryLayout<Int32>.size
            let samples = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Int32.self), count: count)
            return samples.map { sanitize(Float($0) / Float(Int32.max)) }
        }

        return nil
    }

    private nonisolated static func sanitize(_ sample: Float) -> Float {
        guard sample.isFinite else { return 0 }
        return max(-1, min(1, sample))
    }

    private nonisolated static func stereoPlanarPair(
        _ channels: [[Float]],
        channelPairStart: Int
    ) -> AudioLoopEngine.InputBuffer {
        guard let frameCount = channels.map(\.count).min(), frameCount > 0 else {
            return AudioLoopEngine.InputBuffer(left: [], right: [])
        }
        let leftIndex = min(max(0, channelPairStart), channels.count - 1)
        let rightIndex = min(leftIndex + 1, channels.count - 1)
        let leftChannel = channels[leftIndex]
        let rightChannel = channels[rightIndex]
        var left: [Float] = []
        var right: [Float] = []
        left.reserveCapacity(frameCount)
        right.reserveCapacity(frameCount)
        for frame in 0..<frameCount {
            left.append(leftChannel[frame])
            right.append(rightChannel[frame])
        }
        return AudioLoopEngine.InputBuffer(left: left, right: right)
    }

    private nonisolated static func stereoInterleavedPair<S: Collection>(
        samples: S,
        channels: Int,
        channelPairStart: Int
    ) -> AudioLoopEngine.InputBuffer where S.Element == Float {
        let array = Array(samples)
        guard channels > 1 else {
            return AudioLoopEngine.InputBuffer(left: array, right: array)
        }
        let frameCount = array.count / channels
        guard frameCount > 0 else {
            return AudioLoopEngine.InputBuffer(left: [], right: [])
        }

        var left: [Float] = []
        var right: [Float] = []
        left.reserveCapacity(frameCount)
        right.reserveCapacity(frameCount)
        let leftIndex = min(max(0, channelPairStart), channels - 1)
        let rightIndex = min(leftIndex + 1, channels - 1)
        for frame in 0..<frameCount {
            let base = frame * channels
            left.append(array[base + leftIndex])
            right.append(array[base + rightIndex])
        }
        return AudioLoopEngine.InputBuffer(left: left, right: right)
    }
}

private extension TimeInterval {
    var nonZero: TimeInterval? {
        self > 0 ? self : nil
    }
}
