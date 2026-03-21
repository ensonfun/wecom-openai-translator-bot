# WeCom OpenAI Translator Bot

A translation bot for WeCom intelligent bots, powered by OpenAI.

It connects to the official WeCom long-lived WebSocket channel, receives user messages from WeCom chats, applies your custom translation prompts, and sends the translated or polished result back to the same conversation.

## Features

- Default translation to Simplified Chinese
- `T/t` command for English correction + Chinese explanation + Chinese translation
- `S/s` command for Slack-style message polishing
- `*#clear` command for clearing in-memory session state
- Direct chat and group chat support
- Full input, output, and error logging
- Daily log splitting with filenames like `app-YYYYMMDD.log`
- OpenAI official Responses API integration
- Official WeCom intelligent bot long-connection SDK integration

## How It Works

1. The service connects to WeCom over the official WebSocket long-connection channel.
2. WeCom pushes text messages to the bot.
3. The bot parses command prefixes and selects the matching prompt.
4. The service sends the cleaned user text to OpenAI.
5. The translated or polished result is sent back to the same WeCom conversation.

## Commands

```text
hello world
T she no went to the market.
S 这个需求我晚点跟进，先回滚 prod
*#clear
```

Command behavior:

- No prefix: translate to Simplified Chinese
- `T ` / `t `: English correction + Chinese explanation + Chinese translation
- `S ` / `s `: Slack-style rewrite
- `*#clear`: clear in-memory session state for the current conversation

## Requirements

- Python 3.9+
- A WeCom intelligent bot with long-connection API mode enabled
- `BotID` and long-connection `Secret`
- An OpenAI API key

## Setup

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

## Configuration

Create a `.env` file in the project root. The application loads it automatically on startup.

Minimum required variables:

```env
OPENAI_API_KEY=your_openai_api_key
WECOM_BOT_ID=your_bot_id
WECOM_BOT_SECRET=your_bot_secret
```

Optional variables:

```env
OPENAI_MODEL=gpt-5-mini
WECOM_WS_URL=
HEARTBEAT_INTERVAL_MS=30000
RECONNECT_INTERVAL_MS=1000
MAX_RECONNECT_ATTEMPTS=-1
WORKER_COUNT=4
LOG_LEVEL=INFO
LOG_DIR=logs
LOG_RETENTION_DAYS=14
```

Notes:

- Leave `WECOM_WS_URL` empty to use the official default endpoint: `wss://openws.work.weixin.qq.com`
- `MAX_RECONNECT_ATTEMPTS=-1` means unlimited reconnect attempts
- The service prefers values already present in the shell and only falls back to `.env`

## Run

```bash
source .venv/bin/activate
python app.py
```

## Logging

Logs are written to `logs/` and split by day:

- `app-YYYYMMDD.log`
- `error-YYYYMMDD.log`

Logged events include:

- Input messages: message ID, chat type, sender, conversation ID, command type, raw text
- Output messages: message ID, model, command type, output text, send result
- Errors: stage, summary, context, and stack trace when available

Sensitive values such as API keys, secrets, and tokens are masked before logging.

## Project Structure

```text
wecom_translator/
  config.py
  logging_setup.py
  models.py
  prompts.py
  runtime.py
  router/
  services/
  state/
  transport/
tests/
app.py
requirements.txt
```

## Test

```bash
source .venv/bin/activate
pytest
```

## Current Scope

- Text messages only
- In-memory state only
- No database, Redis, or message queue
- No image, voice, video, or file translation workflow yet

## Deployment Notes

- This project is suitable for running on a small long-lived process, such as a VM, container, or lightweight server
- A `Dockerfile` is included for container-based deployment
- No inbound HTTP port is required in long-connection mode; the process only needs outbound access
- Make sure the process can reach both OpenAI and the official WeCom WebSocket endpoint

## License

No license file is included yet. Add one before publishing publicly if you want others to reuse the code.
