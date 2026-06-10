import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

final class AudioLoopEngine: @unchecked Sendable {
    enum Event {
        case none
        case thresholdCrossed
    }

    enum RecordingPlaybackStart {
        case stopped
        case restart(offsetSeconds: TimeInterval)
        case syncedToMaster
    }

    struct InputAnalysis {
        var rms: Double
        var peak: Double
        var event: Event
    }

    struct InputBuffer {
        var left: [Float]
        var right: [Float]

        var count: Int {
            min(left.count, right.count)
        }

        var isEmpty: Bool {
            count == 0
        }
    }

    struct WaveformSnapshot {
        var slot: Int
        var samples: [Float]
        var isRecording: Bool
    }

    private struct Loop {
        var left: [Float] = []
        var right: [Float] = []
        var playPosition = 0
        var hasWrapped = false
        var isPlaying = true
        var isMuted = false
        var stopFadeRemaining = 0
        var stopFadeTotal = 0
    }

    private let lock = NSLock()
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var sampleRate: Double = 48_000
    private var loops: [Int: Loop] = [:]
    private var preBufferLeft: [Float] = Array(repeating: 0, count: 48_000)
    private var preBufferRight: [Float] = Array(repeating: 0, count: 48_000)
    private var preWrite = 0
    private var preFill = 0
    private var listeningSlot: Int?
    private var recordingSlot: Int?
    private var recordBufferLeft: [Float] = []
    private var recordBufferRight: [Float] = []
    private var recordedWaveforms: [Int: [Float]] = [:]
    private var recordingWaveform: [Float] = []
    private var waveformAccumulatorPeak: Float = 0
    private var waveformAccumulatorCount = 0
    private var requestedStop = false
    var performanceOutputHandler: ((InputBuffer, Double, CMTime) -> Void)?
    private var renderSamplePosition: Int64 = 0
    private var crossfadeMilliseconds: Double = 45
    private var fadeOutMilliseconds: Double = 180
    private var fadeMode: LoopFadeMode = .toLoopEnd
    private var masterVolume: Float = 1
    private var selectedOutputDeviceUID: String?

    init() {
        configureEngine()
    }

    func start() {
        applySelectedOutputDevice()
        if !engine.isRunning {
            try? engine.start()
        }
    }

    func stop() {
        lock.lock()
        loops.removeAll()
        recordedWaveforms.removeAll()
        listeningSlot = nil
        recordingSlot = nil
        recordBufferLeft.removeAll(keepingCapacity: true)
        recordBufferRight.removeAll(keepingCapacity: true)
        resetRecordingWaveformLocked()
        performanceOutputHandler = nil
        lock.unlock()
        engine.stop()
    }

    func apply(profile: OffsetProfile) {
        lock.lock()
        crossfadeMilliseconds = max(0, profile.crossfadeMilliseconds)
        fadeOutMilliseconds = max(1, profile.loopFadeOutMilliseconds)
        fadeMode = profile.loopFadeMode
        lock.unlock()
    }

    func setMasterVolume(_ volume: Double) {
        lock.lock()
        masterVolume = Float(max(0, min(1.5, volume)))
        lock.unlock()
    }

    @discardableResult
    func setOutputDevice(uniqueID: String?) -> Bool {
        lock.lock()
        let isCapturingLoop = listeningSlot != nil || recordingSlot != nil
        lock.unlock()
        guard !isCapturingLoop else {
            return true
        }

        if selectedOutputDeviceUID == uniqueID {
            return true
        }
        selectedOutputDeviceUID = uniqueID
        let wasRunning = engine.isRunning
        if wasRunning {
            engine.pause()
        }
        let didApply = applySelectedOutputDevice()
        if wasRunning {
            try? engine.start()
        }
        return didApply
    }

    func armThreshold(slot: Int, preBufferMilliseconds: Double) {
        lock.lock()
        listeningSlot = slot
        recordingSlot = nil
        requestedStop = false
        recordBufferLeft.removeAll(keepingCapacity: true)
        recordBufferRight.removeAll(keepingCapacity: true)
        resetRecordingWaveformLocked()
        ensurePreBuffer(milliseconds: max(1, preBufferMilliseconds))
        lock.unlock()
    }

    func beginRecording(slot: Int, usePreBuffer: Bool) {
        lock.lock()
        beginRecordingLocked(slot: slot, preRollSamples: usePreBuffer ? nil : 0)
        lock.unlock()
    }

    func beginRecording(slot: Int, preRollSeconds: TimeInterval) {
        lock.lock()
        let samples = max(0, Int(sampleRate * preRollSeconds))
        beginRecordingLocked(slot: slot, preRollSamples: samples)
        lock.unlock()
    }

    func beginRecordingSyncedToMaster(slot: Int) {
        lock.lock()
        let preRollSamples: Int
        if let master = loops[1] {
            let masterLength = min(master.left.count, master.right.count)
            preRollSamples = masterLength > 0 ? master.playPosition % masterLength : 0
        } else {
            preRollSamples = 0
        }
        beginRecordingLocked(slot: slot, preRollSamples: preRollSamples)
        lock.unlock()
    }

    func finishRecording(
        slot: Int,
        trimStartSeconds: TimeInterval = 0,
        trimEndSeconds: TimeInterval = 0,
        targetDurationSeconds: TimeInterval? = nil,
        playbackStart: RecordingPlaybackStart = .stopped
    ) -> TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        let startSamples = max(0, Int(sampleRate * trimStartSeconds))
        let trimSamples = max(0, Int(sampleRate * trimEndSeconds))
        let availableCount = min(recordBufferLeft.count, recordBufferRight.count)
        let trimmedAvailableCount = max(0, availableCount - startSamples - trimSamples)
        var count = trimmedAvailableCount
        var targetCount = targetDurationSeconds
            .flatMap { $0.isFinite && $0 > 0 ? max(1, Int(($0 * sampleRate).rounded())) : nil }
        if slot != 1,
           targetCount == nil,
           let master = loops[1] {
            let masterLength = min(master.left.count, master.right.count)
            if masterLength > 0 {
                let multiple = max(1, Int((Double(count) / Double(masterLength)).rounded()))
                targetCount = multiple * masterLength
            }
        }
        if let targetCount {
            count = min(trimmedAvailableCount, targetCount)
        }
        guard recordingSlot == slot, count > Int(sampleRate * 0.08) else {
            recordingSlot = nil
            listeningSlot = nil
            recordBufferLeft.removeAll(keepingCapacity: true)
            recordBufferRight.removeAll(keepingCapacity: true)
            resetRecordingWaveformLocked()
            return nil
        }

        let end = min(availableCount, startSamples + count)
        let canMoveWholeRecording = startSamples == 0 &&
            end == availableCount &&
            count == availableCount &&
            targetCount == nil &&
            recordBufferLeft.count == recordBufferRight.count
        var left: [Float]
        var right: [Float]
        if canMoveWholeRecording {
            // Free-mode master stop must hand the captured buffers to playback immediately.
            // Avoiding Array(slice) here prevents a short audio gap on the spacebar release.
            left = recordBufferLeft
            right = recordBufferRight
            recordBufferLeft = []
            recordBufferRight = []
        } else {
            left = Array(recordBufferLeft[startSamples..<end])
            right = Array(recordBufferRight[startSamples..<end])
        }
        if let targetCount, targetCount > count {
            // Slave loops are defined by the master sample grid. If the UI timer asks to
            // close at a master boundary but the render thread is a few buffers short,
            // pad to the exact target instead of creating a drifting shorter loop.
            padLoopBuffers(left: &left, right: &right, targetCount: targetCount)
            count = targetCount
        }
        var loop = Loop(
            left: left,
            right: right,
            playPosition: 0,
            hasWrapped: false,
            isPlaying: false,
            isMuted: false
        )
        applyPlaybackStartLocked(&loop, mode: playbackStart)
        loops[slot] = loop
        let duration = Double(count) / sampleRate
        recordingSlot = nil
        listeningSlot = nil
        requestedStop = false
        recordBufferLeft.removeAll(keepingCapacity: true)
        recordBufferRight.removeAll(keepingCapacity: true)
        resetRecordingWaveformLocked()
        return duration
    }

    func refreshRecordedWaveform(slot: Int) {
        lock.lock()
        guard let loop = loops[slot] else {
            recordedWaveforms.removeValue(forKey: slot)
            lock.unlock()
            return
        }
        let left = loop.left
        let right = loop.right
        lock.unlock()

        let waveform = Self.makeWaveform(left: left, right: right, targetBins: 360)
        lock.lock()
        if loops[slot] != nil {
            recordedWaveforms[slot] = waveform
        }
        lock.unlock()
    }

    func waveformSnapshots(maxBins: Int = 360) -> [WaveformSnapshot] {
        lock.lock()
        let recorded = recordedWaveforms
        let activeRecordingSlot = recordingSlot
        let activeRecordingWaveform = recordingWaveform
        lock.unlock()

        var snapshots = recorded.map { slot, samples in
            WaveformSnapshot(
                slot: slot,
                samples: Self.resampledWaveform(samples, targetBins: maxBins),
                isRecording: false
            )
        }
        if let activeRecordingSlot, !activeRecordingWaveform.isEmpty {
            snapshots.append(WaveformSnapshot(
                slot: activeRecordingSlot,
                samples: Self.resampledWaveform(activeRecordingWaveform, targetBins: maxBins),
                isRecording: true
            ))
        }
        return snapshots.sorted { $0.slot < $1.slot }
    }

    func currentRecordingDuration(slot: Int) -> TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        guard recordingSlot == slot else { return nil }
        let count = min(recordBufferLeft.count, recordBufferRight.count)
        guard count > 0 else { return 0 }
        return Double(count) / sampleRate
    }

    func masterBoundaryOffsetSeconds() -> TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        guard let master = loops[1] else { return nil }
        let masterLength = min(master.left.count, master.right.count)
        guard masterLength > 0 else { return nil }
        return Double(master.playPosition % masterLength) / sampleRate
    }

    func clear(slot: Int) {
        lock.lock()
        loops.removeValue(forKey: slot)
        recordedWaveforms.removeValue(forKey: slot)
        if recordingSlot == slot { recordingSlot = nil }
        if listeningSlot == slot { listeningSlot = nil }
        lock.unlock()
    }

    func clearAll() {
        lock.lock()
        loops.removeAll()
        recordedWaveforms.removeAll()
        listeningSlot = nil
        recordingSlot = nil
        recordBufferLeft.removeAll(keepingCapacity: true)
        recordBufferRight.removeAll(keepingCapacity: true)
        resetRecordingWaveformLocked()
        lock.unlock()
    }

    func setPlaying(slot: Int, isPlaying: Bool) {
        lock.lock()
        if var loop = loops[slot] {
            if isPlaying {
                if !loop.isPlaying {
                    loop.playPosition = 0
                    loop.hasWrapped = false
                }
                loop.isPlaying = true
                loop.stopFadeRemaining = 0
                loop.stopFadeTotal = 0
            } else if loop.isPlaying {
                let length = min(loop.left.count, loop.right.count)
                let remaining: Int
                switch fadeMode {
                case .fast:
                    remaining = Int(sampleRate * 0.08)
                case .slow:
                    remaining = Int(sampleRate * fadeOutMilliseconds / 1000)
                case .toLoopEnd:
                    remaining = length > 0 ? length - (loop.playPosition % length) : 0
                }
                let fade = max(1, remaining)
                loop.stopFadeRemaining = fade
                loop.stopFadeTotal = fade
            }
            loops[slot] = loop
        }
        lock.unlock()
    }

    func setMuted(slot: Int, isMuted: Bool) {
        lock.lock()
        loops[slot]?.isMuted = isMuted
        lock.unlock()
    }

    func phase(slot: Int) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        guard let loop = loops[slot], !loop.left.isEmpty else { return nil }
        return Double(loop.playPosition) / Double(loop.left.count)
    }

    func restart(slot: Int) {
        lock.lock()
        loops[slot]?.playPosition = 0
        loops[slot]?.hasWrapped = false
        loops[slot]?.isPlaying = true
        lock.unlock()
    }

    func restart(slot: Int, offsetSeconds: TimeInterval) {
        lock.lock()
        if var loop = loops[slot] {
            let length = min(loop.left.count, loop.right.count)
            if length > 0 {
                let offsetSamples = max(0, Int(sampleRate * offsetSeconds)) % length
                loop.playPosition = offsetSamples
                loop.hasWrapped = offsetSamples > 0
                loop.isPlaying = true
                loops[slot] = loop
            }
        }
        lock.unlock()
    }

    func restartSyncedToMaster(slot: Int) {
        lock.lock()
        if var loop = loops[slot],
           let master = loops[1] {
            let length = min(loop.left.count, loop.right.count)
            let masterLength = min(master.left.count, master.right.count)
            if length > 0, masterLength > 0 {
                loop.playPosition = master.playPosition % length
                loop.hasWrapped = loop.playPosition > 0
                loop.isPlaying = true
                loops[slot] = loop
            }
        }
        lock.unlock()
    }

    func processInput(
        samples: InputBuffer,
        inputSampleRate: Double?,
        threshold: Float,
        preBufferMilliseconds: Double
    ) -> InputAnalysis {
        let samples = resampledInputIfNeeded(samples, inputSampleRate: inputSampleRate)
        guard !samples.isEmpty else {
            return InputAnalysis(rms: 0, peak: 0, event: .none)
        }

        lock.lock()
        ensurePreBuffer(milliseconds: max(1, preBufferMilliseconds))

        var peak: Float = 0
        var sum: Double = 0
        let count = samples.count
        for index in 0..<count {
            let left = clamp(samples.left[index])
            let right = clamp(samples.right[index])
            let leftMagnitude = abs(left)
            let rightMagnitude = abs(right)
            peak = max(peak, leftMagnitude, rightMagnitude)
            sum += Double(leftMagnitude * leftMagnitude + rightMagnitude * rightMagnitude)
            preBufferLeft[preWrite] = left
            preBufferRight[preWrite] = right
            preWrite = (preWrite + 1) % preBufferLeft.count
            preFill = min(preFill + 1, preBufferLeft.count)
        }

        var event: Event = .none
        let wasRecording = recordingSlot != nil
        if let slot = listeningSlot, recordingSlot == nil, peak >= threshold {
            beginRecordingLocked(slot: slot, preRollSamples: nil)
            event = .thresholdCrossed
        }

        if wasRecording {
            for index in 0..<count {
                let left = clamp(samples.left[index])
                let right = clamp(samples.right[index])
                recordBufferLeft.append(left)
                recordBufferRight.append(right)
                appendRecordingWaveformLocked(left: left, right: right)
            }
        }

        lock.unlock()
        return InputAnalysis(
            rms: sqrt(sum / Double(count * 2)),
            peak: Double(peak),
            event: event
        )
    }

    private func configureEngine() {
        let hardwareFormat = engine.outputNode.outputFormat(forBus: 0)
        sampleRate = hardwareFormat.sampleRate > 0 ? hardwareFormat.sampleRate : 48_000
        ensurePreBuffer(milliseconds: 2_000)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) ?? hardwareFormat

        let node = AVAudioSourceNode { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            self?.render(frameCount: Int(frameCount), audioBufferList: audioBufferList)
            return noErr
        }
        sourceNode = node
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
    }

    @discardableResult
    private func applySelectedOutputDevice() -> Bool {
        guard let audioUnit = engine.outputNode.audioUnit else { return false }
        let deviceID: AudioDeviceID
        if let selectedOutputDeviceUID {
            guard let selectedDeviceID = Self.audioDeviceID(forUID: selectedOutputDeviceUID) else {
                return false
            }
            deviceID = selectedDeviceID
        } else {
            guard let defaultDeviceID = Self.defaultOutputDeviceID() else {
                return false
            }
            deviceID = defaultDeviceID
        }

        var mutableDeviceID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        return status == noErr
    }

    private static func defaultOutputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID()
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceID
        ) == noErr else {
            return nil
        }
        return deviceID
    }

    private static func audioDeviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        ) == noErr else {
            return nil
        }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = Array(repeating: AudioDeviceID(), count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceIDs
        ) == noErr else {
            return nil
        }

        return deviceIDs.first { deviceID in
            stringProperty(kAudioDevicePropertyDeviceUID, deviceID: deviceID) == uid
        }
    }

    private static func stringProperty(_ selector: AudioObjectPropertySelector, deviceID: AudioDeviceID) -> String? {
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

    private func render(frameCount: Int, audioBufferList: UnsafeMutablePointer<AudioBufferList>) {
        let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
        for buffer in abl {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            data.initialize(repeating: 0, count: frameCount)
        }

        let outputGain: Float
        lock.lock()
        for slotIndex in loops.keys.sorted() {
            guard var loop = loops[slotIndex], loop.isPlaying, !loop.left.isEmpty else { continue }
            let length = min(loop.left.count, loop.right.count)
            guard length > 0 else { continue }
            for frame in 0..<frameCount {
                let left = sample(from: loop.left, position: loop.playPosition, hasWrapped: loop.hasWrapped)
                let right = sample(from: loop.right, position: loop.playPosition, hasWrapped: loop.hasWrapped)
                let gain: Float
                if loop.stopFadeRemaining > 0, loop.stopFadeTotal > 0 {
                    gain = Float(loop.stopFadeRemaining) / Float(loop.stopFadeTotal)
                    loop.stopFadeRemaining -= 1
                } else {
                    gain = 1
                }
                if !loop.isMuted {
                    for (bufferIndex, buffer) in abl.enumerated() {
                        guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                        if abl.count == 1 {
                            data[frame] += (left + right) * 0.5 * gain
                        } else {
                            data[frame] += (bufferIndex == 0 ? left : right) * gain
                        }
                    }
                }
                loop.playPosition = (loop.playPosition + 1) % length
                if loop.playPosition == 0 {
                    loop.hasWrapped = true
                }
                if loop.stopFadeTotal > 0, loop.playPosition == 0 {
                    loop.playPosition = 0
                    loop.hasWrapped = false
                    loop.isPlaying = false
                    loop.stopFadeRemaining = 0
                    loop.stopFadeTotal = 0
                    break
                }
            }
            loops[slotIndex] = loop
        }
        outputGain = masterVolume
        lock.unlock()

        for buffer in abl {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            for frame in 0..<frameCount {
                data[frame] = max(-0.98, min(0.98, data[frame] * outputGain))
            }
        }

        if let performanceOutputHandler {
            var left = [Float](repeating: 0, count: frameCount)
            var right = [Float](repeating: 0, count: frameCount)
            if abl.count == 1,
               let data = abl[0].mData?.assumingMemoryBound(to: Float.self) {
                for frame in 0..<frameCount {
                    left[frame] = data[frame]
                    right[frame] = data[frame]
                }
            } else if abl.count > 1,
                      let leftData = abl[0].mData?.assumingMemoryBound(to: Float.self),
                      let rightData = abl[1].mData?.assumingMemoryBound(to: Float.self) {
                for frame in 0..<frameCount {
                    left[frame] = leftData[frame]
                    right[frame] = rightData[frame]
                }
            }

            let outputPTS = CMTime(value: renderSamplePosition, timescale: CMTimeScale(sampleRate.rounded()))
            performanceOutputHandler(InputBuffer(left: left, right: right), sampleRate, outputPTS)
        }
        renderSamplePosition += Int64(frameCount)
    }

    private func beginRecordingLocked(slot: Int, preRollSamples: Int?) {
        listeningSlot = nil
        recordingSlot = slot
        requestedStop = false
        recordBufferLeft.removeAll(keepingCapacity: true)
        recordBufferRight.removeAll(keepingCapacity: true)
        resetRecordingWaveformLocked()

        if preRollSamples != 0 {
            let requested = preRollSamples ?? preBufferLeft.count
            let count = min(preFill, preBufferLeft.count, requested)
            let start = (preWrite - count + preBufferLeft.count) % preBufferLeft.count
            for index in 0..<count {
                let readIndex = (start + index) % preBufferLeft.count
                let left = preBufferLeft[readIndex]
                let right = preBufferRight[readIndex]
                recordBufferLeft.append(left)
                recordBufferRight.append(right)
                appendRecordingWaveformLocked(left: left, right: right)
            }
        }
    }

    private func appendRecordingWaveformLocked(left: Float, right: Float) {
        waveformAccumulatorPeak = max(waveformAccumulatorPeak, abs(left), abs(right))
        waveformAccumulatorCount += 1
        let binSize = max(128, Int(sampleRate / 120))
        if waveformAccumulatorCount >= binSize {
            recordingWaveform.append(min(1, waveformAccumulatorPeak))
            waveformAccumulatorPeak = 0
            waveformAccumulatorCount = 0
        }
    }

    private func resetRecordingWaveformLocked() {
        recordingWaveform.removeAll(keepingCapacity: true)
        waveformAccumulatorPeak = 0
        waveformAccumulatorCount = 0
    }

    private func padLoopBuffers(left: inout [Float], right: inout [Float], targetCount: Int) {
        guard targetCount > left.count else { return }
        let capturedCount = min(left.count, right.count)
        guard capturedCount > 0 else { return }
        left.reserveCapacity(targetCount)
        right.reserveCapacity(targetCount)
        while left.count < targetCount {
            left.append(left[capturedCount - 1])
            right.append(right[capturedCount - 1])
        }
    }

    private func applyPlaybackStartLocked(_ loop: inout Loop, mode: RecordingPlaybackStart) {
        let length = min(loop.left.count, loop.right.count)
        guard length > 0 else { return }

        switch mode {
        case .stopped:
            return
        case .restart(let offsetSeconds):
            let offsetSamples = max(0, Int(sampleRate * offsetSeconds)) % length
            loop.playPosition = offsetSamples
            loop.hasWrapped = offsetSamples > 0
            loop.isPlaying = true
        case .syncedToMaster:
            if let master = loops[1] {
                let masterLength = min(master.left.count, master.right.count)
                if masterLength > 0 {
                    loop.playPosition = master.playPosition % length
                    loop.hasWrapped = loop.playPosition > 0
                    loop.isPlaying = true
                    return
                }
            }
            loop.playPosition = 0
            loop.hasWrapped = false
            loop.isPlaying = true
        }
    }

    private func resampledInputIfNeeded(_ input: InputBuffer, inputSampleRate: Double?) -> InputBuffer {
        guard let inputSampleRate,
              inputSampleRate.isFinite,
              inputSampleRate > 0,
              sampleRate.isFinite,
              sampleRate > 0,
              abs(inputSampleRate - sampleRate) > 1,
              !input.isEmpty
        else { return input }

        let ratio = sampleRate / inputSampleRate
        let outputCount = max(1, Int((Double(input.count) * ratio).rounded()))
        return InputBuffer(
            left: resampleChannel(input.left, inputCount: input.count, outputCount: outputCount, ratio: ratio),
            right: resampleChannel(input.right, inputCount: input.count, outputCount: outputCount, ratio: ratio)
        )
    }

    private func resampleChannel(
        _ source: [Float],
        inputCount: Int,
        outputCount: Int,
        ratio: Double
    ) -> [Float] {
        guard inputCount > 1, outputCount > 0 else {
            return Array(source.prefix(max(0, min(inputCount, outputCount))))
        }

        var output = [Float](repeating: 0, count: outputCount)
        let maxIndex = inputCount - 1
        for outputIndex in 0..<outputCount {
            let sourcePosition = Double(outputIndex) / ratio
            let lower = min(maxIndex, max(0, Int(sourcePosition.rounded(.down))))
            let upper = min(maxIndex, lower + 1)
            let fraction = Float(sourcePosition - Double(lower))
            output[outputIndex] = source[lower] + (source[upper] - source[lower]) * fraction
        }
        return output
    }

    private func ensurePreBuffer(milliseconds: Double) {
        let desired = max(1, Int(sampleRate * milliseconds / 1000))
        guard desired != preBufferLeft.count else { return }
        preBufferLeft = Array(repeating: 0, count: desired)
        preBufferRight = Array(repeating: 0, count: desired)
        preWrite = 0
        preFill = 0
    }

    private func clamp(_ sample: Float) -> Float {
        max(-1, min(1, sample))
    }

    private func sample(from samples: [Float], position: Int, hasWrapped: Bool) -> Float {
        guard hasWrapped else { return samples[position] }
        let fade = crossfadeSampleCount(for: samples.count)
        guard fade > 0, position < fade else { return samples[position] }
        let tailPosition = samples.count - fade + position
        let blend = Float(position) / Float(max(1, fade - 1))
        return samples[tailPosition] * (1 - blend) + samples[position] * blend
    }

    private func crossfadeSampleCount(for sampleCount: Int) -> Int {
        guard sampleCount > 64 else { return 0 }
        return min(sampleCount / 2, max(8, Int(sampleRate * crossfadeMilliseconds / 1000)))
    }

    private static func makeWaveform(left: [Float], right: [Float], targetBins: Int) -> [Float] {
        let count = min(left.count, right.count)
        guard count > 0, targetBins > 0 else { return [] }
        let binSize = max(1, Int(ceil(Double(count) / Double(targetBins))))
        var bins: [Float] = []
        bins.reserveCapacity(min(targetBins, count))
        var index = 0
        while index < count {
            let end = min(count, index + binSize)
            var peak: Float = 0
            for sampleIndex in index..<end {
                peak = max(peak, abs(left[sampleIndex]), abs(right[sampleIndex]))
            }
            bins.append(min(1, peak))
            index = end
        }
        return bins
    }

    private static func resampledWaveform(_ samples: [Float], targetBins: Int) -> [Float] {
        guard samples.count > targetBins, targetBins > 0 else { return samples }
        let binSize = max(1, Int(ceil(Double(samples.count) / Double(targetBins))))
        var bins: [Float] = []
        bins.reserveCapacity(targetBins)
        var index = 0
        while index < samples.count {
            let end = min(samples.count, index + binSize)
            bins.append(samples[index..<end].max() ?? 0)
            index = end
        }
        return bins
    }

}
