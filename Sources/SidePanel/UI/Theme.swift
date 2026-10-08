import SwiftUI
import AppKit

enum Theme {
    static let spring = Animation.spring(response: 0.7, dampingFraction: 0.78)
    static let snappy = Animation.spring(response: 0.32, dampingFraction: 0.72)
    static let layout = Animation.spring(response: 0.45, dampingFraction: 0.86)

    /// green → amber → red by usage percent
    static func usage(_ pct: Double) -> Color {
        let p = max(0, min(1, pct / 100))
        let hue = p < 0.5 ? 0.38 - (p / 0.5) * 0.26 : 0.12 - ((p - 0.5) / 0.5) * 0.12
        return Color(hue: hue, saturation: 0.78, brightness: 0.95)
    }
    static func compact(_ n: Int64) -> String {
        let d = Double(n)
        switch d {
        case 1e9...: return String(format: "%.2fB", d / 1e9)
        case 1e6...: return String(format: "%.1fM", d / 1e6)
        case 1e3...: return String(format: "%.0fK", d / 1e3)
        default: return "\(n)"
        }
    }
    static func countdown(to date: Date?, now: Date) -> String {
        guard let date else { return "—" }
        let s = max(0, Int(date.timeIntervalSince(now)))
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }
    /// very short countdown for minimal layouts: "14m", "2h", "Tue"
    static func shortCountdown(to date: Date, now: Date) -> String {
        let s = Int(date.timeIntervalSince(now))
        if s <= 0 { return "now" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h" }
        let f = DateFormatter(); f.dateFormat = "EEE"; return f.string(from: date)
    }
}

extension Double { var nonzero: Double { self == 0 ? 1 : self } }

struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blending: NSVisualEffectView.BlendingMode = .behindWindow
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView(); v.material = material; v.blendingMode = blending; v.state = .active; return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) { v.material = material; v.blendingMode = blending }
}

/// Usage ring. `inner` draws an optional thin concentric second ring (e.g. weekly).
struct UsageRing: View {
    static let cheap = UserDefaults.standard.bool(forKey: "cheapRing")
    let pct: Double
    var inner: Double? = nil
    var diameter: CGFloat = 86
    var line: CGFloat = 9
    var label: Bool = true
    var caption: String? = "% · 5h"
    var fontSize: CGFloat = 24

    var body: some View {
        let color = Theme.usage(pct)
        let hot = pct >= 80
        ZStack {
            Circle().stroke(Color.primary.opacity(0.10), lineWidth: line)
            arc(pct, color: color, width: line, hot: hot)
            if let inner {
                let ic = Theme.usage(inner)
                let r = diameter - line * 2 - max(3, line * 0.5) * 2
                Circle().stroke(Color.primary.opacity(0.08), lineWidth: max(2, line * 0.45)).frame(width: r, height: r)
                Circle().trim(from: 0, to: max(0.001, inner / 100))
                    .stroke(ic, style: StrokeStyle(lineWidth: max(2, line * 0.45), lineCap: .round))
                    .rotationEffect(.degrees(-90)).frame(width: r, height: r)
            }
            if label {
                VStack(spacing: -1) {
                    Text("\(Int(pct.rounded()))")
                        .font(.system(size: fontSize, weight: .semibold, design: .rounded)).monospacedDigit()
                        .contentTransition(.numericText(value: pct))
                    if let caption { Text(caption).font(.system(size: max(7, fontSize * 0.38), weight: .medium)).foregroundStyle(.secondary) }
                }
            }
        }
        .frame(width: diameter, height: diameter)
        .animation(Theme.spring, value: pct)
        .animation(Theme.spring, value: inner)
        .phaseAnimator(hot ? [1.0, 1.05, 1.0] : [1.0], trigger: pct) { v, scale in v.scaleEffect(scale) } animation: { _ in .spring(response: 0.35, dampingFraction: 0.55) }
    }

    @ViewBuilder func arc(_ pct: Double, color: Color, width: CGFloat, hot: Bool) -> some View {
        let trim = Circle().trim(from: 0, to: max(0.001, pct / 100))
        if Self.cheap {
            if hot { trim.stroke(color.opacity(0.28), style: StrokeStyle(lineWidth: width * 1.8, lineCap: .round)).rotationEffect(.degrees(-90)) }
            trim.stroke(color, style: StrokeStyle(lineWidth: width, lineCap: .round)).rotationEffect(.degrees(-90))
        } else {
            trim.stroke(AngularGradient(colors: [color.opacity(0.55), color], center: .center,
                                        startAngle: .degrees(0), endAngle: .degrees(max(1, 360 * pct / 100))),
                        style: StrokeStyle(lineWidth: width, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: hot ? color.opacity(0.75) : .clear, radius: hot ? width * 0.75 : 0)
        }
    }
}

struct UsageBar: View {
    let pct: Double
    var animated = true
    var height: CGFloat = 7
    var body: some View {
        let color = Theme.usage(pct)
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.10))
                Capsule()
                    .fill(LinearGradient(colors: [color.opacity(0.65), color], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(height, g.size.width * pct / 100))
            }
        }
        .frame(height: height)
        .animation(animated ? Theme.spring : nil, value: pct)
    }
}

/// Tiny vertical bar for minimal layouts (system stats)
struct VBar: View {
    let pct: Double
    var width: CGFloat = 6
    var height: CGFloat = 28
    var body: some View {
        let color = Theme.usage(pct)
        ZStack(alignment: .bottom) {
            Capsule().fill(Color.primary.opacity(0.12))
            Capsule().fill(color).frame(height: max(width, height * pct / 100))
        }
        .frame(width: width, height: height)
    }
}

struct Sparkline: View {
    let values: [Int64]
    var height: CGFloat = 22
    var body: some View {
        let mx = Double(values.max() ?? 1).nonzero
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(values.enumerated()), id: \.offset) { i, v in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(i == values.count - 1 ? Color.accentColor : Color.primary.opacity(0.28))
                    .frame(height: max(2, height * Double(v) / mx))
            }
        }
        .frame(height: height)
        .animation(Theme.spring, value: values)
    }
}

/// One-shot light sweep when `trigger` changes. Static (off-screen) otherwise.
struct Shimmer<T: Equatable>: ViewModifier {
    let trigger: T
    var radius: CGFloat = 16
    @State private var x: CGFloat = -1.2
    func body(content: Content) -> some View {
        content.overlay(
            GeometryReader { g in
                LinearGradient(colors: [.clear, .white.opacity(0.22), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: g.size.width * 0.6)
                    .offset(x: x * g.size.width)
                    .blendMode(.plusLighter)
            }
            .allowsHitTesting(false)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        )
        .onChange(of: trigger) {
            x = -1.2
            withAnimation(.easeOut(duration: 0.9)) { x = 1.6 }
        }
    }
}

/// Small status badge (minimal layouts)
struct Badge: View {
    let count: Int
    let color: Color
    var body: some View {
        Text(count > 9 ? "9+" : "\(count)")
            .font(.system(size: 9, weight: .bold, design: .rounded)).monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 4).frame(minWidth: 15, minHeight: 15)
            .background(Capsule().fill(color))
            .overlay(Capsule().strokeBorder(.black.opacity(0.25), lineWidth: 0.5))
            .contentTransition(.numericText(value: Double(count)))
    }
}
