import Foundation

/// UI text, without NSError's task identifiers, resume data or internal URLs.
/// Diagnostics still records the underlying error separately.
public func errorMessage(_ error: Error) -> String {
    let ns = error as NSError
    let text: String
    if ns.domain == NSURLErrorDomain {
        switch ns.code {
        case NSURLErrorNetworkConnectionLost:
            text = "The connection was lost. Try again to continue."
        case NSURLErrorNotConnectedToInternet:
            text = "You’re offline. Reconnect and try again to continue."
        case NSURLErrorTimedOut:
            text = "The download timed out. Try again to continue."
        default: text = ns.localizedDescription
        }
    } else if let http = error as? HTTPFailure {
        text = http.errorDescription!
    } else if let tact = error as? TACTError {
        switch tact {
        case .notFound(let value) where URL(string: value)?.host != nil:
            text = "A required file is unavailable on the download server. Try again later."
        case .network:
            text = "Could not reach the download server. Try again to continue."
        default: text = tact.description
        }
    } else if let localized = error as? LocalizedError, let description = localized.errorDescription {
        text = description
    } else if !(type(of: error) is NSError.Type) {
        text = String(describing: error)
    } else {
        text = ns.localizedDescription
    }
    return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
}
