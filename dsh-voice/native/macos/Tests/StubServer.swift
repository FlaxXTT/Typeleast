import Foundation
import Network

// StubServer.swift - minimal loopback HTTP/1.1 stub used by the test harness.
// Emulates the frozen /api/voice-polish contract. Not part of the app bundle.

final class StubServer {
    struct Request {
        var method: String
        var path: String
        var headers: [String: String]
        var body: Data
        func header(_ k: String) -> String { headers[k.lowercased()] ?? "" }
    }

    struct Response {
        var status: Int
        var contentType: String
        var body: Data
        static func json(_ text: String, status: Int = 200) -> Response {
            Response(status: status, contentType: "application/json", body: Data(text.utf8))
        }
    }

    typealias Handler = (Request) -> Response

    private let listener: NWListener
    private let queue = DispatchQueue(label: "dsh.stub.server")
    private let handler: Handler
    private let lock = NSLock()
    private var _requests: [Request] = []
    private var readySem: DispatchSemaphore?
    private var live: [ObjectIdentifier: Connection] = [:]

    private(set) var port: UInt16 = 0
    var requests: [Request] {
        lock.lock(); defer { lock.unlock() }
        return _requests
    }

    init(handler: @escaping Handler) throws {
        self.handler = handler
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredInterfaceType = .loopback
        listener = try NWListener(using: params, on: .any)
    }

    func start() {
        let sem = DispatchSemaphore(value: 0)
        readySem = sem
        listener.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                if let p = self.listener.port { self.port = p.rawValue }
                sem.signal()
            case .failed(let err):
                FileHandle.standardError.write(Data(("stub listener failed: " + String(describing: err) + "\n").utf8))
                sem.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] conn in
            guard let self = self else { return }
            let c = Connection(conn: conn, queue: self.queue, handler: self.handler, onRequest: { req in
                self.lock.lock(); self._requests.append(req); self.lock.unlock()
            }, onClose: { closed in
                self.lock.lock(); self.live[ObjectIdentifier(closed)] = nil; self.lock.unlock()
            })
            self.lock.lock(); self.live[ObjectIdentifier(c)] = c; self.lock.unlock()
            c.start()
        }
        listener.start(queue: queue)
        _ = sem.wait(timeout: .now() + 5)
    }

    func stop() {
        listener.cancel()
    }

    var baseURL: URL { URL(string: "http://127.0.0.1:" + String(port))! }

    // MARK: - one connection

    private final class Connection {
        let conn: NWConnection
        let queue: DispatchQueue
        let handler: Handler
        let onRequest: (Request) -> Void
        let onClose: (Connection) -> Void
        var buffer = Data()
        var closed = false

        init(conn: NWConnection, queue: DispatchQueue, handler: @escaping Handler,
             onRequest: @escaping (Request) -> Void, onClose: @escaping (Connection) -> Void) {
            self.conn = conn
            self.queue = queue
            self.handler = handler
            self.onRequest = onRequest
            self.onClose = onClose
        }

        func start() {
            conn.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                switch state {
                case .ready:
                    self.read()
                case .failed, .cancelled:
                    self.finish()
                default:
                    break
                }
            }
            conn.start(queue: queue)
        }

        private func finish() {
            guard !closed else { return }
            closed = true
            onClose(self)
        }

        private func read() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
                guard let self = self else { return }
                if let d = data, !d.isEmpty { self.buffer.append(d) }
                if let req = self.parse() {
                    self.onRequest(req)
                    self.send(self.handler(req))
                    return
                }
                if isComplete || error != nil {
                    self.conn.cancel()
                    self.finish()
                    return
                }
                self.read()
            }
        }

        private func parse() -> Request? {
            let sep = Data([13, 10, 13, 10])
            guard let range = buffer.range(of: sep) else { return nil }
            let headerData = buffer.subdata(in: 0..<range.lowerBound)
            guard let headerStr = String(data: headerData, encoding: .utf8) else { return nil }
            var lines = headerStr.components(separatedBy: "\r\n")
            guard !lines.isEmpty else { return nil }
            let parts = lines.removeFirst().split(separator: " ")
            guard parts.count >= 2 else { return nil }
            var headers: [String: String] = [:]
            for line in lines {
                guard let idx = line.firstIndex(of: ":") else { continue }
                let k = String(line[line.startIndex..<idx]).lowercased().trimmingCharacters(in: .whitespaces)
                let v = String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
                headers[k] = v
            }
            let bodyStart = range.upperBound
            let len = Int(headers["content-length"] ?? "0") ?? 0
            guard buffer.count - bodyStart >= len else { return nil }
            let body = buffer.subdata(in: bodyStart..<(bodyStart + len))
            return Request(method: String(parts[0]), path: String(parts[1]), headers: headers, body: body)
        }

        private func send(_ r: Response) {
            var head = "HTTP/1.1 " + String(r.status) + " " + Connection.reason(r.status) + "\r\n"
            head += "Content-Type: " + r.contentType + "\r\n"
            head += "Content-Length: " + String(r.body.count) + "\r\n"
            head += "Connection: close\r\n\r\n"
            var out = Data(head.utf8)
            out.append(r.body)
            conn.send(content: out, completion: .contentProcessed { [weak self] _ in
                self?.conn.cancel()
                self?.finish()
            })
        }

        static func reason(_ status: Int) -> String {
            switch status {
            case 200: return "OK"
            case 401: return "Unauthorized"
            case 400: return "Bad Request"
            case 404: return "Not Found"
            case 500: return "Internal Server Error"
            case 503: return "Service Unavailable"
            default: return "Status"
            }
        }
    }
}
