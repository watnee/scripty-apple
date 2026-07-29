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
//  That divergence is also why a second, private list sits beside the web's:
//  the shared one is uppercased, and the checker takes case at face value.
//  Learning only "MAYA" leaves "Maya" — the spelling that was actually
//  underlined — flagged, so both are taught, and the spellings taught are
//  remembered so removal can take out exactly what was put in.
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

    /// Bumped whenever the list changes.
    ///
    /// The editors watch this rather than the list itself: a word already
    /// checked keeps its underline until something asks the checker to look
    /// again, so without a signal to redraw on, ignoring a word reads as having
    /// done nothing at all. See `SpellcheckingTextView.applySpellchecking`.
    private(set) var revision = 0

    /// The spellings actually taught to the device, as they were typed. Ours
    /// alone — the web has no equivalent, because it never touches a device
    /// dictionary — and needed because "McDonald" cannot be recovered from
    /// "MCDONALD" by any amount of recasing.
    private var learned: [String] = []

    private let defaults: UserDefaults
    private static let key = "scripty-spell-ignored"
    private static let learnedKey = "scripty-spell-learned"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        words = Self.decode(defaults.string(forKey: Self.key))
        learned = defaults.stringArray(forKey: Self.learnedKey) ?? words
        // Teach the checker everything already on the list: it is the device's
        // dictionary, so a reinstall or a new device starts out not knowing them.
        for word in learned { Self.learn(word) }
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
        // The uppercase entry for the web's sake, the word as written for the
        // checker's: it is the written spelling that was underlined.
        for spelling in [entry, trimmed(word)] where !learned.contains(spelling) {
            learned.append(spelling)
            Self.learn(spelling)
        }
        save()
        revision += 1
        return true
    }

    func remove(_ word: String) {
        let entry = normalized(word)
        guard let index = words.firstIndex(of: entry) else { return }
        words.remove(at: index)
        for spelling in learned where spelling.uppercased() == entry {
            Self.unlearn(spelling)
        }
        learned.removeAll { $0.uppercased() == entry }
        save()
        revision += 1
    }

    /// Stripped of anything that is not part of a word, so "Maya," and "Maya"
    /// are one entry, but left in the case it was written in.
    private func trimmed(_ word: String) -> String {
        word.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    }

    /// Uppercased on top of that, so "Maya," and "maya" are the same entry
    /// rather than three.
    private func normalized(_ word: String) -> String {
        trimmed(word).uppercased()
    }

    // MARK: - Storage

    private func save() {
        defaults.set(learned, forKey: Self.learnedKey)
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
