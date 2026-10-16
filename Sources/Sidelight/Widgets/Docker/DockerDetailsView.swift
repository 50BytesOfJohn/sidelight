import Observation
import SidelightCore
import SwiftUI

/// What someone is doing in Docker's details panel: their search, Active or All, and the container they opened.
/// Forgotten when the panel closes; it never changes the widget's settings.
@Observable
final class DockerBrowser {
    let context: DockerContextChoice
    var search = ""
    var scope = DockerScope.active
    /// The container shown in full, if any.
    var expandedID: DockerContainer.ID?

    init(context: DockerContextChoice) {
        self.context = context
    }
}

/// Every container in one context, in the details panel: grouped by Compose project, searchable, with CPU and memory
/// while it's open.
struct DockerDetailsView: View {
    let browser: DockerBrowser
    @Environment(DockerService.self) private var service
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        WidgetClock { now in
            let display = DockerDisplay(service: service, choice: browser.context, isPreview: false, now: now)
            VStack(alignment: .leading, spacing: 0) {
                controls(display)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                HairlineDivider()
                switch display {
                case .message(let message):
                    messageView(message)
                case .containers(let snapshot, let note):
                    if let note {
                        Text(note)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 16)
                            .padding(.top, 8)
                    }
                    list(snapshot, now: now)
                        .opacity(note == nil ? 1 : 0.6)
                }
            }
        }
        .defaultFocus($isSearchFocused, true)
        .onAppear { isSearchFocused = true }
    }

    // MARK: Controls

    private func controls(_ display: DockerDisplay) -> some View {
        @Bindable var browser = browser
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("Search by name, image or port", text: $browser.search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .focused($isSearchFocused)
                    .accessibilityLabel("Search containers")
                if !browser.search.isEmpty {
                    Button {
                        browser.search = ""
                        isSearchFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear the search")
                    .accessibilityLabel("Clear the search")
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.07)))

            HStack(spacing: 8) {
                if case .containers(let snapshot, _) = display {
                    let active = snapshot.containers.count { snapshot.condition(of: $0).isActive }
                    Picker("Show", selection: $browser.scope.animation(Motion.snappy)) {
                        Text("Active \(active)").tag(DockerScope.active)
                        Text("All \(snapshot.containers.count)").tag(DockerScope.all)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .controlSize(.small)
                }
                Spacer(minLength: 4)
                Text(service.displayName(for: browser.context))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    // MARK: List

    @ViewBuilder
    private func list(_ snapshot: DockerSnapshot, now: Date) -> some View {
        let search = DockerSearch(browser.search)
        let groups = snapshot.groups(scope: browser.scope, search: search)
        if groups.isEmpty {
            emptyState(
                search.isEmpty
                    ? (browser.scope == .active ? "No containers running" : "No containers") : "No containers match",
                detail: search.isEmpty
                    ? (browser.scope == .active && !snapshot.containers.isEmpty
                        ? "Choose All to see stopped ones too." : "Containers show here once you create them.")
                    : "Nothing called “\(browser.search)”\(browser.scope == .active ? " among active ones" : "").")
        } else {
            let stats = service.connection(browser.context)?.stats ?? [:]
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(groups) { group in
                        section(group, stats: stats, now: now)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .scrollIndicators(.automatic)
        }
    }

    private func section(_ group: DockerGroup, stats: [String: DockerStats], now: Date) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(group.title)
                    .font(.system(size: 10.5, weight: .semibold).smallCaps())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(group.runningCount) of \(group.containers.count) running")
                    .font(.system(size: 10.5))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
            .padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
            ForEach(group.containers) { container in
                DockerContainerRow(
                    container: container, context: browser.context, condition: group.condition(of: container),
                    stats: stats[container.id],
                    isExpanded: browser.expandedID == container.id, now: now
                ) {
                    withAnimation(Motion.snappy) {
                        browser.expandedID = browser.expandedID == container.id ? nil : container.id
                    }
                }
            }
        }
    }

    private func messageView(_ message: DockerDisplay.Message) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            emptyState(message.title, detail: message.detail)
            if let action = message.action {
                Button(action.title, action: action.run)
                    .controlSize(.small)
                    .padding(.horizontal, 16)
            }
        }
    }

    private func emptyState(_ title: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 12.5, weight: .medium))
            if let detail {
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
