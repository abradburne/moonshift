import Foundation
import Network

/// A small HTTP server on the loopback address, for the agent endpoint. It
/// answers one request per connection and refuses anything a web page could send.
final class LoopbackServer: @unchecked Sendable {
    typealias Handler = @Sendable (_ method: String, _ path: String, _ body: Data) async -> (status: Int, headers: [String: String], body: Data?)

    private let listener: NWListener
    private let handler: Handler
    private let queue = DispatchQueue(label: "Moonshift.agents")
    static let largestRequest = 4 * 1024 * 1024

    init(port: Int, handler: @escaping Handler) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(integerLiteral: UInt16(port)))
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters)
        self.handler = handler
    }

    /// Starts listening. `ready` reports whether the port could be used.
    func start(_ ready: @escaping @Sendable (Error?) -> Void) {
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: ready(nil)
            case .failed(let error): ready(error)
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
    }

    func stop() { listener.cancel() }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, Data())
    }

    private func receive(_ connection: NWConnection, _ buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] chunk, _, complete, error in
            guard let self else { return }
            var data = buffered
            if let chunk { data.append(chunk) }
            if error != nil || data.count > Self.largestRequest { connection.cancel(); return }
            switch Request.parse(data) {
            case .incomplete:
                if complete { connection.cancel() } else { self.receive(connection, data) }
            case .invalid:
                self.send(connection, status: 400, headers: [:], body: nil)
            case .complete(let request):
                self.serve(connection, request)
            }
        }
    }

    struct Request {
        var method: String
        var path: String
        var headers: [String: String]
        var body: Data

        enum Parsed { case incomplete, invalid, complete(Request) }

        static func parse(_ data: Data) -> Parsed {
            guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return .incomplete }
            let head = String(decoding: data[data.startIndex..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
            let line = head[0].split(separator: " ")
            guard line.count >= 2 else { return .invalid }
            var headers: [String: String] = [:]
            for field in head.dropFirst() {
                guard let colon = field.firstIndex(of: ":") else { continue }
                headers[field[..<colon].lowercased()] = field[field.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            let length = Int(headers["content-length"] ?? "0") ?? -1
            guard length >= 0, length <= LoopbackServer.largestRequest else { return .invalid }
            let body = data[end.upperBound...]
            guard body.count >= length else { return .incomplete }
            return .complete(Request(method: String(line[0]), path: String(line[1]), headers: headers, body: Data(body.prefix(length))))
        }

        /// A web page cannot reach the server from another origin, nor by pointing
        /// its own hostname at the loopback address.
        var isLocal: Bool {
            var host = headers["host"] ?? ""
            if let port = host.range(of: ":", options: .backwards) { host = String(host[..<port.lowerBound]) }
            guard ["127.0.0.1", "localhost"].contains(host) else { return false }
            guard let origin = headers["origin"] else { return true }
            return origin.matchesPattern(#"^http://(127\.0\.0\.1|localhost)(:\d+)?$"#)
        }
    }

    private func serve(_ connection: NWConnection, _ request: Request) {
        guard request.isLocal else {
            send(connection, status: 403, headers: ["Content-Type": "application/json"], body: Data(#"{"detail":"Local requests only"}"#.utf8))
            return
        }
        let handler = handler
        Task {
            let response = await handler(request.method, request.path, request.body)
            self.send(connection, status: response.status, headers: response.headers, body: response.body)
        }
    }

    private func send(_ connection: NWConnection, status: Int, headers: [String: String], body: Data?) {
        let reasons = [200: "OK", 202: "Accepted", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed"]
        var head = "HTTP/1.1 \(status) \(reasons[status] ?? "Error")\r\nContent-Length: \(body?.count ?? 0)\r\nConnection: close\r\n"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        var response = Data((head + "\r\n").utf8)
        if let body { response.append(body) }
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
}
