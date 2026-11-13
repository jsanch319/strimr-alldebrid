import Foundation

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
