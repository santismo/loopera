@preconcurrency import AVFoundation
import AVKit
import SwiftUI

struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateNSView(_ nsView: PreviewView, context: Context) {
        nsView.previewLayer.session = session
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
    let audioOutputDeviceID: String?
    let playbackClock: LoopPlaybackClock
    let syncTime: TimeInterval
    let syncTimeUpdatedAt: Date

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> PlayerHostView {
        let view = PlayerHostView()
        context.coordinator.configure(
            url: url,
            slotID: slotID,
            startOffset: startOffset,
            duration: duration,
            isMuted: isMuted,
            isPlaying: isPlaying,
            audioOutputDeviceID: audioOutputDeviceID,
            playbackClock: playbackClock,
            syncTime: syncTime,
            syncTimeUpdatedAt: syncTimeUpdatedAt,
            in: view.playerLayer
        )
        return view
    }

    func updateNSView(_ nsView: PlayerHostView, context: Context) {
        context.coordinator.configure(
            url: url,
            slotID: slotID,
            startOffset: startOffset,
            duration: duration,
            isMuted: isMuted,
            isPlaying: isPlaying,
            audioOutputDeviceID: audioOutputDeviceID,
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
        private var player: AVQueuePlayer?
        private var looper: AVPlayerLooper?
        private var timeObserver: Any?
        private var wasPlaying = false
        private var lastSyncCorrection = Date.distantPast
        private weak var playerLayer: AVPlayerLayer?
        private var didFadeIn = false
        private var isFadingOut = false
        private let visualPhaseDelay: TimeInterval = 0.11

        @MainActor
        func configure(
            url: URL,
            slotID: UUID,
            startOffset: TimeInterval,
            duration: TimeInterval,
            isMuted: Bool,
            isPlaying: Bool,
            audioOutputDeviceID: String?,
            playbackClock: LoopPlaybackClock,
            syncTime: TimeInterval,
            syncTimeUpdatedAt: Date,
            in layer: AVPlayerLayer
        ) {
            if currentURL != url || currentStartOffset != startOffset || currentDuration != duration {
                if let timeObserver, let player {
                    player.removeTimeObserver(timeObserver)
                    self.timeObserver = nil
                }

                currentURL = url
                currentStartOffset = startOffset
                currentDuration = duration
                wasPlaying = false
                didFadeIn = false
                isFadingOut = false

                let item = AVPlayerItem(url: url)
                item.preferredForwardBufferDuration = 0
                let queuePlayer = AVQueuePlayer()
                queuePlayer.actionAtItemEnd = .none
                queuePlayer.automaticallyWaitsToMinimizeStalling = false

                let start = CMTime(seconds: startOffset, preferredTimescale: 600)
                if duration > 0 {
                    let rangeDuration = CMTime(seconds: duration, preferredTimescale: 600)
                    looper = AVPlayerLooper(
                        player: queuePlayer,
                        templateItem: item,
                        timeRange: CMTimeRange(start: start, duration: rangeDuration)
                    )
                } else {
                    looper = AVPlayerLooper(player: queuePlayer, templateItem: item)
                }
                player = queuePlayer
                playerLayer = layer
                layer.player = queuePlayer
                layer.videoGravity = .resizeAspectFill
                layer.opacity = 0
                let initialSeconds = targetVideoSeconds(
                    syncTime: syncTime,
                    syncTimeUpdatedAt: syncTimeUpdatedAt,
                    duration: duration
                )
                let initialTime = CMTimeAdd(start, CMTime(seconds: max(0, initialSeconds), preferredTimescale: 600))
                queuePlayer.seek(to: initialTime, toleranceBefore: .zero, toleranceAfter: .zero)
                playbackClock.update(slotID: slotID, seconds: max(0, initialSeconds))

                timeObserver = queuePlayer.addPeriodicTimeObserver(
                    forInterval: CMTime(value: 1, timescale: 30),
                    queue: .main
                ) { time in
                    Task { @MainActor in
                        playbackClock.update(slotID: slotID, seconds: max(0, time.seconds - startOffset))
                    }
                }
            }

            player?.isMuted = isMuted
            player?.audioOutputDeviceUniqueID = audioOutputDeviceID
            playbackClock.setPlaying(slotID: slotID, isPlaying: isPlaying)
            if isPlaying {
                isFadingOut = false
                if !wasPlaying {
                    syncVideoToClock(syncTime: syncTime, syncTimeUpdatedAt: syncTimeUpdatedAt, startOffset: startOffset, duration: duration, force: true)
                } else {
                    syncVideoToClock(syncTime: syncTime, syncTimeUpdatedAt: syncTimeUpdatedAt, startOffset: startOffset, duration: duration, force: false)
                }
                player?.play()
                fadeInIfNeeded()
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
            force: Bool
        ) {
            guard let player, duration > 0 else { return }
            if !force, Date().timeIntervalSince(lastSyncCorrection) < 0.12 {
                return
            }

            let targetSeconds = targetVideoSeconds(syncTime: syncTime, syncTimeUpdatedAt: syncTimeUpdatedAt, duration: duration)
            guard targetSeconds.isFinite, targetSeconds >= 0 else { return }
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
            guard force || abs(wrappedDelta) > 0.015 else { return }

            let target = CMTimeAdd(
                CMTime(seconds: startOffset, preferredTimescale: 600),
                CMTime(seconds: max(0, targetSeconds), preferredTimescale: 600)
            )
            player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
            lastSyncCorrection = Date()
        }

        @MainActor
        private func fadeInIfNeeded() {
            guard !didFadeIn, let playerLayer else { return }
            didFadeIn = true
            playerLayer.opacity = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                CATransaction.begin()
                CATransaction.setAnimationDuration(0.18)
                playerLayer.opacity = 1
                CATransaction.commit()
            }
        }

        @MainActor
        private func fadeOutAndReset(startOffset: TimeInterval) {
            guard let player else { return }
            if isFadingOut { return }
            isFadingOut = true
            didFadeIn = false

            if let playerLayer {
                CATransaction.begin()
                CATransaction.setAnimationDuration(0.16)
                playerLayer.opacity = 0
                CATransaction.commit()
            }

            let startTime = CMTime(seconds: startOffset, preferredTimescale: 600)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { [weak self, weak player] in
                guard let self, let player, self.isFadingOut else { return }
                player.pause()
                player.seek(to: startTime, toleranceBefore: .zero, toleranceAfter: .zero)
            }
        }

        private func audioPhaseSeconds(syncTime: TimeInterval, syncTimeUpdatedAt: Date, duration: TimeInterval) -> TimeInterval {
            guard duration > 0 else { return 0 }
            let phase = (syncTime + Date().timeIntervalSince(syncTimeUpdatedAt))
                .truncatingRemainder(dividingBy: duration)
            return phase.isFinite && phase >= 0 ? phase : 0
        }

        private func targetVideoSeconds(syncTime: TimeInterval, syncTimeUpdatedAt: Date, duration: TimeInterval) -> TimeInterval {
            guard duration > 0 else { return 0 }
            let delayed = audioPhaseSeconds(syncTime: syncTime, syncTimeUpdatedAt: syncTimeUpdatedAt, duration: duration) - visualPhaseDelay
            if delayed < 0 {
                return 0
            }
            return delayed.truncatingRemainder(dividingBy: duration)
        }

        deinit {
            if let timeObserver, let player {
                player.removeTimeObserver(timeObserver)
            }
        }
    }
}

final class PlayerHostView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    override func makeBackingLayer() -> CALayer {
        AVPlayerLayer()
    }

    var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
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
