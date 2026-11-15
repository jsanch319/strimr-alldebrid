import Foundation
import Observation

nonisolated struct CatalogProgress: Codable, Identifiable, Sendable {
    let title: TMDBTitle
    let episode: TMDBEpisode?
    var position: Double
    var duration: Double?
    var completed: Bool
    var updatedAt: Date
    var id: String {
        Self.key(title: title, episode: episode)
    }

    static func key(title: TMDBTitle, episode: TMDBEpisode?) -> String {
        title.catalogID + (episode.map { ":s\($0.season_number):e\($0.episode_number)" } ?? "")
    }

    var fraction: Double {
        guard let duration, duration > 0 else { return 0 }; return min(1, position / duration)
    }
}

@MainActor
@Observable
final class CatalogProgressStore {
    static let shared = CatalogProgressStore()
    private(set) var revision = 0
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func records(scope: String) -> [CatalogProgress] {
        guard let data = defaults.data(forKey: "strimr.catalog.progress.\(scope)") else { return [] }
        return (try? JSONDecoder().decode([CatalogProgress].self, from: data)) ?? []
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
    ) {
        guard position.isFinite, position >= 0 else { return }
        let validDuration = duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let previous = progress(title: title, episode: episode, scope: scope)
        // A transient zero before the engine seeks must not erase a saved resume point.
        if position < 1, previous?.position ?? 0 > 1, !finished {
            return
        }
        let record = CatalogProgress(
            title: title,
            episode: episode,
            position: position,
            duration: validDuration ?? previous?.duration,
            completed: finished || validDuration.map { position / $0 >= 0.95 } == true,
            updatedAt: Date(),
        )
        var records = records(scope: scope).filter { $0.id != record.id }
        records.insert(record, at: 0)
        defaults.set(try? JSONEncoder().encode(Array(records.prefix(1000))), forKey: "strimr.catalog.progress.\(scope)")
        revision += 1
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
    private var syncTask: Task<Void, Never>?
    init(defaults: UserDefaults = .standard, coordinator: TrackerCoordinator = .shared, tmdb: TMDBClient = .shared) {
        self.defaults = defaults
        self.coordinator = coordinator
        self.tmdb = tmdb
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
            let activities = try await client.activities() // Capture BEFORE the pull to avoid lost concurrent writes.
            if snapshot?.activities != activities || snapshot == nil {
                var merged = snapshot?.entries ?? []
                let since = snapshot?.activities.all
                for type in ["movies", "shows"] {
                    let delta = try await client.library(type: type, since: since)
                    let changed = Set(delta.map(\.id))
                    merged.removeAll { changed.contains($0.id) }
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
            errorMessage = "Simkl sync failed. Your cached list is retained. \(error.localizedDescription)"
        }
    }

    func setPlanned(_ title: TMDBTitle, planned: Bool) async throws {
        guard let client = coordinator.simklLibraryClient else { throw TrackerAPIError.unavailable }
        let scope = scope
        await syncTask?.value
        guard self.scope == scope, coordinator.simklLibraryClient === client else { throw TrackerAPIError.unavailable }
        try await client.setPlanned(title, planned: planned)
        guard self.scope == scope, coordinator.simklLibraryClient === client else { return }
        // Full refresh is explicit after a user mutation. Never advance an incremental checkpoint over this write.
        snapshot = nil
        lastSync = nil
        retryAt = nil
        await sync(force: true)
    }
}
