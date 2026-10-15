import AppKit
import SidelightCore
import SwiftUI
import UniformTypeIdentifiers

extension WidgetMetadata {
    static let stash = WidgetMetadata(
        title: "Stash",
        systemImage: "tray.full.fill",
        tint: .teal,
        summary: "Prompts and snippets to use next",
        details:
            "Stash the text selected in any app, or the clipboard, with a shortcut (Settings → Shortcuts), then copy "
            + "items into Claude, Codex or Cursor and check them off. Everything stays on this Mac, in a stash folder "
            + "next to config.json. Selecting needs the Accessibility access window avoidance uses."
    )
}

extension StashSettings {
    var summary: String { itemCount == 1 ? "1 item" : "\(itemCount) items" }
}

extension StashOptions {
    /// How to stash something with the capture shortcuts that are on, for an empty stash.
    var captureHint: String {
        switch (captureHotkey.ifEnabled, clipboardHotkey.ifEnabled) {
        case (let selection?, let clipboard?):
            "Select text in any app and press \(selection.displayString), or copy it and press "
                + "\(clipboard.displayString)."
        case (let selection?, nil): "Select text in any app and press \(selection.displayString)."
        case (nil, let clipboard?): "Copy text in any app and press \(clipboard.displayString)."
        case (nil, nil): "The capture shortcuts are turned off."
        }
    }
}

// MARK: - Settings

struct StashSettingsEditor: View {
    @Binding var settings: StashSettings
    @Environment(ConfigurationStore.self) private var store

    var body: some View {
        @Bindable var store = store
        let options = store.configuration.stash
        Stepper("Items shown: \(settings.itemCount)", value: $settings.itemCount, in: StashSettings.itemCountRange)
        Toggle("Two lines per item", isOn: $settings.showsTwoLines)
        Toggle("App icons", isOn: $settings.showsSourceIcons)
        StashCaptureStatus()
        ExpandableRow(
            title: "Every Stash widget",
            info: "One stash is shared by every Stash widget on every display, so these apply to all of them."
        ) {
            Picker(selection: $store.configuration.stash.order) {
                Text("Oldest first").tag(StashOrder.oldestFirst)
                Text("Newest first").tag(StashOrder.newestFirst)
            } label: {
                InfoLabel(
                    "List open items",
                    info: "Oldest first works through the stash like a queue, new items at the bottom; newest first "
                        + "puts new items on top. Dragging items or ⌥⌘↑ and ⌥⌘↓ still arrange them, and switching "
                        + "flips the whole list, arrangement included. Pinned items stay first either way.")
            }
            Picker(selection: $store.configuration.stash.deleteDoneAfterDays) {
                let days = Set(StashOptions.deleteDoneDayChoices + [options.deleteDoneAfterDays]).subtracting([0])
                ForEach(days.sorted(), id: \.self) {
                    Text($0 == 1 ? "1 day" : "\($0) days").tag($0)
                }
                Text("Never").tag(0)
            } label: {
                InfoLabel(
                    "Delete done items after",
                    info: "Checked-off items stay under Done and All in the stash until then, so the stash keeps "
                        + "itself tidy. Pinned items are never done.")
            }
            Toggle(isOn: $store.configuration.stash.copiesSelectionWithCommandC) {
                Text("Copy with ⌘C when an app doesn't share its selection")
                Text(
                    "Briefly uses the clipboard and puts it back. Clipboard history apps may record the selection. "
                        + "Never used in excluded apps or password fields.")
            }
            StashExcludedApps(bundleIDs: $store.configuration.stash.excludedApps)
        }
    }
}

/// Whether the capture shortcuts are taken right now, and whether the selection can be read. Only what can be known:
/// macOS says when another app has taken a shortcut for itself, but not when one merely shares it.
private struct StashCaptureStatus: View {
    @Environment(HotkeyCenter.self) private var hotkeys
    @Environment(WindowAvoider.self) private var windowAvoider
    @Environment(SettingsNavigator.self) private var navigator
    @Environment(ConfigurationStore.self) private var store

    var body: some View {
        // Access is asked for each time this is drawn, as window avoidance's flag goes stale while avoidance is off;
        // reading the flag still redraws this when access is granted.
        let _ = windowAvoider.isTrusted
        let status = status(hasAccess: AXIsProcessTrusted())
        StatusRow(color: status.color, alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(status.text)
                Button("Change Shortcuts…") { navigator.showShortcuts() }
                    .buttonStyle(.link)
            }
        } trailing: {
            Spacer(minLength: 4)
            if status.needsAccess {
                Button("Open Settings…") { SystemSettingsPane.accessibilityPrivacy.open() }
            }
            InfoButton(
                "The capture shortcuts are taken while a Stash widget is in a panel, shown or hidden, and change in "
                    + "Settings → Shortcuts. If another app uses the same shortcut too, pressing it may do that app's "
                    + "action as well, which macOS can't tell Sidelight about.")
        }
    }

    /// The shortcuts that are on, and whether each is taken; the selection's needs Accessibility access to work.
    private func status(hasAccess: Bool) -> (color: Color, text: String, needsAccess: Bool) {
        let options = store.configuration.stash
        let selection = options.captureHotkey.ifEnabled
        let clipboard = options.clipboardHotkey.ifEnabled
        let actions = [selection.map { _ in HotkeyAction.stashSelection }, clipboard.map { _ in .stashClipboard }]
            .compactMap(\.self)
        if actions.isEmpty {
            return (.secondary, "The capture shortcuts are turned off.", false)
        }
        if actions.contains(where: { hotkeys.problems[$0] != nil }) {
            return (.orange, "A capture shortcut can't be used.", false)
        }
        guard actions.allSatisfy({ hotkeys.workingHotkey(for: $0) != nil }) else {
            return (.secondary, "Capture shortcuts are off until a Stash widget is in a panel.", false)
        }
        let stashesClipboard = clipboard.map { "\($0.displayString) stashes the clipboard" }
        if let selection, !hasAccess {
            let text = "\(selection.displayString) needs Accessibility access to read the selection"
            return (.orange, [text, stashesClipboard].compactMap(\.self).joined(separator: "; ") + ".", true)
        }
        let stashesSelection = selection.map { "\($0.displayString) stashes the selection" }
        return (.green, [stashesSelection, stashesClipboard].compactMap(\.self).joined(separator: ", ") + ".", false)
    }
}

/// The apps nothing is stashed from: each with its icon and a button to remove it, and a button to add one.
private struct StashExcludedApps: View {
    @Binding var bundleIDs: [String]

    var body: some View {
        LabeledContent {
            Button("Add App…", action: addApp)
        } label: {
            InfoLabel(
                "Never stash from",
                info: "Nothing is stashed while one of these apps is in front, nor clipboard text an app says was "
                    + "copied in one of them. Password fields, and what's copied marked private, never are.")
        }
        ForEach(bundleIDs, id: \.self) { bundleID in
            HStack(spacing: 8) {
                StashAppIcon(bundleID: bundleID, size: 16)
                Text(StashAppIcons.name(for: bundleID) ?? bundleID)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                Button {
                    bundleIDs.removeAll { $0 == bundleID }
                } label: {
                    Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Stop excluding it")
                .accessibilityLabel("Stop excluding \(StashAppIcons.name(for: bundleID) ?? bundleID)")
            }
        }
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(filePath: "/Applications", directoryHint: .isDirectory)
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.prompt = "Exclude"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let bundleID = Bundle(url: url)?.bundleIdentifier, !bundleIDs.contains(bundleID) else { continue }
            bundleIDs.append(bundleID)
        }
    }
}

// MARK: - Widget

/// The next few open items, pinned first, each with Copy, Done and Copy & Done on hover. The whole stash opens in the
/// details panel.
struct StashWidgetView: View {
    let settings: StashSettings
    let layout: WidgetLayout
    @Environment(StashStore.self) private var store
    @Environment(StashCapture.self) private var capture
    @Environment(ConfigurationStore.self) private var configuration
    @Environment(DetailsPresenter.self) private var details
    @Environment(SettingsNavigator.self) private var navigator
    @Environment(\.widgetPlacement) private var placement
    @Environment(\.isWidgetPreview) private var isPreview

    /// Someone's stash is theirs: previews show an example instead.
    private var items: [StashItem] { isPreview ? StashList.example.openItems(store.order) : store.openItems }

    var body: some View {
        switch layout {
        case .regular, .compact: list
        case .minimal, .bar: glance
        }
    }

    // MARK: List

    @ViewBuilder
    private var list: some View {
        let items = items
        let isCompact = layout == .compact
        let shown = Array(items.prefix(isCompact ? min(settings.itemCount, 3) : settings.itemCount))
        if items.isEmpty {
            // The footer stays, in every layout: + and Open Stash (done items are there), and Try Again.
            VStack(alignment: .leading, spacing: isCompact ? 4 : 6) {
                if isSaveFailed {
                    WidgetMessage(
                        title: "Stash not saved", detail: Self.saveFailedHelp + ".",
                        systemImage: "exclamationmark.triangle", layout: layout)
                } else {
                    // Done items are kept for a while: with some there, the stash isn't empty, just all done.
                    let isAllDone = !isPreview && !store.list.items.isEmpty
                    WidgetMessage(
                        title: isAllDone ? "All done" : "Nothing stashed",
                        detail: configuration.configuration.stash.captureHint,
                        systemImage: isAllDone ? "checkmark.circle" : "tray", layout: layout,
                        action: .init(title: "Change Shortcuts…", isDisabled: isPreview) { navigator.showShortcuts() })
                }
                footer(more: 0, isCompact: isCompact, isEmpty: true)
            }
        } else {
            VStack(alignment: .leading, spacing: isCompact ? 4 : 6) {
                ForEach(shown) { item in
                    StashWidgetRow(
                        item: item, lineLimit: isCompact || !settings.showsTwoLines ? 1 : 2,
                        showsIcon: settings.showsSourceIcons, isCompact: isCompact, actions: actions(for: item)
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
                footer(more: items.count - shown.count, isCompact: isCompact, isEmpty: false)
            }
            .animation(Motion.layout, value: shown.map(\.id))
        }
    }

    /// Try Again while unsaved, the way into the whole stash (+N more, or Open Stash with nothing open), and the
    /// clipboard and new-item buttons.
    private func footer(more: Int, isCompact: Bool, isEmpty: Bool) -> some View {
        HStack(spacing: 10) {
            if isSaveFailed {
                Button {
                    store.flush()
                } label: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: isCompact ? 9.5 : 10.5, weight: .semibold))
                        .foregroundStyle(.orange)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(Self.saveFailedHelp + ". Click to try again.")
                .accessibilityLabel(Self.saveFailedHelp)
                .accessibilityHint("Tries saving again")
            }
            if more > 0 || isEmpty {
                Button(isEmpty ? "Open Stash" : "+\(more) more") { openDetails?(false) }
                    .buttonStyle(.plain)
                    .font(.system(size: isCompact ? 10 : 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .help("Open the whole stash")
            }
            Spacer(minLength: 4)
            if !isCompact {
                footerButton("clipboard", help: "Stash the clipboard") { capture.addClipboard() }
            }
            footerButton("plus", help: "New item") { openDetails?(true) }
        }
        .padding(.top, 1)
        .disabled(isPreview)
    }

    private func footerButton(_ systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 18)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .hoverHighlight(cornerRadius: 6, vertical: 0)
        .help(help)
        .accessibilityLabel(help)
    }

    // MARK: Glance

    @ViewBuilder
    private var glance: some View {
        let items = items
        let next = items.first
        let content = Group {
            if layout == .bar {
                HStack(spacing: 5) {
                    glanceSymbol
                        .font(.system(size: 11, weight: .semibold))
                    Text(items.count, format: .number)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    if let next {
                        Text(next.title)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .frame(maxWidth: 140, alignment: .leading)
                    }
                }
            } else {
                VStack(spacing: 3) {
                    glanceSymbol
                        .font(.system(size: 13, weight: .semibold))
                    Text(items.count, format: .number)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
            }
        }
        let label = items.count == 1 ? "1 open item" : "\(items.count) open items"
        let help = [label, next.map { "Next: \($0.title)" }, isSaveFailed ? Self.saveFailedHelp : nil]
            .compactMap(\.self).joined(separator: ". ")
        if let openDetails {
            content.opens { openDetails(false) }.help(help).accessibilityLabel(help)
        } else {
            content.help(help).accessibilityLabel(help)
        }
    }

    /// The tray, or a warning while the stash can't be saved.
    private var glanceSymbol: some View {
        Image(
            systemName: isSaveFailed ? "exclamationmark.triangle.fill" : items.isEmpty ? "tray" : "tray.full.fill"
        )
        .foregroundStyle(isSaveFailed ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
    }

    private var isSaveFailed: Bool { store.hasSaveFailed && !isPreview }

    private static let saveFailedHelp =
        "Not saved: the stash file can't be read or written, so the stash is kept only while Sidelight runs"

    // MARK: Actions

    /// Opens the whole stash in the details panel, `composing` a new item or not. Only from a real panel: previews
    /// have no placement.
    private var openDetails: ((_ composing: Bool) -> Void)? {
        guard let placement, !isPreview else { return nil }
        return { [details] composing in details.open(.stash(composing: composing), from: placement) }
    }

    /// Each acts on the item as it is in the store, an edit of it under way in the details panel included.
    private func actions(for item: StashItem) -> StashRowActions? {
        guard !isPreview else { return nil }
        let store = store
        let id = item.id
        return StashRowActions(
            copy: {
                guard let text = store.list[id]?.text else { return false }
                SessionHost.copy(text)
                return true
            },
            done: { store.markDone(id) },
            copyAndDone: {
                guard let text = store.list[id]?.text else { return }
                SessionHost.copy(text)
                store.markDone(id)
            },
            togglePin: { store.setPinned(!item.isPinned, item.id) },
            openStash: openDetails.map { open in { open(false) } })
    }
}

/// What a row in the widget can do; previews do nothing.
private struct StashRowActions {
    /// Returns whether it copied.
    let copy: () -> Bool
    let done: () -> Void
    let copyAndDone: () -> Void
    let togglePin: () -> Void
    let openStash: (() -> Void)?
}

/// One open item: its app's icon, its text and a pin at the end if pinned, and on hover, Copy, Done and Copy & Done.
/// Pinned items are never done, so they offer Copy alone.
private struct StashWidgetRow: View {
    let item: StashItem
    let lineLimit: Int
    let showsIcon: Bool
    let isCompact: Bool
    let actions: StashRowActions?
    @State private var isHovered = false
    @State private var didCopy = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if showsIcon {
                StashAppIcon(bundleID: item.source, size: isCompact ? 11 : 13)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + (isCompact ? 3.5 : 4.5) }
            }
            Text(lineLimit == 1 ? item.title : item.text)
                .font(.system(size: isCompact ? 11 : 12.5))
                .lineLimit(lineLimit)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            // At the end, so pinned or not, every row's text starts at the same place.
            if item.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: isCompact ? 8 : 9, weight: .semibold))
                    .foregroundStyle(.orange)
                    .opacity(isHovered && actions != nil ? 0 : 1)
                    .accessibilityLabel("Pinned")
            }
        }
        .overlay(alignment: .topTrailing) {
            if isHovered, let actions {
                buttons(actions)
                    .transition(.opacity)
            }
        }
        .contentShape(.rect)
        .hoverHighlight(cornerRadius: 7, opacity: 0.06, vertical: 2)
        .onHover { hovering in
            withAnimation(Motion.hover) { isHovered = hovering }
            if !hovering { didCopy = false }
        }
        .contextMenu {
            if let actions { menu(actions) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityActions {
            if let actions { menu(actions) }
        }
    }

    private func buttons(_ actions: StashRowActions) -> some View {
        HStack(spacing: 1) {
            button(didCopy ? "checkmark" : "doc.on.doc", help: didCopy ? "Copied" : "Copy") {
                didCopy = actions.copy()
            }
            if !item.isPinned {
                button("checkmark.circle", help: "Done", action: actions.done)
                button("arrow.right.doc.on.clipboard", help: "Copy & Done", action: actions.copyAndDone)
            }
        }
        .padding(2)
        .glassEffect(.regular, in: .capsule)
    }

    private func button(_ systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: isCompact ? 9.5 : 10.5, weight: .semibold))
                .frame(width: isCompact ? 18 : 22, height: isCompact ? 16 : 19)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    @ViewBuilder
    private func menu(_ actions: StashRowActions) -> some View {
        Button("Copy") { _ = actions.copy() }
        if !item.isPinned {
            Button("Done", action: actions.done)
            Button("Copy & Done", action: actions.copyAndDone)
        }
        Button(item.isPinned ? "Unpin" : "Pin", action: actions.togglePin)
        if let openStash = actions.openStash {
            Divider()
            Button("Open Stash", action: openStash)
        }
    }
}

// MARK: - App icons

/// The icon of the app an item came from. Items from no known app (written here, or clipboard text no app claimed) and
/// ones from an app that isn't installed show a plain text symbol the same size, so every item's text starts at the
/// same place.
struct StashAppIcon: View {
    let bundleID: String?
    let size: CGFloat

    var body: some View {
        Group {
            if let bundleID, let icon = StashAppIcons.icon(for: bundleID) {
                Image(nsImage: icon).resizable().interpolation(.high)
            } else {
                // App icons leave a margin inside their square; the symbol keeps one too, so it weighs the same.
                Image(systemName: "text.alignleft")
                    .resizable()
                    .scaledToFit()
                    .fontWeight(.semibold)
                    .foregroundStyle(.tertiary)
                    .padding(size * 0.18)
            }
        }
        .frame(width: size, height: size)
        .help(help)
        .accessibilityHidden(true)
    }

    private var help: String {
        guard let bundleID else { return "" }
        return "From \(StashAppIcons.name(for: bundleID) ?? bundleID)"
    }
}

/// Apps' icons and names by bundle identifier, looked up once each: rows redraw as the stash changes.
enum StashAppIcons {
    private static var apps: [String: (icon: NSImage, name: String)?] = [:]

    static func icon(for bundleID: String) -> NSImage? { app(bundleID)?.icon }

    static func name(for bundleID: String) -> String? { app(bundleID)?.name }

    private static func app(_ bundleID: String) -> (icon: NSImage, name: String)? {
        if let cached = apps[bundleID] { return cached }
        let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { url in
            (
                icon: NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false)),
                name: FileManager.default.displayName(atPath: url.path(percentEncoded: false))
                    .replacing(/\.app$/, with: "")
            )
        }
        apps[bundleID] = app
        return app
    }
}

// MARK: - Example

extension StashList {
    /// What previews show in place of someone's stash.
    static let example: StashList = {
        var list = StashList()
        let now = Date.now
        list.add(
            "Review the diff for the settings migration and list anything that breaks old config files",
            source: "com.apple.Terminal", now: now)
        list.add("Write tests for the Done filter, then run make check", now: now)
        if let pinned = list.add("Explain this like I'm new to Swift, one sentence per choice", now: now) {
            list.setPinned(true, pinned.id, now: now)
        }
        list.add("Ask Codex to profile idle CPU with Instruments", source: "com.apple.Safari", now: now)
        list.add("Draft release notes for 0.8", now: now)
        return list
    }()
}
