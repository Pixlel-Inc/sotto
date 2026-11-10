import Foundation
import Testing
@testable import SottoCore

func w(_ text: String, _ start: Double, _ end: Double, _ speaker: String) -> Word {
    Word(text: text, start: start, end: end, speaker: speaker)
}

@Suite struct TurnTests {
    @Test func groupsBySpeakerAndPause() {
        let words = [w("Hi", 0, 0.3, "S1"), w("there.", 0.3, 0.6, "S1"), w("Hello.", 1.0, 1.4, "S2"),
                     w("Later", 5.0, 5.3, "S2")]
        let segs = Transcriber.group(words)
        #expect(segs.map(\.text) == ["Hi there.", "Hello.", "Later"])
        #expect(segs.map(\.speaker) == ["S1", "S2", "S2"])
    }

    @Test func sentenceSmoothingFixesBoundaryWords() {
        // "Sounds" leaked onto the previous speaker; the sentence belongs to S2.
        let words = [w("Friday.", 0, 0.5, "S1"), w("Sounds", 1.6, 1.9, "S1"), w("good.", 1.9, 2.3, "S2"),
                     w("Talk", 2.4, 2.6, "S2"), w("soon.", 2.6, 3.0, "S2")]
        let out = Transcriber.smoothBySentence(words)
        #expect(out.map(\.speaker) == ["S1", "S2", "S2", "S2", "S2"])
    }

    @Test func echoOfComputerAudioIsDroppedFromMic() {
        let mic = [w("Hello", 1.0, 1.2, "me"), w("pricing", 3.05, 3.4, "me"), w("yes", 6.0, 6.2, "me")]
        let others = [w("pricing.", 3.0, 3.35, "S1"), w("Ok", 8, 8.2, "S1")]
        let kept = Transcriber.removeEcho(mic: mic, others: others)
        #expect(kept.map(\.text) == ["Hello", "yes"])
    }

    @Test func renumberSkipsSilentSpeakers() {
        var emb: [String: [Float]] = ["S2": [1, 0], "S3": [0, 1]]
        let segs = [Segment(start: 0, end: 1, speaker: "me", text: "a"),
                    Segment(start: 1, end: 2, speaker: "S3", text: "b"),
                    Segment(start: 2, end: 3, speaker: "S2", text: "c")]
        let out = Transcriber.renumber(segs, embeddings: &emb)
        #expect(out.map(\.speaker) == ["me", "S1", "S2"])
        #expect(emb["S1"] == [0, 1])
    }

    @Test func silenceDetection() {
        #expect(Transcriber.isSilent([Float](repeating: 0, count: 16000)))
        #expect(!Transcriber.isSilent((0..<16000).map { sin(Float($0) / 10) * 0.2 }))
    }
}

@Suite struct NamingTests {
    @Test func resolvesLabelsAndNames() {
        var meta = RecordingMeta(id: "x", title: "t", startedAt: Date(), source: "live")
        meta.speakers = ["S2": "Dustin"]
        let labels = ["me", "S1", "S2"]
        #expect(meta.resolveLabel("Speaker 1", labels: labels, ownerName: "Jake") == "S1")
        #expect(meta.resolveLabel("dustin", labels: labels, ownerName: "Jake") == "S2")
        #expect(meta.resolveLabel("jake", labels: labels, ownerName: "Jake") == "me")
        #expect(meta.resolveLabel("S9", labels: labels, ownerName: "Jake") == nil)
        #expect(meta.displayName(for: "S1", ownerName: "Jake") == "Speaker 1")
    }

    @Test func voiceMatch() {
        let book = VoiceBook(paths: SottoPaths(home: URL(fileURLWithPath: "/tmp"), support: URL(fileURLWithPath: "/tmp")))
        let voices = [VoiceBook.Voice(name: "Dana", embedding: [1, 0, 0], samples: 1),
                      VoiceBook.Voice(name: "Lee", embedding: [0, 1, 0], samples: 1)]
        #expect(book.match([0.9, 0.1, 0], threshold: 0.7, among: voices)?.0 == "Dana")
        #expect(book.match([0.5, 0.5, 0.7], threshold: 0.7, among: voices) == nil)
    }
}

@Suite struct SearchTests {
    @Test func ftsQueryQuotesEveryWord() {
        #expect(SearchIndex.ftsQuery("phone number") == "\"phone\" \"number\"")
        #expect(SearchIndex.ftsQuery("say \"free estimates\" now") == "\"say\" \"free estimates\" \"now\"")
        #expect(SearchIndex.ftsQuery("OR AND NOT * ( )") == "\"OR\" \"AND\" \"NOT\"")
        #expect(SearchIndex.ftsQuery("   ") == "")
    }

    @Test func indexesAndSearchesALibrary() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sotto-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = SottoPaths(home: root.appendingPathComponent("home"), support: root.appendingPathComponent("support"))
        let library = try Library(paths: paths)
        let meta = try library.createRecording(title: "Kickoff", source: "live")
        try library.saveTranscript(Transcript(recordingId: meta.id, model: "test", segments: [
            Segment(start: 3, end: 6, speaker: "me", text: "Let's talk about the roofing estimate."),
            Segment(start: 7, end: 9, speaker: "S1", text: "Pricing should be in bold."),
        ]))
        _ = try library.updateMeta(meta.id) { $0.status = .done }
        let index = try SearchIndex(library: library)
        let hits = try index.search("roofing")
        #expect(hits.count == 1)
        #expect(hits.first?.speaker == "Me")
        try library.renameSpeaker(id: meta.id, speaker: "Speaker 1", to: "Dana")
        try index.reindex(meta.id)
        #expect(try index.search("bold").first?.speaker == "Dana")
        let md = try library.markdown(meta.id)
        #expect(md.contains("**[00:00:07] Dana:** Pricing should be in bold."))
        #expect(try library.resolveId(String(meta.id.prefix(10))) == meta.id)
    }
}

@Suite struct HTTPTests {
    @Test func parsesRequests() {
        let raw = "POST /v1/recordings/abc/title?x=1 HTTP/1.1\r\nHost: 127.0.0.1:47820\r\nContent-Length: 14\r\n\r\n{\"title\":\"Hi\"}"
        let req = HTTPServer.parse(Data(raw.utf8))
        #expect(req?.method == "POST")
        #expect(req?.path == "/v1/recordings/abc/title")
        #expect(req?.query["x"] == "1")
        #expect(req?.headers["host"] == "127.0.0.1:47820")
        #expect(req.flatMap { String(data: $0.body, encoding: .utf8) } == "{\"title\":\"Hi\"}")
    }

    @Test func waitsForTheWholeBody() {
        let raw = "POST /v1/x HTTP/1.1\r\nContent-Length: 10\r\n\r\n{\"a\":"
        #expect(HTTPServer.parse(Data(raw.utf8)) == nil)
    }

    @Test func quietComputerMeansInPerson() {
        #expect(Transcriber.isInPerson(hasMic: true, computerWords: 0))
        #expect(Transcriber.isInPerson(hasMic: true, computerWords: 2))
        #expect(!Transcriber.isInPerson(hasMic: true, computerWords: 40))
        #expect(!Transcriber.isInPerson(hasMic: false, computerWords: 0))
    }

    @Test func tokenComparison() {
        #expect(HTTPServer.constantTimeEqual("Bearer abc", "Bearer abc"))
        #expect(!HTTPServer.constantTimeEqual("Bearer abd", "Bearer abc"))
        #expect(!HTTPServer.constantTimeEqual("", "Bearer abc"))
    }
}
