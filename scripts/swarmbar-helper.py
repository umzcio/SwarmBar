#!/usr/bin/env python3
"""SwarmBar remote helper.

Ships bytes, never verdicts. It enumerates agent state and returns file
tails; the Mac parses them with the same parsers it uses locally, so every
parser stays a single implementation.

Constraints that are not negotiable:
  * python 3.9 compatible. umzmac ships stock Apple 3.9.6.
  * No GNU-only userland. `ps --no-headers` and `find -printf` fail on
    Darwin, and a failed `ps` piped into a filter yields an empty list
    that reads exactly like "no sessions".
  * Read-only. This never writes to any agent's state.
"""

import json
import os
import platform
import subprocess
import sys
import time

# 2 added "created" to every session record. Additive: an older Mac
# ignores the field and an older helper simply omits it.
PROTOCOL_VERSION = 2

# Only files touched inside this window are worth shipping. Matches
# ClaudeCodeMonitor.discoveryWindow on the Mac.
DISCOVERY_WINDOW_SECONDS = 8 * 60 * 60

TAIL_BYTES = 64 * 1024

# Ceiling for the growing tail read, matching ClaudeCodeMonitor.maxTailBytes
# on the Mac. A single record larger than this is pathological; giving up
# keeps a runaway file from being read whole on every poll.
MAX_TAIL_BYTES = 4 * 1024 * 1024


class _Sentinel(object):
    """Distinguishable non-string results from tail_of."""

    def __init__(self, name):
        self.name = name

    def __repr__(self):
        return self.name


# The window grew to the ceiling and still held no complete record.
OVERSIZED = _Sentinel("OVERSIZED")
# The file holds no complete record at all: one partial line, still being
# written, with no newline anywhere in it.
INCOMPLETE = _Sentinel("INCOMPLETE")

# A backup directory is shape-identical to a live root: it is prefixed
# .claude and it contains projects/. On umzcaio,
# /root/.claude-cio.pre-symlink-backup/projects holds 344 transcripts.
# Only a stale mtime keeps it out today, and that protection disappears
# the moment a backup is taken recently. So exclude by name, explicitly.
BACKUP_MARKERS = ("backup", ".bak", "-bak", ".pre-", ".old", "-old", ".copy", "~")


def is_backup_name(name):
    lowered = name.lower()
    return any(marker in lowered for marker in BACKUP_MARKERS)


def home_dirs():
    """Every home on this host, root's included. Darwin and Linux differ."""
    homes = []
    if platform.system() == "Darwin":
        homes.append("/var/root")
        parent = "/Users"
    else:
        homes.append("/root")
        parent = "/home"
    try:
        for entry in sorted(os.listdir(parent)):
            path = os.path.join(parent, entry)
            if os.path.isdir(path):
                homes.append(path)
    except OSError:
        pass
    return [h for h in homes if os.path.isdir(h)]


def claude_roots(warnings):
    """<home>/.claude*/projects, excluding backup directories.

    Globbing must happen here, inside the privileged process. Running
    `sudo -n ls -d /root/.claude*` from an unprivileged shell returns
    nothing at all, because that shell cannot read /root so the glob never
    expands and is passed through literally. Every literal path in the same
    command succeeds, which is what makes the failure so convincing.
    """
    roots = []
    seen = set()
    for home in home_dirs():
        try:
            entries = sorted(os.listdir(home))
        except OSError:
            continue
        for entry in entries:
            if not entry.startswith(".claude"):
                continue
            if is_backup_name(entry):
                warnings.append("skipped backup-looking root: %s" % os.path.join(home, entry))
                continue
            projects = os.path.join(home, entry, "projects")
            if not os.path.isdir(projects):
                continue
            resolved = os.path.realpath(projects)
            if resolved in seen:
                continue
            seen.add(resolved)
            roots.append(resolved)
    return roots


def whole_lines(data):
    """Drops a dangling final line.

    A session actively being worked on is normally mid-write, so the file
    on disk commonly ends without a trailing newline. Trimming that partial
    line means what is shipped is always whole records, never a truncated
    fragment of the last one.
    """
    if data and not data.endswith(b"\n"):
        last_newline = data.rfind(b"\n")
        data = data[:last_newline + 1] if last_newline != -1 else b""
    return data


def tail_of(path, size):
    """The trailing complete lines of a JSONL file.

    Starts at TAIL_BYTES and doubles until the window holds at least one
    complete record, mirroring ClaudeCodeMonitor.tail(of:) on the Mac. A
    single record larger than the window would otherwise leave nothing
    complete behind it, and shipping the empty string that results is far
    worse here than locally: the Mac's parser returns nil for it, the record
    never reaches `incomingIds`, and SessionStore.sync DELETES the row. The
    session is on screen one poll and gone the next, with no warning on
    either side, and the window is open exactly when a session is busiest.
    Reading from offset 0 always counts as complete.

    Returns the tail as text, or None if the file cannot be read, or the
    OVERSIZED / INCOMPLETE sentinels when no complete record could be
    obtained. The caller must omit those records rather than ship an empty
    tail.
    """
    try:
        with open(path, "rb") as handle:
            window = TAIL_BYTES
            while True:
                offset = size - window if size > window else 0
                handle.seek(offset)
                data = handle.read()
                if offset == 0:
                    data = whole_lines(data)
                    if not data:
                        return INCOMPLETE
                    return data.decode("utf-8", "replace")
                # The window's first newline ends the partial first record.
                # Anything after it is whole; nothing after it means one
                # oversized record fills the window and it has to grow.
                newline = data.find(b"\n")
                if newline != -1:
                    remainder = whole_lines(data[newline + 1:])
                    if remainder:
                        return remainder.decode("utf-8", "replace")
                if window >= MAX_TAIL_BYTES:
                    return OVERSIZED
                window = min(window * 2, MAX_TAIL_BYTES)
    except OSError:
        return None


def created_time(stat):
    """Session start, as close as this platform will give it.

    st_birthtime is the real thing and Darwin has it. Linux does not expose
    it through os.stat before python 3.12, so there st_ctime stands in.
    POSIX requires write() to update both mtime and ctime, so ctime tracks
    every write and usually equals mtime for a transcript that is actively
    being appended to. It is not, however, bounded by the last write: a
    metadata-only change (chmod, chown, rename, a hardlink) bumps ctime
    without touching mtime, so ctime can land AFTER mtime. That is reachable
    here, and when it happens the Mac side clamps the visible elapsed time
    at zero rather than showing a negative duration (see ElapsedTimeText and
    RemoteSnapshot.swift).
    """
    birth = getattr(stat, "st_birthtime", None)
    if birth:
        return birth
    return stat.st_ctime


def claude_sessions(now, warnings, roots):
    sessions = []
    for root in roots:
        try:
            project_dirs = sorted(os.listdir(root))
        except OSError:
            continue
        for project_dir in project_dirs:
            directory = os.path.join(root, project_dir)
            if not os.path.isdir(directory):
                continue
            try:
                names = sorted(os.listdir(directory))
            except OSError:
                continue
            for name in names:
                if not name.endswith(".jsonl"):
                    continue
                path = os.path.join(directory, name)
                try:
                    stat = os.stat(path)
                except OSError:
                    continue
                if now - stat.st_mtime >= DISCOVERY_WINDOW_SECONDS:
                    continue
                tail = tail_of(path, stat.st_size)
                if tail is None:
                    warnings.append("unreadable: %s" % path)
                    continue
                # Omitting the record says nothing about the session, which
                # is recoverable on the next poll. Shipping an empty tail
                # would delete its row on the Mac, which is not.
                if tail is OVERSIZED:
                    warnings.append(
                        "no complete record within %d bytes, omitted: %s"
                        % (MAX_TAIL_BYTES, path))
                    continue
                if tail is INCOMPLETE:
                    warnings.append("no complete record yet, omitted: %s" % path)
                    continue
                sessions.append({
                    "tool": "claudeCode",
                    "path": path,
                    "root": root,
                    "project_dir": project_dir,
                    "mtime": stat.st_mtime,
                    "created": created_time(stat),
                    "size": stat.st_size,
                    "tail": tail,
                })
    return sessions


def process_cwd(pid):
    """Portable enough for both fleets. /proc is Linux only."""
    if platform.system() != "Darwin":
        try:
            return os.readlink("/proc/%d/cwd" % pid)
        except OSError:
            return ""
    try:
        out = subprocess.run(
            ["lsof", "-a", "-p", str(pid), "-d", "cwd", "-Fn"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=5,
        ).stdout.decode("utf-8", "replace")
    except (OSError, subprocess.SubprocessError):
        return ""
    for line in out.splitlines():
        if line.startswith("n"):
            return line[1:]
    return ""


AGENT_COMMANDS = ("claude", "codex", "kimi", "kimi-code", "opencode", "grok", "agy")


def agent_processes(warnings):
    """Live agent processes. `ps -axo` is portable; GNU long flags are not."""
    try:
        completed = subprocess.run(
            ["ps", "-axo", "pid=,user=,comm="],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15,
        )
    except (OSError, subprocess.SubprocessError) as error:
        warnings.append("ps failed: %s" % error)
        return None
    if completed.returncode != 0:
        warnings.append("ps exited %d: %s" % (
            completed.returncode,
            completed.stderr.decode("utf-8", "replace").strip(),
        ))
        return None

    processes = []
    for line in completed.stdout.decode("utf-8", "replace").splitlines():
        parts = line.split(None, 2)
        if len(parts) < 3:
            continue
        pid_text, user, comm = parts
        comm = comm.strip().split("/")[-1]
        if comm not in AGENT_COMMANDS:
            continue
        try:
            pid = int(pid_text)
        except ValueError:
            continue
        processes.append({
            "pid": pid, "user": user, "comm": comm, "cwd": process_cwd(pid),
        })
    return processes


def snapshot():
    now = time.time()
    warnings = []
    roots = claude_roots(warnings)
    sessions = claude_sessions(now, warnings, roots)
    processes = agent_processes(warnings)
    payload = {
        "ok": True,
        "protocol": PROTOCOL_VERSION,
        "hostname": platform.node(),
        "system": platform.system(),
        "now": now,
        "roots": roots,
        "sessions": sessions,
        "warnings": warnings,
    }
    # None means ps itself failed. An empty list would be indistinguishable
    # from "no agents running", and that is exactly the failure this
    # protocol exists to make visible.
    if processes is None:
        payload["processes"] = []
        payload["processes_failed"] = True
    else:
        payload["processes"] = processes
        payload["processes_failed"] = False
    return payload


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            request = json.loads(line)
        except ValueError:
            sys.stdout.write(json.dumps({"ok": False, "error": "malformed request"}) + "\n")
            sys.stdout.flush()
            continue
        command = request.get("cmd")
        try:
            if command == "snapshot":
                response = snapshot()
            elif command == "ping":
                response = {"ok": True, "protocol": PROTOCOL_VERSION}
            else:
                response = {"ok": False, "error": "unknown command: %s" % command}
        except Exception as error:
            # Every filesystem and process call above is individually
            # defensive, but this is the backstop: no exception may skip
            # a response line, or the one-JSON-object-per-line contract
            # breaks for the rest of the stdin stream. Keep the message
            # short; no traceback in the JSON.
            response = {"ok": False, "error": "internal error: %s" % error}
        sys.stdout.write(json.dumps(response) + "\n")
        sys.stdout.flush()


if __name__ == "__main__":
    main()
