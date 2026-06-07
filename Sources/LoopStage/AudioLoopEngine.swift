import AVFoundation
import Foundation

final class AudioLoopEngine {
    enum Event {
        case none
        case thresholdCrossed
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

    private struct Loop {
        var left: [Float] = []
        var right: [Float] = []
        var playPosition = 0
        var hasWrapped = false
        var isPlaying = true
        var isMuted = false
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
    private var requestedStop = false
    var performanceOutputHandler: ((InputBuffer, Double, CMTime) -> Void)?
    private var renderSamplePosition: Int64 = 0

    init() {
        configureEngine()
    }

    func start() {
        if !engine.isRunning {
            try? engine.start()
        }
    }

    func armThreshold(slot: Int, preBufferMilliseconds: Double) {
        lock.lock()
        listeningSlot = slot
        recordingSlot = nil
        requestedStop = false
        recordBufferLeft.removeAll(keepingCapacity: true)
        recordBufferRight.removeAll(keepingCapacity: true)
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

    func finishRecording(slot: Int, trimEndSeconds: TimeInterval = 0) -> TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        let trimSamples = max(0, Int(sampleRate * trimEndSeconds))
        let count = max(0, min(recordBufferLeft.count, recordBufferRight.count) - trimSamples)
        guard recordingSlot == slot, count > Int(sampleRate * 0.08) else {
            recordingSlot = nil
            listeningSlot = nil
            recordBufferLeft.removeAll(keepingCapacity: true)
            recordBufferRight.removeAll(keepingCapacity: true)
            return nil
        }

        let left = Array(recordBufferLeft.prefix(count))
        let right = Array(recordBufferRight.prefix(count))
        loops[slot] = Loop(
            left: left,
            right: right,
            playPosition: 0,
            hasWrapped: false,
            isPlaying: false,
            isMuted: false
        )
        let duration = Double(count) / sampleRate
        recordingSlot = nil
        listeningSlot = nil
        requestedStop = false
        recordBufferLeft.removeAll(keepingCapacity: true)
        recordBufferRight.removeAll(keepingCapacity: true)
        return duration
    }

    func clear(slot: Int) {
        lock.lock()
        loops.removeValue(forKey: slot)
        if recordingSlot == slot { recordingSlot = nil }
        if listeningSlot == slot { listeningSlot = nil }
        lock.unlock()
    }

    func clearAll() {
        lock.lock()
        loops.removeAll()
        listeningSlot = nil
        recordingSlot = nil
        recordBufferLeft.removeAll(keepingCapacity: true)
        recordBufferRight.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    func setPlaying(slot: Int, isPlaying: Bool) {
        lock.lock()
        loops[slot]?.isPlaying = isPlaying
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

    func processInput(samples: InputBuffer, threshold: Float, preBufferMilliseconds: Double) -> InputAnalysis {
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
                recordBufferLeft.append(clamp(samples.left[index]))
                recordBufferRight.append(clamp(samples.right[index]))
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

    private func render(frameCount: Int, audioBufferList: UnsafeMutablePointer<AudioBufferList>) {
        let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
        for buffer in abl {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            data.initialize(repeating: 0, count: frameCount)
        }

        lock.lock()
        for slotIndex in loops.keys.sorted() {
            guard var loop = loops[slotIndex], loop.isPlaying, !loop.isMuted, !loop.left.isEmpty else { continue }
            let length = min(loop.left.count, loop.right.count)
            guard length > 0 else { continue }
            for frame in 0..<frameCount {
                let left = sample(from: loop.left, position: loop.playPosition, hasWrapped: loop.hasWrapped)
                let right = sample(from: loop.right, position: loop.playPosition, hasWrapped: loop.hasWrapped)
                for (bufferIndex, buffer) in abl.enumerated() {
                    guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                    if abl.count == 1 {
                        data[frame] += (left + right) * 0.5
                    } else {
                        data[frame] += bufferIndex == 0 ? left : right
                    }
                }
                loop.playPosition = (loop.playPosition + 1) % length
                if loop.playPosition == 0 {
                    loop.hasWrapped = true
                }
            }
            loops[slotIndex] = loop
        }
        lock.unlock()

        for buffer in abl {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            for frame in 0..<frameCount {
                data[frame] = max(-0.98, min(0.98, data[frame]))
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

        if preRollSamples != 0 {
            let requested = preRollSamples ?? preBufferLeft.count
            let count = min(preFill, preBufferLeft.count, requested)
            let start = (preWrite - count + preBufferLeft.count) % preBufferLeft.count
            for index in 0..<count {
                let readIndex = (start + index) % preBufferLeft.count
                recordBufferLeft.append(preBufferLeft[readIndex])
                recordBufferRight.append(preBufferRight[readIndex])
            }
        }
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
        return min(sampleCount / 2, max(8, Int(sampleRate * 0.02)))
    }

}
