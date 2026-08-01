import MacTranslatorCore
import SwiftUI

private enum MainDestination: String, CaseIterable, Identifiable {
    case chat
    case learn

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chat: "Chat"
        case .learn: "Learn"
        }
    }

    var icon: String {
        switch self {
        case .chat: "bubble.left.and.text.bubble.right"
        case .learn: "graduationcap"
        }
    }
}

struct MainContentView: View {
    @State private var destination = MainDestination.chat
    @AppStorage(AppSettings.mainSidebarExpandedKey) private var isSidebarExpanded = true

    var body: some View {
        HStack(spacing: 0) {
            navigationRail
            Divider()

            ZStack {
                ChatView()
                    .opacity(destination == .chat ? 1 : 0)
                    .allowsHitTesting(destination == .chat)
                    .accessibilityHidden(destination != .chat)

                LearnView(isActive: destination == .learn)
                    .opacity(destination == .learn ? 1 : 0)
                    .allowsHitTesting(destination == .learn)
                    .accessibilityHidden(destination != .learn)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: isSidebarExpanded)
        .frame(minWidth: 780, minHeight: 620)
        .onAppear {
            DiagnosticLogger.shared.event(
                "main_window_appeared",
                component: "navigation",
                details: [
                    "destination": .string(destination.rawValue),
                    "sidebar_expanded": .boolean(isSidebarExpanded)
                ]
            )
        }
        .onChange(of: destination) { _, newValue in
            DiagnosticLogger.shared.event(
                "main_destination_changed",
                component: "navigation",
                details: ["destination": .string(newValue.rawValue)]
            )
        }
        .onChange(of: isSidebarExpanded) { _, newValue in
            DiagnosticLogger.shared.event(
                "main_sidebar_toggled",
                component: "navigation",
                details: ["expanded": .boolean(newValue)]
            )
        }
    }

    private var navigationRail: some View {
        VStack(spacing: 6) {
            Button {
                isSidebarExpanded.toggle()
            } label: {
                Image(systemName: isSidebarExpanded ? "sidebar.left" : "sidebar.right")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .frame(
                maxWidth: .infinity,
                alignment: isSidebarExpanded ? .trailing : .center
            )
            .help(isSidebarExpanded ? "Collapse sidebar" : "Expand sidebar")
            .accessibilityLabel(isSidebarExpanded ? "Collapse sidebar" : "Expand sidebar")
            .padding(.horizontal, isSidebarExpanded ? 10 : 0)
            .padding(.top, 8)
            .padding(.bottom, 2)

            ForEach(MainDestination.allCases) { item in
                destinationButton(item)
            }

            Spacer(minLength: 12)

            SettingsLink {
                navigationLabel(title: "Settings", icon: "gearshape")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Settings")
            .accessibilityLabel("Settings")
            .padding(.bottom, 10)
        }
        .padding(.horizontal, 7)
        .frame(width: isSidebarExpanded ? 164 : 52)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.62))
    }

    private func destinationButton(_ item: MainDestination) -> some View {
        Button {
            destination = item
        } label: {
            navigationLabel(title: item.title, icon: item.icon)
        }
        .buttonStyle(.plain)
        .foregroundStyle(destination == item ? Color.accentColor : Color.primary)
        .background(
            destination == item ? Color.accentColor.opacity(0.12) : Color.clear,
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .help(item.title)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(destination == item ? .isSelected : [])
    }

    private func navigationLabel(title: String, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .frame(width: 24, height: 24)

            if isSidebarExpanded {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, isSidebarExpanded ? 10 : 7)
        .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
    }
}
