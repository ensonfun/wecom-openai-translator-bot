from __future__ import annotations

import re

from wecom_translator.models import CommandType, InboundMessage, ParsedCommand
from wecom_translator.prompts import PROMPT, PROMPT_SLACK, PROMPT_T


MENTION_PREFIX_RE = re.compile(r"^\s*@\S+\s*")


def _strip_group_prefix(text: str) -> str:
    cleaned = text.strip()
    cleaned = cleaned.replace("\u2005", " ")
    while cleaned.startswith("@"):
        updated = MENTION_PREFIX_RE.sub("", cleaned, count=1).strip()
        if updated == cleaned:
            break
        cleaned = updated
    return cleaned


def parse_command(message: InboundMessage) -> ParsedCommand:
    cleaned = message.content.strip()
    if message.chat_type.value == "group":
        cleaned = _strip_group_prefix(cleaned)

    if not cleaned:
        return ParsedCommand(CommandType.EMPTY, "", None, cleaned)

    if cleaned == "*#clear":
        return ParsedCommand(CommandType.CLEAR, "", None, cleaned)

    if len(cleaned) > 2 and cleaned[1] == " ":
        prefix = cleaned[0]
        text = cleaned[2:].strip()
        if prefix in {"t", "T"}:
            return ParsedCommand(CommandType.CORRECT, text, PROMPT.strip(), cleaned)
        if prefix in {"s", "S"}:
            return ParsedCommand(CommandType.SLACK, text, PROMPT_SLACK.strip(), cleaned)

    return ParsedCommand(CommandType.TRANSLATE, cleaned, PROMPT_T, cleaned)
