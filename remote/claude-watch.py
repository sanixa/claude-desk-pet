#!/usr/bin/env python3
# 远端 Claude Code（SSH 工作阶段）→ 桌宠
#
# Claude Code 连 SSH 的时候，官方 plugin 的 $.env 和 $.fs 都是「工作阶段范围」的：
# USERPROFILE 在 Linux 上不存在，落到 HOME 拿到远端的家目录，$.fs.write 也写远端的硬碟。
# 所以状态档好端端地躺在远端的 ~/.claude/desk-pet/sessions/，本机桌宠根本看不到。
# 这支就是站在远端盯着那个目录，一有变动就 POST 回 Windows 的收集器。
#
# 怎么常驻：它是那把金钥的强制指令之一（ssh <host> watch），由 Windows 这边的看守
# 拉一条连线养着，断了自己重连 —— 不用在远端装 systemd，也不碰登入 shell。
# stdin 一断（ssh 死了）就自己退出，不会留下孤儿。
#
# 用法：claude-watch.py          一直盯着
#       claude-watch.py --once   扫一次就走（装机脚本拿来验证管路）
import json
import os
import socket
import sys
import threading
import time
import urllib.request

# 回报的对象是隧道这端的 127.0.0.1，代理永远不可能是对的；
# 但 urllib 默认会读 http_proxy，远端 shell 常把它设在 rc 里。明确关掉。
NO_PROXY = urllib.request.build_opener(urllib.request.ProxyHandler({}))

PORT = os.environ.get('DESK_PET_PORT') or '__PORT__'
if not PORT.isdigit():
    PORT = '47355'          # 直接从磁盘跑（没经过收集器替换）时的默认值
URL = os.environ.get('DESK_PET_URL') or ('http://127.0.0.1:%s/status' % PORT)
SESSIONS = os.path.join(os.path.expanduser('~'), '.claude', 'desk-pet', 'sessions')

POLL = 0.5          # 轮询间隔：目录很小，一次 listdir 而已
FRESH = 300         # 刚启动时只认五分钟内动过的，不要把上礼拜的状态叫醒
HEARTBEAT = 60      # 没事也固定吭一声，让本机那头知道还活着
TIMEOUT = 2
DOWN_FOR = 60       # 回报失败就歇一下，隧道断掉时不要每 0.5 秒撞一次


try:
    # 别让语系决定命运：stdout 编不出中文的话，下面那行会被当成「管线断了」
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
except Exception:
    pass


def say(line):
    """写 stdout 就是回报给本机的看守（它会收进 tunnel.log）。

    只有「管线真的断了」才退出（OSError / BrokenPipeError = ssh 没了，别赖着）；
    其它写失败一律忍下来 —— 绝不能因为一行日志印不出来就把整支 watcher 弄死。
    """
    try:
        sys.stdout.write('%s\n' % line)
        sys.stdout.flush()
    except OSError:
        os._exit(0)
    except Exception:
        pass


down_until = 0.0


def post(payload):
    global down_until
    if time.time() < down_until:
        return False
    body = json.dumps(payload, ensure_ascii=False).encode('utf-8')
    req = urllib.request.Request(URL, data=body, method='POST',
                                 headers={'Content-Type': 'application/json'})
    try:
        with NO_PROXY.open(req, timeout=TIMEOUT) as resp:
            return resp.status == 200
    except Exception as err:
        down_until = time.time() + DOWN_FOR
        say('回报失败（%s）：%s —— 歇 %d 秒' % (URL, err, DOWN_FOR))
        return False


def send_file(name, path):
    try:
        with open(path, encoding='utf-8') as f:
            data = json.load(f)
        if not isinstance(data, dict):
            return
    except Exception:
        return      # 正在被写的半截档，下一轮再读
    ok = post({
        'source': 'claude',
        'id': name[:-5],
        'state': data.get('state'),
        'text': data.get('text'),
        'project': data.get('project'),
        'sound': data.get('sound'),
    })
    say('%s %s / %s' % ('送出' if ok else '没送成', data.get('state'), data.get('text')))


def is_claude(name):
    # 远端自己的 cursor-/opencode- 状态档有它们自己的路，别重复回报
    return name.endswith('.json') and not name.startswith(('cursor-', 'opencode-'))


def watch_stdin():
    """ssh 一断，stdin 就 EOF —— 立刻退出，免得在远端留下孤儿行程。"""
    try:
        sys.stdin.read()
    except Exception:
        pass
    os._exit(0)


def scan(seen, first):
    now = time.time()
    try:
        names = [n for n in os.listdir(SESSIONS) if is_claude(n)]
    except OSError:
        names = []
    for name in names:
        path = os.path.join(SESSIONS, name)
        try:
            mtime = os.path.getmtime(path)
        except OSError:
            continue
        if seen.get(name) == mtime:
            continue
        stale = first and now - mtime > FRESH
        seen[name] = mtime
        if not stale:
            send_file(name, path)
    for name in [n for n in seen if n not in names]:
        seen.pop(name, None)
        post({'source': 'claude', 'id': name[:-5], 'gone': True})
        say('%s 结束，清掉' % name[:-5])


def main():
    say('盯着 %s → %s（主机 %s）' % (SESSIONS, URL, socket.gethostname()))
    if not os.path.isdir(SESSIONS):
        say('那个目录不存在 —— 这台的 Claude Code SSH 工作阶段没有写过状态。')
        if '--once' in sys.argv:
            return 1
    seen = {}
    if '--once' in sys.argv:
        scan(seen, False)       # 验证用：不管新旧，有什么送什么
        say('扫过 %d 个状态档' % len(seen))
        return 0
    threading.Thread(target=watch_stdin, daemon=True).start()
    first, last_beat = True, 0.0
    while True:
        scan(seen, first)
        first = False
        if time.time() - last_beat > HEARTBEAT:
            last_beat = time.time()
            say('还在（盯着 %d 个工作阶段）' % len(seen))
        time.sleep(POLL)


if __name__ == '__main__':
    try:
        sys.exit(main() or 0)
    except KeyboardInterrupt:
        pass
    except Exception as err:
        say('炸了：%s' % err)
        sys.exit(1)
