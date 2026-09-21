#!/usr/bin/env bash
# Shared helpers for the openspec-boss scripts (bin/boss, bin/boss-waiter).
# Sourced, never executed directly. Comments and messages are in English.

set -u

# --- Paths (overridable via environment) ---
BOSS_CONFIG="${BOSS_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/openspec-boss/boss.toml}"
BOSS_STATE_DIR="${BOSS_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/openspec-boss}"
BOSS_APPLIES_DIR="$BOSS_STATE_DIR/applies"
BOSS_LOGS_DIR="$BOSS_STATE_DIR/logs"
BOSS_CYCLES_DIR="$BOSS_STATE_DIR/cycles"

# --- Tunables ---
BOSS_AGENT_NAME="${BOSS_AGENT_NAME:-boss}"
BOSS_WAITER_MAX_S="${BOSS_WAITER_MAX_S:-7200}"
BOSS_AGENT_START_TIMEOUT_MS="${BOSS_AGENT_START_TIMEOUT_MS:-120000}"
BOSS_AGENT_BUSY_RETRY_MS="${BOSS_AGENT_BUSY_RETRY_MS:-30000}"
BOSS_REVIEW_TEST_TIMEOUT_S="${BOSS_REVIEW_TEST_TIMEOUT_S:-300}"
BOSS_WAITER_STALL_MS="${BOSS_WAITER_STALL_MS:-2700000}"

# Appended to every apply prompt unless the runner overrides or disables it:
# the apply must end its turn, the boss is woken by the waiter and retriggers.
BOSS_APPLY_YIELD_DEFAULT="When done or paused, end your turn and stop. Do not wait or poll for a review - the boss is woken automatically and will retrigger you."

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

# die_json <code> <message> -- error JSON on stderr, exit 1.
# When BOSS_FAILED_TAB/BOSS_FAILED_PANE are set (dispatch after tab create),
# the tab is closed again and the pane's last visible lines are attached as
# pane_tail, unless BOSS_KEEP_FAILED_TAB=1.
die_json() {
  local code="$1" msg="$2" tail_json="null"
  if [ -n "${BOSS_FAILED_TAB:-}" ]; then
    local tail
    tail="$(herdr pane read "${BOSS_FAILED_PANE:-}" --source visible --lines 15 2>/dev/null \
      | grep -v '^[[:space:]]*$' | tail -n 15 || true)"
    tail_json="$(printf '%s' "$tail" | jq -Rs . 2>/dev/null || printf 'null')"
    if [ "${BOSS_KEEP_FAILED_TAB:-0}" != "1" ]; then
      herdr tab close "$BOSS_FAILED_TAB" >/dev/null 2>&1 || true
      log "closed tab $BOSS_FAILED_TAB after failed dispatch ($code)"
    fi
    BOSS_FAILED_TAB=""
  fi
  jq -nc --arg code "$code" --arg msg "$msg" --argjson tail "$tail_json" \
    '{error: $code, message: $msg} + (if $tail == null then {} else {pane_tail: $tail} end)' >&2
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

# apply_agent_name <change> -- herdr agent name for a change's apply.
# Herdr allows [a-z][a-z0-9_-]{0,31}; "apply-<change>" is used when it fits,
# otherwise "apply-" + the first 19 characters + "-" + 6 hex of sha1(change)
# so two long names with the same beginning still differ.
apply_agent_name() {
  local norm full head hash
  norm="$(normalize_name "$1")"
  full="apply-$norm"
  if [ "${#full}" -le 32 ]; then
    printf '%s\n' "$full"
    return 0
  fi
  head="$(printf '%s' "$norm" | cut -c1-19 | sed -e 's/[-_]*$//')"
  hash="$(printf '%s' "$norm" | sha1sum | cut -c1-6)"
  printf 'apply-%s-%s\n' "$head" "$hash"
}

# one_line <text> -- collapse newlines/tabs into single spaces, trim
one_line() {
  printf '%s' "$1" | tr '\n\r\t' '   ' | sed -e 's/  */ /g' -e 's/^ //' -e 's/ $//'
}

# compose_apply_prompt <apply-cmd> <note> <yield> -- the text sent to the
# apply agent: command, then the note (if any), then the yield instruction
# (if any). The yield ends the prompt on purpose.
compose_apply_prompt() {
  local out="$1"
  [ -n "$2" ] && out="$out $2"
  [ -n "$3" ] && out="$out $3"
  printf '%s' "$out"
}

# write_state_field <state-file> <key> <string-value> -- atomic update
write_state_field() {
  local f="$1" k="$2" v="$3" t
  t="$(mktemp)"
  if jq --arg k "$k" --arg v "$v" '.[$k] = $v' "$f" >"$t" 2>/dev/null; then
    mv "$t" "$f"
  else
    rm -f "$t"
    return 1
  fi
}

# state_file_for <project-path> <change> -- path of the state file for an apply
state_file_for() {
  local project="$1" change="$2" hash
  hash="$(printf '%s' "$project" | sha1sum | cut -d' ' -f1)"
  printf '%s/%s-%s.json\n' "$BOSS_APPLIES_DIR" "$hash" "$(normalize_name "$change")"
}

# events_file_for <project-path> <change> -- append-only event log for the
# applies of this change in this project (same keying as state_file_for).
events_file_for() {
  local project="$1" change="$2" hash
  hash="$(printf '%s' "$project" | sha1sum | cut -d' ' -f1)"
  printf '%s/%s-%s.events.jsonl\n' "$BOSS_CYCLES_DIR" "$hash" "$(normalize_name "$change")"
}

# append_event <file> <event> <json-object> -- append one JSONL event line.
# Adds the timestamp 't'; the object carries change/project and the
# event-specific fields. The append is a single O_APPEND write, so parallel
# writers (boss commands and the detached waiter) do not interleave.
append_event() {
  local file="$1" event="$2" extra="${3:-{\}}" line
  [ -n "$file" ] || return 1
  mkdir -p "$(dirname "$file")" || return 1
  line="$(jq -nc --arg t "$(now_iso)" --arg event "$event" --argjson extra "$extra" \
    '{t: $t, event: $event} + $extra')" || return 1
  printf '%s\n' "$line" >>"$file"
}

# event_count <file> <event> -- number of events of that name in the log.
event_count() {
  local file="$1" name="$2"
  [ -f "$file" ] || { printf '0\n'; return 0; }
  jq -Rc --arg e "$name" \
    'select(length > 0) | (fromjson? | select(type == "object")) | select(.event == $e)' \
    "$file" 2>/dev/null | wc -l | tr -d ' '
}

# expand_home <path> -- expand a leading ~
expand_home() {
  case "$1" in
    "~") printf '%s' "$HOME" ;;
    "~/"*) printf '%s/%s' "$HOME" "${1#\~/}" ;;
    *) printf '%s' "$1" ;;
  esac
}

# canonical_path <path> -- absolute, resolved path (no symlink components).
# A path that does not exist is returned expanded but unresolved, so error
# messages can still show it.
canonical_path() {
  local p
  p="$(expand_home "$1")"
  (cd "$p" 2>/dev/null && pwd) || readlink -f "$p" 2>/dev/null || printf '%s' "$p"
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

# waiter_alive <pid> -- 0 when pid is a running boss-waiter. The script runs
# under bash, so comm= is "bash"; the command line carries the script name.
waiter_alive() {
  local pid="$1"
  [ -n "$pid" ] && [ "$pid" != "null" ] || return 1
  ps -p "$pid" -o args= 2>/dev/null | grep -q 'boss-waiter'
}

# kill_waiter <pid> -- stop a running waiter, if the pid really is a boss-waiter
kill_waiter() {
  local pid="$1"
  [ -n "$pid" ] && [ "$pid" != "null" ] || return 0
  if waiter_alive "$pid"; then
    kill "$pid" 2>/dev/null || true
    return 0
  fi
  return 1
}
