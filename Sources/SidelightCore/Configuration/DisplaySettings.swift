import Foundation

/// Which displays show the panel unless a display says otherwise.
public enum PanelDisplays: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Only the display with the menu bar.
    case main
    /// Every connected display.
    case all

    public var id: Self { self }
}

/// The panel settings every display uses unless it overrides them.
public struct PanelDefaults: Codable, Hashable, Sendable {
    public var position: PanelPosition
    public var width: PanelWidth
    public var length: PanelLength
    public var alignment: PanelAlignment
    public var shownOn: PanelDisplays

    public init(
        position: PanelPosition = .left,
        width: PanelWidth = .preset(.regular),
        length: PanelLength = .fill,
        alignment: PanelAlignment = .center,
        shownOn: PanelDisplays = .main
    ) {
        self.position = position
        self.width = width
        self.length = length
        self.alignment = alignment
        self.shownOn = shownOn
    }

    public func showsPanel(onMainDisplay isMain: Bool) -> Bool {
        shownOn == .all || isMain
    }
}

/// One display's overrides of ``PanelDefaults``, remembered across reconnects. `nil` follows the default and is
/// left out of `config.json`.
public struct DisplayProfile: Codable, Hashable, Identifiable, Sendable {
    /// Stable identifier of the display (its Core Graphics display UUID).
    public let id: String
    /// The display's name when last configured, so `config.json` and Settings can tell displays apart.
    public var name: String
    public var showsPanel: Bool?
    public var position: PanelPosition?
    public var width: PanelWidth?
    public var length: PanelLength?
    public var alignment: PanelAlignment?

    public init(
        id: String,
        name: String,
        showsPanel: Bool? = nil,
        position: PanelPosition? = nil,
        width: PanelWidth? = nil,
        length: PanelLength? = nil,
        alignment: PanelAlignment? = nil
    ) {
        self.id = id
        self.name = name
        self.showsPanel = showsPanel
        self.position = position
        self.width = width
        self.length = length
        self.alignment = alignment
    }

    public var overridesAnything: Bool {
        showsPanel != nil || position != nil || width != nil || length != nil || alignment != nil
    }
}

/// The panel on one display: the defaults with the display's overrides applied.
public struct DisplayPanel: Hashable, Sendable {
    public var showsPanel: Bool
    public var position: PanelPosition
    public var width: PanelWidth
    public var length: PanelLength
    public var alignment: PanelAlignment

    public init(
        showsPanel: Bool,
        position: PanelPosition,
        width: PanelWidth,
        length: PanelLength = .fill,
        alignment: PanelAlignment = .center
    ) {
        self.showsPanel = showsPanel
        self.position = position
        self.width = width
        self.length = length
        self.alignment = alignment
    }
}

extension AppConfiguration {
    public func displayProfile(id: String) -> DisplayProfile? {
        displays.first { $0.id == id }
    }

    public func panel(onDisplay id: String, isMain: Bool) -> DisplayPanel {
        let profile = displayProfile(id: id)
        return DisplayPanel(
            showsPanel: profile?.showsPanel ?? panel.showsPanel(onMainDisplay: isMain),
            position: profile?.position ?? panel.position,
            width: profile?.width ?? panel.width,
            length: profile?.length ?? panel.length,
            alignment: profile?.alignment ?? panel.alignment
        )
    }

    /// Edits a display's overrides, creating its profile the first time and dropping it once it overrides nothing.
    public mutating func updateDisplayProfile(id: String, name: String, _ change: (inout DisplayProfile) -> Void) {
        var profile = displayProfile(id: id) ?? DisplayProfile(id: id, name: name)
        profile.name = name
        change(&profile)
        let index = displays.firstIndex { $0.id == id }
        switch (index, profile.overridesAnything) {
        case (let index?, true): displays[index] = profile
        case (let index?, false): displays.remove(at: index)
        case (nil, true): displays.append(profile)
        case (nil, false): break
        }
    }

    /// Changes a setting the way it looks from one display: the display's own override if it has one, otherwise
    /// the default for every display.
    public mutating func set<Value>(
        _ value: Value,
        default defaultKeyPath: WritableKeyPath<PanelDefaults, Value>,
        override overrideKeyPath: WritableKeyPath<DisplayProfile, Value?>,
        onDisplay id: String,
        name: String
    ) {
        if displayProfile(id: id)?[keyPath: overrideKeyPath] != nil {
            updateDisplayProfile(id: id, name: name) { $0[keyPath: overrideKeyPath] = value }
        } else {
            panel[keyPath: defaultKeyPath] = value
        }
    }

    /// Shows or hides the panel on one display, keeping an override only where it differs from the default.
    public mutating func setShowsPanel(_ showsPanel: Bool, onDisplay id: String, name: String, isMain: Bool) {
        let isDefault = showsPanel == panel.showsPanel(onMainDisplay: isMain)
        updateDisplayProfile(id: id, name: name) { $0.showsPanel = isDefault ? nil : showsPanel }
    }
}
