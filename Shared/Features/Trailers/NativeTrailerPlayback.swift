#if os(iOS)
    import AVFoundation
    import AVKit
    import Network
    import Observation
    import SwiftUI
    import WebKit

    @MainActor @Observable
    final class TrailerNetworkState {
        static let shared = TrailerNetworkState()
        private(set) var connected = false
        private(set) var expensive = true
        private(set) var constrained = true
        private let monitor = NWPathMonitor()
        init() {
            monitor.pathUpdateHandler = { [weak self] path in
                let connected = path.status == .satisfied
                let expensive = path.isExpensive || path.usesInterfaceType(.cellular)
                let constrained = path.isConstrained
                Task { @MainActor [weak self] in
                    self?.connected = connected; self?.expensive = expensive; self?.constrained = constrained
                }
            }
            monitor.start(queue: DispatchQueue(label: "strimr.trailer.network"))
        }
    }

    struct TrailerPreviewSurface: UIViewRepresentable {
        let preview: DirectTrailerPreview
        func makeUIView(context _: Context) -> Surface {
            let view = Surface()
            let generation = preview.generation
            view.playerLayer.player = preview.player
            view.playerLayer.videoGravity = .resizeAspectFill
            view.observation = view.playerLayer.observe(\.isReadyForDisplay, options: [
                .initial,
                .new,
            ]) { [weak preview] layer, _ in
                let ready = layer.isReadyForDisplay
                Task { @MainActor in
                    guard let preview, preview.generation == generation, preview.active else { return }
                    preview.ready = ready
                }
            }
            return view
        }

        func updateUIView(_: Surface, context _: Context) {}
        static func dismantleUIView(_ uiView: Surface, coordinator _: Void) {
            uiView.observation = nil; uiView.playerLayer.player = nil
        }

        final class Surface: UIView {
            override class var layerClass: AnyClass {
                AVPlayerLayer.self
            }

            var playerLayer: AVPlayerLayer {
                layer as! AVPlayerLayer
            }

            var observation: NSKeyValueObservation?
        }
    }

    @MainActor @Observable
    private final class ManualTrailerSession {
        let owner = UUID()
        var player: AVPlayer?
        var error: String?
        private(set) var active = false
        @ObservationIgnored weak var webView: WKWebView?
        @ObservationIgnored private var statusObserver: NSKeyValueObservation?
        func start(_ selection: TrailerSelection) {
            guard !active else { return }
            error = nil
            guard TrailerPlaybackCoordinator.shared.claim(owner, manual: true, stop: { [weak self] in self?.stop() })
            else {
                error = "Stop movie or TV playback before opening a trailer."; return
            }
            active = true
            if case let .direct(stream) = selection.source {
                player = AVPlayer(url: stream.url)
                player?.audiovisualBackgroundPlaybackPolicy = .pauses
                statusObserver = player?.currentItem?.observe(\.status, options: [
                    .initial,
                    .new,
                ]) { [weak self] item, _ in
                    let failed = item.status == .failed
                    if failed {
                        Task { @MainActor in
                            self?.error = "The authorized trailer stream could not play. Try again or choose another provider."
                            self?.player?.pause()
                        }
                    }
                }
                player?.play()
            }
        }

        func pause() {
            player?.pause()
            webView?.pauseAllMediaPlayback(completionHandler: nil)
            webView?.evaluateJavaScript("pauseTrailer()", completionHandler: nil)
        }

        func stop() {
            statusObserver = nil
            active = false; pause(); player?.replaceCurrentItem(with: nil); player = nil
            webView?.setAllMediaPlaybackSuspended(true, completionHandler: nil)
            webView?.stopLoading(); webView?.loadHTMLString("", baseURL: nil)
            TrailerPlaybackCoordinator.shared.release(owner)
        }
    }

    /// Deliberately separate from the feature player: trailers never scrobble or create resume checkpoints.
    struct TrailerFullscreenView: View {
        @Environment(\.dismiss) private var dismiss
        @Environment(\.scenePhase) private var phase
        let selection: TrailerSelection
        @State private var session = ManualTrailerSession()
        var body: some View {
            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: 12) {
                        HStack {
                            Button("Done") { dismiss() }.accessibilityIdentifier("trailer.close")
                            Spacer()
                            Text("Trailer · " + selection.title).font(.headline).lineLimit(2)
                                .accessibilityIdentifier("trailer.title")
                            Spacer()
                        }.padding(.horizontal).padding(.top, 8)
                        #if DEBUG && targetEnvironment(simulator)
                            if CatalogVisualFixtures.isEnabled {
                                Text("SIMULATOR · FIXTURE DATA").font(.caption).foregroundStyle(.orange)
                            }
                        #endif
                        if let error = session.error {
                            Text(error).font(.footnote).foregroundStyle(.secondary).padding()
                            Button("Retry Trailer") { session.stop(); session.start(selection) }
                        } else if session.active {
                            if let player = session.player {
                                VideoPlayer(player: player)
                                    .frame(height: max(200, geometry.size.height - 100))
                            } else {
                                TrailerWebPlayer(source: selection.source, session: session)
                                    .frame(
                                        width: geometry.size.width,
                                        height: max(
                                            200,
                                            min(geometry.size.height - 120, geometry.size.width * 9 / 16),
                                        ),
                                    )
                            }
                        }
                        if let url = selection.source.externalURL {
                            Link("Open on Trailer Provider", destination: url).font(.footnote)
                            Text("Provider playback restrictions and advertisements may apply.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(minHeight: geometry.size.height, alignment: .top)
                    .padding(.bottom, 12)
                }
            }
            .background(.black).preferredColorScheme(.dark)
            .onAppear { session.start(selection) }
            .onDisappear { session.stop() }
            .onChange(of: phase) {
                _, value in if value != .active {
                    session.pause()
                }
            }
        }
    }

    private struct TrailerWebPlayer: UIViewRepresentable {
        let source: TrailerSource
        let session: ManualTrailerSession
        func makeCoordinator() -> Coordinator {
            Coordinator(session: session)
        }

        func makeUIView(context: Context) -> WKWebView {
            let configuration = WKWebViewConfiguration()
            configuration.allowsInlineMediaPlayback = true
            configuration.mediaTypesRequiringUserActionForPlayback = .all
            configuration.userContentController.add(context.coordinator, name: "trailer")
            let view = WKWebView(frame: .zero, configuration: configuration)
            view.navigationDelegate = context.coordinator
            view.scrollView.isScrollEnabled = false
            view.isOpaque = false; view.backgroundColor = .black
            session.webView = view
            if let origin = TrailerEmbedConfiguration
                .origin(bundleID: Bundle.main.bundleIdentifier ?? "app.strimr.ios"),
               let html = TrailerEmbedConfiguration.html(source: source, origin: origin)
            {
                view.loadHTMLString(html, baseURL: origin)
            } else {
                session.error = "This trailer cannot be embedded. Open it on the provider instead."
            }
            return view
        }

        func updateUIView(_: WKWebView, context _: Context) {}
        static func dismantleUIView(_ uiView: WKWebView, coordinator _: Coordinator) {
            uiView.configuration.userContentController.removeScriptMessageHandler(forName: "trailer")
            uiView.stopLoading(); uiView.loadHTMLString("", baseURL: nil)
        }

        final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
            weak var session: ManualTrailerSession?
            init(session: ManualTrailerSession) {
                self.session = session
            }

            func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
                if let message = message
                    .body as? String
                {
                    session?.error = message + ". Open on the provider if embedding is restricted."
                }
            }

            func webView(_: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: Error) {
                session?.error = "Trailer could not load: " + error.localizedDescription
            }

            func webView(_: WKWebView, didFail _: WKNavigation!, withError error: Error) {
                session?.error = "Trailer playback could not load: " + error.localizedDescription
            }
        }
    }
#endif
