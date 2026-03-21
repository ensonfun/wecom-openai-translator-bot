from wecom_translator.models import ChatType, InboundMessage
from wecom_translator.state.session_store import SessionStore


def build_message(message_id: str, content: str = "hello") -> InboundMessage:
    return InboundMessage(
        message_id=message_id,
        chat_type=ChatType.DIRECT,
        from_user="alice",
        conversation_id="alice",
        mentioned=True,
        content=content,
        create_time=1,
        raw_payload={},
        req_id="req-1",
        msg_type="text",
        raw_frame={"headers": {"req_id": "req-1"}, "body": {}},
    )


def test_mark_processed_uses_message_id_for_dedupe() -> None:
    store = SessionStore()
    assert store.mark_processed(build_message("abc")) is True
    assert store.mark_processed(build_message("abc")) is False


def test_mark_processed_uses_fallback_key_when_message_id_missing() -> None:
    store = SessionStore()
    first = build_message("", "hello")
    second = build_message("", "hello")
    assert store.mark_processed(first) is True
    assert store.mark_processed(second) is False
