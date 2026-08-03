// SwarmBar bridge for OpenCode. Install by copying to
// ~/.config/opencode/plugins/swarmbar.js (loaded at opencode startup).
//
// permission.ask fires whenever OpenCode is about to prompt. The hook
// returns immediately so the TUI dialog shows as normal, while a detached
// task registers the prompt with the SwarmBar menu bar app and holds for
// its decision. If SwarmBar answers first, the decision is applied through
// the server's own permission endpoint; if the user answers in the TUI
// first (or SwarmBar is not running), the held request resolves empty and
// nothing happens. permission.replied events are forwarded so SwarmBar
// clears its approval row no matter where the prompt was answered.
const SWARMBAR = "http://127.0.0.1:48620"

export const SwarmBarPlugin = async ({ client, directory }) => {
  return {
    "permission.ask": async (input, output) => {
      relay(client, input, directory)
      // output.status stays "ask": the TUI prompt always shows.
    },
    event: async ({ event }) => {
      if (event.type === "permission.replied") {
        fetch(`${SWARMBAR}/hook/OpenCodeReplied`, {
          method: "POST",
          headers: { "content-type": "application/json" },
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
      headers: { "content-type": "application/json" },
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
