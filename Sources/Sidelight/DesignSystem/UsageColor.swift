import SwiftUI

extension Color {
    /// Usage above this percentage is highlighted as "hot".
    static let usageWarningThreshold = 80.0

    /// The amber of a limit that will run out before it resets.
    static let usageWarning = Color.usage(percent: 75)
    /// The red of a limit that is used up.
    static let usageCritical = Color.usage(percent: 100)

    /// Green → amber → red as usage (0–100 %) grows.
    static func usage(percent: Double) -> Color {
        let fraction = min(max(percent / 100, 0), 1)
        let hue = fraction < 0.5 ? 0.38 - (fraction / 0.5) * 0.26 : 0.12 - ((fraction - 0.5) / 0.5) * 0.12
        return Color(hue: hue, saturation: 0.78, brightness: 0.95)
    }
}
