#if !os(tvOS)
    import SwiftUI

    /// Pages of featured titles at the top of the home, on iOS, iPadOS and macOS.
    struct HomeHeroCarousel: View {
        @Environment(\.scenePhase) private var scenePhase
        #if os(iOS)
            @Environment(SettingsManager.self) private var settingsManager
            @State private var preview = DirectTrailerPreview()
            @State private var settled = true
            @State private var covered = false
            @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
            private let network = TrailerNetworkState.shared
            private let trailerCoordinator = TrailerPlaybackCoordinator.shared
        #endif
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.accessibilityVoiceOverEnabled) private var isVoiceOverEnabled
        @Environment(\.dynamicTypeSize) private var dynamicTypeSize

        let slides: [HomeHeroSlide]
        /// Bumped by the home while the user scrolls it, which holds the pages still.
        let interactionCount: Int
        let onPlay: (MediaItem) -> Void
        let onDetails: (MediaItem) -> Void
        var onFeaturedChange: ((MediaItem?) -> Void)?
        var onVisibilityChange: ((Bool) -> Void)?
        var compact = false

        @State private var selection: MediaIdentity?
        @State private var restart = 0
        @State private var isVisible = true
        @State private var autoAdvanceStartedAt: Date?

        private static let autoAdvanceInterval: Duration = .seconds(8)

        var body: some View {
            ScrollView(.horizontal) {
                // Not lazy: a page built while an arrow scrolls to it would lay out inside that animation, its text
                // sliding in and the scroll coming to rest off the page.
                HStack(spacing: 0) {
                    ForEach(slides) { slide in
                        HomeHeroPage(slide: slide, onPlay: performPlay, onDetails: performDetails, compact: compact)
                        #if os(iOS)
                            .environment(\.heroTrailerPresentation, currentID == slide.id ? HeroTrailerPresentation(
                                preview: preview.active ? preview : nil,
                            ) : nil)
                        #endif
                            .containerRelativeFrame(.horizontal)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned(limitBehavior: .always))
            .scrollPosition(id: $selection, anchor: .leading)
            .onScrollPhaseChange { _, phase in
                #if os(iOS)
                    settled = phase == .idle
                    if phase != .idle {
                        preview.stop(); covered = false
                    }
                #endif
                if phase != .idle {
                    restart += 1
                }
            }
            .scrollIndicators(.never)
            .scrollClipDisabled()
            .onScrollVisibilityChange(threshold: 0.5) { isVisible = $0; onVisibilityChange?($0) }
            .containerRelativeFrame(.vertical) { height, _ in
                #if os(iOS)
                    if UIDevice.current.userInterfaceIdiom == .phone {
                        CGFloat(HomeHeroSizing.iPhoneHeight(availableHeight: Double(height)))
                    } else {
                        Self.height(for: height)
                    }
                #else
                    legacyHeight(for: height)
                #endif
            }
            .overlay(alignment: .bottom) {
                if slides.count > 1 {
                    pageIndicator
                        .padding(.bottom, 12)
                }
            }
            #if os(macOS)
            .simultaneousGesture(pageDrag)
            .overlay {
                if slides.count > 1 {
                    pageArrows
                }
            }
            #endif
            .onChange(of: slides) { _, slides in
                if let selection, !slides.contains(where: { $0.id == selection }) {
                    self.selection = slides.first?.id
                }
            }
            .onChange(of: currentID, initial: true) { _, id in
                #if os(iOS)
                    preview.stop()
                #endif
                onFeaturedChange?(slides.first { $0.id == id }?.media)
            }
            .onChange(of: interactionCount) {
                restart += 1
            }
            .task(id: AutoAdvanceKey(
                slide: currentID,
                restart: restart,
                isActive: isVisible && scenePhase == .active && !reduceMotion && !isVoiceOverEnabled && canAdvance,
            )) {
                await autoAdvance()
            }
            #if os(iOS)
            .task(id: previewKey) { await preparePreview() }
            .onAppear { isVisible = true; covered = false }
            .onDisappear { isVisible = false; preview.stop() }
            .onChange(of: scenePhase) {
                _, phase in if phase != .active {
                    preview.stop()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
                lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
                if lowPower {
                    preview.stop()
                }
            }
            #endif
        }

        private var canAdvance: Bool {
            #if os(iOS)
                !preview.active && !covered && !trailerCoordinator.manualTrailerActive && !trailerCoordinator
                    .featurePlaybackActive
            #else
                true
            #endif
        }

        private func performPlay(_ media: MediaItem) {
            #if os(iOS)
                covered = true; preview.stop()
            #endif
            onPlay(media)
        }

        private func performDetails(_ media: MediaItem) {
            #if os(iOS)
                covered = true; preview.stop()
            #endif
            onDetails(media)
        }

        #if os(iOS)
            private var currentSlide: HomeHeroSlide? {
                slides.first { $0.id == currentID }
            }

            private var directStream: AuthorizedTrailerStream? {
                guard let slide = currentSlide, let stream = slide.authorizedTrailer,
                      let kind = PlayerTitleLogoIdentity(media: slide.media).kind,
                      let id = PlayerTitleLogoIdentity(media: slide.media).tmdbID,
                      stream.catalogID == "\(kind.rawValue):\(id)" else { return nil }
                return stream
            }

            private var previewAllowed: Bool {
                TrailerPreviewPolicy.allowsAutoplay(
                    enabled: settingsManager.playback.automaticTrailerPreviews && currentSlide?.isResume == false,
                    visible: isVisible && !covered, active: scenePhase == .active, settled: settled,
                    reduceMotion: reduceMotion || isVoiceOverEnabled, lowPower: lowPower,
                    connected: network.connected, expensive: network.expensive, constrained: network.constrained,
                    allowsCellular: settingsManager.playback.trailerPreviewsOnCellular,
                    anotherPlayerActive: trailerCoordinator.featurePlaybackActive || trailerCoordinator
                        .manualTrailerActive,
                )
            }

            private struct PreviewKey: Equatable {
                let media: MediaIdentity?
                let restart: Int
                let stream: AuthorizedTrailerStream?
                let allowed: Bool
            }

            private var previewKey: PreviewKey {
                PreviewKey(media: currentID, restart: restart, stream: directStream, allowed: previewAllowed)
            }

            private func preparePreview() async {
                preview.stop()
                guard previewAllowed, let stream = directStream else { return }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard !Task.isCancelled, previewAllowed, directStream == stream else { return }
                preview.start(stream)
            }

        #endif

        private func legacyHeight(for height: CGFloat) -> CGFloat {
            compact
                ? min(
                    max(height * 0.38, dynamicTypeSize.isAccessibilitySize ? 420 : 280),
                    dynamicTypeSize.isAccessibilitySize ? 520 : 340,
                )
                : Self.height(for: height)
        }

        /// A large share of an iPhone in portrait, capped where the screen is tall or wide.
        private static func height(for available: CGFloat) -> CGFloat {
            #if os(iOS)
                UIDevice.current.userInterfaceIdiom == .pad
                    ? min(available * 0.6, 560)
                    : min(available * 0.7, 620)
            #else
                min(available * 0.6, 560)
            #endif
        }

        private var currentID: MediaIdentity? {
            selection ?? slides.first?.id
        }

        private var currentIndex: Int {
            currentID.flatMap { id in slides.firstIndex { $0.id == id } } ?? 0
        }

        private var pageIndicator: some View {
            HStack(spacing: 8) {
                ForEach(slides.indices, id: \.self) { index in
                    if index == currentIndex {
                        AutoAdvanceProgressCapsule(startedAt: autoAdvanceStartedAt, interval: Self.autoAdvanceInterval)
                            .frame(width: 28, height: 7)
                    } else {
                        Capsule()
                            .fill(.textTertiary)
                            .frame(width: 7, height: 7)
                    }
                }
            }
            .accessibilityElement()
            .accessibilityLabel(Text("home.hero.page \(currentIndex + 1) \(slides.count)"))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: show(currentIndex + 1)
                case .decrement: show(currentIndex - 1)
                @unknown default: break
                }
            }
        }

        #if os(macOS)
            private var pageArrows: some View {
                HStack {
                    arrow("chevron.left", label: "home.hero.previous") { show(currentIndex - 1) }
                    Spacer()
                    arrow("chevron.right", label: "home.hero.next") { show(currentIndex + 1) }
                }
                .padding(.horizontal, 16)
            }

            /// A click-drag turns the page on release, as a swipe does on a trackpad.
            private var pageDrag: some Gesture {
                DragGesture(minimumDistance: 10)
                    .onEnded { value in
                        let distance = value.predictedEndTranslation.width
                        if distance < -80 {
                            show(currentIndex + 1)
                        } else if distance > 80 {
                            show(currentIndex - 1)
                        }
                    }
            }

            private func arrow(_ symbol: String, label: LocalizedStringKey, action: @escaping () -> Void)
                -> some View
            {
                Button(action: action) {
                    Image(systemName: symbol)
                        .font(.title2.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .glassSurface(in: Circle())
                }
                .buttonStyle(.plain)
                .hoverLift()
                .accessibilityLabel(Text(label))
            }
        #endif

        private func show(_ index: Int) {
            guard !slides.isEmpty else { return }
            let wrapped = (index % slides.count + slides.count) % slides.count
            withAnimation(Motion.animation(Motion.showcase, reduceMotion: reduceMotion)) {
                selection = slides[wrapped].id
            }
            restart += 1
        }

        private struct AutoAdvanceKey: Equatable {
            let slide: MediaIdentity?
            let restart: Int
            let isActive: Bool
        }

        private func autoAdvance() async {
            guard isVisible, scenePhase == .active, !reduceMotion, !isVoiceOverEnabled, canAdvance,
                  slides.count > 1
            else {
                autoAdvanceStartedAt = nil
                return
            }
            autoAdvanceStartedAt = Date()
            try? await Task.sleep(for: Self.autoAdvanceInterval)
            guard !Task.isCancelled else { return }
            show(currentIndex + 1)
        }
    }

    private struct HomeHeroPage: View {
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        #if os(iOS)
            @Environment(\.heroTrailerPresentation) private var trailerPresentation
        #endif
        @Environment(\.horizontalSizeClass) private var horizontalSizeClass

        let slide: HomeHeroSlide
        let onPlay: (MediaItem) -> Void
        let onDetails: (MediaItem) -> Void
        var compact = false

        var body: some View {
            ZStack(alignment: .bottomLeading) {
                HomeHeroArtwork(media: slide.media)
                    // Fades the artwork out rather than painting a color over it, so it melts into
                    // whatever background the home has.
                    .mask(Self.fadeMask)
                    // Stretches when the home is pulled down.
                    .visualEffect { content, proxy in
                        let pull = max(0, proxy.frame(in: .scrollView(axis: .vertical)).minY)
                        return content.scaleEffect(
                            1 + pull / max(proxy.size.height, 1),
                            anchor: .bottom,
                        )
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { onDetails(slide.media) }

                #if os(iOS)
                    if let preview = trailerPresentation?.preview {
                        TrailerPreviewSurface(preview: preview).id(preview.generation)
                            .opacity(preview.ready ? 1 : 0)
                            .animation(reduceMotion ? nil : .easeInOut(duration: 0.6), value: preview.ready)
                            .mask(Self.fadeMask)
                            .allowsHitTesting(false)
                    }
                #endif

                details
                    .padding(.horizontal, LayoutMetrics.pageMargin)
                    .padding(.bottom, compact ? 30 : 36)
            }
            #if os(iOS)
            .overlay(alignment: .bottomTrailing) {
                if let preview = trailerPresentation?.preview, preview.ready {
                    Button { preview.toggleMute() } label: {
                        Image(systemName: preview.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .padding(10).background(.ultraThinMaterial, in: Circle())
                    }.buttonStyle(.plain).padding(.trailing, 16).padding(.bottom, 34)
                        .accessibilityLabel(preview.muted ? "Unmute trailer preview" : "Mute trailer preview")
                }
            }
            #endif
            .clipped()
            .accessibilityElement(children: .contain)
        }

        private var details: some View {
            VStack(alignment: .leading, spacing: compact ? 6 : 10) {
                if let eyebrow = slide.eyebrow {
                    Text(eyebrow)
                        .eyebrowStyle()
                        .foregroundStyle(.textSecondary)
                }

                TitleLogoView(media: slide.media, maxSize: logoSize, hugsLogo: true)

                MediaFactsLine(
                    facts: MediaFactsFormatter.facts(for: slide.media, namesStandardEdition: false),
                    badges: [],
                )
                .lineLimit(1)

                if slide.isResume, let progress = slide.media.viewProgressPercentage {
                    ProgressView(value: progress, total: 100)
                        .tint(.progressFill)
                        .frame(maxWidth: 240)
                }

                HStack(spacing: 12) {
                    Button { onPlay(slide.media) } label: {
                        Label(
                            slide.isResume ? "common.actions.resume" : "common.actions.play",
                            systemImage: "play.fill",
                        )
                    }
                    .actionButtonStyle(.primary)

                    Button { onDetails(slide.media) } label: {
                        Label("home.hero.moreInfo", systemImage: "info.circle")
                    }
                    .actionButtonStyle(.secondary)
                }
                .padding(.top, 4)
                .controlSize(horizontalSizeClass == .compact ? .small : .regular)
            }
            .frame(maxWidth: 520, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(slide.accessibilityLabel)
        }

        /// A smoothstep from 40% of the height down to the bottom edge, so the fade has no visible start or end.
        private static let fadeMask = LinearGradient(
            stops: [
                .init(color: .white, location: 0.4),
                .init(color: .white.opacity(0.93), location: 0.5),
                .init(color: .white.opacity(0.74), location: 0.6),
                .init(color: .white.opacity(0.5), location: 0.7),
                .init(color: .white.opacity(0.26), location: 0.8),
                .init(color: .white.opacity(0.07), location: 0.9),
                .init(color: .clear, location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom,
        )

        private var logoSize: CGSize {
            horizontalSizeClass == .compact ? CGSize(width: 260, height: compact ? 64 : 90) : CGSize(
                width: 360,
                height: 120,
            )
        }
    }

    /// The backdrop of a hero page; an episode shows its series backdrop.
    private struct HomeHeroArtwork: View {
        @Environment(ServerRegistry.self) private var registry
        @Environment(SettingsManager.self) private var settingsManager

        let media: MediaItem

        @State private var resource: ArtworkResource?

        var body: some View {
            Color.surfaceSubtle
                .overlay {
                    if let resource {
                        ArtworkResourceView(resource: resource)
                            .transition(.opacity)
                    }
                }
                .clipped()
                .task(id: "\(media.id)-\(spoilerProtection.rawValue)") {
                    resource = nil
                    guard let path = artworkPath else { return }
                    let loaded: ArtworkResource? = if let services = registry.services(for: media.identity.server) {
                        try? await services.artwork.artwork(path: path, width: 1920, height: 1080)
                    } else if CatalogMediaAdapter.selectionID(media) != nil,
                              let url = CatalogMediaAdapter.artworkURL(path)
                    {
                        .url(url)
                    } else {
                        nil
                    }
                    guard let loaded, !Task.isCancelled else { return }
                    withAnimation(Motion.crossfade) {
                        resource = loaded
                    }
                }
        }

        private var spoilerProtection: SpoilerProtectionLevel {
            settingsManager.interface.spoilerProtection
        }

        /// A protected episode never falls back to its own artwork.
        private var artworkPath: String? {
            if media.isSpoilerProtected(at: spoilerProtection) {
                return media.spoilerProtectedArtworkPath(at: spoilerProtection)
            }
            return media.grandparentArtPath ?? media.artPath
        }
    }
#endif
