import Foundation

/// Resolves one stable movie/episode target for the detail actions; no second progress store or player.
@MainActor
enum CatalogDetailPlayback {
    static func savedRecord(title: TMDBTitle, episode: TMDBEpisode?, records: [CatalogProgress]) -> CatalogProgress? {
        records.first { $0.id == CatalogProgress.key(title: title, episode: episode) }
    }

    static func latestEpisode(title: TMDBTitle, records: [CatalogProgress]) -> TMDBEpisode? {
        records
            .filter {
                $0.title.catalogID == title.catalogID && !$0.completed && $0.locallyCleared != true && $0
                    .episode != nil && ($0.position > 0 || $0.fraction > 0)
            }
            .max { $0.updatedAt < $1.updatedAt }?.episode
    }

    static func resumes(_ record: CatalogProgress?) -> Bool {
        guard let record else { return false }
        return !record.completed && record.locallyCleared != true && (record.position > 0 || record.fraction > 0)
    }

    static func remaining(title: TMDBTitle, episode: TMDBEpisode?, record: CatalogProgress?) -> String? {
        guard resumes(record), let record else { return nil }
        let duration = record.duration ?? (episode?.runtime ?? title.runtimeMinutes).map { Double($0) * 60 }
        let offset = record.usesExactPosition ? record.position : duration.map { $0 * record.fraction }
        return RemainingTimeFormatter.text(duration: duration, viewOffset: offset)
    }
}
