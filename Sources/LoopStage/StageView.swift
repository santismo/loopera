import AppKit
import SwiftUI

private enum StageFocusedField: Hashable {
    case tempo
}

struct StageView: View {
    @StateObject private var capture = CaptureController()
    @StateObject private var output = AudioOutputController()
    @StateObject private var performance = PerformanceRecorder()
    @StateObject private var playbackClock = LoopPlaybackClock()
    @StateObject private var metronome = MetronomeController()
    @State private var layout: StageLayout = .clock
    @State private var editMode = false
    @State private var canvasScale = 1.0
    @State private var livePreviewZoom = 1.0
    @State private var livePreviewShape: LoopSlotShape = .roundedSquare
    @State private var dragPositions: [UUID: CGPointUnit] = [:]
    @State private var layoutName = "Default"
    @State private var savedLayoutNames: [String] = []
    @State private var stageCaptureView: NSView?
    @State private var showOffsetSettings = false
    @State private var showSaveLayout = false
    @State private var offsetDraft = OffsetProfile()
    @FocusState private var focusedField: StageFocusedField?

    var body: some View {
        VStack(spacing: 0) {
            toolbar

            GeometryReader { proxy in
                ZStack {
                    Color(red: 0.045, green: 0.048, blue: 0.052)

                    livePreview(in: proxy.size)

                    loopLayer(in: proxy.size)

                    if editMode {
                        editControlsOverlay
                            .padding(12)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }

                    StageCaptureView { view in
                        if stageCaptureView !== view {
                            stageCaptureView = view
                        }
                    }
                }
                .coordinateSpace(name: "stage")
            }

            AudioTimelineView(
                slots: capture.slots,
                waveforms: capture.waveformSnapshots,
                playbackTimes: capture.loopPlaybackTimes,
                playbackTimeUpdatedAt: capture.loopPlaybackTimeUpdatedAt
            )
            .frame(height: 148)
        }
        .background(Color(red: 0.10, green: 0.105, blue: 0.11))
        .background(KeyEventMonitor { event in
            handleEvent(event)
        })
        .foregroundStyle(.white)
        .focusable()
        .onKeyPress { press in
            handleKeyPress(press)
        }
        .onDeleteCommand {
            capture.deleteSelected()
        }
        .onAppear {
            refreshSavedLayouts()
            offsetDraft = capture.offsetProfile
            metronome.bpm = capture.tempoBPM ?? 120
            capture.performanceAudioHandler = { input, sampleRate, presentationTime in
                performance.appendLiveAudio(input: input, sampleRate: sampleRate, presentationTime: presentationTime)
            }
            capture.requestAccessAndStart()
        }
        .sheet(isPresented: $showOffsetSettings) {
            OffsetSettingsView(
                profile: $offsetDraft,
                apply: { profile in
                    capture.applyOffsetProfile(profile)
                },
                save: { profile in
                    capture.saveOffsetProfile(profile)
                }
            )
        }
        .sheet(isPresented: $showSaveLayout) {
            SaveLayoutView(
                layoutName: $layoutName,
                onSave: {
                    saveLayout()
                    showSaveLayout = false
                }
            )
        }
        .onChange(of: editMode) { _, isEditing in
            if isEditing, capture.selectedSlotIndex == nil {
                capture.selectedSlotIndex = 1
            }
            capture.status = isEditing ? "Edit mode: drag slot rings and resize selected loop." : "Edit mode off."
        }
        .onDisappear {
            shutdownAudioAndCapture()
        }
    }

    private func shutdownAudioAndCapture() {
        capture.setPerformanceLoopAudioHandler(nil)
        capture.performanceAudioHandler = nil
        capture.shutdown()
        metronome.stop()
        if performance.isRecording {
            Task {
                await performance.stop()
            }
        }
    }

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("🎥")
                    .font(.system(size: 22))
                    .frame(width: 34)

                Button {
                    capture.refreshDevices()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh camera and audio inputs")

                Picker("Camera", selection: Binding(
                    get: { capture.selectedDeviceID },
                    set: { capture.selectDevice($0) }
                )) {
                    ForEach(capture.videoDevices, id: \.uniqueID) { device in
                        Text(device.localizedName).tag(device.uniqueID)
                    }
                }
                .labelsHidden()
                .frame(width: 180)

                Menu {
                    ForEach(capture.audioDevices, id: \.uniqueID) { device in
                        Toggle(device.localizedName, isOn: Binding(
                            get: { capture.selectedAudioDeviceIDs.contains(device.uniqueID) },
                            set: { capture.setAudioDevice(device.uniqueID, enabled: $0) }
                        ))
                    }
                } label: {
                    Label(audioMenuTitle, systemImage: "waveform")
                }
                .frame(width: 180)

                Menu {
                    ForEach(capture.audioChannelPairStarts, id: \.self) { start in
                        Button {
                            capture.selectAudioChannelPair(start: start)
                        } label: {
                            if capture.selectedAudioChannelPairStart == start {
                                Label(audioPairTitle(start), systemImage: "checkmark")
                            } else {
                                Text(audioPairTitle(start))
                            }
                        }
                    }
                } label: {
                    Label(audioPairTitle(capture.selectedAudioChannelPairStart), systemImage: "cable.connector")
                }
                .frame(width: 118)

                Menu {
                    Button("System Output") {
                        output.selectSystemOutput()
                    }
                    Divider()
                    ForEach(output.devices) { device in
                        Button {
                            output.select(device.id)
                        } label: {
                            if output.selectedDeviceID == device.id {
                                Label(device.name, systemImage: "checkmark")
                            } else {
                                Text(device.name)
                            }
                        }
                    }
                    Divider()
                    Button {
                        output.refresh()
                    } label: {
                        Label("Refresh Outputs", systemImage: "arrow.clockwise")
                    }
                } label: {
                    Label(audioOutputMenuTitle, systemImage: "speaker.wave.2")
                }
                .frame(width: 180)

                layoutPresetControls

                Button {
                    toggleWindowMode()
                } label: {
                    Image(systemName: "rectangle.on.rectangle")
                }
                .help("Toggle fullscreen/window mode")

                Button {
                    capture.toggleAllPlayback()
                } label: {
                    Label("All", systemImage: allLoopsArePlaying ? "pause.fill" : "play.fill")
                }
                .help("Play or stop all loops")
                .keyboardShortcut(.space, modifiers: [.shift])
            }

            HStack(spacing: 10) {
                meter

                HStack(spacing: 7) {
                    Text("Thr")
                        .font(.system(size: 11, weight: .medium))
                    Slider(value: $capture.threshold, in: 0.0005...0.2)
                        .frame(width: 120)
                }

                HStack(spacing: 7) {
                    Text("BPM")
                        .font(.system(size: 11, weight: .medium))
                    TextField("BPM", value: $metronome.bpm, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .tempo)
                        .frame(width: 54)
                        .onSubmit {
                            metronome.applyTempo()
                            if metronome.isPlaying {
                                capture.tempoBPM = metronome.bpm
                                capture.setMetronomeGrid(bpm: metronome.bpm, startDate: metronome.startedAt)
                            }
                        }
                    Slider(value: $metronome.bpm, in: 20...300)
                        .frame(width: 92)
                        .onChange(of: metronome.bpm) {
                            metronome.applyTempo()
                            if metronome.isPlaying {
                                capture.tempoBPM = metronome.bpm
                                capture.setMetronomeGrid(bpm: metronome.bpm, startDate: metronome.startedAt)
                            }
                        }
                        .help("Metronome tempo")
                    Button {
                        metronome.applyTempo()
                        metronome.togglePlay()
                        if metronome.isPlaying {
                            capture.tempoBPM = metronome.bpm
                            capture.setMetronomeGrid(bpm: metronome.bpm, startDate: metronome.startedAt)
                        } else {
                            capture.setMetronomeGrid(bpm: nil, startDate: nil)
                        }
                    } label: {
                        Image(systemName: metronome.isPlaying ? "stop.fill" : "play.fill")
                    }
                    .help("Play metronome")
                    Button {
                        metronome.toggleMute()
                    } label: {
                        Image(systemName: metronome.isMuted ? "speaker.slash" : "speaker.wave.2")
                    }
                    .help("Mute metronome (K)")
                    Slider(value: $metronome.volume, in: 0...1)
                        .frame(width: 64)
                        .onChange(of: metronome.volume) {
                            metronome.applyVolume()
                        }
                        .help("Metronome volume")
                    Button {
                        capture.detectTempoFromMaster()
                        if let tempo = capture.tempoBPM {
                            metronome.bpm = tempo
                            metronome.applyTempo()
                        }
                    } label: {
                        Image(systemName: "metronome")
                    }
                    .help("Detect tempo from master loop")
                }

                Button {
                    offsetDraft = capture.offsetProfile
                    showOffsetSettings = true
                } label: {
                    Label("Offset", systemImage: "slider.horizontal.2.square")
                }
                .help("Audio/video offset and fade settings")

                Toggle(isOn: $editMode) {
                    Label("Edit", systemImage: "slider.horizontal.3")
                }
                .toggleStyle(.button)

                Button {
                    capture.clearLoops()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .disabled(editMode)

                Button {
                    if performance.isRecording {
                        capture.setPerformanceLoopAudioHandler(nil)
                        Task { await performance.stop() }
                    } else {
                        capture.setPerformanceLoopAudioHandler { input, sampleRate, presentationTime in
                            performance.appendLoopAudio(input: input, sampleRate: sampleRate, presentationTime: presentationTime)
                        }
                        performance.start(microphoneDeviceID: capture.selectedAudioDeviceIDs.first, fallbackView: stageCaptureView)
                        if !performance.isRecording {
                            capture.setPerformanceLoopAudioHandler(nil)
                        }
                    }
                } label: {
                    Label(performance.isRecording ? "Stop Performance" : "Record Performance", systemImage: "rectangle.dashed.badge.record")
                }
                .disabled(editMode)

                Button {
                    openPerformanceFolder()
                } label: {
                    Image(systemName: "folder")
                }
                .help("Show saved performances")

                Text(statusText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.66))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 10) {
                masterProgressBar
                slotStatusStrip
            }

        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.black.opacity(0.86))
    }

    private var meter: some View {
        VStack(alignment: .leading, spacing: 3) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(.white.opacity(0.18))
                RoundedRectangle(cornerRadius: 5)
                    .fill(capture.inputLevel >= capture.threshold ? Color.red : Color.green)
                    .frame(width: max(4, 150 * capture.inputLevel))
                Rectangle()
                    .fill(.yellow)
                    .frame(width: 3)
                    .offset(x: 150 * capture.threshold)
            }
            .frame(width: 150, height: 16)
            HStack {
                Text("In")
                Spacer()
                Text("\(String(format: "%.1f", capture.inputLevel * 100))% / \(String(format: "%.1f", capture.threshold * 100))%")
            }
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundStyle(.white.opacity(0.65))
        }
        .frame(width: 150)
    }

    private var layoutPresetControls: some View {
        HStack(spacing: 6) {
            Button {
                layoutName = normalizedLayoutName(layoutName)
                showSaveLayout = true
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .help("Save named layout")

            Menu {
                if savedLayoutNames.isEmpty {
                    Text("No Saved Layouts")
                } else {
                    ForEach(savedLayoutNames, id: \.self) { name in
                        Button(name) {
                            loadLayout(named: name)
                        }
                    }
                }
            } label: {
                Label("Layouts", systemImage: "rectangle.stack")
            }
            .help("Load named layout")
        }
    }

    private var allLoopsArePlaying: Bool {
        let recorded = capture.slots.filter { $0.state == .recorded }
        return !recorded.isEmpty && recorded.allSatisfy(\.isPlaying)
    }

    private var statusText: String {
        if performance.isRecording || performance.status != "Program recorder idle." {
            return performance.status
        }
        return capture.status
    }

    private func toggleWindowMode() {
        NSApp.keyWindow?.toggleFullScreen(nil)
    }

    private func openPerformanceFolder() {
        NSWorkspace.shared.open(PerformanceRecorder.recordingsDirectory)
    }

    private var editControlsOverlay: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Button {
                    capture.deleteSelected()
                } label: {
                    Image(systemName: "trash")
                }
                .help("Delete selected loop recording")

                Button {
                    capture.addSlot()
                } label: {
                    Image(systemName: "plus")
                }
                .help("Add slot")

                Button {
                    capture.removeSelectedSlot()
                } label: {
                    Image(systemName: "minus")
                }
                .help("Remove selected slot")

                keyMenu
                shapeMenu(title: "Loop", selection: Binding(
                    get: { selectedShape },
                    set: { capture.setShapeForSelected($0) }
                ))
                shapeMenu(title: "Live", selection: $livePreviewShape)
            }

            compactSlider("Live Size", value: $canvasScale, range: 0.65...1.35)
            compactSlider("Live Zoom", value: $livePreviewZoom, range: 1...2.5)
            compactSlider(
                "Loop Size",
                value: Binding(
                    get: { selectedScale },
                    set: { capture.setScaleForSelected($0) }
                ),
                range: 0.5...2.2
            )
        }
        .font(.system(size: 12, weight: .medium))
        .padding(10)
        .frame(width: 330, alignment: .leading)
        .background(.black.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        )
    }

    private var keyMenu: some View {
        Menu {
            Section("Numbers") {
                ForEach(["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"], id: \.self) { key in
                    keyMenuButton(key)
                }
            }
            Section("Symbols") {
                ForEach(["-", "+"], id: \.self) { key in
                    keyMenuButton(key)
                }
            }
            Section("Letters") {
                ForEach(["q", "w", "e", "r", "t", "y"], id: \.self) { key in
                    keyMenuButton(key)
                }
            }
        } label: {
            Label(selectedTriggerKey.uppercased(), systemImage: "keyboard")
        }
        .frame(width: 72)
    }

    private func keyMenuButton(_ key: String) -> some View {
        Button {
            capture.setTriggerKeyForSelected(key)
        } label: {
            if selectedTriggerKey == key {
                Label(key.uppercased(), systemImage: "checkmark")
            } else {
                Text(key.uppercased())
            }
        }
    }

    private func shapeMenu(title: String, selection: Binding<LoopSlotShape>) -> some View {
        Menu {
            ForEach(LoopSlotShape.allCases) { shape in
                Button {
                    selection.wrappedValue = shape
                } label: {
                    if selection.wrappedValue == shape {
                        Label(shape.rawValue, systemImage: "checkmark")
                    } else {
                        Text(shape.rawValue)
                    }
                }
            }
        } label: {
            Label(title, systemImage: "viewfinder")
        }
        .frame(width: 82)
    }

    private func compactSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack(spacing: 7) {
            Text(title)
                .frame(width: 68, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: "%.2f", value.wrappedValue))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 34, alignment: .trailing)
        }
    }

    private var selectedScale: Double {
        guard let selected = capture.selectedSlotIndex,
              let slot = capture.slots.first(where: { $0.index == selected }) else {
            return 1
        }
        return slot.scale
    }

    private var bpmText: Binding<String> {
        Binding(
            get: {
                guard let bpm = capture.tempoBPM else { return "" }
                return String(Int(bpm.rounded()))
            },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                capture.tempoBPM = trimmed.isEmpty ? nil : Double(trimmed)
            }
        )
    }

    private var selectedShape: LoopSlotShape {
        guard let selected = capture.selectedSlotIndex,
              let slot = capture.slots.first(where: { $0.index == selected }) else {
            return .circle
        }
        return slot.shape
    }

    private var selectedTriggerKey: String {
        guard let selected = capture.selectedSlotIndex,
              let slot = capture.slots.first(where: { $0.index == selected }) else {
            return "1"
        }
        return slot.triggerKey
    }

    private func saveLayout() {
        let name = normalizedLayoutName(layoutName)
        let preset = LayoutPreset(
            selectedVideoDeviceID: capture.selectedDeviceID,
            selectedAudioDeviceIDs: Array(capture.selectedAudioDeviceIDs),
            selectedAudioChannelPairStart: capture.selectedAudioChannelPairStart,
            selectedAudioOutputDeviceID: output.selectedDeviceID,
            stageLayout: layout,
            canvasScale: canvasScale,
            livePreviewZoom: livePreviewZoom,
            livePreviewShape: livePreviewShape,
            threshold: capture.threshold,
            thresholdLeadMilliseconds: capture.thresholdLeadMilliseconds,
            tempoBPM: capture.tempoBPM,
            slots: capture.slotPresets()
        )

        do {
            let data = try JSONEncoder().encode(preset)
            try data.write(to: LayoutPresetStore.url(for: name), options: .atomic)
            layoutName = name
            refreshSavedLayouts()
            capture.status = "Saved layout: \(name)."
        } catch {
            capture.status = "Could not save layout: \(error.localizedDescription)"
        }
    }

    private func loadLayout(named name: String) {
        do {
            let data = try Data(contentsOf: LayoutPresetStore.url(for: name))
            let preset = try JSONDecoder().decode(LayoutPreset.self, from: data)
            layoutName = name
            layout = preset.stageLayout
            canvasScale = preset.canvasScale
            livePreviewZoom = preset.livePreviewZoom ?? 1
            livePreviewShape = preset.livePreviewShape ?? .roundedSquare
            capture.threshold = preset.threshold
            capture.thresholdLeadMilliseconds = preset.thresholdLeadMilliseconds ?? capture.thresholdLeadMilliseconds
            capture.tempoBPM = preset.tempoBPM
            if let tempo = preset.tempoBPM {
                metronome.bpm = tempo
                metronome.applyTempo()
            }
            capture.applySlotPresets(preset.slots)
            capture.applyDevicePreset(
                videoDeviceID: preset.selectedVideoDeviceID,
                audioDeviceIDs: preset.selectedAudioDeviceIDs,
                audioChannelPairStart: preset.selectedAudioChannelPairStart,
                refresh: false
            )
            if let outputID = preset.selectedAudioOutputDeviceID {
                if output.devices.contains(where: { $0.id == outputID }) {
                    output.select(outputID)
                } else {
                    output.refresh()
                    output.select(outputID)
                }
            } else {
                output.selectSystemOutput()
            }
            capture.status = "Loaded layout: \(name)."
        } catch {
            capture.status = "Could not load layout: \(error.localizedDescription)"
        }
    }

    private func refreshSavedLayouts() {
        savedLayoutNames = LayoutPresetStore.savedNames()
    }

    private func normalizedLayoutName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Default" : trimmed
    }

    private var audioMenuTitle: String {
        let selected = capture.audioDevices.filter { capture.selectedAudioDeviceIDs.contains($0.uniqueID) }
        switch selected.count {
        case 0:
            return "No Audio"
        case 1:
            return selected[0].localizedName
        default:
            return "\(selected.count) Audio Inputs"
        }
    }

    private var audioOutputMenuTitle: String {
        guard let selected = output.selectedDeviceID,
              let device = output.devices.first(where: { $0.id == selected }) else {
            return "System Output"
        }
        return device.name
    }

    private var selectedAudioDeviceName: String {
        capture.audioDevices.first(where: { capture.selectedAudioDeviceIDs.contains($0.uniqueID) })?.localizedName ?? "No Audio Input"
    }

    private var selectedVideoDeviceName: String {
        capture.videoDevices.first(where: { $0.uniqueID == capture.selectedDeviceID })?.localizedName ?? "No Camera"
    }

    private func audioPairTitle(_ start: Int) -> String {
        "USB \(start + 1)/\(start + 2)"
    }

    private var masterProgressBar: some View {
        let master = capture.slots.first(where: { $0.index == 1 })
        let duration = master?.duration ?? 0
        let syncTime = capture.loopPlaybackTimes[1] ?? 0
        let hasMaster = master?.state == .recorded && duration > 0

        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text("Master")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.62))
                Text(hasMaster ? timeLabel(syncTime, duration: duration) : "--")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
            }
            if hasMaster {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { _ in
                    GeometryReader { proxy in
                        let phase = masterProgressPhase(
                            syncTime: syncTime,
                            updatedAt: capture.loopPlaybackTimeUpdatedAt,
                            duration: duration
                        )
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(.white.opacity(0.14))
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.green.opacity(0.92))
                                .frame(width: max(3, proxy.size.width * phase))
                        }
                    }
                }
                .frame(width: 190, height: 8)
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(.white.opacity(0.14))
                    .frame(width: 190, height: 8)
            }
        }
        .frame(width: 190, alignment: .leading)
    }

    private var slotStatusStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(capture.slots) { slot in
                    Button {
                        capture.handleSlot(slot.index)
                    } label: {
                        Text(slot.triggerKey.uppercased())
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(slotTextColor(slot))
                            .frame(width: 22, height: 18)
                            .background(slotFillColor(slot))
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(
                                        capture.selectedSlotIndex == slot.index ? Color.blue : Color.white.opacity(0.18),
                                        lineWidth: capture.selectedSlotIndex == slot.index ? 2 : 1
                                    )
                                )
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .help("Slot \(slot.index): \(slot.triggerKey.uppercased())")
                }
            }
        }
        .frame(height: 22)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func masterProgressPhase(syncTime: TimeInterval, updatedAt: Date, duration: TimeInterval) -> Double {
        guard duration > 0 else { return 0 }
        let time = syncTime + Date().timeIntervalSince(updatedAt)
        return max(0, min(1, time.truncatingRemainder(dividingBy: duration) / duration))
    }

    private func timeLabel(_ syncTime: TimeInterval, duration: TimeInterval) -> String {
        guard duration > 0 else { return "--" }
        let time = syncTime.truncatingRemainder(dividingBy: duration)
        return String(format: "%.1f/%.1f", time, duration)
    }

    private func slotFillColor(_ slot: LoopSlot) -> Color {
        switch slot.state {
        case .empty:
            return .white.opacity(0.08)
        case .listening:
            return .yellow.opacity(0.85)
        case .armed:
            return .cyan.opacity(0.82)
        case .recording:
            return .red.opacity(0.86)
        case .recorded:
            return slot.isMuted ? .gray.opacity(0.62) : .green.opacity(0.84)
        }
    }

    private func slotTextColor(_ slot: LoopSlot) -> Color {
        switch slot.state {
        case .empty:
            return .white.opacity(0.54)
        case .listening, .armed, .recording, .recorded:
            return .black.opacity(0.88)
        }
    }

    @ViewBuilder
    private func livePreview(in size: CGSize) -> some View {
        let padding = stagePadding(for: size)
        let width = max(120, (size.width - padding * 2) * canvasScale)
        let height = max(90, (size.height - padding * 2) * canvasScale)

        ZStack {
            CameraPreview(session: capture.session)
                .scaleEffect(livePreviewZoom)
                .frame(width: width, height: height)
        }
        .frame(width: width, height: height)
        .clipShape(stageShape(livePreviewShape))
        .overlay {
            if editMode {
                stageShape(livePreviewShape)
                    .stroke(.white.opacity(0.28), lineWidth: 2)
            }
        }
        .position(x: size.width / 2, y: size.height / 2)
    }

    @ViewBuilder
    private func loopLayer(in size: CGSize) -> some View {
        ForEach(capture.slots) { slot in
            if slot.state != .empty || editMode {
                LoopTile(
                    slot: slot,
                    isSelected: capture.selectedSlotIndex == slot.index,
                    editMode: editMode,
                    audioOutputDeviceID: output.selectedDeviceID,
                    playbackClock: playbackClock,
                    syncTime: capture.loopPlaybackTimes[slot.index] ?? 0,
                    syncTimeUpdatedAt: capture.loopPlaybackTimeUpdatedAt,
                    offsetProfile: capture.offsetProfile
                )
                .frame(
                    width: tileSize(in: size) * slot.scale,
                    height: tileSize(in: size) * slot.scale
                )
                .position(position(for: slot, in: size))
                .onTapGesture {
                    capture.selectedSlotIndex = slot.index
                }
                .gesture(editMode ? dragGesture(for: slot, in: size) : nil)
            }
        }
    }

    private func dragGesture(for slot: LoopSlot, in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("stage"))
            .onChanged { value in
                capture.selectedSlotIndex = slot.index
                dragPositions[slot.id] = CGPointUnit(
                    x: min(1, max(0, value.location.x / max(1, size.width))),
                    y: min(1, max(0, value.location.y / max(1, size.height)))
                )
            }
            .onEnded { value in
                let position = CGPointUnit(
                    x: min(1, max(0, value.location.x / max(1, size.width))),
                    y: min(1, max(0, value.location.y / max(1, size.height)))
                )
                capture.setCustomPosition(slot: slot.index, position: position)
                dragPositions[slot.id] = nil
            }
    }

    private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
        if focusedField != nil {
            return .ignored
        }

        if editMode {
            if press.key == .delete || press.key == .deleteForward {
                capture.deleteSelected()
                return .handled
            }
            return .ignored
        }

        if press.key == .space {
            capture.handleSpace()
            return .handled
        }

        if press.key == .delete || press.key == .deleteForward {
            capture.deleteSelected()
            return .handled
        }

        if press.characters.lowercased() == "k" {
            metronome.toggleMute()
            return .handled
        }

        if press.characters.lowercased() == "m" {
            capture.toggleMuteSelected()
            return .handled
        }

        let key = press.characters.lowercased()
        if !key.isEmpty {
            capture.handleTriggerKey(key)
            return .handled
        }

        return .ignored
    }

    private func handleEvent(_ event: NSEvent) -> Bool {
        if NSApp.keyWindow?.firstResponder is NSTextView {
            return false
        }

        if event.modifierFlags.contains(.shift), event.keyCode == 49 {
            capture.toggleAllPlayback()
            return true
        }

        if editMode {
            if event.keyCode == 51 || event.keyCode == 117 {
                capture.deleteSelected()
                return true
            }
            return false
        }

        switch event.keyCode {
        case 49:
            capture.handleSpace()
            return true
        case 51, 117:
            capture.deleteSelected()
            return true
        default:
            break
        }

        let characters = (event.characters ?? event.charactersIgnoringModifiers ?? "").lowercased()
        if characters == "k" {
            metronome.toggleMute()
            return true
        }
        if characters == "m" {
            capture.toggleMuteSelected()
            return true
        }
        if !characters.isEmpty {
            capture.handleTriggerKey(characters)
            return true
        }
        return false
    }

    private func stagePadding(for size: CGSize) -> CGFloat {
        switch layout {
        case .clock:
            min(size.width, size.height) * 0.18
        case .border:
            min(size.width, size.height) * 0.16
        case .grid:
            24
        }
    }

    private func tileSize(in size: CGSize) -> CGFloat {
        switch layout {
        case .clock:
            max(62, min(size.width, size.height) * 0.145)
        case .border:
            max(62, min(size.width, size.height) * 0.135)
        case .grid:
            max(84, min(size.width, size.height) * 0.18)
        }
    }

    private func position(for slot: LoopSlot, in size: CGSize) -> CGPoint {
        if let dragPosition = dragPositions[slot.id] {
            return CGPoint(x: dragPosition.x * size.width, y: dragPosition.y * size.height)
        }

        if let customPosition = slot.customPosition {
            return CGPoint(x: customPosition.x * size.width, y: customPosition.y * size.height)
        }

        let index = slot.index - 1
        switch layout {
        case .clock:
            let radius = min(size.width, size.height) * 0.39
            let angle = (Double(index) / Double(max(1, capture.slots.count))) * 2 * Double.pi - Double.pi / 2
            return CGPoint(
                x: size.width / 2 + cos(angle) * radius,
                y: size.height / 2 + sin(angle) * radius
            )
        case .border:
            return borderPosition(for: index, in: size)
        case .grid:
            let tile = tileSize(in: size)
            let columns = 4
            let spacing = tile + 12
            let row = index / columns
            let column = index % columns
            let totalWidth = CGFloat(columns - 1) * spacing
            return CGPoint(
                x: size.width / 2 - totalWidth / 2 + CGFloat(column) * spacing,
                y: size.height - 75 - CGFloat(row) * spacing
            )
        }
    }

    private func borderPosition(for index: Int, in size: CGSize) -> CGPoint {
        let inset = tileSize(in: size) / 2 + 16
        let points = [
            CGPoint(x: size.width * 0.25, y: inset),
            CGPoint(x: size.width * 0.5, y: inset),
            CGPoint(x: size.width * 0.75, y: inset),
            CGPoint(x: size.width - inset, y: size.height * 0.25),
            CGPoint(x: size.width - inset, y: size.height * 0.5),
            CGPoint(x: size.width - inset, y: size.height * 0.75),
            CGPoint(x: size.width * 0.75, y: size.height - inset),
            CGPoint(x: size.width * 0.5, y: size.height - inset),
            CGPoint(x: size.width * 0.25, y: size.height - inset),
            CGPoint(x: inset, y: size.height * 0.75),
            CGPoint(x: inset, y: size.height * 0.5),
            CGPoint(x: inset, y: size.height * 0.25)
        ]
        return points[index % points.count]
    }

    private func stageShape(_ shape: LoopSlotShape) -> AnyShape {
        switch shape {
        case .circle:
            AnyShape(Circle())
        case .roundedSquare:
            AnyShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        case .capsule:
            AnyShape(Capsule())
        case .diamond:
            AnyShape(DiamondShape())
        case .hexagon:
            AnyShape(HexagonShape())
        }
    }
}

private struct SaveLayoutView: View {
    @Binding var layoutName: String
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Save Layout")
                .font(.system(size: 18, weight: .semibold))

            TextField("Layout name", text: $layoutName)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
                .onSubmit(onSave)

            HStack {
                Button("Save") {
                    onSave()
                }
                .keyboardShortcut(.defaultAction)

                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .frame(width: 320)
        .onAppear {
            nameFocused = true
        }
    }
}

private struct LoopTile: View {
    let slot: LoopSlot
    let isSelected: Bool
    let editMode: Bool
    let audioOutputDeviceID: String?
    @ObservedObject var playbackClock: LoopPlaybackClock
    let syncTime: TimeInterval
    let syncTimeUpdatedAt: Date
    let offsetProfile: OffsetProfile

    var body: some View {
        ZStack {
            if let url = slot.url, slot.state == .recorded, !editMode {
                LoopPlayerView(
                    url: url,
                    slotID: slot.id,
                    startOffset: effectiveVideoStartOffset,
                    duration: slot.duration,
                    isMuted: true,
                    isPlaying: slot.isPlaying,
                    isStopping: slot.isStopping,
                    audioOutputDeviceID: audioOutputDeviceID,
                    playbackClock: playbackClock,
                    syncTime: syncTime,
                    syncTimeUpdatedAt: syncTimeUpdatedAt
                )
                    .clipShape(tileShape)
                    .shadow(color: .black.opacity(editMode ? 0 : 0.45), radius: editMode ? 0 : 16, y: editMode ? 0 : 8)
            } else {
                tileShape
                    .fill(editMode ? .white.opacity(0.045) : .clear)
            }

            if editMode, let ringColor {
                tileShape
                    .stroke(ringColor, lineWidth: 4)
            }

            if editMode {
                editLabel
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private var effectiveVideoStartOffset: TimeInterval {
        max(0, slot.startOffset + offsetProfile.videoStartOffsetMilliseconds / 1000)
    }

    private var ringColor: Color? {
        switch slot.state {
        case .listening:
            return .yellow
        case .armed:
            return .cyan
        case .recording:
            return .red
        case .recorded:
            return isSelected ? .blue : nil
        case .empty:
            return editMode ? (isSelected ? .blue : .white.opacity(0.28)) : nil
        }
    }

    private var progressDot: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { _ in
            GeometryReader { proxy in
                if slot.duration > 0, slot.isPlaying {
                    let interpolatedTime = syncTime + Date().timeIntervalSince(syncTimeUpdatedAt)
                    let phase = interpolatedTime.truncatingRemainder(dividingBy: slot.duration) / slot.duration
                    let position = dotPosition(phase: phase, in: proxy.size)
                    Circle()
                        .fill(.white)
                        .frame(width: 8, height: 8)
                        .position(position)
                }
            }
        }
    }

    private func dotPosition(phase: Double, in size: CGSize) -> CGPoint {
        switch slot.shape {
        case .circle:
            let radius = min(size.width, size.height) / 2 + 4
            let angle = phase * 2 * Double.pi - Double.pi / 2
            return CGPoint(
                x: size.width / 2 + cos(angle) * radius,
                y: size.height / 2 + sin(angle) * radius
            )
        case .roundedSquare, .capsule:
            return perimeterPosition(phase: phase, in: size, inset: -5)
        case .diamond:
            let points = [
                CGPoint(x: size.width / 2, y: -5),
                CGPoint(x: size.width + 5, y: size.height / 2),
                CGPoint(x: size.width / 2, y: size.height + 5),
                CGPoint(x: -5, y: size.height / 2)
            ]
            return polygonPosition(phase: phase, points: points)
        case .hexagon:
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) / 2 + 5
            let points = (0..<6).map { index in
                let angle = Double(index) / 6 * 2 * Double.pi - Double.pi / 2
                return CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
            }
            return polygonPosition(phase: phase, points: points)
        }
    }

    private func perimeterPosition(phase: Double, in size: CGSize, inset: CGFloat) -> CGPoint {
        let minX = inset
        let maxX = size.width - inset
        let minY = inset
        let maxY = size.height - inset
        let width = maxX - minX
        let height = maxY - minY
        let perimeter = 2 * (width + height)
        var distance = phase * perimeter

        if distance <= width / 2 {
            return CGPoint(x: size.width / 2 + distance, y: minY)
        }
        distance -= width / 2
        if distance <= height {
            return CGPoint(x: maxX, y: minY + distance)
        }
        distance -= height
        if distance <= width {
            return CGPoint(x: maxX - distance, y: maxY)
        }
        distance -= width
        if distance <= height {
            return CGPoint(x: minX, y: maxY - distance)
        }
        distance -= height
        return CGPoint(x: minX + distance, y: minY)
    }

    private func polygonPosition(phase: Double, points: [CGPoint]) -> CGPoint {
        guard points.count > 1 else { return points.first ?? .zero }
        let segments = zip(points, points.dropFirst() + [points[0]]).map { start, end in
            (start: start, end: end, length: hypot(end.x - start.x, end.y - start.y))
        }
        let perimeter = segments.reduce(CGFloat(0)) { $0 + $1.length }
        var distance = CGFloat(phase) * perimeter

        for segment in segments {
            if distance <= segment.length {
                let t = segment.length == 0 ? 0 : distance / segment.length
                return CGPoint(
                    x: segment.start.x + (segment.end.x - segment.start.x) * t,
                    y: segment.start.y + (segment.end.y - segment.start.y) * t
                )
            }
            distance -= segment.length
        }
        return points[0]
    }

    private var editLabel: some View {
        VStack(spacing: 1) {
            Text(slotDisplayName)
                .font(.system(size: 15, weight: .bold, design: .rounded))
            Text(slot.triggerKey)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.78))
        }
        .frame(width: 34, height: 34)
        .background(.black.opacity(0.58))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var slotDisplayName: String {
        switch slot.index {
        case 10:
            return "0"
        case 11:
            return "-"
        case 12:
            return "+"
        default:
            return "\(slot.index)"
        }
    }

    private var tileShape: AnyShape {
        switch slot.shape {
        case .circle:
            AnyShape(Circle())
        case .roundedSquare:
            AnyShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        case .capsule:
            AnyShape(Capsule())
        case .diamond:
            AnyShape(DiamondShape())
        case .hexagon:
            AnyShape(HexagonShape())
        }
    }
}

private struct DiamondShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        path.closeSubpath()
        return path
    }
}

private struct HexagonShape: Shape {
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        var path = Path()
        for index in 0..<6 {
            let angle = Double(index) / 6 * 2 * Double.pi - Double.pi / 2
            let point = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        path.closeSubpath()
        return path
    }
}

private struct AudioTimelineView: View {
    let slots: [LoopSlot]
    let waveforms: [AudioLoopEngine.WaveformSnapshot]
    let playbackTimes: [Int: TimeInterval]
    let playbackTimeUpdatedAt: Date

    private var visibleSlots: [LoopSlot] {
        let waveformSlots = Set(waveforms.map(\.slot))
        return slots.filter { slot in
            slot.state == .recorded || slot.state == .recording || waveformSlots.contains(slot.index)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 12, weight: .semibold))
                Text("Audio Timeline")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.72))
                Spacer()
                Text("not recorded")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.42))
            }

            if visibleSlots.isEmpty {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.white.opacity(0.06))
                    .overlay {
                        Text("Waveforms appear while loops record.")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.38))
                    }
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 5) {
                        ForEach(visibleSlots) { slot in
                            TimelineTrackRow(
                                slot: slot,
                                waveform: waveforms.first(where: { $0.slot == slot.index }),
                                syncTime: playbackTimes[slot.index] ?? 0,
                                updatedAt: playbackTimeUpdatedAt
                            )
                            .frame(height: 28)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.black.opacity(0.9))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(.white.opacity(0.08))
                .frame(height: 1)
        }
    }
}

private struct TimelineTrackRow: View {
    let slot: LoopSlot
    let waveform: AudioLoopEngine.WaveformSnapshot?
    let syncTime: TimeInterval
    let updatedAt: Date

    var body: some View {
        HStack(spacing: 8) {
            Text(slotLabel)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(rowColor)
                .frame(width: 28, alignment: .center)

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(.white.opacity(0.075))
                Rectangle()
                    .fill(.white.opacity(0.16))
                    .frame(width: 1)
                GeometryReader { proxy in
                    waveformCanvas(in: proxy.size)
                    if slot.state == .recorded, slot.duration > 0, slot.isPlaying {
                        playhead(in: proxy.size)
                    }
                    if waveform?.isRecording == true {
                        recordingEdge(in: proxy.size)
                    }
                }
            }
        }
    }

    private func waveformCanvas(in size: CGSize) -> some View {
        Canvas { context, canvasSize in
            guard let samples = waveform?.samples, !samples.isEmpty else { return }
            let midY = canvasSize.height / 2
            let step = canvasSize.width / CGFloat(max(1, samples.count - 1))
            var path = Path()
            for (index, sample) in samples.enumerated() {
                let x = CGFloat(index) * step
                let height = max(1, CGFloat(sample) * canvasSize.height * 0.82)
                let rect = CGRect(x: x, y: midY - height / 2, width: max(1, step * 0.72), height: height)
                path.addRoundedRect(in: rect, cornerSize: CGSize(width: 1, height: 1))
            }
            context.fill(path, with: .color(rowColor.opacity(waveform?.isRecording == true ? 0.95 : 0.72)))
        }
        .frame(width: size.width, height: size.height)
    }

    private func playhead(in size: CGSize) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { _ in
            let time = syncTime + Date().timeIntervalSince(updatedAt)
            let phase = time.truncatingRemainder(dividingBy: max(0.001, slot.duration)) / max(0.001, slot.duration)
            Rectangle()
                .fill(.white.opacity(0.92))
                .frame(width: 2)
                .position(x: max(1, min(size.width - 1, size.width * phase)), y: size.height / 2)
        }
    }

    private func recordingEdge(in size: CGSize) -> some View {
        Rectangle()
            .fill(.red.opacity(0.9))
            .frame(width: 2)
            .position(x: size.width - 1, y: size.height / 2)
    }

    private var rowColor: Color {
        switch slot.state {
        case .recording:
            return .red
        case .recorded:
            return slot.isMuted ? .gray : .green
        case .armed:
            return .cyan
        case .listening:
            return .yellow
        case .empty:
            return .white.opacity(0.5)
        }
    }

    private var slotLabel: String {
        switch slot.index {
        case 10:
            return "0"
        case 11:
            return "-"
        case 12:
            return "+"
        default:
            return "\(slot.index)"
        }
    }
}

private struct AnyShape: Shape, @unchecked Sendable {
    private let pathBuilder: @Sendable (CGRect) -> Path

    init<S: Shape>(_ shape: S) {
        pathBuilder = { rect in
            shape.path(in: rect)
        }
    }

    func path(in rect: CGRect) -> Path {
        pathBuilder(rect)
    }
}

private struct KeyEventMonitor: NSViewRepresentable {
    let handler: (NSEvent) -> Bool

    func makeNSView(context: Context) -> NSView {
        context.coordinator.start(handler: handler)
        return NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.handler = handler
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var handler: ((NSEvent) -> Bool)?
        private var monitor: Any?

        func start(handler: @escaping (NSEvent) -> Bool) {
            self.handler = handler
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                if self?.handler?(event) == true {
                    return nil
                }
                return event
            }
        }

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
    }
}

private struct StageCaptureView: NSViewRepresentable {
    let onResolve: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let container = view.superview {
                onResolve(container)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let container = nsView.superview {
                onResolve(container)
            }
        }
    }
}
