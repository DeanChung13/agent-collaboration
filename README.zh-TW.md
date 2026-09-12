# agent-collaboration

讓同一個 Git 儲存庫中各自獨立的 AI CLI session 能夠透過 tmux 互相提問、委派有邊界的任務，並回傳結果。

此 Skill 適用於 macOS 與 Linux 上的 Codex、Claude Code 以及 Gemini CLI。它使用檔案系統來傳遞大量 context，並以 tmux prompt injection 作為已在執行中之 session 之間的輕量級「門鈴（doorbell）」。

## 系統需求

- macOS 或 Linux
- Bash 3.2 或更新版本
- Git
- 支援 Bracketed Paste 的 tmux（`paste-buffer -p`）
- 兩個或更多在同一個 Git 儲存庫的 tmux pane 中執行的 AI CLI session

### 安裝 tmux

- **macOS**（Homebrew）：
  ```sh
  brew install tmux
  ```
- **Ubuntu / Debian**（APT）：
  ```sh
  sudo apt update
  sudo apt install -y tmux
  ```
- **驗證安裝**：
  ```sh
  tmux -V
  ```

本腳本目前已在 macOS（tmux 3.7b、Bash 3.2.57）上完成驗證。專案隨附的 GitHub Actions workflow 設定會在發布後於 macOS 與 Ubuntu 上執行可攜性測試套件。在這些 CI 任務通過前，Linux 與其他 tmux 版本仍屬未驗證狀態；除腳本所使用的命令需求外，未聲明其他最低 tmux 版本需求。

## 安裝

Clone 此儲存庫，然後執行：

```sh
./install.sh
```

安裝程式會將執行期的 skill 複製到 `~/.local/share/agent-skills/agent-collaboration`（或 `$XDG_DATA_HOME`），並建立以下連結：

- `~/.local/bin/agent-collab`：統一 CLI 入口（或 `$XDG_BIN_HOME/agent-collab`）
- `~/.agents/skills/agent-collaboration`：供支援 shared alias 的 host 使用
- `$CODEX_HOME/skills/agent-collaboration`：供 Codex 使用（預設為 `~/.codex/skills`）
- `~/.claude/skills/agent-collaboration`：供 Claude Code 使用
- `~/.gemini/skills/agent-collaboration`：供 Gemini CLI 與 Antigravity 使用

若目前 shell 的 `$PATH` 未包含所選 bin 目錄，安裝程式會提出警告，並顯示應加入 shell profile 的確切 export 指令。只有使用者在終端機直接呼叫 `agent-collab` 時需要這個 PATH；AI host 會從已載入的 `SKILL.md` 解析 bundled CLI，因此不會因 host 保留舊的 PATH 快照而找不到指令或選到不同安裝。

在開發時可使用 `./install.sh --link` 直接連結到你的 clone 目錄。安裝程式預設拒絕替換既有路徑；使用 `--force` 會直接覆蓋衝突的既有安裝。

若要從較新的 clone 更新 copy 模式的安裝，請執行 `./install.sh --force` 直接覆蓋為最新版。

Gemini CLI 亦支援直接安裝已發布的儲存庫：

```sh
gemini skills install https://github.com/DeanChung13/agent-collaboration
```

針對 Codex，你可以要求 `$skill-installer` 安裝已發布的 GitHub 儲存庫。它會安裝至 `$CODEX_HOME/skills`（預設為 `~/.codex/skills`）。本 Skill 會從自身載入的 `SKILL.md` 路徑解析隨附的腳本，因此這兩種原生 GitHub 安裝方式均不需要執行此儲存庫的安裝程式即可運作。本機安裝程式在需要在三個 host 之間共用單一 canonical 複本時依然非常有用。

安裝完成後，Codex 通常會自動偵測 skill 變更。在 Claude Code 中，若頂層個人 skills 目錄是在 session 啟動後才建立，請重啟 session。在 Gemini CLI 中，請執行 `/skills reload`。若 host 仍未列出該 skill，請重啟該 session。

## 使用方式

`agent-collaboration` 使用 tmux 承載協作 session。只要先在 tmux 裡啟動主要 AI，接著直接用自然語言請它新增協作者；skill 會自行建立並管理其他 pane。

### 快速開始

1. 在你的 Git 專案根目錄下建立 tmux session：

```sh
cd /path/to/your/git-repo
tmux new-session -s agents
```

2. 在第一個 pane 啟動主要 AI，例如：

```sh
codex
```

3. 直接請 AI 新增協作者：

```text
新增協作 claude
```

想確認目前有哪些協作者，直接問：

```text
目前有哪些 AI 在協作？
```

4. 直接用自然語言交辦：

```text
請 Claude review 目前的 diff
```

> **注意**：AI host 應一律透過 `SKILL_DIR` 呼叫 bundled CLI，不依賴 `$PATH`：
> ```sh
> SKILL_DIR="<你的 host 安裝 agent-collaboration 的目錄>"
> AGENT_COLLAB="$SKILL_DIR/scripts/agent-collab"
> "$AGENT_COLLAB" add claude
> ```

### 統一 CLI：agent-collab

`agent-collab` 提供單一入口處理所有協作操作：

- `agent-collab add <agent-name>`：建立新的 tmux pane、啟動指定 AI，並確認完成註冊；正常情況由 skill 自行呼叫。
- `agent-collab run <agent-name>`：在新 pane 內註冊並啟動 AI，讓 registry 項目跟隨 AI 程序的生命週期。
- `agent-collab join <agent-name>`：只註冊目前 pane，不啟動 AI；保留給手動設定與向下相容用途。
- `agent-collab list`：列出仍存活的協作 agent，並以原子操作移除 AI 程序已結束或 pane 身分已改變的項目。
- `agent-collab send <agent-name> <message>`：將 prompt 直接投遞至目標 agent pane。

底層原始腳本（`agent-register`、`agent-send`）與別名 `agent-join` 依然保留，以提供向下相容性。

## 安全模型

`agent-send`（與 `agent-collab send`）只會以明確為當前儲存庫註冊的 pane 為目標。它會將每筆項目同時綁定至 pane 的 shell PID 與 AI 程序 PID、拒絕自我發送，並在遇到遺失或過期的 pane／程序時停止執行，而非猜測替代目標。

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
