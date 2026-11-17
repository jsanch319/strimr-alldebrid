import Foundation

/// Cancels a GET after response headers, including hosts which ignore Range. No video body is buffered.
final nonisolated class AllDebridHeaderProbe: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URLResponse, Error>?

    func response(session: URLSession, request: URLRequest) async throws -> URLResponse {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
            session.dataTask(with: request).resume()
        }
    }

    func urlSession(
        _: URLSession,
        dataTask _: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void,
    ) {
        finish(.success(response))
        completionHandler(.cancel)
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failure(error))
        }
    }

    private func finish(_ result: Result<URLResponse, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}
