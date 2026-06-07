import AppKit
@preconcurrency import AVFoundation
import Foundation

final class PerformanceRecorder: NSObject, ObservableObject, @unchecked Sendable {
    @Published private(set) var isRecording = false
    @Published private(set) var status = "Program recorder idle."
    @Published private(set) var lastRecordingURL: URL?

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var didStartSession = false
    private var isFinishing = false
    private var fallbackTimer: DispatchSourceTimer?
    private var fallbackStartTime: Date?
    private let sampleQueue = DispatchQueue(label: "Loopera.PerformanceRecorder.samples")

    @MainActor
    func start(microphoneDeviceID: String?, fallbackView: NSView?) {
        guard !isRecording else { return }
        status = "Preparing performance recorder..."

        do {
            try startFallbackViewCapture(view: fallbackView)
            isRecording = true
            status = "Recording performance video."
        } catch {
            Task { await stop() }
            status = "Performance recording failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    func stop() async {
        isRecording = false
        status = "Finishing performance recording..."
        fallbackTimer?.cancel()
        fallbackTimer = nil

        await finishWriter()
    }

    @MainActor
    private func startFallbackViewCapture(view: NSView?) throws {
        guard let view else { throw RecorderError.noStageView }
        let scale = view.window?.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let width = max(640, Int(view.bounds.width * scale))
        let height = max(360, Int(view.bounds.height * scale))
        let outputURL = Self.recordingsDirectory
            .appendingPathComponent("Loopera-Performance-\(Self.timestamp())")
            .appendingPathExtension("mov")

        try prepareWriter(outputURL: outputURL, width: width, height: height)
        lastRecordingURL = outputURL
        fallbackStartTime = Date()

        let timer = DispatchSource.makeTimerSource(queue: sampleQueue)
        timer.schedule(deadline: .now(), repeating: 1.0 / 30.0)
        timer.setEventHandler { [weak self, weak view] in
            guard let self, let view else { return }
            DispatchQueue.main.async {
                guard let image = self.snapshot(view: view, width: width, height: height) else { return }
                let elapsed = Date().timeIntervalSince(self.fallbackStartTime ?? Date())
                self.sampleQueue.async {
                    self.appendFallbackFrame(image, time: CMTime(seconds: elapsed, preferredTimescale: 600), width: width, height: height)
                }
            }
        }
        fallbackTimer = timer
        timer.resume()
    }

    private func prepareWriter(outputURL: URL, width: Int, height: Int) throws {
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

        if writer.canAdd(videoInput) {
            writer.add(videoInput)
        }

        guard writer.startWriting() else {
            throw writer.error ?? RecorderError.writerStartFailed
        }

        self.writer = writer
        self.videoInput = videoInput
        self.pixelBufferAdaptor = adaptor
    }

    private func cleanupWriter() {
        sampleQueue.sync {
            self.writer?.cancelWriting()
            self.writer = nil
            self.videoInput = nil
            self.pixelBufferAdaptor = nil
            self.didStartSession = false
            self.isFinishing = false
            self.fallbackStartTime = nil
        }
    }

    private func finishWriter() async {
        await withCheckedContinuation { continuation in
            sampleQueue.async {
                self.isFinishing = true
                let writer = self.writer
                self.videoInput?.markAsFinished()
                self.writer = nil
                self.videoInput = nil
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

extension PerformanceRecorder {
    @MainActor
    private func snapshot(view: NSView, width: Int, height: Int) -> CGImage? {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        guard let bitmap else { return nil }
        bitmap.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap.cgImage
    }

    private func appendFallbackFrame(_ image: CGImage, time: CMTime, width: Int, height: Int) {
        guard
            let writer,
            let videoInput,
            let pixelBufferAdaptor,
            videoInput.isReadyForMoreMediaData,
            let pool = pixelBufferAdaptor.pixelBufferPool
        else { return }

        if !didStartSession {
            writer.startSession(atSourceTime: .zero)
            didStartSession = true
        }

        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { return }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) {
            context.setFillColor(NSColor.black.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        pixelBufferAdaptor.append(buffer, withPresentationTime: time)
    }

}

private enum RecorderError: LocalizedError {
    case noStageView
    case writerStartFailed

    var errorDescription: String? {
        switch self {
        case .noStageView:
            return "Loopera could not find the stage view to record."
        case .writerStartFailed:
            return "The movie writer could not start."
        }
    }
}
