import Foundation
import Combine

// MARK: - Config model (Codable; persisted to ~/Library/Application Support/Sidelight/config.json)

enum PanelPosition: String, Codable, CaseIterable, Identifiable {
    case left, right, top, bottom
    var id: String { rawValue }
    var isBar: Bool { self == .top || self == .bottom }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .left: "rectangle.lefthalf.inset.filled"
        case .right: "rectangle.righthalf.inset.filled"
        case .top: "rectangle.tophalf.inset.filled"
        case .bottom: "rectangle.bottomhalf.inset.filled"
        }
    }
    /// Rectangle's matching gap key
    var rectangleKey: String { "screenEdgeGap" + rawValue.capitalized }
}

enum PanelSize: String, Codable, CaseIterable, Identifiable {
    case regular, compact, minimal
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    /// side panel width in points
    var width: CGFloat { switch self { case .regular: 320; case .compact: 190; case .minimal: 68 } }
}

enum DisplayMode: String, Codable, CaseIterable, Identifiable {
    case glass, cards, black, image
    var id: String { rawValue }
    var title: String { switch self { case .glass: "Glass panel"; case .cards: "Glass cards"; case .black: "Black"; case .image: "Image" } }
}

enum AvoidMode: String, Codable, CaseIterable, Identifiable {
    case off, shift, clip, smart
    var id: String { rawValue }
}

enum ImageCardStyle: String, Codable, CaseIterable, Identifiable {
    case glass, material
    var id: String { rawValue }
}

enum StatsChoice: String, Codable, CaseIterable, Identifiable {
    case both, cpu, memory
    var id: String { rawValue }
}

/// Union of per-widget settings. Each widget reads the fields it cares about; missing keys fall back to defaults,
/// so old/hand-edited config files keep decoding.
struct WidgetSettings: Codable, Hashable {
    var showSeconds = false
    var use24h = true
    var showWeekly = true
    var eventCount = 3
    var stats: StatsChoice = .both

    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self); let def = WidgetSettings()
        showSeconds = try c.decodeIfPresent(Bool.self, forKey: .showSeconds) ?? def.showSeconds
        use24h = try c.decodeIfPresent(Bool.self, forKey: .use24h) ?? def.use24h
        showWeekly = try c.decodeIfPresent(Bool.self, forKey: .showWeekly) ?? def.showWeekly
        eventCount = try c.decodeIfPresent(Int.self, forKey: .eventCount) ?? def.eventCount
        stats = try c.decodeIfPresent(StatsChoice.self, forKey: .stats) ?? def.stats
    }
}

struct WidgetInstance: Codable, Hashable, Identifiable {
    var id = UUID()
    var kind: String
    var inSide = true      // shown in the left/right panel
    var inBar = true       // shown in the top/bottom bar (minimal layout)
    var settings = WidgetSettings()

    init(kind: String, inSide: Bool = true, inBar: Bool = true) { self.kind = kind; self.inSide = inSide; self.inBar = inBar }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decode(String.self, forKey: .kind)
        inSide = try c.decodeIfPresent(Bool.self, forKey: .inSide) ?? true
        inBar = try c.decodeIfPresent(Bool.self, forKey: .inBar) ?? true
        settings = try c.decodeIfPresent(WidgetSettings.self, forKey: .settings) ?? WidgetSettings()
    }
}

struct HotkeySpec: Codable, Hashable {
    var keyCode: UInt32 = 1            // kVK_ANSI_S
    var modifiers: UInt32 = 256 | 2048 // cmdKey | optionKey (Carbon)
    var display = "⌥⌘S"
}

struct AppConfig: Codable, Equatable {
    var version = 1
    var position: PanelPosition = .left
    var size: PanelSize = .regular
    var mode: DisplayMode = .glass
    var imageCards: ImageCardStyle = .glass
    var backgroundImage: String? = nil   // nil = bundled wallpaper
    var dim = 0.45
    var fade = 0.9
    var avoidMode: AvoidMode = .smart
    var useGlass = true
    var animatedBG = false
    var hotkey = HotkeySpec()
    var widgets: [WidgetInstance] = AppConfig.defaultWidgets

    static let defaultWidgets: [WidgetInstance] = [
        .init(kind: "clock"), .init(kind: "codex"), .init(kind: "calendar"), .init(kind: "nowPlaying"),
        .init(kind: "agents"), .init(kind: "system"),
    ]

    /// Effective size: bars always use the minimal widget layouts.
    var effectiveSize: PanelSize { position.isBar ? .minimal : size }
    var visibleWidgets: [WidgetInstance] { widgets.filter { position.isBar ? $0.inBar : $0.inSide } }

    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self); let def = AppConfig()
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? def.version
        position = try c.decodeIfPresent(PanelPosition.self, forKey: .position) ?? def.position
        size = try c.decodeIfPresent(PanelSize.self, forKey: .size) ?? def.size
        mode = try c.decodeIfPresent(DisplayMode.self, forKey: .mode) ?? def.mode
        imageCards = try c.decodeIfPresent(ImageCardStyle.self, forKey: .imageCards) ?? def.imageCards
        backgroundImage = try c.decodeIfPresent(String.self, forKey: .backgroundImage)
        dim = try c.decodeIfPresent(Double.self, forKey: .dim) ?? def.dim
        fade = try c.decodeIfPresent(Double.self, forKey: .fade) ?? def.fade
        avoidMode = try c.decodeIfPresent(AvoidMode.self, forKey: .avoidMode) ?? def.avoidMode
        useGlass = try c.decodeIfPresent(Bool.self, forKey: .useGlass) ?? def.useGlass
        animatedBG = try c.decodeIfPresent(Bool.self, forKey: .animatedBG) ?? def.animatedBG
        hotkey = try c.decodeIfPresent(HotkeySpec.self, forKey: .hotkey) ?? def.hotkey
        widgets = try c.decodeIfPresent([WidgetInstance].self, forKey: .widgets) ?? def.widgets
    }
}

// MARK: - Store: load / debounced atomic save / hot reload on external edits

final class ConfigStore: ObservableObject {
    static let shared = ConfigStore()

    @Published var config: AppConfig { didSet { if !applyingExternal && config != oldValue { scheduleSave() } } }
    let url: URL
    private var lastData: Data?
    private var applyingExternal = false
    private var saveWork: DispatchWorkItem?
    private var dirSource: DispatchSourceFileSystemObject?
    private var reloadWork: DispatchWorkItem?

    private init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Sidelight")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("config.json")
        var cfg = AppConfig()
        if let data = try? Data(contentsOf: url) {
            do { cfg = try JSONDecoder().decode(AppConfig.self, from: data); lastData = data }
            catch { Log.config.error("config.json invalid, using defaults: \(error)") }
        }
        if lastData == nil, let data = Self.encode(cfg) { try? data.write(to: url, options: .atomic); lastData = data }   // first run: persist defaults
        config = cfg
        watch()
    }

    private static func encode(_ c: AppConfig) -> Data? {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? e.encode(c)
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
    }

    func save() {
        guard let data = Self.encode(config) else { return }
        lastData = data
        try? data.write(to: url, options: .atomic)
    }

    /// Watch the *directory*: atomic writes (ours and most editors') replace the file's inode, which a
    /// file-level vnode watch would lose.
    private func watch() {
        let fd = open(url.deletingLastPathComponent().path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .extend], queue: .main)
        src.setEventHandler { [weak self] in self?.scheduleReload() }
        src.setCancelHandler { close(fd) }
        src.resume()
        dirSource = src
    }

    private func scheduleReload() {
        reloadWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.reloadIfChanged() }
        reloadWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: w)
    }

    private func reloadIfChanged() {
        guard let data = try? Data(contentsOf: url), data != lastData else { return }
        do {
            let c = try JSONDecoder().decode(AppConfig.self, from: data)
            lastData = data
            applyingExternal = true
            config = c
            applyingExternal = false
            Log.config.info("hot-reloaded config.json (position=\(c.position.rawValue) size=\(c.size.rawValue) mode=\(c.mode.rawValue) widgets=\(c.widgets.count))")
        } catch {
            Log.config.error("config.json edit ignored (invalid JSON): \(error.localizedDescription)")
        }
    }
}
