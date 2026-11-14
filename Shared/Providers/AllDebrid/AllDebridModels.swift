import Foundation

struct AllDebridMagnet: Identifiable, Sendable, Hashable {
    let id: String
    let filename: String
    let size: Int64
    let status: String
    let statusCode: Int?

    var isReady: Bool {
        if status.isEmpty { return statusCode == 4 }
        return status.caseInsensitiveCompare("ready") == .orderedSame
    }
}

struct AllDebridMagnetFile: Identifiable, Sendable, Hashable {
    let id: String
    let magnetID: String
    let filename: String
    let fullPath: String
    let size: Int64
    let link: String

    var isVideo: Bool {
        let path = filename.lowercased()
        return [".mkv", ".mp4", ".m4v", ".mov", ".avi", ".webm", ".ts", ".m2ts"]
            .contains { path.hasSuffix($0) }
    }
}

/// Prototype data model for a future AllDebrid-backed media provider.
/// Not connected to Strimr's production media-service interfaces.
struct AllDebridMediaEntry: Identifiable, Sendable, Hashable {
    let id: String
    let title: String
    let releaseYear: Int?
    let kind: Kind
    let sourceIdentifier: String

    enum Kind: String, Sendable, Hashable {
        case movie
        case episode
    }
}

struct AllDebridPlayable: Sendable {
    let entryID: String
    let url: URL
    let expiresAt: Date?

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt <= Date()
    }
}
