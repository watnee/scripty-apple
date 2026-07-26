//
//  Credentials.swift
//  scripty
//

import Foundation

/// What authenticates this client's API requests: HTTP Basic (the same
/// username/password as the web login), or the bearer token a passkey sign-in
/// minted — a passkey proves who you are without ever handing the client a
/// password, so the server issues a token to stand in for one.
///
/// Older keychain entries carry only `username` and `password`; both new
/// fields are optional so they decode unchanged.
struct Credentials: Codable, Equatable {
    var username: String
    var password: String?
    var token: String?
    /// Where the token can be revoked on sign-out. Learned from the sign-in
    /// response's `revokeToken` link and kept with the token it revokes.
    var revokeHref: String?

    init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    init(username: String, token: String, revokeHref: String?) {
        self.username = username
        self.token = token
        self.revokeHref = revokeHref
    }

    var authorizationHeader: String {
        if let token {
            return "Bearer \(token)"
        }
        let encoded = Data("\(username):\(password ?? "")".utf8).base64EncodedString()
        return "Basic \(encoded)"
    }
}
