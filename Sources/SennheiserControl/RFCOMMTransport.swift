import Foundation
import IOBluetooth
import GAIA3

final class BluetoothDirectory: NSObject, DeviceDirectory {
    private static let nameHints = ["ACCENTUM", "MOMENTUM", "SENNHEISER", "HDB", "AMBEO", "CX", "HD "]

    private var connectNotification: IOBluetoothUserNotification?
    private var connectionHandler: ((String) -> Void)?

    static func pairedDevices() -> [IOBluetoothDevice] {
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        let matches = paired.filter { device in
            let name = (device.name ?? "").uppercased()
            return nameHints.contains { name.contains($0) }
        }
        return matches.isEmpty ? paired : matches
    }

    func candidates() -> [Candidate] {
        Self.pairedDevices().compactMap { device in
            guard let address = device.addressString else { return nil }
            return Candidate(address: address, name: device.name ?? address, isConnected: device.isConnected())
        }
    }

    func makeTransport(for candidate: Candidate) -> GAIATransport? {
        guard let device = IOBluetoothDevice(addressString: candidate.address) else { return nil }
        return RFCOMMTransport(device: device)
    }

    func observeConnections(_ handler: @escaping (String) -> Void) {
        connectionHandler = handler
        connectNotification?.unregister()
        connectNotification = IOBluetoothDevice.register(forConnectNotifications: self,
                                                         selector: #selector(deviceConnected(_:device:)))
    }

    @objc private func deviceConnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        if let address = device.addressString { connectionHandler?(address) }
    }
}

final class RFCOMMTransport: NSObject, GAIATransport {
    weak var delegate: GAIATransportDelegate?

    private let device: IOBluetoothDevice
    private var channel: IOBluetoothRFCOMMChannel?
    private var rxBuffer: [UInt8] = []
    private var channelCandidates: [BluetoothRFCOMMChannelID] = []
    private var candidateIndex = 0
    private var openChannelID: BluetoothRFCOMMChannelID?
    private var sdpTimer: DispatchWorkItem?
    private var validationTimer: DispatchWorkItem?
    private var openTimer: DispatchWorkItem?
    private var pendingAdvance = false
    private var isValidated = false
    private var isClosed = false
    private var unreachableStrikes = 0
    private var openTimeouts = 0

    private static let fallbackChannels: [BluetoothRFCOMMChannelID] = [2, 1, 15, 14, 12, 3, 4, 5, 6, 7, 8, 9, 10, 11]
    private static let gaiaServiceUUID = "a2129ff3-081b-4c45-8afe-469d9c4842ec"

    init(device: IOBluetoothDevice) {
        self.device = device
    }

    private var name: String { device.name ?? device.addressString ?? "device" }

    private func log(_ message: String) { delegate?.transport(self, log: message) }

    // MARK: - GAIATransport

    func open() {
        delegate?.transport(self, status: "Querying services (SDP)…")
        log("SDP query started for \(name)")
        let timer = DispatchWorkItem { [weak self] in self?.sdpFinished(status: kIOReturnTimeout) }
        sdpTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + 12.0, execute: timer)
        if device.performSDPQuery(self) != kIOReturnSuccess {
            sdpFinished(status: kIOReturnError)
        }
    }

    func close() {
        isClosed = true
        sdpTimer?.cancel()
        sdpTimer = nil
        validationTimer?.cancel()
        validationTimer = nil
        openTimer?.cancel()
        openTimer = nil
        pendingAdvance = false
        channel?.close()
        channel = nil
        rxBuffer.removeAll()
    }

    func write(_ bytes: [UInt8]) -> Bool {
        guard let channel, !isClosed else { return false }
        var data = bytes
        let result = data.withUnsafeMutableBytes { raw in
            channel.writeSync(raw.baseAddress, length: UInt16(raw.count))
        }
        return result == kIOReturnSuccess
    }

    // MARK: - Channel discovery

    @objc func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        sdpFinished(status: status)
    }

    private func sdpFinished(status: IOReturn) {
        guard !isClosed, sdpTimer != nil else { return }
        sdpTimer?.cancel()
        sdpTimer = nil
        if status == kIOReturnSuccess {
            buildChannelCandidates()
        } else {
            log("SDP query failed (\(status)) — falling back to channel scan")
            channelCandidates = Self.fallbackChannels
            if !device.isConnected() { unreachableStrikes = 1 }
        }
        candidateIndex = 0
        attemptNextChannel()
    }

    private func buildChannelCandidates() {
        var list: [BluetoothRFCOMMChannelID] = []
        if let records = device.services as? [IOBluetoothSDPServiceRecord] {
            for record in records {
                var channelID: BluetoothRFCOMMChannelID = 0
                let name = (record.getServiceName() ?? "").uppercased()
                let lower = name.lowercased()
                let isHandsFree = lower.contains("hands-free") || lower.contains("headset") || lower.contains("handsfree")
                guard record.getRFCOMMChannelID(&channelID) == kIOReturnSuccess else { continue }
                var carriesGAIAUUID = false
                if let attribute = record.getAttributeDataElement(0x0001),
                   let uuidList = attribute.getArrayValue() as? [IOBluetoothSDPDataElement] {
                    for element in uuidList where element.getUUIDValue()?.description.lowercased() == Self.gaiaServiceUUID {
                        carriesGAIAUUID = true
                    }
                }
                if name == "GAIA" || carriesGAIAUUID {
                    list.insert(channelID, at: 0)
                } else if !isHandsFree {
                    list.append(channelID)
                }
            }
        }
        if let spp = device.getServiceRecord(for: IOBluetoothSDPUUID(uuid16: 0x1101)) {
            var channelID: BluetoothRFCOMMChannelID = 0
            if spp.getRFCOMMChannelID(&channelID) == kIOReturnSuccess {
                list.append(channelID)
            }
        }
        list.append(contentsOf: Self.fallbackChannels)
        var seen = Set<BluetoothRFCOMMChannelID>()
        channelCandidates = list.filter { seen.insert($0).inserted }
        if let gaiaIndex = channelCandidates.firstIndex(of: 15) {
            channelCandidates.remove(at: gaiaIndex)
            channelCandidates.insert(15, at: 0)
        }
        log("RFCOMM channel candidates: \(channelCandidates.map { String($0) }.joined(separator: ", "))")
    }

    private func attemptNextChannel() {
        openTimer?.cancel()
        guard !isClosed else { return }
        guard candidateIndex < channelCandidates.count else {
            log("No RFCOMM channel answered to the GAIA handshake")
            fail("No GAIA service answered on \(name).")
            return
        }
        let channelID = channelCandidates[candidateIndex]
        delegate?.transport(self, status: "Trying RFCOMM channel \(channelID)…")
        log("Opening RFCOMM channel \(channelID)")
        var newChannel: IOBluetoothRFCOMMChannel?
        let result = device.openRFCOMMChannelAsync(&newChannel, withChannelID: channelID, delegate: self)
        if result != kIOReturnSuccess {
            channelFailed()
            return
        }
        channel?.close()
        channel = newChannel
        let timer = DispatchWorkItem { [weak self] in
            guard let self, !self.isValidated else { return }
            self.openTimeouts += 1
            if self.openTimeouts >= 2, self.device.isConnected() {
                self.log("Channel \(channelID) open timed out — giving up")
                self.fail("The Mac could not open a data channel to \(self.name).")
            } else {
                self.log("Channel \(channelID) open timed out — trying next")
                self.channelFailed()
            }
        }
        openTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: timer)
    }

    private func channelFailed() {
        if device.isConnected() {
            unreachableStrikes = 0
        } else {
            unreachableStrikes += 1
            if unreachableStrikes >= 2 {
                log("\(name) has no baseband connection — giving up")
                fail("Couldn't reach \(name). Make sure the headphones are switched on and in range.")
                return
            }
        }
        advanceChannel()
    }

    private func advanceChannel() {
        openTimer?.cancel()
        openTimer = nil
        validationTimer?.cancel()
        validationTimer = nil
        pendingAdvance = false
        channel?.close()
        channel = nil
        rxBuffer.removeAll()
        candidateIndex += 1
        attemptNextChannel()
    }

    private func beginValidation() {
        _ = write(GAIA3.encode(command: Cmd.batteryGet))
        let timer = DispatchWorkItem { [weak self] in
            guard let self, !self.isValidated else { return }
            self.log("Channel \(self.openChannelID.map { String($0) } ?? "?") silent — trying next")
            self.pendingAdvance = true
            self.channel?.close()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, !self.isClosed, self.pendingAdvance else { return }
                self.advanceChannel()
            }
        }
        validationTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: timer)
    }

    private func fail(_ message: String) {
        guard !isClosed else { return }
        close()
        delegate?.transportDidClose(self, error: message)
    }
}

extension RFCOMMTransport: IOBluetoothRFCOMMChannelDelegate {
    func rfcommChannelOpenComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        guard rfcommChannel == channel else { rfcommChannel?.close(); return }
        openTimer?.cancel()
        openTimer = nil
        if error == kIOReturnSuccess {
            openChannelID = rfcommChannel.getID()
            unreachableStrikes = 0
            log("Channel \(openChannelID.map { String($0) } ?? "?") open — validating")
            beginValidation()
        } else {
            log("Channel open failed (\(error))")
            channelFailed()
        }
    }

    func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel!,
                           data dataPointer: UnsafeMutableRawPointer!,
                           length dataLength: Int) {
        guard rfcommChannel == channel else { return }
        rxBuffer.append(contentsOf: UnsafeRawBufferPointer(start: dataPointer, count: dataLength))
        let (frames, remainder) = GAIA3.split(rxBuffer)
        rxBuffer = remainder
        guard !frames.isEmpty else { return }
        if !isValidated {
            validationTimer?.cancel()
            validationTimer = nil
            openTimer?.cancel()
            openTimer = nil
            isValidated = true
            log("GAIA link up on RFCOMM channel \(openChannelID.map { String($0) } ?? "?")")
            delegate?.transportDidOpen(self)
        }
        for frame in frames { delegate?.transport(self, didReceive: frame) }
    }

    func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        guard rfcommChannel == channel else { return }
        if pendingAdvance {
            pendingAdvance = false
            advanceChannel()
            return
        }
        log("RFCOMM channel closed")
        guard isValidated else {
            channelFailed()
            return
        }
        close()
        delegate?.transportDidClose(self, error: nil)
    }
}
