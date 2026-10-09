import Foundation
import SidelightCore

/// The four ways a widget can be drawn: three side-panel densities plus a chip in a horizontal bar.
enum WidgetLayout: String, CaseIterable, Identifiable {
    case regular, compact, minimal, bar

    var id: Self { self }

    var title: String { rawValue.capitalized }

    init(_ density: WidgetDensity) {
        switch density {
        case .regular: self = .regular
        case .compact: self = .compact
        case .minimal: self = .minimal
        }
    }

    /// Minimal and bar layouts show a single glanceable value instead of a list or a header.
    var isGlanceable: Bool { self == .minimal || self == .bar }
}
