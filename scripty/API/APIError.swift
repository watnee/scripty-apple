//
//  APIError.swift
//  scripty
//

import Foundation

enum APIError: Error, LocalizedError {
    case unauthorized
    case forbidden
    case notFound
    /// 400 responses carry a flat `{field: message}` map.
    case validation([String: String])
    case server(status: Int)
    case invalidLink(String)
    /// The request never reached the server: no connection, or it dropped
    /// mid-flight. Distinct from `server` because it is the writer's network
    /// rather than the API that is at fault, and because it is worth retrying.
    case offline
    /// The connection stood up but the server didn't answer in time.
    case timedOut
    /// Any other transport-level failure (TLS, DNS, a malformed response).
    case transport(String)
    /// The request was abandoned rather than failed: the task that owned it was
    /// cancelled, which on this client means a screen was torn down, a debounce
    /// was superseded, or a poll was stopped. Never the writer's problem and
    /// never worth saying — `isCancellation` below is what every reporting path
    /// checks before putting anything on screen. Its own case rather than a
    /// `transport` string because "cancelled" is not a network condition: read
    /// as one it recruits the offline machinery, and the writer is told their
    /// connection is gone over a request this app threw away itself.
    case cancelled
    /// The API sent the request somewhere that isn't the API — in practice the
    /// server's own web pages. An account locked to the change-password page is
    /// the way this happens: the lock redirects every request, including the
    /// ones from here. Refused rather than followed, so the writer gets this
    /// instead of a decode failure against a page of HTML.
    case redirectedOutOfAPI(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Your session is no longer valid. Please sign in again."
        case .forbidden:
            return "You don't have permission to do that."
        case .notFound:
            return "That item no longer exists on the server."
        case .validation(let fields):
            if fields.isEmpty { return "The server rejected the request." }
            return fields.sorted { $0.key < $1.key }
                .map { "\($0.value)" }
                .joined(separator: "\n")
        case .server(let status):
            return "The server returned an unexpected error (\(status))."
        case .invalidLink(let href):
            return "The server returned an unusable link (\(href))."
        case .offline:
            return "You're offline. Your work is kept on this device and will be saved when the connection returns."
        case .timedOut:
            return "The server took too long to respond. Trying again shortly."
        case .transport(let detail):
            return "Couldn't reach the server (\(detail))."
        case .cancelled:
            // Unreachable in the app — kept honest for a log line.
            return "The request was cancelled."
        case .redirectedOutOfAPI(let path):
            return "The server sent this request to a web page (\(path)) instead of answering it. If your account has to set a new password, do that on the Scripty website, then sign in here again."
        }
    }

    /// Whether trying the same request again could plausibly succeed without
    /// the writer doing anything. A 403 or a validation failure will fail
    /// identically forever; a dropped connection or a 5xx may not.
    ///
    /// A cancellation is deliberately *not* retryable, even though repeating it
    /// would very likely work. Every caller of this reads it as "the network is
    /// having a moment": they fall back to the offline copy, raise the offline
    /// banner, hold a new line on the device instead of creating it. None of
    /// that is true of a request this app cancelled itself, and whoever did the
    /// cancelling has either gone away or is about to ask again.
    var isRetryable: Bool {
        switch self {
        case .offline, .timedOut, .transport:
            return true
        case .server(let status):
            return status >= 500
        case .unauthorized, .forbidden, .notFound, .validation, .invalidLink,
             .redirectedOutOfAPI, .cancelled:
            return false
        }
    }

    /// Whether this is the abandoned-request case. Kept as a property rather
    /// than left to pattern matching at each site because the rule it enforces
    /// is one rule: nothing cancelled is ever shown to the writer.
    var isCancellation: Bool {
        if case .cancelled = self { return true }
        return false
    }

    /// Maps a `URLSession` failure onto the cases above, so callers never have
    /// to reason about `NSURLErrorDomain` and writers never see it in an alert.
    static func from(transportError error: Error) -> APIError {
        guard let urlError = error as? URLError else {
            return .transport(error.localizedDescription)
        }
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost,
             .dataNotAllowed, .internationalRoamingOff, .cannotConnectToHost:
            return .offline
        case .timedOut:
            return .timedOut
        case .cancelled:
            return .cancelled
        default:
            return .transport(urlError.localizedDescription)
        }
    }

    /// Maps a failure raised anywhere in a request's chain, not just by the
    /// transport. `URLSession`'s async methods report Swift task cancellation
    /// as `URLError.cancelled`, but a chain that checks cancellation itself
    /// throws `CancellationError`, and neither should reach a writer.
    static func from(_ error: Error) -> APIError {
        if error is CancellationError { return .cancelled }
        return from(transportError: error)
    }
}

extension Error {
    /// True when this failure is worth retrying on the writer's behalf.
    /// Non-`APIError` failures (a decode error, say) are not.
    var isRetryableAPIError: Bool {
        (self as? APIError)?.isRetryable ?? false
    }

    /// True when this is an abandoned request rather than a failed one.
    ///
    /// The rule every reporting path follows: a cancelled request has no news
    /// for the writer. It means a screen was left, a debounce was superseded or
    /// a poll was stopped — all of them things this app did on purpose, none of
    /// them anything to put an alert on screen over. Left unchecked it reads as
    /// "Couldn't reach the server (cancelled)", which is both alarming and
    /// false: the server was reached, or would have been.
    var isCancelledRequest: Bool {
        if self is CancellationError { return true }
        return (self as? APIError)?.isCancellation ?? false
    }
}
