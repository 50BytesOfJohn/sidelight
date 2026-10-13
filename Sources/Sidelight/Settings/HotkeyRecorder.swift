import AppKit
import Carbon.HIToolbox
import SidelightCore
import SwiftUI

/// A button that shows the current shortcut and records a new one when clicked. Esc cancels. A shortcut another of
/// Sidelight's already uses isn't taken: it says which.
struct HotkeyRecorder: View {
    @Binding var hotkey: Hotkey
    /// Sidelight's other shortcuts, and what each does.
    var others: [(hotkey: Hotkey, use: String)] = []
    @Environment(HotkeyCenter.self) private var hotkeys
    @State private var isRecording = false
    @State private var monitor: Any?
    /// Why the last shortcut pressed wasn't taken.
    @State private var rejection: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Button {
                isRecording ? stopRecording() : startRecording()
            } label: {
                Text(isRecording ? "Press shortcut…" : hotkey.displayString)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .frame(minWidth: 110)
            }
            .buttonStyle(.bordered)
            .tint(isRecording ? .accentColor : nil)
            if let rejection {
                Text(rejection)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        isRecording = true
        rejection = nil
        // Free every shortcut, so the current one (or another of Sidelight's) can be recorded too.
        hotkeys.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if Int(event.keyCode) == kVK_Escape {
                stopRecording()
            } else if let recorded = Hotkey(event: event) {
                if let other = others.first(where: { $0.hotkey.isSameShortcut(as: recorded) }) {
                    rejection = "\(recorded.displayString) already \(other.use)."
                } else {
                    hotkey = recorded
                }
                stopRecording()
            }
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard isRecording else { return }
        isRecording = false
        hotkeys.resume()
    }
}
