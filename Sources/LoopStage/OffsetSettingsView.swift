import SwiftUI

struct OffsetSettingsView: View {
    @Binding var profile: OffsetProfile
    let apply: (OffsetProfile) -> Void
    let save: (OffsetProfile) -> Void
    let close: () -> Void
    let panelWidth: CGFloat
    @State private var panelOffset = CGSize.zero
    @GestureState private var panelDrag = CGSize.zero

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                HStack(spacing: 7) {
                    Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Offset")
                        .font(.system(size: 18, weight: .semibold))
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .gesture(panelDragGesture)
                .help("Drag offset menu")

                Button {
                    close()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                }
                .buttonStyle(.plain)
                .help("Close offset menu")
            }
            .foregroundStyle(.white.opacity(0.78))

            Text("Changes apply live. Save stores defaults for the current audio and video devices.")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.58))

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                videoOffsetRow
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

                Button("Close") {
                    close()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .foregroundStyle(.white)
        .padding(18)
        .frame(width: panelWidth)
        .background(.black.opacity(0.78))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 18, y: 10)
        .offset(
            x: panelOffset.width + panelDrag.width,
            y: panelOffset.height + panelDrag.height
        )
        .onChange(of: profile) { _, nextProfile in
            apply(nextProfile)
        }
    }

    private var panelDragGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .updating($panelDrag) { value, state, _ in
                state = value.translation
            }
            .onEnded { value in
                panelOffset.width += value.translation.width
                panelOffset.height += value.translation.height
            }
    }

    private var videoOffsetRow: some View {
        GridRow {
            Text("Video Start ms")
            HStack(spacing: 8) {
                LiveNumberField(value: $profile.videoStartOffsetMilliseconds)
                    .frame(width: 78)

                Slider(value: $profile.videoStartOffsetMilliseconds, in: -500...500, step: 1)
                    .frame(width: 250)

                Button("0") {
                    profile.videoStartOffsetMilliseconds = 0
                }
                .frame(width: 34)
                .help("Reset video offset")
            }
        }
    }

    private func numberRow(_ title: String, value: Binding<Double>) -> some View {
        GridRow {
            Text(title)
            LiveNumberField(value: value)
                .frame(width: 110)
        }
    }
}

private struct LiveNumberField: View {
    @Binding var value: Double
    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("", text: Binding(
            get: {
                if isFocused {
                    return text
                }
                return Self.format(value)
            },
            set: { newValue in
                text = newValue
                if let parsed = Self.parse(newValue) {
                    value = parsed
                }
            }
        ))
        .textFieldStyle(.roundedBorder)
        .focused($isFocused)
        .onAppear {
            text = Self.format(value)
        }
        .onChange(of: value) { _, newValue in
            if !isFocused {
                text = Self.format(newValue)
            }
        }
        .onChange(of: isFocused) { _, focused in
            if focused {
                text = Self.format(value)
            } else {
                if let parsed = Self.parse(text) {
                    value = parsed
                }
                text = Self.format(value)
            }
        }
    }

    private static func parse(_ text: String) -> Double? {
        Double(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}
