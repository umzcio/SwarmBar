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
  * Read-only. This never writes to any agent's state. Its own files
    under ~/.swarmbar/ (the hook sockets and their lock) are the exception.
"""

import base64
import collections
import errno
import fcntl
import fnmatch
import hashlib
import http.server
import json
import os
import platform
import re
import select
import socket
import socketserver
import stat as stat_module
import struct
import subprocess
import sys
import threading
import time
import uuid

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
    """The tail as one chunk at its true offset: ((offset, bytes), covered).

    Unlike tail_of, the chunk runs through `size`, partial last line
    included, so the next poll's growth chunk starts exactly where this one
    ends and the mirror never holds a hole. It also starts one byte early,
    on the newline that ends the record before it. Everything ahead of the
    chunk is a hole in the Mac's sparse mirror, which reads back as zeros;
    without that newline the zeros and the first shipped record would read
    as one line, and a reader that drops a partial first line would drop
    a real record with it.

    `covered` is where the read window began. No newline lies between it
    and the chunk, so a tail reader whose window starts anywhere from
    `covered` on sees the same lines in the mirror as in the file.
    """
    found = tail_window(path, size, start)
    if not isinstance(found, tuple):
        return found
    offset, data, first = found
    if first > 0:
        first -= 1
    return (offset + first, data[first:]), offset


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


def has_timestamp(line):
    """Whether a JSONL line is an object with a top-level string timestamp."""
    try:
        record = json.loads(line.decode("utf-8"))
    except ValueError:
        return False
    return isinstance(record, dict) and isinstance(record.get("timestamp"), str)


def stamped_head_chunk(path, size, limit=None):
    """Claude's head: (0, bytes) from the start through the first complete
    line carrying a top-level timestamp, newline included.

    The Mac dates a session from that timestamp when the remote reports no
    birth time, which is always on Linux. A first-line-only head almost
    never has one: most transcripts open with a `last-prompt` record that
    carries none, and the first timestamp is on the record after it. With
    no such line within `limit` (MAX_HEAD_BYTES) this ships the first line
    alone, exactly as head_chunk would.
    """
    limit = MAX_HEAD_BYTES if limit is None else limit
    try:
        with open(path, "rb") as handle:
            data = handle.read(min(size, limit))
    except OSError:
        return None
    start = 0
    while True:
        newline = data.find(b"\n", start)
        if newline == -1:
            break
        if has_timestamp(data[start:newline]):
            return 0, data[:newline + 1]
        start = newline + 1
    return head_chunk(path, size)


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
# "head_tail"; `gate`, when set, is a predicate a matched path must pass;
# `stamped_head` makes a "head_tail" head run to the first timestamped line.
Spec = collections.namedtuple(
    "Spec", "tool pattern mode windowed tail_start gate stamped_head",
    defaults=(TAIL_BYTES, None, False))

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
    conversation = os.path.basename(path).rsplit(".db", 1)[0]
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
#
# sqlite databases ship with their -wal but never their -shm. The files
# are read at different instants, and a -shm index left over from an older
# -wal can steer a reader to the wrong frames; without one, the Mac's
# SQLiteSnapshot copies the pair and lets sqlite rebuild the index.
SPECS = (
    [
        Spec("claude", CLAUDE_PREFIX + "projects/*/*.jsonl", "head_tail", True,
             stamped_head=True),
        Spec("claude", CLAUDE_PREFIX + "sessions/*.json", "whole", False),
        # CodexMonitor.parsedStatus falls back from 64 KB to 1 MB to 4 MB
        # when the newest records are ones its parser skips, so the mirror
        # has to hold the widest of those windows from the first ship.
        Spec("codex", ".codex/sessions/**/rollout-*.jsonl", "head_tail", True,
             MAX_TAIL_BYTES),
    ]
    + _kimi_family("kimi", ".kimi-code")
    + _kimi_family("bearcode", ".bearcode")
    + [
        Spec("opencode", ".local/share/opencode/opencode.db", "whole", False),
        Spec("opencode", ".local/share/opencode/opencode.db-wal", "whole", False),
        Spec("grok", ".grok/active_sessions.json", "whole", False),
        Spec("grok", ".grok/sessions/*/*/summary.json", "whole", True),
        Spec("grok", ".grok/sessions/*/*/events.jsonl", "tail", True),
        Spec("grok", ".grok/sessions/*/*/updates.jsonl", "tail", True),
        Spec("grok", ".grok/sessions/*/*/subagents/*", "dir", False),
        Spec("antigravity", _AGY + "presence/*.lock", "listing", False),
        Spec("antigravity", _AGY + "history.jsonl", "tail", False),
        Spec("antigravity", _AGY + "conversation_summaries.db", "whole", False),
        Spec("antigravity", _AGY + "conversation_summaries.db-wal", "whole", False),
        Spec("antigravity", _AGY + "brain/*/.system_generated/logs/transcript.jsonl",
             "tail", True),
        Spec("antigravity", _AGY + "conversations/*.db", "whole", False,
             gate=has_presence_lock),
        Spec("antigravity", _AGY + "conversations/*.db-wal", "whole", False,
             gate=has_presence_lock),
    ]
)

# What this process has shipped, per path: Shipped(size, mtime, covered,
# last_newline). `covered` is where the mirror's tail begins and
# `last_newline` the offset of the last newline shipped; both are None for
# whole files. Per process on purpose: a new helper has a new STREAM_ID, the
# Mac discards its mirror on seeing one, and everything ships fresh. A path
# that leaves the manifest leaves this too, so if it comes back it ships
# fresh rather than as growth against bytes the Mac no longer holds. Only
# snapshot() replaces it, and only once the response is fully built.
Shipped = collections.namedtuple("Shipped", "size mtime covered last_newline")
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


def reader_offset(size, last_break, start):
    """Where ClaudeCodeMonitor.tail(of:startingAt:) starts its last window.

    It doubles from `start` until the window holds a newline with at least
    one byte after it, so all it needs to know is where the last such
    newline is (`last_break`, or -1 for none). It gives up at the ceiling.
    """
    window = min(start, MAX_TAIL_BYTES)
    while True:
        offset = size - window if size > window else 0
        if offset == 0 or offset <= last_break or window >= MAX_TAIL_BYTES:
            return offset
        window = min(window * 2, MAX_TAIL_BYTES)


def growth_is_mirrored(prev, size, data, start):
    """Whether appending `data` keeps the mirror's tail equal to the file's.

    A growth chunk holding one record bigger than the reader's window makes
    the reader double back past it, and if that reaches ahead of
    prev.covered the mirror answers from its hole. The widest reader the
    Mac runs on this file starts at `start`, and any narrower one lands
    later, so checking that one covers them all.
    """
    inner = data.rfind(b"\n", 0, len(data) - 1)
    last_break = prev.size + inner if inner != -1 else prev.last_newline
    return reader_offset(size, last_break, start) >= prev.covered


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


def last_newline_in(chunks, fallback):
    """Offset of the last newline across chunks, later chunks winning."""
    found = fallback
    for offset, data in chunks:
        index = data.rfind(b"\n")
        if index != -1:
            found = offset + index
    return found


def file_chunks(spec, path, size, mtime, prev):
    """(reset, [(offset, bytes)], Shipped or None) for one file, or a
    reason string to omit it. `prev` is SHIPPED's entry, or None."""
    if spec.mode == "listing":
        return False, [], None
    if spec.mode == "whole" and size > WHOLE_MAX_BYTES:
        return "too large"
    decision = ship_decision(prev.size if prev else None,
                             prev.mtime if prev else None, size, mtime)
    if decision == "none":
        return False, [], prev
    if spec.mode == "whole":
        found = whole_chunk(path, size)
        return omission_reason(found) or (
            True, [found], Shipped(size, mtime, None, None))
    if decision == "growth":
        found = growth_chunk(path, prev.size, size)
        reason = omission_reason(found)
        if reason:
            return reason
        if growth_is_mirrored(prev, size, found[1], spec.tail_start):
            return False, [found], Shipped(
                size, mtime, prev.covered, last_newline_in([found], prev.last_newline))
    tail = tail_chunk(path, size, spec.tail_start)
    reason = omission_reason(tail)
    if reason:
        return reason
    chunk, covered = tail
    chunks = [chunk]
    if spec.mode == "head_tail":
        head = (stamped_head_chunk(path, size) if spec.stamped_head
                else head_chunk(path, size))
        reason = omission_reason(head)
        if reason:
            return reason
        chunks = [head, chunk]
    return True, chunks, Shipped(size, mtime, covered, last_newline_in([chunk], -1))


def has_magic(part):
    return any(character in part for character in "*?[")


def list_dir(directory, unreadable):
    """Names in a directory. A directory that is not there is empty; one
    that is there but cannot be read is recorded, never read as empty."""
    try:
        return sorted(os.listdir(directory))
    except OSError as error:
        if error.errno not in (errno.ENOENT, errno.ENOTDIR):
            unreadable[directory] = "cannot list: %s" % error.strerror
        return []


def matching(directory, part, unreadable):
    """Entries of `directory` matching one pattern component. Like glob, a
    wildcard never matches a hidden name unless the component asks for one."""
    hidden = part.startswith(".")
    return [os.path.join(directory, name)
            for name in list_dir(directory, unreadable)
            if (hidden or not name.startswith("."))
            and fnmatch.fnmatchcase(name, part)]


def subdirectories(directory, unreadable):
    """`directory` and every directory beneath it, for "**". Symlinked
    directories are not followed, so a link loop cannot run forever."""
    found = [directory]
    for path in matching(directory, "*", unreadable):
        if os.path.isdir(path) and not os.path.islink(path):
            found.extend(subdirectories(path, unreadable))
    return found


def expand_pattern(base, pattern, unreadable):
    """Candidate paths for a glob pattern under `base`.

    glob.glob would do, except that it reads a directory it may not open
    as an empty one, and "found nothing" must never look like "could not
    look". This records such directories in `unreadable` instead. Literal
    components are joined without a check; the caller's stat decides.
    """
    paths = [base]
    for part in pattern.split("/"):
        following = []
        for current in paths:
            if part == "**":
                following.extend(subdirectories(current, unreadable))
            elif has_magic(part):
                following.extend(matching(current, part, unreadable))
            else:
                following.append(os.path.join(current, part))
        paths = following
    return paths


def expand(spec, homes, claude_dirs, unreadable):
    """(home, path) for every candidate of one spec, in a stable order.

    The expansion runs here, inside the privileged process, never in a
    calling shell that cannot read the homes it names.
    """
    if spec.pattern.startswith(CLAUDE_PREFIX):
        rest = spec.pattern[len(CLAUDE_PREFIX):]
        bases = claude_dirs
    else:
        rest = spec.pattern
        bases = [(home, home) for home in homes]
    for home, base in bases:
        for path in expand_pattern(base, rest, unreadable):
            yield home, path


def stat_or_note(path, unreadable):
    """os.stat, or None. A path that is simply gone stays silent; one that
    exists but cannot be examined is recorded in `unreadable`."""
    try:
        return os.stat(path)
    except OSError as error:
        if error.errno not in (errno.ENOENT, errno.ENOTDIR):
            unreadable[path] = "cannot stat: %s" % error.strerror
        return None


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


def manifest(now, warnings, shipped_before):
    """files, dirs, omitted, and the SHIPPED map to commit if the snapshot
    that asked for them completes. It never touches SHIPPED itself."""
    homes = home_dirs()
    claude_dirs = [(os.path.dirname(os.path.dirname(projects)),
                    os.path.dirname(projects))
                   for projects in claude_roots(warnings)]
    files, dirs, omitted = [], {}, []
    unreadable = {}
    seen = set()
    shipped = {}
    for spec in SPECS:
        for home, path in expand(spec, homes, claude_dirs, unreadable):
            if path in seen:
                continue
            info = stat_or_note(path, unreadable)
            if info is None:
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
                result = file_chunks(spec, path, info.st_size, info.st_mtime,
                                     shipped_before.get(path))
                # Omitting the file says nothing about the session, which is
                # recoverable on the next poll. Shipping it empty would wipe
                # the Mac's copy and delete its row, which is not.
                if not isinstance(result, tuple):
                    omitted.append({"path": path, "reason": result})
                    continue
                reset, chunks, record = result
                item = stat_entry(path, info)
                item.update({
                    "size": info.st_size,
                    "reset": reset,
                    "chunks": [[offset, base64.b64encode(data).decode("ascii")]
                               for offset, data in chunks],
                })
                files.append(item)
                if record is not None:
                    shipped[path] = record
            for parent in ancestors(home, path):
                if parent in dirs:
                    continue
                parent_info = stat_or_note(parent, unreadable)
                if parent_info is not None:
                    dirs[parent] = stat_entry(parent, parent_info)
    omitted.extend({"path": path, "reason": unreadable[path]}
                   for path in sorted(unreadable))
    return files, [dirs[path] for path in sorted(dirs)], omitted, shipped


def home_entries(warnings, omitted=None):
    """The homes scanned, each with its owner, and a warning for any home
    that cannot be listed: a glob there finds nothing, which must not read
    as nothing being there.

    Such a home also goes into `omitted` when a list is passed. The warning
    is free text for a person; the omission is what tells the Mac not to
    sweep its mirror of that home empty."""
    entries = []
    for home in home_dirs():
        try:
            os.listdir(home)
        except OSError as error:
            warnings.append("cannot list home %s: %s" % (home, error))
            if omitted is not None:
                omitted.append({"path": home, "reason": "cannot list: %s" % error.strerror})
        entries.append({"path": home, "user": home_owner(home)[0]})
    return entries


def home_owner(home):
    """(user, uid, gid) of a home. The user is the owner's name, or the
    home's basename when there is none; hook events carry the same name as
    the snapshot's homes. uid and gid are None when the home cannot be
    examined."""
    user, uid, gid = os.path.basename(home), None, None
    try:
        info = os.stat(home)
        uid, gid = info.st_uid, info.st_gid
    except OSError:
        return user, uid, gid
    try:
        import pwd
        entry = pwd.getpwuid(uid)
        user, gid = entry.pw_name, entry.pw_gid
    except (ImportError, KeyError):
        pass
    return user, uid, gid


def run_command(argv, timeout=5, input=None):
    """The one place the helper starts a subprocess (ps, tmux, lsof).

    Tests replace this so no unit test ever inspects a real process. It
    raises OSError or SubprocessError like subprocess.run, and callers decide
    whether a failure matters. `input` is bytes for the child's stdin (tmux
    load-buffer reads the paste text there); None leaves stdin alone.
    """
    return subprocess.run(
        argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout,
        input=input,
    )


def process_cwd(pid):
    """Portable enough for both fleets. /proc is Linux only."""
    if platform.system() != "Darwin":
        try:
            return os.readlink("/proc/%d/cwd" % pid)
        except OSError:
            return ""
    try:
        out = run_command(
            ["lsof", "-a", "-p", str(pid), "-d", "cwd", "-Fn"],
        ).stdout.decode("utf-8", "replace")
    except (OSError, subprocess.SubprocessError):
        return ""
    for line in out.splitlines():
        if line.startswith("n"):
            return line[1:]
    return ""


AGENT_COMMANDS = ("claude", "codex", "kimi", "kimi-code", "opencode", "grok", "agy",
                  "bearcode")
# BearCode runs as a bare node process, so its comm says nothing. Its command
# line is the only thing that identifies it.
BEARCODE_ARGS = "bearcode-cli/apps/kimi-code/dist/main.mjs"
ANCESTRY_LIMIT = 32
SCREEN_LINES = 60


def user_for(uid, printed):
    """The account name for a uid, or the name ps printed when that fails.

    procps cuts a long user name to fit its column (`longuser+`, or the
    bare uid), and the Mac matches each process to a home by the full
    owner name, so a truncated one would quietly drop every session that
    user runs. The uid is never truncated.
    """
    try:
        import pwd
        return pwd.getpwuid(uid).pw_name
    except (ImportError, KeyError, OverflowError):
        return printed


def parse_ps(text):
    """Rows of `ps -axo pid=,ppid=,uid=,user=,tty=,comm=,args=`, args kept whole.

    The first six fields never contain whitespace except that comm might
    (a Linux kernel thread name, say), so this splits on the first six runs
    and treats everything after as args. A comm with a space therefore bleeds
    its tail into args; no agent's comm has one. comm may be a full path on
    Darwin, so only its basename is kept. A tty of ? or ?? means none. The
    user comes from the uid, and the printed name is only the fallback.
    """
    rows = []
    for line in text.splitlines():
        parts = line.split(None, 6)
        if len(parts) < 6:
            continue
        try:
            pid, ppid, uid = int(parts[0]), int(parts[1]), int(parts[2])
        except ValueError:
            continue
        tty = parts[4]
        rows.append({
            "pid": pid, "ppid": ppid, "user": user_for(uid, parts[3]),
            "tty": "" if tty in ("?", "??", "-") else tty,
            "comm": parts[5].split("/")[-1],
            "args": parts[6].strip() if len(parts) > 6 else "",
        })
    return rows


def agent_name(row):
    """The agent a ps row is, or None.

    On Darwin `comm` is a full path truncated to 16 characters
    (/Users/zach/.loc), so its basename can be garbage and an agent started by
    absolute path would silently vanish from the table. When comm's basename
    is not an agent, argv[0] (the first token of args) is tried instead.
    BearCode is a bare node process and is recognised by its script path.
    """
    if row["comm"] in AGENT_COMMANDS:
        return row["comm"]
    if BEARCODE_ARGS in row["args"]:
        return "bearcode"
    tokens = row["args"].split(None, 1)
    if tokens:
        name = tokens[0].split("/")[-1]
        if name in AGENT_COMMANDS:
            return name
    return None


def tmux_sockets():
    """Every tmux server socket this user can name, root's view included."""
    roots = ["/tmp"]
    custom = os.environ.get("TMUX_TMPDIR")
    if custom:
        roots.append(custom)
    found = []
    for root in roots:
        try:
            directories = sorted(os.listdir(root))
        except OSError:
            continue
        for name in directories:
            if not name.startswith("tmux-"):
                continue
            directory = os.path.join(root, name)
            try:
                for entry in sorted(os.listdir(directory)):
                    path = os.path.join(directory, entry)
                    if path not in found:
                        found.append(path)
            except OSError:
                continue
    return found


def tmux_panes():
    """pane shell pid -> {"socket", "id"} across every reachable server.

    tmux missing, a dead socket and another user's server (unreadable unless
    root) all just contribute nothing. Panes being null is a normal state,
    never processes_failed.
    """
    panes = {}
    for socket in tmux_sockets():
        try:
            done = run_command(
                ["tmux", "-S", socket, "list-panes", "-a", "-F", "#{pane_id} #{pane_pid}"],
            )
        except (OSError, subprocess.SubprocessError):
            continue
        if done.returncode != 0:
            continue
        for line in done.stdout.decode("utf-8", "replace").splitlines():
            fields = line.split()
            if len(fields) != 2:
                continue
            try:
                panes[int(fields[1])] = {"socket": socket, "id": fields[0]}
            except ValueError:
                continue
    return panes


def pane_for(pid, parents, panes):
    """The pane an agent lives in, found by walking up its parents.

    Bounded so a ppid cycle (or a pathological chain) terminates.
    """
    current = pid
    for _ in range(ANCESTRY_LIMIT):
        if current in panes:
            return panes[current]
        current = parents.get(current)
        if current is None:
            return None
    return None


def proc_fd_links(pid):
    """Link targets of a pid's fds, or None when the directory is unreadable."""
    links = []
    base = "/proc/%d/fd" % pid
    try:
        names = os.listdir(base)
    except OSError:
        return None
    for name in names:
        try:
            links.append(os.readlink(os.path.join(base, name)))
        except OSError:
            continue
    return links


def held_files(comm, pid):
    """(paths, ok) for files a codex or agy process holds open.

    ok is False when the read itself failed, so a failure never reads as
    "holds nothing".
    """
    if comm == "codex":
        def wanted(path):
            return path.endswith(".jsonl") and "/.codex/sessions/" in path
    elif comm == "agy":
        def wanted(path):
            return path.endswith(".lock") and "/presence/" in path
    else:
        return [], True
    if platform.system() == "Darwin":
        try:
            out = run_command(["lsof", "-n", "-P", "-a", "-p", str(pid), "-Fn"])
        except (OSError, subprocess.SubprocessError):
            return [], False
        if out.returncode != 0 and not out.stdout.strip():
            return [], False
        text = out.stdout.decode("utf-8", "replace")
        links = [line[1:] for line in text.splitlines() if line.startswith("n")]
    else:
        links = proc_fd_links(pid)
        if links is None:
            return [], False
    return [path for path in links if wanted(path)], True


def pane_screen(pane):
    text = pane_text(pane)
    if text is None:
        return None
    return "\n".join(text.splitlines()[-SCREEN_LINES:])


def agent_processes(warnings):
    """Live agent processes. `ps -axo` is portable; GNU long flags are not."""
    try:
        completed = run_command(
            # uid= alongside user=: both GNU and BSD ps take it, and GNU's
            # user:64= width syntax is not portable. parse_ps relies on
            # this exact field order.
            ["ps", "-axo", "pid=,ppid=,uid=,user=,tty=,comm=,args="], timeout=15,
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

    text = completed.stdout.decode("utf-8", "replace")
    rows = parse_ps(text)
    if not rows and text.strip():
        # A real ps always lists at least itself. Output nothing parses is a
        # failure, not "no agents".
        warnings.append("ps output could not be parsed")
        return None
    agents = []
    for row in rows:
        name = agent_name(row)
        if name:
            row["comm"] = name
            agents.append(row)
    panes = tmux_panes() if agents else {}
    parents = dict((row["pid"], row["ppid"]) for row in rows)
    processes = []
    for row in agents:
        pid = row["pid"]
        pane = pane_for(pid, parents, panes)
        entry = dict(row)
        paths, ok = held_files(row["comm"], pid)
        if not ok:
            warnings.append("cannot read open files of pid %d" % pid)
            entry["open_failed"] = True
        entry.update({
            "cwd": process_cwd(pid),
            "pane": pane,
            "open": paths,
            "screen": pane_screen(pane) if pane and row["comm"] == "agy" else None,
        })
        processes.append(entry)
    return processes


def snapshot():
    now = time.time()
    warnings = []
    home_omitted = []
    homes = home_entries(warnings, home_omitted)
    files, dirs, omitted, shipped = manifest(now, warnings, SHIPPED)
    # An unlistable home can also surface from the manifest's own walk, so
    # each path is reported once.
    named = set(item["path"] for item in home_omitted)
    omitted = home_omitted + [item for item in omitted if item["path"] not in named]
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
    # Last, after everything that can raise. A snapshot that fails never
    # reaches the Mac, so it must not count its chunks as shipped either, or
    # the next one would send growth on top of bytes the mirror never got.
    SHIPPED.clear()
    SHIPPED.update(shipped)
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


PANE_ID = re.compile(r"^%[0-9]+$")
KEY_GAP_DEFAULT = 0.08
KEY_GAP_MAX = 0.5
PASTE_BUFFER = "swarmbar"
NAMED_KEYS = {"UP": "Up", "DOWN": "Down", "ESC": "Escape", "\n": "Enter"}
# C0 controls other than newline and tab, plus DEL. ESC is the one that
# matters: it could close the bracketed paste early or open a sequence.
PASTE_STRIP = re.compile("[\x00-\x08\x0b-\x1f\x7f]")


def tmux_key_args(key):
    """The send-keys arguments for one key. Anything unnamed is sent literally
    with -l, and "--" ends option parsing so a literal such as "-x" or "Up"
    is never read as a flag or a key name."""
    if key in NAMED_KEYS:
        return [NAMED_KEYS[key]]
    return ["-l", "--", key]


def valid_pane(pane):
    """The pane with its socket resolved, or None when it is not drivable.

    The pane comes off the wire, so it is checked as hostile input: the id
    must be a bare pane id, and the socket must sit in a tmux-* directory both
    as written and after symlinks resolve, under /tmp or TMUX_TMPDIR, be a
    real socket, and be owned by whoever owns its tmux-* directory. The
    resolved path is what every later tmux call uses, so the path checked is
    the path run, with no window for a symlink to be swapped in between.
    """
    if not isinstance(pane, dict):
        return None
    pane_id, sock = pane.get("id"), pane.get("socket")
    if not isinstance(pane_id, str) or not PANE_ID.match(pane_id):
        return None
    if not isinstance(sock, str) or not os.path.isabs(sock):
        return None
    if not os.path.basename(os.path.dirname(sock)).startswith("tmux-"):
        return None
    real = os.path.realpath(sock)
    real_dir = os.path.dirname(real)
    if not os.path.basename(real_dir).startswith("tmux-"):
        return None
    roots = ["/tmp"]
    if os.environ.get("TMUX_TMPDIR"):
        roots.append(os.environ["TMUX_TMPDIR"])
    parent = os.path.dirname(real_dir)
    if not any(parent == os.path.realpath(root) for root in roots):
        return None
    try:
        info = os.stat(real)
        dir_info = os.stat(real_dir)
    except OSError:
        return None
    if not stat_module.S_ISSOCK(info.st_mode) or info.st_uid != dir_info.st_uid:
        return None
    return {"socket": real, "id": pane_id}


def tmux_run(pane, args, input=None):
    """One tmux call against the pane's own server. Returns the completed
    process, or None when tmux could not run at all."""
    argv = ["tmux", "-S", pane["socket"]] + args
    try:
        if input is None:
            return run_command(argv)
        return run_command(argv, input=input)
    except (OSError, subprocess.SubprocessError):
        return None


def pane_text(pane):
    """The VISIBLE screen of a pane, or None when it cannot be read. This is
    the only pane read in the helper: no -S, so scrollback never counts. A
    label that lingers in history must not confirm a prompt that has moved."""
    done = tmux_run(pane, ["capture-pane", "-p", "-t", pane["id"]])
    if done is None or done.returncode != 0:
        return None
    return done.stdout.decode("utf-8", "replace")


def handle_tmux(request):
    """capture, keys and paste. Keys are confirmed against a fresh capture of
    the visible screen taken immediately before sending, and any missing
    expectation sends nothing, because a prompt that moved under the Mac's
    read could otherwise take a keystroke meant for another prompt.

    Response shapes the Mac decodes (the request id is added by main):
      capture: {"text": str}, or {"ok": false, "error": "capture failed"}
      keys and paste: {"sent": true}, or {"sent": false, "reason": r} with r
        "changed" (an expect string was absent), "capture failed" (the
        confirming read failed), or "send failed" (plus "sent_count" for
        keys, how many keys landed first).
      any command: {"ok": false, "error": "bad pane" | "bad keys" | "bad text"}
    """
    pane = valid_pane(request.get("pane"))
    if pane is None:
        return {"ok": False, "error": "bad pane"}
    command = request.get("cmd")
    if command == "capture":
        text = pane_text(pane)
        if text is None:
            return {"ok": False, "error": "capture failed"}
        return {"text": text}
    if command == "paste":
        text = request.get("text")
        if not isinstance(text, str):
            return {"ok": False, "error": "bad text"}
        # Precondition: tmux applies bracketed paste (-p) only when the
        # pane's app enabled the mode, and the Mac verifies the paste on
        # screen before it sends Enter. Stripping controls keeps a reply from
        # carrying its own escape sequences or ending the paste early.
        text = PASTE_STRIP.sub("", text)
        loaded = tmux_run(pane, ["load-buffer", "-b", PASTE_BUFFER, "-"],
                          input=text.encode("utf-8"))
        if loaded is None or loaded.returncode != 0:
            return {"sent": False, "reason": "send failed"}
        # -p wraps the text in bracketed paste, -d drops the buffer after, and
        # no Enter follows: the Mac decides separately whether to submit.
        pasted = tmux_run(pane, ["paste-buffer", "-p", "-d", "-b", PASTE_BUFFER,
                                 "-t", pane["id"]])
        if pasted is None or pasted.returncode != 0:
            return {"sent": False, "reason": "send failed"}
        return {"sent": True}
    keys, expect = request.get("keys"), request.get("expect") or []
    if not isinstance(keys, list) or not all(isinstance(k, str) for k in keys) \
            or not isinstance(expect, list) or not all(isinstance(e, str) for e in expect):
        return {"ok": False, "error": "bad keys"}
    gap = request.get("gap", KEY_GAP_DEFAULT)
    if not isinstance(gap, (int, float)) or isinstance(gap, bool) or gap < 0:
        gap = KEY_GAP_DEFAULT
    gap = min(gap, KEY_GAP_MAX)
    if expect:
        screen = pane_text(pane)
        if screen is None:
            return {"sent": False, "reason": "capture failed"}
        if any(e not in screen for e in expect):
            return {"sent": False, "reason": "changed"}
    for index, key in enumerate(keys):
        if index:
            time.sleep(gap)
        done = tmux_run(pane, ["send-keys", "-t", pane["id"]] + tmux_key_args(key))
        if done is None or done.returncode != 0:
            return {"sent": False, "reason": "send failed", "sent_count": index}
    return {"sent": True}


# The hook relay. Remote bridge scripts post each hook to a Unix socket in
# the agent user's own home, ~/.swarmbar/hook.sock, and this relays it to
# every connected Mac over the ssh channel. File permissions replace the
# loopback token: the directory is 700 and the sockets 600, owned by the
# home's owner, so only that user and root can post or listen.
#
# Several helpers can run on one host, one per connected Mac, but a bridge
# connects to one socket. So per home the helper holding hook.lock is the
# owner: it serves hook.sock and broker.sock. Every other helper is a
# follower: it connects to broker.sock, relays what the owner sends it to
# its own Mac, and keeps trying the lock so it takes over when the owner
# exits.
#
# Broker protocol, newline-delimited JSON over broker.sock:
#   owner -> follower: a Mac event, verbatim, which the follower writes to
#     its own Mac unchanged: {"event": "hook", ...} or
#     {"event": "hook_resolved", "rid": ...}.
#   follower -> owner: {"type": "reply", "rid": str, "body": {...}}, its
#     Mac's hook_reply. The first reply for a rid, from any Mac, answers it.
# Connecting is registering. There is no handshake and no other message.
HOOK_DIR = ".swarmbar"
HOOK_SOCKET = "hook.sock"
BROKER_SOCKET = "broker.sock"
HOOK_LOCK = "hook.lock"

# A home with any of these installed is a hook home and gets a socket.
HOOK_MARKERS = (
    HOOK_DIR + "/swarmbar-remote-hook.sh",
    HOOK_DIR + "/swarmbar-remote-kimi-hook.sh",
    ".config/opencode/plugins/swarmbar-remote.js",
)

# Larger bodies are answered {} and never forwarded. A hook payload is a
# tool call; this is far past any real one.
MAX_HOOK_BODY = 256 * 1024
# An oversized body up to this is read and discarded, so its client gets the
# {} rather than a broken pipe mid-send. Past it the connection just closes.
MAX_HOOK_DRAIN = 4 * 1024 * 1024
# A held request gives up just inside the bridge's own curl -m 350, so the
# agent hears {} rather than a dropped connection.
HOLD_SECONDS = 345
# How often a hold checks that its client is still there.
HOLD_POLL_SECONDS = 0.5
# How often a follower whose owner has gone tries the lock.
LOCK_RETRY_SECONDS = 2.0
# How long a server's loop can take to notice it was shut down.
SERVE_POLL_SECONDS = 0.5
# The peer and its ancestors, at most this many names.
PEER_DEPTH = 8
# ps runs before a PermissionRequest is answered. Grok counts a hook that
# takes about 3 seconds as consent, so a slow ps must fail, not stall.
PEER_PS_TIMEOUT = 1
# Reading the request itself. A client that connects and says nothing must
# not hold a thread forever.
HOOK_READ_TIMEOUT = 10
# A follower that stops reading is dropped rather than allowed to stall
# the owner's broadcasts.
BROKER_SEND_TIMEOUT = 2
MAX_BROKER_LINE = 8 * 1024 * 1024
# sun_path is 104 bytes on Darwin and 108 on Linux, NUL included.
MAX_SOCKET_PATH = 103

HOOK_PATH = re.compile(r"^/hook/([A-Za-z0-9_]+)$")

# os.umask is process-wide. Binding under a tight umask creates each socket
# 600 from the start, with no chmod-by-path afterwards: as root that path is
# inside a directory the user owns, who could swap it for a symlink to a
# file root would then chmod.
_UMASK_LOCK = threading.Lock()


def is_holdable(event, peer):
    """Whether a hook may be held for a decision from a Mac.

    Only Claude Code answers through its hook response, so only its
    PermissionRequest is held. Grok imports Claude-compatible hooks and
    reaches this same socket with the same script, but Grok 0.2.118 treats
    a hook that times out as consent, so a held Grok prompt is an approved
    one. Any chain containing grok is answered at once, and so is one that
    does not prove claude, since an unknown peer could be Grok. OpenCode's
    event comes only from SwarmBar's own plugin, which holds on purpose.
    """
    if event == "OpenCodePermission":
        return True
    return event == "PermissionRequest" and "claude" in peer and "grok" not in peer


def peer_pid(sock):
    """The pid of the process on the other end of a Unix socket, or None."""
    try:
        if hasattr(socket, "SO_PEERCRED"):
            size = struct.calcsize("3i")
            pid, _, _ = struct.unpack(
                "3i", sock.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, size))
            return pid or None
        if platform.system() == "Darwin":
            # SOL_LOCAL is 0 and LOCAL_PEERPID 0x002; python names neither.
            return struct.unpack("i", sock.getsockopt(0, 0x002, 4))[0] or None
    except (OSError, struct.error):
        return None
    return None


def peer_chain(sock):
    """Names of the peer process and its ancestors, nearest first.

    Each name is resolved the way the process table resolves one, so an
    agent started by absolute path on Darwin, whose comm is truncated, still
    reads as the agent. Anything else keeps its raw comm. One ps lists the
    whole table, so the walk costs one subprocess however deep it goes. Any
    failure is an empty list, which is never held. Tests replace this.
    """
    pid = peer_pid(sock)
    if not pid:
        return []
    try:
        done = run_command(["ps", "-axo", "pid=,ppid=,comm=,args="],
                           timeout=PEER_PS_TIMEOUT)
    except (OSError, subprocess.SubprocessError):
        return []
    if done.returncode != 0:
        return []
    table = {}
    for line in done.stdout.decode("utf-8", "replace").splitlines():
        parts = line.split(None, 3)
        if len(parts) < 3:
            continue
        try:
            row_pid, ppid = int(parts[0]), int(parts[1])
        except ValueError:
            continue
        table[row_pid] = {"ppid": ppid, "raw": parts[2], "comm": parts[2].split("/")[-1],
                          "args": parts[3].strip() if len(parts) > 3 else ""}
    names = []
    seen = set()
    current = pid
    while current in table and current not in seen and len(names) < PEER_DEPTH:
        seen.add(current)
        names.append(process_label(table[current]))
        current = table[current]["ppid"]
    return names


def process_label(row):
    """An agent's resolved name, else the comm basename. Darwin cuts comm,
    a full path, to 16 characters, so a comm that is a strict prefix of
    argv0 is a truncated one and argv0's basename names it instead."""
    name = agent_name(row)
    if name:
        return name
    argv0 = row["args"].split(None, 1)[0] if row["args"] else ""
    if argv0 != row["raw"] and argv0.startswith(row["raw"]):
        return argv0.split("/")[-1]
    return row["comm"].lstrip("-") or "?"


def hook_homes():
    """Homes with a remote bridge installed, in home_dirs order."""
    return [home for home in home_dirs()
            if any(os.path.isfile(os.path.join(home, marker)) for marker in HOOK_MARKERS)]


class HookHomeError(Exception):
    """A home whose hook socket cannot be served, with the reason."""


def read_lines(sock, stopping):
    """Lines from a socket that has a timeout, until EOF or `stopping()`.

    The broker's sockets carry a send timeout, which python applies to
    reads as well, so a quiet connection times out on every read and is
    simply read again."""
    buffered = b""
    while True:
        try:
            chunk = sock.recv(65536)
        except socket.timeout:
            if stopping():
                return
            continue
        except OSError:
            return
        if not chunk:
            return
        buffered += chunk
        while b"\n" in buffered:
            line, buffered = buffered.split(b"\n", 1)
            yield line
        if len(buffered) > MAX_BROKER_LINE:
            return


def parse_line(line):
    try:
        message = json.loads(line.decode("utf-8"))
    except ValueError:
        return None
    return message if isinstance(message, dict) else None


def client_gone(sock):
    """Whether a held client has hung up. A bridge sends nothing after its
    request, so a readable socket that peeks empty is one at EOF. poll, not
    select, because select fails outright on a descriptor past 1024, and a
    check that cannot be made keeps holding: the deadline still bounds it."""
    try:
        poller = select.poll()
        poller.register(sock, select.POLLIN)
        if not poller.poll(0):
            return False
        return sock.recv(1, socket.MSG_PEEK) == b""
    except (socket.timeout, BlockingIOError, InterruptedError, ValueError):
        return False
    except OSError:
        return True


def drop_connection(sock):
    """Closes a connection so its peer sees EOF, never an answer."""
    try:
        sock.shutdown(socket.SHUT_RDWR)
    except OSError:
        pass


def read_hook_body(handler):
    """The request body, or None when it is too large or malformed."""
    if "chunked" in handler.headers.get("Transfer-Encoding", "").lower():
        # node's http.request sends chunked unless told a length, and the
        # OpenCode plugin posts through it.
        data = b""
        while True:
            line = handler.rfile.readline(1024)
            try:
                size = int(line.split(b";", 1)[0].strip(), 16)
            except ValueError:
                return None
            if size == 0:
                while handler.rfile.readline(1024).strip():
                    pass
                return data
            if size < 0 or len(data) + size > MAX_HOOK_BODY:
                return None
            chunk = handler.rfile.read(size)
            if len(chunk) != size:
                return None
            data += chunk
            handler.rfile.readline(1024)
    try:
        length = int(handler.headers.get("Content-Length", "0"))
    except ValueError:
        return None
    if length < 0:
        return None
    if length > MAX_HOOK_BODY:
        while 0 < length <= MAX_HOOK_DRAIN:
            chunk = handler.rfile.read(min(length, 65536))
            if not chunk:
                break
            length -= len(chunk)
        return None
    data = handler.rfile.read(length) if length else b""
    return data if len(data) == length else None


class _QuietServer(socketserver.ThreadingUnixStreamServer):
    daemon_threads = True
    hub = None

    def handle_error(self, request, client_address):
        # A held client dropped at exit fails its final flush. socketserver
        # would print a traceback to stderr, which is the ssh channel's.
        pass


class HookHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    timeout = HOOK_READ_TIMEOUT

    def log_message(self, format, *args):
        pass

    def do_POST(self):
        self.close_connection = True
        self.server.hub.handle_post(self)

    def answer(self, obj):
        data = json.dumps(obj).encode("utf-8")
        try:
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(data)
            self.wfile.flush()
        except OSError:
            pass


class BrokerHandler(socketserver.BaseRequestHandler):
    def handle(self):
        hub = self.server.hub
        conn = self.request
        conn.settimeout(BROKER_SEND_TIMEOUT)
        if not hub.add_follower(conn):
            return
        try:
            for line in read_lines(conn, lambda: hub.closing):
                message = parse_line(line)
                if message and message.get("type") == "reply":
                    hub.resolve(message.get("rid"), message.get("body"))
        finally:
            hub.remove_follower(conn)


class Held(object):
    """One request waiting for a Mac's decision."""

    def __init__(self, conn):
        self.conn = conn
        self.done = threading.Event()
        self.body = None
        self.dropped = False


class HookHome(object):
    """The hook socket for one home, as its owner or as a follower."""

    def __init__(self, relay, home):
        self.relay = relay
        self.home = home
        self.user, self.uid, self.gid = home_owner(home)
        self.directory = os.path.join(home, HOOK_DIR)
        self.lock = threading.Lock()
        # Held across taking ownership and across giving it up, so close()
        # can never release the descriptors a takeover is using.
        self.transition = threading.Lock()
        self.stopped = threading.Event()
        self.closing = False
        self.role = None
        self.dir_fd = None
        self.lock_fd = None
        self.servers = []
        self.followers = {}
        self.pending = {}
        self.broker = None
        self.broker_send = threading.Lock()
        self.relayed = set()
        self.error = None

    # Setup

    def start(self):
        for name in (HOOK_SOCKET, BROKER_SOCKET):
            if len(os.path.join(self.directory, name).encode("utf-8")) > MAX_SOCKET_PATH:
                raise HookHomeError("socket path too long")
        try:
            self.open_directory()
            self.lock_fd = os.open(HOOK_LOCK, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW,
                                   0o600, dir_fd=self.dir_fd)
            info = os.fstat(self.lock_fd)
            if not stat_module.S_ISREG(info.st_mode):
                raise HookHomeError("hook.lock is not a regular file")
            if os.geteuid() == 0 and self.uid is not None and info.st_uid != self.uid:
                os.fchown(self.lock_fd, self.uid, self.gid)
        except OSError as error:
            self.release()
            raise HookHomeError(error.strerror or str(error))
        except HookHomeError:
            self.release()
            raise
        with self.transition:
            if self.try_lock():
                try:
                    self.become_owner()
                except (OSError, HookHomeError) as error:
                    self.release()
                    raise HookHomeError(getattr(error, "strerror", None) or str(error))
                return
        self.role = "follower"
        thread = threading.Thread(target=self.follow, name="swarmbar-follower")
        thread.daemon = True
        thread.start()

    def open_directory(self):
        """Opens ~/.swarmbar without following a link, owned by the home's
        owner and mode 700. Everything after goes through this descriptor,
        so a directory swapped out by name later cannot redirect it."""
        if self.uid is None:
            raise HookHomeError("cannot examine home")
        try:
            os.mkdir(self.directory, 0o700)
        except FileExistsError:
            pass
        flags = os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_DIRECTORY", 0)
        self.dir_fd = os.open(self.directory, flags)
        info = os.fstat(self.dir_fd)
        if not stat_module.S_ISDIR(info.st_mode):
            raise HookHomeError("%s is not a directory" % HOOK_DIR)
        root = os.geteuid() == 0
        expected = self.uid if root else os.geteuid()
        if info.st_uid != expected:
            if not (root and info.st_uid == 0):
                raise HookHomeError("%s has another owner" % HOOK_DIR)
            os.fchown(self.dir_fd, self.uid, self.gid)
        if stat_module.S_IMODE(info.st_mode) != 0o700:
            os.fchmod(self.dir_fd, 0o700)

    def try_lock(self):
        try:
            fcntl.flock(self.lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return True
        except OSError:
            return False

    def become_owner(self):
        """Unlinks whatever a crashed owner left and serves both sockets.
        Only the lock holder ever gets here, so it never removes a live
        owner's socket. The caller holds `transition`."""
        if self.closing:
            return
        for name in (HOOK_SOCKET, BROKER_SOCKET):
            try:
                os.unlink(name, dir_fd=self.dir_fd)
            except FileNotFoundError:
                pass
        servers = []
        try:
            for name, handler in ((HOOK_SOCKET, HookHandler), (BROKER_SOCKET, BrokerHandler)):
                with _UMASK_LOCK:
                    previous = os.umask(0o177)
                    try:
                        server = _QuietServer(os.path.join(self.directory, name), handler)
                    finally:
                        os.umask(previous)
                server.hub = self
                servers.append(server)
                if os.geteuid() == 0:
                    os.chown(name, self.uid, self.gid, dir_fd=self.dir_fd,
                             follow_symlinks=False)
        except Exception:
            for server in servers:
                server.server_close()
            raise
        with self.lock:
            self.servers = servers
            self.role = "owner"
            self.error = None
        # Started inside `transition`: shutdown() waits on a serve loop, so
        # close() must never see a server whose loop was not started.
        for server in servers:
            thread = threading.Thread(
                target=server.serve_forever, kwargs={"poll_interval": SERVE_POLL_SECONDS},
                name="swarmbar-hook-server")
            thread.daemon = True
            thread.start()

    # Follower

    def follow(self):
        """Relays the owner's events until it goes, then tries the lock.

        The first attempt comes straight after the connection drops, so a
        clean exit hands over at once; after that, every LOCK_RETRY_SECONDS.
        """
        while not self.closing:
            with self.transition:
                if self.closing:
                    return
                locked = self.try_lock()
                if locked:
                    try:
                        self.become_owner()
                        return
                    except (OSError, HookHomeError) as error:
                        self.error = getattr(error, "strerror", None) or str(error)
                        fcntl.flock(self.lock_fd, fcntl.LOCK_UN)
            if not locked and self.connect_broker():
                self.read_broker()
                continue
            self.stopped.wait(LOCK_RETRY_SECONDS)

    def connect_broker(self):
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            conn.connect(os.path.join(self.directory, BROKER_SOCKET))
        except OSError:
            conn.close()
            return False
        conn.settimeout(BROKER_SEND_TIMEOUT)
        with self.lock:
            if self.closing:
                conn.close()
                return False
            self.broker = conn
        return True

    def read_broker(self):
        conn = self.broker
        try:
            for line in read_lines(conn, lambda: self.closing):
                message = parse_line(line)
                if message is None or "event" not in message:
                    continue
                rid = message.get("rid")
                peer = message.get("peer")
                if message["event"] == "hook" and isinstance(rid, str) and is_holdable(
                        str(message.get("path", "")).rsplit("/", 1)[-1],
                        peer if isinstance(peer, list) else []):
                    self.relayed.add(rid)
                elif message["event"] == "hook_resolved":
                    self.relayed.discard(rid)
                self.relay.emit(message)
        finally:
            with self.lock:
                self.broker = None
            conn.close()
        # Whatever the owner was holding died with it, and the agent has
        # fallen back to its own prompt. Clear those rows on this Mac.
        lost, self.relayed = self.relayed, set()
        if not self.closing:
            for rid in sorted(lost):
                self.relay.emit({"event": "hook_resolved", "rid": rid})

    def forward_reply(self, rid, body):
        conn = self.broker
        if conn is None:
            return
        line = (json.dumps({"type": "reply", "rid": rid, "body": body}) + "\n").encode("utf-8")
        with self.broker_send:
            try:
                conn.sendall(line)
            except OSError:
                drop_connection(conn)

    # Owner

    def add_follower(self, conn):
        with self.lock:
            if self.closing:
                return False
            self.followers[conn] = threading.Lock()
            return True

    def remove_follower(self, conn):
        with self.lock:
            self.followers.pop(conn, None)

    def follower_count(self):
        with self.lock:
            return len(self.followers)

    def broadcast(self, message):
        """Sends a Mac event to every follower. One that cannot take it in
        BROKER_SEND_TIMEOUT is dropped, and will reconnect."""
        line = (json.dumps(message) + "\n").encode("utf-8")
        with self.lock:
            followers = list(self.followers.items())
        for conn, send_lock in followers:
            with send_lock:
                try:
                    conn.sendall(line)
                except OSError:
                    drop_connection(conn)
                    self.remove_follower(conn)

    def publish(self, message):
        """To this helper's Mac and to every follower's."""
        self.relay.emit(message)
        self.broadcast(message)

    def resolve(self, rid, body):
        """Answers a held request with the first reply to reach it. True
        when this home was holding that rid, answered or not."""
        if not isinstance(rid, str) or not isinstance(body, dict):
            return False
        with self.lock:
            held = self.pending.get(rid)
            if held is None:
                return False
            if not held.done.is_set():
                held.body = body
                held.done.set()
        return True

    def handle_post(self, handler):
        match = HOOK_PATH.match(handler.path)
        try:
            body = read_hook_body(handler)
        except OSError:
            body = None
        payload = parse_line(body) if body is not None else None
        if match is None or payload is None or self.closing:
            handler.answer({})
            return
        event = match.group(1)
        try:
            peer = peer_chain(handler.connection)
        except Exception:
            peer = []
        if not isinstance(peer, list):
            peer = []
        account = handler.headers.get("X-Claude-Account", "").strip() or None
        message = {
            "event": "hook",
            "rid": uuid.uuid4().hex,
            "home": self.home,
            "user": self.user,
            "path": "/hook/" + event,
            "account": account,
            "peer": peer,
            "body": payload,
        }
        if not is_holdable(event, peer):
            # Answered before anything else happens, Grok above all: the
            # Mac is only told afterwards, for status.
            handler.answer({})
            self.publish(message)
            return
        self.hold(handler, message)

    def hold(self, handler, message):
        rid = message["rid"]
        held = Held(handler.connection)
        with self.lock:
            if self.closing:
                drop_connection(held.conn)
                return
            self.pending[rid] = held
        self.publish(message)
        deadline = time.monotonic() + HOLD_SECONDS
        gone = False
        while not held.done.is_set():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            if held.done.wait(min(HOLD_POLL_SECONDS, remaining)):
                break
            if client_gone(held.conn):
                gone = True
                break
        with self.lock:
            self.pending.pop(rid, None)
            dropped, body = held.dropped, held.body
        if dropped:
            # The helper is exiting. The connection was shut with no answer,
            # so the agent falls back to its own prompt.
            return
        if not gone:
            handler.answer(body if body is not None else {})
        self.publish({"event": "hook_resolved", "rid": rid})

    # Shutdown

    def release(self):
        for name in ("lock_fd", "dir_fd"):
            fd = getattr(self, name)
            if fd is not None:
                try:
                    os.close(fd)
                except OSError:
                    pass
                setattr(self, name, None)

    def close(self):
        """Drops every held request with no answer, then gives up the
        sockets and the lock, in that order, so the next helper can take
        over the moment its broker connection closes."""
        with self.lock:
            self.closing = True
            dropped = list(self.pending.items())
            for _, held in dropped:
                held.dropped = True
                held.done.set()
                drop_connection(held.conn)
            broker = self.broker
        self.stopped.set()
        for rid, _ in dropped:
            self.broadcast({"event": "hook_resolved", "rid": rid})
        with self.transition:
            with self.lock:
                servers, self.servers = self.servers, []
                followers = list(self.followers)
            if servers:
                for name in (HOOK_SOCKET, BROKER_SOCKET):
                    try:
                        os.unlink(name, dir_fd=self.dir_fd)
                    except OSError:
                        pass
            self.release()
        for conn in followers:
            drop_connection(conn)
        if broker is not None:
            drop_connection(broker)
        # Each shutdown waits out its loop's poll, so they run side by side.
        stoppers = [threading.Thread(target=server.shutdown) for server in servers]
        for stopper in stoppers:
            stopper.start()
        for stopper in stoppers:
            stopper.join()
        for server in servers:
            server.server_close()


class HookRelay(object):
    """Every hook home this helper serves or follows. `emit` sends one event
    to this helper's Mac; it is write_line except in tests."""

    def __init__(self, emit=None):
        self.emit_line = emit if emit is not None else write_line
        self.hubs = {}
        self.lock = threading.Lock()
        self.closed = False

    def emit(self, message):
        try:
            self.emit_line(message)
        except Exception:
            # The Mac is gone or going. Its helper exits on stdin EOF.
            pass

    def refresh(self):
        """Starts a hub for every newly qualifying home and keeps the rest.
        Returns warnings for homes that cannot be served, which are retried
        on the next refresh."""
        warnings = []
        for home in hook_homes():
            with self.lock:
                if self.closed:
                    return warnings
                hub = self.hubs.get(home)
            if hub is not None:
                if hub.error:
                    warnings.append("hook socket for %s: %s" % (home, hub.error))
                continue
            hub = HookHome(self, home)
            try:
                hub.start()
            except HookHomeError as error:
                warnings.append("hook socket unavailable for %s: %s" % (home, error))
                continue
            with self.lock:
                if self.closed:
                    hub.close()
                    return warnings
                self.hubs[home] = hub
        return warnings

    def handle_reply(self, request):
        """The hook_reply request. The rid is answered here when this helper
        holds it, and otherwise passed to each owner it follows."""
        rid, body = request.get("rid"), request.get("body")
        if not isinstance(rid, str) or not isinstance(body, dict):
            return {"ok": False, "error": "bad reply"}
        with self.lock:
            hubs = list(self.hubs.values())
        if not any(hub.resolve(rid, body) for hub in hubs):
            for hub in hubs:
                hub.forward_reply(rid, body)
        return {"ok": True}

    def close(self):
        with self.lock:
            self.closed = True
            hubs = list(self.hubs.values())
        for hub in hubs:
            hub.close()


def main(stdin=None, stdout=None):
    global _OUT
    stdin = stdin if stdin is not None else sys.stdin
    _OUT = stdout if stdout is not None else sys.stdout
    relay = HookRelay()
    try:
        relay.refresh()
    except Exception:
        # Hook homes are checked again on every snapshot, which reports why.
        pass
    try:
        serve_requests(stdin, relay)
    finally:
        # stdin EOF: the Mac is gone. Held requests drop with no answer and
        # the sockets and lock go with them, so the agent falls back to its
        # own prompt and the next helper can take over.
        relay.close()


def refresh_hooks(relay):
    try:
        return relay.refresh()
    except Exception as error:
        return ["hook relay: %s" % error]


def serve_requests(stdin, relay):
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
                hook_warnings = refresh_hooks(relay)
                response = snapshot()
                response["warnings"] = response["warnings"] + hook_warnings
            elif command == "hook_reply":
                response = relay.handle_reply(request)
            elif command == "ping":
                response = ping()
            elif command in ("capture", "keys", "paste"):
                response = handle_tmux(request)
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
