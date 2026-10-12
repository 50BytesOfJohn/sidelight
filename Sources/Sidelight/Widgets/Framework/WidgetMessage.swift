import SwiftUI

/// What a widget shows in place of its content: not set up, still loading, or a problem. Glanceable layouts have
/// room only for an icon, with the message as its tooltip and VoiceOver label; the others show the title, the
/// detail and an optional button.
struct WidgetMessage: View {
    /// A button under the message, in the regular layout.
    struct Action {
        let title: String
        var isDisabled = false
        /// Clicking the icon in glanceable layouts runs it too.
        var runsOnGlanceClick = false
        let run: () -> Void
    }

    let title: String
    var detail: String?
    let systemImage: String
    let layout: WidgetLayout
    var action: Action?
    /// Compact layouts show a smaller title and leave the detail out, since they have little room.
    var trimsCompact = true
    var detailLineLimit: Int? = 3

    var body: some View {
        let text = [title, detail].compactMap(\.self).joined(separator: ". ")
        if layout.isGlanceable {
            let icon = Image(systemName: systemImage).foregroundStyle(.secondary)
            if let action, action.runsOnGlanceClick {
                icon.opens(action.run).help(text).accessibilityLabel(text)
            } else {
                icon.help(text).accessibilityLabel(text)
            }
        } else {
            let showsMore = layout == .regular || !trimsCompact
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(trimsCompact && layout == .compact ? .system(size: 11) : .callout)
                if let detail, showsMore {
                    Text(detail).font(.caption).lineLimit(detailLineLimit).fixedSize(horizontal: false, vertical: true)
                }
                if let action, layout == .regular {
                    Button(action.title, action: action.run)
                        .controlSize(.small)
                        .disabled(action.isDisabled)
                        .padding(.top, 4)
                }
            }
            .foregroundStyle(.secondary)
            // A button inside has to stay reachable on its own.
            .accessibilityElement(children: action == nil ? .combine : .contain)
        }
    }
}

extension View {
    /// A click runs `action`.
    func opens(_ action: @escaping () -> Void) -> some View {
        contentShape(.rect)
            .onTapGesture(perform: action)
            .accessibilityAddTraits(.isButton)
    }
}
