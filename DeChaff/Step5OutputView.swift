import SwiftUI

extension ContentView {

    // MARK: - Step 5: Output

    var step5View: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                settingsGroup("Audio Processing") {
                    settingsToggleRow("Voice Isolation",
                                     subtitle: "Remove background noise and non-voice sounds",
                                     isOn: $model.doIsolation)
                    Divider().padding(.leading, 16)
                    settingsToggleRow("Dynamic Compression",
                                     subtitle: "Balance loud and quiet passages",
                                     isOn: $model.doCompression)
                    Divider().padding(.leading, 16)
                    settingsToggleRow("Long-Term Levelling",
                                     subtitle: "Even out sustained volume differences between speakers",
                                     isOn: $model.doSlowLeveler)
                    Divider().padding(.leading, 16)
                    settingsToggleRow("Loudness Normalisation",
                                     subtitle: "Target \(String(format: "%.0f", model.targetLUFS)) LUFS for consistent podcast volume",
                                     isOn: $model.doNormalization)
                    if model.doNormalization {
                        HStack(spacing: 12) {
                            Slider(value: $model.targetLUFS, in: -32 ... -6, step: 0.5)
                                .padding(.leading, 16)
                            Text(String(format: "%.0f LUFS", model.targetLUFS))
                                .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                                .frame(width: 56, alignment: .trailing).padding(.trailing, 16)
                        }
                        .padding(.bottom, 8)
                    }
                    Divider().padding(.leading, 16)
                    settingsToggleRow("Mono Output",
                                     subtitle: "Convert stereo to mono — recommended for speech",
                                     isOn: $model.monoOutput)
                    Divider().padding(.leading, 16)
                    settingsToggleRow("Shorten Long Silences",
                                     subtitle: model.shortenSilences
                                        ? "Keep up to \(String(format: "%.1f", model.maxSilenceDuration))s of silence in each pause"
                                        : "Trim excessive pauses to tighten the recording",
                                     isOn: $model.shortenSilences)
                    if model.shortenSilences {
                        HStack(spacing: 12) {
                            Slider(value: $model.maxSilenceDuration, in: 0.3...3.0, step: 0.1)
                                .padding(.leading, 16)
                            Text(String(format: "%.1fs max", model.maxSilenceDuration))
                                .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                                .frame(width: 60, alignment: .trailing).padding(.trailing, 16)
                        }
                        .padding(.bottom, 8)
                    }
                }

                settingsGroup("Output Format") {
                    settingsRow("Format") {
                        Picker("", selection: $model.outputFormat) {
                            Text("MP3").tag(OutputFormat.mp3)
                            Text("WAV").tag(OutputFormat.wav)
                        }
                        .pickerStyle(.segmented).frame(width: 110)
                    }
                    if model.outputFormat == .mp3 {
                        Divider().padding(.leading, 16)
                        settingsRow("Bitrate") {
                            Picker("", selection: $model.mp3Bitrate) {
                                ForEach([64, 96, 128, 192, 256], id: \.self) { br in
                                    Text("\(br) kbps").tag(br)
                                }
                            }
                            .pickerStyle(.segmented).frame(width: 290)
                        }
                    }
                }

                settingsGroup("Extras") {
                    settingsToggleRow("Transcribe Audio",
                                     subtitle: "Generate a text transcript using on-device speech recognition (requires macOS 26+)",
                                     isOn: $model.doTranscription)
                }
            }
            .padding(32)
        }
    }

    // MARK: - Settings helpers

    func settingsGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            VStack(spacing: 0) { content() }
                .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    func settingsToggleRow(_ label: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.subheadline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: isOn).toggleStyle(.switch).labelsHidden()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    func settingsRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(label).font(.subheadline)
            Spacer()
            content()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
