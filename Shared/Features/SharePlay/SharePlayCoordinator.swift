import AVFoundation
import Combine
import Foundation
import GroupActivities
import Observation
import OSLog

@MainActor
@Observable
final class SharePlayCoordinator {
    private(set) var activity: StrimrWatchActivity?
    private(set) var isInSession = false
    private(set) var activityChangeID = UUID()
    private(set) var participantCount = 0
    private(set) var isActivating = false
    var errorMessage: String?
    var catalogErrorMessage: String?
    var catalogPlaybackActivity: StrimrWatchActivity?
    var catalogInvitationActivity: StrimrWatchActivity?

    var isEligibleForGroupSession: Bool {
        signingUnavailableReason == nil && groupStateObserver.isEligibleForGroupSession
    }

    var isLaunching: Bool {
        isActivating || launchGuard.activeID != nil || sharingPresentationActivityID != nil
    }

    @ObservationIgnored private let signingUnavailableReason = SharePlaySigningCheck.installedAppUnavailableReason
    private var launchGuard = SharePlayLaunchGuard()
    @ObservationIgnored private var activationDeadline: Task<Void, Never>?
    @ObservationIgnored private static let launchLog = Logger(subsystem: "app.strimr.shareplay", category: "Launch")

    /// Called before constructing any native invitation controller or invoking GroupActivities.
    func checkLaunchAvailability(for activity: StrimrWatchActivity) -> Bool {
        if let signingUnavailableReason {
            Self.launchLog.notice("stage=preflight outcome=signing_unconfirmed")
            reportLaunchError(signingUnavailableReason, for: activity)
            return false
        }
        guard activity.hasValidSharePlayMetadata else {
            reportLaunchError(
                "This SharePlay invitation has invalid media identity or playback metadata.",
                for: activity,
            )
            Self.launchLog.notice("stage=preflight outcome=invalid_metadata")
            return false
        }
        return true
    }

    private func reportLaunchError(_ message: String, for activity: StrimrWatchActivity) {
        if activity.catalog != nil {
            catalogErrorMessage = message
        } else {
            errorMessage = message
        }
    }

    func beginSharingPresentation(_ activity: StrimrWatchActivity) -> Bool {
        guard checkLaunchAvailability(for: activity), !isActivating,
              launchGuard.begin(activity.activityID) else { return false }
        completedInvitationID = nil
        sharingPresentationActivityID = activity.activityID
        locallyPreparedActivityIDs.insert(activity.activityID)
        Self.launchLog.notice("stage=invitation outcome=constructing")
        return true
    }

    func sharingPresentationDidAppear() {
        Self.launchLog.notice("stage=invitation outcome=visible")
    }

    func sharingPresentationFailed(_ activity: StrimrWatchActivity) {
        sharingDidCancel(activity)
        sharingPresentationActivityID = nil
        reportLaunchError(
            "SharePlay could not present its invitation. Check FaceTime availability and the final signed app's Group Activities authorization.",
            for: activity,
        )
        Self.launchLog.notice("stage=invitation outcome=presentation_failed")
    }

    private func awaitSession(for activity: StrimrWatchActivity) {
        activationDeadline?.cancel()
        activationDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            guard let self, launchGuard.activeID == activity.activityID, !isInSession else { return }
            launchGuard.finish(activity.activityID)
            locallyPreparedActivityIDs.remove(activity.activityID)
            setActivationError(for: activity)
            Self.launchLog.notice("stage=activation outcome=session_not_received")
        }
    }

    @ObservationIgnored private let sessionManager: SessionManager
    @ObservationIgnored private lazy var groupStateObserver = GroupStateObserver()
    @ObservationIgnored private var session: GroupSession<StrimrWatchActivity>?
    @ObservationIgnored private weak var playbackPresenter: (any PlaybackPresenting)?
    @ObservationIgnored private weak var playerController: PlayerController?
    @ObservationIgnored private var sessionSubscriptions: Set<AnyCancellable> = []
    @ObservationIgnored private var sessionListener: Task<Void, Never>?
    @ObservationIgnored private var locallyPreparedActivityIDs: Set<UUID> = []
    @ObservationIgnored private var pendingNextItem: MediaItem?
    @ObservationIgnored private var lastLaunchedActivityID: UUID?
    @ObservationIgnored private var completedInvitationID: UUID?
    private var sharingPresentationActivityID: UUID?
    @ObservationIgnored private var pendingSessionAcceptanceActivityID: UUID?
    @ObservationIgnored private var deferredSessionInvalidation = false
    @ObservationIgnored private var pendingInitialResumeActivityID: UUID?
    @ObservationIgnored private var lastCoordinatedActivityID: UUID?

    init(sessionManager: SessionManager) {
        self.sessionManager = sessionManager
        guard signingUnavailableReason == nil else {
            Self.launchLog.notice("stage=listener outcome=signing_unconfirmed")
            return
        }
        sessionListener = Task { [weak self] in
            for await session in StrimrWatchActivity.sessions() {
                guard !Task.isCancelled else { return }
                await self?.accept(session)
            }
        }
    }

    func configurePlaybackPresenter(_ presenter: any PlaybackPresenting) {
        playbackPresenter = presenter
    }

    func makeCatalogActivity(title: TMDBTitle, episode: TMDBEpisode?, initialPosition: Double) -> StrimrWatchActivity? {
        catalogErrorMessage = nil
        let item = CatalogSharePlayItem(
            tmdbID: title.id,
            isTV: title.kind == .tv,
            season: episode?.season_number,
            episode: episode?.episode_number,
        )
        guard item.isValid, initialPosition.isFinite, initialPosition >= 0 else {
            catalogErrorMessage = "Choose a movie or an exact TV episode before starting SharePlay."
            return nil
        }
        // Legacy server fields remain on the wire for compatibility. Catalog routing never
        // looks up a Plex/Jellyfin server and never includes a source URL or account token.
        let sharedTitle = episode
            .map { "\(title.displayTitle) · S\($0.season_number) E\($0.episode_number) — \($0.name)" }
            ?? title.displayTitle
        return StrimrWatchActivity(
            activityID: UUID(),
            provider: .plex,
            serverIdentifier: "tmdb-catalog",
            ratingKey: item.ratingKey,
            mediaKind: item.mediaKind,
            title: sharedTitle,
            initialPosition: initialPosition,
            catalog: item,
        )
    }

    func presentCatalogActivity(_ activity: StrimrWatchActivity) {
        guard let item = activity.catalog, item.matches(activity) else {
            catalogErrorMessage = "This SharePlay title or episode could not be identified safely."
            return
        }
        lastLaunchedActivityID = activity.activityID
        catalogPlaybackActivity = activity
    }

    func makeActivity(
        ratingKey: String,
        type: MediaKind,
        title: String,
        initialPosition: Double,
        server: ServerIdentity,
    ) -> StrimrWatchActivity? {
        guard sessionManager.registry.services(for: server) != nil else {
            errorMessage = String(localized: "sharePlay.error.serverUnavailable")
            return nil
        }
        return StrimrWatchActivity(
            activityID: UUID(),
            provider: server.provider,
            serverIdentifier: server.id,
            ratingKey: ratingKey,
            mediaKind: type,
            title: title,
            initialPosition: max(0, initialPosition),
        )
    }

    func activate(
        ratingKey: String,
        type: MediaKind,
        title: String,
        initialPosition: Double,
        server: ServerIdentity,
    ) async {
        guard !isActivating else { return }
        #if os(tvOS)
            guard groupStateObserver.isEligibleForGroupSession else {
                errorMessage = String(localized: "sharePlay.tv.guidance")
                return
            }
        #endif
        guard let activity = makeActivity(
            ratingKey: ratingKey,
            type: type,
            title: title,
            initialPosition: initialPosition,
            server: server,
        ) else { return }

        await activate(activity)
    }

    func activate(_ activity: StrimrWatchActivity) async {
        guard checkLaunchAvailability(for: activity), !isActivating,
              launchGuard.begin(activity.activityID) else { return }

        isActivating = true
        locallyPreparedActivityIDs.insert(activity.activityID)
        defer { isActivating = false }

        if let session {
            launchGuard.finish(activity.activityID, cooldown: false)
            session.activity = activity
            handleActivityChange(activity)
            if playerController == nil {
                await launchPlaybackIfNeeded(for: activity)
            }
            return
        }

        do {
            Self.launchLog.notice("stage=preparation outcome=started")
            let preparationResult = await activity.prepareForActivation()
            guard !Task.isCancelled else {
                launchGuard.finish(activity.activityID)
                locallyPreparedActivityIDs.remove(activity.activityID)
                return
            }
            switch preparationResult {
            case .activationPreferred:
                Self.launchLog.notice("stage=activation outcome=started")
                let activated = try await activity.activate()
                if activated {
                    Self.launchLog.notice("stage=activation outcome=waiting_for_session")
                    if !isInSession {
                        awaitSession(for: activity)
                    }
                } else {
                    locallyPreparedActivityIDs.remove(activity.activityID)
                    setActivationError(for: activity)
                }
            case .activationDisabled:
                locallyPreparedActivityIDs.remove(activity.activityID)
                setActivationError(for: activity)
            case .cancelled:
                launchGuard.finish(activity.activityID)
                Self.launchLog.notice("stage=preparation outcome=cancelled")
                locallyPreparedActivityIDs.remove(activity.activityID)
            @unknown default:
                locallyPreparedActivityIDs.remove(activity.activityID)
                setActivationError(for: activity)
            }
        } catch {
            locallyPreparedActivityIDs.remove(activity.activityID)
            launchGuard.finish(activity.activityID)
            guard !Task.isCancelled, !error.isCancellation else { return }
            Self.launchLog.notice("stage=activation outcome=failed")
            setActivationError(for: activity)
        }
    }

    private func setActivationError(for activity: StrimrWatchActivity) {
        launchGuard.finish(activity.activityID)
        Self.launchLog.notice("stage=activation outcome=unavailable")
        if activity.catalog != nil {
            catalogErrorMessage = "SharePlay is unavailable. Check FaceTime access and that both apps are signed with the Group Activities entitlement."
        } else {
            errorMessage = String(localized: "sharePlay.error.unavailable")
        }
    }

    func sharingDidCancel(_ activity: StrimrWatchActivity) {
        launchGuard.finish(activity.activityID)
        locallyPreparedActivityIDs.remove(activity.activityID)
        Self.launchLog.notice("stage=invitation outcome=cancelled")
    }

    func sharingDidComplete(_ activity: StrimrWatchActivity) {
        completedInvitationID = activity.activityID
        Self.launchLog.notice("stage=invitation outcome=completed")
        if !isInSession {
            awaitSession(for: activity)
        }
    }

    func sharingPresentationDidEnd() async {
        guard let activityID = sharingPresentationActivityID else { return }
        sharingPresentationActivityID = nil
        // A cancelled/dismissed sheet must release its reservation; an accepted invitation
        // keeps the activation reservation until a session or bounded timeout arrives.
        if completedInvitationID != activityID, !isInSession {
            locallyPreparedActivityIDs.remove(activityID)
            launchGuard.finish(activityID)
        }
        completedInvitationID = nil
        Self.launchLog.notice("stage=invitation outcome=dismissed")
        guard playerController == nil,
              let activity,
              activity.activityID == activityID
        else { return }
        await launchPlaybackIfNeeded(for: activity)
    }

    func attachPlayer(_ controller: PlayerController, ratingKey: String) {
        playerController = controller
        if let activity, activity.ratingKey == ratingKey {
            controller.configureCatalogSharePlay(activity.catalog != nil, initialTime: activity.initialPosition)
        }
        guard participantCount > 1,
              let session,
              let activity,
              activity.ratingKey == ratingKey
        else { return }
        controller.playbackCoordinator.coordinateWithSession(session)
        controller.beginCoordinatedPlayback(
            identifier: playbackIdentifier(for: activity),
            initialTime: activity.initialPosition,
        )
        lastCoordinatedActivityID = activity.activityID
    }

    func detachPlayer(_ controller: PlayerController) {
        guard playerController === controller else { return }
        playerController = nil
    }

    func playerDidLoad(ratingKey: String) {
        guard let activity, activity.ratingKey == ratingKey else { return }
        if participantCount > 1 {
            playerController?.reconcileCoordinatedPlaybackAfterLoad(
                identifier: playbackIdentifier(for: activity),
                initialTime: activity.initialPosition,
            )
        }
        if locallyPreparedActivityIDs.remove(activity.activityID) != nil {
            if participantCount > 1 {
                playerController?.resume()
            } else {
                pendingInitialResumeActivityID = activity.activityID
            }
        }
    }

    func updateToNextItem(_ item: MediaItem) {
        pendingNextItem = item
        publishPendingNextItemIfLeader()
    }

    private func publishPendingNextItemIfLeader() {
        guard let session, isLocalLeader, let item = pendingNextItem else { return }
        let next = StrimrWatchActivity(
            activityID: UUID(),
            provider: item.provider,
            serverIdentifier: session.activity.serverIdentifier,
            ratingKey: item.id,
            mediaKind: item.kind,
            title: item.title,
            initialPosition: 0,
        )
        locallyPreparedActivityIDs.insert(next.activityID)
        pendingNextItem = nil
        session.activity = next
    }

    func leave() {
        session?.leave()
        detach(continueLocally: false)
    }

    private var isLocalLeader: Bool {
        guard let session else { return false }
        let leader = session.activeParticipants.min {
            $0.id.uuidString < $1.id.uuidString
        }
        return leader?.id == session.localParticipant.id
    }

    private func accept(_ newSession: GroupSession<StrimrWatchActivity>) async {
        guard checkLaunchAvailability(for: newSession.activity) else {
            newSession.leave()
            return
        }
        guard session !== newSession else { return }
        guard launchGuard.canAccept(newSession.activity.activityID) else {
            Self.launchLog.notice("stage=session_access outcome=competing_launch_rejected")
            newSession.leave()
            return
        }
        Self.launchLog.notice("stage=session_access outcome=started")
        let acceptanceActivityID = newSession.activity.activityID
        pendingSessionAcceptanceActivityID = acceptanceActivityID
        do {
            try await ensureAccess(to: newSession.activity)
            guard pendingSessionAcceptanceActivityID == acceptanceActivityID,
                  launchGuard.canAccept(acceptanceActivityID)
            else {
                if pendingSessionAcceptanceActivityID == acceptanceActivityID {
                    pendingSessionAcceptanceActivityID = nil
                }
                newSession.leave()
                return
            }
        } catch {
            guard pendingSessionAcceptanceActivityID == acceptanceActivityID else {
                newSession.leave()
                return
            }
            pendingSessionAcceptanceActivityID = nil
            locallyPreparedActivityIDs.remove(newSession.activity.activityID)
            if Task.isCancelled || error.isCancellation {
                if deferredSessionInvalidation {
                    deferredSessionInvalidation = false
                    detach(continueLocally: true)
                }
                return
            }
            launchGuard.finish(acceptanceActivityID)
            Self.launchLog.notice("stage=session_access outcome=failed")
            if newSession.activity.catalog != nil {
                catalogErrorMessage = "This SharePlay movie or episode is unavailable. Check TMDb setup and access to your own playback sources."
            } else {
                errorMessage = String(localized: "sharePlay.error.mediaUnavailable")
            }
            newSession.leave()
            if deferredSessionInvalidation {
                deferredSessionInvalidation = false
                detach(continueLocally: true)
            }
            return
        }

        let previousSession = session
        sessionSubscriptions.removeAll()
        if previousSession != nil,
           previousSession !== newSession,
           playerController?.isCoordinatedPlayback == true
        {
            playerController?.endCoordinatedPlayback(continueLocally: true)
        }
        previousSession?.leave()
        session = newSession
        handleActivityChange(newSession.activity)
        isInSession = true
        participantCount = newSession.activeParticipants.count
        pendingSessionAcceptanceActivityID = nil
        deferredSessionInvalidation = false

        newSession.$activity
            .receive(on: DispatchQueue.main)
            .sink { [weak self] activity in self?.handleActivityChange(activity) }
            .store(in: &sessionSubscriptions)

        newSession.$activeParticipants
            .receive(on: DispatchQueue.main)
            .sink { [weak self] participants in
                guard let self else { return }
                let previousCount = participantCount
                participantCount = participants.count
                handleParticipantCountChange(previousCount: previousCount)
                publishPendingNextItemIfLeader()
            }
            .store(in: &sessionSubscriptions)

        newSession.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard case .invalidated = state, let self, session === newSession else { return }
                if pendingSessionAcceptanceActivityID != nil {
                    deferredSessionInvalidation = true
                    return
                }
                detach(continueLocally: true)
            }
            .store(in: &sessionSubscriptions)

        Self.launchLog.notice("stage=session_join outcome=requested")
        newSession.join()
        activationDeadline?.cancel()
        launchGuard.finish(acceptanceActivityID, cooldown: false)
        if let playerController, let activity {
            if participantCount > 1 {
                playerController.playbackCoordinator.coordinateWithSession(newSession)
                playerController.beginCoordinatedPlayback(
                    identifier: playbackIdentifier(for: activity),
                    initialTime: activity.initialPosition,
                )
                lastCoordinatedActivityID = activity.activityID
            }
        } else if sharingPresentationActivityID != newSession.activity.activityID {
            await launchPlaybackIfNeeded(for: newSession.activity)
        }
    }

    private func launchPlaybackIfNeeded(for activity: StrimrWatchActivity) async {
        guard lastLaunchedActivityID != activity.activityID else { return }
        if activity.catalog != nil {
            presentCatalogActivity(activity); return
        }
        guard let playbackPresenter else { return }
        lastLaunchedActivityID = activity.activityID
        do {
            let services = try await resolvedServices(for: activity)
            await PlaybackLauncher(services: services, coordinator: playbackPresenter).play(
                ratingKey: activity.ratingKey,
                type: activity.mediaKind,
                shouldResumeFromOffset: false,
                allowsExternalPlayer: false,
            )
        } catch {
            guard !Task.isCancelled, !error.isCancellation else { return }
            ErrorReporter.capture(error)
            errorMessage = String(localized: "sharePlay.error.mediaUnavailable")
        }
    }

    private func ensureAccess(to activity: StrimrWatchActivity) async throws {
        if let item = activity.catalog {
            guard item.matches(activity) else { throw SharePlayError.mediaUnavailable }
            let reference = TMDBTitle.reference(id: item.tmdbID, kind: item.isTV ? .tv : .movie, title: activity.title)
            _ = try await TMDBClient.shared.details(reference)
            return
        }
        let services = try await resolvedServices(for: activity)
        _ = try await services.detail.mediaItem(id: activity.ratingKey)
    }

    func playerViewModel(for activity: StrimrWatchActivity) async throws -> PlayerViewModel {
        let services = try await resolvedServices(for: activity)
        let queue = try await services.playback.queue(
            startingWith: activity.ratingKey,
            kind: activity.mediaKind,
            shuffle: false,
        )
        guard !queue.items.isEmpty else { throw SharePlayError.mediaUnavailable }
        return PlayerViewModel(
            queue: queue,
            services: services,
            shouldResumeFromOffset: false,
        )
    }

    /// Any server of the active profile can host the activity, Plex or Jellyfin.
    private func resolvedServices(for activity: StrimrWatchActivity) async throws -> MediaServices {
        let server = ServerIdentity(provider: activity.provider, id: activity.serverIdentifier)
        guard let services = sessionManager.registry.services(for: server) else {
            throw SharePlayError.serverUnavailable
        }
        return services
    }

    private func handleActivityChange(_ newActivity: StrimrWatchActivity) {
        guard activity != newActivity else { return }
        let isReplacingActivity = activity != nil
        activity = newActivity
        pendingNextItem = nil
        activityChangeID = UUID()

        // Publish the new coordinated item as soon as the GroupActivity changes. Waiting for the
        // replacement media to finish loading leaves each participant coordinated against the old
        // item, so a seek can be applied locally while peers reject it for an identifier mismatch.
        // AetherEngine retains commands for this item until the replacement transport is ready.
        if newActivity.catalog == nil {
            playerController?.configureCatalogSharePlay(false, initialTime: newActivity.initialPosition)
        }
        if isReplacingActivity, newActivity.catalog == nil,
           participantCount > 1,
           let playerController,
           playerController.isCoordinatedPlayback
        {
            playerController.beginCoordinatedPlayback(
                identifier: playbackIdentifier(for: newActivity),
                initialTime: newActivity.initialPosition,
            )
            lastCoordinatedActivityID = newActivity.activityID
        }
        if newActivity.catalog != nil, session != nil, playerController == nil,
           sharingPresentationActivityID == nil
        {
            presentCatalogActivity(newActivity)
        }
    }

    private func playbackIdentifier(for activity: StrimrWatchActivity) -> String {
        activity.activityID.uuidString
    }

    private func handleParticipantCountChange(previousCount: Int) {
        guard let playerController else { return }

        if participantCount <= 1 {
            if playerController.isCoordinatedPlayback {
                playerController.endCoordinatedPlayback(continueLocally: true)
            }
            return
        }

        guard previousCount <= 1,
              let session,
              let activity
        else { return }
        if playerController.isCoordinatedPlayback {
            playerController.endCoordinatedPlayback(continueLocally: true)
        }
        let shouldResumeInitialPlayback = pendingInitialResumeActivityID == activity.activityID
        // A first-time participant can reach this point while its media is still loading and its
        // local clock is zero. Use the activity's advertised progress for that first binding; only
        // preserve the local clock when reconnecting to an activity that was already coordinated.
        let isRejoiningCoordinatedActivity = lastCoordinatedActivityID == activity.activityID
        playerController.playbackCoordinator.coordinateWithSession(session)
        if shouldResumeInitialPlayback || isRejoiningCoordinatedActivity {
            pendingInitialResumeActivityID = nil
            playerController.beginCoordinatedPlaybackResumingFromCurrentState(
                identifier: playbackIdentifier(for: activity),
            )
        } else {
            playerController.beginCoordinatedPlayback(
                identifier: playbackIdentifier(for: activity),
                initialTime: activity.initialPosition,
            )
        }
        lastCoordinatedActivityID = activity.activityID
    }

    private func detach(continueLocally: Bool) {
        if !continueLocally {
            catalogPlaybackActivity = nil
        }
        let continuingPlayer = continueLocally ? playerController : nil
        if playerController?.isCoordinatedPlayback == true {
            playerController?.endCoordinatedPlayback(continueLocally: continueLocally)
        }
        playerController = continuingPlayer
        pendingNextItem = nil
        pendingInitialResumeActivityID = nil
        session = nil
        activity = nil
        isInSession = false
        participantCount = 0
        sessionSubscriptions.removeAll()
    }
}

enum SharePlayError: Error {
    case serverUnavailable
    case mediaUnavailable
}
