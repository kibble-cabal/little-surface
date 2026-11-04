import Darwin
import Foundation
import LittleSurfaceCore
import Network

/// Listens for the Blender add-on on the local network. A request has to carry the code shown in the
/// app, because anyone else on the same Wi-Fi could otherwise reach into the open project.
final class BlenderLinkServer {
    static let defaultPort: UInt16 = 48620
    /// A wrong code this many times is somebody guessing, so the link turns itself off.
    static let wrongCodeLimit = 10

    enum State: Equatable {
        case stopped
        case listening(port: UInt16)
        case failed(String)
    }

    private let code: String
    private let port: UInt16
    private let handler: (LinkRequest) async -> LinkResponse
    private let queue = DispatchQueue(label: "com.audreyserene.littlesurface.blender-link")
    private var listener: NWListener?
    private var wrongCodes = 0

    /// Called on the server's own queue.
    var onStateChange: ((State) -> Void)?

    init(code: String, port: UInt16 = BlenderLinkServer.defaultPort, handler: @escaping (LinkRequest) async -> LinkResponse) {
        self.code = code
        self.port = port
        self.handler = handler
    }

    func start() {
        queue.async { [self] in
            guard listener == nil, let endpointPort = NWEndpoint.Port(rawValue: port) else { return }
            wrongCodes = 0
            do {
                let parameters = NWParameters.tcp
                parameters.allowLocalEndpointReuse = true
                let listener = try NWListener(using: parameters, on: endpointPort)
                listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready: self.onStateChange?(.listening(port: self.port))
                    case .failed(let error):
                        self.shutDown()
                        self.onStateChange?(.failed(error.localizedDescription))
                    default: break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
                self.listener = listener
                listener.start(queue: queue)
            } catch {
                onStateChange?(.failed(error.localizedDescription))
            }
        }
    }

    func stop() {
        queue.async { [self] in
            shutDown()
            onStateChange?(.stopped)
        }
    }

    private func shutDown() {
        listener?.cancel()
        listener = nil
    }

    /// What's arrived so far. It's held here so each piece of a large sculpt appends rather than copies.
    private final class Incoming {
        var data = Data()
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, into: Incoming())
        // A sculpt can take a while over Wi-Fi, but nothing should sit here forever.
        queue.asyncAfter(deadline: .now() + 600) { connection.cancel() }
    }

    private func receive(on connection: NWConnection, into incoming: Incoming) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return connection.cancel() }
            if let data { incoming.data.append(data) }
            switch LinkRequestParser.parse(incoming.data) {
            case .complete(let request):
                self.respond(to: request, on: connection)
            case .incomplete:
                if isComplete || error != nil {
                    connection.cancel()
                } else {
                    self.receive(on: connection, into: incoming)
                }
            case .invalid:
                self.send(.message("That isn't a request the app understands.", status: 400), on: connection)
            case .tooLarge:
                self.send(.message("That's too large to send.", status: 413), on: connection)
            }
        }
    }

    private func respond(to request: LinkRequest, on connection: NWConnection) {
        guard request.headers["x-little-surface-code"] == code else {
            wrongCodes += 1
            send(.message("That code doesn't match the one shown in Little Surface.", status: 401), on: connection)
            if wrongCodes >= Self.wrongCodeLimit {
                shutDown()
                onStateChange?(.failed("It turned itself off after too many wrong codes."))
            }
            return
        }
        wrongCodes = 0
        let handler = self.handler
        Task {
            let response = await handler(request)
            self.queue.async { self.send(response, on: connection) }
        }
    }

    private func send(_ response: LinkResponse, on connection: NWConnection) {
        connection.send(content: response.encoded, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
    }

    /// This device's address on the local network, to type into Blender.
    static func localAddress() -> String? {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return nil }
        defer { freeifaddrs(first) }
        var fallback: String?
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = current {
            defer { current = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(cString: host)
            // en0 is Wi-Fi on an iPad. Anything else is only a guess.
            if String(cString: entry.pointee.ifa_name) == "en0" { return text }
            if fallback == nil { fallback = text }
        }
        return fallback
    }

    /// Kept between launches so Blender doesn't need it typing in again.
    static func savedCode(in defaults: UserDefaults = .standard) -> String {
        if let saved = defaults.string(forKey: "blenderLinkCode"), saved.count == 6 { return saved }
        let code = String(format: "%06d", Int.random(in: 0..<1_000_000))
        defaults.set(code, forKey: "blenderLinkCode")
        return code
    }
}
