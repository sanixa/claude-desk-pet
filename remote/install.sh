#!/bin/sh
# 把远端 Cursor 接上 Windows 的桌宠。在「远端机器」上跑一行就好：
#
#   curl -fsS http://127.0.0.1:47355/install | sh
#
# 前提是 Windows 那边桌宠在跑，而且 ssh 带了 RemoteForward（端口两边要一致）。
# Cursor Remote-SSH 吃 ~/.ssh/config，加完要重连一次远端窗口，隧道才会建起来。
set -eu

PORT=__PORT__
case "$PORT" in *PORT*) PORT=47355 ;; esac   # 直接从磁盘跑（没经过收集器替换）时的默认值
URL="http://127.0.0.1:$PORT"
DIR="$HOME/.cursor/desk-pet"
HOOKS="$HOME/.cursor/hooks.json"

command -v curl >/dev/null 2>&1 || { echo "远端没有 curl，装不了。"; exit 1; }

OUT=$(curl -sS -o /dev/null -w 'HTTP %{http_code}' --max-time 5 "$URL/" 2>&1) || true
if [ "$OUT" != "HTTP 200" ]; then
    echo "连不到 $URL（$OUT）——隧道不通，先修隧道再装。"
    echo
    if [ -x "$DIR/fix-tunnel.sh" ]; then
        echo "跑 $DIR/fix-tunnel.sh，它会判断是哪一种断法。"
    else
        case "$OUT" in
            *timed*out*|*Operation*)
                echo "卡到超时 = 有人在听这个端口但不回应。两种可能："
                echo "  ．上一条连线留下的残留 sshd（是你自己的 process，看得到 pid）→ 杀掉它："
                echo "      p=\$(ss -ltnp 2>/dev/null | grep \":$PORT \" | sed -n 's/.*pid=\([0-9]*\).*/\1/p' | head -1); kill \$p"
                echo "  ．看不到 pid = 这台机器上别人占着这个端口 → 换端口（Windows 的 ssh_config"
                echo "    和 start-pet.cmd 的 DESK_PET_PORT 一起改），别硬抢。"
                echo "  两种都要在之后重连这个远端窗口 —— 隧道只在连线那一刻建立。" ;;
            *)
                echo "在 Windows 的 ~/.ssh/config 这台 host 下面要有："
                echo "    RemoteForward $PORT 127.0.0.1:$PORT"
                echo "确认桌宠在跑（start-pet.cmd），重连一次这个远端窗口，再跑一次这行。" ;;
        esac
    fi
    exit 1
fi

PY=""
for c in python3 python; do
    if command -v "$c" >/dev/null 2>&1; then PY="$(command -v "$c")"; break; fi
done
[ -n "$PY" ] || { echo "远端找不到 python3，先装一个再来。"; exit 1; }

mkdir -p "$DIR/state"
curl -fsS --max-time 10 "$URL/cursor-pet.py" -o "$DIR/cursor-pet.py"
curl -fsS --max-time 10 "$URL/fix" -o "$DIR/fix-tunnel.sh"
chmod +x "$DIR/fix-tunnel.sh"
rm -f "$DIR/state/tunnel-down"
LABEL="${DESK_PET_PROJECT:-$(hostname -s 2>/dev/null || hostname)}"

# 包一层壳：hooks.json 里只写一个路径，env 在这里给，Cursor 怎么起这个命令都不会漏
cat > "$DIR/report.sh" <<SH
#!/bin/sh
export DESK_PET_URL="$URL/status"
export DESK_PET_PROJECT="$LABEL"
export DESK_PET_DIR="$DIR/state"
exec "$PY" -I "$DIR/cursor-pet.py"
SH
chmod +x "$DIR/report.sh"

if [ -f "$HOOKS" ] && ! grep -q desk-pet "$HOOKS"; then
    cp "$HOOKS" "$HOOKS.bak.$(date +%s)"
    echo "原本的 hooks.json 已备份成 $HOOKS.bak.*（内容没有合并，自己看一下要不要加回去）"
fi

mkdir -p "$HOME/.cursor"
cat > "$HOOKS" <<JSON
{
  "version": 1,
  "hooks": {
    "sessionStart": [{ "command": "$DIR/report.sh", "timeout": 10 }],
    "beforeSubmitPrompt": [{ "command": "$DIR/report.sh", "timeout": 10 }],
    "postToolUse": [{ "command": "$DIR/report.sh", "timeout": 10 }],
    "postToolUseFailure": [{ "command": "$DIR/report.sh", "timeout": 10 }],
    "afterFileEdit": [{ "command": "$DIR/report.sh", "timeout": 10 }],
    "afterShellExecution": [{ "command": "$DIR/report.sh", "timeout": 10 }],
    "stop": [{ "command": "$DIR/report.sh", "timeout": 10 }],
    "sessionEnd": [{ "command": "$DIR/report.sh", "timeout": 10 }]
  }
}
JSON

printf '{"hook_event_name":"sessionStart","conversation_id":"install-check"}' | "$DIR/report.sh" >/dev/null 2>&1 || true
sleep 1
printf '{"hook_event_name":"sessionEnd","conversation_id":"install-check"}' | "$DIR/report.sh" >/dev/null 2>&1 || true

echo "装好了：$DIR（端口 $PORT，气泡上会标 $LABEL）"
echo "刚才送了一次测试状态，Windows 桌宠应该闪了一下「我来啦～」。"
echo "隧道哪天又不通，跑 $DIR/fix-tunnel.sh，它会自己判断是哪种断法。"
echo "最后一步：Cursor 里 Reload Window（Ctrl+Shift+P → Developer: Reload Window），hooks 才会载入。"
