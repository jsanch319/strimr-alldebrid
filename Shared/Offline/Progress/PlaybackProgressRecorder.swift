import Foundation

/// Records playback progress: every event goes to the local journal and watch state first (so
/// "Continue watching" and progress bars are immediately right), then is pushed live when the owner's server is
/// reachable. Unsynced entries are replayed by `ProgressSynchronizer`.
@MainActor
final class PlaybackProgressRecorder {
    static let watchedThreshold = 0.9

    private let owner: MediaOwner?
    private let itemID: String
    private let media: MediaItem?
    private let store: OfflineStore?
    private let coordinator: OfflineCoordinator?
    private let pushesImmediately: Bool
    private var duration: TimeInterval?
    private let completionThreshold: Double
    private var hasStarted = false
    private var hasReportedWatched = false
    private var pushTask: Task<Void, Never>?

    /// Alternative destination for server-free media. The recorder's validation, event ordering and
    /// completion rules are shared; Simkl's existing channel remains the only network writer.
    struct Destination {
        let resumePosition: () -> TimeInterval?
        let checkpoint: (TimeInterval, TimeInterval?, ProgressJournalEvent) -> Void
    }

    private var destination: Destination?

    init(destination: Destination, duration: TimeInterval?, watchedThreshold: Double = 1) {
        completionThreshold = watchedThreshold
        owner = nil; itemID = ""; media = nil; store = nil; coordinator = nil
        pushesImmediately = false
        self.destination = destination
        self.duration = duration
    }

    init(
        owner: MediaOwner,
        itemID: String,
        duration: TimeInterval?,
        media: MediaItem? = nil,
        pushesImmediately: Bool = true,
        store: OfflineStore,
        coordinator: OfflineCoordinator,
    ) {
        completionThreshold = Self.watchedThreshold
        self.owner = owner
        self.itemID = itemID
        self.media = media
        self.duration = duration
        self.pushesImmediately = pushesImmediately
        self.store = store
        self.coordinator = coordinator
    }

    /// Keeps the position of a stream interrupted by a lost server, so the download resumes there and the server is
    /// caught up by the synchronization.
    static func recordInterruptedStream(
        owner: MediaOwner,
        itemID: String,
        position: TimeInterval,
        duration: TimeInterval?,
        media: MediaItem? = nil,
        store: OfflineStore,
    ) {
        guard position.isFinite, position > 0 else { return }
        let now = Date()
        let previous = store.watchState(itemID: itemID, owner: owner)
        if let media {
            store.savePlaybackProgress(
                media: media,
                owner: owner,
                position: position,
                duration: duration,
                lastWatchedAt: now,
                isCompleted: false,
            )
        } else {
            store.setWatchState(
                OfflineWatchState(
                    viewOffset: position,
                    viewCount: previous?.viewCount ?? 0,
                    played: previous?.played ?? false,
                    lastViewedAt: now,
                    source: .local,
                ),
                itemID: itemID,
                owner: owner,
            )
        }
        _ = store.appendJournal(
            itemID: itemID,
            owner: owner,
            position: position,
            duration: duration,
            event: .stop,
            occurredAt: now,
            syncedAt: nil,
        )
    }

    /// Resume position using the same rules as streaming: finished items restart from the beginning.
    var resumePosition: TimeInterval? {
        if let destination {
            return destination.resumePosition()
        }
        guard let store, let owner else { return nil }
        return store.resumePosition(owner: owner, itemID: itemID, fallbackDuration: duration)
    }

    @discardableResult
    func record(position: TimeInterval, duration: TimeInterval?, isPaused: Bool) -> Int64? {
        guard position.isFinite, position >= 0 else {
            ErrorReporter.capture(PlaybackProgressPersistenceError.invalidRecord)
            return nil
        }
        if let duration, duration.isFinite, duration > 0 {
            self.duration = duration
        }
        if destination != nil, hasReportedWatched {
            return nil
        }
        // The player reports position 0 before seeking to the resume point; do not let it erase local progress.
        guard hasStarted || position >= 1 else { return nil }
        let event: ProgressJournalEvent
        let reportState: ItemPlaybackReportState
        if !hasStarted {
            hasStarted = true
            event = .start
            reportState = .started
        } else {
            event = isPaused ? .pause : .progress
            reportState = .progress
        }
        let journalID = write(
            event: event,
            position: position,
            reportState: reportState,
            isPaused: isPaused,
            pushesImmediately: pushesImmediately,
        )
        checkWatchedThreshold(position: position)
        return journalID
    }

    @discardableResult
    func stop(position: TimeInterval, pushesImmediately: Bool? = nil) -> Int64? {
        guard position.isFinite, position >= 0 else {
            ErrorReporter.capture(PlaybackProgressPersistenceError.invalidRecord)
            return nil
        }
        guard hasStarted else { return nil }
        if destination != nil, hasReportedWatched {
            return nil
        }
        let journalID = write(
            event: .stop,
            position: position,
            reportState: .stopped,
            isPaused: true,
            pushesImmediately: pushesImmediately ?? self.pushesImmediately,
        )
        checkWatchedThreshold(position: position)
        return journalID
    }

    @discardableResult
    func finish(pushesImmediately: Bool? = nil) -> Int64? {
        let position = duration ?? 0
        var journalID: Int64?
        if hasStarted {
            journalID = write(
                event: .stop,
                position: position,
                reportState: .stopped,
                isPaused: true,
                pushesImmediately: pushesImmediately ?? self.pushesImmediately,
            )
        }
        markWatched()
        return journalID
    }

    func markSynced(_ journalID: Int64?) {
        guard let journalID else { return }
        store?.markJournalSynced(ids: [journalID])
    }

    private func checkWatchedThreshold(position: TimeInterval) {
        guard let duration, duration > 0, position / duration >= completionThreshold else { return }
        markWatched()
    }

    private func markWatched() {
        guard !hasReportedWatched else { return }
        hasReportedWatched = true
        if let destination {
            destination.checkpoint(duration ?? 0, duration, .watched)
            return
        }
        guard let store, let owner else { return }
        let now = Date()
        let previous = store.watchState(itemID: itemID, owner: owner)
        store.setWatchState(
            OfflineWatchState(
                viewOffset: nil,
                viewCount: (previous?.viewCount ?? 0) + 1,
                played: true,
                lastViewedAt: now,
                source: .local,
            ),
            itemID: itemID,
            owner: owner,
        )
        if let media {
            store.savePlaybackProgress(
                media: media,
                owner: owner,
                position: duration ?? 0,
                duration: duration,
                lastWatchedAt: now,
                isCompleted: true,
            )
        }
        let journalID = store.appendJournal(
            itemID: itemID,
            owner: owner,
            position: duration ?? 0,
            duration: duration,
            event: .watched,
            occurredAt: now,
            syncedAt: nil,
        )
        push(journalID: journalID) { services, itemID in
            try await services.playback.markItemWatched(itemID: itemID, at: now)
            TrackerCoordinator.shared.noteWatched(itemID: itemID, at: now, detail: services.detail)
        }
    }

    private func write(
        event: ProgressJournalEvent,
        position: TimeInterval,
        reportState: ItemPlaybackReportState,
        isPaused: Bool,
        pushesImmediately: Bool,
    ) -> Int64? {
        if let destination {
            destination.checkpoint(position, duration, event)
            return nil
        }
        guard let store, let owner else { return nil }
        let now = Date()
        let previous = store.watchState(itemID: itemID, owner: owner)
        if let media {
            store.savePlaybackProgress(
                media: media,
                owner: owner,
                position: position,
                duration: duration,
                lastWatchedAt: now,
                isCompleted: false,
            )
        } else {
            store.setWatchState(
                OfflineWatchState(
                    viewOffset: position,
                    viewCount: previous?.viewCount ?? 0,
                    played: previous?.played ?? false,
                    lastViewedAt: now,
                    source: .local,
                ),
                itemID: itemID,
                owner: owner,
            )
        }
        let journalID = store.appendJournal(
            itemID: itemID,
            owner: owner,
            position: position,
            duration: duration,
            event: event,
            occurredAt: now,
            syncedAt: nil,
        )
        guard pushesImmediately else { return journalID }
        let duration = duration
        push(journalID: journalID) { services, itemID in
            try await services.playback.reportItemPlayback(
                itemID: itemID,
                state: reportState,
                position: position,
                duration: duration,
                isPaused: isPaused,
            )
        }
        return journalID
    }

    private func push(
        journalID: Int64?,
        _ operation: @escaping @MainActor (MediaServices, String) async throws -> Void,
    ) {
        guard let journalID, let store, let owner, let coordinator,
              let services = coordinator.reachableServices(for: owner) else { return }
        let previousTask = pushTask
        let itemID = itemID
        pushTask = Task { @MainActor in
            await previousTask?.value
            do {
                try await operation(services, itemID)
                store.markJournalSynced(ids: [journalID])
                if store.pendingJournal(owner: owner).allSatisfy({ $0.itemID != itemID }),
                   var state = store.watchState(itemID: itemID, owner: owner)
                {
                    state.source = .server
                    store.setWatchState(state, itemID: itemID, owner: owner)
                }
            } catch {
                guard !Task.isCancelled, !error.isCancellation else { return }
                if error.isTransportFailure {
                    coordinator.reportTransportFailure(on: owner.server)
                } else {
                    store.markJournalFailed(ids: [journalID], error: String(describing: type(of: error)))
                    ErrorReporter.capture(error)
                }
            }
        }
    }
}
