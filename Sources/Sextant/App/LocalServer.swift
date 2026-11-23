import Foundation
import Network

/// A tiny HTTP server bound to the loopback interface. The web view loads the interface from it,
/// so the page keeps one stable origin (its saved settings survive restarts) and audio gets byte ranges.
final class LocalServer {
    static let shared = LocalServer()
    private(set) var port: UInt16 = 0
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "sextant.localserver", attributes: .concurrent)

    /// Starts on the first free port from 47831; calls back with the port on the main queue.
    func start(_ ready: @escaping (UInt16) -> Void) {
        tryStart(port: 47831, attemptsLeft: 20, ready)
    }

    private func tryStart(port: UInt16, attemptsLeft: Int, _ ready: @escaping (UInt16) -> Void) {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        params.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: port), let l = try? NWListener(using: params, on: nwPort) else {
            if attemptsLeft > 0 { tryStart(port: port + 1, attemptsLeft: attemptsLeft - 1, ready) }
            return
        }
        l.newConnectionHandler = { [weak self] c in self?.serve(c) }
        l.stateUpdateHandler = { [weak self] st in
            switch st {
            case .ready:
                self?.port = port
                DispatchQueue.main.async { ready(port) }
            case .failed:
                l.cancel()
                if attemptsLeft > 0 { self?.tryStart(port: port + 1, attemptsLeft: attemptsLeft - 1, ready) }
            default: break
            }
        }
        listener = l
        l.start(queue: queue)
    }

    private func serve(_ c: NWConnection) {
        c.start(queue: queue)
        receive(c, buffer: Data())
    }

    private func receive(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, err in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            switch HTTPRequest.parse(buf) {
            case .done(let req, _):
                Task {
                    let resp = await AppRouter.shared.handle(req)
                    c.send(content: resp.serialized(), completion: .contentProcessed { _ in c.cancel() })
                }
            case .invalid:
                c.send(content: HTTPResponse.error("geçersiz istek", status: 400).serialized(), completion: .contentProcessed { _ in c.cancel() })
            case .incomplete:
                if done || err != nil { c.cancel() } else { self.receive(c, buffer: buf) }
            }
        }
    }
}
