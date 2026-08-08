//
//  BackgroundNoiseMenu.swift
//  scripty
//
//  Picking the bed, from wherever the writing is happening.
//
//  One menu, mounted in four "…"s — the project list, the screenplay, the
//  lyric editor and the note sheet — the way Text Size is. The bed is a device
//  setting like that one, and the alternative is the writer having to leave the
//  song they are working on to turn the rain down.
//
//  Everything is in the menu itself rather than behind a sheet: choosing a
//  sound is a thing done by ear, and a sheet over the writing is exactly what
//  should not happen while listening to it. The volume is five named steps and
//  not a slider for the same reason a menu holds no sliders — see
//  `BackgroundNoiseVolume`.
//

import SwiftUI

struct BackgroundNoiseMenu: View {
    /// App-wide, like the appearance and the text size the menus beside this
    /// one set.
    private let noise = BackgroundNoisePlayer.shared

    var body: some View {
        Menu {
            Section("Sound") {
                Picker("Sound", selection: soundBinding) {
                    // Off is one of the choices rather than a switch above
                    // them: "no bed" is what a writer picks as often as they
                    // pick rain, and a tick beside it says which is on.
                    Text("Off").tag(BackgroundNoiseSound?.none)
                    ForEach(BackgroundNoiseSound.allCases) { sound in
                        Label(sound.label, systemImage: sound.systemImage)
                            .tag(BackgroundNoiseSound?.some(sound))
                    }
                }
                .pickerStyle(.inline)
            }

            Section("Volume") {
                Picker("Volume", selection: volumeBinding) {
                    ForEach(BackgroundNoiseVolume.choices, id: \.self) { level in
                        Text(BackgroundNoiseVolume.label(level)).tag(level)
                    }
                }
                .pickerStyle(.inline)
            }

            // A bed that will not start sounds precisely like a bed turned
            // down, so the reason is put where the switch is.
            if let message = noise.errorMessage {
                Section {
                    Button {} label: {
                        Label(message, systemImage: "exclamationmark.triangle")
                    }
                    .disabled(true)
                }
            }
        } label: {
            // The label carries the state, since this is the only place it is
            // shown: nothing in the chrome says the rain is on, and a bed is
            // easy to stop noticing and then wonder about.
            Label(title, systemImage: noise.isPlaying ? noise.sound.systemImage : "waveform")
        }
    }

    private var title: String {
        noise.isPlaying ? "Background Noise: \(noise.sound.label)" : "Background Noise"
    }

    private var soundBinding: Binding<BackgroundNoiseSound?> {
        Binding(get: { noise.playingSound }, set: { noise.playingSound = $0 })
    }

    private var volumeBinding: Binding<Double> {
        Binding(get: { noise.volumeStep }, set: { noise.volumeStep = $0 })
    }
}
