import AppKit
import AVFoundation
import Foundation
@preconcurrency import ScreenCaptureKit

final class PerformanceRecorder: NSObject, ObservableObject, @unchecked Sendable {
    @Published private(set) var isRecording = false
    @Published private(set) var status = "Program recorder idle."
    @Published private(set) var lastRecordingURL: URL?

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var didStartSession = false
    private let sampleQueue = DispatchQueue(label: "Loopera.PerformanceRecorder.samples")

    @MainActor
    func start() {
        guard !isRecording else { return }
        status = "Preparing window recorder..."

        Task {
            do {
                try await startCapture()
                await MainActor.run {
                    isRecording = true
                    status = "Recording app window."
                }
            } catch {
                await stop()
                await MainActor.run {
                    status = "Program recording failed: \(error.localizedDescription)"
                }
            }
        }
    }

    @MainActor
    func stop() async {
        let activeStream = stream
        stream = nil
        isRecording = false
        status = "Finishing program recording..."

        do {
            try await activeStream?.stopCapture()
        } catch {
            status = "Stopped with capture warning: \(error.localizedDescription)"
        }

        await finishWriter()
    }

    private func startCapture() async throws {
        let windowMetrics = await MainActor.run { () -> (scale: CGFloat, width: CGFloat, height: CGFloat)? in
            guard let window = NSApp.windows.first(where: { $0.isVisible }) else { return nil }
            let scale = window.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
            return (scale, window.frame.width, window.frame.height)
        }

        guard let windowMetrics else {
            throw RecorderError.noWindow
        }

        let width = max(1280, Int(windowMetrics.width * windowMetrics.scale))
        let height = max(720, Int(windowMetrics.height * windowMetrics.scale))

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Loopera-Performance-\(Self.timestamp())")
            .appendingPathExtension("mov")

        try prepareWriter(outputURL: outputURL, width: width, height: height)

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let scWindow = content.windows.first(where: { candidate in
            candidate.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier
        }) else {
            throw RecorderError.noShareableWindow
        }

        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 5
        configuration.showsCursor = false
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = false

        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        try await stream.startCapture()

        self.stream = stream
        lastRecordingURL = outputURL
    }

    private func prepareWriter(outputURL: URL, width: Int, height: Int) throws {
        didStartSession = false

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
        )

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 2,
            AVSampleRateKey: 44_100,
            AVEncoderBitRateKey: 128_000
        ]
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput.expectsMediaDataInRealTime = true

        if writer.canAdd(videoInput) {
            writer.add(videoInput)
        }
        if writer.canAdd(audioInput) {
            writer.add(audioInput)
        }

        guard writer.startWriting() else {
            throw writer.error ?? RecorderError.writerStartFailed
        }

        self.writer = writer
        self.videoInput = videoInput
        self.audioInput = audioInput
        self.pixelBufferAdaptor = adaptor
    }

    private func finishWriter() async {
        let writer = writer
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        self.writer = nil
        videoInput = nil
        audioInput = nil
        pixelBufferAdaptor = nil
        didStartSession = false

        guard let writer else {
            status = "Program recorder idle."
            return
        }

        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }

        if writer.status == .completed {
            status = "Saved program recording."
        } else {
            status = "Program recording did not finish cleanly."
        }
    }

    nonisolated private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}

extension PerformanceRecorder: SCStreamOutput {
    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard sampleBuffer.isValid else { return }

        switch outputType {
        case .screen:
            appendVideo(sampleBuffer)
        case .audio:
            appendAudio(sampleBuffer)
        case .microphone:
            appendAudio(sampleBuffer)
        @unknown default:
            break
        }
    }

    private func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        guard
            let writer,
            let videoInput,
            let pixelBufferAdaptor,
            videoInput.isReadyForMoreMediaData,
            let imageBuffer = sampleBuffer.imageBuffer
        else { return }

        let presentationTime = sampleBuffer.presentationTimeStamp
        if !didStartSession {
            writer.startSession(atSourceTime: presentationTime)
            didStartSession = true
        }

        pixelBufferAdaptor.append(imageBuffer, withPresentationTime: presentationTime)
    }

    private func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        guard didStartSession, let audioInput, audioInput.isReadyForMoreMediaData else { return }
        audioInput.append(sampleBuffer)
    }
}

private enum RecorderError: LocalizedError {
    case noWindow
    case noShareableWindow
    case writerStartFailed

    var errorDescription: String? {
        switch self {
        case .noWindow:
            return "No visible Loopera window was found."
        case .noShareableWindow:
            return "Loopera could not find its own window in ScreenCaptureKit."
        case .writerStartFailed:
            return "The movie writer could not start."
        }
    }
}
