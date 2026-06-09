import AppKit
@preconcurrency import AVFoundation
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

    static func snapshot(windowID: CGWindowID) -> CGImage? {
        let direct = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            windowID,
            [.boundsIgnoreFraming, .bestResolution]
        )
        if let direct, !isEffectivelyBlack(direct) {
            return direct
        }
        return visibleDisplaySnapshot(windowID: windowID) ?? direct
    }

    private static func visibleDisplaySnapshot(windowID: CGWindowID) -> CGImage? {
        guard let bounds = bounds(for: windowID), bounds.width > 0, bounds.height > 0 else {
            return nil
        }

        var displayCount: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &displayCount) == .success, displayCount > 0 else {
            return nil
        }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        guard CGGetActiveDisplayList(displayCount, &displays, &displayCount) == .success else {
            return nil
        }

        let candidates = displays.compactMap { display -> (CGDirectDisplayID, CGRect, CGRect)? in
            let displayBounds = CGDisplayBounds(display)
            let intersection = bounds.intersection(displayBounds)
            guard intersection.width > 1, intersection.height > 1 else { return nil }
            return (display, displayBounds, intersection)
        }
        guard let best = candidates.max(by: { $0.2.width * $0.2.height < $1.2.width * $1.2.height }),
              let displayImage = CGDisplayCreateImage(best.0)
        else { return nil }

        let scaleX = CGFloat(displayImage.width) / max(1, best.1.width)
        let scaleY = CGFloat(displayImage.height) / max(1, best.1.height)
        let cropRect = CGRect(
            x: (best.2.minX - best.1.minX) * scaleX,
            y: (best.2.minY - best.1.minY) * scaleY,
            width: best.2.width * scaleX,
            height: best.2.height * scaleY
        )
        .integral
        .intersection(CGRect(x: 0, y: 0, width: displayImage.width, height: displayImage.height))

        guard cropRect.width > 0, cropRect.height > 0 else { return nil }
        return displayImage.cropping(to: cropRect)
    }

    private static func bounds(for windowID: CGWindowID) -> CGRect? {
        guard let entries = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]],
              let boundsInfo = entries.first?[kCGWindowBounds as String] as? [String: Any]
        else { return nil }
        return CGRect(dictionaryRepresentation: boundsInfo as CFDictionary)
    }

    private static func isEffectivelyBlack(_ image: CGImage) -> Bool {
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
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.refresh()
                }
            }
            timer?.tolerance = 0.01
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
