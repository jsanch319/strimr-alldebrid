#if os(iOS) || os(macOS)
    import AVFoundation
    import Foundation
    import Observation

    @MainActor @Observable
    final class DirectTrailerPreview {
        let player = AVQueuePlayer()
        private let owner = UUID()
        private var looper: AVPlayerLooper?
        private var endObserver: NSObjectProtocol?
        private var failureObserver: NSObjectProtocol?
        private var itemObserver: NSKeyValueObservation?
        private var currentItemObserver: NSKeyValueObservation?
        private(set) var active = false
        var ready = false
        private(set) var muted = true
        private(set) var generation = UUID()

        init() {
            player.isMuted = true
        }

        func start(_ stream: AuthorizedTrailerStream) {
            stop()
            guard TrailerPlaybackCoordinator.shared.claim(owner, manual: false, stop: { [weak self] in self?.stop() })
            else { return }
            generation = UUID(); active = true; muted = true; ready = false
            player.isMuted = true; player.allowsExternalPlayback = false
            player.audiovisualBackgroundPlaybackPolicy = .pauses
            let item = AVPlayerItem(url: stream.url)
            if stream.permitsAdFreeLooping {
                looper = AVPlayerLooper(player: player, templateItem: item)
            } else {
                player.insert(item, after: nil)
                endObserver = NotificationCenter.default.addObserver(
                    forName: .AVPlayerItemDidPlayToEndTime,
                    object: item,
                    queue: .main,
                ) { [weak self] _ in
                    Task { @MainActor in self?.stop() }
                }
            }
            failureObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemFailedToPlayToEndTime,
                object: nil,
                queue: .main,
            ) { [weak self] _ in
                Task { @MainActor in self?.stop() }
            }
            currentItemObserver = player.observe(\.currentItem, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor in self?.observeCurrentItem() }
            }
            player.play()
        }

        private func observeCurrentItem() {
            guard active else { return }
            itemObserver = player.currentItem?.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                let failed = item.status == .failed
                if failed {
                    Task { @MainActor in self?.stop() }
                }
            }
        }

        func toggleMute() {
            muted.toggle(); player.isMuted = muted
        }

        func stop() {
            itemObserver = nil; currentItemObserver = nil
            player.pause(); looper = nil; player.removeAllItems()
            if let endObserver {
                NotificationCenter.default.removeObserver(endObserver)
            }
            if let failureObserver {
                NotificationCenter.default.removeObserver(failureObserver)
            }
            endObserver = nil; failureObserver = nil; active = false; ready = false
            TrailerPlaybackCoordinator.shared.release(owner)
        }
    }

#endif
