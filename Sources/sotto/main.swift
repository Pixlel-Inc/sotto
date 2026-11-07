import Foundation
import SottoCore

let usage = """
sotto \(Sotto.version): private meeting notes, transcribed on this Mac.

Usage:
  sotto record [--room] [--title "..."]   Record until Ctrl-C, then transcribe.
                                           Default records your mic and computer audio
                                           as separate tracks; --room records the mic only.
  sotto transcribe <file> [--title "..."]  Import an audio file and transcribe it.
  sotto retranscribe <id>                  Run transcription again on a recording.
                                           record, transcribe and retranscribe take
                                           --speakers N when you know how many people talked.
  sotto list [--limit N]                   List recordings, newest first.
  sotto show <id> [--json]                 Print a transcript.
  sotto search <words...>                  Search every transcript.
  sotto rename <id> <speaker> <name>       Name a speaker ("Speaker 2" -> "Dustin").
  sotto title <id> <title>                 Rename a recording.
  sotto inbox                              Import and transcribe files in the inbox folder.
  sotto models                             Download the speech and speaker models now.
  sotto serve                              Run the local HTTP API (127.0.0.1 only).
  sotto mcp                                Run the MCP server on stdio (for Claude and others).
  sotto token                              Print the API token.
  sotto paths                              Show where files are kept.
  sotto reindex                            Rebuild the search index.

Ids can be shortened to any unique prefix, like 2026-11-06_14.
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("sotto: \(message)\n".utf8))
    exit(1)
}

func log(_ s: String) {
    FileHandle.standardError.write(Data("\(s)\n".utf8))
}

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { print(usage); exit(0) }
args.removeFirst()

func flag(_ name: String) -> Bool {
    if let i = args.firstIndex(of: name) { args.remove(at: i); return true }
    return false
}

func option(_ name: String) -> String? {
    if let i = args.firstIndex(of: name), i + 1 < args.count {
        let v = args[i + 1]
        args.removeSubrange(i...(i + 1))
        return v
    }
    return nil
}

func json(_ obj: Any) -> String {
    let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
    return String(data: data, encoding: .utf8) ?? "{}"
}

let library: Library
let index: SearchIndex
do {
    library = try Library()
    index = try SearchIndex(library: library)
} catch {
    fail(error.localizedDescription)
}
let api = SottoAPI(library: library, index: index)

func runAsync(_ body: @escaping () async throws -> Void) -> Never {
    Task {
        do { try await body(); exit(0) } catch { fail(error.localizedDescription) }
    }
    dispatchMain()
}

func pipeline() async -> Pipeline {
    let p = Pipeline(library: library, index: index)
    await p.setHandlers(onChange: nil, log: { log($0) })
    return p
}

switch command {
case "help", "-h", "--help":
    print(usage)

case "paths":
    print("Recordings: \(library.paths.recordings.path)")
    print("Inbox:      \(library.paths.inbox.path)")
    print("Settings:   \(library.paths.configFile.path)")
    print("Index:      \(library.paths.indexDB.path)")

case "token":
    print(library.config.apiToken)

case "list":
    let limit = Int(option("--limit") ?? "") ?? 30
    let metas = library.allMetas().prefix(limit)
    if metas.isEmpty { print("No recordings yet. Run `sotto record` or drop audio in \(library.paths.inbox.path)") }
    for m in metas {
        let status = m.status == .done ? "" : "  [\(m.status.rawValue)]"
        print("\(m.id)  \(Render.duration(m.duration).padding(toLength: 10, withPad: " ", startingAt: 0))  \(m.title)\(status)")
    }

case "show":
    guard let id = args.first else { fail("show needs a recording id") }
    do {
        if flag("--json") || args.contains("--json") { print(json(try api.get(id))) }
        else { print(try api.markdown(id)) }
    } catch { fail(error.localizedDescription) }

case "search":
    let q = args.joined(separator: " ")
    guard !q.isEmpty else { fail("search needs some words") }
    do {
        let hits = try api.search(q, limit: 30)
        if hits.isEmpty { print("No matches.") }
        for h in hits {
            print("\(h["recording_id"]!)  \(h["at"]!)  \(h["speaker"]!): \(h["snippet"]!)")
        }
    } catch { fail(error.localizedDescription) }

case "rename":
    guard args.count >= 3 else { fail("usage: sotto rename <id> <speaker> <name>") }
    do {
        let r = try api.renameSpeaker(args[0], speaker: args[1], name: args[2...].joined(separator: " "))
        print("\(r["speaker_label"]!) is now \(r["name"]!) in \(r["id"]!)")
    } catch { fail(error.localizedDescription) }

case "title":
    guard args.count >= 2 else { fail("usage: sotto title <id> <title>") }
    do { _ = try api.setTitle(args[0], title: args[1...].joined(separator: " ")); print("Renamed.") }
    catch { fail(error.localizedDescription) }

case "reindex":
    try? FileManager.default.removeItem(at: library.paths.indexDB)
    do {
        let fresh = try SearchIndex(library: library)
        fresh.sync()
        print("Indexed \(library.allMetas().count) recordings.")
    } catch { fail(error.localizedDescription) }

case "models":
    runAsync {
        let p = await pipeline()
        try await p.prepareModels()
        print("Models ready.")
    }

case "transcribe":
    let title = option("--title")
    let speakers = option("--speakers").flatMap { Int($0) }
    guard let path = args.first else { fail("transcribe needs an audio file") }
    let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    guard FileManager.default.fileExists(atPath: url.path) else { fail("no file at \(url.path)") }
    runAsync {
        let p = await pipeline()
        let meta = try await p.importFile(url, title: title)
        if let speakers { _ = try library.updateMeta(meta.id) { $0.expectedSpeakers = speakers } }
        log("Imported as \(meta.id)")
        try await p.process(meta.id)
        print(try library.markdown(meta.id))
    }

case "retranscribe":
    let speakers = option("--speakers").flatMap { Int($0) }
    guard let input = args.first else { fail("retranscribe needs a recording id") }
    runAsync {
        let id = try library.resolveId(input)
        if let speakers { _ = try library.updateMeta(id) { $0.expectedSpeakers = speakers } }
        let p = await pipeline()
        try await p.process(id)
        print(try library.markdown(id))
    }

case "inbox":
    runAsync {
        let p = await pipeline()
        let fm = FileManager.default
        // Files changed in the last few seconds may still be copying; wait them out once.
        let names = (try? fm.contentsOfDirectory(atPath: library.paths.inbox.path)) ?? []
        if names.isEmpty { print("Inbox is empty: \(library.paths.inbox.path)"); return }
        try await Task.sleep(nanoseconds: 5_500_000_000)
        let ids = await p.scanInbox()
        for id in ids { try await p.process(id) }
        print("Imported \(ids.count) file(s).")
    }

case "record":
    let mode: Recorder.Mode = flag("--room") ? .room : .call
    let title = option("--title")
    let speakers = option("--speakers").flatMap { Int($0) }
    if library.config.consentReminder {
        log("Reminder: tell everyone on the call that you are recording. (Turn this off with \"consentReminder\": false in \(library.paths.configFile.path))")
    }
    let recorder = Recorder()
    let meta: RecordingMeta
    do {
        meta = try library.createRecording(title: title, source: "live")
        if let speakers { _ = try library.updateMeta(meta.id) { $0.expectedSpeakers = speakers } }
    } catch { fail(error.localizedDescription) }
    do {
        let warnings = try recorder.start(mode: mode, folder: library.folder(for: meta.id))
        warnings.forEach { log($0) }
    } catch {
        try? FileManager.default.removeItem(at: library.folder(for: meta.id))
        fail(error.localizedDescription)
    }
    log("Recording \(meta.id) (\(mode == .call ? "mic + computer audio" : "mic only")). Press Ctrl-C to stop.")
    signal(SIGINT, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    source.setEventHandler {
        source.cancel()
        let result = recorder.stop()
        result.errors.forEach { log($0) }
        log("Stopped after \(Render.duration(result.duration)). Transcribing...")
        _ = try? library.updateMeta(meta.id) { $0.tracks = result.tracks; $0.duration = result.duration; $0.status = .queued }
        runAsync {
            let p = await pipeline()
            try await p.process(meta.id)
            print(try library.markdown(meta.id))
        }
    }
    source.resume()
    dispatchMain()

case "serve":
    let server = HTTPServer(api: api, port: library.config.port, token: library.config.apiToken)
    do { try server.start() } catch { fail("could not listen on 127.0.0.1:\(library.config.port): \(error.localizedDescription)") }
    log("Sotto API on http://127.0.0.1:\(library.config.port) (token: `sotto token`). Ctrl-C to stop.")
    dispatchMain()

case "mcp":
    MCPServer(api: api).run()

default:
    fail("unknown command \"\(command)\". Run `sotto help`.")
}
