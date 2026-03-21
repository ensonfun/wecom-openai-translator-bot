from pathlib import Path

from wecom_translator.logging_setup import _build_daily_handler


def test_daily_handler_uses_expected_file_name_pattern(tmp_path: Path) -> None:
    handler = _build_daily_handler(tmp_path, "app", retention_days=3)
    target = handler._target_path("20260322")
    assert target == tmp_path / "app-20260322.log"
