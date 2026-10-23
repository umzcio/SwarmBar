// swarmbar-remote-bridge-v1
// SwarmBar bridge for OpenCode on a remote host. Installed to
// ~/.config/opencode/plugins/swarmbar-remote.js and declared in
// ~/.config/opencode/opencode.jsonc (auto-discovery only scans
// project-level .opencode/plugin dirs).
//
// The same logic as the local plugin, posting to the SwarmBar helper's
// socket in this user's own home instead of the Mac's loopback port. The
// helper relays each post to every connected Mac. permission.asked fires on
// the event bus whenever OpenCode prompts (the v1 "permission.ask" hook
// never fires in 1.18). The relay registers the prompt and holds for a
// decision while the TUI dialog shows as normal. If a Mac answers first,
// the decision is applied through the server's own permission endpoint; if
// the user answers in the TUI first (or no helper is listening), the held
// request resolves empty and nothing happens. permission.replied is
// forwarded so SwarmBar clears its approval row no matter where the prompt
// was answered.
//
// No token: the socket is mode 600 inside a mode 700 directory owned by
// this user, so only this user and root can post to it at all.
import { request } from "node:http"
import { homedir } from "node:os"

const SOCKET = `${homedir()}/.swarmbar/hook.sock`

// Posts a JSON body and resolves with the parsed answer, or null for any
// failure: no socket, a timeout, a body that is not JSON.
function post(path, payload, timeoutMs) {
  return new Promise((resolve) => {
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

export const SwarmBarRemotePlugin = async ({ client, directory }) => {
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
    // No helper listening or hold expired: the TUI prompt stands alone.
  }
}
