import UniformTypeIdentifiers
import AVFoundation
import AppKit
import ServiceManagement
import SottoCore
import SwiftUI

/// Thread-safe copy of the recording state, for the HTTP API's background threads.
final class RecordingMirror: @unchecked Sendable {
    private let lock = NSLock()
    private var _id: String?
    var id: String? {
        get { lock.lock(); defer { lock.unlock() }; return _id }
        set { lock.lock(); _id = newValue; lock.unlock() }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var isRecording = false
    @Published var elapsed: TimeInterval = 0
    @Published var status = "Ready"
    @Published var recent: [RecordingMeta] = []
    @Published var micLevel: Float = 0
    @Published var systemLevel: Float?
    @Published var pulse: Float = 0
    @Published var warning: String?
    @Published var busy = false
    @Published var ownerName: String
    @Published var consentReminder: Bool
    @Published var openAtLogin: Bool = SMAppService.mainApp.status == .enabled
    @Published var offerToRecordMeetings: Bool = true
    @Published var uploadMessage: String?

    let library: Library
    let index: SearchIndex
    let pipeline: Pipeline
    let api: SottoAPI
    private var server: HTTPServer?
    private let recorder = Recorder()
    private let mirror = RecordingMirror()
    private var currentId: String?
    private var startedAt: Date?
    private var ticker: Timer?
    private var inboxTimer: Timer?
    private var quietWatch: Timer?
    private var quiet = QuietTimer(limit: 600)
    private var checkingForWords = false
    private var sleepObserver: NSObjectProtocol?
    private var meetingTimer: Timer?
    private var meetingWatch = MeetingWatch()
    private let meetingPrompt = MeetingPrompt()
    private let uploadWindow = UploadWindow()

    init() {
        do {
            library = try Library()
            index = try SearchIndex(library: library)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Sotto could not start"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            exit(1)
        }
        pipeline = Pipeline(library: library, index: index)
        api = SottoAPI(library: library, index: index)
        ownerName = library.config.ownerName
        consentReminder = library.config.consentReminder
        offerToRecordMeetings = library.config.meetingPrompt
        index.sync()
        refresh()
        startServices()
    }

    private func startServices() {
        let mirror = self.mirror
        api.recordControl = RecordControl(
            isRecording: { mirror.id != nil },
            currentId: { mirror.id },
            start: { [weak self] mode, title in
                guard let self else { throw SottoError.invalid("app is closing") }
                return try await self.startRecording(mode: mode, title: title, askConsent: false)
            },
            stop: { [weak self] in
                guard let self, let id = await self.stopRecording() else { throw SottoError.invalid("not recording") }
                return id
            })
        let server = HTTPServer(api: api, port: library.config.port, token: library.config.apiToken)
        do {
            try server.start()
            self.server = server
        } catch {
            warning = "Local API is off: port \(library.config.port) is busy."
        }
        Task {
            await pipeline.setHandlers(
                onChange: { [weak self] _, _ in Task { @MainActor in self?.refresh() } },
                log: { [weak self] line in Task { @MainActor in self?.status = line } })
            await pipeline.recoverInterrupted()
            await pipeline.resumeUnfinished()
            // A recording that died moments before launch looks active at first. Look again.
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            await pipeline.recoverInterrupted(excluding: mirror.id)
        }
        // Closing the lid ends the recording cleanly instead of leaving a gap in it.
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in _ = await self?.stopRecording() }
        }
        meetingTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkForMeeting() }
        }
        inboxTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { _ = await self.pipeline.scanInbox() }
        }
    }

    /// Runs every few seconds and offers to record once a meeting app holds the mic.
    private func checkForMeeting() {
        guard offerToRecordMeetings else { return }
        let ignore = library.config.meetingPromptIgnore
        let app = MicUse.apps().first { MicUse.couldBeMeeting($0.bundleID, alsoIgnore: ignore) }
        switch meetingWatch.update(inUse: app != nil) {
        case .offer:
            guard !isRecording else { return }
            meetingPrompt.show(appName: app.flatMap(Self.displayName), showReminder: consentReminder) { [weak self] in
                self?.recordFromPrompt()
            }
        case .micFreed:
            meetingPrompt.hide()
        case nil:
            break
        }
    }

    private static func displayName(_ app: MicUse.App) -> String? {
        if app.bundleID.hasPrefix("com.apple.WebKit.") { return "Safari" }
        if app.bundleID.hasPrefix("com.apple.avconferenced") { return "FaceTime" }
        guard let name = NSRunningApplication(processIdentifier: app.pid)?.localizedName else { return nil }
        if name == "zoom.us" { return "Zoom" }
        return name.components(separatedBy: " Helper").first
    }

    private func recordFromPrompt() {
        Task {
            // The offer itself carries the consent reminder, so one click starts recording.
            do { _ = try await startRecording(mode: .call, title: nil, askConsent: false) }
            catch { warning = error.localizedDescription }
        }
    }

    // MARK: Upload

    func showUpload() {
        uploadMessage = nil
        uploadWindow.show(model: self)
    }

    func chooseFilesToUpload() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = Pipeline.audioExtensions.compactMap { UTType(filenameExtension: $0) }
        guard let window = uploadWindow.host else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else { return }
            Task { @MainActor in self?.upload(panel.urls) }
        }
    }

    func upload(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        uploadMessage = "Adding..."
        Task {
            let (added, problems) = await pipeline.addFiles(urls)
            var parts: [String] = []
            if !added.isEmpty {
                let what = added.count == 1 ? "\(added[0].title)" : "\(added.count) files"
                parts.append("Added \(what). Transcribing now; it will appear under Recent in the menu.")
            }
            parts += problems
            uploadMessage = parts.joined(separator: "\n")
            refresh()
        }
    }

    func setOfferToRecordMeetings(_ on: Bool) {
        offerToRecordMeetings = on
        library.config.meetingPrompt = on
        try? library.config.save(library.paths)
        if !on { meetingPrompt.hide() }
    }

    func refresh() {
        recent = Array(library.allMetas().prefix(8))
        let working = recent.first { $0.status == .transcribing }
        let queued = recent.filter { $0.status == .queued }.count
        if isRecording { return }
        if let w = working {
            if !status.hasPrefix("Transcribing") && !status.hasPrefix("Loading") && !status.hasPrefix("Finding") && !status.hasPrefix("Reading") {
                status = "Transcribing \(w.title)"
            }
        } else if queued > 0 {
            status = "\(queued) waiting to transcribe"
        } else {
            status = "Ready"
        }
    }

    func askOwnerName() {
        let alert = NSAlert()
        alert.messageText = "Your name in transcripts"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = ownerName
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            setOwnerName(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    // MARK: Recording

    func toggle() {
        if isRecording {
            Task { _ = await stopRecording() }
        } else {
            Task {
                do { _ = try await startRecording(mode: .call, title: nil, askConsent: true) }
                catch SottoError.invalid("cancelled") {}
                catch { warning = error.localizedDescription }
            }
        }
    }

    func startRecording(mode: Recorder.Mode, title: String?, askConsent: Bool) async throws -> String {
        guard !isRecording else { throw SottoError.invalid("already recording") }
        if askConsent && consentReminder && !confirmConsent() { throw SottoError.invalid("cancelled") }
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        guard granted else {
            throw SottoError.audio("microphone access is off. Turn it on in System Settings > Privacy & Security > Microphone.")
        }
        let meta = try library.createRecording(title: title, source: "live")
        do {
            let warnings = try recorder.start(mode: mode, folder: library.folder(for: meta.id))
            warning = warnings.first
        } catch {
            try? FileManager.default.removeItem(at: library.folder(for: meta.id))
            throw error
        }
        meetingPrompt.hide()
        currentId = meta.id
        mirror.id = meta.id
        startedAt = Date()
        isRecording = true
        elapsed = 0
        status = "Recording"
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        startQuietWatch()
        refresh()
        return meta.id
    }

    private func startQuietWatch() {
        let minutes = library.config.autoStopMinutes
        guard minutes > 0 else { return }
        quiet = QuietTimer(limit: TimeInterval(minutes) * 60)
        quietWatch = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkForWords() }
        }
    }

    private func checkForWords() async {
        guard isRecording, let id = currentId, !checkingForWords else { return }
        checkingForWords = true
        defer { checkingForWords = false }
        let heard = await pipeline.heardWords(in: recorder.recentAudio(seconds: 65))
        guard isRecording, currentId == id, quiet.update(heardWords: heard) else { return }
        _ = await stopRecording()
        warning = "Recording stopped by itself: nobody spoke for \(library.config.autoStopMinutes) minutes."
    }

    private func tick() {
        guard isRecording, let s = startedAt else { return }
        elapsed = Date().timeIntervalSince(s)
        let (m, sys) = recorder.levels()
        micLevel = m
        systemLevel = sys
        // Rise at once with the loudest source, fall gently, so the dot breathes instead of flickers.
        pulse = max(m, sys ?? 0, pulse * 0.75)
    }

    func stopRecording() async -> String? {
        guard isRecording, let id = currentId else { return nil }
        ticker?.invalidate()
        ticker = nil
        quietWatch?.invalidate()
        quietWatch = nil
        let result = recorder.stop()
        isRecording = false
        currentId = nil
        mirror.id = nil
        micLevel = 0
        systemLevel = nil
        pulse = 0
        if let e = result.errors.first { warning = e }
        _ = try? library.updateMeta(id) {
            $0.tracks = result.tracks
            $0.duration = result.duration
            $0.status = .queued
        }
        if result.tracks.isEmpty {
            _ = try? library.updateMeta(id) { $0.status = .failed; $0.error = "No audio was recorded." }
        } else {
            await pipeline.enqueue(id)
        }
        refresh()
        return id
    }

    /// The reminder shown before a recording starts. Returns false to cancel.
    private func confirmConsent() -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Let everyone know you are recording"
        alert.informativeText = "Many places, Pennsylvania included, require everyone in a conversation to agree before it is recorded. Sotto can copy a short notice you can paste into the meeting chat."
        alert.addButton(withTitle: "Copy Notice and Record")
        alert.addButton(withTitle: "Record")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Do not remind me again"
        let response = alert.runModal()
        if alert.suppressionButton?.state == .on { setConsentReminder(false) }
        switch response {
        case .alertFirstButtonReturn: copyNotice(); return true
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }

    // MARK: Actions

    func copyNotice() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(library.config.consentNotice, forType: .string)
    }

    func copyToken() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(library.config.apiToken, forType: .string)
    }

    func open(_ meta: RecordingMeta) {
        let md = library.folder(for: meta.id).appendingPathComponent("transcript.md")
        if FileManager.default.fileExists(atPath: md.path) { NSWorkspace.shared.open(md) }
        else { NSWorkspace.shared.activateFileViewerSelecting([library.folder(for: meta.id)]) }
    }

    func reveal(_ meta: RecordingMeta) {
        NSWorkspace.shared.activateFileViewerSelecting([library.folder(for: meta.id)])
    }

    func retranscribe(_ meta: RecordingMeta) {
        Task { await pipeline.enqueue(meta.id) }
    }

    func openFolder() { NSWorkspace.shared.open(library.paths.recordings) }
    func openInbox() { NSWorkspace.shared.open(library.paths.inbox) }

    /// Opens the bundled Claude Desktop extension, which Claude Desktop installs in one click.
    func installClaudeExtension() {
        if let url = Bundle.main.url(forResource: "Sotto", withExtension: "mcpb") {
            NSWorkspace.shared.open(url)
        } else {
            warning = "The Claude extension is not in this build. Run scripts/build-app.sh."
        }
    }

    func copyClaudeCodeCommand() {
        let cli = Bundle.main.url(forResource: "sotto", withExtension: nil)?.path ?? "sotto"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("claude mcp add sotto --scope user -- \"\(cli)\" mcp", forType: .string)
    }

    func setConsentReminder(_ on: Bool) {
        consentReminder = on
        library.config.consentReminder = on
        try? library.config.save(library.paths)
    }

    func setOwnerName(_ name: String) {
        let clean = name.trimmingCharacters(in: .whitespaces)
        ownerName = clean
        library.config.ownerName = clean.isEmpty ? "Me" : clean
        try? library.config.save(library.paths)
        // Rewrite transcripts so "Me" shows the new name.
        for meta in library.allMetas() where meta.status == .done { try? library.writeMarkdown(meta.id) }
        index.sync()
    }

    func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            warning = "Could not change Open at Login: \(error.localizedDescription)"
        }
        openAtLogin = SMAppService.mainApp.status == .enabled
    }
}
