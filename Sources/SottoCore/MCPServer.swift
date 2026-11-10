import Foundation

/// A Model Context Protocol server over stdio (newline-delimited JSON-RPC).
/// Claude Desktop, Claude Code, Cursor and other MCP clients launch it as
/// `sotto mcp`. It reads the recordings folder directly, so it works whether or
/// not the menu-bar app is running; recording controls go through the app's API.
public final class MCPServer {
    let api: SottoAPI
    let supportedVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    public init(api: SottoAPI) { self.api = api }

    static let tools: [[String: Any]] = [
        [
            "name": "list_recordings",
            "description": "List recorded conversations, newest first, with title, date, duration, speakers and status. Use since/until (YYYY-MM-DD or ISO 8601) to find recordings around a calendar event.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "limit": ["type": "integer", "description": "How many to return (default 20, max 500)."],
                    "since": ["type": "string", "description": "Only recordings that started on or after this date or time."],
                    "until": ["type": "string", "description": "Only recordings that started on or before this date or time."],
                    "title_contains": ["type": "string", "description": "Only recordings whose title contains this text."],
                ],
            ],
            "annotations": ["readOnlyHint": true],
        ],
        [
            "name": "get_transcript",
            "description": "Get the full transcript of one recording, with timestamps and speaker names. Markdown by default; json gives segments with start and end seconds.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "recording_id": ["type": "string", "description": "Recording id from list_recordings or search_transcripts (a unique prefix works)."],
                    "format": ["type": "string", "enum": ["markdown", "json"], "description": "Default markdown."],
                ],
                "required": ["recording_id"],
            ],
            "annotations": ["readOnlyHint": true],
        ],
        [
            "name": "search_transcripts",
            "description": "Full-text search across every transcript. Every word must match; put a phrase in double quotes. Returns the recording, timestamp, speaker and a snippet for each hit.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "Words to find, for example: pricing \"next week\""],
                    "limit": ["type": "integer", "description": "How many hits (default 20)."],
                    "recording_id": ["type": "string", "description": "Search only this recording."],
                ],
                "required": ["query"],
            ],
            "annotations": ["readOnlyHint": true],
        ],
        [
            "name": "rename_speaker",
            "description": "Put a name on a speaker in one recording (for example Speaker 2 is Dustin). Sotto remembers the voice and suggests the name in later recordings. Only do this when the user tells you who the speaker is.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "recording_id": ["type": "string"],
                    "speaker": ["type": "string", "description": "The speaker as shown now: Speaker 2, S2, or a current name."],
                    "name": ["type": "string", "description": "The person's name."],
                ],
                "required": ["recording_id", "speaker", "name"],
            ],
        ],
        [
            "name": "set_title",
            "description": "Rename a recording, for example after the meeting it was.",
            "inputSchema": [
                "type": "object",
                "properties": ["recording_id": ["type": "string"], "title": ["type": "string"]],
                "required": ["recording_id", "title"],
            ],
        ],
        [
            "name": "recording_status",
            "description": "Whether Sotto is recording right now, and how many recordings exist.",
            "inputSchema": ["type": "object", "properties": [String: Any]()],
            "annotations": ["readOnlyHint": true],
        ],
        [
            "name": "start_recording",
            "description": "Start recording in the Sotto app (it must be running). Only call this when the user asks, and remind them that everyone in the conversation should know it is being recorded. Leave mode out: Sotto records the microphone and computer audio and works out afterward whether it was a call or an in-person conversation. Mode room records the microphone only.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "mode": ["type": "string", "enum": ["call", "room"]],
                    "title": ["type": "string"],
                ],
            ],
        ],
        [
            "name": "stop_recording",
            "description": "Stop the current recording in the Sotto app. Transcription starts on its own and takes about a minute per hour of audio.",
            "inputSchema": ["type": "object", "properties": [String: Any]()],
        ],
    ]

    public func run() {
        while let line = readLine(strippingNewline: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            guard let data = trimmed.data(using: .utf8),
                  let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                write(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "parse error"]])
                continue
            }
            handle(msg)
        }
    }

    func handle(_ msg: [String: Any]) {
        let method = msg["method"] as? String ?? ""
        let id = msg["id"]
        let params = msg["params"] as? [String: Any] ?? [:]
        // Notifications (no id) get no reply.
        guard let id else { return }
        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String ?? ""
            let version = supportedVersions.contains(asked) ? asked : supportedVersions[0]
            reply(id, [
                "protocolVersion": version,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "sotto", "title": "Sotto", "version": Sotto.version],
                "instructions": "Sotto holds transcripts of the user's recorded conversations, made and stored on their Mac. Find recordings with list_recordings (by date) or search_transcripts (by words), then read one with get_transcript. Speakers are named Speaker 1, Speaker 2 until the user names them.",
            ])
        case "ping":
            reply(id, [:])
        case "tools/list":
            reply(id, ["tools": MCPServer.tools])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            let result = callTool(name, args)
            reply(id, result)
        case "resources/list":
            reply(id, ["resources": [Any]()])
        case "prompts/list":
            reply(id, ["prompts": [Any]()])
        default:
            write(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "method not found: \(method)"]])
        }
    }

    func callTool(_ name: String, _ args: [String: Any]) -> [String: Any] {
        func str(_ k: String) -> String? { (args[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        func int(_ k: String) -> Int? { (args[k] as? Int) ?? (args[k] as? Double).map { Int($0) } ?? (args[k] as? String).flatMap { Int($0) } }
        do {
            switch name {
            case "list_recordings":
                let list = api.list(limit: int("limit") ?? 20, since: SottoAPI.parseDate(str("since")),
                                    until: SottoAPI.parseDate(str("until"), endOfDay: true), query: str("title_contains"))
                return text(json(["recordings": list]))
            case "get_transcript":
                guard let rid = str("recording_id") else { throw SottoError.invalid("recording_id is required") }
                if str("format") == "json" { return text(json(try api.get(rid))) }
                return text(try api.markdown(rid))
            case "search_transcripts":
                guard let q = str("query") else { throw SottoError.invalid("query is required") }
                let hits = try api.search(q, limit: int("limit") ?? 20, recording: str("recording_id"))
                return text(json(["results": hits, "count": hits.count]))
            case "rename_speaker":
                guard let rid = str("recording_id"), let sp = str("speaker"), let n = str("name") else {
                    throw SottoError.invalid("recording_id, speaker and name are required")
                }
                return text(json(try api.renameSpeaker(rid, speaker: sp, name: n)))
            case "set_title":
                guard let rid = str("recording_id"), let t = str("title") else { throw SottoError.invalid("recording_id and title are required") }
                return text(json(try api.setTitle(rid, title: t)))
            case "recording_status":
                var status = api.status()
                if let app = try? callApp("GET", "/v1/status", nil) { status.merge(app) { _, new in new } }
                else { status["app_running"] = false }
                return text(json(status))
            case "start_recording":
                var body: [String: Any] = ["mode": str("mode") ?? "call"]
                if let t = str("title") { body["title"] = t }
                return text(json(try callApp("POST", "/v1/record/start", body)))
            case "stop_recording":
                return text(json(try callApp("POST", "/v1/record/stop", [:])))
            default:
                throw SottoError.invalid("unknown tool \(name)")
            }
        } catch {
            return ["content": [["type": "text", "text": error.localizedDescription]], "isError": true]
        }
    }

    /// Calls the menu-bar app's local API (for live recording controls).
    func callApp(_ method: String, _ path: String, _ body: [String: Any]?) throws -> [String: Any] {
        let config = api.library.config
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(config.port)\(path)")!)
        req.httpMethod = method
        req.timeoutInterval = 15
        req.setValue("Bearer \(config.apiToken)", forHTTPHeaderField: "Authorization")
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var out: (Data?, URLResponse?, Error?)
        URLSession.shared.dataTask(with: req) { d, r, e in out = (d, r, e); sem.signal() }.resume()
        sem.wait()
        if out.2 != nil { throw SottoError.invalid("the Sotto app is not running. Open Sotto from Applications, then try again.") }
        let obj = out.0.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        if let code = (out.1 as? HTTPURLResponse)?.statusCode, code >= 300 {
            throw SottoError.invalid(obj["error"] as? String ?? "the Sotto app answered \(code)")
        }
        return obj
    }

    func text(_ s: String) -> [String: Any] { ["content": [["type": "text", "text": s]]] }

    func json(_ obj: Any) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    func reply(_ id: Any, _ result: [String: Any]) {
        write(["jsonrpc": "2.0", "id": id, "result": result])
    }

    func write(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
