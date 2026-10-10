import Foundation

/// Every widget Sidelight can show. The raw value is the stable identifier stored in `config.json`.
public enum WidgetKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case clock
    case codex
    case claudeCode
    case cursor
    case calendar
    case nowPlaying
    case agents
    case system

    public var id: Self { self }
}

/// A clock's look. Each style draws the same time its own way.
public enum ClockStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case digital
    case analog
    /// Dot-matrix digits, like an old LCD or LED display.
    case pixel
    /// Digits on split-flap tiles, like a flip clock or a station board.
    case flip
    /// The time in English words: "nine past ten".
    case words
    /// Binary-coded decimal: a column of dots per digit.
    case binary

    public var id: Self { self }

    /// Faces that can show seconds; a time in words can't.
    public var showsSecondsOption: Bool { self != .words }
}

/// Where a clock sits in its card, and which way its lines of time and date line up.
public enum ClockAlignment: String, Codable, CaseIterable, Identifiable, Sendable {
    case leading, center, trailing

    public var id: Self { self }
}

/// Options that mean the same on every face sit at the top; options only one style has sit in that style's own
/// struct, side by side, so switching styles and back loses nothing.
public struct ClockSettings: Codable, Hashable, Sendable {
    public var style: ClockStyle = .digital
    /// Seconds digits, or an analog second hand. Redraws every second instead of every minute.
    public var showsSeconds = false
    /// Faces that show digits; analog dials and words are always 12-hour.
    public var uses24HourTime = true
    /// Regular and compact cards. Narrow columns always center the clock, and bar chips fit it.
    public var alignment: ClockAlignment = .leading
    public var analog = AnalogClockOptions()
    public var pixel = PixelClockOptions()
    public var flip = FlipClockOptions()
    public var words = WordClockOptions()
    public var binary = BinaryClockOptions()

    public init(
        style: ClockStyle = .digital, showsSeconds: Bool = false, uses24HourTime: Bool = true,
        alignment: ClockAlignment = .leading
    ) {
        self.style = style
        self.showsSeconds = showsSeconds
        self.uses24HourTime = uses24HourTime
        self.alignment = alignment
    }

    /// Missing options take their defaults, so a clock saved before an option existed still loads, and keeps
    /// the leading alignment every clock had before it could be chosen.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ClockSettings()
        style = try container.decodeIfPresent(ClockStyle.self, forKey: .style) ?? defaults.style
        showsSeconds = try container.decodeIfPresent(Bool.self, forKey: .showsSeconds) ?? defaults.showsSeconds
        uses24HourTime = try container.decodeIfPresent(Bool.self, forKey: .uses24HourTime) ?? defaults.uses24HourTime
        alignment = try container.decodeIfPresent(ClockAlignment.self, forKey: .alignment) ?? defaults.alignment
        analog = try container.decodeIfPresent(AnalogClockOptions.self, forKey: .analog) ?? defaults.analog
        pixel = try container.decodeIfPresent(PixelClockOptions.self, forKey: .pixel) ?? defaults.pixel
        flip = try container.decodeIfPresent(FlipClockOptions.self, forKey: .flip) ?? defaults.flip
        words = try container.decodeIfPresent(WordClockOptions.self, forKey: .words) ?? defaults.words
        binary = try container.decodeIfPresent(BinaryClockOptions.self, forKey: .binary) ?? defaults.binary
    }

    /// Whether the face shows seconds, and so redraws every second.
    public var showsSecondsOnFace: Bool { showsSeconds && style.showsSecondsOption }
}

/// Colors for faces drawn in light: pixel and binary dots.
public enum ClockColor: String, Codable, CaseIterable, Identifiable, Sendable {
    case amber, green, cyan, red
    /// The panel's text color.
    case text

    public var id: Self { self }
}

public struct AnalogClockOptions: Codable, Hashable, Sendable {
    public enum Dial: String, Codable, CaseIterable, Identifiable, Sendable {
        /// Hour and minute ticks.
        case ticks
        /// Hour numerals.
        case numerals
        /// A mark at each quarter only.
        case minimal

        public var id: Self { self }
    }

    public var dial: Dial = .ticks
    /// Weekday and date next to the dial.
    public var showsDate = true

    public init(dial: Dial = .ticks, showsDate: Bool = true) {
        self.dial = dial
        self.showsDate = showsDate
    }
}

public struct PixelClockOptions: Codable, Hashable, Sendable {
    public var color: ClockColor = .amber
    /// Unlit dots faintly visible, like an LCD.
    public var showsUnlitPixels = true
    /// A soft halo around lit dots, like an LED or CRT.
    public var glows = true

    public init(color: ClockColor = .amber, showsUnlitPixels: Bool = true, glows: Bool = true) {
        self.color = color
        self.showsUnlitPixels = showsUnlitPixels
        self.glows = glows
    }
}

public struct FlipClockOptions: Codable, Hashable, Sendable {
    public enum Tiles: String, Codable, CaseIterable, Identifiable, Sendable {
        /// Light digits on dark tiles, the classic look.
        case graphite
        /// Dark digits on cream tiles.
        case paper
        /// Translucent tiles in the panel's text color, blending with any background.
        case smoke

        public var id: Self { self }
    }

    public var tiles: Tiles = .graphite
    /// The date under the tiles, or the weekday in narrow columns and bars.
    public var showsDate = true

    public init(tiles: Tiles = .graphite, showsDate: Bool = true) {
        self.tiles = tiles
        self.showsDate = showsDate
    }
}

public struct WordClockOptions: Codable, Hashable, Sendable {
    public enum Typeface: String, Codable, CaseIterable, Identifiable, Sendable {
        case serif, sans, rounded

        public var id: Self { self }
    }

    public var typeface: Typeface = .serif
    /// To the nearest five minutes, like a word clock on the wall: "ten past ten" until 10:12.
    public var roundsToFiveMinutes = false
    /// The date under the words, or the weekday in narrow columns and bars.
    public var showsDate = true

    public init(typeface: Typeface = .serif, roundsToFiveMinutes: Bool = false, showsDate: Bool = true) {
        self.typeface = typeface
        self.roundsToFiveMinutes = roundsToFiveMinutes
        self.showsDate = showsDate
    }
}

public struct BinaryClockOptions: Codable, Hashable, Sendable {
    public var color: ClockColor = .cyan
    /// The decimal digit under each column, to learn to read it.
    public var showsDigits = true

    public init(color: ClockColor = .cyan, showsDigits: Bool = true) {
        self.color = color
        self.showsDigits = showsDigits
    }
}

public struct CodexSettings: Codable, Hashable, Sendable {
    /// Whether limits read as what's left, the way Codex's own `/status` puts it, or as what's used.
    public enum LimitReading: String, Codable, CaseIterable, Identifiable, Sendable {
        case remaining, used

        public var id: Self { self }
    }

    /// The longer of two limits, normally the week.
    public var showsWeeklyLimit = true
    public var limitReading = LimitReading.remaining
    /// Tokens per day and in total, in the regular layout.
    public var showsTokenHistory = true

    public init(
        showsWeeklyLimit: Bool = true, limitReading: LimitReading = .remaining, showsTokenHistory: Bool = true
    ) {
        self.showsWeeklyLimit = showsWeeklyLimit
        self.limitReading = limitReading
        self.showsTokenHistory = showsTokenHistory
    }

    /// Missing options take their defaults, so settings saved before an option existed still load. So does an
    /// unknown reading, rather than failing the whole configuration.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = CodexSettings()
        showsWeeklyLimit =
            try container.decodeIfPresent(Bool.self, forKey: .showsWeeklyLimit) ?? defaults.showsWeeklyLimit
        limitReading =
            (try? container.decodeIfPresent(LimitReading.self, forKey: .limitReading)) ?? defaults.limitReading
        showsTokenHistory =
            try container.decodeIfPresent(Bool.self, forKey: .showsTokenHistory) ?? defaults.showsTokenHistory
    }
}

public struct ClaudeCodeSettings: Codable, Hashable, Sendable {
    /// What the settings editor offers for ``refreshMinutes``.
    public static let refreshMinuteChoices = [2, 5, 15, 30]

    public var showsWeeklyLimit = true
    /// Ask Anthropic for the plan's usage every ``refreshMinutes``, signed in as Claude Code is. Off by default:
    /// it reads Claude Code's sign-in from the keychain and calls an undocumented endpoint.
    public var refreshesFromAnthropic = false
    public var refreshMinutes = 5

    public init(showsWeeklyLimit: Bool = true, refreshesFromAnthropic: Bool = false, refreshMinutes: Int = 5) {
        self.showsWeeklyLimit = showsWeeklyLimit
        self.refreshesFromAnthropic = refreshesFromAnthropic
        self.refreshMinutes = refreshMinutes
    }

    /// Missing options take their defaults, so settings saved before an option existed still load.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ClaudeCodeSettings()
        showsWeeklyLimit =
            try container.decodeIfPresent(Bool.self, forKey: .showsWeeklyLimit) ?? defaults.showsWeeklyLimit
        refreshesFromAnthropic =
            try container.decodeIfPresent(Bool.self, forKey: .refreshesFromAnthropic) ?? defaults.refreshesFromAnthropic
        refreshMinutes = max(
            1, try container.decodeIfPresent(Int.self, forKey: .refreshMinutes) ?? defaults.refreshMinutes)
    }
}

public struct CursorSettings: Codable, Hashable, Sendable {
    /// What the settings editor offers for ``refreshMinutes``.
    public static let refreshMinuteChoices = [5, 15, 30, 60]

    /// Ask Cursor for the account's usage every ``refreshMinutes``, signed in as the Cursor app or CLI is. Cursor
    /// keeps usage nowhere on this Mac, so the widget shows nothing without it; it's still off until the user turns
    /// it on, since it reads Cursor's sign-in and calls an undocumented endpoint.
    public var refreshesFromCursor = false
    /// Included usage moves slowly over a month, so the default is gentle.
    public var refreshMinutes = 15
    /// On-demand spending past the included usage, when it's turned on for the account.
    public var showsOnDemand = true

    public init(refreshesFromCursor: Bool = false, refreshMinutes: Int = 15, showsOnDemand: Bool = true) {
        self.refreshesFromCursor = refreshesFromCursor
        self.refreshMinutes = refreshMinutes
        self.showsOnDemand = showsOnDemand
    }

    /// Missing options take their defaults, so settings saved before an option existed still load.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = CursorSettings()
        refreshesFromCursor =
            try container.decodeIfPresent(Bool.self, forKey: .refreshesFromCursor) ?? defaults.refreshesFromCursor
        refreshMinutes = max(
            1, try container.decodeIfPresent(Int.self, forKey: .refreshMinutes) ?? defaults.refreshMinutes)
        showsOnDemand = try container.decodeIfPresent(Bool.self, forKey: .showsOnDemand) ?? defaults.showsOnDemand
    }
}

public struct CalendarSettings: Codable, Hashable, Sendable {
    /// What the settings editor offers.
    public static let eventCountRange = 1...10

    /// Number of upcoming events listed.
    public var eventCount = 3

    public init(eventCount: Int = 3) {
        self.eventCount = eventCount
    }
}

public struct SystemStatsSettings: Codable, Hashable, Sendable {
    public enum Metrics: String, Codable, CaseIterable, Identifiable, Sendable {
        case both, cpu, memory

        public var id: Self { self }
        public var includesCPU: Bool { self != .memory }
        public var includesMemory: Bool { self != .cpu }
    }

    public var metrics: Metrics = .both

    public init(metrics: Metrics = .both) {
        self.metrics = metrics
    }
}

/// A widget's kind together with the settings that apply to that kind only.
public enum WidgetSettings: Hashable, Sendable {
    case clock(ClockSettings)
    case codex(CodexSettings)
    case claudeCode(ClaudeCodeSettings)
    case cursor(CursorSettings)
    case calendar(CalendarSettings)
    case nowPlaying
    case agents
    case system(SystemStatsSettings)

    public var kind: WidgetKind {
        switch self {
        case .clock: .clock
        case .codex: .codex
        case .claudeCode: .claudeCode
        case .cursor: .cursor
        case .calendar: .calendar
        case .nowPlaying: .nowPlaying
        case .agents: .agents
        case .system: .system
        }
    }

    public static func defaults(for kind: WidgetKind) -> WidgetSettings {
        switch kind {
        case .clock: .clock(ClockSettings())
        case .codex: .codex(CodexSettings())
        case .claudeCode: .claudeCode(ClaudeCodeSettings())
        case .cursor: .cursor(CursorSettings())
        case .calendar: .calendar(CalendarSettings())
        case .nowPlaying: .nowPlaying
        case .agents: .agents
        case .system: .system(SystemStatsSettings())
        }
    }
}

/// One widget placed in the panel.
public struct WidgetInstance: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var settings: WidgetSettings
    /// Shown when the panel sits on the left or right edge.
    public var showsInSidePanel: Bool
    /// Shown when the panel is a top or bottom bar.
    public var showsInBar: Bool

    public init(
        id: UUID = UUID(),
        settings: WidgetSettings,
        showsInSidePanel: Bool = true,
        showsInBar: Bool = true
    ) {
        self.id = id
        self.settings = settings
        self.showsInSidePanel = showsInSidePanel
        self.showsInBar = showsInBar
    }

    public init(kind: WidgetKind) {
        self.init(settings: .defaults(for: kind))
    }

    public var kind: WidgetKind { settings.kind }

    public var isHidden: Bool { !showsInSidePanel && !showsInBar }

    public func isVisible(at position: PanelPosition) -> Bool {
        position.isBar ? showsInBar : showsInSidePanel
    }

    /// A copy with the same settings and placement but a new identity.
    public func duplicated() -> WidgetInstance {
        WidgetInstance(settings: settings, showsInSidePanel: showsInSidePanel, showsInBar: showsInBar)
    }
}
