# 桌寵操作手冊

安裝、檢查、修。設計理由和踩過的坑在 [MULTI-SOURCE.md](MULTI-SOURCE.md)，這份只講「要打什麼」。

> 文件裡的 `<安裝目錄>` 就是這個 repo 放的位置，`<REMOTE-IP>`、`<USER>`、`<HOSTNAME>`
> 換成你自己的。所有 Windows 路徑都假設 clone 在 `%USERPROFILE%\.claude\desk-pet` 底下，
> 放別的地方也行，`start-pet.cmd` 和捷徑會自己用相對路徑找隔壁的檔案。

**每段指令都標了在哪裡跑。** `powershell` 的在 Windows 這台，`sh` 的要貼到**遠端機器的終端**
（遠端 Cursor 視窗的終端就是遠端的）。貼錯地方只會失敗，不會壞事，但會白查半天。

---

## 0. 先跑健檢

```powershell
powershell -ExecutionPolicy Bypass -File <安裝目錄>\check.ps1
```

一口氣把 Windows 這頭該看的都看完。正常長這樣：

```
[OK]  收集器               127.0.0.1:47355  {"ok": true, "pet": "alive"}
[OK]  桌宠                pid=40400  起于 15:42:10
[OK]  看守 remote          pid=42800  起于 15:10:21
[OK]  隧道 remote          pid=47368  撑了 1741 秒（ExitOnForwardFailure=yes，活着就代表远端绑成功）
[OK]  埠号 remote          ssh_config 转送 47355  /  收集器 47355
[OK]  看守 remote2         pid=42036  起于 15:10:21
[OK]  隧道 remote2         pid=47401  撑了 1735 秒（同上）
[OK]  埠号 remote2         ssh_config 转送 47355  /  收集器 47355

--- 现在上镜的来源 ---
  cursor    远端    <HOSTNAME>    轮到你啦！   214 秒前
  claude    本机    seven          在跑命令…     3 秒前
```

「隧道」那幾行的判斷依據：ssh 帶 `ExitOnForwardFailure=yes`，**綁不到埠就會立刻死**，
所以它活著就代表那台遠端的 listener 真的建起來了。看守、隧道、埠號都是**一台一組**，
後面的標籤就是 `tunnel.log` 裡的 `[remote]`、`[remote2]`。

---

## 1. 現在的佈局

| 在哪 | 跑什麼 | 位置 |
|---|---|---|
| Windows | 桌寵 + 收集器（**47355**） | `pet\pet-multi.pyw` |
| Windows | 隧道看守 | `tunnel\tunnel.pyw`，**一台遠端一支**（第一台鎖 47320、第二台鎖 47319） |
| Windows | 隧道本體 | `ssh -N desk-pet-remote`、`ssh -N desk-pet-remote2` |
| Windows | 本機 Cursor 的 hook | `~\.cursor\hooks.json` → `adapters\cursor-pet.py` |
| 遠端 | Cursor 的 hook | `~/.cursor/hooks.json` → `~/.cursor/desk-pet/report.sh` |
| 遠端 | opencode 的 plugin | `~/.config/opencode/plugins/desk-pet.js` |
| 遠端 | Claude SSH 工作階段的監看 | `~/.claude/desk-pet/bin/claude-watch.py`（由看守養著） |
| Windows | 開機自動啟動 | `Startup\Desk Pet.lnk` → `autostart.vbs` |

佔用的埠：**47355** 收集器（每台遠端的 127.0.0.1:47355 都轉到這一個）、47321 桌寵單例鎖、
47320／47319 兩支看守的鎖（**一支一個，不能共用**）。

日誌都在 `~\.claude\desk-pet\`：

| 檔 | 看什麼 |
|---|---|
| `collector.log` | 遠端送進來的每一筆，和被拒的原因 |
| `tunnel.log` | 隧道接上／斷掉／埠被占 |
| `cursor-hook.log` | 本機 Cursor 的 hook 有沒有進來（遠端的那份在遠端） |
| `pet-error.log` | 桌寵自己炸了才會有 |

---

## 2. 啟動與停止

```powershell
<安裝目錄>\start-pet.cmd
```

一次帶起桌寵和隧道看守，兩個都已經在跑的話不會開第二隻，所以隨時可以重跑。

停掉：

```powershell
Get-CimInstance Win32_Process -Filter "Name='pythonw.exe'" | Where-Object { $_.CommandLine -like '*pet-multi*' -or $_.CommandLine -like '*tunnel.pyw*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
```

### 開機自動啟動

登入時會自動跑起來，靠這兩個東西：

```
捷徑  %APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\Desk Pet.lnk
  └─ wscript.exe "<安裝目錄>\autostart.vbs"
       └─ start-pet.cmd（視窗隱藏，不閃黑窗）
```

走 `autostart.vbs` 而不是直接放 `start-pet.cmd` 的捷徑，是為了**不閃黑窗**（`Run(…, 0, False)`
的 0 就是隱藏視窗）。設定沒有被複製一份——埠號和 python 路徑仍然只寫在 `start-pet.cmd` 裡。

要停掉自動啟動：刪掉那個捷徑就好（`explorer shell:startup` 可以打開那個資料夾）。

> **別從 Claude／Cursor 的工作階段裡啟動它。** 那樣起來的行程是那個 app 的子孫，
> app 一重啟（自動更新最常見）整棵樹跟著走，桌寵、看守、隧道一起消失，而且日誌上看不出來——
> 因為沒有人出錯，只是被收掉了。2026-11-25 就這樣：app 凌晨 04:37 更新重啟，三個行程一起沒了。
>
> 手動起而且要脫離目前這個工作階段，讓 explorer 去開那個捷徑：
>
> ```powershell
> explorer.exe "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup\Desk Pet.lnk"
> ```
>
> 這樣行程的父親是 explorer（或直接變孤兒），誰重啟都不會波及。
> 可以用 `check.ps1` 確認：行程還在就對了。

> **捷徑只在「登入」時觸發。** 中途被收掉（app 重啟、被 EDR 收走、當掉）不會自己回來，
> 而且你如果好幾天沒登出，它就一直沒有補位的機會。要它自己長回來就加一個排程工作：
>
> ```powershell
> schtasks /create /tn DeskPet /tr "wscript.exe <安裝目錄>\autostart.vbs" /sc minute /mo 10 /f
> ```
>
> 每 10 分鐘叫一次 `start-pet.cmd`，已經在跑就什麼都不會發生（單例鎖）。
> 要拆掉：`schtasks /delete /tn DeskPet /f`。

### 「退出桌寵」和排程怎麼共存

排程會補位，但**不該跟你的決定作對**。所以右鍵選單的「退出桌宠」會留一個記號
`~/.claude/desk-pet/off`，三邊約定如下：

| 誰 | 怎麼跑 | 看到 `off` 記號時 |
|---|---|---|
| 排程／登入捷徑 | `start-pet.cmd auto` | 什麼都不做 |
| 你自己 | `start-pet.cmd`（不帶參數） | 刪掉記號，照常啟動 |
| 退出選單 | — | 寫下記號，並把看守和它的 ssh 一起收掉 |

所以「退出」是退到你自己再開為止；而意外掛掉（沒有記號）十分鐘內會自己長回來。
`check.ps1` 看得出差別：被人關掉時會多一行「手动关掉了」。

退出時連看守一起收，是因為「說要退出卻留著一條連到公司機器的 ssh」更奇怪。

> **登入後桌寵會先不見，這是正常的。** Claude 和 Cursor 都沒在跑時，桌寵兩分鐘後會**退場**
> ——收起視窗，但行程留著。你一開 agent 它就回來（有人發狀態立刻回來，只是開了 app 沒下指令
> 最多等 30 秒）。想確認它還活著就跑 `check.ps1`，或看 127.0.0.1:47355 有沒有回應。

> **別用 PATH 上的 `python`。** 那是 Microsoft Store 的 stub，跑起來直接 exit 49，什麼都不說。
> 所有腳本都寫死 `%USERPROFILE%\anaconda3\pythonw.exe`。

---

## 3. 安裝

### 3.1 遠端 opencode

在**遠端終端**：

```sh
curl --noproxy '*' -fsS http://127.0.0.1:47355/install-opencode | sh
```

裝到 `~/.config/opencode/plugins/desk-pet.js`，然後**重開 opencode**——plugin 只在啟動時載入。

腳本會先用 curl 直接送一筆測試狀態，所以就算 plugin 沒載入，你也先知道管路通不通。
之後看 `~/.config/opencode/desk-pet.log`：

- 第一行「挂上了：POST …」= plugin 真的被載入了
- 「第一次看到事件 X」= 這版 opencode 有、而我們沒處理的事件（每種只記第一次）
- 「回报失败」= 隧道斷了，跳到第 5 節

### 3.2 遠端 Cursor

在**遠端終端**：

```sh
curl --noproxy '*' -fsS http://127.0.0.1:47355/install | sh
```

裝 `~/.cursor/desk-pet/{cursor-pet.py, report.sh, fix-tunnel.sh}` 並寫 `~/.cursor/hooks.json`
（原本有的話先備份成 `.bak.<時間>`，**不會自動合併**）。裝完 Reload Window。

**換埠之後一定要重跑這行**：`report.sh` 裡的 URL 是裝機當時寫死的。

### 3.3 本機 Cursor

`~\.cursor\hooks.json` 八個事件都指到 `adapters\cursor-pet.py`。
改完 `hooks.json` 要 Reload Window。這份不經過隧道，直接寫檔案。

### 3.4 隧道金鑰

Windows 產金鑰（已經有 `~\.ssh\desk-pet-tunnel` 就跳過）：

```powershell
ssh-keygen -t ed25519 -N '""' -f $env:USERPROFILE\.ssh\desk-pet-tunnel -C "desk-pet-tunnel (forward only)"
```

授權是**一台一次**（每台遠端的 `authorized_keys` 各自獨立）。在**遠端終端**貼，不用密碼，
你在那邊本來就是登入狀態。完整那行存在 Windows 的 `~\.ssh\desk-pet-tunnel.authorized`：

```sh
mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo '<貼 desk-pet-tunnel.authorized 的內容>' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
```

**已經裝過舊版（沒有 `command=` 那段）的話，改這一行就好**，在遠端跑：

```sh
sed -i 's|^restrict,port-forwarding |restrict,port-forwarding,command="/home/<USER>/.cursor/desk-pet/fix-tunnel.sh" |' ~/.ssh/authorized_keys && grep -c 'fix-tunnel' ~/.ssh/authorized_keys
```

印出 `1` 就對了（重複跑不會壞，第二次匹配不到）。

這把金鑰能做的事只有兩件：

- **轉送那個埠**——`restrict` 關掉所有東西，`port-forwarding` 只開回轉送這一項。
- **跑 `fix-tunnel.sh`**——`command=` 是強制指令：不管連線時送什麼過去，sshd 都只跑這支腳本。

開不了 shell、沒有 pty、跑不了別的指令，所以沒有 passphrase 也還算安全。
`-N` 的隧道不開 session channel，完全不受 `command=` 影響，兩件事互不干擾。

---

### 3.5 Claude 的 SSH 工作階段

Claude Code 連 SSH 的時候，官方 plugin 把狀態寫到**遠端**的家目錄（`$.env`／`$.fs` 都是工作階段範圍的：
`USERPROFILE` 在 Linux 上不存在，落到 `HOME` 就變成遠端的路徑）。本機桌寵看不到，所以要有人在遠端盯著。

在**遠端終端**：

```sh
curl --noproxy '*' -fsS http://127.0.0.1:47355/install-claude-ssh | sh
```

它會先**驗一件事**：`~/.claude/desk-pet/sessions/` 裡到底有沒有 Claude 的狀態檔。
沒有的話就不是「寫到遠端」而是「plugin 在 SSH 工作階段根本沒載入」，腳本會直接說並退出——別白裝。

裝好之後：

- `~/.claude/desk-pet/bin/claude-watch.py`：每 0.5 秒看一次那個目錄，有變動就 POST 回收集器。
  啟動時只認五分鐘內動過的（不把上禮拜的狀態叫醒），檔案消失就送 `gone`。
  **stdin 一斷（ssh 死了）就自己退出**，不會在遠端留下孤兒。
- `~/.claude/desk-pet/bin/dispatch.sh`：那把金鑰的強制指令改指到這裡，**一把金鑰兩個動詞**——
  `fix` 跑 `fix-tunnel.sh`、`watch` 跑 watcher，其他一律當 `fix`。還是開不了 shell、跑不了別的指令。
- Windows 這邊：重跑 `start-pet.cmd`，看守會多拉一條 `desk-pet-remote-watch` 的連線把 watcher 養著，
  斷了自動重連。`tunnel.log` 裡開頭是「遠端 watcher」的行就是它說的話。

沒裝的時候看守會講：連三次收到的都不是 watcher 的開場白，就印出該跑的那行裝機指令然後停手
（因為那把金鑰的強制指令還指著 `fix-tunnel.sh`，`watch` 會被當成 `fix`）。

---

### 3.6 再加一台遠端

三件事，缺一件就只會看到「看守活著、隧道沒起來」：

1. **`~\.ssh\config`**：抄 `desk-pet-remote` 那三塊（本體／`-fix`／`-watch`），改名字和 `HostName`。
   `RemoteForward` 兩個數字都保持 47355——那是**對方那台的** 127.0.0.1，各自獨立，不會互相搶。
2. **`start-pet.cmd`**：抄那一對兩行，`DESK_PET_LOCK` 換一個沒人用的（現在用了 47320、47319）。
   **這步最容易漏**：兩台共用一個鎖的話，第二支看守會起不來，而且畫面上什麼都看不出來——
   只有 `tunnel.log` 會說「鎖 47320 有人占著」。
3. **那台的 `authorized_keys`**：照 3.4 貼一次。沒授權的話看守會試三次就收手
   （`tunnel.log` 裡 `Permission denied`），並留下 `tunnel-unauth-<標籤>` 記號：
   排程再怎麼叫，它也要等三十分鐘才再試一次——不然每十分鐘刷八行，會把別台的歷史輪替掉。
   **所以授權完就自己跑一次 `start-pet.cmd`**：手動啟動會把記號清掉，立刻重試。

裝機腳本（3.1／3.2／3.5）也是**一台一次**，在哪台跑就裝在哪台。
`tunnel.log` 每行開頭的 `[remote]`、`[remote2]` 就是哪一台在說話。

---

## 4. 檢查（由近到遠，一層一層）

**第一層，Windows**（`check.ps1` 已經包含）：

```powershell
Invoke-WebRequest http://127.0.0.1:47355/ -UseBasicParsing | Select-Object -ExpandProperty Content
```

通了回 `{"ok": true, "pet": "alive"}`。不通就是桌寵沒在跑。

**第二層，隧道**：

```powershell
Get-Content $env:USERPROFILE\.claude\desk-pet\tunnel.log -Tail 5 -Encoding UTF8
```

「隧道接上了」= 好的。「端口被占着」= 跳到第 5 節。沒有新行而 ssh 行程活著 = 正常（接上之後就安靜）。

**第三層，遠端看得到 Windows 嗎**（在**遠端終端**）：

```sh
curl --noproxy '*' -fsS http://127.0.0.1:47355/ && echo
```

通了回 `{"ok": true, "pet": "alive"}`。這一行是整套最有價值的檢查：它同時驗了隧道和收集器。

**第四層，遠端的 agent 有沒有在報**（在**遠端終端**）：

```sh
tail -5 ~/.cursor/desk-pet/state/cursor-hook.log; tail -5 ~/.config/opencode/desk-pet.log
```

**第五層，桌寵收到了嗎**：

```powershell
Get-Content $env:USERPROFILE\.claude\desk-pet\collector.log -Tail 10 -Encoding UTF8
```

---

## 5. 故障對照

| 症狀 | 多半是 | 怎麼辦 |
|---|---|---|
| 桌寵整隻沒出現 | 沒啟動，或用到 Store 的 python | `start-pet.cmd`；看 `pet-error.log` |
| 本來好好的，突然整組不見 | 從 agent 的工作階段裡起的，app 重啟時被一起收掉 | 用 explorer 開捷徑重起（見第 2 節） |
| 本機 Cursor 沒反應 | hook 沒載入 | 看 `cursor-hook.log` 有沒有新行；Reload Window |
| 遠端完全沒反應 | 隧道斷了 | 看 `tunnel.log`；一分鐘後看守會自己請遠端清 |
| 遠端 curl 逾時 | 殘留的 sshd 占著埠 | 等看守自己清，或遠端跑 `fix-tunnel.sh` |
| 遠端 curl 被拒 | 隧道通、桌寵沒開 | Windows 跑 `start-pet.cmd` |
| 遠端 curl 說連不上／連不到代理 | 那個 shell 的 rc 設了 `http_proxy`，curl 把 127.0.0.1 也丟給代理 | 指令加 `--noproxy '*'`（第 3 節的指令都帶了） |
| Claude 的 SSH 工作階段沒上鏡 | 狀態寫在遠端，沒人送回來 | 遠端裝 3.5 的 watcher |
| 狀態停在舊的不動 | 那端掛了沒送 `gone` | 30 分鐘後自動退場，或直接砍 `sessions\*.json` |
| 看守活著、隧道一直沒起來 | 那台還沒授權金鑰（`tunnel.log` 會有 `Permission denied`） | 照 3.4 在那台貼一次，再跑 `start-pet.cmd` |
| 少一支看守，而且沒聲沒息 | 兩台用到同一個鎖端口 | `tunnel.log` 找「鎖 … 有人占著」；改 `start-pet.cmd` 的 `DESK_PET_LOCK` |
| 改了設定卻沒效果 | **ssh 只在啟動時讀設定** | 砍掉 `ssh -N` 行程，看守會用新設定重拉 |
| 開機後隧道一直搶不到 | 上次關機時留下的殘骸還占著埠 | 遠端跑 `fix-tunnel.sh`；看守會在 8 秒內接手 |

**開機後那一段會自己處理掉。** 關機時 Windows 直接砍掉 ssh，遠端的 sshd 有時候不會立刻放掉埠，
所以登入後 `tunnel.log` 可能先刷一陣「端口被占着」。看守連搶 8 次（約一分鐘）還拿不到，
就會用 `desk-pet-remote-fix` 這條連線請遠端跑 `fix-tunnel.sh` 把殘骸清掉，然後下一輪自己抢回来；
兩次之間至少隔 5 分鐘，不會一直騷擾遠端。日誌長這樣：

```
16:16:43  连抢 8 次都失败，请远端自己清残骸…
16:16:45    远端：127.0.0.1:47355 有人在听，但没人回应：HTTP 000
16:16:46    远端：清掉了。最后一步：去 Cursor 重连这个远端窗口…
16:16:51  隧道接上了，守着 desk-pet-remote
```

（那句「去 Cursor 重连」是 `fix-tunnel.sh` 給人看的，對我們不適用——看守 8 秒內就自己搶回來了。）

要是日誌寫「远端没吭声」，就是遠端的 `authorized_keys` 還沒加 `command=` 那段，看 3.4 節。

`fix-tunnel.sh` 會把五種斷法分開判：通的／Windows 沒人接／沒人在聽／自己的殘留 sshd／
別人占著埠，並且印出證據（socket 的 uid、cgroup 的 session、`State=closing`）。
它清掉殘留之後**不需要重連視窗**——看守 8 秒內會自己把埠搶回來。

---

## 6. 換埠

兩個地方必須同時改，看守開場會比對，不一致會寫進 `tunnel.log`。

1. `start-pet.cmd` 裡的 `set DESK_PET_PORT=47355`
2. `~\.ssh\config` 裡**每一塊** `Host desk-pet-*` 的 `RemoteForward 127.0.0.1:47355 127.0.0.1:47355`（兩個數字都要）

然後：

```powershell
Get-CimInstance Win32_Process -Filter "Name='ssh.exe'" | Where-Object { $_.CommandLine -like '*desk-pet-*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
<安裝目錄>\start-pet.cmd
```

最後在**遠端**重跑 3.1 和 3.2 的裝機指令（它們把埠寫死在 `report.sh` 裡）。
發給遠端的腳本裡的埠號是收集器即時替換的，所以遠端不用手改任何東西。

> `Host <REMOTE-IP>`（Cursor 用的那塊）**刻意不設 `RemoteForward`**。
> Cursor 對同一台會開好幾條連線、reload 就全換，讓它綁埠就會一直互搶。

---

## 7. 拆掉

Windows：停掉行程（第 2 節）、刪 `~\.cursor\hooks.json`、刪 `~\.ssh\config` 裡
`Host desk-pet-*` 每一塊、刪 `~\.ssh\desk-pet-tunnel*`。

遠端：

```sh
rm -rf ~/.cursor/desk-pet ~/.cursor/hooks.json ~/.config/opencode/plugins/desk-pet.js
sed -i '/desk-pet-tunnel/d' ~/.ssh/authorized_keys
```

整套程式就是這個目錄，刪掉就乾淨了；
官方 plugin 那隻桌寵不受影響（它自己在 plugin 安裝目錄裡）。
