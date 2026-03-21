from wecom_translator.models import ChatType, InboundMessage
from wecom_translator.router.command_router import parse_command


def build_message(content: str, chat_type: ChatType = ChatType.DIRECT) -> InboundMessage:
    return InboundMessage(
        message_id="1",
        chat_type=chat_type,
        from_user="alice",
        conversation_id="alice",
        mentioned=chat_type == ChatType.DIRECT,
        content=content,
        create_time=1,
        raw_payload={},
        req_id="req-1",
        msg_type="text",
        raw_frame={"headers": {"req_id": "req-1"}, "body": {}},
    )


def test_parse_default_translate_command() -> None:
    command = parse_command(build_message("hello"))
    assert command.command_type.value == "translate"
    assert command.user_text == "hello"


def test_parse_t_prefix_command() -> None:
    command = parse_command(build_message("T hello"))
    assert command.command_type.value == "correct"
    assert command.user_text == "hello"


def test_parse_s_prefix_command() -> None:
    command = parse_command(build_message("s 这个需求我晚点跟进"))
    assert command.command_type.value == "slack"
    assert command.user_text == "这个需求我晚点跟进"


def test_parse_clear_command() -> None:
    command = parse_command(build_message("*#clear"))
    assert command.command_type.value == "clear"


def test_group_mention_prefix_is_removed() -> None:
    command = parse_command(build_message("@bot T hello", chat_type=ChatType.GROUP))
    assert command.command_type.value == "correct"
    assert command.user_text == "hello"


def test_empty_text_returns_empty_command() -> None:
    command = parse_command(build_message("   "))
    assert command.command_type.value == "empty"
