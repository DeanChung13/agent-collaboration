#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
FORCE=0
LINK_SOURCE=0

usage() {
  cat <<'EOF'
Usage: ./install.sh [--force] [--link]

Installs agent-collaboration for Codex, Claude Code, and Gemini CLI.

  --force  Overwrite existing installs directly.
  --link   Link directly to this clone instead of copying a canonical install.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --force) FORCE=1 ;;
    --link) LINK_SOURCE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

case "$(uname -s)" in
  Darwin|Linux) ;;
  *) echo "Unsupported operating system: $(uname -s). Use macOS or Linux." >&2; exit 1 ;;
esac

for command_name in git tmux; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Missing required command: $command_name" >&2
    exit 1
  fi
done

if [ -z "${HOME:-}" ]; then
  echo 'HOME is not set.' >&2
  exit 1
fi

DATA_ROOT="${XDG_DATA_HOME:-$HOME/.local/share}/agent-skills"
CANONICAL="$DATA_ROOT/agent-collaboration"
BIN_DIR="${XDG_BIN_HOME:-$HOME/.local/bin}"
BIN_LINK="$BIN_DIR/agent-collab"
SHARED_LINK="$HOME/.agents/skills/agent-collaboration"
CODEX_LINK="${CODEX_HOME:-$HOME/.codex}/skills/agent-collaboration"
CLAUDE_LINK="$HOME/.claude/skills/agent-collaboration"
GEMINI_LINK="$HOME/.gemini/skills/agent-collaboration"

replace_or_refuse() {
  target="$1"
  desired="$2"

  if [ -L "$target" ] && [ "$(readlink "$target")" = "$desired" ]; then
    return 0
  fi
  if [ ! -e "$target" ] && [ ! -L "$target" ]; then
    return 0
  fi
  if [ "$FORCE" -ne 1 ]; then
    echo "Refusing to replace existing path: $target" >&2
    echo "Re-run with --force to overwrite." >&2
    exit 1
  fi
  rm -rf "$target"
}

install_link() {
  target="$1"
  desired="$2"
  mkdir -p "$(dirname "$target")"
  replace_or_refuse "$target" "$desired"
  if [ ! -L "$target" ] || [ "$(readlink "$target")" != "$desired" ]; then
    ln -s "$desired" "$target"
  fi
}

if [ "$LINK_SOURCE" -eq 1 ]; then
  SOURCE="$SCRIPT_DIR"
else
  mkdir -p "$DATA_ROOT"
  STAGING="$(mktemp -d "$DATA_ROOT/.agent-collaboration.XXXXXX")"
  trap 'rm -rf "$STAGING"' EXIT
  cp "$SCRIPT_DIR/SKILL.md" "$STAGING/SKILL.md"
  mkdir -p "$STAGING/scripts"
  cp "$SCRIPT_DIR/scripts/agent-collab" "$STAGING/scripts/agent-collab"
  cp "$SCRIPT_DIR/scripts/agent-register" "$STAGING/scripts/agent-register"
  cp "$SCRIPT_DIR/scripts/agent-send" "$STAGING/scripts/agent-send"
  cp "$SCRIPT_DIR/scripts/agent-join" "$STAGING/scripts/agent-join"
  chmod +x "$STAGING/scripts/"*
  replace_or_refuse "$CANONICAL" "$STAGING"
  mv "$STAGING" "$CANONICAL"
  trap - EXIT
  SOURCE="$CANONICAL"
fi

install_link "$BIN_LINK" "$SOURCE/scripts/agent-collab"
install_link "$SHARED_LINK" "$SOURCE"
install_link "$CODEX_LINK" "$SOURCE"
install_link "$CLAUDE_LINK" "$SOURCE"
install_link "$GEMINI_LINK" "$SOURCE"

echo "Installed agent-collaboration from $SOURCE"
echo "CLI command:   $BIN_LINK"
echo "Shared agents: $SHARED_LINK"
echo "Codex:         $CODEX_LINK"
echo "Claude Code:   $CLAUDE_LINK"
echo "Gemini:        $GEMINI_LINK"

case ":${PATH:-}:" in
  *":$BIN_DIR:"*) ;;
  *)
    echo "Warning: $BIN_DIR is not in PATH for this shell." >&2
    echo "Human CLI use: add this line to your shell profile, then restart the shell:" >&2
    echo "  export PATH=\"$BIN_DIR:\$PATH\"" >&2
    echo "AI hosts should use the absolute bundled CLI from their loaded SKILL.md." >&2
    ;;
esac
