#!/usr/bin/env bash
# install.sh -- install (or uninstall) the openspec-boss into Claude Code and
# OpenCode. Idempotent: run again after `git pull` on any machine.
# Usage: ./install.sh [--uninstall]

set -u

# Resolve the repository path portably: source bin/boss-lib.sh first, because
# its resolve_path helper replaces 'readlink -f' (macOS has no -f). install.sh
# is run from the repository root, so the library sits at bin/boss-lib.sh.
BOSS_SELF="${BASH_SOURCE[0]}"
while [ -L "$BOSS_SELF" ]; do
  BOSS_LINK="$(readlink "$BOSS_SELF" 2>/dev/null)" || break
  case "$BOSS_LINK" in
    /*) BOSS_SELF="$BOSS_LINK" ;;
    *) BOSS_SELF="$(dirname "$BOSS_SELF")/$BOSS_LINK" ;;
  esac
done
BOSS_REPO_BOOT="$(cd "$(dirname "$BOSS_SELF")" && pwd -P)" || exit 1
# shellcheck source=bin/boss-lib.sh
. "$BOSS_REPO_BOOT/bin/boss-lib.sh"
REPO_DIR="$(dirname "$(resolve_path "${BASH_SOURCE[0]}")")"
unset BOSS_SELF BOSS_LINK BOSS_REPO_BOOT

CLAUDE_DIR="$HOME/.claude"
OPENCODE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
BIN_LINK="$HOME/.local/bin/boss"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/openspec-boss"

info() { printf 'install: %s\n' "$*"; }
warn() { printf 'install: warning: %s\n' "$*" >&2; }
fail() { printf 'install: error: %s\n' "$*" >&2; }

CHANGED=0
CONFLICTS=0

# link_symlink <src> <dest> -- create a symlink unless a foreign file exists.
# Returns 0 when the link exists (or was created), 1 on conflict/failure.
link_symlink() {
  local src="$1" dest="$2"
  if [ -L "$dest" ]; then
    if [ "$(resolve_path "$dest")" = "$(resolve_path "$src")" ]; then
      return 0
    fi
    warn "$dest already exists as a symlink to $(readlink "$dest"); leaving it alone"
    CONFLICTS=$((CONFLICTS + 1))
    return 1
  fi
  if [ -e "$dest" ]; then
    warn "$dest already exists and is not a symlink; leaving it alone"
    CONFLICTS=$((CONFLICTS + 1))
    return 1
  fi
  mkdir -p "$(dirname "$dest")" || {
    fail "cannot create directory $(dirname "$dest")"
    CONFLICTS=$((CONFLICTS + 1))
    return 1
  }
  if ln -s "$src" "$dest"; then
    info "linked $dest -> $src"
    CHANGED=$((CHANGED + 1))
    return 0
  fi
  fail "cannot create symlink $dest"
  CONFLICTS=$((CONFLICTS + 1))
  return 1
}

check_prereqs() {
  local missing=0 cmd
  for cmd in herdr openspec jq python3; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      fail "missing prerequisite: '$cmd' is not in PATH"
      missing=$((missing + 1))
    fi
  done
  # The waiter is detached with setsid when available, otherwise with nohup
  # (macOS has no setsid). At least one of them must exist.
  if ! command -v setsid >/dev/null 2>&1; then
    if command -v nohup >/dev/null 2>&1; then
      info "setsid not found; the waiter will be detached with nohup"
    else
      fail "missing prerequisite: need 'setsid' or 'nohup' to detach the waiter"
      missing=$((missing + 1))
    fi
  fi
  if command -v python3 >/dev/null 2>&1; then
    if ! python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)'; then
      fail "python3 3.11 or newer is required (tomllib)"
      missing=$((missing + 1))
    fi
  fi
  [ "$missing" -eq 0 ]
}

integration_name() {
  case "$1" in
    gemini) printf 'antigravity-cli' ;;
    *) printf '%s' "$1" ;;
  esac
}

# check_integrations -- require a herdr integration for every configured
# runner kind (or for the installed agents when there is no config yet).
check_integrations() {
  local bad=0 kinds="" k iname status_out
  if [ -f "$CONFIG_DIR/boss.toml" ]; then
    kinds="$(python3 -c '
import tomllib, sys
try:
    with open(sys.argv[1], "rb") as f:
        data = tomllib.load(f)
except Exception:
    sys.exit(0)
print(" ".join(sorted(data.get("runners", {}))))' "$CONFIG_DIR/boss.toml" 2>/dev/null || true)"
  else
    for k in opencode claude gemini copilot kilo qwen cursor codex; do
      if command -v "$k" >/dev/null 2>&1; then
        kinds="$kinds $k"
      fi
    done
  fi
  status_out="$(herdr integration status 2>/dev/null || true)"
  for k in $kinds; do
    iname="$(integration_name "$k")"
    if ! printf '%s\n' "$status_out" | grep -q "^$iname: current"; then
      warn "herdr integration for '$k' is not current; run: herdr integration install $k"
      bad=$((bad + 1))
    fi
  done
  [ "$bad" -eq 0 ]
}

install_all() {
  info "repository: $REPO_DIR"
  link_symlink "$REPO_DIR/skills/boss" "$CLAUDE_DIR/skills/boss"
  link_symlink "$REPO_DIR/skills/boss" "$OPENCODE_DIR/skills/boss"
  link_symlink "$REPO_DIR/commands/claude/boss" "$CLAUDE_DIR/commands/boss"
  local f
  for f in "$REPO_DIR"/commands/opencode/boss-*.md; do
    [ -e "$f" ] || continue
    link_symlink "$f" "$OPENCODE_DIR/commands/$(basename "$f")"
  done
  link_symlink "$REPO_DIR/bin/boss" "$BIN_LINK"
  local bin_dir
  bin_dir="$(dirname "$BIN_LINK")"
  case ":$PATH:" in
    *":$bin_dir:"*) ;;
    *)
      warn "$bin_dir is not in PATH; boss will not be found in new shells"
      warn 'add this line to your shell configuration:'
      warn 'export PATH="$HOME/.local/bin:$PATH"'
      ;;
  esac
  mkdir -p "$CONFIG_DIR" || {
    fail "cannot create $CONFIG_DIR"
    CONFLICTS=$((CONFLICTS + 1))
  }
}

uninstall_all() {
  local f
  remove_link() {
    local dest="$1" src="$2"
    if [ -L "$dest" ]; then
      if [ "$(resolve_path "$dest")" = "$(resolve_path "$src")" ]; then
        rm -f "$dest" && info "removed $dest"
      else
        warn "$dest points elsewhere; leaving it alone"
      fi
    elif [ -e "$dest" ]; then
      warn "$dest exists and is not our symlink; leaving it alone"
    fi
  }
  remove_link "$CLAUDE_DIR/skills/boss" "$REPO_DIR/skills/boss"
  remove_link "$OPENCODE_DIR/skills/boss" "$REPO_DIR/skills/boss"
  remove_link "$CLAUDE_DIR/commands/boss" "$REPO_DIR/commands/claude/boss"
  for f in "$REPO_DIR"/commands/opencode/boss-*.md; do
    [ -e "$f" ] || continue
    remove_link "$OPENCODE_DIR/commands/$(basename "$f")" "$f"
  done
  remove_link "$BIN_LINK" "$REPO_DIR/bin/boss"
  info "uninstall done (config in $CONFIG_DIR and state under ${XDG_STATE_HOME:-$HOME/.local/state}/openspec-boss were kept)"
}

main() {
  if [ "${1:-}" = "--uninstall" ]; then
    uninstall_all
    exit 0
  fi
  if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    printf 'usage: %s [--uninstall]\n' "$0"
    exit 0
  fi
  [ -z "${1:-}" ] || {
    fail "unknown argument: $1"
    exit 2
  }

  check_prereqs || exit 1
  check_integrations || exit 1
  install_all

  if [ "$CHANGED" -eq 0 ]; then
    info "nothing to do; boss is already installed"
  else
    info "done"
  fi
  [ "$CONFLICTS" -eq 0 ] || {
    fail "some targets were skipped due to conflicts; resolve them and run again"
    exit 1
  }
}

main "$@"
