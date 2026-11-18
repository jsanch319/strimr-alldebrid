import Foundation

enum ErrorReporter {
    private static let enabledKey = "strimr.diagnostics.errorReporting"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: enabledKey)
        if enabled {
            start()
        } else {
            #if canImport(Sentry)
                SentrySDK.close()
            #endif
        }
    }

    static func start() {
        // Unit tests run hosted in the app; keep test-induced errors out of production Sentry.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil, isEnabled else { return }

        #if canImport(Sentry)
            let dsn: String?
            #if os(iOS)
                dsn = Bundle.main.object(forInfoDictionaryKey: "SENTRY_DSN_IOS") as? String
            #elseif os(tvOS)
                dsn = Bundle.main.object(forInfoDictionaryKey: "SENTRY_DSN_TVOS") as? String
            #elseif os(macOS)
                dsn = Bundle.main.object(forInfoDictionaryKey: "SENTRY_DSN_MACOS") as? String
            #else
                dsn = nil
            #endif

            guard let dsn, !dsn.isEmpty, dsn != "https://" else { return }
            SentrySDK.start { options in
                options.dsn = dsn
                // Add-on URLs may carry secrets in paths as well as queries. Do not collect them automatically.
                options.enableLogs = false
                options.enableNetworkBreadcrumbs = false
                options.enableNetworkTracking = false
                options.maxBreadcrumbs = 0
                // Automatic capture reports 5xx from self-hosted servers and third-party proxies we can't act on.
                options.enableCaptureFailedRequests = false
                options.beforeBreadcrumb = { breadcrumb in
                    breadcrumb.data = removingSensitiveData(from: breadcrumb.data)
                    return breadcrumb
                }
            }
        #endif
    }

    static func capture(_ error: Error) {
        guard !error.isCancellation, !(error is any ExpectedConnectivityError) else { return }
        #if !os(tvOS)
            guard !error.isTransportFailure, !error.isHostUnreachable else { return }
        #endif

        #if canImport(Sentry)
            SentrySDK.capture(error: safeDiagnosticError(error))
        #endif
    }

    /// Keep only non-sensitive diagnostics. Credential-bearing URLs may occur in arbitrary paths and nested data.
    static func removingSensitiveData(from data: [String: Any]?) -> [String: Any]? {
        data?.filter { key, value in
            let key = key.lowercased()
            let secretFields = [
                "query",
                "fragment",
                "url",
                "path",
                "target",
                "request",
                "header",
                "authorization",
                "cookie",
                "token",
                "password",
            ]
            return !secretFields.contains(where: key.contains) && !String(describing: value).contains("://")
        }
    }

    /// Never send NSError userInfo/descriptions, which can contain private source/configuration URLs.
    static func safeDiagnosticError(_ error: Error) -> NSError {
        let source = error as NSError
        let allowed = [
            NSURLErrorDomain,
            NSCocoaErrorDomain,
            NSPOSIXErrorDomain,
            NSOSStatusErrorDomain,
            "AVFoundationErrorDomain",
        ]
        return NSError(
            domain: allowed.contains(source.domain) ? source.domain : "Strimr",
            code: source.code,
            userInfo: [NSLocalizedDescriptionKey: "An application operation failed. Sensitive details omitted."],
        )
    }
}

/// Errors that describe an expected lack of connectivity and must never be reported.
protocol ExpectedConnectivityError: Error {}

extension Error {
    nonisolated var isCancellation: Bool {
        self is CancellationError
            || (self as? URLError)?.code == .cancelled
    }

    /// Surfaces outside `URLError` when a LAN address is unreachable or local network access is denied.
    var isHostUnreachable: Bool {
        let error = self as NSError
        return error.domain == NSPOSIXErrorDomain && error.code == Int(EHOSTUNREACH)
    }
}

#if canImport(Sentry)
    import Sentry
#endif
