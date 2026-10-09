import CoreGraphics
import Foundation
import Testing

@testable import SidelightCore

struct SectionLayoutTests {
    @Test func `one shared section fills the panel`() {
        #expect(lengths([200], [1], available: 1000) == [1000])
    }

    @Test func `equal shares split the free length into halves`() {
        #expect(lengths([100, 300], [1, 1], available: 1000) == [500, 500])
        #expect(lengths([100, 300], [1, 1], available: 1010, spacing: 10) == [500, 500])
    }

    @Test func `shares are weights`() {
        #expect(lengths([0, 0], [1, 3], available: 1000) == [250, 750])
    }

    @Test func `fitting sections keep their content length and leave the rest to shared ones`() {
        #expect(lengths([100, 200], [nil, 1], available: 1000, spacing: 10) == [100, 890])
        #expect(lengths([100, 200], [nil, nil], available: 1000) == [100, 200])
        #expect(lengths([100, 200], [0, 1], available: 1000) == [100, 900])
    }

    @Test func `a section longer than its share keeps its content and the rest is split again`() {
        #expect(lengths([700, 100], [1, 1], available: 1000) == [700, 300])
        let thirds: [CGFloat] = [500, 500.0 / 3, 1000.0 / 3]
        #expect(lengths([500, 0, 0], [1, 1, 2], available: 1000) == thirds)
    }

    @Test func `overflowing content stacks at its natural lengths`() {
        #expect(lengths([600, 600], [1, 1], available: 1000) == [600, 600])
        #expect(lengths([600, 50, 600], [nil, 1, 1], available: 1000) == [600, 50, 600])
    }

    @Test func `fitted panels stack sections at their natural lengths`() {
        #expect(lengths([100, 200, 0], [1, nil, 1], available: 0, spacing: 8) == [100, 200, 0])
    }

    @Test func `total length includes the gaps between sections`() {
        #expect(SectionLayout.totalLength(of: [100, 200, 300], spacing: 10) == 620)
        #expect(SectionLayout.totalLength(of: [], spacing: 10) == 0)
    }

    private func lengths(
        _ content: [CGFloat], _ shares: [Double?], available: CGFloat, spacing: CGFloat = 0
    ) -> [CGFloat] {
        SectionLayout.lengths(content: content, shares: shares, available: available, spacing: spacing)
    }
}

struct VisibleSectionsTests {
    static let sideOnly = WidgetInstance(settings: .agents, showsInSidePanel: true, showsInBar: false)
    static let barOnly = WidgetInstance(settings: .nowPlaying, showsInSidePanel: false, showsInBar: true)

    @Test func `sections whose widgets are all hidden collapse`() {
        var configuration = AppConfiguration()
        configuration.sections = [PanelSection(widgets: [Self.sideOnly]), PanelSection(widgets: [Self.barOnly])]

        #expect(configuration.visibleSections(at: .left, length: .fill).map(\.widgets) == [[Self.sideOnly]])
        #expect(configuration.visibleSections(at: .top, length: .fill).map(\.widgets) == [[Self.barOnly]])
    }

    @Test func `empty shared sections keep their space only while the panel fills its edge`() {
        var configuration = AppConfiguration()
        let spacer = PanelSection()
        let fitting = PanelSection(share: nil)
        configuration.sections = [spacer, fitting, PanelSection(widgets: [Self.sideOnly])]

        #expect(configuration.visibleSections(at: .left, length: .fill).map(\.id).first == spacer.id)
        #expect(configuration.visibleSections(at: .left, length: .fill).count == 2)
        #expect(configuration.visibleSections(at: .left, length: .fit).count == 1)
    }

    @Test func `flattened widgets keep panel order across sections`() {
        var configuration = AppConfiguration()
        configuration.sections = [PanelSection(widgets: [Self.sideOnly]), PanelSection(widgets: [Self.barOnly])]
        #expect(configuration.widgets == [Self.sideOnly, Self.barOnly])
        #expect(configuration.visibleWidgets(at: .bottom) == [Self.barOnly])
    }

    @Test func `a shared section's fraction is its weight over all shared weights`() {
        var configuration = AppConfiguration()
        let top = PanelSection(share: 1)
        let middle = PanelSection(share: nil)
        let bottom = PanelSection(share: 3)
        configuration.sections = [top, middle, bottom]

        #expect(configuration.freeLengthFraction(of: top.id) == 0.25)
        #expect(configuration.freeLengthFraction(of: bottom.id) == 0.75)
        #expect(configuration.freeLengthFraction(of: middle.id) == nil)
    }

    @Test func `the default is one section that fills the panel from the top`() {
        let sections = AppConfiguration().sections
        #expect(sections.count == 1)
        #expect(sections[0].share == 1)
        #expect(sections[0].alignment == .start)
        #expect(sections[0].widgets.map(\.kind) == AppConfiguration.defaultWidgets.map(\.kind))
    }
}

struct SectionRowsTests {
    let clock = WidgetInstance(kind: .clock)
    let codex = WidgetInstance(kind: .codex)
    let calendar = WidgetInstance(kind: .calendar)
    let top = PanelSection(name: "Top", share: 1, alignment: .end)
    let bottom = PanelSection(share: nil)

    var configuration: AppConfiguration {
        var configuration = AppConfiguration()
        var top = top
        top.widgets = [clock, codex]
        var bottom = bottom
        bottom.widgets = [calendar]
        configuration.sections = [top, bottom]
        return configuration
    }

    @Test func `rows list each header before its widgets`() {
        #expect(configuration.sections.rows.map(\.id) == [top.id, clock.id, codex.id, bottom.id, calendar.id])
    }

    @Test func `rows rebuild the same sections`() {
        let sections = configuration.sections
        #expect([PanelSection](rows: sections.rows) == sections)
    }

    @Test func `moving a widget below another header moves it into that section`() {
        var configuration = configuration
        // Rows: top, clock, codex, bottom, calendar. Move clock to the very end.
        configuration.moveRows(fromOffsets: [1], toOffset: 5)
        #expect(configuration.sections.map { $0.widgets.map(\.id) } == [[codex.id], [calendar.id, clock.id]])
        #expect(configuration.sections[0].name == "Top")
        #expect(configuration.sections[0].alignment == .end)
        #expect(configuration.sections[1].share == nil)
    }

    @Test func `a widget moved above the first header joins the first section`() {
        var configuration = configuration
        configuration.moveRows(fromOffsets: [4], toOffset: 0)
        #expect(configuration.sections.map { $0.widgets.map(\.id) } == [[calendar.id, clock.id, codex.id], []])
    }

    @Test func `a widget dropped right above a header ends the section before it`() {
        var configuration = configuration
        configuration.moveRows(fromOffsets: [4], toOffset: 3)
        #expect(configuration.sections.map { $0.widgets.map(\.id) } == [[clock.id, codex.id, calendar.id], []])
    }

    @Test func `dragging a header moves its whole section`() {
        let third = PanelSection(widgets: [WidgetInstance(kind: .system)])
        var configuration = configuration
        configuration.sections.append(third)
        // Rows: top, clock, codex, bottom, calendar, third, system.
        configuration.moveRows(fromOffsets: [0], toOffset: 7)
        #expect(configuration.sections.map(\.id) == [bottom.id, third.id, top.id])
        #expect(configuration.sections[2].widgets == [clock, codex])

        configuration.moveRows(fromOffsets: [4], toOffset: 0)
        #expect(configuration.sections.map(\.id) == [top.id, bottom.id, third.id])

        // Dropped inside another section, it goes after that section.
        configuration.moveRows(fromOffsets: [0], toOffset: 4)
        #expect(configuration.sections.map(\.id) == [bottom.id, top.id, third.id])
    }

    @Test func `inserting at a row lands in the section that row is in`() {
        var configuration = configuration
        let system = WidgetInstance(kind: .system)
        configuration.insertWidgets([system], atRow: 3)
        #expect(
            configuration.sections.map { $0.widgets.map(\.id) } == [[clock.id, codex.id, system.id], [calendar.id]])

        let agents = WidgetInstance(kind: .agents)
        configuration.insertWidgets([agents], atRow: 99)
        #expect(configuration.sections[1].widgets.last == agents)
    }

    @Test func `removing a section hands its widgets to its neighbour`() {
        var configuration = configuration
        configuration.removeSection(bottom.id)
        #expect(configuration.sections.map { $0.widgets.map(\.id) } == [[clock.id, codex.id, calendar.id]])

        var fromFirst = self.configuration
        fromFirst.removeSection(top.id)
        #expect(fromFirst.sections.map { $0.widgets.map(\.id) } == [[clock.id, codex.id, calendar.id]])
        #expect(fromFirst.sections[0].id == bottom.id)
    }

    @Test func `the last section can't be removed`() {
        var configuration = configuration
        configuration.removeSection(bottom.id)
        configuration.removeSection(top.id)
        #expect(configuration.sections.count == 1)
    }

    @Test func `sections move with their widgets`() {
        var configuration = configuration
        configuration.moveSection(bottom.id, by: -1)
        #expect(configuration.sections.map(\.id) == [bottom.id, top.id])
        #expect(configuration.sections[0].widgets == [calendar])
        configuration.moveSection(bottom.id, by: -1)
        #expect(configuration.sections.map(\.id) == [bottom.id, top.id])
    }

    @Test func `widgets are edited, inserted and removed wherever they are`() {
        var configuration = configuration
        configuration.updateWidget(calendar.id) { $0.showsInBar = false }
        #expect(configuration.widget(calendar.id)?.showsInBar == false)

        let copy = clock.duplicated()
        configuration.insertWidget(copy, after: clock.id)
        #expect(configuration.sections[0].widgets.map(\.id) == [clock.id, copy.id, codex.id])

        let system = WidgetInstance(kind: .system)
        configuration.appendWidget(system, toSection: top.id)
        #expect(configuration.section(containing: system.id)?.id == top.id)

        configuration.removeWidget(clock.id)
        #expect(configuration.widget(clock.id) == nil)
    }
}
