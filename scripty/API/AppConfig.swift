//
//  AppConfig.swift
//  scripty
//

import Foundation

enum AppConfig {
    /// Set this UserDefaults key (e.g. "http://localhost:8080") to point the
    /// app at a local dev server instead of production.
    static let baseURLOverrideKey = "scripty.baseURLOverride"

    static let productionBaseURL = URL(string: "https://web-production-ce5bc3.up.railway.app")!

    static var baseURL: URL {
        if let raw = UserDefaults.standard.string(forKey: baseURLOverrideKey),
           let url = URL(string: raw) {
            return url
        }
        return productionBaseURL
    }
}
