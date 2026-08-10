# Contributing to SwarmBar

Thanks for considering a contribution. SwarmBar is a Swift 6 / SwiftUI macOS menu bar app with
strict concurrency and one third-party dependency (Sparkle, for self-updating). This doc covers local setup, the conventions
the codebase expects, and how to get a change merged.

Two things are unusual about this project and worth reading before you start: the design spec is an
HTML file, and several behaviours can only be verified by running real coding agents. Both are
explained below.

## Local Development Setup

**Prerequisites:**
- macOS 26 or later (the deployment target is 26.0 and there are deliberately no availability
  fallbacks for older systems)
- Xcode with the macOS 26 SDK
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

```bash
git clone https://github.com/umzcio/SwarmBar.git
cd SwarmBar
xcodegen generate
xcodebuild -project SwarmBar.xcodeproj -scheme SwarmBar -configuration Debug build
```

### Project generation

`project.yml` is the source of truth. The `.xcodeproj` is generated and gitignored, so **never edit
it by hand and never commit it.**

**Run `xcodegen generate` whenever you add, move, or delete a file.** Forgetting is the single most
common way to lose an afternoon here: the file exists on disk, the compiler never sees it, and the
error you get points somewhere else entirely.

## The Gate

Every change must pass, in full, before it is mergeable:

```bash
xcodegen generate
xcodebuild -project SwarmBar.xcodeproj -scheme SwarmBar -configuration Debug test
```

The suite is fast (under two seconds) and currently green with no known failures, so there is no
baseline of tolerated breakage. Anything red on your branch blocks merge.

## Conventions

### The prototype is the spec

`swarmbar-prototype.html` defines colours, spacing, section order, status vocabulary, both density
modes, and interaction patterns. `swarm-glyph-hexgrid.html` defines the menu bar icon. Open them in
a browser and match them. Where native SwiftUI cannot match exactly, get as close as it allows and
say so in the PR.

This cuts both ways. If the ramp of type sizes in the app looks excessive, check the prototype
before "cleaning it up": the sizes come from there, and collapsing them is a divergence from the
spec rather than a tidy-up.

### Monitors are read-only

Monitors tail transcripts, session indexes, and state databases. **They never write to them.**

Exactly two kinds of write are allowed and both are deliberate. Approve and deny answer through
each tool's own control channel, never by editing files. Config files are written only by
`IntegrationManager`, only for bridges the user switches on in Settings, and only through the pure
transforms in `IntegrationTransforms`, which resolve symlinks, preserve hardlinks, and leave a
one-time `.backup-swarmbar` copy.

### No dependencies

Zero third-party packages. If you think you need one, open an issue first.

### Copy style

Sentence case, plain verbs ("Approve", "Deny", "Reply", "Pause all agents"). **No em dashes**
anywhere in UI copy or documentation, including this file.

## Testing

Unit test the pure parts: status mapping from transcript events, section derivation, elapsed-time
formatting, config transforms, keystroke script construction. Parser changes should come with a
fixture in `Tests/Fixtures/`.

There are no UI tests, and adding them is not the goal. What matters more:

**Do not write a test that cannot fail.** SwiftUI makes this easy to do by accident. A test that
measured a row's rendered width to prove a scale setting was wired up passed just as happily
against code with the wiring deleted, because the fonts scaled on their own. If you write a test
for view behaviour, delete the implementation and confirm the test goes red before you trust it.

**Some things genuinely are not testable in process**, and the honest move is to say so rather than
to write a test that pretends. A row's buttons winning a click over its double-click gesture is one
of these: SwiftUI renders the row into a single `NSView` whose accessibility children do not
surface and whose hit testing does not discriminate. Those cases get a comment explaining what was
tried, and a manual checklist instead.

### Live verification

Approve and deny drive real coding sessions through terminal automation. Code review and unit tests
are not sufficient evidence that they work, because the failure modes are behavioural: a selector
list that wraps, a hook runner that treats a timeout as consent, a keystroke that lands on the wrong
option.

If you change an approval path, run it against a real session of that tool, both directions, and
put what you observed in the PR.

## Making a Change

1. Branch from `main`.
2. Keep the change focused. Unrelated refactors in the same PR make the interesting part hard to
   review.
3. Match the surrounding code's comment density and naming. Comments here explain **why**,
   especially where the obvious implementation is wrong for a non-obvious reason.
4. Run the gate.
5. If you touched anything visual, compare against the prototype.

## Commit Messages

Write a subject line that says what changed in plain language, then a body that explains why it
needed to change. If the fix is non-obvious, say what the failure looked like and what evidence
established it. Commits here double as the project's memory of behaviour that was expensive to
discover.

## Pull Requests

Include what you changed, why, and how you verified it. Screenshots for anything visual. For
approval paths, the live round and what the tool actually did.

If you found a real problem while working and chose not to fix it, say so in the PR rather than
leaving it silent.

## Security

Please do not open a public issue for a vulnerability. See [SECURITY.md](SECURITY.md).

## License

By contributing, you agree that your contributions are licensed under the MIT License, the same as
the rest of the project. See [LICENSE](LICENSE).
