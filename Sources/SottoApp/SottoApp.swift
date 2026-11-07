import AppKit
import SottoCore
import SwiftUI

@main
struct SottoMenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: delegate.model)
        } label: {
            MenuBarLabel(model: delegate.model)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Image(systemName: model.isRecording ? "record.circle.fill" : "waveform")
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    /// Opening Sotto again (Spotlight, Finder, Launchpad) shows the panel in a window.
    /// On a crowded menu bar macOS hides icons behind the notch, and this is the way back in.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return false
    }

    func showWindow() {
        if window == nil {
            // The window must not follow the view's size on its own: SwiftUI resizing the
            // window mid layout pass makes AppKit throw. Size it once, let the user resize.
            let host = NSHostingController(rootView: PanelView(model: model))
            host.sizingOptions = []
            let size = host.view.fittingSize
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: max(size.height, 420)),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.contentViewController = host
            w.setContentSize(NSSize(width: 340, height: max(size.height, 420)))
            w.title = "Sotto"
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct PanelView: View {
    @ObservedObject var model: AppModel
    @State private var editingName = false
    @State private var nameDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            recordSection
            if let w = model.warning {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text(w).font(.caption).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button { model.warning = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }
            }
            Divider()
            recentSection
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 340)
    }

    var header: some View {
        HStack {
            Text("Sotto").font(.headline)
            Spacer()
            Text(model.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    var recordSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.isRecording {
                Picker("", selection: $model.mode) {
                    Text("Call: mic + computer").tag(Recorder.Mode.call)
                    Text("In person: mic").tag(Recorder.Mode.room)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            Button(action: model.toggle) {
                HStack {
                    Image(systemName: model.isRecording ? "stop.fill" : "record.circle")
                    Text(model.isRecording ? "Stop  \(Render.clock(model.elapsed))" : "Start Recording")
                        .monospacedDigit()
                    Spacer()
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity)
                .background(model.isRecording ? Color.red.opacity(0.85) : Color.accentColor.opacity(0.9))
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("r", modifiers: [.command])
            if model.isRecording {
                LevelRow(label: "Mic", level: model.micLevel)
                if let s = model.systemLevel { LevelRow(label: "Computer", level: s) }
            }
        }
    }

    var recentSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent").font(.caption).foregroundStyle(.secondary)
            if model.recent.isEmpty {
                Text("No recordings yet. You can also drop audio files in the Inbox folder.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(model.recent, id: \.id) { meta in
                Button { model.open(meta) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(meta.title).lineLimit(1)
                            Text("\(meta.startedAt.formatted(date: .abbreviated, time: .shortened))  \(Render.duration(meta.duration))")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        StatusBadge(status: meta.status)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Open Transcript") { model.open(meta) }
                    Button("Show in Finder") { model.reveal(meta) }
                    Button("Transcribe Again") { model.retranscribe(meta) }
                }
            }
        }
    }

    var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button("Recordings") { model.openFolder() }
                Button("Inbox") { model.openInbox() }
                Button("Copy Notice") { model.copyNotice() }
                    .help("Copy a short recording notice to paste into a meeting chat")
            }
            Menu("Connect an AI app") {
                Button("Install in Claude Desktop") { model.installClaudeExtension() }
                Button("Copy Claude Code command") { model.copyClaudeCodeCommand() }
                Button("Copy local API token") { model.copyToken() }
            }
            .fixedSize()
            Toggle("Remind me to tell people before recording", isOn: Binding(
                get: { model.consentReminder }, set: { model.setConsentReminder($0) }))
            Toggle("Open at login", isOn: Binding(
                get: { model.openAtLogin }, set: { model.setOpenAtLogin($0) }))
            HStack {
                Text("Your name in transcripts:").font(.caption)
                if editingName {
                    TextField("Name", text: $nameDraft, onCommit: {
                        model.setOwnerName(nameDraft); editingName = false
                    })
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                } else {
                    Button(model.ownerName.isEmpty ? "Me" : model.ownerName) {
                        nameDraft = model.ownerName; editingName = true
                    }
                    .buttonStyle(.link)
                }
                Spacer()
                Button("Quit") {
                    Task {
                        _ = await model.stopRecording()
                        NSApp.terminate(nil)
                    }
                }
            }
        }
        .controlSize(.small)
    }
}

struct LevelRow: View {
    let label: String
    let level: Float

    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(.caption2).foregroundStyle(.secondary).frame(width: 56, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.2))
                    Capsule().fill(Color.green)
                        .frame(width: geo.size.width * CGFloat(min(1, sqrt(max(0, level)))))
                }
            }
            .frame(height: 5)
        }
    }
}

struct StatusBadge: View {
    let status: RecordingStatus

    var body: some View {
        switch status {
        case .done: EmptyView()
        case .recording: Image(systemName: "record.circle.fill").foregroundStyle(.red)
        case .queued: Image(systemName: "clock").foregroundStyle(.secondary).help("Waiting to transcribe")
        case .transcribing: ProgressView().controlSize(.mini)
        case .failed: Image(systemName: "exclamationmark.circle").foregroundStyle(.orange).help("Transcription failed. Right-click to try again.")
        }
    }
}
