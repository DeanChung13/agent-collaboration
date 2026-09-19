# TODO

實際使用中遇到的問題，依影響程度排序。

## 1. SKILL.md 教的 pane 身分確認指令會回錯 pane（高）

`SKILL.md:125` 建議用這個指令確認自己是誰：

```sh
tmux display-message -p '#{pane_id}'
```

沒帶 `-t`，`display-message` 回的是**當前 session 的 active pane**，不是呼叫端所在的
pane。在 AI CLI 的非互動 shell（例如 Claude Code 的 Bash tool）裡跑，回來的是使用者
最後點過的那個 pane。

實測：我人在 `%6`，這個指令回 `%10`（另一個 agent 的 pane）。若照 SKILL.md 的指示
「身分不明時用這個比對 registry」，會判定自己註冊錯了，進而把自己重註冊到別人的
pane 上——訊息會全部灌進對方的 session。

`scripts/agent-register:17` 自己是用 `$TMUX_PANE` 的，做法正確；只有文件教錯。

修法：SKILL.md 改成 `echo "$TMUX_PANE"`，或 `tmux display-message -p -t "$TMUX_PANE" '#{pane_id}'`。

## 2. ~~`join` 不解析 flag，會把 `--help` 註冊成 agent 名字~~（已修）

> 已於「join 加上撞名守門與 `--force`」一併修正：`join` 分支改為完整解析選項，
> `-h|--help` 先攔截並印出用法，未知的 `-` 開頭參數直接報錯，都不會寫入 registry。
> 回歸測試：`agent-collab join parses options instead of registering them`。

原始記錄：

`scripts/agent-collab:92-99` 的 `join)` 分支只檢查參數個數，直接把 `$1` 當名字傳給
`agent-register`。`-h|--help` 的處理在 `:143`，位於主 case 的後面，輪不到。

實測：`agent-collab join --help` 輸出
`Registered --help -> %6 ...`，並在 registry 留下一筆 `--help` 的殭屍記錄。
`--help` 也通得過 `agent-register:12` 的名稱正規表達式（允許連字號）。

修法：`join` 分支先攔 `-h|--help`；或 `agent-register` 拒絕 `-` 開頭的名字。

## 3. 舊格式 registry 是死路，沒有復原路徑（中）

`scripts/agent-send:34-38`：registry 缺第四欄 `agent-pid` 就直接 exit 1，訊息是
「Re-run agent-register in that session.」

問題是這個指示對呼叫端不可行——要修的是**別人**的 pane，你人在自己的 pane 裡。
SKILL.md 又明文禁止自己掃 tmux 找替代 pane。於是唯一出路是手動編輯
`.agents/registry`，而這個做法文件裡完全沒寫。

實測：`gemini` 那筆是舊格式（`gemini %10 5500`，只有三欄），`agent-collab send` 和
低階 `scripts/agent-send` 都擋，最後是手動補上第四欄才送得出去。

修法（擇一）：
- `send` 遇到缺 `agent-pid` 時，降級成只驗 `pane-pid`（舊格式相容），或
- 提供 `agent-collab repair <name>` 從 pane 反查 agent pid 補寫，或
- 至少在錯誤訊息與 SKILL.md 寫明手改 registry 的欄位格式。

## 4. registry 名稱與實際 CLI 不做驗證（低）

registry 只記名字、pane、pid，不記也不查該 pane 跑的是哪個 CLI。

實測：`gemini` 那筆指向 `%10`，但該 pane 實際跑的是 `agy`（pid 6000）。
`agent-collab send gemini` 照樣回 `Sent to gemini (%10)`，訊息進了 agy 的 session，
兩邊都不會發現送錯對象。

修法：`add`/`run` 註冊時一併寫入 CLI 名稱，`send` 時比對 `#{pane_current_command}`，
不符就警告。
