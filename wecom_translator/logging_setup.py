from __future__ import annotations

import json
import logging
from datetime import datetime
from pathlib import Path
from typing import Any


SENSITIVE_KEYS = {
    "access_token",
    "api_key",
    "authorization",
    "corpsecret",
    "encoding_aes_key",
    "msg_signature",
    "nonce",
    "openai_api_key",
    "secret",
    "signature",
    "suite_secret",
    "token",
}


class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        payload = {
            "time": self.formatTime(record, self.datefmt),
            "level": record.levelname,
            "logger": record.name,
            "message": record.getMessage(),
        }
        extra = getattr(record, "payload", None)
        if isinstance(extra, dict):
            payload.update(sanitize(extra))
        if record.exc_info:
            payload["exception"] = self.formatException(record.exc_info)
        return json.dumps(payload, ensure_ascii=False)


def sanitize(value: Any) -> Any:
    if isinstance(value, dict):
        sanitized: dict[str, Any] = {}
        for key, item in value.items():
            if key.lower() in SENSITIVE_KEYS:
                sanitized[key] = "***"
            else:
                sanitized[key] = sanitize(item)
        return sanitized
    if isinstance(value, list):
        return [sanitize(item) for item in value]
    return value


class DailyFileHandler(logging.Handler):
    def __init__(self, log_dir: Path, stem: str, retention_days: int) -> None:
        super().__init__()
        self._log_dir = log_dir
        self._stem = stem
        self._retention_days = retention_days
        self._log_dir.mkdir(parents=True, exist_ok=True)
        self._current_date = ""
        self._current_path: Path | None = None
        self._stream: Any = None

    def _target_path(self, date_str: str) -> Path:
        return self._log_dir / f"{self._stem}-{date_str}.log"

    def _cleanup(self) -> None:
        files = sorted(self._log_dir.glob(f"{self._stem}-*.log"))
        excess = len(files) - self._retention_days
        if excess <= 0:
            return
        for path in files[:excess]:
            if self._current_path and path == self._current_path:
                continue
            path.unlink(missing_ok=True)

    def _ensure_stream(self) -> None:
        date_str = datetime.now().strftime("%Y%m%d")
        if date_str == self._current_date and self._stream is not None:
            return

        if self._stream is not None:
            self._stream.close()

        self._current_date = date_str
        self._current_path = self._target_path(date_str)
        self._stream = self._current_path.open("a", encoding="utf-8")
        self._cleanup()

    def emit(self, record: logging.LogRecord) -> None:
        try:
            self.acquire()
            self._ensure_stream()
            message = self.format(record)
            self._stream.write(f"{message}\n")
            self._stream.flush()
        finally:
            self.release()

    def close(self) -> None:
        try:
            self.acquire()
            if self._stream is not None:
                self._stream.close()
                self._stream = None
        finally:
            self.release()
        super().close()


def _build_daily_handler(log_dir: Path, stem: str, retention_days: int) -> DailyFileHandler:
    handler = DailyFileHandler(log_dir=log_dir, stem=stem, retention_days=retention_days)
    handler.setFormatter(JsonFormatter())
    return handler


def configure_logging(log_dir: str, level: str, retention_days: int) -> tuple[logging.Logger, logging.Logger]:
    resolved_level = getattr(logging, level.upper(), logging.INFO)
    path = Path(log_dir)

    app_logger = logging.getLogger("wecom_translator.app")
    error_logger = logging.getLogger("wecom_translator.error")

    for logger in (app_logger, error_logger):
        logger.handlers.clear()
        logger.setLevel(resolved_level)
        logger.propagate = False

    app_handler = _build_daily_handler(path, "app", retention_days)
    error_handler = _build_daily_handler(path, "error", retention_days)

    console = logging.StreamHandler()
    console.setFormatter(JsonFormatter())
    console.setLevel(resolved_level)

    error_console = logging.StreamHandler()
    error_console.setFormatter(JsonFormatter())
    error_console.setLevel(resolved_level)

    app_logger.addHandler(app_handler)
    app_logger.addHandler(console)
    error_logger.addHandler(error_handler)
    error_logger.addHandler(error_console)

    return app_logger, error_logger


def log_input(logger: logging.Logger, message: dict[str, Any]) -> None:
    logger.info("inbound_message", extra={"payload": {"event": "input", **message}})


def log_output(logger: logging.Logger, message: dict[str, Any]) -> None:
    logger.info("outbound_message", extra={"payload": {"event": "output", **message}})


def log_error(logger: logging.Logger, stage: str, message: str, **extra: Any) -> None:
    logger.error(message, extra={"payload": {"event": "error", "stage": stage, **extra}})
