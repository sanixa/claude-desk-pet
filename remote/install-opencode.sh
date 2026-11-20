#!/bin/sh
# 把远端 opencode 接上 Windows 的桌宠。在「远端机器」上跑一行：
#
#   curl -fsS http://127.0.0.1:47355/install-opencode | sh
#
# 前提跟 Cursor 那边一样：桌宠在跑、专属隧道通着（Host desk-pet-remote）。
set -eu

PORT=__PORT__
case "$PORT" in *PORT*) PORT=47355 ;; esac   # 直接从磁盘跑（没经过收集器替换）时的默认值
URL="http://127.0.0.1:$PORT"
CFG="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
DIR="$CFG/plugins"
LABEL="${DESK_PET_PROJECT:-}"

command -v curl >/dev/null 2>&1 || { echo "远端没有 curl，装不了。"; exit 1; }

OUT=$(curl -sS -o /dev/null -w 'HTTP %{http_code}' --max-time 5 "$URL/" 2>&1) || true
if [ "$OUT" != "HTTP 200" ]; then
    echo "连不到 $URL（$OUT）——隧道不通，先修隧道再装。"
    if [ -x "$HOME/.cursor/desk-pet/fix-tunnel.sh" ]; then
        echo "跑 $HOME/.cursor/desk-pet/fix-tunnel.sh，它会判断是哪一种断法。"
    else
        echo "去 Windows 确认桌宠在跑（start-pet.cmd），隧道看守有没有连上（tunnel.log）。"
    fi
    exit 1
fi

if ! command -v opencode >/dev/null 2>&1; then
    echo "⚠ PATH 上找不到 opencode。还是照装到 $DIR —— 如果你的 opencode 用的是别的"
    echo "  设定目录（XDG_CONFIG_HOME），自己把 desk-pet.js 搬过去就行。"
fi

mkdir -p "$DIR"
curl -fsS --max-time 10 "$URL/opencode-pet.js" -o "$DIR/desk-pet.js"

# 试一发，确认「远端 → 隧道 → 收集器」这条路是通的（不靠 opencode，先把管路验掉）
post() { curl -sS --max-time 5 -X POST "$URL/status" -H 'Content-Type: application/json' --data-raw "$1" >/dev/null 2>&1 || true; }
HOST_LABEL="${LABEL:-$(hostname -s 2>/dev/null || hostname)}"
post "{\"source\":\"opencode\",\"id\":\"install-check\",\"state\":\"waiting\",\"text\":\"我来啦～\",\"project\":\"$HOST_LABEL\"}"
sleep 1
post "{\"source\":\"opencode\",\"id\":\"install-check\",\"gone\":true}"

echo "装好了：$DIR/desk-pet.js（埠 $PORT）"
echo "刚才送了一次测试状态，Windows 桌宠应该闪了一下「我来啦～」。"
echo "最后一步：重开 opencode —— plugin 只在启动时载入。"
echo
echo "对不上的时候看 $CFG/desk-pet.log："
echo "  ．「挂上了」那行     = plugin 真的被载入了"
echo "  ．「第一次看到事件 X」= 这版 opencode 有而我们没处理的事件，照着补对应"
echo "  ．「回报失败」        = 隧道断了，跑 fix-tunnel.sh"
