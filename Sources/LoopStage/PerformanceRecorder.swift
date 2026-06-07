import AppKit
@preconcurrency import AVFoundation
import Foundation
@preconcurrency import ScreenCaptureKit

final class PerformanceRecorder: NSObject, ObservableObject, @unchecked Sendable {
    @Published private(set) var isRecording = false
    @Published private(set) var status = "Program recorder idle."
    @Published private(set) var lastRecordingURL: URL?

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var appAudioInput: AVAssetWriterInput?
    private var microphoneInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var didStartSession = false
    private var isFinishing = false
    private let sampleQueue = DispatchQueue(label: "Loopera.PerformanceRecorder.samples")

    @MainActor
    func start(microphoneDeviceID: String?) {
        guard !isRecording else { return }
        status = "Preparing window recorder..."

        Task {
            do {
                try await startCaptureWithFallbacks(microphoneDeviceID: microphoneDeviceID)
                await MainActor.run {
                    isRecording = true
                    status = "Recording performance."
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

    private func startCaptureWithFallbacks(microphoneDeviceID: String?) async throws {
        var errors: [String] = []
        let attempts: [(deviceID: String?, captureMicrophone: Bool)] = [
            (microphoneDeviceID, microphoneDeviceID != nil),
            (nil, true),
            (nil, false)
        ]

        for attempt in attempts {
            do {
                try await startCapture(microphoneDeviceID: attempt.deviceID, captureMicrophone: attempt.captureMicrophone)
                return
            } catch {
                errors.append(error.localizedDescription)
                cleanupWriter()
            }
        }

        throw RecorderError.captureStartFailed(errors.joined(separator: " / "))
    }

    private func startCapture(microphoneDeviceID: String?, captureMicrophone: Bool) async throws {
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

        let outputURL = Self.recordingsDirectory
            .appendingPathComponent("Loopera-Performance-\(Self.timestamp())")
            .appendingPathExtension("mov")

        try prepareWriter(outputURL: outputURL, width: width, height: height, includesMicrophone: captureMicrophone)

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
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        if #available(macOS 15.0, *) {
            configuration.captureMicrophone = captureMicrophone
            configuration.microphoneCaptureDeviceID = microphoneDeviceID
        }

        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        if #available(macOS 15.0, *), captureMicrophone {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: sampleQueue)
        }
        try await stream.startCapture()

        self.stream = stream
        lastRecordingURL = outputURL
    }

    private func prepareWriter(outputURL: URL, width: Int, height: Int, includesMicrophone: Bool) throws {
        didStartSession = false
        isFinishing = false

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

        let appAudioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 2,
            AVSampleRateKey: 48_000,
            AVEncoderBitRateKey: 128_000
        ]
        let appAudioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: appAudioSettings)
        appAudioInput.expectsMediaDataInRealTime = true

        let microphoneSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 2,
            AVSampleRateKey: 48_000,
            AVEncoderBitRateKey: 128_000
        ]
        let microphoneInput = AVAssetWriterInput(mediaType: .audio, outputSettings: microphoneSettings)
        microphoneInput.expectsMediaDataInRealTime = true

        if writer.canAdd(videoInput) {
            writer.add(videoInput)
        }
        if writer.canAdd(appAudioInput) {
            writer.add(appAudioInput)
        }
        if includesMicrophone, writer.canAdd(microphoneInput) {
            writer.add(microphoneInput)
        }

        guard writer.startWriting() else {
            throw writer.error ?? RecorderError.writerStartFailed
        }

        self.writer = writer
        self.videoInput = videoInput
        self.appAudioInput = appAudioInput
        self.microphoneInput = includesMicrophone ? microphoneInput : nil
        self.pixelBufferAdaptor = adaptor
    }

    private func cleanupWriter() {
        sampleQueue.sync {
            self.writer?.cancelWriting()
            self.writer = nil
            self.videoInput = nil
            self.appAudioInput = nil
            self.microphoneInput = nil
            self.pixelBufferAdaptor = nil
            self.didStartSession = false
            self.isFinishing = false
        }
    }

    private func finishWriter() async {
        await withCheckedContinuation { continuation in
            sampleQueue.async {
                self.isFinishing = true
                let writer = self.writer
                self.videoInput?.markAsFinished()
                self.appAudioInput?.markAsFinished()
                self.microphoneInput?.markAsFinished()
                self.writer = nil
                self.videoInput = nil
                self.appAudioInput = nil
                self.microphoneInput = nil
                self.pixelBufferAdaptor = nil
                self.didStartSession = false
                self.isFinishing = false

                guard let writer else {
                    Task { @MainActor in
                        self.status = "Performance recorder idle."
                    }
                    continuation.resume()
                    return
                }

                writer.finishWriting {
                    let finalStatus = writer.status
                    let errorText = writer.error?.localizedDescription
                    Task { @MainActor in
                        if finalStatus == .completed {
                            self.status = "Saved performance recording."
                        } else if let errorText {
                            self.status = "Performance recording failed: \(errorText)"
                        } else {
                            self.status = "Performance recording did not finish cleanly."
                        }
                    }
                    continuation.resume()
                }
            }
        }
    }

    nonisolated private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    nonisolated static var recordingsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Loopera", isDirectory: true)
            .appendingPathComponent("Performances", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
}

extension PerformanceRecorder: SCStreamOutput {
    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard sampleBuffer.isValid, !isFinishing else { return }

        switch outputType {
        case .screen:
            appendVideo(sampleBuffer)
        case .audio:
            appendAppAudio(sampleBuffer)
        case .microphone:
            appendMicrophone(sampleBuffer)
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

    private func appendAppAudio(_ sampleBuffer: CMSampleBuffer) {
        guard didStartSession, let appAudioInput, appAudioInput.isReadyForMoreMediaData else { return }
        appAudioInput.append(sampleBuffer)
    }

    private func appendMicrophone(_ sampleBuffer: CMSampleBuffer) {
        guard didStartSession, let microphoneInput, microphoneInput.isReadyForMoreMediaData else { return }
        microphoneInput.append(sampleBuffer)
    }
}

private enum RecorderError: LocalizedError {
    case noWindow
    case noShareableWindow
    case writerStartFailed
    case captureStartFailed(String)

    var errorDescription: String? {
        switch self {
        case .noWindow:
            return "No visible Loopera window was found."
        case .noShareableWindow:
            return "Loopera could not find its own window in ScreenCaptureKit."
        case .writerStartFailed:
            return "The movie writer could not start."
        case .captureStartFailed(let detail):
            return "Performance capture could not start. \(detail)"
        }
    }
}
