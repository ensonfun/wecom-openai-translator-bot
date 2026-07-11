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
