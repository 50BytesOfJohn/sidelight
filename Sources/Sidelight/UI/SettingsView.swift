import SwiftUI
import ServiceManagement
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var store = ConfigStore.shared
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var loginError: String?
    @State private var recording = false
    @State private var monitor: Any?

    var c: Binding<AppConfig> { $store.config }

    var body: some View {
        Form {
            Section {
                Picker("Position", selection: c.position.animation(Theme.layout)) {
                    ForEach(PanelPosition.allCases) { p in Label(p.title, systemImage: p.symbol).tag(p) }
                }
                .pickerStyle(.segmented)
                Picker("Size", selection: c.size) {
                    ForEach(PanelSize.allCases) { s in Text("\(s.title) · \(Int(s.width)) pt").tag(s) }
                }
                .pickerStyle(.segmented)
                .disabled(store.config.position.isBar)
                if store.config.position.isBar {
                    Text("Top and bottom bars always use the minimal widget layouts (\(Int(PanelController.barThickness)) pt tall).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: { Text("Panel") }

            Section {
                Picker("Style", selection: c.mode) {
                    ForEach(DisplayMode.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Use Liquid Glass", isOn: c.useGlass)
                Toggle("Animated background (costs ≈9 % CPU)", isOn: c.animatedBG)
            } header: { Text("Appearance") }

            Section {
                HStack(alignment: .top, spacing: 14) {
                    ImageBackground(path: store.config.backgroundImage, dim: store.config.dim, fade: store.config.fade)
                        .frame(width: 70, height: 130)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.1)))
                    VStack(alignment: .leading, spacing: 8) {
                        Text(store.config.backgroundImage.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Bundled wallpaper")
                            .font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                        HStack {
                            Button("Choose Image…") { chooseImage() }
                            if store.config.backgroundImage != nil { Button("Use Default") { store.config.backgroundImage = nil } }
                        }
                        Picker("Cards", selection: c.imageCards) {
                            Text("Liquid Glass").tag(ImageCardStyle.glass)
                            Text("Blurred material").tag(ImageCardStyle.material)
                        }
                        .pickerStyle(.segmented)
                    }
                }
                LabeledContent("Dim") {
                    HStack { Slider(value: c.dim, in: 0...0.85); Text("\(Int(store.config.dim * 100)) %").monospacedDigit().frame(width: 44, alignment: .trailing) }
                }
                LabeledContent("Fade to black") {
                    HStack { Slider(value: c.fade, in: 0...1); Text("\(Int(store.config.fade * 100)) %").monospacedDigit().frame(width: 44, alignment: .trailing) }
                }
            } header: { Text("Image mode") }
              footer: { Text("Used when Style is Image.").font(.caption).foregroundStyle(.secondary) }

            Section {
                Picker("Mode", selection: c.avoidMode) {
                    Text("Off").tag(AvoidMode.off)
                    Text("Shift").tag(AvoidMode.shift)
                    Text("Clip").tag(AvoidMode.clip)
                    Text("Smart").tag(AvoidMode.smart)
                }
                .pickerStyle(.segmented)
                Text(avoidHelp).font(.caption).foregroundStyle(.secondary)
                LabeledContent("Accessibility") {
                    Text(Avoider.shared.trusted ? "Granted" : "Not granted").foregroundStyle(Avoider.shared.trusted ? .green : .orange)
                }
                HStack {
                    Button("Configure Rectangle…") { (NSApp.delegate as? AppDelegate)?.configureRectangle() }
                    Button("Revert Rectangle") { (NSApp.delegate as? AppDelegate)?.revertRectangle() }
                    Spacer()
                    Text("writes \(store.config.position.rectangleKey)").font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            } header: { Text("Window avoidance") }

            Section {
                LabeledContent("Toggle panel") {
                    Button {
                        recording ? stopRecording() : startRecording()
                    } label: {
                        Text(recording ? "Press shortcut…" : store.config.hotkey.display)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .frame(minWidth: 110)
                    }
                    .buttonStyle(.bordered)
                    .tint(recording ? .accentColor : nil)
                }
                if HotkeyManager.shared.lastStatus != 0 {
                    Text("This shortcut could not be registered (status \(HotkeyManager.shared.lastStatus)); it may be taken.").font(.caption).foregroundStyle(.orange)
                }
            } header: { Text("Keyboard") }

            Section {
                Toggle("Launch at login", isOn: Binding(get: { loginStatus == .enabled }, set: { setLogin($0) }))
                LabeledContent("Status") { Text(statusText).foregroundStyle(.secondary) }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
                LabeledContent("Config file") {
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([store.url]) }
                }
            } header: { Text("General") }
        }
        .formStyle(.grouped)
        .onDisappear { stopRecording() }
    }

    var avoidHelp: String {
        switch store.config.avoidMode {
        case .off: "Windows are never moved."
        case .shift: "Overlapping windows are moved away from the panel, keeping their size."
        case .clip: "Overlapping windows keep their far edge and shrink by the overlap."
        case .smart: "Clip windows snapped/maximized against the edge, shift free-floating ones."
        }
    }
    var statusText: String {
        switch loginStatus {
        case .enabled: "Enabled"
        case .notRegistered: "Not registered"
        case .requiresApproval: "Requires approval in System Settings → General → Login Items"
        case .notFound: "Not found"
        @unknown default: "Unknown"
        }
    }

    func setLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch { loginError = error.localizedDescription }
        loginStatus = SMAppService.mainApp.status
    }

    func chooseImage() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image]
        p.allowsMultipleSelection = false
        p.canChooseDirectories = false
        p.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures")
        p.message = "Choose a background image for the panel"
        if p.runModal() == .OK, let url = p.url {
            store.config.backgroundImage = url.path
            if store.config.mode != .image { store.config.mode = .image }
        }
    }

    func startRecording() {
        recording = true
        HotkeyManager.shared.unregister()   // so the current combo can be re-recorded
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53 { stopRecording(); return nil }   // Esc cancels
            if let spec = HotkeyManager.spec(from: e) { store.config.hotkey = spec; stopRecording(); return nil }
            return nil
        }
    }
    func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording { recording = false; HotkeyManager.shared.register(store.config.hotkey) }
    }
}
