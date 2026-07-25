import MacTranslatorCore
import SwiftUI

struct LearnView: View {
    @StateObject private var viewModel = LearningViewModel()
    @FocusState private var answerFocused: Bool

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
                        sessionView(session)
                    } else {
                        learnHome
                    }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            viewModel.start()
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
                Image(systemName: "graduationcap.fill")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text("Personal English Teacher")
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
                Task { await viewModel.syncHistory() }
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isSyncing || viewModel.isWorking || !viewModel.hasAPIKey)
            .help("Analyze new t/s chats")

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
            Text("Loading your teacher…")
                .font(.headline)
            Text("Your profile is rebuilt from the local learning event history.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var learnHome: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let completed = viewModel.dashboard?.latestCompletedSession,
               !completed.summary.isEmpty {
                sessionSummaryCard(completed)
            }

            if let focus = viewModel.dashboard?.recommendedFocus {
                focusCard(focus)
            } else {
                diagnosticCard
            }

            metrics

            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Ready for a short session?")
                        .font(.headline)
                    Text("One question at a time · usually 4–7 questions")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
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
                            Label("Start session", systemImage: "play.fill")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(viewModel.isWorking || viewModel.isSyncing)
                }
            }
            .padding(18)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))

            profileSection
        }
        .padding(22)
        .frame(maxWidth: 900, alignment: .leading)
        .frame(maxWidth: .infinity)
    }

    private func focusCard(_ focus: KnowledgePointSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Today's focus", systemImage: "scope")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                Spacer()
                Text(focus.lifecycle.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(focus.title)
                .font(.title2.weight(.semibold))
            Text(focusReason(focus))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                ProgressView(value: focus.mastery)
                    .tint(.orange)
                Text("\(Int((focus.mastery * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if !focus.sourceExcerpt.isEmpty {
                Label("Seen in your real writing: “\(focus.sourceExcerpt)”", systemImage: "text.quote")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(20)
        .background(
            LinearGradient(
                colors: [Color.orange.opacity(0.13), Color.pink.opacity(0.07)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 16)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.orange.opacity(0.20))
        }
    }

    private var diagnosticCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Build your first learning profile", systemImage: "sparkles")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
            Text("A short diagnostic will calibrate the first lesson.")
                .font(.title3.weight(.semibold))
            Text(
                viewModel.dashboard?.analyzedTurnCount == 0
                    ? "Use t or s in Chat, then come back here. Chinese drafts help select useful topics; only your English writing counts as proficiency evidence."
                    : "No recurring weakness is strong enough yet, so the teacher will start broadly and refine the profile from your answers."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding(20)
        .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 16))
    }

    private var metrics: some View {
        HStack(spacing: 12) {
            metric(
                value: "\(viewModel.dashboard?.analyzedTurnCount ?? 0)",
                label: "Chats analyzed",
                icon: "bubble.left.and.text.bubble.right"
            )
            metric(
                value: "\(viewModel.dashboard?.eligibleEnglishTurnCount ?? 0)",
                label: "English samples",
                icon: "character.book.closed"
            )
            metric(
                value: "\(viewModel.dashboard?.knowledgePoints.count ?? 0)",
                label: "Knowledge points",
                icon: "point.3.connected.trianglepath.dotted"
            )
        }
    }

    private func metric(value: String, label: String, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.orange)
                .frame(width: 28, height: 28)
                .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.headline.monospacedDigit())
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }

    private var profileSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Your learning profile")
                    .font(.headline)
                Spacer()
                Text(profileConfidence)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let points = viewModel.dashboard?.knowledgePoints, !points.isEmpty {
                ForEach(Array(points.prefix(8))) { point in
                    knowledgeRow(point)
                }
            } else {
                Text("Your profile will appear after the first t/s analysis or learning session.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }
        }
        .padding(18)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
    }

    private func knowledgeRow(_ point: KnowledgePointSnapshot) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(point.title)
                        .font(.subheadline.weight(.medium))
                    Text(point.dimension.title)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                }
                ProgressView(value: point.mastery)
                    .tint(tint(for: point.lifecycle))
            }
            Text("\(Int((point.mastery * 100).rounded()))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
            Text(point.lifecycle.title)
                .font(.caption)
                .foregroundStyle(tint(for: point.lifecycle))
                .frame(width: 90, alignment: .trailing)
        }
    }

    private func sessionView(_ session: LearningSessionSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(session.focusTitle)
                        .font(.title2.weight(.semibold))
                    Text(session.focusReason)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("End session") {
                    viewModel.endSession()
                }
                .buttonStyle(.borderless)
                .disabled(viewModel.isWorking)
            }

            if let attempt = session.attempts.last {
                questionCard(attempt, session: session)
            } else {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Preparing your first question…")
                }
                .padding(24)
            }
        }
        .padding(22)
        .frame(maxWidth: 860, alignment: .leading)
        .frame(maxWidth: .infinity)
    }

    private func questionCard(
        _ attempt: LearningAttemptSnapshot,
        session: LearningSessionSnapshot
    ) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label(
                    "Question \(attempt.question.ordinal)",
                    systemImage: "questionmark.bubble"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
                Spacer()
                Text(attempt.question.type.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !attempt.question.context.isEmpty {
                Text(attempt.question.context)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Text(attempt.question.prompt)
                .font(.title3.weight(.medium))
                .textSelection(.enabled)

            if let grade = attempt.grade {
                feedbackView(grade, answer: attempt.answer ?? "")

                HStack {
                    Spacer()
                    Button {
                        viewModel.continueSession()
                    } label: {
                        if viewModel.isWorking {
                            ProgressView().controlSize(.small)
                        } else {
                            Label(nextButtonTitle(session), systemImage: "arrow.right")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(viewModel.isWorking)
                }
            } else if attempt.answer != nil {
                HStack(spacing: 10) {
                    if viewModel.isWorking {
                        ProgressView()
                    }
                    Text(
                        viewModel.isWorking
                            ? "Checking your answer and preparing an explanation…"
                            : "Your answer is saved and still needs to be graded."
                    )
                    .foregroundStyle(.secondary)
                    Spacer()
                    if !viewModel.isWorking {
                        Button("Retry grading") {
                            viewModel.startOrResumeSession()
                        }
                    }
                }
                .padding(.vertical, 20)
            } else {
                answerEditor(attempt)
            }
        }
        .padding(22)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.primary.opacity(0.09))
        }
    }

    private func answerEditor(_ attempt: LearningAttemptSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack(alignment: .topLeading) {
                if viewModel.answer.isEmpty {
                    Text("Write your answer in English…")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 10)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $viewModel.answer)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .focused($answerFocused)
            }
            .frame(minHeight: 110)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.primary.opacity(0.12))
            }

            if attempt.hintUsed {
                Label(attempt.question.hint, systemImage: "lightbulb.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
            }

            HStack {
                Button {
                    viewModel.requestHint()
                } label: {
                    Label(attempt.hintUsed ? "Hint shown" : "Hint", systemImage: "lightbulb")
                }
                .disabled(attempt.hintUsed || viewModel.isWorking)

                Button("Skip") {
                    viewModel.skipQuestion()
                }
                .disabled(viewModel.isWorking)

                Spacer()

                Button {
                    viewModel.submitAnswer()
                } label: {
                    if viewModel.isWorking {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Check answer", systemImage: "checkmark.circle.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(
                    viewModel.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || viewModel.isWorking
                )
            }
        }
        .onAppear {
            answerFocused = true
        }
    }

    private func feedbackView(
        _ grade: AnswerGradedPayload,
        answer: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: verdictIcon(grade.verdict))
                Text(grade.verdict.title)
                    .font(.headline)
                Spacer()
                Text("\(Int((grade.confidence * 100).rounded()))% confidence")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(verdictColor(grade.verdict))

            VStack(alignment: .leading, spacing: 5) {
                Text("Your answer")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(answer)
                    .textSelection(.enabled)
            }

            if !grade.correctedAnswer.isEmpty, grade.correctedAnswer != answer {
                VStack(alignment: .leading, spacing: 5) {
                    Text("A stronger answer")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(grade.correctedAnswer)
                        .textSelection(.enabled)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }

            Text(grade.explanationZH)
                .lineSpacing(3)
                .textSelection(.enabled)

            if !grade.issues.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(grade.issues.enumerated()), id: \.offset) { _, issue in
                        Label(issue, systemImage: "smallcircle.filled.circle")
                            .font(.callout)
                    }
                }
            }
        }
        .padding(16)
        .background(verdictColor(grade.verdict).opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(verdictColor(grade.verdict).opacity(0.18))
        }
    }

    private func sessionSummaryCard(_ session: LearningSessionSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Last session", systemImage: "checkmark.seal.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
            Text(session.focusTitle)
                .font(.headline)
            Text(session.summary)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
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

    private var profileConfidence: String {
        let count = viewModel.dashboard?.eligibleEnglishTurnCount ?? 0
        switch count {
        case 0..<10: return "Gathering evidence"
        case 10..<30: return "Provisional profile"
        case 30..<100: return "Developing confidence"
        default: return "High-confidence profile"
        }
    }

    private func focusReason(_ point: KnowledgePointSnapshot) -> String {
        if point.realChatErrorCount > 0 {
            return "Selected because it appeared in \(point.realChatErrorCount) real t/s message"
                + (point.realChatErrorCount == 1 ? "." : "s.")
        }
        if let due = point.dueAt, due <= Date() {
            return "This knowledge point is due for review."
        }
        return "The teacher selected this to strengthen your current profile."
    }

    private func nextButtonTitle(_ session: LearningSessionSnapshot) -> String {
        if session.successfulAttemptCount >= 2,
           session.completedQuestionTypes.count >= 2 {
            return "Finish session"
        }
        if session.consecutiveFailureCount >= 2 {
            return "Save and review later"
        }
        return "Next question"
    }

    private func tint(for state: KnowledgeLifecycleState) -> Color {
        switch state {
        case .maintained: .green
        case .masteryCandidate, .consolidating: .blue
        case .lapsed, .weaknessDetected: .orange
        case .learning: .purple
        case .unobserved: .secondary
        }
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
