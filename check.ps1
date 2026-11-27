# 桌宠健检：一口气把 Windows 这头该看的都看一遍。
# 跑法：powershell -ExecutionPolicy Bypass -File "...\standalone\check.ps1"
$ErrorActionPreference = 'SilentlyContinue'
$RUN = Join-Path $env:USERPROFILE '.claude\desk-pet'
$HERE = Split-Path -Parent $MyInvocation.MyCommand.Path

function Line($name, $ok, $note) {
    $mark = if ($ok -eq $true) { '[OK]  ' } elseif ($ok -eq $false) { '[!!]  ' } else { '[--]  ' }
    '{0}{1,-18}{2}' -f $mark, $name, $note
}

# 收集器用哪个埠：以 start-pet.cmd 里的 DESK_PET_PORT 为准
$port = 47322
$cmd = Join-Path $HERE 'start-pet.cmd'
if (Test-Path $cmd) {
    $m = Select-String -Path $cmd -Pattern 'set DESK_PET_PORT=(\d+)'
    if ($m) { $port = [int]$m.Matches[0].Groups[1].Value }
}

# 看守和隧道都是「一台远端一支」。host 别名只写在 start-pet.cmd 里，这里捞出来用，
# 省得两边各记一份、改了一边忘了另一边。
$hosts = @()
if (Test-Path $cmd) {
    $hosts = ([regex]'tunnel\.pyw"\s+(\S+)').Matches((Get-Content $cmd -Raw)) |
             ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique
}
if (-not $hosts) { $hosts = @('desk-pet-remote') }

''
'=== 桌宠健检 ' + (Get-Date -Format 'MM-dd HH:mm:ss') + ' ==='
''

# 1. 收集器
$alive = $false
try {
    $r = Invoke-WebRequest -Uri "http://127.0.0.1:$port/" -TimeoutSec 3 -UseBasicParsing
    $alive = ($r.StatusCode -eq 200)
    Line '收集器' $alive "127.0.0.1:$port  $($r.Content)"
} catch {
    Line '收集器' $false "127.0.0.1:$port 没人接 —— 跑 start-pet.cmd"
}

# 2. 三个行程
$pet = Get-CimInstance Win32_Process -Filter "Name='pythonw.exe'" | Where-Object { $_.CommandLine -like '*pet-multi*' }
Line '桌宠' ($null -ne $pet) $(if ($pet) { "pid=$($pet.ProcessId)  起于 $($pet.CreationDate.ToString('HH:mm:ss'))" } else { '没在跑' })

$dogs = Get-CimInstance Win32_Process -Filter "Name='pythonw.exe'" | Where-Object { $_.CommandLine -like '*tunnel.pyw*' }
$sshs = Get-CimInstance Win32_Process -Filter "Name='ssh.exe'" | Where-Object { $_.CommandLine -like '*desk-pet-*' }
foreach ($h in $hosts) {
    $tag = $h -replace '^desk-pet-', ''
    $d = $dogs | Where-Object { $_.CommandLine -like "*$h*" } | Select-Object -First 1
    Line "看守 $tag" ($null -ne $d) $(if ($d) { "pid=$($d.ProcessId)  起于 $($d.CreationDate.ToString('HH:mm:ss'))" } else { '没在跑（这台没有远端来源的话可以不开）' })
    $t = $sshs | Where-Object { $_.CommandLine -match "-N\s+$h$" } | Select-Object -First 1
    if ($t) {
        $up = [int]((Get-Date) - $t.CreationDate).TotalSeconds
        Line "隧道 $tag" $true "pid=$($t.ProcessId)  撑了 $up 秒（ExitOnForwardFailure=yes，活着就代表远端绑成功）"
    } else {
        Line "隧道 $tag" $false '没有 ssh -N —— 看 tunnel.log 这台的那几行'
    }
    $w = $sshs | Where-Object { $_.CommandLine -like "*$h-watch*" } | Select-Object -First 1
    if ($w) { Line "远端 watcher $tag" $true "pid=$($w.ProcessId)  Claude 的 SSH 工作阶段有人盯着" }
    # 埠号两边要一致：换埠只改一边是最容易犯的错
    $fwd = (& ssh -G $h 2>$null | Select-String '^remoteforward') -replace '.*?:(\d+)\s.*', '$1'
    if ($fwd) {
        Line "埠号 $tag" ("$fwd" -eq "$port") "ssh_config 转送 $fwd  /  收集器 $port"
    } else {
        Line "埠号 $tag" $null "ssh_config 里没有 Host $h"
    }
}

# 2.5 开机自动启动
$lnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'Desk Pet.lnk'
Line '开机自动启动' (Test-Path $lnk) $(if (Test-Path $lnk) { "已设定  $lnk" } else { '没设定（手动跑 start-pet.cmd）' })

# 2.6 是不是被人自己关掉的（排程工作会尊重这个记号）
$off = Join-Path $RUN 'off'
if (Test-Path $off) {
    Line '手动关掉了' $false "$(Get-Content $off -Raw -ErrorAction SilentlyContinue) 关的；排程不会叫它，跑 start-pet.cmd 就会回来"
}

# 4. 日志
foreach ($log in 'tunnel.log', 'collector.log', 'cursor-hook.log') {
    $p = Join-Path $RUN $log
    if (Test-Path $p) {
        $last = Get-Content $p -Tail 1 -Encoding UTF8
        $age = [int]((Get-Date) - (Get-Item $p).LastWriteTime).TotalMinutes
        Line $log $null "$age 分钟前： $last"
    } else {
        Line $log $null '还没有'
    }
}

# 5. 现在谁在桌宠上
''
'--- 现在上镜的来源（超过 30 分钟没更新就不参与显示）---'
$found = $false
Get-ChildItem (Join-Path $RUN 'sessions\*.json') | Sort-Object LastWriteTime | ForEach-Object {
    $found = $true
    $d = Get-Content $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    $age = [int]((Get-Date) - $_.LastWriteTime).TotalSeconds
    $src = if ($d.source) { $d.source } else { 'claude' }
    $where = if ($d.remote) { '远端' } else { '本机' }
    '  {0,-9} {1,-5} {2,-14} {3,-20} {4} 秒前' -f $src, $where, $d.project, $d.text, $age
}
if (-not $found) { '  （没有任何来源在发状态）' }

''
'--- 远端那头要自己看（在远端的终端跑）---'
"  curl --noproxy '*' -fsS http://127.0.0.1:$port/            # 通的话回 {`"ok`": true, `"pet`": `"alive`"}"
'  ~/.cursor/desk-pet/fix-tunnel.sh             # 隧道不通时，它会判断是哪一种断法'
'  tail -5 ~/.cursor/desk-pet/state/cursor-hook.log   # 远端 Cursor 的 hook 有没有进来'
'  tail -5 ~/.config/opencode/desk-pet.log            # 远端 opencode 的 plugin 有没有挂上'
''
