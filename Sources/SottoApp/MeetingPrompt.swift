import AppKit
import SwiftUI

struct MeetingPromptView: View {
    let appName: String?
    let showReminder: Bool
    let onRecord: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Looks like you're in a meeting").font(.headline)
                if let appName {
                    Text("\(appName) is using your microphone.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if showReminder {
                    Text("Remember to tell everyone you are recording.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                Button(action: onRecord) {
                    HStack(spacing: 6) {
                        Image(systemName: "record.circle")
                        Text("Start Recording")
                    }
                    .padding(.vertical, 5)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity)
                    .background(Color.accentColor.opacity(0.9))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Button("Not Now", action: onDismiss)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
            }
        }
        .padding(14)
        .frame(width: 310, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

private final class PromptPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// The small drop-down under the menu bar icon. It never takes focus from the meeting.
@MainActor
final class MeetingPrompt {
    private var panel: NSPanel?
    private var timeout: Timer?
    var isShowing: Bool { panel != nil }

    func show(appName: String?, showReminder: Bool, onRecord: @escaping () -> Void) {
        hide()
        let view = MeetingPromptView(appName: appName, showReminder: showReminder,
                                     onRecord: { [weak self] in self?.hide(); onRecord() },
                                     onDismiss: { [weak self] in self?.hide() })
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        let size = host.fittingSize
        let p = PromptPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.contentView = host
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .statusBar
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.setFrameOrigin(Self.origin(for: size))
        p.alphaValue = 0
        p.orderFrontRegardless()
        p.animator().alphaValue = 1
        panel = p
        // Left alone, it goes away so it never sits over the meeting.
        timeout = Timer.scheduledTimer(withTimeInterval: 120, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.hide() }
        }
    }

    func hide() {
        timeout?.invalidate()
        timeout = nil
        panel?.orderOut(nil)
        panel = nil
    }

    /// Just below the menu bar icon when it can be found, otherwise the top right corner.
    private static func origin(for size: NSSize) -> NSPoint {
        let icon = NSApp.windows.first { String(describing: type(of: $0)).contains("StatusBarWindow") }
        let screen = icon?.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let area = screen.visibleFrame
        let wanted = icon.map { $0.frame.midX - size.width / 2 } ?? (area.maxX - size.width - 8)
        let x = min(max(wanted, area.minX + 8), area.maxX - size.width - 8)
        return NSPoint(x: x, y: area.maxY - size.height - 6)
    }
}
