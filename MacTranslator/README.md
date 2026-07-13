# Mac Translator

一个完全在本机运行的原生 macOS 对话入口。它不依赖企业微信，直接调用 OpenAI Responses API，并保持原 `wecom_translator` 的 prompt 与命令行为。

## 命令

```text
hello world
t she no went to the market.
s 这个需求我晚点跟进，先回滚 prod
```

- 无前缀：翻译为简体中文
- `t ` / `T `：英文标准化、中文解释与中文翻译
- `s ` / `S `：生成两版适合 Slack 的英文消息，并提供反馈

每条请求独立调用模型；窗口会保留本地显示历史，但不会把前文自动发给模型。这与原企业微信版本的行为一致。

聊天记录会自动保存在 SQLite：

```text
~/Library/Application Support/MacTranslator/chat-history.sqlite3
```

重新启动 App 时会自动恢复。点击 “Clear” 会同时删除内存与数据库中的记录。旧版 `chat-history.json` 会在首次启动时自动迁移到 SQLite 并删除。

右上角的导出按钮可以将当前完整记录导出为格式化 JSON。聊天正文只保存在本机；API Key 仍然只保存在 macOS Keychain。

如果请求在尚未返回任何文字时遇到临时网络错误，App 会自动重试最多 2 次（首次请求加两次重试，共最多 3 次请求）。一旦已经返回部分文字，后续断线不会自动重试，以免产生重复或不一致的回答；已返回的部分仍会保留在聊天记录中。

诊断日志位于：

```text
~/Library/Logs/MacTranslator/MacTranslator.log
```

日志按 1 MiB 轮转，最多保留 5 个旧文件（`.1` 到 `.5`）。其中只记录请求编号、尝试次数、HTTP 状态、错误域/错误码、是否收到文字、重试等待时间和耗时；不会记录 API Key、prompt、聊天正文或模型返回正文。

App 的界面语言为英文。

Settings 的 Prompts 页面可以查看、修改或恢复 Default、`t` 和 `s` 三个 prompt。每次请求只会发送当前消息和本次选中的 prompt，SQLite 历史记录不会发送给 OpenAI。

输入框默认按 Return 发送；Shift+Return 或 Command+Return 插入换行。聊天区与输入区之间的分隔条可以上下拖动，调整两块区域的高度。

Settings 的 General 页面可以启用并录制一个系统级快捷键，在其他应用中快速呼出 Mac Translator。默认建议组合为 `⌃⌥M`，但首次安装不会自动启用。

应用图标的 1024px 主图和 macOS `.icns` 文件分别位于 `Resources/AppIcon.png` 与 `Resources/AppIcon.icns`。

## 运行

要求 macOS 14 或更高版本。

```bash
cd MacTranslator
swift run MacTranslator
```

首次打开后进入“设置”，填写 OpenAI API Key。Key 只会保存到 macOS Keychain，也可以在从终端启动时通过 `OPENAI_API_KEY` 环境变量提供。

默认模型是 `gpt-5.4-mini`，可以在设置中修改。

## 生成 `.app`

```bash
cd MacTranslator
./build-app.sh
open dist/MacTranslator.app
```

生成的应用是同时支持 Apple Silicon 与 Intel Mac 的 Universal 2 二进制，并使用 ad-hoc 签名。若要消除其他用户首次打开时的 Gatekeeper 警告，还需要配置 Apple Developer ID 签名与 notarization。

## 生成 DMG

```bash
cd MacTranslator
./build-dmg.sh
```

产物位于 `dist/MacTranslator-<version>.dmg`，同时生成对应的 `.sha256` 校验文件。仓库中的 GitHub Actions 工作流会在推送 `v<version>` tag 时构建相同产物并创建 GitHub Release。

## 测试

```bash
cd MacTranslator
swift run MacTranslatorSelfTests
```

这里使用零依赖自检程序，是因为只有 Command Line Tools、未安装完整 Xcode 的机器通常不包含 `XCTest` 框架。
