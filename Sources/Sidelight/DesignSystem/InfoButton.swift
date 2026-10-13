import SwiftUI

/// An ⓘ button that shows a longer explanation in a popover, so a setting can keep a short label and the details
/// stay one click away instead of always on screen.
struct InfoButton: View {
    let text: String
    @State private var isPresented = false

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .contentShape(Circle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("More information")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 260, alignment: .leading)
                .padding(12)
        }
    }
}

/// A control's label with an ⓘ next to it: `Toggle(isOn: $on) { InfoLabel("Show seconds", info: "…") }`.
struct InfoLabel: View {
    let title: String
    let info: String

    init(_ title: String, info: String) {
        self.title = title
        self.info = info
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
            InfoButton(info)
        }
    }
}

/// A settings row that shows more rows under it, opened and closed by clicking anywhere on it. In a grouped form,
/// `DisclosureGroup` opens only from its arrow and can draw like a switch.
struct ExpandableRow<Content: View>: View {
    let title: String
    var info: String?
    @ViewBuilder let content: Content
    @State private var isExpanded = false

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
            if let info { InfoButton(info) }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
        }
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(Motion.snappy) { isExpanded.toggle() } }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        if isExpanded {
            content
        }
    }
}
