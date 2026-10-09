import AppKit
import Carbon.HIToolbox
import SidelightCore
import SwiftUI

/// A button that shows the current shortcut and records a new one when clicked. Esc cancels.
struct HotkeyRecorder: View {
    @Binding var hotkey: Hotkey
    @Environment(HotkeyCenter.self) private var hotkeys
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            isRecording ? stopRecording() : startRecording()
        } label: {
            Text(isRecording ? "Press shortcut…" : hotkey.displayString)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .frame(minWidth: 110)
        }
        .buttonStyle(.bordered)
        .tint(isRecording ? .accentColor : nil)
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        isRecording = true
        // Free the current shortcut so it can be recorded again.
        hotkeys.unregister()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if Int(event.keyCode) == kVK_Escape {
                stopRecording()
            } else if let recorded = Hotkey(event: event) {
                hotkey = recorded
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
        hotkeys.register(hotkey)
    }
}
