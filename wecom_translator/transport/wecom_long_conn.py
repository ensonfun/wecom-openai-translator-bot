from __future__ import annotations

import asyncio
import logging
from typing import Any, Awaitable, Callable

from aibot import DefaultLogger, WSClient, WSClientOptions

from wecom_translator.config import Settings
from wecom_translator.logging_setup import log_error
from wecom_translator.models import ChatType, InboundMessage


MessageHandler = Callable[[InboundMessage], Awaitable[None]]
EventHandler = Callable[[dict[str, Any]], Awaitable[None]]


class AibotLoggerAdapter(DefaultLogger):
    def __init__(self, app_logger: logging.Logger, error_logger: logging.Logger) -> None:
        self._app_logger = app_logger
        self._error_logger = error_logger

    def debug(self, message: str, *args: Any) -> None:
        self._app_logger.debug(message, *args)

    def info(self, message: str, *args: Any) -> None:
        self._app_logger.info(message, *args)

    def warn(self, message: str, *args: Any) -> None:
        self._app_logger.warning(message, *args)

    def error(self, message: str, *args: Any) -> None:
        self._error_logger.error(message, *args)


def parse_frame_to_inbound(frame: dict[str, Any]) -> InboundMessage:
    headers = frame.get("headers", {})
    body = frame.get("body", {})
    chat_type = ChatType.GROUP if body.get("chattype") == "group" else ChatType.DIRECT
    chat_id = body.get("chatid")
    from_user = ((body.get("from") or {}) if isinstance(body.get("from"), dict) else {}).get("userid", "")
    msg_type = body.get("msgtype", "")
    text_payload = body.get("text") if isinstance(body.get("text"), dict) else {}
    content = text_payload.get("content", "") if msg_type == "text" else ""
    mentioned = chat_type == ChatType.DIRECT or "@" in content

    return InboundMessage(
        message_id=body.get("msgid", ""),
        chat_type=chat_type,
        from_user=from_user,
        conversation_id=chat_id or from_user,
        mentioned=mentioned,
        content=content,
        create_time=int(body.get("msgtime", 0) or 0),
        raw_payload=body,
        req_id=headers.get("req_id", ""),
        msg_type=msg_type,
        raw_frame=frame,
        agent_id=body.get("aibotid"),
        chat_id=chat_id,
    )


class WeComLongConnectionTransport:
    def __init__(
        self,
        settings: Settings,
        app_logger: logging.Logger,
        error_logger: logging.Logger,
        handler: MessageHandler,
        event_handler: EventHandler | None = None,
    ) -> None:
        self._settings = settings
        self._app_logger = app_logger
        self._error_logger = error_logger
        self._handler = handler
        self._event_handler = event_handler
        self._client = WSClient(
            WSClientOptions(
                bot_id=settings.wecom_bot_id,
                secret=settings.wecom_bot_secret,
                reconnect_interval=settings.reconnect_interval_ms,
                max_reconnect_attempts=settings.max_reconnect_attempts,
                heartbeat_interval=settings.heartbeat_interval_ms,
                ws_url=settings.wecom_ws_url,
                logger=AibotLoggerAdapter(app_logger, error_logger),
            )
        )

        self._client.on("connected", lambda: self._app_logger.info("WeCom bot websocket connected"))
        self._client.on("authenticated", lambda: self._app_logger.info("WeCom bot websocket authenticated"))
        self._client.on(
            "reconnecting",
            lambda attempt: self._app_logger.warning(
                "WeCom bot websocket reconnecting", extra={"payload": {"attempt": attempt}}
            ),
        )
        self._client.on(
            "error",
            lambda error: log_error(
                self._error_logger,
                "wecom_long_conn",
                "WeCom bot websocket error",
                error=str(error),
            ),
        )
        self._client.on("message", self._on_message)
        self._client.on("event", self._on_event)

    @property
    def client(self) -> WSClient:
        return self._client

    async def _on_message(self, frame: dict[str, Any]) -> None:
        await self._handler(parse_frame_to_inbound(frame))

    async def _on_event(self, frame: dict[str, Any]) -> None:
        if self._event_handler:
            await self._event_handler(frame)

    async def run_forever(self) -> None:
        await self._client.connect()
        await asyncio.Event().wait()
