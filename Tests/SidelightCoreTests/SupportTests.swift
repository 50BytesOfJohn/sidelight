import Foundation
import Testing

@testable import SidelightCore

struct FormattingTests {
    @Test(
        arguments: [
            (0, "0"), (999, "999"), (12_400, "12K"), (4_500_000, "4.5M"), (1_234_567_890, "1.23B"),
        ] as [(Int64, String)])
    func `compact counts`(value: Int64, expected: String) {
        #expect(Formatting.compactCount(value) == expected)
    }

    @Test(
        arguments: [
            (nil, "—", "—"), (30, "0m", "0m"), (12 * 60, "12m", "12m"), (4 * 3_600 + 5 * 60, "4h 5m", "4h"),
            (2 * 86_400 + 3 * 3_600, "2d 3h", "2d"), (-100, "0m", "0m"),
        ] as [(TimeInterval?, String, String)])
    func `countdowns`(offset: TimeInterval?, full: String, leading: String) {
        let now = Date(timeIntervalSince1970: 0)
        let target = offset.map { now.addingTimeInterval($0) }
        #expect(Formatting.countdown(to: target, now: now) == full)
        #expect(Formatting.countdownLeadingUnit(to: target, now: now) == leading)
    }

    @Test func `short countdowns`() {
        let now = Date(timeIntervalSince1970: 0)
        let locale = Locale(identifier: "en_US")
        #expect(Formatting.shortCountdown(to: now, now: now, locale: locale) == "now")
        #expect(Formatting.shortCountdown(to: now.addingTimeInterval(14 * 60), now: now, locale: locale) == "14m")
        #expect(Formatting.shortCountdown(to: now.addingTimeInterval(2 * 3_600), now: now, locale: locale) == "2h")
        #expect(Formatting.shortCountdown(to: now.addingTimeInterval(3 * 86_400), now: now, locale: locale).count == 3)
    }
}

struct ClockReadingTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }()

    @Test(
        arguments: [
            (0, true, "00", nil), (0, false, "12", "AM"), (13, false, "1", "PM"), (12, false, "12", "PM"),
            (9, true, "09", nil),
        ] as [(Int, Bool, String, String?)])
    func `hours`(hour: Int, uses24HourTime: Bool, expectedHour: String, period: String?) throws {
        let date = try #require(
            calendar.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: hour, minute: 7, second: 5)))
        let reading = ClockReading(date: date, uses24HourTime: uses24HourTime, calendar: calendar)
        #expect(reading.hour == expectedHour)
        #expect(reading.minute == "07")
        #expect(reading.second == "05")
        #expect(reading.period == period)
        #expect(reading.minuteOfDay == hour * 60 + 7)
    }
}

struct LineSplitterTests {
    @Test func `splits across chunk boundaries`() {
        var splitter = LineSplitter()
        #expect(splitter.append(Data("ab".utf8)).isEmpty)
        #expect(splitter.append(Data("c\nde\n\nf".utf8)) == [Data("abc".utf8), Data("de".utf8)])
        #expect(splitter.append(Data("g\n".utf8)) == [Data("fg".utf8)])
    }
}

struct CPUTicksTests {
    @Test func `usage is busy over total`() {
        let previous = CPUTicks(user: 100, system: 50, idle: 800, nice: 50)
        let current = CPUTicks(user: 130, system: 60, idle: 850, nice: 60)
        #expect(CPUTicks.usage(from: previous, to: current) == 50)
    }

    @Test func `no elapsed ticks means no reading`() {
        let ticks = CPUTicks(user: 1, system: 1, idle: 1, nice: 1)
        #expect(CPUTicks.usage(from: ticks, to: ticks) == nil)
    }

    @Test func `survives counter wrap-around`() {
        let previous = CPUTicks(user: .max, system: 0, idle: 0, nice: 0)
        let current = CPUTicks(user: 9, system: 0, idle: 10, nice: 0)
        #expect(CPUTicks.usage(from: previous, to: current) == 50)
    }
}

struct ExecutableLocatorTests {
    @Test func `finds executables in the given directories only`() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tool = directory.appending(path: "tool")
        try Data("#!/bin/sh\n".utf8).write(to: tool)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: tool.path(percentEncoded: false))

        #expect(ExecutableLocator.find("tool", in: [directory]) == tool)
        #expect(ExecutableLocator.find("missing", in: [directory]) == nil)
    }
}

struct ChildProcessTests {
    @Test(.timeLimit(.minutes(1)))
    func `streams stdout lines and echoes stdin`() async throws {
        let process = try ChildProcess(executable: URL(filePath: "/bin/cat"), arguments: [])
        process.send(Data("hello".utf8))
        process.send(Data("world\n".utf8))

        var lines: [String] = []
        for await line in process.lines {
            lines.append(String(decoding: line, as: UTF8.self))
            if lines.count == 2 { process.terminate() }
        }
        #expect(lines == ["hello", "world"])
    }

    @Test func `missing executables fail to spawn`() {
        #expect(throws: ChildProcess.SpawnError.self) {
            try ChildProcess(executable: URL(filePath: "/nonexistent/tool"), arguments: [])
        }
    }
}

struct FileWatcherTests {
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func `notices in-place writes and atomic replacements`(atomically: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "config.json")
        try Data("{}".utf8).write(to: file)

        let (changes, continuation) = AsyncStream.makeStream(of: Void.self)
        let watcher = try #require(
            FileWatcher(file: file, queue: DispatchQueue(label: "FileWatcherTests")) { continuation.yield() }
        )

        try Data(#"{"a":1}"#.utf8).write(to: file, options: atomically ? .atomic : [])

        var iterator = changes.makeAsyncIterator()
        #expect(await iterator.next() != nil)
        withExtendedLifetime(watcher) {}
    }
}

struct ClockHandsTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }()

    @Test(
        arguments: [
            (0, 0, 0, 0.0, 0.0, 0.0), (3, 0, 0, 0.25, 0, 0), (15, 30, 45, 3.5 / 12, 0.5, 0.75),
            (23, 45, 0, 11.75 / 12, 0.75, 0),
        ] as [(Int, Int, Int, Double, Double, Double)])
    func `hands point at the time`(
        hour: Int, minute: Int, second: Int, hourTurn: Double, minuteTurn: Double, secondTurn: Double
    ) throws {
        let date = try #require(
            calendar.date(
                from: DateComponents(year: 2026, month: 1, day: 1, hour: hour, minute: minute, second: second)))
        let hands = ClockHands(date: date, calendar: calendar)
        #expect(abs(hands.hour - hourTurn) < 1e-9)
        #expect(hands.minute == minuteTurn)
        #expect(hands.second == secondTurn)
    }
}

struct PixelFontTests {
    @Test func `every glyph is seven rows of one width`() {
        for (character, rows) in PixelFont.glyphs {
            #expect(rows.count == PixelFont.height, "\(character)")
            #expect(Set(rows.map(\.count)).count == 1, "\(character)")
            #expect(rows.allSatisfy { $0.allSatisfy { $0 == "#" || $0 == "." } }, "\(character)")
        }
    }

    @Test func `covers digits and capital letters`() {
        let required = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ :.,-/"
        #expect(required.allSatisfy { PixelFont.glyphs[$0] != nil })
    }

    @Test func `lays glyphs out with a column between them`() {
        let line = PixelLine("12:34")
        // Four 5-wide digits, a 1-wide colon and four gaps.
        #expect(line.columns == 25)
        #expect(line.lit.count + line.unlit.count == 21 * PixelFont.height)
        #expect(line.lit.allSatisfy { (0..<line.columns).contains($0.column) && (0..<line.rows).contains($0.row) })
    }

    @Test func `folds case and accents, and leaves unknown characters blank`() {
        #expect(PixelLine("paź") == PixelLine("PAZ"))
        #expect(PixelLine("Łódź") == PixelLine("LODZ"))
        let unknown = PixelLine("€")
        #expect(unknown.columns == 5)
        #expect(unknown.lit.isEmpty)
    }
}
