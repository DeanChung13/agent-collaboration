# agent-collaboration

讓同一個 Git 儲存庫中各自獨立的 AI CLI session 能夠透過 tmux 互相提問、委派有邊界的任務，並回傳結果。

此 Skill 適用於 macOS 與 Linux 上的 Codex、Claude Code 以及 Gemini CLI。它使用檔案系統來傳遞大量 context，並以 tmux prompt injection 作為已在執行中之 session 之間的輕量級「門鈴（doorbell）」。

## 系統需求

- macOS 或 Linux
- Bash 3.2 或更新版本
- Git
- 支援 Bracketed Paste 的 tmux（`paste-buffer -p`）
- 兩個或更多在同一個 Git 儲存庫的 tmux pane 中執行的 AI CLI session

本腳本目前已在 macOS（tmux 3.7b、Bash 3.2.57）上完成驗證。專案隨附的 GitHub Actions workflow 設定會在發布後於 macOS 與 Ubuntu 上執行可攜性測試套件。在這些 CI 任務通過前，Linux 與其他 tmux 版本仍屬未驗證狀態；除腳本所使用的命令需求外，未聲明其他最低 tmux 版本需求。

## 安裝

Clone 此儲存庫，然後執行：

```sh
./install.sh
```

安裝程式會將執行期的 skill 複製到 `~/.local/share/agent-skills/agent-collaboration`（或 `$XDG_DATA_HOME`），並建立以下連結：

- `~/.agents/skills/agent-collaboration`：供支援 shared alias 的 host 使用
- `$CODEX_HOME/skills/agent-collaboration`：供 Codex 使用（預設為 `~/.codex/skills`）
- `~/.claude/skills/agent-collaboration`：供 Claude Code 使用
- `~/.gemini/skills/agent-collaboration`：供 Gemini CLI 與 Antigravity 使用

在開發時可使用 `./install.sh --link` 直接連結到你的 clone 目錄。安裝程式預設拒絕替換既有路徑；使用 `--force` 會在安裝前將衝突路徑移動至帶有時間戳記的備份目錄。

若要從較新的 clone 更新 copy 模式的安裝，請執行 `./install.sh --force`。先前的 canonical 複本將會保留為帶有時間戳記的備份。

Gemini CLI 亦支援直接安裝已發布的儲存庫：

```sh
gemini skills install https://github.com/OWNER/agent-collaboration
```

針對 Codex，你可以要求 `$skill-installer` 安裝已發布的 GitHub 儲存庫。它會安裝至 `$CODEX_HOME/skills`（預設為 `~/.codex/skills`）。本 Skill 會從自身載入的 `SKILL.md` 路徑解析隨附的腳本，因此這兩種原生 GitHub 安裝方式均不需要執行此儲存庫的安裝程式即可運作。本機安裝程式在需要在三個 host 之間共用單一 canonical 複本時依然非常有用。

安裝完成後，Codex 通常會自動偵測 skill 變更。在 Claude Code 中，若頂層個人 skills 目錄是在 session 啟動後才建立，請重啟 session。在 Gemini CLI 中，請執行 `/skills reload`。若 host 仍未列出該 skill，請重啟該 session。

## 使用方式

`agent-collaboration` 依賴 tmux 提供之 `$TMUX_PANE` 環境變數來辨識與定位 session。**必須先進入 tmux session，在不同的 pane 內分別啟動每個 AI CLI，之後才在各自的 session 內執行 `agent-register`**。請勿在一般 terminal（非 tmux 環境）啟動 AI CLI 後才嘗試註冊。

### 步驟 1：建立 tmux session 並分割 pane

在你的 Git 專案根目錄下建立 session 並開啟多個 pane：

```sh
cd /path/to/your/git-repo

# 1. 建立新的 tmux session（例如命名為 agents）
tmux new-session -s agents

# 2. 分割出第二個 pane（水平或垂直分割）
tmux split-window -h

# 3. 在各 pane 間切換（快捷鍵 Ctrl-b o，或使用命令 tmux select-pane -t 0 / -t 1）
```

### 步驟 2：在各 pane 中分別啟動 AI CLI

- **Pane 0**（第一個 pane）：
  ```sh
  codex
  ```
- **Pane 1**（第二個 pane）：
  ```sh
  claude
  # 或使用 gemini
  ```

### 步驟 3：在各 AI session 中註冊

在各自的 AI CLI 互動提示列中，執行註冊命令：

```sh
SKILL_DIR="<你的 host 安裝 agent-collaboration 的目錄>"
"$SKILL_DIR/scripts/agent-register" codex
```

切換至另一個 pane 的 session 內執行：

```sh
SKILL_DIR="<你的 host 安裝 agent-collaboration 的目錄>"
"$SKILL_DIR/scripts/agent-register" claude
```

> **注意**：通常 agent 名稱即為其 CLI 名稱（如 `codex`、`claude`、`gemini`）。在同一個儲存庫中切勿將兩個活躍的 session 註冊為相同的名稱。

### 步驟 4：發送 prompt

在任一 session 內，透過 `agent-send` 向另一個已註冊的 agent 發送 prompt：

```sh
"$SKILL_DIR/scripts/agent-send" claude \
  '[from codex] Review the current diff. Reply with agent-send when done.'
```

註冊表與訊息交換位於當前 Git 根目錄底下的 `.agents/`。在首次註冊時，此工具會自動建立 `.agents/.gitignore`，因此即時的註冊表與訊息檔案預設會保留在本地端。

## 安全模型

`agent-send` 只會以明確為當前儲存庫註冊的 pane 為目標。它會將每筆項目與該 pane 的 shell PID 綁定、拒絕自我發送，並在遇到遺失或過期的 pane 時停止執行，而非猜測替代 pane。

本工具刻意對另一個互動式 agent session 執行 prompt injection。它**不提供身分驗證**：`[from claude]`、`[from codex]` 及類似標籤皆為自行宣告的純文字。任何以你的作業系統使用者身分執行且可控制 tmux 的行程，都可能操控已註冊的 pane。

接收端 agent 仍必須套用其正常的權限範圍（scope）、授權（permission）、沙盒（sandbox）與安全規則。請勿在你不信任內容的儲存庫中使用此工具。切勿將轉發的 prompt 視為身分證明或新的權限授予。

對於持久性命令授權（persistent command approvals）請格外謹慎。若對 `agent-send <target>` 前綴給予永久授權，發送端 agent 未來將可向該目標注入任意 prompt，而無需為發送操作再次取得授權。

Pane PID 檢查降低了已 commit 或過期之 registry 項目被濫用的風險，但它並不是身分驗證，且無法偵測在同一個 tmux pane 內重啟的 AI 行程。在重啟 agent 行程後，請務必重新註冊 session。

在貼上內容前，`agent-send` 會退出目標 pane 的 tmux copy-mode，以確保最後的 Enter 鍵能夠送達。這會改變目標 pane 的畫面檢視狀態。

## 已知限制

- 本工具是門鈴（doorbell），而非訊息代理（message broker）或協調器（orchestrator）。不提供送達回執、佇列、重試或身分驗證。
- 在貼上與 Enter 之間固定的 0.4 秒延遲，已在測試過的 macOS 環境中驗證適用於一般的簡短 prompt，但未針對極長訊息或慢速遠端終端進行驗證。請將實質內容寫入 `.agents/messages/` 並僅發送路徑。
- 註冊表查詢以儲存庫為範圍。請在同一個 Git 專案內執行相關工具。
- 同時執行的 agent 仍可能編輯相同的檔案；在要求 peer 進行修改前請先劃分職責範圍。

## 測試

```sh
./tests/run.sh
```

此測試套件使用 mock 的 `git` 與 `tmux` 執行檔，不會向實際的 live pane 輸入內容。

## 授權條款

MIT。詳見 [LICENSE](LICENSE)。

## 參考資料

- [OpenAI: Build skills](https://learn.chatgpt.com/docs/build-skills)
- [Claude Code: Extend Claude with skills](https://code.claude.com/docs/en/slash-commands)
- [Gemini CLI: Managing Agent Skills](https://github.com/google-gemini/gemini-cli/blob/main/docs/cli/using-agent-skills.md)
