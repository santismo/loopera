import AppKit
@preconcurrency import AVFoundation
import Foundation

final class PerformanceRecorder: NSObject, ObservableObject, @unchecked Sendable {
    @Published private(set) var isRecording = false
    @Published private(set) var status = "Program recorder idle."
    @Published private(set) var lastRecordingURL: URL?

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var liveAudioInput: AVAssetWriterInput?
    private var loopAudioInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var didStartSession = false
    private var liveAudioStartPTS: CMTime?
    private var loopAudioStartPTS: CMTime?
    private var isFinishing = false
    private var fallbackTimer: DispatchSourceTimer?
    private var fallbackStartTime: Date?
    private var nextVideoFrameIndex: Int64 = 0
    private nonisolated(unsafe) var acceptingAudio = false
    private let captureQueue = DispatchQueue(label: "Loopera.PerformanceRecorder.capture", qos: .userInteractive)
    private let sampleQueue = DispatchQueue(label: "Loopera.PerformanceRecorder.samples")
    private static let targetFrameRate: Int32 = 60
    private static let maxCatchUpFrames: Int64 = 8

    @MainActor
    func start(microphoneDeviceID: String?, fallbackView: NSView?) {
        guard !isRecording else { return }
        status = "Preparing performance recorder..."

        do {
            try startFallbackViewCapture(view: fallbackView)
            acceptingAudio = true
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
        acceptingAudio = false
        status = "Finishing performance recording..."
        fallbackTimer?.cancel()
        fallbackTimer = nil

        await finishWriter()
    }

    @MainActor
    private func startFallbackViewCapture(view: NSView?) throws {
        guard let view, let captureSource = WindowCaptureSource(view: view) else { throw RecorderError.noStageView }
        let stageAspect = max(1, view.bounds.width) / max(1, view.bounds.height)
        let scale = view.window?.backingScaleFactor ?? view.window?.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        let sourceSize = CGSize(width: view.bounds.width * scale, height: view.bounds.height * scale)
        let size = Self.recordingSize(aspect: stageAspect, sourceSize: sourceSize, minimumLongEdge: 2560, longEdgeLimit: 2560)
        var width = Int(size.width)
        var height = Int(size.height)
        let outputURL = Self.recordingsDirectory
            .appendingPathComponent("Loopera-Performance-\(Self.timestamp())-\(UUID().uuidString.prefix(8))")
            .appendingPathExtension("mov")

        do {
            try prepareWriter(outputURL: outputURL, width: width, height: height, codec: .hevc)
        } catch {
            cleanupWriter()
            do {
                try prepareWriter(outputURL: outputURL, width: width, height: height, codec: .h264)
            } catch {
                cleanupWriter()
                let fallbackSize = Self.recordingSize(aspect: stageAspect, sourceSize: sourceSize, minimumLongEdge: 1920, longEdgeLimit: 1920)
                width = Int(fallbackSize.width)
                height = Int(fallbackSize.height)
                try prepareWriter(outputURL: outputURL, width: width, height: height, codec: .h264)
            }
        }
        lastRecordingURL = outputURL
        let startTime = Date()
        fallbackStartTime = startTime
        let captureWidth = width
        let captureHeight = height

        startCaptureTimer(
            source: captureSource,
            startTime: startTime,
            width: captureWidth,
            height: captureHeight
        )
    }

    private func startCaptureTimer(source: WindowCaptureSource, startTime: Date, width: Int, height: Int) {
        let timer = DispatchSource.makeTimerSource(queue: captureQueue)
        timer.schedule(deadline: .now(), repeating: 1.0 / Double(Self.targetFrameRate), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard let image = Self.snapshot(source: source) else { return }
            let elapsed = Date().timeIntervalSince(startTime)
            self.sampleQueue.async {
                self.appendFallbackFrame(
                    image,
                    elapsed: elapsed,
                    width: width,
                    height: height
                )
            }
        }
        fallbackTimer = timer
        timer.resume()
    }

    private func prepareWriter(outputURL: URL, width: Int, height: Int, codec: AVVideoCodecType) throws {
        didStartSession = false
        isFinishing = false
        nextVideoFrameIndex = 0
        try? FileManager.default.removeItem(at: outputURL)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let targetBitrate = max(120_000_000, width * height * 42)
        var compressionProperties: [String: Any] = [
            AVVideoAverageBitRateKey: targetBitrate,
            AVVideoExpectedSourceFrameRateKey: Int(Self.targetFrameRate),
            AVVideoMaxKeyFrameIntervalKey: Int(Self.targetFrameRate),
            AVVideoMaxKeyFrameIntervalDurationKey: 1,
            AVVideoAllowFrameReorderingKey: false
        ]
        if codec == .h264 {
            compressionProperties[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        }
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compressionProperties
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
        )
        let audioInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 48_000,
                AVEncoderBitRateKey: 256_000
            ]
        )
        audioInput.expectsMediaDataInRealTime = true
        let loopAudioInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 48_000,
                AVEncoderBitRateKey: 256_000
            ]
        )
        loopAudioInput.expectsMediaDataInRealTime = true

        guard writer.canAdd(videoInput) else { throw RecorderError.cannotAddVideoInput }
        writer.add(videoInput)
        guard writer.canAdd(audioInput) else { throw RecorderError.cannotAddLiveAudioInput }
        writer.add(audioInput)
        guard writer.canAdd(loopAudioInput) else { throw RecorderError.cannotAddLoopAudioInput }
        writer.add(loopAudioInput)

        guard writer.startWriting() else {
            throw writer.error ?? RecorderError.writerStartFailed
        }

        self.writer = writer
        self.videoInput = videoInput
        self.liveAudioInput = audioInput
        self.loopAudioInput = loopAudioInput
        self.pixelBufferAdaptor = adaptor
    }

    private static func recordingSize(
        aspect: CGFloat,
        sourceSize: CGSize,
        minimumLongEdge: Double,
        longEdgeLimit: Double
    ) -> CGSize {
        let sourceAspect = Double(max(0.1, aspect))
        let sourceLongEdge = max(Double(sourceSize.width), Double(sourceSize.height))
        let longEdge = min(longEdgeLimit, max(minimumLongEdge, sourceLongEdge))
        let shortEdge: Double
        let width: Double
        let height: Double
        if sourceAspect >= 1 {
            shortEdge = longEdge / sourceAspect
            width = longEdge
            height = shortEdge
        } else {
            shortEdge = longEdge * sourceAspect
            width = shortEdge
            height = longEdge
        }

        return CGSize(
            width: multipleOf16(max(16, Int(width))),
            height: multipleOf16(max(16, Int(height)))
        )
    }

    private static func multipleOf16(_ value: Int) -> Int {
        max(16, (value / 16) * 16)
    }

    private func cleanupWriter() {
        sampleQueue.sync {
            self.writer?.cancelWriting()
            self.writer = nil
            self.videoInput = nil
            self.liveAudioInput = nil
            self.loopAudioInput = nil
            self.pixelBufferAdaptor = nil
            self.didStartSession = false
            self.liveAudioStartPTS = nil
            self.loopAudioStartPTS = nil
            self.isFinishing = false
            self.fallbackStartTime = nil
            self.nextVideoFrameIndex = 0
            self.acceptingAudio = false
        }
    }

    private func finishWriter() async {
        await withCheckedContinuation { continuation in
            sampleQueue.async {
                self.isFinishing = true
                let writer = self.writer
                self.videoInput?.markAsFinished()
                self.liveAudioInput?.markAsFinished()
                self.loopAudioInput?.markAsFinished()
                self.writer = nil
                self.videoInput = nil
                self.liveAudioInput = nil
                self.loopAudioInput = nil
                self.pixelBufferAdaptor = nil
                self.didStartSession = false
                self.liveAudioStartPTS = nil
                self.loopAudioStartPTS = nil
                self.isFinishing = false
                self.nextVideoFrameIndex = 0
                self.acceptingAudio = false

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

    nonisolated private static func even(_ value: Int) -> Int {
        value % 2 == 0 ? value : value + 1
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
    private struct WindowCaptureSource: @unchecked Sendable {
        let windowID: CGWindowID
        let windowFrameSize: CGSize
        let cropRectInWindow: CGRect

        @MainActor
        init?(view: NSView) {
            guard let window = view.window else { return nil }
            windowID = CGWindowID(window.windowNumber)
            windowFrameSize = window.frame.size
            cropRectInWindow = view.convert(view.bounds, to: nil)
        }
    }

    private static func snapshot(source: WindowCaptureSource) -> CGImage? {
        guard let windowImage = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            source.windowID,
            [.boundsIgnoreFraming, .bestResolution]
        ) else { return nil }

        let scale = CGFloat(windowImage.width) / max(1, source.windowFrameSize.width)
        let cropBounds = CGRect(x: 0, y: 0, width: windowImage.width, height: windowImage.height)
        let cropRect = CGRect(
            x: source.cropRectInWindow.minX * scale,
            y: CGFloat(windowImage.height) - source.cropRectInWindow.maxY * scale,
            width: source.cropRectInWindow.width * scale,
            height: source.cropRectInWindow.height * scale
        ).integral.intersection(cropBounds)

        if cropRect.width > 0,
           cropRect.height > 0,
           let cropped = windowImage.cropping(to: cropRect) {
            return cropped
        }
        return windowImage
    }

    private func appendFallbackFrame(_ image: CGImage, elapsed: TimeInterval, width: Int, height: Int) {
        guard
            let writer,
            let videoInput,
            let pixelBufferAdaptor,
            let pool = pixelBufferAdaptor.pixelBufferPool
        else { return }

        if !didStartSession {
            writer.startSession(atSourceTime: .zero)
            didStartSession = true
        }

        let targetFrameIndex = max(0, Int64((elapsed * Double(Self.targetFrameRate)).rounded(.down)))
        if nextVideoFrameIndex < targetFrameIndex - Self.maxCatchUpFrames + 1 {
            nextVideoFrameIndex = targetFrameIndex - Self.maxCatchUpFrames + 1
        }

        while nextVideoFrameIndex <= targetFrameIndex {
            guard videoInput.isReadyForMoreMediaData else { return }
            appendPixelBuffer(
                image,
                time: CMTime(value: nextVideoFrameIndex, timescale: Self.targetFrameRate),
                adaptor: pixelBufferAdaptor,
                pool: pool,
                width: width,
                height: height
            )
            nextVideoFrameIndex += 1
        }
    }

    private func appendPixelBuffer(
        _ image: CGImage,
        time: CMTime,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        pool: CVPixelBufferPool,
        width: Int,
        height: Int
    ) {
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
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        adaptor.append(buffer, withPresentationTime: time)
    }

    func appendLiveAudio(input: AudioLoopEngine.InputBuffer, sampleRate: Double, presentationTime: CMTime) {
        appendAudio(input: input, sampleRate: sampleRate, presentationTime: presentationTime, source: .live)
    }

    func appendLoopAudio(input: AudioLoopEngine.InputBuffer, sampleRate: Double, presentationTime: CMTime) {
        appendAudio(input: input, sampleRate: sampleRate, presentationTime: presentationTime, source: .loop)
    }

    private func appendAudio(
        input: AudioLoopEngine.InputBuffer,
        sampleRate: Double,
        presentationTime: CMTime,
        source: AudioSource
    ) {
        guard acceptingAudio, !input.isEmpty, sampleRate > 0 else { return }
        sampleQueue.async {
            let audioInput: AVAssetWriterInput?
            let basePTS: CMTime?
            switch source {
            case .live:
                audioInput = self.liveAudioInput
                if self.liveAudioStartPTS == nil {
                    self.liveAudioStartPTS = presentationTime
                }
                basePTS = self.liveAudioStartPTS
            case .loop:
                audioInput = self.loopAudioInput
                if self.loopAudioStartPTS == nil {
                    self.loopAudioStartPTS = presentationTime
                }
                basePTS = self.loopAudioStartPTS
            }
            guard let audioInput, audioInput.isReadyForMoreMediaData, let basePTS else { return }

            if !self.didStartSession {
                self.writer?.startSession(atSourceTime: .zero)
                self.didStartSession = true
            }

            let relativePTS = CMTimeSubtract(presentationTime, basePTS)
            guard relativePTS.isValid, relativePTS.seconds.isFinite else { return }

            guard let sampleBuffer = Self.makeStereoSampleBuffer(
                input: input,
                sampleRate: sampleRate,
                presentationTime: relativePTS
            ) else { return }
            audioInput.append(sampleBuffer)
        }
    }

    private static func makeStereoSampleBuffer(
        input: AudioLoopEngine.InputBuffer,
        sampleRate: Double,
        presentationTime: CMTime
    ) -> CMSampleBuffer? {
        let frameCount = input.count
        guard frameCount > 0 else { return nil }

        var interleaved = [Float]()
        interleaved.reserveCapacity(frameCount * 2)
        for index in 0..<frameCount {
            interleaved.append(max(-1, min(1, input.left[index])))
            interleaved.append(max(-1, min(1, input.right[index])))
        }

        var format = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8,
            mFramesPerPacket: 1,
            mBytesPerFrame: 8,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var formatDescription: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &format,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        ) == noErr, let formatDescription else {
            return nil
        }

        let byteCount = interleaved.count * MemoryLayout<Float>.size
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == noErr, let blockBuffer else {
            return nil
        }

        let copied = interleaved.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
            return CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: byteCount
            )
        }
        guard copied == noErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate.rounded())),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: frameCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        ) == noErr else {
            return nil
        }
        return sampleBuffer
    }

}

private enum RecorderError: LocalizedError {
    case noStageView
    case cannotAddVideoInput
    case cannotAddLiveAudioInput
    case cannotAddLoopAudioInput
    case writerStartFailed

    var errorDescription: String? {
        switch self {
        case .noStageView:
            return "Loopera could not find the stage view to record."
        case .cannotAddVideoInput:
            return "The movie writer rejected the performance video settings."
        case .cannotAddLiveAudioInput:
            return "The movie writer rejected the live audio settings."
        case .cannotAddLoopAudioInput:
            return "The movie writer rejected the loop audio settings."
        case .writerStartFailed:
            return "The movie writer could not start."
        }
    }
}

private enum AudioSource {
    case live
    case loop
}
