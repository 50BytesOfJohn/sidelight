import SidelightCore
import SwiftUI

/// A block as the builder lists it.
protocol DescribedBlock: WidgetBlockKind, Identifiable {
    var title: String { get }
    var systemImage: String { get }
    /// A logo in `ProviderLogos.xcassets`, in its own colors, drawn in place of ``systemImage``.
    var logo: String? { get }
    /// What it shows, behind the ⓘ next to its name.
    var blurb: String { get }
}

extension DescribedBlock {
    var logo: String? { nil }
}

/// A widget built from blocks, as its builder edits it. The widget's settings conform: their blocks, each block's
/// options, the options for the whole widget (where its data comes from, how often), and ready-made layouts.
protocol BlockBuiltWidget: Hashable {
    associatedtype Block: DescribedBlock
    associatedtype BlockOptions: View
    associatedtype WidgetOptions: View

    var blocks: BlockLayout<Block> { get set }

    /// Ready-made layouts to start from, the first being the default.
    static var presets: [BlockPreset<Block>] { get }

    /// One block's options, as the sections of the inspector's form.
    @ViewBuilder
    static func options(for block: Block, settings: Binding<Self>) -> BlockOptions

    /// Options for the whole widget, such as its account and how often it refreshes, as rows of a form section. The
    /// Widgets window shows them too.
    @ViewBuilder
    static func widgetOptions(settings: Binding<Self>) -> WidgetOptions

    /// Blocks that can be added any number of times, each with its own options.
    static var addableBlocks: [AddableBlock] { get }

    /// Adds a block of the addable kind `id`, shown at the end, and returns it.
    mutating func addBlock(_ id: AddableBlock.ID) -> Block?

    /// Removes an added block, with its options. Fixed blocks can only be hidden.
    mutating func removeBlock(_ block: Block)

    /// What the builder calls `block`: an added block names what it shows.
    func title(of block: Block) -> String

    /// The looks `block` can take, the first being the default. The builder offers a choice from two.
    func variants(of block: Block) -> [BlockVariant]

    /// The look `block` has, by ``BlockVariant/id``; `nil` for a block without a choice.
    func variantID(of block: Block) -> String?

    /// Gives `block` the look `id`.
    mutating func setVariant(_ id: String, of block: Block)
}

extension BlockBuiltWidget {
    static var addableBlocks: [AddableBlock] { [] }

    mutating func addBlock(_ id: AddableBlock.ID) -> Block? { nil }

    mutating func removeBlock(_ block: Block) { blocks.remove(block) }

    func title(of block: Block) -> String { block.title }

    func variants(of block: Block) -> [BlockVariant] { [] }

    func variantID(of block: Block) -> String? { nil }

    mutating func setVariant(_ id: String, of block: Block) {}
}

/// One way a block can lay out what it shows, which the builder calls its look. Not a ``WidgetStyle``, which is the
/// whole widget's.
struct BlockVariant: Identifiable, Hashable {
    let id: String
    let title: String
    /// What it shows, behind the ⓘ next to the choice.
    let summary: String
}

/// A kind of block the builder offers to add, as many times as wanted.
struct AddableBlock: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    var logo: String?
}

/// A ready-made layout: these blocks in this order, the rest hidden. Each block keeps its options.
struct BlockPreset<Block: WidgetBlockKind>: Identifiable {
    let id: String
    let title: String
    let blocks: [Block]

    func matches(_ layout: BlockLayout<Block>) -> Bool { layout.shownBlocks == blocks }
}

extension WidgetSettings {
    /// The settings of a widget built from blocks; `nil` for any other.
    var blockBuilt: (any BlockBuiltWidget)? {
        switch self {
        case .railway(let settings): settings
        case .codexSessions(let settings): settings
        case .openRouter(let settings): settings
        case .aiUsage(let settings): settings
        case .clock, .codex, .claudeCode, .cursor, .calendar, .nowPlaying, .claudeSessions, .system, .noodleComputer,
            .agentSessions, .stash, .awake, .docker:
            nil
        }
    }

    /// Whether this widget is built from blocks and has a builder.
    var hasBuilder: Bool { blockBuilt != nil }
}

/// A block's icon: its provider's logo in its own colors, or its symbol in the foreground style.
struct BlockIcon: View {
    let systemImage: String
    var logo: String?
    var size: CGFloat = 16

    var body: some View {
        if let logo {
            BrandLogos.artwork(logo, size: size)
        } else {
            Image(systemName: systemImage)
        }
    }
}
