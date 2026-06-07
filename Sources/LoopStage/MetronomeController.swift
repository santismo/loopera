import AVFoundation
import Foundation

@MainActor
final class MetronomeController: ObservableObject {
    @Published var bpm: Double = 120
    @Published private(set) var isPlaying = false
    @Published var isMuted = false

    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private nonisolated(unsafe) var renderBPM: Double = 120
    private nonisolated(unsafe) var renderMuted = false
    private nonisolated(unsafe) var sampleRate: Double = 48_000
    private nonisolated(unsafe) var samplePosition: Int64 = 0

    init() {
        configureEngine()
    }

    func togglePlay() {
        isPlaying ? stop() : play()
    }

    func play() {
        renderBPM = max(20, min(300, bpm))
        renderMuted = isMuted
        samplePosition = 0
        if !engine.isRunning {
            try? engine.start()
        }
        isPlaying = true
    }

    func stop() {
        engine.pause()
        isPlaying = false
    }

    func toggleMute() {
        isMuted.toggle()
        renderMuted = isMuted
    }

    func applyTempo() {
        renderBPM = max(20, min(300, bpm))
    }

    private func configureEngine() {
        let hardwareFormat = engine.outputNode.outputFormat(forBus: 0)
        sampleRate = hardwareFormat.sampleRate > 0 ? hardwareFormat.sampleRate : 48_000
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) ?? hardwareFormat
        let node = AVAudioSourceNode { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            self?.render(frameCount: Int(frameCount), audioBufferList: audioBufferList)
            return noErr
        }
        sourceNode = node
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
    }

    private nonisolated func render(frameCount: Int, audioBufferList: UnsafeMutablePointer<AudioBufferList>) {
        let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
        for buffer in abl {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            data.initialize(repeating: 0, count: frameCount)
        }
        guard !renderMuted else {
            samplePosition += Int64(frameCount)
            return
        }

        let beatSamples = max(1, Int(sampleRate * 60 / max(20, renderBPM)))
        let clickSamples = max(1, Int(sampleRate * 0.025))
        for frame in 0..<frameCount {
            let beatPosition = Int((samplePosition + Int64(frame)) % Int64(beatSamples))
            guard beatPosition < clickSamples else { continue }
            let envelope = Float(1 - Double(beatPosition) / Double(clickSamples))
            let sample = sin(Float(beatPosition) * 0.38) * 0.45 * envelope
            for buffer in abl {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                data[frame] += sample
            }
        }
        samplePosition += Int64(frameCount)
    }
}
