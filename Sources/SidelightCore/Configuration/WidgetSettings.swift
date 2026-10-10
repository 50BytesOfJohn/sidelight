import Foundation

/// Every widget Sidelight can show. The raw value is the stable identifier stored in `config.json`.
public enum WidgetKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case clock
    case codex
    case claudeCode
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

    public var id: Self { self }
}

/// Options that mean the same on every face sit at the top; options only one style has sit in that style's own
/// struct, side by side, so switching styles and back loses nothing.
public struct ClockSettings: Codable, Hashable, Sendable {
    public var style: ClockStyle = .digital
    /// Seconds digits, or an analog second hand. Redraws every second instead of every minute.
    public var showsSeconds = false
    /// Digital and pixel faces; an analog dial is always 12-hour.
    public var uses24HourTime = true
    public var analog = AnalogClockOptions()
    public var pixel = PixelClockOptions()

    public init(style: ClockStyle = .digital, showsSeconds: Bool = false, uses24HourTime: Bool = true) {
        self.style = style
        self.showsSeconds = showsSeconds
        self.uses24HourTime = uses24HourTime
    }
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
    public enum Color: String, Codable, CaseIterable, Identifiable, Sendable {
        case amber, green, cyan, red
        /// The panel's text color.
        case text

        public var id: Self { self }
    }

    public var color: Color = .amber
    /// Unlit dots faintly visible, like an LCD.
    public var showsUnlitPixels = true
    /// A soft halo around lit dots, like an LED or CRT.
    public var glows = true

    public init(color: Color = .amber, showsUnlitPixels: Bool = true, glows: Bool = true) {
        self.color = color
        self.showsUnlitPixels = showsUnlitPixels
        self.glows = glows
    }
}

public struct CodexSettings: Codable, Hashable, Sendable {
    public var showsWeeklyLimit = true

    public init(showsWeeklyLimit: Bool = true) {
        self.showsWeeklyLimit = showsWeeklyLimit
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
    case calendar(CalendarSettings)
    case nowPlaying
    case agents
    case system(SystemStatsSettings)

    public var kind: WidgetKind {
        switch self {
        case .clock: .clock
        case .codex: .codex
        case .claudeCode: .claudeCode
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
