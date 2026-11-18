import Foundation
@testable import Strimr
import Testing

struct ErrorReporterTests {
    @Test func `a POSIX host unreachable error is recognized`() {
        let error = NSError(domain: NSPOSIXErrorDomain, code: Int(EHOSTUNREACH))

        #expect(error.isHostUnreachable)
    }

    @Test func `other POSIX errors are not treated as host unreachable`() {
        let error = NSError(domain: NSPOSIXErrorDomain, code: Int(EADDRNOTAVAIL))

        #expect(!error.isHostUnreachable)
    }

    @Test func `the same code in another domain is not treated as host unreachable`() {
        let error = NSError(domain: NSURLErrorDomain, code: Int(EHOSTUNREACH))

        #expect(!error.isHostUnreachable)
    }
}

struct ErrorReporterBreadcrumbTests {
    @Test func `query and fragment are removed from network breadcrumbs`() {
        let data: [String: Any] = [
            "url": "https://media.example.com/library/metadata/1/thumb",
            "method": "GET",
            "http.query": "X-Plex-Token=secret",
            "http.fragment": "anchor",
        ]

        let sanitized = ErrorReporter.removingSensitiveData(from: data)

        #expect(sanitized?["http.query"] == nil)
        #expect(sanitized?["http.fragment"] == nil)
        #expect(sanitized?["url"] == nil)
        #expect(sanitized?["method"] as? String == "GET")
    }

    @Test func `private add-on paths headers and nested URLs do not reach diagnostics`() throws {
        let data: [String: Any] = [
            "http.path": "/ad=fixtureOnly/manifest.json",
            "headers": ["Authorization": "fixtureOnly"],
            "nested": ["source": "https://addon.test/fixtureOnly/manifest.json"],
            "method": "GET",
            "status": 200,
        ]
        let safe = try #require(ErrorReporter.removingSensitiveData(from: data))
        #expect(!String(describing: safe).contains("fixtureOnly"))
        #expect(safe["status"] as? Int == 200)
        let error = NSError(
            domain: "private-fixtureOnly",
            code: 42,
            userInfo: [
                NSLocalizedDescriptionKey: "URL https://addon.test/fixtureOnly/manifest.json",
                "secret": "fixtureOnly",
            ],
        )
        let result = ErrorReporter.safeDiagnosticError(error)
        #expect(!String(describing: result).contains("fixtureOnly"))
        #expect(result.code == 42)
    }

    @Test func `breadcrumbs without data stay without data`() {
        #expect(ErrorReporter.removingSensitiveData(from: nil) == nil)
    }
}
