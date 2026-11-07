import AVFoundation
import FluidAudio
import Foundation

/// A word with its time, after it has been given a speaker.
struct Word {
    var text: String
    var start: Double
    var end: Double
    var speaker: String
}

/// Runs speech recognition (Parakeet) and speaker diarization (pyannote) on the
/// Neural Engine. Models download once, from Hugging Face, on first use; after
/// that nothing leaves the Mac.
public actor Transcriber {
    private var asr: AsrManager?
    private var diarizer: OfflineDiarizerManager?
    private let modelName: String

    public init(model: String = "v3") {
        self.modelName = model
        // The speech library logs every step at debug level; keep the console readable.
        AppLogger.minimumLevel = getenv("SOTTO_DEBUG") == nil ? .warning : .debug
    }

    var version: AsrModelVersion {
        switch modelName.lowercased() {
        case "v2": return .v2
        case "ultra": return .ultra
        default: return .v3
        }
    }

    public var modelLabel: String { "parakeet-\(modelName.lowercased()) + pyannote-community-1" }

    /// Downloads (first run only) and loads both models.
    public func prepare(log: (@Sendable (String) -> Void)? = nil) async throws {
        if asr == nil {
            log?("Loading speech model (first run downloads about 500 MB)...")
            let models = try await AsrModels.downloadAndLoad(version: version)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            asr = manager
        }
        if diarizer == nil {
            log?("Loading speaker model...")
            let d = OfflineDiarizerManager(config: .default)
            try await d.prepareModels()
            diarizer = d
        }
    }

    /// Transcribes every track of a recording and merges them into one timeline.
    public func transcribe(meta: RecordingMeta, folder: URL, voices: [VoiceBook.Voice], threshold: Float,
                           log: (@Sendable (String) -> Void)? = nil) async throws
        -> (segments: [Segment], embeddings: [String: [Float]], names: [String: String])
    {
        try await prepare(log: log)
        var allWords: [[Word]] = []
        var roles: [TrackRole] = []
        var embeddings: [String: [Float]] = [:]
        var nextSpeaker = 1

        for track in meta.tracks {
            let url = folder.appendingPathComponent(track.file)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            log?("Reading \(track.file)...")
            let samples = try AudioConverter().resampleAudioFile(url)
            if Transcriber.isSilent(samples) {
                log?("\(track.file) is silent, skipping")
                continue
            }
            log?("Transcribing \(track.file) (\(Render.duration(Double(samples.count) / 16000)))...")
            let words = try await recognize(samples)
            var labelled: [Word]
            if track.role == .me {
                labelled = words.map { Word(text: $0.word, start: $0.startTime, end: $0.endTime, speaker: "me") }
            } else {
                log?("Finding speakers in \(track.file)...")
                var hint = meta.expectedSpeakers
                if let n = hint, track.role == .others { hint = max(1, n - 1) }
                let result = try await diarize(samples, speakers: hint)
                // Number speakers across the whole recording in order of first appearance.
                var map: [String: String] = [:]
                for seg in result.segments.sorted(by: { $0.startTimeSeconds < $1.startTimeSeconds })
                where map[seg.speakerId] == nil {
                    map[seg.speakerId] = "S\(nextSpeaker)"
                    nextSpeaker += 1
                }
                for (raw, label) in map {
                    if let e = Transcriber.centroid(raw, result: result) { embeddings[label] = e }
                }
                labelled = Transcriber.assign(words: words, segments: result.segments, map: map)
            }
            allWords.append(labelled.map { var w = $0; w.start += track.offset; w.end += track.offset; return w })
            roles.append(track.role)
        }

        // Without headphones the mic also hears the other side through the speakers.
        // Drop mic words that are the same word, at the same moment, as the computer audio.
        if let meIndex = roles.firstIndex(of: .me), let othersIndex = roles.firstIndex(of: .others) {
            allWords[meIndex] = Transcriber.removeEcho(mic: allWords[meIndex], others: allWords[othersIndex])
        }

        let merged = allWords.flatMap { $0 }.sorted { $0.start < $1.start }
        var segments = Transcriber.group(merged)
        segments = Transcriber.renumber(segments, embeddings: &embeddings)

        // Put remembered names on voices we have heard before.
        var names: [String: String] = [:]
        let book = VoiceBook(paths: SottoPaths.standard())
        var used = Set<String>()
        for (label, e) in embeddings.sorted(by: { $0.key < $1.key }) {
            if let (name, _) = book.match(e, threshold: threshold, among: voices), !used.contains(name) {
                names[label] = name
                used.insert(name)
            }
        }
        return (segments, embeddings, names)
    }

    private func diarize(_ samples: [Float], speakers: Int?) async throws -> DiarizationResult {
        guard let speakers, speakers > 0 else { return try await diarizer!.process(audio: samples) }
        var config = OfflineDiarizerConfig.default
        config.clustering.numSpeakers = speakers
        let d = OfflineDiarizerManager(config: config)
        try await d.prepareModels()
        return try await d.process(audio: samples)
    }

    private func recognize(_ samples: [Float]) async throws -> [WordTiming] {
        guard let asr else { throw SottoError.invalid("speech model not loaded") }
        var state = TdtDecoderState.make(decoderLayers: version.decoderLayers)
        let result = try await asr.transcribe(samples, decoderState: &state)
        return buildWordTimings(from: result.tokenTimings ?? [])
    }

    // MARK: Pure helpers (tested)

    static func isSilent(_ samples: [Float]) -> Bool {
        guard !samples.isEmpty else { return true }
        var peak: Float = 0
        var sum: Float = 0
        for s in samples { let a = abs(s); peak = max(peak, a); sum += s * s }
        let rms = (sum / Float(samples.count)).squareRoot()
        return peak < 0.003 || rms < 0.0003
    }

    static func centroid(_ raw: String, result: DiarizationResult) -> [Float]? {
        if let e = result.speakerDatabase?[raw], !e.isEmpty { return e }
        let segs = result.segments.filter { $0.speakerId == raw && !$0.embedding.isEmpty }
        guard let first = segs.first else { return nil }
        var acc = [Float](repeating: 0, count: first.embedding.count)
        var weight: Float = 0
        for s in segs where s.embedding.count == acc.count {
            let w = max(0.1, s.durationSeconds)
            for i in acc.indices { acc[i] += s.embedding[i] * w }
            weight += w
        }
        return weight > 0 ? acc.map { $0 / weight } : nil
    }

    /// Gives each word the speaker whose turn overlaps it most, or the nearest turn.
    static func assign(words: [WordTiming], segments: [TimedSpeakerSegment], map: [String: String]) -> [Word] {
        let turns = segments.map { (Double($0.startTimeSeconds), Double($0.endTimeSeconds), map[$0.speakerId] ?? "S?") }
        var lastSpeaker = turns.first?.2 ?? "S1"
        let labelled = words.map { w in
            var best: (overlap: Double, label: String)?
            var nearest: (distance: Double, label: String)?
            for (s, e, label) in turns {
                let overlap = min(e, w.endTime) - max(s, w.startTime)
                if overlap > 0, overlap > (best?.overlap ?? 0) { best = (overlap, label) }
                let mid = (w.startTime + w.endTime) / 2
                let distance = mid < s ? s - mid : (mid > e ? mid - e : 0)
                if distance < (nearest?.distance ?? .infinity) { nearest = (distance, label) }
            }
            let label: String
            if let b = best { label = b.label }
            else if let n = nearest, n.distance < 1.5 { label = n.label }
            else { label = lastSpeaker }
            lastSpeaker = label
            return Word(text: w.word, start: w.startTime, end: w.endTime, speaker: label)
        }
        return smoothBySentence(labelled)
    }

    /// Turn boundaries from the speaker model are a little blurry, so a word or two
    /// at the edge of a turn can land on the wrong person ("Sounds | good."). People
    /// rarely hand over mid-sentence, so give each short sentence to whoever spoke
    /// most of it.
    static func smoothBySentence(_ words: [Word], maxWords: Int = 25) -> [Word] {
        var out = words
        var start = 0
        func flush(_ end: Int) {
            guard end > start else { return }
            let range = start..<end
            if range.count <= maxWords {
                var time: [String: Double] = [:]
                for i in range { time[out[i].speaker, default: 0] += max(0.05, out[i].end - out[i].start) }
                if let winner = time.max(by: { $0.value < $1.value })?.key {
                    for i in range { out[i].speaker = winner }
                }
            }
            start = end
        }
        for (i, w) in words.enumerated() {
            let endsSentence = w.text.last.map { ".?!".contains($0) } ?? false
            let pauseAfter = i + 1 < words.count ? words[i + 1].start - w.end : 0
            if endsSentence || pauseAfter > 1.0 { flush(i + 1) }
        }
        flush(words.count)
        return out
    }

    static func normalize(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    static func removeEcho(mic: [Word], others: [Word]) -> [Word] {
        guard !others.isEmpty else { return mic }
        let sortedOthers = others.sorted { $0.start < $1.start }
        let starts = sortedOthers.map(\.start)
        return mic.filter { w in
            let key = normalize(w.text)
            guard !key.isEmpty else { return true }
            // Binary search to the window of computer-audio words near this mic word.
            var lo = 0, hi = starts.count
            while lo < hi { let mid = (lo + hi) / 2; if starts[mid] < w.start - 1.0 { lo = mid + 1 } else { hi = mid } }
            var i = lo
            while i < sortedOthers.count, sortedOthers[i].start <= w.start + 1.0 {
                if normalize(sortedOthers[i].text) == key { return false }
                i += 1
            }
            return true
        }
    }

    /// Joins words into turns: a new turn when the speaker changes, after a long
    /// pause, or when a long turn reaches the end of a sentence.
    static func group(_ words: [Word], pause: Double = 2.0, maxTurn: Double = 45) -> [Segment] {
        var out: [Segment] = []
        for w in words {
            if var last = out.last, last.speaker == w.speaker, w.start - last.end < pause,
               !(w.start - last.start > maxTurn && last.text.last.map { ".?!".contains($0) } == true) {
                last.text += " " + w.text
                last.end = max(last.end, w.end)
                out[out.count - 1] = last
            } else {
                out.append(Segment(start: w.start, end: w.end, speaker: w.speaker, text: w.text))
            }
        }
        return out.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Diarizers sometimes find a "speaker" that never says a word. Renumber the
    /// ones that do, so the transcript reads Speaker 1, 2, 3 with no gaps.
    static func renumber(_ segments: [Segment], embeddings: inout [String: [Float]]) -> [Segment] {
        var map: [String: String] = ["me": "me"]
        var n = 1
        for s in segments where map[s.speaker] == nil {
            map[s.speaker] = "S\(n)"; n += 1
        }
        var newEmbeddings: [String: [Float]] = [:]
        for (old, new) in map { if let e = embeddings[old] { newEmbeddings[new] = e } }
        embeddings = newEmbeddings
        return segments.map { var s = $0; s.speaker = map[s.speaker] ?? s.speaker; return s }
    }
}
