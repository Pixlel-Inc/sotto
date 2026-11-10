import AVFoundation
import Foundation

/// Takes a finished recording (or an imported file) to a searchable transcript.
/// Jobs run one at a time; models stay loaded between jobs.
public actor Pipeline {
    public let library: Library
    public let index: SearchIndex
    private let transcriber: Transcriber
    private var queue: [String] = []
    private var running = false
    public var onChange: (@Sendable (String, RecordingStatus) -> Void)?
    public var log: (@Sendable (String) -> Void)?

    public init(library: Library, index: SearchIndex) {
        self.library = library
        self.index = index
        self.transcriber = Transcriber(model: library.config.asrModel)
    }

    public func setHandlers(onChange: (@Sendable (String, RecordingStatus) -> Void)?, log: (@Sendable (String) -> Void)?) {
        self.onChange = onChange
        self.log = log
    }

    public func prepareModels() async throws {
        try await transcriber.prepare(log: log)
    }

    public static let audioExtensions: Set<String> = ["m4a", "wav", "mp3", "aac", "caf", "aif", "aiff", "flac", "mp4", "mov", "opus"]

    /// Copies (or moves) an audio file into a new recording folder.
    public func importFile(_ url: URL, title: String? = nil, move: Bool = false) throws -> RecordingMeta {
        let ext = url.pathExtension.lowercased()
        guard Pipeline.audioExtensions.contains(ext) else {
            throw SottoError.invalid("\(url.lastPathComponent) is not an audio file Sotto reads (\(Pipeline.audioExtensions.sorted().joined(separator: ", ")))")
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let started = (attrs?[.creationDate] as? Date) ?? Date()
        let name = title ?? url.deletingPathExtension().lastPathComponent
        var meta = try library.createRecording(title: name, source: "import", startedAt: started)
        let dest = library.folder(for: meta.id).appendingPathComponent("audio.\(ext)")
        if move { try FileManager.default.moveItem(at: url, to: dest) }
        else { try FileManager.default.copyItem(at: url, to: dest) }
        meta = try library.updateMeta(meta.id) {
            $0.tracks = [Track(file: dest.lastPathComponent, role: .room)]
            $0.duration = Pipeline.duration(of: dest)
            $0.status = .queued
        }
        try? index.reindex(meta.id)
        return meta
    }

    static func duration(of url: URL) -> Double {
        guard let f = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(f.length) / f.fileFormat.sampleRate
    }

    /// Adds a recording to the queue and processes the queue in order.
    public func enqueue(_ id: String) {
        if !queue.contains(id) { queue.append(id) }
        _ = try? library.updateMeta(id) { if $0.status != .transcribing { $0.status = .queued } }
        onChange?(id, .queued)
        if !running {
            running = true
            Task { await self.drain() }
        }
    }

    private func drain() async {
        while !queue.isEmpty {
            let id = queue.removeFirst()
            _ = try? await process(id)
        }
        running = false
    }

    /// Transcribes one recording now. Returns the finished transcript.
    @discardableResult
    public func process(_ id: String) async throws -> Transcript {
        var meta = try library.updateMeta(id) { $0.status = .transcribing; $0.error = nil }
        onChange?(id, .transcribing)
        let folder = library.folder(for: id)
        do {
            if meta.duration == 0 {
                let d = meta.tracks.map { Pipeline.duration(of: folder.appendingPathComponent($0.file)) + $0.offset }.max() ?? 0
                meta = try library.updateMeta(id) { $0.duration = d }
            }
            let voices = VoiceBook(paths: library.paths)
            let result = try await transcriber.transcribe(
                meta: meta, folder: folder, voices: voices.load(),
                threshold: library.config.voiceMatchThreshold, log: log)
            try voices.saveRecordingEmbeddings(result.embeddings, folder: folder)
            let model = await transcriber.modelLabel
            let transcript = Transcript(recordingId: id, model: model, segments: result.segments)
            _ = try library.updateMeta(id) { m in
                m.status = .done
                m.model = model
                // Remembered voices fill in names, but never overwrite one you typed.
                for (label, name) in result.names where m.speakers[label] == nil { m.speakers[label] = name }
            }
            try library.saveTranscript(transcript)
            try? index.reindex(id)
            onChange?(id, .done)
            log?("Done: \(meta.title)")
            return transcript
        } catch {
            _ = try? library.updateMeta(id) { $0.status = .failed; $0.error = error.localizedDescription }
            try? index.reindex(id)
            onChange?(id, .failed)
            log?("Failed: \(meta.title): \(error.localizedDescription)")
            throw error
        }
    }

    /// Picks up files dropped in the inbox folder. Files still being written
    /// (changed in the last few seconds) are left for the next pass.
    public func scanInbox() -> [String] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: library.paths.inbox.path) else { return [] }
        var ids: [String] = []
        for name in names.sorted() where !name.hasPrefix(".") {
            let url = library.paths.inbox.appendingPathComponent(name)
            guard Pipeline.audioExtensions.contains(url.pathExtension.lowercased()) else { continue }
            let modified = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date ?? Date()
            if Date().timeIntervalSince(modified) < 5 { continue }
            do {
                let meta = try importFile(url, move: true)
                ids.append(meta.id)
                enqueue(meta.id)
            } catch {
                log?("Inbox: could not import \(name): \(error.localizedDescription)")
            }
        }
        return ids
    }

    /// Whether anyone said anything in these tracks. If a track cannot be checked the answer
    /// is yes, so a problem here can never end a recording early. Two words, because noise
    /// can come out as one stray word.
    public func heardWords(in tracks: [[Float]]) async -> Bool {
        for samples in tracks where !samples.isEmpty {
            guard let count = try? await transcriber.wordCount(samples) else { return true }
            if count >= 2 { return true }
        }
        return false
    }

    /// Saves recordings that never reached Stop because the app quit or the Mac went down.
    public func recoverInterrupted(excluding active: String? = nil) {
        for meta in library.allMetas() where meta.status == .recording && meta.id != active {
            do {
                guard let found = try Recorder.recover(folder: library.folder(for: meta.id)) else { continue }
                if found.tracks.isEmpty {
                    _ = try library.updateMeta(meta.id) { $0.status = .failed; $0.error = "Sotto closed before any audio was saved." }
                    try? index.reindex(meta.id)
                    onChange?(meta.id, .failed)
                } else {
                    _ = try library.updateMeta(meta.id) { $0.tracks = found.tracks; $0.duration = found.duration; $0.status = .queued }
                    log?("Recovered \(meta.title)")
                    enqueue(meta.id)
                }
            } catch {
                _ = try? library.updateMeta(meta.id) { $0.status = .failed; $0.error = "Could not recover: \(error.localizedDescription)" }
                onChange?(meta.id, .failed)
            }
        }
    }

    /// Recordings left queued or half-done (the app quit mid-job) go back on the queue.
    public func resumeUnfinished() {
        for meta in library.allMetas() where meta.status == .queued || meta.status == .transcribing {
            enqueue(meta.id)
        }
    }
}
