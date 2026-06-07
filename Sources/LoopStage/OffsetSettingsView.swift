import SwiftUI

struct OffsetSettingsView: View {
    @Binding var profile: OffsetProfile
    let apply: (OffsetProfile) -> Void
    let save: (OffsetProfile) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Offset")
                    .font(.system(size: 18, weight: .semibold))
                Text("Apply tests live. Save stores defaults for the current audio and video devices.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                numberRow("Video Start ms", value: $profile.videoStartOffsetMilliseconds)
                numberRow("Audio Stop ms", value: $profile.audioStopOffsetMilliseconds)
                numberRow("Crossfade ms", value: $profile.crossfadeMilliseconds)
                numberRow("Fade Out ms", value: $profile.loopFadeOutMilliseconds)

                GridRow {
                    Text("Fade Mode")
                    Picker("", selection: $profile.loopFadeMode) {
                        ForEach(LoopFadeMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 230)
                }
            }

            HStack {
                Button("Apply") {
                    apply(profile)
                }
                .keyboardShortcut(.return, modifiers: [])

                Button("Save") {
                    save(profile)
                }

                Spacer()

                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 450)
    }

    private func numberRow(_ title: String, value: Binding<Double>) -> some View {
        GridRow {
            Text(title)
            TextField("", value: value, format: .number.precision(.fractionLength(1)))
                .textFieldStyle(.roundedBorder)
                .frame(width: 110)
        }
    }
}
