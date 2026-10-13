import Foundation

/// The details panel: the full-height panel a widget opens in place of the side panel to show more, like every
/// OpenRouter model. The same for every widget that opens one.
public struct DetailsPanelSettings: Codable, Hashable, Sendable {
    /// Its own background rather than the panel's.
    public var usesCustomStyle = false
    /// The background it draws while ``usesCustomStyle`` is on; `nil` until it's first given one. Kept while the
    /// switch is off, so turning it back on brings the same style back.
    public var customBackground: BackgroundSettings?
    /// Closes the details panel from any app.
    public var closeHotkey = Hotkey.defaultCloseDetails

    public init(usesCustomStyle: Bool = false, customBackground: BackgroundSettings? = nil) {
        self.usesCustomStyle = usesCustomStyle
        self.customBackground = customBackground
    }

    /// Missing options take their defaults. A background or shortcut that can't be read takes its default too,
    /// rather than failing the whole configuration.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = DetailsPanelSettings()
        usesCustomStyle = try container.decode(.usesCustomStyle, or: defaults.usesCustomStyle)
        customBackground = try? container.decodeIfPresent(BackgroundSettings.self, forKey: .customBackground)
        closeHotkey = container.decodeLeniently(.closeHotkey, or: defaults.closeHotkey)
        if !closeHotkey.isValid { closeHotkey = defaults.closeHotkey }
    }

    /// What the details panel draws behind its content, given the panel's own background.
    public func background(inheriting panel: BackgroundSettings) -> BackgroundSettings {
        usesCustomStyle ? customBackground ?? panel : panel
    }

    /// Turns the custom style on or off. The first time it's turned on, it starts from the panel's background.
    public mutating func setUsesCustomStyle(_ isOn: Bool, startingFrom panel: BackgroundSettings) {
        if isOn && customBackground == nil { customBackground = panel }
        usesCustomStyle = isOn
    }
}

extension Appearance {
    /// The appearance the details panel draws with: the panel's, with the details panel's own background when it has
    /// a custom style. Cards and text are always the panel's.
    public func forDetailsPanel(_ details: DetailsPanelSettings) -> Appearance {
        var appearance = self
        appearance.background = details.background(inheriting: background)
        return appearance
    }
}
