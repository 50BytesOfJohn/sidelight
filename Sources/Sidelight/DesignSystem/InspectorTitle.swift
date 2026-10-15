import SwiftUI

/// What an inspector shows above its first section: an icon, a name and, optionally, a line about it. The Widgets
/// window and the builder head their inspectors with it.
struct InspectorTitle<Icon: View, Accessories: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder let icon: Icon
    @ViewBuilder let accessories: Accessories

    var body: some View {
        HStack(spacing: 10) {
            icon
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.primary).lineLimit(1)
                    accessories
                }
                if let subtitle {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .textCase(nil)
        .padding(.bottom, 6)
    }
}

extension InspectorTitle where Accessories == EmptyView {
    init(title: String, subtitle: String? = nil, @ViewBuilder icon: () -> Icon) {
        self.init(title: title, subtitle: subtitle, icon: icon) { EmptyView() }
    }
}
