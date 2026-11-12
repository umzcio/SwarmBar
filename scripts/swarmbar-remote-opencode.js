// swarmbar-remote-bridge-v1
// SwarmBar bridge for OpenCode on a remote host. Installed to
// ~/.config/opencode/plugins/swarmbar-remote.js and declared in
// ~/.config/opencode/opencode.jsonc (auto-discovery only scans
// project-level .opencode/plugin dirs).
//
// One file for both plugin systems. OpenCode 2 loads only a default
// export with an id and a setup(); OpenCode 1.17 and later take a default
// export with an id as their own module format and call its server().
// OpenCode 1 before that called every export as a function, so it cannot
// load this file.
//
// The same logic as the local plugin, posting to the SwarmBar helper's
// socket in this user's own home instead of the Mac's loopback port. The
// helper relays each post to every connected Mac. permission.asked fires
// whenever OpenCode prompts (the v1 "permission.ask" hook never fires in
// 1.18). The relay registers the prompt and holds for a decision while the
// TUI dialog shows as normal. If a Mac answers first,
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

// Holds for SwarmBar's decision and hands an allow or a deny to `answer`.
// Anything else, including no answer at all, leaves the TUI prompt alone.
async function relay(request, answer) {
  try {
    const body = await post("/hook/OpenCodePermission", request, 350_000)
    const decision = body && body.decision
    if (decision !== "allow" && decision !== "deny") return
    await answer(decision === "allow" ? "once" : "reject")
  } catch {
    // No helper listening or hold expired: the TUI prompt stands alone.
  }
}

// OpenCode 1.17 and later.
async function server({ client, directory }) {
  return {
    event: async ({ event }) => {
      const input = event.properties ?? {}
      if (event.type === "permission.asked") {
        relay({ ...input, directory }, (response) =>
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
        relay(asV1Request(data, directory), (decision) =>
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

export default { id: "swarmbar-remote", server, setup }
