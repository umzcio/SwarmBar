# Security Policy

## Supported Versions

SwarmBar is pre-release and moves fast. Only the latest commit on `main` is
supported with security fixes. There is no parallel maintenance of older
builds.

| Version | Supported |
|---------|-----------|
| latest  | ✅ |
| older   | ❌ |

## Reporting a Vulnerability

Please **do not** open a public GitHub issue for security vulnerabilities.

Use GitHub's [private vulnerability reporting](https://github.com/umzcio/SwarmBar/security/advisories/new)
for this repo instead. It opens a private draft advisory visible only to the
maintainer until a fix is ready. This applies especially to anything touching:

- The **loopback hook server** and its per-install token
  (`SwarmBar/Monitors/HookServer.swift`, `SwarmBar/Settings/HookToken.swift`).
  It listens on `127.0.0.1:48620` and can hold a Claude Code permission
  prompt open, so anything that lets an unauthenticated caller plant a row,
  resolve a decision, or exhaust the connection budget matters here.
- The **approve and deny paths** (`SwarmBar/Store/TerminalFocuser.swift`).
  These drive real terminals. A bug that sends the wrong keystroke can
  approve a command the user denied, which has happened before and is the
  reason the on-screen selector is read and re-confirmed rather than
  assumed.
- **Inline reply delivery**, which types user text into a live coding
  session via bracketed paste. Anything that could break out of the paste or
  submit unverified content belongs here.
- **AppleScript construction** (`SwarmBar/Store/AppleScriptLiteral.swift`).
  User-influenced text is interpolated into script source, so escaping
  failures are injection.
- **Config file writes** (`SwarmBar/Settings/IntegrationManager.swift`,
  `IntegrationTransforms.swift`). These edit real dotfiles under the user's
  home directory, resolve symlinks, and shell-quote installed paths.

You should receive an initial response within a few days. Confirmed
vulnerabilities will be credited in the fix's release notes unless you would
prefer to stay anonymous.

## Scope

SwarmBar runs entirely on your own machine. There is no SwarmBar-operated
backend, no account, and no telemetry. It makes exactly one network call, an
unauthenticated request to the GitHub releases API, and only when you press
Check for updates in Settings. Nothing is checked on launch or on a timer.

Worth knowing about the threat model, since it is unusual for a status bar
app:

- **The App Sandbox is off.** Monitors need to read agent state directories
  across the home directory, which the sandbox does not permit. This is a
  deliberate tradeoff for a personal tool and is listed for revisiting
  before any wider distribution.
- **SwarmBar reads agent transcripts.** Those contain whatever you and your
  agents discussed, including anything sensitive in a prompt or a tool
  result. Nothing is transmitted, but it is held in memory and rendered in
  the popover.
- **Builds are not yet signed or notarized.** Until they are, verify what
  you are running by building from source.

Findings in macOS itself or in the agent tools SwarmBar watches should
generally be reported upstream, but flag them here too if you are not sure.
