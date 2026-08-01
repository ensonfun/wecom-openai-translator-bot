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

## Personal English Teacher

主窗口左侧可以在 **Chat** 和 **Learn** 之间切换；侧栏可以收起为窄图标栏，减少对内容区域的占用。Learn 会形成完整的个人学习循环：

1. 自动发现尚未分析的 `t` / `s` 记录。
2. 只增量发送新记录，不重复发送完整历史。
3. 区分真实英文能力证据与中文输入中的学习兴趣。
4. 提取高频错误、正确使用证据和工作场景需求。
5. 选择当前最值得练习的知识点。
6. 每次展示一道自适应题目。
7. 保存答案后使用结构化模型输出判题，并用简体中文解释。
8. 根据题型、提示、重试和延迟复习更新掌握度。
9. App 中断后从已保存的答案或题目继续。

学习域使用事件溯源：聊天分析、问题、答案、判题和 session 状态都保存为只追加事件；当前知识点画像和复习队列是可以从事件重新生成的投影。

默认的长期掌握条件不是“答对一次”，而是需要跨 session、跨题型并包含自由表达和延迟复习证据。单次 session 达标后只会显示“本轮完成”，后续仍会安排间隔复习。

聊天记录会自动保存在 SQLite：

```text
~/Library/Application Support/MacTranslator/chat-history.sqlite3
```

重新启动 App 时会自动恢复。点击 “Clear” 会删除原始聊天记录，但保留已经提炼的学习事件和画像。旧版 `chat-history.json` 会在首次启动时自动迁移到 SQLite 并删除。

同一个数据库还会保存：

- 稳定的 chat turn ID 与请求元数据
- 只追加的学习事件
- 可重建的知识点、session、同步覆盖和复习投影

Settings 的 Learning 页面可以：

- 重建学习画像
- 重置练习进度并保留聊天弱项
- 永久删除全部学习事件和派生示例

Learn 页面可以单独导出完整的学习事件归档 JSON。

右上角的导出按钮可以将当前完整记录导出为格式化 JSON。聊天正文只保存在本机；API Key 仍然只保存在 macOS Keychain。

如果请求在尚未返回任何文字时遇到临时网络错误，App 会自动重试最多 2 次（首次请求加两次重试，共最多 3 次请求）。一旦已经返回部分文字，后续断线不会自动重试，以免产生重复或不一致的回答；已返回的部分仍会保留在聊天记录中。

诊断日志位于：

```text
~/Library/Logs/MacTranslator/MacTranslator.log
```

日志采用 JSON Lines 格式，单个文件达到 5 MiB 后自动轮转，最多保留 7 个旧文件（`.1` 到 `.7`）。日志会记录足够还原问题现场的信息，包括：

- App 版本、macOS 版本、启动、正常退出与上次异常退出
- Chat 的命令、prompt、输入、完整或部分模型输出及持久化状态
- OpenAI 请求阶段、模型、reasoning effort、HTTP 状态、request ID、重试、耗时和错误详情
- Learn 的历史同步、证据提取、出题、答案、判题、讲解和 session 状态
- SQLite 事件写入、投影重建、Keychain、设置与全局快捷键操作
- 错误域、错误码、错误说明、源代码位置和调用栈

只有 OpenAI API Key 会被强制脱敏；即使 Key 出现在聊天正文、错误信息或 Authorization 文本中也会替换为 `<redacted-api-key>`。为了能够在无需复现的情况下定位问题，其他聊天与学习内容会写入本机日志。

Settings → Diagnostics 可以在 Finder 中打开日志目录，也可以把当前文件和所有轮转文件合并导出为一个 `.jsonl` 文件。

App 的界面语言为英文。

Settings 的 Prompts 页面可以查看、修改或恢复 Default、`t` 和 `s` 三个 prompt。Chat 请求只发送当前消息和本次选中的 prompt。Learn 会另外发送尚未分析的少量 `t` / `s` 记录，出题和判题时只发送当前知识点及当前答案，不会发送完整事件归档。

Chat 和 Learn 共用 Settings → OpenAI 中的同一个 API Key。模型配置按工作负载分开：Chat 使用自己的模型；Learn 的历史分析以及互动出题/判题各自使用独立的模型和 reasoning effort。默认情况下，历史分析使用 `gpt-5.6-terra` + `high`，互动出题和判题使用 `gpt-5.6-luna` + `medium`。

如果 macOS 返回 Keychain 错误 `-25293`，设置页会提供 **Reconnect and Save**。该操作让系统重新连接 login keychain，并由 macOS 自己询问 Mac 登录密码；应用不会读取或保存这段登录密码。

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

Chat 默认模型是 `gpt-5.4-mini`。Learn 默认使用 `gpt-5.6-terra` + `high` 分析历史，使用 `gpt-5.6-luna` + `medium` 出题和判题；这些配置都可以在设置中修改。

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

需要验证真实 Responses API 的流式与结构化学习闭环时：

```bash
cd MacTranslator
OPENAI_API_KEY=... swift run MacTranslatorSelfTests --live-openai
```

真实闭环测试只使用合成句子，并将临时数据库写入系统临时目录，不读取正式聊天记录。
