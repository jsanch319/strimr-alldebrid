import Foundation

nonisolated enum CatalogAvailabilityPolling {
    /// Processing is refreshed promptly; missing/incomplete libraries back off. Never spin or poll in the background.
    static func delay(processing: Bool, attempt: Int) -> Duration {
        .seconds(min(processing ? 30 : 60, (processing ? 10 : 30) + max(0, attempt) * 5))
    }
}
