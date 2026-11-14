import Foundation
#if os(iOS)
    import UIKit
#endif

enum DiscordWatchTogetherConfiguration {
    static func activityLaunchURL(
        for media: MediaItem,
        position: Double = 0,
        isPlaying: Bool = false,
        duration: Double? = nil,
        selectedSourceIdentifier: String? = nil,
    ) -> URL? {
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
        let safeDuration = duration ?? media.duration
        let durationValue = safeDuration.flatMap { $0.isFinite && $0 >= 0 ? min($0, 7 * 24 * 3600) : nil }
        let positionValue = position.isFinite ? max(0, min(position, durationValue ?? 7 * 24 * 3600)) : 0
        components.queryItems = [
            URLQueryItem(name: "media_id", value: media.id),
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "media_type", value: mediaType),
            URLQueryItem(name: "season", value: media.parentIndex.map(String.init)),
            URLQueryItem(name: "episode", value: media.index.map(String.init)),
            URLQueryItem(name: "duration", value: durationValue.map { String(Int($0)) }),
            URLQueryItem(name: "position", value: String(Int(positionValue))),
            URLQueryItem(name: "is_playing", value: isPlaying ? "1" : "0"),
            URLQueryItem(name: "source_id", value: selectedSourceIdentifier.flatMap(safeIdentifier)),
        ].filter { $0.value != nil }
        return components.url
    }

    #if os(iOS)
        enum LaunchResult {
            case opened
            case discordNotInstalled
            case activityUnavailable
        }

        @MainActor
        static func openActivityURL(_ url: URL, completion: @escaping (LaunchResult) -> Void) {
            guard let discordURL = URL(string: "discord://") else {
                completion(.discordNotInstalled)
                return
            }
            UIApplication.shared.open(discordURL) { isDiscordInstalled in
                guard isDiscordInstalled else {
                    completion(.discordNotInstalled)
                    return
                }
                UIApplication.shared.open(url) { opened in
                    completion(opened ? .opened : .activityUnavailable)
                }
            }
        }
    #endif

    private static func safeIdentifier(_ value: String) -> String? {
        let identifier = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return identifier.range(of: #"^[\w:.-]{1,180}$"#, options: .regularExpression) == nil ? nil : identifier
    }
}
