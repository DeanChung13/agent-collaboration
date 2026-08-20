#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/agent-collaboration-test.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

pass_count=0

pass() {
  pass_count=$((pass_count + 1))
  echo "ok $pass_count - $1"
}

fail() {
  echo "not ok - $1" >&2
  exit 1
}

assert_contains() {
  haystack="$1"
  needle="$2"
  label="$3"
  case "$haystack" in
    *"$needle"*) ;;
    *) fail "$label (missing: $needle)" ;;
  esac
}

MOCK_BIN="$TEST_ROOT/bin"
mkdir -p "$MOCK_BIN"

cat > "$MOCK_BIN/tmux" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${MOCK_TMUX_LOG:?}"
case "${1:-}" in
  display-message)
    case "$*" in
      *'#{pane_in_mode}'*) printf '%s\n' "${MOCK_PANE_IN_MODE:-0}" ;;
      *'#{pane_pid}'*) printf '%s\n' "${MOCK_PANE_PID:-4242}" ;;
      *) printf '%s\n' "${MOCK_PANE_PID:-4242}" ;;
    esac
    ;;
  list-panes) printf '%s\n' '%1' '%2' ;;
  set-buffer)
    shift
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -b) shift 2 ;;
        --) shift; printf '%s' "$*" > "${MOCK_TMUX_BUFFER:-/dev/null}"; break ;;
        *) shift ;;
      esac
    done
    ;;
esac
EOF
chmod +x "$MOCK_BIN/tmux"

cat > "$MOCK_BIN/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = rev-parse ] && [ "${2:-}" = --show-toplevel ]; then
  printf '%s\n' "${MOCK_GIT_ROOT:?}"
  exit 0
fi
exit 1
EOF
chmod +x "$MOCK_BIN/git"

# 1. Symlink install mode
INSTALL_HOME="$TEST_ROOT/home-install"
mkdir -p "$INSTALL_HOME"
MOCK_TMUX_LOG="$TEST_ROOT/install-tmux.log" HOME="$INSTALL_HOME" PATH="$MOCK_BIN:$PATH" \
  "$REPO_ROOT/install.sh" --link >/dev/null
[ -L "$INSTALL_HOME/.agents/skills/agent-collaboration" ] || fail 'installer creates shared skill link'
[ -L "$INSTALL_HOME/.claude/skills/agent-collaboration" ] || fail 'installer creates Claude skill link'
pass 'installer links Codex/Gemini and Claude discovery paths'

mkdir -p "$INSTALL_HOME/.agents/skills/conflict"
if MOCK_TMUX_LOG="$TEST_ROOT/install-tmux.log" HOME="$INSTALL_HOME" PATH="$MOCK_BIN:$PATH" \
  "$REPO_ROOT/install.sh" --link >/dev/null 2>&1; then
  pass 'installer is idempotent for matching links'
else
  fail 'installer should be idempotent for matching links'
fi

# 2. Default copy install mode & update / force handling
INSTALL_COPY_HOME="$TEST_ROOT/home-copy"
mkdir -p "$INSTALL_COPY_HOME"
MOCK_TMUX_LOG="$TEST_ROOT/install-copy-tmux.log" HOME="$INSTALL_COPY_HOME" PATH="$MOCK_BIN:$PATH" \
  "$REPO_ROOT/install.sh" >/dev/null
[ -d "$INSTALL_COPY_HOME/.local/share/agent-skills/agent-collaboration" ] || fail 'default install creates canonical copy'
[ -x "$INSTALL_COPY_HOME/.local/share/agent-skills/agent-collaboration/scripts/agent-send" ] || fail 'copied script has execute permission'
[ -L "$INSTALL_COPY_HOME/.agents/skills/agent-collaboration" ] || fail 'default install links shared skill'
[ -L "$INSTALL_COPY_HOME/.claude/skills/agent-collaboration" ] || fail 'default install links Claude skill'
pass 'default copy install creates canonical copy and discovery links'

if MOCK_TMUX_LOG="$TEST_ROOT/install-copy-tmux.log" HOME="$INSTALL_COPY_HOME" PATH="$MOCK_BIN:$PATH" \
  "$REPO_ROOT/install.sh" >/dev/null 2>&1; then
  fail 'default copy install should refuse to clobber existing canonical directory without --force'
fi
pass 'default copy install refuses overwrite without --force'

MOCK_TMUX_LOG="$TEST_ROOT/install-copy-tmux.log" HOME="$INSTALL_COPY_HOME" PATH="$MOCK_BIN:$PATH" \
  "$REPO_ROOT/install.sh" --force >/dev/null
pass 'default copy install can be re-run and updated with --force'

# 3. Registration & Agent validation tests
PROJECT="$TEST_ROOT/project"
mkdir -p "$PROJECT"
REGISTER_OUTPUT="$(MOCK_TMUX_LOG="$TEST_ROOT/tmux.log" MOCK_GIT_ROOT="$PROJECT" MOCK_PANE_PID=4242 \
  TMUX_PANE='%1' PATH="$MOCK_BIN:$PATH" "$REPO_ROOT/scripts/agent-register" codex)"
assert_contains "$REGISTER_OUTPUT" 'Registered codex -> %1' 'register output'
assert_contains "$(cat "$PROJECT/.agents/registry")" 'codex' 'registry contains agent'
assert_contains "$(cat "$PROJECT/.agents/registry")" '4242' 'registry contains pane pid'
pass 'agent-register creates a pid-bound registry entry'

MOCK_TMUX_LOG="$TEST_ROOT/tmux.log" MOCK_GIT_ROOT="$PROJECT" MOCK_PANE_PID=4242 \
  TMUX_PANE='%1' PATH="$MOCK_BIN:$PATH" "$REPO_ROOT/scripts/agent-register" codex >/dev/null
[ "$(awk '$1 == "codex" { count++ } END { print count+0 }' "$PROJECT/.agents/registry")" -eq 1 ] || \
  fail 'agent-register should replace duplicate names'
pass 'agent-register is idempotent by agent name'

for bad_name in 'agent name' 'bad#agent' 'foo$bar' $'name\nnewline'; do
  if MOCK_TMUX_LOG="$TEST_ROOT/tmux.log" MOCK_GIT_ROOT="$PROJECT" MOCK_PANE_PID=4242 \
    TMUX_PANE='%1' PATH="$MOCK_BIN:$PATH" "$REPO_ROOT/scripts/agent-register" "$bad_name" >/dev/null 2>&1; then
    fail "agent-register should reject invalid agent name: $bad_name"
  fi
done
pass 'agent-register rejects invalid agent names'

if MOCK_TMUX_LOG="$TEST_ROOT/tmux.log" MOCK_GIT_ROOT="$PROJECT" MOCK_PANE_PID=4242 \
  TMUX_PANE='' PATH="$MOCK_BIN:$PATH" "$REPO_ROOT/scripts/agent-register" codex >/dev/null 2>&1; then
  fail 'agent-register should fail when TMUX_PANE is empty'
fi
pass 'agent-register rejects execution outside tmux (missing TMUX_PANE)'

# 4. Message delivery & Quoting / Multiline / CJK tests
printf '%-15s %-15s %s\n' 'claude' '%2' '9001' >> "$PROJECT/.agents/registry"
SEND_OUTPUT="$(MOCK_TMUX_LOG="$TEST_ROOT/tmux.log" MOCK_GIT_ROOT="$PROJECT" MOCK_PANE_PID=9001 \
  TMUX_PANE='%1' PATH="$MOCK_BIN:$PATH" "$REPO_ROOT/scripts/agent-send" claude 'hello world')"
assert_contains "$SEND_OUTPUT" 'Sent to claude (%2)' 'send output'
TMUX_LOG="$(cat "$TEST_ROOT/tmux.log")"
assert_contains "$TMUX_LOG" 'paste-buffer -p -d' 'bracketed paste is used'
assert_contains "$TMUX_LOG" 'send-keys -t %2 Enter' 'message is submitted'
pass 'agent-send validates and submits through tmux'

MOCK_BUFFER_FILE="$TEST_ROOT/tmux_buffer.txt"
TEST_MSG="[from codex] 多行測試第一行
\"第二行包含雙引號\" 與 '單引號'
第三行: CJK 繁體中文 & 特殊符號 \`\$VAR\`"

MOCK_TMUX_LOG="$TEST_ROOT/tmux.log" MOCK_TMUX_BUFFER="$MOCK_BUFFER_FILE" MOCK_GIT_ROOT="$PROJECT" MOCK_PANE_PID=9001 \
  TMUX_PANE='%1' PATH="$MOCK_BIN:$PATH" "$REPO_ROOT/scripts/agent-send" claude "$TEST_MSG" >/dev/null

[ -f "$MOCK_BUFFER_FILE" ] || fail 'tmux set-buffer was not called'
BUFFER_CONTENT="$(cat "$MOCK_BUFFER_FILE")"
[ "$BUFFER_CONTENT" = "$TEST_MSG" ] || fail "buffer payload mismatch: got '$BUFFER_CONTENT'"
pass 'agent-send delivers multiline CJK and quoted message intact in set-buffer'

# 5. Copy-mode cancellation regression test
COPY_MODE_LOG="$TEST_ROOT/tmux-copy-mode.log"
MOCK_TMUX_LOG="$COPY_MODE_LOG" MOCK_GIT_ROOT="$PROJECT" MOCK_PANE_PID=9001 MOCK_PANE_IN_MODE=1 \
  TMUX_PANE='%1' PATH="$MOCK_BIN:$PATH" "$REPO_ROOT/scripts/agent-send" claude 'copy mode test' >/dev/null

COPY_LOG_CONTENT="$(cat "$COPY_MODE_LOG")"
assert_contains "$COPY_LOG_CONTENT" 'send-keys -t %2 -X cancel' 'copy-mode is canceled before paste'

case "$COPY_LOG_CONTENT" in
  *'send-keys -t %2 -X cancel'*'paste-buffer -p -d'*) ;;
  *) fail 'copy-mode cancel must occur before paste-buffer' ;;
esac
pass 'agent-send cancels copy-mode when pane_in_mode is non-zero'

# 6. Legacy format & Stale PID rejection tests
LEGACY_PROJECT="$TEST_ROOT/legacy-project"
mkdir -p "$LEGACY_PROJECT/.agents"
printf '# agent-name    tmux-pane-id\n%-15s %s\n' 'legacyagent' '%2' > "$LEGACY_PROJECT/.agents/registry"
if MOCK_TMUX_LOG="$TEST_ROOT/tmux.log" MOCK_GIT_ROOT="$LEGACY_PROJECT" MOCK_PANE_PID=4242 \
  TMUX_PANE='%1' PATH="$MOCK_BIN:$PATH" "$REPO_ROOT/scripts/agent-send" legacyagent 'test' >/dev/null 2>&1; then
  fail 'agent-send should reject legacy 2-column registry entry'
fi
pass 'agent-send rejects legacy 2-column registry entries'

if MOCK_TMUX_LOG="$TEST_ROOT/tmux.log" MOCK_GIT_ROOT="$PROJECT" MOCK_PANE_PID=9999 \
  TMUX_PANE='%1' PATH="$MOCK_BIN:$PATH" "$REPO_ROOT/scripts/agent-send" claude 'test' >/dev/null 2>&1; then
  fail 'agent-send should reject stale pane with mismatched PID'
fi
pass 'agent-send rejects stale pane with mismatched PID'

if MOCK_TMUX_LOG="$TEST_ROOT/tmux.log" MOCK_GIT_ROOT="$PROJECT" MOCK_PANE_PID=4242 \
  TMUX_PANE='%1' PATH="$MOCK_BIN:$PATH" "$REPO_ROOT/scripts/agent-send" codex loop >/dev/null 2>&1; then
  fail 'agent-send should refuse to send to itself'
fi
pass 'agent-send refuses self-delivery'

echo "1..$pass_count"
