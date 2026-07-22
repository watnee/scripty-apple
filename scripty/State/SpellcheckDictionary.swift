//
//  SpellcheckDictionary.swift
//  scripty
//
//  The words Scripty should stop underlining.
//
//  Screenplays are full of names, invented places and shouted sluglines that no
//  dictionary knows, and the alternative to a list like this is turning spell
//  checking off altogether. The web editor keeps one under `scripty-spell-
//  ignored`, as an object keyed by the uppercased word, and this keeps the same
//  shape so the two are recognisably the same feature.
//
//  One real divergence, and it is worth knowing about. The browser runs its own
//  checker and can simply skip these words; here the checking is the system's,
//  and the only way to reach it is `UITextChecker.learnWord`, which adds to the
//  *device's* dictionary rather than to Scripty's. So a word ignored here stops
//  being flagged in other apps too — and removing it here takes it back out
//  again, which is why removal unlearns rather than just forgetting.
//

import Foundation
import Observation
#if canImport(UIKit)
import UIKit
#endif

@Observable
@MainActor
final class SpellcheckDictionary {
    static let shared = SpellcheckDictionary()

    /// Uppercased, as the web stores them, and sorted so the list does not
    /// reshuffle itself between visits.
    private(set) var words: [String] = []

    private let defaults: UserDefaults
    private static let key = "scripty-spell-ignored"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        words = Self.decode(defaults.string(forKey: Self.key))
        // Teach the checker everything already on the list: it is the device's
        // dictionary, so a reinstall or a new device starts out not knowing them.
        for word in words { Self.learn(word) }
    }

    func contains(_ word: String) -> Bool {
        words.contains(normalized(word))
    }

    /// Returns false when the word was blank or already listed, so a caller can
    /// tell "added" from "nothing to do".
    @discardableResult
    func add(_ word: String) -> Bool {
        let entry = normalized(word)
        guard !entry.isEmpty, !words.contains(entry) else { return false }
        words.append(entry)
        words.sort()
        save()
        Self.learn(entry)
        return true
    }

    func remove(_ word: String) {
        let entry = normalized(word)
        guard let index = words.firstIndex(of: entry) else { return }
        words.remove(at: index)
        save()
        Self.unlearn(entry)
    }

    func remove(atOffsets offsets: IndexSet) {
        for word in offsets.map({ words[$0] }) { remove(word) }
    }

    /// Uppercased and stripped of anything that is not part of a word, so
    /// "Maya," and "maya" are the same entry rather than three.
    private func normalized(_ word: String) -> String {
        word.trimmingCharacters(in: CharacterSet.alphanumerics.inverted).uppercased()
    }

    // MARK: - Storage

    private func save() {
        let object = Dictionary(uniqueKeysWithValues: words.map { ($0, true) })
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let json = String(data: data, encoding: .utf8) else { return }
        defaults.set(json, forKey: Self.key)
    }

    /// The web's shape: `{"MAYA": true}`, where a false value means the word was
    /// taken off the list rather than never on it.
    static func decode(_ json: String?) -> [String] {
        guard let data = json?.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        return object
            .filter { ($0.value as? Bool) == true }
            .keys
            .map { $0.uppercased() }
            .sorted()
    }

    // MARK: - The system checker

    private static func learn(_ word: String) {
        #if canImport(UIKit)
        guard !UITextChecker.hasLearnedWord(word) else { return }
        UITextChecker.learnWord(word)
        #endif
    }

    private static func unlearn(_ word: String) {
        #if canImport(UIKit)
        guard UITextChecker.hasLearnedWord(word) else { return }
        UITextChecker.unlearnWord(word)
        #endif
    }
}
