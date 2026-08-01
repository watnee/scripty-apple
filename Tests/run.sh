#!/bin/bash
#
# Logic checks for the parts of the client that are pure Swift: the ported
# stats/outline arithmetic and the demo backend's HAL contract.
#
# These compile the app's own sources directly with swiftc — there is no Xcode
# test target, so nothing here touches project.pbxproj. Anything needing UIKit
# or a running app is out of scope; use scripts/demo.sh for that.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/scripty"
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT

SHARED=(
    "$SRC/HAL/HALLink.swift"
    "$SRC/HAL/HALCollection.swift"
    "$SRC/HAL/Rel.swift"
)

# Match the app's build settings (SWIFT_VERSION = 5.0, SWIFT_DEFAULT_ACTOR_ISOLATION
# = MainActor, SWIFT_APPROACHABLE_CONCURRENCY = YES): without these, the same
# sources compile under a *different* actor-isolation default here than in the
# product, so the checks could pass against semantics the app doesn't have.
FLAGS=(
    -swift-version 5
    -default-isolation MainActor
    -enable-upcoming-feature NonisolatedNonsendingByDefault
    -enable-upcoming-feature InferIsolatedConformances
)

status=0

# Every suite here is arithmetic, in-process fakes, or requests to a closed
# port: milliseconds of work. So anything still running after the limit is
# stuck, not slow, and the only useful thing to do is say so and move on —
# a suite that blocks forever otherwise takes the whole run with it, silently,
# and nothing here has a timeout of its own.
#
# Override with SCRIPTY_TEST_TIMEOUT if a machine is genuinely that slow.
SUITE_TIMEOUT="${SCRIPTY_TEST_TIMEOUT:-60}"

# Blocks on `wait`, never on `kill -0`: a suite that has exited but has not
# been reaped yet is still a live pid as far as `kill -0` is concerned, so
# polling it that way reports a suite that passed in milliseconds as a hang.
# The watchdog runs alongside instead, and stands down the moment the suite
# lands — the marker file is what tells it so.
run_suite() {
    local binary="$1"
    local finished="$BUILD/.finished"
    rm -f "$finished"

    "$binary" &
    local pid=$!
    (
        deadline=$((SECONDS + SUITE_TIMEOUT))
        while [ "$SECONDS" -lt "$deadline" ] && [ ! -e "$finished" ]; do
            sleep 0.2
        done
        if [ ! -e "$finished" ]; then
            echo "  TIMEOUT  no result after ${SUITE_TIMEOUT}s — killed $(basename "$binary")"
            kill -9 "$pid" 2>/dev/null || true
        fi
    ) &
    local watchdog=$!
    # Off the jobs table, or the shell announces its own watchdog's death in
    # a wall of "Terminated: 15 ( deadline=... )" after every single suite.
    disown "$watchdog" 2>/dev/null || true

    local result=0
    wait "$pid" || result=$?
    # Marker first, and left in place: once it exists the watchdog cannot
    # accuse a suite that has already landed, however late the kill reaches
    # it. The next call clears it, and the BUILD trap takes the last one.
    touch "$finished"
    kill "$watchdog" 2>/dev/null || true
    return "$result"
}

echo "== ScriptStats / ScriptOutline =="
swiftc "${FLAGS[@]}" -o "$BUILD/stats" \
    "$SRC/Models/Block.swift" \
    "$SRC/Models/ScriptStats.swift" \
    "$SRC/Models/ScriptOutline.swift" \
    "${SHARED[@]}" \
    "$ROOT/Tests/ScriptStats/main.swift"
run_suite "$BUILD/stats" || status=1

echo
echo "== Screenplay pagination =="
swiftc "${FLAGS[@]}" -o "$BUILD/pagination" \
    "$SRC/Models/Block.swift" \
    "$SRC/Models/ScreenplayLayout.swift" \
    "$SRC/Models/PageSetup.swift" \
    "$SRC/Models/ScriptPagination.swift" \
    "${SHARED[@]}" \
    "$ROOT/Tests/Pagination/main.swift"
run_suite "$BUILD/pagination" || status=1

echo
echo "== Offline print PDF =="
# Core Text and Core Graphics, not UIKit, so the renderer the offline print
# fallback draws with stays checkable here. ScriptTypeface imports SwiftUI for
# the sheet view's font type; only its names and ratios are used in this suite.
swiftc "${FLAGS[@]}" -o "$BUILD/printpdf" \
    "$SRC/Models/Block.swift" \
    "$SRC/Models/Project.swift" \
    "$SRC/Models/ScreenplayLayout.swift" \
    "$SRC/Models/PageSetup.swift" \
    "$SRC/Models/ScriptPagination.swift" \
    "$SRC/Models/ScreenplayCover.swift" \
    "$SRC/Models/ScriptTypeface.swift" \
    "$SRC/Models/ScreenplayPDF.swift" \
    "${SHARED[@]}" \
    "$ROOT/Tests/Print/main.swift"
run_suite "$BUILD/printpdf" || status=1

echo
echo "== Element clipboard =="
swiftc "${FLAGS[@]}" -o "$BUILD/clipboard" \
    "$SRC/Models/Block.swift" \
    "$SRC/Models/ScriptClipboard.swift" \
    "$SRC/Models/FountainDetect.swift" \
    "${SHARED[@]}" \
    "$ROOT/Tests/Clipboard/main.swift"
run_suite "$BUILD/clipboard" || status=1

echo
echo "== Fountain detection =="
swiftc "${FLAGS[@]}" -o "$BUILD/fountain" \
    "$SRC/Models/Block.swift" \
    "$SRC/Models/ScriptClipboard.swift" \
    "$SRC/Models/FountainDetect.swift" \
    "${SHARED[@]}" \
    "$ROOT/Tests/FountainDetect/main.swift"
run_suite "$BUILD/fountain" || status=1

echo
echo "== Read-aloud narration =="
swiftc "${FLAGS[@]}" -o "$BUILD/narration" \
    "$SRC/Models/Block.swift" \
    "$SRC/Models/ScriptNarration.swift" \
    "${SHARED[@]}" \
    "$ROOT/Tests/Narration/main.swift"
run_suite "$BUILD/narration" || status=1

echo
echo "== Reading a picked file =="
# Foundation only: the coordinated read itself needs a Files provider to have
# anything to coordinate with, so what is checked here is the shape around it —
# the bytes, the MIME types the server sorts formats by, and the failure message
# keeping the system's reason instead of swallowing it.
swiftc "${FLAGS[@]}" -o "$BUILD/pickedfile" \
    "$SRC/Models/PickedFile.swift" \
    "$ROOT/Tests/PickedFile/main.swift"
run_suite "$BUILD/pickedfile" || status=1

echo
echo "== Note formatting =="
swiftc "${FLAGS[@]}" -o "$BUILD/notes" \
    "$SRC/Models/NoteFormatting.swift" \
    "$ROOT/Tests/NoteFormatting/main.swift"
run_suite "$BUILD/notes" || status=1

echo
echo "== A note as the reader sees it =="
swiftc "${FLAGS[@]}" -o "$BUILD/notereading" \
    "$SRC/Models/NoteFormatting.swift" \
    "$SRC/Models/NoteReading.swift" \
    "$ROOT/Tests/NoteReading/main.swift"
run_suite "$BUILD/notereading" || status=1

echo
echo "== Note undo/redo =="
swiftc "${FLAGS[@]}" -o "$BUILD/notehistory" \
    "$SRC/State/NoteHistory.swift" \
    "$ROOT/Tests/NoteHistory/main.swift"
run_suite "$BUILD/notehistory" || status=1

echo
echo "== Password reset links =="
swiftc "${FLAGS[@]}" -o "$BUILD/passwordreset" \
    "$SRC/API/PasswordResetLink.swift" \
    "$ROOT/Tests/PasswordReset/main.swift"
run_suite "$BUILD/passwordreset" || status=1

echo
echo "== Autocomplete =="
swiftc "${FLAGS[@]}" -o "$BUILD/suggestions" \
    "$SRC/Models/Block.swift" \
    "$SRC/Models/Person.swift" \
    "$SRC/Models/ScriptSuggestions.swift" \
    "${SHARED[@]}" \
    "$ROOT/Tests/Suggestions/main.swift"
run_suite "$BUILD/suggestions" || status=1

echo
echo "== Script view options =="
swiftc "${FLAGS[@]}" -o "$BUILD/viewoptions" \
    "$SRC/State/ScriptViewOptions.swift" \
    "$SRC/State/DocumentViewOptions.swift" \
    "$SRC/State/LastOpenedProject.swift" \
    "$SRC/State/SongWorkspaceOpenState.swift" \
    "$ROOT/Tests/ViewOptions/main.swift"
run_suite "$BUILD/viewoptions" || status=1

echo
echo "== Dismissed notices =="
swiftc "${FLAGS[@]}" -o "$BUILD/notices" \
    "$SRC/State/DismissedNotices.swift" \
    "$ROOT/Tests/Notices/main.swift"
run_suite "$BUILD/notices" || status=1

echo
echo "== Reopening what was left open =="
swiftc "${FLAGS[@]}" -o "$BUILD/editorstate" \
    "$SRC/State/OpenEditorState.swift" \
    "$SRC/Models/TextDocument.swift" \
    "${SHARED[@]}" \
    "$ROOT/Tests/EditorState/main.swift"
"$BUILD/editorstate" || status=1

echo
echo "== Presentation / appearance settings =="
swiftc "${FLAGS[@]}" -o "$BUILD/viewsettings" \
    "$SRC/State/PresentationSettings.swift" \
    "$SRC/State/AppearanceSettings.swift" \
    "$SRC/Models/ScriptTypeface.swift" \
    "$SRC/State/SpellcheckDictionary.swift" \
    "$SRC/Models/SpellcheckWord.swift" \
    "$SRC/Models/PageSetup.swift" \
    "$SRC/Models/ScreenplayLayout.swift" \
    "$SRC/Models/Block.swift" \
    "${SHARED[@]}" \
    "$ROOT/Tests/ViewSettings/main.swift"
run_suite "$BUILD/viewsettings" || status=1

echo
echo "== Where a document opens =="
swiftc "${FLAGS[@]}" -o "$BUILD/readingview" \
    "$SRC/State/ReadingViewSettings.swift" \
    "$ROOT/Tests/ReadingView/main.swift"
run_suite "$BUILD/readingview" || status=1

echo
echo "== Search and selection =="
swiftc "${FLAGS[@]}" -o "$BUILD/statelogic" \
    "$SRC/Models/Block.swift" \
    "$SRC/State/ScriptSearchModel.swift" \
    "$SRC/State/BlockSelectionModel.swift" \
    "${SHARED[@]}" \
    "$ROOT/Tests/StateLogic/main.swift"
run_suite "$BUILD/statelogic" || status=1

echo
echo "== Passkey ceremony wire formats =="
swiftc "${FLAGS[@]}" -o "$BUILD/passkeys" \
    "$SRC/API/Credentials.swift" \
    "$SRC/Models/PasskeyCeremony.swift" \
    "${SHARED[@]}" \
    "$ROOT/Tests/Passkeys/main.swift"
run_suite "$BUILD/passkeys" || status=1

echo
echo "== Home Screen quick actions =="
# QuickAction itself, not QuickActions.swift next door: the routing is pure
# Swift and belongs here, while the half that talks to UIApplication does not
# compile outside an app.
#
# IntentRouting rides along, with ScriptyLink from the shared widget file it
# reads its routes out of. A Control Center button arrives as a URL rather than
# a shortcut item, but what it resolves to is a QuickAction like any other, and
# checking the two apart would only make it easier for them to disagree.
swiftc "${FLAGS[@]}" -o "$BUILD/quickactions" \
    "$SRC/Models/Project.swift" \
    "$SRC/Models/TextDocument.swift" \
    "$SRC/Models/QuickAction.swift" \
    "$SRC/Models/IntentRouting.swift" \
    "$ROOT/Shared/SongsNotesWidgetData.swift" \
    "${SHARED[@]}" \
    "$ROOT/Tests/QuickActions/main.swift"
run_suite "$BUILD/quickactions" || status=1

echo
echo "== What a launch opens =="
swiftc "${FLAGS[@]}" -o "$BUILD/launchproject" \
    "$SRC/Models/Project.swift" \
    "$SRC/Models/LaunchProject.swift" \
    "${SHARED[@]}" \
    "$ROOT/Tests/LaunchProject/main.swift"
"$BUILD/launchproject" || status=1

echo
echo "== Song and note shortcuts =="
swiftc "${FLAGS[@]}" -o "$BUILD/songshortcuts" \
    "$SRC/Models/TextDocument.swift" \
    "$SRC/Models/DocumentsRequest.swift" \
    "${SHARED[@]}" \
    "$ROOT/Tests/SongShortcuts/main.swift"
run_suite "$BUILD/songshortcuts" || status=1

echo
echo "== Folding a lyric line into the one above =="
# Driven against the in-process demo backend rather than a stub, so the PUT,
# the DELETE and the reload that follows them all really happen.
swiftc "${FLAGS[@]}" -o "$BUILD/songlines" \
    "$SRC/API/APIClient.swift" \
    "$SRC/API/APIError.swift" \
    "$SRC/API/AppConfig.swift" \
    "$SRC/API/Credentials.swift" \
    "$SRC/API/KeychainStore.swift" \
    "$SRC/Demo/DemoBackend.swift" \
    "$SRC/Demo/LocalWorkspaceStore.swift" \
    "$SRC/Demo/DemoMusicXml.swift" \
    "$SRC/State/AppModel.swift" \
    "$ROOT/Shared/SongsNotesWidgetData.swift" \
    "$ROOT/Shared/BookmarksWidgetData.swift" \
    "$SRC/State/ScriptModel.swift" \
    "$SRC/State/LocalHistory.swift" \
    "$SRC/State/OfflineBlockQueue.swift" \
    "$SRC/State/SongBlockModel.swift" \
    "$SRC/State/UnsavedDraftStore.swift" \
    "$SRC/State/UnsavedDocumentStore.swift" \
    "$SRC/State/OfflineStore.swift" \
    "$SRC/State/ConnectivityMonitor.swift" \
    "$SRC/State/PresentationSettings.swift" \
    "$SRC/State/CapitalizationSettings.swift" \
    "$SRC/Models/"*.swift \
    "${SHARED[@]}" \
    "$ROOT/Tests/SongLines/main.swift"
"$BUILD/songlines" || status=1

echo
echo "== Song drafts survive a failed save =="
# The same closed-port failures the UnsavedWork suite drives, aimed at the
# lyric editor: held words, drafts on disk, restore on relaunch.
swiftc "${FLAGS[@]}" -o "$BUILD/songdrafts" \
    "$SRC/API/APIClient.swift" \
    "$SRC/API/APIError.swift" \
    "$SRC/API/AppConfig.swift" \
    "$SRC/API/Credentials.swift" \
    "$SRC/API/KeychainStore.swift" \
    "$SRC/Demo/DemoBackend.swift" \
    "$SRC/Demo/LocalWorkspaceStore.swift" \
    "$SRC/Demo/DemoMusicXml.swift" \
    "$SRC/State/AppModel.swift" \
    "$ROOT/Shared/SongsNotesWidgetData.swift" \
    "$ROOT/Shared/BookmarksWidgetData.swift" \
    "$SRC/State/ScriptModel.swift" \
    "$SRC/State/LocalHistory.swift" \
    "$SRC/State/OfflineBlockQueue.swift" \
    "$SRC/State/SongBlockModel.swift" \
    "$SRC/State/UnsavedDraftStore.swift" \
    "$SRC/State/UnsavedDocumentStore.swift" \
    "$SRC/State/OfflineStore.swift" \
    "$SRC/State/ConnectivityMonitor.swift" \
    "$SRC/State/PresentationSettings.swift" \
    "$SRC/State/CapitalizationSettings.swift" \
    "$SRC/Models/"*.swift \
    "${SHARED[@]}" \
    "$ROOT/Tests/SongDrafts/main.swift"
run_suite "$BUILD/songdrafts" || status=1

echo
echo "== Undo and redo in a lyric, on both sides of the connection =="
# Both halves in one suite: the offline steps are driven with the connectivity
# monitor held down by hand (no socket at all), and the server round trip runs
# against the in-process demo backend, which keeps a real per-edition stack.
swiftc "${FLAGS[@]}" -o "$BUILD/songhistory" \
    "$SRC/API/APIClient.swift" \
    "$SRC/API/APIError.swift" \
    "$SRC/API/AppConfig.swift" \
    "$SRC/API/Credentials.swift" \
    "$SRC/API/KeychainStore.swift" \
    "$SRC/Demo/DemoBackend.swift" \
    "$SRC/Demo/LocalWorkspaceStore.swift" \
    "$SRC/Demo/DemoMusicXml.swift" \
    "$SRC/State/AppModel.swift" \
    "$ROOT/Shared/SongsNotesWidgetData.swift" \
    "$ROOT/Shared/BookmarksWidgetData.swift" \
    "$SRC/State/ScriptModel.swift" \
    "$SRC/State/LocalHistory.swift" \
    "$SRC/State/OfflineBlockQueue.swift" \
    "$SRC/State/SongBlockModel.swift" \
    "$SRC/State/UnsavedDraftStore.swift" \
    "$SRC/State/UnsavedDocumentStore.swift" \
    "$SRC/State/OfflineStore.swift" \
    "$SRC/State/ConnectivityMonitor.swift" \
    "$SRC/State/PresentationSettings.swift" \
    "$SRC/State/CapitalizationSettings.swift" \
    "$SRC/Models/"*.swift \
    "${SHARED[@]}" \
    "$ROOT/Tests/SongHistory/main.swift"
run_suite "$BUILD/songhistory" || status=1

echo
echo "== Songs and Notes widgets =="
# The half the extension and the app share — one file for both widgets, since
# they draw one stored list. WidgetPublisher next door is not here: it imports
# WidgetKit and only exists to call these.
swiftc "${FLAGS[@]}" -o "$BUILD/widget" \
    "$ROOT/Shared/SongsNotesWidgetData.swift" \
    "$ROOT/Tests/SongsNotesWidget/main.swift"
"$BUILD/widget" || status=1

echo
echo "== Home Screen projects widget =="
# The same arrangement for the other widget: pure Foundation on purpose, so
# what the extension draws can be checked without a simulator to draw it in.
swiftc "${FLAGS[@]}" -o "$BUILD/projectswidget" \
    "$ROOT/Shared/ProjectsWidgetData.swift" \
    "$ROOT/Tests/ProjectsWidget/main.swift"
"$BUILD/projectswidget" || status=1
echo "== Songs & notes ordering =="
swiftc "${FLAGS[@]}" -o "$BUILD/documentorder" \
    "$SRC/Models/TextDocument.swift" \
    "${SHARED[@]}" \
    "$ROOT/Tests/DocumentOrder/main.swift"
"$BUILD/documentorder" || status=1

echo
echo "== Home Screen bookmarks widget =="
# And again for the third. This one carries rows from several screenplays at
# once, so the merge matters as much as the ordering does.
swiftc "${FLAGS[@]}" -o "$BUILD/bookmarkswidget" \
    "$ROOT/Shared/BookmarksWidgetData.swift" \
    "$ROOT/Tests/BookmarksWidget/main.swift"
"$BUILD/bookmarkswidget" || status=1

echo
echo "== Demo backend API contract =="
swiftc "${FLAGS[@]}" -o "$BUILD/api" \
    "$SRC/Demo/DemoBackend.swift" \
    "$SRC/Demo/LocalWorkspaceStore.swift" \
    "$SRC/Demo/DemoMusicXml.swift" \
    "$SRC/API/APIClient.swift" \
    "$SRC/API/APIError.swift" \
    "$SRC/API/AppConfig.swift" \
    "$SRC/API/Credentials.swift" \
    "$SRC/Models/"*.swift \
    "$ROOT/Shared/SongsNotesWidgetData.swift" \
    "${SHARED[@]}" \
    "$ROOT/Tests/APIContract/main.swift"
run_suite "$BUILD/api" || status=1

echo
echo "== The signed-out workspace survives a relaunch =="
swiftc "${FLAGS[@]}" -o "$BUILD/localworkspace" \
    "$SRC/Demo/DemoBackend.swift" \
    "$SRC/Demo/LocalWorkspaceStore.swift" \
    "$SRC/Demo/DemoMusicXml.swift" \
    "$SRC/API/APIClient.swift" \
    "$SRC/API/APIError.swift" \
    "$SRC/API/AppConfig.swift" \
    "$SRC/API/Credentials.swift" \
    "$SRC/Models/"*.swift \
    "$ROOT/Shared/SongsNotesWidgetData.swift" \
    "${SHARED[@]}" \
    "$ROOT/Tests/LocalWorkspace/main.swift"
run_suite "$BUILD/localworkspace" || status=1

echo
echo "== Unsaved work survives a failed save =="
swiftc "${FLAGS[@]}" -o "$BUILD/unsaved" \
    "$SRC/API/APIClient.swift" \
    "$SRC/API/APIError.swift" \
    "$SRC/API/AppConfig.swift" \
    "$SRC/API/Credentials.swift" \
    "$SRC/API/KeychainStore.swift" \
    "$SRC/Demo/DemoBackend.swift" \
    "$SRC/Demo/LocalWorkspaceStore.swift" \
    "$SRC/Demo/DemoMusicXml.swift" \
    "$SRC/State/AppModel.swift" \
    "$ROOT/Shared/SongsNotesWidgetData.swift" \
    "$ROOT/Shared/BookmarksWidgetData.swift" \
    "$SRC/State/ScriptModel.swift" \
    "$SRC/State/LocalHistory.swift" \
    "$SRC/State/UnsavedDraftStore.swift" \
    "$SRC/State/UnsavedDocumentStore.swift" \
    "$SRC/State/OfflineStore.swift" \
    "$SRC/State/OfflineBlockQueue.swift" \
    "$SRC/State/ConnectivityMonitor.swift" \
    "$SRC/State/PresentationSettings.swift" \
    "$SRC/State/CapitalizationSettings.swift" \
    "$SRC/Models/"*.swift \
    "${SHARED[@]}" \
    "$ROOT/Tests/UnsavedWork/main.swift"
run_suite "$BUILD/unsaved" || status=1

echo
echo "== Offline: cached copies, fast failure, reconnect =="
swiftc "${FLAGS[@]}" -o "$BUILD/offline" \
    "$SRC/API/APIClient.swift" \
    "$SRC/API/APIError.swift" \
    "$SRC/API/AppConfig.swift" \
    "$SRC/API/Credentials.swift" \
    "$SRC/API/KeychainStore.swift" \
    "$SRC/Demo/DemoBackend.swift" \
    "$SRC/Demo/LocalWorkspaceStore.swift" \
    "$SRC/Demo/DemoMusicXml.swift" \
    "$SRC/State/AppModel.swift" \
    "$ROOT/Shared/SongsNotesWidgetData.swift" \
    "$ROOT/Shared/BookmarksWidgetData.swift" \
    "$SRC/State/ScriptModel.swift" \
    "$SRC/State/LocalHistory.swift" \
    "$SRC/State/UnsavedDraftStore.swift" \
    "$SRC/State/UnsavedDocumentStore.swift" \
    "$SRC/State/OfflineStore.swift" \
    "$SRC/State/OfflineBlockQueue.swift" \
    "$SRC/State/ConnectivityMonitor.swift" \
    "$SRC/State/PresentationSettings.swift" \
    "$SRC/State/CapitalizationSettings.swift" \
    "$SRC/Models/"*.swift \
    "${SHARED[@]}" \
    "$ROOT/Tests/Offline/main.swift"
run_suite "$BUILD/offline" || status=1

echo
echo "== A new screenplay opens ready to type into =="
# The live cases drive the in-process demo backend, so the seeding POST really
# goes out; the last one drives a closed port, so the failure it must not seed
# over is a real one.
swiftc "${FLAGS[@]}" -o "$BUILD/firstelement" \
    "$SRC/API/APIClient.swift" \
    "$SRC/API/APIError.swift" \
    "$SRC/API/AppConfig.swift" \
    "$SRC/API/Credentials.swift" \
    "$SRC/API/KeychainStore.swift" \
    "$SRC/Demo/DemoBackend.swift" \
    "$SRC/Demo/LocalWorkspaceStore.swift" \
    "$SRC/Demo/DemoMusicXml.swift" \
    "$SRC/State/AppModel.swift" \
    "$ROOT/Shared/SongsNotesWidgetData.swift" \
    "$ROOT/Shared/BookmarksWidgetData.swift" \
    "$SRC/State/ScriptModel.swift" \
    "$SRC/State/ProjectListModel.swift" \
    "$SRC/State/LocalHistory.swift" \
    "$SRC/State/UnsavedDraftStore.swift" \
    "$SRC/State/UnsavedDocumentStore.swift" \
    "$SRC/State/OfflineStore.swift" \
    "$SRC/State/OfflineBlockQueue.swift" \
    "$SRC/State/ConnectivityMonitor.swift" \
    "$SRC/State/PresentationSettings.swift" \
    "$SRC/State/CapitalizationSettings.swift" \
    "$SRC/Models/"*.swift \
    "${SHARED[@]}" \
    "$ROOT/Tests/FirstElement/main.swift"
run_suite "$BUILD/firstelement" || status=1

echo
echo "== Cancelled requests are never the writer's problem =="
# The one suite here that talks to something listening rather than to a closed
# port: a request the client cancelled and a request it never sent look
# identical from the outside, and telling them apart is the whole question.
swiftc "${FLAGS[@]}" -o "$BUILD/cancellation" \
    "$SRC/API/APIClient.swift" \
    "$SRC/API/APIError.swift" \
    "$SRC/API/AppConfig.swift" \
    "$SRC/API/Credentials.swift" \
    "$SRC/API/KeychainStore.swift" \
    "$SRC/Demo/DemoBackend.swift" \
    "$SRC/Demo/LocalWorkspaceStore.swift" \
    "$SRC/Demo/DemoMusicXml.swift" \
    "$SRC/State/AppModel.swift" \
    "$ROOT/Shared/SongsNotesWidgetData.swift" \
    "$ROOT/Shared/BookmarksWidgetData.swift" \
    "$SRC/State/ScriptModel.swift" \
    "$SRC/State/LocalHistory.swift" \
    "$SRC/State/UnsavedDraftStore.swift" \
    "$SRC/State/UnsavedDocumentStore.swift" \
    "$SRC/State/OfflineStore.swift" \
    "$SRC/State/OfflineBlockQueue.swift" \
    "$SRC/State/ConnectivityMonitor.swift" \
    "$SRC/State/PresentationSettings.swift" \
    "$SRC/State/CapitalizationSettings.swift" \
    "$SRC/Models/"*.swift \
    "${SHARED[@]}" \
    "$ROOT/Tests/Cancellation/main.swift"
run_suite "$BUILD/cancellation" || status=1

echo
if [ "$status" -eq 0 ]; then
    echo "All logic checks passed."
else
    echo "Logic checks FAILED."
fi
exit "$status"
