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

    @Test func unclaimedSentencesGoToTheVoiceTheyMatch() {
        func w(_ text: String, _ start: Double, _ end: Double, _ speaker: String) -> Word {
            Word(text: text, start: start, end: end, speaker: speaker)
        }
        let voices: [String: [Float]] = ["S1": [1, 0], "S2": [0, 1]]
        let words = [w("Hey,", 0, 0.5, "S2"), w("there.", 0.5, 1.0, "S2"),
                     w("Answer.", 2, 4, "S2"),
                     w("Nice.", 4.2, 5.2, "S2"), w("It", 5.4, 5.6, "S2"), w("re", 5.6, 5.8, "S2")]
        let sentences = Transcriber.sentenceRanges(words)
        #expect(sentences == [0..<2, 2..<3, 3..<4, 4..<6])
        let out = Transcriber.settleUnclaimed(words, sentences: sentences, unclaimed: [0..<2, 3..<4, 4..<6],
                                              measured: [0..<2: [0.9, 0.1], 3..<4: [0.8, 0.0]], voices: voices)
        #expect(out.map(\.speaker) == ["S1", "S1", "S2", "S1", "S1", "S1"])
    }

    @Test func unclearVoicesAreLeftAlone() {
        #expect(Transcriber.closestVoice([1, 1], voices: ["S1": [1, 0], "S2": [0, 1]]) == nil)
        #expect(Transcriber.closestVoice([-1, -1], voices: ["S1": [1, 0], "S2": [0.5, 1]]) == nil)
        #expect(Transcriber.closestVoice([1, 0], voices: ["S1": [1, 0], "S2": [0, 1]]) == "S1")
    }

    @Test func coverageCountsOverlapOnce() {
        #expect(Transcriber.coverage(start: 0, end: 2, turns: []) == 0)
        #expect(Transcriber.coverage(start: 0, end: 2, turns: [(1, 3), (1, 3)]) == 0.5)
    }

    @Test func aRecordingThatNeverStoppedIsRecovered() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let tone = (0..<32000).map { Float(sin(Double($0) * 0.1) * 0.3) }
        for name in ["mic", "system"] {
            let writer = try TrackWriter(url: folder.appendingPathComponent("\(name).m4a"), label: name, startHost: 0)
            writer.append(tone, sampleRate: 16000, hostTime: mach_absolute_time())
            _ = writer.currentLevel() // waits for the write; finish() is deliberately never called
            #expect(TrackWriter.readTail(of: writer.liveURL, seconds: 1).count == 16000)
        }
        #expect(try Recorder.recover(folder: folder) == nil) // files just changed: maybe still recording
        let found = try #require(try Recorder.recover(folder: folder, minimumAge: 0))
        #expect(found.tracks.map(\.role) == [.me, .others])
        #expect(found.tracks.map(\.file) == ["mic.m4a", "system.m4a"])
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(!names.contains { $0.hasSuffix(".pcm") })
        let seconds = Pipeline.duration(of: folder.appendingPathComponent("mic.m4a"))
        #expect(abs(seconds - 2) < 0.2)
    }

    @Test func stopsOnlyAfterTheWholeQuietPeriod() {
        let start = Date(timeIntervalSince1970: 0)
        var timer = QuietTimer(limit: 600, start: start)
        let early = timer.update(heardWords: false, at: start.addingTimeInterval(540))
        let spoke = timer.update(heardWords: true, at: start.addingTimeInterval(590))
        let stillCounting = timer.update(heardWords: false, at: start.addingTimeInterval(1100))
        let done = timer.update(heardWords: false, at: start.addingTimeInterval(1190))
        #expect(!early && !spoke && !stillCounting && done)
    }

    @Test func meetingAppsCountButBackgroundListenersDoNot() {
        for app in ["us.zoom.xos", "com.microsoft.teams2", "com.google.Chrome.helper", "com.apple.WebKit.GPU",
                    "com.apple.avconferenced", "com.acme.whitelabel-meetings"] {
            #expect(MicUse.couldBeMeeting(app), "\(app)")
        }
        for app in ["com.apple.CoreSpeech", "com.apple.assistantd", "com.pixlel.sotto", "com.anthropic.claudefordesktop.helper", ""] {
            #expect(!MicUse.couldBeMeeting(app), "\(app)")
        }
        #expect(!MicUse.couldBeMeeting("com.spotify.client", alsoIgnore: ["com.spotify"]))
    }

    @Test func offersOncePerMeeting() {
        let t0 = Date(timeIntervalSince1970: 0)
        func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }
        var w = MeetingWatch()
        var seen: [MeetingWatch.Event?] = []
        seen.append(w.update(inUse: true, at: at(0)))     // mic opens
        seen.append(w.update(inUse: false, at: at(2)))    // a quick voice note: no offer
        seen.append(w.update(inUse: true, at: at(10)))
        seen.append(w.update(inUse: true, at: at(13)))    // still under 5 s since it reopened
        seen.append(w.update(inUse: true, at: at(16)))    // 6 s held: offer
        seen.append(w.update(inUse: true, at: at(19)))    // no repeat
        seen.append(w.update(inUse: false, at: at(25)))   // muted briefly: offer stays up
        seen.append(w.update(inUse: true, at: at(40)))    // same meeting: no new offer
        seen.append(w.update(inUse: true, at: at(49)))    // and none after holding again
        seen.append(w.update(inUse: false, at: at(70)))   // meeting over: offer comes down
        seen.append(w.update(inUse: false, at: at(200)))  // mic has rested
        seen.append(w.update(inUse: true, at: at(300)))   // next meeting
        seen.append(w.update(inUse: true, at: at(306)))
        #expect(seen == [nil, nil, nil, nil, .offer, nil, nil, nil, nil, .micFreed, nil, nil, .offer])
    }

    @Test func tokenComparison() {
        #expect(HTTPServer.constantTimeEqual("Bearer abc", "Bearer abc"))
        #expect(!HTTPServer.constantTimeEqual("Bearer abd", "Bearer abc"))
        #expect(!HTTPServer.constantTimeEqual("", "Bearer abc"))
    }

    @Test func computerTrackOnTheWrongClockIsCorrected() {
        // 44.1 kHz audio saved as 48 kHz: the Nov 12 recording, 4621 s of mic, 4246 s of computer.
        let fix = Transcriber.clockStretch(micSeconds: 4621.4, otherSeconds: 4246.0)
        #expect(fix.map { abs($0 - 48000.0 / 44100.0) < 1e-9 } == true)
        #expect(Transcriber.clockStretch(micSeconds: 4621.4, otherSeconds: 4620.0) == nil)  // already right
        #expect(Transcriber.clockStretch(micSeconds: 4621.4, otherSeconds: 3000.0) == nil)  // computer stopped early
        #expect(Transcriber.clockStretch(micSeconds: 7.2, otherSeconds: 5.5) == nil)        // too short to judge
        let longer = Transcriber.stretched([0, 1, 2, 3], by: 2)
        #expect(longer.count == 8)
        #expect(longer[1] == 0.5)
    }

    @Test func rateClockFollowsTheRealRate() {
        #expect(RateClock.snap(44_093) == 44100)
        #expect(RateClock.snap(47_990) == 48000)
        #expect(RateClock.snap(40_000) == nil)
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let ticks = { (s: Double) in UInt64(s * 1e9 * Double(info.denom) / Double(info.numer)) }
        let clock = RateClock(assumed: 48000)
        var t = 0.0
        var used: Double = 0
        while t < 10 {
            used = clock.observe(frames: 441, hostTime: ticks(100 + t))  // 441 frames every 10 ms is 44.1 kHz
            t += 0.01
        }
        #expect(used == 44100)
    }

    @Test func oneVoiceSplitInTwoIsJoined() {
        let words = [Word(text: "hello", start: 0, end: 1, speaker: "S1"),
                     Word(text: "there", start: 1, end: 2, speaker: "S1"),
                     Word(text: "yeah", start: 3, end: 4, speaker: "S2"),
                     Word(text: "no", start: 5, end: 6, speaker: "S3")]
        var e: [String: [Float]] = ["S1": [1, 0.1, 0], "S2": [1, 0.3, 0], "S3": [0, 0, 1]]
        let out = Transcriber.mergeSameVoices(words, embeddings: &e, threshold: 0.72)
        #expect(out.map(\.speaker) == ["S1", "S1", "S1", "S3"])
        #expect(Set(e.keys) == ["S1", "S3"])
    }

    @Test func talkingOverEachOtherKeepsWholeLines() {
        // Both talking at once, words 0.5 s apart with no real pause: two whole lines.
        let me = ["was", "your", "brother", "there"].enumerated().map {
            Word(text: $0.element, start: Double($0.offset) * 0.5, end: Double($0.offset) * 0.5 + 0.45, speaker: "me") }
        let them = ["yeah", "that", "was", "Mark"].enumerated().map {
            Word(text: $0.element, start: Double($0.offset) * 0.5 + 0.2, end: Double($0.offset) * 0.5 + 0.65, speaker: "S1") }
        #expect(Transcriber.interleave([me, them]).map(\.text) == ["was your brother there", "yeah that was Mark"])
        // They pause for a second while I answer: their line splits around mine.
        let them2 = [Word(text: "is", start: 0, end: 0.4, speaker: "S1"), Word(text: "it?", start: 0.5, end: 0.9, speaker: "S1"),
                     Word(text: "great", start: 2.5, end: 3, speaker: "S1")]
        let me2 = [Word(text: "yes", start: 1.2, end: 1.6, speaker: "me")]
        #expect(Transcriber.interleave([me2, them2]).map(\.text) == ["is it?", "yes", "great"])
    }
}
