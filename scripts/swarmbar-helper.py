#!/usr/bin/env python3
"""SwarmBar remote helper.

Ships bytes, never verdicts. It lists agent state files for all seven tools
and returns their bytes at their true offsets; the Mac writes those into a
sparse mirror and runs the same monitors it runs locally, so every parser
stays a single implementation.

Constraints that are not negotiable:
  * python 3.9 compatible. umzmac ships stock Apple 3.9.6.
  * No GNU-only userland. `ps --no-headers` and `find -printf` fail on
    Darwin, and a failed `ps` piped into a filter yields an empty list
    that reads exactly like "no sessions".
  * Read-only. This never writes to any agent's state.
"""

import base64
import collections
import glob
import hashlib
import json
import os
import platform
import stat as stat_module
import subprocess
import sys
import threading
import time

# 2 added "created" to every session record. Additive: an older Mac
# ignores the field and an older helper simply omits it.
# 3 frames every request with an "id" that the response echoes, and lets the
# helper push unsolicited {"event": ...} lines that carry no id. Its snapshot
# is an incremental file manifest, replacing phase 1a's "sessions".
PROTOCOL_VERSION = 3

# Fixed for the life of the process. A Mac that sees it change knows the
# helper restarted underneath it and that anything cached is stale.
STREAM_ID = os.urandom(8).hex()

# The stream main was given, and the lock that keeps lines whole. Socket
# threads push events while the request loop answers, so every write goes
# through write_line or two JSON objects could interleave mid-line.
_OUT = sys.stdout
_WRITE_LOCK = threading.Lock()


def write_line(obj):
    """The only function that writes to the output stream."""
    text = json.dumps(obj) + "\n"
    with _WRITE_LOCK:
        _OUT.write(text)
        _OUT.flush()

# Only files touched inside this window are worth shipping. Matches
# ClaudeCodeMonitor.discoveryWindow on the Mac.
DISCOVERY_WINDOW_SECONDS = 8 * 60 * 60

TAIL_BYTES = 64 * 1024

# Ceiling for the growing tail read, matching ClaudeCodeMonitor.maxTailBytes
# on the Mac. A single record larger than this is pathological; giving up
# keeps a runaway file from being read whole on every poll.
MAX_TAIL_BYTES = 4 * 1024 * 1024

# Ceiling for the head read, matching CodexMonitor.maxHeadBytes. Codex's
# first line carries base_instructions and runs to about 19 KB, so the
# window grows from HEAD_BYTES until it holds a newline.
HEAD_BYTES = 32 * 1024
MAX_HEAD_BYTES = 1024 * 1024

# A "whole" file over this is listed in `omitted` rather than shipped. These
# are small JSON indexes and sqlite databases; anything this size is not
# what the Mac's monitor expects, and re-shipping it on every change would
# swamp the channel.
WHOLE_MAX_BYTES = 16 * 1024 * 1024


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
    """The homes to scan. Darwin and Linux differ.

    SWARMBAR_HELPER_HOMES (colon-separated) replaces discovery so tests never
    read a real home. Without it, root sees every home, while any other user
    sees only its own: listing /home as an unprivileged user would offer
    directories it cannot read.
    """
    override = os.environ.get("SWARMBAR_HELPER_HOMES")
    if override:
        return [h for h in override.split(":") if h and os.path.isdir(h)]
    if os.geteuid() != 0:
        home = os.path.expanduser("~")
        return [home] if os.path.isdir(home) else []
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
    """<home>/.claude*/projects, excluding backup directories and second
    names for a root already found.

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
            # Deduped by realpath, but returned as found: a root symlinked
            # elsewhere still has to mirror under the home it was found
            # in, or its files lose their place relative to that home.
            resolved = os.path.realpath(projects)
            if resolved in seen:
                continue
            seen.add(resolved)
            roots.append(projects)
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


def tail_window(path, size, start=TAIL_BYTES):
    """Locates the trailing complete records of a JSONL file.

    Starts at `start` bytes and doubles until the window holds at least one
    complete record, mirroring ClaudeCodeMonitor.tail(of:) on the Mac. A
    single record larger than the window would otherwise leave nothing
    complete behind it, and shipping the empty result is far worse remotely
    than locally: the Mac's parser returns nil for it, the record never
    reaches `incomingIds`, and SessionStore.sync DELETES the row. The
    session is on screen one poll and gone the next, with no warning on
    either side, and the window is open exactly when a session is busiest.
    Reading from offset 0 always counts as complete.

    Returns (offset, data, first): `data` is the file's raw bytes from
    `offset` up to `size`, and `first` is where the first complete record
    starts within it. Returns None if the file cannot be read, or the
    OVERSIZED / INCOMPLETE sentinels when no complete record could be
    obtained. The read stops at `size` so the bytes always agree with the
    stat the caller reports, even while the file is being appended to.
    """
    try:
        with open(path, "rb") as handle:
            window = start
            while True:
                offset = size - window if size > window else 0
                handle.seek(offset)
                data = handle.read(size - offset)
                if offset == 0:
                    if not whole_lines(data):
                        return INCOMPLETE
                    return 0, data, 0
                # The window's first newline ends the partial first record.
                # Anything after it is whole; nothing after it means one
                # oversized record fills the window and it has to grow.
                newline = data.find(b"\n")
                if newline != -1 and whole_lines(data[newline + 1:]):
                    return offset, data, newline + 1
                if window >= MAX_TAIL_BYTES:
                    return OVERSIZED
                window = min(window * 2, MAX_TAIL_BYTES)
    except OSError:
        return None


def tail_of(path, size):
    """The trailing complete lines of a JSONL file, as text.

    Returns the tail, or whatever tail_window returned in place of one. The
    caller must omit OVERSIZED and INCOMPLETE records rather than ship an
    empty tail.
    """
    found = tail_window(path, size)
    if not isinstance(found, tuple):
        return found
    _, data, first = found
    return whole_lines(data[first:]).decode("utf-8", "replace")


def tail_chunk(path, size, start=TAIL_BYTES):
    """The tail as one chunk, (offset, bytes), at its true offset.

    Unlike tail_of, the chunk runs through `size`, partial last line
    included, so the next poll's growth chunk starts exactly where this one
    ends and the mirror never holds a hole. It also starts one byte early,
    on the newline that ends the record before it. Everything ahead of the
    chunk is a hole in the Mac's sparse mirror, which reads back as zeros;
    without that newline the zeros and the first shipped record would read
    as one line, and a reader that drops a partial first line would drop
    a real record with it.
    """
    found = tail_window(path, size, start)
    if not isinstance(found, tuple):
        return found
    offset, data, first = found
    if first > 0:
        first -= 1
    return offset + first, data[first:]


def head_chunk(path, size):
    """The first line, newline included, as (0, bytes).

    Grows from HEAD_BYTES the way CodexMonitor.headText does. With no
    newline inside MAX_HEAD_BYTES it ships what it read, which is what
    headText would have handed the parser locally.
    """
    try:
        with open(path, "rb") as handle:
            data = b""
            window = HEAD_BYTES
            limit = min(size, MAX_HEAD_BYTES)
            while len(data) < limit:
                piece = handle.read(min(window, limit - len(data)))
                if not piece:
                    break
                data += piece
                newline = data.find(b"\n")
                if newline != -1:
                    return 0, data[:newline + 1]
                window *= 2
            return 0, data
    except OSError:
        return None


def whole_chunk(path, size):
    try:
        with open(path, "rb") as handle:
            return 0, handle.read(size)
    except OSError:
        return None


def created_time(stat):
    """The file's birth time where the platform records one, else None.

    Darwin has st_birthtime. Linux does not expose it through os.stat
    before python 3.12, and st_ctime is no substitute: POSIX requires
    write() to update ctime, so for any file inside the discovery window it
    equals mtime. A null tells the Mac to derive the start from the head
    record instead of trusting a date that is really the last write.
    """
    birth = getattr(stat, "st_birthtime", None)
    return birth if birth else None


# One row of SPECS. `tail_start` is the first tail window for "tail" and
# "head_tail"; `gate`, when set, is a predicate a matched path must pass.
Spec = collections.namedtuple(
    "Spec", "tool pattern mode windowed tail_start gate",
    defaults=(TAIL_BYTES, None))

# Patterns under this prefix expand only beneath the Claude config dirs
# that claude_roots accepts, so backups are skipped and a symlinked second
# name for a root does not list its files twice.
CLAUDE_PREFIX = ".claude*/"


def has_presence_lock(path):
    """conversations/<id>.db* only while presence/<id>.lock exists.

    Antigravity keeps the lock open for the life of the session, so this
    ships the databases of running conversations and none of the ended
    ones, which can be many and large.
    """
    name = os.path.basename(path)
    conversation = name.rsplit(".db", 1)[0]
    agy = os.path.dirname(os.path.dirname(path))
    return os.path.exists(os.path.join(agy, "presence", conversation + ".lock"))


def _kimi_family(tool, root):
    return [
        Spec(tool, root + "/session_index.jsonl", "tail", False, MAX_TAIL_BYTES),
        Spec(tool, root + "/sessions/*/*/state.json", "whole", True),
        Spec(tool, root + "/sessions/*/*/agents/main/wire.jsonl", "tail", True),
    ]


_AGY = ".gemini/antigravity-cli/"

# What each tool's monitor reads, relative to a home. Kimi session dirs are
# <root>/sessions/wd_<name>_<hash>/session_<uuid>, so two fixed levels
# stand in for a ** walk through whatever else lives under sessions/.
SPECS = (
    [
        Spec("claude", CLAUDE_PREFIX + "projects/*/*.jsonl", "head_tail", True),
        Spec("claude", CLAUDE_PREFIX + "sessions/*.json", "whole", False),
        # CodexMonitor reads its tail from 1 MB first, so a smaller window
        # would hand the mirror less than the local monitor expects.
        Spec("codex", ".codex/sessions/**/rollout-*.jsonl", "head_tail", True,
             1024 * 1024),
    ]
    + _kimi_family("kimi", ".kimi-code")
    + _kimi_family("bearcode", ".bearcode")
    + [
        Spec("opencode", ".local/share/opencode/opencode.db", "whole", False),
        Spec("opencode", ".local/share/opencode/opencode.db-wal", "whole", False),
        Spec("opencode", ".local/share/opencode/opencode.db-shm", "whole", False),
        Spec("grok", ".grok/active_sessions.json", "whole", False),
        Spec("grok", ".grok/sessions/*/*/summary.json", "whole", True),
        Spec("grok", ".grok/sessions/*/*/events.jsonl", "tail", True),
        Spec("grok", ".grok/sessions/*/*/updates.jsonl", "tail", True),
        Spec("grok", ".grok/sessions/*/*/subagents/*", "dir", False),
        Spec("antigravity", _AGY + "presence/*.lock", "listing", False),
        Spec("antigravity", _AGY + "history.jsonl", "tail", False),
        Spec("antigravity", _AGY + "conversation_summaries.db", "whole", False),
        Spec("antigravity", _AGY + "conversation_summaries.db-wal", "whole", False),
        Spec("antigravity", _AGY + "conversation_summaries.db-shm", "whole", False),
        Spec("antigravity", _AGY + "brain/*/.system_generated/logs/transcript.jsonl",
             "tail", True),
        Spec("antigravity", _AGY + "conversations/*.db", "whole", False,
             gate=has_presence_lock),
        Spec("antigravity", _AGY + "conversations/*.db-wal", "whole", False,
             gate=has_presence_lock),
        Spec("antigravity", _AGY + "conversations/*.db-shm", "whole", False,
             gate=has_presence_lock),
    ]
)

# {path: (size, mtime)} of what this process has shipped. Per process on
# purpose: a new helper has a new STREAM_ID, the Mac discards its mirror on
# seeing one, and everything ships fresh. A path that leaves the manifest
# leaves this too, so if it comes back it ships fresh rather than as growth
# against bytes the Mac no longer holds.
SHIPPED = {}


def ship_decision(prev_size, prev_mtime, size, mtime):
    """What to ship for a file: "none", "growth" or "fresh".

    Growth is only trusted when the file got longer by no more than one
    tail's ceiling; a shrink, a same-size rewrite or a huge jump means the
    bytes the Mac holds may no longer be a prefix of the file, so it starts
    over with a reset.
    """
    if prev_size is None:
        return "fresh"
    if size == prev_size and mtime == prev_mtime:
        return "none"
    if prev_size < size <= prev_size + MAX_TAIL_BYTES:
        return "growth"
    return "fresh"


def growth_chunk(path, start, size):
    try:
        with open(path, "rb") as handle:
            handle.seek(start)
            return start, handle.read(size - start)
    except OSError:
        return None


def omission_reason(found):
    """Why a chunk read produced nothing shippable."""
    if found is None:
        return "unreadable"
    if found is OVERSIZED:
        return "no complete record within %d bytes" % MAX_TAIL_BYTES
    if found is INCOMPLETE:
        return "no complete record yet"
    return None


def file_chunks(spec, path, size, mtime):
    """(reset, [(offset, bytes)]) for one file, or a reason string to omit it."""
    if spec.mode == "listing":
        return False, []
    if spec.mode == "whole" and size > WHOLE_MAX_BYTES:
        return "too large"
    prev = SHIPPED.get(path, (None, None))
    decision = ship_decision(prev[0], prev[1], size, mtime)
    if decision == "none":
        return False, []
    if spec.mode == "whole":
        found = whole_chunk(path, size)
        return omission_reason(found) or (True, [found])
    if decision == "growth":
        found = growth_chunk(path, prev[0], size)
        return omission_reason(found) or (False, [found])
    tail = tail_chunk(path, size, spec.tail_start)
    reason = omission_reason(tail)
    if reason:
        return reason
    if spec.mode != "head_tail":
        return True, [tail]
    head = head_chunk(path, size)
    return omission_reason(head) or (True, [head, tail])


def expand(spec, homes, claude_dirs):
    """(home, path) for every match of one spec, in a stable order.

    The glob runs here, inside the privileged process, never in a calling
    shell that cannot read the homes it names.
    """
    if spec.pattern.startswith(CLAUDE_PREFIX):
        rest = spec.pattern[len(CLAUDE_PREFIX):]
        bases = claude_dirs
    else:
        rest = spec.pattern
        bases = [(home, home) for home in homes]
    for home, base in bases:
        for path in sorted(glob.glob(os.path.join(glob.escape(base), rest),
                                     recursive=True)):
            yield home, path


def ancestors(home, path):
    """Directories between `path` and `home`, the home itself excluded."""
    found = []
    parent = os.path.dirname(path)
    prefix = home.rstrip("/") + "/"
    while parent.startswith(prefix):
        found.append(parent)
        parent = os.path.dirname(parent)
    return found


def stat_entry(path, info):
    return {"path": path, "mtime": info.st_mtime, "created": created_time(info)}


def manifest(now, warnings):
    """files, dirs and omitted for every spec in every home."""
    homes = home_dirs()
    claude_dirs = [(os.path.dirname(os.path.dirname(projects)),
                    os.path.dirname(projects))
                   for projects in claude_roots(warnings)]
    files, dirs, omitted = [], {}, []
    seen = set()
    shipped = {}
    for spec in SPECS:
        for home, path in expand(spec, homes, claude_dirs):
            if path in seen:
                continue
            try:
                info = os.stat(path)
            except OSError:
                continue
            is_dir = stat_module.S_ISDIR(info.st_mode)
            if (spec.mode == "dir") != is_dir:
                continue
            if not is_dir and not stat_module.S_ISREG(info.st_mode):
                continue
            if spec.windowed and now - info.st_mtime >= DISCOVERY_WINDOW_SECONDS:
                continue
            if spec.gate is not None and not spec.gate(path):
                continue
            seen.add(path)
            if is_dir:
                dirs[path] = stat_entry(path, info)
            else:
                result = file_chunks(spec, path, info.st_size, info.st_mtime)
                # Omitting the file says nothing about the session, which is
                # recoverable on the next poll. Shipping it empty would wipe
                # the Mac's copy and delete its row, which is not.
                if not isinstance(result, tuple):
                    omitted.append({"path": path, "reason": result})
                    continue
                reset, chunks = result
                item = stat_entry(path, info)
                item.update({
                    "size": info.st_size,
                    "reset": reset,
                    "chunks": [[offset, base64.b64encode(data).decode("ascii")]
                               for offset, data in chunks],
                })
                files.append(item)
                if spec.mode != "listing":
                    shipped[path] = (info.st_size, info.st_mtime)
            for parent in ancestors(home, path):
                if parent in dirs:
                    continue
                try:
                    dirs[parent] = stat_entry(parent, os.stat(parent))
                except OSError:
                    continue
    SHIPPED.clear()
    SHIPPED.update(shipped)
    return files, [dirs[path] for path in sorted(dirs)], omitted


def home_entries(warnings):
    """The homes scanned, each with its owner, and a warning for any home
    that cannot be listed: a glob there finds nothing, which must not read
    as nothing being there."""
    try:
        import pwd
    except ImportError:
        pwd = None
    entries = []
    for home in home_dirs():
        try:
            os.listdir(home)
        except OSError as error:
            warnings.append("cannot list home %s: %s" % (home, error))
        user = os.path.basename(home)
        try:
            if pwd is not None:
                user = pwd.getpwuid(os.stat(home).st_uid).pw_name
        except (OSError, KeyError):
            pass
        entries.append({"path": home, "user": user})
    return entries


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
    homes = home_entries(warnings)
    files, dirs, omitted = manifest(now, warnings)
    processes = agent_processes(warnings)
    payload = {
        "ok": True,
        "protocol": PROTOCOL_VERSION,
        "stream": STREAM_ID,
        "hostname": platform.node(),
        "system": platform.system(),
        "now": now,
        "homes": homes,
        "files": files,
        "dirs": dirs,
        "omitted": omitted,
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


def ping():
    try:
        import pwd
        user = pwd.getpwuid(os.geteuid()).pw_name
    except (ImportError, KeyError):
        user = ""
    with open(os.path.abspath(__file__), "rb") as handle:
        digest = hashlib.sha256(handle.read()).hexdigest()
    return {
        "ok": True,
        "protocol": PROTOCOL_VERSION,
        "sha256": digest,
        "euid": os.geteuid(),
        "user": user,
        "system": platform.system(),
        "python": platform.python_version(),
        "stream": STREAM_ID,
    }


def main(stdin=None, stdout=None):
    global _OUT
    stdin = stdin if stdin is not None else sys.stdin
    _OUT = stdout if stdout is not None else sys.stdout
    for line in stdin:
        line = line.strip()
        if not line:
            continue
        try:
            request = json.loads(line)
        except ValueError:
            write_line({"ok": False, "error": "malformed request"})
            continue
        if not isinstance(request, dict):
            write_line({"ok": False, "error": "malformed request"})
            continue
        command = request.get("cmd")
        try:
            if command == "snapshot":
                response = snapshot()
            elif command == "ping":
                response = ping()
            elif command == "echo":
                # Hands back whatever the request carried, under the
                # request's own id. It proves on the Mac that concurrent
                # requests each get their own answer, not merely an answer.
                response = {"ok": True, "value": request.get("value")}
            else:
                response = {"ok": False, "error": "unknown command: %s" % command}
        except Exception as error:
            # Every filesystem and process call above is individually
            # defensive, but this is the backstop: no exception may skip
            # a response line, or the one-JSON-object-per-line contract
            # breaks for the rest of the stdin stream. Keep the message
            # short; no traceback in the JSON.
            response = {"ok": False, "error": "internal error: %s" % error}
        if "id" in request:
            response["id"] = request["id"]
        write_line(response)


if __name__ == "__main__":
    main()
