#!/usr/bin/env bash
# Shared helpers for the openspec-boss scripts (bin/boss, bin/boss-waiter).
# Sourced, never executed directly. Comments and messages are in English.

set -u

# --- Paths (overridable via environment) ---
BOSS_CONFIG="${BOSS_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/openspec-boss/boss.toml}"
BOSS_STATE_DIR="${BOSS_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/openspec-boss}"
BOSS_APPLIES_DIR="$BOSS_STATE_DIR/applies"
BOSS_LOGS_DIR="$BOSS_STATE_DIR/logs"

# --- Tunables ---
BOSS_AGENT_NAME="${BOSS_AGENT_NAME:-boss}"
BOSS_WAITER_MAX_S="${BOSS_WAITER_MAX_S:-7200}"
BOSS_AGENT_START_TIMEOUT_MS="${BOSS_AGENT_START_TIMEOUT_MS:-120000}"
BOSS_AGENT_BUSY_RETRY_MS="${BOSS_AGENT_BUSY_RETRY_MS:-30000}"

# When set (by bin/boss-waiter), log() appends to this file instead of stderr.
BOSS_LOG_FILE="${BOSS_LOG_FILE:-}"

now_iso() {
  date '+%Y-%m-%dT%H:%M:%S%z'
}

log() {
  local line
  line="$(now_iso) $*"
  if [ -n "$BOSS_LOG_FILE" ]; then
    printf '%s\n' "$line" >>"$BOSS_LOG_FILE"
  else
    printf '%s\n' "$line" >&2
  fi
}

# die_json <code> <message> -- error JSON on stderr, exit 1
die_json() {
  local code="$1" msg="$2"
  printf '{"error":"%s","message":"%s"}\n' "$code" "$msg" >&2
  exit 1
}

# usage_error <message> -- usage JSON on stderr, exit 2 (same convention as herdr)
usage_error() {
  local msg="$1"
  printf '{"error":"usage","message":"%s"}\n' "$msg" >&2
  exit 2
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die_json "missing_dependency" "required command '$1' not found in PATH"
}

# herdr_json <args...> -- run herdr, print the .result payload as compact JSON.
# Dies with a JSON error on stderr (exit 1) when herdr fails or .result is null.
herdr_json() {
  local out rc
  out="$(herdr "$@" 2>&1)"
  rc=$?
  if [ "$rc" -ne 0 ] || ! printf '%s' "$out" | jq -e '.result != null' >/dev/null 2>&1; then
    local code msg
    code="$(printf '%s' "$out" | jq -r '.error.code // "herdr_error"' 2>/dev/null || printf 'herdr_error')"
    msg="$(printf '%s' "$out" | jq -r '.error.message // empty' 2>/dev/null || true)"
    die_json "$code" "herdr ${*:-}: ${msg:-call failed with exit $rc}"
  fi
  printf '%s' "$out" | jq -c '.result'
}

# normalize_name <s> -- lower-case, keep only [a-z0-9_-] (herdr-safe names)
normalize_name() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9_-]/-/g' -e 's/-\{2,\}/-/g' -e 's/^-//' -e 's/-$//'
}

# apply_agent_name <change> -- "apply-<change>", normalized for herdr
apply_agent_name() {
  printf 'apply-%s\n' "$(normalize_name "$1")"
}

# state_file_for <project-path> <change> -- path of the state file for an apply
state_file_for() {
  local project="$1" change="$2" hash
  hash="$(printf '%s' "$project" | sha1sum | cut -d' ' -f1)"
  printf '%s/%s-%s.json\n' "$BOSS_APPLIES_DIR" "$hash" "$(normalize_name "$change")"
}

# expand_home <path> -- expand a leading ~
expand_home() {
  case "$1" in
    "~") printf '%s' "$HOME" ;;
    "~/"*) printf '%s%s' "$HOME" "${1#\~/}" ;;
    *) printf '%s' "$1" ;;
  esac
}

# canonical_path <path> -- absolute, resolved path (no symlink components)
canonical_path() {
  local p
  p="$(expand_home "$1")"
  (cd "$p" 2>/dev/null && pwd) || printf '%s' "$(readlink -f "$p")"
}

# herdr_raw <method> <params-json> -- call the Herdr socket API directly.
# Used where the herdr CLI cannot express a call (e.g. pane.report_metadata).
# Prints the .result payload as compact JSON, dies on error.
herdr_raw() {
  local method="$1" params sock out rc code msg
  method="${1:-}"
  params="${2:-}"
  [ -n "$params" ] || params='{}'
  sock="${HERDR_SOCKET_PATH:-}"
  [ -n "$sock" ] || die_json "herdr_socket" "HERDR_SOCKET_PATH is not set; cannot reach the Herdr socket"
  out="$(python3 - "$sock" "$method" "$params" 2>&1 <<'PY'
import json, socket, sys
sock_path, method, params = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    params = json.loads(params)
except ValueError:
    params = {}
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
try:
    s.connect(sock_path)
    s.sendall(json.dumps({"id": "boss", "method": method, "params": params}).encode() + b"\n")
    f = s.makefile("r")
    sys.stdout.write(f.readline())
finally:
    s.close()
PY
)"
  rc=$?
  if [ "$rc" -ne 0 ] || ! printf '%s' "$out" | jq -e '.result != null' >/dev/null 2>&1; then
    code="$(printf '%s' "$out" | jq -r '.error.code // "herdr_error"' 2>/dev/null || printf 'herdr_error')"
    msg="$(printf '%s' "$out" | jq -r '.error.message // empty' 2>/dev/null || true)"
    die_json "$code" "herdr ${method}: ${msg:-socket call failed (exit $rc)}"
  fi
  printf '%s' "$out" | jq -c '.result'
}

# kill_waiter <pid> -- stop a running waiter, if the pid really is a boss-waiter
kill_waiter() {
  local pid="$1"
  [ -n "$pid" ] && [ "$pid" != "null" ] || return 0
  if ps -p "$pid" -o comm= 2>/dev/null | grep -q 'boss-waiter'; then
    kill "$pid" 2>/dev/null || true
    return 0
  fi
  return 1
}
