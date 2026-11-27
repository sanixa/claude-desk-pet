# 桌宠的反向隧道看守：让「远端 127.0.0.1:47355 → 这台的收集器」这条隧道有自己的 ssh 连线。
#
# 为什么要有这支：隧道原本是搭 Cursor 的 Remote-SSH 连线便车（ssh_config 里的 RemoteForward）。
# 但 Cursor 对同一台会开好几条连线、reload 一次就全换，每条都去抢同一个端口：
# 谁先到谁拥有，拥有者死得不干净时端口就被锁住，于是每次 reload 都要手动修 + 重连。
# 这支自己拉一条「只做转送、不开 shell」的 ssh 常驻着，Cursor 怎么 reload 都不影响。
#
# ExitOnForwardFailure=yes（在 ssh_config 的 Host desk-pet-remote 里）是关键：
# 端口被别人占着就马上退出，这支隔几秒再试，所以端口一空出来就会被我们抢回来。
#
# 用法：pythonw tunnel.pyw [ssh 的 host 别名] [运行目录]
#       一台远端一支，锁端口用 DESK_PET_LOCK 区分（见 start-pet.cmd）。
import os
import re
import socket
import subprocess
import sys
import time

HOST = sys.argv[1] if len(sys.argv) > 1 else (os.environ.get('DESK_PET_TUNNEL_HOST') or 'desk-pet-remote')
RUN_DIR = sys.argv[2] if len(sys.argv) > 2 else os.path.join(os.path.expanduser('~'), '.claude', 'desk-pet')
LOG = os.path.join(RUN_DIR, 'tunnel.log')
KEY = os.path.join(os.path.expanduser('~'), '.ssh', 'desk-pet-tunnel')
TAG = HOST.replace('desk-pet-', '') or HOST   # 日志前缀：多台的时候要分得出是谁在说话

# 一台远端一支看守，所以锁端口要一台一个（start-pet.cmd 里设）。
# 两台不小心设成同一个的话，第二支起不来 —— take_lock() 会把这件事写进日志，不会悄悄消失。
LOCK_PORT = int(os.environ.get('DESK_PET_LOCK') or 47320)
BUSY_WAIT = 8              # 端口被占：很快再试，一空出来就抢
NORMAL_WAIT = 15           # 连线掉了：隔一下再连
AUTH_TRIES = 3             # 金钥没授权的话，试这么多次就收手（不然永远在那边敲门）
FIX_HOST = HOST + '-fix'   # 同一把金钥、不带转送的那条，专门用来请远端清残骸
FIX_AFTER = 8              # 连抢这么多次都失败（约 1 分钟）就请远端自己清
FIX_GAP = 300              # 两次清之间至少隔这么久
NO_WINDOW = 0x08000000     # CREATE_NO_WINDOW：别闪黑窗
SSH = os.environ.get('DESK_PET_SSH') or 'ssh'   # 想指定别的 ssh 执行档就设这个
UNAUTH = os.path.join(RUN_DIR, 'tunnel-unauth-%s' % TAG)   # 这台还没授权的记号
UNAUTH_QUIET = 1800       # 记号还新就静静退出：排程每 10 分钟会叫一次，不然日志会被刷掉


def log(line):
    try:
        os.makedirs(RUN_DIR, exist_ok=True)
        if os.path.exists(LOG) and os.path.getsize(LOG) > 200000:
            os.replace(LOG, LOG + '.old')   # 不要 remove：多支看守写同一个档，删掉会把别人的行一起带走
        with open(LOG, 'a', encoding='utf-8') as f:
            f.write('%s  [%s] %s\n' % (time.strftime('%m-%d %H:%M:%S'), TAG, line))
    except Exception:
        pass


def host_spec():
    """从 ssh -G 捞出 user@hostname，纯本机解析设定档，不会连线。
    专用金钥带 restrict 不能跑指令，所以清残骸得用一般登入 —— 日志里直接把那行印给人看。"""
    try:
        out = subprocess.run([SSH, '-G', HOST], capture_output=True, text=True, encoding='utf-8',
                             errors='replace', creationflags=NO_WINDOW).stdout
        conf = dict(line.split(' ', 1) for line in out.splitlines() if ' ' in line)
        user, host = conf.get('user', ''), conf.get('hostname', HOST)
        return ('%s@%s' % (user, host)) if user else host
    except Exception:
        return HOST


def check_port():
    """ssh_config 的 RemoteForward 和收集器的 DESK_PET_PORT 必须是同一个数字。
    这是换埠时最容易漏的一边，开场先对一下，不对就写进日志（照样跑，只是会一直空转）。"""
    want = (os.environ.get('DESK_PET_PORT') or '47322').strip()
    try:
        out = subprocess.run([SSH, '-G', HOST], capture_output=True, text=True, encoding='utf-8',
                             errors='replace', creationflags=NO_WINDOW).stdout
        found = re.search(r'remoteforward \[?[^\]\s]*\]?:(\d+)', out, re.I)
    except Exception:
        return
    if found and found.group(1) != want:
        log('⚠ 埠号不一致：ssh_config 转送的是 %s，收集器在 %s —— 隧道会通但没人接。'
            % (found.group(1), want))


def kill_stray_ssh():
    """收掉上一轮看守留下的 ssh（它不会跟着父行程死，会继续占着远端的埠）。
    单例锁已经保证现在只有我们一支看守，所以同名的 ssh 一定是孤儿。"""
    ps = ("Get-CimInstance Win32_Process -Filter \"Name='ssh.exe'\" | "
          "Where-Object { $_.CommandLine -like '*%s*' } | "
          "ForEach-Object { Stop-Process -Id $_.ProcessId -Force; $_.ProcessId }" % HOST)
    try:
        done = subprocess.run(['powershell', '-NoProfile', '-Command', ps], capture_output=True,
                              text=True, encoding='utf-8', errors='replace', timeout=25,
                              creationflags=NO_WINDOW)
        killed = [x for x in (done.stdout or '').split() if x.isdigit()]
        if killed:
            log('收掉上一轮留下的 ssh：%s' % '、'.join(killed))
            time.sleep(1)
    except Exception as err:
        log('清旧 ssh 时出错（不影响后面）：%s' % err)


def clean_remote():
    """请远端把占着埠的残骸清掉 —— 关机时砍掉的 ssh 常常会在那头留一个。

    走的是同一把金钥：authorized_keys 那行绑了 command="…/fix-tunnel.sh"，
    所以这条连线能做的就只有跑那支脚本，开不了 shell、跑不了别的指令。
    没绑的话这里会什么都没发生（我们送的 true 被执行），日志会讲。"""
    log('连抢 %d 次都失败，请远端自己清残骸…' % FIX_AFTER)
    try:
        done = subprocess.run([SSH, FIX_HOST, 'fix'], capture_output=True, text=True,
                              encoding='utf-8', errors='replace', timeout=40,
                              stdin=subprocess.DEVNULL, creationflags=NO_WINDOW)
    except Exception as err:
        log('  清不成：%s' % err)
        return
    said = [x.strip() for x in ((done.stdout or '') + '\n' + (done.stderr or '')).splitlines() if x.strip()]
    for line in said[:8]:
        log('  远端：%s' % line[:160])
    if not said:
        log('  远端没吭声 —— authorized_keys 那行大概还没加 command="…/fix-tunnel.sh"，看 RUNBOOK 3.4。')


def config_stamp():
    """ssh_config 的改动时间。"""
    try:
        return os.path.getmtime(os.path.join(os.path.expanduser('~'), '.ssh', 'config'))
    except OSError:
        return 0


def watch(proc):
    """隧道活着的时候守着，顺便盯 ssh_config 有没有被改；回传 stderr。

    ssh 只在启动时读一次设定档，所以换了埠却不重拉，这条连线会继续守着旧埠 ——
    两头对不上，桌宠静静地没反应，而 ssh 行程看起来好得很（2026-11-20 就这样查了半天）。"""
    stamp = config_stamp()
    while proc.poll() is None:
        time.sleep(5)
        if config_stamp() != stamp:
            log('ssh_config 改了，重拉隧道（ssh 只在启动时读设定）')
            check_port()
            proc.terminate()
            break
    return proc.communicate()[1]


def take_lock():
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        s.bind(('127.0.0.1', LOCK_PORT))
        return s
    except OSError:
        s.close()
        log('锁 %d 有人占着，这支不起来（这台已经有一支在看了，或是两台用到同一个锁端口）' % LOCK_PORT)
        sys.exit(0)


def main():
    if not os.path.exists(KEY):
        log('没有 %s —— 金钥还没做，先看 README 的「专属隧道」那节。' % KEY)
        return
    try:
        if time.time() - os.path.getmtime(UNAUTH) < UNAUTH_QUIET:
            return        # 刚刚才确认过这台没授权，上一轮写过日志了，这次不吵
    except OSError:
        pass
    log('看守启动，守 %s' % HOST)
    kill_stray_ssh()
    check_port()
    # 这里原本会拉一条 HOST-watch 的连线，养着远端的 claude-watch.py。2026-11-27 量掉了：
    # 官方那只 mod 在 SSH 工作阶段根本不跑（本机会话写得出状态档，SSH 会话两边都没有），
    # 远端没有人写状态，watcher 装了也永远读不到东西。细节看 README「Claude 的 SSH 工作阶段」。
    auth_fails = busy = 0
    last_fix = 0
    while True:
        started = time.time()
        try:
            proc = subprocess.Popen([SSH, '-N', HOST], stdout=subprocess.PIPE,
                                    stderr=subprocess.PIPE, text=True, encoding='utf-8',
                                    errors='replace', creationflags=NO_WINDOW)
        except Exception as err:
            log('起不了 ssh：%s' % err)
            return
        try:
            # 三秒内就结束 = 没接上（认证失败、端口被占）；撑过三秒就是真的通了
            _, raw = proc.communicate(timeout=3)
        except subprocess.TimeoutExpired:
            log('隧道接上了，守着 %s' % HOST)
            auth_fails = busy = 0
            try:
                os.remove(UNAUTH)   # 通了，记号就不该留着
            except OSError:
                pass
            raw = watch(proc)
        err = ' '.join((raw or '').split())[:300]
        alive = time.time() - started

        if 'Permission denied' in err or 'publickey' in err:
            auth_fails += 1
            log('登不进去（%d/%d）：%s' % (auth_fails, AUTH_TRIES, err))
            if auth_fails >= AUTH_TRIES:
                log('金钥看起来还没授权到这台，先停了（%d 分钟内不再试）。'
                    '授权好以后重跑 start-pet.cmd，或等排程自己叫。' % (UNAUTH_QUIET // 60))
                try:
                    with open(UNAUTH, 'w', encoding='utf-8') as f:
                        f.write(time.strftime('%Y-%m-%d %H:%M:%S'))
                except OSError:
                    pass
                return
            wait = 20
        elif 'forwarding failed' in err:
            # 端口还被别人（通常是 Cursor 上一条连线的残留 sshd）占着。
            # 同一行别刷满整个日志：第一次、第二次（带解法）之后，每十次报一下还活着。
            auth_fails = 0
            busy += 1
            if busy == 1 or busy % 10 == 0:
                log('端口被占着（第 %d 次，%d 秒后再抢）：%s' % (busy, BUSY_WAIT, err[:90]))
            if busy == 2:
                log('一直抢不到就是远端有残骸（关掉的连线留下 closing 的 session）。')
                log('    自己清：ssh %s "~/.cursor/desk-pet/fix-tunnel.sh"' % host_spec())
                log('    或者等我：再抢 %d 次就会去请远端清。' % (FIX_AFTER - busy))
            if busy >= FIX_AFTER and time.time() - last_fix > FIX_GAP:
                last_fix = time.time()
                clean_remote()
            wait = BUSY_WAIT
        else:
            auth_fails = busy = 0
            log('隧道结束（撑了 %.0f 秒）%s' % (alive, ('：' + err) if err else ''))
            wait = NORMAL_WAIT if alive < 10 else 3
        time.sleep(wait)


_lock = take_lock()
if __name__ == '__main__':
    try:
        main()
    except Exception:
        import traceback
        with open(os.path.join(RUN_DIR, 'tunnel-error.log'), 'w', encoding='utf-8') as f:
            traceback.print_exc(file=f)
