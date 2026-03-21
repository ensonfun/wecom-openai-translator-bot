from __future__ import annotations

import logging

from openai import OpenAI

from wecom_translator.config import Settings
from wecom_translator.logging_setup import log_error
from wecom_translator.models import InboundMessage, ParsedCommand


class TranslatorService:
    def __init__(
        self,
        settings: Settings,
        app_logger: logging.Logger,
        error_logger: logging.Logger,
        client: OpenAI | None = None,
    ) -> None:
        self._settings = settings
        self._app_logger = app_logger
        self._error_logger = error_logger
        self._client = client

    @property
    def model(self) -> str:
        return self._settings.openai_model

    def _get_client(self) -> OpenAI:
        if self._client is None:
            if not self._settings.openai_api_key:
                raise RuntimeError("OPENAI_API_KEY is not configured")
            self._client = OpenAI(api_key=self._settings.openai_api_key)
        return self._client

    def translate(self, message: InboundMessage, command: ParsedCommand) -> str:
        try:
            response = self._get_client().responses.create(
                model=self._settings.openai_model,
                instructions=command.instructions,
                input=command.user_text,
            )
            output = (response.output_text or "").strip()
            return output or "（模型未返回文本输出）"
        except Exception as exc:
            log_error(
                self._error_logger,
                "openai",
                "OpenAI request failed",
                message_id=message.message_id,
                command_type=command.command_type.value,
                error=str(exc),
            )
            raise
