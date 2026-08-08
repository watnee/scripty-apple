//
//  NarrationVoices.swift
//  scripty
//
//  Which of the device's voices are worth reading a script in.
//
//  A device answers "what voices do you have?" with everything it has ever
//  shipped, and the list is not a menu — it is an inventory. On an English
//  device it holds a dozen joke voices from the nineties (Bells, Bubbles,
//  Zarvox), and it holds the *same* voice more than once when a better-sounding
//  download of it exists: "Samantha" the small built-in one and "Samantha" the
//  enhanced one are two entries with one name. Offered raw, the picker is a
//  wall of near-duplicates with a robot choir in the middle of it, and — worse
//  — handing voices out to a cast walks straight down it, so a table read of a
//  drama is performed by Bad News and Trinoids.
//
//  So this is the sorting: what to offer, in what order, and which one to read
//  in when the writer has not chosen. It is deliberately free of AVFoundation —
//  a `NarrationVoice` is what the narrator makes of an `AVSpeechSynthesisVoice`
//  — because these rules are the part worth checking, and no test can install a
//  voice.
//

import Foundation

/// How good a voice sounds, which is the one thing about it that is ranked.
///
/// The names are the system's own: the small voice every device carries, the
/// download that sounds like a person, and the neural one that sounds like a
/// person in a room. A voice the writer recorded of themselves outranks all
/// three, because nobody makes one of those and then wants something else.
enum NarrationVoiceGrade: Int, Comparable, Sendable {
    case compact = 0
    case enhanced = 1
    case premium = 2
    case personal = 3

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// What the picker says after the voice's name. The small one says nothing:
    /// it is the ordinary case, and "Samantha (Compact)" would read as a
    /// warning rather than a default.
    var label: String? {
        switch self {
        case .compact: return nil
        case .enhanced: return "Enhanced"
        case .premium: return "Premium"
        case .personal: return "Personal"
        }
    }
}

/// One voice the device could read in.
struct NarrationVoice: Identifiable, Equatable, Sendable {
    let identifier: String
    let name: String
    /// BCP-47, as the system gives it: "en-GB", "fr-CA".
    let language: String
    let grade: NarrationVoiceGrade
    /// The joke voices. They are real voices with real identifiers and the
    /// system lists them beside the others; what marks them is a trait.
    let isNovelty: Bool

    var id: String { identifier }

    /// The picker's row. The grade is worth showing — two rows reading
    /// "Samantha" with no way to tell which is the good one is the state this
    /// whole file exists to avoid.
    var label: String {
        guard let grade = grade.label else { return name }
        return "\(name) (\(grade))"
    }

    init(identifier: String,
         name: String,
         language: String,
         grade: NarrationVoiceGrade,
         isNovelty: Bool = false) {
        self.identifier = identifier
        self.name = name
        self.language = language
        self.grade = grade
        self.isNovelty = isNovelty
    }
}

enum NarrationVoices {

    /// The voices worth offering, best first.
    ///
    /// Four passes, each of which can be undone by the next being empty —
    /// a picker with nothing in it looks broken, and every one of these rules
    /// is a preference rather than a requirement:
    ///
    ///   1. The device's own language, by family, so an English device is not
    ///      offered forty voices that cannot pronounce the script.
    ///   2. No novelty voices.
    ///   3. One row per name, keeping the best-sounding download of it.
    ///   4. Best grade first, then alphabetical.
    ///
    /// `keeping` is the voice the writer has already chosen: it survives the
    /// deduplication whatever else outranks it, because a picker whose current
    /// selection is not in its own list shows no selection at all.
    static func offered(from all: [NarrationVoice],
                        language: String,
                        keeping chosen: String? = nil) -> [NarrationVoice] {
        let wanted = family(of: language)
        let spoken = all.filter { family(of: $0.language) == wanted }
        var voices = spoken.isEmpty ? all : spoken

        let serious = voices.filter { !$0.isNovelty }
        if !serious.isEmpty { voices = serious }

        // Looked up in everything installed rather than in what survived the
        // filtering: a voice chosen while the device spoke another language is
        // still the voice this reading is in, and a picker that cannot show its
        // own selection shows none.
        let kept = all.filter { $0.identifier == chosen }

        var best: [String: NarrationVoice] = [:]
        for voice in voices where voice.identifier != chosen {
            // Keyed by name *and* language: "Daniel" is a British voice and
            // "Karen" an Australian one, and on a device carrying both they are
            // two different voices that happen to share an alphabet.
            let key = "\(voice.name)\u{1F}\(family(of: voice.language))"
            if let existing = best[key], existing.grade >= voice.grade { continue }
            best[key] = voice
        }
        // The chosen voice keeps its row; the deduplicated one for the same
        // name goes, or the picker shows the name twice.
        let chosenNames = Set(kept.map { "\($0.name)\u{1F}\(family(of: $0.language))" })
        let rest = best.filter { !chosenNames.contains($0.key) }.values

        return (kept + rest).sorted {
            if $0.grade != $1.grade { return $0.grade > $1.grade }
            if $0.name != $1.name { return $0.name < $1.name }
            return $0.identifier < $1.identifier
        }
    }

    /// The voice to read in when the writer has not picked one.
    ///
    /// The system hands out a default per language, and on most devices it is
    /// the small built-in voice even when the writer has downloaded a better
    /// one — the download is something they went and fetched, so it is the
    /// thing to read a script in. Upgrading in place comes first: a writer who
    /// hears Samantha every day should keep hearing Samantha, only better.
    /// Only when the system's own voice has no better edition does the choice
    /// move to another voice, and only to one that actually sounds better.
    static func best(from offered: [NarrationVoice],
                     systemDefault: NarrationVoice?) -> NarrationVoice? {
        guard let systemDefault else { return offered.first }
        let sameName = offered
            .filter { $0.name == systemDefault.name
                      && family(of: $0.language) == family(of: systemDefault.language) }
            .max { $0.grade < $1.grade }
        if let sameName, sameName.grade > systemDefault.grade { return sameName }
        if let better = offered.first, better.grade > systemDefault.grade { return better }
        return systemDefault
    }

    /// The voices to hand a cast, in the order they are handed out: the
    /// best-sounding ones first, and never the narrator's own — the page and
    /// the people in it sounding identical is the thing distinct voices are for.
    ///
    /// The joke voices are already gone, which matters more here than in the
    /// picker: nobody picks Trinoids, but a cast walking down an unsorted list
    /// is handed it without being asked.
    static func cast(from offered: [NarrationVoice],
                     narrator: String?) -> [NarrationVoice] {
        offered.filter { $0.identifier != narrator }
    }

    /// Which voice the nth character gets, and at what pitch.
    ///
    /// There are almost always more characters than voices — a device with
    /// three usable voices and a scene with eight people in it is the ordinary
    /// case — so the list wraps. Wrapping alone means the fourth character and
    /// the first are the *same voice at the same pitch*, which is not a cast
    /// with a shortage in it; it is two characters a listener cannot tell
    /// apart, and in a two-hander between them it is unfollowable.
    ///
    /// So each time round the list the pitch shifts, alternately up and down
    /// and further each time: same voice, recognisably not the same person.
    /// The first time round is left at its natural pitch, because that is the
    /// voice as it was chosen and most casts never wrap at all.
    ///
    /// The range stays well inside what the synthesizer accepts (0.5…2.0) —
    /// pushed to the ends a voice stops sounding like a person.
    static func part(at offset: Int, poolSize: Int) -> (index: Int, pitch: Double) {
        guard poolSize > 0 else { return (0, 1) }
        let index = offset % poolSize
        let round = offset / poolSize
        guard round > 0 else { return (index, 1) }

        // 1, 2, 2, 3, 3 … — how far from natural, with the odd rounds up and
        // the even rounds down.
        let distance = Double((round + 1) / 2)
        let up = round.isMultiple(of: 2) == false
        let pitch = up ? 1 + 0.15 * distance : 1 - 0.12 * distance
        return (index, min(1.6, max(0.6, pitch)))
    }

    /// Whether the device has anything better than the small built-in voices.
    /// When it does not, the reading is as good as it can be made from here and
    /// the menu says where the better ones live.
    static func hasDownloadedVoice(_ offered: [NarrationVoice]) -> Bool {
        offered.contains { $0.grade > .compact }
    }

    /// "en-GB" and "en-US" are the same language for the purpose of "can this
    /// voice read what I wrote".
    private static func family(of language: String) -> String {
        language.split(separator: "-").first.map(String.init)?.lowercased()
            ?? language.lowercased()
    }
}
