import AVFoundation
import Foundation

private final class MetronomeRenderState {
    var bpm: Double = 120
    var isMuted = false
    var sampleRate: Double = 48_000
    var samplePosition: Int64 = 0

    func render(frameCount: Int, audioBufferList: UnsafeMutablePointer<AudioBufferList>) {
        let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
        for buffer in abl {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            data.initialize(repeating: 0, count: frameCount)
        }
        guard !isMuted else {
            samplePosition += Int64(frameCount)
            return
        }

        let beatSamples = max(1, Int(sampleRate * 60 / max(20, bpm)))
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

@MainActor
final class MetronomeController: ObservableObject {
    @Published var bpm: Double = 120
    @Published private(set) var isPlaying = false
    @Published var isMuted = false

    private let engine = AVAudioEngine()
    private let renderState = MetronomeRenderState()
    private var sourceNode: AVAudioSourceNode?

    init() {
        configureEngine()
    }

    func togglePlay() {
        isPlaying ? stop() : play()
    }

    func play() {
        renderState.bpm = max(20, min(300, bpm))
        renderState.isMuted = isMuted
        renderState.samplePosition = 0
        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                isPlaying = false
                return
            }
        }
        isPlaying = true
    }

    func stop() {
        engine.pause()
        isPlaying = false
    }

    func toggleMute() {
        isMuted.toggle()
        renderState.isMuted = isMuted
    }

    func applyTempo() {
        renderState.bpm = max(20, min(300, bpm))
    }

    private func configureEngine() {
        let hardwareFormat = engine.outputNode.outputFormat(forBus: 0)
        renderState.sampleRate = hardwareFormat.sampleRate > 0 ? hardwareFormat.sampleRate : 48_000
        let format = AVAudioFormat(standardFormatWithSampleRate: renderState.sampleRate, channels: 2) ?? hardwareFormat
        let renderState = renderState
        let node = AVAudioSourceNode { _, _, frameCount, audioBufferList -> OSStatus in
            renderState.render(frameCount: Int(frameCount), audioBufferList: audioBufferList)
            return noErr
        }
        sourceNode = node
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
    }
}
