import Foundation

/// GET requests can be repeated after a connection drops. Cancellation and
/// permanent failures must leave immediately, including in task groups.
struct NetworkRetry: Sendable {
    var delays: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16), .seconds(30)]
    var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }

    func run<T>(_ operation: (Int) async throws -> T) async throws -> T {
        for attempt in 0...delays.count {
            try Task.checkCancellation()
            do {
                return try await operation(attempt)
            } catch {
                // Preserve a real failure that raced with cancellation.
                if Task.isCancelled || Self.isCancellation(error) { throw error }
                guard Self.isTransient(error), attempt < delays.count else { throw error }
                Log.info(.cdn, "retry_scheduled", nil, ["attempt": attempt + 2, "delay": "\(delays[attempt])", "error": error])
                try await sleep(delays[attempt])
            }
        }
        preconditionFailure("unreachable")
    }

    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let ns = error as NSError
        return ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled
    }

    static func isTransient(_ error: Error) -> Bool {
        if let http = error as? HTTPFailure { return [408, 429, 500, 502, 503, 504].contains(http.status) }
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return false }
        return [NSURLErrorTimedOut, NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost,
                NSURLErrorNetworkConnectionLost, NSURLErrorDNSLookupFailed, NSURLErrorNotConnectedToInternet,
                NSURLErrorInternationalRoamingOff, NSURLErrorCallIsActive, NSURLErrorDataNotAllowed].contains(ns.code)
    }
}

struct HTTPFailure: Error, CustomStringConvertible, LocalizedError {
    var status: Int
    var url: URL
    var description: String { "\(url.absoluteString): HTTP \(status)" }
    var errorDescription: String? { "The download server returned HTTP \(status). Try again later." }
}
