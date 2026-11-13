import Foundation
import GAIA3

struct Candidate: Identifiable, Equatable {
    var id: String { address }
    let address: String
    let name: String
    let isConnected: Bool
}

protocol GAIATransportDelegate: AnyObject {
    func transport(_ transport: GAIATransport, status: String)
    func transport(_ transport: GAIATransport, log message: String)
    func transportDidOpen(_ transport: GAIATransport)
    func transport(_ transport: GAIATransport, didReceive frame: GAIA3.Frame)
    func transportDidClose(_ transport: GAIATransport, error: String?)
}

protocol GAIATransport: AnyObject {
    var delegate: GAIATransportDelegate? { get set }
    func open()
    func close()
    func write(_ bytes: [UInt8]) -> Bool
}

protocol SettingsStore: AnyObject {
    func string(forKey key: String) -> String?
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
}

extension UserDefaults: SettingsStore {}

protocol DeviceDirectory: AnyObject {
    func candidates() -> [Candidate]
    func makeTransport(for candidate: Candidate) -> GAIATransport?
    func observeConnections(_ handler: @escaping (String) -> Void)
}
