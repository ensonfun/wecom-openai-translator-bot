import AppKit
import MacTranslatorCore
import SwiftUI

struct ChatView: View {
    @StateObject private var viewModel = ChatViewModel()
    @State private var showingClearConfirmation = false
    @State private var composerFocused = false
    @AppStorage(AppSettings.composerHeightKey) private var composerHeight = 190.0
    @State private var composerHeightAtDragStart: Double?

    var body: some View {
        GeometryReader { geometry in
            let maximumComposerHeight = max(
                130,
                min(420, geometry.size.height - 360)
            )

            VStack(spacing: 0) {
                header
                Divider().opacity(0.6)
                commandGuide
                conversation
                resizeHandle(maximumComposerHeight: maximumComposerHeight)
                if let error = viewModel.errorMessage {
                    errorBanner(error)
                }
                composer
                    .frame(
                        height: clampedComposerHeight(
                            maximumComposerHeight: maximumComposerHeight
                        )
                    )
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 720, minHeight: 620)
        .onAppear {
            viewModel.refreshCredentials()
            composerFocused = true
        }
        .confirmationDialog(
            "Clear all chat history?",
            isPresented: $showingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear History", role: .destructive) {
                viewModel.clearConversation()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes the conversation from this Mac.")
        }
    }

    private func resizeHandle(maximumComposerHeight: CGFloat) -> some View {
        ZStack {
            Rectangle()
                .fill(Color.clear)
            Capsule()
                .fill(Color.secondary.opacity(0.28))
                .frame(width: 42, height: 4)
        }
        .frame(height: 12)
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering {
                NSCursor.resizeUpDown.set()
            } else {
                NSCursor.arrow.set()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    if composerHeightAtDragStart == nil {
                        composerHeightAtDragStart = Double(
                            clampedComposerHeight(
                                maximumComposerHeight: maximumComposerHeight
                            )
                        )
                    }
                    let startingHeight = composerHeightAtDragStart ?? composerHeight
                    composerHeight = min(
                        Double(maximumComposerHeight),
                        max(130, startingHeight - Double(value.translation.height))
                    )
                }
                .onEnded { _ in
                    composerHeight = Double(
                        clampedComposerHeight(
                            maximumComposerHeight: maximumComposerHeight
                        )
                    )
                    composerHeightAtDragStart = nil
                }
        )
        .help("Drag to resize the conversation and composer")
    }

    private func clampedComposerHeight(maximumComposerHeight: CGFloat) -> CGFloat {
        min(maximumComposerHeight, max(130, CGFloat(composerHeight)))
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.indigo, Color.blue],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "character.bubble.fill")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text("Mac Translator")
                    .font(.headline)
                Text("Translation, correction, and Slack polishing")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if viewModel.isSending {
                ProgressView()
                    .controlSize(.small)
                Text("Generating")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                viewModel.exportHistory()
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.messages.isEmpty)
            .help("Export chat history as JSON")

            SettingsLink {
                Image(systemName: "gearshape")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var commandGuide: some View {
        HStack(spacing: 8) {
            commandPill(mode: .translate, description: "Translate to Chinese")
            commandPill(mode: .correct, description: "Correct + explain")
            commandPill(mode: .slack, description: "Polish team messages")
            Spacer()
            Button {
                showingClearConfirmation = true
            } label: {
                Label("Clear", systemImage: "trash")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .disabled(viewModel.messages.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }

    private func commandPill(mode: CommandMode, description: String) -> some View {
        HStack(spacing: 6) {
            Text(mode.commandHint)
                .font(.system(.caption, design: .monospaced, weight: .semibold))
                .foregroundStyle(mode.tint)
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(mode.tint.opacity(0.09), in: Capsule())
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if viewModel.messages.isEmpty {
                    emptyState
                } else {
                    LazyVStack(spacing: 16) {
                        ForEach(viewModel.messages) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 22)
                }
            }
            .onChange(of: viewModel.messages.last?.text) { _, _ in
                guard let lastID = viewModel.messages.last?.id else { return }
                withAnimation(.easeOut(duration: 0.16)) {
                    proxy.scrollTo(lastID, anchor: .bottom)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "text.bubble")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.secondary)
            VStack(spacing: 6) {
                Text("Start a conversation")
                    .font(.title3.weight(.semibold))
                Text("Type normally to translate into Simplified Chinese, or use t / s followed by a space to switch prompts.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if !viewModel.hasAPIKey {
                SettingsLink {
                    Label("Set OpenAI API Key", systemImage: "key.fill")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 120)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .textSelection(.enabled)
            Spacer()
            Button {
                viewModel.errorMessage = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    private var composer: some View {
        VStack(spacing: 10) {
            HStack {
                Label(viewModel.currentMode.title, systemImage: viewModel.currentMode.icon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(viewModel.currentMode.tint)
                Spacer()
                Text("↩ Send  ·  ⇧↩ / ⌘↩ New line")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            HStack(alignment: .bottom, spacing: 12) {
                ZStack(alignment: .topLeading) {
                    if viewModel.input.isEmpty {
                        Text("Enter text to translate or polish…")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                    ComposerTextView(
                        text: $viewModel.input,
                        isFocused: $composerFocused,
                        onSend: {
                            viewModel.send()
                        }
                    )
                        .frame(minHeight: 60, maxHeight: .infinity)
                }

                if viewModel.isSending {
                    Button {
                        viewModel.cancel()
                    } label: {
                        Image(systemName: "stop.fill")
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .help("Stop generating")
                } else {
                    Button {
                        viewModel.send()
                        composerFocused = true
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 15, weight: .bold))
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Send")
                }
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.primary.opacity(0.08))
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 16)
    }
}

private struct MessageBubble: View {
    let message: ChatMessage
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if message.role == .user {
                Spacer(minLength: 160)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(message.role == .user ? "You" : message.mode.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(message.role == .user ? Color.blue : message.mode.tint)
                    Spacer()
                    if !message.text.isEmpty {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(message.text, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Copy")
                    }
                }

                if message.text.isEmpty {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.small)
                        Text("Generating…")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(formattedText)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .lineSpacing(3)
                }
            }
            .padding(14)
            .frame(
                maxWidth: message.role == .user ? 520 : 760,
                alignment: .leading
            )
            .background(bubbleBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            if message.role == .assistant {
                Spacer(minLength: 40)
            }
        }
    }

    private var formattedText: AttributedString {
        MessageTextFormatter.format(message.text)
    }

    private var bubbleBackground: Color {
        if message.role == .user {
            return Color.blue.opacity(colorScheme == .dark ? 0.30 : 0.18)
        }
        return Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.08)
    }
}

private extension CommandMode {
    var tint: Color {
        switch self {
        case .translate: .blue
        case .correct: .purple
        case .slack: .green
        }
    }

    var icon: String {
        switch self {
        case .translate: "character.book.closed"
        case .correct: "text.badge.checkmark"
        case .slack: "bubble.left.and.bubble.right"
        }
    }
}
