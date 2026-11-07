import Foundation

public enum Render {
    public static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    public static func duration(_ seconds: Double) -> String {
        let m = Int((seconds / 60).rounded())
        if seconds < 60 { return "\(Int(seconds.rounded())) sec" }
        if m < 60 { return "\(m) min" }
        return "\(m / 60) hr \(m % 60) min"
    }

    static let longDate: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeStyle = .short
        return f
    }()

    public static func header(meta: RecordingMeta, transcript: Transcript?, ownerName: String) -> String {
        var lines = ["# \(meta.title)", ""]
        lines.append("- Date: \(longDate.string(from: meta.startedAt))")
        lines.append("- Duration: \(duration(meta.duration))")
        if let t = transcript {
            let names = t.labels.map { meta.displayName(for: $0, ownerName: ownerName) }
            if !names.isEmpty { lines.append("- Speakers: \(names.joined(separator: ", "))") }
        }
        lines.append("- Recording id: \(meta.id)")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    public static func markdown(meta: RecordingMeta, transcript: Transcript, ownerName: String) -> String {
        var out = header(meta: meta, transcript: transcript, ownerName: ownerName)
        if transcript.segments.isEmpty {
            out += "\n_No speech found._\n"
            return out
        }
        for seg in transcript.segments {
            let name = meta.displayName(for: seg.speaker, ownerName: ownerName)
            out += "\n**[\(clock(seg.start))] \(name):** \(seg.text)\n"
        }
        return out
    }

    /// Plain JSON for the API and MCP: meta plus segments with display names.
    public static func json(meta: RecordingMeta, transcript: Transcript?, ownerName: String) -> [String: Any] {
        var dict: [String: Any] = summary(meta: meta, ownerName: ownerName, transcript: transcript)
        var segs: [[String: Any]] = []
        for seg in transcript?.segments ?? [] {
            var row: [String: Any] = [:]
            row["start"] = (seg.start * 100).rounded() / 100
            row["end"] = (seg.end * 100).rounded() / 100
            row["speaker"] = meta.displayName(for: seg.speaker, ownerName: ownerName)
            row["speaker_label"] = seg.speaker
            row["text"] = seg.text
            segs.append(row)
        }
        dict["segments"] = segs
        return dict
    }

    public static func summary(meta: RecordingMeta, ownerName: String, transcript: Transcript?) -> [String: Any] {
        var dict: [String: Any] = [
            "id": meta.id,
            "title": meta.title,
            "started_at": ISO8601DateFormatter().string(from: meta.startedAt),
            "duration_seconds": Int(meta.duration.rounded()),
            "status": meta.status.rawValue,
            "source": meta.source,
        ]
        if let e = meta.error { dict["error"] = e }
        if let t = transcript {
            dict["speakers"] = t.labels.map { meta.displayName(for: $0, ownerName: ownerName) }
            let words = t.segments.reduce(0) { $0 + $1.text.split(separator: " ").count }
            dict["word_count"] = words
        }
        return dict
    }
}
