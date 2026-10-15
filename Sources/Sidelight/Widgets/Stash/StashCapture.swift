import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Observation
import SidelightCore
import SwiftUI
import os

/// Stashes text from other apps, on the stash shortcuts or the widget's clipboard button. Nothing runs between
/// presses: the selection and the clipboard are each read once, when asked, never watched.
///
/// The selection is read through Accessibility, which Sidelight already has for window avoidance, so the app you're
/// in keeps focus. Password fields, and apps the settings exclude (password managers by default), are never read. The
/// clipboard is left alone while an excluded app is in front, or when it says an excluded app copied it or marks it
/// private; text copied in an app that doesn't say so can still be stashed after switching to another app.
@Observable
final class StashCapture {
    @ObservationIgnored private let store: StashStore
    @ObservationIgnored private let configuration: ConfigurationStore
    @ObservationIgnored private let toast = StashToast()

    /// Password managers mark what they copy with this, so clipboard tools leave it alone (nspasteboard.org).
    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    /// The bundle identifier of the app that copied, for apps that say.
    private static let sourceType = NSPasteboard.PasteboardType("org.nspasteboard.source")

    init(store: StashStore, configuration: ConfigurationStore) {
        self.store = store
        self.configuration = configuration
    }

    private var options: StashOptions { configuration.configuration.stash }

    /// Stashes the text selected in the frontmost app, or says why it can't.
    func captureSelection() {
        // A capture may still be borrowing the clipboard; a second one would take the first's copy for the clipboard.
        guard !isCapturing else { return Log.stash.info("Already capturing the selection") }
        let app = NSWorkspace.shared.frontmostApplication
        guard !options.excludes(app?.bundleIdentifier) else {
            Log.stash.info("Not capturing from an excluded app")
            return show(
                notStashed: "\(app?.localizedName ?? "This app") is excluded from the stash.",
                systemImage: "hand.raised.fill")
        }
        isCapturing = true
        Task {
            await capture(from: app)
            isCapturing = false
        }
    }

    @ObservationIgnored private var isCapturing = false

    private func capture(from app: NSRunningApplication?) async {
        let name = app?.localizedName ?? "This app"
        switch await selection(in: app) {
        case .text(let text, let strategy):
            Log.stash.info("Captured the selection \(strategy, privacy: .public)")
            save(text, source: app?.bundleIdentifier)
        case .secure:
            Log.stash.info("Not capturing from a password field")
            show(notStashed: "Sidelight never reads password fields.", systemImage: "lock.fill")
        case .concealed:
            Log.stash.info("Not stashing a copied selection marked concealed")
            show(notStashed: "\(name) marked what it copied as private, like a password.", systemImage: "lock.fill")
        case .noAccess:
            // A build run from a terminal (`make dev`) is trusted through the app that launched it, not itself.
            Log.stash.notice("Can't read the selection: no Accessibility access")
            toast.show(
                StashToast.Message(
                    title: "Sidelight needs Accessibility access",
                    detail: "It reads the selection the way it moves windows.", systemImage: "hand.raised.fill",
                    tint: .orange,
                    action: StashToast.Message.Action(title: "Open Settings") {
                        SystemSettingsPane.accessibilityPrivacy.open()
                    }))
        case .sidelightInFront:
            Log.stash.info("Not capturing: Sidelight itself is in front")
            toast.show(
                StashToast.Message(
                    title: "Nothing selected", detail: "Select text in another app, then press the shortcut there.",
                    systemImage: "text.cursor", tint: .secondary))
        case .noSelection(let reason):
            Log.stash.info("Nothing to capture: \(reason, privacy: .public)")
            toast.show(
                StashToast.Message(
                    title: "Nothing selected", detail: "Select text in \(name), then press the shortcut.",
                    systemImage: "text.cursor", tint: .secondary))
        case .unreadable(let reason, let hint):
            Log.stash.info("Nothing to capture: \(reason, privacy: .public)")
            toast.show(
                StashToast.Message(
                    title: "Nothing selected",
                    detail: [
                        hint ?? "\(name) doesn't share a selection.",
                        options.clipboardHotkey.ifEnabled.map { "Copy it, then press \($0.displayString)." },
                    ].compactMap(\.self).joined(separator: " "),
                    systemImage: "text.cursor", tint: .secondary))
        }
    }

    /// Stashes the text on the clipboard, read once, now.
    func addClipboard() {
        let pasteboard = NSPasteboard.general
        let types = pasteboard.types ?? []
        guard !types.contains(Self.concealedType) else {
            Log.stash.info("Not stashing a clipboard marked concealed")
            return show(
                notStashed: "What's on the clipboard is marked private, like a password.", systemImage: "lock.fill")
        }
        // Not every app says it copied, and the one that did may not be the one you're in: either being excluded is
        // enough.
        let source = pasteboard.string(forType: Self.sourceType)
        guard !options.excludes(source) else {
            Log.stash.info("Not stashing a clipboard from an excluded app")
            return show(
                notStashed: "It was copied from an app excluded from the stash.", systemImage: "hand.raised.fill")
        }
        let app = NSWorkspace.shared.frontmostApplication
        guard !options.excludes(app?.bundleIdentifier) else {
            Log.stash.info("Not stashing the clipboard in an excluded app")
            return show(
                notStashed: "\(app?.localizedName ?? "This app") is excluded from the stash.",
                systemImage: "hand.raised.fill")
        }
        guard let text = pasteboard.string(forType: .string), !text.allSatisfy(\.isWhitespace) else {
            Log.stash.info("Nothing to capture: the clipboard has no text")
            return toast.show(
                StashToast.Message(
                    title: "Nothing to stash", detail: "The clipboard has no text.", systemImage: "doc.on.clipboard",
                    tint: .secondary))
        }
        save(text, source: source)
    }

    private func save(_ text: String, source: String?) {
        let item: StashItem
        switch store.add(text, source: source) {
        case .success(let added): item = added
        case .failure(.blank):
            // Both callers already leave out blank text; still, never end a capture without a word.
            Log.stash.info("Nothing to capture: the text is blank")
            return toast.show(
                StashToast.Message(title: "Nothing to stash", systemImage: "text.cursor", tint: .secondary))
        case .failure(.tooLong):
            Log.stash.info("Not stashing text over the length limit")
            return show(
                notStashed: "It's over \(StashList.maximumTextLength.formatted()) characters, too long for the stash.",
                systemImage: "text.badge.xmark")
        }
        let undo = StashToast.Message.Action(title: "Undo") { [store] in store.delete(item.id) }
        // The last save failed: it's stashed for now, but not on disk yet.
        let message =
            store.hasSaveFailed
            ? StashToast.Message(
                title: "Stashed, but not saved to disk",
                detail: "The stash file can't be read or written, so it's kept only while Sidelight runs.",
                systemImage: "exclamationmark.triangle.fill", tint: .orange, action: undo)
            : StashToast.Message(
                title: "Saved to Stash", detail: item.title, systemImage: "tray.and.arrow.down.fill", action: undo)
        toast.show(message)
    }

    private func show(notStashed reason: String, systemImage: String) {
        toast.show(StashToast.Message(title: "Not stashed", detail: reason, systemImage: systemImage, tint: .orange))
    }

    // MARK: Reading the selection

    private enum Selection {
        /// The strategy that read it is for the log.
        case text(String, strategy: String)
        /// A password field has focus.
        case secure
        /// The app copied it marked private, like a password.
        case concealed
        /// The app says nothing is selected; the reason is for the log.
        case noSelection(String)
        /// The selection couldn't be read: the reason is for the log, the hint, if any, for the person.
        case unreadable(String, hint: String?)
        /// One of Sidelight's own windows is in front.
        case sidelightInFront
        case noAccess

        var isUnreadable: Bool {
            if case .unreadable = self { true } else { false }
        }
    }

    /// Apps asked to build their accessibility tree (``AccessibilityElement/requestAccessibilityTree()``) since
    /// Sidelight started: one that still shares no selection after that isn't asked, or waited for, again.
    @ObservationIgnored private var askedForTree: Set<pid_t> = []

    /// How long an app asked to build its accessibility tree gets to do it, checked every ``treePollInterval``.
    private static let treeTimeout = Duration.milliseconds(500)
    private static let treePollInterval = Duration.milliseconds(50)

    /// The text selected in `app`, trying in turn:
    /// 1. its focused element's selected text, through Accessibility;
    /// 2. the same, once an Electron app has been asked to build its accessibility tree (the first time only);
    /// 3. pressing ⌘C there and putting the clipboard back (``SelectionCopier``), for apps that draw their own text,
    ///    unless the settings turn it off.
    ///
    /// The later ones run only when Accessibility can't tell: when it says nothing is selected, that's the answer
    /// (⌘C with nothing selected copies the whole line in some editors).
    private func selection(in app: NSRunningApplication?) async -> Selection {
        guard AXIsProcessTrusted() else { return .noAccess }
        guard let app else { return .noSelection("no app is in front") }
        // Asking Sidelight's own windows through Accessibility from the main thread would wait on itself.
        guard app != .current else { return .sidelightInFront }

        var selection = Self.accessibilitySelection(in: app, strategy: "through Accessibility")
        guard case .unreadable(let reason, _) = selection else { return selection }

        let pid = app.processIdentifier
        if !askedForTree.contains(pid) {
            askedForTree = askedForTree.filter { NSRunningApplication(processIdentifier: $0) != nil }
            askedForTree.insert(pid)
            Log.stash.info(
                "Asking the app to build its accessibility tree, as \(reason, privacy: .public)")
            AccessibilityElement.application(pid).requestAccessibilityTree()
            let clock = ContinuousClock()
            let deadline = clock.now + Self.treeTimeout
            repeat {
                try? await Task.sleep(for: Self.treePollInterval)
                // Switched away while waiting: the selection was in the app the shortcut was pressed in.
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
                    return .unreadable(
                        "another app came to the front", hint: "Stay in \(app.localizedName ?? "the app").")
                }
                selection = Self.accessibilitySelection(
                    in: app, strategy: "through Accessibility, once the app built its accessibility tree")
            } while selection.isUnreadable && clock.now < deadline
            guard case .unreadable(let reason, _) = selection else { return selection }
            Log.stash.info("Still unreadable once asked for the accessibility tree: \(reason, privacy: .public)")
        }

        // Accessibility can't see a password field the app draws itself, but the app has secure input on for it.
        guard !Self.isSecureInputOn(in: app) else { return .secure }
        guard options.copiesSelectionWithCommandC else {
            return .unreadable("\(reason), and copying with ⌘C is off", hint: nil)
        }
        switch await SelectionCopier.copySelection(in: app) {
        case .text(let text) where !text.allSatisfy(\.isWhitespace):
            return .text(text, strategy: "by copying it with ⌘C, then putting the clipboard back")
        case .text: return .noSelection("⌘C copied only whitespace")
        case .concealed: return .concealed
        case .nothingCopied(let why): return .noSelection("\(reason), and \(why)")
        case .notTried(let why, let hint): return .unreadable("\(reason), and not copying: \(why)", hint: hint)
        }
    }

    /// The text selected in `app`'s focused element, through Accessibility. Each call waits at most
    /// ``AccessibilityElement/messagingTimeout`` for a busy app.
    private static func accessibilitySelection(in app: NSRunningApplication, strategy: String) -> Selection {
        let focused: AccessibilityElement
        switch AccessibilityElement.application(app.processIdentifier).focusedElement {
        case .success(let element): focused = element
        case .failure(let error):
            return .unreadable("the app's focused element can't be read (\(error))", hint: nil)
        }
        if focused.isSecureTextField || (focused.role == kAXTextFieldRole && isSecureInputOn(in: app)) {
            return .secure
        }
        switch focused.selectedText {
        case .success(let text) where !text.allSatisfy(\.isWhitespace): return .text(text, strategy: strategy)
        case .success: return .noSelection("nothing is selected in its \(focused.role ?? "focused element")")
        case .failure(let error):
            return .unreadable(
                "its \(focused.role ?? "focused element") doesn't share a selection (\(error))", hint: nil)
        }
    }

    /// Whether `app` has secure keyboard entry on, as a password field that doesn't say it's one does while it has
    /// focus. The flag is system-wide, so another app's (a password manager's, a terminal's secure entry) would
    /// otherwise make every plain text field look like a password field; the session names the app that turned it
    /// on. That name isn't public API: without it, any app having it on counts.
    private static func isSecureInputOn(in app: NSRunningApplication) -> Bool {
        guard IsSecureEventInputEnabled() else { return false }
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        guard let owner = (session?["kCGSSessionSecureInputPID"] as? NSNumber)?.int32Value else { return true }
        return owner == app.processIdentifier
    }
}
