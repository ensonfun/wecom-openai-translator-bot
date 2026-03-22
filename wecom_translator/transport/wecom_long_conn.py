from __future__ import annotations

import asyncio
import json
import logging
import os
import ssl
import time
from typing import Any, Awaitable, Callable

import websockets

from wecom_translator.config import Settings
from wecom_translator.logging_setup import log_error
from wecom_translator.models import ChatType, InboundMessage


DEFAULT_WS_URL = "wss://openws.work.weixin.qq.com"
CMD_SUBSCRIBE = "aibot_subscribe"
CMD_HEARTBEAT = "ping"
CMD_REPLY = "aibot_respond_msg"
CMD_SEND_MESSAGE = "aibot_send_msg"
CMD_MESSAGE_CALLBACK = "aibot_msg_callback"
CMD_EVENT_CALLBACK = "aibot_event_callback"
ACK_TIMEOUT_SECONDS = 5.0

MessageHandler = Callable[[InboundMessage], Awaitable[None]]
EventHandler = Callable[[dict[str, Any]], Awaitable[None]]


def _build_ssl_context() -> ssl.SSLContext:
    try:
        import certifi

        return ssl.create_default_context(cafile=certifi.where())
    except ImportError:
        return ssl.create_default_context()


def _generate_req_id(prefix: str) -> str:
    return f"{prefix}_{int(time.time() * 1000)}_{os.urandom(4).hex()}"


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


class WeComWSClient:
    def __init__(
        self,
        settings: Settings,
        app_logger: logging.Logger,
        error_logger: logging.Logger,
        message_handler: MessageHandler,
        event_handler: EventHandler | None = None,
    ) -> None:
        self._settings = settings
        self._app_logger = app_logger
        self._error_logger = error_logger
        self._message_handler = message_handler
        self._event_handler = event_handler
        self._ws: Any = None
        self._receive_task: asyncio.Task[None] | None = None
        self._heartbeat_task: asyncio.Task[None] | None = None
        self._pending_acks: dict[str, asyncio.Future[dict[str, Any]]] = {}
        self._send_lock = asyncio.Lock()
        self._closed = False

    @property
    def is_connected(self) -> bool:
        return self._ws is not None

    async def connect(self) -> None:
        ws_url = self._settings.wecom_ws_url or DEFAULT_WS_URL
        self._ws = await websockets.connect(
            ws_url,
            ssl=_build_ssl_context(),
            ping_interval=None,
            ping_timeout=None,
            close_timeout=5,
        )
        self._app_logger.info("WeCom bot websocket connected")

        self._receive_task = asyncio.create_task(self._receive_loop(), name="wecom-receive-loop")
        await self._authenticate()
        self._heartbeat_task = asyncio.create_task(self._heartbeat_loop(), name="wecom-heartbeat-loop")
        self._app_logger.info("WeCom bot websocket authenticated")

    async def close(self) -> None:
        self._closed = True
        if self._heartbeat_task is not None:
            self._heartbeat_task.cancel()
        if self._receive_task is not None:
            self._receive_task.cancel()

        for future in self._pending_acks.values():
            if not future.done():
                future.set_exception(RuntimeError("WebSocket client closed"))
        self._pending_acks.clear()

        if self._ws is not None:
            try:
                await self._ws.close()
            except Exception:
                pass
            self._ws = None

    async def reply(self, frame: dict[str, Any], body: dict[str, Any]) -> dict[str, Any]:
        headers = frame.get("headers", {})
        req_id = headers.get("req_id", "")
        if not req_id:
            raise RuntimeError("Missing req_id in inbound frame")
        return await self._send_with_ack(CMD_REPLY, req_id, body)

    async def send_message(self, chatid: str, body: dict[str, Any]) -> dict[str, Any]:
        req_id = _generate_req_id(CMD_SEND_MESSAGE)
        payload = {"chatid": chatid, **body}
        return await self._send_with_ack(CMD_SEND_MESSAGE, req_id, payload)

    async def _authenticate(self) -> None:
        req_id = _generate_req_id(CMD_SUBSCRIBE)
        await self._send_with_ack(
            CMD_SUBSCRIBE,
            req_id,
            {
                "bot_id": self._settings.wecom_bot_id,
                "secret": self._settings.wecom_bot_secret,
            },
        )

    async def _heartbeat_loop(self) -> None:
        try:
            while True:
                await asyncio.sleep(self._settings.heartbeat_interval_ms / 1000)
                req_id = _generate_req_id(CMD_HEARTBEAT)
                try:
                    await self._send_with_ack(CMD_HEARTBEAT, req_id, None)
                except Exception as exc:
                    raise RuntimeError(f"Heartbeat failed: {exc}") from exc
        except asyncio.CancelledError:
            return

    async def _receive_loop(self) -> None:
        try:
            async for raw_message in self._ws:
                if isinstance(raw_message, bytes):
                    raw_message = raw_message.decode("utf-8")
                frame = json.loads(raw_message)
                await self._handle_frame(frame)
        except asyncio.CancelledError:
            return
        except Exception as exc:
            log_error(
                self._error_logger,
                "wecom_long_conn_receive",
                "WeCom bot websocket receive loop failed",
                error=str(exc),
            )
            raise
        finally:
            self._fail_pending_acks(RuntimeError("WebSocket connection closed"))
            self._ws = None

    async def _handle_frame(self, frame: dict[str, Any]) -> None:
        headers = frame.get("headers", {})
        req_id = headers.get("req_id", "")
        cmd = frame.get("cmd", "")

        if req_id in self._pending_acks and cmd not in {CMD_MESSAGE_CALLBACK, CMD_EVENT_CALLBACK}:
            future = self._pending_acks.pop(req_id)
            if not future.done():
                future.set_result(frame)
            return

        if cmd == CMD_MESSAGE_CALLBACK:
            await self._message_handler(parse_frame_to_inbound(frame))
            return

        if cmd == CMD_EVENT_CALLBACK:
            if self._event_handler is not None:
                await self._event_handler(frame)
            return

        self._app_logger.warning("Received unhandled WeCom frame", extra={"payload": {"frame": frame}})

    async def _send_with_ack(self, cmd: str, req_id: str, body: Any) -> dict[str, Any]:
        if self._ws is None:
            raise RuntimeError("WebSocket is not connected")

        loop = asyncio.get_running_loop()
        ack_future: asyncio.Future[dict[str, Any]] = loop.create_future()
        self._pending_acks[req_id] = ack_future

        frame: dict[str, Any] = {
            "cmd": cmd,
            "headers": {"req_id": req_id},
        }
        if body is not None:
            frame["body"] = body

        try:
            async with self._send_lock:
                await self._ws.send(json.dumps(frame, ensure_ascii=False))
            ack = await asyncio.wait_for(ack_future, timeout=ACK_TIMEOUT_SECONDS)
        except Exception:
            self._pending_acks.pop(req_id, None)
            raise

        if ack.get("errcode", 0) != 0:
            raise RuntimeError(f"WeCom ack error: {ack.get('errmsg', 'unknown error')}")
        return ack

    def _fail_pending_acks(self, exc: Exception) -> None:
        for future in self._pending_acks.values():
            if not future.done():
                future.set_exception(exc)
        self._pending_acks.clear()


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
        self._client = WeComWSClient(settings, app_logger, error_logger, handler, event_handler)

    @property
    def client(self) -> WeComWSClient:
        return self._client

    async def run_forever(self) -> None:
        attempts = 0

        while True:
            try:
                await self._client.connect()
                attempts = 0
                assert self._client._receive_task is not None
                await self._client._receive_task
            except asyncio.CancelledError:
                await self._client.close()
                raise
            except Exception as exc:
                attempts += 1
                log_error(
                    self._error_logger,
                    "wecom_long_conn",
                    "WeCom bot websocket connection failed",
                    error=str(exc),
                    attempt=attempts,
                )
                if self._settings.max_reconnect_attempts != -1 and attempts >= self._settings.max_reconnect_attempts:
                    raise

                delay_ms = min(
                    self._settings.reconnect_interval_ms * (2 ** max(attempts - 1, 0)),
                    30000,
                )
                self._app_logger.warning(
                    "WeCom bot websocket reconnecting",
                    extra={"payload": {"attempt": attempts, "delay_ms": delay_ms}},
                )
                await self._client.close()
                await asyncio.sleep(delay_ms / 1000)
