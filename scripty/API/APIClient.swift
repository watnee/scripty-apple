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

    /// When set, requests are answered by the in-process demo backend
    /// instead of the network (see `DemoBackend`).
    private let demo: DemoBackend?

    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init(baseURL: URL = AppConfig.baseURL, credentials: Credentials? = nil,
         demo: DemoBackend? = nil) {
        self.baseURL = baseURL
        self.credentials = credentials
        self.demo = demo

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

    /// Fixed multipart boundary so the demo backend can parse the body
    /// without inspecting request headers.
    static let multipartBoundary = "----scripty-boundary-7f3a1c"

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

        let data: Data
        let statusCode: Int
        if let demo {
            (statusCode, data) = await demo.respond(method: method, url: url,
                                                    body: request.httpBody)
        } else {
            let (received, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw APIError.server(status: -1)
            }
            data = received
            statusCode = http.statusCode
        }
        switch statusCode {
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
            throw APIError.server(status: statusCode)
        }
    }

    func fetch<T: Decodable>(_ type: T.Type = T.self,
                             from link: HALLink,
                             method: String = "GET",
                             body: (any Encodable)? = nil) async throws -> T {
        let data = try await data(for: link, method: method, body: body)
        return try decoder.decode(T.self, from: data)
    }

    /// POST a single file as `multipart/form-data` (part name `file`) and
    /// decode the response. Used for project import.
    func upload<T: Decodable>(_ type: T.Type = T.self,
                              to link: HALLink,
                              fileData: Data,
                              filename: String,
                              contentType: String = "application/json") async throws -> T {
        guard let url = link.url(relativeTo: baseURL) else {
            throw APIError.invalidLink(link.href)
        }
        let boundary = Self.multipartBoundary
        var body = Data()
        func append(_ string: String) { body.append(Data(string.utf8)) }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: \(contentType)\r\n\r\n")
        body.append(fileData)
        append("\r\n--\(boundary)--\r\n")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/hal+json", forHTTPHeaderField: "Accept")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let credentials {
            request.setValue(credentials.basicAuthorizationHeader, forHTTPHeaderField: "Authorization")
        }
        request.httpBody = body

        let data: Data
        let statusCode: Int
        if let demo {
            (statusCode, data) = await demo.respond(method: "POST", url: url, body: body)
        } else {
            let (received, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw APIError.server(status: -1)
            }
            data = received
            statusCode = http.statusCode
        }
        switch statusCode {
        case 200..<300:
            return try decoder.decode(T.self, from: data)
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
            throw APIError.server(status: statusCode)
        }
    }
}
