import SidelightCore
import SwiftUI

/// A widget drawn with the panel's current card style at a given layout, for the manager.
struct WidgetPreview: View {
    let settings: WidgetSettings
    let layout: WidgetLayout
    @Environment(ConfigurationStore.self) private var store

    var body: some View {
        let appearance = CardAppearance(store.configuration.appearance).forPreview
        Group {
            if layout == .bar {
                WidgetCard(settings: settings, layout: layout, appearance: appearance)
                    .frame(height: 36)
                    .fixedSize(horizontal: true, vertical: false)
            } else {
                WidgetCard(settings: settings, layout: layout, appearance: appearance)
                    .frame(width: layout.previewCardWidth)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .environment(\.colorScheme, .dark)
        .animation(Motion.layout, value: layout)
    }
}

extension WidgetPreview {
    /// 10:09:30 today, the time watch ads show: the hands frame the dial and the digits are all different.
    static var showcaseDate: Date {
        Calendar.autoupdatingCurrent.date(bySettingHour: 10, minute: 9, second: 30, of: .now) ?? .now
    }
}

extension WidgetLayout {
    /// Card width matching the real panel's content width; `nil` for bars, which size to fit.
    var previewCardWidth: CGFloat? {
        switch self {
        case .regular: 296
        case .compact: 178
        case .minimal: 60
        case .bar: nil
        }
    }

    var galleryTileMinimumWidth: CGFloat {
        switch self {
        case .regular: 330
        case .compact: 230
        case .minimal: 170
        case .bar: 250
        }
    }

    var galleryStageHeight: CGFloat {
        switch self {
        case .regular: 250
        case .compact: 170
        case .minimal: 130
        case .bar: 80
        }
    }
}
