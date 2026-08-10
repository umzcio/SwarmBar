<p align="center">
  <img src="assets/logo.png" alt="SwarmBar" width="140" />
</p>

<p align="center">
  <img src="https://img.shields.io/badge/swarmbar-Agent_Status_At_A_Glance-FF9F0A?style=for-the-badge&labelColor=0C0D14" alt="SwarmBar" />
</p>

<p align="center">
  <a href="https://github.com/umzcio/SwarmBar/releases/latest"><img src="https://img.shields.io/github/v/release/umzcio/SwarmBar?style=flat-square&color=FF9F0A&labelColor=0C0D14" alt="Latest release" /></a>
  <a href="https://github.com/umzcio/SwarmBar/actions/workflows/ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/umzcio/SwarmBar/ci.yml?branch=main&style=flat-square&label=tests&color=30D158&labelColor=0C0D14" alt="CI" /></a>
  <img src="https://img.shields.io/badge/signed-notarized-30D158?style=flat-square&labelColor=0C0D14" alt="Signed and notarized" />
  <img src="https://img.shields.io/badge/license-MIT-FF9F0A?style=flat-square&labelColor=0C0D14" alt="MIT" />
  <img src="https://img.shields.io/badge/stack-Swift%206%20%7C%20SwiftUI-0C0D14?style=flat-square" alt="Stack" />
  <img src="https://img.shields.io/badge/platform-macOS%2026%2B-30D158?style=flat-square&labelColor=0C0D14" alt="macOS 26+" />
  <img src="https://img.shields.io/badge/dependencies-1_(Sparkle)-30D158?style=flat-square&labelColor=0C0D14" alt="One dependency" />
</p>

<p align="center">
  <strong>A macOS menu bar app that answers one question: do any of my agents need me right now?</strong><br/>
  Watches Claude Code, Codex, Kimi Code, BearCode, OpenCode, Grok Build, and Antigravity across
  every concurrent session, surfaces the ones waiting on you, and lets you approve, deny, or reply
  without leaving the menu bar.<br/><br/>
  <a href="#quick-start">Quick Start</a> · <a href="#how-it-works">How It Works</a> · <a href="#supported-agents">Supported Agents</a> · <a href="#features">Features</a> · <a href="#architecture">Architecture</a>
</p>

---

## Why

Running one coding agent is fine. Running seven is a tab-hunting problem.

Agents block on permission prompts, finish turns quietly, and ask clarifying questions into
terminal windows you are not looking at. The cost is not the waiting, it is the discovery: cycling
through windows to find which session stalled twenty minutes ago on a yes-or-no question.

SwarmBar puts that in the menu bar. Sessions sort into **Needs you**, **Active**, and **Recent**,
the icon animates only while agents are working, and an approval prompt can be answered from the
popover with the command visible in front of you.

It reads each tool's own state and speaks each tool's own control channel. There is no daemon to
install in your agents, no wrapper to launch them through, and no telemetry going anywhere.

---

## How It Works

```
Agent writes state --> Monitor tails it --> Status derived --> Popover section --> You answer
```

1. **Each tool gets a monitor.** They tail transcripts, session indexes, and state databases that
   the tools already write, and map trailing events to a status.
2. **Approvals arrive faster over hooks.** Where a tool supports it, a small bridge script posts
   to a loopback server so a pending prompt shows up immediately rather than on the next poll.
3. **Sections answer the question.** Needs you means answer something. Active means the process is
   alive. Recent means it is over.
4. **You answer in place.** Approve and deny go back through each tool's own control channel.
   Replies are delivered to the session's terminal so you can steer a finished turn without
   switching windows.

Monitors are strictly read-only. Nothing is ever written to an agent's session or transcript state.

---

## Supported Agents

| Agent | Detection | Approve / Deny | Notes |
|-------|-----------|----------------|-------|
| Claude Code | transcripts + hooks | held hook response | The only tool whose hook carries a decision |
| Codex | rollout files | tty hotkeys | ESC is the only deny Codex offers |
| Kimi Code | session index + wire log | on-screen selector | The selector is read, never assumed |
| BearCode | same as Kimi | on-screen selector | Rides the Kimi family layout |
| OpenCode | in-process plugin | plugin respond endpoint | Prompts only where config has ask rules |
| Grok Build | update stream | tty keystrokes | Its hook runner ignores deny responses |
| Antigravity | presence lock + transcript | on-screen selector | Walked to with arrows, never a digit |

Keystroke-answered tools require **iTerm2**, and that is a design choice rather than a gap.
iTerm2 can deliver a keystroke to one specific session, addressed by its tty, without touching
what you are looking at. Other terminals only offer "type into whatever is frontmost", which
would mean stealing your focus and racing you for it. Everywhere else, Approve and Deny focus
the terminal instead of answering for you.

---

## Features

### At a glance
- Three sections that mean something: Needs you, Active, Recent.
- Comfortable and compact densities, plus a Small / Medium / Large size that scales the whole
  popover rather than only the type.
- A menu bar icon that encodes state in shape and opacity, never colour, and animates only while
  work is happening. All motion respects Reduce Motion.

### Answering
- Approve and deny from the popover, with the command shown in monospace.
- Inline reply: write a multi-line answer in the popover and send it to a session whose turn has
  ended, without visiting the terminal.
- Double-click a row to jump to its terminal. Right-click for the path.

### Safety
- Monitors never write to agent state.
- The loopback hook channel is authenticated per install.
- Config files are touched only for bridges you switch on in Settings, always through pure
  transforms, always leaving a one-time backup, and always preserving symlinks and hardlinks so
  shared profile dotfiles stay shared.

---

## Tech Stack

- **Swift 6** with strict concurrency set to `complete`
- **SwiftUI** only, `MenuBarExtra` in window style, with AppKit used solely for the status item
- **macOS 26+**, no availability fallbacks
- **XcodeGen** so the project is defined by `project.yml` rather than a checked-in `.xcodeproj`
- **One third-party dependency.** [Sparkle](https://github.com/sparkle-project/Sparkle), for
  updates that install themselves. Self-updating replaces the running app with a file from the
  network, and the signature check that makes that safe is the last thing worth hand-rolling.
  Everything else is the system `libsqlite3`, used to read Codex's own state database

---

## Architecture

A single `@Observable SessionStore` is the source of truth. `SessionMonitor` is the boundary with
one conformer per tool, so adding an agent means adding a monitor and nothing else. `SessionStatus`
is an enum with associated values, and `needsAttention` / `isActive` are computed from it, which is
what makes the three sections fall out rather than be maintained.

```
SwarmBar/
  Monitors/     One per tool, plus the loopback hook server
  Store/        SessionStore, terminal automation, status model
  Views/        Popover, rows, settings, reply composer
  Settings/     Bridge install and removal, pure config transforms
Tests/          Parsers, transforms, sections, timers, typography
scripts/        Bridge scripts installed into Application Support
```

---

## Quick Start

### Install

Signed and notarized builds are published to the
[Releases](https://github.com/umzcio/SwarmBar/releases) page. Download the latest, drag it to
`/Applications`, and launch it. There is no Dock icon by design: look for the hexagon in the menu
bar.

SwarmBar updates itself from there: Settings has a Check for updates button, and it also checks
quietly in the background.

### Build from source

**Prerequisites:** macOS 26+, Xcode with the macOS 26 SDK, and
[XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
git clone https://github.com/umzcio/SwarmBar.git
cd SwarmBar

xcodegen generate
xcodebuild -project SwarmBar.xcodeproj -scheme SwarmBar -configuration Release build
```

The built app lands in the Xcode derived data path printed at the end of the build. Copy it to
`/Applications` and launch it.

`xcodegen generate` has to run whenever files are added, since `project.yml` is the source of truth
and the `.xcodeproj` is generated and gitignored.

### Tests

```bash
xcodebuild -project SwarmBar.xcodeproj -scheme SwarmBar -configuration Debug test
```

### Optional: approval bridges

Open Settings from the popover footer and switch on the tools you use. Each toggle installs a small
script and registers it with that tool's own hook or plugin mechanism, and leaves a
`.backup-swarmbar` copy of any config it edits. Detection works without them; they make pending
approvals appear immediately.

---

## Roadmap

- Remote sessions over SSH
- More agents, added the way the seven built in were

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). The short version: match the HTML prototype, keep monitors
read-only, add no dependencies, and unit test the pure parts.

## Security

See [SECURITY.md](SECURITY.md). Please report vulnerabilities privately rather than in an issue.

## License

MIT. See [LICENSE](LICENSE).
