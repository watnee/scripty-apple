//
//  Credentials.swift
//  scripty
//

import Foundation

/// A stored authorization for the Scripty API. Historically this was always HTTP
/// Basic (the web username/email + password). Passkey sign-in produces a
/// long-lived opaque bearer token instead — there is no password to store — so a
/// credential now carries a scheme and is replayed as either a `Basic` or a
/// `Bearer` `Authorization` header.
struct Credentials: Codable, Equatable {
    enum Scheme: String, Codable {
        case basic
        case bearer
    }

    var scheme: Scheme
    var username: String
    /// The password for `.basic`, or the opaque token for `.bearer`.
    var secret: String

    /// HTTP Basic credentials (username/email + password).
    init(username: String, password: String) {
        self.scheme = .basic
        self.username = username
        self.secret = password
    }

    /// A bearer token minted by a passkey sign-in.
    init(token: String, username: String) {
        self.scheme = .bearer
        self.username = username
        self.secret = token
    }

    var authorizationHeader: String {
        switch scheme {
        case .basic:
            let encoded = Data("\(username):\(secret)".utf8).base64EncodedString()
            return "Basic \(encoded)"
        case .bearer:
            return "Bearer \(secret)"
        }
    }

    // Backward compatibility: credentials stored before passkeys existed have no
    // `scheme` (and used `password` for the secret), so default those to Basic.
    private enum CodingKeys: String, CodingKey {
        case scheme, username, secret, password
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        username = try container.decode(String.self, forKey: .username)
        scheme = try container.decodeIfPresent(Scheme.self, forKey: .scheme) ?? .basic
        if let secret = try container.decodeIfPresent(String.self, forKey: .secret) {
            self.secret = secret
        } else {
            secret = try container.decode(String.self, forKey: .password)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(scheme, forKey: .scheme)
        try container.encode(username, forKey: .username)
        try container.encode(secret, forKey: .secret)
    }
}
