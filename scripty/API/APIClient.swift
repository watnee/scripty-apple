//
//  APIClient.swift
//  scripty
//
//  Executes HAL links against the Scripty API with HTTP Basic authentication.
//  The only path the client knows on its own is the API entry point; every
//  other URL comes from `_links` in server responses.
//

import Foundation

final class APIClient {
    let baseURL: URL
    var credentials: Credentials?

    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init(baseURL: URL = AppConfig.baseURL, credentials: Credentials? = nil) {
        self.baseURL = baseURL
        self.credentials = credentials

        // Basic auth on every request; no cookies so state never leaks
        // between accounts (the server also sets remember-me cookies).
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        session = URLSession(configuration: configuration)

        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        encoder = JSONEncoder()
    }

    /// The API entry point (`GET /api`) — the root of all link-following.
    var rootLink: HALLink {
        HALLink(href: baseURL.appendingPathComponent("api").absoluteString)
    }

    @discardableResult
    func data(for link: HALLink,
              method: String = "GET",
              body: (any Encodable)? = nil) async throws -> Data {
        guard let url = link.url(relativeTo: baseURL) else {
            throw APIError.invalidLink(link.href)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/hal+json", forHTTPHeaderField: "Accept")
        if let credentials {
            request.setValue(credentials.basicAuthorizationHeader, forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try encoder.encode(body)
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.server(status: -1)
        }
        switch http.statusCode {
        case 200..<300:
            return data
        case 400:
            let fields = (try? decoder.decode([String: String].self, from: data)) ?? [:]
            throw APIError.validation(fields)
        case 401:
            throw APIError.unauthorized
        case 403:
            throw APIError.forbidden
        case 404:
            throw APIError.notFound
        default:
            throw APIError.server(status: http.statusCode)
        }
    }

    func fetch<T: Decodable>(_ type: T.Type = T.self,
                             from link: HALLink,
                             method: String = "GET",
                             body: (any Encodable)? = nil) async throws -> T {
        let data = try await data(for: link, method: method, body: body)
        return try decoder.decode(T.self, from: data)
    }
}
