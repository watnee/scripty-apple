//
//  scriptyApp.swift
//  scripty
//
//  Created by Clint Watnee on 7/13/26.
//

import SwiftUI

@main
struct scriptyApp: App {
    @State private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView(app: appModel)
        }
    }
}

/// Switches between the launch spinner, login, and the main app.
struct RootView: View {
    let app: AppModel

    var body: some View {
        switch app.phase {
        case .loading:
            ProgressView()
                .task { await app.bootstrap() }
        case .signedOut:
            LoginView(app: app)
        case .signedIn:
            ContentView(app: app)
        }
    }
}
