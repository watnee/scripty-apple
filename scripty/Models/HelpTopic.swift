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
//  the browser does and this client does not (installing to a home screen,
//  Safari Reader) is left out entirely: a help centre that
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
                    + "or delete it. A screenplay already open can be renamed where you "
                    + "are: Rename Screenplay sits under its name in the script's "
                    + "toolbar, beside the title page and the rest of its affairs.",
                    "The star marks a default project. Tap it on the row you keep "
                    + "coming back to, and Scripty opens that screenplay for you "
                    + "the next time it starts — the same landing the web editor "
                    + "gives you. With nothing starred you begin here, on the list."
                ],
                keywords: ["sidebar", "list", "screenplays", "sort", "rename", "default",
                           "star", "swipe", "launch", "open", "startup"]),
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
                id: "project-archive",
                title: "Wrapped a Production?",
                systemImage: "archivebox",
                paragraphs: [
                    "Archive it. Archiving takes a screenplay out of the list without "
                    + "deleting it — the show that closed, last year's short, the pitch "
                    + "that went nowhere. Swipe a row for Archive, or hold it for the "
                    + "same entry in its menu.",
                    "Archive in the list's menu opens what is there: swipe to unarchive "
                    + "and the screenplay rejoins the list, script, songs, notes and "
                    + "version history intact. Unlike Recently Deleted nothing in the "
                    + "archive is on a clock and nothing is ever removed on its own, and "
                    + "an archived screenplay still travels in a project export. It has "
                    + "to come back to the list before it can be opened here, which "
                    + "unarchiving does in one swipe. Archiving also clears it as your "
                    + "default project; unarchiving does not set that again.",
                    "Done with it for good? Delete works from the archive too, and does "
                    + "what it does in the list: the screenplay moves to Recently "
                    + "Deleted, still recoverable."
                ],
                keywords: ["archive", "archived", "unarchive", "put aside", "hide",
                           "finished", "wrapped", "done", "old", "shelve", "retire",
                           "clutter", "tidy"]),
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
                           "accident", "bin"])
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
                    "A new screenplay opens with its first element already there and "
                    + "the caret in it, so naming one and typing into it are the same "
                    + "move.",
                    "Tap an element and type. Return splits it and starts the next one "
                    + "— a character cue is followed by dialogue, everything else by "
                    + "action. Backspace with the caret at the very start merges the "
                    + "element back into the one above.",
                    "Edits save themselves as you pause, so there is no save button to "
                    + "look for.",
                    "The cloud beside the title says where those words are: ticked and "
                    + "grey once everything has reached the server, amber while a save "
                    + "is still on its way or the connection is gone, red if the server "
                    + "refused one. Tap it for the rest of the answer — when this script "
                    + "was last in step with the server, and a Sync Now button that "
                    + "sends everything held on this device without waiting for the "
                    + "connection to come back on its own. The same cloud sits in the "
                    + "corner of the song editor and the project list, and does the "
                    + "same thing there."
                ],
                keywords: ["return", "enter", "backspace", "split", "merge", "auto-save",
                           "autosave", "editing", "new", "first element", "empty",
                           "cloud", "sync", "offline", "saved", "badge"]),
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
                    + "offered below the line. On a scene heading you are offered the "
                    + "INT./EXT. prefixes, locations used earlier, and the times of day "
                    + "after a dash.",
                    "Headings are only suggested once you mean one: on an element that "
                    + "is not a scene heading, nothing is offered until you type the "
                    + "leading dot or write a prefix out in full, so a line beginning "
                    + "\"I\" is left as prose.",
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
                    "The format button at the left of the bar above the keyboard "
                    + "unfolds bold, italic and underline for the element you are in, "
                    + "along with its alignment and typeface. Each chip shows what the "
                    + "element is already set to, so the bar doubles as a readout.",
                    "The text size sits at the end of that bar: A− and A+ step it, and "
                    + "the percentage between them puts it back to 100%. Unlike the "
                    + "rest of the bar it belongs to this device rather than to the "
                    + "element, and it moves the whole script."
                ],
                keywords: ["bold", "italic", "underline", "align", "centre", "font",
                           "typeface", "style", "text size"]),
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
                    "Check Spelling underlines misspelled words as you type, using the "
                    + "system checker and the system's own corrections. It is in the "
                    + "View menu for a screenplay, and under Spelling in the toolbar of "
                    + "a song, the all-songs workspace and a note.",
                    "Touch and hold an underlined word and choose Ignore Spelling to "
                    + "leave it alone from then on — a character's name, a place, a "
                    + "dialect spelling in a lyric. The underline goes everywhere the "
                    + "word appears, not just on the line you were on.",
                    "Ignored Words is that list, and the place to add a word before it "
                    + "is flagged or take one back off. Because the checker is the "
                    + "device's, a word added there stops being flagged in other apps "
                    + "too, and removing it takes it back out."
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
                    "Read Script sets the screenplay in screenplay format — the same "
                    + "face and the same indents as the writing column — with the "
                    + "editing controls and the working annotations — synopses and notes "
                    + "— left out. It swaps in on the script screen itself, opening at "
                    + "the place you were writing; choose it again in the View menu to "
                    + "put the writing back. It runs continuously, without page breaks "
                    + "or page numbers: page view is the one for reading it as paper.",
                    "Read Aloud (⌘⇧A) speaks the script from wherever you are, on "
                    + "whichever surface is up. The element being read is highlighted "
                    + "and scrolls itself into view, and the transport at the foot of "
                    + "the screen steps back and forward an element at a time; hold an "
                    + "element for “Read Aloud From Here”.",
                    "The speaker menu sets the speed and the voice, and what gets read: "
                    + "character names, action and headings, and parentheticals can each "
                    + "be left out — dialogue alone is how you run lines. “A Voice Each” "
                    + "hands the speaking parts different voices, as far as the voices "
                    + "installed on the device stretch; add more in the Settings app "
                    + "under Accessibility."
                ],
                keywords: ["reader", "reading", "format", "courier", "indents",
                           "review", "distraction free",
                           "aloud", "speech", "speak", "voice", "listen", "audio",
                           "table read", "run lines", "text to speech"]),
            HelpTopic(
                id: "outline",
                title: "Navigator and Outline Mode",
                systemImage: "list.bullet.indent",
                paragraphs: [
                    "Navigator opens a panel of the scenes, sections, synopses and "
                    + "bookmarks in script order; tapping one jumps to it.",
                    "Outline Mode is the other half of the idea: it filters the script "
                    + "itself down to scene headings, sections and synopses, so you can "
                    + "restructure a draft without the dialogue in the way.",
                    "You can write in it, not just read it. Return starts another "
                    + "element of the same kind — a scene after a scene, a section "
                    + "after a section — and Tab, the element-type bar and Add Element "
                    + "Below stay inside those three, so nothing you type disappears "
                    + "behind the filter. Turn Outline Mode on in an empty script and "
                    + "the first element it gives you is a scene heading."
                ],
                keywords: ["navigator", "structure", "beats", "scenes", "jump",
                           "navigate", "index", "outlining", "beat sheet"]),
            HelpTopic(
                id: "edit-screenplay",
                title: "Getting Back to Writing",
                systemImage: "pencil.line",
                paragraphs: [
                    "Edit Screenplay, at the foot of the View menu's first group, puts "
                    + "the script back the way it is written in: page view, focus mode, "
                    + "outline mode and Read Script all off, and Lock Editing cleared "
                    + "with them. It saves working out which of the modes is the one "
                    + "still on. It is greyed when the plain writing column is already "
                    + "up, and it is offered only where you have editing rights — "
                    + "unlocking here changes what this device shows you, never what "
                    + "the screenplay lets you do."
                ],
                keywords: ["edit", "write", "writing", "back", "exit", "leave", "modes",
                           "unlock", "locked", "read only"]),
            HelpTopic(
                id: "marks",
                title: "Bookmarks, Pins and Labels",
                systemImage: "bookmark",
                paragraphs: [
                    "Bookmark an element to find it again from the outline; pin one to "
                    + "keep it in reach. The Outline panel's Pins and Bookmarks tabs "
                    + "list what you have marked, and each carries a switch for showing "
                    + "those marks beside the script — the list still takes you to a "
                    + "line whose mark is hidden. The Show section of the View menu "
                    + "turns element labels and inline notes on and off. Every one of "
                    + "these settings belongs to this screenplay, so marking up one "
                    + "draft leaves the others alone."
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
                    "The formatting bar behind the Aa button carries the same three, so "
                    + "the size can be changed mid-sentence without dismissing the "
                    + "keyboard: the percentage in the middle is the reset.",
                    "Both are settings for this device rather than for the account: the "
                    + "same screenplay is read on a bright rehearsal-room iPad and in a "
                    + "dark editing suite.",
                    "Songs and notes are set in the screenplay's own typeface and scale "
                    + "with it, so a lyric reads at the size of the scene it belongs to."
                ],
                keywords: ["zoom", "font size", "larger", "smaller", "dark mode",
                           "light", "theme", "readability", "format bar"]),
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
                    + "elements, one line each. Insert into Script lives on the list "
                    + "row's menu and in the editor's own menu, so a song just finished "
                    + "can be sent to the script without stepping back out. Saving a "
                    + "song updates every place it was already inserted.",
                    "Nothing here is saved by hand. A song or a note saves itself "
                    + "as it is written, and a new one is created for you a moment "
                    + "after you start — untitled if you have not named it yet, "
                    + "filed as \u{201C}Untitled Song\u{201D} or \u{201C}Untitled Notes\u{201D} "
                    + "until you do, and simply renamed when you type a title. The "
                    + "cloud in the corner says where your words are, the same one "
                    + "the screenplay wears. Clearing a title you gave it is the one edit that waits "
                    + "for a new one, since that is a name being taken away rather "
                    + "than never given; emptying the borrowed \u{201C}Untitled\u{201D} one on "
                    + "your way to typing a real title is not.",
                    "The notes editor carries lists down a line at a time on Return, "
                    + "nests them on Tab, and sets headings; the prefixes stay plain "
                    + "text, so what reaches the script is what you typed. Either kind "
                    + "can be opened one at a time, or all together on the workspace "
                    + "screen — Edit All on One Page — for a change that runs through "
                    + "several of them.",
                    "Songs and notes are offered the same things. Both export as text, "
                    + "PDF, Word or EPUB, on their own or as one file of the whole list; "
                    + "both can be emailed to a collaborator; and Edit selects several "
                    + "at once to delete, archive, email or export together. The one "
                    + "format that stays with songs is MusicXML, which is a score to "
                    + "open in a notation program, and a page of scene notes is not a "
                    + "thing to set to music.",
                    "Archiving is not deleting. A song or note set aside from its "
                    + "menu leaves the list whole and readable, with nothing counting "
                    + "down against it; Archived Songs & Notes lists what is on the "
                    + "shelf and Put Back returns it. Delete still sends things to the "
                    + "trash, which is where a countdown does apply, and an archived "
                    + "document can be deleted from the shelf without coming back "
                    + "first.",
                    "A song being worked on is rarely far away. The script has a Songs "
                    + "button and a Notes button, each opening its own list; holding "
                    + "one opens the last few of that kind you edited, each going "
                    + "straight to its lyrics or its text. The lists repeat those same "
                    + "few at the top, so a long one needs no scrolling to reach them. "
                    + "Starting one is the button under the list — New Song over the "
                    + "songs, New Note over the notes. An element's own menu inserts a "
                    + "song below it. Swipe a row to rename or delete it; touch and "
                    + "hold for everything else.",
                    "A lyric line or a note edited without a connection is kept on "
                    + "this device — the corner cloud in the song editor and on the "
                    + "workspace screen, and the note editor's status line, all say "
                    + "so; the cloud turns orange while anything is waiting, and opens "
                    + "on a tap with a Sync Now button — and is saved by itself when "
                    + "the connection returns, even across a relaunch, without your "
                    + "asking it to try again. The same "
                    + "promise the screenplay editor makes. A note that changed "
                    + "elsewhere in the meantime is set aside rather than overwritten, "
                    + "and the editor says when that happens. A song opened offline "
                    + "shows the lyrics saved on this device last time it loaded, "
                    + "with a banner saying how old that copy is. Undo and Redo keep "
                    + "working there: with no connection they walk back the lyric "
                    + "edits still held on this device, and hand over to the song's "
                    + "own history once those have been saved. A brand-new song "
                    + "or note is the exception: until it has reached the server "
                    + "once there is nothing there to keep it against, so the editor "
                    + "says it has not been saved and holds on to it until you are "
                    + "back — leave it and it asks first.",
                    "Finished with a song but not ready to lose it? Archive it. "
                    + "Archiving takes a song or note out of the list without "
                    + "deleting it — the cut verse, the number that left the show. "
                    + "Swipe a row for Archive, or tick several in edit mode and "
                    + "archive them together; notes archive as readily as songs. "
                    + "Archive in the list's menu opens what is there: swipe to "
                    + "unarchive and it rejoins the end of the list, or tap to open "
                    + "it where it is. Unlike the trash nothing in the archive is on "
                    + "a clock and nothing is ever removed from it on its own — an "
                    + "archived song keeps its lyrics and version history and still "
                    + "exports. A songbook of every song leaves the archived ones out."
                ],
                keywords: ["lyrics", "drafts", "scratch", "documents", "insert",
                           "workspace", "list", "bullets", "heading",
                           "recent", "quick", "shortcut", "rename", "swipe",
                           "offline", "unsaved", "sync", "cloud", "badge",
                           "save", "autosave", "title", "undo", "redo",
                           "archive", "archived", "unarchive", "put aside",
                           "hide", "finished", "cut", "shelve", "old",
                           "export", "email", "share", "put back", "select",
                           "musicxml"]),
            HelpTopic(
                id: "title-page",
                title: "Title Page",
                systemImage: "doc.text",
                paragraphs: [
                    "The title page holds the front matter — title, writers, contact "
                    + "details, draft version — with a live preview of the sheet beside "
                    + "the form. It travels with every export that has a front page.",
                    "The screenplay title set here is what the script is headed with. "
                    + "The project name, which the same sheet also holds, is only what "
                    + "your list calls it — so on a screenplay with a title of its own, "
                    + "renaming the project changes the list and leaves the heading "
                    + "alone. Leave the title blank and the two are the same thing."
                ],
                keywords: ["front matter", "credits", "author", "byline", "contact",
                           "draft", "name", "rename", "project name", "heading"]),
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
