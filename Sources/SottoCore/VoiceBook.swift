import Foundation

/// Remembers voices you have named. When you rename "Speaker 2" to "Dustin",
/// Sotto stores the average voice embedding for that speaker. Later recordings
/// whose speaker sounds close enough get the name automatically.
public struct VoiceBook {
    public struct Voice: Codable {
        public var name: String
        public var embedding: [Float]
        public var samples: Int
    }

    let paths: SottoPaths

    public init(paths: SottoPaths) { self.paths = paths }

    public func load() -> [Voice] {
        guard let data = try? Data(contentsOf: paths.voicesFile) else { return [] }
        return (try? JSONDecoder().decode([Voice].self, from: data)) ?? []
    }

    func save(_ voices: [Voice]) throws {
        try JSONEncoder().encode(voices).write(to: paths.voicesFile, options: .atomic)
    }

    public func remember(name: String, embedding: [Float]) throws {
        var voices = load()
        if let i = voices.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) {
            // Running average, so the voice gets steadier with every named recording.
            let n = Float(voices[i].samples)
            if voices[i].embedding.count == embedding.count {
                voices[i].embedding = zip(voices[i].embedding, embedding).map { ($0 * n + $1) / (n + 1) }
                voices[i].samples += 1
            } else {
                voices[i].embedding = embedding
                voices[i].samples = 1
            }
        } else {
            voices.append(Voice(name: name, embedding: embedding, samples: 1))
        }
        try save(voices)
    }

    public func forget(name: String) throws {
        try save(load().filter { $0.name.lowercased() != name.lowercased() })
    }

    /// Best remembered name for an embedding, if it clears the threshold.
    public func match(_ embedding: [Float], threshold: Float, among voices: [Voice]) -> (String, Float)? {
        var best: (String, Float)?
        for v in voices {
            let sim = VoiceBook.cosine(v.embedding, embedding)
            if sim >= threshold, sim > (best?.1 ?? -1) { best = (v.name, sim) }
        }
        return best
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return -1 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        guard na > 0, nb > 0 else { return -1 }
        return dot / (na.squareRoot() * nb.squareRoot())
    }

    // Per-recording embeddings live next to the audio in speakers.json.

    public func recordingEmbeddings(folder: URL) -> [String: [Float]] {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("speakers.json")) else { return [:] }
        return (try? JSONDecoder().decode([String: [Float]].self, from: data)) ?? [:]
    }

    public func saveRecordingEmbeddings(_ e: [String: [Float]], folder: URL) throws {
        try JSONEncoder().encode(e).write(to: folder.appendingPathComponent("speakers.json"), options: .atomic)
    }
}
