#if os(iOS)
    import AVFoundation
    import Combine
    import OSLog

    /// On-device unified logging only; no analytics, URLs, names, IPs, media IDs, headers,
    /// NSError descriptions, log-event URIs or account information leave this observer.
    @MainActor
    final class AirPlayDiagnostics {
        private let logger = Logger(subsystem: "app.strimr.playback", category: "AirPlay")
        private weak var player: AVPlayer?
        private var playerSubscriptions = Set<AnyCancellable>()
        private var itemSubscriptions = Set<AnyCancellable>()
        private var sessionSubscriptions = Set<AnyCancellable>()
        private var source = "unknown"

        init() {
            let center = NotificationCenter.default
            center.publisher(for: AVAudioSession.routeChangeNotification)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] note in
                    let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
                    // oldDeviceUnavailable cannot distinguish a deliberate TV disconnect from Wi-Fi loss.
                    self?.record("route-changed", detail: Int(reason))
                }.store(in: &sessionSubscriptions)
            center.publisher(for: AVAudioSession.interruptionNotification)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] note in
                    let began = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                        == AVAudioSession.InterruptionType.began.rawValue
                    let flags = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                    self?.record(began ? "interruption-began" : "interruption-ended", detail: Int(flags))
                    // The engine already honours shouldResume and explicit pause intent. Do not play/reload here.
                }.store(in: &sessionSubscriptions)
        }

        func setSource(_ url: URL) {
            source = AirPlayPlaybackPolicy.sourceCategory(url)
            record("source-load")
        }

        func attach(_ player: AVPlayer?) {
            guard self.player !== player else { return }
            playerSubscriptions.removeAll(); itemSubscriptions.removeAll()
            self.player = player
            guard let player else { return }
            player.publisher(for: \.isExternalPlaybackActive).removeDuplicates()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.record("external-state") }
                .store(in: &playerSubscriptions)
            player.publisher(for: \.timeControlStatus).removeDuplicates()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] state in
                    self?.record(state == .waitingToPlayAtSpecifiedRate ? "waiting" :
                        state == .playing ? "playing" : "paused")
                }.store(in: &playerSubscriptions)
            player.publisher(for: \.currentItem)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] item in self?.observe(item) }
                .store(in: &playerSubscriptions)
        }

        func record(_ event: String, detail: Int = 0) {
            let external = player?.isExternalPlaybackActive == true
            let route = AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .airPlay }
            logger
                .info(
                    "event=\(event, privacy: .public) detail=\(detail) external=\(external) airplayRoute=\(route) source=\(source, privacy: .public)",
                )
        }

        private func observe(_ item: AVPlayerItem?) {
            itemSubscriptions.removeAll()
            guard let item else { return }
            record("item-replaced")
            item.publisher(for: \.status).removeDuplicates()
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak item] status in
                    if status == .failed, let item {
                        self?.failure(item)
                    }
                }.store(in: &itemSubscriptions)
            for name in [
                AVPlayerItem.playbackStalledNotification,
                AVPlayerItem.newErrorLogEntryNotification,
                AVPlayerItem.failedToPlayToEndTimeNotification,
            ] {
                NotificationCenter.default.publisher(for: name, object: item)
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self, weak item] _ in
                        guard let self, let item else { return }
                        if name == AVPlayerItem.playbackStalledNotification {
                            record("stalled")
                        } else {
                            failure(item)
                        }
                    }.store(in: &itemSubscriptions)
            }
        }

        private func failure(_ item: AVPlayerItem) {
            let error = item.error as NSError?
            guard player?.currentItem === item else { return }
            let event = item.errorLog()?.events.last
            let http = AirPlayPlaybackPolicy.httpStatus(domain: event?.errorDomain, code: event?.errorStatusCode)
            let category: AirPlayPlaybackPolicy.Failure = if error?.domain == AVFoundationErrorDomain,
                                                             [
                                                                 AVError.Code.decoderNotFound.rawValue,
                                                                 AVError.Code.fileFormatNotRecognized.rawValue,
                                                                 AVError.Code.contentIsProtected.rawValue,
                                                             ].contains(error?.code ?? 0)
            {
                .incompatible
            } else {
                AirPlayPlaybackPolicy.failure(
                    domain: error?.domain ?? "",
                    code: error?.code ?? 0,
                    httpStatus: http,
                )
            }
            record(category.rawValue, detail: http ?? 0)
        }
    }
#endif
