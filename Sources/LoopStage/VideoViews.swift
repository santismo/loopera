@preconcurrency import AVFoundation
import AVKit
import SwiftUI

struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    var videoGravity: AVLayerVideoGravity = .resizeAspectFill

    func makeNSView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = videoGravity
        return view
    }

    func updateNSView(_ nsView: PreviewView, context: Context) {
        nsView.previewLayer.session = session
        nsView.previewLayer.videoGravity = videoGravity
    }
}

final class PreviewView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    override func makeBackingLayer() -> CALayer {
        AVCaptureVideoPreviewLayer()
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }
}

struct LoopPlayerView: NSViewRepresentable {
    let url: URL
    let slotID: UUID
    let startOffset: TimeInterval
    let duration: TimeInterval
    let isMuted: Bool
    let isPlaying: Bool
    let isStopping: Bool
    let audioOutputDeviceID: String?
    let videoZoom: Double
    let videoSyncOffset: TimeInterval
    let playbackClock: LoopPlaybackClock
    let syncTime: TimeInterval
    let syncTimeUpdatedAt: Date

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> PlayerHostView {
        let view = PlayerHostView()
        view.videoZoom = max(1, CGFloat(videoZoom))
        context.coordinator.configure(
            url: url,
            slotID: slotID,
            startOffset: startOffset,
            duration: duration,
            isMuted: isMuted,
            isPlaying: isPlaying,
            isStopping: isStopping,
            audioOutputDeviceID: audioOutputDeviceID,
            videoZoom: videoZoom,
            videoSyncOffset: videoSyncOffset,
            playbackClock: playbackClock,
            syncTime: syncTime,
            syncTimeUpdatedAt: syncTimeUpdatedAt,
            in: view.playerLayer
        )
        return view
    }

    func updateNSView(_ nsView: PlayerHostView, context: Context) {
        nsView.videoZoom = max(1, CGFloat(videoZoom))
        context.coordinator.configure(
            url: url,
            slotID: slotID,
            startOffset: startOffset,
            duration: duration,
            isMuted: isMuted,
            isPlaying: isPlaying,
            isStopping: isStopping,
            audioOutputDeviceID: audioOutputDeviceID,
            videoZoom: videoZoom,
            videoSyncOffset: videoSyncOffset,
            playbackClock: playbackClock,
            syncTime: syncTime,
            syncTimeUpdatedAt: syncTimeUpdatedAt,
            in: nsView.playerLayer
        )
    }

    final class Coordinator {
        private var currentURL: URL?
        private var currentStartOffset: TimeInterval = -1
        private var currentDuration: TimeInterval = -1
        private var player: AVPlayer?
        private var wasPlaying = false
        private var lastSyncCorrection = Date.distantPast
        private var previousAudioPhase: TimeInterval?
        private var currentVideoZoom: Double = 1
        private var currentVideoSyncOffset: TimeInterval = 0
        private weak var playerLayer: AVPlayerLayer?
        private var didFadeIn = false
        private var isFadingOut = false

        @MainActor
        func configure(
            url: URL,
            slotID: UUID,
            startOffset: TimeInterval,
            duration: TimeInterval,
            isMuted: Bool,
            isPlaying: Bool,
            isStopping: Bool,
            audioOutputDeviceID: String?,
            videoZoom: Double,
            videoSyncOffset: TimeInterval,
            playbackClock: LoopPlaybackClock,
            syncTime: TimeInterval,
            syncTimeUpdatedAt: Date,
            in layer: AVPlayerLayer
        ) {
            currentVideoZoom = max(1, videoZoom)
            let syncOffsetChanged = abs(currentVideoSyncOffset - videoSyncOffset) > 0.0005
            currentVideoSyncOffset = videoSyncOffset
            if currentURL != url || currentStartOffset != startOffset || currentDuration != duration {
                currentURL = url
                currentStartOffset = startOffset
                currentDuration = duration
                wasPlaying = false
                didFadeIn = false
                isFadingOut = false
                previousAudioPhase = nil

                let item = AVPlayerItem(url: url)
                item.preferredForwardBufferDuration = 0
                let player = AVPlayer(playerItem: item)
                player.actionAtItemEnd = .none
                player.automaticallyWaitsToMinimizeStalling = false
                let start = CMTime(seconds: startOffset, preferredTimescale: 600)
                item.forwardPlaybackEndTime = duration > 0
                    ? CMTimeAdd(start, CMTime(seconds: duration, preferredTimescale: 600))
                    : .invalid
                self.player = player
                playerLayer = layer
                layer.player = player
                layer.videoGravity = .resizeAspectFill
                layer.opacity = 0
                let initialSeconds = targetVideoSeconds(
                    syncTime: syncTime,
                    syncTimeUpdatedAt: syncTimeUpdatedAt,
                    duration: duration,
                    videoSyncOffset: videoSyncOffset
                )
                let initialTime = CMTimeAdd(start, CMTime(seconds: max(0, initialSeconds), preferredTimescale: 600))
                player.seek(to: initialTime, toleranceBefore: .zero, toleranceAfter: .zero)
            }

            player?.isMuted = isMuted
            player?.audioOutputDeviceUniqueID = audioOutputDeviceID
            if isPlaying {
                let currentAudioPhase = audioPhaseSeconds(syncTime: syncTime, syncTimeUpdatedAt: syncTimeUpdatedAt, duration: duration)
                if isStopping {
                    fadeOutToBoundary(currentSeconds: currentAudioPhase)
                } else {
                    isFadingOut = false
                }
                if !wasPlaying || syncOffsetChanged {
                    syncVideoToClock(syncTime: syncTime, syncTimeUpdatedAt: syncTimeUpdatedAt, startOffset: startOffset, duration: duration, videoSyncOffset: videoSyncOffset, force: true)
                } else {
                    syncVideoToClock(syncTime: syncTime, syncTimeUpdatedAt: syncTimeUpdatedAt, startOffset: startOffset, duration: duration, videoSyncOffset: videoSyncOffset, force: false)
                }
                player?.play()
                if !isStopping {
                    fadeInIfNeeded()
                }
            } else {
                fadeOutAndReset(startOffset: startOffset)
            }
            wasPlaying = isPlaying
        }

        @MainActor
        private func syncVideoToClock(
            syncTime: TimeInterval,
            syncTimeUpdatedAt: Date,
            startOffset: TimeInterval,
            duration: TimeInterval,
            videoSyncOffset: TimeInterval,
            force: Bool
        ) {
            guard let player, duration > 0 else { return }
            let targetSeconds = targetVideoSeconds(syncTime: syncTime, syncTimeUpdatedAt: syncTimeUpdatedAt, duration: duration, videoSyncOffset: videoSyncOffset)
            guard targetSeconds.isFinite, targetSeconds >= 0 else { return }
            let crossedBoundary = didAudioPhaseWrap(targetSeconds: targetSeconds, duration: duration)
            if !force, !crossedBoundary, targetSeconds >= 0.025, Date().timeIntervalSince(lastSyncCorrection) < 0.35 {
                return
            }
            let currentSeconds = max(0, player.currentTime().seconds - startOffset)
                .truncatingRemainder(dividingBy: duration)
            let rawDelta = targetSeconds - currentSeconds
            let wrappedDelta: TimeInterval
            if rawDelta > duration / 2 {
                wrappedDelta = rawDelta - duration
            } else if rawDelta < -duration / 2 {
                wrappedDelta = rawDelta + duration
            } else {
                wrappedDelta = rawDelta
            }
            guard force || crossedBoundary || targetSeconds < 0.025 || abs(wrappedDelta) > 0.06 else { return }

            let target = CMTimeAdd(
                CMTime(seconds: startOffset, preferredTimescale: 600),
                CMTime(seconds: crossedBoundary ? 0 : max(0, targetSeconds), preferredTimescale: 600)
            )
            let tolerance = crossedBoundary || force || targetSeconds < 0.025
                ? CMTime.zero
                : CMTime(seconds: 1.0 / 60.0, preferredTimescale: 600)
            player.seek(to: target, toleranceBefore: tolerance, toleranceAfter: tolerance)
            lastSyncCorrection = Date()
        }

        @MainActor
        private func fadeInIfNeeded() {
            guard !didFadeIn, let playerLayer else { return }
            didFadeIn = true
            playerLayer.removeAnimation(forKey: "loopera.opacity")
            playerLayer.opacity = 1
        }

        @MainActor
        private func fadeOutAndReset(startOffset: TimeInterval) {
            guard let player else { return }
            if isFadingOut { return }
            isFadingOut = true
            didFadeIn = false
            let duration = max(0, currentDuration)
            let currentSeconds: TimeInterval
            if duration > 0, let previousAudioPhase {
                currentSeconds = previousAudioPhase.truncatingRemainder(dividingBy: duration)
            } else {
                currentSeconds = 0
            }
            let fadeDuration = duration > 0 ? max(0.18, duration - currentSeconds) : 0.18

            if let playerLayer {
                animateOpacity(of: playerLayer, to: 0, duration: fadeDuration)
            }

            let startTime = CMTime(seconds: startOffset, preferredTimescale: 600)
            DispatchQueue.main.asyncAfter(deadline: .now() + fadeDuration) { [weak self, weak player] in
                guard let self, let player, self.isFadingOut else { return }
                player.pause()
                player.seek(to: startTime, toleranceBefore: .zero, toleranceAfter: .zero)
            }
        }

        @MainActor
        private func fadeOutToBoundary(currentSeconds: TimeInterval) {
            guard !isFadingOut else { return }
            isFadingOut = true
            didFadeIn = false
            let duration = max(0, currentDuration)
            let fadeDuration = duration > 0 ? max(0.18, duration - currentSeconds) : 0.18
            if let playerLayer {
                animateOpacity(of: playerLayer, to: 0, duration: fadeDuration)
            }
        }

        @MainActor
        private func animateOpacity(of layer: CALayer, to opacity: Float, duration: TimeInterval) {
            let fromOpacity = (layer.presentation() ?? layer).opacity
            layer.removeAnimation(forKey: "loopera.opacity")
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = fromOpacity
            animation.toValue = opacity
            animation.duration = max(0.01, duration)
            animation.timingFunction = CAMediaTimingFunction(name: .linear)
            layer.opacity = opacity
            layer.add(animation, forKey: "loopera.opacity")
        }

        private func audioPhaseSeconds(syncTime: TimeInterval, syncTimeUpdatedAt: Date, duration: TimeInterval) -> TimeInterval {
            guard duration > 0 else { return 0 }
            let phase = (syncTime + Date().timeIntervalSince(syncTimeUpdatedAt))
                .truncatingRemainder(dividingBy: duration)
            return phase.isFinite && phase >= 0 ? phase : 0
        }

        private func targetVideoSeconds(
            syncTime: TimeInterval,
            syncTimeUpdatedAt: Date,
            duration: TimeInterval,
            videoSyncOffset: TimeInterval
        ) -> TimeInterval {
            guard duration > 0 else { return 0 }
            let phase = audioPhaseSeconds(syncTime: syncTime, syncTimeUpdatedAt: syncTimeUpdatedAt, duration: duration)
            let adjusted = phase + videoSyncOffset
            let wrapped = adjusted.truncatingRemainder(dividingBy: duration)
            return wrapped >= 0 ? wrapped : wrapped + duration
        }

        private func didAudioPhaseWrap(targetSeconds: TimeInterval, duration: TimeInterval) -> Bool {
            defer { previousAudioPhase = targetSeconds }
            guard let previousAudioPhase else { return false }
            return previousAudioPhase > duration * 0.82 && targetSeconds < duration * 0.18
        }
    }
}

final class PlayerHostView: NSView {
    let playerLayer = AVPlayerLayer()

    var videoZoom: CGFloat = 1 {
        didSet {
            if abs(videoZoom - oldValue) > 0.001 {
                needsLayout = true
            }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        playerLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.masksToBounds = true
        playerLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(playerLayer)
    }

    override func layout() {
        super.layout()
        let zoom = max(1, videoZoom)
        let width = bounds.width * zoom
        let height = bounds.height * zoom
        playerLayer.frame = CGRect(
            x: bounds.midX - width / 2,
            y: bounds.midY - height / 2,
            width: width,
            height: height
        )
    }
}

@MainActor
final class LoopPlaybackClock: ObservableObject {
    struct Sample {
        var seconds: TimeInterval
        var date: Date
        var isPlaying: Bool
    }

    @Published private var samples: [UUID: Sample] = [:]

    func time(for slotID: UUID) -> TimeInterval {
        guard let sample = samples[slotID] else { return 0 }
        guard sample.isPlaying else { return sample.seconds }
        return sample.seconds + Date().timeIntervalSince(sample.date)
    }

    func update(slotID: UUID, seconds: TimeInterval) {
        let isPlaying = samples[slotID]?.isPlaying ?? true
        samples[slotID] = Sample(seconds: seconds.isFinite ? seconds : 0, date: Date(), isPlaying: isPlaying)
    }

    func setPlaying(slotID: UUID, isPlaying: Bool) {
        let current = time(for: slotID)
        samples[slotID] = Sample(seconds: current, date: Date(), isPlaying: isPlaying)
    }
}
