import AppKit
import SidelightCore
import SwiftUI

/// `NSVisualEffectView` blur, optionally with a custom blur radius.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    /// `nil` keeps the material's own radius.
    var blurRadius: Double?

    func makeNSView(context: Context) -> BlurRadiusEffectView {
        let view = BlurRadiusEffectView()
        view.state = .active
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: BlurRadiusEffectView, context: Context) {
        view.material = material
        view.blendingMode = blendingMode
        view.blurRadius = blurRadius
        // Follow the SwiftUI color scheme (e.g. forced light text), not just the window's appearance.
        view.appearance = NSAppearance(named: context.environment.colorScheme == .dark ? .darkAqua : .aqua)
    }
}

extension VisualEffectBackground {
    /// The background or card material for a ``BlurMaterial``.
    init(_ material: BlurMaterial, blendingMode: NSVisualEffectView.BlendingMode = .behindWindow, radius: Double? = nil)
    {
        let nsMaterial: NSVisualEffectView.Material =
            switch material {
            case .thin: .fullScreenUI
            case .regular: .popover
            case .thick: .underWindowBackground
            case .dark: .hudWindow
            }
        self.init(material: nsMaterial, blendingMode: blendingMode, blurRadius: radius)
    }
}

/// Changes the radius of the Gaussian blur inside `NSVisualEffectView`.
///
/// AppKit has no public API for this. The view draws with a private `CABackdropLayer` whose `gaussianBlur` filter
/// has an `inputRadius` (30 for every system material), so we set that by key path after AppKit (re)builds its
/// layers. If a future macOS renames anything, the key path matches nothing and the material keeps its own blur.
final class BlurRadiusEffectView: NSVisualEffectView {
    var blurRadius: Double? {
        didSet {
            if blurRadius != oldValue { applyBlurRadius() }
        }
    }

    override func layout() {
        super.layout()
        applyBlurRadius()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyBlurRadius()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyBlurRadius()
    }

    private func applyBlurRadius() {
        guard let blurRadius, let layer else { return }
        for backdrop in Self.backdropLayers(in: layer) {
            backdrop.setValue(blurRadius, forKeyPath: "filters.gaussianBlur.inputRadius")
        }
    }

    private static func backdropLayers(in layer: CALayer) -> [CALayer] {
        var found = NSStringFromClass(type(of: layer)) == "CABackdropLayer" ? [layer] : []
        for sublayer in layer.sublayers ?? [] {
            found += backdropLayers(in: sublayer)
        }
        return found
    }
}
