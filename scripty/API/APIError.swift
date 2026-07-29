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
        case .redirectedOutOfAPI(let path):
            return "The server sent this request to a web page (\(path)) instead of answering it. If your account has to set a new password, do that on the Scripty website, then sign in here again."
        }
    }

    /// Whether trying the same request again could plausibly succeed without
    /// the writer doing anything. A 403 or a validation failure will fail
    /// identically forever; a dropped connection or a 5xx may not.
    var isRetryable: Bool {
        switch self {
        case .offline, .timedOut, .transport:
            return true
        case .server(let status):
            return status >= 500
        case .unauthorized, .forbidden, .notFound, .validation, .invalidLink,
             .redirectedOutOfAPI:
            return false
        }
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
        default:
            return .transport(urlError.localizedDescription)
        }
    }
}

extension Error {
    /// True when this failure is worth retrying on the writer's behalf.
    /// Non-`APIError` failures (a decode error, say) are not.
    var isRetryableAPIError: Bool {
        (self as? APIError)?.isRetryable ?? false
    }
}
