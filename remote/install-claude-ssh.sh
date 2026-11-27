#!/bin/sh
# 把「Claude Code 的 SSH 工作阶段」接上桌宠。在远端机器上跑：
#
#   curl --noproxy '*' -fsS http://127.0.0.1:47355/install-claude-ssh | sh
#
# 它顺便会验一个假设：官方 plugin 在 SSH 工作阶段里，到底有没有把状态写到这台的家目录。
# 没有的话这整套就没有意义，脚本会直接告诉你并退出。
set -eu

PORT=__PORT__
case "$PORT" in *PORT*) PORT=47355 ;; esac
URL="http://127.0.0.1:$PORT"
DIR="$HOME/.claude/desk-pet/bin"
SESSIONS="$HOME/.claude/desk-pet/sessions"
AK="$HOME/.ssh/authorized_keys"
FIX="$HOME/.cursor/desk-pet/fix-tunnel.sh"

command -v curl >/dev/null 2>&1 || { echo "远端没有 curl，装不了。"; exit 1; }

OUT=$(curl --noproxy '*' -sS -o /dev/null -w 'HTTP %{http_code}' --max-time 5 "$URL/" 2>&1) || true
if [ "$OUT" != "HTTP 200" ]; then
    echo "连不到 $URL（$OUT）——隧道不通，先修隧道再装。"
    [ -x "$FIX" ] && echo "跑 $FIX，它会判断是哪一种断法。"
    exit 1
fi

echo "--- 先验假设：plugin 有没有在这台写状态 ---"
if [ ! -d "$SESSIONS" ]; then
    echo "  $SESSIONS 不存在。"
    echo
    echo "  => 那就不是「写到远端了」，而是 plugin 在 SSH 工作阶段里根本没载入。"
    echo "     装这套没有用。先在这台开一次 Claude Code 的 SSH 工作阶段、让它跑个指令，"
    echo "     再回来跑一次这行；如果还是没有这个目录，那条路就是走不通的。"
    exit 1
fi
ls -la "$SESSIONS" | sed 's/^/    /'
COUNT=$(ls -1 "$SESSIONS" 2>/dev/null | grep '\.json$' | grep -cv -e '^cursor-' -e '^opencode-' || true)
echo "    其中属于 Claude 的：$COUNT 个"
if [ "$COUNT" -eq 0 ]; then
    echo
    echo "  => 目录在、但一个 Claude 状态档都没有。同上：先跑一次 SSH 工作阶段再来。"
    exit 1
fi

PY=""
for c in python3 python; do
    if command -v "$c" >/dev/null 2>&1; then PY="$(command -v "$c")"; break; fi
done
[ -n "$PY" ] || { echo "远端找不到 python3，先装一个再来。"; exit 1; }

mkdir -p "$DIR"
curl --noproxy '*' -fsS --max-time 10 "$URL/claude-watch.py" -o "$DIR/claude-watch.py"
chmod +x "$DIR/claude-watch.py"

# 强制指令的分派：一把金钥、两个动词，其它一律当 fix
cat > "$DIR/dispatch.sh" <<SH
#!/bin/sh
# 桌宠那把金钥的强制指令。连线送什么过来都只会落到这两条路之一，开不了 shell。
case "\${SSH_ORIGINAL_COMMAND:-}" in
    watch)
        exec "$PY" "$DIR/claude-watch.py" ;;
    *)
        if [ -x "$FIX" ]; then exec "$FIX"; fi
        echo "没有 $FIX —— 先跑 Cursor 那支装机脚本。"; exit 1 ;;
esac
SH
chmod +x "$DIR/dispatch.sh"

echo
echo "--- 改 authorized_keys 的强制指令 ---"
if [ ! -f "$AK" ] || ! grep -q 'desk-pet-tunnel' "$AK"; then
    echo "  找不到 desk-pet-tunnel 那一行，先把隧道金钥装好（RUNBOOK 3.4）。"
    exit 1
fi
if grep -q 'dispatch.sh' "$AK"; then
    echo "  已经指到 dispatch.sh，不用改。"
else
    cp "$AK" "$AK.bak.$(date +%s)"
    sed -i "/desk-pet-tunnel/{s|command=\"[^\"]*\"|command=\"$DIR/dispatch.sh\"|;t;s|^restrict,port-forwarding |restrict,port-forwarding,command=\"$DIR/dispatch.sh\" |}" "$AK"
    grep -q 'dispatch.sh' "$AK" && echo "  改好了（原档备份成 $AK.bak.*）" || {
        echo "  改失败，authorized_keys 没动到。自己看一下那一行：grep desk-pet-tunnel $AK"; exit 1; }
fi

echo
echo "--- 试送一次（把现有的 Claude 状态推回桌宠）---"
DESK_PET_URL="$URL/status" "$PY" "$DIR/claude-watch.py" --once | sed 's/^/    /'

echo
echo "装好了：$DIR/"
echo "最后一步在 Windows：重跑 start-pet.cmd，看守会多拉一条连线把 watcher 养着。"
echo "之后看 tunnel.log 里「远端 watcher」开头的行就知道它活着没。"
