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
        let octets = host.split(separator: ".").compactMap { Int($0) }
        if octets.count == 4, octets.allSatisfy({ (0 ... 255).contains($0) }),
           octets[0] == 10 || (octets[0] == 192 && octets[1] == 168) ||
           (octets[0] == 172 && (16 ... 31).contains(octets[1])) ||
           (octets[0] == 169 && octets[1] == 254)
        {
            return "lan"
        }
        if host.hasSuffix(".local") {
            return "lan"
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
        case authorizationOrExpiredLink, unavailable, network, redirect, incompatible, playback
    }

    static func diagnosticErrorCode(_ error: NSError?) -> Int {
        var current = error
        var result = 0
        for _ in 0 ..< 4 {
            guard let error = current else { break }
            if [NSURLErrorDomain, "AVFoundationErrorDomain"].contains(error.domain) {
                result = error.code
            }
            current = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return result
    }

    static func failure(error: NSError?, httpStatus: Int?) -> Failure {
        var current = error
        for _ in 0 ..< 4 {
            guard let error = current else { break }
            let category = failure(domain: error.domain, code: error.code, httpStatus: httpStatus)
            if category != .playback {
                return category
            }
            current = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return failure(domain: "", code: 0, httpStatus: httpStatus)
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
            if code == NSURLErrorHTTPTooManyRedirects {
                return .redirect
            }
            if [
                NSURLErrorTimedOut,
                NSURLErrorNetworkConnectionLost,
                NSURLErrorNotConnectedToInternet,
                NSURLErrorCannotConnectToHost,
                NSURLErrorCannotFindHost,
                NSURLErrorDNSLookupFailed,
            ].contains(code) {
                return .network
            }
        }
        return .playback
    }
}
