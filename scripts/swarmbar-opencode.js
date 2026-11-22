// swarmbar-bridge-v3
// SwarmBar bridge for OpenCode. Install by copying to
// ~/.config/opencode/plugins/swarmbar.js and declaring it in
// ~/.config/opencode/opencode.jsonc:
//   "plugin": ["file:///Users/<you>/.config/opencode/plugins/swarmbar.js"]
// (Auto-discovery only scans project-level .opencode/plugin dirs.)
//
// One file for both plugin systems. OpenCode 2 loads only a default
// export with an id and a setup() (anything else fails with "Plugin must
// export a default definition with an id and an effect or setup
// function"). OpenCode 1.17 and later take a default export with an id
// as their own module format and call its server(). OpenCode 1 before
// that called every export as a function, so it cannot load this file.
//
// permission.asked fires whenever OpenCode prompts. The relay registers
// the prompt with the SwarmBar menu bar app and holds for its decision
// while the TUI dialog shows as normal. If SwarmBar answers first, the
// decision is applied through the server's own permission endpoint; if
// the user answers in the TUI first (or SwarmBar is not running), the
// held request resolves empty and nothing happens. permission.replied is
// forwarded so SwarmBar clears its approval row no matter where the
// prompt was answered. Each prompt goes with the tool call it gates, read
// from OpenCode's own tool hooks, since the prompt alone does not say
// what the call runs (see gatedCall).
//
// It talks only to SwarmBar's own Unix socket, in a folder only this user
// can enter, never to a network port: whatever held a port while SwarmBar
// was not running would receive every prompt and could answer allow. No
// token is sent; reaching the socket at all proves the caller is this
// user. Anything other than this user's socket sends nothing, and the TUI
// prompt stands alone.
import { request } from "node:http"
import { lstatSync } from "node:fs"
import { homedir } from "node:os"

const DIR = `${homedir()}/Library/Application Support/SwarmBar/run`
const SOCKET = `${DIR}/hook.sock`

// The socket and its folder must be this user's own, and not links.
function ownSocket() {
  try {
    const uid = process.getuid()
    const dir = lstatSync(DIR)
    const sock = lstatSync(SOCKET)
    return dir.isDirectory() && dir.uid === uid && sock.isSocket() && sock.uid === uid
  } catch {
    return false
  }
}

// Posts a JSON body and resolves with the parsed answer, or null for any
// failure: no socket, a timeout, a body that is not JSON.
function post(path, payload, timeoutMs) {
  return new Promise((resolve) => {
    if (!ownSocket()) return resolve(null)
    const data = JSON.stringify(payload)
    const req = request(
      {
        socketPath: SOCKET,
        path,
        method: "POST",
        headers: {
          "content-type": "application/json",
          "content-length": Buffer.byteLength(data),
        },
      },
      (res) => {
        const chunks = []
        res.on("data", (chunk) => chunks.push(chunk))
        res.on("end", () => {
          if (res.statusCode !== 200) return resolve(null)
          try {
            resolve(JSON.parse(Buffer.concat(chunks).toString("utf8")))
          } catch {
            resolve(null)
          }
        })
        res.on("error", () => resolve(null))
      }
    )
    req.setTimeout(timeoutMs, () => req.destroy())
    req.on("error", () => resolve(null))
    req.end(data)
  })
}

// OpenCode 2 names a request's permission `action` and what it covers
// `resources`. SwarmBar reads OpenCode 1's names, `permission` and
// `patterns`, so a request is sent in those, with everything else it
// carries passed through unchanged.
export function asV1Request(request, directory) {
  const { action, resources, ...rest } = request ?? {}
  return {
    ...rest,
    ...(action === undefined ? {} : { permission: action }),
    ...(resources === undefined ? {} : { patterns: resources }),
    directory,
  }
}

// The tool calls OpenCode is running, by call id. A permission request
// names the call it gates but carries only the permission's patterns,
// which are what a rule matches, not what runs: for a shell call they
// drop redirections, cd, assignments and expansions, and other tools ask
// with "*". So each request is relayed with the gated call's own input,
// and SwarmBar shows that beside Approve. A call this plugin did not see
// start is sent without one, and SwarmBar offers the terminal instead.
const calls = new Map()
const MAX_CALLS = 256

function remember(id, read) {
  if (typeof id !== "string" || id === "") return
  calls.delete(id)
  calls.set(id, read)
  while (calls.size > MAX_CALLS) calls.delete(calls.keys().next().value)
}

function forget(id) {
  if (typeof id === "string") calls.delete(id)
}

// The call as { tool, input }, or undefined when it is not known.
function gatedCall(id) {
  const read = typeof id === "string" ? calls.get(id) : undefined
  if (!read) return undefined
  try {
    const { tool, input } = read()
    if (typeof tool !== "string" || tool === "") return undefined
    if (!input || typeof input !== "object" || Array.isArray(input)) return undefined
    return { tool, input }
  } catch {
    return undefined
  }
}

// The request with the gated call attached as `call`, and never a `call`
// of any other origin.
function withCall(request, call) {
  const { call: _unused, ...rest } = request
  return call ? { ...rest, call } : rest
}

// Holds for SwarmBar's decision and hands an allow or a deny to `answer`.
// Anything else, including no answer at all, leaves the TUI prompt alone.
async function relay(request, answer) {
  try {
    const body = await post("/hook/OpenCodePermission", request, 350_000)
    const decision = body && body.decision
    if (decision !== "allow" && decision !== "deny") return
    await answer(decision === "allow" ? "once" : "reject")
  } catch {
    // SwarmBar not running or hold expired: the TUI prompt stands alone.
  }
}

// OpenCode 1.17 and later.
async function server({ client, directory }) {
  return {
    // OpenCode 1 hands the tool the same args object it passes here, so
    // the object itself is kept, not a copy, and read when a request for
    // the call is relayed.
    "tool.execute.before": async (input, output) => {
      const tool = input?.tool
      const args = output?.args
      remember(input?.callID, () => ({ tool, input: args }))
    },
    "tool.execute.after": async (input) => forget(input?.callID),
    event: async ({ event }) => {
      const input = event.properties ?? {}
      if (event.type === "permission.asked") {
        relay(withCall({ ...input, directory }, gatedCall(input.tool?.callID)), (response) =>
          client.postSessionIdPermissionsPermissionId({
            path: { id: input.sessionID, permissionID: input.id },
            body: { response },
          }))
      }
      if (event.type === "permission.replied") {
        post("/hook/OpenCodeReplied", input, 5_000)
      }
    },
  }
}

// OpenCode 2. Events arrive as { type, location: { directory }, data }.
async function setup(opencode) {
  // OpenCode 2 runs the input as it stands on this payload once every
  // execute.before hook has run (a hook repairs it by assigning to it), so
  // the payload is kept and its tool and input are read at relay time.
  try {
    Promise.resolve(opencode.tool.hook("execute.before", (call) => {
      remember(call?.id, () => ({ tool: call.tool, input: call.input }))
    })).catch(() => {})
    Promise.resolve(opencode.tool.hook("execute.after", (call) => forget(call?.id))).catch(() => {})
  } catch {
    // No tool hooks: every request goes without its call, to the terminal.
  }
  const stop = new AbortController()
  const events = opencode.event.subscribe({
    types: ["permission.asked", "permission.replied"],
    signal: stop.signal,
  })
  ;(async () => {
    for await (const event of events) {
      const data = event.data ?? event.properties ?? {}
      const directory = event.location?.directory ?? opencode.location?.directory
      if (event.type === "permission.asked") {
        const source = data.source?.type === "tool" ? data.source.id : undefined
        relay(withCall(asV1Request(data, directory), gatedCall(source)), (decision) =>
          opencode.permission.reply({
            sessionID: data.sessionID, requestID: data.id, decision,
          }))
      }
      if (event.type === "permission.replied") {
        post("/hook/OpenCodeReplied", data, 5_000)
      }
    }
  })().catch(() => {
    // The stream ended with the plugin: nothing is left to relay.
  })
  return () => stop.abort()
}

export default { id: "swarmbar", server, setup }
