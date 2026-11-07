// swarmbar-bridge-v3
// SwarmBar bridge for OpenCode. Install by copying to
// ~/.config/opencode/plugins/swarmbar.js and declaring it in
// ~/.config/opencode/opencode.jsonc:
//   "plugin": ["file:///Users/<you>/.config/opencode/plugins/swarmbar.js"]
// (Auto-discovery only scans project-level .opencode/plugin dirs.)
//
// permission.asked fires on the event bus whenever OpenCode prompts (the
// v1 "permission.ask" hook never fires in 1.18). The relay registers the
// prompt with the SwarmBar menu bar app and holds for its decision while
// the TUI dialog shows as normal. If SwarmBar answers first, the decision
// is applied through the server's own permission endpoint; if the user
// answers in the TUI first (or SwarmBar is not running), the held request
// resolves empty and nothing happens. permission.replied is forwarded so
// SwarmBar clears its approval row no matter where the prompt was
// answered.
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

export const SwarmBarPlugin = async ({ client, directory }) => {
  return {
    event: async ({ event }) => {
      if (event.type === "permission.asked") {
        relay(client, event.properties ?? {}, directory)
      }
      if (event.type === "permission.replied") {
        post("/hook/OpenCodeReplied", event.properties ?? {}, 5_000)
      }
    },
  }
}

async function relay(client, input, directory) {
  try {
    const body = await post(
      "/hook/OpenCodePermission", { ...input, directory }, 350_000)
    const decision = body && body.decision
    if (decision !== "allow" && decision !== "deny") return
    await client.postSessionIdPermissionsPermissionId({
      path: { id: input.sessionID, permissionID: input.id },
      body: { response: decision === "allow" ? "once" : "reject" },
    })
  } catch {
    // SwarmBar not running or hold expired: the TUI prompt stands alone.
  }
}
