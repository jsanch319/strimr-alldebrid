import Foundation

/// An in-memory placeholder; API retrieval and streaming are not yet implemented.
actor AllDebridCatalog {
    private var entries: [AllDebridMediaEntry] = []
    private var playableByID: [String: AllDebridPlayable] = [:]

    func replaceEntries(_ updated: [AllDebridMediaEntry]) {
        entries = updated
    }

    func listEntries() -> [AllDebridMediaEntry] {
        entries
    }

    func setPlayable(_ playable: AllDebridPlayable) {
        playableByID[playable.entryID] = playable
    }

    func playableURL(for entryID: String) -> URL? {
        guard let item = playableByID[entryID], !item.isExpired else { return nil }
        return item.url
    }
}
