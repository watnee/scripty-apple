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
                    "Signed in, this app is the same screenplay as the web editor, on "
                    + "the same account. What you can do to a script is whatever the "
                    + "server says you can do to it, so a reader sees no editing "
                    + "controls at all rather than controls that fail.",
                    "An account is not needed to start. Scripty opens on a workspace "
                    + "kept on this device, and everything below works there too — see "
                    + "Using Scripty Without an Account."
                ],
                keywords: ["introduction", "overview", "start", "beginning", "what is",
                           "account", "sign in", "without an account"]),
            HelpTopic(
                id: "projects",
                title: "Your Projects",
                systemImage: "list.bullet.rectangle",
                paragraphs: [
                    "The sidebar lists every screenplay you can open. Search it by "
                    + "title, sort by last edited or by name, and swipe a row to rename "
                    + "or delete it. A screenplay already open can be renamed where you "
                    + "are: Rename Screenplay heads the “…” menu in the script's "
                    + "toolbar, beside the title page and the rest of its affairs.",
                    "The script itself is headed with the name, at the top of the "
                    + "writing column as well as in reading mode, and tapping that "
                    + "heading types over it. Where a title page sets a screenplay "
                    + "title, that is the name you are editing — the project keeps the "
                    + "name it is filed under in the list, which the title page can "
                    + "change too.",
                    "The star marks a default project. Tap it on the row you keep "
                    + "coming back to, and Scripty opens that screenplay for you "
                    + "the next time it starts — the same landing the web editor "
                    + "gives you. With nothing starred you begin here, on the list."
                ],
                keywords: ["sidebar", "list", "screenplays", "sort", "rename", "default",
                           "star", "swipe", "launch", "open", "startup",
                           "title", "heading", "retitle", "name", "tap the title"]),
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
                    + "version history intact. Bringing back a whole season's worth is "
                    + "one trip — tap Edit in the archive, tick as many as you like and "
                    + "unarchive them together. Unlike Recently Deleted nothing in the "
                    + "archive is on a clock and nothing is ever removed on its own, and "
                    + "an archived screenplay still travels in a project export. It has "
                    + "to come back to the list before it can be opened here, which "
                    + "unarchiving does in one swipe. Archiving also clears it as your "
                    + "default project; unarchiving does not set that again.",
                    "Bringing back a whole season? Edit in the archive ticks rows, and "
                    + "Unarchive brings every ticked screenplay back at once.",
                    "Done with it for good? Delete works from the archive too, and does "
                    + "what it does in the list: the screenplay moves to Recently "
                    + "Deleted, still recoverable."
                ],
                keywords: ["archive", "archived", "unarchive", "put aside", "hide",
                           "finished", "wrapped", "done", "old", "shelve", "retire",
                           "clutter", "tidy", "put back", "restore", "bring back",
                           "select", "bulk", "several", "multiple", "at once",
                           "season", "batch"]),
            HelpTopic(
                id: "project-trash",
                title: "Deleted a Project by Mistake?",
                systemImage: "trash",
                paragraphs: [
                    "Deleting a screenplay asks first, naming the one you swiped — a "
                    + "whole production leaves the list at once, so the swipe alone is "
                    + "not enough to send it.",
                    "Deleting a screenplay moves it to Recently Deleted rather than "
                    + "erasing it, and it comes back with its scenes, characters, "
                    + "versions, songs and notes intact.",
                    "Open Recently Deleted from the sidebar menu — it is offered once "
                    + "there is something in it — and swipe a row to restore it. If the "
                    + "entry is missing, your account is not the one allowed to restore; "
                    + "ask an administrator."
                ],
                keywords: ["recover", "recovery", "undelete", "lost", "missing", "gone",
                           "accident", "bin", "confirm", "are you sure", "asks first"]),
            HelpTopic(
                id: "demo",
                title: "Using Scripty Without an Account",
                systemImage: "sparkles",
                paragraphs: [
                    "Scripty opens straight into a workspace with a sample screenplay in "
                    + "it, with no sign-in first. Everything works — writing, songs, "
                    + "notes, printing — with no server behind it, and nothing is sent "
                    + "anywhere.",
                    "What you write is kept on this device and is still here next time "
                    + "you open Scripty. Projects, songs and notes behave exactly as "
                    + "they do in an account: the app reopens on the screenplay you "
                    + "left, the star still picks which one that is, and the Home "
                    + "Screen widgets and long-press menu list your work as usual.",
                    "The one thing a local workspace cannot do is leave the device. "
                    + "There is no backup, no second device, and nobody to share with; "
                    + "deleting the app takes the writing with it.",
                    "Sign In, in the sidebar menu or on the banner above the list, "
                    + "attaches an account. Everything you wrote before signing in is "
                    + "saved to that account there and then — you are not asked, and "
                    + "there is nothing to tick. It stays on this device as well: "
                    + "keeping is not moving.",
                    "Kept screenplays say so: signed out, the ones your account "
                    + "has carry a Kept badge in the list, and the ones without "
                    + "it are on this device and nowhere else.",
                    "A screenplay you have kept stays one screenplay. Sign out and it "
                    + "is there to go on writing in, holding whatever you last wrote in "
                    + "your account; sign back in and the words you added while signed "
                    + "out go up into that same screenplay. No second copy appears — "
                    + "Scripty does the carrying each time you cross, as long as you "
                    + "are online when you do.",
                    "The songs and notes inside it come across as themselves, not as "
                    + "copies. A song you started signed out is the same song in your "
                    + "account — the same lyric, the same versions behind it — and when "
                    + "you sign out again it is the same song on this device, holding "
                    + "whatever verses you added in either place. Scripty puts you back "
                    + "in the one you were writing in, too: sign in from a lyric and the "
                    + "lyric is what you land in. Folders cross with them: a song filed "
                    + "under a name here arrives filed under that name, and a folder "
                    + "your account has not got is made for it.",
                    "If the same screenplay has been written in both places at once — "
                    + "here while signed out, and in your account from a browser or "
                    + "another device — neither version is thrown away. What you wrote "
                    + "here is saved to your account as a screenplay of its own and "
                    + "Scripty says so, leaving you to decide which is which. The "
                    + "version that any update replaces is kept in that project's "
                    + "version history too.",
                    "A screenplay a different account already has a copy of is the one "
                    + "thing signing in leaves alone: taking it would make a second "
                    + "screenplay rather than catching the first one up, so it stays on "
                    + "this device until you export it yourself. If anything else "
                    + "cannot be saved — you are offline, say — Scripty says so, and it "
                    + "goes up the next time you sign in.",
                    "Screenplays that were only ever in your account stay there: "
                    + "signing out does not bring them onto this device."
                ],
                keywords: ["sample", "try", "offline", "test", "example", "demo",
                           "guest", "sign in", "sign out", "account", "no account",
                           "without an account", "local", "kept", "saved", "backup",
                           "sync", "same project", "same screenplay", "copy", "duplicate",
                           "cloud", "song", "songs", "note", "notes", "lyrics",
                           "same song", "same note"])
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
                    "Undo sits in the top bar, where it can be seen — greyed out when "
                    + "there is nothing to take back, and there whether or not the rest "
                    + "of the chrome is. Hold it and it keeps going, a step at a time, "
                    + "until you lift your finger or there is nothing left to take "
                    + "back — the way a held key repeats. Undo and Redo are both in the "
                    + "“…” menu as well, one step per tap, and both answer to ⌘Z and "
                    + "⌘⇧Z on a keyboard. On a narrow phone the menu is where they "
                    + "are: the bar has no room to draw the pair, so that is where a "
                    + "step comes from there. Steps taken without a connection come "
                    + "back one at a time on this device, and the screenplay's own "
                    + "history takes over once they have been saved.",
                    "The keyboard key at the end of the element bar puts the keyboard "
                    + "away and gives the screen back to the script, without leaving "
                    + "what you were writing. The lyric and note editors carry the "
                    + "same key above their own keyboards.",
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
                           "undo", "redo", "mistake", "step back", "take back",
                           "hold", "long press", "repeat", "keep undoing", "history",
                           "cloud", "sync", "offline", "saved", "badge",
                           "hide keyboard", "dismiss keyboard", "close keyboard",
                           "keyboard"]),
            HelpTopic(
                id: "offline-writing",
                title: "Writing Without a Connection",
                systemImage: "wifi.slash",
                paragraphs: [
                    "Keep typing. Words written with the connection down are kept on "
                    + "this device, survive closing the app, and are sent by themselves "
                    + "when it comes back. A strip under the toolbar says which state "
                    + "you are in: You're offline while there is no connection, Not "
                    + "saved yet while something is still on its way, and Couldn't save "
                    + "if the server refused a line — editing that line tries again.",
                    "Undo and Redo keep working while you are cut off. With no "
                    + "connection they walk back the changes still held on this device "
                    + "— a line retyped, an element started offline, one taken away — "
                    + "and hand over to the screenplay's own history once those have "
                    + "reached the server.",
                    "Tap the ✕ on the strip to put it away. It stays away for as long "
                    + "as that situation lasts, and comes back if the situation changes "
                    + "— a refusal arriving, or the connection dropping again after it "
                    + "returned. The cloud in the top left goes on showing the same "
                    + "state either way, and tapping it says when everything last "
                    + "reached the server.",
                    "Songs, notes and the project list work the same way, and each says "
                    + "how old the copy on screen is when it was read back from this "
                    + "device rather than the server.",
                    "If the same line, song or note was also written somewhere else "
                    + "while you were away, neither version is thrown away. A purple "
                    + "strip says how many changes need your choice; tapping it — or "
                    + "the Review button in the cloud's panel — shows your version "
                    + "beside the cloud's, whole, either one copyable. Keep Mine "
                    + "replaces the other; Use the Cloud's drops yours. Nothing is "
                    + "sent or deleted until you choose, and the question waits as "
                    + "long as it has to, including across a relaunch.",
                    "When several are waiting at once \u{2014} one offline stretch, one "
                    + "other person working through the same scene \u{2014} Resolve All at "
                    + "the top answers them together: Keep All of Mine, or Use All "
                    + "from the Cloud. It asks first and says how many, and it leaves "
                    + "out the ones with nothing to keep.",
                    "The same screen holds the other cases where words would "
                    + "otherwise have gone quietly: a note deleted elsewhere while "
                    + "your edit was waiting (there is nothing to put it back into, "
                    + "so copy what you want to keep), a change the server "
                    + "refused outright, and an element written offline that the "
                    + "server would not take \u{2014} that one never existed anywhere else, "
                    + "so the words are held here for you to copy."
                ],
                keywords: ["offline", "no connection", "unsaved", "held", "sync",
                           "cloud", "banner", "dismiss", "close", "airplane mode",
                           "undo", "redo", "mistake", "step back",
                           "conflict", "conflicts", "two versions", "choose",
                           "keep mine", "review changes", "clobber", "overwrite",
                           "changed elsewhere"]),
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
                    "You can also swipe an element to the left to pick it out where it "
                    + "sits. The first swipe turns Select Elements on around it, and each "
                    + "one after that takes a row or puts it back — a swipe on a ticked "
                    + "row unticks it. Swiping right is left alone: that is how iOS goes "
                    + "back out of the screenplay.",
                    "Each bulk action is one request and one undo step, so a change of "
                    + "mind costs one Undo rather than twenty."
                ],
                keywords: ["bulk", "multiple", "checkbox", "select all", "tags", "batch",
                           "swipe"]),
            HelpTopic(
                id: "find-replace",
                title: "Find and Replace",
                systemImage: "text.magnifyingglass",
                paragraphs: [
                    "The magnifying glass in the toolbar, or ⌘F, opens the find bar "
                    + "over the script. Type and every match is highlighted where it "
                    + "stands; the arrows step from one to the next, bringing each "
                    + "into view without leaving the page.",
                    "Three switches decide what counts as a match. Match Case looks "
                    + "for the capitals you typed. Whole Words ignores a match inside "
                    + "a longer word — \"art\" stops finding \"start\". Cues searches "
                    + "character cues as well as the rest, which is off to begin with "
                    + "so that looking for a word in the dialogue does not stop on "
                    + "every name above it.",
                    "Where you can type, Replace sits beside them. Replace changes "
                    + "the match you are standing on and moves to the next. Replace "
                    + "All asks first, naming how many it is about to change, and "
                    + "counts as one step — so a replacement across two hundred "
                    + "elements is one Undo, not two hundred.",
                    "A song and a note have their own, and they are not quite this. A "
                    + "song's Search narrows the lyric to the lines that match, which "
                    + "is a filter rather than a walk; a note's find bar steps through "
                    + "the prose with Match Case and Whole Words of its own. ⌘F opens "
                    + "whichever belongs to what is in front of you."
                ],
                keywords: ["find", "replace", "search", "match case", "whole word",
                           "replace all", "cues", "highlight", "next", "previous"]),
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
                    "Open in Edit View, at the top of Editor Preferences, decides "
                    + "how a document comes up: off, which it is to begin with, a "
                    + "screenplay, song or note opens to be read, and on, it opens "
                    + "ready to write in. It answers for documents you have never "
                    + "made a choice about — see Documents Open for Reading. Like "
                    + "the font below it, the choice is this device's.",
                    "Default Font in Editor Preferences, on the sidebar menu, sets the "
                    + "typeface everything is written in — Courier Prime, Arial or "
                    + "Times New Roman. It is what an element is drawn in unless you "
                    + "give that one a font of its own from the Format bar, and it "
                    + "carries to songs, notes and a script printed from this device. "
                    + "The choice is this device's, so an iPad and a phone can differ, "
                    + "and files exported through the server are set in Courier "
                    + "whatever you pick here.",
                    "The same screen decides which elements are typed in capitals — "
                    + "scene headings, character cues and transitions, each on its "
                    + "own. That choice is stored on your account, so it follows you "
                    + "to the web editor and back, and the toggles appear only once "
                    + "you are signed in. The font is there either way."
                ],
                keywords: ["capitalisation", "capitalization", "caps", "uppercase",
                           "settings", "automatic", "font", "typeface", "default font",
                           "courier", "arial", "times", "preferences",
                           "open in edit view", "edit view", "reading view"])
        ]),
        HelpSection(id: "reading", title: "Reading and Layout", topics: [
            HelpTopic(
                id: "reading-view",
                title: "Documents Open for Reading",
                systemImage: "book",
                paragraphs: [
                    "A screenplay, song or note opens to be read rather than to "
                    + "be typed into, the way Pages and Word open a file on iPhone "
                    + "and iPad. A phone is a thing you scroll with your thumb, and "
                    + "a document that is live to the keyboard while you scroll "
                    + "through it is one you will eventually type into by accident.",
                    "The words themselves do not change. Reading shows a "
                    + "screenplay, song or note in the same typeface at the same "
                    + "size in the same place on the page as writing does — the "
                    + "same lines breaking in the same spots — and what it leaves "
                    + "out is the editing: the cursor, the element bar, the marks "
                    + "and pins in the margins. Switching between the two moves "
                    + "nothing you were reading. See Read Script, and Songs and "
                    + "Notes for the other two.",
                    "Tap Edit to start writing. It is in the top corner on iPad "
                    + "and Mac, for screenplays as well as songs and notes. On "
                    + "iPhone, where that corner has room for two controls and "
                    + "no more, the screenplay's Edit is in the “…” menu — and "
                    + "the tap below is the quicker way in.",
                    "Or double tap the words themselves, as you would in Pages or "
                    + "Word. Two taps on a line start writing in that line: the "
                    + "screenplay hands you the element you tapped with the cursor "
                    + "at the end of it, and a song or note takes the cursor to "
                    + "where your finger landed. It works the same way on a "
                    + "screenplay or song you have locked with Lock Editing: two "
                    + "taps take the lock off and put you in the line you tapped. "
                    + "Nothing happens where the words were never yours to change: "
                    + "a script shared with you to read stays read-only however "
                    + "many times you tap it.",
                    "That choice is remembered for that document, so it opens ready "
                    + "to type in from then on — the button is a one-time cost, not "
                    + "a toll on every visit. To put a document back up to be read, "
                    + "tap Read Script — or Read Song or Read Note — which takes the "
                    + "place Edit had in the top corner on iPad and Mac, so one tap "
                    + "in that spot is whichever surface is not up. On iPhone the "
                    + "screenplay keeps Read Script in the bar at the foot of the "
                    + "screen, beside Read Aloud. Read Script is in the View menu as "
                    + "well, and Read Song and Read Note stay in a song or note's "
                    + "“…” menu.",
                    "Open in Edit View, in Editor Preferences on the sidebar "
                    + "menu, turns the default round for every document you have never "
                    + "made a choice about; documents you have chosen for keep the "
                    + "choice you made. A script with nothing in it, or one holding "
                    + "words this device has not managed to send yet, always opens "
                    + "for writing — there is nothing to read, or something to "
                    + "finish."
                ],
                keywords: ["read only", "read-only", "reading mode", "read mode",
                           "edit button", "pencil", "accidental", "accident",
                           "locked", "cannot type", "can't type", "won't let me type",
                           "keyboard", "open", "opens", "default", "pages", "word",
                           "double tap", "double-tap", "two taps", "tap twice",
                           "settings", "preferences", "open in edit view"]),
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
                    + "printing, so what you see is what comes out.",
                    "The View menu turns it on from anywhere. While you are reading "
                    + "on an iPhone there is a button for it in the bar at the foot of "
                    + "the screen instead, next to Read Aloud, and it turns back into "
                    + "the reading you came from rather than dropping you into the "
                    + "writing column — see Read Script.",
                    "Paper with nothing on it says which kind of nothing it is. An empty "
                    + "screenplay offers Start Writing, which puts the script back in the "
                    + "writing column with a first element ready to type into. A script "
                    + "holding only notes, sections and synopses has nothing to print, "
                    + "because none of those go to paper."
                ],
                keywords: ["pages", "paper", "pagination", "letter", "a4", "margins",
                           "print", "more", "cont'd", "empty", "blank", "nothing to paginate"]),
            HelpTopic(
                id: "focus",
                title: "Focus Mode and Full Width",
                systemImage: "moon",
                paragraphs: [
                    "Focus Mode strips the screen back to the script alone, leaving only "
                    + "the View menu as the way out. The toolbar keeps that menu, Undo "
                    + "and the way back from reading and loses the rest; the Songs & "
                    + "Notes button goes with it, and so does the running word count. "
                    + "Both margins empty as well — element labels, pins, bookmarks, "
                    + "comment bubbles and tags are all put down for the duration, and "
                    + "the room they were holding goes back to the writing.",
                    "Nothing you had switched on is switched off by it: the marks and "
                    + "the word count are exactly as you left them the moment you leave "
                    + "the mode, which is why their switches are greyed while it is on. "
                    + "What stays is what you cannot afford to lose sight of — whether "
                    + "your work is saved, which version you are typing into, and a "
                    + "reading that is playing.",
                    "Full Page Width lets the writing column use the whole window "
                    + "instead of the printed measure; it is offered only outside page "
                    + "view, where paper has a width of its own."
                ],
                keywords: ["distraction", "zen", "width", "column", "measure",
                           "concentrate", "hide", "marks", "word count", "clutter"]),
            HelpTopic(
                id: "bars-on-scroll",
                title: "The Bars Get Out of the Way",
                systemImage: "arrow.up.and.down",
                paragraphs: [
                    "On an iPhone, scrolling down through a screenplay, a song or "
                    + "a note folds the toolbar at the top away, and the word count "
                    + "at the foot with it, so the page you are reading gets the "
                    + "room the bars were using. Scrolling back up brings them "
                    + "straight back, and so does arriving at the top — it takes a "
                    + "deliberate pull down to fold them away and barely a flick to "
                    + "get them back. A song or note being written folds its title "
                    + "field away too, since that sits above the words rather than "
                    + "scrolling with them.",
                    "It works the same whether the document is open to be read or "
                    + "to be written in, and it is a phone thing only: an iPad has "
                    + "the room to keep its controls. The transport that appears "
                    + "while something is being read aloud is deliberately left "
                    + "where it is — scrolling through a document is not a reason to "
                    + "lose the only handle on the voice reading it. Starting a "
                    + "search, selecting elements, or switching between reading and "
                    + "writing brings everything back as well."
                ],
                keywords: ["toolbar", "bar", "bars", "hide", "hides", "fold",
                           "scroll", "scrolling", "chrome", "room", "space",
                           "navigation bar", "title"]),
            HelpTopic(
                id: "scroll-thumb",
                title: "Getting Down a Long Script",
                systemImage: "arrow.up.and.down.text.horizontal",
                paragraphs: [
                    "Scrolling a feature-length screenplay flick by flick is a long "
                    + "way. A slim handle appears down the right edge while the script "
                    + "is moving: drag it and the whole document goes past at the "
                    + "speed of your thumb. It fades once you stop, so it is not "
                    + "another thing standing on the page.",
                    "For going somewhere in particular rather than just far, the "
                    + "outline is the better tool \u{2014} it lists the scenes and sections, "
                    + "and tapping one lands on it."
                ],
                keywords: ["scrollbar", "scroll bar", "thumb", "handle", "drag",
                           "long", "feature", "jump", "fast scroll", "scrubber"]),
            HelpTopic(
                id: "read-script",
                title: "Read Script",
                systemImage: "book",
                paragraphs: [
                    "Read Script sets the screenplay in screenplay format — the same "
                    + "face and the same indents as the writing column — with the "
                    + "editing controls and the working annotations — synopses and notes "
                    + "— left out. It swaps in on the script screen itself, opening at "
                    + "the place you were writing; double tapping a line, the Edit "
                    + "button, or choosing it again in the View menu puts the "
                    + "writing back — and the Read Script button brings the reading "
                    + "back. Both surfaces "
                    + "measure the page the same way, so switching does not move the "
                    + "script: an element keeps its indent, its line breaks and the air "
                    + "around it, and so does a script with editing locked. To copy a "
                    + "line while you are reading, hold it and choose Copy. It runs "
                    + "continuously, without page breaks or page numbers: page view "
                    + "is the one for reading it as paper, and turning Read Script on "
                    + "switches page view off rather than leaving it waiting "
                    + "underneath. On an iPhone the two sit side by side: Page View "
                    + "is a button in the bar at the foot of the screen, beside Read "
                    + "Aloud, and while the pages are up the same button reads Read "
                    + "Script and brings the reading back. This is also the surface a "
                    + "screenplay opens on — see Documents Open for Reading, which is "
                    + "also where the ways into writing are described. Two taps on a "
                    + "line is the shortest of them, and lands you in that line, the "
                    + "way it does in Pages and Word.",
                    "Read Aloud (⌘⇧A) speaks the script from wherever you are, on "
                    + "whichever surface is up. On a phone it is the speaker in the "
                    + "bar along the bottom, and on every device it is also in the "
                    + "“…” menu in the corner. The element being read is highlighted "
                    + "and scrolls itself into view, and the transport at the foot of "
                    + "the screen steps back and forward an element at a time; hold an "
                    + "element for “Read Aloud From Here”.",
                    "The speaker menu sets the speed and the voice, and what gets read: "
                    + "character names, action and headings, and parentheticals can each "
                    + "be left out — dialogue alone is how you run lines. “A Voice Each” "
                    + "hands the speaking parts different voices, as far as the voices "
                    + "installed on the device stretch. Those four are screenplay "
                    + "grammar, so a song or a note — which can be read aloud too, see "
                    + "Songs and Notes — is offered the speed and the voice alone.",
                    "The voice list is the device’s, sorted: the best-sounding first, "
                    + "one entry per voice, and the joke voices left out. A voice marked "
                    + "Enhanced or Premium is one that has been downloaded — they sound "
                    + "far better than the built-in ones, and Default picks the best "
                    + "edition you have. To get more, go to the Settings app, then "
                    + "Accessibility › Spoken Content › Voices, and download one; it "
                    + "appears here next time the menu opens. Speeds are honest "
                    + "multiples of the normal pace, so 2× is twice as fast and still "
                    + "words."
                ],
                keywords: ["reader", "reading", "format", "courier", "indents",
                           "review", "distraction free",
                           "copy", "select", "selection", "highlight text",
                           "aloud", "speech", "speak", "voice", "listen", "audio",
                           "table read", "run lines", "text to speech",
                           "voices", "enhanced", "premium", "download voice",
                           "narrator", "speed", "faster", "slower"]),
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
                    + "the screenplay lets you do.",
                    "A locked script has one other way back: double tap the line you "
                    + "want. The lock comes off and the cursor lands at the end of "
                    + "that line, the way it does in Pages and Word. Display modes "
                    + "are left alone — that gesture is about the keyboard, not about "
                    + "how the script is laid out.",
                    "Lock Editing itself is in the screenplay's “…” menu, where a song "
                    + "and a note both keep theirs. It is not in the View menu: what is "
                    + "under View changes how the script is laid out and nothing else, "
                    + "and the lock takes the keyboard away until you turn it off."
                ],
                keywords: ["edit", "write", "writing", "back", "exit", "leave", "modes",
                           "unlock", "locked", "read only",
                           "lock", "lock editing", "protect", "menu", "where",
                           "double tap", "double-tap", "tap twice"]),
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
                    + "draft leaves the others alone.",
                    "Tags, set from an element's own menu or on a whole selection at "
                    + "once, sit under the line they belong to as small badges — while "
                    + "you are writing as well as while you are reading, so a tag you "
                    + "set is a tag you can see."
                ],
                keywords: ["star", "pin", "flag", "highlight", "labels", "markers",
                           "favourite", "tags", "badges"]),
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
                    "The size you set here composes with the one in the Settings app "
                    + "under Display & Brightness, rather than overriding it: the script "
                    + "follows the type size the rest of your device is set at, and "
                    + "Bigger and Smaller move it from there. The column grows with the "
                    + "type either way, so the same number of characters stays on the "
                    + "line and the script keeps the shape of a script.",
                    "All of these are settings for this device rather than for the "
                    + "account: the same screenplay is read on a bright rehearsal-room "
                    + "iPad and in a dark editing suite. Printing and PDF export stay at "
                    + "12pt whatever you are reading at, so the pages still count the "
                    + "way a screenplay's pages are supposed to.",
                    "Songs and notes are set in the screenplay's own typeface and scale "
                    + "with it, so a lyric reads at the size of the scene it belongs to."
                ],
                keywords: ["zoom", "font size", "larger", "smaller", "dark mode",
                           "light", "theme", "readability", "format bar",
                           "dynamic type", "accessibility", "display brightness",
                           "points", "pt", "10", "12", "14", "16"]),
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
                    + "rather than how the whole draft balances. That band is the "
                    + "screenplay's alone: a song or a note is short enough that its "
                    + "own count is read from its \u{201C}…\u{201D} menu instead, "
                    + "leaving the writing the whole sheet."
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
                    + "several of them. There is no Add Line button under a song "
                    + "there: Return at the end of a line makes the next one, which is "
                    + "how a lyric is written anyway. A song with nothing in it yet "
                    + "keeps the offer, having no line to press Return at.",
                    "How long a song or a note runs is one line of its \u{201C}…\u{201D} "
                    + "menu — the word count, counted over what is on screen rather "
                    + "than what was last saved. It is read there rather than switched "
                    + "on under the words, so nothing stands between a short document "
                    + "and the writing of it. The closed sections of the workspace "
                    + "screens say the same number for every song or note at once.",
                    "Both editors can be searched. In a song the magnifying glass "
                    + "narrows the lyric to the lines that match, which is what a "
                    + "lyric is — a list. In a note it opens the find bar over the "
                    + "prose: every hit highlighted, arrows to step between them, "
                    + "Match Case and Whole Words of their own, and Replace beside "
                    + "Find while the note is open to typing.",
                    "The order of the songs is your own, and the all-songs workspace "
                    + "will rearrange it. Arrange Songs, in the \u{201C}…\u{201D} menu "
                    + "there, sets the lyrics aside and leaves the titles to be "
                    + "dragged into the order you want by the grip beside each one; "
                    + "Done puts the writing back, still open at the songs you left "
                    + "open. Arrange Notes does the same on the all-notes page. For a "
                    + "single nudge there is no need for any of that — Move Up and "
                    + "Move Down, in the \u{201C}…\u{201D} beside a title, move that "
                    + "one document a place where it stands. Either way the whole "
                    + "arrangement is saved, and a filter narrowing the screen moves "
                    + "only the documents you can see. The lists rearrange the same "
                    + "way: Edit, then drag by the grip.",
                    "A row\u{2019}s \u{201C}\u{2026}\u{201D} menu holds two more. Duplicate makes a "
                    + "copy titled \u{201C}\u{2026} (copy)\u{201D} \u{2014} somewhere to try a second "
                    + "chorus without losing the first. Make a Song and Make a Note "
                    + "swap which list a document belongs to; the words come across "
                    + "whole, and a song that becomes a note leaves its folder behind, "
                    + "because the two lists keep their own.",
                    "Songs and notes are offered the same things. Both export as text, "
                    + "PDF, Word or EPUB, on their own or as one file of the whole list; "
                    + "both can be emailed to a collaborator; and Edit selects several "
                    + "at once to delete, archive, email, print or export together. The "
                    + "one format that stays with songs is MusicXML, which is a score to "
                    + "open in a notation program, and a page of scene notes is not a "
                    + "thing to set to music.",
                    "Import, in the top corner of either list, brings words in "
                    + "from a file: plain text, Fountain, Word, Final Draft, PDF, "
                    + "or a MusicXML score, which comes in as its lyric. Pick as "
                    + "many files as you like in one go — each becomes a song or a "
                    + "note of its own, named after the file, and they arrive in "
                    + "the order you picked them, joining whichever list you were "
                    + "on. A single file opens for writing as soon as it lands; "
                    + "several stay in the list, and a line at the end says what "
                    + "came in and names anything that did not.",
                    "Print sits beside Export wherever Export is, because it is an "
                    + "errand rather than another format: on a row's menu for that one "
                    + "song or note, in either editor's \u{201C}…\u{201D} menu for the "
                    + "one you have open, and in the list's and the workspace's menus "
                    + "for the whole list at once — one document to a sheet, headed with "
                    + "its title. \u{2318}P prints whichever song or note is in front of "
                    + "you, and the screenplay when none is. As with a script, the paper "
                    + "comes from the PDF, so it is the file you would have exported; "
                    + "with no connection the sheet is drawn here instead, from the "
                    + "words on screen — including the ones typed since the last save, "
                    + "and from a note that has never reached the server at all.",
                    "A song can keep the recording as well as the words. "
                    + "Recordings sits at the head of the lyric — over the title "
                    + "while you write, over the page while you read — and "
                    + "holds what this song sounds like: the voice memo you sang "
                    + "the tune into, the demo the band sent back, a reference "
                    + "track you are chasing. "
                    + "Add Recording takes an audio file of 25 MB or less from "
                    + "anywhere the Files app can reach \u{2014} MP3, M4A, AAC, WAV, AIFF, "
                    + "FLAC, OGG, Opus, CAF and the rest of what an iPhone records or "
                    + "a band sends \u{2014} up to fifty of them. A file over the limit is "
                    + "turned away before it is sent, rather than after. "
                    + "Each plays in place, one at a time, "
                    + "and keeps playing with the screen off; swipe a take to rename "
                    + "or delete it, or press and hold to send a copy on. Anyone who "
                    + "can open the song can listen — adding and deleting need the "
                    + "same permission the lyrics do. Recordings are the one thing "
                    + "that stays behind when a song travels: they are not carried in "
                    + "an export, an email, a printed sheet or the bundle that moves "
                    + "work into an account when you sign in, so save anything you "
                    + "cannot replace first. Deleting one is final — there is no "
                    + "trash for a file.",
                    "Folders group a long list. They sit as a strip of names "
                    + "above the rows — All and Unfiled among them — and tapping "
                    + "one shows that folder; New Folder at the end of the strip "
                    + "names a new one, and pressing and holding a folder there "
                    + "renames or removes it. "
                    + "A row's Folder menu files that song or note, and can make "
                    + "the folder while it does it; Edit ticks several and files "
                    + "them together. Each row says which folder it is in, and a "
                    + "search runs inside whichever folder is showing. Songs and "
                    + "notes keep separate folders, since they are separate "
                    + "lists, and a song that becomes a note leaves its folder "
                    + "behind. Removing a folder takes away the name and nothing "
                    + "else: everything that was in it stays in the list, "
                    + "unfiled.",
                    "Archiving is not deleting. A song or note set aside from its "
                    + "menu leaves the list whole and readable, with nothing counting "
                    + "down against it; Archived Songs & Notes lists what is on the "
                    + "shelf and Put Back returns it. Delete still sends things to the "
                    + "trash, which is where a countdown does apply, and an archived "
                    + "document can be deleted from the shelf without coming back "
                    + "first.",
                    "Undo and redo are offered wherever songs and notes are written, "
                    + "and answer to ⌘Z and ⌘⇧Z. They belong to the document while it "
                    + "is open — never to the screenplay behind it — so a step back in "
                    + "a verse can never rewind the script you left. In the notes and "
                    + "plain song editors the pair sits in the top corner beside Done, "
                    + "where holding either one keeps walking that way a step at a time "
                    + "until you lift your finger or run out of history, and the pair is "
                    + "repeated in the bar above the keyboard while you are typing. "
                    + "They walk the whole document "
                    + "— the title as well as the words, so a new song can be taken "
                    + "back from its first keystroke, which is typed into its name. A "
                    + "burst of typing, a bullet the bar added, a title being renamed, "
                    + "an edit made offline: one step at a time, and the caret goes "
                    + "back to the field the step was typed into. That history stays "
                    + "on this device and starts fresh each time the document is "
                    + "opened.",
                    "A song with lyric lines keeps a longer memory. The pair at the top "
                    + "of its editor holds the same way, and steps through the same "
                    + "history the browser shows while you have a connection; without "
                    + "one it steps back through "
                    + "the lyric edits still waiting on this device, newest first, so a "
                    + "line typed offline can be taken back offline. Once those edits "
                    + "reach the server they become part of its history and undo goes "
                    + "back to walking that. Each step says what it did, the way a "
                    + "screenplay's does — a line that comes back may be one you cannot "
                    + "see from where you are. On either workspace screen the pair sits "
                    + "beside each title instead, since every song and every note keeps "
                    + "a history of its own.",
                    "Songs and notes each have a reading mode, the songs' and notes' "
                    + "answer to Read Script — and, as with a screenplay, the surface "
                    + "an existing one opens on. Read Song and Read Note show the "
                    + "words exactly as you wrote them: the same face, the same size, "
                    + "the same left edge, the same line breaks, blank lines and all. "
                    + "Nothing is re-set for reading — a note is the plain text it "
                    + "always was, hashes and dashes included — so the only "
                    + "difference is that one takes the keyboard and the other does "
                    + "not. Both are in the editor's “…” menu; Edit, in the top "
                    + "corner, puts the writing back where you left it, and both take "
                    + "the same device-wide text size. A document with nothing in it "
                    + "opens for writing instead — there is nothing to read.",
                    "Both workspace screens read as well as write. Read Songs — or "
                    + "Read Notes — in the top corner beside Expand and Collapse and "
                    + "in the \u{201C}…\u{201D} menu, puts everything open on the "
                    + "screen up to be read at once, which is how you hear whether the "
                    + "third song follows the second and how you read a project's "
                    + "notes end to end; Edit, in the same corner, hands them all "
                    + "back. Two taps in the words do the same, land the cursor where "
                    + "your finger did, and take any lock on that one document off on "
                    + "the way. It is the whole screen rather than one document at a "
                    + "time, and each screen remembers which way you left it; a song's "
                    + "or a note's own choice in its editor is its own, and says "
                    + "nothing about the page that shows them all, nor does one page "
                    + "speak for the other. Because you reach these screens by tapping "
                    + "Edit All on One Page, they open ready to type in unless you "
                    + "have put them up to be read yourself. A note being read is not "
                    + "clipped to the height its field had — the page scrolls through "
                    + "the whole of it, note after note.",
                    "The name sits at the head of a song or note either way — over the "
                    + "words while you read, over the lines while you write, in the "
                    + "same face and the same place — and you can type over it there "
                    + "instead of going back to the list to rename it.",
                    "Both editors show a keyboard key above the keyboard while you "
                    + "write — it puts the keyboard away and leaves the words where "
                    + "they are.",
                    "A song being worked on is rarely far away. The script has a Songs "
                    + "& Notes button at the top of the screen. Pressing it opens the "
                    + "list you were last on — songs until you have been on the other "
                    + "one — and holding it lists both by name, along with the last "
                    + "few of each kind you edited, each going "
                    + "straight to its lyrics or its text. The lists repeat those same "
                    + "few at the top, so a long one needs no scrolling to reach them. "
                    + "Starting one is the button under the list — New Song over the "
                    + "songs, New Note over the notes. An element's own menu inserts a "
                    + "song below it. Swipe a row one way to rename or delete it and "
                    + "the other way to lock it; touch and hold for everything else.",
                    "A finished song or note can be locked. Lock Editing closes it "
                    + "to typing — a lyric's lines stop taking keystrokes and stop "
                    + "offering delete and highlight, and a note stops taking them "
                    + "at all — so a song being read from at a rehearsal, or a shot "
                    + "list held up on set, cannot pick up a stray character. "
                    + "Whatever you had just typed is saved on the way in. A banner "
                    + "across the top says it is locked and unlocks it when tapped — "
                    + "as does a double tap on the words themselves, which unlocks "
                    + "the document and puts the cursor where your finger landed. "
                    + "The lock is kept on this device, one document at a time, and "
                    + "applies to a song's own edition when you are in one.",
                    "The switch is wherever the document is. It is in the editor's "
                    + "menu; it is also on the list, where a swipe across a row — "
                    + "rightwards, away from Delete — closes it to typing, and the "
                    + "same swipe on a closed row says Unlock and opens it again. "
                    + "Touching and holding offers the same switch by name, and "
                    + "a padlock beside the name says which rows are closed. On "
                    + "either workspace page — every song at once, or every note — "
                    + "each title's “…” carries the same switch beside its Move Up "
                    + "and Move Down, and Lock All Songs, or Lock All Notes, in the "
                    + "page's menu closes the lot in one press, which is what "
                    + "finishing a book or a batch usually means; press it again to "
                    + "unlock them. It is still one lock per document, so unlocking "
                    + "the one number being rewritten leaves the rest of the book "
                    + "shut. With a filter on the page it covers what you can see.",
                    "Both workspace screens honour a lock too — every song on one "
                    + "page, every note on the other — mark the locked ones with a "
                    + "padlock, and take the same double tap to unlock the one "
                    + "document you meant; neither is a way round a lock. The banner "
                    + "is there as well, over the locked document you open, and "
                    + "unlocks that one alone.",
                    "A song or a note can also be read to you. Read Aloud, in the "
                    + "editor's \u{201C}…\u{201D} menu and on \u{2318}\u{21E7}A, speaks the "
                    + "words in the same voice and at the same speed the screenplay's "
                    + "own Read Aloud uses; the transport at the foot of the screen "
                    + "steps a line at a time, and the speaker beside it sets the "
                    + "speed and the voice. In a song the line being read is "
                    + "highlighted and scrolls itself into view, and holding a line "
                    + "while the song is up to be read offers \u{201C}Read Aloud From "
                    + "Here\u{201D} \u{2014} the third verse without the two before it. It works "
                    + "while you "
                    + "are writing as well as while you are reading, and it keeps "
                    + "going with the screen off \u{2014} the Lock Screen shows the "
                    + "document's name and the line being read. One voice at a time: "
                    + "reading a song stops a screenplay that was being read, and "
                    + "closing the document stops the reading. The reading follows "
                    + "the words: keep typing and what you have written is picked up "
                    + "as each change saves, rather than the voice going on with the "
                    + "version you started it on.",
                    "Both workspace screens read the whole set through. Read Songs "
                    + "Aloud and Read Notes Aloud, in the \u{201C}\u{2026}\u{201D} menu there, "
                    + "speak every song or note on the page in the order it is shown, "
                    + "each announced by its title \u{2014} which is how you hear whether "
                    + "the third song follows the second. \u{2318}\u{21E7}A does the same from "
                    + "the keyboard, a filter narrows what is read to what is on "
                    + "screen, and leaving the page stops the reading.",
                    "Locking is not reading. A locked document is still the writing "
                    + "surface — the same lines, the same lists — with the keyboard "
                    + "taken away from it; Read Song and Read Note set the words for "
                    + "reading instead. Either can be on without the other, and a "
                    + "double tap takes both off at once.",
                    "The lists, the editors and the workspace each take the whole "
                    + "screen rather than a card over the script; Done, at the top "
                    + "left, is the way back.",
                    "A lyric line or a note edited without a connection is kept on "
                    + "this device — the corner cloud says so wherever songs and "
                    + "notes are written, in either editor and on either workspace "
                    + "screen; it turns orange while anything is waiting, and opens "
                    + "on a tap with a Sync Now button — and is saved by itself when "
                    + "the connection returns, even across a relaunch, without your "
                    + "asking it to try again. The same "
                    + "promise the screenplay editor makes. A line or a note that "
                    + "changed elsewhere in the meantime is never overwritten and "
                    + "never dropped: both versions are kept, and a purple strip "
                    + "offers the choice between them. A song or a note opened "
                    + "offline shows the words saved on this device last time it "
                    + "loaded — the whole document, not the line of preview the list "
                    + "shows — with a strip saying how old that copy is; tap its ✕ to "
                    + "put it away until a newer copy arrives. Undo and Redo keep "
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
                    + "it where it is. Whatever you archived together comes back "
                    + "together — tap Edit in the archive, tick them and unarchive "
                    + "the lot. Unlike the trash nothing in the archive is on "
                    + "a clock and nothing is ever removed from it on its own — an "
                    + "archived song keeps its lyrics and version history and still "
                    + "exports. A songbook of every song leaves the archived ones out.",
                    "Opened one from the archive? The editor says so along the top, "
                    + "and Unarchive there puts it back into the list without "
                    + "closing what you are reading."
                ],
                keywords: ["lyrics", "drafts", "scratch", "documents", "insert",
                           "word count", "words", "count", "length", "how long",
                           "recording", "recordings", "voice memo", "demo",
                           "mp3", "m4a", "wav", "aiff", "flac", "upload",
                           "attach", "play", "playback", "track", "tape",
                           "workspace", "list", "bullets", "heading",
                           "read", "reading", "read song", "read note", "prose",
                           "read songs", "read notes", "all songs", "all notes",
                           "one page", "set list",
                           "verse", "stanza", "distraction",
                           "aloud", "read aloud", "speech", "speak", "voice",
                           "listen", "audio", "text to speech", "sing",
                           "recent", "quick", "shortcut", "rename", "swipe",
                           "offline", "unsaved", "sync", "cloud", "badge",
                           "save", "autosave", "title", "undo", "redo",
                           "hold", "long press", "repeat", "keep undoing",
                           "archive", "archived", "unarchive", "put aside",
                           "hide", "finished", "cut", "shelve", "old",
                           "bring back", "bulk", "several", "multiple",
                           "at once", "batch",
                           "export", "email", "share", "put back", "select",
                           "print", "printing", "printer", "paper", "lyric sheet",
                           "musicxml", "mistake", "history", "step back",
                           "dismiss", "close",
                           "lock", "locked", "unlock", "lock all", "unlock all",
                           "swipe to lock", "read only", "protect",
                           "find", "search", "replace", "match case", "whole words",
                           "arrange", "rearrange", "reorder", "order", "drag",
                           "move up", "move down", "sort",
                           "folder", "folders", "group", "grouping", "file",
                           "filed", "unfiled", "act", "organise", "organize",
                           "tidy", "move to",
                           "add line", "new line", "another line",
                           "hide keyboard", "dismiss keyboard", "keyboard"]),
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
                    + "alone. Leave the title blank and the two are the same thing.",
                    "That heading can also be typed over where it stands, at the top "
                    + "of the script: it edits whichever of the two names it is "
                    + "showing, so a screenplay with a title of its own is retitled "
                    + "there and keeps the name it is filed under."
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
                    + "first, because Undo cannot reach it.",
                    "Empty Trash at the top of that screen destroys all of them at "
                    + "once. It asks first and says how many, for the same reason: "
                    + "nothing brings them back afterwards.",
                    "A song keeps one of its own. Deleted Lines, in a song's \"…\" "
                    + "menu, is the same screen for the lines of that lyric — restore "
                    + "one to where it was, or destroy it. A note has no line list, so "
                    + "it has nothing of the kind; a deleted note goes to the project's "
                    + "trash whole."
                ],
                keywords: ["restore", "recover", "undelete", "bin", "removed", "block",
                           "empty trash", "deleted lines", "lyric"])
        ]),
        // Its own section because none of it is about writing. Passkeys, the
        // password, Siri and the widgets are about the account behind the work
        // and the device it is being done on, and each of them had nowhere to
        // live in the five sections that came before — so none of them was
        // written about at all, while every one of them puts a button in front
        // of the writer.
        HelpSection(id: "account", title: "Your Account and This Device", topics: [
            HelpTopic(
                id: "passkeys",
                title: "Signing In with a Passkey",
                systemImage: "person.badge.key",
                paragraphs: [
                    "A passkey signs you in with Face ID, Touch ID or your device "
                    + "passcode instead of a password. There is nothing to remember and "
                    + "nothing to type, and because the key never leaves your device "
                    + "there is nothing that can be read off a server or guessed.",
                    "Sign in with a Passkey appears on the sign-in screen wherever the "
                    + "server offers them. The first time, sign in with your password "
                    + "and then add one from Account in the sidebar menu: it asks for "
                    + "Face ID and gives the passkey a name, so a list of several says "
                    + "which device each belongs to.",
                    "Passkeys are kept in the same place your passwords are, so one "
                    + "added on an iPhone works on the iPad signed in to the same Apple "
                    + "Account. Account lists every passkey on your account and can "
                    + "revoke any of them — worth doing for a device you no longer have. "
                    + "Your password still works, so revoking the last passkey does not "
                    + "lock you out.",
                    "Use a Saved Password, underneath, is the other way in: it opens the "
                    + "same sheet your passwords are kept in and fills the form from "
                    + "there."
                ],
                keywords: ["face id", "touch id", "biometric", "passwordless",
                           "webauthn", "security key", "log in", "login", "authenticate",
                           "keychain", "revoke", "device"]),
            HelpTopic(
                id: "password",
                title: "Changing or Recovering Your Password",
                systemImage: "key",
                paragraphs: [
                    "Account, in the sidebar menu, changes the password: the current one "
                    + "and the new one, and you stay signed in here.",
                    "Forgotten it, on the sign-in screen, is Forgot Password. Give the "
                    + "email address on the account and a link is sent to it. There is "
                    + "no code to copy — opening the link on this device brings you "
                    + "straight back here with the new-password field ready. Reading "
                    + "your mail somewhere else? Paste the link into the waiting screen "
                    + "instead and it goes on from there.",
                    "The link is good once and not for long. Asking again simply sends "
                    + "another; the screen says the same thing either way, which is "
                    + "deliberate — an address that is not on an account should not be "
                    + "told so by a help screen or by anyone trying addresses.",
                    "If the server has locked your account until the password changes, "
                    + "it will say so and send you to the website to do it. That one "
                    + "cannot be done from here."
                ],
                keywords: ["forgot", "forgotten", "reset", "recover", "lost",
                           "email", "link", "locked out", "cannot sign in",
                           "change", "credentials"]),
            HelpTopic(
                id: "users",
                title: "Managing Users",
                systemImage: "person.2.badge.gearshape",
                paragraphs: [
                    "Users, on the sidebar menu, appears only for an administrator \u{2014} "
                    + "the server advertises it to nobody else, so an ordinary writer "
                    + "never sees it. It lists everyone with an account on this server, "
                    + "with what each of them may do.",
                    "From there an account can be made, renamed, given or refused "
                    + "administrator rights, and removed. It is about who may sign in "
                    + "at all; who can see a particular screenplay is a different "
                    + "question, answered by Teams and by sharing."
                ],
                keywords: ["admin", "administrator", "accounts", "people", "roles",
                           "permissions", "server", "manage"]),
            HelpTopic(
                id: "siri-shortcuts",
                title: "Siri, Shortcuts and Spotlight",
                systemImage: "mic",
                paragraphs: [
                    "Scripty answers Siri without any setting up. \"Open Songs in "
                    + "Scripty\", \"Open Notes in Scripty\", "
                    + "\"Open my screenplay in Scripty\", \"New note in "
                    + "Scripty\", \"New song in Scripty\", \"Add a lyric in Scripty\" and "
                    + "\"Add an action line in Scripty\" all work, and each opens the app "
                    + "where the words landed rather than leaving you to find them.",
                    "The same actions are in the Shortcuts app under Scripty, so they "
                    + "can be put in a shortcut of your own — dictate a line on a walk, "
                    + "or open the songs list from a Home Screen icon. Where an action "
                    + "asks which screenplay, song or note, type part of the title and "
                    + "it is found: an exact name comes first, then one that starts that "
                    + "way, and accents and capitals are not something you have to get "
                    + "right.",
                    "Your screenplays, songs and notes are in Spotlight too: type part "
                    + "of a title from the Home Screen and it is a result that opens the "
                    + "thing it names. A screenplay can also be found by who it is by, "
                    + "and a song or a note by the screenplay it belongs to. Signing out "
                    + "clears all of it from the device.",
                    "For anything more particular there are Find Screenplays and Find "
                    + "Songs & Notes in the Shortcuts app, which take conditions — a "
                    + "title that contains something, only the songs, only what was "
                    + "written this week, only your starred screenplay — and hand back "
                    + "what matched for the next step to work on."
                ],
                keywords: ["voice", "hey siri", "dictate", "speak", "automation",
                           "search", "spotlight", "app shortcuts", "hands free",
                           "find", "filter", "look up", "by name"]),
            HelpTopic(
                id: "widgets",
                title: "Widgets and Control Centre",
                systemImage: "square.grid.2x2",
                paragraphs: [
                    "Four widgets, added the usual way — press and hold the Home Screen, "
                    + "then Edit, then drag one out of the gallery. Screenplays lists "
                    + "your projects and can be set to one in particular; Songs and "
                    + "Notes each list documents from the screenplay you last had open; "
                    + "Bookmarks lists the lines you have flagged, grouped by "
                    + "screenplay. Every row opens the thing it names.",
                    "Scripty's buttons are in Control Centre as well, and can go on the "
                    + "Lock Screen or the Action button: Songs, Screenplay, New Note and "
                    + "New Song. Press and hold Control Centre, then the add button, to "
                    + "find them under Scripty.",
                    "Press and hold the app icon for Songs and Notes, plus the "
                    + "screenplays you were working on most recently. It is a shorter "
                    + "list than Control Centre\u{2019}s on purpose \u{2014} the Home Screen menu "
                    + "holds a few entries, and the two lists are the ones worth the "
                    + "room.",
                    "All of it works without an account, on whatever is on the device. "
                    + "Signing out empties every widget rather than leaving the last "
                    + "writer's titles on the Home Screen."
                ],
                keywords: ["home screen", "lock screen", "control centre",
                           "control center", "action button", "tile", "glance",
                           "quick action", "long press", "icon"])
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
                    + "character.",
                    "An actor can also be marked as having auditioned for particular "
                    + "characters, which is a separate thing from being cast in one: it "
                    + "is the record of who was seen for what, kept while the decision "
                    + "is still open. Open an actor and edit them to tick the characters "
                    + "they read for; the set you leave is the set that is kept."
                ],
                keywords: ["cast", "actors", "roles", "people", "assign", "profile",
                           "audition", "auditioned", "read for", "shortlist",
                           "considered", "tried out"]),
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
                    + "last cut.",
                    "A song keeps both of its own, in its \u{201C}\u{2026}\u{201D} menu. Editions "
                    + "there are second and third versions of the same lyric \u{2014} the "
                    + "radio edit beside the album cut \u{2014} and the picker at the head of "
                    + "the song appears once there is more than one to choose between. "
                    + "Version History there lists that song\u{2019}s snapshots, and a song "
                    + "version reports its title and how many lines it had where a "
                    + "screenplay reports scenes and elements. A note has neither: it "
                    + "is plain text with nothing to vary."
                ],
                keywords: ["snapshot", "revision", "backup", "restore", "draft",
                           "history", "timeline", "published", "song editions",
                           "alternate", "cut", "lyric version"]),
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
