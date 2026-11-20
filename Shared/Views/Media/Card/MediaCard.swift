import SwiftUI

struct MediaCard: View {
    @Environment(\.mediaCardIsInContinueWatching) private var isInContinueWatching
    @Environment(\.catalogBackdropSelection) private var catalogBackdrop
    @Environment(ServerRegistry.self) private var registry
    @Environment(MediaServices.self) private var scopedServices: MediaServices?
    #if os(tvOS)
        @Environment(MediaFocusModel.self) private var focusModel
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @FocusState private var isFocused: Bool
    #elseif os(macOS)
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var isFocused = false
    #endif

    let size: CGSize
    let media: MediaDisplayItem
    let artworkKind: MediaImageViewModel.ArtworkKind
    let showsLabels: Bool
    let onTap: () -> Void
    var compactResume = false

    private var progress: Double? {
        media.viewProgressPercentage.map { $0 / 100 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LayoutMetrics.cardLabelSpacing) {
            artwork
            #if os(tvOS) || os(macOS)
                .cardFocusStyle(isFocused: isFocused)
            #endif

            if showsLabels {
                if compactResume {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(media.primaryLabel).font(.subheadline.weight(.semibold)).lineLimit(1)
                        if media.playableItem?.type == .episode {
                            Text(episodeCaption)
                                .font(.caption).foregroundStyle(.textSecondary).lineLimit(1).truncationMode(.tail)
                        }
                    }
                } else {
                    labels
                    if episodeLabel != nil {
                        Text(episodeCaption).font(.caption).foregroundStyle(.textSecondary).lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            } else if episodeLabel != nil {
                Text(episodeCaption).font(.caption).foregroundStyle(.textSecondary).lineLimit(1).truncationMode(.tail)
            }
        }
        .frame(width: size.width, alignment: .leading)
        #if os(iOS)
            // Artwork is clipped and captions contain transparent space. Give the card's
            // tap and context-menu gestures one stable hit region across both children.
            .contentShape(Rectangle())
        #endif
            .offlineAvailability(of: media)
        #if os(tvOS)
            .focusable()
            .focused($isFocused)
            .onChange(of: isFocused) { _, focused in
                if focused, let playableItem = media.playableItem {
                    focusModel.focus(playableItem)
                }
            }
            .onPlayPauseCommand(perform: onTap)
        #elseif os(macOS)
            .contentShape(Rectangle())
            .onHover { isFocused = $0 }
        #endif
            .onTapGesture {
                if let media = media.playableItem {
                    catalogBackdrop?.select(media)
                }
                onTap()
            }
            .accessibilityIdentifier("catalog.card.\(media.playableItem?.id ?? media.primaryLabel)")
            .catalogBackdropCandidate(media.playableItem)
            .mediaCardContextMenu(media)
    }

    private var artwork: some View {
        ItemArtworkView(
            services: registry.services(for: media, scoped: scopedServices),
            kind: artworkKind,
            media: media,
        )
        .frame(width: size.width, height: size.height)
        .overlay(alignment: .bottomLeading) {
            if compactResume {
                ZStack(alignment: .bottomLeading) {
                    LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .center, endPoint: .bottom)
                    Label(compactRemainingTime ?? String(localized: "common.actions.resume"), systemImage: "play.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 20)
                }
            }
        }
        .mediaArtworkStyle()
        .overlay(alignment: .topTrailing) {
            WatchStatusBadge(media: media)
        }
        .downloadStatusOverlay(media)
        .artworkProgress(progress, hidePercentage: compactResume)
    }

    private var episodeLabel: String? {
        isInContinueWatching ? media.playableItem?.continueWatchingEpisodeLabel : nil
    }

    private var episodeCaption: String {
        if isInContinueWatching, let caption = media.playableItem?.continueWatchingEpisodeCaption {
            return caption
        }
        return media.cardSecondaryLabel(remainingTime: nil) ?? ""
    }

    private var compactRemainingTime: String? {
        RemainingTimeFormatter.compactText(
            duration: media.playableItem?.duration,
            viewOffset: media.playableItem?.viewOffset,
        )
    }

    private var labels: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(media.primaryLabel)
                .font(.cardTitle)
                .foregroundStyle(.textPrimary.opacity(titleOpacity))
                .lineLimit(1)
            Text(secondaryLabel ?? "")
                .font(.cardMetadata)
                .foregroundStyle(remainingTimeLine == .secondary ? .textTertiary : .textSecondary)
                .opacity(metadataOpacity)
                .lineLimit(1)
            Text(tertiaryLabel ?? "")
                .font(.cardMetadata)
                .foregroundStyle(remainingTimeLine == .tertiary ? .textTertiary : .textSecondary)
                .opacity(metadataOpacity)
                .lineLimit(1)
        }
        #if os(tvOS) || os(macOS)
        // Follows the bottom edge of the focused artwork so the lifted card does not cover its caption.
        .offset(y: isFocused && !reduceMotion ? size.height * (CardFocusStyle.focusedScale - 1) / 2 : 0)
        .animation(Motion.animation(Motion.focusScale, reduceMotion: reduceMotion), value: isFocused)
        #endif
    }

    private enum CaptionLine { case secondary, tertiary }

    private var remainingTimeText: String? {
        media.playableItem?.remainingTimeText
    }

    /// In-progress cards show the time left: after the episode number for episodes, in place of the year otherwise.
    private var remainingTimeLine: CaptionLine? {
        guard remainingTimeText != nil else { return nil }
        return media.playableItem?.type == .episode ? .tertiary : .secondary
    }

    private var secondaryLabel: String? {
        media.cardSecondaryLabel(remainingTime: remainingTimeLine == .secondary ? remainingTimeText : nil)
    }

    private var tertiaryLabel: String? {
        media.cardTertiaryLabel(remainingTime: remainingTimeLine == .tertiary ? remainingTimeText : nil)
    }

    private var titleOpacity: Double {
        #if os(tvOS)
            isFocused ? 1 : 0.45
        #else
            1
        #endif
    }

    /// Relative to `textSecondary`, so unfocused metadata lands at about a third of full white on tvOS.
    private var metadataOpacity: Double {
        #if os(tvOS)
            isFocused ? 1 : 0.32 / 0.65
        #else
            1
        #endif
    }
}

extension View {
    /// Download badge on artwork; tvOS has no downloads.
    func downloadStatusOverlay(_ media: MediaDisplayItem) -> some View {
        #if os(tvOS)
            self
        #else
            overlay(alignment: .bottomTrailing) {
                DownloadStatusBadge(media: media)
            }
        #endif
    }

    /// Greys out items that cannot be played while their server is unreachable; tvOS has no offline mode.
    func offlineAvailability(of media: MediaDisplayItem) -> some View {
        #if os(tvOS)
            self
        #else
            modifier(OfflineDimmingModifier(media: media, server: media.server))
        #endif
    }
}

/// Artwork of an item loaded through its server's services; a plain placeholder when the server is not available.
struct ItemArtworkView: View {
    let services: MediaServices?
    let kind: MediaImageViewModel.ArtworkKind
    let media: MediaDisplayItem

    var body: some View {
        if let services {
            MediaImageView(viewModel: MediaImageViewModel(services: services, artworkKind: kind, media: media))
        } else if let item = media.playableItem, CatalogMediaAdapter.selectionID(item) != nil {
            MediaImageView(viewModel: MediaImageViewModel(artworkKind: kind, media: media))
        } else {
            Rectangle()
                .fill(.gray.opacity(0.15))
        }
    }
}

struct CardProgressBar: View {
    let progress: Double

    var body: some View {
        Capsule(style: .continuous)
            .fill(.progressTrack)
            .frame(height: 4)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule(style: .continuous)
                        .fill(.progressFill)
                        .frame(width: proxy.size.width * min(max(progress, 0), 1))
                }
            }
            .accessibilityElement()
            .accessibilityValue(Text(progress, format: .percent.precision(.fractionLength(0))))
    }
}
