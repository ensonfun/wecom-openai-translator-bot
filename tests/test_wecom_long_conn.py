from wecom_translator.models import ChatType
from wecom_translator.transport.wecom_long_conn import parse_frame_to_inbound


def test_parse_direct_text_frame() -> None:
    inbound = parse_frame_to_inbound(
        {
            "cmd": "aibot_msg_callback",
            "headers": {"req_id": "req-1"},
            "body": {
                "msgid": "msg-1",
                "aibotid": "bot-1",
                "chatid": "alice",
                "chattype": "single",
                "from": {"userid": "alice"},
                "msgtype": "text",
                "msgtime": 123,
                "text": {"content": "hello"},
            },
        }
    )

    assert inbound.chat_type == ChatType.DIRECT
    assert inbound.content == "hello"
    assert inbound.conversation_id == "alice"
    assert inbound.mentioned is True


def test_parse_group_text_frame_marks_mentions() -> None:
    inbound = parse_frame_to_inbound(
        {
            "cmd": "aibot_msg_callback",
            "headers": {"req_id": "req-2"},
            "body": {
                "msgid": "msg-2",
                "aibotid": "bot-1",
                "chatid": "group-1",
                "chattype": "group",
                "from": {"userid": "alice"},
                "msgtype": "text",
                "msgtime": 123,
                "text": {"content": "@bot hello"},
            },
        }
    )

    assert inbound.chat_type == ChatType.GROUP
    assert inbound.chat_id == "group-1"
    assert inbound.mentioned is True
