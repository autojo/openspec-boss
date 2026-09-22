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
BOSS_BOSSES_DIR="$BOSS_STATE_DIR/bosses"

# --- Tunables ---
BOSS_AGENT_NAME="${BOSS_AGENT_NAME:-boss}"
BOSS_WAITER_MAX_S="${BOSS_WAITER_MAX_S:-7200}"
BOSS_AGENT_START_TIMEOUT_MS="${BOSS_AGENT_START_TIMEOUT_MS:-120000}"
BOSS_AGENT_BUSY_RETRY_MS="${BOSS_AGENT_BUSY_RETRY_MS:-30000}"
BOSS_AGENT_TUI_TIMEOUT_MS="${BOSS_AGENT_TUI_TIMEOUT_MS:-60000}"
BOSS_AGENT_PROMPT_TIMEOUT_MS="${BOSS_AGENT_PROMPT_TIMEOUT_MS:-90000}"
BOSS_RUNNER_READY_TIMEOUT_MS="${BOSS_RUNNER_READY_TIMEOUT_MS:-90000}"
BOSS_REVIEW_TEST_TIMEOUT_S="${BOSS_REVIEW_TEST_TIMEOUT_S:-300}"
BOSS_WAITER_STALL_MS="${BOSS_WAITER_STALL_MS:-2700000}"

# Appended to every apply prompt unless the runner overrides or disables it:
# the apply must end its turn, the boss is woken by the waiter and retriggers.
BOSS_APPLY_YIELD_DEFAULT="When done or paused, end your turn and stop. Do not wait or poll for a review - the boss is woken automatically and will retrigger you."

# Env for an opencode runner without an explicit 'env' field: inline config
# with the highest standard precedence, so only tabs started by boss get it.
BOSS_OPENCODE_ENV_DEFAULT='OPENCODE_CONFIG_CONTENT={"permission":"allow"}'

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

# boss_registry_file_for <workspace-id> -- registry file for the workspace's boss
boss_registry_file_for() {
  printf '%s/%s.json\n' "$BOSS_BOSSES_DIR" "$(normalize_name "$1")"
}

# boss_name_for <workspace-id> -- default herdr agent name of a workspace boss.
# Herdr allows [a-z][a-z0-9_-]{0,31}; "boss-<workspace>" is used when it fits,
# otherwise "boss-" + the first 19 characters + "-" + 6 hex of sha1(workspace)
# so two long ids with the same beginning still differ.
boss_name_for() {
  local norm full head hash
  norm="$(normalize_name "$1")"
  full="boss-$norm"
  if [ "${#full}" -le 32 ]; then
    printf '%s\n' "$full"
    return 0
  fi
  head="$(printf '%s' "$norm" | cut -c1-19 | sed -e 's/[-_]*$//')"
  hash="$(printf '%s' "$norm" | sha1sum | cut -c1-6)"
  printf 'boss-%s-%s\n' "$head" "$hash"
}

# runner_env_of <runner-json> -- the runner's resolved env entries, one per
# line. A missing field yields the built-in opencode default for kind=opencode
# and nothing for other kinds; an empty array yields nothing; otherwise exactly
# the configured entries.
runner_env_of() {
  printf '%s' "$1" | jq -r --arg d "$BOSS_OPENCODE_ENV_DEFAULT" \
    'if has("env") then (.env[]? // empty)
     elif .kind == "opencode" then $d
     else empty end'
}

# boss_agents -- compact '.agents' array from 'herdr agent list', or '[]' when
# Herdr is unavailable. Tolerant on purpose: callers use it only for liveness.
boss_agents() {
  local out
  out="$(herdr agent list 2>/dev/null || true)"
  printf '%s' "$out" | jq -c '.result.agents // .agents // []' 2>/dev/null || printf '[]'
}

# boss_agent_alive_name <agents-json> <name> -- 0 when an agent has that name
boss_agent_alive_name() {
  printf '%s' "$1" | jq -e --arg n "$2" \
    'map(select(type == "object" and .name == $n)) | length > 0' >/dev/null 2>&1
}

# boss_agent_alive_pane <agents-json> <pane-id> -- 0 when an agent sits on that pane
boss_agent_alive_pane() {
  printf '%s' "$1" | jq -e --arg p "$2" \
    'map(select(type == "object" and .pane_id == $p)) | length > 0' >/dev/null 2>&1
}

# boss_write_registry <file> <workspace-id> <pane-id> <agent> -- write the entry
boss_write_registry() {
  local file="$1" workspace_id="$2" pane_id="$3" agent="$4"
  mkdir -p "$BOSS_BOSSES_DIR" || die_json "state_write" "cannot create boss registry dir $BOSS_BOSSES_DIR"
  jq -n --arg w "$workspace_id" --arg p "$pane_id" --arg a "$agent" --arg t "$(now_iso)" \
    '{workspace_id: $w, pane_id: $p, agent: $a, claimed_at: $t}' >"$file" \
    || die_json "state_write" "cannot write boss registry $file"
}

# boss_registered_pane_ids -- pane ids of every registered boss, one per line
boss_registered_pane_ids() {
  local f
  [ -d "$BOSS_BOSSES_DIR" ] || return 0
  for f in "$BOSS_BOSSES_DIR"/*.json; do
    [ -f "$f" ] || continue
    jq -r '.pane_id // empty' "$f" 2>/dev/null || true
  done
}

# boss_agent_name <workspace-id> -- registered agent of the workspace's boss, or empty
boss_agent_name() {
  local reg
  [ -n "${1:-}" ] || return 0
  reg="$(boss_registry_file_for "$1")"
  [ -f "$reg" ] || return 0
  jq -r '.agent // empty' "$reg" 2>/dev/null || true
}

# boss_workspace_boss_pane <workspace-id> -- pane id of the workspace's living
# boss, or empty (no entry, no pane, or the pane is gone).
boss_workspace_boss_pane() {
  local workspace_id="${1:-}" reg reg_pane
  [ -n "$workspace_id" ] || return 0
  reg="$(boss_registry_file_for "$workspace_id")"
  [ -f "$reg" ] || return 0
  reg_pane="$(jq -r '.pane_id // empty' "$reg" 2>/dev/null || true)"
  [ -n "$reg_pane" ] || return 0
  if boss_agent_alive_pane "$(boss_agents)" "$reg_pane"; then
    printf '%s' "$reg_pane"
  fi
}

# boss_claim_pane <workspace-id> <pane-id> [<name>] -- register an existing pane
# as the boss of its workspace, keeping one registry entry per workspace and
# following the same rules as 'boss claim'. Prints the claim JSON (status
# claimed/already_claimed). Dies with boss_exists when another living pane owns
# the workspace or the derived name. Used by 'boss claim' (caller pane) and
# 'boss session' (the newly created pane).
boss_claim_pane() {
  local workspace_id="${1:-}" pane_id="${2:-}" name="${3:-}"
  [ -n "$pane_id" ] || die_json "not_in_herdr" "cannot claim the boss role without a pane id"
  [ -n "$workspace_id" ] || die_json "not_in_herdr" "cannot claim the boss role without a workspace id"

  local reg
  reg="$(boss_registry_file_for "$workspace_id")"

  if [ -z "$name" ]; then
    name="$(boss_name_for "$workspace_id")"
  else
    name="$(normalize_name "$name")"
    [ -n "$name" ] || usage_error "--name must contain a usable name (letters, digits, - or _)"
  fi

  local agents reg_pane reg_agent
  agents="$(boss_agents)"
  if [ -f "$reg" ]; then
    reg_pane="$(jq -r '.pane_id // empty' "$reg" 2>/dev/null || true)"
    reg_agent="$(jq -r '.agent // empty' "$reg" 2>/dev/null || true)"
    if [ -n "$reg_pane" ]; then
      if [ "$reg_pane" = "$pane_id" ]; then
        if [ -n "$reg_agent" ] && [ "$name" != "$reg_agent" ]; then
          herdr_json agent rename "$pane_id" "$name" >/dev/null || exit 1
          boss_write_registry "$reg" "$workspace_id" "$pane_id" "$name"
          reg_agent="$name"
        fi
        printf '%s\n' "$(jq -n --arg w "$workspace_id" --arg p "$pane_id" --arg a "$reg_agent" \
          '{workspace_id: $w, pane_id: $p, agent: $a, status: "already_claimed"}')"
        return 0
      fi
      if boss_agent_alive_pane "$agents" "$reg_pane"; then
        die_json "boss_exists" "workspace $workspace_id already has a boss on pane $reg_pane (agent ${reg_agent:-unknown})"
      fi
    fi
  fi

  local owner
  owner="$(printf '%s' "$agents" | jq -r --arg n "$name" \
    'map(select(type == "object" and .name == $n)) | .[0].pane_id // empty')"
  if [ -n "$owner" ] && [ "$owner" != "$pane_id" ]; then
    die_json "boss_exists" "agent '$name' already belongs to pane $owner; choose another name with --name"
  fi

  herdr_json agent rename "$pane_id" "$name" >/dev/null || exit 1
  boss_write_registry "$reg" "$workspace_id" "$pane_id" "$name"
  log "claimed boss of workspace $workspace_id as agent '$name' (pane $pane_id)"
  printf '%s\n' "$(jq -n --arg w "$workspace_id" --arg p "$pane_id" --arg a "$name" \
    '{workspace_id: $w, pane_id: $p, agent: $a, status: "claimed"}')"
}

# boss_resolve_agent <state-file> -- agent name of the boss responsible for an
# apply, in this order: (1) the boss registered for the apply's workspace,
# (2) the dispatcher boss recorded in the state, (3) the global BOSS_AGENT_NAME.
# Dead entries are skipped; prints nothing when no boss is reachable.
boss_resolve_agent() {
  local state_file="$1" agents ws reg reg_agent reg_pane state_boss
  agents="$(boss_agents)"
  ws="$(jq -r '.workspace_id // empty' "$state_file" 2>/dev/null || true)"
  if [ -n "$ws" ]; then
    reg="$(boss_registry_file_for "$ws")"
    if [ -f "$reg" ]; then
      reg_agent="$(jq -r '.agent // empty' "$reg" 2>/dev/null || true)"
      reg_pane="$(jq -r '.pane_id // empty' "$reg" 2>/dev/null || true)"
      if [ -n "$reg_agent" ] && boss_agent_alive_pane "$agents" "$reg_pane"; then
        printf '%s' "$reg_agent"
        return 0
      fi
    fi
  fi
  state_boss="$(jq -r '.boss // empty' "$state_file" 2>/dev/null || true)"
  if [ -n "$state_boss" ] && boss_agent_alive_name "$agents" "$state_boss"; then
    printf '%s' "$state_boss"
    return 0
  fi
  if [ -n "${BOSS_AGENT_NAME:-}" ] && boss_agent_alive_name "$agents" "$BOSS_AGENT_NAME"; then
    printf '%s' "$BOSS_AGENT_NAME"
    return 0
  fi
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

# git_range_base <project> <base-head> -- print <base-head> when it is a commit
# in <project> and an ancestor of HEAD, otherwise nothing. Used to guard the
# apply's commit range.
git_range_base() {
  local project="$1" base="${2:-}"
  [ -n "$base" ] || return 0
  git -C "$project" cat-file -e "${base}^{commit}" 2>/dev/null || return 0
  git -C "$project" merge-base --is-ancestor "$base" HEAD 2>/dev/null || return 0
  printf '%s' "$base"
}

# last_event_field <file> <event> <field> -- value of <field> in the last event
# of that name (may be multi-line), or nothing. Skips malformed lines.
last_event_field() {
  local file="$1" event="$2" field="$3"
  [ -f "$file" ] || return 0
  jq -Rrc --arg e "$event" --arg f "$field" \
    'split("\n")
     | map(select(length > 0) | (fromjson? | select(type == "object" and .event == $e)))
     | map(.[$f] // empty)
     | last // empty' "$file" 2>/dev/null || true
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
