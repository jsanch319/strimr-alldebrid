import AppIntents
import Foundation

enum StrimrAppLink {
    static func url(host: String) -> URL? {
        var components = URLComponents()
        components.scheme = "strimr"
        components.host = host
        return components.url
    }

    static func mediaURL(provider: String, serverID: String, itemID: String, mediaType: String) -> URL? {
        var components = URLComponents()
        components.scheme = "strimr"
        components.host = "media"
        components.queryItems = [
            URLQueryItem(name: "provider", value: provider),
            URLQueryItem(name: "server", value: serverID),
            URLQueryItem(name: "item", value: itemID),
            URLQueryItem(name: "type", value: mediaType),
        ]
        return components.url
    }
}

struct OpenStrimrIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Strimr"
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        guard let url = StrimrAppLink.url(host: "open") else {
            throw StrimrShortcutError.invalidLink
        }
        return .result(opensIntent: OpenURLIntent(url: url))
    }
}

struct ResumeWatchingIntent: AppIntent {
    static let title: LocalizedStringResource = "Resume Watching"
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        guard let url = StrimrAppLink.url(host: "resume") else {
            throw StrimrShortcutError.invalidLink
        }
        return .result(opensIntent: OpenURLIntent(url: url))
    }
}

struct OpenMediaByIdentifierIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Strimr Media"
    static let openAppWhenRun = true

    @Parameter(title: "Provider")
    var provider: String

    @Parameter(title: "Server Identifier")
    var serverID: String

    @Parameter(title: "Media Identifier")
    var itemID: String

    @Parameter(title: "Media Type")
    var mediaType: String

    func perform() async throws -> some IntentResult {
        guard MediaProvider(rawValue: provider) != nil,
              !serverID.isEmpty,
              !itemID.isEmpty,
              let kind = MediaKind(rawValue: mediaType),
              [.movie, .episode, .series].contains(kind),
              let url = StrimrAppLink.mediaURL(
                  provider: provider,
                  serverID: serverID,
                  itemID: itemID,
                  mediaType: kind.rawValue,
              )
        else {
            throw StrimrShortcutError.invalidMediaIdentifier
        }
        return .result(opensIntent: OpenURLIntent(url: url))
    }
}

struct StrimrAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        [
            AppShortcut(
                intent: OpenStrimrIntent(),
                phrases: ["Open \(.applicationName)"],
                shortTitle: "Open Strimr",
                systemImageName: "play.rectangle",
            ),
            AppShortcut(
                intent: ResumeWatchingIntent(),
                phrases: ["Resume watching with \(.applicationName)"],
                shortTitle: "Resume Watching",
                systemImageName: "play.fill",
            ),
        ]
    }
}

private enum StrimrShortcutError: LocalizedError {
    case invalidLink
    case invalidMediaIdentifier

    var errorDescription: String? {
        switch self {
        case .invalidLink:
            return "Could not open Strimr."
        case .invalidMediaIdentifier:
            return "A valid provider, server, media identifier, and movie/show type are required."
        }
    }
}
