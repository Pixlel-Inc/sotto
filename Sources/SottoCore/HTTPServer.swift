import Foundation
import Network

/// A small HTTP/1.1 server bound to 127.0.0.1 only. Every route except /v1/health
/// needs `Authorization: Bearer <token>`. Requests whose Host header is not
/// localhost are refused, which blocks DNS-rebinding tricks from web pages.
public final class HTTPServer: @unchecked Sendable {
    private let api: SottoAPI
    private let port: UInt16
    private let token: String
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "sotto.http")

    public init(api: SottoAPI, port: Int, token: String) {
        self.api = api
        self.port = UInt16(port)
        self.token = token
    }

    public func start() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params)
        l.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        l.start(queue: queue)
        listener = l
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    struct Request {
        var method: String
        var path: String
        var query: [String: String]
        var headers: [String: String]
        var body: Data
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if buf.count > 2_000_000 { return self.send(conn, 413, ["error": "request too large"]) }
            if let req = HTTPServer.parse(buf) {
                Task { await self.respond(conn, req) }
            } else if done || error != nil {
                conn.cancel()
            } else {
                self.receive(conn, buffer: buf)
            }
        }
    }

    static func parse(_ data: Data) -> Request? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: data[data.startIndex..<headerEnd.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ")
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = data[headerEnd.upperBound...]
        guard body.count >= length else { return nil }
        let target = String(parts[1])
        let comps = URLComponents(string: "http://localhost" + target)
        var query: [String: String] = [:]
        for item in comps?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return Request(method: String(parts[0]).uppercased(), path: comps?.path ?? target, query: query,
                       headers: headers, body: Data(body.prefix(length)))
    }

    private func send(_ conn: NWConnection, _ status: Int, _ json: Any) {
        let data = (try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        send(conn, status, data, type: "application/json; charset=utf-8")
    }

    private func send(_ conn: NWConnection, _ status: Int, _ body: Data, type: String) {
        let reason = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found",
                      405: "Method Not Allowed", 409: "Conflict", 413: "Payload Too Large", 500: "Internal Server Error"][status] ?? "OK"
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        head += "Cache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

    private func allowedHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        let name = host.split(separator: ":").first.map(String.init) ?? host
        return name == "127.0.0.1" || name == "localhost" || name == "[::1]"
    }

    private func respond(_ conn: NWConnection, _ req: Request) async {
        guard allowedHost(req.headers["host"]) else { return send(conn, 403, ["error": "host not allowed"]) }
        if req.path == "/v1/health" { return send(conn, 200, ["ok": true, "version": Sotto.version]) }
        let auth = req.headers["authorization"] ?? ""
        guard HTTPServer.constantTimeEqual(auth, "Bearer \(token)") else {
            return send(conn, 401, ["error": "missing or wrong token. Send Authorization: Bearer <token>; `sotto token` prints it."])
        }
        do {
            let (status, result) = try await route(req)
            if let text = result as? String {
                send(conn, status, Data(text.utf8), type: "text/markdown; charset=utf-8")
            } else {
                send(conn, status, result)
            }
        } catch let e as SottoError {
            if case .notFound = e { send(conn, 404, ["error": e.localizedDescription]) }
            else { send(conn, 400, ["error": e.localizedDescription]) }
        } catch {
            send(conn, 500, ["error": error.localizedDescription])
        }
    }

    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in x.indices { diff |= x[i] ^ y[i] }
        return diff == 0
    }

    private func bodyJSON(_ req: Request) throws -> [String: Any] {
        if req.body.isEmpty { return [:] }
        guard let obj = try JSONSerialization.jsonObject(with: req.body) as? [String: Any] else {
            throw SottoError.invalid("body must be a JSON object")
        }
        return obj
    }

    private func route(_ req: Request) async throws -> (Int, Any) {
        let parts = req.path.split(separator: "/").map(String.init)
        let q = req.query
        let m = req.method
        guard parts.first == "v1" else { throw SottoError.notFound("\(m) \(req.path)") }
        let p = Array(parts.dropFirst())
        if m == "GET", p == ["status"] { return (200, api.status()) }
        if m == "GET", p == ["recordings"] {
            let list = api.list(limit: Int(q["limit"] ?? "") ?? 20,
                                since: SottoAPI.parseDate(q["since"]),
                                until: SottoAPI.parseDate(q["until"], endOfDay: true),
                                query: q["q"])
            return (200, ["recordings": list])
        }
        if m == "GET", p.count == 2, p[0] == "recordings" { return (200, try api.get(p[1])) }
        if m == "GET", p.count == 3, p[0] == "recordings", p[2] == "transcript.md" { return (200, try api.markdown(p[1])) }
        if m == "GET", p == ["search"] {
            guard let text = q["q"], !text.isEmpty else { throw SottoError.invalid("add ?q=your+words") }
            return (200, ["results": try api.search(text, limit: Int(q["limit"] ?? "") ?? 20, recording: q["recording"])])
        }
        if m == "POST", p.count == 3, p[0] == "recordings", p[2] == "speakers" {
            let b = try bodyJSON(req)
            guard let from = b["speaker"] as? String, let to = b["name"] as? String else {
                throw SottoError.invalid("send {\"speaker\": \"Speaker 2\", \"name\": \"Dustin\"}")
            }
            return (200, try api.renameSpeaker(p[1], speaker: from, name: to))
        }
        if m == "POST", p.count == 3, p[0] == "recordings", p[2] == "title" {
            guard let title = try bodyJSON(req)["title"] as? String else { throw SottoError.invalid("send {\"title\": \"...\"}") }
            return (200, try api.setTitle(p[1], title: title))
        }
        if m == "POST", p == ["record", "start"] {
            guard let rc = api.recordControl else { throw SottoError.invalid("recording is only available while the Sotto app is running") }
            let b = try bodyJSON(req)
            let mode = Recorder.Mode(rawValue: (b["mode"] as? String) ?? "call") ?? .call
            let id = try await rc.start(mode, b["title"] as? String)
            return (200, ["recording": true, "id": id])
        }
        if m == "POST", p == ["record", "stop"] {
            guard let rc = api.recordControl else { throw SottoError.invalid("recording is only available while the Sotto app is running") }
            let id = try await rc.stop()
            return (200, ["recording": false, "id": id, "status": "queued"])
        }
        throw SottoError.notFound("\(m) \(req.path)")
    }
}
