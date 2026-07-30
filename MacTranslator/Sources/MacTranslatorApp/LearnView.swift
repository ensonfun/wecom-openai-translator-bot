import MacTranslatorCore
import SwiftUI

struct LearnView: View {
    let isActive: Bool

    @StateObject private var viewModel = LearningViewModel()
    @State private var isShowingDebug = false

    init(isActive: Bool = true) {
        self.isActive = isActive
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.6)

            if let error = viewModel.errorMessage {
                errorBanner(error)
            }

            if viewModel.isLoading, viewModel.dashboard == nil {
                loadingState
            } else {
                ScrollView {
                    if let session = viewModel.dashboard?.activeSession {
                        practiceView(session)
                    } else {
                        readyView
                    }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            if isActive {
                viewModel.start()
            }
        }
        .onChange(of: isActive) { _, active in
            if active {
                viewModel.start()
            }
        }
        .sheet(isPresented: $isShowingDebug) {
            LearningDebugView(
                entries: viewModel.debugEntries,
                onClear: viewModel.clearDebugEntries
            )
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.orange, Color.pink],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "character.book.closed.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text("English Expression Practice")
                    .font(.headline)
                HStack(spacing: 6) {
                    if viewModel.isSyncing {
                        ProgressView().controlSize(.mini)
                    }
                    Text(viewModel.syncMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button {
                viewModel.reloadDebugEntries()
                isShowingDebug = true
            } label: {
                Image(systemName: "ladybug")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("Show Learn debug information")

            Button {
                Task { await viewModel.syncHistory() }
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isSyncing || viewModel.isWorking || !viewModel.hasAPIKey)
            .help("Analyze recent chats")

            Button {
                viewModel.exportProgress()
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .disabled((viewModel.dashboard?.analyzedTurnCount ?? 0) == 0)
            .help("Export learning event archive")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var loadingState: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text("Preparing five expressions from your recent chats…")
                .font(.headline)
            Text("Only new chat history is analyzed.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var readyView: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let completed = viewModel.dashboard?.latestCompletedSession,
               !completed.summary.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Last practice saved", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                    Text(completed.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            }

            VStack(alignment: .leading, spacing: 12) {
                Label("Practise something you actually say", systemImage: "bubble.left.and.text.bubble.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                Text("Review what is due, then learn something new")
                    .font(.title2.weight(.semibold))
                Text(
                    "Each daily plan mixes spaced review with new material from your chats. "
                        + "If a batch is difficult, Learn keeps the same skill and strengthens it first."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)

                if !viewModel.hasAPIKey {
                    SettingsLink {
                        Label("Open shared API settings", systemImage: "key.fill")
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button {
                        viewModel.startOrResumeSession()
                    } label: {
                        if viewModel.isWorking {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Start practising", systemImage: "play.fill")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(viewModel.isWorking || viewModel.isSyncing)
                }
            }
            .padding(22)
            .background(
                LinearGradient(
                    colors: [Color.orange.opacity(0.12), Color.pink.opacity(0.06)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 16)
            )
        }
        .padding(22)
        .frame(maxWidth: 860, alignment: .leading)
        .frame(maxWidth: .infinity)
    }

    private func practiceView(_ session: LearningSessionSnapshot) -> some View {
        let batch = currentBatch(in: session)
        let completedRounds = LearningEngine.completedBatchCount(in: session)
        let currentRound = completedRounds + (batch.allSatisfy { $0.grade != nil } ? 0 : 1)
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(
                        currentRound > 1
                            ? "Strengthening round \(currentRound)"
                            : session.focusPlanKind.title
                    )
                        .font(.title2.weight(.semibold))
                    Text(
                        currentRound > 1
                            ? "Fresh variations for \(session.focusTitle)"
                            : session.focusReason
                    )
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Finish") {
                    viewModel.endSession()
                }
                .buttonStyle(.borderless)
                .disabled(viewModel.isWorking)
            }

            if !batch.isEmpty {
                batchCard(batch)
            } else {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Preparing five expressions…")
                }
                .padding(24)
            }
        }
        .padding(22)
        .frame(maxWidth: 860, alignment: .leading)
        .frame(maxWidth: .infinity)
    }

    private func batchCard(_ batch: [LearningAttemptSnapshot]) -> some View {
        let isGraded = batch.allSatisfy { $0.grade != nil }
        let hasSubmittedAnswers = batch.contains { $0.answer != nil }

        return VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label(
                    isGraded ? "Batch feedback" : "Complete all five, then check once",
                    systemImage: isGraded ? "checkmark.seal.fill" : "square.stack.3d.up.fill"
                )
                .font(.headline)
                Spacer()
                Text("\(batch.count) expressions")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if isGraded {
                batchResultSummary(batch)

                ForEach(Array(batch.enumerated()), id: \.element.id) { index, attempt in
                    gradedExpression(attempt, index: index)
                }

                HStack {
                    Button("Finish for now") {
                        viewModel.endSession()
                    }
                    .disabled(viewModel.isWorking)

                    Spacer()

                    Button {
                        viewModel.continueSession()
                    } label: {
                        if viewModel.isWorking {
                            ProgressView().controlSize(.small)
                        } else {
                            Label(
                                continueButtonTitle(for: batch),
                                systemImage: continueButtonIcon(for: batch)
                            )
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(viewModel.isWorking)
                }
            } else if hasSubmittedAnswers {
                ForEach(Array(batch.enumerated()), id: \.element.id) { index, attempt in
                    submittedExpression(attempt, index: index)
                }

                HStack(spacing: 10) {
                    if viewModel.isWorking {
                        ProgressView()
                    }
                    Text(
                        viewModel.isWorking
                            ? "Checking all five expressions together…"
                            : "Your batch is saved and still needs to be checked."
                    )
                    .foregroundStyle(.secondary)
                    Spacer()
                    if !viewModel.isWorking {
                        Button("Retry checking") {
                            viewModel.startOrResumeSession()
                        }
                    }
                }
                .padding(.vertical, 20)
            } else {
                ForEach(Array(batch.enumerated()), id: \.element.id) { index, attempt in
                    expressionEditor(attempt, index: index)
                }

                HStack {
                    Button("Replace batch") {
                        viewModel.replaceBatch()
                    }
                    .disabled(viewModel.isWorking)

                    Spacer()

                    Button {
                        viewModel.submitBatch()
                    } label: {
                        if viewModel.isWorking {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Check all five", systemImage: "checkmark.circle.fill")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!allAnswersComplete(in: batch) || viewModel.isWorking)
                }
            }
        }
        .padding(22)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.primary.opacity(0.09))
        }
    }

    private func batchResultSummary(
        _ batch: [LearningAttemptSnapshot]
    ) -> some View {
        let successfulCount = successfulCount(in: batch)
        let session = viewModel.dashboard?.activeSession
        let completedBatchCount = session.map {
            LearningEngine.completedBatchCount(in: $0)
        } ?? 1
        let outcome = LearningEngine.batchOutcome(
            successfulCount: successfulCount,
            completedBatchCount: completedBatchCount
        )
        let nextReview = session?.focusKnowledgePointID.flatMap { focusID in
            viewModel.dashboard?.knowledgePoints.first { $0.id == focusID }?.dueAt
        }
        let nextReviewText = nextReview.map {
            " Next review: \($0.formatted(date: .abbreviated, time: .omitted))."
        } ?? ""
        let message: String
        let color: Color
        let icon: String
        switch outcome {
        case .passed:
            message = "\(successfulCount)/\(batch.count) passed. This is today's pass, "
                + "not permanent mastery; Learn will bring it back after a delay."
                + nextReviewText
            color = .green
            icon = "calendar.badge.checkmark"
        case .reinforce:
            message = "\(successfulCount)/\(batch.count) passed. The next batch will keep "
                + "this skill and target the issues above with fresh variations."
            color = .orange
            icon = "arrow.triangle.2.circlepath"
        case .paused:
            message = "\(successfulCount)/\(batch.count) passed after three rounds. "
                + "This skill is scheduled for priority review."
                + nextReviewText
            color = .orange
            icon = "calendar.badge.clock"
        }
        return Label(message, systemImage: icon)
            .font(.callout.weight(.medium))
            .foregroundStyle(color)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
    }

    private func successfulCount(
        in batch: [LearningAttemptSnapshot]
    ) -> Int {
        batch.filter {
            guard let grade = $0.grade else { return false }
            return grade.targetDemonstrated
                && (grade.verdict == .correct || grade.verdict == .acceptable)
        }.count
    }

    private func continueButtonTitle(
        for batch: [LearningAttemptSnapshot]
    ) -> String {
        guard let session = viewModel.dashboard?.activeSession else {
            return "Continue today's plan"
        }
        let outcome = LearningEngine.batchOutcome(
            successfulCount: successfulCount(in: batch),
            completedBatchCount: LearningEngine.completedBatchCount(in: session)
        )
        return outcome == .reinforce
            ? "Strengthen this skill"
            : "Continue today's plan"
    }

    private func continueButtonIcon(
        for batch: [LearningAttemptSnapshot]
    ) -> String {
        guard let session = viewModel.dashboard?.activeSession else {
            return "arrow.right"
        }
        let outcome = LearningEngine.batchOutcome(
            successfulCount: successfulCount(in: batch),
            completedBatchCount: LearningEngine.completedBatchCount(in: session)
        )
        return outcome == .reinforce
            ? "arrow.triangle.2.circlepath"
            : "arrow.right"
    }

    private func expressionEditor(
        _ attempt: LearningAttemptSnapshot,
        index: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            expressionPrompt(attempt, index: index)

            let answer = answerBinding(for: attempt.question.id)
            ZStack(alignment: .topLeading) {
                if answer.wrappedValue.isEmpty {
                    Text("Write your English expression…")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 10)
                        .allowsHitTesting(false)
                }
                TextEditor(text: answer)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(6)
            }
            .frame(minHeight: 90)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.primary.opacity(0.12))
            }

        }
        .padding(16)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }

    private func submittedExpression(
        _ attempt: LearningAttemptSnapshot,
        index: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            expressionPrompt(attempt, index: index)
            feedbackSection(title: "Your expression") {
                Text(attempt.answer ?? "")
                    .textSelection(.enabled)
            }
        }
        .padding(16)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }

    private func gradedExpression(
        _ attempt: LearningAttemptSnapshot,
        index: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            expressionPrompt(attempt, index: index)
            if let grade = attempt.grade {
                feedbackView(grade, answer: attempt.answer ?? "")
            }
        }
        .padding(16)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }

    private func expressionPrompt(
        _ attempt: LearningAttemptSnapshot,
        index: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Expression \(index + 1)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                if !attempt.question.context.isEmpty {
                    Text(attempt.question.context)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text(attempt.question.prompt)
                .font(.title3.weight(.medium))
                .lineSpacing(4)
                .textSelection(.enabled)
        }
    }

    private func answerBinding(for questionID: UUID) -> Binding<String> {
        Binding(
            get: { viewModel.batchAnswers[questionID] ?? "" },
            set: { viewModel.batchAnswers[questionID] = $0 }
        )
    }

    private func allAnswersComplete(
        in batch: [LearningAttemptSnapshot]
    ) -> Bool {
        batch.count == LearningEngine.expressionBatchSize
            && batch.allSatisfy {
                !(viewModel.batchAnswers[$0.question.id] ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
            }
    }

    private func currentBatch(
        in session: LearningSessionSnapshot
    ) -> [LearningAttemptSnapshot] {
        guard let batchID = session.attempts.last?.question.batchID else {
            return []
        }
        return session.attempts.filter {
            $0.question.batchID == batchID
        }.sorted {
            ($0.question.batchIndex ?? 0) < ($1.question.batchIndex ?? 0)
        }
    }

    private func feedbackView(
        _ grade: AnswerGradedPayload,
        answer: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(grade.verdict.title, systemImage: verdictIcon(grade.verdict))
                .font(.headline)
                .foregroundStyle(verdictColor(grade.verdict))

            feedbackSection(title: "Your expression") {
                Text(answer)
                    .textSelection(.enabled)
            }

            if !grade.correctedAnswer.isEmpty {
                feedbackSection(title: "Recommended expression") {
                    Text(grade.correctedAnswer)
                        .textSelection(.enabled)
                }
                .padding(12)
                .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }

            if !grade.alternativeAnswers.isEmpty {
                feedbackSection(title: "Natural alternatives") {
                    ForEach(Array(grade.alternativeAnswers.enumerated()), id: \.offset) { _, answer in
                        Text("• \(answer)")
                            .textSelection(.enabled)
                    }
                }
            }

            if !grade.issues.isEmpty {
                feedbackSection(title: "Key issues") {
                    ForEach(Array(grade.issues.enumerated()), id: \.offset) { _, issue in
                        Label(issue, systemImage: "smallcircle.filled.circle")
                            .font(.callout)
                    }
                }
            }

            if !grade.patterns.isEmpty {
                feedbackSection(title: "Useful sentence patterns") {
                    ForEach(Array(grade.patterns.enumerated()), id: \.offset) { _, pattern in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(pattern.pattern)
                                .font(.body.weight(.semibold))
                                .textSelection(.enabled)
                            Text(pattern.meaningZH)
                                .font(.callout)
                            Text(pattern.example)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, 3)
                    }
                }
            }

            feedbackSection(title: "Focused explanation") {
                if grade.keyExplanationsZH.isEmpty {
                    Text(grade.explanationZH)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                } else {
                    ForEach(Array(grade.keyExplanationsZH.enumerated()), id: \.offset) { _, point in
                        Text("• \(point)")
                            .lineSpacing(3)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .padding(16)
        .background(verdictColor(grade.verdict).opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(verdictColor(grade.verdict).opacity(0.16))
        }
    }

    private func feedbackSection<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
        .padding(.top, 10)
    }

    private func verdictColor(_ verdict: LearningVerdict) -> Color {
        switch verdict {
        case .correct: .green
        case .acceptable: .blue
        case .needsImprovement: .orange
        case .incorrect: .red
        case .ungradable: .secondary
        }
    }

    private func verdictIcon(_ verdict: LearningVerdict) -> String {
        switch verdict {
        case .correct: "checkmark.circle.fill"
        case .acceptable: "checkmark.seal.fill"
        case .needsImprovement: "pencil.circle.fill"
        case .incorrect: "xmark.circle.fill"
        case .ungradable: "questionmark.circle.fill"
        }
    }
}
