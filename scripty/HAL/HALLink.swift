//
//  HALLink.swift
//  scripty
//
//  HAL hypermedia link types. The client never hardcodes endpoint paths;
//  it follows these links starting from the API root.
//

import Foundation

/// A single HAL link object (`{"href": "..."}`).
///
/// Identifiable by its href, so a screen can be presented from a link the
/// server advertised rather than from a flag — the sheet then cannot open
/// before the server has said where it leads.
struct HALLink: Codable, Hashable, Sendable, Identifiable {
    let href: String
    var templated: Bool?

    var id: String { href }

    init(href: String, templated: Bool? = nil) {
        self.href = href
        self.templated = templated
    }

    /// Server hrefs are absolute in practice; resolve relative ones defensively.
    ///
    /// Expands first, so a template is never sent as a URL — see `expanded`.
    func url(relativeTo base: URL) -> URL? {
        URL(string: expanded().href, relativeTo: base)?.absoluteURL
    }

    /// A copy of this link with the given query parameters added or replaced.
    ///
    /// Values naming a variable the template declares fill it where it stands;
    /// the rest are appended. Either way the result is a plain URL, since
    /// `expanded` clears whatever was left unfilled.
    func addingQuery(_ items: [String: String]) -> HALLink {
        let filled = expanded(with: items)
        guard var components = URLComponents(string: filled.href) else { return filled }
        var query = components.queryItems ?? []
        for (name, value) in items.sorted(by: { $0.key < $1.key }) {
            query.removeAll { $0.name == name }
            query.append(URLQueryItem(name: name, value: value))
        }
        components.queryItems = query
        return HALLink(href: components.string ?? filled.href)
    }

    // MARK: - URI templates

    /// This link as a plain URL: every RFC 6570 variable the server declared is
    /// either filled from `values` or removed.
    ///
    /// The server templates every href whose endpoint takes an optional
    /// parameter, so a project's script arrives as
    /// `/api/block?projectId=7{&editionId}`. Following that verbatim does not
    /// ask for the default edition — it asks for the project `7{`, which the
    /// server cannot read as a number and refuses with a 400 carrying no field
    /// map, which is to say "The server rejected the request." over the whole
    /// screenplay. Reducing the template to the URL it stands for is the
    /// difference between a script that opens and one that does not.
    func expanded(with values: [String: String] = [:]) -> HALLink {
        guard href.contains("{") else { return self }
        var result = ""
        var rest = Substring(href)
        // Whether a query has been opened already, so a `{&…}` reached before
        // any `?` — one whose earlier `{?…}` expanded to nothing, say — starts
        // the query rather than continuing one that isn't there.
        var hasQuery = false
        while let open = rest.firstIndex(of: "{") {
            guard let close = rest[open...].firstIndex(of: "}") else { break }
            let literal = rest[rest.startIndex..<open]
            if literal.contains("?") { hasQuery = true }
            result += literal
            result += Self.expand(rest[rest.index(after: open)..<close],
                                  with: values, hasQuery: &hasQuery)
            rest = rest[rest.index(after: close)...]
        }
        result += rest
        return HALLink(href: result)
    }

    /// One `{…}` expression, filled with whatever `values` offers for the names
    /// it lists and dropped where it offers nothing.
    ///
    /// Only the forms the server emits are honoured: `{?a,b}` and `{&a,b}` for
    /// query parameters, and the bare `{a}` it uses inside a query value. The
    /// other operators (`/`, `;`, `.`, …) are treated as bare names, which for a
    /// server that never sends them keeps the unfilled case — drop it — right.
    private nonisolated static func expand(_ expression: Substring,
                                           with values: [String: String],
                                           hasQuery: inout Bool) -> String {
        var names = expression
        var isQuery = false
        switch names.first {
        case "?", "&":
            isQuery = true
            names = names.dropFirst()
        case "+", "#", "/", ".", ";", "=", ",", "!", "@", "|":
            names = names.dropFirst()
        default:
            break
        }
        // `*` (explode) and `:n` (prefix) change nothing for the single-valued
        // strings passed here, so the name is all that is read.
        let wanted = names.split(separator: ",").map { name -> String in
            let bare = name.hasSuffix("*") ? name.dropLast() : name[...]
            return String(bare.split(separator: ":").first ?? bare)
        }
        guard isQuery else {
            return wanted.compactMap { values[$0] }.map(encode).joined(separator: ",")
        }
        let pairs = wanted.compactMap { name in
            values[name].map { "\(encode(name))=\(encode($0))" }
        }
        guard !pairs.isEmpty else { return "" }
        let separator = hasQuery ? "&" : "?"
        hasQuery = true
        return separator + pairs.joined(separator: "&")
    }

    /// RFC 6570 percent-encodes everything outside the unreserved set, which is
    /// stricter than a query value has to be and never wrong.
    private nonisolated static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    private nonisolated static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
}

/// The `_links` object of a HAL resource.
/// Tolerates both single-object and array rel values (Spring emits single objects).
struct HALLinks: Hashable, Sendable {
    private var storage: [String: HALLink]

    init(_ storage: [String: HALLink] = [:]) {
        self.storage = storage
    }

    subscript(rel: Rel) -> HALLink? {
        storage[rel.rawValue]
    }

    var isEmpty: Bool { storage.isEmpty }

    func contains(_ rel: Rel) -> Bool {
        storage[rel.rawValue] != nil
    }
}

extension HALLinks: Decodable {
    private enum Value: Decodable {
        case single(HALLink)
        case many([HALLink])

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let link = try? container.decode(HALLink.self) {
                self = .single(link)
            } else {
                self = .many(try container.decode([HALLink].self))
            }
        }
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode([String: Value].self)
        var links: [String: HALLink] = [:]
        var curied: [String: HALLink] = [:]
        for (rel, value) in raw {
            let link: HALLink?
            switch value {
            case .single(let one):
                link = one
            case .many(let list):
                link = list.first
            }
            guard let link else { continue }
            links[rel] = link
            // The server namespaces its own rels through a HAL curie, so
            // `actors` arrives as `scripty:actors`. Record the bare name too, so
            // a lookup by rel works whether or not a curie provider is in play —
            // the demo backend answers without one.
            if let colon = rel.firstIndex(of: ":") {
                curied[String(rel[rel.index(after: colon)...])] = link
            }
        }
        // An exact match always wins; the un-prefixed aliases only fill gaps.
        storage = curied.merging(links) { _, exact in exact }
    }
}

/// A resource that carries HAL `_links`. UI affordances are driven by link
/// presence: no `update` link means no edit button.
protocol HALResource {
    var links: HALLinks? { get }
}

extension HALResource {
    func link(_ rel: Rel) -> HALLink? {
        links?[rel]
    }

    func hasLink(_ rel: Rel) -> Bool {
        link(rel) != nil
    }
}
