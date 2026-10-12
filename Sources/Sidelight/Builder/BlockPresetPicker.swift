import SidelightCore
import SwiftUI

/// The settings form's choice of a ready-made block layout, which reads "Custom" once the blocks are arranged some
/// other way in the builder.
struct BlockPresetPicker<Widget: BlockBuiltWidget>: View {
    @Binding var settings: Widget

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Layout", selection: preset) {
                ForEach(Widget.presets) { Text($0.title).tag(Optional($0.id)) }
                if preset.wrappedValue == nil { Text("Custom").tag(String?.none) }
            }
            SettingsCaption("Open the builder to arrange the blocks and set each one's options.")
        }
    }

    private var preset: Binding<String?> {
        Binding {
            Widget.presets.first { $0.matches(settings.blocks) }?.id
        } set: { id in
            guard let preset = Widget.presets.first(where: { $0.id == id }) else { return }
            settings.blocks.showOnly(preset.blocks)
        }
    }
}
