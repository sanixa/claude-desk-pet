#!/usr/bin/env python3
# Cursor → 桌宠状态适配器
#
# Cursor 的 hook 会把一包 JSON 从 stdin 喂进来，这支脚本把它翻成桌宠认的状态文件：
#   <运行目录>/sessions/cursor-<conversation_id>.json
# 只用标准库，不管发生什么都印 {} 并以 0 退出 —— 绝不能挡住 Cursor 干活。
#
# 同一支脚本在远端 Linux 也能用（Cursor Remote-SSH 的 hooks 是在远端跑的）：
# 设了 DESK_PET_URL 就同时 POST 给 Windows 那边的收集器（经 ssh RemoteForward 的 127.0.0.1:47355）。
# 本地状态文件照写不误 —— 连续出错次数要靠它记。
#   DESK_PET_URL      收集器地址，例如 http://127.0.0.1:47355/status
#   DESK_PET_PROJECT  气泡上的名字，不设就按 workspace 路径取
#
# 装法见 ~/.cursor/hooks.json；远端装法见 ../remote/install.sh
import json
import os
import re
import sys
import time
import urllib.request

# 回报的对象是隧道这端的 127.0.0.1，代理永远不可能是对的；
# 但 urllib 默认会读 http_proxy，远端 shell 常把它设在 rc 里。明确关掉。
NO_PROXY = urllib.request.build_opener(urllib.request.ProxyHandler({}))

RUN_DIR = os.environ.get('DESK_PET_DIR') or os.path.join(os.path.expanduser('~'), '.claude', 'desk-pet')
SESSIONS = os.path.join(RUN_DIR, 'sessions')
LOG = os.path.join(RUN_DIR, 'cursor-hook.log')  # 自己留一份呼叫记录，省得去翻 Cursor 的 log
POST_URL = (os.environ.get('DESK_PET_URL') or '').strip()
POST_TIMEOUT = 1.2            # 隧道断了的时候，别让 Cursor 每个 hook 都在这里等
DOWN_FOR = 60                 # 失败过一次就歇这么久，期间直接不回报
DOWN_FLAG = os.path.join(RUN_DIR, 'tunnel-down')
STARTED = time.time()

FILE_KEYS = ('file_path', 'target_file', 'path', 'relative_workspace_path', 'filename', 'file', 'notebook_path')


def log(line):
    """每次被呼叫都记一行；超过 200KB 就重新开始，不会无限长大。"""
    try:
        os.makedirs(RUN_DIR, exist_ok=True)
        if os.path.exists(LOG) and os.path.getsize(LOG) > 200000:
            os.remove(LOG)
        with open(LOG, 'a', encoding='utf-8') as f:
            f.write('%s  %s\n' % (time.strftime('%m-%d %H:%M:%S'), line))
    except Exception:
        pass


def safe_id(value):
    return re.sub(r'[^A-Za-z0-9._-]', '_', str(value))[:60] or 'default'


def base_name(value):
    if not value:
        return ''
    return os.path.basename(str(value).replace('\\', '/').rstrip('/'))


def pick_file(data):
    for key in FILE_KEYS:
        value = data.get(key)
        if isinstance(value, str) and value.strip():
            return base_name(value)
    return ''


def describe(tool, tool_input):
    """Cursor 的工具名 → 气泡里的一句话。顺序有讲究：web_search 要在 search 前面拦下来。"""
    name, found = tool or '', pick_file(tool_input)
    if re.search(r'terminal|shell|command|bash|process', name, re.I) or isinstance(tool_input.get('command'), str):
        return 'tool', '在跑命令…'
    if re.search(r'edit|write|create|apply|patch|replace|delete|rename|move|format', name, re.I):
        return 'tool', ('在改 %s' % found) if found else '在改文件…'
    if re.search(r'web|fetch|http|url|browser|docs', name, re.I):
        return 'reading', '在上网查…'
    if re.search(r'read|view|open|notebook', name, re.I):
        return 'reading', ('在读 %s' % found) if found else '在翻文件…'
    if re.search(r'grep|search|glob|find|list|dir|symbol', name, re.I):
        return 'reading', '在找东西…'
    if re.search(r'agent|task|subagent|todo', name, re.I):
        return 'tool', '派小助手干活中…'
    if name.lower().startswith('mcp'):
        return 'tool', '在用扩展工具…'
    return 'tool', ('在用 %s…' % name) if name else '在干活…'


def load(path):
    try:
        with open(path, encoding='utf-8') as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def save(path, record):
    os.makedirs(SESSIONS, exist_ok=True)
    tmp = path + '.tmp'  # 先写临时文件再改名，桌宠不会读到半截的 JSON
    with open(tmp, 'w', encoding='utf-8') as f:
        json.dump(record, f, ensure_ascii=False)
    os.replace(tmp, path)


def post(payload):
    """把状态捎给 Windows 那边的收集器。隧道没通、桌宠没开都很正常，静静失败就好。

    断了之后先歇 60 秒：ssh 的反向转送有个经典坑 —— 上一条连线留下的残留 sshd 还占着端口，
    新连线 bind 失败，于是每个请求都卡到超时。真遇上了，每个 hook 都等 1.2 秒会把 Cursor 拖顿，
    所以失败一次就记个旗标、先不回报；一通就马上恢复。修法见 remote/fix-tunnel.sh。"""
    if not POST_URL:
        return
    try:
        resting = time.time() - os.path.getmtime(DOWN_FLAG)
    except OSError:
        resting = None
    if resting is not None and resting < DOWN_FOR:
        log('    → 隧道 %.0f 秒前是断的，这轮先不回报' % resting)
        return
    body = json.dumps(payload, ensure_ascii=False).encode('utf-8')
    req = urllib.request.Request(POST_URL, data=body, method='POST',
                                 headers={'Content-Type': 'application/json'})
    try:
        with NO_PROXY.open(req, timeout=POST_TIMEOUT) as resp:
            log('    → 已回报（HTTP %s）' % resp.status)
    except Exception as err:
        log('    → 回报失败（%s）：%s —— 先歇 %d 秒，要修跑 fix-tunnel.sh' % (POST_URL, err, DOWN_FOR))
        try:
            with open(DOWN_FLAG, 'w', encoding='utf-8') as f:
                f.write(str(err)[:200])
        except OSError:
            pass
        return
    if resting is not None:
        try:
            os.remove(DOWN_FLAG)   # 通了就马上恢复，不用等满 60 秒
        except OSError:
            pass


def project_of(event, previous):
    label = (os.environ.get('DESK_PET_PROJECT') or '').strip()
    if label:
        return label   # 远端装的时候写成主机名，气泡才分得出是哪一台
    roots = event.get('workspace_roots')
    if isinstance(roots, list) and roots:
        return base_name(roots[0])
    for value in (event.get('cwd'), os.environ.get('CURSOR_PROJECT_DIR')):
        if isinstance(value, str) and value.strip():
            return base_name(value)
    return previous.get('project', '')


def main():
    raw = ''
    if not sys.stdin.isatty():
        # 一定要自己按 UTF-8 解：这支脚本用 -I 跑，sys.stdin 会按系统编码（繁中 Windows 是 cp950）解，
        # 路径或 prompt 里有中文就会解坏，JSON 直接 parse 失败。
        raw = sys.stdin.buffer.read().decode('utf-8', 'replace')
    event = json.loads(raw) if raw.strip() else {}
    if not isinstance(event, dict):
        return

    name = str(event.get('hook_event_name') or '')
    sid = safe_id(event.get('conversation_id') or 'default')
    path = os.path.join(SESSIONS, 'cursor-%s.json' % sid)
    log('收到 %-20s tool=%-24s roots=%s' % (name or '(没有事件名)', event.get('tool_name') or '-',
                                            event.get('workspace_roots') or '-'))

    if name == 'sessionEnd':
        try:
            os.remove(path)  # 会话结束，别再占着桌宠
        except OSError:
            pass
        post({'source': 'cursor', 'id': sid, 'gone': True})
        return

    previous = load(path)
    errors = int(previous.get('errors') or 0)
    tool_input = event.get('tool_input') if isinstance(event.get('tool_input'), dict) else {}
    sound = None

    if name == 'stop':
        state, text, errors, sound = 'waiting', '轮到你啦！', 0, 'done'
    elif name == 'beforeSubmitPrompt':
        state, text, errors = 'thinking', '思考中…', 0
    elif name == 'sessionStart':
        state, text, errors = 'waiting', '我来啦～', 0
    elif name == 'postToolUseFailure':
        errors += 1
        # 连续出错 3 次：石化彩蛋（跟 Claude 那边一样）
        state, text = ('stone', '石化了…') if errors >= 3 else ('error', '出错了…')
        sound = 'error' if errors == 1 else None
    elif name == 'afterFileEdit':
        found = pick_file(event) or pick_file(tool_input)
        state, text, errors = 'tool', ('在改 %s' % found) if found else '在改文件…', 0
    elif name == 'afterShellExecution':
        state, text, errors = 'tool', '在跑命令…', 0
    elif name == 'postToolUse':
        state, text = describe(event.get('tool_name') or '', tool_input)
        errors = 0
    else:
        log('    → 不处理这个事件')
        return  # 其它事件不动桌宠

    log('    → %s / %s（本体耗时 %.0fms）' % (state, text, (time.time() - STARTED) * 1000))
    record = {
        'source': 'cursor',
        'state': state,
        'text': text,
        'project': project_of(event, previous),
        'ts': int(time.time() * 1000),
        'sound': sound,
        'errors': errors,
    }
    save(path, record)
    post(dict(record, id=sid))


if __name__ == '__main__':
    try:
        main()
    except Exception:
        pass  # 桌宠这边出任何错，都不能影响 Cursor
    sys.stdout.write('{}')
