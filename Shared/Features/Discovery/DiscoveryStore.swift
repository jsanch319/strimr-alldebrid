import Foundation
import Observation

nonisolated struct CatalogProgress: Codable, Identifiable, Sendable {
    let title: TMDBTitle
    let episode: TMDBEpisode?
    var position: Double
    var duration: Double?
    var completed: Bool
    var remotePercentage: Double?
    var pendingSync: Bool?
    var checkpointEvent: String?
    var updatedAt: Date
    /// Last device-recorded timestamp, retained even when a newer remote session is selected.
    struct ExactCheckpoint: Codable, Sendable {
        let position: Double
        let duration: Double?
        let updatedAt: Date
    }

    var localCheckpoint: ExactCheckpoint?
    var locallyCleared: Bool?
    var acknowledgedAt: Date?

    var exactCheckpoint: ExactCheckpoint? {
        if let localCheckpoint {
            return localCheckpoint
        }
        // Migrate checkpoints written before source provenance was recorded.
        guard checkpointEvent != nil || remotePercentage == nil else { return nil }
        return ExactCheckpoint(position: position, duration: duration, updatedAt: updatedAt)
    }

    var usesExactPosition: Bool {
        guard let checkpoint = exactCheckpoint else { return false }
        return checkpoint.position.isFinite && checkpoint.position >= 0 && checkpoint.updatedAt >= updatedAt
    }

    var resumeOffset: Double? {
        guard !completed, locallyCleared != true, usesExactPosition else { return nil }
        return exactCheckpoint?.position
    }

    var resumePercentage: Double? {
        guard !completed, locallyCleared != true, !usesExactPosition else { return nil }
        return remotePercentage
    }

    var id: String {
        Self.key(title: title, episode: episode)
    }

    static func key(title: TMDBTitle, episode: TMDBEpisode?) -> String {
        title.catalogID + (episode.map { ":s\($0.season_number):e\($0.episode_number)" } ?? "")
    }

    var fraction: Double {
        if let remotePercentage, !usesExactPosition {
            return remotePercentage / 100
        }
        guard let duration, duration > 0 else { return 0 }; return min(1, position / duration)
    }
}

@MainActor
@Observable
final class CatalogProgressStore {
    static let shared: CatalogProgressStore = {
        #if DEBUG && os(iOS) && targetEnvironment(simulator)
            if CatalogVisualFixtures.isEnabled {
                let suite = "strimr.visual-progress"
                let defaults = UserDefaults(suiteName: suite)!
                defaults.removePersistentDomain(forName: suite)
                return CatalogProgressStore(defaults: defaults)
            }
        #endif
        return CatalogProgressStore()
    }()

    private(set) var revision = 0
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func records(scope: String) -> [CatalogProgress] {
        guard let data = defaults.data(forKey: "strimr.catalog.progress.\(scope)") else { return [] }
        return (try? JSONDecoder().decode([CatalogProgress].self, from: data)) ?? []
    }

    /// Presentation-only suppression, separate from resume/history and remote synchronization.
    private func dismissedTitles(scope: String) -> Set<String> {
        Set(defaults.stringArray(forKey: "strimr.catalog.continue-dismissed.\(scope)") ?? [])
    }

    func dismissFromContinueWatching(title: TMDBTitle, scope: String) {
        var dismissed = dismissedTitles(scope: scope)
        guard dismissed.insert(title.catalogID).inserted else { return }
        defaults.set(dismissed.sorted(), forKey: "strimr.catalog.continue-dismissed.\(scope)")
        revision += 1
    }

    private func restoreToContinueWatching(title: TMDBTitle, scope: String) {
        var dismissed = dismissedTitles(scope: scope)
        guard dismissed.remove(title.catalogID) != nil else { return }
        defaults.set(dismissed.sorted(), forKey: "strimr.catalog.continue-dismissed.\(scope)")
        revision += 1
    }

    func continueWatchingRecords(scope: String) -> [CatalogProgress] {
        let dismissed = dismissedTitles(scope: scope)
        var seen: Set<String> = []
        return records(scope: scope).sorted {
            $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt
        }.filter { record in
            guard record.title.kind == .movie || record.episode != nil,
                  seen.insert(record.title.catalogID).inserted else { return false }
            return !dismissed.contains(record.title.catalogID) && !record.completed && record.locallyCleared != true
                && (record.fraction > 0 || record.position > 0)
        }
    }

    func progress(title: TMDBTitle, episode: TMDBEpisode?, scope: String) -> CatalogProgress? {
        records(scope: scope).first { $0.id == CatalogProgress.key(title: title, episode: episode) }
    }

    func save(
        title: TMDBTitle,
        episode: TMDBEpisode?,
        position: Double,
        duration: Double?,
        finished: Bool,
        scope: String,
        event: String = "stop",
        protectInitialZero: Bool = true,
    ) {
        guard position.isFinite, position >= 0 else { return }
        let validDuration = duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let previous = progress(title: title, episode: episode, scope: scope)
        // A transient zero before the engine seeks must not erase a saved resume point.
        if protectInitialZero, position < 1, previous?.position ?? 0 > 1, !finished {
            return
        }
        let now = Date()
        let record = CatalogProgress(
            title: title,
            episode: episode,
            position: position,
            duration: validDuration ?? previous?.duration,
            completed: finished || validDuration.map { position / $0 >= 1 } == true,
            remotePercentage: nil,
            pendingSync: true,
            checkpointEvent: event,
            updatedAt: now,
            localCheckpoint: .init(position: position, duration: validDuration ?? previous?.duration, updatedAt: now),
            locallyCleared: false,
        )
        var records = records(scope: scope).filter { $0.id != record.id }
        records.insert(record, at: 0)
        defaults.set(try? JSONEncoder().encode(records), forKey: "strimr.catalog.progress.\(scope)")
        revision += 1
    }

    /// A zero-position checkpoint fences off older remote pauses before a deliberate replay begins.
    func restart(title: TMDBTitle, episode: TMDBEpisode?, scope: String) {
        save(
            title: title,
            episode: episode,
            position: 0,
            duration: progress(title: title, episode: episode, scope: scope)?.duration,
            finished: false,
            scope: scope,
            event: "restart",
            protectInitialZero: false,
        )
    }

    func clear(title: TMDBTitle, episode: TMDBEpisode?, scope: String) {
        restart(title: title, episode: episode, scope: scope)
        var all = records(scope: scope)
        guard let index = all.firstIndex(where: { $0.id == CatalogProgress.key(title: title, episode: episode) })
        else { return }
        all[index].locallyCleared = true
        all[index].pendingSync = false
        replace(all, scope: scope)
    }

    private var activeKeys: Set<String> = []
    func isActive(_ record: CatalogProgress, scope: String) -> Bool {
        activeKeys.contains(scope + "|" + record.id)
    }

    func endPlayback(title: TMDBTitle, episode: TMDBEpisode?, scope: String) {
        activeKeys.remove(scope + "|" + CatalogProgress.key(title: title, episode: episode))
    }

    func replace(_ records: [CatalogProgress], scope: String) {
        defaults.set(
            try? JSONEncoder().encode(records.sorted { $0.updatedAt > $1.updatedAt }),
            forKey: "strimr.catalog.progress.\(scope)",
        )
        revision += 1
    }

    func acknowledge(_ report: TrackerPlaybackReport, scope: String) {
        guard report.event == .pause || report.event == .stop, let tmdb = report.item.ids.tmdb else { return }
        var records = records(scope: scope)
        guard let index = records.firstIndex(where: {
            String($0.title.id) == tmdb && ($0.title.kind == .movie) == (report.item.kind == .movie) &&
                $0.episode?.season_number == report.item.season && $0.episode?.episode_number == report.item.episode
        }), records[index].updatedAt <= report.date else { return }
        records[index].pendingSync = false
        records[index].remotePercentage = report.progress
        records[index].acknowledgedAt = Date()
        replace(records, scope: scope)
    }

    func makeRecorder(title: TMDBTitle, episode: TMDBEpisode?, scope: String) -> PlaybackProgressRecorder {
        let key = CatalogProgress.key(title: title, episode: episode)
        activeKeys.insert(scope + "|" + key)
        let destination = PlaybackProgressRecorder.Destination(
            resumePosition: { [weak self] in
                guard let record = self?.progress(title: title, episode: episode, scope: scope),
                      !record.completed else { return nil }
                return record.resumeOffset
            },
            checkpoint: { [weak self] position, duration, event in
                // Only a new, validated player session restores visibility. Sync/replay, failed
                // source selection, restarts and an already-running session cannot undo removal.
                if event == .start {
                    self?.restoreToContinueWatching(title: title, scope: scope)
                }
                self?.save(
                    title: title,
                    episode: episode,
                    position: position,
                    duration: duration,
                    finished: event == .watched,
                    scope: scope,
                    event: event.rawValue,
                    protectInitialZero: false,
                )
                if event == .stop || event == .watched {
                    self?.activeKeys.remove(scope + "|" + key)
                }
            },
        )
        return PlaybackProgressRecorder(
            destination: destination,
            duration: progress(title: title, episode: episode, scope: scope)?.duration,
        )
    }
}

/// Persisted per profile and Simkl account. Incremental pulls are always gated by activities.
@MainActor
@Observable
final class DiscoveryStore {
    static let shared = DiscoveryStore()
    private struct Snapshot: Codable {
        var activities: SimklActivities
        var entries: [SimklListEntry]
    }

    private(set) var entries: [SimklListEntry] = []
    private(set) var artwork: [String: TMDBTitle] = [:]
    private(set) var isSyncing = false
    var errorMessage: String?
    private var snapshot: Snapshot?
    private var loadedScope: String?
    private var lastSync: Date?
    private var retryAt: Date?
    private let defaults: UserDefaults
    private let coordinator: TrackerCoordinator
    private let tmdb: TMDBClient
    private let progress: CatalogProgressStore
    private var syncTask: Task<Void, Never>?
    init(
        defaults: UserDefaults = .standard,
        coordinator: TrackerCoordinator? = nil,
        tmdb: TMDBClient = .shared,
        progress: CatalogProgressStore? = nil,
    ) {
        self.defaults = defaults
        self.coordinator = coordinator ?? .shared
        self.tmdb = tmdb
        self.progress = progress ?? .shared
    }

    var scope: String {
        (coordinator.activeProfileID ?? TrackerCoordinator.allDebridProfileID) + ":" +
            (coordinator.state(for: .simkl).settings.username ?? "local")
    }

    var accountKey: String {
        let state = coordinator.state(for: .simkl)
        return "\(scope):\(state.isConnected):\(state.settings.isEnabled)"
    }

    var planned: [SimklListEntry] {
        entries.filter(\.isPlanned)
    }

    var nextUp: [SimklListEntry] {
        entries.filter { $0.nextEpisode != nil }
    }

    func entry(for title: TMDBTitle) -> SimklListEntry? {
        entries.first { $0.catalogID == title.catalogID }
    }

    func title(for entry: SimklListEntry) -> TMDBTitle? {
        guard let raw = entry.media?.ids.tmdb, let id = Int(raw), id > 0 else { return nil }
        return artwork["\(entry.kind.rawValue):\(id)"] ?? .reference(
            id: id,
            kind: entry.kind,
            title: entry.media?.title ?? "Untitled",
            year: entry.media?.year,
        )
    }

    func sync(force: Bool = false) async {
        #if DEBUG && os(iOS) && targetEnvironment(simulator)
            if CatalogVisualFixtures.isEnabled {
                entries = CatalogVisualFixtures.entries
                artwork = Dictionary(uniqueKeysWithValues: CatalogVisualFixtures.titles.map { ($0.catalogID, $0) })
                CatalogVisualFixtures.seedProgress(progress, scope: scope)
                return
            }
        #endif
        let currentScope = scope
        if loadedScope != currentScope {
            syncTask?.cancel(); syncTask = nil
            loadedScope = currentScope
            snapshot = defaults.data(forKey: "strimr.simkl.library.\(currentScope)")
                .flatMap { try? JSONDecoder().decode(
                    Snapshot.self,
                    from: $0,
                ) }
            entries = snapshot?.entries ?? []; artwork = [:]; lastSync = nil; retryAt = nil
        }
        guard let client = coordinator.simklLibraryClient else {
            entries = []; snapshot = nil; artwork = [:]
            loadedScope = nil; lastSync = nil; retryAt = nil
            return
        }
        if let syncTask {
            await syncTask.value; return
        }
        if let retryAt, retryAt > Date() {
            return
        }
        guard force || (lastSync.map { Date().timeIntervalSince($0) > 60 } ?? true) else { return }
        let task = Task { await pull(client: client, scope: currentScope) }
        syncTask = task
        await task.value
        if loadedScope == currentScope {
            syncTask = nil
        }
    }

    private func pull(client: SimklClient, scope: String) async {
        isSyncing = true; errorMessage = nil
        defer { isSyncing = false }
        do {
            await coordinator.flushCatalogPlaybackReports()
            let activities = try await client.activities() // Capture BEFORE the pull to avoid lost concurrent writes.
            if snapshot?.activities != activities || snapshot == nil {
                var merged = snapshot?.entries ?? []
                let since = snapshot?.activities.all
                for type in ["movies", "shows"] {
                    let delta = try await client.library(type: type, since: since)
                    let changed = Set(delta.map(\.id))
                    let catalogIDs = Set(delta.compactMap(\.catalogID))
                    merged.removeAll { changed.contains($0.id) || $0.catalogID.map { catalogIDs.contains($0) } == true }
                    merged += delta
                }
                if let old = snapshot?.activities, old.removals != activities.removals {
                    var remaining = Set<String>()
                    for type in ["movies", "shows"] {
                        let ids = try await client.library(type: type, idsOnly: true)
                        remaining.formUnion(ids.map(\.id))
                    }
                    merged.removeAll { !remaining.contains($0.id) }
                }
                try Task.checkCancellation()
                guard self.scope == scope, coordinator.simklLibraryClient === client else { return }
                snapshot = Snapshot(activities: activities, entries: merged)
                entries = merged
                try defaults.set(JSONEncoder().encode(snapshot), forKey: "strimr.simkl.library.\(scope)")
            }
            // A full saved-playback snapshot detects clears, rewinds and updates made on another Apple device.
            let paused = try await client.pausedPlaybacks()
            let result = await progress.reconcile(
                paused: paused,
                entries: entries,
                scope: scope,
                activities: activities,
                tmdb: tmdb,
                isCurrent: { self.scope == scope && self.coordinator.simklLibraryClient === client },
                replay: { item, percent, date in
                    guard self.scope == scope, self.coordinator.simklLibraryClient === client else { return false }
                    return await self.coordinator.replayCatalogCheckpoint(item: item, progress: percent, date: date)
                },
            )
            if result.replayed {
                let refreshed = try await client.pausedPlaybacks()
                _ = await progress.reconcile(
                    paused: refreshed,
                    entries: entries,
                    scope: scope,
                    activities: activities,
                    tmdb: tmdb,
                    isCurrent: { self.scope == scope && self.coordinator.simklLibraryClient === client },
                    replay: { _, _, _ in false },
                )
            }
            if result
                .unmapped >
                0
            {
                errorMessage =
                    "Some Simkl playbacks have no verified TMDb/episode mapping and cannot be resumed automatically."
            }
            lastSync = Date()
            // Only hydrate visible rails; My List can fetch additional metadata on demand.
            for entry in Array((planned + nextUp).prefix(40)) {
                guard let reference = title(for: entry), artwork[reference.catalogID] == nil else { continue }
                do {
                    let title = try await tmdb.details(reference)
                    try Task.checkCancellation()
                    guard self.scope == scope else { return }
                    artwork[title.catalogID] = title
                } catch is CancellationError { throw CancellationError() }
                catch { break } // TMDb setup/rate errors must not discard a successful Simkl sync.
            }
        } catch {
            guard self.scope == scope, !Task.isCancelled else { return }
            if case let TrackerAPIError.rateLimited(delay) = error {
                retryAt = Date().addingTimeInterval(delay ?? 60)
            } else {
                retryAt = Date().addingTimeInterval(60)
            }
            errorMessage = "Simkl sync failed. Cached lists and resume positions are retained; cross-device progress could not be refreshed. \(error.localizedDescription)"
        }
    }

    func markWatched(_ title: TMDBTitle, episode: TMDBEpisode?) async throws {
        guard let client = coordinator.simklLibraryClient,
              let item = title.trackerItem(episode: episode) else { throw TrackerAPIError.unavailable }
        let scope = scope
        await syncTask?.value
        guard self.scope == scope, coordinator.simklLibraryClient === client else { throw TrackerAPIError.unavailable }
        let now = Date()
        try await client.markCatalogWatched(title, episode: episode, at: now)
        guard self.scope == scope, coordinator.simklLibraryClient === client else { return }
        let saved = progress.progress(title: title, episode: episode, scope: scope)
        let duration = saved?.duration ?? (episode?.runtime ?? title.runtimeMinutes).map { Double($0) * 60 }
        progress.save(
            title: title,
            episode: episode,
            position: duration ?? saved?.position ?? 0,
            duration: duration,
            finished: true,
            scope: scope,
            event: "watched",
            protectInitialZero: false,
        )
        progress.acknowledge(TrackerPlaybackReport(event: .stop, item: item, progress: 100, date: Date()), scope: scope)
        lastSync = nil; retryAt = nil
        await sync(force: true)
    }

    func setPlanned(_ title: TMDBTitle, planned: Bool) async throws {
        guard let client = coordinator.simklLibraryClient else { throw TrackerAPIError.unavailable }
        let scope = scope
        await syncTask?.value
        guard self.scope == scope, coordinator.simklLibraryClient === client else { throw TrackerAPIError.unavailable }
        try await client.setPlanned(title, planned: planned)
        guard self.scope == scope, coordinator.simklLibraryClient === client else { return }
        // Apply a confirmed write locally, retaining the pre-write checkpoint for the next delta.
        var changed = entry(for: title) ?? SimklListEntry.planned(title)
        changed.status = "plantowatch"
        entries.removeAll { $0.catalogID == title.catalogID }
        if planned {
            entries.append(changed)
        }
        if snapshot != nil {
            snapshot?.entries = entries
            try defaults.set(JSONEncoder().encode(snapshot), forKey: "strimr.simkl.library.\(scope)")
        }
        lastSync = nil
        retryAt = nil
        await sync(force: true)
    }
}

extension CatalogProgressStore {
    /// Shares the server journal's newest-change conflict rule, while retaining device checkpoints
    /// when Simkl expires a paused session. Remote absence is not an instruction to delete local progress.
    func reconcile(
        paused: [SimklPausedPlayback], entries: [SimklListEntry], scope: String,
        activities _: SimklActivities, tmdb: TMDBClient,
        isCurrent: () -> Bool = { true },
        replay: (TrackerItem, Double, Date) async -> Bool,
    ) async -> (replayed: Bool, unmapped: Int) {
        let local = records(scope: scope)
        var resolved: [String: CatalogProgress] = [:]
        var unmapped = 0
        for (index, pause) in paused.enumerated() {
            guard isCurrent(), !Task.isCancelled else { return (false, unmapped) }
            guard let media = pause.media, media.anime_type == nil,
                  pause.type == "movie" || pause.type == "episode",
                  let date = pause.date else { unmapped += 1; continue }
            let cached = local.first { pause.matches($0.title, episode: $0.episode) }
            let library = entries.first { entry in
                guard entry.kind == pause.kind, let ids = entry.media?.ids else { return false }
                return (ids.simkl != nil && ids.simkl == media.ids.simkl) ||
                    (ids.tmdb != nil && ids.tmdb == media.ids.tmdb) || (
                        ids.imdb != nil && ids.imdb == media.ids.imdb
                    ) ||
                    (ids.tvdb != nil && ids.tvdb == media.ids.tvdb)
            }
            var title = cached?.title
            if title == nil, let raw = media.ids.tmdb ?? library?.media?.ids.tmdb, let id = Int(raw), id > 0 {
                title = .reference(id: id, kind: pause.kind, title: media.title ?? "Untitled", year: media.year)
            }
            if title ==
                nil
            {
                title = try? await tmdb.find(imdb: media.ids.imdb, tvdb: media.ids.tvdb, kind: pause.kind)
            }
            guard var title else { unmapped += 1; continue }
            if let detail = try? await tmdb.details(title) {
                title = detail
            }
            var episode: TMDBEpisode?
            if pause.kind == .tv {
                guard let remote = pause.episode,
                      let season = remote.tvdb_season ?? remote.season else { unmapped += 1; continue }
                let number = remote.tvdb_number ?? remote.number
                episode = cached?.episode
                if index < 40, let episodes = try? await tmdb.episodes(tvID: title.id, season: season),
                   let known = episodes.first(where: { $0.episode_number == number })
                {
                    episode = known
                }
                if episode == nil {
                    episode = TMDBEpisode(
                        id: -1,
                        episode_number: number,
                        season_number: season,
                        name: remote.title ?? "Episode \(number)",
                        overview: nil,
                        air_date: nil,
                        still_path: nil,
                        runtime: nil,
                        vote_average: nil,
                    )
                }
            }
            let duration = cached?.duration ?? (episode?.runtime ?? title.runtime).map { Double($0) * 60 }
            let record = CatalogProgress(
                title: title,
                episode: episode,
                position: PlaybackProgressConflict.position(
                    percentage: pause.progress,
                    duration: duration,
                ) ?? 0,
                duration: duration,
                completed: pause.progress >= 100,
                remotePercentage: pause.progress,
                pendingSync: false,
                checkpointEvent: nil,
                updatedAt: date,
                localCheckpoint: cached?.completed == false ? cached?.exactCheckpoint : nil,
                locallyCleared: false,
            )
            if resolved[record.id].map({ $0.updatedAt < date }) ?? true {
                resolved[record.id] = record
            }
        }
        var replayed = false
        for record in records(scope: scope) {
            guard isCurrent(), !Task.isCancelled else { return (false, unmapped) }
            if isActive(record, scope: scope) {
                resolved[record.id] = record; continue
            }
            let library = entries.first { $0.catalogID == record.title.catalogID }
            let watchedDate: Date?
            if let episode = record.episode {
                let stamp = library?.seasons?.first { $0.number == episode.season_number }?.episodes?
                    .first { $0.number == episode.episode_number }?.watched_at
                watchedDate = (stamp ?? (library?.status == "completed" ? library?.last_watched_at : nil))
                    .flatMap(PlaybackProgressConflict.date)
            } else {
                watchedDate = (library?.status == "completed" ? library?.last_watched_at : nil)
                    .flatMap(PlaybackProgressConflict.date)
            }
            let remoteDate = resolved[record.id]?.updatedAt
            // Only explicit watched history completes a title. Global playback activity and a
            // missing pause cannot distinguish expiry, another title, or a completed session.
            if let watchedDate, watchedDate > record.updatedAt,
               remoteDate.map({ watchedDate >= $0 }) ?? true
            {
                var completed = record
                completed.completed = true; completed.pendingSync = false
                completed.remotePercentage = 100; completed.updatedAt = watchedDate
                completed.checkpointEvent = "watched"
                resolved[record.id] = completed
                continue
            }
            let echoesAcknowledgement: Bool = if let remote = resolved[record.id],
                                                 let acknowledgedAt = record.acknowledgedAt,
                                                 let percentage = record.remotePercentage
            {
                record.usesExactPosition && record.pendingSync == false && remote.updatedAt <= acknowledgedAt
                    && abs((remote.remotePercentage ?? -1) - percentage.trackerProgress) < 0.011
            } else {
                false
            }
            if let remoteDate, remoteDate > record.updatedAt, !echoesAcknowledgement {
                // Keep the precise checkpoint as provenance, but select this newer cross-device session.
                continue
            }
            let hasLocalState = record.exactCheckpoint != nil || record.completed || record.locallyCleared == true
            guard hasLocalState || remoteDate != nil else { continue }
            if record.locallyCleared == true || record.completed && record.pendingSync != true {
                resolved[record.id] = record; continue
            }
            guard PlaybackProgressConflict.prefersLocal(
                      localDate: record.updatedAt,
                      isPending: record.pendingSync ?? !record.completed,
                      remoteDate: remoteDate,
                  ),
                  let item = record.title.trackerItem(episode: record.episode),
                  record.completed || record.duration.map({ $0 > 0 }) == true
            else {
                resolved[record.id] = record; continue
            }
            let percent = record.completed ? 100 : record.fraction * 100
            let delivered = await replay(item, percent, record.updatedAt)
            var updated = record
            if delivered {
                updated.pendingSync = false; updated.remotePercentage = percent.trackerProgress
                updated.acknowledgedAt = Date(); replayed = true
            }
            // Recording can continue while the shared network channel is awaited.
            if let current = progress(title: record.title, episode: record.episode, scope: scope),
               current.updatedAt > record.updatedAt
            {
                resolved[record.id] = current
            } else {
                resolved[record.id] = updated
            }
        }
        guard isCurrent(), !Task.isCancelled else { return (false, unmapped) }
        // Another episode may have started while a network replay was suspended.
        for current in records(scope: scope) where current.exactCheckpoint != nil {
            if current.updatedAt > (resolved[current.id]?.updatedAt ?? .distantPast) {
                resolved[current.id] = current
            }
        }
        replace(Array(resolved.values), scope: scope)
        return (replayed, unmapped)
    }
}
