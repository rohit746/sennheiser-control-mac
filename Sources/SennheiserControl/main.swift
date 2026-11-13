import AppKit
import SwiftUI
import IOBluetooth
import GAIA3

let arguments = CommandLine.arguments

if arguments.contains("--selftest") {
    runSelfTest()
    exit(0)
}

if arguments.contains("--services") {
    dumpServices()
    exit(0)
}

if arguments.contains("--probe") {
    runProbe()
    exit(0)
}

if let flag = arguments.firstIndex(of: "--snapshot"), arguments.indices.contains(flag + 1) {
    runSnapshot(to: arguments[flag + 1])
    exit(0)
}

let application = NSApplication.shared
let appDelegate = AppDelegate(session: arguments.contains("--demo") ? makeDemoSession() : HeadphoneSession())
application.delegate = appDelegate
application.setActivationPolicy(.regular)
application.run()

// MARK: - CLI modes

func makeDemoSession(directory: SimulatedDirectory = SimulatedDirectory()) -> HeadphoneSession {
    let settings = MemorySettings()
    settings.set(SimulatedDirectory.address, forKey: "lastDeviceAddress")
    return HeadphoneSession(directory: directory, settings: settings)
}

func runSelfTest() {
    var failures = 0
    func check(_ condition: Bool, _ name: String) {
        print(condition ? "PASS  \(name)" : "FAIL  \(name)")
        if !condition { failures += 1 }
    }

    check(GAIA3.encode(command: Cmd.batteryGet) == [0xFF, 0x03, 0x00, 0x00, 0x04, 0x95, 0x06, 0x03],
          "encode GET battery")

    check(GAIA3.encode(command: Cmd.ancOnSet, payload: [1]) == [0xFF, 0x03, 0x00, 0x01, 0x04, 0x95, 0x1A, 0x04, 0x01],
          "encode SET ANC on")

    let (batteryFrames, batteryRemainder) = GAIA3.split([0xFF, 0x03, 0x00, 0x01, 0x04, 0x95, 0x07, 0x03, 0x2A])
    check(batteryFrames.count == 1 && batteryFrames[0].payload == [0x2A] && batteryRemainder.isEmpty,
          "decode battery response (42%)")
    check(batteryFrames.first?.kind == .response, "classify response kind")

    let (setFrames, _) = GAIA3.split([0xFF, 0x03, 0x00, 0x00, 0x04, 0x95, 0x1B, 0x04])
    check(setFrames.first?.command == 0x1B04, "decode SET ANC response id")

    let (resyncFrames, resyncRemainder) = GAIA3.split([0x00, 0x11,
                                                       0xFF, 0x03, 0x00, 0x00, 0x04, 0x95, 0x06, 0x03,
                                                       0xFF, 0x03, 0x00])
    check(resyncFrames.count == 1 && resyncRemainder == [0xFF, 0x03, 0x00],
          "resync past garbage, keep partial frame")

    let (modeFrames, _) = GAIA3.split([0xFF, 0x03, 0x00, 0x06, 0x04, 0x95, 0x1B, 0x01,
                                       0x01, 0x02, 0x02, 0x00, 0x03, 0x01])
    var noise = NoiseControl()
    if let frame = modeFrames.first { noise.applyModePayload(frame.payload) }
    check(noise.antiWind == .auto && noise.adaptiveANC == true, "parse noise-control mode payload")

    check(GAIA3.encode(vendor: GAIA3.vendorQualcomm, command: Cmd.serialGet) ==
          [0xFF, 0x03, 0x00, 0x00, 0x00, 0x1D, 0x00, 0x03], "encode Qualcomm serial GET")

    var state = DeviceState()
    state.apply(GAIA3.Frame(vendor: GAIA3.vendorSennheiser, command: Cmd.eqConfigResp, payload: [0x05, 0xC4, 0x3C, 0x00, 0x00]))
    check(state.eqBands.count == 5 && state.eqMinGain == -6 && state.eqMaxGain == 6, "parse EQ config (5 bands, ±6 dB)")

    print(failures == 0 ? "SELFTEST PASS" : "SELFTEST FAIL (\(failures) failures)")
    exit(failures == 0 ? 0 : 1)
}

func dumpServices() {
    for device in BluetoothDirectory.pairedDevices() {
        print("Device: \(device.name ?? "?")  [\(device.addressString ?? "?")]")
        _ = device.performSDPQuery(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(2.5))
        guard let records = device.services as? [IOBluetoothSDPServiceRecord], !records.isEmpty else {
            print("  (no SDP records)\n")
            continue
        }
        for record in records {
            var channel: BluetoothRFCOMMChannelID = 0
            let hasRFCOMM = record.getRFCOMMChannelID(&channel) == kIOReturnSuccess
            let name = record.getServiceName() ?? "(unnamed)"
            var uuids: [String] = []
            if let attribute = record.getAttributeDataElement(0x0001),
               let list = attribute.getArrayValue() as? [IOBluetoothSDPDataElement] {
                for element in list {
                    if let uuid = element.getUUIDValue() { uuids.append(uuid.description) }
                }
            }
            print("  • \(name)  rfcomm=\(hasRFCOMM ? String(channel) : "—")  uuids=[\(uuids.joined(separator: ", "))]")
        }
        print("")
    }
}

func runProbe() {
    let directory = BluetoothDirectory()
    guard let candidate = directory.candidates().first else {
        print("No paired Sennheiser device found.")
        exit(2)
    }
    print("Probing \(candidate.name) [\(candidate.address)] …")
    let session = HeadphoneSession(directory: directory, settings: MemorySettings())
    session.connect(to: candidate)
    let deadline = Date().addingTimeInterval(30.0)
    while session.isConnecting, Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    let connected = session.isConnected
    let settled = Date().addingTimeInterval(15.0)
    repeat {
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    } while connected && !session.isIdle && Date() < settled

    let device = session.device
    print("connected: \(connected)  status: \(session.lastError ?? session.statusMessage)")
    print("model:     \(device.modelID)")
    print("firmware:  \(device.firmware)")
    print("serial:    \(device.serial)")
    print("battery:   \(device.battery.map { String($0) } ?? "—") %")
    print("codec:     \(device.codec ?? "—")")
    print("anc:       \(String(describing: device.noise.ancOn))  transparency: \(String(describing: device.noise.transparencyOn)) level: \(device.noise.transparencyLevel)")
    print("anti-wind: \(String(describing: device.noise.antiWind))  adaptive: \(String(describing: device.noise.adaptiveANC))")
    print("eq:        \(device.eqBands)  range: \(device.eqMinGain)…\(device.eqMaxGain) dB")
    print("power-off: \(device.autoPowerOffSeconds.map { "\($0) s" } ?? "—")  audio mode: \(device.audioMode.map { String($0) } ?? "—")")
    print("paired:    \(device.pairedDevices.count) of \(device.pairedCount.map { String($0) } ?? "—") read, \(device.pairedDevices.filter(\.connected).count) connected")
    print(session.log.text)
    session.disconnect()
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    exit(connected ? 0 : 1)
}

func runSnapshot(to path: String) {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    if arguments.contains("--dark") { application.appearance = NSAppearance(named: .darkAqua) }
    if arguments.contains("--light") { application.appearance = NSAppearance(named: .aqua) }

    let directory = SimulatedDirectory()
    // A headset that never answers keeps the connecting screen up for the picture.
    if arguments.contains("--connecting") { directory.headset.openDelay = 3600 }
    let session = makeDemoSession(directory: directory)
    session.refreshCandidates()
    if !arguments.contains("--disconnected"), let candidate = session.candidates.first {
        session.connect(to: candidate)
    }

    var size = NSSize(width: 940, height: 800)
    if let flag = arguments.firstIndex(of: "--size"), arguments.indices.contains(flag + 1) {
        let parts = arguments[flag + 1].split(separator: "x").compactMap { Double($0) }
        if parts.count == 2 { size = NSSize(width: parts[0], height: parts[1]) }
    }
    let showsPanel = arguments.contains("--panel")
    let background = Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
    let hosting = NSHostingView(rootView: showsPanel
        ? AnyView(MenuPanelView(session: session, presentation: PanelPresentation(isShown: true), openWindow: {})
            .background(background))
        : AnyView(ContentView(session: session).background(background)))
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: showsPanel ? [.borderless] : [.titled, .fullSizeContentView],
                          backing: .buffered, defer: false)
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.contentView = hosting
    window.setContentSize(size)
    RunLoop.current.run(until: Date().addingTimeInterval(1.0))
    if let flag = arguments.firstIndex(of: "--mode"), arguments.indices.contains(flag + 1),
       let mode = NoiseControl.Mode.allCases.first(where: { $0.rawValue.lowercased() == arguments[flag + 1].lowercased() }) {
        session.setNoiseMode(mode)
    }
    RunLoop.current.run(until: Date().addingTimeInterval(1.5))
    if showsPanel { window.setContentSize(hosting.fittingSize) }
    hosting.layoutSubtreeIfNeeded()

    guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
        print("Could not allocate snapshot bitmap")
        exit(1)
    }
    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]),
          (try? png.write(to: URL(fileURLWithPath: path))) != nil else {
        print("Could not write \(path)")
        exit(1)
    }
    print("Wrote \(path)")
}
