import Foundation

// Phase 4 stubs. State-dir survey of this machine (2026-08-02):
//
// Kimi Code: ~/.kimi-code/session_index.jsonl maps sessionId -> sessionDir
// -> workDir; each sessionDir has state.json (workDir, updatedAt) and
// agents/main/wire.jsonl (protocol events, epoch-millisecond timestamps).
// Sessions observed so far are empty shells; revisit mapping once real
// conversations exist to sample.
struct KimiMonitor: SessionMonitor {
    func start(into store: SessionStore) async { }
}

// OpenCode: state is SQLite at ~/.local/share/opencode/opencode.db
// (session / message / part tables, JSON blobs, epoch-millisecond times).
// Needs a read-only sqlite reader; session.directory carries the cwd and a
// trailing step-start part without step-finish implies an in-flight turn.
struct OpenCodeMonitor: SessionMonitor {
    func start(into store: SessionStore) async { }
}

// Grok Build: ~/.grok/active_sessions.json is the live-session fast path
// (pid + session id when running); per-session dirs under ~/.grok/sessions/
// <url-encoded-cwd>/<uuid>/ hold summary.json (cwd, updated_at, agent_name)
// plus chat_history.jsonl and events.jsonl.
struct GrokBuildMonitor: SessionMonitor {
    func start(into store: SessionStore) async { }
}
