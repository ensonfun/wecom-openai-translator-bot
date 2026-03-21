from __future__ import annotations

import hashlib
import threading
import time

from wecom_translator.models import InboundMessage


class SessionStore:
    def __init__(self, ttl_seconds: int = 3600) -> None:
        self._ttl_seconds = ttl_seconds
        self._lock = threading.Lock()
        self._conversation_state: dict[str, dict[str, str]] = {}
        self._dedupe_seen: dict[str, float] = {}

    def _prune(self) -> None:
        cutoff = time.time()
        expired = [key for key, expiry in self._dedupe_seen.items() if expiry <= cutoff]
        for key in expired:
            self._dedupe_seen.pop(key, None)

    def build_dedupe_key(self, inbound: InboundMessage) -> str:
        if inbound.message_id:
            return inbound.message_id
        content_hash = hashlib.sha1(inbound.content.encode("utf-8")).hexdigest()
        return f"{inbound.from_user}:{inbound.create_time}:{content_hash}"

    def mark_processed(self, inbound: InboundMessage) -> bool:
        with self._lock:
            self._prune()
            key = self.build_dedupe_key(inbound)
            if key in self._dedupe_seen:
                return False
            self._dedupe_seen[key] = time.time() + self._ttl_seconds
            return True

    def clear(self, conversation_id: str) -> None:
        with self._lock:
            self._conversation_state.pop(conversation_id, None)

    def remember(self, conversation_id: str, key: str, value: str) -> None:
        with self._lock:
            self._conversation_state.setdefault(conversation_id, {})[key] = value
