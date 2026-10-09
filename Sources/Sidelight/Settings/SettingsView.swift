import SidelightCore
import SwiftUI

/// The Settings window: a System Settings–style sidebar of panes.
struct SettingsView: View {
    @State private var pane: SettingsPane? = .panel
    @Environment(LoginItem.self) private var loginItem

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $pane) { pane in
                Label {
                    Text(pane.sidebarTitle)
                } icon: {
                    IconTile(systemImage: pane.systemImage, tint: pane.tint, size: 22)
                }
                .padding(.vertical, 2)
            }
            .safeAreaInset(edge: .bottom) {
                WindowSwitchLink(destination: .manager).padding(10)
            }
            .navigationSplitViewColumnWidth(180)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            let pane = pane ?? .panel
            Group {
                switch pane {
                case .panel: PanelSettingsPane()
                case .appearance: AppearanceSettingsPane()
                case .windows: WindowsSettingsPane()
                case .general: GeneralSettingsPane()
                }
            }
            .formStyle(.grouped)
            .navigationTitle(pane.title)
        }
        .onAppear { loginItem.refresh() }
    }
}

enum SettingsPane: String, CaseIterable, Identifiable {
    case panel, appearance, windows, general

    var id: Self { self }

    var title: String {
        switch self {
        case .panel: "Panel & Displays"
        case .appearance: "Appearance"
        case .windows: "Window Avoidance"
        case .general: "General"
        }
    }

    var sidebarTitle: String {
        switch self {
        case .panel: "Panel"
        case .windows: "Windows"
        case .appearance, .general: title
        }
    }

    var systemImage: String {
        switch self {
        case .panel: "sidebar.left"
        case .appearance: "paintbrush.fill"
        case .windows: "macwindow.on.rectangle"
        case .general: "gearshape.fill"
        }
    }

    var tint: Color {
        switch self {
        case .panel: .blue
        case .appearance: .pink
        case .windows: .orange
        case .general: .gray
        }
    }
}

/// A row of large, visual choices (positions, styles), each a preview with a title under it.
struct TilePicker<Value: Hashable, Preview: View>: View {
    let values: [Value]
    @Binding var selection: Value
    let title: (Value) -> String
    @ViewBuilder let preview: (Value, Bool) -> Preview

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ForEach(values, id: \.self) { value in
                let isSelected = value == selection
                Button {
                    withAnimation(Motion.snappy) { selection = value }
                } label: {
                    VStack(spacing: 7) {
                        preview(value, isSelected)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2.5)
                                    .padding(-4)
                            )
                            .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
                        Text(title(value))
                            .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                            .foregroundStyle(isSelected ? .primary : .secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title(value))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
    }
}

/// Placeholder widget cards for miniature panel previews.
struct MiniatureCards: View {
    var fill: Color = .white.opacity(0.22)
    var heights: [CGFloat] = [14, 22, 11, 17]
    var spacing: CGFloat = 3
    var cornerRadius: CGFloat = 3

    var body: some View {
        VStack(spacing: spacing) {
            ForEach(heights.indices, id: \.self) { index in
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(fill).frame(
                    height: heights[index])
            }
            Spacer(minLength: 0)
        }
    }
}
