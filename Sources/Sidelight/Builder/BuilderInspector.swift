import SidelightCore
import SwiftUI

/// The options for the whole widget, or for the selected block, in a form like the Widgets window's inspector.
struct BuilderInspector<Widget: BlockBuiltWidget>: View {
    let kind: WidgetKind
    let editor: BlockEditor<Widget>

    var body: some View {
        Form {
            // A block can be gone by the time this draws, removed from the configuration file.
            if case .block(let block) = editor.selection, editor.settings.blocks.contains(block) {
                blockOptions(block)
            } else {
                widgetOptions
            }
        }
        .formStyle(.grouped)
        // Each selection's options start at the top.
        .id(editor.selection)
    }

    private var widgetOptions: some View {
        let metadata = kind.metadata
        return Section {
            Widget.widgetOptions(settings: editor.$settings)
        } header: {
            InspectorTitle(title: metadata.title, subtitle: metadata.summary) {
                metadata.iconTile(size: 32)
            } accessories: {
                if metadata.isBeta { BetaBadge() }
                if let details = metadata.details { InfoButton(details) }
            }
        }
    }

    @ViewBuilder
    private func blockOptions(_ block: Widget.Block) -> some View {
        Section {
            Toggle("Show in widget", isOn: editor.isShown(block))
            if !block.isFixed {
                Button("Remove Block…", role: .destructive) { editor.requestRemoval(block) }
                    .buttonStyle(.borderless)
            }
        } header: {
            InspectorTitle(title: editor.settings.title(of: block)) {
                if let logo = block.logo {
                    BrandLogos.artwork(logo, size: 20)
                        .frame(width: 32, height: 32)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 32 * 0.27, style: .continuous))
                } else {
                    IconTile(systemImage: block.systemImage, tint: kind.metadata.tint, size: 32)
                }
            } accessories: {
                InfoButton(block.blurb)
            }
        }
        Widget.options(for: block, settings: editor.$settings)
    }
}
