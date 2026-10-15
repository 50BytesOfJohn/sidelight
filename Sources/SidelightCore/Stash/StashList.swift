import Foundation

/// Which items the details panel lists.
public enum StashFilter: String, CaseIterable, Identifiable, Sendable {
    /// Waiting to be used: pinned first, then in queue order, from the end ``StashOrder`` says.
    case open
    /// Done, the most recently done first.
    case done
    /// Open, then done.
    case all

    public var id: Self { self }

    public var title: String {
        switch self {
        case .open: "Open"
        case .done: "Done"
        case .all: "All"
        }
    }
}

/// What each filter lists for a search: the open items, pinned first, and the done ones, most recently done first.
public struct StashMatches: Equatable, Sendable {
    public var open: [StashItem] = []
    public var done: [StashItem] = []

    public init(open: [StashItem] = [], done: [StashItem] = []) {
        self.open = open
        self.done = done
    }

    public subscript(filter: StashFilter) -> [StashItem] {
        switch filter {
        case .open: open
        case .done: done
        case .all: open + done
        }
    }
}

/// Every stashed item, in queue order, as saved in `stash/items.json`. One list for every display and every Stash widget.
///
/// Every change takes the time it happens at, so the logic stays testable and items never read the clock themselves.
public struct StashList: Equatable, Sendable {
    /// The file format this version writes. A file from a later version is read as far as it can be.
    public static let currentVersion = 1
    /// Longer text is refused (see ``isTooLong(_:)``): a stash is for prompts and snippets, and an accidental
    /// select-all of a huge document shouldn't make every save slow.
    public static let maximumTextLength = 100_000

    /// In queue order. Pinned items keep their place here; they're listed first wherever it matters.
    public private(set) var items: [StashItem]
    /// Whether reading the file it came from left something out (an item that couldn't be read, or a later version's
    /// format), so saving over that file would lose it.
    public private(set) var droppedOnLoad = false

    public init(items: [StashItem] = []) {
        self.items = items
    }

    public subscript(id: StashItem.ID) -> StashItem? {
        items.first { $0.id == id }
    }

    /// Open items as the widget lists them: pinned first, then the rest, each in queue order read from `order`'s end.
    public func openItems(_ order: StashOrder) -> [StashItem] {
        Self.listed(items.filter { !$0.isDone }, order)
    }

    /// What every filter lists, matching `search`, in one pass. The item `keeping` (the one being edited) is listed
    /// whether or not it matches the search, so editing it never hides it.
    public func matches(
        search: StashSearch = StashSearch(""), pinnedOnly: Bool = false, keeping kept: StashItem.ID? = nil,
        order: StashOrder = .oldestFirst
    ) -> StashMatches {
        var open: [StashItem] = []
        var done: [StashItem] = []
        for item in items where (!pinnedOnly || item.isPinned) && (item.id == kept || item.matches(search)) {
            if item.isDone { done.append(item) } else { open.append(item) }
        }
        // Most recently done first; the queue order breaks ties, as stable sorting keeps it.
        done.sort { ($0.doneAt ?? .distantPast) > ($1.doneAt ?? .distantPast) }
        return StashMatches(open: Self.listed(open, order), done: done)
    }

    /// Open items as they're listed: pinned first, then the rest, each in queue order read from `order`'s end.
    /// Moving an item into a neighbour's place (``move(_:toPlaceOf:)``) works the same read from either end, so
    /// dragging and the move shortcuts need nothing of their own for the order.
    private static func listed(_ open: [StashItem], _ order: StashOrder) -> [StashItem] {
        let queued = order == .newestFirst ? Array(open.reversed()) : open
        return queued.filter(\.isPinned) + queued.filter { !$0.isPinned }
    }

    // MARK: Changing items

    /// Deletes the items done before `date`. Returns whether any were.
    @discardableResult
    public mutating func removeDone(before date: Date) -> Bool {
        let count = items.count
        items.removeAll { $0.doneAt.map { $0 < date } ?? false }
        return items.count != count
    }

    /// Adds `text` at the end of the queue, trimmed of blank lines and trailing whitespace. Returns the new item, or
    /// `nil` for text with nothing but whitespace or longer than ``maximumTextLength``.
    @discardableResult
    public mutating func add(_ text: String, source: String? = nil, now: Date) -> StashItem? {
        guard let text = Self.normalized(text) else { return nil }
        let item = StashItem(text: text, createdAt: now, source: source)
        items.append(item)
        return item
    }

    /// Puts `item` back at `index` in the queue (or at the end, past it), as undoing its removal does. Nothing
    /// happens if an item with its ID is already there.
    public mutating func restore(_ item: StashItem, at index: Int) {
        guard self[item.id] == nil else { return }
        items.insert(item, at: min(max(index, 0), items.count))
    }

    /// Removes the item, returning it and where it was, to undo with ``restore(_:at:)``.
    @discardableResult
    public mutating func remove(_ id: StashItem.ID) -> (item: StashItem, index: Int)? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        return (items.remove(at: index), index)
    }

    /// Replaces the item's text. Returns whether it changed: text with nothing but whitespace is refused, as removing
    /// the item is up to the caller, and so is text longer than ``maximumTextLength``.
    @discardableResult
    public mutating func setText(_ text: String, of id: StashItem.ID, now: Date) -> Bool {
        guard let text = Self.normalized(text) else { return false }
        return update(id, now: now) { item in
            guard item.text != text else { return false }
            item.text = text
            return true
        }
    }

    /// Pins or unpins the item. Pinning a done item opens it again: pinned items are never done.
    @discardableResult
    public mutating func setPinned(_ isPinned: Bool, _ id: StashItem.ID, now: Date) -> Bool {
        update(id, now: now) { item in
            guard item.isPinned != isPinned else { return false }
            item.isPinned = isPinned
            if isPinned { item.doneAt = nil }
            return true
        }
    }

    /// Marks the item done. Pinned items aren't: they're meant to be used again.
    @discardableResult
    public mutating func markDone(_ id: StashItem.ID, now: Date) -> Bool {
        update(id, now: now) { item in
            guard !item.isPinned, !item.isDone else { return false }
            item.doneAt = now
            return true
        }
    }

    /// Opens a done item again, where it was in the queue.
    @discardableResult
    public mutating func reopen(_ id: StashItem.ID, now: Date) -> Bool {
        update(id, now: now) { item in
            guard item.isDone else { return false }
            item.doneAt = nil
            return true
        }
    }

    /// Moves the item into `target`'s place in the queue: just before it when it was after it, just after it when it
    /// was before it, as dragging it there does. Returns whether it moved.
    @discardableResult
    public mutating func move(_ id: StashItem.ID, toPlaceOf target: StashItem.ID) -> Bool {
        guard id != target, let from = items.firstIndex(where: { $0.id == id }),
            let to = items.firstIndex(where: { $0.id == target })
        else { return false }
        // Taking the item out shifts a target after it one place up, so inserting at `to` lands just after it.
        items.insert(items.remove(at: from), at: to)
        return true
    }

    /// Moves the item one place up (`offset` -1) or down (+1) among `listed`, the items a list shows in its order,
    /// which may leave others out: into the place of its neighbour there. Returns whether it moved.
    @discardableResult
    public mutating func move(_ id: StashItem.ID, by offset: Int, among listed: [StashItem.ID]) -> Bool {
        guard let position = listed.firstIndex(of: id), listed.indices.contains(position + offset) else { return false }
        return move(id, toPlaceOf: listed[position + offset])
    }

    /// Applies `change` to the item, stamping it updated when it reports a change.
    private mutating func update(_ id: StashItem.ID, now: Date, _ change: (inout StashItem) -> Bool) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return false }
        guard change(&items[index]) else { return false }
        items[index].updatedAt = now
        return true
    }

    /// Whether `text`, once trimmed as adding it would, is longer than ``maximumTextLength``, so it would be refused.
    public static func isTooLong(_ text: String) -> Bool {
        // Every character takes at least one UTF-16 unit, and counting those is free: most text needs no more.
        guard text.utf16.count > maximumTextLength else { return false }
        return trimmed(text).map { $0.count > maximumTextLength } ?? false
    }

    /// `text` trimmed, if it fits in ``maximumTextLength``; `nil` if nothing's left or it's too long.
    static func normalized(_ text: String) -> String? {
        guard let trimmed = trimmed(text), trimmed.count <= maximumTextLength else { return nil }
        return trimmed
    }

    /// `text` without its leading blank lines and its trailing whitespace; `nil` if nothing's left. The first line's
    /// indentation stays, as does every other line's: code keeps its shape.
    private static func trimmed(_ text: String) -> String? {
        guard let first = text.firstIndex(where: { !$0.isWhitespace }),
            let last = text.lastIndex(where: { !$0.isWhitespace })
        else { return nil }
        let start = text[..<first].lastIndex(where: \.isNewline).map(text.index(after:)) ?? text.startIndex
        return String(text[start...last])
    }
}

/// Stored as `{"version": 1, "items": [...]}`. An item that can't be read is left out rather than failing the whole
/// file, and noted in ``StashList/droppedOnLoad``, as is a version later than this one writes.
extension StashList: Codable {
    private enum CodingKeys: String, CodingKey {
        case version, items
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        let elements = try container.decode([LenientElement<StashItem>].self, forKey: .items)
        // One item per ID: a duplicate, written by hand, would make the list ambiguous.
        var seen = Set<StashItem.ID>()
        items = elements.compactMap(\.value).filter { seen.insert($0.id).inserted }
        droppedOnLoad = version > Self.currentVersion || items.count != elements.count
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentVersion, forKey: .version)
        try container.encode(items, forKey: .items)
    }

    public init(json: Data) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self = try decoder.decode(StashList.self, from: json)
    }

    /// Pretty-printed with sorted keys, like `config.json`, so the file reads and diffs well.
    public func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    /// Equal lists hold the same items; how they were loaded doesn't count.
    public static func == (lhs: StashList, rhs: StashList) -> Bool {
        lhs.items == rhs.items
    }
}
