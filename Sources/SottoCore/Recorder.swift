import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// Writes mono audio to a 16 kHz AAC file, resampling from whatever rate the
/// source delivers. Speech models run at 16 kHz, and AAC keeps an hour of one
/// track around 15 MB.
final class TrackWriter: @unchecked Sendable {
    static let rate: Double = 16000
    private var file: AVAudioFile?
    private let queue: DispatchQueue
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: TrackWriter.rate, channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    private var inFormat: AVAudioFormat?
    private(set) var framesWritten: AVAudioFramePosition = 0
    private(set) var firstHostTime: UInt64?
    private(set) var lastError: Error?
    /// Recent loudness, 0...1, for the level meter.
    private(set) var level: Float = 0
    /// A plain copy of the audio, flushed to disk every few seconds. An AAC file cannot be
    /// read until it is closed, so this is what survives a crash or a power cut.
    let liveURL: URL
    private var live: FileHandle?
    private let startHost: UInt64
    private var framesSinceFlush = 0

    init(url: URL, label: String, startHost: UInt64) throws {
        queue = DispatchQueue(label: "sotto.writer.\(label)")
        self.startHost = startHost
        liveURL = url.deletingPathExtension().appendingPathExtension(TrackWriter.liveExtension)
        FileManager.default.createFile(atPath: liveURL.path, contents: nil)
        live = try FileHandle(forWritingTo: liveURL)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: TrackWriter.rate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32000,
        ]
        file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    /// Called from the audio thread with a copy of the samples; the work happens on our queue.
    func append(_ mono: [Float], sampleRate: Double, hostTime: UInt64) {
        guard !mono.isEmpty else { return }
        queue.async { [self] in
            if firstHostTime == nil {
                firstHostTime = hostTime
                writeLiveHeader(hostTime: hostTime)
            }
            var peak: Float = 0
            for s in mono { peak = max(peak, abs(s)) }
            level = max(peak, level * 0.8)
            do { try write(mono, sampleRate: sampleRate) } catch { lastError = error }
        }
    }

    private func write(_ mono: [Float], sampleRate: Double) throws {
        guard let file else { return }
        if inFormat?.sampleRate != sampleRate {
            inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)
            converter = sampleRate == TrackWriter.rate ? nil : AVAudioConverter(from: inFormat!, to: outFormat)
        }
        let input = AVAudioPCMBuffer(pcmFormat: inFormat!, frameCapacity: AVAudioFrameCount(mono.count))!
        input.frameLength = AVAudioFrameCount(mono.count)
        mono.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: mono.count) }
        guard let converter else {
            try store(input, in: file)
            return
        }
        let capacity = AVAudioFrameCount(Double(mono.count) * TrackWriter.rate / sampleRate) + 256
        let output = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity)!
        var fed = false
        var err: NSError?
        let status = converter.convert(to: output, error: &err) { _, outStatus in
            if fed { outStatus.pointee = .noDataNow; return nil }
            fed = true
            outStatus.pointee = .haveData
            return input
        }
        if status == .error { throw err ?? SottoError.audio("resampling failed") }
        if output.frameLength > 0 { try store(output, in: file) }
    }

    private func store(_ buffer: AVAudioPCMBuffer, in file: AVAudioFile) throws {
        try file.write(from: buffer)
        framesWritten += AVAudioFramePosition(buffer.frameLength)
        appendLive(buffer)
    }

    // MARK: The crash-safe copy: 8 bytes of track offset, then 16-bit samples at 16 kHz.

    static let liveExtension = "pcm"
    private static let liveHeaderSize: UInt64 = 8

    private func writeLiveHeader(hostTime: UInt64) {
        var offset = max(0, AVAudioTime.seconds(forHostTime: hostTime) - AVAudioTime.seconds(forHostTime: startHost))
        try? live?.write(contentsOf: Data(bytes: &offset, count: 8))
    }

    private func appendLive(_ buffer: AVAudioPCMBuffer) {
        guard let live, let channel = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        var ints = [Int16](repeating: 0, count: count)
        for i in 0..<count { ints[i] = Int16(max(-1, min(1, channel[i])) * 32767) }
        ints.withUnsafeBytes { try? live.write(contentsOf: Data($0)) }
        framesSinceFlush += count
        if Double(framesSinceFlush) >= TrackWriter.rate * 5 {
            framesSinceFlush = 0
            _ = fcntl(live.fileDescriptor, F_FULLFSYNC)
        }
    }

    /// The last `seconds` of a live file, for checking whether anyone is talking.
    static func readTail(of url: URL, seconds: Double) -> [Float] {
        guard let handle = try? FileHandle(forReadingFrom: url), let size = try? handle.seekToEnd(),
              size > liveHeaderSize else { return [] }
        defer { try? handle.close() }
        let wanted = UInt64(seconds * rate) * 2
        let body = size - liveHeaderSize
        let skip = body > wanted ? (body - wanted) & ~1 : 0
        guard (try? handle.seek(toOffset: liveHeaderSize + skip)) != nil,
              let data = try? handle.readToEnd() else { return [] }
        return data.withUnsafeBytes { raw in
            raw.bindMemory(to: Int16.self).map { Float($0) / 32767 }
        }
    }

    /// Turns a live file left behind by a crash into a normal AAC track.
    static func encodeLive(_ source: URL, to destination: URL) throws -> (offset: Double, seconds: Double) {
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        guard let head = try handle.read(upToCount: 8), head.count == 8 else { return (0, 0) }
        let offset = head.withUnsafeBytes { $0.loadUnaligned(as: Double.self) }
        try? FileManager.default.removeItem(at: destination)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        var frames = 0
        var out: AVAudioFile? = try AVAudioFile(forWriting: destination, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32000,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        while let chunk = try handle.read(upToCount: 320_000), chunk.count >= 2 {
            let count = chunk.count / 2
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
            buffer.frameLength = AVAudioFrameCount(count)
            chunk.withUnsafeBytes { raw in
                let ints = raw.bindMemory(to: Int16.self)
                for i in 0..<count { buffer.floatChannelData![0][i] = Float(ints[i]) / 32767 }
            }
            try out?.write(from: buffer)
            frames += count
        }
        out = nil
        return (offset, Double(frames) / rate)
    }

    /// Waits for pending writes, closes the file and discards the crash-safe copy.
    func finish() {
        queue.sync {
            file = nil
            try? live?.close()
            live = nil
            try? FileManager.default.removeItem(at: liveURL)
        }
    }

    func currentLevel() -> Float { queue.sync { level } }
}

/// Mixes any buffer list down to one channel of Float32.
func downmix(_ abl: UnsafePointer<AudioBufferList>, frames: Int, channels: Int, interleaved: Bool) -> [Float] {
    let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: abl))
    guard frames > 0, channels > 0, list.count > 0 else { return [] }
    var out = [Float](repeating: 0, count: frames)
    if interleaved {
        guard let data = list[0].mData?.assumingMemoryBound(to: Float.self) else { return [] }
        let available = Int(list[0].mDataByteSize) / MemoryLayout<Float>.size / channels
        let n = min(frames, available)
        for f in 0..<n {
            var sum: Float = 0
            for c in 0..<channels { sum += data[f * channels + c] }
            out[f] = sum / Float(channels)
        }
        if n < frames { out.removeLast(frames - n) }
    } else {
        var used = 0
        for buffer in list {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let n = min(frames, Int(buffer.mDataByteSize) / MemoryLayout<Float>.size)
            for f in 0..<n { out[f] += data[f] }
            used += 1
        }
        if used > 1 { for f in out.indices { out[f] /= Float(used) } }
    }
    return out
}

/// The microphone, through AVAudioEngine.
final class MicCapture {
    private let engine = AVAudioEngine()

    func start(writer: TrackWriter) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw SottoError.audio("no microphone found, or microphone access is off (System Settings > Privacy & Security > Microphone)")
        }
        let rate = format.sampleRate
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, time in
            let mono = downmix(buffer.audioBufferList, frames: Int(buffer.frameLength),
                               channels: Int(format.channelCount), interleaved: format.isInterleaved)
            writer.append(mono, sampleRate: rate, hostTime: time.isHostTimeValid ? time.hostTime : mach_absolute_time())
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}

/// Everything the Mac plays (Zoom, Meet, Teams, a browser tab), through a Core
/// Audio process tap. Needs macOS 14.2 and the "System Audio Recording" permission.
@available(macOS 14.2, *)
final class SystemCapture {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

    private static func check(_ status: OSStatus, _ what: String) throws {
        if status != noErr { throw SottoError.audio("\(what) failed (OSStatus \(status))") }
    }

    private static func defaultOutputUID() throws -> String {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device), "finding the output device")
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        addr.mSelector = kAudioDevicePropertyDeviceUID
        try check(AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &uid), "reading the output device id")
        guard let value = uid?.takeRetainedValue() else { throw SottoError.audio("output device has no id") }
        return value as String
    }

    func start(writer: TrackWriter) throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.name = "Sotto"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try SystemCapture.check(AudioHardwareCreateProcessTap(description, &tapID),
                                "creating the system audio tap (is System Audio Recording allowed for Sotto?)")

        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        try SystemCapture.check(AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd), "reading the tap format")

        let outputUID = try SystemCapture.defaultOutputUID()
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Sotto Capture",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        try SystemCapture.check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "creating the capture device")

        let rate = asbd.mSampleRate
        let channels = Int(asbd.mChannelsPerFrame)
        let interleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
        let bytesPerFrame = Int(asbd.mBytesPerFrame)
        try SystemCapture.check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { _, inInput, inTime, _, _ in
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInput))
            guard list.count > 0 else { return }
            let frames: Int
            if interleaved { frames = bytesPerFrame > 0 ? Int(list[0].mDataByteSize) / bytesPerFrame : 0 }
            else { frames = Int(list[0].mDataByteSize) / MemoryLayout<Float>.size }
            let mono = downmix(inInput, frames: frames, channels: channels, interleaved: interleaved)
            writer.append(mono, sampleRate: rate, hostTime: inTime.pointee.mHostTime)
        }, "attaching to the capture device")
        try SystemCapture.check(AudioDeviceStart(aggregateID, procID), "starting system audio capture")
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            if let procID { AudioDeviceDestroyIOProcID(aggregateID, procID) }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        procID = nil
    }
}

/// Records a call (your mic plus computer audio, as two tracks) or a room (mic only).
public final class Recorder: @unchecked Sendable {
    public enum Mode: String, Sendable {
        /// Mic plus computer audio, the default. Transcription works out whether it was a
        /// call (mic is "me", computer is "others") or in person (no speech from the computer).
        case call
        /// Mic only, everyone split by voice. For in-person meetings.
        case room
    }

    public private(set) var isRecording = false
    public private(set) var mode: Mode = .call
    public private(set) var startedAt: Date?
    private var startHost: UInt64 = 0
    private var mic: MicCapture?
    private var system: AnyObject?
    private var micWriter: TrackWriter?
    private var systemWriter: TrackWriter?

    public init() {}

    /// Starts recording into `folder`. Returns warnings (system audio unavailable, say)
    /// for things that failed without stopping the recording.
    public func start(mode: Mode, folder: URL) throws -> [String] {
        guard !isRecording else { throw SottoError.invalid("already recording") }
        var warnings: [String] = []
        startHost = mach_absolute_time()
        startedAt = Date()
        self.mode = mode

        let mw = try TrackWriter(url: folder.appendingPathComponent("mic.m4a"), label: "mic", startHost: startHost)
        let m = MicCapture()
        try m.start(writer: mw)
        mic = m
        micWriter = mw

        if mode == .call {
            if #available(macOS 14.2, *) {
                do {
                    let sw = try TrackWriter(url: folder.appendingPathComponent("system.m4a"), label: "system", startHost: startHost)
                    let s = SystemCapture()
                    try s.start(writer: sw)
                    system = s
                    systemWriter = sw
                } catch {
                    warnings.append("Computer audio is not being recorded: \(error.localizedDescription). Recording the microphone only.")
                    try? FileManager.default.removeItem(at: folder.appendingPathComponent("system.m4a"))
                    try? FileManager.default.removeItem(at: folder.appendingPathComponent("system.\(TrackWriter.liveExtension)"))
                }
            } else {
                warnings.append("Computer audio needs macOS 14.2 or later. Recording the microphone only.")
            }
        }
        isRecording = true
        return warnings
    }

    /// Input levels (0...1) for a meter: (mic, computer).
    public func levels() -> (Float, Float?) {
        (micWriter?.currentLevel() ?? 0, systemWriter?.currentLevel())
    }

    /// The last `seconds` of each track being recorded.
    public func recentAudio(seconds: Double) -> [[Float]] {
        [micWriter, systemWriter].compactMap { $0 }.map { TrackWriter.readTail(of: $0.liveURL, seconds: seconds) }
    }

    /// Rebuilds the tracks of a recording that never reached Stop. Returns nil if its files
    /// changed within `minimumAge` seconds, which means something may still be recording.
    public static func recover(folder: URL, minimumAge: TimeInterval = 10) throws -> (tracks: [Track], duration: Double)? {
        let fm = FileManager.default
        let mic = folder.appendingPathComponent("mic.\(TrackWriter.liveExtension)")
        let system = folder.appendingPathComponent("system.\(TrackWriter.liveExtension)")
        let hasSystem = fm.fileExists(atPath: system.path)
        for url in [mic, system] where fm.fileExists(atPath: url.path) {
            let changed = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date ?? .distantPast
            if Date().timeIntervalSince(changed) < minimumAge { return nil }
        }
        var tracks: [Track] = []
        var duration = 0.0
        for (url, file, role) in [(mic, "mic.m4a", hasSystem ? TrackRole.me : .room), (system, "system.m4a", TrackRole.others)]
        where fm.fileExists(atPath: url.path) {
            let destination = folder.appendingPathComponent(file)
            let (offset, seconds) = try TrackWriter.encodeLive(url, to: destination)
            if seconds > 0 {
                tracks.append(Track(file: file, role: role, offset: offset))
                duration = max(duration, offset + seconds)
            } else {
                try? fm.removeItem(at: destination)
            }
            try? fm.removeItem(at: url)
        }
        return (tracks, duration)
    }

    /// Stops and returns the tracks written, with their offsets, plus the duration.
    public func stop() -> (tracks: [Track], duration: Double, errors: [String]) {
        guard isRecording else { return ([], 0, []) }
        mic?.stop()
        if #available(macOS 14.2, *) { (system as? SystemCapture)?.stop() }
        var tracks: [Track] = []
        var duration: Double = 0
        var errors: [String] = []
        let hasSystem = systemWriter != nil
        for (writer, file, role) in [(micWriter, "mic.m4a", hasSystem ? TrackRole.me : .room),
                                     (systemWriter, "system.m4a", TrackRole.others)] {
            guard let writer else { continue }
            writer.finish()
            if let e = writer.lastError { errors.append("\(file): \(e.localizedDescription)") }
            let offset = writer.firstHostTime.map { max(0, AVAudioTime.seconds(forHostTime: $0) - AVAudioTime.seconds(forHostTime: startHost)) } ?? 0
            let length = Double(writer.framesWritten) / TrackWriter.rate
            if writer.framesWritten > 0 {
                tracks.append(Track(file: file, role: role, offset: offset))
                duration = max(duration, offset + length)
            }
        }
        mic = nil; system = nil; micWriter = nil; systemWriter = nil
        isRecording = false
        return (tracks, duration, errors)
    }
}

/// Decides when a recording has gone quiet for long enough to stop by itself.
public struct QuietTimer: Sendable {
    public let limit: TimeInterval
    public private(set) var lastHeard: Date

    public init(limit: TimeInterval, start: Date = Date()) {
        self.limit = limit
        lastHeard = start
    }

    /// Reports the latest check. Returns true when it is time to stop.
    public mutating func update(heardWords: Bool, at now: Date = Date()) -> Bool {
        if heardWords { lastHeard = now }
        return now.timeIntervalSince(lastHeard) >= limit
    }
}
