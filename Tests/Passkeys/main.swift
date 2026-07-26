//
//  Passkey ceremony wire-format checks
//
//  The WebAuthn ceremony is two JSON exchanges whose byte fields travel as
//  base64url — an encoding Foundation doesn't speak, decoded from fixtures
//  shaped exactly like the server's (Spring Security's WebauthnJackson2Module
//  on the way out, PasskeyRestController's records on the way in). A field
//  spelled or encoded slightly wrong here fails only at the real server, as a
//  refused ceremony with a deliberately unspecific message — so the shapes are
//  pinned where the failure can actually be read.
//
//  Also pins Credentials: a keychain entry written by the Basic-only client
//  must keep decoding, and a token must win over a password when both exist.
//
//  Run via Tests/run.sh.
//

import Foundation

var failures = 0

/// Typed optional equality, not stringification: half the values here are
/// optionals decoded from JSON, and `Optional("x")` must equal `"x"`.
func check<T: Equatable>(_ label: String, _ actual: T?, _ expected: T?) {
    if actual == expected {
        print("  PASS  \(label)")
    } else {
        failures += 1
        print("  FAIL  \(label) — expected \(String(describing: expected)), "
            + "got \(String(describing: actual))")
    }
}

// MARK: - Base64url

func checkBase64URL() {
    print("Base64url:")
    // 0xFB 0xEF is "++8=" in classic base64: both special characters and
    // padding in one round-trip.
    let tricky = Data([0xFB, 0xEF])
    check("encodes with the url-safe alphabet, unpadded",
          Base64URL.encode(tricky), "--8")
    check("decodes its own output", Base64URL.decode("--8"), tricky)
    check("decodes the classic alphabet too", Base64URL.decode("++8"), tricky)
    check("round-trips text",
          Base64URL.decode(Base64URL.encode(Data("challenge".utf8)))
              .map { String(decoding: $0, as: UTF8.self) },
          "challenge")
    check("empty stays empty", Base64URL.encode(Data()), "")
    check("garbage decodes to nil", Base64URL.decode("!!!"), nil as Data?)
}

// MARK: - Credentials

func checkCredentials() {
    print("Credentials:")
    // Exactly what the Basic-only client wrote to the keychain.
    let legacy = Data(#"{"username":"pat","password":"pw"}"#.utf8)
    let decoded = try? JSONDecoder().decode(Credentials.self, from: legacy)
    check("a legacy keychain entry still decodes", decoded?.username, "pat")
    check("…and still authenticates as Basic",
          decoded?.authorizationHeader,
          "Basic \(Data("pat:pw".utf8).base64EncodedString())")

    let token = Credentials(username: "pat", token: "tok123", revokeHref: "/api/token")
    check("a passkey session authenticates as Bearer",
          token.authorizationHeader, "Bearer tok123")
    let rewritten = (try? JSONEncoder().encode(token))
        .flatMap { try? JSONDecoder().decode(Credentials.self, from: $0) }
    check("token credentials survive the keychain round-trip", rewritten, token)
    check("…including where to revoke", rewritten?.revokeHref, "/api/token")
}

// MARK: - Options decoding (server → client)

func checkOptionsDecoding() {
    print("Ceremony options:")
    let decoder = JSONDecoder()

    // The login options document, as PasskeyRestController answers it: the
    // W3C request options under `publicKey`, the challenge handle, and the
    // curied verify link.
    let assertion = Data("""
    {"challengeId":"c1d2","publicKey":{"challenge":"aGVsbG8","timeout":300000,
    "rpId":"web-production-ce5bc3.up.railway.app","allowCredentials":[],
    "userVerification":"preferred"},
    "_links":{"scripty:verify":{"href":"https://x/api/login/passkey"}}}
    """.utf8)
    let login = try? decoder.decode(PasskeyCeremonyOptions.self, from: assertion)
    check("login options carry the challenge handle", login?.challengeId, "c1d2")
    check("…the challenge bytes", login?.challenge, Data("hello".utf8))
    check("…the relying party", login?.relyingPartyId,
          "web-production-ce5bc3.up.railway.app")
    check("…and the verify link, through the curie",
          login?.verifyLink?.href, "https://x/api/login/passkey")

    // The registration options document: the relying party is an object here,
    // and the user id is base64url bytes.
    let creation = Data("""
    {"challengeId":"c3","publicKey":{"rp":{"name":"Scripty","id":"scripty.test"},
    "user":{"id":"cGF0LWlk","name":"pat","displayName":"Pat Q"},
    "challenge":"Y2hhbGxlbmdl","pubKeyCredParams":[{"type":"public-key","alg":-7}],
    "excludeCredentials":[],"attestation":"none"},
    "_links":{"scripty:verify":{"href":"https://x/api/account/passkeys"}}}
    """.utf8)
    let register = try? decoder.decode(PasskeyCeremonyOptions.self, from: creation)
    check("creation options name the relying party from the rp object",
          register?.relyingPartyId, "scripty.test")
    check("…the user handle bytes",
          register?.publicKey?.user?.id.flatMap(Base64URL.decode),
          Data("pat-id".utf8))
    check("…the account name", register?.publicKey?.user?.name, "pat")

    // What a verified sign-in answers.
    let session = Data("""
    {"username":"pat","token":"tok","_links":{
    "scripty:revokeToken":{"href":"https://x/api/token"}}}
    """.utf8)
    let signedIn = try? decoder.decode(PasskeySession.self, from: session)
    check("the session names the user", signedIn?.username, "pat")
    check("…hands over the token", signedIn?.token, "tok")
    check("…and says where it dies", signedIn?.revokeLink?.href, "https://x/api/token")
}

// MARK: - Command encoding (client → server)

func checkCommandEncoding() throws {
    print("Ceremony answers:")
    let encoder = JSONEncoder()

    let attestation = PasskeyCredentialPayload.attestation(
        credentialId: Data("cred".utf8),
        clientDataJSON: Data("client".utf8),
        attestationObject: Data([0xFB, 0xEF]))
    let registerData = try encoder.encode(RegisterPasskeyCommand(
        challengeId: "c3", label: "Pat's iPhone", credential: attestation))
    let register = try JSONSerialization.jsonObject(with: registerData) as? [String: Any]
    let regCredential = register?["credential"] as? [String: Any]
    let regResponse = regCredential?["response"] as? [String: Any]
    check("registration echoes the challenge id", register?["challengeId"] as? String, "c3")
    check("…carries the label", register?["label"] as? String, "Pat's iPhone")
    check("…types the credential", regCredential?["type"] as? String, "public-key")
    check("…base64url-encodes the id", regCredential?["id"] as? String, "Y3JlZA")
    check("…and the attestation, url-safe unpadded",
          regResponse?["attestationObject"] as? String, "--8")
    check("…declares the platform transport",
          (regResponse?["transports"] as? [String]) ?? [], ["internal"])
    check("…and sends no assertion fields",
          regResponse?["signature"] == nil && regResponse?["authenticatorData"] == nil,
          true)

    let assertion = PasskeyCredentialPayload.assertion(
        credentialId: Data("cred".utf8),
        clientDataJSON: Data("client".utf8),
        authenticatorData: Data("auth".utf8),
        signature: Data("sig".utf8),
        userHandle: Data("pat-id".utf8))
    let loginData = try encoder.encode(PasskeyLoginCommand(
        challengeId: "c1", label: "Pat's iPhone", credential: assertion))
    let login = try JSONSerialization.jsonObject(with: loginData) as? [String: Any]
    let logResponse = (login?["credential"] as? [String: Any])?["response"] as? [String: Any]
    check("sign-in carries the signature", logResponse?["signature"] as? String, "c2ln")
    check("…the user handle", logResponse?["userHandle"] as? String, "cGF0LWlk")
    check("…and no attestation fields",
          logResponse?["attestationObject"] == nil && logResponse?["transports"] == nil,
          true)
}

// MARK: -

checkBase64URL()
checkCredentials()
checkOptionsDecoding()
try checkCommandEncoding()

print("")
if failures == 0 {
    print("All passkey checks passed.")
    exit(0)
} else {
    print("\(failures) passkey check(s) FAILED.")
    exit(1)
}
