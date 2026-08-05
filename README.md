# Scripty for iPhone and iPad

A SwiftUI client for Scripty, the screenplay editor. It talks to the same HAL
API the web app does, and it opens straight into a working editor — no account,
no server, no sign-in first. Signing in is offered from inside the app, and
brings whatever was written before it along.

## Start from nothing

On a Mac with none of this yet, one line gets you a running app:

```sh
curl -fsSL https://raw.githubusercontent.com/watnee/scripty-apple/main/scripts/get.sh | bash
```

That checks Xcode, clones this repository into `~/scripty-apple`, and runs the
app. It asks before anything that needs your password, and Xcode itself is the
one thing it cannot install for you — it is a free App Store download, and the
script points you at it and stops.

```sh
... | bash -s -- --dir ~/code/scripty   # clone somewhere else
... | bash -s -- --no-run               # set up, don't launch
... | bash -s -- -- --simulator         # pass the rest to run.sh
```

Rerunning it updates an existing clone and starts the app again. If you would
rather do it by hand, `git clone` this repository and read on.

If a terminal is not your thing, skip the command entirely: download this
repository (the green **Code** button > **Download ZIP**, or `git clone`) and
double-click **Install Scripty.command** inside it. Finder opens it in a
Terminal window and it does exactly what the one-liner does. Four siblings sit
next to it for the other things you might want without typing a command —
**Install on iPhone or iPad.command** (build a signed copy and put it on every
plugged-in device, waiting for one instead of falling back to the demo),
**Try Scripty (Demo).command** (the offline demo in a simulator),
**Update Scripty.command**, and **Uninstall Scripty.command**. The first time you
open any of them, macOS may say it is from an unidentified developer —
right-click the file, choose **Open**, and that button runs it once and
remembers.

## Run it

```sh
./scripts/run.sh
```

That is the whole thing. If an unlocked iPhone or iPad is plugged in and this
Mac can sign, Scripty lands on the device; otherwise it opens the offline demo
in a simulator. It says which it chose and why before it starts.

```sh
./scripts/run.sh --simulator             # ignore any plugged-in device
./scripts/run.sh --device                # insist on the real device
./scripts/run.sh --device "Clint iPhone" # pick one by name
./scripts/run.sh --all                   # every connected device
./scripts/run.sh -- --reset              # pass the rest to whichever it picks
```

It only chooses between the two commands below, so reach for those directly
when you already know which one you want.

## Try it in the simulator

```sh
./scripts/demo.sh
```

That builds the app, boots an iPad simulator, and opens a sample screenplay in
the offline demo — no account, no backend, nothing to sign. Everything you type
lives in memory and disappears when you uninstall it.

```sh
./scripts/demo.sh --device "iPhone 17"   # pick a simulator by name
./scripts/demo.sh --no-build             # relaunch what is already installed
./scripts/demo.sh --reset                # discard edits from a past demo
```

You need Xcode with an iOS 26.2 simulator runtime (Xcode > Settings >
Components). If `xcodebuild` is missing, point the command-line tools at your
Xcode:

```sh
sudo xcode-select --switch /Applications/Xcode.app
```

## Put it on your own iPhone or iPad

```sh
./scripts/install.sh
```

Run that, then plug the device in over USB and unlock it. It waits for a device
rather than telling you it found none, finds your signing team, builds,
installs, and launches. The first pairing needs the cable; after that, if you
turn on "Connect via network" for the device in Xcode's Devices window, later
runs find it over Wi-Fi and you can leave the cable out.

A phone and a tablet on the same desk are one run, not two: with several devices
connected it offers "All 2 of them" as the first answer, and `--all` skips the
question entirely. It builds once and installs that same copy everywhere, so the
second device costs seconds — only a device your team has never seen needs a
build of its own, to get itself registered.

If you would rather not open a terminal, double-click **Install on iPhone or
iPad.command** at the top of the project instead — it runs this same path (Xcode
check included) in a Terminal window Finder opens for you, and takes every
connected device without asking.

```sh
./scripts/install.sh --all                       # every connected device, no question
./scripts/install.sh --list                      # show paired devices
./scripts/install.sh --device "Clint iPhone"     # just this one
./scripts/install.sh --team ABCDE12345           # if you have more than one team
./scripts/install.sh --bundle-id com.you.scripty # a name of your choosing
./scripts/install.sh --demo                      # start in the offline demo
./scripts/install.sh --no-launch                 # install without launching
./scripts/install.sh --forget                    # drop the remembered answers
```

Unlike the simulator, a real device insists the app be signed. A free Apple ID
is enough. Six things commonly stand in the way, and the script handles five
of them while you watch rather than leaving you in the build log:

- **Developer Mode is off.** It says so and waits: Settings > Privacy &
  Security > Developer Mode on the device, then restart it.
- **The screen is locked.** Installing onto a locked device works, but Xcode
  will not *build* against one — it waits for a destination that never arrives
  and reports a timeout. With another device connected the script builds against
  that one instead and installs on both; with only the locked one it says so and
  waits for you to unlock it. A locked device that can't open the app afterwards
  is told apart from the trust problem below, rather than both being reported as
  a certificate you haven't trusted.
- **The bundle id is taken.** The default is `scripty.scripty`, which is
  registered to this project's team, so the first build by anyone else fails.
  The script then names the app after your team — `com.<teamid>.scripty` — and
  builds again. Pass `--bundle-id` if you would rather choose.
- **The app installs but won't open.** A free Apple ID signs with a certificate
  the device does not trust until you say so: Settings > General > VPN & Device
  Management > tap your Apple ID > Trust. The script waits for that tap and
  starts the app once you've made it.
- **A copy signed by another team is already there.** iOS won't upgrade across
  teams, and no flag talks it round — the old copy has to go, taking its notes,
  drafts and sign-in with it. The script recognises that error, explains what
  will be lost, and asks before removing anything.
- **No certificate.** This one it cannot do for you: open Xcode > Settings >
  Accounts, add your Apple ID, let it create a development certificate, and
  rerun.

Your team, and the bundle id if it had to pick one, are remembered in
`.scripty-install` so later runs need no flags. Waiting and asking need a
terminal — run from a script or CI and it reports the same problems and stops.

Every signature expires, and an expired one is invisible: the app is still on
the Home Screen, it just won't open. How long you get depends on the account — a
free Apple ID signs for seven days, a paid developer account for a year — so the
script reads the date out of the profile it just built and tells you, rather than
guessing. It writes that date down too, and if you come back after it has passed,
the first thing it says is that this run brings the app back.

## Remove it

```sh
./scripts/uninstall.sh
```

The reverse of the two above: it takes Scripty off a connected iPhone or iPad,
or off a booted simulator when none is plugged in. Without a build to ask, it
removes both names the installers use — the default `scripty.scripty` and the
`com.<team>.scripty` that `install.sh` remembers in `.scripty-install` — so it
works whichever one you ended up with.

```sh
./scripts/uninstall.sh --simulator            # a booted simulator, ignore devices
./scripts/uninstall.sh --device "Clint iPhone" # a device by name
./scripts/uninstall.sh --bundle-id com.you.scripty # one specific id
```

Whatever the app was keeping goes with it; reinstalling is the way back.

## Send it to someone else

```sh
./scripts/share.sh
```

That archives a Release build, signs it for distribution, and uploads it to
TestFlight. Testers install Apple's TestFlight app and tap Install — no Mac, no
Xcode, no cable. Processing on Apple's side takes a few minutes; after that you
add people under TestFlight in App Store Connect and they get an email invite.

```sh
./scripts/share.sh --no-upload   # build the .ipa into build/share, don't send it
./scripts/share.sh --ad-hoc      # .ipa for devices already registered to the team
./scripts/share.sh --build 42    # build number, otherwise a UTC timestamp
./scripts/share.sh --out DIR     # where the .ipa lands
```

This is the one path a free Apple ID cannot take: sharing needs a distribution
certificate, which only the paid Developer Program issues. Sending a build also
needs an App Store Connect API key — App Store Connect > Users and Access >
Integrations > App Store Connect API, create one with the App Manager role, and
keep the `.p8` it downloads once:

```sh
./scripts/share.sh --key ~/Downloads/AuthKey_XXXXXXXXXX.p8 --issuer ISSUER-UUID
```

Drop that file in `~/.appstoreconnect/private_keys/` and the script finds it on
its own; the issuer id can live in `SCRIPTY_ASC_ISSUER`. Two more things
App Store Connect insists on before a first upload: an app record for the bundle
id, and a build number it has not seen — hence the timestamp default.

`--ad-hoc` skips all of that and writes an `.ipa` you can hand over directly,
but it only installs on devices whose UDIDs are already registered at
developer.apple.com > Devices.

## Where it opens

Star a project in the sidebar and Scripty opens it on its own the next time it
starts, the way signing in to the web editor lands you on the same screenplay.
Star nothing and it opens on the list — with no request behind a launch, it
would rather ask than guess. A tap on the Home Screen menu outranks both, and
going back to the list stays there until the next launch. The choice itself is
[LaunchProject.swift](scripty/Models/LaunchProject.swift).

## The Home Screen menu

Press and hold the app icon and four entries come up:

| Entry              | Where it lands                                          |
| ------------------ | ------------------------------------------------------- |
| **Songs**          | The songs list of your default screenplay               |
| **Notes**          | The notes list of the same one                          |
| The last two screenplays you edited | That screenplay, open                   |

"Your default screenplay" is the one starred in the projects list; with none
starred it is whichever you edited last. The two named screenplays are
republished every time the list loads, so they follow your writing rather than
whatever was there on the day you installed it.

Four is the most iOS will show, which is why two screenplays are named and not
three. Songs and Notes are declared in
[Info.plist](scripty/Info.plist) so they are there on a fresh install; the rest
of the wiring is in [QuickAction.swift](scripty/Models/QuickAction.swift) and
[QuickActions.swift](scripty/State/QuickActions.swift). The demo names no
screenplays — its projects only exist while it is running, so an entry for one
could only ever fail — and signing out takes them back off.

## Siri, Spotlight and Shortcuts

Say "open my songs in Scripty", or start typing a screenplay's title into
Spotlight and open it from the result. Nothing to set up: the phrases and the
actions are registered by the app itself, and the Shortcuts app lists them under
**Scripty** the moment it is installed.

Seven phrases, said with the app's name in them:

| Say                                | You get                                       |
| ---------------------------------- | --------------------------------------------- |
| "Open Songs in Scripty"            | The songs of your starred screenplay          |
| "Open Notes in Scripty"            | The notes of the same one                     |
| "Open my screenplay in Scripty"    | That screenplay's script                      |
| "New note in Scripty"              | A note, with what you dictate already in it   |
| "New song in Scripty"              | A song, the same way                          |
| "Add a lyric in Scripty"           | A line on the end of a song you name          |
| "Add an action line in Scripty"    | A line on the end of a screenplay             |

None of the phrases takes a screenplay's title, on purpose: a phrase with an
entity in it makes Siri enumerate the picker while it is still matching, so what
it recognised would depend on which screenplays this device happened to have
cached. Naming one is what the Shortcuts app and Spotlight are for.

### Finding one

Two actions take a name rather than a phrase — **Open Screenplay** and **Open
Song or Note**. Both are searched rather than spoken: type part of a title into
the Shortcuts app's picker, or into Spotlight, where every screenplay, song and
note is a result that opens the thing it names.

Typing matches more loosely than saying does, and in a deliberate order. An
exact title wins outright, then a title that starts that way, then one with the
word in it, then one that merely contains the letters, and last of all a title
that has all of the words in some other order. So *Wake* beats *Wakefield* even
if *Wakefield* was written more recently, and *The Long Wake Up* beats
*Awakening*. Case and accents are folded throughout: *revolution* finds
*Révolution*.

The Shortcuts app also vends a **Find Screenplays** and a **Find Songs & Notes**
action, which the app writes no code for beyond saying what can be asked:

| Find Screenplays where | Find Songs & Notes where |
| --- | --- |
| Title contains / begins with / is | Title contains / begins with / is |
| Writers contains | Kind is (or is not) Song or Note |
| Last Edited before / after | Screenplay contains / is |
| Starred is true | Last Edited before / after |

Both sort by title or by when they were last edited, take a limit, and hand back
screenplays and documents whose own fields — title, writers, draft version, last
edited, starred — a later step can read.

Everything findable comes out of the same App Group snapshots the widgets draw
from, and for the same reason: an entity query is answered by a copy of the app
woken in the background, with no screen and often with no network, so asking the
server would mean a request that works at a desk and fails on the Tube. It also
means the same rules apply — the demo offers nothing, and signing out empties the
Spotlight index along with both widgets and the Home Screen menu.

The intents that only ask for a screen park the same request a tapped widget row
parks, so there is one arrival path rather than two, and the same routes are
reachable by hand from a shortcut you build yourself:

| Link | What it opens |
| --- | --- |
| `scripty://songs`, `scripty://notes` | Your starred screenplay's songs or notes |
| `scripty://project?id=…` | That screenplay; `scripty://project` for the list |
| `scripty://document?project=…&id=…&kind=…` | One song or note |

The pieces are in [scripty/Intents](scripty/Intents): the two entities the system
can name, search and index
([ScreenplayEntity.swift](scripty/Intents/ScreenplayEntity.swift),
[DocumentEntity.swift](scripty/Intents/DocumentEntity.swift)), the intents that
ask for a screen ([OpenIntents.swift](scripty/Intents/OpenIntents.swift)) and
those that write something
([CaptureIntents.swift](scripty/Intents/CaptureIntents.swift)), the spoken
phrases ([ScriptyAppShortcuts.swift](scripty/Intents/ScriptyAppShortcuts.swift)),
the Spotlight donation ([SpotlightIndex.swift](scripty/Intents/SpotlightIndex.swift)),
and one file deliberately free of the AppIntents framework so `Tests/AppIntents`
can check it without a simulator — the ranking, filtering and ordering behind
every one of the above
([IntentTargets.swift](scripty/Intents/IntentTargets.swift)).

**None of this can be verified in the Simulator.** Its App Intents metadata store
fails for Apple's own bundles too, so a control or a phrase that does nothing
there is telling you about the Simulator, not the app. Check on a device. What
the Simulator can still prove is that the intents shipped at all — they are
listed in `Metadata.appintents/extract.actionsdata` inside the built `.app`.

## The Home Screen widgets

Four of them, all shipped with the app rather than installed separately. Add
any of them the usual way: press and hold the Home Screen, **Edit → Add
Widget**, then search for **Scripty**. The gallery searches the *app's* name,
not the widget's, so searching "Screenplays" or "Bookmarks" finds nothing.

**Screenplays** lists what you have been working on, most recent first, and
tapping a row opens that screenplay. The starred one is marked with a star
wherever it happens to land — the widget answers "what have I been working on"
rather than "which is mine", so a draft you spent the week in comes first even
when another is starred.

**Songs** and **Notes** do the same for the songs and the notes inside those
screenplays, newest first across all of them, and tapping one opens that
document on the right list. Two widgets rather than one, so a wall of songs
cannot bury the notes: place either, both, or one of each at different sizes.

**Bookmarks** shows the lines you flagged while writing, and tapping one opens
that screenplay scrolled to that element — the same jump the outline sidebar
makes from inside the app. Its rows are grouped by screenplay rather than
individually sorted: they are sentences out of a script, and a run of them only
reads as anything in the order it was written. The most recently marked-up
screenplay leads, which is when it was *flagged*, not when it was last opened —
reading an old draft does not push aside the one you annotated this morning.
The server dates neither the element nor the flag, so that stamp is the app's
own.

| Size        | Screenplays     | Songs / Notes (each)         | Bookmarks         |
| ----------- | --------------- | ---------------------------- | ----------------- |
| Small       | The most recent | The one most recently edited | The most recent   |
| Medium      | Three           | Three                        | Two               |
| Large       | Six             | Six                          | Five              |
| Lock Screen | The most recent | The one most recently edited | The most recent   |

Bookmarks fits fewer per size on purpose: its rows are lines of dialogue and
action rather than titles, and a clipped sentence is worth less than a whole one.

A widget cannot sign in, and none of these tries. The app writes the handful of
rows each one draws into a shared App Group container — the projects list as it
loads, a screenplay's songs and notes as they settle, its flagged elements as
the script does — and the extensions only ever read them. So a row appears once
the app has seen it, the rows are there whether or not the phone has a
connection, and there is no second copy of the API client to keep honest. The
demo publishes nothing, for the same reason it names no screenplays in the Home
Screen menu, and signing out empties all three — the Home Screen keeps showing
whatever it was last given until this app takes it back, and nobody else can.
That last part matters most for Bookmarks, whose rows are not titles but the
script itself.

The pieces, in matching sets: [Shared/](Shared) holds the one file per set
that both its targets compile — Songs and Notes share theirs, being two views
of one stored list — and it is pure Foundation on purpose, so
`Tests/SongsNotesWidget`, `Tests/ProjectsWidget` and `Tests/BookmarksWidget` can
check the ordering, the merge and the deep-link URLs without a simulator.

| | Screenplays | Songs / Notes | Bookmarks |
| --- | --- | --- | --- |
| Shared | [ProjectsWidgetData.swift](Shared/ProjectsWidgetData.swift) | [SongsNotesWidgetData.swift](Shared/SongsNotesWidgetData.swift) | [BookmarksWidgetData.swift](Shared/BookmarksWidgetData.swift) |
| Extension | [ProjectsWidget.swift](ProjectsWidget/ProjectsWidget.swift) | [SongsNotesWidget.swift](SongsNotesWidget/SongsNotesWidget.swift) | [BookmarksWidget.swift](BookmarksWidget/BookmarksWidget.swift) |
| App's half | [ProjectsWidgetPublisher.swift](scripty/Widgets/ProjectsWidgetPublisher.swift) | [WidgetPublisher.swift](scripty/Widgets/WidgetPublisher.swift) | [BookmarksWidgetPublisher.swift](scripty/Widgets/BookmarksWidgetPublisher.swift) |
| Tapped row | `scripty://project?id=…` | `scripty://document?project=…&id=…&kind=…` | `scripty://bookmark?project=…&block=…` |

All three URLs are read in [scriptyApp.swift](scripty/scriptyApp.swift). A
tapped screenplay becomes the same pending request a long-press menu entry
makes; a tapped song carries a document as well, and a tapped bookmark an
element, so each of those gets a request of its own. A bookmark's element is
handed to the script view, which scrolls to it once the script has actually
arrived — an element deleted since it was flagged is simply never found, and the
screenplay opens where it otherwise would.

The App Group is `group.scripty.scripty`, named once in each widget's store and
spelled out in **eight** entitlements files — one iOS and one Catalyst for each
of the four targets. They all have to agree; a mismatch builds cleanly and shows
up only as a widget that is permanently empty.

The two platforms spell the same group differently, which is why there are two
files per target rather than one: iOS grants it plain, macOS grants it with the
team prefix, as `TEAMID.group.scripty.scripty`, and a container opens only under
the exact string its entitlement granted. `CODE_SIGN_ENTITLEMENTS[sdk=macosx*]`
picks the Catalyst set, every target carries `TeamIdentifierPrefix` in its
Info.plist so the prefix can be read back at runtime, and each store asks for
the plain spelling first and the prefixed one only if that fails. Nothing has to
know which platform it is on.

**Mac Catalyst is untried.** The code is there and the entitlements are there,
but it has not been run on a Mac. If it is wrong, the app publishes into a
container the widgets cannot open and they show their empty state — nothing else
breaks.

Two things worth knowing if you are changing any of this. Xcode's automatic
signing registers the group against your App ID the first time it signs the app
for a device, so the first device build after pulling this needs a signing team
selected. And an extension built with `CODE_SIGNING_ALLOWED=NO` embeds fine,
runs fine, and never appears in the gallery at all — so a quick unsigned
simulator build is not a test of anything. That applies to the Control Center
gallery below as well.

The Screenplays tile can be configured: it leads with the starred draft or with
whatever was edited last. The option filters what the app already published,
because the extensions cannot fetch anything of their own — which is also why no
widget offers a screenplay picker. The app writes songs and notes only for the
screenplay whose script has been opened, so a tile pinned to any other one would
be permanently empty with no honest way to say why. Songs and Notes have nothing
left to configure: choosing between them is done in the gallery, by placing the
one you meant — or both, at different sizes.

Each widget's `kind` string is load-bearing across an app update: iOS finds an
already-placed widget by it. `SongsWidget` and `NotesWidget` replaced the single
`SongsNotesWidget` kind the two once shared, and WidgetKit offers no way to
rename a kind — a tile placed under the old combined widget has nothing left in
the bundle to draw it, is dropped by the system, and has to be placed again.

## Siri, Shortcuts and Control Center

[scripty/Intents/](scripty/Intents) holds seven App Intents, and
[ScriptyAppShortcuts.swift](scripty/Intents/ScriptyAppShortcuts.swift) gives
each one Siri phrases and a Spotlight entry.

| | Does | Rides |
| --- | --- | --- |
| Open Songs / Notes / Screenplay | Parks a request and returns | The same pending machinery a widget row uses |
| New Note / New Song | One `documents` POST, content inline | `ScriptModel.createDocument` |
| Add Lyric Line | One `songBlocks` POST | `SongBlockModel.appendLine(content:)` |
| Add Screenplay Element | One `blocks` POST | `ScriptModel.createBlock` |

Nothing here needed a new HAL rel, and nothing here should grow one — an intent
that could do something the app itself cannot is a second idea of what the
product is.

**Every intent lives in the app target, and that is a design decision rather
than an accident.** They are all `openAppWhenRun`, so `perform()` runs in the
app's own process, where `APIClient` and the Keychain already work — the
keychain item has no access group and no extension has a network entitlement, so
an intent running out of process would have neither credentials nor a route to
the server. The Control Center tiles in
[ScriptyControls.swift](SongsNotesWidget/ScriptyControls.swift) are what makes
that possible: they carry a `scripty://` URL through the system's own
`OpenURLIntent`, so no custom intent type has to compile inside an extension.
Those tiles ride in the Songs & Notes widget bundle for the same reason there is
no fourth target — a `ControlWidget` is a `Widget`, hosted by the same extension
point.

The screenplay picker in the Shortcuts app reads the Screenplays widget's App
Group snapshot rather than the server, so it answers instantly and offline. It
is empty in the demo and when signed out, both deliberately.

**The Simulator cannot verify a control's final hop.** The tiles register, list
in the Control Center gallery and hand the right `scripty://` URL to the system,
but the app never comes forward, and the log says why:

```
linkd: Missing: scripty.scripty:OpenURLIntent
       Bundle scripty.scripty exists, action OpenURLIntent is missing
```

That is not this app's bug. Apple's own Reminders control fails identically in
the same simulator (`Missing: com.apple.reminders:CreateQuickReminderIntent`),
and `linkd` cannot extract metadata for several Apple bundles there at all. The
Simulator's App Intents metadata store is simply broken; **anything to do with
running an intent has to be checked on a device.**

On a device it all works: Spotlight lists the App Shortcuts, a required
parameter prompts for its value, `openAppWhenRun` brings the app to the front,
and the Screenplays widget offers its setting under "Edit Widget".

**`Tests/run.sh` cannot compile anything that imports AppIntents**, so
`ci_scripts/ci_post_clone.sh` will not catch an intents regression. The
mitigation is the one `QuickAction` already embodies: every decision lives in a
pure file — `ScriptyLink` and the widget filters in [Shared/](Shared),
[IntentRouting.swift](scripty/Models/IntentRouting.swift) and
[QuickAction.swift](scripty/Models/QuickAction.swift) beside it — and the
AppIntents types are adapters with no branches in them.

## Which server it talks to

By default the app uses the hosted backend in
[AppConfig.swift](scripty/API/AppConfig.swift). To point a build at a server you
are running yourself, set the `scripty.baseURLOverride` user default — for the
simulator:

```sh
xcrun simctl spawn booted defaults write scripty.scripty \
    scripty.baseURLOverride "http://localhost:8080"
```

The offline demo bypasses the network entirely, and is also where a launch with
no stored account lands: the app opens on a workspace rather than a login wall,
and **Sign In** — in the sidebar menu, or on the banner above the project list —
attaches an account when the writer wants one. Whatever they wrote first is
offered to that account straight afterwards, as one `.scripty.json` bundle
through the same import the projects list already has; anything they leave
unticked goes when the app quits, as everything local does. Signing out comes
back here rather than to a login screen.

`demo.sh` always starts here and `install.sh --demo` does too; on an installed
copy the `scripty://demo` URL does the same, so a Home Screen shortcut can jump
straight into it.

### Deploy the server before you install

Two features are claims on the server's domain rather than settings in the app:
passkeys, and the password reset link that opens the app instead of a browser.
iOS believes a claim only after fetching
`/.well-known/apple-app-site-association` from that domain, and it does that
when the app is installed — so **the server has to be serving the claim before
the install, not after**.

Get the order wrong and nothing reports an error. Passkeys are simply never
offered, and a reset link opens the web page instead of the app; both look like
the feature was never built. The fix is to deploy the server, then reinstall the
app — a relaunch is not enough. A build pointed at a `baseURLOverride` has
neither, since the claim names the hosted domain.

## Tests

```sh
./Tests/run.sh
```

The parts of the client that are pure Swift — the stats and pagination
arithmetic, and the demo backend's HAL contract — compile straight from the
app's sources with `swiftc`. There is no XCTest target, so a build's Test action
has nothing to run; this script is what CI exercises, via
[ci_scripts/ci_post_clone.sh](ci_scripts/ci_post_clone.sh) on Xcode Cloud.
Anything that needs a running app is out of scope here — use `demo.sh` for that.

## Where things live

| Path            | What's in it                                            |
| --------------- | ------------------------------------------------------- |
| `scripty/API`   | HTTP client, config, keychain-backed credentials        |
| `scripty/HAL`   | Link and collection decoding, the `scripty:*` rel names |
| `scripty/Demo`  | The in-memory backend behind the offline demo           |
| `scripty/Models`| Screenplay blocks, pagination, stats                    |
| `scripty/Views` | The editor and everything around it                     |
| `scripty/Widgets`| The app's half of the Home Screen widgets              |
| `Shared`        | The files the app and each widget extension share       |
| `ProjectsWidget`| The Screenplays widget extension                        |
| `SongsNotesWidget`| The Songs & Notes widget extension                     |
| `BookmarksWidget`| The Bookmarks widget extension                         |
