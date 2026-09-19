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
  list-panes) printf '%s\n' '%1' '%2' '%3' ;;
  split-window) printf '%s\n' "${MOCK_NEW_PANE:-%9}" ;;
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

for mock_agent in agy claude codex gemini; do
  cat > "$MOCK_BIN/$mock_agent" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
  chmod +x "$MOCK_BIN/$mock_agent"
done

# 1. Symlink install mode (links: CLI bin, shared, codex, claude, gemini)
INSTALL_HOME="$TEST_ROOT/home-install"
mkdir -p "$INSTALL_HOME"
MOCK_TMUX_LOG="$TEST_ROOT/install-tmux.log" HOME="$INSTALL_HOME" PATH="$INSTALL_HOME/.local/bin:$MOCK_BIN:$PATH" \
  "$REPO_ROOT/install.sh" --link >/dev/null
[ -L "$INSTALL_HOME/.local/bin/agent-collab" ] || fail 'installer creates agent-collab bin link in link mode'
[ -L "$INSTALL_HOME/.agents/skills/agent-collaboration" ] || fail 'installer creates shared skill link'
[ -L "$INSTALL_HOME/.codex/skills/agent-collaboration" ] || fail 'installer creates Codex skill link'
[ -L "$INSTALL_HOME/.claude/skills/agent-collaboration" ] || fail 'installer creates Claude skill link'
[ -L "$INSTALL_HOME/.gemini/skills/agent-collaboration" ] || fail 'installer creates Gemini skill link'
pass 'installer links bin, shared, Codex, Claude, and Gemini discovery paths'

# 2. Custom CODEX_HOME and XDG_BIN_HOME install test
CUSTOM_CODEX_HOME="$TEST_ROOT/custom-codex-dir"
CUSTOM_BIN_DIR="$TEST_ROOT/custom-bin-dir"
MOCK_TMUX_LOG="$TEST_ROOT/install-custom-codex.log" HOME="$INSTALL_HOME" CODEX_HOME="$CUSTOM_CODEX_HOME" \
  XDG_BIN_HOME="$CUSTOM_BIN_DIR" PATH="$CUSTOM_BIN_DIR:$MOCK_BIN:$PATH" "$REPO_ROOT/install.sh" --link >/dev/null
[ -L "$CUSTOM_CODEX_HOME/skills/agent-collaboration" ] || fail 'installer respects custom CODEX_HOME'
[ -L "$CUSTOM_BIN_DIR/agent-collab" ] || fail 'installer respects custom XDG_BIN_HOME'
pass 'installer respects custom CODEX_HOME and XDG_BIN_HOME'

# Installer warns instead of silently leaving the CLI unreachable from a PATH snapshot.
PATH_WARNING_FILE="$TEST_ROOT/install-path-warning.txt"
PATH_WITHOUT_BIN="$MOCK_BIN:/usr/bin:/bin"
MOCK_TMUX_LOG="$TEST_ROOT/install-path-warning-tmux.log" HOME="$TEST_ROOT/home-path-warning" \
  XDG_BIN_HOME="$TEST_ROOT/not-on-path-bin" PATH="$PATH_WITHOUT_BIN" \
  "$REPO_ROOT/install.sh" --link >/dev/null 2>"$PATH_WARNING_FILE"
assert_contains "$(cat "$PATH_WARNING_FILE")" 'is not in PATH for this shell' 'installer warns when bin directory is absent from PATH'
assert_contains "$(cat "$PATH_WARNING_FILE")" 'AI hosts should use the absolute bundled CLI' 'installer gives deterministic AI-host guidance'
pass 'installer reports a missing CLI PATH entry with actionable guidance'

mkdir -p "$INSTALL_HOME/.agents/skills/conflict"
if MOCK_TMUX_LOG="$TEST_ROOT/install-tmux.log" HOME="$INSTALL_HOME" PATH="$MOCK_BIN:$PATH" \
  "$REPO_ROOT/install.sh" --link >/dev/null 2>&1; then
  pass 'installer is idempotent for matching links'
else
  fail 'installer should be idempotent for matching links'
fi

# 3. Default copy install mode & update / force handling
INSTALL_COPY_HOME="$TEST_ROOT/home-copy"
mkdir -p "$INSTALL_COPY_HOME"
MOCK_TMUX_LOG="$TEST_ROOT/install-copy-tmux.log" HOME="$INSTALL_COPY_HOME" PATH="$INSTALL_COPY_HOME/.local/bin:$MOCK_BIN:$PATH" \
  "$REPO_ROOT/install.sh" >/dev/null
[ -d "$INSTALL_COPY_HOME/.local/share/agent-skills/agent-collaboration" ] || fail 'default install creates canonical copy'
[ -L "$INSTALL_COPY_HOME/.local/bin/agent-collab" ] || fail 'default install creates CLI bin link'
[ -x "$INSTALL_COPY_HOME/.local/share/agent-skills/agent-collaboration/scripts/agent-collab" ] || fail 'copied agent-collab has execute permission'
[ -x "$INSTALL_COPY_HOME/.local/share/agent-skills/agent-collaboration/scripts/agent-send" ] || fail 'copied agent-send has execute permission'
[ -x "$INSTALL_COPY_HOME/.local/share/agent-skills/agent-collaboration/scripts/agent-register" ] || fail 'copied agent-register has execute permission'
[ -x "$INSTALL_COPY_HOME/.local/share/agent-skills/agent-collaboration/scripts/agent-join" ] || fail 'copied agent-join has execute permission'
[ -L "$INSTALL_COPY_HOME/.agents/skills/agent-collaboration" ] || fail 'default install links shared skill'
[ -L "$INSTALL_COPY_HOME/.codex/skills/agent-collaboration" ] || fail 'default install links Codex skill'
[ -L "$INSTALL_COPY_HOME/.claude/skills/agent-collaboration" ] || fail 'default install links Claude skill'
[ -L "$INSTALL_COPY_HOME/.gemini/skills/agent-collaboration" ] || fail 'default install links Gemini skill'
pass 'default copy install creates canonical copy, bin link, and discovery links'

if MOCK_TMUX_LOG="$TEST_ROOT/install-copy-tmux.log" HOME="$INSTALL_COPY_HOME" PATH="$MOCK_BIN:$PATH" \
  "$REPO_ROOT/install.sh" >/dev/null 2>&1; then
  fail 'default copy install should refuse to clobber existing canonical directory without --force'
fi
pass 'default copy install refuses overwrite without --force'

MOCK_TMUX_LOG="$TEST_ROOT/install-copy-tmux.log" HOME="$INSTALL_COPY_HOME" PATH="$INSTALL_COPY_HOME/.local/bin:$MOCK_BIN:$PATH" \
  "$REPO_ROOT/install.sh" --force >/dev/null
[ -z "$(find "$INSTALL_COPY_HOME/.local/share/agent-skills" -maxdepth 1 -name '*.backup.*')" ] || fail 'force install should overwrite directly without backup directories'
pass 'default copy install can be re-run and updated with --force'

# 4. SKILL.md portability check (no fixed host skill paths, contains SKILL_DIR)
SKILL_FILE="$REPO_ROOT/SKILL.md"
for bad_pattern in '~/.ai_skills' '~/.claude/skills' '~/.codex/skills' '~/.gemini/skills' '/Users/'; do
  if grep -q "$bad_pattern" "$SKILL_FILE"; then
    fail "SKILL.md contains hardcoded path: $bad_pattern"
  fi
done
assert_contains "$(cat "$SKILL_FILE")" 'SKILL_DIR="<absolute directory containing this loaded SKILL.md>"' 'SKILL.md defines SKILL_DIR placeholder'
assert_contains "$(cat "$SKILL_FILE")" 'AGENT_COLLAB="$SKILL_DIR/scripts/agent-collab"' 'SKILL.md resolves the bundled CLI once'
assert_contains "$(cat "$SKILL_FILE")" 'Do not invoke a bare' 'SKILL.md rejects PATH-dependent agent invocation'
pass 'SKILL.md contains no hardcoded host paths and requires deterministic bundled CLI resolution'

assert_contains "$(cat "$SKILL_FILE")" '"$AGENT_COLLAB" join <your-own-agent-name>' 'SKILL.md tells the host session to register itself'
assert_contains "$(cat "$SKILL_FILE")" 'add` refuses a name that is already live' 'SKILL.md documents the duplicate refusal'
pass 'SKILL.md requires self-registration before adding collaborators'

# 5. Arbitrary installation directory & symlinked CLI execution
ARBITRARY_DIR="$TEST_ROOT/arbitrary-location/my-skill"
mkdir -p "$ARBITRARY_DIR/scripts" "$TEST_ROOT/arbitrary-bin"
cp "$REPO_ROOT/SKILL.md" "$ARBITRARY_DIR/SKILL.md"
cp "$REPO_ROOT/scripts/agent-collab" "$ARBITRARY_DIR/scripts/agent-collab"
cp "$REPO_ROOT/scripts/agent-register" "$ARBITRARY_DIR/scripts/agent-register"
cp "$REPO_ROOT/scripts/agent-send" "$ARBITRARY_DIR/scripts/agent-send"
cp "$REPO_ROOT/scripts/agent-join" "$ARBITRARY_DIR/scripts/agent-join"
chmod +x "$ARBITRARY_DIR/scripts/"*
ln -s "$ARBITRARY_DIR/scripts/agent-collab" "$TEST_ROOT/arbitrary-bin/agent-collab"

RESOLVED_SKILL_DIR="$(cd "$ARBITRARY_DIR" && pwd -P)"
ARBITRARY_PROJECT="$TEST_ROOT/arbitrary-project"
mkdir -p "$ARBITRARY_PROJECT"

# Test invoking symlinked agent-collab in PATH without SKILL_DIR
PATH="$TEST_ROOT/arbitrary-bin:$MOCK_BIN:$PATH"
ARB_JOIN_OUT="$(MOCK_TMUX_LOG="$TEST_ROOT/tmux.log" MOCK_GIT_ROOT="$ARBITRARY_PROJECT" MOCK_PANE_PID=5555 \
  TMUX_PANE='%1' agent-collab join gemini)"
assert_contains "$ARB_JOIN_OUT" 'Registered gemini -> %1' 'symlinked agent-collab join output'

# Test agent-collab list on populated registry
printf '%-15s %-15s %-15s %s\n' 'codex' '%2' '7777' "$$" >> "$ARBITRARY_PROJECT/.agents/registry"
ARB_LIST_OUT="$(MOCK_TMUX_LOG="$TEST_ROOT/tmux.log" MOCK_PANE_PID=7777 MOCK_GIT_ROOT="$ARBITRARY_PROJECT" agent-collab list)"
if printf '%s\n' "$ARB_LIST_OUT" | grep -Fq 'gemini'; then
  fail 'agent-collab list should remove the exited gemini process'
fi
assert_contains "$ARB_LIST_OUT" 'codex' 'agent-collab list output contains codex'

ARB_SEND_OUT="$(MOCK_TMUX_LOG="$TEST_ROOT/tmux.log" MOCK_GIT_ROOT="$ARBITRARY_PROJECT" MOCK_PANE_PID=7777 \
  TMUX_PANE='%1' agent-collab send codex 'hello from symlinked agent-collab')"
assert_contains "$ARB_SEND_OUT" 'Sent to codex (%2)' 'agent-collab send output'
pass 'symlinked agent-collab CLI on PATH executes join, list, and send cleanly'

# 6. Unified CLI agent-collab dispatch & validation tests
PROJECT="$TEST_ROOT/project"
mkdir -p "$PROJECT"

# agent-collab list when empty
EMPTY_LIST_OUT="$(MOCK_GIT_ROOT="$PROJECT" "$REPO_ROOT/scripts/agent-collab" list)"
assert_contains "$EMPTY_LIST_OUT" 'No agents registered yet' 'empty agent-collab list output'

# agent-collab join
JOIN_OUTPUT="$(MOCK_TMUX_LOG="$TEST_ROOT/tmux.log" MOCK_GIT_ROOT="$PROJECT" MOCK_PANE_PID=4242 \
  TMUX_PANE='%1' PATH="$MOCK_BIN:$PATH" "$REPO_ROOT/scripts/agent-collab" join codex)"
assert_contains "$JOIN_OUTPUT" 'Registered codex -> %1' 'join output'
assert_contains "$(cat "$PROJECT/.agents/registry")" 'codex' 'registry contains agent'
assert_contains "$(cat "$PROJECT/.agents/registry")" '4242' 'registry contains pane pid'
pass 'agent-collab join creates pid-bound registry entry'

# agent-collab run registers the pane and launches the matching CLI.
for launched_agent in agy claude codex gemini; do
  AGENT_LAUNCH_LOG="$TEST_ROOT/$launched_agent-launch.log"
  cat > "$MOCK_BIN/$launched_agent" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ -n "${MOCK_AGENT_LAUNCH_LOG:-}" ]; then
  printf '%s\n' "${MOCK_LAUNCHED_AGENT:?}" >> "$MOCK_AGENT_LAUNCH_LOG"
fi
EOF
  chmod +x "$MOCK_BIN/$launched_agent"
  AGENT_JOIN_OUTPUT="$(MOCK_TMUX_LOG="$TEST_ROOT/tmux.log" MOCK_GIT_ROOT="$PROJECT" MOCK_PANE_PID=9001 \
    MOCK_LAUNCHED_AGENT="$launched_agent" MOCK_AGENT_LAUNCH_LOG="$AGENT_LAUNCH_LOG" \
    TMUX_PANE='%2' PATH="$MOCK_BIN:$PATH" "$REPO_ROOT/scripts/agent-collab" run "$launched_agent")"
  assert_contains "$AGENT_JOIN_OUTPUT" "Registered $launched_agent -> %2" "$launched_agent run output"
  assert_contains "$(cat "$AGENT_LAUNCH_LOG")" "$launched_agent" "$launched_agent CLI is launched"
  assert_contains "$(cat "$PROJECT/.agents/registry")" "$launched_agent" "registry contains $launched_agent"
done
pass 'agent-collab run launches agy, claude, codex, and gemini after registration'

# agent-collab add opens a detached pane that runs the lifecycle launcher
ADD_TMUX_LOG="$TEST_ROOT/tmux-add.log"
printf '%-15s %-15s %-15s %s\n' 'claude' '%8' '9001' "$$" >> "$PROJECT/.agents/registry"
ADD_OUTPUT="$(MOCK_TMUX_LOG="$ADD_TMUX_LOG" MOCK_GIT_ROOT="$PROJECT" MOCK_NEW_PANE='%8' \
  TMUX_PANE='%1' PATH="$MOCK_BIN:$PATH" "$REPO_ROOT/scripts/agent-collab" add claude)"
assert_contains "$ADD_OUTPUT" 'Added claude in %8' 'add confirms registration in the new pane'
ADD_LOG_CONTENT="$(cat "$ADD_TMUX_LOG")"
assert_contains "$ADD_LOG_CONTENT" 'split-window -d -P -F #{pane_id}' 'add creates a detached tmux pane'
assert_contains "$ADD_LOG_CONTENT" 'agent-collab run claude' 'add starts the lifecycle launcher in the new pane'
pass 'agent-collab add creates a pane and starts the requested collaborator'

# agent-collab add refuses a name that is already live in the registry
DUP_PROJECT="$TEST_ROOT/dup-project"
mkdir -p "$DUP_PROJECT/.agents"
printf '# agent-name    tmux-pane-id    pane-pid        agent-pid\n%-15s %-15s %-15s %s\n' \
  'claude' '%6' '4242' "$$" > "$DUP_PROJECT/.agents/registry"
DUP_TMUX_LOG="$TEST_ROOT/tmux-dup.log"
DUP_ERR="$TEST_ROOT/add-duplicate.err"
if MOCK_TMUX_LOG="$DUP_TMUX_LOG" MOCK_GIT_ROOT="$DUP_PROJECT" MOCK_PANE_PID=4242 MOCK_NEW_PANE='%9' \
  TMUX_PANE='%1' PATH="$MOCK_BIN:$PATH" "$REPO_ROOT/scripts/agent-collab" add claude \
  >/dev/null 2>"$DUP_ERR"; then
  fail 'agent-collab add should refuse a duplicate live agent'
fi
assert_contains "$(cat "$DUP_ERR")" 'already running in %6' 'add names the pane holding the live agent'
if [ -f "$DUP_TMUX_LOG" ] && grep -Fq 'split-window' "$DUP_TMUX_LOG"; then
  fail 'agent-collab add should not open a pane when refusing a duplicate'
fi
pass 'agent-collab add refuses to start a second live session under the same name'

# A dead or reassigned entry does not block a fresh add
STALE_PROJECT="$TEST_ROOT/stale-project"
mkdir -p "$STALE_PROJECT/.agents"
printf '# agent-name    tmux-pane-id    pane-pid        agent-pid\n%-15s %-15s %-15s %s\n%-15s %-15s %-15s %s\n' \
  'claude' '%6' '4242' '99999999' 'codex' '%7' '1111' "$$" > "$STALE_PROJECT/.agents/registry"
STALE_ADD_OUT="$(MOCK_TMUX_LOG="$TEST_ROOT/tmux-stale.log" MOCK_GIT_ROOT="$STALE_PROJECT" MOCK_PANE_PID=4242 \
  MOCK_NEW_PANE='%6' TMUX_PANE='%1' PATH="$MOCK_BIN:$PATH" "$REPO_ROOT/scripts/agent-collab" add claude)"
assert_contains "$STALE_ADD_OUT" 'Added claude in %6' 'add proceeds past a dead agent entry'
STALE_CODEX_OUT="$(MOCK_TMUX_LOG="$TEST_ROOT/tmux-stale.log" MOCK_GIT_ROOT="$STALE_PROJECT" MOCK_PANE_PID=4242 \
  MOCK_NEW_PANE='%7' TMUX_PANE='%1' PATH="$MOCK_BIN:$PATH" "$REPO_ROOT/scripts/agent-collab" add codex)"
assert_contains "$STALE_CODEX_OUT" 'Added codex in %7' 'add proceeds past a reassigned pane entry'
pass 'agent-collab add ignores dead and reassigned registry entries'

# agent-collab join idempotency
MOCK_TMUX_LOG="$TEST_ROOT/tmux.log" MOCK_GIT_ROOT="$PROJECT" MOCK_PANE_PID=4242 \
  TMUX_PANE='%1' PATH="$MOCK_BIN:$PATH" "$REPO_ROOT/scripts/agent-collab" join codex >/dev/null
[ "$(awk '$1 == "codex" { count++ } END { print count+0 }' "$PROJECT/.agents/registry")" -eq 1 ] || \
  fail 'agent-collab join should replace duplicate names'
pass 'agent-collab join is idempotent by agent name'

# agent-collab join validation
for bad_name in 'agent name' 'bad#agent' 'foo$bar' $'name\nnewline'; do
  if MOCK_TMUX_LOG="$TEST_ROOT/tmux.log" MOCK_GIT_ROOT="$PROJECT" MOCK_PANE_PID=4242 \
    TMUX_PANE='%1' PATH="$MOCK_BIN:$PATH" "$REPO_ROOT/scripts/agent-collab" join "$bad_name" >/dev/null 2>&1; then
    fail "agent-collab join should reject invalid agent name: $bad_name"
  fi
done
pass 'agent-collab join rejects invalid agent names'

if MOCK_TMUX_LOG="$TEST_ROOT/tmux.log" MOCK_GIT_ROOT="$PROJECT" MOCK_PANE_PID=4242 \
  TMUX_PANE='' PATH="$MOCK_BIN:$PATH" "$REPO_ROOT/scripts/agent-collab" join codex >/dev/null 2>&1; then
  fail 'agent-collab join should fail when TMUX_PANE is empty'
fi
pass 'agent-collab join rejects execution outside tmux (missing TMUX_PANE)'

# agent-collab list with registered agent
printf '%-15s %-15s %-15s %s\n' 'liveagent' '%1' '4242' "$$" >> "$PROJECT/.agents/registry"
POPULATED_LIST_OUT="$(MOCK_TMUX_LOG="$TEST_ROOT/tmux.log" MOCK_GIT_ROOT="$PROJECT" "$REPO_ROOT/scripts/agent-collab" list)"
assert_contains "$POPULATED_LIST_OUT" 'liveagent' 'populated list contains a live agent'
assert_contains "$POPULATED_LIST_OUT" '%1' 'populated list contains %1'
pass 'agent-collab list displays registered agents'

# agent-collab list removes entries whose registered process no longer exists
PID_PROJECT="$TEST_ROOT/pid-project"
mkdir -p "$PID_PROJECT/.agents"
printf '# agent-name    tmux-pane-id    pane-pid        agent-pid\n%-15s %-15s %-15s %s\n%-15s %-15s %-15s %s\n' \
  'liveagent' '%1' '4242' "$$" 'deadagent' '%2' '4242' '99999999' > "$PID_PROJECT/.agents/registry"
PID_LIST_OUT="$(MOCK_TMUX_LOG="$TEST_ROOT/tmux.log" MOCK_GIT_ROOT="$PID_PROJECT" "$REPO_ROOT/scripts/agent-collab" list)"
assert_contains "$PID_LIST_OUT" 'liveagent' 'list retains a live agent process'
if printf '%s\n' "$PID_LIST_OUT" | grep -Fq 'deadagent'; then
  fail 'list should hide an agent whose process no longer exists'
fi
if grep -Fq 'deadagent' "$PID_PROJECT/.agents/registry"; then
  fail 'list should remove a dead agent from the registry'
fi
pass 'agent-collab list removes agents whose registered process no longer exists'

# agent-collab unknown command and missing arguments
if "$REPO_ROOT/scripts/agent-collab" unknown-cmd >/dev/null 2>&1; then
  fail 'agent-collab should reject unknown subcommand'
fi
if "$REPO_ROOT/scripts/agent-collab" join >/dev/null 2>&1; then
  fail 'agent-collab join should require agent name'
fi
if "$REPO_ROOT/scripts/agent-collab" add >/dev/null 2>&1; then
  fail 'agent-collab add should require agent name'
fi
if "$REPO_ROOT/scripts/agent-collab" run unknown-agent >/dev/null 2>&1; then
  fail 'agent-collab run should reject unsupported agents'
fi
if "$REPO_ROOT/scripts/agent-collab" send claude >/dev/null 2>&1; then
  fail 'agent-collab send should require both target and message'
fi
pass 'agent-collab rejects unknown commands and missing arguments'

# 7. Message delivery via agent-collab send & Quoting / Multiline / CJK tests
printf '%-15s %-15s %-15s %s\n' 'claude' '%2' '9001' "$$" >> "$PROJECT/.agents/registry"
SEND_OUTPUT="$(MOCK_TMUX_LOG="$TEST_ROOT/tmux.log" MOCK_GIT_ROOT="$PROJECT" MOCK_PANE_PID=9001 \
  TMUX_PANE='%1' PATH="$MOCK_BIN:$PATH" "$REPO_ROOT/scripts/agent-collab" send claude 'hello world')"
assert_contains "$SEND_OUTPUT" 'Sent to claude (%2)' 'send output'
TMUX_LOG="$(cat "$TEST_ROOT/tmux.log")"
assert_contains "$TMUX_LOG" 'paste-buffer -p -d' 'bracketed paste is used'
assert_contains "$TMUX_LOG" 'send-keys -t %2 Enter' 'message is submitted'
pass 'agent-collab send validates and submits through tmux'

MOCK_BUFFER_FILE="$TEST_ROOT/tmux_buffer.txt"
TEST_MSG="[from codex] 多行測試第一行
\"第二行包含雙引號\" 與 '單引號'
第三行: CJK 繁體中文 & 特殊符號 \`\$VAR\`"

MOCK_TMUX_LOG="$TEST_ROOT/tmux.log" MOCK_TMUX_BUFFER="$MOCK_BUFFER_FILE" MOCK_GIT_ROOT="$PROJECT" MOCK_PANE_PID=9001 \
  TMUX_PANE='%1' PATH="$MOCK_BIN:$PATH" "$REPO_ROOT/scripts/agent-collab" send claude "$TEST_MSG" >/dev/null

[ -f "$MOCK_BUFFER_FILE" ] || fail 'tmux set-buffer was not called'
BUFFER_CONTENT="$(cat "$MOCK_BUFFER_FILE")"
[ "$BUFFER_CONTENT" = "$TEST_MSG" ] || fail "buffer payload mismatch: got '$BUFFER_CONTENT'"
pass 'agent-collab send delivers multiline CJK and quoted message intact in set-buffer'

# 8. Copy-mode cancellation regression test
COPY_MODE_LOG="$TEST_ROOT/tmux-copy-mode.log"
MOCK_TMUX_LOG="$COPY_MODE_LOG" MOCK_GIT_ROOT="$PROJECT" MOCK_PANE_PID=9001 MOCK_PANE_IN_MODE=1 \
  TMUX_PANE='%1' PATH="$MOCK_BIN:$PATH" "$REPO_ROOT/scripts/agent-collab" send claude 'copy mode test' >/dev/null

COPY_LOG_CONTENT="$(cat "$COPY_MODE_LOG")"
assert_contains "$COPY_LOG_CONTENT" 'send-keys -t %2 -X cancel' 'copy-mode is canceled before paste'
pass 'agent-collab send cancels copy-mode when pane_in_mode is non-zero'

# 9. Legacy primitives & wrappers backward compatibility tests
# agent-register directly
MOCK_TMUX_LOG="$TEST_ROOT/tmux.log" MOCK_GIT_ROOT="$PROJECT" MOCK_PANE_PID="$$" \
  TMUX_PANE='%3' PATH="$MOCK_BIN:$PATH" "$REPO_ROOT/scripts/agent-register" legacygemini >/dev/null
assert_contains "$(cat "$PROJECT/.agents/registry")" 'legacygemini' 'legacy agent-register works'
pass 'legacy agent-register directly creates registry entry'

# agent-send directly
LEGACY_SEND_OUT="$(MOCK_TMUX_LOG="$TEST_ROOT/tmux.log" MOCK_GIT_ROOT="$PROJECT" MOCK_PANE_PID="$$" \
  TMUX_PANE='%1' PATH="$MOCK_BIN:$PATH" "$REPO_ROOT/scripts/agent-send" legacygemini 'legacy send test')"
assert_contains "$LEGACY_SEND_OUT" 'Sent to legacygemini (%3)' 'legacy agent-send output'
pass 'legacy agent-send directly delivers message'

# agent-join wrapper
JOIN_WRAP_OUT="$(MOCK_TMUX_LOG="$TEST_ROOT/tmux.log" MOCK_GIT_ROOT="$PROJECT" MOCK_PANE_PID="$$" \
  TMUX_PANE='%3' PATH="$MOCK_BIN:$PATH" "$REPO_ROOT/scripts/agent-join" joinedagent)"
assert_contains "$JOIN_WRAP_OUT" 'Registered joinedagent -> %3' 'agent-join wrapper output'
JOIN_LIST_OUT="$(MOCK_TMUX_LOG="$TEST_ROOT/tmux.log" MOCK_GIT_ROOT="$PROJECT" MOCK_PANE_PID="$$" "$REPO_ROOT/scripts/agent-join" --list)"
assert_contains "$JOIN_LIST_OUT" 'joinedagent' 'agent-join --list output'
pass 'agent-join wrapper preserves join and --list options'

# 10. Safety validations (stale PID, legacy format, self-send)
LEGACY_PROJECT="$TEST_ROOT/legacy-project"
mkdir -p "$LEGACY_PROJECT/.agents"
printf '# agent-name    tmux-pane-id\n%-15s %s\n' 'legacyagent' '%2' > "$LEGACY_PROJECT/.agents/registry"
if MOCK_TMUX_LOG="$TEST_ROOT/tmux.log" MOCK_GIT_ROOT="$LEGACY_PROJECT" MOCK_PANE_PID=4242 \
  TMUX_PANE='%1' PATH="$MOCK_BIN:$PATH" "$REPO_ROOT/scripts/agent-collab" send legacyagent 'test' >/dev/null 2>&1; then
  fail 'agent-collab send should reject legacy 2-column registry entry'
fi
pass 'agent-collab send rejects legacy 2-column registry entries'

if MOCK_TMUX_LOG="$TEST_ROOT/tmux.log" MOCK_GIT_ROOT="$PROJECT" MOCK_PANE_PID=9999 \
  TMUX_PANE='%1' PATH="$MOCK_BIN:$PATH" "$REPO_ROOT/scripts/agent-collab" send claude 'test' >/dev/null 2>&1; then
  fail 'agent-collab send should reject stale pane with mismatched PID'
fi
pass 'agent-collab send rejects stale pane with mismatched PID'

if MOCK_TMUX_LOG="$TEST_ROOT/tmux.log" MOCK_GIT_ROOT="$PROJECT" MOCK_PANE_PID=4242 \
  TMUX_PANE='%1' PATH="$MOCK_BIN:$PATH" "$REPO_ROOT/scripts/agent-collab" send codex loop >/dev/null 2>&1; then
  fail 'agent-collab send should refuse to send to itself'
fi
pass 'agent-collab send refuses self-delivery'

echo "1..$pass_count"
