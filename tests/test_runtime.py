import asyncio

from wecom_translator.config import Settings
from wecom_translator.models import CommandType, ParsedCommand
from wecom_translator.models import ChatType, InboundMessage
from wecom_translator.runtime import CLEAR_SUCCESS_MESSAGE, FAILURE_MESSAGE, TranslatorRuntime
from wecom_translator.state.session_store import SessionStore


class FakeTranslator:
    model = "gpt-5-mini"

    def __init__(self, response: str = "translated", should_raise: bool = False) -> None:
        self.response = response
        self.should_raise = should_raise

    def translate(self, inbound: InboundMessage, command) -> str:
        if self.should_raise:
            raise RuntimeError("boom")
        return self.response


class FakeSender:
    def __init__(self) -> None:
        self.messages: list[tuple[str, str]] = []

    async def send_text(self, inbound: InboundMessage, content: str) -> bool:
        self.messages.append((inbound.message_id, content))
        return True


class FakeLogger:
    def info(self, *args, **kwargs) -> None:
        return None

    def error(self, *args, **kwargs) -> None:
        return None


def build_settings() -> Settings:
    settings = Settings()
    settings.worker_count = 1
    return settings


def build_message(content: str, *, chat_type: ChatType = ChatType.DIRECT, mentioned: bool = True) -> InboundMessage:
    return InboundMessage(
        message_id=f"id-{content}",
        chat_type=chat_type,
        from_user="alice",
        conversation_id="chat-1",
        mentioned=mentioned,
        content=content,
        create_time=1,
        raw_payload={},
        req_id=f"req-{content}",
        msg_type="text",
        raw_frame={"headers": {"req_id": f"req-{content}"}, "body": {}},
        chat_id="chat-1" if chat_type == ChatType.GROUP else None,
    )


def test_clear_command_sends_confirmation() -> None:
    async def _run() -> list[tuple[str, str]]:
        sender = FakeSender()
        runtime = TranslatorRuntime(build_settings(), FakeLogger(), FakeLogger(), FakeTranslator(), sender, SessionStore())
        await runtime.handle_inbound(build_message("*#clear"))
        return sender.messages

    assert asyncio.run(_run()) == [("id-*#clear", CLEAR_SUCCESS_MESSAGE)]


def test_group_message_without_mention_is_ignored() -> None:
    async def _run() -> list[tuple[str, str]]:
        sender = FakeSender()
        runtime = TranslatorRuntime(build_settings(), FakeLogger(), FakeLogger(), FakeTranslator(), sender, SessionStore())
        await runtime.handle_inbound(build_message("hello", chat_type=ChatType.GROUP, mentioned=False))
        return sender.messages

    assert asyncio.run(_run()) == []


def test_worker_sends_failure_message_on_translator_error() -> None:
    async def _run() -> list[tuple[str, str]]:
        sender = FakeSender()
        runtime = TranslatorRuntime(
            build_settings(),
            FakeLogger(),
            FakeLogger(),
            FakeTranslator(should_raise=True),
            sender,
            SessionStore(),
        )
        inbound = build_message("hello")
        command = ParsedCommand(CommandType.TRANSLATE, "hello", "prompt", "hello")
        await runtime.process_job(inbound, command)
        return sender.messages

    assert asyncio.run(_run())[0][1] == FAILURE_MESSAGE
