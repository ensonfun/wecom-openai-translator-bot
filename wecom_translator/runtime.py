from __future__ import annotations

import asyncio
import logging

from wecom_translator.config import Settings, load_dotenv
from wecom_translator.logging_setup import configure_logging, log_error, log_input, log_output
from wecom_translator.models import ChatType, CommandType, InboundMessage, ParsedCommand
from wecom_translator.router.command_router import parse_command
from wecom_translator.services.translator import TranslatorService
from wecom_translator.services.wecom_sender import WeComSender
from wecom_translator.state.session_store import SessionStore
from wecom_translator.transport.wecom_long_conn import WeComLongConnectionTransport


FAILURE_MESSAGE = "当前无法处理您的请求，请稍后再试。"
CLEAR_SUCCESS_MESSAGE = "Context cleared succeeded!"
UNSUPPORTED_MESSAGE = "当前仅支持文本消息。"


class TranslatorRuntime:
    def __init__(
        self,
        settings: Settings,
        app_logger: logging.Logger,
        error_logger: logging.Logger,
        translator: TranslatorService,
        sender: WeComSender,
        session_store: SessionStore | None = None,
    ) -> None:
        self._settings = settings
        self._app_logger = app_logger
        self._error_logger = error_logger
        self._translator = translator
        self._sender = sender
        self._session_store = session_store or SessionStore()
        self._queue: asyncio.Queue[tuple[InboundMessage, ParsedCommand]] = asyncio.Queue()
        self._workers: list[asyncio.Task[None]] = []

    def start_workers(self) -> None:
        if self._workers:
            return
        for index in range(self._settings.worker_count):
            self._workers.append(asyncio.create_task(self._worker_loop(), name=f"translator-worker-{index}"))

    async def handle_inbound(self, inbound: InboundMessage) -> None:
        if inbound.msg_type != "text":
            await self._sender.send_text(inbound, UNSUPPORTED_MESSAGE)
            return

        if not inbound.from_user or not inbound.content.strip():
            return

        if inbound.chat_type == ChatType.GROUP and not inbound.mentioned:
            return

        if not self._session_store.mark_processed(inbound):
            return

        command = parse_command(inbound)
        log_input(
            self._app_logger,
            {
                "message_id": inbound.message_id,
                "chat_type": inbound.chat_type.value,
                "from_user": inbound.from_user,
                "conversation_id": inbound.conversation_id,
                "command_type": command.command_type.value,
                "raw_text": inbound.content,
            },
        )

        if command.command_type == CommandType.EMPTY:
            return

        if command.command_type == CommandType.CLEAR:
            self._session_store.clear(inbound.conversation_id)
            delivered = await self._sender.send_text(inbound, CLEAR_SUCCESS_MESSAGE)
            log_output(
                self._app_logger,
                {
                    "message_id": inbound.message_id,
                    "model": self._translator.model,
                    "command_type": command.command_type.value,
                    "output_text": CLEAR_SUCCESS_MESSAGE,
                    "send_success": delivered,
                },
            )
            return

        self._session_store.remember(inbound.conversation_id, "last_user_text", command.user_text)
        await self._queue.put((inbound, command))

    async def process_job(self, inbound: InboundMessage, command: ParsedCommand) -> None:
        try:
            output = await asyncio.to_thread(self._translator.translate, inbound, command)
            delivered = await self._sender.send_text(inbound, output)
            log_output(
                self._app_logger,
                {
                    "message_id": inbound.message_id,
                    "model": self._translator.model,
                    "command_type": command.command_type.value,
                    "output_text": output,
                    "send_success": delivered,
                },
            )
        except Exception as exc:
            log_error(
                self._error_logger,
                "runtime_worker",
                "Failed to process inbound message",
                message_id=inbound.message_id,
                error=str(exc),
            )
            fallback_delivered = await self._sender.send_text(inbound, FAILURE_MESSAGE)
            log_output(
                self._app_logger,
                {
                    "message_id": inbound.message_id,
                    "model": self._translator.model,
                    "command_type": command.command_type.value,
                    "output_text": FAILURE_MESSAGE,
                    "send_success": fallback_delivered,
                },
            )

    async def _worker_loop(self) -> None:
        while True:
            inbound, command = await self._queue.get()
            try:
                await self.process_job(inbound, command)
            finally:
                self._queue.task_done()


async def async_main() -> None:
    load_dotenv()
    settings = Settings()
    settings.validate()
    app_logger, error_logger = configure_logging(settings.log_dir, settings.log_level, settings.log_retention_days)
    runtime_box: dict[str, TranslatorRuntime] = {}

    async def _dispatch(inbound: InboundMessage) -> None:
        await runtime_box["runtime"].handle_inbound(inbound)

    transport = WeComLongConnectionTransport(settings, app_logger, error_logger, handler=_dispatch)
    sender = WeComSender(app_logger, error_logger, transport.client)
    translator = TranslatorService(settings, app_logger, error_logger)
    runtime = TranslatorRuntime(settings, app_logger, error_logger, translator, sender)
    runtime_box["runtime"] = runtime
    runtime.start_workers()
    await transport.run_forever()


def main() -> None:
    asyncio.run(async_main())
