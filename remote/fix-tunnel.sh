#!/bin/sh
# 隧道不通的时候在远端跑这支。
#
# 断法有五种，处理方式完全不同：
#   a) curl 回 200              → 通的，不用修
#   b) 连线被拒 / Empty reply    → 隧道通了，Windows 那头没人接（桌宠没在跑）
#   c) 没有人在听这个端口        → 反向转送根本没建起来（ssh_config 没设，或连线时 bind 失败）
#   d) 超时，socket 是我的       → 上一条连线留下的残留：它还在听，对面的 ssh 已经没了，请求卡死
#   e) 超时，socket 是别人的     → 这台机器上别人占着这个端口，杀不了也不该杀，要换端口
#
# d) 最麻烦的地方是「找不到 pid」：ss -p 要读 /proc/<pid>/fd，而 Yama 的 ptrace_scope=1
# 只允许读自己子孙的，所以别条 session 里的 sshd 对不回 pid。
# 解法是走 ss -ltnpe 给的 cgroup：/user.slice/user-<UID>.slice/session-<N>.scope，
# 直接问 systemd 那条 session 是谁的、还在不在，再比对自己现在的 $XDG_SESSION_ID。
set -u

PORT=__PORT__
case "$PORT" in *PORT*) PORT=47355 ;; esac   # 直接从磁盘跑（没经过收集器替换）时的默认值
URL="http://127.0.0.1:$PORT"
ME=$(id -u)

sockline() { ss -ltnpe 2>/dev/null | grep ":$PORT "; }
listening() {
    [ -n "$(sockline)" ] && return 0
    netstat -ltn 2>/dev/null | grep -q ":$PORT " && return 0
    return 1
}
holder()  { ss -ltnp 2>/dev/null | grep ":$PORT " | sed -n 's/.*pid=\([0-9]*\).*/\1/p' | head -1; }
sock_uid() { sockline | sed -n 's/.*uid:\([0-9]*\).*/\1/p' | head -1; }
sock_session() { sockline | sed -n 's#.*session-\([0-9]*\)\.scope.*#\1#p' | head -1; }

OUT=$(curl --noproxy '*' -sS -o /dev/null -w 'HTTP %{http_code}' --max-time 3 "$URL/" 2>&1)
case "$OUT" in
    'HTTP 200') echo "隧道是通的（$OUT），不用修。"; exit 0 ;;
    *refused*|*reset*|*Empty*|*'closed connection'*)
        echo "$URL $OUT"
        echo "这是「隧道通了、Windows 那头没人接」—— 桌宠没在跑，这里不用动。"
        echo "去 Windows 跑：%USERPROFILE%\.claude\desk-pet\standalone\start-pet.cmd"
        exit 1 ;;
esac

if ! listening; then
    echo "没有人在听 127.0.0.1:$PORT —— 反向转送根本没建起来（$OUT）。"
    echo "去 Windows 确认 ~/.ssh/config 这台 host 下面有："
    echo "    RemoteForward $PORT 127.0.0.1:$PORT"
    echo "然后重连这个远端窗口。顺便看 Cursor 的 Remote - SSH.log 有没有"
    echo "「remote port forwarding failed for listen port $PORT」—— 有的话是端口被占。"
    exit 1
fi

echo "127.0.0.1:$PORT 有人在听，但没人回应（$OUT）。"
U=$(sock_uid)
if [ -n "$U" ] && [ "$U" != "$ME" ]; then
    NAME=$(getent passwd "$U" 2>/dev/null | cut -d: -f1)
    echo "这个 socket 是 uid=$U${NAME:+（$NAME）}的，不是你 —— 这台机器上别人占着这个端口。"
    echo "杀不了也不该杀，换一个端口："
    echo "  1. Windows: ~/.ssh/config 这台 host 的 RemoteForward 两个数字都改成新端口"
    echo "  2. Windows: start-pet.cmd 里的 DESK_PET_PORT 改成同一个，重启桌宠"
    echo "  3. 重连这个远端窗口，再跑 curl --noproxy '*' -fsS http://127.0.0.1:<新端口>/install | sh"
    echo "挑端口前先看一下这台有没有人用：ss -ltn | grep ':4735'"
    exit 1
fi

P=$(holder)
if [ -n "$P" ]; then
    NAME=$(ps -o comm= -p "$P" 2>/dev/null | tr -d ' ')
    echo "是 pid=$P（${NAME:-?}）。"
    if [ "$NAME" != "sshd" ]; then
        echo "不是 sshd，不敢乱杀。先自己看看这是什么：ps -fp $P"
        exit 1
    fi
    kill "$P" 2>/dev/null || true
    sleep 1
    listening && { kill -9 "$P" 2>/dev/null || true; sleep 1; }
else
    # 自己的 socket 却拿不到 pid：ptrace_scope 挡住了，改走 systemd 的 session
    YAMA=$(cat /proc/sys/kernel/yama/ptrace_scope 2>/dev/null || echo '?')
    S=$(sock_session)
    echo "是你自己的（uid=$ME），但 ss 对不回 pid（ptrace_scope=$YAMA 挡住 /proc/<pid>/fd）。"
    if [ -z "$S" ]; then
        echo "也拿不到 cgroup 资讯。手动看：ps -u $(id -un) -o pid,lstart,cmd | grep sshd"
        exit 1
    fi
    echo "它属于登入 session $S（你现在这个 shell 是 session ${XDG_SESSION_ID:-?}）。"
    loginctl show-session "$S" -p State -p Leader -p RemoteHost -p Timestamp 2>/dev/null | sed 's/^/    /'
    case "$(loginctl show-session "$S" -p State 2>/dev/null)" in
        *closing*) echo "    （State=closing：这条 session 正在收但卡住了 —— 典型的残骸）" ;;
    esac
    if [ "$S" = "${XDG_SESSION_ID:-}" ]; then
        echo
        echo "就是你现在这条 session —— 你的 Cursor remote server 还活在这条旧连线里，"
        echo "但真正建隧道的那条 ssh 已经死了。收掉它，你这个终端和远端窗口会一起断（本来就要重连）："
        echo "    loginctl terminate-session $S"
        echo "断掉之后重连远端窗口，端口就空出来了。"
        exit 1
    fi
    # 这条 session 的 sshd 在哪个 pid：/proc/<pid>/cgroup 读得到，不受 ptrace_scope 限制
    PIDS=$(for p in $(pgrep -u "$ME" sshd 2>/dev/null); do
               grep -qs "session-$S\.scope" "/proc/$p/cgroup" && echo "$p"
           done)
    if [ -z "$PIDS" ]; then
        echo "找不到那条 session 的 sshd。直接收掉整条 session："
        echo "    loginctl terminate-session $S"
        exit 1
    fi
    echo "判定是残留的 session，收掉它里面的 sshd："
    for p in $PIDS; do ps -o pid=,lstart=,cmd= -p "$p" 2>/dev/null; kill "$p" 2>/dev/null || true; done
    sleep 1
    if listening; then
        for p in $PIDS; do kill -9 "$p" 2>/dev/null || true; done
        sleep 1
    fi
fi

if listening; then
    echo "还是有人在听。再跑一次这支看看现在算哪一种；最后手段是 loginctl terminate-session <id>。"
    exit 1
fi
rm -f "$HOME/.cursor/desk-pet/state/tunnel-down"
echo "清掉了。最后一步：去 Cursor 重连这个远端窗口（Reload Window 不够，要重连），隧道才会重新建。"
