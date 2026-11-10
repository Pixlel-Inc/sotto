import AppKit
import SottoCore
import SwiftUI
import UniformTypeIdentifiers

struct UploadView: View {
    @ObservedObject var model: AppModel
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 8) {
                Image(systemName: "square.and.arrow.down").font(.system(size: 26)).foregroundStyle(.secondary)
                Text("Drop audio files here").font(.headline)
                Button("Choose Files...") { model.chooseFilesToUpload() }
            }
            .frame(maxWidth: .infinity, minHeight: 150)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(hovering ? Color.accentColor : Color.secondary.opacity(0.5),
                                  style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                    .background(hovering ? Color.accentColor.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
            )
            .dropDestination(for: URL.self) { urls, _ in
                model.upload(urls)
                return !urls.isEmpty
            } isTargeted: { hovering = $0 }
            Text(model.uploadMessage ?? "Transcribed files appear under Recent in the menu.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(width: 340, height: 270)
    }
}

/// Stays above other windows, because dragging from Finder would otherwise hide it.
@MainActor
final class UploadWindow {
    private var window: NSWindow?

    func show(model: AppModel) {
        if window == nil {
            let host = NSHostingController(rootView: UploadView(model: model))
            host.sizingOptions = [] // see AppDelegate.showWindow
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 270),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.contentViewController = host
            w.setContentSize(NSSize(width: 340, height: 270))
            w.title = "Upload to Sotto"
            w.level = .floating
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    var host: NSWindow? { window }
}
