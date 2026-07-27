//
//  ReadScriptView.swift
//  scripty
//
//  Read Script mode: the screenplay as prose, for reading rather than writing.
//  Ported from the web app's reader template, which drops the editing chrome,
//  sets the script in a serif face at a comfortable measure, and leaves out the
//  working annotations — synopses and notes are for the writer, not the reader.
//
//  Deliberately not a page-accurate view; that is what page view is for. This
//  one optimises for reading on a screen.
//
//  It is also where the script is read *aloud*, which is the same job done by
//  ear: the narrator (`ScriptNarrator`) speaks the run and this view follows
//  it, highlighting the element being read and scrolling it into view, so the
//  page and the voice stay together.
//

// The voice picker names the installed voices, which is an AVFoundation type
// even though the speaking itself is all behind the narrator.
import AVFoundation
import SwiftUI

struct ReadScriptView: View {
    let title: String
    let blocks: [Block]
    let textScale: Double
    /// Set when the reader was opened by "Read Aloud" rather than by "Read
    /// Script" — the same view either way, already speaking.
    var startsSpeaking = false

    @Environment(\.dismiss) private var dismiss

    /// One narrator per visit: a reading is of the script in front of you, and
    /// closing the reader ends it. The preferences it carries are stored, so
    /// the voice and speed survive even though the narrator does not.
    @State private var narrator = ScriptNarrator()

    /// The reader's measure: roughly the 40rem column the web app uses.
    ///
    /// Scaled with the type, because a measure is a count of characters before
    /// it is a width. Held at a fixed 640 points it was the right line length
    /// at the default size and a narrower and narrower ribbon above it — worst
    /// exactly where the extra room the bigger sheet brings should be going.
    private var measure: CGFloat { 640 * scale }

    /// The OS text-size setting, as a multiplier.
    ///
    /// This view sets its type in fixed points to hold the reader's
    /// proportions — a scene heading is deliberately a shade larger than the
    /// prose — which meant it ignored Dynamic Type entirely. Folding the
    /// setting in as a *multiplier* keeps those proportions while still
    /// honouring the size someone chose system-wide, and composes with the
    /// script's own type-size control rather than overriding it.
    @ScaledMetric(relativeTo: .body) private var dynamicTypeScale: CGFloat = 1

    private var scale: CGFloat { CGFloat(textScale) * dynamicTypeScale }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(title.isEmpty ? "Untitled Project" : title)
                            .font(.system(size: 28 * scale, weight: .bold, design: .serif))
                            .padding(.bottom, 24)

                        ForEach(Array(readableBlocks.enumerated()),
                                id: \.element.id) { index, block in
                            row(block, isFirst: index == 0)
                                .background(alignment: .center) { spotlight(block) }
                                .id(block.id)
                                .contextMenu {
                                    Button("Read Aloud From Here", systemImage: "play") {
                                        narrator.play(from: block.id)
                                    }
                                }
                        }
                    }
                    .frame(maxWidth: measure, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 24)
                    .textSelection(.enabled)
                }
                // Follow the voice. Centred rather than at the top, because a
                // line read at the very top of the screen has no context above
                // it and the next one is always a jump.
                .onChange(of: narrator.currentBlockId) { _, id in
                    guard let id else { return }
                    withAnimation(.easeInOut(duration: 0.3)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
            .overlay { emptyState }
            .safeAreaInset(edge: .bottom) { transportBar }
            .navigationTitle(startsSpeaking ? "Read Aloud" : "Read Script")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItemGroup(placement: .navigation) {
                    Button {
                        narrator.togglePlayPause()
                    } label: {
                        Label(narrator.isSpeaking ? "Pause" : "Read Aloud",
                              systemImage: narrator.isSpeaking ? "pause.fill" : "play.fill")
                    }
                    .disabled(!narrator.hasSomethingToRead)

                    readingOptions
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                narrator.prepare(blocks)
                if startsSpeaking { narrator.play() }
            }
            .onChange(of: blocks) { _, updated in narrator.prepare(updated) }
            // The reading is of this script, in this sheet: closing it stops
            // the voice rather than leaving it talking to an empty screen.
            .onDisappear { narrator.stop() }
        }
        // Reading wants the screen. A sheet defaults to the small centred form
        // size on iPad and the Mac, which left the reader showing half a dozen
        // elements at a time — little enough that following the voice was most
        // of a page of scrolling per scene, and the surrounding script it was
        // covering had more of the window than the reading did. The page size
        // is the largest a sheet offers, and still a sheet: swipe-down and the
        // dimmed script behind it both survive. On iPhone this changes
        // nothing, the sheet being full height there already.
        .presentationSizing(.page)
    }

    // MARK: - Reading aloud

    /// The element being read, marked without moving anything: the background
    /// is inset outwards so switching it on cannot reflow the page.
    @ViewBuilder
    private func spotlight(_ block: Block) -> some View {
        if narrator.currentBlockId == block.id {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.accentColor.opacity(0.16))
                .padding(.horizontal, -10)
                .padding(.vertical, -2)
        }
    }

    /// The transport, shown only while a reading is loaded — nothing to
    /// control otherwise, and the reader is for reading.
    @ViewBuilder
    private var transportBar: some View {
        if narrator.isActive {
            HStack(spacing: 20) {
                Button {
                    narrator.skipBackward()
                } label: {
                    Label("Previous Element", systemImage: "backward.fill")
                }

                Button {
                    narrator.togglePlayPause()
                } label: {
                    Label(narrator.isSpeaking ? "Pause" : "Play",
                          systemImage: narrator.isSpeaking ? "pause.fill" : "play.fill")
                        .font(.title3)
                }

                Button {
                    narrator.skipForward()
                } label: {
                    Label("Next Element", systemImage: "forward.fill")
                }

                Text(nowReading)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Now reading: \(nowReading)")

                Button {
                    narrator.stop()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
            }
            .labelStyle(.iconOnly)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
    }

    /// Whose line is being read, which is the one thing the transport can say
    /// that the highlight does not.
    private var nowReading: String {
        guard let cue = narrator.currentCue else { return "Paused" }
        if let speaker = cue.speaker, cue.kind.isSpoken { return speaker }
        return "Narration"
    }

    private var readingOptions: some View {
        Menu {
            // What to read comes first, and the voices go in a submenu of
            // their own: a device can have forty installed, and listed inline
            // they push everything else off the end of the menu.
            Section("Read") {
                Toggle(isOn: $narrator.options.announcesSpeakers) {
                    Label("Character Names", systemImage: "person.wave.2")
                }
                Toggle(isOn: $narrator.options.includesDescription) {
                    Label("Action and Headings", systemImage: "text.alignleft")
                }
                Toggle(isOn: $narrator.options.includesDirections) {
                    Label("Parentheticals", systemImage: "parentheses")
                }
                // What it can actually manage is worth saying: a device with
                // one installed voice cannot tell a cast apart, and silently
                // reading everything in the same voice looks like a bug.
                Toggle(isOn: $narrator.options.usesDistinctVoices) {
                    Label(narrator.options.usesDistinctVoices && narrator.castSize > 0
                          ? "A Voice Each (\(narrator.castSize))"
                          : "A Voice Each",
                          systemImage: "person.2.wave.2")
                }
            }

            Section("Speed") {
                Picker("Speed", selection: $narrator.speed) {
                    ForEach(ScriptNarrator.speedChoices, id: \.self) { speed in
                        Text(speedLabel(speed)).tag(speed)
                    }
                }
                .pickerStyle(.inline)
            }

            Menu {
                Picker("Voice", selection: $narrator.voiceIdentifier) {
                    Text("Default").tag(String?.none)
                    ForEach(narrator.availableVoices, id: \.identifier) { voice in
                        Text(voice.name).tag(String?.some(voice.identifier))
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label(narratorVoiceName, systemImage: "waveform")
            }
        } label: {
            Label("Reading Options", systemImage: "speaker.wave.2")
        }
        .disabled(!narrator.hasSomethingToRead)
    }

    /// The submenu names the voice in use, so the choice is readable without
    /// opening it.
    private var narratorVoiceName: String {
        guard narrator.voiceIdentifier != nil,
              let name = narrator.narratorVoice?.name else { return "Voice" }
        return "Voice: \(name)"
    }

    private func speedLabel(_ speed: Double) -> String {
        speed == 1 ? "Normal" : String(format: "%g×", speed)
    }

    /// Notes, synopses and page breaks are working marks that the reader view
    /// leaves out, matching the reader template and the print stylesheet.
    private var readableBlocks: [Block] {
        blocks.filter { block in
            switch block.blockType {
            case .synopsis, .note, .pageBreak: return false
            default: return true
            }
        }
    }

    /// Display case for a rendered element, honouring the auto-caps preference
    /// the way the editor does — the reader transforms on display instead of
    /// forcing caps, so a toggled-off scene/cue/transition reads in typed case.
    private func cased(_ text: String, _ block: Block) -> String {
        CapitalizationSettings.shared.displayCased(text, forBlockType: block.blockType)
    }

    @ViewBuilder
    private func row(_ block: Block, isFirst: Bool) -> some View {
        let text = displayText(for: block)

        switch block.blockType {
        case .scene:
            VStack(alignment: .leading, spacing: 0) {
                if !isFirst {
                    Divider().padding(.bottom, 16)
                }
                Text(cased(text, block))
                    .font(.system(size: 17 * scale, weight: .bold, design: .serif))
                    .tracking(0.7)
                    // Read back in its written case: VoiceOver spells out
                    // all-caps runs letter by letter, which turns every scene
                    // heading into an initialism.
                    .accessibilityLabel(text)
                    .accessibilityAddTraits(.isHeader)
            }
            .padding(.top, isFirst ? 0 : 16)
            .padding(.bottom, 16)

        case .section:
            Text(text)
                .font(.system(size: 20 * scale, weight: .semibold, design: .serif))
                .accessibilityAddTraits(.isHeader)
                .padding(.top, 20)
                .padding(.bottom, 12)

        case .character, .dualDialogue:
            Text(cased(text, block))
                .font(.system(size: 16 * scale, weight: .bold, design: .serif))
                .tracking(0.9)
                .frame(maxWidth: .infinity, alignment: .center)
                .accessibilityLabel(text)
                .padding(.top, 12)
                .padding(.bottom, 4)

        case .parenthetical:
            prose(text.hasPrefix("(") ? text : "(\(text))", block: block)
                .italic()
                .frame(maxWidth: .infinity, alignment: .center)

        case .dialogue, .lyrics:
            prose(text, block: block)
                .italic(block.blockType == .lyrics)
                .padding(.horizontal, 32)
                .padding(.bottom, 14)

        case .transition:
            prose(cased(text, block), block: block)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.vertical, 10)

        case .centered:
            prose(text, block: block)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.bottom, 14)

        default:
            VStack(alignment: .leading, spacing: 4) {
                // The reader labels a speaker that is attached to a non-cue
                // element, since there is no cue line to carry the name.
                if let name = block.personName, !name.isEmpty,
                   !block.blockType.isCharacterCue {
                    Text(name.uppercased())
                        .font(.system(size: 15 * scale, weight: .bold, design: .serif))
                        .tracking(0.9)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                prose(text, block: block)
            }
            .padding(.bottom, 14)
        }
    }

    /// Body copy shared by the prose-like elements, honouring the writer's
    /// character formatting but not the screenplay indents.
    private func prose(_ text: String, block: Block) -> Text {
        var result = Text(text.isEmpty ? " " : text)
            .font(.system(size: 17 * scale, design: .serif))
        if block.textBold ?? false { result = result.bold() }
        if block.textItalic ?? false { result = result.italic() }
        if block.textUnderline ?? false { result = result.underline() }
        return result
    }

    private func displayText(for block: Block) -> String {
        let content = block.content ?? ""
        if content.isEmpty, block.blockType.isCharacterCue, let name = block.personName {
            return name
        }
        return content
    }

    @ViewBuilder
    private var emptyState: some View {
        if readableBlocks.isEmpty {
            ContentUnavailableView(
                "Nothing to Read",
                systemImage: "book",
                description: Text("This script has no elements yet."))
        }
    }
}

/// Which of the two ways into the reader was taken.
///
/// It is the *item* the sheet is presented with rather than a flag beside an
/// `isPresented` — SwiftUI builds an `isPresented` sheet's content from the
/// view as it stood before the button's action ran, so a flag set in the same
/// tap is not there yet and Read Aloud opens silent.
enum ReaderMode: Int, Identifiable {
    case silent
    case aloud

    var id: Int { rawValue }
}
