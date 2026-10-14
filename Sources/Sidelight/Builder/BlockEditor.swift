import SidelightCore
import SwiftUI

/// Changes to a widget's blocks, as the builder's sidebar and inspector make them: animated, and with the selection
/// following the block changed, or leaving one that's gone.
struct BlockEditor<Widget: BlockBuiltWidget> {
    @Binding var settings: Widget
    @Binding var selection: BuilderSelection<Widget.Block>?
    /// An added block waiting for the person to confirm its removal.
    @Binding var pendingRemoval: Widget.Block?

    func isShown(_ block: Widget.Block) -> Binding<Bool> {
        Binding {
            settings.blocks.isShown(block)
        } set: { isShown in
            withAnimation(Motion.layout) { settings.blocks.setShown(block, isShown) }
        }
    }

    func add(_ addable: AddableBlock) {
        var updated = settings
        guard let block = updated.addBlock(addable.id) else { return }
        withAnimation(Motion.layout) { settings = updated }
        selection = .block(block)
    }

    /// Asks to remove an added block, which takes its options with it. A fixed block can't be removed, so it's
    /// hidden instead.
    func requestRemoval(_ block: Widget.Block) {
        if block.isFixed {
            isShown(block).wrappedValue = false
        } else {
            pendingRemoval = block
        }
    }

    /// Removes an added block, once confirmed.
    func remove(_ block: Widget.Block) {
        if selection == .block(block) { selection = .widget }
        withAnimation(Motion.layout) { settings.removeBlock(block) }
    }

    func move(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        withAnimation(Motion.layout) { settings.blocks.move(fromOffsets: offsets, toOffset: destination) }
    }

    func move(_ block: Widget.Block, by offset: Int) {
        withAnimation(Motion.layout) { settings.blocks.move(block, by: offset) }
    }
}
