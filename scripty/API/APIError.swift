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
        }
    }
}
