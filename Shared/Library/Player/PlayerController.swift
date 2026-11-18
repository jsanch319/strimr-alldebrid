import AetherEngine
import AVFoundation
import Combine
import CoreGraphics
import Foundation
import Observation
import SwiftAssRenderer
import SwiftUI
#if os(iOS)
    import UIKit
#endif

struct PlayerScrubPreview {
    var position: Double
    var image: CGImage?
}

@MainActor
@Observable
final class PlayerController {
    fileprivate let engine: AetherEngine

    var isPaused = false
    var isBuffering = false
    var duration: Double?
    var position = 0.0
    var sourcePosition = 0.0
    var bufferedAhead = 0.0
    var isLive = false
    var liveEdgeTime = 0.0
    var behindLiveSeconds = 0.0
    var isAtLiveEdge = true
    var seekableLiveRange: ClosedRange<Double>?
    var sourceVideoSize: CGSize?
    private(set) var displayVideoSize: CGSize?
    private(set) var videoZoom = VideoZoom.fit
    @ObservationIgnored private var videoZoomContext: String?
    var videoFormatBadge: PlayerVideoFormatBadge?
    var subtitleCues: [SubtitleCue] = []
    var subtitleMaxCueDuration = 60.0
    var assRenderer: AssSubtitlesRenderer?
    var activeSubtitleCodec: String?
    @ObservationIgnored private var handoffResumeTask: Task<Void, Never>?
    @ObservationIgnored private var handoffToken = UUID()
    @ObservationIgnored private weak var continuityItem: AVPlayerItem?
    var resumeTarget: Double? {
        resumeVerification?.target
    }

    @ObservationIgnored private var completedResumeTransportIntent: Bool?
    var resumeTransportIntent: Bool? {
        resumeVerification?.requestedPause ?? completedResumeTransportIntent
    }

    func consumeResumeTransportIntent() -> Bool? {
        let intent = resumeTransportIntent
        completedResumeTransportIntent = nil
        return intent
    }

    var resumeRecoveryMessage: String?
    private(set) var resumeVerifiedPosition: Double?
    @ObservationIgnored private var resumeVerification: ResumeVerification?
    @ObservationIgnored private let nativeResumeClock = NativeResumeClock()
    @ObservationIgnored private var resumeVerificationToken = UUID()
    @ObservationIgnored private var resumeSeekTask: Task<Void, Never>?
    @ObservationIgnored private var landedSeekPosition: Double?
    @ObservationIgnored private var isLoadingSource = false
    var errorMessage: String?
    #if os(iOS) || os(macOS)
        var showsPictureInPictureControl = false
        var isPictureInPictureAvailable = false
        var isPictureInPictureActive = false
        var isPictureInPictureTransitioning = false
        @ObservationIgnored var onPictureInPictureStartFailed: (() -> Void)?
        @ObservationIgnored var onPictureInPictureRestoreRequested: (() -> Void)?
    #endif
    private(set) var scrubPreview: PlayerScrubPreview?
    private(set) var audioDelayMilliseconds = 0
    private(set) var subtitleDelayMilliseconds = 0
    private(set) var isApplyingAudioDelay = false
    private(set) var audioShaping = AudioShaping()
    private(set) var audioShapingState: AudioShapingState = .off
    private(set) var videoRoute: VideoRoute = .none
    private(set) var audioTrackRevision = 0
    @ObservationIgnored private var nativeAudioSelection: NativeAudioSelection?
    private(set) var selectedSubtitleTrackID: Int?
    private(set) var volume: Float = 1.0
    private(set) var isCoordinatedPlayback = false

    func setVideoZoom(_ zoom: VideoZoom) {
        videoZoom = zoom
    }

    func prepareVideoZoom(for context: String?, persistedMode: PlayerVideoScaleMode) {
        videoZoom = VideoZoom.carriedOver(
            videoZoom,
            from: videoZoomContext,
            to: context,
            persistedMode: persistedMode,
        )
        videoZoomContext = context
    }

    var isMuted: Bool {
        volume == 0
    }

    /// Where subtitles are drawn from: the source time moved by the subtitle delay.
    var subtitlePosition: Double {
        sourcePosition - Double(subtitleDelayMilliseconds) / 1000
    }

    var audioDelayAvailability: PlaybackOffsetAvailability {
        .audio(
            isNativeBypass: videoRoute == .remoteBypass,
            isAudioOnly: videoRoute == .audio,
            isLiveWithoutDVR: isLive && !hasLiveDVRWindow && seekableLiveRange == nil,
        )
    }

    /// AVPlayer owns the audio on the native bypass, so the engine has no PCM to shape there.
    var isAudioShapingAvailable: Bool {
        videoRoute != .remoteBypass && audioShapingState != .unavailable
    }

    func subtitleDelayAvailability(burnsSubtitles: Bool) -> PlaybackOffsetAvailability {
        .subtitles(
            isNativeBypass: videoRoute == .remoteBypass,
            burnsSubtitles: burnsSubtitles,
            hasActiveSubtitleTrack: selectedSubtitleTrackID != nil,
        )
    }

    @ObservationIgnored var onMediaLoaded: (() -> Void)?
    /// The engine could not demux a live stream it read itself; the server-transcoded route may still play it.
    @ObservationIgnored var onLiveDemuxFailure: ((Error) -> Void)?
    @ObservationIgnored var onPlaybackEnded: (() -> Void)?

    @ObservationIgnored private var cancellables: Set<AnyCancellable> = []
    @ObservationIgnored private var coordinatedPlaybackIdentifier: String?
    @ObservationIgnored private var isCatalogSharePlayItem = false
    @ObservationIgnored private var hasStartedPlayback = false
    @ObservationIgnored private var isStopping = false
    @ObservationIgnored private var playbackRate: Float = 1.0
    @ObservationIgnored private var styledASSSubtitles = true
    @ObservationIgnored private var mediaIdentifier = "media"
    @ObservationIgnored private var hasLiveDVRWindow = false
    @ObservationIgnored private var audioDelayDispatch = AudioDelayDispatch()
    @ObservationIgnored private var audioDelayDispatchTask: Task<Void, Never>?
    @ObservationIgnored private var audioDelayApplyPhase = AudioDelayApplyPhase.idle
    @ObservationIgnored private var audioDelayApplyTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var providerStreamIDsByFFIndex: [Int: Int] = [:]
    @ObservationIgnored private var externalSubtitleProviderStreamIDs: [Int: Int] = [:]
    @ObservationIgnored private var sidecarASSHeaderCancellable: AnyCancellable?
    @ObservationIgnored private lazy var assCoordinator = ASSRenderCoordinator(engine: engine)
    @ObservationIgnored private var nowPlayingController: NowPlayingController?
    @ObservationIgnored private let trailerPlaybackOwner = UUID()
    #if os(iOS)
        @ObservationIgnored private let airPlayDiagnostics = AirPlayDiagnostics()
        @ObservationIgnored private var remoteInterruptionToken: UUID?
        @ObservationIgnored private var remoteInterruptionLoadGeneration: UUID?
        @ObservationIgnored private var backgroundRestoreTask: Task<Void, Never>?
        @ObservationIgnored private var backgroundRestoreResumesPlayback = false
    #endif
    @ObservationIgnored private var lastAudibleVolume: Float = 1.0
    @ObservationIgnored private var volumeAttenuation: Float = 1.0
    @ObservationIgnored private var pendingSeekTarget: Double?
    @ObservationIgnored private var continuity = PlaybackContinuity()
    @ObservationIgnored private var loadGeneration = UUID()
    @ObservationIgnored private var scrubThumbnailTask: Task<Void, Never>?
    @ObservationIgnored private var scrubAetherTask: Task<Void, Never>?
    @ObservationIgnored private var scrubExtractorDwellTask: Task<Void, Never>?
    @ObservationIgnored private var scrubThumbnailPreparationTask: Task<Void, Never>?
    @ObservationIgnored private var scrubThumbnailProvider: (any ScrubThumbnailProviding)?
    @ObservationIgnored private var scrubFrameExtractor: FrameExtractor?
    @ObservationIgnored private var scrubExtractorRequestGeneration: Int?
    @ObservationIgnored private var scrubGeneratedThumbnailCache: [Int: CGImage] = [:]
    @ObservationIgnored private var scrubGeneratedThumbnailOrder: [Int] = []
    @ObservationIgnored private var scrubPreviewGeneration = 0
    @ObservationIgnored private var activeScrubBucket: Int?
    @ObservationIgnored private var isScrubPreviewing = false
    @ObservationIgnored private var showsScrubThumbnailPreviews = true
    @ObservationIgnored private var generatesMissingScrubThumbnailPreviews = true
    @ObservationIgnored private var showsSubtitlesOnSkipBack = false
    @ObservationIgnored private var skipBackSubtitles = SkipBackSubtitles()
    #if os(iOS) || os(macOS)
        @ObservationIgnored private lazy var pictureInPictureCoordinator = PictureInPictureCoordinator(engine: engine)
    #endif

    private let scrubBucketDuration = 10.0
    private let unavailableThumbnailExtractorDelay: Duration = .milliseconds(250)
    private let failedThumbnailExtractorDelay: Duration = .milliseconds(450)
    private let pendingThumbnailExtractorDelay: Duration = .milliseconds(800)
    private let extractorAvailabilityPollInterval: Duration = .milliseconds(50)
    private let scrubThumbnailWidth = 320
    private let scrubGeneratedThumbnailCacheLimit = 32

    init() {
        do {
            engine = try AetherEngine()
        } catch {
            fatalError("Failed to initialize player engine: \(error)")
        }
        nowPlayingController = NowPlayingController(
            engine: engine,
            commands: NowPlayingController.Commands(
                play: { [weak self] in self?.resume() },
                pause: { [weak self] in self?.pause() },
                togglePlayPause: { [weak self] in self?.togglePlayback() },
                skip: { [weak self] seconds in self?.seek(by: seconds) },
                seek: { [weak self] position in self?.seek(to: position) },
            ),
        )

        observeEngine()
        #if os(iOS) || os(macOS)
            configurePictureInPicture()
        #endif
    }

    func load(
        url: URL,
        httpHeaders: [String: String] = [:],
        startPosition: Double?,
        preferredAudioTrackID: Int?,
        preferredAudioLanguages: [String] = [],
        losslessAudio: Bool,
        readAhead: PlaybackReadAhead = .standard,
        spatialAudioLayout: SpatialSpeakerLayout?,
        styledASSSubtitles: Bool,
        mediaIdentifier: String,
        providerStreamIDsByFFIndex: [Int: Int],
        externalSubtitles: [PlayerExternalSubtitle],
        scrubThumbnailSource: ScrubThumbnailSource? = nil,
        showsScrubThumbnailPreviews: Bool = true,
        generatesMissingScrubThumbnailPreviews: Bool = true,
        showsSubtitlesOnSkipBack: Bool = false,
        live: LiveLoadOptions? = nil,
        audioDelayMilliseconds: Int = 0,
        audioShaping: AudioShaping = AudioShaping(),
        autoplay: Bool = true,
        nowPlaying: NowPlayingItem? = nil,
    ) {
        #if os(iOS)
            remoteInterruptionToken = nil
            airPlayDiagnostics.setSource(url)
        #endif
        cancelResumeVerification()
        isLoadingSource = true
        loadGeneration = UUID()
        let generation = loadGeneration
        if isCatalogSharePlayItem {
            continuity.beginTransition()
        } else {
            continuity.reset(to: startPosition ?? 0)
        }
        position = continuity.position
        deactivateASSRendering()
        resetScrubPreviewSession()
        self.showsScrubThumbnailPreviews = showsScrubThumbnailPreviews
        self.generatesMissingScrubThumbnailPreviews = generatesMissingScrubThumbnailPreviews
        self.showsSubtitlesOnSkipBack = showsSubtitlesOnSkipBack
        skipBackSubtitles.cancel()
        if showsScrubThumbnailPreviews {
            scrubThumbnailProvider = scrubThumbnailSource.map { source in
                switch source {
                case let .plex(source):
                    PlexBIFThumbnailProvider(source: source)
                case let .jellyfin(source):
                    JellyfinTrickplayThumbnailProvider(source: source)
                }
            }
        }
        isStopping = false
        hasStartedPlayback = false
        pendingSeekTarget = nil
        nativeAudioSelection = nil
        selectedSubtitleTrackID = nil
        subtitleCues = []
        sourceVideoSize = nil
        displayVideoSize = nil
        activeSubtitleCodec = nil
        self.styledASSSubtitles = styledASSSubtitles
        if mediaIdentifier != self.mediaIdentifier {
            setSubtitleDelay(milliseconds: 0)
        }
        self.mediaIdentifier = mediaIdentifier
        let isLive = live != nil
        hasLiveDVRWindow = (live?.dvrWindowSeconds ?? 0) > 0
        cancelPendingAudioDelay()
        self.audioDelayMilliseconds = PlaybackOffsetRange.audio.clamp(audioDelayMilliseconds)
        let audioDelaySeconds = PlaybackOffset(milliseconds: self.audioDelayMilliseconds).seconds
        self.audioShaping = audioShaping.clamped
        self.providerStreamIDsByFFIndex = providerStreamIDsByFFIndex
        externalSubtitleProviderStreamIDs = [:]
        errorMessage = nil
        TrailerPlaybackCoordinator.shared.beginFeature(trailerPlaybackOwner)
        nowPlayingController?.begin(nowPlaying, isLive: isLive)

        Task { @MainActor [weak self] in
            guard let self, loadGeneration == generation else { return }
            do {
                let sourceProbe = try await engine.load(
                    url: url,
                    startPosition: startPosition,
                    options: LoadOptions(
                        httpHeaders: httpHeaders,
                        audioBridgeMode: losslessAudio ? .lossless : .surroundCompat,
                        objectAudioRendering: spatialAudioLayout.map { .apac($0) } ?? .off,
                        isLive: isLive,
                        dvrWindowSeconds: live?.dvrWindowSeconds,
                        liveJoinProfile: .fastZap,
                        liveJoinStartsImmediately: live?.startsImmediately ?? true,
                        nativeRemoteHLS: live?.nativeRemoteHLS ?? false,
                        preserveASSMarkup: true,
                        prepareNativeSubtitles: Self.preparesNativeSubtitles,
                        probesize: live?.probesize,
                        maxAnalyzeDuration: live?.maxAnalyzeDuration,
                        preferredAudioLanguages: preferredAudioLanguages
                            .isEmpty ? (live?.preferredAudioLanguages ?? []) : preferredAudioLanguages,
                        externalSubtitles: externalSubtitles.map(\.track),
                        forwardBufferSegments: isLive ? nil : readAhead.forwardBufferSegments,
                        softwarePacketCacheStorage: isLive ? .automatic : readAhead.softwarePacketCacheStorage,
                        autoplay: autoplay && (live?.autoplay ?? true),
                        audioDelaySeconds: audioDelaySeconds,
                        audioShaping: audioShaping,
                        preferredDecodePath: live?.preferredDecodePath ?? .automatic,
                    ),
                    audioSourceStreamIndex: preferredAudioTrackID.map(Int32.init),
                )
                guard loadGeneration == generation, !Task.isCancelled else { return }
                isLoadingSource = false
                if autoplay, live?.autoplay == false {
                    engine.play()
                }
                if let sourceProbe,
                   sourceProbe.videoWidth > 0,
                   sourceProbe.videoHeight > 0
                {
                    sourceVideoSize = CGSize(
                        width: Int(sourceProbe.videoWidth),
                        height: Int(sourceProbe.videoHeight),
                    )
                }
                await refreshNativeAudioSelection()
                guard loadGeneration == generation, !Task.isCancelled else { return }
                let externalEngineTracks = engine.subtitleTracks.filter(\.isExternal)
                if externalEngineTracks.count == externalSubtitles.count {
                    externalSubtitleProviderStreamIDs = Dictionary(
                        uniqueKeysWithValues: zip(externalEngineTracks, externalSubtitles).map {
                            ($0.id, $1.providerStreamID)
                        },
                    )
                } else {
                    ErrorReporter.capture(ExternalSubtitleTrackMappingError())
                }
                if !isCoordinatedPlayback {
                    engine.setRate(playbackRate)
                }
                if !engine.isLive, let scrubThumbnailProvider {
                    scrubThumbnailPreparationTask = Task {
                        await scrubThumbnailProvider.prepare()
                    }
                }
                nowPlayingController?.playbackDidLoad()
                onMediaLoaded?()
            } catch {
                guard loadGeneration == generation, !Task.isCancelled, !error.isCancellation else { return }
                isLoadingSource = false
                deactivateASSRendering()
                nowPlayingController?.stop()
                TrailerPlaybackCoordinator.shared.endFeature(trailerPlaybackOwner)
                if let live, !live.nativeRemoteHLS, LiveLoadOptions.isDemuxFailure(error),
                   let onLiveDemuxFailure
                {
                    onLiveDemuxFailure(error)
                    return
                }
                if isLive {
                    LiveTVErrorReporting.capture(error, route: live?.route)
                } else {
                    ErrorReporter.capture(error)
                }
                errorMessage = error.localizedDescription
            }
        }
    }

    func togglePlayback() {
        #if os(iOS)
            if resumeVerification != nil {
                if isPaused {
                    resume()
                } else {
                    pause()
                }
                return
            }
        #endif
        #if os(iOS)
            remoteInterruptionToken = nil
            airPlayDiagnostics.record("toggle-command")
        #endif
        #if os(iOS)
            if needsBackgroundRestore {
                restoreAfterBackground(resumesPlayback: !backgroundRestoreResumesPlayback)
                return
            }
        #endif
        if isCoordinatedPlayback {
            engine.playbackCoordinator.coordinateRateChange(
                to: isPaused ? playbackRate : 0,
                options: [],
            )
        } else {
            engine.togglePlayPause()
        }
    }

    func prepareForRouteChange() {
        guard !isLive else { return }
        continuity.beginTransition()
    }

    func seekToLiveEdge() {
        Task { await engine.seekToLiveEdge() }
    }

    func pause() {
        #if os(iOS)
            if resumeVerification != nil {
                resumeVerification?.requestedPause = true
            }
            remoteInterruptionToken = nil
            airPlayDiagnostics.record("pause-command")
        #endif
        #if os(iOS)
            if needsBackgroundRestore {
                backgroundRestoreResumesPlayback = false
                return
            }
        #endif
        if isCoordinatedPlayback {
            engine.playbackCoordinator.coordinateRateChange(to: 0, options: [])
        } else {
            engine.pause()
        }
    }

    func resume() {
        #if os(iOS)
            if resumeVerification != nil {
                resumeVerification?.requestedPause = false
                resumeRecoveryMessage = "Waiting for your saved position. Retry resume, choose another source, or explicitly start from the beginning."
                return
            }
            remoteInterruptionToken = nil
            airPlayDiagnostics.record("play-command")
        #endif
        #if os(iOS)
            if needsBackgroundRestore {
                restoreAfterBackground(resumesPlayback: true)
                return
            }
        #endif
        if isCoordinatedPlayback {
            engine.playbackCoordinator.coordinateRateChange(to: playbackRate, options: [])
        } else {
            engine.play()
        }
    }

    #if os(iOS)
        var isAirPlayPlaybackActive: Bool {
            engine.currentAVPlayer?.isExternalPlaybackActive == true || LiveLoadOptions.routesAudioToAirPlay
        }

        func recordAirPlayDiagnostic(_ event: String) {
            airPlayDiagnostics.record(event)
        }

        func cancelAutomaticAirPlayResume() {
            remoteInterruptionToken = nil
        }

        func handleAirPlayInterruption(began: Bool, shouldResume: Bool, background: Bool) {
            if began {
                if hasStartedPlayback, !isPaused, isAirPlayPlaybackActive {
                    remoteInterruptionToken = UUID()
                    remoteInterruptionLoadGeneration = loadGeneration
                }
                return
            }
            guard let token = remoteInterruptionToken, let generation = remoteInterruptionLoadGeneration else { return }
            Task { @MainActor [weak self] in
                // AetherEngine owns the foreground/software interruption paths. Give it the
                // notification first and never issue a competing resume on those paths.
                await Task.yield()
                guard let self, remoteInterruptionToken == token else { return }
                remoteInterruptionToken = nil
                guard AirPlayPlaybackPolicy.shouldResumeRemoteInterruption(
                    wasPlaying: true, shouldResume: shouldResume,
                    background: background && UIApplication.shared.applicationState == .background,
                    externalPlayback: engine.currentAVPlayer?.isExternalPlaybackActive == true,
                    nativeVideo: videoRoute == .loopback || videoRoute == .remoteBypass,
                    sameSession: generation == loadGeneration && !isStopping,
                    coordinated: isCoordinatedPlayback,
                ), engine.currentAVPlayer?.timeControlStatus == .paused else { return }
                if resumeVerification != nil {
                    resumeVerification?.requestedPause = false; return
                }
                airPlayDiagnostics.record("system-authorized-background-resume")
                // One existing-transport command: no route selection, reload or retries.
                engine.play()
            }
        }

        private var needsBackgroundRestore: Bool {
            engine.currentAVPlayer?.isExternalPlaybackActive != true &&
                (engine.needsForegroundVideoRestore || backgroundRestoreTask != nil)
        }

        /// The engine releases the video of a session left paused in the background; it has to be rebuilt where it
        /// stopped before it can play again.
        /// `nil` keeps the intent of a restore already running, such as a play from the lock screen.
        func restoreAfterBackground(resumesPlayback: Bool? = nil) {
            if let resumesPlayback {
                backgroundRestoreResumesPlayback = resumesPlayback
            }
            guard engine.currentAVPlayer?.isExternalPlaybackActive != true, backgroundRestoreTask == nil,
                  engine.needsForegroundVideoRestore else { return }
            if resumesPlayback == nil {
                backgroundRestoreResumesPlayback = false
            }
            backgroundRestoreTask = Task { [weak self] in
                guard let self else { return }
                do {
                    try await engine.reloadAtCurrentPosition { $0.autoplay = false }
                } catch {
                    guard !Task.isCancelled, !error.isCancellation else { return }
                    backgroundRestoreTask = nil
                    ErrorReporter.capture(error)
                    errorMessage = error.localizedDescription
                    return
                }
                guard !Task.isCancelled else { return }
                backgroundRestoreTask = nil
                if backgroundRestoreResumesPlayback {
                    resume()
                }
            }
        }
    #endif

    /// Where relative seeks start from. `position` only catches up once the engine has taken the seek,
    /// so rapid presses would otherwise restart from the same stale value.
    var seekOrigin: Double {
        pendingSeekTarget ?? position
    }

    func seek(to time: Double) {
        if let restore = skipBackSubtitles.end() {
            applySubtitleTrack(id: restore.trackID)
        }
        performSeek(to: time)
    }

    private func cancelHandoffVerification() {
        handoffToken = UUID(); handoffResumeTask?.cancel(); handoffResumeTask = nil
    }

    func cancelResumeVerification() {
        cancelHandoffVerification()
        resumeVerificationToken = UUID()
        resumeSeekTask?.cancel(); resumeSeekTask = nil
        resumeVerification = nil; resumeRecoveryMessage = nil
        completedResumeTransportIntent = nil
        nativeResumeClock.reset()
        resumeVerifiedPosition = nil
    }

    private func observeNativeResumeClock() {
        nativeResumeClock.observe(engine.currentAVPlayer) { [weak self] in
            _ = self?.checkResumePosition()
        }
    }

    private func verifyHandoff(_ item: AVPlayerItem) {
        guard !isLive, !isLoadingSource, !isStopping, !isCoordinatedPlayback, hasStartedPlayback, position > 2,
              resumeVerification == nil else { return }
        cancelHandoffVerification()
        let token = handoffToken
        let generation = loadGeneration
        let checkpoint = position
        continuity.beginTransition()
        resumeVerification = ResumeVerification(target: checkpoint)
        resumeVerification?.requestedPause = completedResumeTransportIntent
        completedResumeTransportIntent = nil; resumeVerifiedPosition = nil
        observeNativeResumeClock()
        landedSeekPosition = nil
        handoffResumeTask = Task { @MainActor [weak self, weak item] in
            let started = ContinuousClock.now
            var stableSince: ContinuousClock.Instant?
            while let self, let item, token == handoffToken, generation == loadGeneration,
                  engine.currentAVPlayerItem === item, !isStopping, hasStartedPlayback, engine.state != .ended,
                  errorMessage == nil, !Task.isCancelled
            {
                if resumeVerification == nil || checkResumePosition() {
                    return
                }
                let native = nativeResumeClock.position
                let mapped = native.map { $0 + (videoRoute == .loopback ? engine.playlistShiftSeconds : 0) }
                let settled = item.status == .readyToPlay && !engine.isBuffering && !engine.isSeeking && engine
                    .state != .loading
                if settled {
                    if stableSince == nil {
                        stableSince = .now
                    }
                } else {
                    stableSince = nil
                }
                let stable = stableSince.map { Double($0.duration(to: .now).components.seconds) } ?? 0
                if ResumeVerification.shouldCorrectHandoff(
                    target: checkpoint,
                    native: mapped,
                    rendered: engine.clock.sourceTime,
                    display: engine.clock.currentTime,
                    settled: settled,
                    stableSeconds: stable,
                ) {
                    #if os(iOS)
                        airPlayDiagnostics.record("resume-handoff-position-mismatch")
                    #endif
                    // The engine's route restore has settled at a corroborated wrong position.
                    // Correct this item once; never reload or re-resolve its source.
                    handoffResumeTask = nil
                    _ = await seekAfterReady(to: checkpoint)
                    return
                }
                if started.duration(to: .now) >= .seconds(180) {
                    resumeRecoveryMessage = "The playback route is still restoring your saved position. Choose how to continue."
                    return
                }
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
        }
    }

    private var resumeTransportReady: Bool {
        if let item = engine.currentAVPlayerItem {
            return item.status == .readyToPlay
        }
        guard engine.videoRoute != .loopback, engine.videoRoute != .remoteBypass else { return false }
        return engine.state == .playing || engine.state == .paused
    }

    private func checkResumePosition() -> Bool {
        guard var verification = resumeVerification else { return false }
        let ready = resumeTransportReady
        // Native time is folded by the same public playlist shift used by the engine.
        // Require agreement with the rendered source clock, not a synthetic currentTime alone.
        let native = nativeResumeClock.position
        let mapped = native.map { $0 + (videoRoute == .loopback ? engine.playlistShiftSeconds : 0) }
        let rendered = engine.clock.sourceTime
        let actual: Double? = if let mapped, verification.near(mapped), verification.near(rendered) {
            rendered
        } else if !engine.isSeeking, engine.clock.sourceTimeFollowsPicture {
            rendered
        } else {
            nil
        }
        let confirmed = verification.observe(
            actual: actual,
            display: engine.clock.currentTime,
            ready: ready && !engine.isBuffering,
            paused: isPaused,
            landed: landedSeekPosition,
        )
        resumeVerification = verification
        if confirmed {
            // Persist canonical display seconds, not raw source PTS from a different origin.
            let accepted = landedSeekPosition.flatMap { verification.near($0) ? $0 : nil } ?? engine.clock.currentTime
            continuity.seek(to: accepted); _ = continuity.observe(accepted); position = accepted
            completedResumeTransportIntent = verification.requestedPause
            resumeVerifiedPosition = accepted
            resumeVerification = nil; resumeRecoveryMessage = nil
            nativeResumeClock.reset()
            #if os(iOS)
                airPlayDiagnostics.record("resume-verified")
            #endif
        }
        return confirmed
    }

    @discardableResult
    func seekAfterReady(to time: Double) async -> Bool {
        guard time.isFinite, time >= 0 else { return false }
        let explicitIntent = resumeTransportIntent
        cancelResumeVerification()
        let token = resumeVerificationToken
        let generation = loadGeneration
        continuity.seek(to: time)
        if isCoordinatedPlayback {
            engine.playbackCoordinator.coordinateSeek(to: CMTime(seconds: time, preferredTimescale: 600), options: [])
            return true
        }
        resumeVerification = ResumeVerification(target: time)
        resumeVerification?.requestedPause = explicitIntent
        observeNativeResumeClock()
        landedSeekPosition = nil
        let started = ContinuousClock.now
        var budget = 60.0
        while generation == loadGeneration, token == resumeVerificationToken, !Task.isCancelled, !isStopping {
            if resumeVerifiedPosition != nil || checkResumePosition() {
                return true
            }
            if errorMessage != nil {
                return false
            } // A genuine engine failure retains normal source fallback.
            let elapsed = Double(started.duration(to: .now).components.seconds)
            #if os(iOS)
                let remote = isAirPlayPlaybackActive
            #else
                let remote = engine.currentAVPlayer?.isExternalPlaybackActive == true
            #endif
            budget = max(budget, ResumeVerification.budget(remote: remote, buffering: engine.isBuffering))
            if engine.isSourceSeekable == false || elapsed >= budget {
                resumeRecoveryMessage = engine.isSourceSeekable == false
                    ? "This stream cannot seek to your saved position. Your saved progress is preserved."
                    : "Resume is taking longer than expected. Your saved position is preserved; playback has not been stopped."
                #if os(iOS)
                    airPlayDiagnostics
                        .record(engine.isSourceSeekable == false ? "resume-not-seekable" : "resume-delayed")
                #endif
                return false // Nonfatal. Observers may still confirm a late landing.
            }
            let ready = resumeTransportReady
            if resumeSeekTask == nil,
               resumeVerification?.requestSeek(
                   ready: ready,
                   buffering: engine.isBuffering,
                   seeking: engine.isSeeking,
                   elapsed: elapsed,
                   supported: engine.isSourceSeekable,
               ) == true
            {
                pendingSeekTarget = time
                resumeSeekTask = Task { @MainActor [weak self] in
                    guard let self, generation == loadGeneration, token == resumeVerificationToken,
                          !Task.isCancelled, !isStopping else { return }
                    await engine.seek(to: time, exact: true)
                    if token == resumeVerificationToken {
                        resumeSeekTask = nil
                    }
                }
                #if os(iOS)
                    airPlayDiagnostics.record("resume-seek-requested")
                #endif
            }
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return false }
        }
        return false
    }

    func seek(by delta: Double) {
        var target = max(0, seekOrigin + delta)
        if !isLive, let duration {
            target = min(target, duration)
        }
        if delta < 0 {
            showSubtitlesForSkipBack(from: seekOrigin, to: target)
        } else if let restore = skipBackSubtitles.skipForward(to: target) {
            applySubtitleTrack(id: restore.trackID)
        }
        performSeek(to: target)
    }

    private func performSeek(to time: Double) {
        cancelHandoffVerification()
        if resumeVerification != nil {
            resumeVerificationToken = UUID(); resumeSeekTask?.cancel(); resumeSeekTask = nil
            resumeVerification = ResumeVerification(target: time); landedSeekPosition = nil
        }
        continuity.seek(to: time)
        if isCoordinatedPlayback {
            engine.playbackCoordinator.coordinateSeek(
                to: CMTime(seconds: time, preferredTimescale: 600),
                options: [],
            )
            return
        }
        pendingSeekTarget = time
        Task { @MainActor [weak self] in
            await self?.engine.seek(to: time)
        }
    }

    private func showSubtitlesForSkipBack(from origin: Double, to target: Double) {
        guard showsSubtitlesOnSkipBack else { return }
        let activeAudio = engine.audioTracks.first { $0.id == engine.activeAudioTrackIndex }
        let trackID = skipBackSubtitles.skipBack(
            from: origin,
            to: target,
            selectedTrackID: selectedSubtitleTrackID,
            tracks: engine.subtitleTracks.map {
                SkipBackSubtitles.Track(
                    id: $0.id,
                    language: $0.language,
                    isForced: $0.isForced,
                    isCommentary: $0.isCommentary,
                )
            },
            audioLanguage: activeAudio?.language,
        )
        if let trackID {
            applySubtitleTrack(id: trackID)
        }
    }

    func beginScrubPreviewing(at position: Double) {
        guard showsScrubThumbnailPreviews else { return }
        isScrubPreviewing = true
        updateScrubPreview(to: position)
    }

    func updateScrubPreview(to position: Double) {
        guard showsScrubThumbnailPreviews, isScrubPreviewing, position.isFinite else { return }

        let target = max(0, position)
        let bucket = Int(floor(target / scrubBucketDuration))
        let bucketChanged = activeScrubBucket != bucket

        if bucketChanged {
            cancelPendingExtractorFallback()
            activeScrubBucket = bucket
            scrubPreviewGeneration &+= 1
            scrubThumbnailTask?.cancel()
            scrubAetherTask?.cancel()
            scrubPreview = PlayerScrubPreview(
                position: target,
                image: scrubGeneratedThumbnailCache[bucket],
            )
            requestBucketThumbnails(
                target: target,
                bucket: bucket,
                generation: scrubPreviewGeneration,
            )
            scheduleExtractorFallback(
                bucket: bucket,
                generation: scrubPreviewGeneration,
            )
        } else {
            scrubPreview = PlayerScrubPreview(
                position: target,
                image: scrubPreview?.image,
            )
        }
    }

    func endScrubPreviewing() {
        isScrubPreviewing = false
        scrubPreviewGeneration &+= 1
        activeScrubBucket = nil
        scrubThumbnailTask?.cancel()
        scrubThumbnailTask = nil
        scrubAetherTask?.cancel()
        scrubAetherTask = nil
        scrubExtractorDwellTask?.cancel()
        scrubExtractorDwellTask = nil
        cancelInFlightScrubExtraction()
        scrubPreview = nil
    }

    func setPlaybackRate(_ rate: Float) {
        playbackRate = rate
        nowPlayingController?.setPlaybackRate(rate)
        if isCoordinatedPlayback {
            engine.playbackCoordinator.coordinateRateChange(to: rate, options: [])
        } else {
            engine.setRate(rate)
        }
    }

    func setVolume(_ newVolume: Float) {
        let clampedVolume = min(max(newVolume, 0), 1)
        volume = clampedVolume
        if clampedVolume > 0 {
            lastAudibleVolume = clampedVolume
        }
        engine.volume = clampedVolume * volumeAttenuation
    }

    /// Scales the output without touching the user's volume, so a fade never shows up on the volume control.
    func setVolumeAttenuation(_ attenuation: Float) {
        volumeAttenuation = min(max(attenuation, 0), 1)
        engine.volume = volume * volumeAttenuation
    }

    func toggleMute() {
        if isMuted {
            setVolume(lastAudibleVolume)
        } else {
            lastAudibleVolume = volume
            setVolume(0)
        }
    }

    var playbackCoordinator: AVDelegatingPlaybackCoordinator {
        engine.playbackCoordinator
    }

    func configureCatalogSharePlay(_ enabled: Bool, initialTime: Double) {
        isCatalogSharePlayItem = enabled
        if enabled {
            continuity.seek(to: initialTime)
        }
    }

    func beginCoordinatedPlayback(
        identifier: String,
        initialTime: Double,
        initialRate: Float = 0,
    ) {
        if isCatalogSharePlayItem {
            continuity.seek(to: initialTime)
        }
        isCoordinatedPlayback = true
        coordinatedPlaybackIdentifier = identifier
        engine.transitionToCoordinatedPlaybackItem(
            identifier: identifier,
            initialTime: initialTime,
            initialRate: initialRate,
        )
    }

    func reconcileCoordinatedPlaybackAfterLoad(
        identifier: String,
        initialTime: Double,
    ) {
        guard isCoordinatedPlayback,
              coordinatedPlaybackIdentifier == identifier
        else {
            beginCoordinatedPlayback(
                identifier: identifier,
                initialTime: initialTime,
            )
            return
        }

        // The item was already registered when the player attached. Re-registering it here with
        // an initial rate of zero can overwrite a play command that arrived while media loaded.
        // Ask the coordinator to replay its latest session state onto the now-loaded transport.
        engine.playbackCoordinator.reapplyCurrentItemStateToPlaybackControlDelegate()
    }

    func beginCoordinatedPlaybackFromCurrentState(identifier: String) {
        beginCoordinatedPlayback(
            identifier: identifier,
            initialTime: position,
            initialRate: isPaused ? 0 : playbackRate,
        )
    }

    func beginCoordinatedPlaybackResumingFromCurrentState(identifier: String) {
        beginCoordinatedPlayback(
            identifier: identifier,
            initialTime: position,
            initialRate: playbackRate,
        )
    }

    func endCoordinatedPlayback(continueLocally: Bool) {
        let intendedRate = engine.coordinatedPlaybackIntendedRate
        engine.endCoordinatedPlayback()
        isCoordinatedPlayback = false
        coordinatedPlaybackIdentifier = nil
        guard continueLocally else { return }
        if intendedRate > 0 {
            playbackRate = intendedRate
            engine.setRate(intendedRate)
            engine.play()
        } else {
            engine.pause()
        }
    }

    /// Updates the value at once; the engine gets it after a quiet period, because each change
    /// re-anchors playback (a reload of about 0.3 s on the AVPlayer route).
    func setAudioDelay(milliseconds: Int) {
        let clamped = PlaybackOffsetRange.audio.clamp(milliseconds)
        guard clamped != audioDelayMilliseconds else { return }
        audioDelayMilliseconds = clamped
        audioDelayDispatch.submit(clamped, at: .now)
        audioDelayDispatchTask?.cancel()
        let delay = audioDelayDispatch.delay
        audioDelayDispatchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            if let pending = audioDelayDispatch.takeIfDue(at: .now) {
                sendAudioDelay(pending)
            }
        }
    }

    /// Sends a pending audio delay without waiting, when the sync bar closes.
    func commitAudioDelay() {
        audioDelayDispatchTask?.cancel()
        audioDelayDispatchTask = nil
        if let pending = audioDelayDispatch.flush() {
            sendAudioDelay(pending)
        }
    }

    /// Each change rebuilds the session at the playhead (about 0.3 s of held picture).
    func setAudioShaping(_ shaping: AudioShaping) {
        audioShaping = shaping.clamped
        engine.setAudioShaping(shaping)
    }

    func setSubtitleDelay(milliseconds: Int) {
        let clamped = PlaybackOffsetRange.subtitles.clamp(milliseconds)
        guard clamped != subtitleDelayMilliseconds else { return }
        subtitleDelayMilliseconds = clamped
        assCoordinator.setSubtitleDelay(seconds: PlaybackOffset(milliseconds: clamped).seconds)
    }

    func selectAudioTrack(id: Int?) {
        guard let id else { return }
        if let nativeAudioSelection, nativeAudioSelection.item === engine.currentAVPlayerItem {
            nativeAudioSelection.select(id: id); audioTrackRevision += 1
        } else {
            engine.selectAudioTrack(index: id)
        }
    }

    func selectSubtitleTrack(id: Int?, styledASSSubtitles: Bool? = nil) {
        skipBackSubtitles.cancel()
        if let styledASSSubtitles {
            self.styledASSSubtitles = styledASSSubtitles
        }
        applySubtitleTrack(id: id)
    }

    private func applySubtitleTrack(id: Int?) {
        deactivateASSRendering()
        selectedSubtitleTrackID = id
        guard let id else {
            engine.clearSubtitle()
            subtitleCues = []
            activeSubtitleCodec = nil
            return
        }

        let track = engine.subtitleTracks.first { $0.id == id }
        activeSubtitleCodec = track?.codec.lowercased()
        engine.selectSubtitleTrack(index: id)
        subtitleCues = engine.subtitleCues

        guard styledASSSubtitles,
              activeSubtitleCodec == "ass" || activeSubtitleCodec == "ssa"
        else {
            return
        }

        assCoordinator.onRendererChanged = { [weak self] renderer in
            self?.assRenderer = renderer
        }
        if track?.isExternal == true {
            sidecarASSHeaderCancellable = engine.$sidecarASSHeader
                .receive(on: DispatchQueue.main)
                .compactMap(\.self)
                .first()
                .sink { [weak self] header in
                    guard let self else { return }
                    assCoordinator.activate(header: header)
                    assRenderer = assCoordinator.renderer
                }
        } else {
            assCoordinator.activate(header: track?.assHeader)
            assRenderer = assCoordinator.renderer
        }
    }

    func registerExternalSubtitleIfNeeded(
        _ subtitle: PlayerExternalSubtitle,
        styledASSSubtitles: Bool,
    ) throws -> Int {
        if let existingID = externalSubtitleProviderStreamIDs.first(where: {
            $0.value == subtitle.providerStreamID
        })?.key {
            selectSubtitleTrack(id: existingID, styledASSSubtitles: styledASSSubtitles)
            return existingID
        }

        let track = engine.addExternalSubtitleTrack(subtitle.track)
        guard engine.subtitleTracks.contains(where: { $0.id == track.id && $0.isExternal }) else {
            throw ExternalSubtitleRegistrationError()
        }
        externalSubtitleProviderStreamIDs[track.id] = subtitle.providerStreamID
        selectSubtitleTrack(id: track.id, styledASSSubtitles: styledASSSubtitles)
        return track.id
    }

    func trackList() -> [PlayerTrack] {
        let audio = nativeAudioSelection?.tracks() ?? engine.audioTracks.map { track in
            PlayerTrack(
                id: track.id,
                ffIndex: track.id,
                providerStreamID: providerStreamIDsByFFIndex[track.id],
                type: .audio,
                title: track.name,
                language: track.language,
                codec: track.codec,
                isDefault: track.isDefault,
                isForced: track.isForced,
                isHearingImpaired: track.isHearingImpaired,
                isCommentary: track.isCommentary,
                isExternal: track.isExternal,
                isSelected: engine.activeAudioTrackIndex == track.id,
            )
        }

        let subtitles = engine.subtitleTracks.map { track in
            PlayerTrack(
                id: track.id,
                ffIndex: track.isExternal ? nil : track.id,
                providerStreamID: track.isExternal
                    ? externalSubtitleProviderStreamIDs[track.id]
                    : providerStreamIDsByFFIndex[track.id],
                type: .subtitle,
                title: track.name,
                language: track.language,
                codec: track.codec,
                isDefault: track.isDefault,
                isForced: track.isForced,
                isHearingImpaired: track.isHearingImpaired,
                isCommentary: track.isCommentary,
                isExternal: track.isExternal,
                isSelected: skipBackSubtitles.userTrackID(displayedTrackID: selectedSubtitleTrackID) == track.id,
            )
        }

        return audio + subtitles
    }

    func stop() {
        isCatalogSharePlayItem = false
        cancelResumeVerification()
        #if os(iOS)
            remoteInterruptionToken = nil
            airPlayDiagnostics.record("session-stop")
        #endif
        loadGeneration = UUID()
        nativeAudioSelection = nil
        #if os(iOS) || os(macOS)
            pictureInPictureCoordinator.stop()
        #endif
        deactivateASSRendering()
        resetScrubPreviewSession()
        isStopping = true
        pendingSeekTarget = nil
        isPaused = true
        isBuffering = false
        sourceVideoSize = nil
        displayVideoSize = nil
        activeSubtitleCodec = nil
        selectedSubtitleTrackID = nil
        cancelPendingAudioDelay()
        skipBackSubtitles.cancel()
        #if os(iOS)
            backgroundRestoreTask?.cancel()
            backgroundRestoreTask = nil
        #endif
        nowPlayingController?.stop()
        TrailerPlaybackCoordinator.shared.endFeature(trailerPlaybackOwner)
        engine.stop()
    }

    private func sendAudioDelay(_ milliseconds: Int) {
        let reanchors = (videoRoute == .loopback || videoRoute == .software)
            && (engine.state == .playing || engine.state == .paused)
        engine.setAudioDelay(PlaybackOffset(milliseconds: milliseconds).seconds)
        guard reanchors else { return }
        beginApplyingAudioDelay()
    }

    private func beginApplyingAudioDelay() {
        audioDelayApplyPhase = .requested
        isApplyingAudioDelay = true
        audioDelayApplyTimeoutTask?.cancel()
        audioDelayApplyTimeoutTask = Task { @MainActor [weak self] in
            // A re-anchor that never leaves the playing state (or hangs) must not leave the label up.
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            if audioDelayApplyPhase == .requested {
                endApplyingAudioDelay()
                return
            }
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            endApplyingAudioDelay()
        }
    }

    private func updateAudioDelayApplyPhase() {
        guard audioDelayApplyPhase != .idle else { return }
        let isSettled = !engine.isSeeking && (engine.state == .playing || engine.state == .paused)
        switch audioDelayApplyPhase {
        case .requested where !isSettled:
            audioDelayApplyPhase = .reanchoring
        case .reanchoring where isSettled:
            endApplyingAudioDelay()
        default:
            break
        }
    }

    private func endApplyingAudioDelay() {
        audioDelayApplyTimeoutTask?.cancel()
        audioDelayApplyTimeoutTask = nil
        audioDelayApplyPhase = .idle
        isApplyingAudioDelay = false
    }

    private func cancelPendingAudioDelay() {
        audioDelayDispatchTask?.cancel()
        audioDelayDispatchTask = nil
        _ = audioDelayDispatch.flush()
        endApplyingAudioDelay()
    }

    #if os(iOS) || os(macOS)
        func startPictureInPicture() {
            pictureInPictureCoordinator.start()
        }

        func setPictureInPictureEnabled(_ enabled: Bool) {
            pictureInPictureCoordinator.isEnabled = enabled
        }

        private func configurePictureInPicture() {
            pictureInPictureCoordinator.onAvailabilityChanged = { [weak self] showsControl, isAvailable in
                self?.showsPictureInPictureControl = showsControl
                self?.isPictureInPictureAvailable = isAvailable
            }
            pictureInPictureCoordinator.onActivityChanged = { [weak self] isActive, isTransitioning in
                self?.isPictureInPictureActive = isActive
                self?.isPictureInPictureTransitioning = isTransitioning
            }
            pictureInPictureCoordinator.onRestoreUserInterface = { [weak self] in
                self?.onPictureInPictureRestoreRequested?()
            }
            pictureInPictureCoordinator.onStartFailed = { [weak self] in
                self?.onPictureInPictureStartFailed?()
            }
        }
    #endif

    private func deactivateASSRendering() {
        sidecarASSHeaderCancellable?.cancel()
        sidecarASSHeaderCancellable = nil
        assCoordinator.deactivate()
        assRenderer = nil
    }

    private func isCurrentScrubBucket(generation: Int, bucket: Int) -> Bool {
        isScrubPreviewing
            && scrubPreviewGeneration == generation
            && activeScrubBucket == bucket
    }

    private func requestBucketThumbnails(
        target: Double,
        bucket: Int,
        generation: Int,
    ) {
        if let scrubThumbnailProvider {
            scrubThumbnailTask = Task { @MainActor [weak self, scrubThumbnailProvider] in
                let thumbnail = await scrubThumbnailProvider.thumbnail(at: target)
                guard let self,
                      let thumbnail,
                      isCurrentScrubBucket(generation: generation, bucket: bucket)
                else {
                    return
                }
                scrubPreview = PlayerScrubPreview(
                    position: scrubPreview?.position ?? target,
                    image: thumbnail.image,
                )
                cancelPendingExtractorFallback()
            }
        }

        let bucketPosition = Double(bucket) * scrubBucketDuration
        scrubAetherTask = Task { @MainActor [weak self] in
            guard let self, scrubPreview?.image == nil else { return }
            let image = await engine.scrubThumbnail(
                atSeconds: bucketPosition,
                maxWidth: scrubThumbnailWidth,
            )
            guard let image,
                  isCurrentScrubBucket(generation: generation, bucket: bucket),
                  scrubPreview?.image == nil
            else {
                return
            }
            scrubPreview = PlayerScrubPreview(
                position: scrubPreview?.position ?? target,
                image: image,
            )
            cancelPendingExtractorFallback()
        }
    }

    private func scheduleExtractorFallback(
        bucket: Int,
        generation: Int,
    ) {
        scrubExtractorDwellTask?.cancel()
        scrubExtractorDwellTask = nil
        guard generatesMissingScrubThumbnailPreviews,
              scrubPreview?.image == nil,
              !engine.isLive
        else {
            return
        }

        scrubExtractorDwellTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let startedAt = ContinuousClock.now
            while true {
                do {
                    try await Task.sleep(for: extractorAvailabilityPollInterval)
                } catch {
                    return
                }
                let requiredDelay = await extractorDelayForCurrentThumbnailState()
                if startedAt.duration(to: ContinuousClock.now) >= requiredDelay {
                    break
                }
            }
            guard isCurrentScrubBucket(generation: generation, bucket: bucket),
                  scrubPreview?.image == nil,
                  !engine.isLive
            else {
                return
            }

            let extractor: FrameExtractor
            if let scrubFrameExtractor {
                extractor = scrubFrameExtractor
            } else {
                guard let newExtractor = engine.makeFrameExtractor() else { return }
                scrubFrameExtractor = newExtractor
                extractor = newExtractor
            }

            let bucketPosition = Double(bucket) * scrubBucketDuration
            scrubExtractorRequestGeneration = generation
            let extractedImage = await extractor.thumbnail(
                at: bucketPosition,
                maxWidth: scrubThumbnailWidth,
            )
            if scrubExtractorRequestGeneration == generation {
                scrubExtractorRequestGeneration = nil
            }
            guard let extractedImage,
                  isCurrentScrubBucket(generation: generation, bucket: bucket),
                  scrubPreview?.image == nil
            else {
                return
            }
            storeGeneratedThumbnail(extractedImage, for: bucket)
            scrubPreview = PlayerScrubPreview(
                position: scrubPreview?.position ?? bucketPosition,
                image: extractedImage,
            )
        }
    }

    private func extractorDelayForCurrentThumbnailState() async -> Duration {
        guard let scrubThumbnailProvider else {
            return unavailableThumbnailExtractorDelay
        }
        switch await scrubThumbnailProvider.availability() {
        case .unavailable:
            return unavailableThumbnailExtractorDelay
        case .temporarilyFailed:
            return failedThumbnailExtractorDelay
        case .loading, .ready:
            return pendingThumbnailExtractorDelay
        }
    }

    private func cancelPendingExtractorFallback() {
        scrubExtractorDwellTask?.cancel()
        scrubExtractorDwellTask = nil
        cancelInFlightScrubExtraction()
    }

    private func storeGeneratedThumbnail(_ image: CGImage, for bucket: Int) {
        if scrubGeneratedThumbnailCache[bucket] == nil {
            scrubGeneratedThumbnailOrder.append(bucket)
        }
        scrubGeneratedThumbnailCache[bucket] = image

        while scrubGeneratedThumbnailOrder.count > scrubGeneratedThumbnailCacheLimit {
            let expiredBucket = scrubGeneratedThumbnailOrder.removeFirst()
            scrubGeneratedThumbnailCache[expiredBucket] = nil
        }
    }

    private func resetScrubPreviewSession() {
        isScrubPreviewing = false
        scrubPreviewGeneration &+= 1
        activeScrubBucket = nil
        scrubThumbnailTask?.cancel()
        scrubThumbnailTask = nil
        scrubAetherTask?.cancel()
        scrubAetherTask = nil
        scrubExtractorDwellTask?.cancel()
        scrubExtractorDwellTask = nil
        scrubThumbnailPreparationTask?.cancel()
        scrubThumbnailPreparationTask = nil
        scrubPreview = nil
        scrubExtractorRequestGeneration = nil
        scrubGeneratedThumbnailCache = [:]
        scrubGeneratedThumbnailOrder = []

        if let scrubThumbnailProvider {
            self.scrubThumbnailProvider = nil
            Task {
                await scrubThumbnailProvider.cancel()
            }
        }
        if let extractor = scrubFrameExtractor {
            scrubFrameExtractor = nil
            Task {
                await extractor.shutdown()
            }
        }
    }

    private func cancelInFlightScrubExtraction() {
        guard scrubExtractorRequestGeneration != nil,
              let extractor = scrubFrameExtractor
        else {
            return
        }
        scrubExtractorRequestGeneration = nil
        scrubFrameExtractor = nil
        Task {
            await extractor.shutdown()
        }
    }

    func playbackStatistics(context: PlaybackStatisticsContext) -> PlaybackStatistics {
        let audioTrack = engine.activeAudioTrackIndex.flatMap { index in
            engine.audioTracks.first { $0.id == index }
        }
        return PlaybackStatistics(PlaybackStatisticsSource(
            context: context,
            videoRoute: engine.videoRoute,
            containerFormat: engine.sourceContainerFormat,
            videoCodec: engine.sourceVideoCodecName,
            videoStreamFormat: engine.sourceVideoStreamFormat,
            decodedVideoFormat: engine.decodedVideoFormat,
            sourceVideoSize: sourceVideoSize,
            displayVideoSize: displayVideoSize,
            frameRate: engine.sourceVideoFrameRate,
            videoBitrate: engine.sourceVideoBitrate,
            sourceVideoFormat: engine.sourceVideoFormat,
            presentedVideoFormat: engine.videoFormat,
            dolbyVisionProfile: engine.sourceDVProfile,
            dolbyVisionConversion: engine.dolbyVisionConversion,
            videoDecoder: engine.activeVideoDecoder,
            audioTrack: audioTrack,
            audioDecoder: engine.activeAudioDecoder,
            audioDelivery: engine.audioDelivery,
            subtitleCodec: activeSubtitleCodec,
            subtitleRenderer: statisticsSubtitleRenderer(burnsSubtitles: context.burnsSubtitles),
            bufferedAhead: isLive ? nil : bufferedAhead,
            telemetry: engine.diagnostics.liveTelemetry,
        ))
    }

    private func statisticsSubtitleRenderer(burnsSubtitles: Bool) -> PlaybackStatisticsSubtitleRenderer? {
        if burnsSubtitles {
            return .burnedIn
        }
        guard let selectedSubtitleTrackID,
              let track = engine.subtitleTracks.first(where: { $0.id == selectedSubtitleTrackID })
        else {
            return nil
        }
        if track.isNativelyRenderedSubtitle {
            return .native
        }
        return assRenderer == nil ? .overlay : .styled
    }

    private func refreshNativeAudioSelection() async {
        guard engine.videoRoute == .remoteBypass, let item = engine.currentAVPlayerItem else { return }
        let selection = await NativeAudioSelection.prepare(item: item)
        guard engine.currentAVPlayerItem === item else { return }
        nativeAudioSelection = selection; audioTrackRevision += 1
    }

    private func observeEngine() {
        engine.$currentAVPlayer
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, resumeVerification != nil else { return }
                observeNativeResumeClock()
            }.store(in: &cancellables)

        #if os(iOS)
            // Without this the system pauses a player showing video as soon as the app leaves the foreground.
            engine.$currentAVPlayer
                .receive(on: DispatchQueue.main)
                .sink { [weak self] player in
                    self?.airPlayDiagnostics.attach(player)
                    if let player {
                        PlayerAirPlayConfiguration.apply(to: player)
                    }
                }
                .store(in: &cancellables)
        #endif

        #if os(iOS)
            engine.$currentAVPlayer
                .map { player -> AnyPublisher<AVPlayer?, Never> in
                    guard let player else { return Just(nil).eraseToAnyPublisher() }
                    return player.publisher(for: \.isExternalPlaybackActive)
                        .map { _ in Optional(player) }.eraseToAnyPublisher()
                }
                .switchToLatest()
                .combineLatest(engine.$currentAVPlayerItem)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] player, item in
                    guard let self, let player, let item, videoRoute == .remoteBypass,
                          !isCoordinatedPlayback else { return }
                    PlayerAirPlayConfiguration.applyRemoteBuffering(to: player, item: item)
                }
                .store(in: &cancellables)
        #endif

        engine.$currentAVPlayerItem
            .receive(on: DispatchQueue.main)
            .sink { [weak self] item in
                guard let self, !isLive, !isStopping else { return }
                continuity.beginTransition()
                if let item, continuityItem !== item {
                    continuityItem = item
                    if resumeVerification != nil {
                        nativeResumeClock.reset(); observeNativeResumeClock()
                    }
                    verifyHandoff(item)
                }
            }
            .store(in: &cancellables)

        engine.$currentAVPlayerItem
            .map { item -> AnyPublisher<CGSize, Never> in
                guard let item else { return Just(.zero).eraseToAnyPublisher() }
                return item.publisher(for: \.presentationSize).eraseToAnyPublisher()
            }
            .switchToLatest()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] size in
                guard size.width > 0, size.height > 0 else { return }
                self?.displayVideoSize = size
            }
            .store(in: &cancellables)

        engine.$softwareDisplaySize
            .receive(on: DispatchQueue.main)
            .sink { [weak self] size in
                guard let size, size.width > 0, size.height > 0 else { return }
                self?.displayVideoSize = size
            }
            .store(in: &cancellables)

        engine.$audioTracks
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                audioTrackRevision += 1
                Task { @MainActor [weak self] in await self?.refreshNativeAudioSelection() }
            }.store(in: &cancellables)
        engine.$activeAudioTrackIndex
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.audioTrackRevision += 1 }
            .store(in: &cancellables)

        engine.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.handleState(state)
                self?.updateAudioDelayApplyPhase()
            }
            .store(in: &cancellables)

        engine.$isSeeking
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateAudioDelayApplyPhase()
            }
            .store(in: &cancellables)

        engine.$videoRoute
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.videoRoute = $0 }
            .store(in: &cancellables)

        engine.$audioShapingState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.audioShapingState = $0 }
            .store(in: &cancellables)

        engine.$isBuffering
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isBuffering in
                guard let self else { return }
                self.isBuffering = isBuffering || engine.isWaitingForCoordinatedPlayback
            }
            .store(in: &cancellables)

        engine.$isWaitingForCoordinatedPlayback
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isWaiting in
                guard let self else { return }
                isBuffering = engine.isBuffering || isWaiting
            }
            .store(in: &cancellables)

        engine.clock.$currentTime
            .receive(on: DispatchQueue.main)
            .sink { [weak self] time in
                guard let self, !isStopping, !isLoadingSource else { return }
                if !isLive, !continuity.observe(time) {
                    if time < 1, position > 2, resumeVerification == nil, let item = engine.currentAVPlayerItem {
                        verifyHandoff(item)
                    }
                    return
                }
                position = time
                if let restore = skipBackSubtitles.observe(position: time) {
                    applySubtitleTrack(id: restore.trackID)
                }
            }
            .store(in: &cancellables)

        engine.seekEvents
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                guard let self, !isStopping, !isLoadingSource else { return }
                if event.origin == .nativeScrub {
                    continuity.seek(to: event.target)
                }
                if isCoordinatedPlayback, isCatalogSharePlayItem, case .began = event.outcome {
                    // A peer's explicit coordinated seek (including zero) is authoritative intent.
                    continuity.seek(to: event.target)
                }
                switch event.outcome {
                case let .landed(renderedTime):
                    landedSeekPosition = renderedTime
                    pendingSeekTarget = nil
                    _ = checkResumePosition()
                    if continuity.observe(renderedTime) {
                        position = renderedTime
                    }
                case .stalled, .rejected:
                    pendingSeekTarget = nil
                case .began, .superseded:
                    break
                }
            }
            .store(in: &cancellables)

        engine.clock.$sourceTime
            .receive(on: DispatchQueue.main)
            .sink { [weak self] time in
                self?.sourcePosition = time
                if self?.resumeVerification != nil {
                    _ = self?.checkResumePosition()
                }
            }
            .store(in: &cancellables)

        engine.clock.$bufferedPosition
            .receive(on: DispatchQueue.main)
            .sink { [weak self] bufferedPosition in
                guard let self else { return }
                bufferedAhead = max(0, bufferedPosition - position)
            }
            .store(in: &cancellables)

        engine.$duration
            .receive(on: DispatchQueue.main)
            .sink { [weak self] duration in
                self?.duration = duration > 0 ? duration : nil
            }
            .store(in: &cancellables)

        engine.$isLive
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.isLive = $0 }
            .store(in: &cancellables)

        engine.clock.$liveEdgeTime
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.liveEdgeTime = $0 }
            .store(in: &cancellables)

        engine.clock.$behindLiveSeconds
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.behindLiveSeconds = $0 }
            .store(in: &cancellables)

        engine.clock.$isAtLiveEdge
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.isAtLiveEdge = $0 }
            .store(in: &cancellables)

        engine.clock.$seekableLiveRange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.seekableLiveRange = $0 }
            .store(in: &cancellables)

        engine.$videoFormat
            .receive(on: DispatchQueue.main)
            .sink { [weak self] format in
                self?.videoFormatBadge = Self.videoFormatBadge(for: format)
            }
            .store(in: &cancellables)

        engine.$subtitleCues
            .receive(on: DispatchQueue.main)
            .sink { [weak self] cues in
                guard let self else { return }
                subtitleCues = cues
                subtitleMaxCueDuration = cues.reduce(60.0) {
                    max($0, $1.endTime - $1.startTime)
                }
            }
            .store(in: &cancellables)
    }

    private func handleState(_ state: PlaybackState) {
        switch state {
        case .playing:
            hasStartedPlayback = true
            isPaused = false
        case .paused:
            isPaused = true
        case .loading, .seeking:
            break
        case let .error(message):
            nowPlayingController?.stop()
            TrailerPlaybackCoordinator.shared.endFeature(trailerPlaybackOwner)
            deactivateASSRendering()
            errorMessage = message
        case .ended:
            nowPlayingController?.stop()
            TrailerPlaybackCoordinator.shared.endFeature(trailerPlaybackOwner)
            isPaused = false
            guard hasStartedPlayback, !isStopping else { return }
            hasStartedPlayback = false
            onPlaybackEnded?()
        case .idle:
            isPaused = isStopping
        }
    }

    private static func videoFormatBadge(for format: VideoFormat) -> PlayerVideoFormatBadge? {
        switch format {
        case .sdr:
            nil
        case .hdr10:
            .hdr10
        case .hdr10Plus:
            .hdr10Plus
        case .dolbyVision:
            .dolbyVision
        case .hlg:
            .hlg
        }
    }

    private static var preparesNativeSubtitles: Bool {
        #if os(iOS) || os(macOS)
            true
        #else
            false
        #endif
    }
}

private enum AudioDelayApplyPhase {
    case idle
    case requested
    case reanchoring
}

struct ExternalSubtitleTrackMappingError: LocalizedError {
    var errorDescription: String? {
        "AetherEngine returned an unexpected external subtitle track table."
    }
}

struct ExternalSubtitleRegistrationError: LocalizedError {
    var errorDescription: String? {
        String(localized: "subtitles.search.activation.error")
    }
}

struct PlayerSurfaceView: View {
    let controller: PlayerController
    var zoomScale = 1.0

    var body: some View {
        AetherPlayerSurface(engine: controller.engine)
            .scaleEffect(zoomScale)
            .clipped()
    }
}
