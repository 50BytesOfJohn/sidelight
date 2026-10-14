import SidelightCore
import SwiftUI

/// The widget, then its blocks top to bottom, hidden ones dimmed where they'd show. Drag a block to move it, hover
/// it to show, hide or remove it, and add blocks after the others. Delete removes an added block, or hides another.
struct BlockSidebar<Widget: BlockBuiltWidget>: View {
    /// The widget as the panel has it, for its row.
    let widget: WidgetSettings
    let editor: BlockEditor<Widget>

    var body: some View {
        let entries = editor.settings.blocks.entries
        List(selection: editor.$selection) {
            WidgetRow(settings: widget)
                .tag(BuilderSelection<Widget.Block>.widget)

            Section("Blocks") {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    row(entry.block, at: index, of: entries)
                }
                .onMove(perform: editor.move)
                AddBlockRow(addable: Widget.addableBlocks, add: editor.add)
            }
        }
        .listStyle(.sidebar)
        .onDeleteCommand {
            if case .block(let block) = editor.selection { editor.requestRemoval(block) }
        }
    }

    private func row(_ block: Widget.Block, at index: Int, of entries: [BlockLayout<Widget.Block>.Entry]) -> some View {
        let title = editor.settings.title(of: block)
        return BlockRow(
            title: title, systemImage: block.systemImage, logo: block.logo, isShown: editor.isShown(block),
            remove: block.isFixed ? nil : { editor.requestRemoval(block) }
        )
        .tag(BuilderSelection<Widget.Block>.block(block))
        .help(block.blurb)
        .contextMenu {
            Toggle("Show in Widget", isOn: editor.isShown(block))
            Divider()
            Button("Move Up") { editor.move(block, by: -1) }
                .disabled(index == 0)
            Button("Move Down") { editor.move(block, by: 1) }
                .disabled(index == entries.count - 1)
            if !block.isFixed {
                Divider()
                Button("Remove…", role: .destructive) { editor.requestRemoval(block) }
            }
        }
    }
}

/// The widget itself, as the Widgets window lists it: selecting it shows the options for the whole widget.
private struct WidgetRow: View {
    let settings: WidgetSettings

    var body: some View {
        let metadata = settings.kind.metadata
        HStack(spacing: 10) {
            metadata.iconTile(size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(metadata.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(settings.summary).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }
}

/// A block, with buttons that show while it's hovered: remove, for an added block, and an eye that shows or hides
/// it. A hidden block keeps its eye, as the Widgets window marks a widget left out of a placement.
private struct BlockRow: View {
    let title: String
    let systemImage: String
    let logo: String?
    @Binding var isShown: Bool
    /// `nil` for a fixed block, which can only be hidden.
    let remove: (() -> Void)?
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 0) {
            Label {
                Text(title)
            } icon: {
                BlockIcon(systemImage: systemImage, logo: logo).sidebarIconStyle()
            }
            .lineLimit(1)
            .opacity(isShown ? 1 : 0.55)
            Spacer(minLength: 4)
            if isHovered, let remove {
                RowButton(systemImage: "trash", help: "Remove…", isHovered: isHovered, action: remove)
                    .accessibilityLabel("Remove")
            }
            if isHovered || !isShown {
                RowButton(
                    systemImage: isShown ? "eye" : "eye.slash", help: isShown ? "Hide" : "Show",
                    isHovered: isHovered
                ) {
                    isShown.toggle()
                }
                .accessibilityLabel("Show in widget")
                .accessibilityValue(isShown ? "On" : "Off")
            }
        }
        .contentShape(Rectangle())
        .sidebarRowStyle()
        .onHover { hovering in withAnimation(Motion.hover) { isHovered = hovering } }
    }
}

/// A small borderless icon button at the end of a row, faint until the row is hovered.
private struct RowButton: View {
    let systemImage: String
    let help: String
    let isHovered: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 22, height: 20)
                .foregroundStyle(isHovered ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
        .transition(.opacity)
    }
}

/// Adds a block after the others: straight away when there's one kind to add, from a menu when there are more.
private struct AddBlockRow: View {
    let addable: [AddableBlock]
    let add: (AddableBlock) -> Void

    var body: some View {
        if addable.count == 1, let only = addable.first {
            Button {
                add(only)
            } label: {
                AddRowLabel(title: "Add \(only.title)")
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        } else if !addable.isEmpty {
            Menu {
                ForEach(addable) { addable in
                    Button {
                        add(addable)
                    } label: {
                        Label {
                            Text(addable.title)
                        } icon: {
                            BlockIcon(systemImage: addable.systemImage, logo: addable.logo)
                        }
                    }
                }
            } label: {
                AddRowLabel(title: "Add Block")
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .padding(.top, 4)
        }
    }
}
