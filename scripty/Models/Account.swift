//
//  Account.swift
//  scripty
//
//  The signed-in user's own account — not an admin's view of someone else's.
//  Advertised on the API root to anyone signed in, which is what separates it
//  from the admin-only `users` collection.
//
//  Registering a new passkey is deliberately absent: that is a WebAuthn ceremony
//  the browser and the server's filters run between them, so the API (and this
//  client) offer listing and revoking only.
//

import Foundation

struct Account: Decodable, HALResource {
    var username: String?
    var firstName: String?
    var lastName: String?
    /// The server is still insisting on a password change — worth saying out
    /// loud on the account screen rather than waiting for the next redirect.
    var passwordChangeRequired: Bool?
    /// Whether the deployment has passkeys configured at all. The `passkeys`
    /// link is the real gate; this is what explains its absence to the user.
    var passkeysEnabled: Bool?
    let links: HALLinks?

    private enum CodingKeys: String, CodingKey {
        case username, firstName, lastName, passwordChangeRequired, passkeysEnabled
        case links = "_links"
    }

    var displayName: String {
        let value = [firstName, lastName].compactMap { $0 }.joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? (username ?? "Your Account") : value
    }

    var canChangePassword: Bool { hasLink(.changePassword) }
}

/// One passkey registered to the signed-in user. The credential id is the
/// base64url form WebAuthn uses; whether it may be revoked travels as a link.
struct Passkey: Decodable, Identifiable, Hashable, HALResource {
    let credentialId: String
    var label: String?
    var created: Date?
    var lastUsed: Date?
    let links: HALLinks?

    var id: String { credentialId }

    private enum CodingKeys: String, CodingKey {
        case credentialId, label, created, lastUsed
        case links = "_links"
    }

    var displayLabel: String {
        let trimmed = (label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Passkey" : trimmed
    }

    var canDelete: Bool { hasLink(.delete) }
}

/// The current password is required even when the server has flagged the
/// account as needing a change — knowing the old one is what makes the new one
/// the account holder's choice.
struct ChangePasswordCommand: Encodable {
    var currentPassword: String
    var newPassword: String
}
