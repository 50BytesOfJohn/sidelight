import SidelightCore
import SwiftUI

extension WidgetMetadata {
    static let system = WidgetMetadata(
        title: "System",
        systemImage: "cpu",
        tint: .teal,
        summary: "CPU % and memory, refreshed every 2 s."
    )
}

extension SystemStatsSettings {
    var summary: String {
        switch metrics {
        case .both: "CPU + memory"
        case .cpu: "CPU"
        case .memory: "Memory"
        }
    }
}

struct SystemSettingsEditor: View {
    @Binding var settings: SystemStatsSettings

    var body: some View {
        Picker("Show", selection: $settings.metrics) {
            Text("CPU + memory").tag(SystemStatsSettings.Metrics.both)
            Text("CPU").tag(SystemStatsSettings.Metrics.cpu)
            Text("Memory").tag(SystemStatsSettings.Metrics.memory)
        }
    }
}

// Values change on a timer, so nothing here animates: animating a 2-second ticker kept SwiftUI permanently
// mid-animation (measured 12–16 % CPU at idle).
struct SystemWidgetView: View {
    let settings: SystemStatsSettings
    let layout: WidgetLayout
    @Environment(SystemStatsService.self) private var stats

    private var showsCPU: Bool { settings.metrics.includesCPU }
    private var showsMemory: Bool { settings.metrics.includesMemory }
    private var cpuText: String { "\(Int(stats.cpuUsage.rounded()))%" }
    private var memoryPercent: Double { stats.memory.usedFraction * 100 }

    var body: some View {
        switch layout {
        case .regular:
            HStack(alignment: .top, spacing: 18) {
                if showsCPU {
                    metric("CPU", value: "\(Int(stats.cpuUsage.rounded()))", unit: "%", percent: stats.cpuUsage)
                }
                if showsMemory {
                    metric(
                        "Memory",
                        value: stats.memory.usedGigabytes.formatted(.number.precision(.fractionLength(1))),
                        unit: "/ \(Int(stats.memory.totalGigabytes.rounded())) GB",
                        percent: memoryPercent
                    )
                }
            }
        case .compact:
            VStack(alignment: .leading, spacing: 5) {
                if showsCPU { row("CPU", value: cpuText, percent: stats.cpuUsage) }
                if showsMemory {
                    row(
                        "MEM",
                        value: stats.memory.usedGigabytes.formatted(.number.precision(.fractionLength(1))) + " GB",
                        percent: memoryPercent
                    )
                }
            }
        case .minimal:
            HStack(spacing: 7) {
                if showsCPU { verticalMeter("C", percent: stats.cpuUsage) }
                if showsMemory { verticalMeter("M", percent: memoryPercent) }
            }
            .help(
                "CPU \(cpuText) · Memory \(stats.memory.usedGigabytes.formatted(.number.precision(.fractionLength(1)))) GB"
            )
        case .bar:
            HStack(spacing: 6) {
                if showsCPU {
                    VerticalUsageBar(percent: stats.cpuUsage, width: 5, height: 22)
                    barValue(cpuText)
                }
                if showsMemory {
                    VerticalUsageBar(percent: memoryPercent, width: 5, height: 22)
                    barValue(stats.memory.usedGigabytes.formatted(.number.precision(.fractionLength(0))) + "G")
                }
            }
        }
    }

    private func metric(_ title: String, value: String, unit: String, percent: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 10.5)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.system(size: 20, weight: .medium, design: .rounded)).monospacedDigit()
                Text(unit).font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            UsageBar(percent: percent, isAnimated: false).frame(width: 110)
        }
    }

    private func row(_ title: String, value: String, percent: Double) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Text(value).font(.system(size: 11, weight: .medium, design: .rounded)).monospacedDigit()
            }
            UsageBar(percent: percent, isAnimated: false, height: 4)
        }
    }

    private func verticalMeter(_ label: String, percent: Double) -> some View {
        VStack(spacing: 3) {
            VerticalUsageBar(percent: percent)
            Text(label).font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary)
        }
    }

    private func barValue(_ text: String) -> some View {
        Text(text).font(.system(size: 11.5, weight: .medium, design: .rounded)).monospacedDigit()
    }
}
