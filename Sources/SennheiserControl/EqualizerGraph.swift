import SwiftUI
import GAIA3

struct GainVector: VectorArithmetic {
    var values: [Double]

    static var zero: GainVector { GainVector(values: []) }

    static func + (lhs: GainVector, rhs: GainVector) -> GainVector { combine(lhs, rhs, +) }

    static func - (lhs: GainVector, rhs: GainVector) -> GainVector { combine(lhs, rhs, -) }

    mutating func scale(by factor: Double) { values = values.map { $0 * factor } }

    var magnitudeSquared: Double { values.reduce(0) { $0 + $1 * $1 } }

    private static func combine(_ lhs: GainVector, _ rhs: GainVector, _ operation: (Double, Double) -> Double) -> GainVector {
        let count = max(lhs.values.count, rhs.values.count)
        return GainVector(values: (0..<count).map { index in
            operation(index < lhs.values.count ? lhs.values[index] : 0, index < rhs.values.count ? rhs.values[index] : 0)
        })
    }
}

extension Path {
    static func monotone(through points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 2 else {
            points.dropFirst().forEach { path.addLine(to: $0) }
            return path
        }
        let last = points.count - 1
        var slopes = [CGFloat](repeating: 0, count: last)
        for index in 0..<last {
            let dx = points[index + 1].x - points[index].x
            slopes[index] = dx == 0 ? 0 : (points[index + 1].y - points[index].y) / dx
        }
        var tangents = [CGFloat](repeating: 0, count: points.count)
        tangents[0] = slopes[0]
        tangents[last] = slopes[last - 1]
        for index in 1..<last {
            tangents[index] = slopes[index - 1] * slopes[index] <= 0 ? 0 : (slopes[index - 1] + slopes[index]) / 2
        }
        for index in 0..<last {
            if slopes[index] == 0 {
                tangents[index] = 0
                tangents[index + 1] = 0
                continue
            }
            let a = tangents[index] / slopes[index]
            let b = tangents[index + 1] / slopes[index]
            let magnitude = a * a + b * b
            if magnitude > 9 {
                let limit = 3 / magnitude.squareRoot()
                tangents[index] = limit * a * slopes[index]
                tangents[index + 1] = limit * b * slopes[index]
            }
        }
        for index in 0..<last {
            let third = (points[index + 1].x - points[index].x) / 3
            path.addCurve(to: points[index + 1],
                          control1: CGPoint(x: points[index].x + third, y: points[index].y + tangents[index] * third),
                          control2: CGPoint(x: points[index + 1].x - third, y: points[index + 1].y - tangents[index + 1] * third))
        }
        return path
    }
}

struct EqualizerCurve: Shape {
    var gains: GainVector
    let positions: [CGFloat]
    let range: ClosedRange<Double>
    var closed = false

    var animatableData: GainVector {
        get { gains }
        set { gains = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let count = min(gains.values.count, positions.count)
        guard count > 0 else { return Path() }
        func y(_ gain: Double) -> CGFloat {
            let clamped = min(max(gain, range.lowerBound), range.upperBound)
            return rect.minY + CGFloat((range.upperBound - clamped) / (range.upperBound - range.lowerBound)) * rect.height
        }
        var points = [CGPoint(x: rect.minX, y: y(gains.values[0]))]
        for index in 0..<count {
            points.append(CGPoint(x: rect.minX + positions[index] * rect.width, y: y(gains.values[index])))
        }
        points.append(CGPoint(x: rect.maxX, y: y(gains.values[count - 1])))
        var path = Path.monotone(through: points)
        if closed {
            path.addLine(to: CGPoint(x: rect.maxX, y: y(0)))
            path.addLine(to: CGPoint(x: rect.minX, y: y(0)))
            path.closeSubpath()
        }
        return path
    }
}

struct EqualizerGraph: View {
    let gains: [Float]
    let range: ClosedRange<Float>
    let onChange: (Int, Float) -> Void

    @State private var grab: (band: Int, gain: Float)?
    @State private var grabMissed = false
    @State private var hoveredBand: Int?
    @FocusState private var focusedBand: Int?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let insets = EdgeInsets(top: 36, leading: 44, bottom: 34, trailing: 30)
    /// Ruled like the paper frequency responses are plotted on: every decade, and the steps within it.
    private static let decades: [Double] = [100, 1000, 10000]
    private static let decadeSteps: [Double] = [10, 100, 1000].flatMap { decade in (2...9).map { Double($0) * decade } }
        + [20000]
    private static let lowest = 20.0
    private static let highest = 20000.0
    private let step: Float = 0.5
    private let reach: CGFloat = 20

    private var positions: [CGFloat] { Self.positions(bandCount: gains.count) }

    static func positions(bandCount: Int) -> [CGFloat] {
        guard bandCount == EqPreset.bandFrequencies.count else {
            return (0..<bandCount).map { CGFloat($0 + 1) / CGFloat(bandCount + 1) }
        }
        return EqPreset.bandFrequencies.map(position)
    }

    private static func position(of frequency: Double) -> CGFloat {
        CGFloat((log10(frequency) - log10(lowest)) / (log10(highest) - log10(lowest)))
    }

    private var vector: GainVector { GainVector(values: gains.map(Double.init)) }

    private var decibelRange: ClosedRange<Double> { Double(range.lowerBound)...Double(range.upperBound) }

    private var gridGains: [Float] {
        stride(from: range.lowerBound, through: range.upperBound, by: 3).map { $0 }
    }

    var body: some View {
        GeometryReader { geometry in
            let plot = CGRect(x: Self.insets.leading, y: Self.insets.top,
                              width: geometry.size.width - Self.insets.leading - Self.insets.trailing,
                              height: geometry.size.height - Self.insets.top - Self.insets.bottom)
            ZStack(alignment: .topLeading) {
                grid(in: plot)
                lane(in: plot)
                Group {
                    EqualizerCurve(gains: vector, positions: positions, range: decibelRange, closed: true)
                        .fill(Palette.heard.opacity(colorScheme == .dark ? 0.2 : 0.13))
                    EqualizerCurve(gains: vector, positions: positions, range: decibelRange)
                        .stroke(Palette.heard, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                }
                .padding(Self.insets)
                .animation(grab == nil && !reduceMotion ? .spring(response: 0.4, dampingFraction: 0.82) : nil, value: gains)
                ForEach(gains.indices, id: \.self) { index in
                    handle(index, in: plot)
                }
            }
            .contentShape(Rectangle())
            .gesture(drag(in: plot))
            .onContinuousHover { phase in
                switch phase {
                case .active(let location): hoveredBand = band(near: location, in: plot)
                case .ended: hoveredBand = nil
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.plate))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Palette.rule))
    }

    private func point(_ index: Int, in plot: CGRect) -> CGPoint {
        let gain = min(max(gains[index], range.lowerBound), range.upperBound)
        return CGPoint(x: plot.minX + positions[index] * plot.width,
                       y: plot.minY + CGFloat((range.upperBound - gain) / (range.upperBound - range.lowerBound)) * plot.height)
    }

    private func grid(in plot: CGRect) -> some View {
        ZStack(alignment: .topLeading) {
            Path { path in
                for frequency in Self.decadeSteps {
                    let x = plot.minX + Self.position(of: frequency) * plot.width
                    path.move(to: CGPoint(x: x, y: plot.minY))
                    path.addLine(to: CGPoint(x: x, y: plot.maxY))
                }
            }
            .stroke(Color.primary.opacity(0.055), lineWidth: 1)
            Path { path in
                for frequency in Self.decades {
                    let x = plot.minX + Self.position(of: frequency) * plot.width
                    path.move(to: CGPoint(x: x, y: plot.minY))
                    path.addLine(to: CGPoint(x: x, y: plot.maxY))
                }
                for gain in gridGains where gain != 0 {
                    let y = plot.minY + CGFloat((range.upperBound - gain) / (range.upperBound - range.lowerBound)) * plot.height
                    path.move(to: CGPoint(x: plot.minX, y: y))
                    path.addLine(to: CGPoint(x: plot.maxX, y: y))
                }
            }
            .stroke(Palette.rule, lineWidth: 1)
            Path { path in
                let y = plot.minY + CGFloat(range.upperBound / (range.upperBound - range.lowerBound)) * plot.height
                path.move(to: CGPoint(x: plot.minX, y: y))
                path.addLine(to: CGPoint(x: plot.maxX, y: y))
            }
            .stroke(Palette.strongRule, lineWidth: 1)
            ForEach(gridGains, id: \.self) { gain in
                Text(gain == 0 ? "0" : String(format: "%+g", gain).replacingOccurrences(of: "-", with: "−"))
                    .frame(width: 30, alignment: .trailing)
                    .position(x: plot.minX - 23,
                              y: plot.minY + CGFloat((range.upperBound - gain) / (range.upperBound - range.lowerBound)) * plot.height)
            }
            Text("dB")
                .position(x: plot.minX - 15, y: plot.minY - 20)
            ForEach(gains.indices, id: \.self) { index in
                Text(EqPreset.bandLabels.indices.contains(index) && gains.count == EqPreset.bandLabels.count
                     ? EqPreset.bandLabels[index] : "\(index + 1)")
                    .position(x: plot.minX + positions[index] * plot.width, y: plot.maxY + 17)
            }
            Text("Hz")
                .position(x: plot.maxX + 14, y: plot.maxY + 17)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }

    private var activeBand: Int? { grab?.band ?? focusedBand ?? hoveredBand }

    /// A soft column behind the band under the pointer, so it is clear which band a drag will move.
    private func lane(in plot: CGRect) -> some View {
        let x = activeBand.map { plot.minX + positions[$0] * plot.width } ?? plot.midX
        return RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(Color.primary.opacity(0.06))
            .frame(width: 30, height: plot.height + 24)
            .position(x: x, y: plot.midY)
            .opacity(activeBand == nil ? 0 : 1)
            .animation(reduceMotion ? nil : Motion.snap, value: activeBand)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func handle(_ index: Int, in plot: CGRect) -> some View {
        let center = point(index, in: plot)
        let active = grab?.band == index || hoveredBand == index || focusedBand == index
        return ZStack {
            Text(gains[index] == 0 ? "0.0" : String(format: "%+.1f", gains[index]).replacingOccurrences(of: "-", with: "−"))
                .font(.legend(10))
                .monospacedDigit()
                .foregroundStyle(active ? .primary : .secondary)
                .fixedSize()
                .offset(y: -20)
            Circle()
                .fill(active ? Palette.heard : Palette.plate)
                .overlay(Circle().stroke(Palette.heard, lineWidth: 2.5))
                .frame(width: 14, height: 14)
                .scaleEffect(active ? 1.25 : 1)
                .animation(reduceMotion ? nil : Motion.snap, value: active)
        }
        .frame(width: 2 * reach, height: 2 * reach)
        .contentShape(Rectangle())
        .focusable()
        .focused($focusedBand, equals: index)
        .onMoveCommand { direction in
            if direction == .up { set(index, gains[index] + step) }
            if direction == .down { set(index, gains[index] - step) }
        }
        .accessibilityElement()
        .accessibilityLabel(EqPreset.bandLabels.indices.contains(index) ? "\(EqPreset.bandLabels[index]) hertz" : "Band \(index + 1)")
        .accessibilityValue(String(format: "%+.1f decibels", gains[index]))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: set(index, gains[index] + step)
            case .decrement: set(index, gains[index] - step)
            @unknown default: break
            }
        }
        .position(center)
    }

    private func band(near location: CGPoint, in plot: CGRect) -> Int? {
        gains.indices.first { index in
            let center = point(index, in: plot)
            return abs(center.x - location.x) <= reach && abs(center.y - location.y) <= reach
        }
    }

    private func drag(in plot: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if grab == nil, !grabMissed {
                    if let index = band(near: value.startLocation, in: plot) {
                        grab = (index, gains[index])
                    } else {
                        grabMissed = true
                    }
                }
                guard let grab else { return }
                let delta = Float(-value.translation.height / plot.height) * (range.upperBound - range.lowerBound)
                set(grab.band, grab.gain + delta)
            }
            .onEnded { _ in
                grab = nil
                grabMissed = false
            }
    }

    private func set(_ index: Int, _ proposed: Float) {
        let stepped = (min(max(proposed, range.lowerBound), range.upperBound) / step).rounded() * step
        if stepped != gains[index] { onChange(index, stepped) }
    }
}

struct EqualizerSparkline: View {
    let gains: [Float]
    let range: ClosedRange<Float>
    /// How much of the curve is drawn, 0…1, so it can trace itself in from the left.
    var drawn: CGFloat = 1

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let vector = GainVector(values: gains.map(Double.init))
        let positions = EqualizerGraph.positions(bandCount: gains.count)
        let decibels = Double(range.lowerBound)...Double(range.upperBound)
        ZStack {
            GeometryReader { geometry in
                Path { path in
                    let y = CGFloat(range.upperBound / (range.upperBound - range.lowerBound)) * geometry.size.height
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: geometry.size.width, y: y))
                }
                .stroke(Palette.strongRule, lineWidth: 1)
            }
            EqualizerCurve(gains: vector, positions: positions, range: decibels, closed: true)
                .fill(Palette.heard.opacity(colorScheme == .dark ? 0.2 : 0.13))
                .opacity(drawn)
            EqualizerCurve(gains: vector, positions: positions, range: decibels)
                .trim(from: 0, to: drawn)
                .stroke(Palette.heard, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
        .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.82), value: gains)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Palette.plate))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Palette.rule))
        .accessibilityElement()
        .accessibilityLabel("Equalizer curve")
        .accessibilityValue(gains.map { String(format: "%+.1f", $0) }.joined(separator: ", "))
    }
}
