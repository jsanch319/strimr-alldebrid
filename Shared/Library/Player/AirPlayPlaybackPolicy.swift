import Foundation

/// Host decisions only. AetherEngine and AVFoundation remain the route/recovery owners.
enum AirPlayPlaybackPolicy {
    static func shouldPauseForBackground(backgroundAudio: Bool, externalPlayback: Bool, airPlayRoute: Bool) -> Bool {
        !backgroundAudio && !externalPlayback && !airPlayRoute
    }

    /// The native engine intentionally declines background video interruption resume. The
    /// host may resume the existing remote transport once, only with the system's permission.
    static func shouldResumeRemoteInterruption(
        wasPlaying: Bool, shouldResume: Bool, background: Bool,
        externalPlayback: Bool, nativeVideo: Bool, sameSession: Bool, coordinated: Bool,
    ) -> Bool {
        wasPlaying && shouldResume && background && externalPlayback && nativeVideo && sameSession && !coordinated
    }

    static func sourceCategory(_ url: URL) -> String {
        let host = url.host?.lowercased() ?? ""
        if host == "localhost" || host == "::1" || host.hasPrefix("127.") {
            return "loopback"
        }
        if url.isFileURL {
            return "file"
        }
        return url.scheme == "https" ? "remote-https" : "network-other"
    }

    static func httpStatus(domain: String?, code: Int?) -> Int? {
        guard let domain, ["HTTP", "HTTPErrorDomain"].contains(domain),
              let code, (400 ... 599).contains(code) else { return nil }
        return code
    }

    enum Failure: String {
        case authorizationOrExpiredLink, unavailable, network, incompatible, playback
    }

    /// Only structured, whitelisted facts are classified. No URL or error description is logged.
    static func failure(domain: String, code: Int, httpStatus: Int?) -> Failure {
        if let httpStatus {
            if [401, 403].contains(httpStatus) {
                return .authorizationOrExpiredLink
            }
            if [404, 410].contains(httpStatus) {
                return .unavailable
            }
        }
        if domain == NSURLErrorDomain {
            if [
                NSURLErrorTimedOut,
                NSURLErrorNetworkConnectionLost,
                NSURLErrorNotConnectedToInternet,
                NSURLErrorCannotConnectToHost,
                NSURLErrorDNSLookupFailed,
            ].contains(code) {
                return .network
            }
        }
        return .playback
    }
}
