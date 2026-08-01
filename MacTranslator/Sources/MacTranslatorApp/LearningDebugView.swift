import AppKit
import MacTranslatorCore
import SwiftUI

struct LearningDebugView: View {
    let entries: [LearningDebugEntry]
    let onClear: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: UUID?

    init(
        entries: [LearningDebugEntry],
        onClear: @escaping () -> Void
    ) {
        self.entries = entries
        self.onClear = onClear
        _selectedID = State(initialValue: entries.first?.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "ladybug.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Learn Debug")
                        .font(.headline)
                    Text("Prompts, raw model output, and token usage from this app session")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Clear") {
                    onClear()
                    selectedID = nil
                }
                .disabled(entries.isEmpty)
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(16)

            Divider()

            if entries.isEmpty {
                ContentUnavailableView {
                    Label("No Learn requests yet", systemImage: "ladybug")
                } description: {
                    Text(
                        "Generate or check a Learn batch, then open Debug to inspect "
                            + "the request and response."
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    requestList
                        .frame(minWidth: 230, idealWidth: 270, maxWidth: 330)
                    requestDetail
                        .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(minWidth: 900, minHeight: 650)
        .onChange(of: entries.map(\.id)) { _, ids in
            if selectedID == nil || !ids.contains(selectedID!) {
                selectedID = ids.first
            }
        }
    }

    private var requestList: some View {
        List(entries, selection: $selectedID) { entry in
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor(entry.status))
                        .frame(width: 7, height: 7)
                    Text(flowTitle(entry.flow))
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                }
                Text(entry.model)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Text(entry.startedAt.formatted(date: .omitted, time: .standard))
                    Spacer()
                    if let totalTokens = entry.tokenUsage?.totalTokens {
                        Text("\(totalTokens) tokens")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
            .tag(entry.id)
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private var requestDetail: some View {
        if let entry = selectedEntry {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    requestSummary(entry)
                    debugSection(title: "Instructions / Prompt") {
                        debugText(entry.instructions)
                    }
                    debugSection(title: "Input") {
                        debugText(prettyPrintedJSON(entry.input))
                    }
                    debugSection(title: "LLM Response") {
                        if let response = entry.response, !response.isEmpty {
                            debugText(prettyPrintedJSON(response))
                        } else if entry.status == .running {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Waiting for the model…")
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Text("No response body was captured.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let errorMessage = entry.errorMessage {
                        debugSection(title: "Error") {
                            Text(errorMessage)
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView(
                "Select a request",
                systemImage: "cursorarrow.click"
            )
        }
    }

    private func requestSummary(_ entry: LearningDebugEntry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(flowTitle(entry.flow))
                        .font(.title2.weight(.semibold))
                    Text(entry.id.uuidString)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                Text(entry.status.rawValue.capitalized)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusColor(entry.status))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(
                        statusColor(entry.status).opacity(0.1),
                        in: Capsule()
                    )
            }

            HStack(spacing: 10) {
                summaryItem(title: "Model", value: entry.model)
                summaryItem(title: "Attempt", value: "\(entry.attempt)")
                if let status = entry.openAIStatus {
                    summaryItem(title: "OpenAI status", value: status)
                }
                if entry.pollCount > 0 {
                    summaryItem(title: "Polls", value: "\(entry.pollCount)")
                }
                if let duration = entry.durationMilliseconds {
                    summaryItem(title: "Duration", value: formatDuration(duration))
                }
            }

            if let responseID = entry.openAIResponseID {
                VStack(alignment: .leading, spacing: 2) {
                    Text("OpenAI response ID")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(responseID)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }

            tokenUsageView(entry.tokenUsage)
        }
        .padding(16)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func tokenUsageView(_ usage: LearningTokenUsage?) -> some View {
        if let usage {
            HStack(spacing: 10) {
                summaryItem(title: "Input tokens", value: tokenText(usage.inputTokens))
                summaryItem(title: "Output tokens", value: tokenText(usage.outputTokens))
                summaryItem(title: "Total tokens", value: tokenText(usage.totalTokens))
                if let cached = usage.cachedInputTokens, cached > 0 {
                    summaryItem(title: "Cached", value: "\(cached)")
                }
                if let reasoning = usage.reasoningOutputTokens, reasoning > 0 {
                    summaryItem(title: "Reasoning", value: "\(reasoning)")
                }
            }
        } else {
            Text("Token usage is not available until the request completes.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func summaryItem(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospacedDigit().weight(.medium))
                .textSelection(.enabled)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
    }

    private func debugSection<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func debugText(_ text: String) -> some View {
        ScrollView(.horizontal) {
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: false)
                .padding(12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(nsColor: .textBackgroundColor),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.1))
        }
    }

    private var selectedEntry: LearningDebugEntry? {
        entries.first { $0.id == selectedID } ?? entries.first
    }

    private func flowTitle(_ flow: String) -> String {
        switch flow {
        case "learning_history_analysis":
            return "History analysis"
        case "learning_question_batch_generation":
            return "Question batch"
        case "learning_answer_batch_grading":
            return "Batch grading"
        default:
            return flow.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private func statusColor(_ status: LearningDebugRequestStatus) -> Color {
        switch status {
        case .running:
            return .orange
        case .completed:
            return .green
        case .failed:
            return .red
        }
    }

    private func tokenText(_ value: Int?) -> String {
        value.map(String.init) ?? "—"
    }

    private func formatDuration(_ milliseconds: Int) -> String {
        if milliseconds < 1_000 {
            return "\(milliseconds) ms"
        }
        return String(format: "%.2f s", Double(milliseconds) / 1_000)
    }

    private func prettyPrintedJSON(_ text: String) -> String {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let prettyData = try? JSONSerialization.data(
                  withJSONObject: object,
                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
              ),
              let pretty = String(data: prettyData, encoding: .utf8) else {
            return text
        }
        return pretty
    }
}
