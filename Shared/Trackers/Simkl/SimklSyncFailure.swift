import Foundation
import OSLog

/// Stable, privacy-safe diagnostics; Swift's synthesized NSError integers are not an API contract.
nonisolated enum SimklSyncFailure {
    private static let log = Logger(subsystem: "app.strimr.simkl", category: "Sync")

    static func category(_ error: Error) -> String {
        if let error = error as? TrackerAPIError {
            switch error {
            case .unauthorized, .sessionExpired: return "authorization"
            case .rateLimited: return "rate_limit"
            case .throttled: return "client_or_throttle"
            case .writeLocked: return "write_lock"
            case .invalidResponse: return "invalid_response"
            case .server: return "server"
            case .unexpected: return "http_rejection"
            default: return "tracker_rejection"
            }
        }
        if error is DecodingError {
            return "decoding"
        }
        if error is URLError {
            return "network"
        }
        if error.isCancellation {
            return "cancelled"
        }
        return "other"
    }

    static func record(_ error: Error, stage: String, httpStatus: Int? = nil) {
        // Only caller-owned stage constants and categorical values: never error descriptions or bodies.
        let category = category(error)
        let status: Int = switch error as? TrackerAPIError {
        case .unauthorized: 401
        case .rateLimited: 429
        case .throttled: 412
        case let .server(value), let .unexpected(value): value
        case .invalidResponse: 200 // Response decode/validation failed after an accepted HTTP response.
        default: 0 // Not enough evidence to claim a particular HTTP status.
        }
        let actualStatus = httpStatus ?? status
        let network = (error as? URLError)?.errorCode ?? 0
        log
            .notice(
                "stage=\(stage, privacy: .public) category=\(category, privacy: .public) http=\(actualStatus) network=\(network)",
            )
    }

    static func message(_ error: Error, consecutiveFailures: Int) -> String? {
        switch error as? TrackerAPIError {
        case .unauthorized, .sessionExpired:
            return "Reconnect Simkl in Settings to refresh your lists and progress."
        case .throttled, .unexpected(status: 403):
            return "Simkl rejected this app's access. Check Simkl connection settings."
        case .invalidResponse where consecutiveFailures >= 2:
            return "Simkl returned an unreadable update. Pull to refresh or report the issue."
        case .rateLimited:
            return nil // Honor the reset quietly; reconnecting cannot restore a quota.
        default:
            if let network = error as? URLError, network.code == .notConnectedToInternet {
                return "Connect to the internet to refresh Simkl."
            }
            return consecutiveFailures >= 3 ? "Simkl couldn't refresh. Pull to retry later." : nil
        }
    }

    /// Retry reads only; never repeat a write whose server-side outcome is unknown.
    static func retryDelay(_ error: Error, attempt: Int) -> TimeInterval? {
        guard attempt < 2, !error.isCancellation else { return nil }
        switch error as? TrackerAPIError {
        case let .rateLimited(delay):
            guard let delay, delay.isFinite, delay >= 0, delay <= 5 else { return nil }
            return max(1, delay)
        case .server(status: 500), .server(status: 502), .server(status: 503), .server(status: 504):
            return Double(attempt + 1)
        default:
            guard let error = error as? URLError,
                  [URLError.Code.timedOut, .networkConnectionLost, .cannotConnectToHost, .dnsLookupFailed]
                      .contains(error.code)
            else { return nil }
            return Double(attempt + 1)
        }
    }
}
