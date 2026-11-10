import CoreAudio
import Foundation

/// Finds out which apps have the microphone open. A meeting always needs the mic, so this
/// catches Zoom, Teams, Meet, and any white-labeled meeting site or app, with no permission
/// prompts and without looking at network traffic or at what is being said.
public enum MicUse {
    public struct App: Sendable, Equatable {
        public let bundleID: String
        public let pid: Int32
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    /// Every app with an open microphone stream right now.
    public static func apps() -> [App] {
        guard #available(macOS 14.2, *) else { return [] }
        var list = address(kAudioHardwarePropertyProcessObjectList)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &list, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &list, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id -> App? in
            var running = address(kAudioProcessPropertyIsRunningInput)
            var isRunning: UInt32 = 0
            var length = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(id, &running, 0, nil, &length, &isRunning) == noErr, isRunning == 1 else { return nil }
            var bundle = address(kAudioProcessPropertyBundleID)
            var name: Unmanaged<CFString>?
            length = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(id, &bundle, 0, nil, &length, &name) == noErr,
                  let bundleID = name?.takeRetainedValue() as String? else { return nil }
            var pidAddress = address(kAudioProcessPropertyPID)
            var pid: pid_t = 0
            length = UInt32(MemoryLayout<pid_t>.size)
            AudioObjectGetPropertyData(id, &pidAddress, 0, nil, &length, &pid)
            return App(bundleID: bundleID, pid: pid)
        }
    }

    /// Mic users that are never a meeting: Sotto itself, voice chat with an AI app, dictation tools.
    static let ignored = ["com.pixlel.sotto", "com.anthropic.claudefordesktop", "com.superduper.superwhisper",
                          "com.electron.wispr-flow", "com.goodsnooze.MacWhisper"]
    /// Apple's own background listeners hold the mic all the time ("Hey Siri"), so everything
    /// from Apple is skipped except Safari's audio process and FaceTime.
    static let appleMeetings = ["com.apple.WebKit.", "com.apple.avconferenced", "com.apple.FaceTime"]

    /// Whether this app having the mic suggests a meeting. Anything not ruled out counts,
    /// so meeting apps Sotto has never heard of still get the offer.
    public static func couldBeMeeting(_ bundleID: String, alsoIgnore: [String] = []) -> Bool {
        guard !bundleID.isEmpty else { return false }
        if (ignored + alsoIgnore).contains(where: { bundleID.hasPrefix($0) }) { return false }
        if bundleID.hasPrefix("com.apple.") { return appleMeetings.contains { bundleID.hasPrefix($0) } }
        return true
    }
}

/// Decides when to offer to record, from a stream of "is a meeting app using the mic".
public struct MeetingWatch: Sendable {
    public enum Event: Sendable, Equatable {
        case offer
        case micFreed
    }

    /// How long the mic must stay open before offering, so a quick voice message does not.
    public let hold: TimeInterval
    /// How long the mic must stay free before the next use counts as a new meeting.
    /// Some meeting apps release the mic on mute, and that should not offer again.
    public let rest: TimeInterval
    /// How long the mic must stay free before an offer on screen is taken away.
    public let grace: TimeInterval
    private var since: Date?
    private var lastInUse: Date?
    private var offered = false

    public init(hold: TimeInterval = 5, rest: TimeInterval = 120, grace: TimeInterval = 15) {
        self.hold = hold
        self.rest = rest
        self.grace = grace
    }

    public mutating func update(inUse: Bool, at now: Date = Date()) -> Event? {
        if inUse {
            if let last = lastInUse, now.timeIntervalSince(last) >= rest { offered = false; since = nil }
            if since == nil { since = now }
            lastInUse = now
            if !offered, now.timeIntervalSince(since!) >= hold {
                offered = true
                return .offer
            }
            return nil
        }
        guard let last = lastInUse else { return nil }
        if !offered { since = nil; lastInUse = nil; return nil }
        let free = now.timeIntervalSince(last)
        if free >= rest { since = nil; lastInUse = nil; offered = false; return nil }
        since = nil
        return free >= grace ? .micFreed : nil
    }
}
