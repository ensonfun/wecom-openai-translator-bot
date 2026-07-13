import Darwin
import Foundation
import MacTranslatorCore

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
    }

    private static let lock = NSLock()
    private static var outcomes: [Outcome] = []
    private static var requests = 0

    static func configure(_ newOutcomes: [Outcome]) {
        lock.lock()
        outcomes = newOutcomes
        requests = 0
        lock.unlock()
    }

    static var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let outcome: Outcome
        Self.lock.lock()
        Self.requests += 1
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
    AppSettings.resolvedModel("gpt-5.6-luna") == "gpt-5.5",
    "不可用的 gpt-5.6-luna 设置会迁移到 gpt-5.5"
)
expect(
    AppSettings.resolvedModel("gpt-5.4-mini") == "gpt-5.4-mini",
    "其他自定义模型设置保持不变"
)

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
    expect(restoredMessages == savedMessages, "旧 JSON 聊天记录会迁移到 SQLite")
    expect(FileManager.default.fileExists(atPath: historyStore.databaseURL.path), "SQLite 数据库已创建")
    expect(!FileManager.default.fileExists(atPath: historyStore.legacyJSONURL.path), "迁移成功后删除旧 JSON")

    let updatedText = "你好，世界"
    try historyStore.updateText(id: savedMessages[1].id, text: updatedText)
    let messagesAfterUpdate = try historyStore.load()
    expect(messagesAfterUpdate[1].text == updatedText, "流式响应只更新当前消息行")

    let thirdMessage = ChatMessage(role: .user, text: "S hello", mode: .slack)
    try historyStore.upsert(thirdMessage, position: 2)
    let messagesAfterInsert = try historyStore.load()
    expect(messagesAfterInsert.count == 3, "可以增量插入单条消息")

    let exportURL = testDirectory.appendingPathComponent("export.json")
    try historyStore.exportJSON(to: exportURL)
    let exportedMessages = try JSONDecoder().decode(
        [ChatMessage].self,
        from: Data(contentsOf: exportURL)
    )
    expect(exportedMessages.count == 3, "聊天记录可以导出为 JSON")

    try historyStore.clear()
    let clearedMessages = try historyStore.load()
    expect(clearedMessages.isEmpty, "清空按钮会删除 SQLite 中的聊天记录")
} catch {
    failures += 1
    print("✗ 聊天记录持久化自检出错：\(error.localizedDescription)")
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
    maxFileSize: 350,
    retainedFileCount: 5
)
let stubConfiguration = URLSessionConfiguration.ephemeral
stubConfiguration.protocolClasses = [OpenAIStubURLProtocol.self]
let stubSession = URLSession(configuration: stubConfiguration)
defer { stubSession.invalidateAndCancel() }
let retryClient = OpenAIClient(
    endpoint: URL(string: "https://self-test.invalid/v1/responses")!,
    session: stubSession,
    diagnosticLogger: retryLogger,
    retryDelayNanoseconds: [0, 0]
)
let secretAPIKey = "sk-self-test-must-not-appear"
let secretChatText = "private chat body must not appear"

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
expect(diagnosticFiles.count > 1, "诊断日志达到大小限制后会轮转")
expect(diagnosticText.contains("retry_scheduled"), "诊断日志记录重试事件")
expect(!diagnosticText.contains(secretAPIKey), "诊断日志不记录 API Key")
expect(!diagnosticText.contains(secretChatText), "诊断日志不记录聊天正文")
expect(!diagnosticText.contains("private instructions must not appear"), "诊断日志不记录 prompt")
expect(!diagnosticText.contains("Recovered"), "诊断日志不记录模型返回正文")
expect(!diagnosticText.contains("Partial"), "诊断日志不记录部分模型返回正文")

let oldestRequestID = UUID()
retryLogger.requestStarted(requestID: oldestRequestID, attempt: 1)
retryLogger.flush()
for _ in 0..<30 {
    retryLogger.requestStarted(requestID: UUID(), attempt: 1)
}
retryLogger.flush()
let retainedDiagnosticFiles = ([retryLogger.logFileURL] + (1...5).map(retryLogger.archivedLogFileURL))
    .filter { FileManager.default.fileExists(atPath: $0.path) }
let retainedDiagnosticText = retainedDiagnosticFiles
    .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
    .joined()
expect(
    !FileManager.default.fileExists(atPath: retryLogger.archivedLogFileURL(index: 6).path),
    "诊断日志最多保留五个归档文件"
)
expect(
    !retainedDiagnosticText.contains(oldestRequestID.uuidString),
    "超过轮转保留数量后会删除最旧日志"
)

if CommandLine.arguments.contains("--live-openai") {
    do {
        guard let apiKey = try KeychainStore().read(), !apiKey.isEmpty else {
            throw NSError(
                domain: "MacTranslatorSelfTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "OpenAI API key is missing from Keychain."]
            )
        }
        let appDefaults = UserDefaults(suiteName: "com.mario.MacTranslator")
        let model = AppSettings.resolvedModel(
            appDefaults?.string(forKey: AppSettings.modelKey)
        )
        var output = ""
        for try await delta in OpenAIClient().streamResponse(
            apiKey: apiKey,
            model: model,
            instructions: "Reply with exactly one short word.",
            input: "hello"
        ) {
            output += delta
        }
        expect(!output.isEmpty, "真实 OpenAI 流式请求成功（model: \(model)）")
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
