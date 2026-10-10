import Foundation

/// A stretch of the panel along its edge with its own widgets, length and alignment. A side panel stacks its
/// sections top to bottom, a bar left to right. The same sections apply on every display and position.
public struct PanelSection: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    /// Shown in the Widgets window only. `nil` reads "Section 1", "Section 2" and so on.
    public var name: String?
    public var widgets: [WidgetInstance]
    /// Share of the panel's free length as a weight (1 and 1 make halves), or `nil` to be as long as its widgets.
    /// Only applies while the panel fills its edge.
    public var share: Double?
    /// Where the widgets sit inside the section along the edge. Only applies while the panel fills its edge.
    public var alignment: PanelAlignment

    public init(
        id: UUID = UUID(),
        name: String? = nil,
        widgets: [WidgetInstance] = [],
        share: Double? = 1,
        alignment: PanelAlignment = .start
    ) {
        self.id = id
        self.name = name
        self.widgets = widgets
        self.share = share
        self.alignment = alignment
    }

    /// Whether the section takes a share of the free length rather than fitting its widgets.
    public var isShared: Bool { (share ?? 0) > 0 }
}

extension PanelSection {
    private enum CodingKeys: String, CodingKey {
        case id, name, widgets, share, alignment
    }

    /// Widgets of kinds that have been removed since they were saved are dropped; any other widget that doesn't
    /// decode still fails the configuration.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            name: try container.decodeIfPresent(String.self, forKey: .name),
            widgets: try container.decode([StoredWidget].self, forKey: .widgets).compactMap(\.widget),
            share: try container.decodeIfPresent(Double.self, forKey: .share),
            alignment: try container.decode(PanelAlignment.self, forKey: .alignment)
        )
    }

    private struct StoredWidget: Decodable {
        let widget: WidgetInstance?

        init(from decoder: any Decoder) throws {
            let kind = try decoder.container(keyedBy: AnyCodingKey.self).decode(
                String.self, forKey: AnyCodingKey("kind"))
            widget = WidgetKind.retiredRawValues.contains(kind) ? nil : try WidgetInstance(from: decoder)
        }
    }
}

/// One row of the Widgets window's list, which shows every section's header followed by its widgets.
public enum PanelRow: Hashable, Identifiable, Sendable {
    /// A section's header. Its widgets are the rows that follow, so the section here has none.
    case section(PanelSection)
    case widget(WidgetInstance)

    public var id: UUID {
        switch self {
        case .section(let section): section.id
        case .widget(let widget): widget.id
        }
    }
}

extension [PanelSection] {
    /// Each section's header followed by its widgets.
    public var rows: [PanelRow] {
        flatMap { section in
            var header = section
            header.widgets = []
            return [.section(header)] + section.widgets.map(PanelRow.widget)
        }
    }

    /// The sections `rows` describe: each widget belongs to the header above it. Widgets above the first header
    /// join the first section, so a row dropped at the very top never leaves the panel.
    public init(rows: [PanelRow]) {
        var sections: [PanelSection] = []
        var orphans: [WidgetInstance] = []
        for row in rows {
            switch row {
            case .section(let section): sections.append(section)
            case .widget(let widget):
                if sections.isEmpty {
                    orphans.append(widget)
                } else {
                    sections[sections.count - 1].widgets.append(widget)
                }
            }
        }
        if sections.isEmpty, !orphans.isEmpty { sections.append(PanelSection()) }
        if !orphans.isEmpty { sections[0].widgets.insert(contentsOf: orphans, at: 0) }
        self = sections
    }
}

// MARK: - Reading and editing widgets across sections

extension AppConfiguration {
    /// Every widget in panel order, across sections.
    public var widgets: [WidgetInstance] { sections.flatMap(\.widgets) }

    public func widget(_ id: WidgetInstance.ID) -> WidgetInstance? {
        widgets.first { $0.id == id }
    }

    public func section(_ id: PanelSection.ID) -> PanelSection? {
        sections.first { $0.id == id }
    }

    /// The section holding the widget with `id`.
    public func section(containing id: WidgetInstance.ID) -> PanelSection? {
        sections.first { $0.widgets.contains { $0.id == id } }
    }

    /// The part of the free length the section with `id` gets while nothing overflows: its weight over all shared
    /// sections' weights. `nil` for a section that fits its widgets.
    public func freeLengthFraction(of id: PanelSection.ID) -> Double? {
        guard let section = section(id), section.isShared, let share = section.share else { return nil }
        return share / sections.filter(\.isShared).reduce(0) { $0 + ($1.share ?? 0) }
    }

    /// The sections a panel at `position` shows, each holding only the widgets visible there.
    ///
    /// A section whose widgets are all hidden at `position` collapses to nothing. An empty section stays while
    /// the panel fills its edge and the section has a share, because its free space is then deliberate.
    public func visibleSections(at position: PanelPosition, length: PanelLength) -> [PanelSection] {
        sections.compactMap { section in
            var visible = section
            visible.widgets = section.widgets.filter { $0.isVisible(at: position) }
            let keepsEmpty = section.widgets.isEmpty && section.isShared && length == .fill
            return visible.widgets.isEmpty && !keepsEmpty ? nil : visible
        }
    }

    /// Edits the widget with `id` in place; does nothing if it was removed meanwhile.
    public mutating func updateWidget(_ id: WidgetInstance.ID, _ change: (inout WidgetInstance) -> Void) {
        for sectionIndex in sections.indices {
            if let index = sections[sectionIndex].widgets.firstIndex(where: { $0.id == id }) {
                change(&sections[sectionIndex].widgets[index])
                return
            }
        }
    }

    /// Edits the section with `id` in place; does nothing if it was removed meanwhile.
    public mutating func updateSection(_ id: PanelSection.ID, _ change: (inout PanelSection) -> Void) {
        guard let index = sections.firstIndex(where: { $0.id == id }) else { return }
        change(&sections[index])
    }

    public mutating func removeWidget(_ id: WidgetInstance.ID) {
        for index in sections.indices {
            sections[index].widgets.removeAll { $0.id == id }
        }
    }

    /// Adds `widget` right after the widget with `id`, or at the end of the last section if there's no such widget.
    public mutating func insertWidget(_ widget: WidgetInstance, after id: WidgetInstance.ID) {
        for sectionIndex in sections.indices {
            if let index = sections[sectionIndex].widgets.firstIndex(where: { $0.id == id }) {
                sections[sectionIndex].widgets.insert(widget, at: index + 1)
                return
            }
        }
        appendWidget(widget)
    }

    /// Adds `widget` at the end of the section with `id`, or of the last section if there's no such section.
    public mutating func appendWidget(_ widget: WidgetInstance, toSection id: PanelSection.ID? = nil) {
        if sections.isEmpty { sections.append(PanelSection()) }
        let index = sections.firstIndex { $0.id == id } ?? sections.count - 1
        sections[index].widgets.append(widget)
    }

    // MARK: Editing through the Widgets window's rows

    /// Reorders the list's rows like SwiftUI's `move(fromOffsets:toOffset:)` and rebuilds the sections from the new
    /// order, so widgets can move between sections.
    ///
    /// Dragging a header moves its whole section, widgets included, to the section boundary at `destination`; any
    /// widget rows dragged along with it stay where they are.
    public mutating func moveRows(fromOffsets source: IndexSet, toOffset destination: Int) {
        let rows = sections.rows
        let movedSections = source.filter(rows.indices.contains).compactMap { index -> PanelSection.ID? in
            if case .section(let section) = rows[index] { section.id } else { nil }
        }
        guard movedSections.isEmpty else {
            // The moved sections go after every other section whose header is above the drop.
            let headersAbove = rows[..<min(max(destination, 0), rows.count)].filter { row in
                if case .section(let section) = row { !movedSections.contains(section.id) } else { false }
            }
            let moved = sections.filter { movedSections.contains($0.id) }
            var remaining = sections.filter { !movedSections.contains($0.id) }
            remaining.insert(contentsOf: moved, at: headersAbove.count)
            sections = remaining
            return
        }
        let moved = source.filter(rows.indices.contains).map { rows[$0] }
        var remaining = rows.indices.filter { !source.contains($0) }.map { rows[$0] }
        let insertion = destination - source.count(in: 0..<min(destination, rows.count))
        remaining.insert(contentsOf: moved, at: min(max(insertion, 0), remaining.count))
        sections = [PanelSection](rows: remaining)
    }

    /// Inserts `widgets` before the list's row at `index` (or at the end), in the section that row is in.
    public mutating func insertWidgets(_ widgets: [WidgetInstance], atRow index: Int) {
        var rows = sections.rows
        rows.insert(contentsOf: widgets.map(PanelRow.widget), at: min(max(index, 0), rows.count))
        sections = [PanelSection](rows: rows)
    }

    // MARK: Editing sections

    /// Appends a new, empty section that takes an equal share of the free length.
    @discardableResult
    public mutating func addSection() -> PanelSection {
        let section = PanelSection()
        sections.append(section)
        return section
    }

    /// Removes the section with `id`, moving its widgets to the end of the section above it, or to the start of
    /// the one below it for the first section. The last remaining section can't be removed.
    public mutating func removeSection(_ id: PanelSection.ID) {
        guard sections.count > 1, let index = sections.firstIndex(where: { $0.id == id }) else { return }
        let removed = sections.remove(at: index)
        if index > 0 {
            sections[index - 1].widgets.append(contentsOf: removed.widgets)
        } else {
            sections[0].widgets.insert(contentsOf: removed.widgets, at: 0)
        }
    }

    /// Moves the section with `id` `offset` places towards the end (negative: towards the start), with its widgets.
    public mutating func moveSection(_ id: PanelSection.ID, by offset: Int) {
        guard let index = sections.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard sections.indices.contains(target) else { return }
        sections.insert(sections.remove(at: index), at: target)
    }
}
