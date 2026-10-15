import AppKit
import SidelightCore
import SwiftUI
import os

/// A short message near the bottom of the screen the pointer is on: what a capture saved, with Undo, or why it saved
/// nothing. It never takes focus, so the app you were in keeps it, and goes away on its own.
final class StashToast {
    struct Message {
        struct Action {
            let title: String
            let run: () -> Void
        }

        let title: String
        var detail: String?
        let systemImage: String
        var tint: Color = .accentColor
        var action: Action?
    }

    private var window: NSPanel?
    private var hostingView: NSHostingView<StashToastView>?
    private let pendingHide = DelayedTask()

    /// How long a message stays; one with a button stays longer, to reach it.
    private static let duration: Duration = .milliseconds(2_200)
    private static let durationWithAction: Duration = .seconds(4)
    /// Above the bottom of the screen's usable area: clear of the Dock, near where you look.
    private static let bottomInset: CGFloat = 72

    func show(_ message: Message) {
        let (window, hostingView) = windowAndHost()
        hostingView.rootView = StashToastView(message: message) { [weak self] in
            message.action?.run()
            self?.hide()
        }
        let size = hostingView.fittingSize
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else {
            return Log.stash.error("No screen to show \"\(message.title, privacy: .public)\" on")
        }
        window.setFrame(
            CGRect(
                x: (visible.midX - size.width / 2).rounded(), y: visible.minY + Self.bottomInset, width: size.width,
                height: size.height),
            display: true)
        if !window.isVisible {
            window.alphaValue = 0
            window.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            window.animator().alphaValue = 1
        }
        pendingHide.schedule(after: message.action == nil ? Self.duration : Self.durationWithAction) {
            [weak self] in self?.hide()
        }
        // VoiceOver reads it out: focus stays in the other app, so it wouldn't come across it otherwise.
        NSAccessibility.post(
            element: NSApp as Any, notification: .announcementRequested,
            userInfo: [
                .announcement: [message.title, message.detail].compactMap(\.self).joined(separator: ". "),
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ])
    }

    func hide() {
        pendingHide.cancel()
        guard let window, window.isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            window.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated {
                // Shown again while fading out: leave it.
                guard window.alphaValue == 0 else { return }
                window.orderOut(nil)
            }
        }
    }

    private func windowAndHost() -> (NSPanel, NSHostingView<StashToastView>) {
        if let window, let hostingView { return (window, hostingView) }
        let window = NSPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        window.isFloatingPanel = true
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = true
        window.isReleasedWhenClosed = false
        window.setAccessibilitySubrole(.floatingWindow)
        let hostingView = NSHostingView(rootView: StashToastView(message: nil, run: {}))
        hostingView.sizingOptions = []
        window.contentView = hostingView
        self.window = window
        self.hostingView = hostingView
        return (window, hostingView)
    }
}

/// The toast's content: an icon, a title, a line of detail, and an optional button, on glass.
struct StashToastView: View {
    let message: StashToast.Message?
    let run: () -> Void

    var body: some View {
        if let message {
            HStack(spacing: 10) {
                Image(systemName: message.systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(message.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(message.title)
                        .font(.system(size: 12.5, weight: .semibold))
                    if let detail = message.detail {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.tail)
                    }
                }
                .frame(maxWidth: 320, alignment: .leading)
                if let action = message.action {
                    Button(action.title, action: run)
                        .buttonStyle(.glass)
                        .controlSize(.small)
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, message.action == nil ? 18 : 10)
            .padding(.vertical, 10)
            .fixedSize()
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
            // Room for the glass's edge, which draws a little outside its shape.
            .padding(6)
            .accessibilityElement(children: .contain)
            .accessibilityLabel([message.title, message.detail].compactMap(\.self).joined(separator: ". "))
        }
    }
}
