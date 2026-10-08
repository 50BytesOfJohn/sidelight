import SwiftUI
import WebKit

enum WebWidget: PanelWidget {
    static let meta = WidgetMeta(kind: "web", title: "HTML widget", icon: "globe", tint: .indigo,
                                 summary: "Local widget.html in a WKWebView (cost test for web widgets).")

    static func content(_ ctx: WidgetContext) -> some View {
        if ctx.preview {
            // don't spawn WebKit processes for every preview in the manager
            Label("WKWebView · widget.html", systemImage: "globe").font(.system(size: ctx.size == .minimal ? 9 : 11)).foregroundStyle(.secondary)
                .labelStyle(.iconOnlyIfMinimal(ctx.size == .minimal || ctx.bar))
        } else if ctx.size == .minimal || ctx.bar {
            Image(systemName: "globe").font(.system(size: 16)).foregroundStyle(.secondary)
        } else {
            HTMLView(zoom: ctx.size == .regular ? 1 : 0.72).frame(height: ctx.size == .regular ? 70 : 56)
        }
    }

    static func settings(_ s: Binding<WidgetSettings>) -> some View {
        Text("Hidden as an icon in minimal layouts; off in bars by default.").font(.callout).foregroundStyle(.secondary)
    }
}

extension LabelStyle where Self == IconOnlyIfMinimal {
    static func iconOnlyIfMinimal(_ on: Bool) -> IconOnlyIfMinimal { IconOnlyIfMinimal(on: on) }
}
struct IconOnlyIfMinimal: LabelStyle {
    let on: Bool
    func makeBody(configuration: Configuration) -> some View {
        if on { configuration.icon.font(.system(size: 16)) } else { HStack(spacing: 5) { configuration.icon; configuration.title } }
    }
}

struct HTMLView: NSViewRepresentable {
    var zoom: CGFloat = 1
    func makeNSView(context: Context) -> WKWebView {
        let wv = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        wv.setValue(false, forKey: "drawsBackground")
        wv.pageZoom = zoom
        if let url = Bundle.main.url(forResource: "widget", withExtension: "html") {
            wv.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return wv
    }
    func updateNSView(_ nsView: WKWebView, context: Context) { if nsView.pageZoom != zoom { nsView.pageZoom = zoom } }
}
