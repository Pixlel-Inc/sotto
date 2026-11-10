import AppKit
import SottoCore
import SwiftUI

@main
struct SottoMenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    init() {
        // New menu bar items start at the far left of the icons, which on a MacBook with
        // a busy menu bar is underneath the notch, where macOS draws nothing. Start near
        // the clock instead. Cmd-dragging the icon overwrites this value, so it is only a
        // starting point. The number is the distance in points from the right screen edge.
        let key = "NSStatusItem Preferred Position Item-0"
        if UserDefaults.standard.object(forKey: key) == nil {
            UserDefaults.standard.set(300.0, forKey: key)
        }
    }

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
        if model.isRecording {
            Image(nsImage: RecordingDot.image(for: model.pulse))
        } else {
            Image(systemName: "waveform")
        }
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
            settingsMenu
        }
    }

    /// Everything that is not recording lives behind the gear.
    var settingsMenu: some View {
        Menu {
            Button("Open Recordings Folder") { model.openFolder() }
            Button("Open Inbox Folder") { model.openInbox() }
            Button("Copy Recording Notice") { model.copyNotice() }
            Divider()
            Menu("Connect an AI app") {
                Button("Install in Claude Desktop") { model.installClaudeExtension() }
                Button("Copy Claude Code command") { model.copyClaudeCodeCommand() }
                Button("Copy local API token") { model.copyToken() }
            }
            Button("Your Name: \(model.ownerName.isEmpty ? "Me" : model.ownerName)...") { model.askOwnerName() }
            Toggle("Remind Me to Tell People", isOn: Binding(
                get: { model.consentReminder }, set: { model.setConsentReminder($0) }))
            Toggle("Offer to Record Meetings", isOn: Binding(
                get: { model.offerToRecordMeetings }, set: { model.setOfferToRecordMeetings($0) }))
            Toggle("Open at Login", isOn: Binding(
                get: { model.openAtLogin }, set: { model.setOpenAtLogin($0) }))
            Divider()
            Button("Quit Sotto") {
                Task {
                    _ = await model.stopRecording()
                    NSApp.terminate(nil)
                }
            }
        } label: {
            Image(systemName: "gearshape")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Settings")
    }

    var recordSection: some View {
        VStack(alignment: .leading, spacing: 8) {
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
            if !model.isRecording {
                Button(action: model.showUpload) {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.arrow.up")
                        Text("Upload Audio File")
                        Spacer()
                    }
                    .padding(.vertical, 5)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity)
                    .background(Color.secondary.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
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
