import AppKit
import MacTranslatorCore
import SwiftUI

struct ChatHistoryBrowserView: View {
    let messages: [ChatMessage]
    let isLoading: Bool
    let onReload: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var selectedMessageID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if isLoading && messages.isEmpty {
                loadingState
            } else if messages.isEmpty {
                emptyState
            } else {
                historyBrowser
            }
        }
        .frame(minWidth: 900, idealWidth: 1_050, minHeight: 620, idealHeight: 720)
        .onAppear {
            selectFirstVisibleMessageIfNeeded()
        }
        .onChange(of: filteredMessages.map(\.id)) { _, _ in
            selectFirstVisibleMessageIfNeeded()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.blue)

            VStack(alignment: .leading, spacing: 2) {
                Text("Chat History")
                    .font(.title3.weight(.semibold))
                Text(historySummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isLoading {
                ProgressView()
                    .controlSize(.small)
            }

            Button {
                onReload()
            } label: {
                Label("Reload", systemImage: "arrow.clockwise")
            }
            .disabled(isLoading)

            Button("Done") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var historyBrowser: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search all messages", text: $searchText)
                        .textFieldStyle(.plain)
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Clear search")
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color(nsColor: .controlBackgroundColor))

                Divider()

                List(selection: $selectedMessageID) {
                    ForEach(filteredMessages) { message in
                        HistoryMessageRow(message: message)
                            .tag(message.id)
                    }
                }
                .listStyle(.sidebar)

                Divider()
                Text(resultSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
            .frame(minWidth: 310, idealWidth: 370, maxWidth: 460)

            if let selectedMessage {
                HistoryMessageDetail(message: selectedMessage)
                    .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
            } else {
                noSearchResults
                    .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Loading complete chat history…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)
            Text("No chat history")
                .font(.headline)
            Button("Reload") {
                onReload()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noSearchResults: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.secondary)
            Text("No matching messages")
                .font(.headline)
            Text("Try a different word or phrase.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var filteredMessages: [ChatMessage] {
        let newestFirst = Array(messages.reversed())
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return newestFirst }

        return newestFirst.filter { message in
            message.text.localizedCaseInsensitiveContains(query)
                || message.mode.title.localizedCaseInsensitiveContains(query)
                || roleTitle(for: message).localizedCaseInsensitiveContains(query)
        }
    }

    private var selectedMessage: ChatMessage? {
        guard let selectedMessageID else { return nil }
        return filteredMessages.first { $0.id == selectedMessageID }
    }

    private var historySummary: String {
        "\(messages.count.formatted()) messages · newest first"
    }

    private var resultSummary: String {
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "\(messages.count.formatted()) messages"
        }
        return "\(filteredMessages.count.formatted()) of \(messages.count.formatted()) messages"
    }

    private func selectFirstVisibleMessageIfNeeded() {
        let visibleIDs = Set(filteredMessages.map(\.id))
        if let selectedMessageID, visibleIDs.contains(selectedMessageID) {
            return
        }
        selectedMessageID = filteredMessages.first?.id
    }

    private func roleTitle(for message: ChatMessage) -> String {
        message.role == .user ? "You" : "Assistant"
    }
}

private struct HistoryMessageRow: View {
    let message: ChatMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: message.role == .user ? "person.fill" : modeIcon)
                    .foregroundStyle(accentColor)
                Text(message.role == .user ? "You" : message.mode.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(accentColor)
                Spacer()
                Text(dateLabel)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Text(message.text.isEmpty ? "(Empty response)" : message.text)
                .font(.callout)
                .foregroundStyle(message.text.isEmpty ? .secondary : .primary)
                .lineLimit(2)
        }
        .padding(.vertical, 5)
    }

    private var accentColor: Color {
        if message.role == .user {
            return .blue
        }
        switch message.mode {
        case .translate: return .blue
        case .correct: return .purple
        case .slack: return .green
        }
    }

    private var modeIcon: String {
        switch message.mode {
        case .translate: return "character.book.closed"
        case .correct: return "text.badge.checkmark"
        case .slack: return "bubble.left.and.bubble.right"
        }
    }

    private var dateLabel: String {
        guard message.createdAt.timeIntervalSince1970 > 0 else {
            return "Imported"
        }
        return message.createdAt.formatted(date: .abbreviated, time: .shortened)
    }
}

private struct HistoryMessageDetail: View {
    let message: ChatMessage

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(message.role == .user ? "You" : message.mode.title)
                        .font(.headline)
                    Text(metadata)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message.text, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .disabled(message.text.isEmpty)
            }
            .padding(16)

            Divider()

            ScrollView {
                Text(MessageTextFormatter.format(message.text))
                    .textSelection(.enabled)
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(22)
            }
        }
    }

    private var metadata: String {
        let role = message.role == .user ? "User message" : "Assistant response"
        guard message.createdAt.timeIntervalSince1970 > 0 else {
            return "\(role) · \(message.mode.title) · Imported history"
        }
        return "\(role) · \(message.mode.title) · \(message.createdAt.formatted(date: .long, time: .standard))"
    }
}
