//
//  NarrationControls.swift
//  scripty
//
//  The read-aloud transport and its options menu. The script screen mounts
//  the transport once, outside its surface switch, so the same bar rides the
//  writing column, the paper and the prose reader alike — one narrator, one
//  set of controls, whatever is on screen.
//
//  The lyric editor and the note sheet mount the same bar, in the same place at
//  the foot of the screen, and it behaves the same way over a song as it does
//  over a screenplay. What it says changes with what is loaded: the arrows step
//  by line rather than by element, the readout shows the line being read where a
//  script would name the speaker, and the options menu drops the four screenplay
//  switches — a lyric has no character cues to announce and no parentheticals to
//  leave out.
//

// The voice picker names the installed voices, which is an AVFoundation type
// even though the speaking itself is all behind the narrator.
import AVFoundation
import SwiftUI

/// The transport row: previous, play/pause, next, whose line is being read,
/// and a close that ends the reading and takes the bar with it. Callers show
/// it only while a reading is loaded — nothing to control otherwise.
struct NarrationTransportBar: View {
    var narrator: ScriptNarrator

    var body: some View {
        HStack(spacing: 20) {
            Button {
                narrator.skipBackward()
            } label: {
                Label("Previous \(narrator.elementNoun)", systemImage: "backward.fill")
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
                Label("Next \(narrator.elementNoun)", systemImage: "forward.fill")
            }

            Text(narrator.nowReading)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Now reading: \(narrator.nowReading)")

            NarrationOptionsMenu(narrator: narrator)

            // An X rather than a transport "stop": stopping is also how the
            // bar is put away, and a stop glyph promises the controls stay.
            Button {
                narrator.stop()
            } label: {
                Label("Close", systemImage: "xmark")
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
            //
            // Screenplay only, every one of them: a song is one voice singing
            // lines nobody is announced before, and a note is prose. Shown over
            // a lyric they would be four switches that changed nothing — and
            // "Action and Headings", left off from a run-lines session, would
            // read as the reason the song had gone quiet.
            if narrator.offersScriptOptions {
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
            }

            Section("Speed") {
                Picker("Speed", selection: $narrator.speed) {
                    ForEach(ScriptNarrator.speedChoices, id: \.self) { speed in
                        Text(NarrationSpeed.label(speed)).tag(speed)
                    }
                }
                .pickerStyle(.inline)
            }

            Menu {
                Picker("Voice", selection: $narrator.voiceIdentifier) {
                    // Named rather than "Default", because it is not obvious
                    // which voice that is — and it is not necessarily the one
                    // the system would have picked, since a voice the writer
                    // downloaded outranks the built-in one.
                    Text(defaultVoiceLabel).tag(String?.none)
                    ForEach(narrator.availableVoices) { voice in
                        Text(voice.label).tag(String?.some(voice.identifier))
                    }
                }
                .pickerStyle(.inline)

                // The writer's own recorded voice is the best one any device
                // has, and it is kept back until an app asks for it — so it is
                // missing from the list above until this is tapped. Offered
                // only where the answer could be yes: a device with no
                // Personal Voice recorded, or one that has already answered,
                // gets no row rather than a prompt that leads nowhere.
                if narrator.canRequestPersonalVoice {
                    Section {
                        Button {
                            narrator.requestPersonalVoice()
                        } label: {
                            Label("Use My Personal Voice", systemImage: "waveform.badge.mic")
                        }
                    }
                }

                // Every voice on this device is a built-in one, so the reading
                // is as good as it can be made from in here. Where the better
                // ones come from is worth saying — and there is no way to open
                // that page from an app, so it is said rather than linked.
                if !narrator.hasDownloadedVoice {
                    Section {
                        Button {} label: {
                            Label("Better voices: Settings › Accessibility › Spoken Content › Voices",
                                  systemImage: "arrow.down.circle")
                        }
                        .disabled(true)
                    }
                }
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

    private var defaultVoiceLabel: String {
        guard let name = narrator.defaultVoiceName else { return "Default" }
        return "Default (\(name))"
    }
}
