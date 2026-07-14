//
//  AppModel.swift
//  scripty
//
//  Session state: credentials, the API root document, and the global
//  signed-in/out phase. A 401 from anywhere routes through handle(_:)
//  and drops the user back to the login screen.
//

import Foundation
import Observation

@Observable @MainActor
final class AppModel {
    enum Phase {
        case loading
        case signedOut
        case signedIn
    }

    private(set) var phase: Phase = .loading
    private(set) var apiRoot: APIRoot?
    var signInError: String?

    let client = APIClient()

    /// Called once at launch: try stored credentials against the API root.
    func bootstrap() async {
        guard let stored = KeychainStore.load() else {
            phase = .signedOut
            return
        }
        client.credentials = stored
        do {
            apiRoot = try await client.fetch(APIRoot.self, from: client.rootLink)
            phase = .signedIn
        } catch APIError.unauthorized {
            client.credentials = nil
            KeychainStore.delete()
            phase = .signedOut
        } catch {
            client.credentials = nil
            signInError = error.localizedDescription
            phase = .signedOut
        }
    }

    func signIn(username: String, password: String) async {
        let credentials = Credentials(username: username, password: password)
        client.credentials = credentials
        do {
            apiRoot = try await client.fetch(APIRoot.self, from: client.rootLink)
            try? KeychainStore.save(credentials)
            signInError = nil
            phase = .signedIn
        } catch APIError.unauthorized {
            client.credentials = nil
            signInError = "Incorrect username or password."
        } catch {
            client.credentials = nil
            signInError = error.localizedDescription
        }
    }

    func signOut() {
        KeychainStore.delete()
        client.credentials = nil
        apiRoot = nil
        signInError = nil
        phase = .signedOut
    }

    /// Global error routing: revoked credentials end the session.
    func handle(_ error: Error) {
        if case APIError.unauthorized = error {
            signOut()
            signInError = "Your session ended. Please sign in again."
        }
    }
}
