import AppKit
import Carbon.HIToolbox
import Observation
import SidelightCore
import SwiftUI

/// What has focus in the stash's details panel.
enum StashField: Hashable {
    case search
    /// The new item's editor, or an item's inline editor: only one is open at a time.
    case editor
    /// The items: the arrows, Tab or a click take focus there, and typing goes back to the search.
    case list
}

/// One editing session in the stash's details panel: what's edited, and a token of its own. Every editor opened is a
/// new session with a new editor view, so nothing of one (its undo history, a late focus report) reaches another.
struct StashEditing: Equatable {
    enum Target: Equatable {
        case new
        case item(StashItem.ID)
    }

    let target: Target
    let token = UUID()
}

/// What someone is doing in the stash's details panel: their search, filter, selection, edit and last deletion.
/// Forgotten when the panel closes, so a deletion can only be undone while it's open. It holds no items itself: the
/// stash changes only through its store.
///
/// It's driven from the keyboard: the window hands it every key press first (see ``handlesKey(_:)``). Shortcuts
/// that edit text belong to the search or the editor while one has focus; the rest work from anywhere.
@Observable
final class StashBrowser {
    let store: StashStore
    var search = ""
    var filter = StashFilter.open
    var pinnedOnly = false
    var selectedID: StashItem.ID? {
        didSet { if selectedID != oldValue { copiedID = nil } }
    }
    private(set) var editing: StashEditing?
    /// The text in the open editor. It's written through to the store as it changes (see
    /// ``editorChanged(_:session:)``).
    private(set) var draft = ""
    /// The last item deleted, and where it was, until it's restored or another is deleted.
    private(set) var lastDeleted: (item: StashItem, index: Int)?
    /// The item the new item's editor created, once it had text: kept out of the list while it's written above it.
    private var composedID: StashItem.ID?
    /// The edited item's text when its editor opened: it's kept while the editor is blank.
    @ObservationIgnored private var originalText = ""
    /// Set to `.list` through ``focusList()`` only, which moves AppKit's focus too.
    var focusedField: StashField? = .search
    /// The details panel's window, as of the last key press.
    @ObservationIgnored private weak var window: NSWindow?
    /// The item just copied, marked as such until the selection moves.
    private(set) var copiedID: StashItem.ID?

    /// The new item's editor was opened from the widget's + button: Esc saves it and closes the panel, back to the
    /// app you were in.
    @ObservationIgnored private var closesAfterComposing = false

    init(store: StashStore, composing: Bool) {
        self.store = store
        if composing { openComposer(closingAfter: true) }
    }

    // MARK: What's listed

    /// The item being edited in its row, listed whatever the search.
    private var editedID: StashItem.ID? {
        if case .item(let id) = editing?.target { id } else { nil }
    }

    /// What every filter lists. Worked out afresh each time: a stash is small, and this runs once per redraw.
    var matches: StashMatches {
        var matches = store.list.matches(
            search: StashSearch(search), pinnedOnly: pinnedOnly, keeping: editedID, order: store.order)
        if let composedID { matches.open.removeAll { $0.id == composedID } }
        return matches
    }

    /// The items listed, in the order the arrows go through them.
    var listed: [StashItem] {
        matches[filter]
    }

    // MARK: Acting on items

    func select(_ id: StashItem.ID) {
        // Focus goes to the list next, not the search.
        if editing != nil, editing?.target != .item(id) { endEditing(focusingSearch: false) }
        selectedID = id
        // The item's own editor keeps focus.
        if editing == nil { focusList() }
    }

    /// Copies the item's text, as written so far if it's being edited.
    func copy(_ id: StashItem.ID) {
        guard let item = store.list[id] else { return }
        SessionHost.copy(item.text)
        selectedID = id
        copiedID = id
    }

    /// Done if it's open, open again if it's done. Pinned items are never done.
    func toggleDone(_ id: StashItem.ID) {
        guard let item = store.list[id] else { return }
        guard !item.isPinned else { return NSSound.beep() }
        keepingPlace(of: id) {
            if item.isDone { store.reopen(id) } else { store.markDone(id) }
        }
    }

    /// Copies the item's text and marks it done.
    func copyAndDone(_ id: StashItem.ID) {
        guard let item = store.list[id] else { return }
        SessionHost.copy(item.text)
        guard !item.isPinned else {
            copiedID = id
            return
        }
        keepingPlace(of: id) { store.markDone(id) }
    }

    func togglePin(_ id: StashItem.ID) {
        guard let item = store.list[id] else { return }
        keepingPlace(of: id) { store.setPinned(!item.isPinned, id) }
    }

    func delete(_ id: StashItem.ID) {
        if editing?.target == .item(id) { endEditing() }
        keepingPlace(of: id) {
            if let deleted = store.delete(id) { lastDeleted = deleted }
        }
    }

    /// Puts the last deleted item back where it was.
    func undoDelete() {
        guard let deleted = lastDeleted else { return }
        lastDeleted = nil
        store.restore(deleted.item, at: deleted.index)
        if listed.contains(where: { $0.id == deleted.item.id }) { selectedID = deleted.item.id }
    }

    /// Runs `change` on the item at `id`; if the selection leaves the list (done under Open, deleted), it moves to the
    /// item that took its place, so the arrows and Return carry on from there. An editor open is closed first, as the
    /// change may hide its row.
    private func keepingPlace(of id: StashItem.ID, _ change: () -> Void) {
        endEditing(focusingSearch: false)
        let before = listed.map(\.id)
        let index = before.firstIndex(of: selectedID ?? id)
        change()
        let after = listed.map(\.id)
        guard let selectedID, !after.contains(selectedID) else { return }
        self.selectedID = index.flatMap { after.isEmpty ? nil : after[min($0, after.count - 1)] }
    }

    /// Moves the item up or down among the open items listed with it, pinned among pinned and the rest among the
    /// rest. Done items keep the order they were done in.
    func moveItem(_ id: StashItem.ID, by offset: Int) {
        guard let item = store.list[id], !item.isDone else { return }
        let group = listed.filter { !$0.isDone && $0.isPinned == item.isPinned }.map(\.id)
        store.move(id, by: offset, among: group)
    }

    /// Drops the dragged item on `target`, taking its place: before it when dragged up, after it when dragged down.
    @discardableResult
    func drop(_ payload: [String], onto target: StashItem.ID) -> Bool {
        guard let id = payload.first.flatMap(UUID.init(uuidString:)), id != target,
            let item = store.list[id], let targetItem = store.list[target],
            !item.isDone, !targetItem.isDone, item.isPinned == targetItem.isPinned
        else { return false }
        store.move(id, toPlaceOf: target)
        selectedID = id
        return true
    }

    // MARK: Editing

    /// Opens the new item's editor at the top of the list, closing any editor open first.
    func compose(closingAfter: Bool) {
        // Focus goes to the new editor, not the search.
        endEditing(focusingSearch: false)
        openComposer(closingAfter: closingAfter)
    }

    private func openComposer(closingAfter: Bool) {
        if filter == .done { filter = .open }
        editing = StashEditing(target: .new)
        draft = ""
        closesAfterComposing = closingAfter
        // The editor takes AppKit's focus itself, once it's in the window (see `StashTextView`).
        focusedField = .editor
    }

    func edit(_ id: StashItem.ID) {
        guard editing?.target != .item(id), let item = store.list[id] else { return }
        // Focus goes to the new editor, not the search.
        endEditing(focusingSearch: false)
        selectedID = id
        editing = StashEditing(target: .item(id))
        draft = item.text
        originalText = item.text
        closesAfterComposing = false
        focusedField = .editor
    }

    /// The editor of session `token` changed: its text goes straight into the store, which saves it shortly. The new
    /// item's editor creates the item with its first text that isn't blank, and takes it back if it's emptied; an
    /// emptied item's editor leaves it as it was. The editor itself refuses text too long to keep.
    func editorChanged(_ text: String, session token: UUID) {
        guard let editing, editing.token == token else { return }
        draft = text
        let isBlank = text.allSatisfy(\.isWhitespace)
        switch editing.target {
        case .new:
            if let id = composedID, store.list[id] != nil {
                if isBlank {
                    store.delete(id)
                    composedID = nil
                } else {
                    store.setText(text, of: id)
                }
            } else if !isBlank, case .success(let item) = store.add(text) {
                composedID = item.id
            }
        case .item(let id):
            store.setText(isBlank ? originalText : text, of: id)
        }
    }

    /// The editor of the session `token` lost focus: clicking out of it closes it. A report from another session's
    /// editor (switched from, or closing) changes nothing.
    func editorDidResign(_ token: UUID) {
        guard editing?.token == token else { return }
        // Focus is already going wherever it was clicked.
        endEditing(focusingSearch: false)
    }

    /// The editor of session `token` went away while its session was still open: something hid its row (marked done
    /// from the widget, say). What it held is in the store already; the session ends after SwiftUI's update that
    /// removed it.
    func editorDidGoAway(_ token: UUID) {
        guard editing?.token == token else { return }
        Task { [weak self] in
            guard let self, editing?.token == token else { return }
            endEditing(focusingSearch: false)
        }
    }

    /// Closes the open editor; what it holds is in the store already. A new item it created is selected, and listed:
    /// the search and filters make way for it if they'd hide it. Gives the search focus unless `focusingSearch` is off.
    func endEditing(focusingSearch: Bool = true) {
        guard let editing else { return }
        let composed = composedID
        self.editing = nil
        composedID = nil
        draft = ""
        originalText = ""
        closesAfterComposing = false
        if editing.target == .new, let composed, store.list[composed] != nil {
            if !listed.contains(where: { $0.id == composed }) {
                search = ""
                pinnedOnly = false
                if filter == .done { filter = .open }
            }
            selectedID = composed
        }
        if focusingSearch { focusSearch() } else { focusedField = .search }
    }

    // MARK: Keyboard

    /// Handles a key press before the window and its fields do. While editing, only ⌘↩ (done) and Esc (done, and
    /// close if the editor was opened from the widget) are taken; everything else, ⌘C included, edits text as usual.
    /// While the search has focus, ⌘⌫ and ⌘Z are its own, even with nothing to delete or undo there, and so is ⌘C
    /// with text selected: deleting and restoring items needs the list's focus. Typing in the list goes to the search.
    func handlesKey(_ event: NSEvent) -> Bool {
        window = event.window
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let keyCode = Int(event.keyCode)
        let isReturn = keyCode == kVK_Return || keyCode == kVK_ANSI_KeypadEnter

        if editing != nil {
            if keyCode == kVK_Escape, flags.isEmpty {
                let closes = editing?.target == .new && closesAfterComposing
                endEditing()
                // Not handled: the window closes the panel, and gives focus back.
                return !closes
            }
            if isReturn, flags == .command {
                endEditing()
                return true
            }
            return false
        }

        // The search field's editor, while it has focus.
        let field = event.window?.firstResponder as? NSTextView
        let isListFocused = isListFocused(in: event.window)
        switch (keyCode, flags) {
        case (kVK_DownArrow, []): return moveSelection(by: 1)
        case (kVK_UpArrow, []):
            // Up from the first item goes back to the search.
            if isListFocused, let selectedID, listed.first?.id == selectedID {
                focusSearch()
                return true
            }
            return moveSelection(by: -1)
        case (kVK_Tab, []), (kVK_Tab, [.shift]):
            if isListFocused {
                focusSearch()
                return true
            }
            return field != nil && flags.isEmpty && moveSelection(by: 0)
        case (kVK_DownArrow, [.option, .command]): return withSelection { moveItem($0, by: 1) }
        case (kVK_UpArrow, [.option, .command]): return withSelection { moveItem($0, by: -1) }
        case (kVK_Delete, [.command]):
            // Deletes to the start of the line in the search: holding it down to clear one never reaches an item.
            guard isListFocused else { return false }
            return withSelection { delete($0) }
        default: break
        }
        if isReturn, flags.isEmpty { return withSelection { toggleDone($0) } }
        if isReturn, flags == .command { return withSelection { copyAndDone($0) } }
        if isListFocused, flags.isDisjoint(with: [.command, .control]),
            let characters = event.charactersIgnoringModifiers, Self.isTyping(characters)
        {
            typeInSearch(event)
            return true
        }

        guard flags == .command, let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        switch key {
        case "c":
            // Text selected in the search field copies as usual.
            if let field, field.selectedRange().length > 0 {
                return false
            }
            return withSelection { copy($0) }
        case "n":
            compose(closingAfter: false)
            return true
        case "e":
            return withSelection { edit($0) }
        case "p":
            return withSelection { togglePin($0) }
        case "f":
            focusSearch()
            return true
        case "z":
            // The search's own undo while it has focus.
            guard isListFocused, lastDeleted != nil else { return false }
            undoDelete()
            return true
        default:
            return false
        }
    }

    /// Runs `action` on the selected item, if it's still listed. Returns whether there was one.
    private func withSelection(_ action: (StashItem.ID) -> Void) -> Bool {
        guard let selectedID, listed.contains(where: { $0.id == selectedID }) else { return false }
        action(selectedID)
        return true
    }

    /// Gives the search focus, in AppKit as well as SwiftUI: what SwiftUI last knew of focus may be stale, after the
    /// editor or the list took it.
    private func focusSearch() {
        focusedField = .search
        guard let window = window ?? NSApp.keyWindow.flatMap({ $0 as? DetailsWindow }),
            let field = Self.searchField(in: window.contentView), window.firstResponder !== field.currentEditor()
        else { return }
        window.makeFirstResponder(field)
    }

    /// Gives the list focus. It's the window's own: whatever had first responder (the search, a button) gives it up,
    /// so typing and the editing shortcuts can't reach a field, whether or not keyboard navigation is on in System
    /// Settings. Asserted on every request, as a button may have taken first responder since the last.
    private func focusList() {
        focusedField = .list
        guard let window = window ?? NSApp.keyWindow.flatMap({ $0 as? DetailsWindow }),
            window.firstResponder !== window
        else { return }
        window.makeFirstResponder(nil)
    }

    /// Moves focus to the search and hands it the key press, so it types there as it would have with focus: Option
    /// characters, dead keys and input methods included.
    private func typeInSearch(_ event: NSEvent) {
        focusedField = .search
        guard let window = event.window, let field = Self.searchField(in: window.contentView),
            window.makeFirstResponder(field), let editor = window.firstResponder as? NSTextView
        else {
            // No field to hand it to: the text it types, as is.
            if let characters = event.characters, Self.isTyping(characters) { search += characters }
            return
        }
        // Taking focus selects the search; typing carries on after it instead.
        editor.moveToEndOfDocument(nil)
        editor.keyDown(with: event)
    }

    /// The search field: while nothing's being edited, the only editable text field in the panel.
    private static func searchField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField, field.isEditable { return field }
        return view.subviews.lazy.compactMap { searchField(in: $0) }.first
    }

    /// Whether the list has focus: it was given it, and nothing (a field, a button) took first responder since.
    private func isListFocused(in window: NSWindow?) -> Bool {
        guard focusedField == .list, let window else { return false }
        return window.firstResponder === window
    }

    /// Moves focus to the list and selects the next or previous item (`offset` 0 keeps it), or the first or last
    /// when none is. Returns whether there was an item; the arrows are taken either way.
    private func moveSelection(by offset: Int) -> Bool {
        let ids = listed.map(\.id)
        guard !ids.isEmpty else { return offset != 0 }
        focusList()
        guard let selectedID, let index = ids.firstIndex(of: selectedID) else {
            self.selectedID = offset >= 0 ? ids.first : ids.last
            return true
        }
        self.selectedID = ids[min(max(index + offset, 0), ids.count - 1)]
        return true
    }

    /// Whether a key press types text, rather than moving or editing.
    private static func isTyping(_ characters: String) -> Bool {
        !characters.isEmpty
            && characters.unicodeScalars.allSatisfy { scalar in
                // Function keys (arrows, F1…) come through as private-use characters.
                !CharacterSet.controlCharacters.contains(scalar) && !(0xF700...0xF8FF).contains(scalar.value)
            }
    }
}

// MARK: - View

/// The whole stash, in the details panel: search, filters, every item with its actions, editing in place, and
/// reordering by dragging or ⌥⌘↑↓.
struct StashDetailsView: View {
    let browser: StashBrowser
    @Environment(StashCapture.self) private var capture
    @Environment(ConfigurationStore.self) private var configuration
    @Environment(SettingsNavigator.self) private var navigator
    @FocusState private var focus: StashField?

    private var store: StashStore { browser.store }

    var body: some View {
        let matches = browser.matches
        VStack(alignment: .leading, spacing: 0) {
            controls(matches)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            HairlineDivider()
            if let session = browser.editing, session.target == .new {
                composer(session)
                    .padding(12)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                HairlineDivider()
            }
            if store.hasSaveFailed {
                saveFailedBar
                HairlineDivider()
            }
            list(matches[browser.filter])
                .frame(maxHeight: .infinity, alignment: .top)
            if let deleted = browser.lastDeleted {
                undoBar(deleted.item)
            }
            HairlineDivider()
            StashKeyHints(isEditing: browser.editing != nil)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
        }
        .animation(Motion.snappy, value: browser.editing)
        .onAppear {
            store.retryReading()
            store.deleteExpiredDone()
            // The editor, when it opens with the panel, takes focus itself.
            if browser.focusedField == .search { focus = .search }
        }
        // SwiftUI's focus is the search's alone: the editor and the list take AppKit's focus themselves, and what
        // SwiftUI reports while they have it isn't acted on.
        .onChange(of: browser.focusedField) { _, field in
            if field == .search { focus = .search }
        }
        .onChange(of: focus) { _, new in
            // Clicked into: the editor, if one was open, saved itself as it lost focus.
            if new == .search, browser.editing == nil, browser.focusedField != .search {
                browser.focusedField = .search
            }
        }
    }

    // MARK: Controls

    private func controls(_ matches: StashMatches) -> some View {
        @Bindable var browser = browser
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    TextField("Search", text: $browser.search)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                        .focused($focus, equals: .search)
                        .accessibilityLabel("Search the stash")
                    if !browser.search.isEmpty {
                        Button {
                            browser.search = ""
                            focus = .search
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .help("Clear the search")
                        .accessibilityLabel("Clear the search")
                    }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.07)))
                controlButton("clipboard", help: "Stash the clipboard") { capture.addClipboard() }
                controlButton("plus", help: "New item (⌘N)") { browser.compose(closingAfter: false) }
            }
            HStack(spacing: 5) {
                ForEach(StashFilter.allCases) { filter in
                    StashFilterTab(
                        title: filter.title, count: matches[filter].count,
                        isSelected: browser.filter == filter
                    ) {
                        browser.endEditing(focusingSearch: false)
                        withAnimation(Motion.snappy) { browser.filter = filter }
                    }
                }
                Spacer(minLength: 4)
                Toggle(isOn: pinnedOnly) {
                    Label("Pinned", systemImage: browser.pinnedOnly ? "pin.fill" : "pin")
                        .font(.system(size: 11, weight: .medium))
                }
                .toggleStyle(.button)
                .buttonStyle(.borderless)
                .help("Only pinned items")
            }
        }
    }

    /// Only pinned items, once an editor open, whose row it may hide, is closed.
    private var pinnedOnly: Binding<Bool> {
        Binding {
            browser.pinnedOnly
        } set: { isOn in
            browser.endEditing(focusingSearch: false)
            withAnimation(Motion.snappy) { browser.pinnedOnly = isOn }
        }
    }

    private func controlButton(_ systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.primary.opacity(0.07)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private func composer(_ session: StashEditing) -> some View {
        StashEditor(browser: browser, session: session, placeholder: "Something to use next…")
    }

    // MARK: List

    /// Redrawn when the stash, the search or the selection changes, and never on a timer: the rows' ages are as of
    /// then.
    @ViewBuilder
    private func list(_ items: [StashItem]) -> some View {
        let now = Date.now
        if items.isEmpty {
            emptyState
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(items) { row($0, now: now) }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                }
                .scrollIndicators(.automatic)
                .onChange(of: browser.selectedID) { _, id in
                    guard let id else { return }
                    withAnimation(Motion.snappy) { proxy.scrollTo(id) }
                }
            }
        }
    }

    private func row(_ item: StashItem, now: Date) -> some View {
        StashDetailsRow(item: item, browser: browser, now: now)
            .id(item.id)
            .transition(.opacity)
    }

    @ViewBuilder
    private var emptyState: some View {
        let options = configuration.configuration.stash
        if store.list.items.isEmpty {
            emptyState(
                "Nothing stashed yet",
                detail: options.captureHint + " ⌘N writes one here.",
                action: ("Change Shortcuts…", navigator.showShortcuts))
        } else if !StashSearch(browser.search).isEmpty {
            emptyState(
                "No matches", detail: "Nothing \(browser.pinnedOnly ? "pinned " : "")contains “\(browser.search)”.")
        } else if browser.pinnedOnly {
            emptyState(
                "Nothing pinned", detail: "Pin what you reuse, with ⌘P: pinned items stay first and never get done.")
        } else {
            switch browser.filter {
            case .open: emptyState("All done", detail: "Nothing open. ⌘N adds an item.")
            case .done, .all:
                let days = options.deleteDoneAfterDays
                emptyState(
                    "Nothing done yet",
                    detail: days == 0
                        ? "Items you check off are kept here."
                        : "Items you check off are kept here for \(days == 1 ? "a day" : "\(days) days").")
            }
        }
    }

    private func emptyState(
        _ title: String, detail: String, action: (title: String, perform: () -> Void)? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 12.5, weight: .medium))
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let action {
                Button(action.title, action: action.perform)
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                    .padding(.top, 2)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The last save failed: what's stashed is kept only while Sidelight runs, until one goes through.
    private var saveFailedBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10.5)).foregroundStyle(.orange)
            Text("Not saved: the stash file can't be read or written, so the stash is kept only while Sidelight runs.")
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            Button("Try Again") { store.flush() }
                .buttonStyle(.borderless)
                .font(.system(size: 11, weight: .medium))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color.orange.opacity(0.08))
    }

    private func undoBar(_ item: StashItem) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "trash").font(.system(size: 10.5)).foregroundStyle(.secondary)
            Text("Deleted “\(item.title)”")
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            Button("Undo") { browser.undoDelete() }
                .buttonStyle(.borderless)
                .font(.system(size: 11, weight: .medium))
                .help("Undo (⌘Z)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.05))
        .transition(.opacity)
    }
}

/// One of Open, Done and All, with how many items it lists.
private struct StashFilterTab: View {
    let title: String
    let count: Int
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                Text(count, format: .number)
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
                    .opacity(isSelected ? 0.8 : 0.55)
                    .contentTransition(.numericText(value: Double(count)))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(isSelected ? Color.accentColor : Color.primary.opacity(0.07)))
            .foregroundStyle(isSelected ? .white : .primary)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue("\(count) items")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A multi-line editor for an editing session: an item's text, or a new one's, written to the stash as it's typed.
/// Return starts a new line; ⌘↩ and Esc close it, and so does clicking out of it. An edit that would make it too long
/// for the stash is refused, and says so under it.
private struct StashEditor: View {
    let browser: StashBrowser
    let session: StashEditing
    let placeholder: String
    @State private var wasRefused = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            StashTextView(
                initialText: browser.draft, token: session.token,
                onChange: { [browser] text, token in
                    wasRefused = false
                    browser.editorChanged(text, session: token)
                },
                onRefuse: { wasRefused = true },
                onResign: { [browser] token in browser.editorDidResign(token) },
                onGone: { [browser] token in browser.editorDidGoAway(token) }
            )
            // A new editor for every session, never one reused from another.
            .id(session.token)
            .frame(height: 96)
            .overlay(alignment: .topLeading) {
                if browser.draft.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.07)))
            if wasRefused {
                Label(
                    "Too long: the stash keeps up to \(StashList.maximumTextLength.formatted()) characters.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.system(size: 10.5))
                .foregroundStyle(.orange)
            }
        }
    }
}

/// A plain-text editor for one editing session, `token`, that owns its focus in AppKit: it takes first responder as
/// soon as it's in a window, and reports losing it with its session's token, so a late report from a session switched
/// from or closed can't end the open one, and SwiftUI's focus, which may still say the search, has no say. It keeps its
/// own undo history, which goes with it, and refuses an edit that would make its text too long for the stash.
///
/// An `NSTextView` rather than a `TextEditor`: SwiftUI gives no way to focus a view the moment it's there, or to refuse
/// an edit before it's made.
private struct StashTextView: NSViewRepresentable {
    let initialText: String
    let token: UUID
    /// Says the text changed, with the session's token.
    let onChange: (_ text: String, _ token: UUID) -> Void
    /// Says an edit was refused, as it would have made the text too long.
    let onRefuse: () -> Void
    let onResign: (UUID) -> Void
    /// Says the editor went away, with the session's token.
    let onGone: (UUID) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = FocusingTextView(frame: .zero)
        textView.token = token
        textView.onResign = onResign
        textView.string = initialText
        textView.delegate = context.coordinator
        textView.font = .systemFont(ofSize: 12.5)
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        // Prompts and code stay as typed.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.setAccessibilityLabel("Item text")

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.view = self
        (scrollView.documentView as? FocusingTextView)?.onResign = onResign
    }

    /// Says it's going, in case its session is still open (its row was hidden): no longer able to report losing
    /// focus, it can't end the session any other way.
    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.undoManager.removeAllActions()
        guard let textView = scrollView.documentView as? FocusingTextView, let token = textView.token else { return }
        textView.token = nil
        coordinator.view.onGone(token)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var view: StashTextView
        /// The session's own undo history, apart from the window's and the search's.
        let undoManager = UndoManager()

        init(_ view: StashTextView) {
            self.view = view
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            view.onChange(textView.string, view.token)
        }

        /// Refuses an edit that would make the text too long for the stash, rather than taking text it can't keep.
        func textView(
            _ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?
        ) -> Bool {
            guard let replacementString else { return true }
            let text = textView.string as NSString
            // Every character takes at least one UTF-16 unit: most edits need no closer look.
            guard text.length - range.length + (replacementString as NSString).length > StashList.maximumTextLength
            else { return true }
            guard StashList.isTooLong(text.replacingCharacters(in: range, with: replacementString)) else { return true }
            NSSound.beep()
            view.onRefuse()
            return false
        }

        func undoManager(for view: NSTextView) -> UndoManager? {
            undoManager
        }
    }
}

/// Takes first responder once it's in a window, and says when it gives it up, with its session's token: unless the
/// editor taking it is one for the same session, as when SwiftUI rebuilds it.
private final class FocusingTextView: NSTextView {
    var token: UUID?
    var onResign: (UUID) -> Void = { _ in }
    /// The editor taking first responder right now, while the one that had it resigns.
    private static weak var takingFocus: FocusingTextView?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        takeFocus()
    }

    func takeFocus() {
        guard let window, window.firstResponder !== self else { return }
        Self.takingFocus = self
        defer { Self.takingFocus = nil }
        window.makeFirstResponder(self)
    }

    override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        if let token, Self.takingFocus?.token != token { onResign(token) }
        return true
    }
}

/// One item in the details panel: done or pinned at the start, its app, its text and when it was added or done. Click
/// selects, double-click edits, drag reorders, and its menu has everything.
private struct StashDetailsRow: View {
    let item: StashItem
    let browser: StashBrowser
    let now: Date
    @State private var isHovered = false

    private var isSelected: Bool { browser.selectedID == item.id }
    private var isEditing: Bool { browser.editing?.target == .item(item.id) }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            leadingMark
            StashAppIcon(bundleID: item.source, size: 15)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                if let session = browser.editing, session.target == .item(item.id) {
                    StashEditor(browser: browser, session: session, placeholder: "Text")
                } else {
                    Text(item.text)
                        .font(.system(size: 12.5))
                        .lineLimit(isSelected ? 12 : 3)
                        .foregroundStyle(item.isDone ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    status
                }
            }
            if !isEditing, isHovered || isSelected {
                Button {
                    browser.copy(item.id)
                } label: {
                    Image(systemName: browser.copiedID == item.id ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 20)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("Copy (⌘C)")
                .accessibilityLabel("Copy")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                // Stronger while the list has focus, so it's clear what ⌘⌫ and ⌘Z act on.
                .fill(isSelected ? Color.accentColor.opacity(browser.focusedField == .list ? 0.22 : 0.12) : .clear)
        )
        .hoverHighlight(isEnabled: !isSelected, cornerRadius: 9, opacity: 0.05, vertical: 0)
        .onHover { isHovered = $0 }
        .modifier(StashRowInteraction(item: item, browser: browser, isEnabled: !isEditing))
        .contextMenu { menu }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityActions { menu }
    }

    /// Done's checkbox, or a pin for pinned items, which are never done.
    @ViewBuilder
    private var leadingMark: some View {
        if item.isPinned {
            Button {
                browser.togglePin(item.id)
            } label: {
                Image(systemName: "pin.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.orange)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .help("Unpin (⌘P)")
            .accessibilityLabel("Unpin")
        } else {
            Button {
                browser.toggleDone(item.id)
            } label: {
                Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(item.isDone ? Color.green : Color.secondary)
                    .frame(width: 16, height: 16)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .help(item.isDone ? "Open again (↩)" : "Done (↩)")
            .accessibilityLabel(item.isDone ? "Open again" : "Done")
        }
    }

    /// `Copied`, `Done 3d`, `Added 2h`.
    private var status: some View {
        let text =
            if browser.copiedID == item.id {
                "Copied"
            } else if let doneAt = item.doneAt {
                "Done \(Formatting.shortAge(since: doneAt, now: now))"
            } else {
                "Added \(Formatting.shortAge(since: item.createdAt, now: now))"
            }
        return Text(text)
            .font(.system(size: 10))
            .monospacedDigit()
            .foregroundStyle(.tertiary)
    }

    @ViewBuilder
    private var menu: some View {
        Button("Copy") { browser.copy(item.id) }
        if !item.isPinned {
            Button("Copy & Done") { browser.copyAndDone(item.id) }
            Button(item.isDone ? "Open Again" : "Done") { browser.toggleDone(item.id) }
        }
        Button(item.isPinned ? "Unpin" : "Pin") { browser.togglePin(item.id) }
        Button("Edit") { browser.edit(item.id) }
        Divider()
        Button("Delete", role: .destructive) { browser.delete(item.id) }
    }
}

/// Click selects, double-click edits, and open items drag onto each other to reorder. While the row is being edited
/// its taps are off, and the editor takes its own clicks and drags, to select text.
private struct StashRowInteraction: ViewModifier {
    let item: StashItem
    let browser: StashBrowser
    let isEnabled: Bool

    /// One structure whether or not it's on: switching between two would rebuild the row, and the one fading out
    /// would hold a second editor for the same item while it went.
    func body(content: Content) -> some View {
        // Off, the row's own taps are, but not its editor's.
        let gestures: GestureMask = isEnabled ? .all : .subviews
        return
            content
            .contentShape(.rect)
            .gesture(TapGesture(count: 2).onEnded { browser.edit(item.id) }, including: gestures)
            .simultaneousGesture(TapGesture().onEnded { browser.select(item.id) }, including: gestures)
            .draggable(item.id.uuidString)
            .dropDestination(for: String.self) { payload, _ in
                withAnimation(Motion.layout) { _ = browser.drop(payload, onto: item.id) }
            }
    }
}

/// The keys the panel answers to, along its bottom edge.
private struct StashKeyHints: View {
    let isEditing: Bool

    private var hints: [(key: String, action: String)] {
        isEditing
            ? [("⌘↩", "Save"), ("Esc", "Save and leave"), ("↩", "New line")]
            : [
                ("↑↓", "Select"), ("↩", "Done"), ("⌘C", "Copy"), ("⌘↩", "Copy & Done"), ("⌘E", "Edit"),
                ("⌘P", "Pin"), ("⌘N", "New"), ("⌘⌫", "Delete"), ("⌥⌘↑↓", "Move"),
            ]
    }

    var body: some View {
        hints.enumerated().reduce(Text(verbatim: "")) { text, element in
            let separator = element.offset == 0 ? "" : "   "
            return Text(
                "\(text)\(separator)\(Text(element.element.key).fontWeight(.semibold)) \(element.element.action)")
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityHidden(true)
    }
}
