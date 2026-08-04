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
import { readFileSync } from "node:fs"
import { homedir } from "node:os"

const SWARMBAR = "http://127.0.0.1:48620"

// Read once at plugin load. Fails open: if the file cannot be read (not
// yet minted, permissions, different home directory), the token is just
// empty and the request still goes out; the server decides from there.
function loadToken() {
  try {
    return readFileSync(
      `${homedir()}/Library/Application Support/SwarmBar/hook-token`,
      "utf8"
    ).trim()
  } catch {
    return ""
  }
}
const TOKEN = loadToken()

export const SwarmBarPlugin = async ({ client, directory }) => {
  return {
    event: async ({ event }) => {
      if (event.type === "permission.asked") {
        relay(client, event.properties ?? {}, directory)
      }
      if (event.type === "permission.replied") {
        fetch(`${SWARMBAR}/hook/OpenCodeReplied`, {
          method: "POST",
          headers: { "content-type": "application/json", "X-SwarmBar-Token": TOKEN },
          body: JSON.stringify(event.properties ?? {}),
        }).catch(() => {})
      }
    },
  }
}

async function relay(client, input, directory) {
  try {
    const res = await fetch(`${SWARMBAR}/hook/OpenCodePermission`, {
      method: "POST",
      headers: { "content-type": "application/json", "X-SwarmBar-Token": TOKEN },
      body: JSON.stringify({ ...input, directory }),
      signal: AbortSignal.timeout(350_000),
    })
    if (!res.ok) return
    const body = await res.json().catch(() => null)
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
