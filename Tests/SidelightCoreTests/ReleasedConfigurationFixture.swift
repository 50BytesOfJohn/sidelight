import Foundation
import Testing

@testable import SidelightCore

/// Writes the configuration ``ReleasedConfigurationTests`` keeps loading, for the release about to be cut: every
/// widget, with every option set away from its default wherever the schema allows. Off unless asked for:
///
///     SIDELIGHT_RELEASE_FIXTURE=v0.5.0 make test
///
/// writes `ReleasedConfigurations/v0.5.0.json`; add the version to ``ReleasedConfigurationTests/releases`` and
/// commit both. When a widget gains an option, set it here too, so the next release's file has it.
struct ReleasedConfigurationFixture {
    static let release = ProcessInfo.processInfo.environment["SIDELIGHT_RELEASE_FIXTURE"]

    @Test(.enabled(if: release != nil))
    func `write this version's configuration`() throws {
        var c = Self.base()
        c.appearance.cards.showsTitles = false
        var clock = ClockSettings(style: .flip, showsSeconds: true, uses24HourTime: false, alignment: .trailing)
        clock.analog = AnalogClockOptions(dial: .numerals, showsDate: false)
        clock.pixel = PixelClockOptions(color: .green, showsUnlitPixels: false, glows: false)
        clock.flip = FlipClockOptions(tiles: .paper, showsDate: false)
        clock.words = WordClockOptions(typeface: .rounded, roundsToFiveMinutes: true, showsDate: false)
        clock.binary = BinaryClockOptions(color: .red, showsDigits: false)
        var words = ClockSettings(style: .words, alignment: .center)
        words.words = WordClockOptions(typeface: .sans, roundsToFiveMinutes: true, showsDate: true)

        let work = Account(
            id: AccountID(rawValue: Self.id(701).uuidString), provider: .openRouter, name: "Work", kind: .key)
        let personal = Account(
            id: AccountID(rawValue: Self.id(702).uuidString), provider: .openRouter, name: "Personal", kind: .key)
        let token = Account(
            id: AccountID(rawValue: Self.id(703).uuidString), provider: .railway, name: "Acme token", kind: .key)
        let claude = Account(
            id: AccountID(rawValue: Self.id(704).uuidString), provider: .claudeCode, name: "Work Claude",
            kind: .appProfile, folder: "/Users/example/.claude-work")
        c.accounts = [work, personal, token, claude]
        c.defaultAccounts = [.openRouter: work.id, .railway: .railwayCLI, .claudeCode: claude.id]
        var railway = RailwaySettings(
            account: token.id, refreshMinutes: 15,
            blocks: BlockLayout(entries: [
                .init(block: .usage, isShown: true), .init(block: .summary, isShown: true),
                .init(block: .service(Self.id(501)), isShown: true), .init(block: .services, isShown: false),
                .init(block: .incidents, isShown: true),
            ]),
            glance: .usage)
        railway.workspaceID = "ws-7f3a"
        railway.workspaceName = "Acme"
        railway.projectID = "proj-1b2c"
        railway.projectName = "Storefront"
        railway.environmentName = "staging"
        railway.blockOptions.summary = RailwaySummaryOptions(showsWorkspace: false)
        railway.blockOptions.services = RailwayServicesOptions(
            order: .recent, showsCommit: false, showsSleeping: false, maximumRows: 12)
        railway.blockOptions.usage = RailwayUsageOptions(showsEstimate: false, showsLimit: false)
        railway.blockOptions.incidents = RailwayIncidentsOptions(showsMaintenance: false)
        var serviceBlock = RailwayServiceBlockOptions(projectID: "proj-1b2c", serviceID: "svc-9d8e", serviceName: "api")
        serviceBlock.showsCommit = false
        serviceBlock.showsMetrics = false
        serviceBlock.showsHistory = false
        railway.setServiceOptions(serviceBlock, for: Self.id(501))
        let personalClaude = AIUsageBlock(.claudeCode, uuid: Self.id(601))
        let workClaude = AIUsageBlock(.claudeCode, uuid: Self.id(602))
        var aiUsage = AIUsageSettings(
            reading: .remaining, showsOtherLimits: false, refreshesClaudeFromAnthropic: true,
            claudeRefreshMinutes: 15, refreshesCursor: true, cursorRefreshMinutes: 60)
        aiUsage.blocks = BlockLayout(entries: [
            .init(block: workClaude, isShown: true), .init(block: .codex, isShown: true),
            .init(block: personalClaude, isShown: true), .init(block: .cursor, isShown: false),
        ])
        aiUsage.setOptions(AIUsageBlockOptions(label: "Work", account: claude.id), for: workClaude)
        aiUsage.setOptions(AIUsageBlockOptions(label: "Personal", variant: .eachLimit), for: personalClaude)
        var cliRailway = RailwaySettings(account: .railwayCLI)
        cliRailway.blocks.setShown(.incidents, false)

        var codexSessions = CodexSessionsSettings(
            recentHours: 12, includesExec: true,
            blocks: BlockLayout(entries: [
                .init(block: .limits, isShown: true), .init(block: .sessions, isShown: true),
                .init(block: .spotlight, isShown: false),
            ]))
        codexSessions.blockOptions.spotlight = CodexSpotlightOptions(
            showsPlan: false, showsDetails: false, showsLastMessage: false)
        codexSessions.blockOptions.sessions = CodexSessionListOptions(maximumRows: 3, showsBranch: false)
        codexSessions.blockOptions.limits = CodexSessionLimitsOptions(reading: .used, showsWeeklyLimit: false)
        var models = OpenRouterSettings(sync: .manual, glance: .count, preset: .textOnly)
        models.summary.filter = .textOnly
        models.setListOptions(
            .init(
                title: "Price watch", sort: .outputPrice, filter: .all, density: .detail,
                maximumRows: 12, showsRetiring: false),
            for: OpenRouterPreset.textOnly.listID!)
        models.blocks.add(.list(Self.id(502)))
        models.setListOptions(
            .init(title: "Small", sort: .context, filter: .textOnly, density: .lean, maximumRows: 3),
            for: Self.id(502))
        var credits = OpenRouterSettings(refresh: .manual, glance: .balance, preset: .credits)
        credits.setBalanceOptions(
            .init(
                title: "Work",
                chart: .init(
                    isShown: false, days: 30, scope: .key,
                    keyHash: String(repeating: "a", count: 64), keyName: "Build fixture")),
            for: OpenRouterPreset.balanceID)
        credits.blocks.add(.balance(Self.id(503)))
        credits.setBalanceOptions(.init(title: "Personal", account: personal.id), for: Self.id(503))
        c.details = DetailsPanelSettings(usesCustomStyle: true, customBackground: c.appearance.background)
        c.details.closeHotkey = Hotkey(keyCode: 49, modifiers: [.control, .command], key: "Space")
        c.sections = [
            PanelSection(
                id: Self.id(901), name: "Work",
                widgets: [
                    Self.widget(1, .clock(clock)),
                    Self.widget(
                        2,
                        .codex(CodexSettings(showsWeeklyLimit: false, limitReading: .used, showsTokenHistory: false)),
                        bar: false),
                    Self.widget(
                        3,
                        .claudeCode(
                            ClaudeCodeSettings(
                                account: claude.id, showsWeeklyLimit: false, refreshesFromAnthropic: true,
                                refreshMinutes: 15))),
                    Self.widget(
                        4, .cursor(CursorSettings(refreshesFromCursor: true, refreshMinutes: 30, showsOnDemand: false))),
                ], share: 2, alignment: .center),
            PanelSection(
                id: Self.id(902), name: nil,
                widgets: [
                    Self.widget(
                        5,
                        .aiUsage(aiUsage)),
                    Self.widget(6, .calendar(CalendarSettings(eventCount: 7))),
                    Self.widget(7, .nowPlaying, side: false),
                    Self.widget(8, .claudeSessions(ClaudeSessionsSettings(sessionCount: 8, recentHours: 12))),
                    Self.widget(9, .system(SystemStatsSettings(metrics: .cpu))),
                    Self.widget(10, .clock(words), bar: false),
                ], share: nil, alignment: .end),
            PanelSection(
                id: Self.id(903), name: "Evening",
                widgets: [
                    Self.widget(11, .system(SystemStatsSettings(metrics: .memory))),
                    Self.widget(
                        12,
                        .noodleComputer(NoodleComputerSettings(computerID: Self.id(601), computerName: "Studio Mac"))),
                    Self.widget(13, .railway(railway), bar: false),
                    Self.widget(14, .railway(cliRailway), side: false),
                    Self.widget(15, .noodleComputer(NoodleComputerSettings())),
                    Self.widget(16, .codexSessions(codexSessions), bar: false),
                    Self.widget(17, .codexSessions(CodexSessionsSettings(recentHours: 24)), side: false),
                    Self.widget(
                        18,
                        .agentSessions(
                            AgentSessionsSettings(
                                providers: [.codex, .cursor, .openCode], sessionCount: 8, recentHours: 24,
                                includesCodexExec: true))),
                    Self.widget(19, .openRouter(credits), bar: false),
                    Self.widget(20, .openRouter(models), side: false),
                ], share: 0.5, alignment: .start),
        ]
        let data = try c.json()
        // What this version writes, it must read back unchanged.
        #expect(try AppConfiguration(json: data) == c)
        let directory = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "ReleasedConfigurations")
        try data.write(to: directory.appending(path: "\(try #require(Self.release)).json"))
    }

    private static func base() -> AppConfiguration {
        func color(_ hex: String) -> RGBAColor { RGBAColor(hex: hex)! }
        var c = AppConfiguration()
        c.panel = PanelDefaults(
            position: .right, width: .percent(22.5), length: .fit, alignment: .end, shownOn: .all)
        c.windowAvoidance = .clip
        c.hotkey = Hotkey(keyCode: 49, modifiers: [.control, .option, .shift], key: "Space")
        c.updates = UpdateSettings(checksAutomatically: false, installsAutomatically: true)
        c.displays = [
            DisplayProfile(
                id: "37D8832A-2D66-02CA-B9F7-8F30A301B230", name: "Studio Display", showsPanel: false, position: .top,
                width: .points(320), length: .fill, alignment: .start),
            DisplayProfile(id: "A1B2C3D4-0000-4000-8000-00000000BEEF", name: "LG UltraFine", width: .preset(.compact)),
            DisplayProfile(
                id: "0F0E0D0C-1111-4222-9333-444455556666", name: "Sidecar", showsPanel: true, position: .bottom,
                width: .preset(.minimal), alignment: .center),
        ]

        var background = BackgroundSettings()
        background.kind = .image
        background.grain = 0.35
        background.glass.variant = .clear
        background.glass.tint = Tint(color: color("#2040A0"), amount: 0.4)
        background.blur.material = .dark
        background.blur.radius = 55
        background.blur.tint = Tint(color: color("#802020"), amount: 0.25)
        background.color.fill = .solid
        background.color.color = color("#33AA77CC")
        background.color.gradient = [color("#FF0055"), color("#FFAA00"), color("#00CCFF80")]
        background.color.angle = 45
        background.color.isAnimated = true
        background.color.opacity = 0.8
        background.image.path = "/Users/example/Pictures/wallpaper.heic"
        background.image.tint = Tint(color: color("#101030"), amount: 0.2)
        background.image.blur = 0.05
        background.image.dim = 0.5
        background.image.fade = 0.2
        background.image.effect = ImageEffect(
            kind: .dither, size: 8, levels: 6, shadows: color("#0B1020"), highlights: color("#F5E6C8"))
        c.appearance.background = background
        c.appearance.cards.style = .glass
        c.appearance.cards.tint = Tint(color: color("#FFFFFF"), amount: 0.15)
        c.appearance.cards.fill = Tint(color: color("#112233"), amount: 0.4)
        c.appearance.text = .light
        return c
    }

    private static func id(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))!
    }

    private static func widget(
        _ n: Int, _ settings: WidgetSettings, side: Bool = true, bar: Bool = true
    ) -> WidgetInstance {
        WidgetInstance(id: id(n), settings: settings, showsInSidePanel: side, showsInBar: bar)
    }
}
