from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path


def load_dotenv(dotenv_path: str = ".env") -> None:
    path = Path(dotenv_path)
    if not path.exists():
        return

    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue

        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip()

        if not key:
            continue

        if value and len(value) >= 2 and value[0] == value[-1] and value[0] in {'"', "'"}:
            value = value[1:-1]

        os.environ.setdefault(key, value)


def _env_int(name: str, default: int) -> int:
    raw = os.getenv(name)
    if raw is None:
        return default
    return int(raw)


@dataclass
class Settings:
    openai_api_key: str | None = field(default_factory=lambda: os.getenv("OPENAI_API_KEY"))
    openai_model: str = field(default_factory=lambda: os.getenv("OPENAI_MODEL", "gpt-5-mini"))
    wecom_bot_id: str = field(default_factory=lambda: os.getenv("WECOM_BOT_ID", ""))
    wecom_bot_secret: str = field(default_factory=lambda: os.getenv("WECOM_BOT_SECRET", ""))
    wecom_ws_url: str = field(default_factory=lambda: os.getenv("WECOM_WS_URL", ""))
    heartbeat_interval_ms: int = field(default_factory=lambda: _env_int("HEARTBEAT_INTERVAL_MS", 30000))
    reconnect_interval_ms: int = field(default_factory=lambda: _env_int("RECONNECT_INTERVAL_MS", 1000))
    max_reconnect_attempts: int = field(default_factory=lambda: _env_int("MAX_RECONNECT_ATTEMPTS", -1))
    worker_count: int = field(default_factory=lambda: _env_int("WORKER_COUNT", 4))
    log_level: str = field(default_factory=lambda: os.getenv("LOG_LEVEL", "INFO"))
    log_dir: str = field(default_factory=lambda: os.getenv("LOG_DIR", "logs"))
    log_retention_days: int = field(default_factory=lambda: _env_int("LOG_RETENTION_DAYS", 14))

    def validate(self) -> None:
        required = {
            "WECOM_BOT_ID": self.wecom_bot_id,
            "WECOM_BOT_SECRET": self.wecom_bot_secret,
        }
        missing = [name for name, value in required.items() if not value]
        if missing:
            raise ValueError(f"Missing required settings: {', '.join(missing)}")
