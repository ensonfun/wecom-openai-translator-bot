#!/usr/bin/env bash

if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi

if shopt -oq posix; then
  exec bash "$0" "$@"
fi

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_FILE="$ROOT_DIR/app.py"
VENV_DIR="$ROOT_DIR/.venv"
REQUIREMENTS_FILE="$ROOT_DIR/requirements.txt"
LOG_DIR="$ROOT_DIR/logs"
PID_FILE="$ROOT_DIR/.wecom_translator.pid"
STARTUP_LOG="$LOG_DIR/startup.log"
REQUIREMENTS_STAMP="$VENV_DIR/.requirements.sha256"

mkdir -p "$LOG_DIR"

if command -v python3 >/dev/null 2>&1; then
  SYSTEM_PYTHON="$(command -v python3)"
elif command -v python >/dev/null 2>&1; then
  SYSTEM_PYTHON="$(command -v python)"
else
  echo "python3 not found"
  exit 1
fi

requirements_hash() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$REQUIREMENTS_FILE" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$REQUIREMENTS_FILE" | awk '{print $1}'
  else
    "$SYSTEM_PYTHON" -c 'from pathlib import Path; import hashlib; print(hashlib.sha256(Path("'"$REQUIREMENTS_FILE"'").read_bytes()).hexdigest())'
  fi
}

ensure_venv() {
  if [[ ! -x "$VENV_DIR/bin/python" ]]; then
    echo "Creating virtual environment in $VENV_DIR"
    "$SYSTEM_PYTHON" -m venv "$VENV_DIR"
  fi
  PYTHON_BIN="$VENV_DIR/bin/python"
  PIP_BIN="$VENV_DIR/bin/pip"
}

ensure_dependencies() {
  local current_hash=""
  local installed_hash=""

  current_hash="$(requirements_hash)"
  if [[ -f "$REQUIREMENTS_STAMP" ]]; then
    installed_hash="$(cat "$REQUIREMENTS_STAMP" 2>/dev/null || true)"
  fi

  if [[ "$current_hash" != "$installed_hash" ]] || ! "$PYTHON_BIN" -c "import openai, websockets" >/dev/null 2>&1; then
    echo "Installing dependencies from $REQUIREMENTS_FILE"
    "$PIP_BIN" install --upgrade pip >/dev/null
    "$PIP_BIN" install -r "$REQUIREMENTS_FILE"
    printf '%s\n' "$current_hash" > "$REQUIREMENTS_STAMP"
  fi
}

preflight_check() {
  echo "Running configuration preflight"
  "$PYTHON_BIN" -c "from wecom_translator.config import Settings, load_dotenv; load_dotenv(); Settings().validate()"
}

runtime_import_check() {
  echo "Running runtime import check"
  "$PYTHON_BIN" -c "from wecom_translator.runtime import main"
}

stop_pid() {
  local pid="$1"
  if kill -0 "$pid" >/dev/null 2>&1; then
    kill "$pid" >/dev/null 2>&1 || true
    for _ in {1..10}; do
      if ! kill -0 "$pid" >/dev/null 2>&1; then
        return 0
      fi
      sleep 1
    done
    kill -9 "$pid" >/dev/null 2>&1 || true
  fi
}

ensure_venv
ensure_dependencies
preflight_check
runtime_import_check

if [[ -f "$PID_FILE" ]]; then
  OLD_PID="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [[ -n "${OLD_PID:-}" ]]; then
    echo "Stopping previous process from pid file: $OLD_PID"
    stop_pid "$OLD_PID"
  fi
  rm -f "$PID_FILE"
fi

MATCHED_PIDS="$(pgrep -f "$APP_FILE" || true)"
if [[ -n "$MATCHED_PIDS" ]]; then
  echo "Stopping existing app.py process(es):"
  while IFS= read -r pid; do
    [[ -z "$pid" ]] && continue
    echo "  - $pid"
    stop_pid "$pid"
  done <<< "$MATCHED_PIDS"
fi

START_LINE=0
if [[ -f "$STARTUP_LOG" ]]; then
  START_LINE="$(wc -l < "$STARTUP_LOG" | tr -d ' ')"
fi

printf '\n[%s] launching service\n' "$(date '+%Y-%m-%d %H:%M:%S')" >> "$STARTUP_LOG"
echo "Starting service with $PYTHON_BIN"
nohup "$PYTHON_BIN" "$APP_FILE" >> "$STARTUP_LOG" 2>&1 &
NEW_PID=$!
echo "$NEW_PID" > "$PID_FILE"

for _ in {1..5}; do
  sleep 1
  if ! kill -0 "$NEW_PID" >/dev/null 2>&1; then
    echo "Service failed to start. Recent log output:"
    tail -n +"$((START_LINE + 1))" "$STARTUP_LOG" || true
    rm -f "$PID_FILE"
    exit 1
  fi
done

echo "Service started successfully. PID: $NEW_PID"
echo "Startup log: $STARTUP_LOG"
