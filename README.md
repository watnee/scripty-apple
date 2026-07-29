# Scripty for iPhone and iPad

A SwiftUI client for Scripty, the screenplay editor. It talks to the same HAL
API the web app does, and it ships with an offline demo so you can see the
whole editor without an account or a server.

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
**Install on iPhone or iPad.command** (build a signed copy and put it on a
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

If you would rather not open a terminal, double-click **Install on iPhone or
iPad.command** at the top of the project instead — it runs this same path (Xcode
check included) in a Terminal window Finder opens for you.

```sh
./scripts/install.sh --list                      # show paired devices
./scripts/install.sh --device "Clint iPhone"     # skip the question when several
./scripts/install.sh --team ABCDE12345           # if you have more than one team
./scripts/install.sh --bundle-id com.you.scripty # a name of your choosing
./scripts/install.sh --demo                      # start in the offline demo
./scripts/install.sh --no-launch                 # install without launching
./scripts/install.sh --forget                    # drop the remembered answers
```

Unlike the simulator, a real device insists the app be signed. A free Apple ID
is enough. Four things commonly stand in the way, and the script handles three
of them while you watch rather than leaving you in the build log:

- **Developer Mode is off.** It says so and waits: Settings > Privacy &
  Security > Developer Mode on the device, then restart it.
- **The bundle id is taken.** The default is `scripty.scripty`, which is
  registered to this project's team, so the first build by anyone else fails.
  The script then names the app after your team — `com.<teamid>.scripty` — and
  builds again. Pass `--bundle-id` if you would rather choose.
- **The app installs but won't open.** A free Apple ID signs with a certificate
  the device does not trust until you say so: Settings > General > VPN & Device
  Management > tap your Apple ID > Trust. The script waits for that tap and
  starts the app once you've made it.
- **No certificate.** This one it cannot do for you: open Xcode > Settings >
  Accounts, add your Apple ID, let it create a development certificate, and
  rerun.

Your team, and the bundle id if it had to pick one, are remembered in
`.scripty-install` so later runs need no flags. Waiting and asking need a
terminal — run from a script or CI and it reports the same problems and stops.

Apps signed with a free Apple ID stop working after seven days — the app is
still on the Home Screen, it just won't open. Rerun `install.sh` to renew it;
it remembers when it last installed and, a week on, tells you up front that the
copy has likely expired and that this run brings it back.

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

| Ask for                    | You get                                          |
| -------------------------- | ------------------------------------------------ |
| "Open my songs in Scripty" | The songs of your default screenplay             |
| "Open my notes in Scripty" | The notes of the same one                        |
| "Open my screenplays in Scripty" | The projects list                          |
| "Open the Scripty demo"    | The offline demo, no account needed              |
| **Open Screenplay**        | A screenplay you name — also a Spotlight result  |
| **Open Song or Note**      | A song or note you name, in its screenplay       |

The last two take a name, so they are offered through the Shortcuts app's picker
and through Spotlight rather than as a fixed phrase — searching thirty titles is
something a search field does better than a sentence that has to guess the title
in advance.

Everything nameable comes out of the same App Group snapshots the widgets draw
from, and for the same reason: an entity query is answered by a copy of the app
woken in the background, with no screen and often with no network, so asking the
server would mean a request that works at a desk and fails on the Tube. It also
means the same rules apply — the demo offers nothing, and signing out empties the
Spotlight index along with both widgets and the Home Screen menu.

Each intent ends by handing back a `scripty://` link and letting the app's own
front door answer it, which is what the widgets have always done. So every one
of these is available to a shortcut you build by hand, using exactly the link
Siri uses:

| Link | What it opens |
| --- | --- |
| `scripty://songs`, `scripty://notes` | Your default screenplay's songs or notes |
| `scripty://project?id=…` | That screenplay; `scripty://project` for the list |
| `scripty://document?project=…&id=…&kind=…` | One song or note |
| `scripty://demo` | The offline demo |

The pieces are in [scripty/Intents](scripty/Intents): the entities Siri can name
([ScreenplayEntity.swift](scripty/Intents/ScreenplayEntity.swift),
[DocumentEntity.swift](scripty/Intents/DocumentEntity.swift)), the intents
themselves ([OpenIntents.swift](scripty/Intents/OpenIntents.swift)), the spoken
phrases ([ScriptyShortcuts.swift](scripty/Intents/ScriptyShortcuts.swift)), and
two files deliberately free of the AppIntents framework so `Tests/AppIntents` can
check them without a simulator — the links
([ShortcutLink.swift](scripty/Intents/ShortcutLink.swift)) and the name matching
([IntentTargets.swift](scripty/Intents/IntentTargets.swift)).

**None of this can be verified in the Simulator.** Its App Intents metadata store
fails for Apple's own bundles too, so a control or a phrase that does nothing
there is telling you about the Simulator, not the app. Check on a device. What
the Simulator can still prove is that the intents shipped at all — they are
listed in `Metadata.appintents/extract.actionsdata` inside the built `.app`.

## The Home Screen widgets

Two of them, both shipped with the app rather than installed separately. Add
either the usual way: press and hold the Home Screen, **Edit → Add Widget**,
then search for **Scripty**. The gallery searches the *app's* name, not the
widget's, so searching "Screenplays" or "Songs & Notes" finds nothing.

**Screenplays** lists what you have been working on, most recent first, and
tapping a row opens that screenplay. The starred one is marked with a star
wherever it happens to land — the widget answers "what have I been working on"
rather than "which is mine", so a draft you spent the week in comes first even
when another is starred.

**Songs & Notes** does the same for the songs and notes inside those
screenplays, newest first across all of them, and tapping one opens that
document on the right list.

| Size        | Screenplays              | Songs & Notes                |
| ----------- | ------------------------ | ---------------------------- |
| Small       | The most recent          | The one most recently edited |
| Medium      | Three                    | Three                        |
| Large       | Six                      | Six                          |
| Lock Screen | The most recent          | The one most recently edited |

A widget cannot sign in, and neither of these tries. The app writes the handful
of rows each one draws into a shared App Group container — the projects list as
it loads, a screenplay's songs and notes as they settle — and the extensions
only ever read them. So a row appears once the app has seen it, the rows are
there whether or not the phone has a connection, and there is no second copy of
the API client to keep honest. The demo publishes nothing, for the same reason
it names no screenplays in the Home Screen menu, and signing out empties both —
the Home Screen keeps showing whatever it was last given until this app takes it
back, and nobody else can.

The pieces, in matching pairs: [Shared/](Shared) holds the one file per widget
that both its targets compile, and it is pure Foundation on purpose, so
`Tests/SongsNotesWidget` and `Tests/ProjectsWidget` can check the ordering, the
merge and the deep-link URLs without a simulator.

| | Screenplays | Songs & Notes |
| --- | --- | --- |
| Shared | [ProjectsWidgetData.swift](Shared/ProjectsWidgetData.swift) | [SongsNotesWidgetData.swift](Shared/SongsNotesWidgetData.swift) |
| Extension | [ProjectsWidget.swift](ProjectsWidget/ProjectsWidget.swift) | [SongsNotesWidget.swift](SongsNotesWidget/SongsNotesWidget.swift) |
| App's half | [ProjectsWidgetPublisher.swift](scripty/Widgets/ProjectsWidgetPublisher.swift) | [WidgetPublisher.swift](scripty/Widgets/WidgetPublisher.swift) |
| Tapped row | `scripty://project?id=…` | `scripty://document?project=…&id=…&kind=…` |

Both URLs are read in [scriptyApp.swift](scripty/scriptyApp.swift). A tapped
screenplay becomes the same pending request a long-press menu entry makes; a
tapped song carries a document as well, so it gets a request of its own.

The App Group is `group.scripty.scripty`, named once in each widget's store and
spelled out in **six** entitlements files — one iOS and one Catalyst for each of
the three targets. They all have to agree; a mismatch builds cleanly and shows
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
simulator build is not a test of anything.

## Which server it talks to

By default the app uses the hosted backend in
[AppConfig.swift](scripty/API/AppConfig.swift). To point a build at a server you
are running yourself, set the `scripty.baseURLOverride` user default — for the
simulator:

```sh
xcrun simctl spawn booted defaults write scripty.scripty \
    scripty.baseURLOverride "http://localhost:8080"
```

The offline demo bypasses the network entirely. `demo.sh` always starts there
and `install.sh --demo` does too; on an installed copy the `scripty://demo` URL
does the same, so a Home Screen shortcut can jump straight into it.

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
| `scripty/Intents`| Siri, Spotlight and Shortcuts: entities, intents, links |
| `scripty/Widgets`| The app's half of both Home Screen widgets             |
| `Shared`        | The files the app and each widget extension share       |
| `ProjectsWidget`| The Screenplays widget extension                        |
| `SongsNotesWidget`| The Songs & Notes widget extension                     |
