import Darwin
import Foundation
import MacTranslatorCore
import Security

var failures = 0

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if condition() {
        print("✓ \(message)")
    } else {
        failures += 1
        print("✗ \(message)")
    }
}

final class OpenAIStubURLProtocol: URLProtocol {
    enum Outcome {
        case connectionLostBeforeText
        case success(String)
        case partialTextThenConnectionLost(String)
        case structuredSuccess(String)
        case structuredSuccessWithID(String, responseID: String)
        case structuredIncomplete(String, reason: String)
        case structuredQueued(String)
        case structuredInProgress(String)
    }

    private static let lock = NSLock()
    private static var outcomes: [Outcome] = []
    private static var requests = 0
    private static var requestBodies: [Data] = []
    private static var requestMethods: [String] = []
    private static var requestURLs: [URL] = []

    static func configure(_ newOutcomes: [Outcome]) {
        lock.lock()
        outcomes = newOutcomes
        requests = 0
        requestBodies = []
        requestMethods = []
        requestURLs = []
        lock.unlock()
    }

    static var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    static var lastRequestBody: Data? {
        lock.lock()
        defer { lock.unlock() }
        return requestBodies.last
    }

    static var capturedRequestMethods: [String] {
        lock.lock()
        defer { lock.unlock() }
        return requestMethods
    }

    static var capturedRequestURLs: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return requestURLs
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let outcome: Outcome
        Self.lock.lock()
        Self.requests += 1
        Self.requestMethods.append(request.httpMethod ?? "GET")
        if let url = request.url {
            Self.requestURLs.append(url)
        }
        if let body = request.httpBody ?? Self.readBodyStream(request.httpBodyStream) {
            Self.requestBodies.append(body)
        }
        if Self.outcomes.isEmpty {
            outcome = .connectionLostBeforeText
        } else {
            outcome = Self.outcomes.removeFirst()
        }
        Self.lock.unlock()

        switch outcome {
        case .connectionLostBeforeText:
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
        case .success(let text):
            sendResponse(data: Self.streamData(text: text), finish: true)
        case .partialTextThenConnectionLost(let text):
            sendResponse(data: Self.streamData(text: text, includeDone: false), finish: false)
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { [self] in
                client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            }
        case .structuredSuccess(let json):
            sendJSONResponse(outputText: json)
        case .structuredSuccessWithID(let json, let responseID):
            sendJSONResponse(outputText: json, responseID: responseID)
        case .structuredIncomplete(let json, let reason):
            sendJSONResponse(
                outputText: json,
                status: "incomplete",
                incompleteReason: reason
            )
        case .structuredQueued(let responseID):
            sendJSONResponse(
                outputText: nil,
                responseID: responseID,
                status: "queued"
            )
        case .structuredInProgress(let responseID):
            sendJSONResponse(
                outputText: nil,
                responseID: responseID,
                status: "in_progress"
            )
        }
    }

    override func stopLoading() {}

    private func sendResponse(data: Data, finish: Bool) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": "text/event-stream",
                "x-request-id": "req_self_test"
            ]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        if finish {
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    private static func streamData(text: String, includeDone: Bool = true) -> Data {
        let encodedText = try! JSONEncoder().encode(text)
        let jsonString = String(decoding: encodedText, as: UTF8.self)
        let done = includeDone ? "data: [DONE]\n\n" : ""
        return Data("data: {\"type\":\"response.output_text.delta\",\"delta\":\(jsonString)}\n\n\(done)".utf8)
    }

    private static func readBodyStream(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data.isEmpty ? nil : data
    }

    private func sendJSONResponse(
        outputText: String?,
        responseID: String = "resp_structured_self_test",
        status: String = "completed",
        incompleteReason: String? = nil
    ) {
        let encodedResponseID = try! JSONEncoder().encode(responseID)
        let responseIDText = String(decoding: encodedResponseID, as: UTF8.self)
        let encodedStatus = try! JSONEncoder().encode(status)
        let statusText = String(decoding: encodedStatus, as: UTF8.self)
        let output: String
        let usage: String
        if let outputText {
            let encodedText = try! JSONEncoder().encode(outputText)
            let text = String(decoding: encodedText, as: UTF8.self)
            output = """
            [{
              "type": "message",
              "content": [{
                "type": "output_text",
                "text": \(text)
              }]
            }]
            """
            usage = """
            {
              "input_tokens": 111,
              "input_tokens_details": {
                "cached_tokens": 11
              },
              "output_tokens": 37,
              "output_tokens_details": {
                "reasoning_tokens": 7
              },
              "total_tokens": 148
            }
            """
        } else {
            output = "[]"
            usage = "null"
        }
        let incompleteDetails: String
        if let incompleteReason {
            let encodedReason = try! JSONEncoder().encode(incompleteReason)
            let reasonText = String(decoding: encodedReason, as: UTF8.self)
            incompleteDetails = #"{"reason":\#(reasonText)}"#
        } else {
            incompleteDetails = "null"
        }
        let body = Data(
            """
            {
              "id": \(responseIDText),
              "status": \(statusText),
              "error": null,
              "incomplete_details": \(incompleteDetails),
              "output": \(output),
              "usage": \(usage)
            }
            """.utf8
        )
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": "application/json",
                "x-request-id": "req_structured_self_test"
            ]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private struct StructuredSelfTestOutput: Decodable {
    let value: String
}

if let optionIndex = CommandLine.arguments.firstIndex(of: "--database-directory"),
   CommandLine.arguments.indices.contains(optionIndex + 1) {
    let directoryURL = URL(
        fileURLWithPath: CommandLine.arguments[optionIndex + 1],
        isDirectory: true
    )
    do {
        let history = ChatHistoryStore(directoryURL: directoryURL)
        let messages = try history.load()
        let turns = try history.learningSourceTurns()
        let validationLogger = DiagnosticLogger(
            directoryURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "MacTranslatorMigrationLogs-\(UUID().uuidString)",
                    isDirectory: true
                )
        )
        let dashboard = try LearningStore(
            directoryURL: directoryURL,
            diagnosticLogger: validationLogger
        ).dashboard()
        print(
            "Migration validation passed: "
                + "\(messages.count) messages, "
                + "\(turns.count) t/s turns, "
                + "\(dashboard.knowledgePoints.count) learning projections."
        )
        exit(0)
    } catch {
        print("Migration validation failed: \(error.localizedDescription)")
        exit(1)
    }
}

let defaultCommand = CommandParser.parse("hello")
expect(defaultCommand.mode == .translate, "无前缀使用默认翻译")
expect(defaultCommand.userText == "hello", "默认命令保留正文")
expect(defaultCommand.instructions == TranslationPrompts.translate, "默认命令选择中文翻译 prompt")

let correctCommand = CommandParser.parse("T she no went to the market.")
expect(correctCommand.mode == .correct, "T 前缀选择英文纠错")
expect(correctCommand.userText == "she no went to the market.", "T 前缀会从正文中移除")
expect(correctCommand.instructions == TranslationPrompts.correct, "T 前缀选择原纠错 prompt")

let slackCommand = CommandParser.parse("s 这个需求我晚点跟进")
expect(slackCommand.mode == .slack, "s 前缀选择 Slack 润色")
expect(slackCommand.userText == "这个需求我晚点跟进", "s 前缀会从正文中移除")
expect(slackCommand.instructions == TranslationPrompts.slack, "s 前缀选择原 Slack prompt")

expect(CommandParser.parse("t hello").mode == .correct, "小写 t 可用")
expect(CommandParser.parse("S hello").mode == .slack, "大写 S 可用")
expect(CommandParser.parse("*#clear").mode == .translate, "*#clear 不再是特殊命令")

expect(CommandParser.parse("s").mode == .translate, "没有空格和正文的 s 不是命令")
expect(CommandParser.parse("something").mode == .translate, "普通 s 开头单词不是命令")

let customPrompts = PromptConfiguration(
    translate: "CUSTOM DEFAULT",
    correct: "CUSTOM CORRECTION",
    slack: "CUSTOM SLACK"
)
expect(
    CommandParser.parse("hello", prompts: customPrompts).instructions == "CUSTOM DEFAULT",
    "无前缀命令使用已配置的默认 prompt"
)
expect(
    CommandParser.parse("t hello", prompts: customPrompts).instructions == "CUSTOM CORRECTION",
    "t 命令使用已配置的 correction prompt"
)
expect(
    CommandParser.parse("s hello", prompts: customPrompts).instructions == "CUSTOM SLACK",
    "s 命令使用已配置的 Slack prompt"
)

let promptDefaultsSuite = "MacTranslatorSelfTests.Prompts.\(UUID().uuidString)"
let promptDefaults = UserDefaults(suiteName: promptDefaultsSuite)!
defer { promptDefaults.removePersistentDomain(forName: promptDefaultsSuite) }
customPrompts.save(to: promptDefaults)
let storedCustomPrompts = PromptConfiguration.stored(in: promptDefaults)
expect(storedCustomPrompts.translate == "CUSTOM DEFAULT", "自定义默认 prompt 会持久化")
expect(storedCustomPrompts.correct == "CUSTOM CORRECTION", "自定义 correction prompt 会持久化")
expect(storedCustomPrompts.slack == "CUSTOM SLACK", "自定义 Slack prompt 会持久化")

expect(
    ComposerKeyBehavior.action(
        isReturnKey: true,
        hasMarkedText: false,
        shiftPressed: false,
        commandPressed: false
    ) == .send,
    "普通回车发送消息"
)
expect(
    ComposerKeyBehavior.action(
        isReturnKey: true,
        hasMarkedText: false,
        shiftPressed: true,
        commandPressed: false
    ) == .insertNewline,
    "Shift+回车插入换行"
)
expect(
    ComposerKeyBehavior.action(
        isReturnKey: true,
        hasMarkedText: false,
        shiftPressed: false,
        commandPressed: true
    ) == .insertNewline,
    "Command+回车插入换行"
)
expect(
    ComposerKeyBehavior.action(
        isReturnKey: true,
        hasMarkedText: true,
        shiftPressed: false,
        commandPressed: false
    ) == .passThrough,
    "输入法正在选词时回车不会发送"
)

let shortcutDefaultsSuite = "MacTranslatorSelfTests.Shortcut.\(UUID().uuidString)"
let shortcutDefaults = UserDefaults(suiteName: shortcutDefaultsSuite)!
defer { shortcutDefaults.removePersistentDomain(forName: shortcutDefaultsSuite) }
let customShortcut = GlobalShortcut(
    keyCode: 40,
    modifiers: [.command, .shift],
    keyName: "K"
)
GlobalShortcutPreferences.save(enabled: true, shortcut: customShortcut, to: shortcutDefaults)
expect(GlobalShortcutPreferences.isEnabled(in: shortcutDefaults), "全局呼出快捷键启用状态会持久化")
expect(GlobalShortcutPreferences.load(in: shortcutDefaults) == customShortcut, "全局呼出快捷键会持久化")

let nestedStreamError = Data(
    #"{"type":"error","error":{"code":"model_not_available","message":"Preview model is not available on this account."}}"#.utf8
)
do {
    let outcome = try OpenAIStreamEventParser.parse(nestedStreamError)
    expect(
        outcome == .failure("Preview model is not available on this account."),
        "流式 error 事件会显示嵌套的真实错误信息"
    )
} catch {
    failures += 1
    print("✗ 流式错误解析自检出错：\(error.localizedDescription)")
}

expect(
    AppSettings.resolvedModel("gpt-5.6-luna") == "gpt-5.6-luna",
    "自定义模型名不会被自动迁移"
)
expect(
    AppSettings.resolvedModel("gpt-5.4-mini") == "gpt-5.4-mini",
    "其他自定义模型设置保持不变"
)
expect(
    AppSettings.resolvedModel("  custom-model  ") == "custom-model",
    "自定义模型名只会移除首尾空白"
)
expect(
    KeychainError.from(status: errSecAuthFailed).requiresLoginKeychainReconnect,
    "Keychain 鉴权失败会进入重新连接流程"
)
expect(
    !KeychainError.from(status: errSecParam).requiresLoginKeychainReconnect,
    "普通 Keychain 参数错误不会误触发重新连接"
)
expect(
    !LearningTaxonomy.trainableIDs.contains("mechanics.spelling")
        && !LearningTaxonomy.trainableIDs.contains("mechanics.capitalization")
        && !LearningTaxonomy.trainableIDs.contains("mechanics.punctuation"),
    "拼写、大小写和标点不会进入可训练知识点"
)
expect(
    LearningPromptContracts.answerGrader.contains("all punctuation differences")
        && LearningPromptContracts.answerGrader.contains(
            "including missing or incorrect punctuation"
        ),
    "V2 判题会完全忽略标点问题"
)
expect(
    LearningEngine.expressionBatchSize == 5,
    "Learn 默认每批生成五道表达题"
)
expect(
    LearningEngine.batchOutcome(successfulCount: 4, completedBatchCount: 1) == .passed,
    "一批达到 4/5 只结束当天强化"
)
expect(
    LearningEngine.batchOutcome(successfulCount: 3, completedBatchCount: 1) == .reinforce,
    "一批低于 4/5 会继续相同知识点"
)
expect(
    LearningEngine.batchOutcome(successfulCount: 2, completedBatchCount: 20) == .reinforce,
    "当天即使连续多轮未通过也会继续强化同一知识点"
)
expect(
    !LearningEngine.shouldIntroduceNewMaterial(
        reviewSessionsToday: 1,
        newMaterialSessionsToday: 0,
        hasNewMaterial: true
    )
        && LearningEngine.shouldIntroduceNewMaterial(
            reviewSessionsToday: 2,
            newMaterialSessionsToday: 0,
            hasNewMaterial: true
        ),
    "每日计划按约两轮旧知识复习搭配一轮新内容"
)
expect(
    !LearningEngine.shouldAutomaticallySync(pendingTurnCount: 49),
    "未分析 Chat 少于 50 条时不会自动调用 Learn"
)
expect(
    LearningEngine.shouldAutomaticallySync(pendingTurnCount: 50),
    "未分析 Chat 达到 50 条时才会自动调用 Learn"
)

do {
    let questionSchemaData = try JSONEncoder().encode(
        LearningPromptContracts.questionBatchSchema
    )
    let questionSchemaText = String(decoding: questionSchemaData, as: UTF8.self)
    expect(
        questionSchemaText.contains("chinese_to_english")
            && questionSchemaText.contains("questions")
            && !questionSchemaText.contains("fill_blank")
            && !questionSchemaText.contains("sentence_repair"),
        "V3 批量出题 Schema 只允许中文到英文表达"
    )
    let gradeSchemaText = String(
        decoding: try JSONEncoder().encode(LearningPromptContracts.gradeBatchSchema),
        as: UTF8.self
    )
    expect(
        gradeSchemaText.contains("patterns")
            && gradeSchemaText.contains("key_explanations_zh")
            && gradeSchemaText.contains("question_id")
            && gradeSchemaText.contains("grades"),
        "V3 批量判题 Schema 强制返回常见句式和重点讲解"
    )
    let constrainedHistorySchemaText = String(
        decoding: try JSONEncoder().encode(
            LearningPromptContracts.historyAnalysisSchema(turnIDs: ["t1", "t2"])
        ),
        as: UTF8.self
    )
    expect(
        constrainedHistorySchemaText.contains(#""enum":["t1","t2"]"#)
            || constrainedHistorySchemaText.contains(#""enum":["t2","t1"]"#),
        "历史分析 Schema 只允许回传本批短 turn ID"
    )
    let constrainedGradeSchemaText = String(
        decoding: try JSONEncoder().encode(
            LearningPromptContracts.gradeBatchSchema(questionIDs: ["q1", "q2"])
        ),
        as: UTF8.self
    )
    expect(
        constrainedGradeSchemaText.contains(#""enum":["q1","q2"]"#)
            || constrainedGradeSchemaText.contains(#""enum":["q2","q1"]"#),
        "批量判题 Schema 只允许回传本批短 question ID"
    )
} catch {
    failures += 1
    print("✗ V2 学习 Schema 自检出错：\(error.localizedDescription)")
}

let multilineMarkdown = "**Option 1:**\nFirst line\n**Option 2:**\nSecond line"
let formattedMarkdown = MessageTextFormatter.format(multilineMarkdown)
expect(
    String(formattedMarkdown.characters) == "Option 1:\nFirst line\nOption 2:\nSecond line",
    "Markdown 粗体渲染后仍保留模型输出的单换行"
)

let blockMarkdown = "## Feedback & Corrections\n**Critique:**\n- First item"
let formattedBlockMarkdown = MessageTextFormatter.format(blockMarkdown)
expect(
    String(formattedBlockMarkdown.characters) == "Feedback & Corrections\nCritique:\n- First item",
    "Markdown 标题会移除井号并保留块之间的换行"
)

do {
    let analysisTurnID = UUID()
    let analysisJSON = Data(
        """
        {
          "turns": [{
            "turn_id": "\(analysisTurnID.uuidString)",
            "input_language": "english",
            "is_proficiency_evidence": true,
            "evidence": [{
              "kind": "error",
              "knowledge_point_id": "grammar.tense_aspect",
              "title": "Tense and aspect",
              "dimension": "grammar",
              "severity": "high",
              "confidence": 0.98,
              "communication_impact": 0.9,
              "source_excerpt": "He go yesterday.",
              "corrected_form": "He went yesterday.",
              "explanation_zh": "需要使用过去时。"
            }]
          }]
        }
        """.utf8
    )
    let analysis = try JSONDecoder().decode(HistoryAnalysisResult.self, from: analysisJSON)
    expect(
        analysis.turns.first?.evidence.first?.knowledgePointID == "grammar.tense_aspect",
        "历史分析 JSON Schema 字段可以解码到学习模型"
    )
} catch {
    failures += 1
    print("✗ 历史分析结构解码自检出错：\(error.localizedDescription)")
}

let testDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent("MacTranslatorSelfTests-\(UUID().uuidString)", isDirectory: true)
defer { try? FileManager.default.removeItem(at: testDirectory) }

let historyStore = ChatHistoryStore(directoryURL: testDirectory)
let savedMessages = [
    ChatMessage(role: .user, text: "hello", mode: .translate),
    ChatMessage(role: .assistant, text: "你好", mode: .translate)
]

do {
    let legacyData = try JSONEncoder().encode(savedMessages)
    try FileManager.default.createDirectory(at: testDirectory, withIntermediateDirectories: true)
    try legacyData.write(to: historyStore.legacyJSONURL)

    let restoredMessages = try historyStore.load()
    expect(
        restoredMessages.map(\.id) == savedMessages.map(\.id)
            && restoredMessages.map(\.text) == savedMessages.map(\.text)
            && restoredMessages.map(\.mode) == savedMessages.map(\.mode),
        "旧 JSON 聊天记录会迁移到 SQLite"
    )
    expect(FileManager.default.fileExists(atPath: historyStore.databaseURL.path), "SQLite 数据库已创建")
    expect(!FileManager.default.fileExists(atPath: historyStore.legacyJSONURL.path), "迁移成功后删除旧 JSON")

    let updatedText = "你好，世界"
    try historyStore.updateText(id: savedMessages[1].id, text: updatedText)
    let messagesAfterUpdate = try historyStore.load()
    expect(messagesAfterUpdate[1].text == updatedText, "流式响应只更新当前消息行")

    let thirdMessage = ChatMessage(role: .user, text: "S hello", mode: .slack)
    try historyStore.append(thirdMessage)
    let messagesAfterInsert = try historyStore.load()
    expect(messagesAfterInsert.count == 3, "可以增量插入单条消息")
    let insertedMessageCount = try historyStore.messageCount()
    let twoMostRecentMessages = try historyStore.loadRecent(limit: 2)
    expect(insertedMessageCount == 3, "可以不加载正文就统计全部聊天记录")
    expect(
        twoMostRecentMessages.map(\.id) == [savedMessages[1].id, thirdMessage.id],
        "主聊天页可以只读取最近的消息并保持时间顺序"
    )

    let recentHistoryStore = ChatHistoryStore(
        directoryURL: testDirectory.appendingPathComponent("RecentHistory", isDirectory: true)
    )
    let longHistory = (0..<205).map { index in
        ChatMessage(
            role: index.isMultiple(of: 2) ? .user : .assistant,
            text: "history-\(index)",
            mode: .translate,
            createdAt: Date(timeIntervalSince1970: Double(index + 1))
        )
    }
    try recentHistoryStore.replaceAll(longHistory)
    let visibleHistory = try recentHistoryStore.loadRecent(limit: 200)
    let longHistoryCount = try recentHistoryStore.messageCount()
    expect(
        longHistoryCount == 205
            && visibleHistory.count == 200
            && visibleHistory.first?.text == "history-5"
            && visibleHistory.last?.text == "history-204",
        "超过 200 条时主页面只读取最近 200 条"
    )
    let appendedHistoryMessage = ChatMessage(
        role: .user,
        text: "history-205",
        mode: .translate
    )
    try recentHistoryStore.append(appendedHistoryMessage)
    let historyAfterAppend = try recentHistoryStore.loadRecent(limit: 200)
    let appendedHistoryCount = try recentHistoryStore.messageCount()
    expect(
        appendedHistoryCount == 206
            && historyAfterAppend.first?.text == "history-6"
            && historyAfterAppend.last?.id == appendedHistoryMessage.id,
        "新消息会追加到完整历史且最近 200 条窗口向前滚动"
    )

    let turnID = UUID()
    let turnDate = Date(timeIntervalSince1970: 1_725_000_000)
    let learningUser = ChatMessage(
        role: .user,
        text: "He go to office yesterday.",
        mode: .correct,
        turnID: turnID,
        createdAt: turnDate
    )
    let learningAssistant = ChatMessage(
        role: .assistant,
        text: "He went to the office yesterday.",
        mode: .correct,
        turnID: turnID,
        createdAt: turnDate
    )
    try historyStore.upsert(learningUser, position: 3)
    try historyStore.upsert(learningAssistant, position: 4)
    try historyStore.upsertTurn(
        ChatTurn(
            id: turnID,
            mode: .correct,
            userMessageID: learningUser.id,
            assistantMessageID: learningAssistant.id,
            createdAt: turnDate,
            completedAt: turnDate,
            status: .completed,
            model: "self-test-model",
            promptFingerprint: PromptFingerprint.make("test prompt")
        )
    )
    let learningTurns = try historyStore.learningSourceTurns()
    expect(
        learningTurns.contains {
            $0.mode == .translate
                && $0.userText == savedMessages[0].text
                && $0.assistantText == updatedText
        },
        "所有对话模式都可以提供个性化出题场景"
    )
    expect(
        learningTurns.contains {
            $0.id == turnID
                && $0.userText == learningUser.text
                && $0.assistantText == learningAssistant.text
        },
        "英文纠正消息会按稳定 turn ID 组成学习数据源"
    )

    let exportURL = testDirectory.appendingPathComponent("export.json")
    try historyStore.exportJSON(to: exportURL)
    let exportedMessages = try JSONDecoder().decode(
        [ChatMessage].self,
        from: Data(contentsOf: exportURL)
    )
    expect(exportedMessages.count == 5, "聊天记录可以导出为 JSON")

    try historyStore.clear()
    let clearedMessages = try historyStore.load()
    expect(clearedMessages.isEmpty, "清空按钮会删除 SQLite 中的聊天记录")
    let clearedLearningTurns = try historyStore.learningSourceTurns()
    expect(clearedLearningTurns.isEmpty, "清空聊天也会删除 chat turn 元数据")
} catch {
    failures += 1
    print("✗ 聊天记录持久化自检出错：\(error.localizedDescription)")
}

let syncThresholdDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent(
        "MacTranslatorSyncThreshold-\(UUID().uuidString)",
        isDirectory: true
    )
defer { try? FileManager.default.removeItem(at: syncThresholdDirectory) }

do {
    let thresholdLogger = DiagnosticLogger(
        directoryURL: syncThresholdDirectory.appendingPathComponent(
            "logs",
            isDirectory: true
        )
    )
    let thresholdHistoryStore = ChatHistoryStore(
        directoryURL: syncThresholdDirectory
    )
    let thresholdLearningStore = LearningStore(
        directoryURL: syncThresholdDirectory,
        diagnosticLogger: thresholdLogger
    )
    var firstTurnID: UUID?
    for index in 0..<LearningEngine.automaticHistorySyncThreshold {
        let turnID = UUID()
        firstTurnID = firstTurnID ?? turnID
        let timestamp = Date(timeIntervalSince1970: 1_730_000_000 + Double(index))
        let user = ChatMessage(
            role: .user,
            text: "Test message \(index)",
            mode: .slack,
            turnID: turnID,
            createdAt: timestamp
        )
        let assistant = ChatMessage(
            role: .assistant,
            text: "Rewritten test message \(index)",
            mode: .slack,
            turnID: turnID,
            createdAt: timestamp
        )
        try thresholdHistoryStore.upsert(user, position: index * 2)
        try thresholdHistoryStore.upsert(assistant, position: index * 2 + 1)
        try thresholdHistoryStore.upsertTurn(
            ChatTurn(
                id: turnID,
                mode: .slack,
                userMessageID: user.id,
                assistantMessageID: assistant.id,
                createdAt: timestamp,
                completedAt: timestamp,
                status: .completed,
                model: "self-test-model",
                promptFingerprint: "self-test"
            )
        )
    }
    let thresholdEngine = LearningEngine(
        historyStore: thresholdHistoryStore,
        learningStore: thresholdLearningStore,
        diagnosticLogger: thresholdLogger
    )
    let pendingAtThreshold = try await thresholdEngine.pendingHistoryTurnCount()
    expect(
        pendingAtThreshold == LearningEngine.automaticHistorySyncThreshold,
        "自动同步阈值按未分析的已完成 Chat turn 计算"
    )

    if let firstTurnID {
        try thresholdLearningStore.append(
            PendingLearningEvent(
                type: .sourceTurnAnalysisCompleted,
                sourceTurnID: firstTurnID,
                idempotencyKey: "threshold-first-turn-analyzed",
                producer: "self_test",
                payload: SourceTurnAnalysisCompletedPayload(
                    sourceTurnID: firstTurnID,
                    inputLanguage: .english,
                    isProficiencyEvidence: true,
                    analyzerVersion: LearningPromptContracts.analyzerVersion,
                    evidenceCount: 0
                )
            )
        )
    }
    let pendingAfterOneAnalyzed = try await thresholdEngine.pendingHistoryTurnCount()
    expect(
        pendingAfterOneAnalyzed == LearningEngine.automaticHistorySyncThreshold - 1,
        "已分析的 Chat 不会重复计入 50 条阈值"
    )
} catch {
    failures += 1
    print("✗ Learn 自动同步阈值自检出错：\(error.localizedDescription)")
}

let learningTestDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent("MacTranslatorLearningTests-\(UUID().uuidString)", isDirectory: true)
defer { try? FileManager.default.removeItem(at: learningTestDirectory) }
let learningTestLogger = DiagnosticLogger(
    directoryURL: learningTestDirectory.appendingPathComponent("logs", isDirectory: true)
)
let learningStore = LearningStore(
    directoryURL: learningTestDirectory,
    diagnosticLogger: learningTestLogger
)

do {
    let sourceTurnID = UUID()
    let observedAt = Date(timeIntervalSince1970: 1_725_000_100)
    let evidencePayload = EvidenceObservedPayload(
        evidenceID: UUID(),
        sourceTurnID: sourceTurnID,
        sourceMode: .correct,
        sourceOrigin: .native,
        inputLanguage: .english,
        isProficiencyEvidence: true,
        knowledgePointID: "grammar.tense_aspect",
        title: "Tense and aspect",
        dimension: .grammar,
        severity: .high,
        confidence: 0.98,
        communicationImpact: 0.9,
        sourceExcerpt: "He go yesterday.",
        correctedForm: "He went yesterday.",
        explanationZH: "过去发生的动作需要使用一般过去时。"
    )
    let evidenceEvent = try PendingLearningEvent(
        id: UUID(),
        type: .errorEvidenceObserved,
        occurredAt: observedAt,
        knowledgePointID: "grammar.tense_aspect",
        sourceTurnID: sourceTurnID,
        idempotencyKey: "self-test-evidence",
        producer: "self_test",
        payload: evidencePayload
    )
    let firstEvidenceInsert = try learningStore.append(evidenceEvent)
    let duplicateEvidenceInsert = try learningStore.append(evidenceEvent)
    expect(firstEvidenceInsert, "学习事件可以追加到事件存储")
    expect(!duplicateEvidenceInsert, "相同幂等键不会重复写入学习事件")

    let completionPayload = SourceTurnAnalysisCompletedPayload(
        sourceTurnID: sourceTurnID,
        inputLanguage: .english,
        isProficiencyEvidence: true,
        analyzerVersion: LearningPromptContracts.analyzerVersion,
        evidenceCount: 1
    )
    try learningStore.append(
        PendingLearningEvent(
            type: .sourceTurnAnalysisCompleted,
            occurredAt: observedAt,
            sourceTurnID: sourceTurnID,
            idempotencyKey: "self-test-analysis-complete",
            producer: "self_test",
            payload: completionPayload
        )
    )

    var learningDashboard = try learningStore.dashboard()
    let initialTense = learningDashboard.knowledgePoints.first {
        $0.id == "grammar.tense_aspect"
    }
    expect(initialTense != nil, "错误证据会建立知识点投影")
    expect((initialTense?.mastery ?? 1) < 0.5, "真实聊天错误会降低初始掌握度")
    expect(learningDashboard.analyzedTurnCount == 1, "分析覆盖投影会记录已处理聊天")
    let analyzedTurnIDs = try learningStore.analyzedTurnIDs(
        analyzerVersion: LearningPromptContracts.analyzerVersion
    )
    expect(
        analyzedTurnIDs.contains(sourceTurnID),
        "增量同步可以查询已分析的 turn ID"
    )

    let sessionID = UUID()
    let questionID = UUID()
    let answerID = UUID()
    let generatedQuestion = GeneratedLearningQuestion(
        type: .sentenceRepair,
        prompt: "Fix: She go home yesterday.",
        context: "A short workplace update",
        hint: "Look at the time word.",
        rubric: "Use the past tense of go.",
        referenceAnswer: "She went home yesterday."
    )
    let question = QuestionPresentedPayload(
        id: questionID,
        sessionID: sessionID,
        ordinal: 1,
        knowledgePointID: "grammar.tense_aspect",
        generated: generatedQuestion
    )
    let answer = AnswerSubmittedPayload(
        answerID: answerID,
        sessionID: sessionID,
        questionID: questionID,
        answer: "She went home yesterday.",
        submittedAt: observedAt.addingTimeInterval(20)
    )
    let grade = AnswerGradedPayload(
        gradeID: UUID(),
        sessionID: sessionID,
        questionID: questionID,
        answerID: answerID,
        knowledgePointID: "grammar.tense_aspect",
        questionType: .sentenceRepair,
        usedHint: false,
        isRetry: false,
        verdict: .correct,
        confidence: 0.99,
        targetDemonstrated: true,
        correctedAnswer: "She went home yesterday.",
        explanationZH: "went 正确表达过去发生的动作。",
        issues: [],
        followUp: .variation,
        gradedAt: observedAt.addingTimeInterval(30),
        alternativeAnswers: ["She returned home yesterday."],
        patterns: [
            LearningSentencePattern(
                pattern: "subject + past-tense verb + time",
                meaningZH: "用一般过去时说明已发生的动作",
                example: "The deployment finished yesterday."
            )
        ],
        keyExplanationsZH: ["明确的过去时间通常需要一般过去时。"]
    )
    do {
        let encodedGrade = try JSONEncoder().encode(grade)
        guard var legacyObject = try JSONSerialization.jsonObject(
            with: encodedGrade
        ) as? [String: Any] else {
            throw LearningStoreError.invalidPayload
        }
        legacyObject.removeValue(forKey: "alternativeAnswers")
        legacyObject.removeValue(forKey: "patterns")
        legacyObject.removeValue(forKey: "keyExplanationsZH")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let decodedLegacyGrade = try JSONDecoder().decode(
            AnswerGradedPayload.self,
            from: legacyData
        )
        expect(
            decodedLegacyGrade.patterns.isEmpty
                && decodedLegacyGrade.keyExplanationsZH.isEmpty
                && decodedLegacyGrade.countsTowardMastery,
            "旧判题事件缺少 V2 反馈字段时仍可解码"
        )
    }
    try learningStore.append([
        try PendingLearningEvent(
            type: .learningSessionStarted,
            occurredAt: observedAt.addingTimeInterval(10),
            sessionID: sessionID,
            idempotencyKey: "self-test-session-start",
            producer: "self_test",
            payload: LearningSessionStartedPayload(
                sessionID: sessionID,
                startedAt: observedAt.addingTimeInterval(10)
            )
        ),
        try PendingLearningEvent(
            type: .sessionFocusSelected,
            occurredAt: observedAt.addingTimeInterval(11),
            sessionID: sessionID,
            knowledgePointID: "grammar.tense_aspect",
            idempotencyKey: "self-test-session-focus",
            producer: "self_test",
            payload: SessionFocusSelectedPayload(
                sessionID: sessionID,
                knowledgePointID: "grammar.tense_aspect",
                title: "Tense and aspect",
                reason: "Seen in a real t message."
            )
        ),
        try PendingLearningEvent(
            type: .questionPresented,
            occurredAt: observedAt.addingTimeInterval(12),
            sessionID: sessionID,
            knowledgePointID: "grammar.tense_aspect",
            idempotencyKey: "self-test-question",
            producer: "self_test",
            payload: question
        ),
        try PendingLearningEvent(
            type: .answerSubmitted,
            occurredAt: observedAt.addingTimeInterval(20),
            sessionID: sessionID,
            knowledgePointID: "grammar.tense_aspect",
            idempotencyKey: "self-test-answer",
            producer: "self_test",
            payload: answer
        ),
        try PendingLearningEvent(
            type: .answerGraded,
            occurredAt: observedAt.addingTimeInterval(30),
            sessionID: sessionID,
            knowledgePointID: "grammar.tense_aspect",
            idempotencyKey: "self-test-grade",
            producer: "self_test",
            payload: grade
        )
    ])

    learningDashboard = try learningStore.dashboard()
    expect(
        learningDashboard.activeSession?.attempts.last?.grade?.verdict == .correct,
        "答案、判题和讲解状态可以从事件重建"
    )
    expect(
        learningDashboard.activeSession?.attempts.last?.question.batchID == nil,
        "升级前没有 batch ID 的旧题目事件仍可重建"
    )
    expect(
        learningDashboard.activeSession?.attempts.last?.grade?.patterns.first?.pattern
            == "subject + past-tense verb + time",
        "常见句式和重点讲解会随判题事件持久化"
    )
    expect(
        learningDashboard.knowledgePoints.first {
            $0.id == "grammar.tense_aspect"
        }?.successfulAttempts == 1,
        "正确答案会通过确定性策略更新知识点投影"
    )

    let beforeReplay = learningDashboard
    try learningStore.rebuildProjections()
    let replayedDashboard = try learningStore.dashboard()
    expect(replayedDashboard == beforeReplay, "完整事件重放会得到相同学习投影")

    try learningStore.startNewEpoch(keepExtractedEvidence: true)
    let resetDashboard = try learningStore.dashboard()
    expect(resetDashboard.activeSession == nil, "重置进度会结束当前学习 session")
    expect(
        resetDashboard.knowledgePoints.first {
            $0.id == "grammar.tense_aspect"
        }?.realChatErrorCount == 1,
        "重置进度会保留从聊天提取的弱项证据"
    )

    try learningStore.deleteAllLearningData()
    let deletedEvents = try learningStore.loadEvents()
    let deletedDashboard = try learningStore.dashboard()
    expect(deletedEvents.isEmpty, "可以永久删除完整学习事件历史")
    expect(deletedDashboard.knowledgePoints.isEmpty, "删除学习数据会清空投影")
} catch {
    failures += 1
    print("✗ 事件驱动学习存储自检出错：\(error.localizedDescription)")
}

let spacedReviewDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent(
        "MacTranslatorSpacedReview-\(UUID().uuidString)",
        isDirectory: true
    )
defer { try? FileManager.default.removeItem(at: spacedReviewDirectory) }

do {
    let spacedReviewStore = LearningStore(
        directoryURL: spacedReviewDirectory,
        diagnosticLogger: DiagnosticLogger(
            directoryURL: spacedReviewDirectory.appendingPathComponent(
                "logs",
                isDirectory: true
            )
        )
    )
    let knowledgePointID = "vocabulary.collocation"
    let firstSessionID = UUID()
    let firstReviewAt = Date(timeIntervalSince1970: 1_750_000_000)
    try spacedReviewStore.append([
        try PendingLearningEvent(
            type: .learningSessionStarted,
            occurredAt: firstReviewAt,
            sessionID: firstSessionID,
            idempotencyKey: "spaced-session-start",
            producer: "self_test",
            payload: LearningSessionStartedPayload(
                sessionID: firstSessionID,
                startedAt: firstReviewAt
            )
        ),
        try PendingLearningEvent(
            type: .sessionFocusSelected,
            occurredAt: firstReviewAt,
            sessionID: firstSessionID,
            knowledgePointID: knowledgePointID,
            idempotencyKey: "spaced-session-focus",
            producer: "self_test",
            payload: SessionFocusSelectedPayload(
                sessionID: firstSessionID,
                knowledgePointID: knowledgePointID,
                title: "Collocation",
                reason: "New from recent chats.",
                planKind: .newMaterial
            )
        ),
        try PendingLearningEvent(
            type: .batchReviewCompleted,
            occurredAt: firstReviewAt,
            sessionID: firstSessionID,
            knowledgePointID: knowledgePointID,
            idempotencyKey: "spaced-first-pass",
            producer: "self_test",
            payload: BatchReviewCompletedPayload(
                sessionID: firstSessionID,
                batchID: UUID(),
                knowledgePointID: knowledgePointID,
                successfulCount: 4,
                questionCount: 5,
                reinforcementRound: 1,
                outcome: .passed,
                completedAt: firstReviewAt
            )
        )
    ])
    var spacedKnowledge = try spacedReviewStore.dashboard().knowledgePoints.first {
        $0.id == knowledgePointID
    }
    expect(
        spacedKnowledge?.reviewStage == 0
            && spacedKnowledge?.successfulReviewCount == 1,
        "当天首次 4/5 只建立复习计划，不会直接推进长期记忆阶段"
    )

    let sameDayReviewAt = firstReviewAt.addingTimeInterval(60 * 60)
    try spacedReviewStore.append(
        PendingLearningEvent(
            type: .batchReviewCompleted,
            occurredAt: sameDayReviewAt,
            sessionID: firstSessionID,
            knowledgePointID: knowledgePointID,
            idempotencyKey: "spaced-same-day-pass",
            producer: "self_test",
            payload: BatchReviewCompletedPayload(
                sessionID: firstSessionID,
                batchID: UUID(),
                knowledgePointID: knowledgePointID,
                successfulCount: 5,
                questionCount: 5,
                reinforcementRound: 2,
                outcome: .passed,
                completedAt: sameDayReviewAt
            )
        )
    )
    spacedKnowledge = try spacedReviewStore.dashboard().knowledgePoints.first {
        $0.id == knowledgePointID
    }
    expect(
        spacedKnowledge?.reviewStage == 0,
        "同一天重复答对不会推进间隔阶段"
    )

    guard let firstDueAt = spacedKnowledge?.dueAt else {
        throw LearningStoreError.invalidPayload
    }
    let delayedReviewAt = firstDueAt.addingTimeInterval(60)
    let secondSessionID = UUID()
    try spacedReviewStore.append(
        PendingLearningEvent(
            type: .batchReviewCompleted,
            occurredAt: delayedReviewAt,
            sessionID: secondSessionID,
            knowledgePointID: knowledgePointID,
            idempotencyKey: "spaced-delayed-pass",
            producer: "self_test",
            payload: BatchReviewCompletedPayload(
                sessionID: secondSessionID,
                batchID: UUID(),
                knowledgePointID: knowledgePointID,
                successfulCount: 4,
                questionCount: 5,
                reinforcementRound: 1,
                outcome: .passed,
                completedAt: delayedReviewAt
            )
        )
    )
    spacedKnowledge = try spacedReviewStore.dashboard().knowledgePoints.first {
        $0.id == knowledgePointID
    }
    expect(
        spacedKnowledge?.reviewStage == 1,
        "跨天且到期后的成功复习最多推进一个间隔阶段"
    )

    let lapseAt = (spacedKnowledge?.dueAt ?? delayedReviewAt).addingTimeInterval(60)
    try spacedReviewStore.append(
        PendingLearningEvent(
            type: .batchReviewCompleted,
            occurredAt: lapseAt,
            sessionID: UUID(),
            knowledgePointID: knowledgePointID,
            idempotencyKey: "spaced-lapse",
            producer: "self_test",
            payload: BatchReviewCompletedPayload(
                sessionID: UUID(),
                batchID: UUID(),
                knowledgePointID: knowledgePointID,
                successfulCount: 2,
                questionCount: 5,
                reinforcementRound: 1,
                outcome: .reinforce,
                completedAt: lapseAt
            )
        )
    )
    spacedKnowledge = try spacedReviewStore.dashboard().knowledgePoints.first {
        $0.id == knowledgePointID
    }
    expect(
        spacedKnowledge?.reviewStage == 0
            && spacedKnowledge?.lifecycle == .lapsed,
        "到期复习低于 3/5 会重置短间隔并标记为遗忘"
    )
} catch {
    failures += 1
    print("✗ 批次级间隔复习自检出错：\(error.localizedDescription)")
}

expect(
    OpenAIClient.isRetryable(URLError(.networkConnectionLost)),
    "连接中断属于可重试错误"
)
expect(
    OpenAIClient.isRetryable(OpenAIClientError.api(statusCode: 503, message: "Unavailable")),
    "HTTP 5xx 属于可重试错误"
)
expect(
    !OpenAIClient.isRetryable(OpenAIClientError.api(statusCode: 401, message: "Unauthorized")),
    "认证错误不会重试"
)
expect(
    !OpenAIClient.isRetryable(OpenAIClientError.stream("Generation failed")),
    "模型流事件错误不会重试"
)

let retryTestDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent("MacTranslatorRetryTests-\(UUID().uuidString)", isDirectory: true)
defer { try? FileManager.default.removeItem(at: retryTestDirectory) }
let retryLogger = DiagnosticLogger(
    directoryURL: retryTestDirectory,
    maxFileSize: 2_000_000,
    retainedFileCount: 5
)
let stubConfiguration = URLSessionConfiguration.ephemeral
stubConfiguration.protocolClasses = [OpenAIStubURLProtocol.self]
let stubSession = URLSession(configuration: stubConfiguration)
defer { stubSession.invalidateAndCancel() }
let learningDebugStore = LearningDebugStore(maxEntries: 10)
let retryClient = OpenAIClient(
    endpoint: URL(string: "https://self-test.invalid/v1/responses")!,
    session: stubSession,
    diagnosticLogger: retryLogger,
    learningDebugStore: learningDebugStore,
    retryDelayNanoseconds: [0, 0],
    backgroundPollIntervalNanoseconds: 0
)
let secretAPIKey = "sk-self-test-must-not-appear"
let secretChatText = "private chat body must not appear"

do {
    OpenAIStubURLProtocol.configure([
        .structuredSuccess(#"{"value":"schema matched"}"#)
    ])
    let structured: StructuredSelfTestOutput = try await retryClient.structuredResponse(
        apiKey: secretAPIKey,
        model: "self-test-model",
        instructions: "Return structured JSON.",
        input: secretChatText,
        schemaName: "self_test",
        schema: .strictObject(properties: [
            "value": .object(["type": .string("string")])
        ]),
        diagnosticContext: DiagnosticRequestContext(flow: "learning_self_test")
    )
    expect(structured.value == "schema matched", "Responses API 结构化输出可以解码为 Swift 类型")

    let requestObject = OpenAIStubURLProtocol.lastRequestBody.flatMap {
        try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
    }
    let textObject = requestObject?["text"] as? [String: Any]
    let formatObject = textObject?["format"] as? [String: Any]
    expect(formatObject?["type"] as? String == "json_schema", "结构化请求使用 text.format JSON Schema")
    expect(requestObject?["store"] as? Bool == false, "学习请求明确关闭服务端响应存储")
    expect(requestObject?["background"] as? Bool == true, "学习请求启用 Responses background mode")

    let debugEntry = learningDebugStore.entries().first
    expect(debugEntry?.instructions == "Return structured JSON.", "Learn Debug 记录输入 prompt")
    expect(debugEntry?.input == secretChatText, "Learn Debug 记录请求 input")
    expect(debugEntry?.response == #"{"value":"schema matched"}"#, "Learn Debug 记录 LLM response")
    expect(debugEntry?.tokenUsage?.inputTokens == 111, "Learn Debug 记录 input token 用量")
    expect(debugEntry?.tokenUsage?.outputTokens == 37, "Learn Debug 记录 output token 用量")
    expect(debugEntry?.tokenUsage?.totalTokens == 148, "Learn Debug 记录 total token 用量")
    expect(debugEntry?.tokenUsage?.cachedInputTokens == 11, "Learn Debug 记录 cached token 用量")
    expect(debugEntry?.tokenUsage?.reasoningOutputTokens == 7, "Learn Debug 记录 reasoning token 用量")
} catch {
    failures += 1
    print("✗ 结构化输出自检出错：\(error.localizedDescription)")
}

do {
    let responseID = "resp_background_poll_self_test"
    OpenAIStubURLProtocol.configure([
        .structuredQueued(responseID),
        .connectionLostBeforeText,
        .structuredInProgress(responseID),
        .structuredSuccessWithID(
            #"{"value":"completed after polling"}"#,
            responseID: responseID
        )
    ])
    let structured: StructuredSelfTestOutput = try await retryClient.structuredResponse(
        apiKey: secretAPIKey,
        model: "self-test-model",
        instructions: "Return structured JSON.",
        input: secretChatText,
        schemaName: "background_poll_self_test",
        schema: .strictObject(properties: [
            "value": .object(["type": .string("string")])
        ]),
        diagnosticContext: DiagnosticRequestContext(flow: "learning_background_poll")
    )
    expect(
        structured.value == "completed after polling",
        "Background response 会轮询到完成后再解码"
    )
    let methods = OpenAIStubURLProtocol.capturedRequestMethods
    expect(methods.filter { $0 == "POST" }.count == 1, "Background 等待期间只创建一次推理")
    expect(methods.filter { $0 == "GET" }.count == 3, "轮询网络错误只重试 GET 查询")
    let pollURLs = OpenAIStubURLProtocol.capturedRequestURLs.dropFirst()
    expect(
        pollURLs.allSatisfy { $0.path.hasSuffix("/responses/\(responseID)") },
        "Background 查询始终复用同一个 response ID"
    )
    let debugEntry = learningDebugStore.entries().first {
        $0.flow == "learning_background_poll"
    }
    expect(debugEntry?.attempt == 1, "Background 轮询不会显示为第二次模型 attempt")
    expect(debugEntry?.openAIResponseID == responseID, "Learn Debug 记录 OpenAI response ID")
    expect(debugEntry?.openAIStatus == "completed", "Learn Debug 记录最终后台状态")
    expect(debugEntry?.pollCount == 2, "Learn Debug 记录后台轮询次数")
} catch {
    failures += 1
    print("✗ Background mode 轮询自检出错：\(error.localizedDescription)")
}

do {
    OpenAIStubURLProtocol.configure([
        .connectionLostBeforeText,
        .structuredSuccess(#"{"value":"must not be requested"}"#)
    ])
    let _: StructuredSelfTestOutput = try await retryClient.structuredResponse(
        apiKey: secretAPIKey,
        model: "self-test-model",
        instructions: "Return structured JSON.",
        input: secretChatText,
        schemaName: "background_create_failure_self_test",
        schema: .strictObject(properties: [
            "value": .object(["type": .string("string")])
        ]),
        diagnosticContext: DiagnosticRequestContext(
            flow: "learning_background_create_failure"
        )
    )
    failures += 1
    print("✗ Background 创建连接丢失应返回错误")
} catch {
    expect(
        OpenAIStubURLProtocol.requestCount == 1
            && OpenAIStubURLProtocol.capturedRequestMethods == ["POST"],
        "Background 创建结果不明确时不会重复 POST 并产生重复推理"
    )
}

do {
    OpenAIStubURLProtocol.configure([
        .structuredSuccess(#"{"wrong":"first response cannot decode"}"#),
        .structuredSuccess(#"{"value":"recovered after decode retry"}"#)
    ])
    let structured: StructuredSelfTestOutput = try await retryClient.structuredResponse(
        apiKey: secretAPIKey,
        model: "self-test-model",
        instructions: "Return structured JSON.",
        input: secretChatText,
        schemaName: "decode_retry_self_test",
        schema: .strictObject(properties: [
            "value": .object(["type": .string("string")])
        ]),
        diagnosticContext: DiagnosticRequestContext(flow: "learning_decode_retry")
    )
    expect(
        structured.value == "recovered after decode retry",
        "结构化内容解码失败后会自动紧凑重试一次"
    )
    expect(OpenAIStubURLProtocol.requestCount == 2, "结构化解码重试最多额外请求一次")
    let retryRequest = OpenAIStubURLProtocol.lastRequestBody.flatMap {
        try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
    }
    expect(
        (retryRequest?["instructions"] as? String)?.contains(
            "Do not pad any field with spaces"
        ) == true,
        "结构化内容重试会要求模型返回紧凑完整 JSON"
    )
    let retryEntries = learningDebugStore.entries().filter {
        $0.flow == "learning_decode_retry"
    }
    expect(
        retryEntries.count == 2
            && retryEntries.contains(where: {
                $0.status == .failed
                    && $0.errorMessage?.contains("missing required field 'value'") == true
            }),
        "Learn Debug 会保留首次解码失败的具体字段"
    )
} catch {
    failures += 1
    print("✗ 结构化解码重试自检出错：\(error.localizedDescription)")
}

do {
    OpenAIStubURLProtocol.configure([
        .structuredIncomplete(#"{"value":"truncated""#, reason: "max_output_tokens"),
        .structuredSuccess(#"{"value":"recovered after truncation"}"#)
    ])
    let structured: StructuredSelfTestOutput = try await retryClient.structuredResponse(
        apiKey: secretAPIKey,
        model: "self-test-model",
        instructions: "Return structured JSON.",
        input: secretChatText,
        schemaName: "incomplete_retry_self_test",
        schema: .strictObject(properties: [
            "value": .object(["type": .string("string")])
        ]),
        diagnosticContext: DiagnosticRequestContext(flow: "learning_incomplete_retry")
    )
    expect(
        structured.value == "recovered after truncation",
        "达到输出 token 上限的结构化响应不会解码，并会自动重试"
    )
    expect(OpenAIStubURLProtocol.requestCount == 2, "截断响应只触发一次内容重试")
    let incompleteEntry = learningDebugStore.entries().first {
        $0.flow == "learning_incomplete_retry" && $0.status == .failed
    }
    expect(
        incompleteEntry?.response == #"{"value":"truncated""#,
        "Learn Debug 保留截断时的模型原始输出"
    )
    expect(
        incompleteEntry?.tokenUsage?.totalTokens == 148,
        "Learn Debug 在截断失败时仍保留 token 用量"
    )
    expect(
        incompleteEntry?.errorMessage?.contains("output-token limit") == true,
        "Learn Debug 明确显示结构化响应因 token 上限而截断"
    )
} catch {
    failures += 1
    print("✗ 结构化截断重试自检出错：\(error.localizedDescription)")
}

OpenAIStubURLProtocol.configure([
    .structuredSuccess(#"{"wrong":"first"}"#),
    .structuredSuccess(#"{"wrong":"second"}"#)
])
var finalStructuredError = ""
do {
    let _: StructuredSelfTestOutput = try await retryClient.structuredResponse(
        apiKey: secretAPIKey,
        model: "self-test-model",
        instructions: "Return structured JSON.",
        input: secretChatText,
        schemaName: "decode_failure_self_test",
        schema: .strictObject(properties: [
            "value": .object(["type": .string("string")])
        ]),
        diagnosticContext: DiagnosticRequestContext(flow: "learning_decode_failure")
    )
} catch {
    finalStructuredError = error.localizedDescription
}
expect(
    finalStructuredError.contains("missing required field 'value'")
        && finalStructuredError.contains("retried once"),
    "两次结构化解码失败后会显示具体字段和已重试信息"
)
expect(OpenAIStubURLProtocol.requestCount == 2, "内容无效时不会无限重试")

do {
    OpenAIStubURLProtocol.configure([
        .connectionLostBeforeText,
        .connectionLostBeforeText,
        .success("Recovered")
    ])
    var output = ""
    for try await delta in retryClient.streamResponse(
        apiKey: secretAPIKey,
        model: "self-test-model",
        instructions: "private instructions must not appear",
        input: secretChatText
    ) {
        output += delta
    }
    expect(output == "Recovered", "未收到文字时最多重试两次并可在第三次恢复")
    expect(OpenAIStubURLProtocol.requestCount == 3, "两次自动重试总计发起三次请求")
} catch {
    failures += 1
    print("✗ 无文字断线重试自检出错：\(error.localizedDescription)")
}

OpenAIStubURLProtocol.configure([
    .connectionLostBeforeText,
    .connectionLostBeforeText,
    .connectionLostBeforeText,
    .success("Fourth attempt must not happen")
])
var exhaustedRetryDidFail = false
do {
    for try await _ in retryClient.streamResponse(
        apiKey: secretAPIKey,
        model: "self-test-model",
        instructions: "private instructions must not appear",
        input: secretChatText
    ) {}
} catch {
    exhaustedRetryDidFail = true
}
expect(exhaustedRetryDidFail, "连续网络错误在两次重试后会报告失败")
expect(OpenAIStubURLProtocol.requestCount == 3, "连续失败时不会发起第四次请求")

OpenAIStubURLProtocol.configure([
    .partialTextThenConnectionLost("Partial"),
    .success("Should not be requested")
])
var partialOutput = ""
var partialRequestDidFail = false
do {
    for try await delta in retryClient.streamResponse(
        apiKey: secretAPIKey,
        model: "self-test-model",
        instructions: "private instructions must not appear",
        input: secretChatText
    ) {
        partialOutput += delta
    }
} catch {
    partialRequestDidFail = true
}
expect(partialRequestDidFail, "收到部分文字后断线会向界面报告错误")
expect(partialOutput == "Partial", "收到部分文字后断线会保留已有输出")
expect(OpenAIStubURLProtocol.requestCount == 1, "收到部分文字后不会自动重试")

retryLogger.flush()
let diagnosticFiles = ([retryLogger.logFileURL] + (1...5).map(retryLogger.archivedLogFileURL))
    .filter { FileManager.default.fileExists(atPath: $0.path) }
let diagnosticText = diagnosticFiles.compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined()
expect(diagnosticText.contains("retry_scheduled"), "诊断日志记录重试事件")
expect(!diagnosticText.contains(secretAPIKey), "诊断日志不记录 API Key")
expect(diagnosticText.contains(secretChatText), "诊断日志记录聊天正文以便事后定位")
expect(diagnosticText.contains("private instructions must not appear"), "诊断日志记录 prompt")
expect(diagnosticText.contains("Recovered"), "诊断日志记录完整模型输出")
expect(diagnosticText.contains("Partial"), "诊断日志记录失败前的部分模型输出")
expect(diagnosticText.contains("self-test-model"), "诊断日志记录请求模型")
expect(diagnosticText.contains("\"total_tokens\":148"), "诊断日志记录 token 用量")
expect(diagnosticText.contains("response_received"), "诊断日志记录 HTTP 响应阶段")
expect(diagnosticText.contains("response_headers"), "诊断日志记录 HTTP 响应头")
expect(diagnosticText.contains("stream_done_received"), "诊断日志记录流式完成标记")

retryLogger.event(
    "redaction_probe",
    component: "self_test",
    details: [
        "chat_text": .string("before \(secretAPIKey) after"),
        "authorization": .string("Bearer \(secretAPIKey)")
    ]
)
retryLogger.flush()
let redactionProbeText = (try? String(contentsOf: retryLogger.logFileURL, encoding: .utf8))
    ?? ""
expect(redactionProbeText.contains("before <redacted-api-key> after"), "聊天正文中的 API Key 会脱敏")
expect(redactionProbeText.contains("Bearer <redacted-api-key>"), "Authorization 形式的 API Key 会脱敏")
expect(!redactionProbeText.contains(secretAPIKey), "脱敏测试不会泄露 API Key")

retryLogger.event(
    "synchronous_error_probe",
    level: .error,
    component: "self_test",
    failure: DiagnosticFailure(
        statusCode: 500,
        errorDomain: "SelfTest",
        errorCode: 500,
        message: "Persist immediately"
    )
)
let immediateErrorText = (try? String(
    contentsOf: retryLogger.logFileURL,
    encoding: .utf8
)) ?? ""
expect(
    immediateErrorText.contains("synchronous_error_probe"),
    "错误日志会同步落盘"
)

let exportedDiagnosticURL = retryTestDirectory.appendingPathComponent(
    "MacTranslator-Diagnostics.jsonl"
)
do {
    try retryLogger.exportArchive(to: exportedDiagnosticURL)
    let exportedText = try String(contentsOf: exportedDiagnosticURL, encoding: .utf8)
    let exportedLines = exportedText.split(separator: "\n")
    let allLinesAreJSON = exportedLines.allSatisfy {
        guard let data = String($0).data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }
    expect(exportedText.contains(secretChatText), "导出的诊断日志包含完整问题上下文")
    expect(exportedText.contains("Recovered"), "导出的诊断日志包含模型结果")
    expect(!exportedText.contains(secretAPIKey), "导出的诊断日志不包含 API Key")
    expect(allLinesAreJSON, "导出的每一行都是有效 JSON")
} catch {
    failures += 1
    print("✗ 诊断日志导出自检出错：\(error.localizedDescription)")
}

let rotationTestDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent("MacTranslatorLogRotation-\(UUID().uuidString)", isDirectory: true)
defer { try? FileManager.default.removeItem(at: rotationTestDirectory) }
let rotationLogger = DiagnosticLogger(
    directoryURL: rotationTestDirectory,
    maxFileSize: 350,
    retainedFileCount: 5
)
let oldestRequestID = UUID()
rotationLogger.requestStarted(requestID: oldestRequestID, attempt: 1)
rotationLogger.flush()
for _ in 0..<30 {
    rotationLogger.requestStarted(requestID: UUID(), attempt: 1)
}
rotationLogger.flush()
let retainedDiagnosticFiles = (
    [rotationLogger.logFileURL] + (1...5).map(rotationLogger.archivedLogFileURL)
)
    .filter { FileManager.default.fileExists(atPath: $0.path) }
let retainedDiagnosticText = retainedDiagnosticFiles
    .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
    .joined()
expect(retainedDiagnosticFiles.count > 1, "诊断日志达到大小限制后会轮转")
expect(
    !FileManager.default.fileExists(atPath: rotationLogger.archivedLogFileURL(index: 6).path),
    "诊断日志最多保留五个归档文件"
)
expect(
    !retainedDiagnosticText.contains(oldestRequestID.uuidString),
    "超过轮转保留数量后会删除最旧日志"
)

let lifecycleTestDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent("MacTranslatorLifecycleLogs-\(UUID().uuidString)", isDirectory: true)
defer { try? FileManager.default.removeItem(at: lifecycleTestDirectory) }
let interruptedLogger = DiagnosticLogger(directoryURL: lifecycleTestDirectory)
interruptedLogger.startApplicationSession(
    details: ["app_version": .string("self-test")]
)
let restartedLogger = DiagnosticLogger(directoryURL: lifecycleTestDirectory)
restartedLogger.startApplicationSession(
    details: ["app_version": .string("self-test")]
)
restartedLogger.endApplicationSession()
let lifecycleText = (try? String(contentsOf: restartedLogger.logFileURL, encoding: .utf8))
    ?? ""
expect(lifecycleText.contains("application_started"), "诊断日志记录程序启动")
expect(lifecycleText.contains("application_terminated"), "诊断日志记录正常退出")
expect(lifecycleText.contains("previous_session_unclosed"), "下次启动会识别上次异常退出")

if CommandLine.arguments.contains("--live-openai") {
    do {
        func liveStage(_ message: String) {
            FileHandle.standardError.write(Data("[live] \(message)\n".utf8))
        }
        liveStage("reading API key")
        guard let apiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"],
              !apiKey.isEmpty else {
            throw NSError(
                domain: "MacTranslatorSelfTests",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Set OPENAI_API_KEY in the shell before running live self-tests."
                ]
            )
        }
        let appDefaults = UserDefaults(suiteName: "com.mario.MacTranslator")
        let model = AppSettings.resolvedModel(
            appDefaults?.string(forKey: AppSettings.modelKey)
        )
        let liveDiagnosticDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "MacTranslatorLiveDiagnostics-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: liveDiagnosticDirectory) }
        let liveLogger = DiagnosticLogger(directoryURL: liveDiagnosticDirectory)
        let liveClient = OpenAIClient(diagnosticLogger: liveLogger)
        liveStage("streaming request with \(model)")
        var output = ""
        for try await delta in liveClient.streamResponse(
            apiKey: apiKey,
            model: model,
            instructions: "Reply with exactly one short word.",
            input: "hello"
        ) {
            output += delta
        }
        expect(!output.isEmpty, "真实 OpenAI 流式请求成功（model: \(model)）")

        liveStage("structured request")
        let liveStructured: StructuredSelfTestOutput = try await liveClient.structuredResponse(
            apiKey: apiKey,
            model: model,
            instructions: "Return the requested value as structured JSON.",
            input: "Set value to live.",
            schemaName: "live_self_test",
            schema: .strictObject(properties: [
                "value": .object(["type": .string("string")])
            ])
        )
        expect(!liveStructured.value.isEmpty, "真实 OpenAI 结构化输出请求成功")

        liveStage("learning analysis")
        let liveLearningDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacTranslatorLiveLearning-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: liveLearningDirectory) }
        let liveHistoryStore = ChatHistoryStore(directoryURL: liveLearningDirectory)
        let liveLearningStore = LearningStore(
            directoryURL: liveLearningDirectory,
            diagnosticLogger: liveLogger
        )
        let liveTurnID = UUID()
        let liveUserMessage = ChatMessage(
            role: .user,
            text: "He go to the office yesterday.",
            mode: .correct,
            turnID: liveTurnID
        )
        let liveAssistantMessage = ChatMessage(
            role: .assistant,
            text: "He went to the office yesterday.",
            mode: .correct,
            turnID: liveTurnID
        )
        try liveHistoryStore.upsert(liveUserMessage, position: 0)
        try liveHistoryStore.upsert(liveAssistantMessage, position: 1)
        try liveHistoryStore.upsertTurn(
            ChatTurn(
                id: liveTurnID,
                mode: .correct,
                userMessageID: liveUserMessage.id,
                assistantMessageID: liveAssistantMessage.id,
                createdAt: liveUserMessage.createdAt,
                completedAt: Date(),
                status: .completed,
                model: model,
                promptFingerprint: PromptFingerprint.make("live learning test")
            )
        )
        let liveEngine = LearningEngine(
            historyStore: liveHistoryStore,
            learningStore: liveLearningStore,
            client: liveClient,
            diagnosticLogger: liveLogger
        )
        let liveSync = try await liveEngine.syncHistory(apiKey: apiKey, model: model)
        expect(
            liveSync.analyzedTurnCount == 1 && liveSync.evidenceCount > 0,
            "真实模型可以从 t 记录提取学习证据"
        )
        liveStage("question generation")
        var liveDashboard = try await liveEngine.startOrResumeSession(
            apiKey: apiKey,
            model: model
        )
        let liveAttempts = liveDashboard.activeSession?.attempts ?? []
        expect(
            liveAttempts.count == LearningEngine.expressionBatchSize
                && liveAttempts.allSatisfy {
                    $0.question.type == .chineseToEnglish
                        && $0.question.batchID != nil
                },
            "真实模型一次生成五道中文到英文表达题"
        )
        if liveAttempts.count == LearningEngine.expressionBatchSize {
            liveStage("answer grading")
            let liveAnswers = Dictionary(
                uniqueKeysWithValues: liveAttempts.map {
                    ($0.question.id, $0.question.referenceAnswer)
                }
            )
            liveDashboard = try await liveEngine.submitAnswers(
                liveAnswers,
                apiKey: apiKey,
                model: model
            )
            expect(
                liveDashboard.activeSession?.attempts.allSatisfy {
                    $0.grade != nil
                } == true,
                "真实模型可以一次判定整批答案并生成中文讲解"
            )
            expect(
                liveDashboard.activeSession?.attempts.allSatisfy {
                    !($0.grade?.patterns.isEmpty ?? true)
                } == true,
                "整批判题中的每道题都会生成可复用句式"
            )
        }
        liveStage("complete")
    } catch {
        failures += 1
        print("✗ 真实 OpenAI 流式请求失败：\(error.localizedDescription)")
    }
}

if failures > 0 {
    print("\n\(failures) 项自检失败")
    exit(1)
}

print("\n全部命令兼容自检通过")
