import SwiftUI
import GAIA3

/// How the sound stage is drawn. Every component interpolates, so a change of
/// listening mode animates as one continuous movement.
struct StageTuning: VectorArithmetic {
    /// Outside sound arriving at the ear cups, 0…1.
    var presence: Double
    /// Share of the outside sound that gets past the cups, 0…1.
    var pass: Double
    /// 0: what gets past leaks through the cups. 1: the headphones play it.
    var relay: Double
    /// Anti-noise meeting the sound that gets in, 0…1.
    var cancel: Double
    /// How closed the cups are drawn, 0…1.
    var seal: Double
    /// 0 draws a solid cup, 1 an open, dashed one.
    var porous: Double
    /// Adaptive noise cancellation: the cups breathe.
    var adaptive: Double
    /// Pulses going out from the listener while connecting.
    var search: Double

    static let idle = StageTuning(presence: 0, pass: 0, relay: 0, cancel: 0, seal: 0, porous: 0, adaptive: 0, search: 0)
    static let searching = StageTuning(presence: 0, pass: 0, relay: 0, cancel: 0, seal: 0, porous: 0, adaptive: 0, search: 1)

    static func listening(_ noise: NoiseControl) -> StageTuning {
        switch noise.activeMode {
        case .anc:
            return StageTuning(presence: 1, pass: 0, relay: 0, cancel: 1, seal: 1, porous: 0,
                               adaptive: noise.adaptiveANC == true ? 1 : 0, search: 0)
        case .transparency:
            return StageTuning(presence: 1, pass: 0.3 + 0.7 * Double(noise.transparencyLevel) / 100, relay: 1,
                               cancel: 0, seal: 1, porous: 1, adaptive: 0, search: 0)
        case .off, nil:
            return StageTuning(presence: 1, pass: 0.3, relay: 0, cancel: 0, seal: 0, porous: 0, adaptive: 0, search: 0)
        }
    }

    private var components: [Double] { [presence, pass, relay, cancel, seal, porous, adaptive, search] }

    private init(_ values: [Double]) {
        self.init(presence: values[0], pass: values[1], relay: values[2], cancel: values[3],
                  seal: values[4], porous: values[5], adaptive: values[6], search: values[7])
    }

    init(presence: Double, pass: Double, relay: Double, cancel: Double,
         seal: Double, porous: Double, adaptive: Double, search: Double) {
        self.presence = presence
        self.pass = pass
        self.relay = relay
        self.cancel = cancel
        self.seal = seal
        self.porous = porous
        self.adaptive = adaptive
        self.search = search
    }

    static var zero: StageTuning { StageTuning(Array(repeating: 0, count: 8)) }

    static func + (lhs: StageTuning, rhs: StageTuning) -> StageTuning {
        StageTuning(zip(lhs.components, rhs.components).map(+))
    }

    static func - (lhs: StageTuning, rhs: StageTuning) -> StageTuning {
        StageTuning(zip(lhs.components, rhs.components).map(-))
    }

    mutating func scale(by factor: Double) { self = StageTuning(components.map { $0 * factor }) }

    var magnitudeSquared: Double { components.reduce(0) { $0 + $1 * $1 } }
}

/// A cross-section through the headphones: the listener in the middle, an ear cup on
/// either side, and the outside world beyond. Outside sound travels in from both edges.
/// Noise cancellation meets it with its mirror image and leaves a flat line, transparency
/// plays it on smoothed, and with noise control off a muffled remainder leaks through.
struct SoundStage: View {
    let tuning: StageTuning
    /// Whether the stage moves. It also rests while its window is inactive.
    var isRunning = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        StageSurface(tuning: tuning, still: reduceMotion, paused: !isRunning)
            .animation(reduceMotion ? nil : Motion.field, value: tuning)
            .accessibilityHidden(true)
    }
}

private struct StageSurface: View, Animatable {
    var tuning: StageTuning
    let still: Bool
    let paused: Bool

    var animatableData: StageTuning {
        get { tuning }
        set { tuning = newValue }
    }

    @Environment(\.controlActiveState) private var activeState

    private static let pulseCount = 3
    private static let pulsePeriod = 2.6

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: still || paused || activeState == .inactive)) { timeline in
            Canvas { context, size in
                draw(in: &context, size: size, time: still ? 2.4 : timeline.date.timeIntervalSinceReferenceDate)
            }
        }
    }

    /// The stage is laid out for a height of 150 points and scales down from there.
    private func draw(in context: inout GraphicsContext, size: CGSize, time: Double) {
        let width = Double(size.width)
        let mid = Double(size.height) / 2
        let centre = width / 2
        let scale = min(max(Double(size.height) / 150, 0.4), 1.15)
        let weight = max(min(scale, 1), 0.7)
        let reach = min(width * 0.2, 200)
        let cupWidth = max(13 * scale, 6)
        let cupHeight = min(Double(size.height) * 0.6, 104) * (1 + 0.06 * tuning.adaptive * sin(time * 1.3))
        let clearance = cupWidth / 2 + 5 * scale
        let inner = reach - clearance
        let amplitude = min(Double(size.height) * 0.25, 42) / 1.3
        let fine = scale < 0.6 ? 0.45 : 1.0

        func wave(_ radius: Double, seed: Double) -> (low: Double, high: Double) {
            let d = radius / scale
            let low = 0.62 * sin(d / 27 + time * 1.5 + seed) + 0.38 * sin(d / 15.5 + time * 2.6 + 1.7 * seed)
            let high = 0.34 * sin(d / 6.2 + time * 6.1 + 2.3 * seed) + 0.2 * sin(d / 3.4 + time * 9.5 + 0.6 * seed)
                + 0.1 * sin(d / 2.1 + time * 13 + 3.1 * seed)
            return (low, high * fine)
        }

        func trace(from start: Double, to end: Double, step: Double = 1.5, _ offset: (Double) -> Double) -> Path {
            var path = Path()
            guard end > start else { return path }
            var radius = start
            var first = true
            while true {
                let point = CGPoint(x: radius, y: offset(radius))
                if first { path.move(to: point) } else { path.addLine(to: point) }
                first = false
                if radius >= end { break }
                radius = min(radius + step, end)
            }
            return path
        }

        // Rest line: where sound would be, before there is any.
        let rest = 0.16 * (1 - tuning.presence)
        if rest > 0.005 {
            var line = Path()
            for (from, to) in [(0, centre - reach - clearance), (centre - inner, centre + inner), (centre + reach + clearance, width)] {
                line.move(to: CGPoint(x: from, y: mid))
                line.addLine(to: CGPoint(x: to, y: mid))
            }
            context.stroke(line, with: .color(Palette.ink.opacity(rest)), lineWidth: 1.2 * weight)
        }

        for side in [-1.0, 1.0] {
            let seed = side < 0 ? 0.0 : 4.1
            // Paths are traced by distance from the listener, then placed on this side.
            let place = CGAffineTransform(translationX: centre, y: 0).scaledBy(x: side, y: 1)
            let edge = width / 2
            let outside = reach + clearance

            if tuning.presence > 0.005, edge - outside > 4 {
                let fadeLength = min(80 * scale, (edge - outside) * 0.6)
                let layers: [(gain: Double, alpha: Double, width: Double)] = [(0.46, 0.22, 1), (0.72, 0.42, 1.2), (1, 0.95, 1.6)]
                for (index, layer) in layers.enumerated() {
                    let path = trace(from: outside, to: edge) { radius in
                        let sound = wave(radius, seed: seed + Double(2 - index) * 1.9)
                        return mid + amplitude * layer.gain * smoothstep(0, fadeLength, edge - radius) * (sound.low + sound.high)
                    }
                    context.stroke(path.applying(place), with: .color(Palette.world.opacity(tuning.presence * layer.alpha)),
                                   style: StrokeStyle(lineWidth: layer.width * weight, lineCap: .round, lineJoin: .round))
                }
            }

            // What leaks past the cup with noise control off: quieter, and without its treble.
            let leak = tuning.presence * (1 - tuning.relay) * (1 - tuning.cancel)
            if leak > 0.005 {
                let path = trace(from: 0, to: inner) { radius in
                    let sound = wave(radius, seed: seed)
                    return mid + amplitude * tuning.pass * taper(radius / inner) * (sound.low + 0.3 * sound.high)
                }
                context.stroke(path.applying(place), with: .color(Palette.world.opacity(leak * 0.85)),
                               style: StrokeStyle(lineWidth: 1.5 * weight, lineCap: .round, lineJoin: .round))
            }

            // What the headphones play: the outside, smoothed, or nothing at all.
            let played = max(tuning.relay, tuning.cancel) * max(tuning.presence, tuning.search)
            if played > 0.005 {
                let path = trace(from: 0, to: inner) { radius in
                    let sound = wave(radius, seed: seed)
                    return mid + amplitude * tuning.pass * tuning.relay * taper(radius / inner) * (sound.low + 0.12 * sound.high)
                }
                context.stroke(path.applying(place), with: .color(Palette.heard.opacity(played)),
                               style: StrokeStyle(lineWidth: 1.8 * weight, lineCap: .round, lineJoin: .round))
            }

            // Noise cancellation: what gets in, and its mirror image, die out together.
            let cancelling = tuning.cancel * tuning.presence
            if cancelling > 0.005 {
                let span = inner * 0.7
                func remainder(_ sign: Double) -> Path {
                    trace(from: inner - span, to: inner) { radius in
                        let sound = wave(radius, seed: seed)
                        let depth = (inner - radius) / span
                        return mid + sign * amplitude * 0.85 * exp(-depth * 3) * (1 - smoothstep(0.6, 1, depth))
                            * (sound.low + 0.6 * sound.high)
                    }.applying(place)
                }
                let start = CGPoint(x: centre + side * inner, y: mid)
                let end = CGPoint(x: centre + side * (inner - span), y: mid)
                func fading(_ color: Color, _ alpha: Double) -> GraphicsContext.Shading {
                    .linearGradient(Gradient(colors: [color.opacity(alpha), color.opacity(0)]), startPoint: start, endPoint: end)
                }
                context.stroke(remainder(1), with: fading(Palette.world, cancelling * 0.9),
                               style: StrokeStyle(lineWidth: 1.5 * weight, lineCap: .round, lineJoin: .round))
                context.stroke(remainder(-1), with: fading(Palette.heard, cancelling),
                               style: StrokeStyle(lineWidth: 1.5 * weight, lineCap: .round, lineJoin: .round,
                                                  dash: [3.5 * weight, 3.5 * weight]))
            }
        }

        // Connecting: pulses go out from the listener, looking for the headphones.
        for index in 0..<Self.pulseCount where tuning.search > 0.005 {
            let cycle = time / Self.pulsePeriod + Double(index) / Double(Self.pulseCount)
            let phase = cycle - cycle.rounded(.down)
            let radius = 6 * scale + (reach * 1.7 - 6 * scale) * phase
            let alpha = tuning.search * (1 - phase) * smoothstep(0, 0.1, phase)
            // Arcs rather than rings, kept short enough to stay inside the stage.
            let sweep = min(asin(min((mid - 8) / radius, 1)), 0.75)
            for facing in [0.0, Double.pi] {
                var arc = Path()
                arc.addArc(center: CGPoint(x: centre, y: mid), radius: radius, startAngle: .radians(facing - sweep),
                           endAngle: .radians(facing + sweep), clockwise: false)
                context.stroke(arc, with: .color(Palette.heard.opacity(alpha * 0.9)),
                               style: StrokeStyle(lineWidth: 1.8 * weight, lineCap: .round))
            }
        }

        // The ear cups: solid when they seal, dashed when they let sound through, an outline otherwise.
        let strength = 0.34 + 0.66 * max(tuning.seal, tuning.search * 0.5)
        for side in [-1.0, 1.0] {
            let rect = CGRect(x: centre + side * reach - cupWidth / 2, y: mid - cupHeight / 2, width: cupWidth, height: cupHeight)
            let cup = Path(roundedRect: rect, cornerRadius: cupWidth / 2, style: .continuous)
            let solid = tuning.seal * (1 - tuning.porous)
            if solid > 0.005 { context.fill(cup, with: .color(Palette.ink.opacity(solid))) }
            let perimeter = 2 * (cupHeight - cupWidth) + Double.pi * cupWidth
            let dash = perimeter / max((perimeter / (7.5 * scale)).rounded(), 1)
            let opening = dash * 0.42 * tuning.porous
            context.stroke(cup, with: .color(Palette.ink.opacity(strength)),
                           style: StrokeStyle(lineWidth: 1.6 * weight, lineCap: .butt,
                                              dash: opening > 0.05 ? [dash - opening, opening] : []))
        }

        context.fill(circle(x: centre, y: mid, radius: max(3.2 * scale, 2)), with: .color(Palette.ink))
    }

    /// Sound settles as it reaches the listener.
    private func taper(_ fraction: Double) -> Double { smoothstep(0.03, 0.5, fraction) }

    private func circle(x: Double, y: Double, radius: Double) -> Path {
        Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: 2 * radius, height: 2 * radius))
    }

    private func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }
}

/// A listening mode in the stage's own terms: sound arrives from the left, meets a cup,
/// and what comes out on the right is what you hear.
struct ModeGlyph: View {
    let mode: NoiseControl.Mode

    var body: some View {
        Canvas { context, size in
            let mid = size.height / 2
            let cup = CGRect(x: size.width / 2 - 2.5, y: 1, width: 5, height: size.height - 2)
            let line = StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)

            func ripple(from start: CGFloat, to end: CGFloat, height: CGFloat) -> Path {
                var path = Path()
                let steps = 20
                for step in 0...steps {
                    let progress = CGFloat(step) / CGFloat(steps)
                    let point = CGPoint(x: start + (end - start) * progress, y: mid - height * sin(progress * 2.5 * .pi))
                    if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
                return path
            }

            context.stroke(ripple(from: 1, to: cup.minX - 2.5, height: 4.2), with: .foreground, style: line)
            let shape = Path(roundedRect: cup, cornerRadius: 2.5, style: .continuous)
            let after: (start: CGFloat, end: CGFloat) = (cup.maxX + 2.5, size.width - 1)
            switch mode {
            case .anc:
                context.fill(shape, with: .foreground)
                context.stroke(ripple(from: after.start, to: after.end, height: 0), with: .foreground, style: line)
            case .transparency:
                context.stroke(shape, with: .foreground, style: StrokeStyle(lineWidth: 1.3, dash: [2.4, 1.9]))
                context.stroke(ripple(from: after.start, to: after.end, height: 4.2), with: .foreground, style: line)
            case .off:
                context.stroke(shape, with: .foreground, lineWidth: 1.1)
                context.stroke(ripple(from: after.start, to: after.end, height: 1.7), with: .foreground, style: line)
            }
        }
        .frame(width: 34, height: 16)
        .accessibilityHidden(true)
    }
}
