//
//  Credentials.swift
//  scripty
//

import Foundation

/// HTTP Basic credentials for the Scripty API — the same username (or email)
/// and password used for the web login. The server has no token scheme.
struct Credentials: Codable, Equatable {
    var username: String
    var password: String

    var basicAuthorizationHeader: String {
        let encoded = Data("\(username):\(password)".utf8).base64EncodedString()
        return "Basic \(encoded)"
    }
}
