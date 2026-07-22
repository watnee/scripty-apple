//
//  HelpTopic.swift
//  scripty
//
//  The help centre's content, as data rather than as a view.
//
//  The web app's help page is twenty-one cards of HTML with a `data-keywords`
//  attribute on each, searched in the browser. Keeping the same shape here —
//  content in one place, matching as a method on it — means the search can be
//  reasoned about without a running view, and that a topic is added by adding
//  a value rather than by editing a layout.
//
//  What it says is deliberately not a translation of the web's copy. Anything
//  the browser does and this client does not (offline editing, installing to a
//  home screen, Safari Reader) is left out entirely: a help centre that
//  describes features the reader cannot find is worse than a shorter one.
//

import Foundation

/// One help card: a heading, a few short paragraphs, and the extra words a
/// writer might search for that the prose itself never uses.
struct HelpTopic: Identifiable, Equatable {
    let id: String
    let title: String
    let systemImage: String
    let paragraphs: [String]
    /// Synonyms only. The title and the prose are searched already, so
    /// repeating a word here buys nothing.
    let keywords: [String]

    /// Whether this topic answers the query.
    ///
    /// Every whitespace-separated word has to match something, so a second word
    /// narrows rather than widens — which is what typing more words means to
    /// everyone who has ever used a search box.
    func matches(_ query: String) -> Bool {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return true }
        return words.allSatisfy { word in haystack.contains(word) }
    }

    private var haystack: String {
        ([title] + paragraphs + keywords).joined(separator: " ").lowercased()
    }
}

/// A run of topics under one heading, in the order they should be read.
struct HelpSection: Identifiable, Equatable {
    let id: String
    let title: String
    let topics: [HelpTopic]
}

extension HelpTopic {
    /// The sections that still have a topic in them once the query is applied.
    ///
    /// Empty sections are dropped rather than shown empty: a heading with
    /// nothing under it reads as a result, and it is not one.
    static func sections(matching query: String) -> [HelpSection] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return sections }
        return sections.compactMap { section in
            let hits = section.topics.filter { $0.matches(trimmed) }
            return hits.isEmpty
                ? nil
                : HelpSection(id: section.id, title: section.title, topics: hits)
        }
    }

    static let sections: [HelpSection] = [
        HelpSection(id: "start", title: "Getting Started", topics: [
            HelpTopic(
                id: "welcome",
                title: "Welcome to Scripty",
                systemImage: "film",
                paragraphs: [
                    "Scripty holds a screenplay as a sequence of typed elements — scene "
                    + "headings, action, character cues, dialogue and the rest — rather "
                    + "than as pages of text. Everything else follows from that: an "
                    + "element can be retyped, moved, commented on or restored on its own.",
                    "This app is the same screenplay as the web editor, on the same "
                    + "account. What you can do to a script is whatever the server says "
                    + "you can do to it, so a reader sees no editing controls at all "
                    + "rather than controls that fail."
                ],
                keywords: ["introduction", "overview", "start", "beginning", "what is"]),
            HelpTopic(
                id: "projects",
                title: "Your Projects",
                systemImage: "list.bullet.rectangle",
                paragraphs: [
                    "The sidebar lists every screenplay you can open. Search it by "
                    + "title, sort by last edited or by name, and swipe a row to rename "
                    + "or delete it.",
                    "The star marks a default project. Tap it on the row you keep "
                    + "coming back to."
                ],
                keywords: ["sidebar", "list", "screenplays", "sort", "rename", "default",
                           "star", "swipe"]),
            HelpTopic(
                id: "project-transfer",
                title: "Importing and Exporting a Project",
                systemImage: "shippingbox",
                paragraphs: [
                    "Import Project takes a .scripty.json file and brings it in as a new "
                    + "screenplay, so importing never writes over anything you already "
                    + "have. Export All Projects sends the whole list back out in the "
                    + "same format.",
                    "The archive carries the project whole — elements, characters, "
                    + "songs, notes and version history — which makes it both a backup "
                    + "and the way to move a screenplay to another account."
                ],
                keywords: ["backup", "archive", "json", "transfer", "move", "download",
                           "upload", "restore"]),
            HelpTopic(
                id: "project-trash",
                title: "Deleted a Project by Mistake?",
                systemImage: "trash",
                paragraphs: [
                    "Deleting a screenplay moves it to Recently Deleted rather than "
                    + "erasing it, and it comes back with its scenes, characters, "
                    + "versions, songs and notes intact.",
                    "Open Recently Deleted from the sidebar menu — it is offered once "
                    + "there is something in it — and swipe a row to restore it. If the "
                    + "entry is missing, your account is not the one allowed to restore; "
                    + "ask an administrator."
                ],
                keywords: ["recover", "recovery", "undelete", "lost", "missing", "gone",
                           "accident", "bin"]),
            HelpTopic(
                id: "demo",
                title: "Demo Mode",
                systemImage: "sparkles",
                paragraphs: [
                    "Try Demo on the sign-in screen opens a sample screenplay with no "
                    + "server behind it. Everything works, nothing is sent anywhere, and "
                    + "every edit is discarded when you quit."
                ],
                keywords: ["sample", "try", "offline", "test", "example"])
        ]),
        HelpSection(id: "writing", title: "Writing", topics: [
            HelpTopic(
                id: "elements",
                title: "Elements and Their Types",
                systemImage: "square.stack.3d.up",
                paragraphs: [
                    "There are fifteen element types: Scene, Action, Text, Character, "
                    + "Dialogue, Dual Dialogue, Parenthetical, Transition, Shot, Lyrics, "
                    + "Centered, Section, Synopsis, Note and Page Break. A scene heading "
                    + "groups everything typed under it.",
                    "Change the type from the element bar under the script, from the "
                    + "Format menu, or by pressing Tab to walk the classic cycle: Scene, "
                    + "Action, Character, Parenthetical, Dialogue, Transition, Shot. "
                    + "Shift-Tab walks it backwards."
                ],
                keywords: ["scene", "action", "character", "dialogue", "parenthetical",
                           "transition", "shot", "lyrics", "section", "synopsis",
                           "page break", "retype", "tab"]),
            HelpTopic(
                id: "typing",
                title: "Typing Straight Through",
                systemImage: "text.cursor",
                paragraphs: [
                    "Tap an element and type. Return splits it and starts the next one "
                    + "— a character cue is followed by dialogue, everything else by "
                    + "action. Backspace with the caret at the very start merges the "
                    + "element back into the one above.",
                    "Edits save themselves as you pause, so there is no save button to "
                    + "look for."
                ],
                keywords: ["return", "enter", "backspace", "split", "merge", "auto-save",
                           "autosave", "editing"]),
            HelpTopic(
                id: "fountain",
                title: "Fountain as You Type",
                systemImage: "wand.and.stars",
                paragraphs: [
                    "Type a Fountain force marker and the element retypes itself: "
                    + ".INT. HOUSE for a scene heading, @JANE for a character cue, "
                    + ">CUT TO: for a transition, ~lyrics, [[a note]], # for a section "
                    + "and = for a synopsis.",
                    "Plain screenplay shorthand works too — a line beginning INT. or "
                    + "EXT. is read as a scene heading without the leading dot."
                ],
                keywords: ["syntax", "markers", "detect", "shorthand", "int", "ext",
                           "automatic"]),
            HelpTopic(
                id: "autocomplete",
                title: "Character and Scene Suggestions",
                systemImage: "text.badge.checkmark",
                paragraphs: [
                    "While you type a character cue, the cast already in the script is "
                    + "offered below the line. While you type a scene heading you are "
                    + "offered the INT./EXT. prefixes, locations used earlier, and the "
                    + "times of day after a dash.",
                    "With a keyboard, the arrow keys move through the list, Return or "
                    + "Tab takes the highlighted one, and Escape dismisses it. By touch, "
                    + "tap the one you want."
                ],
                keywords: ["autocomplete", "suggestion", "cast", "location", "time of day",
                           "prediction"]),
            HelpTopic(
                id: "formatting",
                title: "Bold, Italic and Alignment",
                systemImage: "bold.italic.underline",
                paragraphs: [
                    "The format bar above the keyboard sets bold, italic and underline "
                    + "for the element you are in, along with its alignment and "
                    + "typeface. Each chip shows what the element is already set to, so "
                    + "the bar doubles as a readout."
                ],
                keywords: ["bold", "italic", "underline", "align", "centre", "font",
                           "typeface", "style"]),
            HelpTopic(
                id: "clipboard",
                title: "Moving Elements Around",
                systemImage: "arrow.up.arrow.down",
                paragraphs: [
                    "Copy Element, Cut Element and Paste Elements Below work on whole "
                    + "elements and keep their types. They are deliberately not ⌘C and "
                    + "⌘V, which belong to the words inside the element you are typing "
                    + "in.",
                    "To reorder, turn on Select Elements and drag a row onto another, or "
                    + "use Move Up and Move Down from an element's context menu. Pasting "
                    + "Fountain or plain screenplay text from elsewhere splits it into "
                    + "typed elements."
                ],
                keywords: ["copy", "cut", "paste", "reorder", "drag", "move", "clipboard",
                           "rearrange"]),
            HelpTopic(
                id: "selection",
                title: "Working on Several Elements at Once",
                systemImage: "checklist",
                paragraphs: [
                    "Select Elements turns the script read-only and puts a checkmark on "
                    + "every row. Tick the ones you want and the action bar offers what "
                    + "the server allows for the set — tagging, retyping and deleting.",
                    "Each bulk action is one request and one undo step, so a change of "
                    + "mind costs one Undo rather than twenty."
                ],
                keywords: ["bulk", "multiple", "checkbox", "select all", "tags", "batch"]),
            HelpTopic(
                id: "spelling",
                title: "Spelling",
                systemImage: "textformat.abc.dottedunderline",
                paragraphs: [
                    "Check Spelling in the View menu underlines misspelled words as you "
                    + "type, using the system checker and the system's own corrections.",
                    "Ignored Words is the list of words to stop flagging. Because the "
                    + "checker is the device's, a word added there stops being flagged "
                    + "in other apps too."
                ],
                keywords: ["spellcheck", "spell check", "dictionary", "misspelled",
                           "typo", "ignore"]),
            HelpTopic(
                id: "preferences",
                title: "Editor Preferences",
                systemImage: "textformat",
                paragraphs: [
                    "Editor Preferences in the sidebar menu decides which elements are "
                    + "typed in capitals — scene headings, character cues and "
                    + "transitions, each on its own. The choice is stored on your "
                    + "account, so it follows you to the web editor and back."
                ],
                keywords: ["capitalisation", "capitalization", "caps", "uppercase",
                           "settings", "automatic"])
        ]),
        HelpSection(id: "reading", title: "Reading and Layout", topics: [
            HelpTopic(
                id: "page-view",
                title: "Page View",
                systemImage: "doc.richtext",
                paragraphs: [
                    "Page View lays the screenplay out on paper with page numbers, and "
                    + "you can still type into it. Breaks follow screenplay convention: "
                    + "a cue, parenthetical or scene heading is never stranded at the "
                    + "foot of a page, and a speech split across pages closes with "
                    + "(MORE) and resumes under CHARACTER (CONT'D).",
                    "Page Setup chooses the paper size, the margins and where the page "
                    + "numbers sit. The same choice is used for the PDF export and for "
                    + "printing, so what you see is what comes out."
                ],
                keywords: ["pages", "paper", "pagination", "letter", "a4", "margins",
                           "print", "more", "cont'd"]),
            HelpTopic(
                id: "focus",
                title: "Focus Mode and Full Width",
                systemImage: "moon",
                paragraphs: [
                    "Focus Mode strips the screen back to the script alone, leaving only "
                    + "the View menu as the way out. Full Page Width lets the writing "
                    + "column use the whole window instead of the printed measure; it is "
                    + "offered only outside page view, where paper has a width of its "
                    + "own."
                ],
                keywords: ["distraction", "zen", "width", "column", "measure",
                           "concentrate"]),
            HelpTopic(
                id: "read-script",
                title: "Read Script",
                systemImage: "book",
                paragraphs: [
                    "Read Script sets the screenplay as prose in a serif face, with the "
                    + "editing controls and the working annotations — synopses and notes "
                    + "— left out. It is for reading on a screen; page view is the one "
                    + "for reading it as paper."
                ],
                keywords: ["reader", "reading", "prose", "review", "distraction free"]),
            HelpTopic(
                id: "outline",
                title: "Outline and Outline Mode",
                systemImage: "list.bullet.indent",
                paragraphs: [
                    "Outline opens a panel of the scenes, sections, synopses and "
                    + "bookmarks in script order; tapping one jumps to it.",
                    "Outline Mode is the other half of the idea: it filters the script "
                    + "itself down to scene headings, sections and synopses, so you can "
                    + "restructure a draft without the dialogue in the way."
                ],
                keywords: ["navigator", "structure", "beats", "scenes", "jump",
                           "navigate", "index"]),
            HelpTopic(
                id: "marks",
                title: "Bookmarks, Pins and Labels",
                systemImage: "bookmark",
                paragraphs: [
                    "Bookmark an element to find it again from the outline; pin one to "
                    + "keep it in reach. The Show section of the View menu turns pins, "
                    + "bookmarks, element labels and inline notes on and off — each "
                    + "setting belongs to this screenplay, so marking up one draft "
                    + "leaves the others alone."
                ],
                keywords: ["star", "pin", "flag", "highlight", "labels", "markers",
                           "favourite"]),
            HelpTopic(
                id: "text-size",
                title: "Text Size and Appearance",
                systemImage: "textformat.size",
                paragraphs: [
                    "Bigger, Smaller and Actual Size scale the script for your eyes and "
                    + "your screen. Appearance in the sidebar menu picks light, dark, or "
                    + "whatever the device is doing.",
                    "Both are settings for this device rather than for the account: the "
                    + "same screenplay is read on a bright rehearsal-room iPad and in a "
                    + "dark editing suite."
                ],
                keywords: ["zoom", "font size", "larger", "smaller", "dark mode",
                           "light", "theme", "readability"]),
            HelpTopic(
                id: "stats",
                title: "Script Stats and Word Count",
                systemImage: "chart.bar",
                paragraphs: [
                    "Script Stats counts the scenes, elements and words, splits the "
                    + "dialogue against the action, and breaks both down by character "
                    + "and by location.",
                    "Word Count in the View menu puts a running count on the script "
                    + "itself, for when the question is how long today's pages are "
                    + "rather than how the whole draft balances."
                ],
                keywords: ["statistics", "length", "words", "count", "pages",
                           "breakdown", "characters", "locations"])
        ]),
        HelpSection(id: "documents", title: "Documents", topics: [
            HelpTopic(
                id: "songs-notes",
                title: "Songs and Notes",
                systemImage: "music.note.list",
                paragraphs: [
                    "Songs and Notes are written outside the screenplay and inserted "
                    + "when they are ready — a song as Lyrics elements, a note as Note "
                    + "elements, one line each. Saving a song updates every place it was "
                    + "already inserted.",
                    "The notes editor carries lists down a line at a time on Return, "
                    + "nests them on Tab, and sets headings; the prefixes stay plain "
                    + "text, so what reaches the script is what you typed. Songs can be "
                    + "opened one at a time, or all together on the workspace screen for "
                    + "a change that runs through several of them."
                ],
                keywords: ["lyrics", "drafts", "scratch", "documents", "insert",
                           "workspace", "list", "bullets", "heading"]),
            HelpTopic(
                id: "title-page",
                title: "Title Page",
                systemImage: "doc.text",
                paragraphs: [
                    "The title page holds the front matter — title, writers, contact "
                    + "details, draft version — with a live preview of the sheet beside "
                    + "the form. It travels with every export that has a front page."
                ],
                keywords: ["front matter", "credits", "author", "byline", "contact",
                           "draft"]),
            HelpTopic(
                id: "import-export",
                title: "Importing and Exporting a Screenplay",
                systemImage: "square.and.arrow.up",
                paragraphs: [
                    "Import accepts Fountain, plain text, Word, Final Draft and PDF. "
                    + "Files exported by Scripty round-trip their element types; anything "
                    + "else is read with Fountain heuristics. Scanned or image-only PDFs "
                    + "are not supported, and import replaces the whole script — which "
                    + "is why it asks first.",
                    "Export offers whichever formats the server advertises: PDF, "
                    + "Fountain, Word, Final Draft, EPUB and the Scripty archive. "
                    + "Printing goes through the PDF, so the paper and the file are the "
                    + "same document."
                ],
                keywords: ["fountain", "fdx", "docx", "pdf", "epub", "final draft",
                           "word", "print", "download", "convert"]),
            HelpTopic(
                id: "element-trash",
                title: "Deleted Elements",
                systemImage: "arrow.uturn.backward",
                paragraphs: [
                    "A deleted element goes to the screenplay's own trash. Open Deleted "
                    + "Elements from the toolbar, swipe to restore it to where it was, "
                    + "or swipe the other way to destroy it for good — that one asks "
                    + "first, because Undo cannot reach it."
                ],
                keywords: ["restore", "recover", "undelete", "bin", "removed", "block"])
        ]),
        HelpSection(id: "collaboration", title: "Collaboration", topics: [
            HelpTopic(
                id: "characters",
                title: "Characters and Casting",
                systemImage: "person.2",
                paragraphs: [
                    "Characters lists the cues in the screenplay along with the people "
                    + "behind them. Open one to see the actor assigned, their details, "
                    + "and everything they say.",
                    "The cast list is the counterpart of the web app's Casting screen: a "
                    + "directory of real actors, each of whom can be attached to a "
                    + "character."
                ],
                keywords: ["cast", "actors", "roles", "people", "assign", "profile"]),
            HelpTopic(
                id: "comments",
                title: "Comments",
                systemImage: "bubble.left.and.bubble.right",
                paragraphs: [
                    "Any element can carry a thread, shown with the element itself at "
                    + "the top so the note has something to be about. Commenting needs "
                    + "only read access — it is how a director or a producer contributes "
                    + "to a screenplay they may not edit."
                ],
                keywords: ["notes", "thread", "feedback", "discussion", "reply",
                           "review"]),
            HelpTopic(
                id: "sharing",
                title: "Sharing and Teams",
                systemImage: "person.badge.plus",
                paragraphs: [
                    "Share answers two questions at once: who can already see this "
                    + "screenplay, and who you would like to invite. Access follows from "
                    + "a role or a team as much as from an invitation, so the list can "
                    + "hold people no invitation ever named.",
                    "Teams, in the sidebar menu, is the other route: assign a project to "
                    + "a team and its members can open it. Only a writer can change the "
                    + "script."
                ],
                keywords: ["invite", "collaborate", "access", "permissions", "readers",
                           "collaborators", "roles", "group"]),
            HelpTopic(
                id: "versions",
                title: "Versions, Editions and History",
                systemImage: "clock.arrow.circlepath",
                paragraphs: [
                    "Version History lists the saved snapshots newest first, with the "
                    + "ones you named kept apart from the automatic saves — a history "
                    + "where four deliberate marks are buried in a hundred autosaves is "
                    + "not much of a history. Restoring saves the current state first.",
                    "Editions are parallel cuts of the same screenplay rather than "
                    + "points in its past. The default edition is the one that opens "
                    + "when none is named; the published one is what view-only readers "
                    + "see, so a writer can be drafting in one while readers stay on the "
                    + "last cut."
                ],
                keywords: ["snapshot", "revision", "backup", "restore", "draft",
                           "history", "timeline", "published"]),
            HelpTopic(
                id: "activity",
                title: "Recent Activity",
                systemImage: "clock",
                paragraphs: [
                    "Recent Activity is the record of who did what to this screenplay, "
                    + "newest first. It is read-only: a feed a client could post to "
                    + "would be a record of what someone said happened, not of what did."
                ],
                keywords: ["log", "audit", "changes", "who", "when", "feed", "history"])
        ])
    ]
}
