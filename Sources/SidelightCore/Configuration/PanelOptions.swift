import Foundation

/// The screen edge the panel is attached to.
public enum PanelPosition: String, Codable, CaseIterable, Identifiable, Sendable {
    case left, right, top, bottom

    public var id: Self { self }

    /// Top and bottom positions render a horizontal bar instead of a side panel.
    public var isBar: Bool { self == .top || self == .bottom }
}

/// How long the panel is along its screen edge.
public enum PanelLength: String, Codable, CaseIterable, Identifiable, Sendable {
    /// The whole edge.
    case fill
    /// As long as its widgets, up to the whole edge. Windows still keep out of the whole edge.
    case fit

    public var id: Self { self }
}

/// Where a panel that fits its content sits along its screen edge.
public enum PanelAlignment: String, Codable, CaseIterable, Identifiable, Sendable {
    /// The top of a side panel's edge, the left of a bar's.
    case start
    case center
    /// The bottom of a side panel's edge, the right of a bar's.
    case end

    public var id: Self { self }
}

/// What happens to other apps' windows that overlap the panel.
public enum WindowAvoidanceMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Windows are never moved.
    case off
    /// Overlapping windows are moved away from the panel, keeping their size.
    case shift
    /// Overlapping windows keep their far edge and shrink by the overlap.
    case clip
    /// Clip windows snapped against the screen edge, shift free-floating ones.
    case smart

    public var id: Self { self }
}
