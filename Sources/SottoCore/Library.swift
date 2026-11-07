import Foundation

public enum SottoError: LocalizedError {
    case notFound(String)
    case invalid(String)
    case audio(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let s): return "Not found: \(s)"
        case .invalid(let s): return s
        case .audio(let s): return "Audio: \(s)"
        }
    }
}

/// The recordings folder. Files on disk are the source of truth: each recording
/// is a folder holding its audio, meta.json, transcript.json and transcript.md.
public final class Library: @unchecked Sendable {
    public let paths: SottoPaths
    public var config: SottoConfig
    private let lock = NSLock()

    public init(paths: SottoPaths = .standard()) throws {
        self.paths = paths
        self.config = try SottoConfig.load(paths)
    }

    public func reloadConfig() {
        if let c = try? SottoConfig.load(paths) { config = c }
    }

    // MARK: Folders

    public func folder(for id: String) -> URL {
        paths.recordings.appendingPathComponent(id, isDirectory: true)
    }

    static let idFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        return f
    }()

    static let titleFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE MMM d, h:mm a"
        return f
    }()

    /// Makes a new, empty recording folder and its meta.json.
    public func createRecording(title: String?, source: String, startedAt: Date = Date()) throws -> RecordingMeta {
        lock.lock(); defer { lock.unlock() }
        try paths.ensure()
        let base = Library.idFormatter.string(from: startedAt)
        var id = base
        var n = 2
        while FileManager.default.fileExists(atPath: folder(for: id).path) {
            id = "\(base)-\(n)"; n += 1
        }
        try FileManager.default.createDirectory(at: folder(for: id), withIntermediateDirectories: true)
        let name = (title?.isEmpty == false) ? title! : "Recording \(Library.titleFormatter.string(from: startedAt))"
        let meta = RecordingMeta(id: id, title: name, startedAt: startedAt, source: source)
        try saveMeta(meta)
        return meta
    }

    // MARK: Meta and transcript

    public func loadMeta(_ id: String) throws -> RecordingMeta {
        let url = folder(for: id).appendingPathComponent("meta.json")
        guard let data = try? Data(contentsOf: url) else { throw SottoError.notFound("recording \(id)") }
        return try JSONCoding.decoder().decode(RecordingMeta.self, from: data)
    }

    public func saveMeta(_ meta: RecordingMeta) throws {
        let url = folder(for: meta.id).appendingPathComponent("meta.json")
        try JSONCoding.encoder().encode(meta).write(to: url, options: .atomic)
    }

    public func updateMeta(_ id: String, _ change: (inout RecordingMeta) -> Void) throws -> RecordingMeta {
        lock.lock(); defer { lock.unlock() }
        var meta = try loadMeta(id)
        change(&meta)
        try saveMeta(meta)
        return meta
    }

    public func loadTranscript(_ id: String) -> Transcript? {
        let url = folder(for: id).appendingPathComponent("transcript.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONCoding.decoder().decode(Transcript.self, from: data)
    }

    public func transcriptModified(_ id: String) -> Date? {
        let url = folder(for: id).appendingPathComponent("transcript.json")
        return (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    public func metaModified(_ id: String) -> Date? {
        let url = folder(for: id).appendingPathComponent("meta.json")
        return (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// Writes transcript.json and transcript.md for a recording.
    public func saveTranscript(_ transcript: Transcript) throws {
        let dir = folder(for: transcript.recordingId)
        try JSONCoding.encoder().encode(transcript).write(to: dir.appendingPathComponent("transcript.json"), options: .atomic)
        try writeMarkdown(transcript.recordingId)
    }

    /// Rewrites transcript.md from transcript.json and meta.json (after a rename, say).
    public func writeMarkdown(_ id: String) throws {
        let meta = try loadMeta(id)
        guard let transcript = loadTranscript(id) else { return }
        let md = Render.markdown(meta: meta, transcript: transcript, ownerName: config.ownerName)
        try md.write(to: folder(for: id).appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
    }

    public func markdown(_ id: String) throws -> String {
        let meta = try loadMeta(id)
        guard let transcript = loadTranscript(id) else {
            return Render.header(meta: meta, transcript: nil, ownerName: config.ownerName)
                + "\n_No transcript yet (status: \(meta.status.rawValue))._\n"
        }
        return Render.markdown(meta: meta, transcript: transcript, ownerName: config.ownerName)
    }

    /// Every recording, newest first.
    public func allMetas() -> [RecordingMeta] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: paths.recordings.path) else { return [] }
        return names.compactMap { try? loadMeta($0) }.sorted { $0.startedAt > $1.startedAt }
    }

    /// Accepts a full id or any unique prefix of one ("2026-11-06" when there is one that day).
    public func resolveId(_ input: String) throws -> String {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: paths.recordings.path)) ?? []
        if names.contains(input) { return input }
        let matches = names.filter { $0.hasPrefix(input) }
        if matches.count == 1 { return matches[0] }
        if matches.isEmpty { throw SottoError.notFound("recording \(input)") }
        throw SottoError.invalid("\"\(input)\" matches \(matches.count) recordings; use the full id")
    }

    // MARK: Speakers

    /// Names a speaker in one recording, and remembers the voice for next time.
    @discardableResult
    public func renameSpeaker(id: String, speaker: String, to name: String) throws -> String {
        let transcript = loadTranscript(id)
        let labels = transcript?.labels ?? []
        let current = try loadMeta(id)
        guard let label = current.resolveLabel(speaker, labels: labels, ownerName: config.ownerName) else {
            let names = labels.map { current.displayName(for: $0, ownerName: config.ownerName) }
            throw SottoError.notFound("speaker \"\(speaker)\" (this recording has: \(names.joined(separator: ", ")))")
        }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw SottoError.invalid("name is empty") }
        _ = try updateMeta(id) { $0.speakers[label] = clean }
        try writeMarkdown(id)
        if label != "me" {
            let voices = VoiceBook(paths: paths)
            if let embedding = voices.recordingEmbeddings(folder: folder(for: id))[label] {
                try? voices.remember(name: clean, embedding: embedding)
            }
        }
        return label
    }
}
