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

    init(url: URL, label: String) throws {
        queue = DispatchQueue(label: "sotto.writer.\(label)")
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
            if firstHostTime == nil { firstHostTime = hostTime }
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
            try file.write(from: input)
            framesWritten += AVAudioFramePosition(input.frameLength)
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
        if output.frameLength > 0 {
            try file.write(from: output)
            framesWritten += AVAudioFramePosition(output.frameLength)
        }
    }

    /// Waits for pending writes and closes the file.
    func finish() {
        queue.sync { file = nil }
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

        let mw = try TrackWriter(url: folder.appendingPathComponent("mic.m4a"), label: "mic")
        let m = MicCapture()
        try m.start(writer: mw)
        mic = m
        micWriter = mw

        if mode == .call {
            if #available(macOS 14.2, *) {
                do {
                    let sw = try TrackWriter(url: folder.appendingPathComponent("system.m4a"), label: "system")
                    let s = SystemCapture()
                    try s.start(writer: sw)
                    system = s
                    systemWriter = sw
                } catch {
                    warnings.append("Computer audio is not being recorded: \(error.localizedDescription). Recording the microphone only.")
                    try? FileManager.default.removeItem(at: folder.appendingPathComponent("system.m4a"))
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
