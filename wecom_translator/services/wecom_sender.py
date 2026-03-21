from __future__ import annotations

import logging
from typing import Any

from wecom_translator.logging_setup import log_error
from wecom_translator.models import InboundMessage


class WeComSender:
    def __init__(self, app_logger: logging.Logger, error_logger: logging.Logger, client: Any) -> None:
        self._app_logger = app_logger
        self._error_logger = error_logger
        self._client = client

    async def send_text(self, inbound: InboundMessage, content: str) -> bool:
        body = {
            "msgtype": "markdown",
            "markdown": {"content": content},
        }
        try:
            if inbound.raw_frame and inbound.req_id:
                await self._client.reply(inbound.raw_frame, body)
            else:
                target = inbound.chat_id or inbound.from_user
                await self._client.send_message(target, body)
            return True
        except Exception as exc:
            log_error(
                self._error_logger,
                "wecom_send",
                "WeCom send exception",
                message_id=inbound.message_id,
                error=str(exc),
            )
            return False
