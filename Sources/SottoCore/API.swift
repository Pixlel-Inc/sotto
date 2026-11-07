import Foundation

/// The actions both the HTTP API and the MCP server offer, in one place.
public final class SottoAPI: @unchecked Sendable {
    public let library: Library
    public let index: SearchIndex
    /// Set by the app so the API can start and stop recordings. Nil in the CLI server.
    public var recordControl: RecordControl?

    public init(library: Library, index: SearchIndex) {
        self.library = library
        self.index = index
    }

    var owner: String { library.config.ownerName }

    static let isoDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    public static func parseDate(_ s: String?, endOfDay: Bool = false) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        if let d = ISO8601DateFormatter().date(from: s) { return d }
        if let d = isoDay.date(from: s) { return endOfDay ? d.addingTimeInterval(86399) : d }
        return nil
    }

    public func list(limit: Int = 20, since: Date? = nil, until: Date? = nil, query: String? = nil) -> [[String: Any]] {
        var metas = library.allMetas()
        if let since { metas = metas.filter { $0.startedAt >= since } }
        if let until { metas = metas.filter { $0.startedAt <= until } }
        if let q = query?.lowercased(), !q.isEmpty { metas = metas.filter { $0.title.lowercased().contains(q) } }
        return metas.prefix(max(1, min(limit, 500))).map {
            Render.summary(meta: $0, ownerName: owner, transcript: library.loadTranscript($0.id))
        }
    }

    public func get(_ input: String) throws -> [String: Any] {
        let id = try library.resolveId(input)
        let meta = try library.loadMeta(id)
        var dict = Render.json(meta: meta, transcript: library.loadTranscript(id), ownerName: owner)
        dict["folder"] = library.folder(for: id).path
        return dict
    }

    public func markdown(_ input: String) throws -> String {
        try library.markdown(try library.resolveId(input))
    }

    public func search(_ query: String, limit: Int = 20, recording: String? = nil) throws -> [[String: Any]] {
        let rid = try recording.map { try library.resolveId($0) }
        return try index.search(query, limit: max(1, min(limit, 200)), recordingId: rid).map {
            [
                "recording_id": $0.recordingId,
                "title": $0.title,
                "started_at": ISO8601DateFormatter().string(from: $0.startedAt),
                "at": Render.clock($0.start),
                "at_seconds": Int($0.start),
                "speaker": $0.speaker,
                "snippet": $0.snippet,
            ]
        }
    }

    public func renameSpeaker(_ input: String, speaker: String, name: String) throws -> [String: Any] {
        let id = try library.resolveId(input)
        let label = try library.renameSpeaker(id: id, speaker: speaker, to: name)
        try? index.reindex(id)
        return ["id": id, "speaker_label": label, "name": name]
    }

    public func setTitle(_ input: String, title: String) throws -> [String: Any] {
        let id = try library.resolveId(input)
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw SottoError.invalid("title is empty") }
        _ = try library.updateMeta(id) { $0.title = clean }
        try? library.writeMarkdown(id)
        try? index.reindex(id)
        return ["id": id, "title": clean]
    }

    public func status() -> [String: Any] {
        var dict: [String: Any] = ["version": Sotto.version, "recordings": library.allMetas().count,
                                   "folder": library.paths.home.path]
        if let rc = recordControl {
            dict["recording"] = rc.isRecording()
            if let id = rc.currentId() { dict["current_recording_id"] = id }
        }
        return dict
    }
}

/// Lets the API drive the app's recorder.
public struct RecordControl: Sendable {
    public var isRecording: @Sendable () -> Bool
    public var currentId: @Sendable () -> String?
    public var start: @Sendable (_ mode: Recorder.Mode, _ title: String?) async throws -> String
    public var stop: @Sendable () async throws -> String

    public init(isRecording: @escaping @Sendable () -> Bool, currentId: @escaping @Sendable () -> String?,
                start: @escaping @Sendable (Recorder.Mode, String?) async throws -> String,
                stop: @escaping @Sendable () async throws -> String) {
        self.isRecording = isRecording
        self.currentId = currentId
        self.start = start
        self.stop = stop
    }
}
