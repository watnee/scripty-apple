//
//  Actor.swift
//  scripty
//

import Foundation

/// An actor available for casting. Listing requires the casting permission
/// (the server answers 403 otherwise; the UI degrades gracefully).
struct ScriptyActor: Decodable, Identifiable, Hashable, HALResource {
    let id: Int
    var first: String?
    var last: String?
    var phone: String?
    var email: String?
    var hasHeadshot: Bool?
    var projectIds: [Int]?
    let links: HALLinks?

    private enum CodingKeys: String, CodingKey {
        case id, first, last, phone, email, hasHeadshot, projectIds
        case links = "_links"
    }

    var displayName: String {
        let value = [first, last].compactMap { $0 }.joined(separator: " ")
        return value.isEmpty ? "Unnamed" : value
    }
}
