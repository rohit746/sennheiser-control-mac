import AppKit
import SwiftUI
import Combine
import GAIA3

final class MenuPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func performClose(_ sender: Any?) {
        onCancel?()
    }
}

/// Whether the panel is on screen, so its content can play its entrance each time it opens
/// and rest its animations while it is closed.
final class PanelPresentation: ObservableObject {
    @Published private(set) var isShown: Bool
    /// Counts openings; views keyed on it start afresh each time the panel opens.
    @Published private(set) var openings = 0

    init(isShown: Bool = false) {
        self.isShown = isShown
    }

    func open() {
        openings += 1
        isShown = true
    }

    func close() {
        isShown = false
    }
}

/// A content view with its origin at the top left, so what it holds stays put as the window changes height.
private final class TopAnchoredView: NSView {
    override var isFlipped: Bool { true }
}

final class StatusItemController: NSObject, NSWindowDelegate {
    private let session: HeadphoneSession
    private let openWindow: () -> Void
    private let presentation = PanelPresentation()
    private var item: NSStatusItem?
    private var panel: MenuPanel?
    private var subscription: AnyCancellable?
    private var outsideClickMonitor: Any?
    private var shadowClickMonitor: Any?
    private var lastDismissal = Date.distantPast
    private var isOpen = false
    /// The card's size as last laid out, and the size the window currently makes room for.
    private var cardSize = NSSize(width: MenuPanelView.width, height: 360)
    private var room = NSSize(width: MenuPanelView.width, height: 360)
    private var pendingShrink: DispatchWorkItem?
    private var pulse: Timer?
    private var pulseDimmed = false

    /// Height of the panel's SwiftUI canvas. It never changes: SwiftUI slides the card around if its
    /// hosting view is resized mid-animation, so the window just clips the canvas to the card.
    private static let canvasHeight: CGFloat = 1200

    init(session: HeadphoneSession, openWindow: @escaping () -> Void) {
        self.session = session
        self.openWindow = openWindow
        super.init()
        subscription = session.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshButton()
                DispatchQueue.main.async { self?.layoutPanel() }
            }
    }

    var isVisible: Bool {
        get { item != nil }
        set {
            guard newValue != isVisible else { return }
            if newValue {
                let created = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                created.button?.target = self
                created.button?.action = #selector(togglePanel(_:))
                created.button?.sendAction(on: [.leftMouseDown, .rightMouseDown])
                item = created
                refreshButton()
            } else if let item {
                dismissPanel()
                setPulsing(false)
                NSStatusBar.system.removeStatusItem(item)
                self.item = nil
            }
        }
    }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private func refreshButton() {
        guard let button = item?.button else { return }
        button.image = NSImage(systemSymbolName: "headphones", accessibilityDescription: "Sennheiser Control")
        button.imagePosition = .imageLeading
        button.title = session.device.battery.map { " \($0)%" } ?? ""
        button.appearsDisabled = !session.isConnected
        setPulsing(session.isConnecting)
    }

    /// Breathes the menu bar icon while a connection is being made.
    private func setPulsing(_ pulsing: Bool) {
        let pulsing = pulsing && !reduceMotion
        guard pulsing != (pulse != nil), let button = item?.button else { return }
        pulse?.invalidate()
        pulse = nil
        guard pulsing else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                button.animator().alphaValue = 1
            }
            return
        }
        pulseDimmed = false
        let timer = Timer(timeInterval: 0.8, repeats: true) { [weak self, weak button] _ in
            guard let self, let button else { return }
            self.pulseDimmed.toggle()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.8
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                button.animator().alphaValue = self.pulseDimmed ? 0.3 : 1
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        timer.fire()
        pulse = timer
    }

    // MARK: - Panel

    static func origin(below anchor: NSRect, size: NSSize, within visible: NSRect) -> NSPoint {
        let x = min(max(anchor.midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
        return NSPoint(x: x.rounded(), y: (anchor.minY - 6 - size.height).rounded())
    }

    @objc private func togglePanel(_ sender: Any?) {
        if isOpen {
            dismissPanel()
        } else if Date().timeIntervalSince(lastDismissal) > 0.25 {
            showPanel()
        }
    }

    func showPanel() {
        guard !isOpen, item?.button != nil else { return }
        if !session.isConnected && !session.isConnecting { session.refreshCandidates() }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        isOpen = true
        layoutPanel(force: true)
        if !panel.isVisible { panel.alphaValue = 0 }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(nil)
        item?.button?.highlight(true)
        fade(panel, to: 1, duration: 0.16)
        // One pass with the content at rest, so its entrance has somewhere to start from.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isOpen else { return }
            self.presentation.open()
        }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.dismissPanel()
        }
        // The window reaches past the card to make room for its shadow; a click there is a click outside.
        shadowClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let panel = self.panel, event.window === panel,
                  !self.cardFrame(in: panel).contains(event.locationInWindow) else { return event }
            self.dismissPanel()
            return nil
        }
    }

    func dismissPanel() {
        guard isOpen, let panel else { return }
        isOpen = false
        item?.button?.highlight(false)
        for monitor in [outsideClickMonitor, shadowClickMonitor].compactMap({ $0 }) {
            NSEvent.removeMonitor(monitor)
        }
        outsideClickMonitor = nil
        shadowClickMonitor = nil
        lastDismissal = Date()
        fade(panel, to: 0, duration: 0.12) { [weak self] in
            guard let self, !self.isOpen else { return }
            panel.orderOut(nil)
            self.presentation.close()
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        dismissPanel()
    }

    private func fade(_ panel: NSWindow, to alpha: CGFloat, duration: TimeInterval, completion: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: alpha > 0 ? .easeOut : .easeIn)
            panel.animator().alphaValue = alpha
        }, completionHandler: completion)
    }

    private func makePanel() -> MenuPanel {
        let panel = MenuPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        // The card draws its own shadow, which follows it while it changes height.
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary, .moveToActiveSpace]
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.dismissPanel() }

        let content = MenuPanelView(session: session, presentation: presentation, openWindow: { [weak self] in
            self?.dismissPanel()
            self?.openWindow()
        }, onResize: { [weak self] size in
            DispatchQueue.main.async { self?.cardDidResize(size) }
        })
        let hosting = NSHostingView(rootView: content)
        // The window follows the size the card reports rather than the hosting view's constraints.
        hosting.sizingOptions = []
        let margin = MenuPanelView.margin
        hosting.frame = NSRect(x: 0, y: 0, width: MenuPanelView.width + margin.leading + margin.trailing,
                               height: Self.canvasHeight)
        let container = TopAnchoredView()
        container.addSubview(hosting)
        panel.contentView = container
        return panel
    }

    /// The window grows with the card at once, so the card has room to animate into,
    /// and shrinks only once the card has settled.
    private func cardDidResize(_ size: CGSize) {
        cardSize = NSSize(width: size.width.rounded(.up), height: size.height.rounded(.up))
        pendingShrink?.cancel()
        pendingShrink = nil
        guard cardSize != room else { return }
        if cardSize.height > room.height || !isOpen {
            room = cardSize
            layoutPanel()
            return
        }
        let shrink = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.room = self.cardSize
            self.layoutPanel()
        }
        pendingShrink = shrink
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: shrink)
    }

    private func cardFrame(in panel: NSWindow) -> NSRect {
        let margin = MenuPanelView.margin
        let top = panel.frame.height - margin.top
        return NSRect(x: margin.leading, y: top - cardSize.height, width: cardSize.width, height: cardSize.height)
    }

    private func layoutPanel(force: Bool = false) {
        guard let panel, force || isOpen,
              let button = item?.button, let window = button.window else { return }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? anchor
        let card = NSRect(origin: Self.origin(below: anchor, size: room, within: visible), size: room)
        let margin = MenuPanelView.margin
        let frame = NSRect(x: card.minX - margin.leading, y: card.minY - margin.bottom,
                           width: card.width + margin.leading + margin.trailing,
                           height: card.height + margin.top + margin.bottom)
        guard frame != panel.frame else { return }
        if panel.isVisible, frame.size == panel.frame.size, !reduceMotion {
            // The status item moved, say because the battery reading appeared: glide along with it.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }
}

// MARK: - Content

struct MenuPanelView: View {
    static let width: CGFloat = 300
    static let cornerRadius: CGFloat = 16
    /// Clear room around the card for its shadow.
    static let margin = EdgeInsets(top: 4, leading: 24, bottom: 32, trailing: 24)

    @ObservedObject var session: HeadphoneSession
    @ObservedObject var presentation: PanelPresentation
    let openWindow: () -> Void
    var onResize: (CGSize) -> Void = { _ in }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var device: DeviceState { session.device }
    private var shown: Bool { presentation.isShown }

    private enum Stage: Hashable { case disconnected, connecting, connected }

    private var stage: Stage {
        session.isConnected ? .connected : session.isConnecting ? .connecting : .disconnected
    }

    var body: some View {
        card
            .background(GeometryReader { geometry in
                Color.clear.preference(key: CardSizeKey.self, value: geometry.size)
            })
            .onPreferenceChange(CardSizeKey.self, perform: onResize)
            .padding(Self.margin)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 15)
                .entrance(0, shown)
            SoundStage(tuning: stageTuning, isRunning: shown)
                .frame(height: 62)
                .padding(.top, 6)
                .entrance(1, shown)
            if stage == .connected {
                controls
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
                    .transition(.opacity)
            } else if stage == .disconnected, let candidate = session.preferredCandidate {
                connectButton(candidate)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .entrance(2, shown)
                    .transition(.opacity)
            }
            Palette.rule
                .frame(height: 1)
                .padding(.top, 16)
            PanelMenu(items: menuItems, isShown: shown)
                .padding(6)
                .entrance(5, shown)
        }
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        .background(PanelMaterial(cornerRadius: Self.cornerRadius))
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        .background(CardShadow(cornerRadius: Self.cornerRadius))
        .animation(reduceMotion ? nil : Motion.snap, value: device.noise.activeMode)
        .animation(reduceMotion ? nil : Motion.stage, value: stage)
        .animation(reduceMotion ? nil : Motion.stage, value: session.lastError)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.legend(15, .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                subtitle
                    .transition(.opacity)
            }
            Spacer(minLength: 0)
            if stage == .connected, let battery = device.battery {
                // Rebuilt on every opening, so the meter fills up again.
                BatteryMeter(level: battery, compact: true)
                    .id(presentation.openings)
                    .padding(.top, 2)
                    .transition(.opacity)
            }
        }
    }

    private var title: String {
        guard stage == .disconnected else { return session.deviceName }
        return session.preferredCandidate?.name ?? "Not connected"
    }

    private var stageTuning: StageTuning {
        switch stage {
        case .connected: return .listening(device.noise)
        case .connecting: return .searching
        case .disconnected: return .idle
        }
    }

    @ViewBuilder
    private var subtitle: some View {
        switch stage {
        case .connected:
            EmptyView()
        case .connecting:
            caption(session.statusMessage)
        case .disconnected:
            if let error = session.lastError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.alarm)
                    .fixedSize(horizontal: false, vertical: true)
            } else if session.preferredCandidate != nil {
                caption("Not connected")
            } else {
                caption(session.candidates.isEmpty ? "No paired headphones found" : "Choose your headphones in the app")
            }
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    private func connectButton(_ candidate: Candidate) -> some View {
        Button {
            session.connect(to: candidate)
        } label: {
            Text("Connect")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 1)
        }
        .buttonStyle(InkButtonStyle())
    }

    // MARK: Controls

    private var hasDetail: Bool {
        device.noise.activeMode == .anc || device.noise.activeMode == .transparency
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            ModeSelector(session: session, compact: true)
                .entrance(2, shown)
            if hasDetail {
                ModeDetail(session: session, stacked: true)
                    .padding(.horizontal, 4)
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
                    .entrance(3, shown)
            }
            equalizer
                .padding(.horizontal, 4)
                .entrance(4, shown)
        }
    }

    private var equalizer: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text("Equalizer")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                ValueMenu(label: "Equalizer preset", selection: device.eqPreset, choices: device.presetChoices) { name in
                    if let gains = EqPreset.gains(named: name) { session.applyEqPreset(gains) }
                }
                .font(.system(size: 12))
                .disabled(device.eqBands.count != EqPreset.bandLabels.count)
            }
            EqualizerSparkline(gains: device.eqBands, range: device.eqMinGain...device.eqMaxGain, drawn: shown ? 1 : 0)
                .frame(height: 58)
                .animation(shown && !reduceMotion ? .easeInOut(duration: 0.9).delay(0.2) : nil, value: shown)
        }
    }

    // MARK: Menu

    private var menuItems: [PanelMenu.Item] {
        var items = [PanelMenu.Item(id: "open", title: "Open Sennheiser Control", symbol: "macwindow", action: openWindow)]
        if stage != .disconnected {
            items.append(PanelMenu.Item(id: "connection", title: stage == .connecting ? "Cancel" : "Disconnect",
                                        symbol: "xmark.circle") { session.disconnect() })
        }
        items.append(PanelMenu.Item(id: "quit", title: "Quit", symbol: "power") { NSApp.terminate(nil) })
        return items
    }
}

private struct CardSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero

    /// Views that do not measure the card report the default; they must not hide the measurement.
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

private struct Entrance: ViewModifier {
    let order: Int
    let shown: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : -8)
            .animation(shown ? Motion.drop.delay(0.04 + Double(order) * 0.045) : nil, value: shown)
    }
}

private extension View {
    /// Fades the view in and drops it into place when the panel opens, after the views before it.
    func entrance(_ order: Int, _ shown: Bool) -> some View {
        modifier(Entrance(order: order, shown: shown))
    }
}

// MARK: - Card surface

/// Popover material, blurring whatever is behind the panel.
private struct PanelMaterial: NSViewRepresentable {
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        view.maskImage = Self.mask(cornerRadius: cornerRadius)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}

    /// A stretchable rounded rectangle with the same continuous corners as the card.
    private static func mask(cornerRadius: CGFloat) -> NSImage {
        let inset = (cornerRadius * 1.53).rounded(.up)
        let edge = 2 * inset + 1
        let shape = Path(roundedRect: CGRect(x: 0, y: 0, width: edge, height: edge),
                         cornerRadius: cornerRadius, style: .continuous).cgPath
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.addPath(shape)
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath()
            return true
        }
        image.capInsets = NSEdgeInsets(top: inset, left: inset, bottom: inset, right: inset)
        image.resizingMode = .stretch
        return image
    }
}

/// A soft shadow that falls only outside the card, so none of it shows through the material.
/// It is drawn in a frame reaching past the card, since a mask hides everything beyond its own frame.
private struct CardShadow: View {
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    private static let reach: CGFloat = 48

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.black)
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.5 : 0.18), radius: 12, y: 7)
            .padding(Self.reach)
            .mask(Surroundings(cornerRadius: cornerRadius, reach: Self.reach).fill(style: FillStyle(eoFill: true)))
            .padding(-Self.reach)
            .allowsHitTesting(false)
    }

    private struct Surroundings: Shape {
        let cornerRadius: CGFloat
        let reach: CGFloat

        func path(in rect: CGRect) -> Path {
            var path = Path(rect)
            path.addRoundedRect(in: rect.insetBy(dx: reach, dy: reach),
                                cornerSize: CGSize(width: cornerRadius, height: cornerRadius), style: .continuous)
            return path
        }
    }
}

// MARK: - Menu rows

/// The panel's menu rows. One highlight follows the pointer from row to row.
private struct PanelMenu: View {
    struct Item: Identifiable {
        let id: String
        let title: String
        let symbol: String
        let action: () -> Void
    }

    let items: [Item]
    let isShown: Bool

    @State private var hovered: String?
    @Namespace private var highlight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            ForEach(items) { item in
                Button(action: item.action) {
                    HStack(spacing: 9) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(hovered == item.id ? .primary : .secondary)
                            .frame(width: 16)
                        Text(item.title)
                            .font(.system(size: 13))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                    .matchedGeometryEffect(id: item.id, in: highlight)
                }
                .buttonStyle(.plain)
                .onHover { inside in
                    if inside {
                        hovered = item.id
                    } else if hovered == item.id {
                        hovered = nil
                    }
                }
            }
        }
        .background {
            if let hovered, items.contains(where: { $0.id == hovered }) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(0.1))
                    .matchedGeometryEffect(id: hovered, in: highlight, isSource: false)
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.26, dampingFraction: 0.86), value: hovered)
        .onChange(of: isShown) { shown in
            if !shown { hovered = nil }
        }
        .onChange(of: items.map(\.id)) { ids in
            // A row that goes away under the pointer never reports that the pointer left it.
            if let hovered, !ids.contains(hovered) { self.hovered = nil }
        }
    }
}
