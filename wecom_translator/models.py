from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum
from typing import Any


class ChatType(str, Enum):
    DIRECT = "direct"
    GROUP = "group"


class CommandType(str, Enum):
    TRANSLATE = "translate"
    CORRECT = "correct"
    SLACK = "slack"
    CLEAR = "clear"
    EMPTY = "empty"


@dataclass
class InboundMessage:
    message_id: str
    chat_type: ChatType
    from_user: str
    conversation_id: str
    mentioned: bool
    content: str
    create_time: int
    raw_payload: dict[str, Any]
    req_id: str = ""
    msg_type: str = "text"
    raw_frame: dict[str, Any] = field(default_factory=dict)
    agent_id: str | None = None
    chat_id: str | None = None


@dataclass
class ParsedCommand:
    command_type: CommandType
    user_text: str
    instructions: str | None
    cleaned_text: str
