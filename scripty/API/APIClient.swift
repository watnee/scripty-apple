//
//  APIClient.swift
//  scripty
//
//  Executes HAL links against the Scripty API, authenticating each request
//  with HTTP Basic or, after a passkey sign-in, a bearer token (Credentials
//  decides which). The only path the client knows on its own is the API entry
//  point; every other URL comes from `_links` in server responses.
//

import Foundation

final class APIClient {
    let baseURL: URL
    var credentials: Credentials?

    /// Asked before every network request; answering true fails the request
    /// immediately with `APIError.offline` rather than spending a round trip
    /// discovering the same thing, and names the failure for what it is
    /// instead of leaving it to whatever the transport happens to report.
    /// Wired by AppModel to the connectivity monitor on real clients only —
    /// the demo backend never goes offline.
    var offlineCheck: (() -> Bool)?

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
        // Fail the request rather than sitting in URLSession's connectivity
        // wait. The writer on a train is covered better by the app's own
        // machinery — `offlineCheck` below refuses a request the moment the
        // route is gone, the words are flagged unsaved and written to disk,
        // a backoff retries them, and `connectionRestored()` pushes the lot
        // the instant the route is back. Waiting here only hides that from
        // the writer.
        //
        // It is also the wrong answer to the one case it can still reach.
        // With the connectivity monitor wired, a request only gets as far as
        // the session when the path *is* satisfied — so the wait engages
        // exactly when the route is fine and the server is not. URLSession
        // counts a refused connection as something to wait out, so that case
        // hangs for the full resource timeout and then reports a timeout,
        // instead of failing in milliseconds and entering the retry path.
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
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
    nonisolated static let multipartBoundary = "----scripty-boundary-7f3a1c"

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
            request.setValue(credentials.authorizationHeader, forHTTPHeaderField: "Authorization")
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
            (statusCode, data) = try await perform(request)
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

    /// What the server says a caller with no credentials may do.
    ///
    /// The entry point answers an unauthenticated request with a 401 challenge,
    /// and that challenge carries links — today just the way into password
    /// recovery, which is the one thing you can only need while signed out.
    /// Every other document that could advertise it is behind the sign-in, so
    /// the challenge is where it has to live.
    ///
    /// Deliberately swallows everything. This runs on the way to a login screen
    /// that works perfectly well without it; a server that offers nothing, or
    /// no server at all, should cost the writer nothing but a missing button.
    func signedOutLinks() async -> HALLinks {
        guard demo == nil, let url = rootLink.url(relativeTo: baseURL) else { return HALLinks() }
        var request = URLRequest(url: url)
        request.setValue("application/hal+json", forHTTPHeaderField: "Accept")
        guard let (_, data) = try? await perform(request),
              let document = try? decoder.decode(SignedOutDocument.self, from: data) else {
            return HALLinks()
        }
        return document.links ?? HALLinks()
    }

    /// Just the links: the challenge body says nothing else worth decoding.
    private struct SignedOutDocument: Decodable {
        let links: HALLinks?

        private enum CodingKeys: String, CodingKey {
            case links = "_links"
        }
    }

    /// Runs a request and reports the outcome as a status code, translating
    /// transport failures into `APIError` so no caller ever has to surface a
    /// raw `NSURLErrorDomain` string to the writer.
    private func perform(_ request: URLRequest) async throws -> (Int, Data) {
        // No route to the network means the request is guaranteed lost time:
        // fail now, and fail as `.offline`, so a save is held (and a load
        // falls back to the offline copy) knowing why.
        if offlineCheck?() == true {
            throw APIError.offline
        }
        let received: Data
        let response: URLResponse
        do {
            (received, response) = try await session.data(for: request)
        } catch {
            throw APIError.from(transportError: error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw APIError.server(status: -1)
        }
        return (http.statusCode, received)
    }

    func fetch<T: Decodable>(_ type: T.Type = T.self,
                             from link: HALLink,
                             method: String = "GET",
                             body: (any Encodable)? = nil) async throws -> T {
        let data = try await data(for: link, method: method, body: body)
        return try decoder.decode(T.self, from: data)
    }

    /// Decode a payload with the same decoder the network path uses — for
    /// reading back a response the offline store saved byte for byte, so a
    /// cached document and a live one decode identically.
    func decode<T: Decodable>(_ type: T.Type = T.self, from data: Data) throws -> T {
        try decoder.decode(T.self, from: data)
    }

    // MARK: - Multipart upload

    /// POST a file as `multipart/form-data`, following a HAL link. Used for
    /// project import and for importing a song/note file — the server reuses
    /// its web import pipeline for both.
    @discardableResult
    func upload(to link: HALLink,
                fields: [String: String] = [:],
                fileFieldName: String = "file",
                fileName: String,
                fileData: Data,
                mimeType: String = "application/octet-stream") async throws -> Data {
        guard let url = link.url(relativeTo: baseURL) else {
            throw APIError.invalidLink(link.href)
        }
        let boundary = Self.multipartBoundary
        var body = Data()
        let dashes = "--"
        let crlf = "\r\n"
        for (name, value) in fields.sorted(by: { $0.key < $1.key }) {
            body.append(Data((dashes + boundary + crlf).utf8))
            body.append(Data(("Content-Disposition: form-data; name=\"\(name)\"" + crlf + crlf).utf8))
            body.append(Data((value + crlf).utf8))
        }
        body.append(Data((dashes + boundary + crlf).utf8))
        body.append(Data(("Content-Disposition: form-data; name=\"\(fileFieldName)\"; filename=\"\(fileName)\"" + crlf).utf8))
        body.append(Data(("Content-Type: \(mimeType)" + crlf + crlf).utf8))
        body.append(fileData)
        body.append(Data((crlf + dashes + boundary + dashes + crlf).utf8))

        let data: Data
        let statusCode: Int
        if let demo {
            (statusCode, data) = await demo.respond(method: "POST", url: url, body: body)
        } else {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/hal+json", forHTTPHeaderField: "Accept")
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            if let credentials {
                request.setValue(credentials.authorizationHeader, forHTTPHeaderField: "Authorization")
            }
            request.httpBody = body
            (statusCode, data) = try await perform(request)
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

    func upload<T: Decodable>(_ type: T.Type = T.self,
                              to link: HALLink,
                              fields: [String: String] = [:],
                              fileFieldName: String = "file",
                              fileName: String,
                              fileData: Data,
                              mimeType: String = "application/octet-stream") async throws -> T {
        let data = try await upload(to: link, fields: fields, fileFieldName: fileFieldName,
                                    fileName: fileName, fileData: fileData, mimeType: mimeType)
        return try decoder.decode(T.self, from: data)
    }
}
