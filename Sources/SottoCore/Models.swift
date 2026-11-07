import Foundation

public enum TrackRole: String, Codable, Sendable {
    /// Your microphone during a call: everything on it is you.
    case me
    /// Computer audio during a call: everyone else, split by voice.
    case others
    /// A single recording of a room (or an imported file): everyone, split by voice.
    case room
}

public struct Track: Codable, Sendable {
    public var file: String
    public var role: TrackRole
    /// Seconds from the start of the recording to the first sample of this track.
    public var offset: Double

    public init(file: String, role: TrackRole, offset: Double = 0) {
        self.file = file
        self.role = role
        self.offset = offset
    }
}

public enum RecordingStatus: String, Codable, Sendable {
    case recording, queued, transcribing, done, failed
}

public struct RecordingMeta: Codable, Sendable {
    public var id: String
    public var title: String
    public var startedAt: Date
    public var duration: Double
    /// "live" for recordings made by Sotto, "import" for files dropped in the inbox.
    public var source: String
    public var tracks: [Track]
    public var status: RecordingStatus
    public var error: String?
    /// Speaker label ("me", "S1", "S2") to the name shown in transcripts.
    public var speakers: [String: String]
    public var model: String?
    /// How many people were in the conversation, if you said. Helps the speaker split.
    public var expectedSpeakers: Int?

    public init(id: String, title: String, startedAt: Date, source: String) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.duration = 0
        self.source = source
        self.tracks = []
        self.status = .recording
        self.error = nil
        self.speakers = [:]
        self.model = nil
    }
}

public struct Segment: Codable, Sendable, Equatable {
    public var start: Double
    public var end: Double
    /// Stable label: "me" for your microphone, "S1", "S2" and so on for other voices.
    public var speaker: String
    public var text: String

    public init(start: Double, end: Double, speaker: String, text: String) {
        self.start = start
        self.end = end
        self.speaker = speaker
        self.text = text
    }
}

public struct Transcript: Codable, Sendable {
    public var recordingId: String
    public var createdAt: Date
    public var model: String
    public var segments: [Segment]

    public init(recordingId: String, createdAt: Date = Date(), model: String, segments: [Segment]) {
        self.recordingId = recordingId
        self.createdAt = createdAt
        self.model = model
        self.segments = segments
    }

    /// Speaker labels in the order they first speak.
    public var labels: [String] {
        var seen: [String] = []
        for s in segments where !seen.contains(s.speaker) { seen.append(s.speaker) }
        return seen
    }
}

extension RecordingMeta {
    /// The name shown for a speaker label.
    public func displayName(for label: String, ownerName: String) -> String {
        if let name = speakers[label], !name.isEmpty { return name }
        if label == "me" { return ownerName }
        if label.hasPrefix("S"), let n = Int(label.dropFirst()) { return "Speaker \(n)" }
        return label
    }

    /// Finds the label for something a person typed: a label ("S2"), a default
    /// name ("Speaker 2") or a name already given ("Dustin").
    public func resolveLabel(_ input: String, labels: [String], ownerName: String) -> String? {
        let needle = input.trimmingCharacters(in: .whitespaces).lowercased()
        for label in labels where label.lowercased() == needle { return label }
        for label in labels where displayName(for: label, ownerName: ownerName).lowercased() == needle { return label }
        return nil
    }
}

enum JSONCoding {
    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
