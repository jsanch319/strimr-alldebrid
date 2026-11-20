import Foundation
import Observation

nonisolated struct DiscordNativeMedia: Encodable, Equatable, Sendable {
    let mediaId: String
    let title: String
    let mediaType: String
    let season: Int?
    let episode: Int?
    let duration: Double
    let selectedSourceIdentifier: String? = nil

    init?(media: MediaItem, duration: Double?) {
        guard [.movie, .episode].contains(media.kind),
              media.id.range(of: #"^[\w:.-]{1,180}$"#, options: .regularExpression) != nil else { return nil }
        mediaId = media.id
        title = String((media.kind == .episode ? media.grandparentTitle ?? media.title : media.title).prefix(180))
        mediaType = media.kind == .episode ? "episode" : "movie"
        season = media.kind == .episode ? media.parentIndex : nil
        episode = media.kind == .episode ? media.index : nil
        if media.kind == .episode, season == nil || episode == nil {
            return nil
        }
        let value = duration ?? media.duration ?? 0
        self.duration = value.isFinite ? min(max(0, value), 7 * 24 * 3600) : 0
    }
}

nonisolated struct DiscordPlaybackSample: Codable, Equatable, Sendable {
    let position: Double
    let isPlaying: Bool
    var isValid: Bool {
        position.isFinite && position >= 0
    }
}

nonisolated enum DiscordSyncPolicy {
    static func isTemporaryZero(
        _ sample: DiscordPlaybackSample,
        previous: DiscordPlaybackSample?,
        intentional: Bool,
    ) -> Bool {
        !intentional && sample.position <= 0.5 && (previous?.position ?? 0) > 2
    }

    static func shouldPublish(
        _ sample: DiscordPlaybackSample, previous: DiscordPlaybackSample?, elapsed: TimeInterval,
        canControl: Bool, intentionalZeroSeek: Bool,
    ) -> Bool {
        guard canControl, sample.isValid, let previous,
              !isTemporaryZero(sample, previous: previous, intentional: intentionalZeroSeek) else { return false }
        let expected = previous.position + (previous.isPlaying ? max(0, elapsed) : 0)
        return sample.isPlaying != previous.isPlaying || abs(sample.position - expected) > 1.5
    }
}

/// Metadata/control transport only. Never receives or serializes a playback URL or AllDebrid credential.
@MainActor
@Observable
final class DiscordNativeBridge {
    private(set) var isConnected = false
    private(set) var isConnecting = false
    private(set) var message = ""
    private var generation = UUID()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var applyTask: Task<Void, Never>?
    @ObservationIgnored private var token: String?
    private var origin: URL?
    private var intentionalZeroSeek = false
    private var resetSampleAfterRemote = false
    private var synchronizationSuspended = false
    private let session: URLSession
    private enum BridgeError: Error { case authorization }

    nonisolated struct Participant: Decodable, Sendable { let userId: String; let canControl: Bool }
    nonisolated struct Room: Decodable, Sendable {
        struct Media: Decodable, Sendable { let duration: Double }
        let media: Media
        let revision: Int
        let currentPosition: Double
        let isPlaying: Bool
        let participants: [Participant]
    }

    nonisolated struct Reply: Decodable, Sendable {
        let token: String?
        let userId: String?
        let room: Room
        let serverTime: Double
    }

    private struct PairBody: Encodable {
        let code: String; let media: DiscordNativeMedia; let initialPlayback: DiscordPlaybackSample
    }

    private struct Command: Encodable {
        let type = "sync-playback"
        let position: Double
        let isPlaying: Bool
        let revision: Int
    }

    private struct SyncBody: Encodable { let media: DiscordNativeMedia; let command: Command? }
    private struct Empty: Encodable {}
    private final class RedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(
            _: URLSession, task _: URLSessionTask, willPerformHTTPRedirection _: HTTPURLResponse,
            newRequest _: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void,
        ) {
            completionHandler(nil)
        }
    }

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 10
        session = URLSession(configuration: configuration, delegate: RedirectBlocker(), delegateQueue: nil)
    }

    func noteIntentionalSeek() {
        intentionalZeroSeek = true
    }

    func connect(
        code: String, origin: URL, media: DiscordNativeMedia,
        read: @escaping @MainActor () -> DiscordPlaybackSample?,
        apply: @escaping @MainActor (DiscordPlaybackSample) async -> Bool,
    ) async {
        guard !isConnecting, !isConnected else { return }
        guard origin.scheme == "https", origin.host != nil, origin.user == nil, origin.password == nil,
              origin.query == nil, origin.fragment == nil, ["", "/"].contains(origin.path),
              code.range(of: #"^[\w-]{24}$"#, options: .regularExpression) != nil,
              let sample = read(), sample.isValid
        else {
            message =
                "Use the HTTPS Activity origin and a fresh pairing code. Wait until this title is ready to play."; return
        }
        let current = UUID(); generation = current
        synchronizationSuspended = false; resetSampleAfterRemote = false
        isConnecting = true; message = "Connecting to Discord…"
        defer {
            if generation == current {
                isConnecting = false
            }
        }
        do {
            let reply = try await post(
                "api/native/pair",
                origin: origin,
                token: nil,
                body: PairBody(code: code, media: media, initialPlayback: sample),
            )
            guard generation == current, let token = reply.token, let userID = reply.userId else { return }
            self.token = token; self.origin = origin; isConnected = true
            message = "Connected to Discord"
            task = Task { [weak self] in
                await self?.poll(
                    initial: reply,
                    userID: userID,
                    media: media,
                    generation: current,
                    read: read,
                    apply: apply,
                )
            }
        } catch {
            if generation ==
                current
            {
                message =
                    "Pairing failed. Check the deployed Activity, membership, matching title and fresh code. Private playback URLs were not sent."
            }
        }
    }

    func disconnect() {
        generation = UUID(); task?.cancel(); task = nil; applyTask?.cancel(); applyTask = nil
        let oldToken = token, oldOrigin = origin
        token = nil; origin = nil; isConnected = false; isConnecting = false; intentionalZeroSeek = false
        message = "Disconnected from Discord"
        if let oldToken, let oldOrigin {
            Task { [session] in
                var request = URLRequest(url: oldOrigin.appending(path: "api/native/leave"))
                request.httpMethod = "POST"; request.setValue("Bearer " + oldToken, forHTTPHeaderField: "Authorization")
                _ = try? await session.data(for: request)
            }
        }
    }

    private func poll(
        initial: Reply, userID: String, media: DiscordNativeMedia, generation current: UUID,
        read: @escaping @MainActor () -> DiscordPlaybackSample?,
        apply: @escaping @MainActor (DiscordPlaybackSample) async -> Bool,
    ) async {
        var reply = initial, received = Date(), previous: DiscordPlaybackSample?, sampled = Date()
        var appliedRevision = -1, failures = 0
        while !Task.isCancelled, generation == current, let token, let origin {
            let canControl = reply.room.participants.first { $0.userId == userID }?.canControl == true
            let local = read()
            let acceptsZero = intentionalZeroSeek
            var command: Command?
            if let local, resetSampleAfterRemote {
                if !DiscordSyncPolicy.isTemporaryZero(local, previous: previous, intentional: false) {
                    previous = local; sampled = Date()
                }
                resetSampleAfterRemote = false
            }
            if let local, applyTask == nil, !synchronizationSuspended {
                if appliedRevision != reply.room.revision || (!canControl && previous.map {
                    abs(local.position - ($0.position + ($0.isPlaying ? Date().timeIntervalSince(sampled) : 0))) >
                        1.5 ||
                        local.isPlaying != $0.isPlaying
                } == true) {
                    let end = reply.room.media.duration > 0 ? reply.room.media.duration : Double(7 * 24 * 3600)
                    let position = min(
                        end,
                        reply.room.currentPosition + (reply.room.isPlaying ? Date().timeIntervalSince(received) : 0),
                    )
                    let target = DiscordPlaybackSample(
                        position: position,
                        isPlaying: reply.room.isPlaying && position < end,
                    )
                    let revision = reply.room.revision
                    applyTask = Task { [weak self] in
                        guard let self else { return }
                        let succeeded = await apply(target)
                        guard generation == current, !Task.isCancelled else { return }
                        applyTask = nil
                        resetSampleAfterRemote = true
                        if !succeeded {
                            synchronizationSuspended = true
                            message = "Discord position could not be restored. Local playback is retained; disconnect and reconnect to retry."
                        }
                    }
                    appliedRevision = revision
                    previous = target; sampled = Date(); intentionalZeroSeek = false
                } else if DiscordSyncPolicy.shouldPublish(
                    local,
                    previous: previous,
                    elapsed: Date().timeIntervalSince(sampled),
                    canControl: canControl,
                    intentionalZeroSeek: intentionalZeroSeek,
                ) {
                    command = Command(
                        position: local.position,
                        isPlaying: local.isPlaying,
                        revision: reply.room.revision,
                    )
                    intentionalZeroSeek = false
                }
                if applyTask == nil, !DiscordSyncPolicy.isTemporaryZero(
                    local,
                    previous: previous,
                    intentional: acceptsZero,
                ) {
                    previous = local; sampled = Date()
                }
            }
            do {
                let next = try await post(
                    "api/native/sync",
                    origin: origin,
                    token: token,
                    body: SyncBody(media: media, command: command),
                )
                guard generation == current else { return }
                if command != nil,
                   next.room.revision == reply.room.revision + 1
                {
                    appliedRevision = next.room.revision
                }
                reply = next; received = Date(); failures = 0
            } catch {
                guard generation == current, !Task.isCancelled else { return }
                if error is BridgeError {
                    disconnect(); message =
                        "Discord authorization or pairing ended. Reopen the Activity and pair again. Local playback is unchanged."; return
                }
                failures += 1
                message = "Discord connection interrupted. Local playback and resume are retained."
                if failures >=
                    3
                {
                    disconnect(); message =
                        "Discord synchronization stopped. Reopen the Activity and pair again. Local playback is unchanged."; return
                }
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func post(_ path: String, origin: URL, token: String?, body: some Encodable) async throws -> Reply {
        var request = URLRequest(url: origin.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token {
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await session.data(for: request)
        if let response = response as? HTTPURLResponse,
           [401, 403].contains(response.statusCode)
        {
            throw BridgeError.authorization
        }
        guard let response = response as? HTTPURLResponse,
              response.statusCode == 200,
              data.count < 65536 else { throw URLError(.badServerResponse) }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        guard reply.room.revision >= 0, reply.room.currentPosition.isFinite,
              (0 ... Double(7 * 24 * 3600)).contains(reply.room.currentPosition)
        else { throw URLError(.badServerResponse) }
        return reply
    }
}
