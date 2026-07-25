# Mac Translator

本项目现在以原生 macOS App 为主：从 Mac 本机直接调用 OpenAI Responses API，提供翻译、英文纠错和 Slack 文案润色，不再依赖企业微信作为消息入口。

## macOS App

App 位于 [`MacTranslator/`](MacTranslator/)，支持原 `wecom_translator` 的相同 prompt 和命令：

- 无前缀：翻译为简体中文
- `t ` / `T `：英文标准化、中文解释与中文翻译
- `s ` / `S `：Slack 风格润色

App 还提供独立的 **Learn** 页面：它会增量分析新的 `t` / `s` 记录，建立本地英语能力画像，并针对高频错误自动出题、判题、讲解和安排复习。学习过程采用只追加事件记录，App 重启后可以恢复未完成的题目和进度。

快速运行：

```bash
cd MacTranslator
swift run MacTranslator
```

构建可双击运行的应用：

```bash
cd MacTranslator
./build-app.sh
open dist/MacTranslator.app
```

构建可分发的 DMG：

```bash
cd MacTranslator
./build-dmg.sh
```

推送与 App 版本一致的 tag（例如 `v1.0.0`）后，GitHub Actions 会自动创建 Release，并上传 DMG 与 SHA-256 校验文件。

API Key 在 App 设置中填写并保存在 macOS Keychain。完整说明见 [`MacTranslator/README.md`](MacTranslator/README.md)。

聊天记录会保存在 SQLite 数据库 `~/Library/Application Support/MacTranslator/chat-history.sqlite3`，重启 App 后自动恢复。界面中的 “Clear” 会清空记录，右上角导出按钮可以导出为 JSON。App 界面语言为英文。

学习事件、知识点投影、复习计划和 session 也保存在同一个 SQLite 数据库中。清空聊天不会自动删除已经提炼的学习画像；学习数据可以在 Settings → Learning 中单独重置、重建或永久删除。

App 会持续写入可轮转的 JSON Lines 运行日志，记录 Chat、Learn、OpenAI、SQLite、Keychain 和启动/退出的完整诊断链路。除 OpenAI API Key 始终脱敏外，日志会保留问题现场所需的输入与输出。可以在 Settings → Diagnostics 中查看位置或一键导出。

## 旧企业微信实现

原 Python/企业微信长连接代码暂时保留在 `wecom_translator/`、`app.py` 和 `tests/` 中，方便核对旧行为或后续迁移；新的 macOS App 不引用这些代码，也不需要 WeCom Bot ID、Secret、WebSocket 或 Python 运行环境。

旧测试仍可运行：

```bash
source .venv/bin/activate
pytest
```
