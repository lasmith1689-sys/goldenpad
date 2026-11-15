import Foundation
import Network

/// The networking half of "use your iPhone as a controller", with no UI and
/// no game calls, so CI can run a real phone-to-TV connection on a Mac.
/// Callbacks arrive on the object's own queue.
enum RemoteControllerNetwork {
    static func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 5
        let parameters = NWParameters(tls: nil, tcp: tcp)
        // Same Wi-Fi network only; no ad-hoc peer-to-peer links.
        parameters.includePeerToPeer = false
        return parameters
    }

    /// Reads fixed-size frames until the connection ends.
    static func receiveFrames(
        _ connection: NWConnection,
        size: Int,
        onFrame: @escaping (Data) -> Void,
        onEnd: @escaping () -> Void
    ) {
        connection.receive(minimumIncompleteLength: size, maximumLength: size) { data, _, isComplete, error in
            if let data, data.count == size { onFrame(data) }
            if isComplete || error != nil {
                onEnd()
            } else {
                receiveFrames(connection, size: size, onFrame: onFrame, onEnd: onEnd)
            }
        }
    }
}

/// TV side: advertises `_gpad-ctrl._tcp` and accepts phones.
final class RemoteControllerServer {
    let queue = DispatchQueue(label: "goldenpad.remote-controller.server")
    var onReady: ((UInt16) -> Void)?
    var onFailed: ((String) -> Void)?
    var onConnect: ((UUID) -> Void)?
    var onInput: ((UUID, RemoteControllerInput) -> Void)?
    var onDisconnect: ((UUID) -> Void)?

    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]

    /// `name` nil uses the device's own name (for example "Living Room").
    func start(name: String? = nil, port: NWEndpoint.Port = .any, advertise: Bool = true) throws {
        let listener = try NWListener(using: RemoteControllerNetwork.parameters(), on: port)
        if advertise {
            listener.service = NWListener.Service(name: name, type: RemoteControllerWire.serviceType)
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self.onReady?(listener.port?.rawValue ?? 0)
            case .failed(let error): self.onFailed?("\(error)")
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    /// Four players plus a couple waiting for one to leave; any more are refused.
    static let maxConnections = RemoteControllerWire.maxPlayers + 2

    private func accept(_ connection: NWConnection) {
        guard connections.count < Self.maxConnections else {
            connection.cancel()
            return
        }
        let id = UUID()
        connections[id] = connection
        var ended = false
        let end: () -> Void = { [weak self] in
            guard let self, !ended else { return }
            ended = true
            connection.cancel()
            self.connections[id] = nil
            self.onDisconnect?(id)
        }
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.onConnect?(id)
                RemoteControllerNetwork.receiveFrames(
                    connection, size: RemoteControllerInput.size,
                    onFrame: { data in
                        if let input = RemoteControllerInput(data) { self?.onInput?(id, input) }
                    },
                    onEnd: end)
            case .failed, .cancelled:
                end()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    /// Call on `queue`.
    func send(_ status: RemoteControllerStatus, to id: UUID) {
        connections[id]?.send(content: status.encoded(), completion: .idempotent)
    }

    func stop() {
        queue.async { [self] in
            listener?.cancel()
            listener = nil
            connections.values.forEach { $0.cancel() }
            connections.removeAll()
        }
    }
}

/// An Apple TV running GoldenPad, found on the local network.
struct RemoteControllerTV: Identifiable, Hashable {
    let name: String
    let endpoint: NWEndpoint
    var id: String { "\(endpoint)" }
}

/// Phone side: finds TVs.
final class RemoteControllerBrowser {
    let queue = DispatchQueue(label: "goldenpad.remote-controller.browser")
    var onChange: (([RemoteControllerTV]) -> Void)?
    var onFailed: ((String) -> Void)?
    private var browser: NWBrowser?

    func start() {
        let browser = NWBrowser(
            for: .bonjour(type: RemoteControllerWire.serviceType, domain: nil),
            using: RemoteControllerNetwork.parameters())
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let tvs = results.compactMap { result -> RemoteControllerTV? in
                if case let .service(name, _, _, _) = result.endpoint {
                    return RemoteControllerTV(name: name, endpoint: result.endpoint)
                }
                return nil
            }
            self?.onChange?(tvs.sorted { $0.name < $1.name })
        }
        browser.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let error), .waiting(let error): self?.onFailed?("\(error)")
            default: break
            }
        }
        self.browser = browser
        browser.start(queue: queue)
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }
}

/// Phone side: one connection to one TV.
final class RemoteControllerLink {
    enum State: Equatable {
        case connecting
        case ready
        case ended(String?)
    }

    let queue = DispatchQueue(label: "goldenpad.remote-controller.link")
    var onState: ((State) -> Void)?
    var onStatus: ((RemoteControllerStatus) -> Void)?
    private let connection: NWConnection
    private var ended = false

    init(endpoint: NWEndpoint) {
        connection = NWConnection(to: endpoint, using: RemoteControllerNetwork.parameters())
    }

    func start() {
        onState?(.connecting)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onState?(.ready)
                RemoteControllerNetwork.receiveFrames(
                    self.connection, size: RemoteControllerStatus.size,
                    onFrame: { [weak self] data in
                        if let status = RemoteControllerStatus(data) { self?.onStatus?(status) }
                    },
                    onEnd: { [weak self] in self?.finish(nil) })
            case .waiting(let error):
                // No route yet (Wi-Fi off, TV asleep): give up rather than hang.
                self.finish("\(error)")
            case .failed(let error):
                self.finish("\(error)")
            case .cancelled:
                self.finish(nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func finish(_ reason: String?) {
        guard !ended else { return }
        ended = true
        connection.cancel()
        onState?(.ended(reason))
    }

    /// Safe from any thread.
    func send(_ input: RemoteControllerInput) {
        connection.send(content: input.encoded(), completion: .idempotent)
    }

    func cancel() {
        queue.async { [weak self] in self?.finish(nil) }
    }
}
