import AppKit
@preconcurrency import AVFoundation
import CoreImage
@preconcurrency import ScreenCaptureKit
import SwiftUI

enum VideoInputMode: String, CaseIterable, Identifiable, Codable {
    case camera = "Camera"
    case appWindow = "App Window"

    var id: String { rawValue }
}

struct AppWindowSource: Identifiable, Hashable {
    let id: CGWindowID
    let title: String
    let ownerName: String
    let bounds: CGRect

    var displayName: String {
        title.isEmpty ? ownerName : "\(ownerName): \(title)"
    }
}

enum AppWindowSourceStore {
    static var hasScreenCaptureAccess: Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    static func requestScreenCaptureAccess() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    static func currentWindows(excludingProcessID: pid_t = ProcessInfo.processInfo.processIdentifier) -> [AppWindowSource] {
        guard let entries = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }

        return entries.compactMap { entry in
            guard let idNumber = entry[kCGWindowNumber as String] as? NSNumber,
                  let ownerPID = entry[kCGWindowOwnerPID as String] as? NSNumber,
                  ownerPID.int32Value != excludingProcessID,
                  let layer = entry[kCGWindowLayer as String] as? NSNumber,
                  layer.intValue == 0,
                  let boundsInfo = entry[kCGWindowBounds as String] as? [String: Any]
            else { return nil }

            let bounds = CGRect(dictionaryRepresentation: boundsInfo as CFDictionary) ?? .zero
            guard bounds.width >= 120, bounds.height >= 90 else { return nil }

            let owner = (entry[kCGWindowOwnerName as String] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "App"
            let title = (entry[kCGWindowName as String] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !owner.isEmpty, owner != "Window Server" else { return nil }

            return AppWindowSource(
                id: CGWindowID(idNumber.uint32Value),
                title: title,
                ownerName: owner,
                bounds: bounds
            )
        }
        .sorted { lhs, rhs in
            lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    static func shareableWindows(excludingProcessID: pid_t = ProcessInfo.processInfo.processIdentifier) async -> [AppWindowSource] {
        guard hasScreenCaptureAccess, #available(macOS 14.0, *) else {
            return []
        }

        do {
            let content = try await SCShareableContent.current
            return content.windows.compactMap { window in
                guard window.owningApplication?.processID != excludingProcessID,
                      window.frame.width >= 120,
                      window.frame.height >= 90
                else { return nil }

                let owner = window.owningApplication?.applicationName
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "App"
                let title = (window.title ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !owner.isEmpty, owner != "Window Server" else { return nil }

                return AppWindowSource(
                    id: window.windowID,
                    title: title,
                    ownerName: owner,
                    bounds: window.frame
                )
            }
            .sorted { lhs, rhs in
                lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
        } catch {
            return []
        }
    }

    static func snapshot(windowID: CGWindowID) -> CGImage? {
        guard hasScreenCaptureAccess else { return nil }

        if let streamImage = AppWindowStreamFrameProvider.shared.snapshot(windowID: windowID) {
            return streamImage
        }

        let direct = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            windowID,
            [.boundsIgnoreFraming, .bestResolution]
        )
        if let direct, !isEffectivelyBlack(direct) {
            return direct
        }
        return nil
    }

    static func isEffectivelyBlack(_ image: CGImage) -> Bool {
        let width = 16
        let height = 16
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }

        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var brightPixels = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let red = Int(pixels[index])
            let green = Int(pixels[index + 1])
            let blue = Int(pixels[index + 2])
            if red + green + blue > 24 {
                brightPixels += 1
            }
        }
        return brightPixels < 3
    }
}

final class AppWindowStreamFrameProvider: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    static let shared = AppWindowStreamFrameProvider()

    private let stateQueue = DispatchQueue(label: "Loopera.AppWindowStreamFrameProvider.state")
    private let outputQueue = DispatchQueue(label: "Loopera.AppWindowStreamFrameProvider.output", qos: .userInteractive)
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var stream: SCStream?
    private var currentWindowID: CGWindowID?
    private var latestImage: CGImage?
    private var isStarting = false
    private var lastFailedWindowID: CGWindowID?
    private var lastFailureDate = Date.distantPast

    func snapshot(windowID: CGWindowID) -> CGImage? {
        let state = stateQueue.sync { () -> (image: CGImage?, shouldStart: Bool) in
            let recentFailure = lastFailedWindowID == windowID &&
                Date().timeIntervalSince(lastFailureDate) < 6
            return (
                image: currentWindowID == windowID ? latestImage : nil,
                shouldStart: !recentFailure && (currentWindowID != windowID || (stream == nil && !isStarting))
            )
        }

        if state.shouldStart {
            start(windowID: windowID)
        }
        return state.image
    }

    private func start(windowID: CGWindowID) {
        let startState = stateQueue.sync { () -> (shouldStart: Bool, oldStream: SCStream?) in
            if isStarting {
                return (false, nil)
            }
            isStarting = true
            latestImage = nil
            currentWindowID = windowID
            lastFailedWindowID = nil
            let previousStream = stream
            stream = nil
            return (true, previousStream)
        }
        guard startState.shouldStart else {
            return
        }

        if let oldStream = startState.oldStream {
            oldStream.stopCapture { _ in }
        }

        guard #available(macOS 14.0, *) else {
            finishStarting()
            return
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                let content = try await SCShareableContent.current
                guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                    self.finishStarting(failedWindowID: windowID)
                    return
                }

                if let initialImage = await self.captureInitialImage(for: window) {
                    self.stateQueue.sync {
                        if self.currentWindowID == windowID {
                            self.latestImage = initialImage
                        }
                    }
                }

                let config = SCStreamConfiguration()
                config.width = max(16, Int(window.frame.width.rounded()))
                config.height = max(16, Int(window.frame.height.rounded()))
                config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
                config.pixelFormat = kCVPixelFormatType_32BGRA
                config.scalesToFit = true
                config.preservesAspectRatio = true
                config.showsCursor = false
                config.capturesAudio = false
                config.queueDepth = 3
                config.ignoreShadowsSingleWindow = true
                config.ignoreGlobalClipSingleWindow = true
                config.shouldBeOpaque = true

                let filter = SCContentFilter(desktopIndependentWindow: window)
                let stream = SCStream(filter: filter, configuration: config, delegate: self)
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
                try await stream.startCapture()

                let keepStream = self.stateQueue.sync { () -> Bool in
                    guard self.currentWindowID == windowID else { return false }
                    self.stream = stream
                    self.isStarting = false
                    return true
                }
                if !keepStream {
                    stream.stopCapture { _ in }
                    self.finishStarting()
                }
            } catch {
                self.finishStarting(failedWindowID: windowID)
            }
        }
    }

    @available(macOS 14.0, *)
    private func captureInitialImage(for window: SCWindow) async -> CGImage? {
        let config = SCStreamConfiguration()
        config.width = max(16, Int(window.frame.width.rounded()))
        config.height = max(16, Int(window.frame.height.rounded()))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.scalesToFit = true
        config.preservesAspectRatio = true
        config.showsCursor = false
        config.capturesAudio = false
        config.ignoreShadowsSingleWindow = true
        config.ignoreGlobalClipSingleWindow = true
        config.shouldBeOpaque = true

        let filter = SCContentFilter(desktopIndependentWindow: window)
        return await withCheckedContinuation { continuation in
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }

    private func finishStarting(failedWindowID: CGWindowID? = nil) {
        stateQueue.sync {
            isStarting = false
            if let failedWindowID {
                lastFailedWindowID = failedWindowID
                lastFailureDate = Date()
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              CMSampleBufferIsValid(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }

        stateQueue.sync {
            latestImage = cgImage
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        stateQueue.sync {
            if self.stream === stream {
                self.stream = nil
                latestImage = nil
            }
            isStarting = false
        }
    }
}

struct AppWindowPreview: NSViewRepresentable {
    let windowID: CGWindowID?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> AppWindowPreviewView {
        let view = AppWindowPreviewView()
        context.coordinator.start(view: view, windowID: windowID)
        return view
    }

    func updateNSView(_ nsView: AppWindowPreviewView, context: Context) {
        context.coordinator.start(view: nsView, windowID: windowID)
    }

    final class Coordinator {
        private weak var view: AppWindowPreviewView?
        private var timer: Timer?
        private var currentWindowID: CGWindowID?

        @MainActor
        func start(view: AppWindowPreviewView, windowID: CGWindowID?) {
            self.view = view
            guard currentWindowID != windowID || timer == nil else { return }
            currentWindowID = windowID
            timer?.invalidate()
            timer = nil
            view.imageLayer.contents = nil

            guard windowID != nil else { return }
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.refresh()
                }
            }
            timer?.tolerance = 0.004
            refresh()
        }

        @MainActor
        private func refresh() {
            guard let currentWindowID,
                  let image = AppWindowSourceStore.snapshot(windowID: currentWindowID)
            else { return }
            view?.imageLayer.contents = image
        }

        deinit {
            timer?.invalidate()
        }
    }
}

final class AppWindowPreviewView: NSView {
    let imageLayer = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        imageLayer.contentsGravity = .resizeAspectFill
        layer?.addSublayer(imageLayer)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func layout() {
        super.layout()
        imageLayer.frame = bounds
    }
}

final class AppWindowLoopRecorder: @unchecked Sendable {
    enum RecorderError: LocalizedError {
        case noWindowSelected
        case noInitialFrame
        case cannotAddVideoInput
        case writerStartFailed

        var errorDescription: String? {
            switch self {
            case .noWindowSelected:
                return "No app window selected."
            case .noInitialFrame:
                return "Could not capture the selected window."
            case .cannotAddVideoInput:
                return "Could not add window video input."
            case .writerStartFailed:
                return "Could not start window video writer."
            }
        }
    }

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var timer: DispatchSourceTimer?
    private var startTime = Date()
    private var nextFrameIndex: Int64 = 0
    private var outputURL: URL?
    private var windowID: CGWindowID = 0
    private var width = 1920
    private var height = 1080
    private var isRecording = false
    private let captureQueue = DispatchQueue(label: "Loopera.AppWindowLoopRecorder.capture", qos: .userInteractive)
    private let writerQueue = DispatchQueue(label: "Loopera.AppWindowLoopRecorder.writer")
    private static let targetFrameRate: Int32 = 60
    private static let maxCatchUpFrames: Int64 = 8

    @MainActor
    func start(windowID: CGWindowID?, outputURL: URL) throws {
        stopDiscarding()
        guard let windowID, windowID != 0 else { throw RecorderError.noWindowSelected }
        guard let firstImage = AppWindowSourceStore.snapshot(windowID: windowID) else {
            throw RecorderError.noInitialFrame
        }

        self.windowID = windowID
        self.outputURL = outputURL
        let size = Self.recordingSize(for: firstImage)
        width = size.width
        height = size.height
        try prepareWriter(outputURL: outputURL, width: width, height: height)
        isRecording = true
        startTime = Date()
        nextFrameIndex = 0
        appendFrame(firstImage, elapsed: 0)
        startTimer()
    }

    @MainActor
    func stop(completion: @escaping @MainActor (URL, Error?) -> Void) {
        guard isRecording, let outputURL else { return }
        isRecording = false
        timer?.cancel()
        timer = nil
        writerQueue.async { [weak self] in
            guard let self else { return }
            self.videoInput?.markAsFinished()
            self.writer?.finishWriting { [weak self] in
                guard let self else { return }
                let error = self.writer?.error
                self.cleanupWriter(cancelWriting: false)
                Task { @MainActor in
                    completion(outputURL, error)
                }
            }
        }
    }

    @MainActor
    func stopDiscarding() {
        isRecording = false
        timer?.cancel()
        timer = nil
        cleanupWriter(cancelWriting: true)
    }

    private func prepareWriter(outputURL: URL, width: Int, height: Int) throws {
        try? FileManager.default.removeItem(at: outputURL)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let bitrate = max(30_000_000, width * height * 18)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: Int(Self.targetFrameRate),
                AVVideoMaxKeyFrameIntervalKey: Int(Self.targetFrameRate),
                AVVideoAllowFrameReorderingKey: false,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
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

        guard writer.canAdd(videoInput) else { throw RecorderError.cannotAddVideoInput }
        writer.add(videoInput)
        guard writer.startWriting() else {
            throw writer.error ?? RecorderError.writerStartFailed
        }
        writer.startSession(atSourceTime: .zero)

        self.writer = writer
        self.videoInput = videoInput
        self.pixelBufferAdaptor = adaptor
    }

    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: captureQueue)
        timer.schedule(deadline: .now(), repeating: 1.0 / Double(Self.targetFrameRate), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            guard let self, self.isRecording else { return }
            guard let image = AppWindowSourceStore.snapshot(windowID: self.windowID) else { return }
            let elapsed = Date().timeIntervalSince(self.startTime)
            self.appendFrame(image, elapsed: elapsed)
        }
        self.timer = timer
        timer.resume()
    }

    private func appendFrame(_ image: CGImage, elapsed: TimeInterval) {
        writerQueue.async { [weak self] in
            guard let self,
                  self.isRecording,
                  let videoInput = self.videoInput,
                  let adaptor = self.pixelBufferAdaptor,
                  let pool = adaptor.pixelBufferPool
            else { return }

            let targetFrameIndex = max(0, Int64((elapsed * Double(Self.targetFrameRate)).rounded(.down)))
            if self.nextFrameIndex < targetFrameIndex - Self.maxCatchUpFrames + 1 {
                self.nextFrameIndex = targetFrameIndex - Self.maxCatchUpFrames + 1
            }
            while self.nextFrameIndex <= targetFrameIndex {
                guard videoInput.isReadyForMoreMediaData else { return }
                self.appendPixelBuffer(
                    image,
                    time: CMTime(value: self.nextFrameIndex, timescale: Self.targetFrameRate),
                    adaptor: adaptor,
                    pool: pool
                )
                self.nextFrameIndex += 1
            }
        }
    }

    private func appendPixelBuffer(
        _ image: CGImage,
        time: CMTime,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        pool: CVPixelBufferPool
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

    private func cleanupWriter(cancelWriting: Bool) {
        if cancelWriting {
            writer?.cancelWriting()
        }
        writer = nil
        videoInput = nil
        pixelBufferAdaptor = nil
        outputURL = nil
    }

    private static func recordingSize(for image: CGImage) -> (width: Int, height: Int) {
        let sourceWidth = max(16, image.width)
        let sourceHeight = max(16, image.height)
        let longEdge = min(2560, max(sourceWidth, sourceHeight))
        let aspect = Double(sourceWidth) / Double(sourceHeight)
        let width: Int
        let height: Int
        if aspect >= 1 {
            width = longEdge
            height = max(16, Int(Double(longEdge) / aspect))
        } else {
            height = longEdge
            width = max(16, Int(Double(longEdge) * aspect))
        }
        return (multipleOf16(width), multipleOf16(height))
    }

    private static func multipleOf16(_ value: Int) -> Int {
        max(16, (value / 16) * 16)
    }
}
