import AppKit
import SidelightCore
import SwiftUI
import UniformTypeIdentifiers

/// The panel's background, cards and text, with a live preview on the desktop picture.
struct AppearanceSettingsPane: View {
    @Environment(ConfigurationStore.self) private var store
    @Environment(DisplayMonitor.self) private var monitor

    var body: some View {
        @Bindable var store = store
        let appearance = store.configuration.appearance
        let display = monitor.displays.first { $0.isMain } ?? monitor.displays.first

        Form {
            Section {
                AppearancePreview(appearance: appearance, display: display)
                    .frame(height: 210)
            }

            Section {
                TilePicker(
                    values: BackgroundKind.allCases,
                    selection: $store.configuration.appearance.background.kind,
                    title: \.title
                ) { kind, _ in
                    BackgroundTile(kind: kind, appearance: appearance, display: display)
                }
            } header: {
                Text("Background")
            } footer: {
                Text(appearance.background.kind.explanation).settingsFootnote()
            }

            BackgroundOptions(background: $store.configuration.appearance.background)
            CardsSection(appearance: $store.configuration.appearance)
            TextSection(appearance: $store.configuration.appearance)
        }
        .animation(Motion.layout, value: appearance.background.kind)
        .animation(Motion.layout, value: appearance.cards.style)
    }
}

// MARK: Preview

/// The panel as it will look, on the desktop picture.
private struct AppearancePreview: View {
    let appearance: Appearance
    let display: Display?

    var body: some View {
        let desk = RoundedRectangle(cornerRadius: 12, style: .continuous)
        // The picture fills the space, so it's a background: as content it would size the view to its own aspect.
        GeometryReader { proxy in
            AppearanceMiniature(
                appearance: appearance, scale: 1,
                cutout: Desk.cutout(
                    of: CGRect(x: 7, y: 7, width: 112, height: proxy.size.height - 14),
                    deskSize: proxy.size, display: display)
            )
            .frame(width: 112)
            .padding(7)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .background { Desk(display: display) }
        .clipShape(desk)
        .overlay(desk.strokeBorder(.separator))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview of the panel")
    }
}

/// One background kind with its current settings, as a tile.
private struct BackgroundTile: View {
    let kind: BackgroundKind
    let appearance: Appearance
    let display: Display?

    var body: some View {
        var tileAppearance = appearance
        tileAppearance.background.kind = kind
        let size = CGSize(width: 64, height: 92)
        return AppearanceMiniature(
            appearance: tileAppearance, scale: 0.5,
            cutout: Desk.cutout(of: CGRect(x: 6, y: 6, width: 52, height: 80), deskSize: size, display: display)
        )
        .padding(6)
        .background { Desk(display: display) }
        .frame(width: 64, height: 92)
    }
}

/// The desktop picture, or the preview gradient without a display.
private struct Desk: View {
    let display: Display?

    var body: some View {
        if let display {
            Wallpaper(display: display)
        } else {
            PreviewStage()
        }
    }

    /// The part of the desk's picture behind `rect` (y growing upwards, like screen coordinates), so a miniature
    /// with the desktop picture as its background shows what's behind it, as the real panel does.
    static func cutout(of rect: CGRect, deskSize: CGSize, display: Display?) -> DesktopCutout {
        DesktopCutout(
            displayID: display?.id, screen: CGRect(origin: .zero, size: deskSize), rect: rect, anchor: .center)
    }
}

/// A small panel with placeholder cards whose "text" lines show the contrast the real text will get.
private struct AppearanceMiniature: View {
    let appearance: Appearance
    let scale: CGFloat
    var cutout: DesktopCutout?
    @Environment(DesktopPictures.self) private var desktopPictures
    @Environment(\.colorScheme) private var systemColorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12 * scale, style: .continuous)
        let cards = CardAppearance(appearance).forPreview
        ZStack(alignment: .top) {
            PanelBackground(
                background: appearance.background, shape: shape, blendingMode: .withinWindow, cutout: cutout)
            VStack(spacing: 5 * scale) {
                ForEach([30.0, 44, 24, 36].indices, id: \.self) { index in
                    let height = [30.0, 44, 24, 36][index] * scale
                    VStack(alignment: .leading, spacing: 4 * scale) {
                        Capsule().fill(.secondary).frame(width: 26 * scale, height: 3 * scale)
                        Capsule().fill(.primary).frame(width: 52 * scale, height: 5 * scale)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(6 * scale)
                    .frame(height: height)
                    .cardChrome(cards, cornerRadius: 7 * scale)
                }
            }
            .padding(6 * scale)
        }
        .environment(
            \.colorScheme,
            appearance.colorScheme(
                system: systemColorScheme,
                imageURL: appearance.background.image.url(
                    desktopPictures: desktopPictures, displayID: cutout?.displayID)
            ))
    }
}

// MARK: Background options

/// The settings of the selected background kind.
private struct BackgroundOptions: View {
    @Binding var background: BackgroundSettings

    var body: some View {
        switch background.kind {
        case .none:
            EmptyView()
        case .glass:
            Section {
                Picker("Variant", selection: $background.glass.variant) {
                    ForEach(GlassVariant.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                TintRow(tint: $background.glass.tint)
            } header: {
                Text("Glass")
            } footer: {
                Text("Clear glass is more transparent. It reads best over dark or quiet backgrounds.")
                    .settingsFootnote()
            }
        case .blur:
            Section("Blur") {
                Picker("Material", selection: $background.blur.material) {
                    ForEach(BlurMaterial.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                LabeledContent("Radius") {
                    ValueSlider(value: $background.blur.radius, range: BlurBackground.radiusRange) {
                        "\(Int($0.rounded())) pt"
                    }
                }
                TintRow(tint: $background.blur.tint)
                GrainRow(grain: $background.grain)
            }
        case .color:
            ColorOptions(color: $background.color, grain: $background.grain)
        case .image:
            ImageOptions(image: $background.image, grain: $background.grain)
        }
    }
}

private struct ColorOptions: View {
    @Binding var color: ColorBackground
    @Binding var grain: Double

    var body: some View {
        Section {
            Picker("Fill", selection: $color.fill) {
                ForEach(ColorFill.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            switch color.fill {
            case .solid:
                ColorPicker("Color", selection: $color.color.asColor, supportsOpacity: false)
            case .gradient:
                LabeledContent("Colors") {
                    GradientColorsEditor(colors: $color.gradient)
                }
                LabeledContent("Angle") {
                    ValueSlider(value: $color.angle, range: 0...360) { "\(Int($0.rounded()))°" }
                }
                Toggle(isOn: $color.isAnimated) {
                    Text("Animate")
                    Text("Slowly drifts the gradient. Costs about 9 % CPU while the panel is visible.")
                }
            }
            LabeledContent("Opacity") {
                ValueSlider(value: $color.opacity, range: 0...1)
            }
            GrainRow(grain: $grain)
        } header: {
            Text("Color")
        }
    }
}

/// A row of color wells with buttons to add, remove and reverse colors.
private struct GradientColorsEditor: View {
    @Binding var colors: [RGBAColor]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(colors.indices, id: \.self) { index in
                ColorPicker("Color \(index + 1)", selection: color(at: index).asColor, supportsOpacity: false)
                    .labelsHidden()
            }
            ControlGroup {
                Button("Remove Color", systemImage: "minus") {
                    colors.removeLast()
                }
                .disabled(colors.count <= ColorBackground.gradientColorCount.lowerBound)
                Button("Add Color", systemImage: "plus") {
                    colors.append(colors.last ?? .white)
                }
                .disabled(colors.count >= ColorBackground.gradientColorCount.upperBound)
            }
            .labelStyle(.iconOnly)
            .fixedSize()
            Button("Reverse", systemImage: "arrow.left.arrow.right") {
                colors.reverse()
            }
            .labelStyle(.iconOnly)
            .help("Reverse the gradient")
        }
    }

    /// Bounds-checked, because a well can briefly outlive its color while one is being removed.
    private func color(at index: Int) -> Binding<RGBAColor> {
        Binding {
            colors.indices.contains(index) ? colors[index] : .black
        } set: { newValue in
            if colors.indices.contains(index) { colors[index] = newValue }
        }
    }
}

private struct ImageOptions: View {
    @Binding var image: ImageBackground
    @Binding var grain: Double

    var body: some View {
        Section {
            LabeledContent {
                HStack {
                    if image.path != nil {
                        Button("Use Desktop Picture") { image.path = nil }
                    }
                    Button("Choose…", action: chooseImage)
                }
            } label: {
                Text("Image")
                Text(image.path.map { URL(filePath: $0).lastPathComponent } ?? "Desktop picture")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard
                    let url = urls.first(where: {
                        UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) ?? false
                    })
                else { return false }
                image.path = url.path(percentEncoded: false)
                return true
            }
            TintRow(tint: $image.tint)
            LabeledContent("Blur") {
                ValueSlider(value: $image.blur, range: ImageBackground.blurRange) {
                    ($0 / ImageBackground.blurRange.upperBound).formatted(.percent.precision(.fractionLength(0)))
                }
            }
            LabeledContent("Dim") {
                ValueSlider(value: $image.dim, range: ImageBackground.dimRange)
            }
            LabeledContent("Fade to black") {
                ValueSlider(value: $image.fade, range: ImageBackground.fadeRange)
            }
            GrainRow(grain: $grain)
            EffectRows(effect: $image.effect)
        } header: {
            Text("Image")
        } footer: {
            Text(
                image.path == nil
                    ? "The desktop picture shows exactly the part behind the panel. You can also drop an image file "
                        + "on the Image row."
                    : "You can also drop an image file on the Image row."
            )
            .settingsFootnote()
        }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL.picturesDirectory
        panel.message = "Choose a background image for the panel"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        image.path = url.path(percentEncoded: false)
    }
}

/// One effect, with only the settings it uses.
private struct EffectRows: View {
    @Binding var effect: ImageEffect

    var body: some View {
        Picker("Effect", selection: $effect.kind.animation(Motion.layout)) {
            ForEach(ImageEffectKind.allCases) { kind in
                Text(kind.title).tag(kind)
            }
        }
        if effect.kind.usesSize {
            LabeledContent(effect.kind == .halftone ? "Dot size" : "Cell size") {
                ValueSlider(value: $effect.size, range: ImageEffect.sizeRange) { "\(Int($0.rounded())) pt" }
            }
        }
        if effect.kind.usesLevels {
            Stepper(value: $effect.levels, in: ImageEffect.levelsRange) {
                LabeledContent("Levels", value: "\(effect.levels)")
            }
        }
        if effect.kind.usesColors {
            LabeledContent("Colors") {
                HStack(spacing: 10) {
                    ColorPicker("Shadows", selection: $effect.shadows.asColor, supportsOpacity: false)
                    ColorPicker("Highlights", selection: $effect.highlights.asColor, supportsOpacity: false)
                    Button {
                        (effect.shadows, effect.highlights) = (effect.highlights, effect.shadows)
                    } label: {
                        Image(systemName: "arrow.left.arrow.right")
                    }
                    .buttonStyle(.borderless)
                    .help("Swap the colors")
                }
            }
        }
    }
}

// MARK: Cards and text

private struct CardsSection: View {
    @Binding var appearance: Appearance

    var body: some View {
        Section {
            Picker("Style", selection: $appearance.cards.style) {
                ForEach(CardStyle.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            switch appearance.cards.style {
            case .none:
                EmptyView()
            case .glass, .blur:
                TintRow(tint: $appearance.cards.tint)
            case .solid:
                TintRow(title: "Color", tint: $appearance.cards.fill)
            }
        } header: {
            Text("Cards")
        } footer: {
            if appearance.background.kind == .none && appearance.cards.style == .none {
                Label(
                    "With no background and no cards, text sits directly on the windows behind the panel.",
                    systemImage: "exclamationmark.triangle"
                )
                .settingsFootnote()
            }
        }
    }
}

private struct TextSection: View {
    @Binding var appearance: Appearance
    @Environment(DesktopPictures.self) private var desktopPictures
    @Environment(\.colorScheme) private var systemColorScheme

    var body: some View {
        Section {
            Picker("Text", selection: $appearance.text) {
                ForEach(TextAppearance.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
        } footer: {
            VStack(alignment: .leading, spacing: 14) {
                if appearance.text == .automatic {
                    Text(automaticExplanation).settingsFootnote()
                }
                HStack {
                    Spacer()
                    Button("Restore Defaults") {
                        withAnimation(Motion.layout) { appearance = Appearance() }
                    }
                    .disabled(appearance == Appearance())
                }
            }
        }
    }

    private var automaticExplanation: String {
        let luminance =
            appearance.background.kind == .image
            ? appearance.background.image.url(desktopPictures: desktopPictures).flatMap(BackgroundImageLoader.luminance)
            : nil
        return switch appearance.resolvedText(imageLuminance: luminance) {
        case .automatic: "Automatic follows the system's light or dark mode, like glass and blur do."
        case .light: "Automatic uses light text on this background."
        case .dark: "Automatic uses dark text on this background."
        }
    }
}

// MARK: Controls

/// A color well plus how strongly it's applied.
private struct TintRow: View {
    var title = "Tint"
    @Binding var tint: Tint

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                ColorPicker(title, selection: $tint.color.asColor, supportsOpacity: false)
                    .labelsHidden()
                ValueSlider(value: $tint.amount, range: 0...1)
            }
        }
    }
}

private struct GrainRow: View {
    @Binding var grain: Double

    var body: some View {
        LabeledContent("Grain") {
            ValueSlider(value: $grain, range: BackgroundSettings.grainRange)
        }
    }
}

/// A slider with its value written out next to it, as a percentage unless `label` says otherwise.
private struct ValueSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var label: (Double) -> String = { $0.formatted(.percent.precision(.fractionLength(0))) }

    var body: some View {
        HStack {
            Slider(value: $value, in: range)
            Text(label(value))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
        .frame(minWidth: 220)
    }
}
