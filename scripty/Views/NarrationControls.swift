//
//  NarrationControls.swift
//  scripty
//
//  The read-aloud transport and its options menu. The script screen mounts
//  the transport once, outside its surface switch, so the same bar rides the
//  writing column, the paper and the prose reader alike — one narrator, one
//  set of controls, whatever is on screen.
//

// The voice picker names the installed voices, which is an AVFoundation type
// even though the speaking itself is all behind the narrator.
import AVFoundation
import SwiftUI

/// The transport row: previous, play/pause, next, whose line is being read,
/// and stop. Callers show it only while a reading is loaded — nothing to
/// control otherwise.
struct NarrationTransportBar: View {
    var narrator: ScriptNarrator

    var body: some View {
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

            Text(narrator.nowReading)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Now reading: \(narrator.nowReading)")

            NarrationOptionsMenu(narrator: narrator)

            Button {
                narrator.stop()
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
        }
        .labelStyle(.iconOnly)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

/// What to read, how fast, and in whose voice.
struct NarrationOptionsMenu: View {
    @Bindable var narrator: ScriptNarrator

    var body: some View {
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
                Label(voiceName, systemImage: "waveform")
            }
        } label: {
            Label("Reading Options", systemImage: "speaker.wave.2")
        }
        .disabled(!narrator.hasSomethingToRead)
    }

    /// The submenu names the voice in use, so the choice is readable without
    /// opening it.
    private var voiceName: String {
        guard narrator.voiceIdentifier != nil,
              let name = narrator.narratorVoice?.name else { return "Voice" }
        return "Voice: \(name)"
    }

    private func speedLabel(_ speed: Double) -> String {
        speed == 1 ? "Normal" : String(format: "%g×", speed)
    }
}
