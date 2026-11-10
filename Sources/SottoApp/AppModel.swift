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
            await pipeline.resumeUnfinished()
        }
        inboxTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { _ = await self.pipeline.scanInbox() }
        }
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
        currentId = meta.id
        mirror.id = meta.id
        startedAt = Date()
        isRecording = true
        elapsed = 0
        status = "Recording"
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        refresh()
        return meta.id
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
