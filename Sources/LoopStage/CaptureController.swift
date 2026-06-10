import AppKit
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
    @Published var threshold: Double = 0.006 {
        didSet { thresholdForCapture = threshold }
    }
    @Published var thresholdLeadMilliseconds: Double = 80 {
        didSet { thresholdLeadMillisecondsForCapture = thresholdLeadMilliseconds }
    }
    @Published var tempoBPM: Double?
    @Published var selectedSlotIndex: Int?
    @Published var crossfadeMilliseconds: Double = 35
    @Published var metronomeGridBPM: Double?
    @Published var offsetProfile = OffsetProfile()
    @Published var masterVolume: Double = 1 {
        didSet {
            let clamped = max(0, min(1.5, masterVolume))
            UserDefaults.standard.set(clamped, forKey: masterVolumeKey)
            audioLoopEngine.setMasterVolume(clamped)
        }
    }
    @Published private(set) var loopPlaybackTimes: [Int: TimeInterval] = [:]
    @Published private(set) var loopPlaybackTimeUpdatedAt = Date()
    @Published private(set) var waveformSnapshots: [AudioLoopEngine.WaveformSnapshot] = []
    @Published private(set) var videoFormatStatus = ""
    @Published var videoInputMode: VideoInputMode = .camera
    @Published private(set) var appWindowSources: [AppWindowSource] = []
    @Published var selectedAppWindowID: CGWindowID?
    @Published private(set) var appWindowCaptureAccessGranted = AppWindowSourceStore.hasScreenCaptureAccess
    private var currentVideoZoom = 1.0

    private let movieOutput = AVCaptureMovieFileOutput()
    private let appWindowLoopRecorder = AppWindowLoopRecorder()
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
    private var completedVideoStartTrims: [Int: TimeInterval] = [:]
    private var recordingSlotByOutputURL: [URL: Int] = [:]
    private var activeVideoRecordingMode: VideoInputMode?
    private var pendingStopOnMasterBoundary = false
    private var pendingStopTrimEndSeconds: TimeInterval = 0
    private var pendingStartTrimSeconds: TimeInterval = 0
    private var pendingStopTargetDuration: TimeInterval?
    private var quantizeTask: Task<Void, Never>?
    private var reconfigureTask: Task<Void, Never>?
    private var previousMasterPhase: Double?
    private var previousStoppingPhases: [Int: Double] = [:]
    private var lastPlaybackPublishDate = Date.distantPast
    private var lastMeterPublishDate = Date.distantPast
    private var metronomeGridStartDate: Date?
    nonisolated(unsafe) var performanceAudioHandler: ((AudioLoopEngine.InputBuffer, Double, CMTime) -> Void)?
    private nonisolated(unsafe) var audioChannelPairStartForCapture = 0
    private nonisolated(unsafe) var detectedAudioInputChannelCountForCapture = 2
    private nonisolated(unsafe) var thresholdForCapture = 0.006
    private nonisolated(unsafe) var thresholdLeadMillisecondsForCapture = 80.0
    private nonisolated(unsafe) var lastMeterPublishDateForCapture = Date.distantPast
    private let lastAudioDeviceIDKey = "Loopera.lastAudioDeviceID"
    private let lastAudioChannelPairStartKey = "Loopera.lastAudioChannelPairStart"
    private let masterVolumeKey = "Loopera.masterVolume"

    private struct CapturedStereoInput {
        var buffer: AudioLoopEngine.InputBuffer
        var channelCount: Int
        var sampleRate: Double
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
        thresholdForCapture = threshold
        thresholdLeadMillisecondsForCapture = thresholdLeadMilliseconds
        audioMeterOutput.setSampleBufferDelegate(self, queue: audioMeterQueue)
        offsetProfile = OffsetProfileStore.load(audioDeviceID: selectedAudioDeviceIDs.first, videoDeviceID: selectedDeviceID)
        audioLoopEngine.apply(profile: offsetProfile)
        let savedVolume = UserDefaults.standard.object(forKey: masterVolumeKey) == nil
            ? 1
            : UserDefaults.standard.double(forKey: masterVolumeKey)
        masterVolume = max(0, min(1.5, savedVolume))
        audioLoopEngine.setMasterVolume(masterVolume)
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

    func shutdown() {
        stopTask?.cancel()
        stopTask = nil
        quantizeTask?.cancel()
        quantizeTask = nil
        reconfigureTask?.cancel()
        reconfigureTask = nil
        performanceAudioHandler = nil
        audioLoopEngine.performanceOutputHandler = nil
        audioLoopEngine.stop()
        if movieOutput.isRecording {
            movieOutput.stopRecording()
        }
        appWindowLoopRecorder.stopDiscarding()
        session.stopRunning()
        isRecording = false
    }

    func refreshDevices() {
        videoDevices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .continuityCamera, .external],
            mediaType: .video,
            position: .unspecified
        ).devices

        audioDevices = AVCaptureDevice.devices(for: .audio)
        refreshAppWindowSources()

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

    func refreshAppWindowSources() {
        appWindowCaptureAccessGranted = AppWindowSourceStore.hasScreenCaptureAccess
        appWindowSources = AppWindowSourceStore.currentWindows()
        if let selectedAppWindowID,
           appWindowSources.contains(where: { $0.id == selectedAppWindowID }) {
            return
        }
        selectedAppWindowID = appWindowSources.first?.id
        if appWindowSources.isEmpty {
            status = appWindowCaptureAccessGranted
                ? "No app windows found. Bring the source app out of fullscreen or refresh windows."
                : "No app windows found. Screen Recording may need Loopera removed and re-added in System Settings."
        } else if appWindowCaptureAccessGranted {
            status = "Found \(appWindowSources.count) app window(s)."
        } else {
            status = "Found \(appWindowSources.count) app window(s). If preview is blank, remove/re-add Loopera in Screen Recording."
        }
    }

    func selectVideoInputMode(_ mode: VideoInputMode) {
        videoInputMode = mode
        if mode == .appWindow {
            refreshAppWindowSources()
        } else {
            status = "Video source: \(mode.rawValue)."
        }
    }

    func selectAppWindow(_ windowID: CGWindowID) {
        selectedAppWindowID = windowID
        status = "App window selected."
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
            detectedAudioInputChannelCountForCapture = 2
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
                stopActiveVideoRecording()
                isRecording = false
            }
            if slots[slotPosition].state == .armed,
               isRecording,
               recordingSlotIndex == number {
                recordingSlotIndex = nil
                stopActiveVideoRecording()
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
        if slots[slotPosition].isPlaying {
            guard !slots[slotPosition].isStopping else { return }
            slots[slotPosition].isStopping = true
            slots[slotPosition].stoppingStartedAt = Date()
            previousStoppingPhases[selectedSlotIndex] = audioLoopEngine.phase(slot: selectedSlotIndex)
            audioLoopEngine.setPlaying(slot: selectedSlotIndex, isPlaying: false)
            status = "Slot \(selectedSlotIndex) fading to loop start."
        } else {
            slots[slotPosition].isPlaying = true
            slots[slotPosition].isStopping = false
            slots[slotPosition].stoppingStartedAt = nil
            previousStoppingPhases[selectedSlotIndex] = nil
            startPlaybackSynced(slot: selectedSlotIndex)
            loopPlaybackTimeUpdatedAt = Date()
            status = "Slot \(selectedSlotIndex) playing."
        }
    }

    private func startPlaybackSynced(slot selectedSlotIndex: Int) {
        if selectedSlotIndex == 1 {
            audioLoopEngine.restart(slot: 1)
            loopPlaybackTimes[1] = 0
            for index in slots.indices where slots[index].state == .recorded && slots[index].isPlaying && slots[index].index != 1 {
                audioLoopEngine.restartSyncedToMaster(slot: slots[index].index)
                loopPlaybackTimes[slots[index].index] = 0
            }
            return
        }

        if let master = slots.first(where: { $0.index == 1 && $0.state == .recorded && $0.isPlaying }),
           master.duration > 0 {
            audioLoopEngine.restartSyncedToMaster(slot: selectedSlotIndex)
            let phase = audioLoopEngine.phase(slot: selectedSlotIndex) ?? 0
            loopPlaybackTimes[selectedSlotIndex] = phase * (slots.first(where: { $0.index == selectedSlotIndex })?.duration ?? 0)
        } else {
            audioLoopEngine.restart(slot: selectedSlotIndex)
            loopPlaybackTimes[selectedSlotIndex] = 0
        }
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

    func setPerformanceLoopAudioHandler(_ handler: ((AudioLoopEngine.InputBuffer, Double, CMTime) -> Void)?) {
        audioLoopEngine.performanceOutputHandler = handler
    }

    func applyOffsetProfile(_ profile: OffsetProfile) {
        offsetProfile = profile
        crossfadeMilliseconds = profile.crossfadeMilliseconds
        audioLoopEngine.apply(profile: profile)
        status = "Offset settings applied."
    }

    func saveOffsetProfile(_ profile: OffsetProfile) {
        applyOffsetProfile(profile)
        OffsetProfileStore.save(profile, audioDeviceID: selectedAudioDeviceIDs.first, videoDeviceID: selectedDeviceID)
        status = "Offset settings saved for current devices."
    }

    func setLivePreviewZoom(_ zoom: Double) {
        currentVideoZoom = max(1, zoom)
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
        slots[slotPosition].videoZoom = 1
        slots[slotPosition].state = .empty
        slots[slotPosition].isMuted = false
        slots[slotPosition].isPlaying = true
        slots[slotPosition].isStopping = false
        slots[slotPosition].stoppingStartedAt = nil
        audioLoopEngine.clear(slot: number)
        loopPlaybackTimes[number] = nil
        previousStoppingPhases[number] = nil
        status = "Cleared slot \(number)."
    }

    func clearLoops() {
        for index in slots.indices {
            slots[index].url = nil
            slots[index].createdAt = nil
            slots[index].duration = 0
            slots[index].startOffset = 0
            slots[index].videoZoom = 1
            slots[index].state = .empty
            slots[index].isMuted = false
            slots[index].isPlaying = true
            slots[index].isStopping = false
            slots[index].stoppingStartedAt = nil
        }
        selectedSlotIndex = nil
        loopPlaybackTimes.removeAll()
        previousStoppingPhases.removeAll()
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
            slots[index].isStopping = false
            slots[index].stoppingStartedAt = nil
            if shouldPlay {
                if slots[index].index == 1 {
                    audioLoopEngine.restart(slot: 1)
                } else {
                    audioLoopEngine.restartSyncedToMaster(slot: slots[index].index)
                }
                loopPlaybackTimes[slots[index].index] = audioLoopEngine.phase(slot: slots[index].index).map { $0 * slots[index].duration } ?? 0
            } else {
                slots[index].isStopping = true
                slots[index].stoppingStartedAt = Date()
                audioLoopEngine.setPlaying(slot: slots[index].index, isPlaying: false)
                previousStoppingPhases[slots[index].index] = audioLoopEngine.phase(slot: slots[index].index)
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
        let savedIndices = Set(presets.map(\.index))
        slots.removeAll { slot in
            slot.index != 1 && !savedIndices.contains(slot.index)
        }

        for preset in presets where !slots.contains(where: { $0.index == preset.index }) {
            slots.append(LoopSlot(index: preset.index))
        }
        slots.sort { $0.index < $1.index }

        for preset in presets {
            guard let index = slots.firstIndex(where: { $0.index == preset.index }) else { continue }
            slots[index].triggerKey = preset.triggerKey
            slots[index].customPosition = preset.customPosition
            slots[index].scale = preset.scale
            slots[index].shape = preset.shape
        }
        if let selectedSlotIndex, !slots.contains(where: { $0.index == selectedSlotIndex }) {
            self.selectedSlotIndex = nil
        }
        status = "Loaded slot layout."
    }

    func applyDevicePreset(videoDeviceID: String, audioDeviceIDs: [String], audioChannelPairStart: Int?, refresh: Bool = true) {
        if refresh {
            refreshDevices()
        }
        let previousVideoID = selectedDeviceID
        let previousAudioIDs = selectedAudioDeviceIDs
        let previousPairStart = selectedAudioChannelPairStart
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
        let devicesChanged = previousVideoID != selectedDeviceID ||
            previousAudioIDs != selectedAudioDeviceIDs ||
            previousPairStart != selectedAudioChannelPairStart
        if isConfigured, devicesChanged {
            scheduleSessionReconfigure(delayMilliseconds: refresh ? 450 : 80)
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

    func setMetronomeGrid(bpm: Double?, startDate: Date?) {
        if let bpm {
            metronomeGridBPM = max(20, min(300, bpm))
            metronomeGridStartDate = startDate
        } else {
            metronomeGridBPM = nil
            metronomeGridStartDate = nil
        }
    }

    func updateInputMeter(rms: Double, peak: Double, presentationTime: CMTime) {
        if isRecording, recordingSlotIndex == 1, captureStartPTS == nil {
            captureStartPTS = presentationTime
        }

        let now = Date()
        guard now.timeIntervalSince(lastMeterPublishDate) >= 1.0 / 15.0 else { return }
        let nextLevel = min(1, max(inputLevel * 0.72, rms * 4.5, peak))
        guard abs(nextLevel - inputLevel) >= 0.008 || nextLevel >= threshold else { return }
        lastMeterPublishDate = now
        inputLevel = nextLevel
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
        pendingStartTrimSeconds = metronomeStartTrimSeconds(thresholdDate: thresholdDate)
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
        pendingStopTargetDuration = nil
        pendingStartTrimSeconds = 0
        recordingSlotIndex = number
        slots[slotPosition].state = .recording
        audioLoopEngine.beginRecording(slot: number, usePreBuffer: false)
        guard startLoopVideoRecording(to: outputURL, slot: number) else {
            audioLoopEngine.clear(slot: number)
            slots[slotPosition].state = .empty
            recordingSlotIndex = nil
            return
        }
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
        pendingStopTargetDuration = nil
        pendingStartTrimSeconds = 0
        recordingSlotIndex = number
        slots[slotPosition].state = .armed
        guard startLoopVideoRecording(to: outputURL, slot: number) else {
            slots[slotPosition].state = .empty
            recordingSlotIndex = nil
            return
        }
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
        pendingStopTargetDuration = nil
        pendingStartTrimSeconds = 0
        recordingSlotIndex = number
        slots[slotPosition].state = .listening
        audioLoopEngine.armThreshold(slot: number, preBufferMilliseconds: thresholdLeadMilliseconds)
        guard startLoopVideoRecording(to: outputURL, slot: number) else {
            audioLoopEngine.clear(slot: number)
            slots[slotPosition].state = .empty
            recordingSlotIndex = nil
            return
        }
        isRecording = true
        status = "Slot 1 listening for threshold."
    }

    private func stopRecordingQuantized() {
        guard isRecording else { return }
        if recordingSlotIndex == 1,
           let metronomeGridBPM,
           metronomeGridStartDate != nil,
           let currentDuration = audioLoopEngine.currentRecordingDuration(slot: 1),
           let targetDuration = targetMetronomeStopDuration(max(0, currentDuration - pendingStartTrimSeconds), bpm: metronomeGridBPM) {
            let delay = targetDuration - max(0, currentDuration - pendingStartTrimSeconds)
            if delay > 0.02 {
                stopTask?.cancel()
                status = "Master will close on metronome beat."
                stopTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(delay))
                    await MainActor.run {
                        self?.stopRecordingNow()
                    }
                }
                return
            }
        }
        guard recordingSlotIndex != 1, masterDuration != nil else {
            stopRecordingNow()
            return
        }

        stopTask?.cancel()
        let masterPhase = audioLoopEngine.phase(slot: 1) ?? 0
        let masterDuration = masterDuration ?? 0
        let sincePreviousBoundary = audioLoopEngine.masterBoundaryOffsetSeconds() ?? masterPhase * masterDuration
        let untilNextBoundary = max(0, masterDuration - sincePreviousBoundary)
        let currentRecordingDuration = recordingSlotIndex.flatMap {
            audioLoopEngine.currentRecordingDuration(slot: $0)
        } ?? 0
        // Slave audio must finish to an exact master multiple. Keep
        // pendingStopTargetDuration in sync with every immediate/scheduled stop;
        // otherwise the UI can show a quantized length while the audio buffer drifts.
        if let metronomeGridBPM, metronomeGridStartDate != nil {
            let beat = 60.0 / metronomeGridBPM
            let previousBoundaryGrace = beat * 1.5
            if currentRecordingDuration >= masterDuration,
               sincePreviousBoundary > 0,
               sincePreviousBoundary <= untilNextBoundary,
               sincePreviousBoundary <= previousBoundaryGrace {
                pendingStopTrimEndSeconds = sincePreviousBoundary
                pendingStopOnMasterBoundary = false
                pendingStopTargetDuration = slaveTargetDuration(
                    currentDuration: currentRecordingDuration,
                    trimEndSeconds: sincePreviousBoundary,
                    masterDuration: masterDuration
                )
                stopRecordingNow()
            } else {
                scheduleStopAtMasterLength(currentDuration: currentRecordingDuration, masterDuration: masterDuration)
            }
            return
        }

        if currentRecordingDuration >= masterDuration,
           sincePreviousBoundary <= untilNextBoundary,
           sincePreviousBoundary > 0 {
            pendingStopTrimEndSeconds = sincePreviousBoundary
            pendingStopOnMasterBoundary = false
            pendingStopTargetDuration = slaveTargetDuration(
                currentDuration: currentRecordingDuration,
                trimEndSeconds: sincePreviousBoundary,
                masterDuration: masterDuration
            )
            stopRecordingNow()
        } else {
            scheduleStopAtMasterLength(currentDuration: currentRecordingDuration, masterDuration: masterDuration)
        }
    }

    private func slaveTargetDuration(
        currentDuration: TimeInterval,
        trimEndSeconds: TimeInterval,
        masterDuration: TimeInterval
    ) -> TimeInterval? {
        guard currentDuration.isFinite,
              trimEndSeconds.isFinite,
              masterDuration.isFinite,
              masterDuration > 0
        else { return nil }

        let effectiveDuration = max(0, currentDuration - max(0, trimEndSeconds))
        let multiple = max(1, Int((effectiveDuration / masterDuration).rounded()))
        return Double(multiple) * masterDuration
    }

    private func scheduleStopAtMasterLength(currentDuration: TimeInterval, masterDuration: TimeInterval) {
        guard let recordingSlotIndex, masterDuration.isFinite, masterDuration > 0 else { return }
        let multiple = max(1, Int(ceil(max(0, currentDuration) / masterDuration)))
        let targetDuration = Double(multiple) * masterDuration
        pendingStopTrimEndSeconds = 0
        pendingStopOnMasterBoundary = true
        pendingStopTargetDuration = targetDuration
        stopTask?.cancel()
        status = "Slot \(recordingSlotIndex) will close on master boundary."
    }

    private func stopRecordingNow() {
        guard isRecording else { return }
        stopTask?.cancel()
        stopTask = nil
        isRecording = false
        let shouldStopMovie = movieOutput.isRecording
        let shouldStopWindow = activeVideoRecordingMode == .appWindow
        var audioLoopCompleted = false
        if let recordingSlotIndex {
            let trimStartSeconds = recordingSlotIndex == 1 ? pendingStartTrimSeconds : 0
            var trimEndSeconds = pendingStopTrimEndSeconds
            let targetDuration = recordingSlotIndex == 1 ? nil : pendingStopTargetDuration
            if recordingSlotIndex == 1 {
                trimEndSeconds = max(0, trimEndSeconds + offsetProfile.audioStopOffsetMilliseconds / 1000)
                if let metronomeGridBPM,
                   metronomeGridStartDate != nil,
                   let currentDuration = audioLoopEngine.currentRecordingDuration(slot: recordingSlotIndex) {
                    let effectiveDuration = max(0, currentDuration - trimStartSeconds)
                    let quantized = quantizedMetronomeDuration(effectiveDuration, bpm: metronomeGridBPM)
                    trimEndSeconds = max(0, effectiveDuration - quantized)
                }
            }
            let duration = audioLoopEngine.finishRecording(
                slot: recordingSlotIndex,
                trimStartSeconds: trimStartSeconds,
                trimEndSeconds: trimEndSeconds,
                targetDurationSeconds: targetDuration,
                playbackStart: recordingSlotIndex == 1
                    ? .restart(offsetSeconds: trimEndSeconds)
                    : .syncedToMaster
            )
            completedAudioDurations[recordingSlotIndex] = duration
            completedVideoEndTrims[recordingSlotIndex] = trimEndSeconds
            completedVideoStartTrims[recordingSlotIndex] = trimStartSeconds
            if duration != nil {
                audioLoopCompleted = true
                markAudioLoopReady(slot: recordingSlotIndex, duration: duration)
                Task.detached(priority: .utility) { [audioLoopEngine] in
                    audioLoopEngine.refreshRecordedWaveform(slot: recordingSlotIndex)
                }
            }
        }
        pendingStopOnMasterBoundary = false
        pendingStopTrimEndSeconds = 0
        pendingStopTargetDuration = nil
        pendingStartTrimSeconds = 0
        if shouldStopMovie {
            movieOutput.stopRecording()
        } else if shouldStopWindow {
            appWindowLoopRecorder.stop { [weak self] url, error in
                Task { @MainActor in
                    await self?.handleLoopVideoFinished(outputFileURL: url, error: error)
                }
            }
        }
        status = audioLoopCompleted ? "Audio loop playing. Finishing video..." : "Finishing loop..."
    }

    private func startLoopVideoRecording(to outputURL: URL, slot: Int) -> Bool {
        recordingSlotByOutputURL[outputURL] = slot
        activeVideoRecordingMode = videoInputMode
        switch videoInputMode {
        case .camera:
            configureMovieOutputForHighQuality()
            movieOutput.startRecording(to: outputURL, recordingDelegate: self)
            return true
        case .appWindow:
            do {
                try appWindowLoopRecorder.start(windowID: selectedAppWindowID, outputURL: outputURL)
                return true
            } catch {
                recordingSlotByOutputURL[outputURL] = nil
                activeVideoRecordingMode = nil
                status = "Window video failed: \(error.localizedDescription)"
                return false
            }
        }
    }

    private func stopActiveVideoRecording() {
        if movieOutput.isRecording {
            movieOutput.stopRecording()
        }
        if activeVideoRecordingMode == .appWindow {
            appWindowLoopRecorder.stopDiscarding()
        }
        activeVideoRecordingMode = nil
    }

    private func markAudioLoopReady(slot number: Int, duration: TimeInterval?) {
        guard let duration,
              let slotPosition = slots.firstIndex(where: { $0.index == number })
        else { return }

        slots[slotPosition].createdAt = Date()
        slots[slotPosition].duration = max(0.25, duration)
        slots[slotPosition].state = .recorded
        slots[slotPosition].isPlaying = true
        slots[slotPosition].isStopping = false
        slots[slotPosition].stoppingStartedAt = nil
        slots[slotPosition].isMuted = false
        if let phase = audioLoopEngine.phase(slot: number) {
            loopPlaybackTimes[number] = phase * slots[slotPosition].duration
            loopPlaybackTimeUpdatedAt = Date()
        }
        selectedSlotIndex = nil
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

    private func configureMovieOutputForHighQuality() {
        guard let connection = movieOutput.connection(with: .video) else { return }
        movieOutput.connection(with: .audio)?.isEnabled = false
        let videoDevice = videoDevices.first(where: { $0.uniqueID == selectedDeviceID }) ?? videoDevices.first
        let dimensions = videoDevice.map { CMVideoFormatDescriptionGetDimensions($0.activeFormat.formatDescription) }
        let width = Int(dimensions?.width ?? 1920)
        let height = Int(dimensions?.height ?? 1080)
        let bitrate = max(25_000_000, width * height * 14)
        movieOutput.setOutputSettings(
            [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: bitrate,
                    AVVideoExpectedSourceFrameRateKey: 60,
                    AVVideoMaxKeyFrameIntervalKey: 60,
                    AVVideoAllowFrameReorderingKey: false
                ]
            ],
            for: connection
        )
    }

    private func startSession() {
        let captureSession = session
        DispatchQueue.global(qos: .userInitiated).async {
            guard !captureSession.isRunning else { return }
            captureSession.startRunning()
        }
    }

    private func scheduleSessionReconfigure(delayMilliseconds: Int = 450) {
        reconfigureTask?.cancel()
        reconfigureTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(delayMilliseconds))
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
                let interval = await MainActor.run {
                    self?.quantizeTickIntervalMilliseconds() ?? 100
                }
                try? await Task.sleep(for: .milliseconds(interval))
                await MainActor.run {
                    self?.tick()
                }
            }
        }
    }

    private func quantizeTickIntervalMilliseconds() -> Int {
        if isRecording { return 10 }
        if slots.contains(where: { $0.state == .armed || $0.isStopping }) { return 10 }
        if slots.contains(where: { $0.state == .recorded && $0.isPlaying }) { return 16 }
        return 120
    }

    private func tick() {
        updateLoopPlaybackTimesIfNeeded()
        finishStoppingLoopsAtBoundary()

        guard let master = slots.first(where: { $0.index == 1 && $0.state == .recorded }), master.duration > 0 else {
            return
        }

        let masterPhase = audioLoopEngine.phase(slot: 1)
            ?? Date().timeIntervalSince(master.createdAt ?? Date()).truncatingRemainder(dividingBy: master.duration) / master.duration
        let crossedBoundary = didMasterCrossBoundary(currentPhase: masterPhase)

        if isRecording, pendingStopOnMasterBoundary, crossedBoundary {
            pendingStopTrimEndSeconds = max(0, audioLoopEngine.masterBoundaryOffsetSeconds() ?? master.duration * masterPhase)
            stopRecordingNow()
            return
        }

        if let recordingSlotIndex,
           isRecording,
           let slotPosition = slots.firstIndex(where: { $0.index == recordingSlotIndex }),
           slots[slotPosition].state == .armed,
           crossedBoundary {
            let preRoll = max(0, audioLoopEngine.masterBoundaryOffsetSeconds() ?? master.duration * masterPhase)
            pendingStartDate = Date().addingTimeInterval(-preRoll)
            slots[slotPosition].state = .recording
            audioLoopEngine.beginRecordingSyncedToMaster(slot: recordingSlotIndex)
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

    private func updateLoopPlaybackTimesIfNeeded(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastPlaybackPublishDate) >= 1.0 / 30.0 else { return }
        lastPlaybackPublishDate = now
        var times: [Int: TimeInterval] = [:]
        for slot in slots where slot.state == .recorded && slot.duration > 0 {
            if let phase = audioLoopEngine.phase(slot: slot.index) {
                times[slot.index] = phase * slot.duration
            }
        }
        loopPlaybackTimes = times
        loopPlaybackTimeUpdatedAt = now
        waveformSnapshots = audioLoopEngine.waveformSnapshots()
    }

    private func finishStoppingLoopsAtBoundary() {
        for index in slots.indices where slots[index].isStopping {
            let slotIndex = slots[index].index
            guard let phase = audioLoopEngine.phase(slot: slotIndex) else {
                slots[index].isStopping = false
                slots[index].stoppingStartedAt = nil
                slots[index].isPlaying = false
                previousStoppingPhases[slotIndex] = nil
                loopPlaybackTimes[slotIndex] = 0
                continue
            }

            let previous = previousStoppingPhases[slotIndex] ?? phase
            if previous > 0.85 && phase < 0.15 {
                slots[index].isStopping = false
                slots[index].stoppingStartedAt = nil
                slots[index].isPlaying = false
                previousStoppingPhases[slotIndex] = nil
                loopPlaybackTimes[slotIndex] = 0
            } else {
                previousStoppingPhases[slotIndex] = phase
            }
        }
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
            await handleLoopVideoFinished(outputFileURL: outputFileURL, error: error)
        }
    }

    private func handleLoopVideoFinished(outputFileURL: URL, error: Error?) async {
        isRecording = false
        activeVideoRecordingMode = nil

        let finishedSlotIndex = recordingSlotByOutputURL.removeValue(forKey: outputFileURL) ?? recordingSlotIndex
        guard let finishedSlotIndex, let slotPosition = slots.firstIndex(where: { $0.index == finishedSlotIndex }) else {
            return
        }

        if let error {
            if completedAudioDurations[finishedSlotIndex] != nil {
                slots[slotPosition].url = nil
                status = "Video failed, audio loop kept: \(error.localizedDescription)"
                completedAudioDurations[finishedSlotIndex] = nil
                completedVideoEndTrims[finishedSlotIndex] = nil
                completedVideoStartTrims[finishedSlotIndex] = nil
                if recordingSlotIndex == finishedSlotIndex {
                    self.recordingSlotIndex = nil
                }
            } else {
                slots[slotPosition].state = .empty
                status = "Recording failed: \(error.localizedDescription)"
                if recordingSlotIndex == finishedSlotIndex {
                    self.recordingSlotIndex = nil
                }
            }
            return
        }

        if slots[slotPosition].state == .listening, thresholdDate == nil {
            slots[slotPosition].state = .empty
            status = "Slot \(finishedSlotIndex) disarmed before threshold."
            if recordingSlotIndex == finishedSlotIndex {
                self.recordingSlotIndex = nil
            }
            return
        }

        if slots[slotPosition].state == .empty ||
            (slots[slotPosition].state == .armed && completedAudioDurations[finishedSlotIndex] == nil) {
            if recordingSlotIndex == finishedSlotIndex {
                self.recordingSlotIndex = nil
            }
            return
        }

        let assetDuration = await measuredDuration(for: outputFileURL)
        let engineDuration = completedAudioDurations[finishedSlotIndex]
        let rawDuration = engineDuration
            ?? assetDuration.map { max(0.25, $0) }
            ?? Date().timeIntervalSince(pendingStartDate ?? Date())
        let duration = quantizedLoopDuration(rawDuration, slot: finishedSlotIndex)
        let endTrim = completedVideoEndTrims[finishedSlotIndex] ?? 0
        let startTrim = completedVideoStartTrims[finishedSlotIndex] ?? 0
        let mediaAlignedStartOffset = videoStartOffset(
            assetDuration: assetDuration,
            loopDuration: duration,
            endTrim: endTrim
        )
        let startOffset: TimeInterval
        if finishedSlotIndex == 1 {
            startOffset = mediaAlignedStartOffset ?? loopStartOffset() + startTrim
        } else {
            startOffset = mediaAlignedStartOffset
                ?? recordingStartOffset()
                ?? 0
        }
        slots[slotPosition].url = outputFileURL
        slots[slotPosition].createdAt = Date()
        slots[slotPosition].startOffset = startOffset
        slots[slotPosition].videoZoom = currentVideoZoom
        slots[slotPosition].duration = max(0.25, duration)
        slots[slotPosition].state = .recorded
        slots[slotPosition].isPlaying = true
        slots[slotPosition].isStopping = false
        slots[slotPosition].stoppingStartedAt = nil
        slots[slotPosition].isMuted = false
        if let phase = audioLoopEngine.phase(slot: finishedSlotIndex) {
            loopPlaybackTimes[finishedSlotIndex] = phase * slots[slotPosition].duration
        }
        selectedSlotIndex = nil
        status = "Slot \(finishedSlotIndex) captured."
        completedAudioDurations[finishedSlotIndex] = nil
        completedVideoEndTrims[finishedSlotIndex] = nil
        completedVideoStartTrims[finishedSlotIndex] = nil
        if recordingSlotIndex == finishedSlotIndex {
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

    private func quantizedLoopDuration(_ duration: TimeInterval, slot: Int) -> TimeInterval {
        guard slot != 1,
              let masterDuration,
              duration.isFinite,
              masterDuration.isFinite,
              masterDuration > 0
        else {
            return duration
        }
        let multiple = max(1, Int((duration / masterDuration).rounded()))
        return Double(multiple) * masterDuration
    }

    private func quantizedMetronomeDuration(_ duration: TimeInterval, bpm: Double) -> TimeInterval {
        guard duration.isFinite, duration > 0, bpm.isFinite, bpm > 0 else { return duration }
        let beat = 60.0 / bpm
        let beats = max(1, Int((duration / beat).rounded()))
        return Double(beats) * beat
    }

    private func targetMetronomeStopDuration(_ duration: TimeInterval, bpm: Double) -> TimeInterval? {
        guard duration.isFinite, duration > 0, bpm.isFinite, bpm > 0 else { return nil }
        let beat = 60.0 / bpm
        let beats = max(1, Int((duration / beat).rounded()))
        return Double(beats) * beat
    }

    private func metronomeStartTrimSeconds(thresholdDate: Date?) -> TimeInterval {
        guard let thresholdDate,
              let metronomeGridBPM,
              let metronomeGridStartDate,
              metronomeGridBPM.isFinite,
              metronomeGridBPM > 0
        else { return 0 }

        let audioStartDate = thresholdDate.addingTimeInterval(-thresholdLeadMilliseconds / 1000)
        let beat = 60.0 / metronomeGridBPM
        let thresholdElapsed = thresholdDate.timeIntervalSince(metronomeGridStartDate)
        let nearestBeatIndex = max(0, Int((thresholdElapsed / beat).rounded()))
        let beatDate = metronomeGridStartDate.addingTimeInterval(Double(nearestBeatIndex) * beat)
        let trim = beatDate.timeIntervalSince(audioStartDate)
        guard trim.isFinite, trim > 0, trim <= thresholdLeadMilliseconds / 1000 + beat * 0.5 else { return 0 }
        return trim
    }

    private func detectedMediaAudioStartOffset(for url: URL) async -> TimeInterval? {
        let asset = AVURLAsset(url: url)
        do {
            guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
                return nil
            }
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(
                track: audioTrack,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVLinearPCMIsFloatKey: true,
                    AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsNonInterleaved: false
                ]
            )
            guard reader.canAdd(output) else { return nil }
            reader.add(output)
            guard reader.startReading() else { return nil }

            let thresholdValue = Float(threshold)
            while let sampleBuffer = output.copyNextSampleBuffer() {
                guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
                      let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
                else { continue }
                let asbd = streamDescription.pointee
                let channels = max(1, Int(asbd.mChannelsPerFrame))
                let sampleRate = asbd.mSampleRate > 0 ? asbd.mSampleRate : 48_000
                let presentationTime = sampleBuffer.presentationTimeStamp.seconds
                var blockBuffer: CMBlockBuffer?
                var audioBufferList = AudioBufferList()
                let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                    sampleBuffer,
                    bufferListSizeNeededOut: nil,
                    bufferListOut: &audioBufferList,
                    bufferListSize: MemoryLayout<AudioBufferList>.size,
                    blockBufferAllocator: kCFAllocatorDefault,
                    blockBufferMemoryAllocator: kCFAllocatorDefault,
                    flags: 0,
                    blockBufferOut: &blockBuffer
                )
                guard status == noErr,
                      let data = audioBufferList.mBuffers.mData?.assumingMemoryBound(to: Float.self)
                else { continue }

                let floatCount = Int(audioBufferList.mBuffers.mDataByteSize) / MemoryLayout<Float>.size
                let frameCount = floatCount / channels
                for frame in 0..<frameCount {
                    var peak: Float = 0
                    for channel in 0..<channels {
                        peak = max(peak, abs(data[frame * channels + channel]))
                    }
                    if peak >= thresholdValue {
                        let detected = presentationTime + Double(frame) / sampleRate - thresholdLeadMilliseconds / 1000
                        return max(0, detected - 0.035)
                    }
                }
            }
        } catch {
            return nil
        }
        return nil
    }

    private func videoStartOffset(assetDuration: TimeInterval?, loopDuration: TimeInterval, endTrim: TimeInterval) -> TimeInterval? {
        guard let assetDuration, assetDuration.isFinite, assetDuration > 0, loopDuration.isFinite, loopDuration > 0 else {
            return nil
        }
        let videoEnd = max(0, assetDuration - max(0, endTrim))
        return max(0, videoEnd - loopDuration)
    }

    private func recordingStartOffset() -> TimeInterval? {
        guard let captureStartDate, let pendingStartDate, pendingStartDate >= captureStartDate else {
            return nil
        }
        let offset = pendingStartDate.timeIntervalSince(captureStartDate)
        return offset.isFinite ? max(0, offset) : nil
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
            let now = Date()
            if now.timeIntervalSince(lastMeterPublishDateForCapture) >= 0.12 {
                lastMeterPublishDateForCapture = now
                Task { @MainActor in
                    let nextLevel = inputLevel * 0.82
                    if abs(nextLevel - inputLevel) >= 0.008 {
                        inputLevel = nextLevel
                    }
                }
            }
            return
        }

        let pts = sampleBuffer.presentationTimeStamp
        performanceAudioHandler?(capturedInput.buffer, capturedInput.sampleRate, pts)

        let detectedChannels = max(2, capturedInput.channelCount)
        if detectedChannels != detectedAudioInputChannelCountForCapture {
            detectedAudioInputChannelCountForCapture = detectedChannels
            Task { @MainActor in
                detectedAudioInputChannelCount = detectedChannels
                if selectedAudioChannelPairStart >= detectedAudioInputChannelCount {
                    selectAudioChannelPair(start: 0)
                }
            }
        }

        let analysis = audioLoopEngine.processInput(
            samples: capturedInput.buffer,
            inputSampleRate: capturedInput.sampleRate,
            threshold: Float(thresholdForCapture),
            preBufferMilliseconds: thresholdLeadMillisecondsForCapture
        )

        let now = Date()
        let crossedThreshold: Bool
        if case .thresholdCrossed = analysis.event {
            crossedThreshold = true
        } else {
            crossedThreshold = false
        }
        let shouldPublishMeter = crossedThreshold ||
            analysis.peak >= thresholdForCapture * 0.35 ||
            now.timeIntervalSince(lastMeterPublishDateForCapture) >= 1.0 / 20.0
        if shouldPublishMeter {
            lastMeterPublishDateForCapture = now
            Task { @MainActor in
                updateInputMeter(rms: analysis.rms, peak: analysis.peak, presentationTime: pts)
                if crossedThreshold {
                    markThresholdCrossed(presentationTime: pts)
                }
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
                    channelCount: channelCount,
                    sampleRate: asbd.mSampleRate
                )
            }

            return CapturedStereoInput(
                buffer: stereoInterleavedPair(samples: channelSamples[0], channels: channels, channelPairStart: channelPairStart),
                channelCount: channelCount,
                sampleRate: asbd.mSampleRate
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
