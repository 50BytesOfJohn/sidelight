import CoreGraphics

/// What reserves a display's edge: the panel itself, or the details panel standing in for it.
public enum ReservationRole: String, Sendable {
    case main
    case details
}

/// The strip a display keeps clear, in Accessibility coordinates (see ``AvoidanceGeometry``).
public struct Reservation: Equatable, Sendable {
    /// The space to leave between a strip and the nearest window. The panel's number, not any one feature's, so a
    /// tile, a pushed window and one of Sidelight's own windows all stop on the same line.
    public static let defaultClearance: CGFloat = 8

    public var frame: CGRect
    public var edge: PanelPosition
    public var role: ReservationRole
    /// The space to leave between this strip and the nearest window (see ``defaultClearance``).
    public var clearance: CGFloat

    public init(
        frame: CGRect, edge: PanelPosition, role: ReservationRole, clearance: CGFloat = Self.defaultClearance
    ) {
        self.frame = frame
        self.edge = edge
        self.role = role
        self.clearance = clearance
    }

    /// The strip plus ``clearance`` on its inner edge: where a window beside the panel starts. The strip itself is
    /// what a window may never cover (see ``WorkArea/isClear(_:)``); this is where one belongs.
    public var keepOut: CGRect {
        switch edge {
        case .left:
            CGRect(x: frame.minX, y: frame.minY, width: frame.width + clearance, height: frame.height)
        case .right:
            CGRect(x: frame.minX - clearance, y: frame.minY, width: frame.width + clearance, height: frame.height)
        case .top:
            CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height + clearance)
        case .bottom:
            CGRect(x: frame.minX, y: frame.minY - clearance, width: frame.width, height: frame.height + clearance)
        }
    }
}

/// Why Sidelight moved a window, and so what may move it next.
public enum WindowMoveReason: String, Equatable, Sendable {
    /// Out from under a panel it overlapped, as it was created, moved, resized or shown.
    case keepClear
    /// Out of a strip a panel has just taken.
    case push
    /// Back where it was before a panel moved it.
    case restore
    /// Following the edge it was snapped to, as a details panel closes.
    case follow
}

/// Why a window is where it is, which decides what may move it next.
///
/// *Keep clear* applies to every window, whatever put it there; *put it back* applies only to a window avoidance
/// moved itself. So a deliberate placement is never avoidance's to undo.
public enum PlacementIntent: Equatable, Sendable {
    /// Window avoidance keeping a strip clear, or giving one back.
    case avoidance(WindowMoveReason)
    /// A window manager shortcut: the tile the window now is, at which step of its cycle.
    case manager(WindowAction, step: Int)
    /// The window manager putting a window back where it first found it.
    case restore
    /// One of Sidelight's own windows, kept beside the panel.
    case ownWindow

    /// Whether someone asked for this placement, as opposed to avoidance making room.
    public var isDeliberate: Bool {
        switch self {
        case .avoidance: false
        case .manager, .restore, .ownWindow: true
        }
    }
}

/// Where a window was before Sidelight moved it, for each panel that did, and where Sidelight left it. A layer per
/// panel, so closing the details panel puts a window back where the side panel had it, and hiding everything puts
/// it back where it was before either.
public struct WindowBaselines: Equatable, Sendable {
    /// Before the side panel or bar first moved it.
    public var main: CGRect?
    /// Before the details panel first moved it.
    public var details: CGRect?
    /// The frame the app ended up with the last time Sidelight moved it, which may not be what was asked for.
    public var accepted: CGRect

    public init(main: CGRect? = nil, details: CGRect? = nil, accepted: CGRect) {
        self.main = main
        self.details = details
        self.accepted = accepted
    }

    /// Where it was before any panel moved it.
    public var earliest: CGRect? { main ?? details }

    public subscript(role: ReservationRole) -> CGRect? {
        get {
            switch role {
            case .main: main
            case .details: details
            }
        }
        set {
            switch role {
            case .main: main = newValue
            case .details: details = newValue
            }
        }
    }
}
