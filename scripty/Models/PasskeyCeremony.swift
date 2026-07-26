//
//  PasskeyCeremony.swift
//  scripty
//
//  The wire types for the API's WebAuthn ceremonies. Each ceremony is two
//  requests: POST an options link (`registerPasskey` on the passkeys
//  collection, or `passkeyLogin` from the signed-out 401 challenge) to get the
//  standard WebAuthn options plus a `challengeId`, run the platform ceremony,
//  then POST the authenticator's answer to the options response's `verify`
//  link with the same `challengeId` — the API's replacement for the session
//  the browser flow keeps between the two halves.
//
//  All byte fields travel as base64url, the WebAuthn wire encoding.
//

import Foundation

/// Base64url ("base64 with URL and filename safe alphabet", unpadded) — how
/// WebAuthn JSON carries bytes. Foundation only speaks classic base64, so the
/// alphabet and padding are mapped here.
enum Base64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ string: String) -> Data? {
        var classic = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = classic.count % 4
        if remainder > 0 {
            classic += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: classic)
    }
}

/// The first half of either ceremony: the W3C options document under
/// `publicKey` (only the fields this client acts on are decoded), the
/// `challengeId` to echo back, and the `verify` link to answer to.
struct PasskeyCeremonyOptions: Decodable, HALResource {
    var challengeId: String?
    var publicKey: PublicKeyOptions?
    let links: HALLinks?

    private enum CodingKeys: String, CodingKey {
        case challengeId, publicKey
        case links = "_links"
    }

    struct PublicKeyOptions: Decodable {
        var challenge: String?
        /// Assertion options name the relying party flat…
        var rpId: String?
        /// …creation options name it as an object.
        var rp: RelyingParty?
        var user: UserEntity?

        struct RelyingParty: Decodable {
            var id: String?
            var name: String?
        }

        struct UserEntity: Decodable {
            var id: String?
            var name: String?
            var displayName: String?
        }
    }

    var verifyLink: HALLink? { link(.verify) }
    var challenge: Data? { publicKey?.challenge.flatMap(Base64URL.decode) }
    /// The relying party id, whichever spelling this ceremony's options use.
    var relyingPartyId: String? { publicKey?.rpId ?? publicKey?.rp?.id }
}

/// The authenticator's answer, in the same shape the browser flow sends:
/// registration fills `attestationObject`/`transports`, sign-in fills
/// `authenticatorData`/`signature`/`userHandle`.
struct PasskeyCredentialPayload: Encodable {
    var id: String
    var rawId: String
    var type = "public-key"
    var response: Response

    struct Response: Encodable {
        var clientDataJSON: String
        var attestationObject: String?
        var transports: [String]?
        var authenticatorData: String?
        var signature: String?
        var userHandle: String?
    }

    /// A registration answer. The platform authenticator is the device
    /// itself, so the transport is `internal`.
    static func attestation(credentialId: Data, clientDataJSON: Data,
                            attestationObject: Data) -> PasskeyCredentialPayload {
        PasskeyCredentialPayload(
            id: Base64URL.encode(credentialId),
            rawId: Base64URL.encode(credentialId),
            response: Response(
                clientDataJSON: Base64URL.encode(clientDataJSON),
                attestationObject: Base64URL.encode(attestationObject),
                transports: ["internal"]))
    }

    /// A sign-in answer.
    static func assertion(credentialId: Data, clientDataJSON: Data,
                          authenticatorData: Data, signature: Data,
                          userHandle: Data?) -> PasskeyCredentialPayload {
        PasskeyCredentialPayload(
            id: Base64URL.encode(credentialId),
            rawId: Base64URL.encode(credentialId),
            response: Response(
                clientDataJSON: Base64URL.encode(clientDataJSON),
                authenticatorData: Base64URL.encode(authenticatorData),
                signature: Base64URL.encode(signature),
                userHandle: userHandle.map(Base64URL.encode)))
    }
}

/// Second half of registering: the label is required, like the web form's.
struct RegisterPasskeyCommand: Encodable {
    var challengeId: String
    var label: String
    var credential: PasskeyCredentialPayload
}

/// Second half of signing in. The label names the token this mints (shown
/// nowhere yet, but a future token list would want to say which device).
struct PasskeyLoginCommand: Encodable {
    var challengeId: String
    var label: String?
    var credential: PasskeyCredentialPayload
}

/// What a verified sign-in answers: who the client now is, the bearer token
/// standing in for the password it never had, and where that token can be
/// revoked (`revokeToken` — the API's sign-out).
struct PasskeySession: Decodable, HALResource {
    var username: String?
    var token: String?
    let links: HALLinks?

    private enum CodingKeys: String, CodingKey {
        case username, token
        case links = "_links"
    }

    var revokeLink: HALLink? { link(.revokeToken) }
}
