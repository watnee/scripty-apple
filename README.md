# Scripty for iPhone and iPad

A SwiftUI client for Scripty, the screenplay editor. It talks to the same HAL
API the web app does, and it ships with an offline demo so you can see the
whole editor without an account or a server.

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

Plug the device in over USB, unlock it, tap Trust, and run that. It picks the
connected device, finds your signing team, builds, installs, and launches.

```sh
./scripts/install.sh --list                      # show paired devices
./scripts/install.sh --device "Clint iPhone"     # if more than one is plugged in
./scripts/install.sh --team ABCDE12345           # if you have more than one team
./scripts/install.sh --bundle-id com.you.scripty # if the default is taken
./scripts/install.sh --demo                      # start in the offline demo
./scripts/install.sh --no-launch                 # install without launching
```

Unlike the simulator, a real device insists the app be signed. A free Apple ID
is enough. Four things commonly stand in the way, and the script says so in
words rather than leaving you in the build log:

- **No certificate.** Open Xcode > Settings > Accounts, add your Apple ID, and
  let it create a development certificate. Then rerun.
- **Developer Mode is off.** Settings > Privacy & Security > Developer Mode on
  the device, then restart it.
- **The bundle id is taken.** The default is `scripty.scripty`, which is
  registered to this project's team. Anyone else needs their own:
  `--bundle-id com.yourname.scripty`.
- **The app installs but won't open.** A free Apple ID signs with a certificate
  the device does not trust until you say so: Settings > General > VPN & Device
  Management > tap your Apple ID > Trust.

Apps signed with a free Apple ID stop working after seven days. Rerun
`install.sh` to renew them.

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
