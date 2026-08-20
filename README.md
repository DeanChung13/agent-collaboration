# agent-collaboration

[繁體中文說明文件](README.zh-TW.md)

Let separate AI CLI sessions in the same Git repository ask each other questions,
delegate bounded work, and return results through tmux.

The skill targets Codex, Claude Code, and Gemini CLI on macOS and Linux. It uses
the filesystem for substantial context and tmux prompt injection as a lightweight
"doorbell" between already-running sessions.

## Requirements

- macOS or Linux
- Bash 3.2 or newer
- Git
- tmux with bracketed-paste support (`paste-buffer -p`)
- Two or more AI CLI sessions running in tmux panes for the same Git repository

### Installing tmux

- **macOS** (Homebrew):
  ```sh
  brew install tmux
  ```
- **Ubuntu / Debian** (APT):
  ```sh
  sudo apt update
  sudo apt install -y tmux
  ```
- **Verify installation**:
  ```sh
  tmux -V
  ```

The scripts are currently verified on macOS with tmux 3.7b and Bash 3.2.57. The
included GitHub Actions workflow is configured to run the portable test suite on
macOS and Ubuntu after publication. Linux and other tmux versions remain unverified
until those CI jobs pass; no minimum tmux version is claimed beyond requiring the
commands used by the scripts.

## Install

Clone the repository, then run:

```sh
./install.sh
```

The installer copies the runtime skill to
`~/.local/share/agent-skills/agent-collaboration` (or `$XDG_DATA_HOME`) and creates:

- `~/.agents/skills/agent-collaboration` for hosts supporting the shared alias
- `$CODEX_HOME/skills/agent-collaboration` for Codex (`~/.codex/skills` by default)
- `~/.claude/skills/agent-collaboration` for Claude Code
- `~/.gemini/skills/agent-collaboration` for Gemini CLI and Antigravity

Use `./install.sh --link` while developing to link directly to your clone. The
installer refuses to replace existing paths. `--force` moves conflicts to
timestamped backups before installing.

To update a copy-mode installation from a newer clone, run `./install.sh --force`.
The previous canonical copy is preserved as a timestamped backup.

Gemini CLI also supports installing a published repository directly:

```sh
gemini skills install https://github.com/OWNER/agent-collaboration
```

For Codex, you can ask `$skill-installer` to install the published GitHub
repository. It installs into `$CODEX_HOME/skills` (default `~/.codex/skills`).
The skill resolves bundled scripts from its own loaded `SKILL.md` path, so both
native GitHub installation methods work without running this repository's
installer. The local installer remains useful when sharing one canonical copy
across all three hosts.

After installation, Codex normally detects skill changes automatically. In Claude
Code, restart if the top-level personal skills directory was created after the
session started. In Gemini CLI, run `/skills reload`. If a host still does not list
the skill, restart that session.

## Use

`agent-collaboration` relies on the `$TMUX_PANE` environment variable provided by tmux to identify sessions. **You must enter a tmux session first, start each AI CLI in a different pane, and only then run `agent-register` from within each session.** Do not start AI CLIs in a regular terminal outside tmux and attempt to register afterwards.

### Step 1: Create a tmux session and split panes

Inside your Git repository root:

```sh
cd /path/to/your/git-repo

# 1. Create a new tmux session (e.g. named agents)
tmux new-session -s agents

# 2. Split into a second pane
tmux split-window -h

# 3. Switch between panes (shortcut Ctrl-b o, or command tmux select-pane -t 0 / -t 1)
```

### Step 2: Start an AI CLI in each pane

- **Pane 0** (first pane):
  ```sh
  codex
  ```
- **Pane 1** (second pane):
  ```sh
  claude
  # or gemini
  ```

### Step 3: Register in each AI session

In each AI CLI prompt, run the registration command:

```sh
SKILL_DIR="<directory where your host installed agent-collaboration>"
"$SKILL_DIR/scripts/agent-register" codex
```

Switch to the other pane's session and run:

```sh
SKILL_DIR="<directory where your host installed agent-collaboration>"
"$SKILL_DIR/scripts/agent-register" claude
```

> **Note**: Agent names normally match the CLI name (`codex`, `claude`, `gemini`). Never register two active sessions under the same name in one repository.

### Step 4: Send a prompt

From either session, use `agent-send` to prompt another registered agent:

```sh
"$SKILL_DIR/scripts/agent-send" claude \
  '[from codex] Review the current diff. Reply with agent-send when done.'
```

The registry and message exchange live under `.agents/` in the current Git root.
On first registration, the tool creates `.agents/.gitignore` so live registry and
message files stay local by default.

## Security model

`agent-send` only targets panes explicitly registered for the current repository.
It binds each entry to the pane's shell PID, refuses self-delivery, and stops on
missing or stale panes instead of guessing a replacement.

The tool deliberately performs prompt injection into another interactive agent
session. It provides no authentication: `[from claude]`, `[from codex]`, and similar
labels are self-declared text. Any process running as your operating-system user
that can control tmux may be able to drive registered panes.

The receiving agent must still apply its normal scope, permission, sandbox, and
safety rules. Do not use this tool in repositories whose contents you do not trust.
Do not treat a relayed prompt as proof of identity or as new authorization.

Be especially careful with persistent command approvals. Permanently approving an
`agent-send <target>` prefix lets the sending agent inject arbitrary future prompts
into that target without another approval for the send operation.

The pane PID check makes committed or stale registry entries harder to exploit, but
it is not authentication and cannot detect an AI process restarted inside the same
tmux pane. Re-register sessions after restarting their agent process.

Before pasting, `agent-send` exits tmux copy-mode in the target pane so the final
Enter key is delivered. This changes the target pane's viewing state.

## Known limits

- This is a doorbell, not a message broker or orchestrator. There are no delivery
  receipts, queues, retries, or identity verification.
- The fixed 0.4-second delay between paste and Enter is verified for ordinary short
  prompts on the tested macOS setup, not for arbitrarily large messages or slow
  remote terminals. Put substantial content in `.agents/messages/` and send a path.
- Registry lookup is repository-scoped. Run the tools inside the same Git project.
- Concurrent agents can still edit the same files; divide ownership before asking
  peers to make changes.

## Test

```sh
./tests/run.sh
```

The suite uses mock `git` and `tmux` executables. It does not type into live panes.

## License

MIT. See [LICENSE](LICENSE).

## References

- [OpenAI: Build skills](https://learn.chatgpt.com/docs/build-skills)
- [Claude Code: Extend Claude with skills](https://code.claude.com/docs/en/slash-commands)
- [Gemini CLI: Managing Agent Skills](https://github.com/google-gemini/gemini-cli/blob/main/docs/cli/using-agent-skills.md)
