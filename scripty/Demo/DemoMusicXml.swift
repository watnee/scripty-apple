//
//  DemoMusicXml.swift
//  scripty
//
//  Scores, for the offline demo only.
//
//  Against a real server the client never reads or writes MusicXML — it hands
//  the file up and takes the score back down, and the parsing is the server's
//  job. The demo has no server to defer to, so it does the small part of that
//  work itself: enough to export a song as a real score and read one back, so
//  the round trip a writer would make through MuseScore is something they can
//  try before they have an account.
//
//  Deliberately smaller than the server's converter. It reads the two things
//  the server writes — words and line breaks — and nothing else.
//

import Foundation

/// `nonisolated`: string assembly and an XML read, called from the `DemoBackend`
/// actor without a hop. As with `DocumentPDF`, this describes what already
/// happens rather than moving the work.
nonisolated enum DemoMusicXml {

    static let contentType = "application/vnd.recordare.musicxml+xml"

    // MARK: - Writing

    /// One song per section, each on its own page, matching the server's
    /// songbook. A single song passes a nil title and lets the score's own
    /// title stand for it.
    struct Section {
        let title: String?
        let lyrics: String
    }

    static func score(title: String, sections: [Section]) -> Data {
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE score-partwise PUBLIC "-//Recordare//DTD MusicXML 4.0 Partwise//EN" \
        "http://www.musicxml.org/dtds/partwise.dtd">
        <score-partwise version="4.0">
          <work>
            <work-title>\(escape(title))</work-title>
          </work>
          <part-list>
            <score-part id="P1">
              <part-name>Voice</part-name>
            </score-part>
          </part-list>
          <part id="P1">

        """
        var measure = 0
        for (index, section) in sections.enumerated() {
            for (position, line) in lines(of: section.lyrics).enumerated() {
                measure += 1
                let opens = position == 0
                xml += self.measure(number: measure, line: line,
                                    heading: opens ? section.title : nil,
                                    newPage: opens && index > 0)
            }
        }
        if measure == 0 {
            xml += "    <measure number=\"1\">\n      <note><rest/><duration>4</duration>"
                + "<type>whole</type></note>\n    </measure>\n"
        }
        xml += "  </part>\n</score-partwise>\n"
        return Data(xml.utf8)
    }

    /// One line of the lyric.
    ///
    /// A blank line is not a line of its own but the end of a verse, which is
    /// how MusicXML sees it too — hence the flag on the line before rather than
    /// an empty entry here.
    struct Line {
        let words: String
        var endsStanza: Bool
    }

    private static func lines(of lyrics: String) -> [Line] {
        var lines: [Line] = []
        for raw in lyrics.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                if !lines.isEmpty { lines[lines.count - 1].endsStanza = true }
                continue
            }
            lines.append(Line(words: line, endsStanza: false))
        }
        return lines
    }

    /// One line of the lyric, a word to a quarter note, ending in the marker
    /// that tells a reader where the writer's line — or verse — stopped.
    private static func measure(number: Int, line: Line,
                                heading: String?, newPage: Bool) -> String {
        var xml = "    <measure number=\"\(number)\">\n"
        if newPage {
            xml += "      <print new-page=\"yes\"/>\n"
        }
        if let heading, !heading.isEmpty {
            xml += "      <direction placement=\"above\">\n        <direction-type>\n"
                + "          <words>\(escape(heading))</words>\n"
                + "        </direction-type>\n      </direction>\n"
        }
        let words = line.words.split(separator: " ").map(String.init)
        for (index, word) in words.enumerated() {
            xml += "      <note>\n"
                + "        <pitch><step>C</step><octave>5</octave></pitch>\n"
                + "        <duration>1</duration>\n"
                + "        <type>quarter</type>\n"
                + "        <lyric number=\"1\">\n"
                + "          <syllabic>single</syllabic>\n"
                + "          <text>\(escape(word))</text>\n"
            if index == words.count - 1 {
                xml += line.endsStanza ? "          <end-paragraph/>\n" : "          <end-line/>\n"
            }
            xml += "        </lyric>\n      </note>\n"
        }
        return xml + "    </measure>\n"
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: - Reading

    /// What a score has to say, or nil if it is not one.
    struct Reading {
        let title: String?
        let lyrics: String
    }

    /// Reads the words back out, breaking lines where the score says to.
    ///
    /// A score that never says — which a real notation program's output often
    /// does not — comes back as one long line here. The server's converter
    /// falls back to measures and system breaks for those; the demo does not,
    /// because the only scores it ever sees are ones it or the server wrote,
    /// and both mark their line and verse ends.
    static func read(_ data: Data) -> Reading? {
        let parser = LyricParser()
        let xml = XMLParser(data: data)
        xml.delegate = parser
        guard xml.parse(), parser.isScore else { return nil }
        return Reading(title: parser.title, lyrics: parser.lyrics)
    }

    private final class LyricParser: NSObject, XMLParserDelegate {
        private(set) var isScore = false
        private(set) var title: String?

        private var lines: [String] = []
        private var words: [String] = []
        private var word = ""
        private var continues = false

        private var text = ""
        private var inLyric = false
        private var inWorkTitle = false

        var lyrics: String {
            var all = lines
            let trailing = finishedLine()
            if !trailing.isEmpty {
                all.append(trailing)
            }
            // A verse break at the very end has nothing to separate.
            while all.last?.isEmpty == true {
                all.removeLast()
            }
            return all.joined(separator: "\n")
        }

        private func finishedLine() -> String {
            endWord()
            let line = words.joined(separator: " ")
            words = []
            return line
        }

        private func endWord() {
            guard !word.isEmpty else { return }
            words.append(word)
            word = ""
        }

        private func endLine() {
            let line = finishedLine()
            if !line.isEmpty {
                lines.append(line)
            }
        }

        func parser(_ parser: XMLParser, didStartElement name: String,
                    namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String]) {
            text = ""
            switch name {
            case "score-partwise", "score-timewise": isScore = true
            case "work-title": inWorkTitle = true
            case "lyric": inLyric = true
            case "end-line":
                guard inLyric else { break }
                endLine()
            case "end-paragraph":
                guard inLyric else { break }
                endLine()
                // The blank line the writer typed between two verses.
                lines.append("")
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, didEndElement name: String,
                    namespaceURI: String?, qualifiedName: String?) {
            switch name {
            case "work-title":
                if inWorkTitle, title == nil {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    title = trimmed.isEmpty ? nil : trimmed
                }
                inWorkTitle = false
            case "syllabic":
                let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
                continues = value == "begin" || value == "middle"
            case "text":
                guard inLyric else { break }
                word += text
                if !continues { endWord() }
                continues = false
            case "lyric":
                endWord()
                inLyric = false
            default: break
            }
            text = ""
        }
    }
}
