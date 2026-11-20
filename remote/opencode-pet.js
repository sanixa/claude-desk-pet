// opencode → 桌宠状态适配器
//
// 装到 ~/.config/opencode/plugins/desk-pet.js（那个目录里的 .ts/.js 会被直接载入）。
// 把 opencode 的事件翻成桌宠认的状态，POST 到 Windows 那边的收集器
// （远端经 ssh RemoteForward 的 127.0.0.1:<埠>，装机脚本会把埠号填好）。
//
// 三条规矩，顺序就是重要性：
//   1. 绝不丢异常出去 —— 每个 hook 都包 try/catch，桌宠再怎么坏都不能影响 agent 干活。
//   2. 绝不 await 回报 —— fetch 不等它，不然隧道断掉时每个事件都要耗 1.2 秒。
//   3. 断了就歇 60 秒 —— 省掉一堆没意义的超时。
//
// API 来源：@opencode-ai/plugin 的 index.d.ts（Hooks）和 @opencode-ai/sdk 1.19.6 的
// types.gen.d.ts（Event 的 32 个 type 字面值）。版本有差异时，没对上的事件会原样记进
// ~/.config/opencode/desk-pet.log（每种事件只记第一次），照着改对应就好。
import fs from "node:fs"
import os from "node:os"
import path from "node:path"

const POST_URL = process.env.DESK_PET_URL || "http://127.0.0.1:__PORT__/status"
const LOG = process.env.DESK_PET_LOG || path.join(os.homedir(), ".config", "opencode", "desk-pet.log")
const TIMEOUT = 1200      // 回报的上限，别拖住 agent
const DOWN_FOR = 60000    // 失败过就歇这么久
const SAME_GAP = 1500     // 同一个状态在这么短时间内重复，就不再送（session.status busy 会连发）

const S = {
  label: "",
  downUntil: 0,
  lastSid: "main",
  lastKey: "",
  lastAt: 0,
  seen: new Set(),        // 记过第一次的事件种类
  errors: new Map(),      // sessionID → 连续出错次数
  sessions: new Set(),    // 送过状态的 session，dispose 时要清掉
}

let registered = false

function log(line) {
  try {
    if (fs.existsSync(LOG) && fs.statSync(LOG).size > 200000) fs.rmSync(LOG)
    const now = new Date().toISOString().slice(5, 19).replace("T", " ")
    fs.appendFileSync(LOG, `${now}  ${line}\n`)
  } catch {}
}

function baseName(value) {
  return String(value ?? "").replace(/\\/g, "/").replace(/\/+$/, "").split("/").pop() || ""
}

const FILE_KEYS = ["filePath", "file_path", "path", "file", "target_file", "notebook_path"]

function pickFile(args) {
  for (const key of FILE_KEYS) {
    const value = args?.[key]
    if (typeof value === "string" && value.trim()) return baseName(value)
  }
  return ""
}

// 工具名 → 气泡台词。顺序有讲究：web 要在 search/read 前面拦下来。
// 台词跟 Cursor 那支 adapter 一字不差，同一个气泡里不要出现两种说法。
function describe(tool, args) {
  const name = String(tool ?? "")
  const found = pickFile(args)
  if (/terminal|shell|command|bash|process|pty/i.test(name) || typeof args?.command === "string") {
    return ["tool", "在跑命令…"]
  }
  if (/todo/i.test(name)) return ["tool", "在排进度…"]   // todowrite/todoread 要在 write/read 前面拦下来
  if (/edit|write|create|apply|patch|replace|delete|rename|move|format/i.test(name)) {
    return ["tool", found ? `在改 ${found}` : "在改文件…"]
  }
  if (/web|fetch|http|url|browser|docs/i.test(name)) return ["reading", "在上网查…"]
  if (/read|view|open|notebook/i.test(name)) return ["reading", found ? `在读 ${found}` : "在翻文件…"]
  if (/grep|search|glob|find|list|dir|symbol/i.test(name)) return ["reading", "在找东西…"]
  if (/agent|task|subagent/i.test(name)) return ["tool", "派小助手干活中…"]
  if (/^mcp/i.test(name)) return ["tool", "在用扩展工具…"]
  return ["tool", name ? `在用 ${name}…` : "在干活…"]
}

function send(payload) {
  if (Date.now() < S.downUntil) return
  const body = JSON.stringify({ source: "opencode", project: S.label, ...payload })
  try {
    fetch(POST_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body,
      signal: AbortSignal.timeout(TIMEOUT),
    })
      .then((res) => {
        if (!res.ok) log(`回报被拒 HTTP ${res.status}：${body.slice(0, 120)}`)
      })
      .catch((err) => {
        S.downUntil = Date.now() + DOWN_FOR
        log(`回报失败（${POST_URL}）：${err} —— 先歇 ${DOWN_FOR / 1000} 秒，要修跑 fix-tunnel.sh`)
      })
  } catch (err) {
    log(`连 fetch 都起不来：${err}`)
  }
}

function push(sid, state, text, sound) {
  if (sid) S.lastSid = String(sid)
  const id = S.lastSid
  S.sessions.add(id)
  const key = `${id}|${state}|${text}`
  const now = Date.now()
  if (key === S.lastKey && now - S.lastAt < SAME_GAP) return   // 同一个状态连发，送一次就够
  S.lastKey = key
  S.lastAt = now
  send({ id, state, text, sound })
  log(`→ ${state} / ${text}${sound ? `（${sound}）` : ""}`)
}

function bump(sid) {
  const id = String(sid || S.lastSid)
  const n = (S.errors.get(id) ?? 0) + 1
  S.errors.set(id, n)
  return n
}

function onEvent(event) {
  const type = String(event?.type ?? "")
  const p = event?.properties ?? {}
  const sid = p.sessionID || p.info?.sessionID || p.part?.sessionID || p.info?.id || ""
  if (!S.seen.has(type)) {
    S.seen.add(type)
    log(`第一次看到事件 ${type}`)
  }
  switch (type) {
    case "session.idle":
      S.errors.delete(String(sid || S.lastSid))
      push(sid, "waiting", "轮到你啦！", "done")
      return
    case "session.status": {
      const kind = p.status?.type
      if (kind === "idle") push(sid, "waiting", "轮到你啦！", "done")
      else if (kind === "busy") push(sid, "thinking", "思考中…")
      else if (kind === "retry") push(sid, "error", "重试中…")
      return
    }
    case "session.error": {
      const n = bump(sid)
      // 连续出错 3 次：石化彩蛋（跟 Claude、Cursor 那边一样）
      push(sid, n >= 3 ? "stone" : "error", n >= 3 ? "石化了…" : "出错了…", n === 1 ? "error" : undefined)
      return
    }
    case "session.compacted":
      push(sid, "thinking", "在整理上下文…")
      return
    case "file.edited":
      push("", "tool", `在改 ${baseName(p.file)}`)   // 这个事件没有 sessionID，算在最近那个头上
      return
    case "permission.updated":
      push(sid, "waiting", "等你同意…", "done")
      return
    case "session.deleted": {
      const id = String(p.info?.id || S.lastSid)
      S.sessions.delete(id)
      send({ id, gone: true })
      log(`→ ${id} 结束`)
      return
    }
    default:
      return   // message.part.updated 之类一秒好几次，不动桌宠
  }
}

/** @type {import("@opencode-ai/plugin").Plugin} */
export const DeskPet = async (input) => {
  // 同一个档案被当成两个 plugin 载入（具名 + default）时只接一次，不然每个事件会报两遍
  if (registered) return {}
  registered = true

  const dir = baseName(input?.worktree || input?.directory || input?.project?.worktree || "")
  S.label = process.env.DESK_PET_PROJECT || (dir.length >= 2 ? dir : os.hostname())
  log(`挂上了：POST ${POST_URL}，气泡标「${S.label}」`)

  return {
    event: async ({ event }) => {
      try {
        onEvent(event)
      } catch (err) {
        log(`event 出错（不影响 agent）：${err}`)
      }
    },
    "chat.message": async (info) => {
      try {
        push(info?.sessionID, "thinking", "思考中…")
      } catch (err) {
        log(`chat.message 出错：${err}`)
      }
    },
    "tool.execute.before": async (info, out) => {
      try {
        const [state, text] = describe(info?.tool, out?.args)   // out.args 只读，别改
        push(info?.sessionID, state, text)
      } catch (err) {
        log(`tool.execute.before 出错：${err}`)
      }
    },
    "tool.execute.after": async (info) => {
      try {
        push(info?.sessionID, "thinking", "思考中…")
      } catch (err) {
        log(`tool.execute.after 出错：${err}`)
      }
    },
    dispose: async () => {
      try {
        for (const id of S.sessions) send({ id, gone: true })
        log("opencode 收摊，状态都清掉了")
      } catch (err) {
        log(`dispose 出错：${err}`)
      }
    },
  }
}

export default DeskPet
