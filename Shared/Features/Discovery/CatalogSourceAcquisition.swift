import CryptoKit
import Foundation

nonisolated enum AllDebridLinkImport: Sendable {
    case ready(AllDebridSavedLink)
    case delayed(id: String, filename: String)
}

nonisolated protocol CatalogAcquisitionClient: Sendable {
    func uploadMagnet(_ link: String) async throws -> String
    func importDownloadLink(_ link: String) async throws -> AllDebridLinkImport
    func delayedDownload(id: String, original: String, filename: String) async throws -> AllDebridSavedLink?
}

extension AllDebridAPIClient: CatalogAcquisitionClient {}

/// Acquisition feeds the original resolver. Only hashed submission receipts are persisted, never links or API keys.
@MainActor
final class CatalogSourceAcquisition {
    struct Receipt: Codable { var id: String?; let created: Date; let target: String }
    private let providers: [any AuthorizedSourceProvider]
    private let client: any CatalogAcquisitionClient
    private let defaults: UserDefaults
    private let ledgerKey: String
    private var boundIdentity: String?
    private var searchedAt: Date?
    private var searchIdentity: String?
    private var candidates: [AuthorizedSourceCandidate] = []
    private var links: [AllDebridSavedLink] = []
    private var delayed: (id: String, original: String, filename: String)?
    private var pendingID: String?
    private var failedDirect = Set<String>()
    private(set) var needsSetup: Bool
    private(set) var isProcessing = false

    init(
        client: any CatalogAcquisitionClient,
        providers: [any AuthorizedSourceProvider],
        account: String,
        defaults: UserDefaults = .standard,
    ) {
        self.client = client; self.providers = providers; self.defaults = defaults
        ledgerKey = "catalog.acquisition." + Self.digest(account)
        needsSetup = providers.isEmpty
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func submissionKey(_ link: String) -> String {
        if link.lowercased().hasPrefix("magnet:"),
           let hash = URLComponents(string: link)?.queryItems?.first(where: { $0.name == "xt" })?.value
        {
            return digest(hash.lowercased())
        }
        return digest(link)
    }

    private var receipts: [String: Receipt] {
        get {
            (defaults.data(forKey: ledgerKey))
                .flatMap { try? JSONDecoder().decode([String: Receipt].self, from: $0) } ?? [:]
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: ledgerKey) }
    }

    private func bind(_ identity: String) {
        guard boundIdentity != identity else { return }
        boundIdentity = identity; links = []; delayed = nil; pendingID = nil; candidates = []; failedDirect = []
        searchedAt = nil; searchIdentity = nil
    }

    func discover(
        title: TMDBTitle,
        episode: TMDBEpisode?,
        snapshot: AllDebridLibrarySnapshot,
    ) async throws -> [AllDebridSavedLink] {
        let identity = "\(title.kind)-\(title.id)-\(episode?.season_number ?? -1)-\(episode?.episode_number ?? -1)"
        bind(identity)
        isProcessing = false
        if let delayed {
            if let ready = try await client.delayedDownload(
                id: delayed.id,
                original: delayed.original,
                filename: delayed.filename,
            ) {
                self.delayed = nil
                guard AuthorizedSourceCandidate.matchesFile(ready.filename, title: title, episode: episode) else {
                    throw CatalogSourceResolver.Failure
                        .noMatch("The generated file does not match this title/year/episode. It was not played.")
                }
                links.append(ready)
            } else {
                isProcessing = true; return []
            }
        }
        if !links.isEmpty {
            return links
        }
        if pendingID == nil {
            pendingID = receipts.values.first(where: { receipt in
                receipt.target == Self.digest(identity) && receipt.id.map { id in
                    snapshot.magnets.contains { $0.id == id && $0.isProcessing }
                } == true
            })?.id
        }
        if let pendingID, !snapshot.magnets.contains(where: { $0.id == pendingID }),
           receipts.values.contains(where: { $0.id == pendingID && Date().timeIntervalSince($0.created) < 120 })
        {
            isProcessing = true; return []
        }
        if let pendingID, let magnet = snapshot.magnets.first(where: { $0.id == pendingID }) {
            if magnet.isProcessing {
                isProcessing = true; return []
            }
            throw CatalogSourceResolver.Failure.noMatch(magnet.isReady
                ? "The submitted magnet is ready, but contains no exact matching playable file. Choose another authorized source."
                :
                "AllDebrid could not process the submitted magnet. Check its status in your library or choose another authorized source.")
        }
        if searchIdentity != identity || searchedAt == nil || Date().timeIntervalSince(searchedAt!) >= 60 {
            searchIdentity = identity; searchedAt = Date(); candidates = []
            for provider in providers {
                try Task.checkCancellation()
                do {
                    candidates += try await provider.search(title: title, episode: episode).filter { $0.matches(
                        title,
                        episode: episode,
                    ) }
                } catch {
                    if error.isCancellation {
                        throw error
                    }
                    // Try other configured providers, but never hammer a rate-limited provider.
                    if providers.count == 1 {
                        throw error
                    }
                }
            }
            candidates
                .sort { AllDebridTitleMatcher.resolution($0.filename) > AllDebridTitleMatcher.resolution($1.filename) }
        }
        var submissions = 0
        for candidate in candidates
            where AuthorizedSourceCandidate.validLink(candidate.link) && !failedDirect.contains(candidate.link)
        {
            try Task.checkCancellation()
            let key = Self.submissionKey(candidate.link)
            if let receipt = receipts[key] {
                if let id = receipt.id, let magnet = snapshot.magnets.first(where: { $0.id == id }) {
                    if magnet.isProcessing {
                        pendingID = id; isProcessing = true; return []
                    }
                } else if receipt.id != nil, Date().timeIntervalSince(receipt.created) < 120 {
                    pendingID = receipt.id; isProcessing = true; return []
                }
                continue // Never resubmit on polling, relaunch, or an ambiguous upload response.
            }
            guard submissions < 3 else { break }
            submissions += 1
            do {
                let result = try await submit(candidate.link, identity: identity)
                if let result {
                    guard AuthorizedSourceCandidate.matchesFile(result.filename, title: title, episode: episode) else {
                        links = []; failedDirect.insert(candidate.link); continue
                    }
                    return [result]
                }
                return []
            } catch {
                if error.isCancellation || AllDebridAPIClient.isAuthenticationOrRateLimit(error) {
                    throw error
                }
                failedDirect.insert(candidate.link)
            }
        }
        return []
    }

    func submitUserLink(_ link: String, title: TMDBTitle, episode: TMDBEpisode?) async throws {
        guard AuthorizedSourceCandidate.validLink(link) else { throw AllDebridAPIClient.APIError.invalidLink }
        if title.kind == .tv, episode == nil {
            throw CatalogSourceResolver.Failure.chooseEpisode
        }
        // Manual entry explicitly binds an authorized link to this title; actual returned filenames still must match.
        let identity = "\(title.kind)-\(title.id)-\(episode?.season_number ?? -1)-\(episode?.episode_number ?? -1)"
        bind(identity)
        if let ready = try await submit(link, identity: identity) {
            guard AuthorizedSourceCandidate.matchesFile(ready.filename, title: title, episode: episode) else {
                links = []
                throw CatalogSourceResolver.Failure
                    .noMatch("The link's actual filename does not match this title/year/episode. It was not played.")
            }
        }
    }

    private func submit(_ link: String, identity: String) async throws -> AllDebridSavedLink? {
        try Task.checkCancellation()
        let key = Self.submissionKey(link)
        if link.lowercased().hasPrefix("magnet:") {
            guard receipts[key] == nil else {
                throw CatalogSourceResolver.Failure
                    .noMatch(
                        "This magnet was already submitted or its submission is uncertain. Refresh the library instead of uploading it again.",
                    )
            }
            receipts[key] = Receipt(id: nil, created: Date(), target: Self.digest(identity))
            let id = try await client.uploadMagnet(link)
            receipts[key] = Receipt(id: id, created: Date(), target: Self.digest(identity))
            pendingID = id; isProcessing = true
            return nil
        }
        switch try await client.importDownloadLink(link) {
        case let .ready(ready): links = [ready]; return ready
        case let .delayed(id, filename):
            delayed = (id, link, filename); isProcessing = true; return nil
        }
    }
}
