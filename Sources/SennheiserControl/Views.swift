import SwiftUI
import GAIA3

extension DeviceState {
    var presetChoices: [Choice<String>] {
        var choices = EqPreset.all.map { Choice($0.name, $0.name) }
        choices.append(Choice(EqPreset.bassBoostName, EqPreset.bassBoostName))
        if eqPreset == EqPreset.customName {
            choices.append(Choice(EqPreset.customName, EqPreset.customName))
        }
        return choices
    }
}

extension NoiseControl.Mode {
    var title: String {
        switch self {
        case .anc: return "Noise cancellation"
        case .transparency: return "Transparency"
        case .off: return "Off"
        }
    }
}

// MARK: - Listening mode

/// The three listening modes; an ink plate slides to the one in use.
struct ModeSelector: View {
    @ObservedObject var session: HeadphoneSession
    /// Stacks each mode's pictogram over its name, for narrow places.
    var compact = false

    @Namespace private var plate
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let active = session.device.noise.activeMode
        HStack(spacing: 3) {
            ForEach(NoiseControl.Mode.allCases) { mode in
                segment(mode, selected: active == mode)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Color.primary.opacity(0.08)))
        .fixedSize(horizontal: !compact, vertical: true)
        .animation(reduceMotion ? nil : Motion.snap, value: active)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Listening mode")
    }

    private func segment(_ mode: NoiseControl.Mode, selected: Bool) -> some View {
        Button {
            session.setNoiseMode(mode)
        } label: {
            label(mode)
                .foregroundStyle(selected ? Palette.onInk : Color.primary)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Palette.ink)
                            .matchedGeometryEffect(id: "plate", in: plate)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(pressedScale: 0.97))
        .accessibilityLabel(mode.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private func label(_ mode: NoiseControl.Mode) -> some View {
        if compact {
            VStack(spacing: 6) {
                ModeGlyph(mode: mode)
                Text(mode.title)
                    .font(.system(size: 11, weight: .medium))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            HStack(spacing: 10) {
                ModeGlyph(mode: mode)
                Text(mode.title)
                    .font(.system(size: 13, weight: .medium))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
        }
    }
}

/// What can be adjusted about the listening mode in use.
struct ModeDetail: View {
    @ObservedObject var session: HeadphoneSession
    /// Stacks the controls instead of setting them in a row.
    var stacked = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var noise: NoiseControl { session.device.noise }

    var body: some View {
        content
            .font(.system(size: 12))
            .animation(reduceMotion ? nil : Motion.snap, value: noise.activeMode)
    }

    @ViewBuilder
    private var content: some View {
        switch noise.activeMode {
        case .anc:
            Group {
                if stacked {
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Wind noise reduction")
                                .foregroundStyle(.secondary)
                            wind
                        }
                        HStack {
                            Text("Adapt to surroundings")
                                .foregroundStyle(.secondary)
                            Spacer()
                            adaptive
                        }
                    }
                } else {
                    HStack(spacing: 12) {
                        Text("Wind noise reduction")
                            .foregroundStyle(.secondary)
                        wind
                            .frame(width: 186)
                        Text("Adapt to surroundings")
                            .foregroundStyle(.secondary)
                            .padding(.leading, 22)
                        adaptive
                    }
                }
            }
            .transition(.opacity)
        case .transparency:
            Group {
                if stacked {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Level")
                                .foregroundStyle(.secondary)
                            Spacer()
                            level
                        }
                        slider
                    }
                } else {
                    HStack(spacing: 12) {
                        Text("Level")
                            .foregroundStyle(.secondary)
                        slider
                            .frame(width: 300)
                        level
                            .frame(width: 26, alignment: .trailing)
                    }
                }
            }
            .transition(.opacity)
        case .off:
            Text("Outside sound is neither reduced nor let in.")
                .foregroundStyle(.secondary)
                .transition(.opacity)
        case nil:
            EmptyView()
        }
    }

    private var wind: some View {
        SegmentedChoice(label: "Wind noise reduction", selection: noise.antiWind,
                        choices: [Choice(.off, "Off"), Choice(.auto, "Auto"), Choice(.max, "Max")]) {
            session.setAntiWind($0)
        }
        .disabled(noise.antiWind == nil)
    }

    private var adaptive: some View {
        Toggle("Adapt noise cancellation to surroundings", isOn: Binding(
            get: { noise.adaptiveANC ?? false },
            set: { session.setAdaptiveANC($0) }
        ))
        .toggleStyle(InkToggleStyle())
        .disabled(noise.adaptiveANC == nil)
    }

    private var slider: some View {
        LevelSlider(label: "Transparency level", value: Double(noise.transparencyLevel), range: 0...100) {
            session.setTransparencyLevel(UInt8($0))
        }
    }

    private var level: some View {
        Text("\(noise.transparencyLevel)")
            .font(.legend(12))
            .monospacedDigit()
    }
}

// MARK: - Window

struct ContentView: View {
    @ObservedObject var session: HeadphoneSession
    @AppStorage(Preference.showFrameLog) private var showLog = false
    @State private var confirmReset = false
    @State private var unpairTarget: DeviceState.PairedDevice?
    @State private var showsDashboard = false
    @Namespace private var stage
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var device: DeviceState { session.device }

    init(session: HeadphoneSession) {
        self.session = session
        _showsDashboard = State(initialValue: session.isConnected)
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if showsDashboard {
                    dashboard
                        .transition(.opacity)
                } else {
                    connectView
                        .transition(.opacity)
                }
            }
            .overlay {
                // One stage for both screens: it follows whichever placeholder is showing, so
                // connecting reads as the searching stage rising to the top and filling with sound.
                SoundStage(tuning: stageTuning)
                    .matchedGeometryEffect(id: "stage", in: stage, isSource: false)
                    .allowsHitTesting(false)
            }
            if showLog {
                VStack(spacing: 0) {
                    Palette.rule.frame(height: 1)
                    FrameLogView(log: session.log, canSend: session.isConnected) { session.sendRaw(hex: $0) }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(Palette.ground.ignoresSafeArea())
        .animation(reduceMotion ? nil : Motion.stage, value: showLog)
        .frame(minWidth: 820, minHeight: 620)
        .onChange(of: session.isConnected) { connected in
            withAnimation(reduceMotion ? nil : Motion.stage) { showsDashboard = connected }
        }
        .alert("Unpair \(unpairTarget?.name ?? "device")?", isPresented: Binding(
            get: { unpairTarget != nil },
            set: { if !$0 { unpairTarget = nil } }
        ), presenting: unpairTarget) { paired in
            Button("Cancel", role: .cancel) {}
            Button("Unpair", role: .destructive) { session.deletePairedDevice(at: paired.index) }
        } message: { _ in
            Text("The headphones will forget this device. If it is this Mac, the connection drops and you will have to pair again.")
        }
        .alert("Factory reset the headphones?", isPresented: $confirmReset) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) { session.factoryReset() }
        } message: {
            Text("This erases the settings and pairings stored on the headphones.")
        }
    }

    private var stageTuning: StageTuning {
        if showsDashboard { return .listening(device.noise) }
        return isReaching ? .searching : .idle
    }

    /// Where the sound stage sits on the current screen; the stage itself is drawn above both.
    private var stageSlot: some View {
        Color.clear
            .matchedGeometryEffect(id: "stage", in: stage)
    }

    /// Connecting, or connected while the dashboard is still on its way in.
    private var isReaching: Bool { session.isConnecting || session.isConnected }

    // MARK: - Dashboard

    private var dashboard: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 28)
                .padding(.top, 8)
            stageSlot
                .frame(height: 150)
                .padding(.top, 6)
            VStack(spacing: 14) {
                ModeSelector(session: session)
                ModeDetail(session: session)
                    .frame(height: 24)
            }
            .padding(.top, 8)
            .padding(.bottom, 20)
            Palette.rule.frame(height: 1)
            settings
                .reveal(delay: 0.12, offset: 14)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(session.deviceName)
                    .font(.legend(22, .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(device.modelID.isEmpty ? " " : device.modelID)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if let battery = device.battery {
                BatteryMeter(level: battery)
                    .transition(.opacity)
            }
            Menu {
                Button("Refresh") { session.refreshAll() }
                Button(showLog ? "Hide Frame Log" : "Show Frame Log") { showLog.toggle() }
                Divider()
                Button("Disconnect") { session.disconnect() }
                Button("Factory Reset…", role: .destructive) { confirmReset = true }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 30, height: 30)
            .background(Circle().fill(Color.primary.opacity(0.08)))
            .accessibilityLabel("More actions")
        }
        .animation(reduceMotion ? nil : Motion.stage, value: device.battery == nil)
    }

    private var settings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                equalizer
                HStack(alignment: .top, spacing: 36) {
                    VStack(alignment: .leading, spacing: 28) {
                        sound
                        calls
                        wearing
                    }
                    VStack(alignment: .leading, spacing: 28) {
                        connections
                        prompts
                        about
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 22)
            .padding(.bottom, 26)
        }
    }

    private var equalizer: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                Text("Equalizer")
                    .font(.legend(15))
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 16)
                ViewThatFits(in: .horizontal) {
                    ChipRow(label: "Preset", selection: device.eqPreset, choices: device.presetChoices, onSelect: applyPreset)
                    ValueMenu(label: "Preset", selection: device.eqPreset, choices: device.presetChoices, onSelect: applyPreset)
                }
                .disabled(device.eqBands.count != EqPreset.bandLabels.count)
            }
            .frame(height: 26)
            EqualizerGraph(gains: device.eqBands, range: device.eqMinGain...device.eqMaxGain) { index, gain in
                session.setEqBand(index, gain)
            }
            .frame(height: 216)
        }
    }

    private func applyPreset(_ name: String) {
        if let gains = EqPreset.gains(named: name) { session.applyEqPreset(gains) }
    }

    private var sound: some View {
        SettingGroup(title: "Sound") {
            ToggleRow(title: "Bass boost", value: device.bassBoost) { session.setBassBoost($0) }
            ToggleRow(title: "Podcast mode", value: device.audioMode.map { $0 == HeadphoneSession.podcastAudioMode }) {
                session.setPodcastMode($0)
            }
            ToggleRow(title: "Low latency", value: device.lowLatency) { session.setLowLatency($0) }
        }
    }

    private var calls: some View {
        SettingGroup(title: "Calls") {
            ToggleRow(title: "Auto answer", value: device.autoAnswer) { session.setAutoAnswer($0) }
            ToggleRow(title: "Comfort call", value: device.comfortCall) { session.setComfortCall($0) }
            SettingRow(title: "Sidetone", isAvailable: device.sidetone != nil) {
                LevelSlider(label: "Sidetone", value: Double(device.sidetone ?? 0), range: 0...5, showsSteps: true) {
                    session.setSidetone(UInt8($0))
                }
                .frame(width: 120)
                Text(device.sidetone.map { String($0) } ?? "—")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 12, alignment: .trailing)
            }
        }
    }

    private var wearing: some View {
        SettingGroup(title: "Wear detection") {
            ToggleRow(title: "Smart pause", value: device.smartPause) { session.setSmartPause($0) }
            ToggleRow(title: "On-head detection", value: device.onHeadDetection) { session.setOnHeadDetection($0) }
        }
    }

    private var prompts: some View {
        SettingGroup(title: "Prompts and power") {
            SettingRow(title: "Voice prompts", isAvailable: device.promptMode != nil) {
                ValueMenu(label: "Voice prompts", selection: device.promptMode ?? 0, choices: promptChoices) {
                    session.setPromptMode($0)
                }
            }
            SettingRow(title: "Prompt language", isAvailable: device.promptLanguage != nil) {
                Text(device.promptLanguage.map(PromptLanguage.name) ?? "—")
                    .foregroundStyle(.secondary)
            }
            SettingRow(title: "Auto power off", isAvailable: device.autoPowerOffSeconds != nil) {
                ValueMenu(label: "Auto power off", selection: device.autoPowerOffSeconds ?? 0, choices: powerOffChoices) {
                    session.setAutoPowerOff(seconds: $0)
                }
            }
        }
    }

    private var promptChoices: [Choice<UInt8>] {
        var choices: [Choice<UInt8>] = [Choice(0, "Off"), Choice(1, "Tone"), Choice(2, "Tone and voice")]
        if let mode = device.promptMode, mode > 2 { choices.append(Choice(mode, "Mode \(mode)")) }
        return choices
    }

    private var powerOffChoices: [Choice<UInt16>] {
        var seconds: [UInt16] = [15, 30, 60, 120].map { $0 * 60 }
        if let current = device.autoPowerOffSeconds, current != 0, !seconds.contains(current) {
            seconds.append(current)
            seconds.sort()
        }
        return [Choice(0, "Never")] + seconds.map { Choice($0, $0 % 60 == 0 ? "\($0 / 60) min" : "\($0) s") }
    }

    private var connections: some View {
        SettingGroup(title: "Connections") {
            SettingRow(title: "Bluetooth", isAvailable: device.btCompatibility != nil) {
                ValueMenu(label: "Bluetooth mode", selection: device.btCompatibility ?? 0,
                          choices: [Choice(0, "Better audio"), Choice(1, "Better compatibility")]) {
                    session.setBtCompatibility($0 == 1)
                }
            }
            if device.pairedDevices.isEmpty {
                SettingRow(title: device.pairedCount == nil ? "Reading paired devices…" : "No paired devices", isAvailable: false) {
                    EmptyView()
                }
            }
            ForEach(device.pairedDevices) { paired in
                SettingRow(title: paired.name) {
                    if paired.connected {
                        Text("Connected")
                            .foregroundStyle(.secondary)
                    }
                    Menu {
                        if paired.connected {
                            Button("Disconnect") { session.disconnectPairedDevice(at: paired.index) }
                        } else {
                            Button("Connect") { session.connectPairedDevice(at: paired.index) }
                        }
                        Divider()
                        Button("Unpair…", role: .destructive) { unpairTarget = paired }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("Actions for \(paired.name)")
                }
            }
        }
    }

    private var about: some View {
        SettingGroup(title: "About") {
            fact("Firmware", device.firmware)
            fact("Serial number", device.serial)
            fact("Hardware revision", device.hwRevision)
            fact("Codec", device.codec ?? "")
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        SettingRow(title: label) {
            Text(value.isEmpty ? "—" : value)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    // MARK: - Disconnected

    private var connectView: some View {
        VStack(spacing: 0) {
            stageSlot
                .frame(height: 170)
                .padding(.bottom, 26)

            ZStack(alignment: .top) {
                if isReaching {
                    VStack(spacing: 0) {
                        VStack(spacing: 7) {
                            Text("Connecting to \(session.deviceName)")
                                .font(.legend(24, .bold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                            Text(session.statusMessage)
                                .foregroundStyle(.secondary)
                        }
                        .multilineTextAlignment(.center)
                        Button("Cancel") { session.disconnect() }
                            .buttonStyle(QuietButtonStyle())
                            .keyboardShortcut(.cancelAction)
                            .padding(.top, 20)
                    }
                    .transition(.opacity)
                } else {
                    chooser
                        .transition(.opacity)
                }
            }
            .frame(minHeight: 220, alignment: .top)
            .padding(.horizontal, 28)
        }
        .font(.system(size: 13))
        .animation(reduceMotion ? nil : Motion.stage, value: isReaching)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 24)
    }

    private var chooser: some View {
        VStack(spacing: 0) {
            VStack(spacing: 7) {
                Text("Connect your headphones")
                    .font(.legend(24, .bold))
                Text("Choose a headset that is paired with this Mac.")
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 14) {
                if let error = session.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Palette.alarm)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if session.candidates.isEmpty {
                    Text("No paired Bluetooth devices found. Pair your Sennheiser headphones with this Mac in Bluetooth Settings, then refresh.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(spacing: 0) {
                        Palette.strongRule.frame(height: 1)
                        ForEach(session.candidates) { candidate in
                            candidateRow(candidate)
                        }
                    }
                }
                HStack(spacing: 8) {
                    Button("Refresh") { session.refreshCandidates() }
                    Button("Bluetooth Settings…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    Spacer()
                    Button(showLog ? "Hide Frame Log" : "Show Frame Log") { showLog.toggle() }
                }
                .buttonStyle(QuietButtonStyle())
            }
            .frame(width: 440)
            .padding(.top, 26)
        }
    }

    private func candidateRow(_ candidate: Candidate) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.name)
                    .font(.system(size: 13, weight: .semibold))
                Text(candidate.isConnected ? "Connected to this Mac" : "Not connected to this Mac")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Connect") { session.connect(to: candidate) }
                .buttonStyle(InkButtonStyle())
                .keyboardShortcut(candidate == session.preferredCandidate ? .defaultAction : nil)
        }
        .padding(.vertical, 11)
        .overlay(alignment: .bottom) { Palette.rule.frame(height: 1) }
    }
}

// MARK: - Frame log

struct FrameLogView: View {
    @ObservedObject var log: FrameLog
    let canSend: Bool
    let onSend: (String) -> Void
    @State private var rawHex = "ff03000004951a05"

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Text("Frame log")
                    .font(.legend(12))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(log.text, forType: .string)
                }
                .disabled(log.entries.isEmpty)
                Button("Clear") { log.clear() }
                    .disabled(log.entries.isEmpty)
            }
            .buttonStyle(QuietButtonStyle())

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(log.entries) { entry in
                            row(entry)
                                .id(entry.id)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: log.entries.last?.id) { id in
                    if let id { proxy.scrollTo(id, anchor: .bottom) }
                }
                .onAppear {
                    if let id = log.entries.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
            .frame(height: 160)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.plate))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Palette.rule))

            HStack(spacing: 8) {
                TextField("Raw frame hex, e.g. ff03000004950603", text: $rawHex)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.plate))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Palette.rule))
                    .onSubmit(send)
                Button("Send", action: send)
                    .buttonStyle(QuietButtonStyle())
                    .disabled(!canSend || GAIA3.parseHex(rawHex) == nil)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 12)
    }

    private func send() {
        guard canSend, GAIA3.parseHex(rawHex) != nil else { return }
        onSend(rawHex)
    }

    private func row(_ entry: FrameLog.Entry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(Self.timeFormatter.string(from: entry.time))
                .foregroundStyle(.tertiary)
            Text(entry.direction.rawValue)
                .foregroundStyle(entry.direction == .info ? Color.secondary : Color.primary)
                .fontWeight(entry.direction == .tx ? .bold : .regular)
            Text(entry.summary)
            if !entry.hex.isEmpty {
                Text(entry.hex)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .textSelection(.enabled)
    }
}
