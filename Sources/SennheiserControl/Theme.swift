import SwiftUI
import AppKit

/// The interface is ink on chalk (or chalk on carbon). Colour is kept for sound:
/// `world` is sound from outside, `heard` is what the headphones play.
enum Palette {
    static let ground = Color(nsColor: groundColor)
    static let groundColor = dynamic(light: 0xF1F2EF, dark: 0x1B1C1E)
    static let plate = Color(nsColor: dynamic(light: 0xFFFFFF, dark: 0x121314))
    static let ink = Color(nsColor: dynamic(light: 0x16181B, dark: 0xF1F2EE))
    static let onInk = Color(nsColor: dynamic(light: 0xF6F7F4, dark: 0x16181B))
    static let heard = Color(nsColor: dynamic(light: 0x3A47E0, dark: 0x8F9BFF))
    static let world = Color(nsColor: dynamic(light: 0xDB7C0E, dark: 0xFFB454))
    static let alarm = Color(nsColor: dynamic(light: 0xD23B32, dark: 0xFF6F62))
    static let well = Color.primary.opacity(0.06)
    static let rule = Color.primary.opacity(0.10)
    static let strongRule = Color.primary.opacity(0.26)

    private static func dynamic(light: Int, dark: Int) -> NSColor {
        NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
    }
}

extension Font {
    /// Wide lettering for names, headings and readouts, like the legends printed on audio equipment.
    static func legend(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight).width(.expanded)
    }
}

enum Motion {
    /// Selections and switches: quick, with a little give.
    static let snap = Animation.spring(response: 0.32, dampingFraction: 0.78)
    /// Whole-window changes such as connecting.
    static let stage = Animation.spring(response: 0.6, dampingFraction: 0.88)
    /// The sound stage settling into a new listening mode.
    static let field = Animation.spring(response: 0.8, dampingFraction: 0.9)
    /// Menu bar panel content dropping into place as the panel opens.
    static let drop = Animation.spring(response: 0.42, dampingFraction: 0.84)
}

extension View {
    /// Rolls digits instead of swapping them, where the system supports it.
    @ViewBuilder
    func numericTransition() -> some View {
        if #available(macOS 14.0, *) {
            contentTransition(.numericText())
        } else {
            self
        }
    }

    /// Fades the view in and lifts it into place once it appears.
    func reveal(delay: Double = 0, offset: CGFloat = 10) -> some View {
        modifier(Reveal(delay: delay, offset: offset))
    }
}

private struct Reveal: ViewModifier {
    let delay: Double
    let offset: CGFloat
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown || reduceMotion ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : offset)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(Motion.stage.delay(delay)) { shown = true }
            }
    }
}

struct Choice<Value: Hashable>: Identifiable {
    let value: Value
    let label: String
    var id: Value { value }

    init(_ value: Value, _ label: String) {
        self.value = value
        self.label = label
    }
}

// MARK: - Buttons

/// Plain button that gives a little under the pointer.
struct PressStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.98

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? pressedScale : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// The one action a view is there for.
struct InkButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Palette.onInk)
            .padding(.horizontal, 15)
            .padding(.vertical, 6)
            .background(Capsule().fill(Palette.ink))
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(isEnabled ? 1 : 0.4)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Everything else you can press.
struct QuietButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.primary.opacity(configuration.isPressed ? 0.16 : 0.08)))
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.4)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Switch

struct InkToggleStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            EmptyView()
        }
        .buttonStyle(SwitchStyle(isOn: configuration.isOn))
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}

/// The switch track and knob. The knob stretches while pressed and springs across on release.
private struct SwitchStyle: ButtonStyle {
    let isOn: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        Capsule()
            .fill(isOn ? Palette.ink : Color.primary.opacity(0.16))
            .frame(width: 36, height: 20)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? Palette.onInk : Color.white)
                    .shadow(color: .black.opacity(isOn ? 0 : 0.22), radius: 1, y: 0.5)
                    .frame(width: configuration.isPressed ? 19 : 15, height: 15)
                    .padding(2.5)
            }
            .contentShape(Capsule())
            .animation(reduceMotion ? nil : Motion.snap, value: isOn)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Slider

/// A level of sound, so its track fills in the colour of what is heard.
struct LevelSlider: View {
    let label: String
    let value: Double
    let range: ClosedRange<Double>
    var showsSteps = false
    let onChange: (Double) -> Void

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState private var dragging = false
    private let knob: CGFloat = 14

    var body: some View {
        GeometryReader { geometry in
            let travel = geometry.size.width - knob
            let span = range.upperBound - range.lowerBound
            let center = knob / 2 + CGFloat((min(max(value, range.lowerBound), range.upperBound) - range.lowerBound) / span) * travel
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.14))
                    .frame(height: 4)
                Capsule()
                    .fill(Palette.heard)
                    .frame(width: center, height: 4)
                if showsSteps {
                    ForEach(0...Int(span), id: \.self) { step in
                        Circle()
                            .fill(Color.primary.opacity(0.35))
                            .frame(width: 2, height: 2)
                            .offset(x: knob / 2 + CGFloat(Double(step) / span) * travel - 1, y: 7)
                    }
                }
                Circle()
                    .fill(Color.white)
                    .overlay(Circle().stroke(Color.black.opacity(0.18), lineWidth: 0.5))
                    .shadow(color: .black.opacity(dragging ? 0.3 : 0.25), radius: dragging ? 3 : 1.5, y: 0.5)
                    .frame(width: knob, height: knob)
                    .scaleEffect(dragging ? 1.2 : 1)
                    .offset(x: center - knob / 2)
            }
            .frame(height: geometry.size.height)
            .contentShape(Rectangle())
            .animation(reduceMotion ? nil : Motion.snap, value: dragging)
            .animation(dragging || reduceMotion ? nil : Motion.snap, value: value)
            .gesture(DragGesture(minimumDistance: 0)
                .updating($dragging) { _, state, _ in state = true }
                .onChanged { drag in
                    let fraction = min(max(Double((drag.location.x - knob / 2) / travel), 0), 1)
                    set((range.lowerBound + fraction * span).rounded())
                })
        }
        .frame(height: 20)
        .opacity(isEnabled ? 1 : 0.4)
        .focusable()
        .onMoveCommand { direction in
            if direction == .right || direction == .up { set(value + 1) }
            if direction == .left || direction == .down { set(value - 1) }
        }
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue("\(Int(value))")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: set(value + 1)
            case .decrement: set(value - 1)
            @unknown default: break
            }
        }
    }

    private func set(_ proposed: Double) {
        let clamped = min(max(proposed, range.lowerBound), range.upperBound)
        if clamped != value { onChange(clamped) }
    }
}

// MARK: - Choices

struct ValueMenu<Value: Hashable>: View {
    let label: String
    let selection: Value
    let choices: [Choice<Value>]
    let onSelect: (Value) -> Void

    var body: some View {
        Menu {
            Picker(label, selection: Binding(get: { selection }, set: onSelect)) {
                ForEach(choices) { choice in Text(choice.label).tag(choice.value) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text(choices.first { $0.value == selection }?.label ?? "—")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel(label)
    }
}

/// A few choices side by side; an ink plate slides to the one chosen.
struct SegmentedChoice<Value: Hashable>: View {
    let label: String
    let selection: Value?
    let choices: [Choice<Value>]
    let onSelect: (Value) -> Void

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var plate

    var body: some View {
        HStack(spacing: 2) {
            ForEach(choices) { choice in
                let selected = choice.value == selection
                Button {
                    onSelect(choice.value)
                } label: {
                    Text(choice.label)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(selected ? Palette.onInk : Color.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .background {
                            if selected {
                                Capsule()
                                    .fill(Palette.ink)
                                    .matchedGeometryEffect(id: "plate", in: plate)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.primary.opacity(0.08)))
        .opacity(isEnabled ? 1 : 0.4)
        .animation(reduceMotion ? nil : Motion.snap, value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

/// Named choices in a row, for when there is room to show them all.
struct ChipRow<Value: Hashable>: View {
    let label: String
    let selection: Value
    let choices: [Choice<Value>]
    let onSelect: (Value) -> Void

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var plate

    var body: some View {
        HStack(spacing: 0) {
            ForEach(choices) { choice in
                let selected = choice.value == selection
                Button {
                    onSelect(choice.value)
                } label: {
                    Text(choice.label)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(selected ? Palette.onInk : Color.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background {
                            if selected {
                                Capsule()
                                    .fill(Palette.ink)
                                    .matchedGeometryEffect(id: "plate", in: plate)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .fixedSize()
        .opacity(isEnabled ? 1 : 0.4)
        .animation(reduceMotion ? nil : Motion.snap, value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

// MARK: - Battery

struct BatteryMeter: View {
    let level: Int
    var compact = false

    @State private var filled = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var cell: CGSize { compact ? CGSize(width: 23, height: 11) : CGSize(width: 27, height: 13) }

    private var charge: CGFloat {
        guard filled || reduceMotion else { return 0 }
        return CGFloat(min(max(level, 0), 100)) / 100
    }

    var body: some View {
        HStack(spacing: compact ? 6 : 8) {
            HStack(spacing: 1.5) {
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.42), lineWidth: 1)
                    .frame(width: cell.width, height: cell.height)
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 1.75, style: .continuous)
                            .fill(level <= 20 ? Palette.alarm : Palette.ink)
                            .frame(width: max((cell.width - 4) * charge, charge > 0 ? 2 : 0), height: cell.height - 4)
                            .padding(2)
                            .animation(reduceMotion ? nil : .easeOut(duration: 0.55), value: charge)
                    }
                Capsule()
                    .fill(Color.primary.opacity(0.42))
                    .frame(width: 2, height: 5)
            }
            Text("\(level)%")
                .font(.legend(compact ? 12 : 13))
                .monospacedDigit()
                .numericTransition()
                .animation(reduceMotion ? nil : .default, value: level)
        }
        .onAppear { filled = true }
        .accessibilityElement()
        .accessibilityLabel("Battery")
        .accessibilityValue("\(level) percent")
    }
}

// MARK: - Settings

struct SettingGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.legend(12))
                .padding(.bottom, 8)
                .accessibilityAddTraits(.isHeader)
            Palette.strongRule.frame(height: 1)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SettingRow<Control: View>: View {
    let title: String
    var isAvailable = true
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .foregroundStyle(isAvailable ? .primary : .secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            control()
                .layoutPriority(1)
        }
        .font(.system(size: 13))
        .frame(minHeight: 38)
        .overlay(alignment: .bottom) { Palette.rule.frame(height: 1) }
        .disabled(!isAvailable)
    }
}

struct ToggleRow: View {
    let title: String
    let value: Bool?
    let onChange: (Bool) -> Void

    var body: some View {
        SettingRow(title: title, isAvailable: value != nil) {
            Toggle(title, isOn: Binding(get: { value ?? false }, set: onChange))
                .toggleStyle(InkToggleStyle())
        }
    }
}
