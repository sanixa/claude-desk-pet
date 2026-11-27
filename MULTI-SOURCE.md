# 多來源桌寵（multi-source）

從 `claude-desk-pet` plugin 的 `pet.pyw` fork 出來（MIT，見 LICENSE），改成**一隻桌寵接收多個 agent 的狀態**。
完全獨立於 plugin 安裝目錄：plugin 更新、重裝、停用都不影響這份。

> 要打的指令在 **[RUNBOOK.md](RUNBOOK.md)**（安裝、檢查、故障對照、換埠、拆掉）。
> 這份講的是為什麼這樣設計、以及踩過哪些坑。

```
pet/pet-multi.pyw           懸浮窗本體（多來源版）+ 遠端狀態收集器
pet/sprites/*.png           立繪（沿用 plugin 那份）
sounds/*.wav                提示音（同上）
adapters/cursor-pet.py      Cursor hook → 狀態檔（本機寫檔；遠端改成 POST）
tunnel/tunnel.pyw           反向隧道看守（專屬 ssh 連線，不搭別人的便車）
remote/install.sh           遠端 Cursor 的裝機腳本（由收集器自己發給遠端）
remote/fix-tunnel.sh        遠端修隧道
remote/opencode-pet.js      遠端 opencode 的 plugin
remote/install-opencode.sh  遠端 opencode 的裝機腳本
remote/claude-watch.py      遠端盯著 Claude SSH 工作階段的狀態檔
remote/install-claude-ssh.sh  上面那支的裝機腳本
start-pet.cmd               啟動桌寵 + 隧道看守；**每台機器的設定都在這支裡**
autostart.vbs               開機自動啟動用（跑 start-pet.cmd 且不閃黑窗）
check.ps1                   一鍵健檢
RUNBOOK.md                  要打什麼指令看這份
```

原本的 plugin（`pet/pet.pyw`、`hooks/`）原封不動留著，這份是放在旁邊的另一隻。
`start-pet.cmd` 是唯一需要按機器改的檔：python 路徑、收集器的埠、ssh 的 host 別名都在裡面。

## 狀態協定

任何 agent 只要把一個 JSON 檔寫到 `~/.claude/desk-pet/sessions/` 就會出現在桌寵上：

```json
{
  "source": "cursor",
  "state": "tool",
  "text": "在改 loader.py",
  "project": "seven",
  "ts": 1795140927014,
  "sound": "done"
}
```

- `state`：`thinking` / `tool` / `reading` / `waiting` / `celebrate` / `error` / `aborted` / `stone`（其他值會被當 `waiting`）
- `source`：`claude` / `cursor` / `opencode`。省略時按檔名前綴判斷（`cursor-*.json`、`opencode-*.json`），都對不上就當 `claude`——官方 plugin 寫的檔名就是會話 id，所以它不用改任何東西。
- `sound`：`done` / `error` / 省略。
- 檔名建議 `<source>-<會話id>.json`；同一個來源可以有多個會話同時存在。
- 寫檔請「先寫 `.tmp` 再 rename」，桌寵才不會讀到半截 JSON。
- 會話結束就把檔案刪掉；沒刪也沒關係，超過 30 分鐘沒更新就不再上鏡，兩天後自動清掉。

**寫不到這台硬碟的（遠端機器）走 HTTP**：桌寵在 `127.0.0.1:47355`（`DESK_PET_PORT` 可換）開了個收集器，
`POST /status` 一包同樣欄位的 JSON（多一個 `id`，就是會話 id）就會被寫成 `sessions/<source>-<id>.json`；
`{"source":"cursor","id":"...","gone":true}` 等於刪檔。`ts` 一律用 Windows 本機時間蓋掉，遠端時鐘跑掉也不會排錯順序。

對面是遠端機器，所以每個欄位都當不可信：`source` 必須在白名單裡（`claude`/`cursor`/`opencode`），
`id` 過濾成安全檔名（跑不出 `sessions/`），`state` 不認識就當 `waiting`，台詞截到 120 字，body 上限 16KB，
不合格一律 400。只聽 127.0.0.1，所以能寫進來的只有「隧道那頭的那台機器」。收到什麼、拒掉什麼都記在
`~/.claude/desk-pet/collector.log`。

## 顯示規則

- 同時有多個來源在跑時，**氣泡前面會標來源**（`Cursor · 在改 loader.py`）；同一個來源有多個會話時標成 `Cursor/seven`。
- 鏡頭給誰：某個來源剛進入「要你看一下」的狀態（`waiting`/`celebrate`/`error`/`aborted`/`stone`）時，先給它 12 秒；否則顯示最近有動作的那個。所以「某端叫你」不會被另一端的忙碌狀態蓋掉，12 秒後又會回到正在幹活的那個。
- 提示音至少間隔 1.2 秒，三端同時收工不會疊三聲。
- 右鍵菜單多了「只看來源」，可以只盯 Claude 或只盯 Cursor。
- 「退出桌宠」會留下 `~/.claude/desk-pet/off`，排程式的自動啟動看到它就不叫了（手動跑 `start-pet.cmd` 會清掉）。退出時順手把隧道看守一起收掉。
- 單例鎖佔用 **127.0.0.1:47321**，跟官方桌寵同一個埠：這隻先起來，plugin 自己那隻就起不來；官方那隻已經在跑的話會被自動收掉（只認命令行有 `pet.pyw` 又不是 `pet-multi` 的 python 行程）。
- Claude 和 Cursor 都沒在跑、又沒有任何來源還在發狀態，兩分鐘後桌寵**退場**（收起視窗，行程留著）。
  任何一端有動靜就立刻回來；只是開了 app 沒下指令的話最多等 30 秒。
  刻意不退出行程：開機自動啟動時登入當下通常還沒開 agent，真的退出就再也回不來了。

## 啟動

```
<這個 repo 的目錄>\start-pet.cmd
```

用的是 `%USERPROFILE%\anaconda3\pythonw.exe`。**別用 PATH 上的 `python`**：那是 Microsoft Store 的 stub，跑起來直接 exit 49——這也是官方 plugin 的桌寵一直沒出現的原因（`~/.claude/desk-pet/mod-launch.log` 裡的 `exit=49`）。

要開機自動啟動，把 `start-pet.cmd` 的捷徑丟進 `shell:startup`。

## Cursor 接法（已完成）

`~/.cursor/hooks.json` 把八個事件都指到 `adapters/cursor-pet.py`：

| Cursor 事件 | 桌寵 |
|---|---|
| `sessionStart` | `waiting` 我来啦～ |
| `beforeSubmitPrompt` | `thinking` 思考中… |
| `postToolUse` | 按 tool_name 判斷 `tool`/`reading` |
| `afterFileEdit` | `tool` 在改 `<檔名>` |
| `afterShellExecution` | `tool` 在跑命令… |
| `postToolUseFailure` | `error`，連三次 → `stone` |
| `stop` | `waiting` 轮到你啦！+ 叮咚 |
| `sessionEnd` | 刪掉狀態檔 |

注意事項：

- **刻意避開所有 permission hook**（`preToolUse`、`beforeShellExecution`、`beforeMCPExecution`、`beforeReadFile`、`beforeTabFileRead`、`subagentStart`）。那幾個如果輸出不合格式會直接 block agent，不值得為了提早 0.5 秒換表情去冒險。
- adapter 不管發生什麼都 `print("{}")` 並 exit 0，壞 JSON、空 stdin、怪 id 都測過（`conversation_id` 會做字元過濾，不會跑出 `sessions/` 以外）。
- stdin 一定自己按 UTF-8 解碼：腳本用 `-I` 跑，不然會按 cp950 解，中文路徑直接 parse 失敗。
- 每個 hook 約 0.15–0.2 秒（Python 啟動），`timeout` 設 10 秒。實測一次正常回合的 adapter 本體是 2–10ms
  （見 `cursor-hook.log`）；只有「關視窗」那條路徑上的 `sessionEnd` 量到 5.4 秒，那是 Cursor 自己的 shell 服務正在收掉。
- 改完 `hooks.json` 要重開 Cursor（Reload Window）。user 層級的 hooks 在 Cursor 的 cloud agent 裡不會跑。
- **Remote-SSH 視窗的 hooks 是在遠端跑的**，Cursor 去讀的是遠端的 `~/.cursor/hooks.json`，Windows 這份它不看
  （log 會寫 `User config path: \home\<user>\.cursor\hooks.json` → `No user hooks configuration found`）。接法見下一節。

## 遠端接法（Cursor Remote-SSH，opencode 也走同一條）

```
遠端 Cursor hook → cursor-pet.py（DESK_PET_URL）→ POST 遠端的 127.0.0.1:47355
                 → ssh RemoteForward（專屬連線）→ Windows 的 127.0.0.1:47355 → sessions/cursor-<id>.json
```

目前用的埠是 **47355**。要換埠就改兩個地方：`start-pet.cmd` 的 `DESK_PET_PORT`、
`Host desk-pet-remote` 的 `RemoteForward`。看守程式開場會比對這兩個數字，不一致會寫進 `tunnel.log`。

1. **Windows**：隧道走自己的一條 ssh（`Host desk-pet-remote`），由 `tunnel/tunnel.pyw` 看著，
   `start-pet.cmd` 會一起起來——細節見下一節。
   **Cursor 用的那塊（`Host <REMOTE-IP>`）刻意不設 `RemoteForward`**：
   Cursor 對同一台會開好幾條連線、reload 就全換，讓它綁埠就會一直互搶（再下一節有實錄）。
   它對我們的埠本來毫無興趣，是 `RemoteForward` 把它請來的。
2. **遠端**：在遠端的終端跑一行，裝機腳本和 adapter 都是桌寵自己從同一個埠發過去的：

   ```sh
   curl -fsS http://127.0.0.1:47355/install | sh
   ```

   它會把 adapter 和 `fix-tunnel.sh` 放到 `~/.cursor/desk-pet/`，包一層 `report.sh`
   （env 寫在裡面，Cursor 怎麼起都不會漏），寫好遠端的 `~/.cursor/hooks.json`
   （原本有的話先備份成 `.bak.<時間>`，**不會自動合併**），再送一次測試狀態。
   隧道不通的時候它會直接告訴你是哪一種斷法。最後在 Cursor 裡 Reload Window。
   **換埠之後要重跑這行**：`report.sh` 裡的 URL 是裝機當時寫死的。
3. 氣泡上的名字預設取遠端的 `hostname`，所以同時有本機和遠端 Cursor 時會長成
   `Cursor/<HOSTNAME>`、`Cursor/seven` 這樣分得出來。要自己取名就
   `DESK_PET_PROJECT=xxx sh -c "$(curl -fsS http://127.0.0.1:47355/install)"`。

### 專屬隧道（治根，建議用這個）

搭 Cursor 便車的毛病是**每次 Reload Window 都要修一次**：reload 換連線，換連線就重新搶埠，
搶不到就靜靜失敗（上面那段時間軸）。所以讓隧道有自己的一條 ssh：

```
tunnel/tunnel.pyw  →  ssh -N desk-pet-remote  →  常駐，Cursor 怎麼 reload 都不碰它
```

`~/.ssh/config` 要有這兩塊（名字自己取，`start-pet.cmd` 裡填同一個）：

```
# 隧道本體。埠號兩個數字要跟 start-pet.cmd 的 DESK_PET_PORT 一致
Host desk-pet-remote
    HostName <REMOTE-IP>
    User <USER>
    IdentityFile ~/.ssh/desk-pet-tunnel
    IdentitiesOnly yes
    BatchMode yes
    ExitOnForwardFailure yes
    ServerAliveInterval 20
    ServerAliveCountMax 3
    RemoteForward 127.0.0.1:47355 127.0.0.1:47355

# 同一把金鑰的另一個用途：請遠端清掉占著埠的殘骸。
# 這條一定不能帶 RemoteForward —— 埠被占著時 ExitOnForwardFailure 會讓它連指令都還沒跑就退出。
Host desk-pet-remote-fix
    HostName <REMOTE-IP>
    User <USER>
    IdentityFile ~/.ssh/desk-pet-tunnel
    IdentitiesOnly yes
    BatchMode yes
    ClearAllForwardings yes
    RequestTTY no
    ServerAliveInterval 20
    ServerAliveCountMax 3

# 養著遠端 claude-watch.py 的那條（RUNBOOK 3.5）。內容跟 -fix 一樣，只有名字不同：
# 看守是用別名去連的（HOST + '-watch'），少了這塊，ssh 會把名字當主機名去解析然後失敗。
Host desk-pet-remote-watch
    HostName <REMOTE-IP>
    User <USER>
    IdentityFile ~/.ssh/desk-pet-tunnel
    IdentitiesOnly yes
    BatchMode yes
    ClearAllForwardings yes
    RequestTTY no
    ServerAliveInterval 20
    ServerAliveCountMax 3
```

**Cursor（或其他工具）連同一台的那塊設定，不要加 `RemoteForward`。** 它們對同一台會開好幾條
連線、reload 就全換，讓它們綁埠就會跟我們互搶——我們這條是常駐的，讓它獨佔就好。

- `~/.ssh/config` 的 `Host desk-pet-remote` 放所有設定，看守程式只負責「斷了就重連」。
- `ExitOnForwardFailure yes` 是關鍵：埠被占著就立刻退出，看守 8 秒後再搶——**埠一空出來就是我們的**。
  Cursor 只在連線那一刻試一次，我們每 8 秒試一次，長期一定是我們贏。
- **搶不到就請遠端自己清**：連續 8 次拿不到埠（約一分鐘），看守會用 `desk-pet-remote-fix`
  這條連線請遠端跑 `fix-tunnel.sh`，清完下一輪就搶回來；兩次之間至少隔 5 分鐘。
  關機時砍掉的 ssh 常在遠端留下殘骸，所以這段主要是為了「開機後不用人管」。
  那條別名**刻意不帶 `RemoteForward`**——埠被占著時 `ExitOnForwardFailure` 會讓它連指令都還沒跑就退出。
- 金鑰 `~/.ssh/desk-pet-tunnel` 在遠端 `authorized_keys` 裡帶
  `restrict,port-forwarding,command="…/fix-tunnel.sh"`：能做的只有「轉送那個埠」和「跑那支修隧道的腳本」，
  **開不了 shell、沒有 pty、跑不了別的指令**。所以它沒有 passphrase 也還算安全。
  `-N` 的隧道不開 session channel，所以 `command=` 不會干擾轉送。
  要再緊一點可以加 `permitlisten="127.0.0.1:47355"`，但如果加了之後 `tunnel.log` 出現
  `administratively prohibited`，就是 bind address 對不上，拿掉即可。
- **`ssh` 只在啟動時讀一次設定檔。** 改了埠而不重拉連線，那條 ssh 會繼續守著舊埠：
  兩頭對不上、桌寵靜靜沒反應，而 `ssh` 行程看起來好得很（`ps` 只告訴你它活著，不告訴你它綁的是什麼）。
  查的時候要比對**行程啟動時間和 `~/.ssh/config` 的改動時間**，誰先誰後決定它拿的是哪份設定。
  看守程式現在每 5 秒看一次 config 的 mtime，改了就自己重拉。
- 看守程式自己認得三種結果：登不進去（試三次就收手，不會一直敲門）、埠被占（快速重搶，
  第二次會把清殘骸的指令印進日誌）、連線掉了（隔一下重連）。接上超過三秒也會報一行。
  開場還會比對 `ssh_config` 的 `RemoteForward` 和 `DESK_PET_PORT`，數字不一樣就警告——
  換埠只改一邊是最容易犯的錯。全部寫在 `~/.claude/desk-pet/tunnel.log`。

授權的那一行（在遠端跑一次就好，不用密碼——你在遠端視窗的終端本來就是登入狀態）：

```sh
mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo 'restrict,port-forwarding ssh-ed25519 AAAA...<你自己的公鑰> desk-pet-tunnel (forward only)' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
```

同一行也存在 Windows 的 `~/.ssh/desk-pet-tunnel.authorized`。授權完重跑 `start-pet.cmd` 就接手了
（已完成：`Host <REMOTE-IP>` 的 `RemoteForward` 也拿掉了，Cursor 不會再來搶）。

### 多台遠端：一台一支看守

在第二台上跑 `curl 127.0.0.1:47355` 連不上，是因為那個回路是它自己的，而隧道只通到第一台。
要多接一台就得多一條 ssh——**不能共用**，因為「這條連線活著」正是隧道通不通的唯一證據
（`ExitOnForwardFailure=yes`），一條連線沒辦法同時替兩台作證。

所以看守變成一台一支。本來卡住這件事的是單例鎖：`LOCK_PORT` 寫死 47320，
第二支會以為「已經有人在看了」然後**安靜退出**——這是最糟的失敗方式，畫面上什麼都看不出來。
現在鎖端口由 `DESK_PET_LOCK` 指定（`start-pet.cmd` 裡一台一個），而且搶不到鎖會寫進日誌。

兩台共用一個收集器埠是安全的：各自的 `RemoteForward` 綁的是**自己那台**的 127.0.0.1:47355，
同名但不同機器，轉進來之後都落到 Windows 這一個收集器。狀態檔的 id 是 conversation uuid，
不會撞；氣泡上的名字取遠端 hostname，所以兩台的工作階段分得出來。

日誌還是同一個 `tunnel.log`，每行前面加了 `[remote]`／`[remote2]`（別名去掉 `desk-pet-` 的那段）。
輪替也從 `os.remove` 改成 `os.replace(… .old)`：兩支看守寫同一個檔，直接刪會把另一支剛寫的行一起帶走。

金鑰沒授權的那台，看守試三次就收手並留下 `tunnel-unauth-<標籤>` 記號，三十分鐘內不再試——
排程每十分鐘叫一次，不然光是這台就會把別台的日誌刷掉。手動跑 `start-pet.cmd` 會清掉記號立刻重試。

### 隧道不通的時候

在遠端跑 `~/.cursor/desk-pet/fix-tunnel.sh`，它會自己判斷是哪一種斷法：

| 症狀 | 意思 | 怎麼辦 |
|---|---|---|
| `curl` 回 200 | 通的 | 不用修，去看 `cursor-hook.log` |
| 逾時，socket 是**我的** | 殘留的 sshd | 殺掉它，看守 8 秒內自己接手（不用重連視窗） |
| 逾時，socket 是**別人的** | 這台機器上別人占著這個埠 | **換埠**（見下面），別硬搶 |
| 連線被拒 / Empty reply | 隧道通了，Windows 那頭沒人接 | 在 Windows 跑 `start-pet.cmd` |
| 沒人在聽 | 反向轉送沒建起來 | 查 ssh_config，重連視窗 |

是誰的要看 `ss -ltnpe` 的 `uid:`（不用 root），**不能看有沒有 pid**：`ss -p` 要讀 `/proc/<pid>/fd`，
而 Yama 的 `ptrace_scope=1`（很多發行版的預設）只准讀自己子孫的，所以別條 session 裡的 sshd
就算是自己的也對不回 pid。這時候走 `ss -ltnpe` 給的 cgroup
（`/user.slice/user-<UID>.slice/session-2927.scope`）去問 systemd：

```sh
loginctl show-session 2927 -p State -p Leader -p RemoteHost   # 那條是什麼（State=closing 就是殘骸）
echo $XDG_SESSION_ID                                          # 自己現在這條
# 只殺那條 session 的 sshd —— 埠會放掉，scope 裡別的東西（卡住的 bash、你的工作）不動
for p in $(pgrep -u $(id -u) sshd); do grep -qs 'session-2927.scope' /proc/$p/cgroup && kill $p; done
loginctl terminate-session 2927                               # 連 sshd 都找不到時的鈍刀
```

共用機器上優先用上面那條 `for` —— `terminate-session` 會把整個 scope 裡的東西一起帶走，
萬一那條 session 裡還有別的終端在跑東西就虧了。

如果 `$XDG_SESSION_ID` 就是它，表示 Cursor 的 remote server 還活在那條舊連線裡（server 斷線後會留著），
而真正建隧道的 ssh 已經死了——同一個指令照用，只是終端和遠端視窗會一起斷，重連即可。
`fix-tunnel.sh` 這整套判斷都包好了。

**換埠**：`start-pet.cmd` 裡的 `DESK_PET_PORT` 和 `~/.ssh/config` 的 `RemoteForward` 改成同一個新埠，
重啟桌寵、重連遠端視窗，再跑一次裝機那行。發給遠端的腳本裡的埠號是收集器即時替換的（`__PORT__`），
所以遠端不用手改任何東西。

**最容易踩的是第二種，而且它是結構性的。** Cursor 對同一台遠端會開**好幾條** ssh 連線
（主連線、終端、轉送各自一條，重連時又換新的），每一條都照 ssh_config 試著綁同一個埠：
誰先到誰擁有，其他的 bind 失敗。只要擁有者活著就一切正常，壞在擁有者死得不乾淨的時候。
實際抓到的一次長這樣：

```
14:25     連線 A → 綁到 47322，狀態正常送達
14:26:01  連線 B（主連線）→ bind 失敗：A 還占著
14:26:32  連線 C → A 放掉了，C 綁到手
之後      C 的 ssh 死了，sshd 和一個卡住的 bash 還在（session State=closing）→ 埠鎖住，全部逾時
```

ssh 的反向轉送是「連線的那一刻」才在遠端 bind 端口；前一條連線如果沒好好收掉
（視窗 reload、網路跳一下），它的 sshd 會繼續聽著那個埠，而新連線那次 bind 就失敗了——
ssh 預設 `ExitOnForwardFailure no`，所以它只警告一聲就照常連上，視窗看起來一切正常，
但所有 POST 都掉進那個沒人接的黑洞裡卡到逾時。證據在 Cursor 自己的 log：

```
%APPDATA%\Cursor\logs\<run>\window*\exthost\anysphere.remote-ssh\Remote - SSH.log
    Warning: remote port forwarding failed for listen port 47322
```

遠端的 adapter 對這件事有防身術：POST 逾時上限 1.2 秒，失敗一次就寫 `state/tunnel-down`
並且 60 秒內不再試（否則每個 hook 都要等 1.2 秒，Cursor 會變頓），一通就馬上恢復。
所以隧道壞掉的代價是「桌寵不動」，不會變成「Cursor 變慢」。

查的順序：遠端 `curl http://127.0.0.1:47355/`（通的話回 `{"ok": true, "pet": "alive"}`）
→ 遠端 `~/.cursor/desk-pet/state/cursor-hook.log` → Windows 的 `collector.log`。
遠端 sshd 如果設了 `AllowTcpForwarding no`，隧道永遠建不起來，那就得改走下面的備案。

備案（不用改 ssh 設定、遠端零依賴）：遠端只 append 一行 JSON 到 `~/.cursor/desk-pet/bus.ndjson`，
Windows 這邊開 `ssh host "tail -f ..."` 子行程讀回來。

**代理環境變數會把 127.0.0.1 也劫走。** 公司機器的 `.bashrc` 常設 `http_proxy`，
而 `curl` 和 python 的 `urllib` 都會照著走——隧道明明是通的，手打的指令卻回「連不上」，
但 Cursor 的 hook 又照樣進得來（hook 不是互動 shell，不讀 `.bashrc`）。
這個差異很容易把人帶去查隧道。對「隧道這端的 127.0.0.1」來說代理永遠不可能是對的，
所以遠端腳本的每個 `curl` 都帶 `--noproxy '*'`，兩支 python 改用 `ProxyHandler({})` 的 opener。

## Claude 的 SSH 工作階段（已完成）

這一格是最後補上的，而且成因最不直覺：**官方 plugin 在 SSH 工作階段裡，把狀態寫到了遠端的硬碟**。

```ts
const home = ((await $.env.get('USERPROFILE')) ?? (await $.env.get('HOME')) ?? '')
runDir = `${home}/.claude/desk-pet`
await $.fs.write(petFile, ...)
```

`$.env` 和 `$.fs` 都是**工作階段範圍**的：SSH 模式下 `USERPROFILE` 不存在，落到 `HOME` 拿到
`/home/<帳號>`，`$.fs.write` 寫的也是遠端的檔案系統。所以狀態檔好端端地躺在遠端，本機桌寵完全看不到——
從本機看起來就是「Claude 在動，桌寵沒反應」，而且日誌一片正常，因為每一層都沒壞。

做法是在遠端放一支 `claude-watch.py` 盯著那個目錄，有變動就 POST 回收集器（跟 Cursor、opencode 同一條隧道）。
它的常駐方式值得一提：**不裝 systemd、不碰登入 shell**，而是當成那把金鑰的第二個動詞，
由 Windows 這邊的看守拉一條連線養著。連線斷了看守會重連；watcher 這端則靠 **stdin EOF** 判斷
「ssh 沒了該收攤」——這一條是刻意設計的，否則遠端會慢慢堆出一地孤兒行程（這個坑我們在隧道上踩過一次了）。

一把金鑰兩個動詞靠 `dispatch.sh`：`command=` 強制指令指到它，它只認 `fix` 和 `watch`，
其他一律當 `fix`。所以那把金鑰能做的事還是只有「轉送那個埠」「修隧道」「送狀態」三件，開不了 shell。

## opencode 接法（已完成）

遠端 opencode 走同一條隧道，只是改用 plugin：

```sh
curl -fsS http://127.0.0.1:47355/install-opencode | sh
```

裝到 `~/.config/opencode/plugins/desk-pet.js`（那個目錄裡的 `.ts`/`.js` 會被直接載入，
**目錄名是複數 `plugins`**；專案層級是 `.opencode/plugins/`）。裝完要**重開 opencode**，plugin 只在啟動時載入。

| opencode | 桌寵 |
|---|---|
| `chat.message` hook | `thinking` 思考中… |
| `tool.execute.before` | 按工具名判斷 `tool`/`reading`（跟 Cursor 同一套台詞） |
| `tool.execute.after` | `thinking` 思考中… |
| `session.status` busy / idle / retry | `thinking` / `waiting` 轮到你啦！/ `error` 重试中… |
| `session.idle` | `waiting` 轮到你啦！+ 叮咚 |
| `session.error` | `error`，連三次 → `stone` |
| `session.compacted` | `thinking` 在整理上下文… |
| `file.edited` | `tool` 在改 `<檔名>` |
| `permission.updated` | `waiting` 等你同意…+ 叮咚 |
| `session.deleted` / `dispose` | 清掉狀態 |

三條規矩，順序就是重要性：

1. **絕不丟異常出去**——每個 hook 都包 `try/catch`。桌寵再怎麼壞都不能把 agent 的回合搞斷。
2. **絕不 `await` 回報**——`fetch` 射出去就不管了。否則隧道斷掉時每個事件都要等 1.2 秒逾時。
3. **斷了就歇 60 秒**——跟 Cursor 那支一樣的斷路器。

其他細節：

- 同狀態 1.5 秒內連發只送一次（`session.status` busy 會連發）。
- `file.edited` 沒有 `sessionID`，算在最近有動作的那個 session 頭上。
- 檔案被當成兩個 plugin 載入（具名 + default 兩個 export）時只接一次，不會重複回報。
- **對應表會過時。** API 來源是 `@opencode-ai/plugin` 的 `index.d.ts`（`Hooks`）和
  `@opencode-ai/sdk` 1.19.6 的 `types.gen.d.ts`（`Event` 的 32 個 type 字面值）。
  版本不同時，沒處理到的事件會記進 `~/.config/opencode/desk-pet.log`，**每種只記第一次**，
  照著補 `switch` 就好。那個 log 也是查「plugin 到底有沒有被載入」最快的地方：
  第一行會是「挂上了：POST …」。
- `message.part.updated` 這類一秒好幾次的事件刻意不處理，不然桌寵會瘋狂抖動。

## 已知限制

- Token / 快取命中率狀態欄是 Claude Code 引擎專屬（`$.ui.status` + `$.session.usage()`），Cursor 和 opencode 沒有對應介面，不會統一。
- 氣泡台詞沿用原作的簡體文案，所以 Cursor adapter 也刻意用同樣字串，免得同一個氣泡裡簡繁混排。
