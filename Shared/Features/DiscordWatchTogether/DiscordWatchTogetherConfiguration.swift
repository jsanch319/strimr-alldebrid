import Foundation

enum DiscordWatchTogetherConfiguration {
    static func activityLaunchURL(for media: MediaItem) -> URL? {
        guard let applicationID = Bundle.main.object(forInfoDictionaryKey: "DiscordApplicationClientID") as? String,
              !applicationID.isEmpty,
              applicationID.allSatisfy(\.isNumber),
              let activityURL = Bundle.main.object(forInfoDictionaryKey: "DiscordActivityURL") as? String,
              let configuredActivityURL = URL(string: activityURL),
              configuredActivityURL.scheme == "https",
              configuredActivityURL.host != nil,
              var components = URLComponents(string: "https://discord.com/activities/\(applicationID)")
        else { return nil }

        let mediaType: String? = switch media.kind {
        case .movie: "movie"
        case .episode: "episode"
        case .series, .season: "show"
        case .clip, .collection, .playlist, .folder, .unknown: nil
        }
        guard let mediaType else { return nil }
        let title = media.kind == .episode ? (media.grandparentTitle ?? media.title) : media.title
        let duration = media.duration.flatMap { $0.isFinite && $0 >= 0 ? String(Int(min($0, 7 * 24 * 3600))) : nil }
        components.queryItems = [
            URLQueryItem(name: "media_id", value: media.id),
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "media_type", value: mediaType),
            URLQueryItem(name: "season", value: media.parentIndex.map(String.init)),
            URLQueryItem(name: "episode", value: media.index.map(String.init)),
            URLQueryItem(name: "duration", value: duration),
        ].filter { $0.value != nil }
        return components.url
    }
}
