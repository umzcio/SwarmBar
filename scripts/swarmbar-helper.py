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

import sys

# The probe must leave nothing behind, and python's own bytecode cache is a
# write like any other: Apple's python 3.9 keeps it under ~/Library/Caches.
# Set before any other import so none of them writes one either.
if sys.argv[1:2] == ["probe"]:
    sys.dont_write_bytecode = True

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
import queue
import re
import select
import shutil
import signal
import socket
import socketserver
import stat as stat_module
import struct
import subprocess
import tempfile
import threading
import time
import uuid
import zlib

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


def owned_home(path):
    """Whether a directory is somebody's home: a passwd entry's pw_dir
    resolves to it, the entry's uid owns it, and nobody else can write it.

    Darwin's /Users/Shared sits beside the homes, root-owned and mode 1777.
    Taken as a home it was root's, so a hardlink any user planted in it
    was read by the probe and written by root. Checking the owner's own
    entry, not merely the owner, keeps out every shared directory like it.
    """
    try:
        import pwd
        real = os.path.realpath(path)
        info = os.stat(real)
        if not stat_module.S_ISDIR(info.st_mode) or not only_owner_can_write(info):
            return False
        return os.path.realpath(pwd.getpwuid(info.st_uid).pw_dir) == real
    except (ImportError, KeyError, OSError):
        return False


def home_candidates():
    """Where homes may be, before owned_home has a say."""
    if os.geteuid() != 0:
        return [os.path.expanduser("~")]
    homes = []
    if platform.system() == "Darwin":
        homes.append("/var/root")
        parent = "/Users"
    else:
        homes.append("/root")
        parent = "/home"
    try:
        for entry in sorted(os.listdir(parent)):
            homes.append(os.path.join(parent, entry))
    except OSError:
        pass
    return homes


def home_dirs():
    """The homes to scan. Darwin and Linux differ.

    SWARMBAR_HELPER_HOMES (colon-separated) replaces discovery so tests never
    read a real home. Without it, root sees every home, while any other user
    sees only its own: listing /home as an unprivileged user would offer
    directories it cannot read. Either way a directory is a home only when
    owned_home says so, and that holds for discovery, the probe, the hook
    homes and setup writes alike.
    """
    override = os.environ.get("SWARMBAR_HELPER_HOMES")
    if override:
        return [h for h in override.split(":") if h and os.path.isdir(h)]
    return [h for h in home_candidates() if owned_home(h)]


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


def run_command(argv, timeout=5, input=None, **options):
    """The one place the helper starts a subprocess (ps, tmux, lsof, kimi
    doctor, visudo).

    Tests replace this so no unit test ever inspects a real process. It
    raises OSError or SubprocessError like subprocess.run, and callers decide
    whether a failure matters. `input` is bytes for the child's stdin (tmux
    load-buffer reads the paste text there); None leaves stdin alone.
    `options` go to subprocess as they are: env, cwd, and user, group and
    extra_groups to run as someone other than root. With
    start_new_session, a timeout kills the child's whole process group,
    since a wrapper script that execs node can leave a grandchild running
    after its own pid is gone.
    """
    if not options.get("start_new_session"):
        return subprocess.run(
            argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout,
            input=input, **options
        )
    with subprocess.Popen(argv, stdin=subprocess.PIPE if input is not None else None,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, **options) as proc:
        try:
            out, err = proc.communicate(input, timeout=timeout)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except OSError:
                proc.kill()
            proc.communicate()
            raise
        return subprocess.CompletedProcess(argv, proc.returncode, out, err)


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


def agent_processes(warnings, screens=True):
    """Live agent processes. `ps -axo` is portable; GNU long flags are not.

    `screens` False leaves out the pane captures and the "screen" field,
    which the probe has no use for and which cost a tmux call per agy."""
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
        })
        if screens:
            entry["screen"] = pane_screen(pane) if pane and row["comm"] == "agy" else None
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


# The files setup may write, relative to a home. Task 19's write_file
# enforces this list; the probe reports the first five, the agents' own
# config files, so the Mac can plan edits against the exact bytes it read.
# The rest are SwarmBar's own bridge files.
ALLOWED = (
    ".claude*/settings.json",
    ".kimi-code/config.toml",
    ".bearcode/config.toml",
    ".config/opencode/opencode.json",
    ".config/opencode/opencode.jsonc",
    ".config/opencode/plugins/swarmbar-remote.js",
    ".swarmbar/swarmbar-remote-hook.sh",
    ".swarmbar/swarmbar-remote-kimi-hook.sh",
)
CONFIG_TOOLS = (
    ("claude", ALLOWED[0]),
    ("kimi", ALLOWED[1]),
    ("bearcode", ALLOWED[2]),
    ("opencode", ALLOWED[3]),
    ("opencode", ALLOWED[4]),
)
# Past this a config's sha256 is still reported but its text is not: the
# setup plan cannot edit what it did not read, and no real config is this big.
CONFIG_TEXT_MAX = 256 * 1024
# Each tool's state directory, which says the tool is in use in a home.
# Claude is found the way discovery finds it, through claude_config_dirs.
TOOL_STATE_DIRS = (
    ("codex", ".codex"),
    ("kimi", ".kimi-code"),
    ("bearcode", ".bearcode"),
    ("opencode", ".local/share/opencode"),
    ("grok", ".grok"),
    ("antigravity", ".gemini/antigravity-cli"),
)
# The order the probe lists tools in, matching AgentTool.allCases on the Mac.
TOOL_ORDER = ("claude", "codex", "kimi", "bearcode", "opencode", "grok", "antigravity")
# A bridge is installed when its config names it and the file the config
# names is there: an entry pointing at a missing script answers nothing.
BRIDGE_FILES = (
    ("claude", ALLOWED[6]),
    ("kimi", ALLOWED[7]),
    ("bearcode", ALLOWED[7]),
    ("opencode", ALLOWED[5]),
)
# The order the probe lists a home's bridge files in.
BRIDGE_PATHS = (ALLOWED[6], ALLOWED[7], ALLOWED[5])
BRIDGE_MARK = b"swarmbar-remote"
HELPER_PATHS = ("/usr/local/lib/swarmbar-helper",)
USER_HELPER = ".swarmbar/swarmbar-helper"
SUDO_SECONDS = 5


def claude_config_dirs(home):
    """<home>/.claude* directories, backups left out by name, the same way
    claude_roots leaves them out of discovery."""
    try:
        entries = sorted(os.listdir(home))
    except OSError:
        return []
    return [os.path.join(home, entry) for entry in entries
            if entry.startswith(".claude") and not is_backup_name(entry)
            and os.path.isdir(os.path.join(home, entry))]


def file_digest(path, limit=None):
    """(sha256, bytes or None) of a regular file, or None when it cannot be
    read. The bytes come back only when the file is at most `limit`."""
    try:
        with open(path, "rb") as handle:
            data = handle.read()
    except OSError:
        return None
    kept = data if limit is None or len(data) <= limit else None
    return hashlib.sha256(data).hexdigest(), kept


def owner_only_path(home, resolved, uid):
    """Whether every directory from the home down to a file is owned by
    `uid` and writable by nobody else, the file included and links not
    followed. Anything less and someone else chose what sits at that
    path: a hardlink to /etc/sudoers in a shared directory has exactly
    the right name."""
    real_home = os.path.realpath(home).rstrip("/")
    if uid is None or not resolved.startswith(real_home + "/"):
        return False
    current = real_home
    for part in [""] + resolved[len(real_home) + 1:].split("/"):
        current = os.path.join(current, part) if part else current
        try:
            info = os.lstat(current)
        except OSError:
            return False
        if info.st_uid != uid or not only_owner_can_write(info) \
                or stat_module.S_ISLNK(info.st_mode):
            return False
    return True


def read_owned_bytes(path, uid, size=-1):
    """Up to `size` bytes of a file that must be `uid`'s own regular file,
    checked on the descriptor actually read, so a swap after the path was
    checked is caught. None when it is not, or cannot be read."""
    def opener(name, flags):
        return os.open(name, flags | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        with open(path, "rb", opener=opener) as handle:
            info = os.fstat(handle.fileno())
            if not stat_module.S_ISREG(info.st_mode) or info.st_uid != uid:
                return None
            return handle.read(size)
    except OSError:
        return None


def read_owned(path, uid, limit=None):
    """file_digest through read_owned_bytes."""
    data = read_owned_bytes(path, uid)
    if data is None:
        return None
    kept = data if limit is None or len(data) <= limit else None
    return hashlib.sha256(data).hexdigest(), kept


def home_configs(home, warnings):
    """The agent config files in a home that exist, each once by realpath.

    One that exists but cannot be read is still listed, with a null hash
    and text and a warning: dropping it would make the plan create a file
    that is already there, and could-not-read would read as absent. So is
    one that is not the home owner's own all the way down (owner_only_path):
    run as root, reading it would hand its contents to whoever planted it.

    Each entry carries the file's dev and ino, so the Mac can plan one
    write for profiles that share one file by hardlink: two realpaths, one
    file, and a second write would find the hash it expected already gone."""
    configs = []
    seen = set()
    uid = home_owner(home)[1]
    for tool, pattern in CONFIG_TOOLS:
        if pattern.startswith(".claude*/"):
            candidates = [os.path.join(d, pattern[len(".claude*/"):])
                          for d in claude_config_dirs(home)]
        else:
            candidates = [os.path.join(home, pattern)]
        for candidate in candidates:
            resolved = os.path.realpath(candidate)
            if resolved in seen or not os.path.isfile(resolved):
                continue
            seen.add(resolved)
            # stat reads no contents, so it is safe even on a refused file.
            try:
                info = os.stat(resolved)
                identity = {"dev": info.st_dev, "ino": info.st_ino}
            except OSError:
                identity = {"dev": None, "ino": None}
            entry = {"tool": tool, "path": resolved, "sha256": None, "text": None}
            entry.update(identity)
            if not owner_only_path(home, resolved, uid):
                warnings.append("refusing %s config %s: it is not the home owner's own"
                                % (tool, resolved))
                configs.append(entry)
                continue
            digest = read_owned(resolved, uid, CONFIG_TEXT_MAX)
            if digest is None:
                warnings.append("cannot read %s config %s" % (tool, resolved))
                configs.append(entry)
                continue
            text = None
            if digest[1] is not None:
                try:
                    text = digest[1].decode("utf-8")
                except UnicodeDecodeError:
                    text = None
            entry["sha256"], entry["text"] = digest[0], text
            configs.append(entry)
    return configs


def owned_state(home, path, uid):
    """("absent", None), ("present", sha256) or ("unreadable", None) for a
    file the setup plan may write. Absent only when lstat says there is no
    such file: anything else that stops the read is unreadable, which must
    never plan as a new file. The read is the configs' own: refused unless
    the file is the home owner's all the way down."""
    try:
        os.lstat(path)
    except FileNotFoundError:
        return "absent", None
    except OSError:
        return "unreadable", None
    resolved = os.path.realpath(path)
    if not owner_only_path(home, resolved, uid):
        return "unreadable", None
    digest = read_owned(resolved, uid, 0)
    if digest is None:
        return "unreadable", None
    return "present", digest[0]


def home_bridges(home, warnings):
    """SwarmBar's three remote bridge files in a home, each {"path",
    "sha256"}, the sha256 null when the file is absent. One there that
    cannot be read adds "unreadable": true and a warning, so the plan can
    replace a current copy, skip an identical one, and never take a file it
    could not read for a missing one."""
    uid = home_owner(home)[1]
    found = []
    for relative in BRIDGE_PATHS:
        path = os.path.join(home, relative)
        state, digest = owned_state(home, path, uid)
        entry = {"path": path, "sha256": digest}
        if state == "unreadable":
            entry["unreadable"] = True
            warnings.append("cannot read bridge file %s" % path)
        found.append(entry)
    return found


def home_claude_dirs(home, warnings):
    """Every Claude config dir in use in a home (one with projects/), once
    by realpath, each {"path", "settings": "present" | "missing" |
    "unreadable"}. A profile with no settings.json still needs hooks, and
    only this says where it is."""
    uid = home_owner(home)[1]
    found = []
    seen = set()
    for directory in claude_config_dirs(home):
        if not os.path.isdir(os.path.join(directory, "projects")):
            continue
        real = os.path.realpath(directory)
        if real in seen:
            continue
        seen.add(real)
        state = owned_state(home, os.path.join(real, "settings.json"), uid)[0]
        if state == "unreadable":
            warnings.append("cannot read Claude settings in %s" % real)
        found.append({"path": real, "settings": "missing" if state == "absent" else state})
    return found


def mentions_bridge(home, path, uid):
    """True or False, or None when the file is there but cannot be read, or
    is not the home owner's own all the way down (owner_only_path). Like
    the config reads, it refuses rather than reads: one bit is still a
    read of a file someone else planted."""
    resolved = os.path.realpath(path)
    if not os.path.lexists(resolved):
        return False
    if not owner_only_path(home, resolved, uid):
        return None
    data = read_owned_bytes(resolved, uid, WHOLE_MAX_BYTES)
    if data is None:
        return None
    return BRIDGE_MARK in data


def home_tools(home):
    """Which tools have their state directory in a home, in TOOL_ORDER."""
    present = set()
    if any(os.path.isdir(os.path.join(d, "projects")) for d in claude_config_dirs(home)):
        present.add("claude")
    for tool, relative in TOOL_STATE_DIRS:
        if os.path.isdir(os.path.join(home, relative)):
            present.add(tool)
    return [tool for tool in TOOL_ORDER if tool in present]


def home_installed(home, warnings):
    """(installed, unknown): which tools' remote bridges are in place in a
    home, and which could not be told because a config could not be read,
    each in TOOL_ORDER.

    Claude counts only when every config dir it is used from names the
    bridge, so a second profile without hooks still reads as not set up."""
    installed, unknown = set(), set()
    uid = home_owner(home)[1]
    for tool, bridge in BRIDGE_FILES:
        if not os.path.isfile(os.path.join(home, bridge)):
            continue
        if tool == "claude":
            used = [d for d in claude_config_dirs(home)
                    if os.path.isdir(os.path.join(d, "projects"))]
            found = [mentions_bridge(home, os.path.join(d, "settings.json"), uid)
                     for d in used]
        else:
            found = [mentions_bridge(home, os.path.join(home, pattern), uid)
                     for name, pattern in CONFIG_TOOLS if name == tool]
            # One OpenCode config naming the bridge is enough.
            if True in found:
                found = [True]
        if not found or False in found:
            continue
        if None in found:
            unknown.add(tool)
            warnings.append("cannot tell whether %s is set up in %s: a config cannot be read "
                            "or is not the home owner's own" % (tool, home))
        else:
            installed.add(tool)
    return ([tool for tool in TOOL_ORDER if tool in installed],
            [tool for tool in TOOL_ORDER if tool in unknown])


def installed_helpers(homes):
    """{"path", "sha256"} for each installed helper. sha256 is None when the
    file is there but cannot be read, as the root helper (root's, mode 700)
    cannot be by anyone else."""
    found = []
    for path in list(HELPER_PATHS) + [os.path.join(home, USER_HELPER) for home in homes]:
        if not os.path.isfile(path):
            continue
        digest = file_digest(path)
        found.append({"path": path, "sha256": digest[0] if digest else None})
    return found


def own_digest():
    """This file's sha256 when it runs from a file, as the installed root
    helper does under the narrow sudo rule; None when it came from stdin."""
    path = globals().get("__file__")
    if not path or not os.path.isfile(path):
        return None
    digest = file_digest(path)
    return digest[0] if digest else None


def sudo_ok():
    try:
        return run_command(["sudo", "-n", "true"], timeout=SUDO_SECONDS).returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


def probe():
    """What the setup wizard needs to know about a host, read-only.

    It runs as `python3 -B - probe` with this file on stdin, before the
    helper is installed anywhere, and as `/usr/local/lib/swarmbar-helper
    probe` under the narrow sudo rule for the view of every user. It writes nothing and starts nothing that
    outlives it: no hook homes, sockets, ~/.swarmbar or writer thread.
    """
    warnings = []
    homes = home_entries(warnings)
    paths = [home["path"] for home in homes]
    processes = agent_processes(warnings, screens=False)
    try:
        import pwd
        user = pwd.getpwuid(os.geteuid()).pw_name
    except (ImportError, KeyError):
        user = ""
    installed, unknown, configs, bridges, claude_dirs = {}, {}, {}, {}, {}
    for path in paths:
        installed[path], unknown[path] = home_installed(path, warnings)
        configs[path] = home_configs(path, warnings)
        bridges[path] = home_bridges(path, warnings)
        claude_dirs[path] = home_claude_dirs(path, warnings)
    return {
        "ok": True,
        "protocol": PROTOCOL_VERSION,
        "system": platform.system(),
        "python": platform.python_version(),
        "hostname": platform.node(),
        "user": user,
        "euid": os.geteuid(),
        "sudo_ok": sudo_ok(),
        "homes": homes,
        "processes": processes if processes is not None else [],
        "processes_failed": processes is None,
        "tools": dict((path, home_tools(path)) for path in paths),
        "installed": installed,
        "installed_unknown": unknown,
        "configs": configs,
        "bridges": bridges,
        "claude_dirs": claude_dirs,
        "helper": installed_helpers(paths),
        "self_sha256": own_digest(),
        "warnings": warnings,
    }


def probe_main():
    """One JSON object on stdout and exit 0, whatever happens: the Mac
    reads a failure from the object, not from the exit status."""
    try:
        result = probe()
    except Exception as error:
        # The version rides along so an old python reads as too old, not as
        # an unexplained failure.
        result = {"ok": False, "protocol": PROTOCOL_VERSION,
                  "python": platform.python_version(),
                  "error": "probe failed: %s" % error}
    sys.stdout.write(json.dumps(result) + "\n")
    sys.stdout.flush()


PANE_ID = re.compile(r"^%[0-9]+$")
KEY_GAP_DEFAULT = 0.08
KEY_GAP_MAX = 0.5
# ESC[200~ and ESC[201~ as send-keys -H hex, the bracketed paste markers.
PASTE_START = ["1b", "5b", "32", "30", "30", "7e"]
PASTE_END = ["1b", "5b", "32", "30", "31", "7e"]
NAMED_KEYS = {"UP": "Up", "DOWN": "Down", "ESC": "Escape", "\n": "Enter"}
# C0 controls other than newline and tab, plus DEL. ESC is the one that
# matters: it could close the bracketed paste early or open a sequence.
PASTE_STRIP = re.compile("[\x00-\x08\x0b-\x1f\x7f]")


def paste_buffer_name():
    """A buffer of this request's own. Two Macs share a helper's tmux server,
    and a shared name lets one paste the other's text."""
    return "swarmbar-%d-%s" % (os.getpid(), uuid.uuid4().hex)


def valid_expect_more(entries):
    """Whether `entries` is a list of {"text": non-empty str, "before": int
    of at least 0}."""
    if not isinstance(entries, list):
        return False
    for entry in entries:
        if not isinstance(entry, dict):
            return False
        text, before = entry.get("text"), entry.get("before")
        if not isinstance(text, str) or not text:
            return False
        if isinstance(before, bool) or not isinstance(before, int) or before < 0:
            return False
    return True


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


def target_still_there(pid, comm, pane):
    """Whether `pid` is still the agent `comm`, running in `pane`.

    Read fresh at press time. A pane the Mac learned from a snapshot can be
    seconds old by the time a key goes to it: the agent may have exited and
    left a shell, its pid may belong to something else, or the pane may have
    been reused. Any doubt, a failed ps included, reads as changed, so a key
    only ever lands where the Mac believes it does.
    """
    try:
        completed = run_command(
            ["ps", "-axo", "pid=,ppid=,uid=,user=,tty=,comm=,args="], timeout=15,
        )
    except (OSError, subprocess.SubprocessError):
        return False
    if completed.returncode != 0:
        return False
    rows = parse_ps(completed.stdout.decode("utf-8", "replace"))
    row = None
    for candidate in rows:
        if candidate["pid"] == pid:
            row = candidate
            break
    if row is None or agent_name(row) != comm:
        return False
    parents = dict((r["pid"], r["ppid"]) for r in rows)
    found = pane_for(pid, parents, tmux_panes())
    if found is None or found.get("id") != pane.get("id"):
        return False
    return os.path.realpath(found.get("socket", "")) == os.path.realpath(pane.get("socket", ""))


def target_refusal(request, malformed):
    """The reply refusing a keys or paste request whose `pid` and `comm` no
    longer describe its pane, or None to go ahead. A request carrying
    neither is not checked; one carrying only one, or either of the wrong
    type, is refused with `malformed`."""
    has_pid, has_comm = "pid" in request, "comm" in request
    if not (has_pid or has_comm):
        return None
    pid, comm = request.get("pid"), request.get("comm")
    if not (has_pid and has_comm) or isinstance(pid, bool) \
            or not isinstance(pid, int) or not isinstance(comm, str):
        return {"ok": False, "error": malformed}
    if not target_still_there(pid, comm, request.get("pane")):
        return {"sent": False, "reason": "changed"}
    return None


def handle_tmux(request):
    """capture, keys and paste. Keys are confirmed against a fresh capture of
    the visible screen taken immediately before sending, and any missing
    expectation sends nothing, because a prompt that moved under the Mac's
    read could otherwise take a keystroke meant for another prompt.

    Response shapes the Mac decodes (the request id is added by main):
      capture: {"text": str}, or {"ok": false, "error": "capture failed"}
      keys and paste: {"sent": true}, or {"sent": false, "reason": r} with r
        "changed" (an expect string was absent, or an expect_more count did
        not rise), "capture failed" (the confirming read failed), "load
        failed" (paste only: the text never reached tmux, so nothing was
        typed), or "send failed" (plus "sent_count" for keys, how many keys
        landed first; for paste, some of the text may be in the pane).
      any command: {"ok": false, "error": "bad pane" | "bad keys" | "bad text"
        | "bad target"}

    keys and paste may carry `pid` (int) and `comm` (str), always together.
    With them the target is re-read before anything is sent, and a pid that
    is gone, is another agent, or no longer sits in this pane answers
    "changed". A malformed pair answers "bad keys" for keys and "bad target"
    for paste.

    keys may also carry `expect_more`, a list of {"text": str, "before":
    int}: each text must occur more times on the press-time screen than
    `before`, the count the Mac read before it pasted. A short reply such
    as "ok" is usually on screen already, so presence alone would confirm a
    paste that never landed. A malformed list answers "bad keys".
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
        # A reply pasted into a pane that now holds a shell or another agent
        # is text the Mac never meant there, so the target is re-read first.
        refused = target_refusal(request, "bad target")
        if refused is not None:
            return refused
        # The local reply's form, verified live on all seven tools: the
        # bracket markers are sent explicitly and the text goes between them
        # with -r. paste-buffer -p would bracket only when the pane's app has
        # enabled the mode, which tmux 3.4 cannot report, and without -r tmux
        # turns every LF into CR, an Enter, so a multi-line reply would
        # submit line by line before the Mac ever checked the screen. No
        # Enter follows: the Mac decides separately whether to submit.
        # Stripping controls means the text itself can never carry ESC, so
        # it cannot close the paste early or open a sequence of its own.
        text = PASTE_STRIP.sub("", text)

        def step(args, data=None):
            done = tmux_run(pane, args, input=data)
            return done is not None and done.returncode == 0

        buffer = paste_buffer_name()
        close = ["send-keys", "-t", pane["id"], "-H"] + PASTE_END
        # Nothing has reached the pane yet, so this one says so: the Mac
        # reports it as nothing sent, where every later failure may have
        # left text in the composer.
        if not step(["load-buffer", "-b", buffer, "-"], text.encode("utf-8")):
            return {"sent": False, "reason": "load failed"}

        def failed():
            # Best effort: the paste has already failed, and a buffer left
            # behind holds the reply's text on the server.
            step(["delete-buffer", "-b", buffer])
            return {"sent": False, "reason": "send failed"}
        if not step(["send-keys", "-t", pane["id"], "-H"] + PASTE_START):
            return failed()
        if not step(["paste-buffer", "-r", "-d", "-b", buffer, "-t", pane["id"]]):
            # ESC[200~ is out, so close it whatever happened, or the pane's
            # app stays in paste mode and takes the next keys as text.
            step(close)
            return failed()
        if not step(close):
            return failed()
        return {"sent": True}
    keys, expect = request.get("keys"), request.get("expect") or []
    expect_more = request.get("expect_more", [])
    if not isinstance(keys, list) or not all(isinstance(k, str) for k in keys) \
            or not isinstance(expect, list) or not all(isinstance(e, str) for e in expect) \
            or not valid_expect_more(expect_more):
        return {"ok": False, "error": "bad keys"}
    refused = target_refusal(request, "bad keys")
    if refused is not None:
        return refused
    gap = request.get("gap", KEY_GAP_DEFAULT)
    if not isinstance(gap, (int, float)) or isinstance(gap, bool) or gap < 0:
        gap = KEY_GAP_DEFAULT
    gap = min(gap, KEY_GAP_MAX)
    if expect or expect_more:
        screen = pane_text(pane)
        if screen is None:
            return {"sent": False, "reason": "capture failed"}
        if any(e not in screen for e in expect):
            return {"sent": False, "reason": "changed"}
        # str.count is non-overlapping, as the Mac counts.
        if any(screen.count(m["text"]) <= m["before"] for m in expect_more):
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
# Running as root, the helper never creates, binds or changes anything in a
# user's home itself. Each of those steps runs in a child process started as
# the home's owner, and the child hands back only file descriptors.
# Done as root, a user could hardlink a root-owned file in as hook.lock for
# root to hand over, or swap ~/.swarmbar for a link between a check and a
# bind.
#
# Broker protocol, newline-delimited JSON over broker.sock:
#   owner -> follower:
#     a Mac event, verbatim, which the follower writes to its own Mac
#       unchanged: {"event": "hook", ...} or {"event": "hook_resolved", ...};
#     {"type": "held", "rid": str}, just before the hook event of a request
#       the owner is holding, so the follower knows which rows to clear if
#       the owner dies holding them;
#     {"type": "pending", "rids": [str]}, first on every connection: the
#       holds still open. Each is then replayed as "held" plus its hook
#       event, so a follower that reconnects can still answer it, and one
#       that missed a resolution while away can clear the row.
#   follower -> owner:
#     {"type": "reply", "rid": str, "body": {...}}, its Mac's hook_reply. The
#       first reply for a rid, from any Mac, answers it.
# Connecting is registering. There is no other handshake.
#
# Every hook event carries "held": true while the owner is holding that
# request for a decision, so a Mac shows Approve only when an answer can
# still land, and false when it was already answered {} (not holdable, a
# Grok refusal, unreadable Grok state, the hold cap). Replays carry true.

# The steps that act inside a home, as python source. Run as root, they run
# in a child started with `python3 -I -S -c STEP_SOURCE <step> <dir> <fd>`
# that is already the home's owner (uid, gid and its groups, umask 177), and
# hand back descriptors over the socketpair whose number is <fd>. Run as
# the owner, the same text is exec'd once into _STEPS and called
# in-process. Inline source, because under root the helper file is root's,
# mode 700, and the child cannot read it. exec, not fork, because a fork of
# this threaded process can deadlock in the child on any lock another
# thread held, and python 3.12 says so on stderr.
STEP_SOURCE = r'''
import base64
import errno
import hashlib
import json
import os
import shutil
import socket
import stat
import sys

HOOK_SOCKET = "hook.sock"
BROKER_SOCKET = "broker.sock"
HOOK_LOCK = "hook.lock"


class StepError(Exception):
    """A home whose sockets cannot be set up, with the reason."""


def step_prepare(directory, umask_lock):
    """~/.swarmbar (700, this user's own, never through a link) and its
    lock file. Returns [directory fd, lock fd]."""
    try:
        os.mkdir(directory, 0o700)
    except FileExistsError:
        pass
    dir_fd = os.open(directory, os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_DIRECTORY", 0))
    try:
        info = os.fstat(dir_fd)
        if not stat.S_ISDIR(info.st_mode):
            raise StepError(".swarmbar is not a directory")
        if info.st_uid != os.geteuid():
            raise StepError(".swarmbar has another owner")
        if stat.S_IMODE(info.st_mode) != 0o700:
            os.fchmod(dir_fd, 0o700)
        lock_fd = os.open(HOOK_LOCK, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600,
                          dir_fd=dir_fd)
        lock = os.fstat(lock_fd)
        # A second link is someone else's file wearing this name.
        if not stat.S_ISREG(lock.st_mode) or lock.st_uid != os.geteuid() \
                or lock.st_nlink != 1:
            os.close(lock_fd)
            raise StepError("%s is not this user's own file" % HOOK_LOCK)
    except BaseException:
        os.close(dir_fd)
        raise
    return [dir_fd, lock_fd]


def step_bind(directory, umask_lock):
    """Removes whatever a crashed owner left and binds both sockets, 600 by
    umask: the child's was set when it started, and in-process it is set
    here under the lock, since a umask is process-wide. Returns
    [hook fd, broker fd], listening."""
    fds = []
    try:
        for name in (HOOK_SOCKET, BROKER_SOCKET):
            path = os.path.join(directory, name)
            try:
                os.unlink(path)
            except FileNotFoundError:
                pass
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            try:
                if umask_lock is None:
                    sock.bind(path)
                else:
                    with umask_lock:
                        previous = os.umask(0o177)
                        try:
                            sock.bind(path)
                        finally:
                            os.umask(previous)
                sock.listen(16)
            except BaseException:
                sock.close()
                raise
            fds.append(sock.detach())
    except BaseException:
        for fd in fds:
            os.close(fd)
        raise
    return fds


def step_connect(directory, umask_lock):
    """A connection to the owner's broker. Returns [fd]."""
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        sock.connect(os.path.join(directory, BROKER_SOCKET))
    except BaseException:
        sock.close()
        raise
    return [sock.detach()]


BY_KIND = {"prepare": step_prepare, "bind": step_bind, "connect": step_connect}

BACKUP_SUFFIX = ".backup-swarmbar"
# A job is a few config files' worth of JSON. Past this the parent is not
# one this child should be listening to.
MAX_JOB_BYTES = 16 * 1024 * 1024


def refusal(error):
    return {"ok": False, "error": error}


def write_bytes(handle, data):
    """Replaces a file's bytes through an open handle, so the inode, and
    with it every hardlink, stays the one the user had."""
    handle.seek(0)
    handle.truncate()
    handle.write(data)
    handle.flush()
    os.fsync(handle.fileno())


class Refused(Exception):
    """A file job refused, with the error the response carries."""


DIRECTORY_FLAGS = os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_DIRECTORY", 0)


def only_owner_can_write(info):
    """Whether nobody but the owner of `info` can write it. The one rule for
    the home check, the write walk and the probe's reads.

    Other-writable never passes. Group-writable passes only through a
    user-private group: Ubuntu's umask 002 makes a user's own directories
    775 under a group named for them, and refusing those would refuse the
    login user's own config. The group must be the owner's primary group,
    have no member but the owner, and be no one else's primary group.
    """
    mode = info.st_mode
    if mode & 0o002:
        return False
    if not mode & 0o020:
        return True
    try:
        import grp
        import pwd
        owner = pwd.getpwuid(info.st_uid)
        if info.st_gid != owner.pw_gid:
            return False
        if any(member != owner.pw_name for member in grp.getgrgid(info.st_gid).gr_mem):
            return False
        return not any(entry.pw_gid == info.st_gid and entry.pw_name != owner.pw_name
                       for entry in pwd.getpwall())
    except (ImportError, KeyError, OSError):
        return False


def checked_directory(fd):
    """A directory this user owns and nobody else can write, or Refused.
    Anything less and someone else decides what its names point at."""
    info = os.fstat(fd)
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid() \
            or not only_owner_can_write(info):
        os.close(fd)
        raise Refused("not allowed")
    return fd


def open_directory(name, parent_fd=None):
    try:
        if parent_fd is None:
            fd = os.open(name, DIRECTORY_FLAGS)
        else:
            fd = os.open(name, DIRECTORY_FLAGS, dir_fd=parent_fd)
    except OSError as error:
        if error.errno in (errno.ELOOP, errno.ENOTDIR):
            raise Refused("not allowed")
        raise
    return checked_directory(fd)


def walk_to_parent(job, create):
    """An fd on the directory that holds the target, reached from the home
    one component at a time with O_NOFOLLOW, every step checked by
    checked_directory. Nothing is resolved by path after the parent
    process checked the allowlist, so a link swapped in anywhere along
    the way refuses the job instead of steering it. With `create`, a
    missing directory is made 700 (~/.swarmbar must be 700 for the hook
    steps) and the mode set outright, since a umask would narrow it.
    Returns (fd, leaf name); None as fd when a directory is missing and
    `create` is false."""
    home, target = job["home"], job["target"]
    if not target.startswith(home.rstrip("/") + "/"):
        raise Refused("not allowed")
    parts = target[len(home.rstrip("/")) + 1:].split("/")
    fd = open_directory(home)
    try:
        for part in parts[:-1]:
            try:
                child = open_directory(part, fd)
            except FileNotFoundError:
                if not create:
                    os.close(fd)
                    return None, parts[-1]
                try:
                    os.mkdir(part, 0o700, dir_fd=fd)
                except FileExistsError:
                    pass
                child = os.open(part, DIRECTORY_FLAGS, dir_fd=fd)
                try:
                    os.fchmod(child, 0o700)
                except BaseException:
                    os.close(child)
                    raise
                child = checked_directory(child)
            os.close(fd)
            fd = child
    except BaseException:
        try:
            os.close(fd)
        except OSError:
            pass
        raise
    return fd, parts[-1]


def take_backup(parent_fd, leaf, current, mode):
    """The one-time backup beside the file: written from the bytes the hash
    just matched, through the directory fd, O_EXCL and O_NOFOLLOW, with the
    original's mode. One already there is kept, since it is the file as it
    was before SwarmBar first changed it, but only when it is this user's
    own regular file. Returns the backup's name."""
    name = leaf + BACKUP_SUFFIX
    try:
        info = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    except FileNotFoundError:
        info = None
    if info is not None:
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid():
            raise Refused("backup path is not a file")
        return name
    try:
        fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600,
                     dir_fd=parent_fd)
    except FileExistsError:
        raise Refused("backup path is not a file")
    with os.fdopen(fd, "wb") as handle:
        try:
            handle.write(current)
            handle.flush()
            os.fsync(fd)
            os.fchmod(fd, mode)
        except BaseException:
            try:
                os.unlink(name, dir_fd=parent_fd)
            except OSError:
                pass
            raise
    return name


def file_write(job):
    """The write half of write_file, run as the home's owner.

    Root never opens a path in a user's home: as root this runs in a child
    that already is the owner. The parent checked the allowlist; this
    checks the path still resolves where it did, walks to it by descriptor
    (walk_to_parent), and refuses a file that is not this user's own, which
    is what a hardlink to someone else's file looks like. A second link to
    the user's own file is fine: that is how profiles share one config.
    Then the precondition hash, the backup, and the write in place.
    """
    try:
        return write_checked(job)
    except Refused as refused:
        return refusal(str(refused))


def write_checked(job):
    path, target = job["path"], job["target"]
    if os.path.realpath(path) != target:
        return refusal("not allowed")
    data = base64.b64decode(job["content_b64"])
    expect = job["expect_sha256"]
    try:
        parent_fd, leaf = walk_to_parent(job, create=expect == "absent")
    except OSError as error:
        return refusal("cannot open: %s" % (error.strerror or error))
    if parent_fd is None:
        return refusal("changed")
    try:
        try:
            fd = os.open(leaf, os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent_fd)
        except FileNotFoundError:
            return create_file(job, data, parent_fd, leaf)
        except OSError as error:
            if error.errno == errno.ELOOP:
                return refusal("not allowed")
            return refusal("cannot open: %s" % (error.strerror or error))
        with os.fdopen(fd, "r+b") as handle:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid():
                return refusal("not allowed")
            current = handle.read()
            if expect == "absent" or hashlib.sha256(current).hexdigest() != expect:
                return refusal("changed")
            try:
                backup = take_backup(parent_fd, leaf, current, stat.S_IMODE(info.st_mode))
            except OSError as error:
                return refusal("cannot back up: %s" % (error.strerror or error))
            backup = os.path.join(os.path.dirname(target), backup)
            try:
                write_bytes(handle, data)
            except Exception as error:
                # The bytes the hash just matched, which are the backup's when
                # this call took it. An older backup would also undo whatever
                # the user changed since, so it is not the one written back.
                try:
                    write_bytes(handle, current)
                    restored = "restored"
                except Exception:
                    restored = "not restored, the backup is at %s" % backup
                return refusal("write failed: %s; %s"
                               % (getattr(error, "strerror", None) or error, restored))
        return {"ok": True, "written": True, "backup": backup}
    finally:
        os.close(parent_fd)


def create_file(job, data, parent_fd, leaf):
    """A file the plan expected to be absent. O_EXCL makes "absent" hold at
    the moment of creation, and the mode is set outright since a umask
    would otherwise narrow it."""
    if job["expect_sha256"] != "absent":
        return refusal("changed")
    mode = job["mode"]
    try:
        fd = os.open(leaf, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode,
                     dir_fd=parent_fd)
    except FileExistsError:
        return refusal("changed")
    except OSError as error:
        if error.errno == errno.ELOOP:
            return refusal("not allowed")
        return refusal("cannot create: %s" % (error.strerror or error))
    with os.fdopen(fd, "wb") as handle:
        try:
            os.fchmod(fd, mode)
            write_bytes(handle, data)
        except Exception as error:
            try:
                os.unlink(leaf, dir_fd=parent_fd)
            except OSError:
                pass
            return refusal("write failed: %s" % (getattr(error, "strerror", None) or error))
    return {"ok": True, "written": True, "backup": None}


def file_remove(job):
    """The remove half of remove_file, run as the home's owner and reached
    the same way as a write. Already gone counts as done, so undo can run
    twice."""
    path, target = job["path"], job["target"]
    if os.path.realpath(path) != target:
        return refusal("not allowed")
    try:
        parent_fd, leaf = walk_to_parent(job, create=False)
    except Refused as refused:
        return refusal(str(refused))
    except OSError as error:
        return refusal("cannot open: %s" % (error.strerror or error))
    if parent_fd is None:
        return {"ok": True, "removed": False}
    try:
        try:
            info = os.stat(leaf, dir_fd=parent_fd, follow_symlinks=False)
        except FileNotFoundError:
            return {"ok": True, "removed": False}
        if not stat.S_ISREG(info.st_mode):
            return refusal("not allowed")
        try:
            os.unlink(leaf, dir_fd=parent_fd)
        except FileNotFoundError:
            return {"ok": True, "removed": False}
        except OSError as error:
            return refusal("cannot remove: %s" % (error.strerror or error))
        return {"ok": True, "removed": True}
    finally:
        os.close(parent_fd)


FILE_BY_KIND = {"write": file_write, "remove": file_remove}


def read_job(channel):
    chunks, size = [], 0
    while True:
        chunk = channel.recv(65536)
        if not chunk:
            break
        size += len(chunk)
        if size > MAX_JOB_BYTES:
            raise StepError("job too large")
        chunks.append(chunk)
    return json.loads(b"".join(chunks).decode("utf-8"))


def run_child(argv):
    """The child's whole life: one step, its descriptors, its file result
    or its error back to the parent, and nothing on any standard stream."""
    channel = socket.socket(fileno=int(argv[3]))
    try:
        work = FILE_BY_KIND.get(argv[1])
        if work is not None:
            channel.sendall(json.dumps(work(read_job(channel))).encode("utf-8"))
            return
        step = BY_KIND.get(argv[1])
        if step is None:
            raise StepError("unknown step")
        socket.send_fds(channel, [b"ok"], step(argv[2], None))
    except Exception as error:
        text = getattr(error, "strerror", None) or str(error)
        try:
            channel.sendall(("error:" + text).encode("utf-8", "replace"))
        except OSError:
            pass


if __name__ == "__main__" and len(sys.argv) == 4:
    run_child(sys.argv)
'''

_STEPS = {"__name__": "swarmbar_steps"}
exec(compile(STEP_SOURCE, "<swarmbar-steps>", "exec"), _STEPS)
STEP_BY_KIND = _STEPS["BY_KIND"]
StepError = _STEPS["StepError"]
only_owner_can_write = _STEPS["only_owner_can_write"]


HOOK_DIR = ".swarmbar"
HOOK_SOCKET = _STEPS["HOOK_SOCKET"]
BROKER_SOCKET = _STEPS["BROKER_SOCKET"]
HOOK_LOCK = _STEPS["HOOK_LOCK"]

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
# Holds per home at once. Past it a request is answered {} at once.
MAX_HOLDS = 32
# How often a hold checks that its client is still there.
HOLD_POLL_SECONDS = 0.5
# How often a follower whose owner has gone tries the lock.
LOCK_RETRY_SECONDS = 2.0
# How long a server's loop can take to notice it was shut down.
SERVE_POLL_SECONDS = 0.5
# The peer and its ancestors, at most this many names.
PEER_DEPTH = 8
# The whole decision to hold, peer lookup and Grok checks together, runs on
# a thread given this long. Grok counts a hook that takes about 3 seconds as
# consent, so a decision that is late is a refusal, answered {}.
DECIDE_SECONDS = 1.5
PEER_PS_TIMEOUT = 1
# Reading the request itself. A client that connects and says nothing must
# not hold a thread forever.
HOOK_READ_TIMEOUT = 10
# A follower that stops reading is dropped rather than allowed to stall
# the owner's broadcasts.
BROKER_SEND_TIMEOUT = 2
MAX_BROKER_LINE = 8 * 1024 * 1024
# Events for this helper's Mac wait here for the one writer thread. A Mac
# that stops reading costs dropped events, never a stalled request: a held
# request whose event is dropped times out to {}.
EMIT_QUEUE_SIZE = 256
# sun_path is 104 bytes on Darwin and 108 on Linux, NUL included.
MAX_SOCKET_PATH = 103
# None runs each home step in a child exactly when running as root. True runs
# the child path as an ordinary user, for tests; SWARMBAR_HELPER_STEP_CHILD=1
# sets it for a whole helper process.
STEP_CHILD = True if os.environ.get("SWARMBAR_HELPER_STEP_CHILD") == "1" else None
# A step child that has not answered by then is killed.
USER_STEP_SECONDS = 5
GROK_INDEX_MAX_BYTES = 4 * 1024 * 1024

HOOK_PATH = re.compile(r"^/hook/([A-Za-z0-9_]+)$")
GROK_SESSION_KEYS = ("id", "session_id", "sessionId", "sessionID")

# os.umask is process-wide. Binding under a tight umask creates each socket
# 600 from the start, with no chmod by path afterwards. A step child starts
# with that umask and needs no lock.
_UMASK_LOCK = threading.Lock()


def nearest_agent(peer):
    """The first agent walking up from the client: the one that ran the hook."""
    for name in peer:
        if name in AGENT_COMMANDS:
            return name
    return None


def is_holdable(event, peer):
    """Whether a hook may be held for a decision from a Mac, by its peer.

    Only Claude Code answers through its hook response, so only its
    PermissionRequest is held. Grok imports Claude-compatible hooks and
    reaches this same socket with the same script, but Grok 0.2.118 treats
    a hook that times out as consent, so a held Grok prompt is an approved
    one. A chain containing grok is answered at once, and so is one that
    does not prove claude, or whose nearest agent is another one, since the
    agent that ran the hook is the one waiting on it. OpenCode's event comes
    only from SwarmBar's own plugin, which holds on purpose.
    """
    if event == "OpenCodePermission":
        return True
    return (event == "PermissionRequest" and "claude" in peer and "grok" not in peer
            and nearest_agent(peer) == "claude")


def names_session(value, session_id):
    """Whether parsed JSON names a session: as a bare string in a list, as a
    key, or under one of GROK_SESSION_KEYS, at any depth. Broader than the
    file's shape needs, which only ever refuses more."""
    if isinstance(value, list):
        return any(item == session_id or names_session(item, session_id) for item in value)
    if isinstance(value, dict):
        if session_id in value:
            return True
        if any(value.get(key) == session_id for key in GROK_SESSION_KEYS):
            return True
        return any(names_session(item, session_id) for item in value.values())
    return False


def grok_session(home, session_id):
    """Whether a session might be Grok's, mirroring HookServer.originTool:
    named in ~/.grok/active_sessions.json, or a ~/.grok/sessions/*/<id>
    directory. A session id that cannot be checked, or Grok state that
    exists but cannot be read, counts as Grok: the cost is one prompt
    answered in the terminal, where the other mistake approves it."""
    if not isinstance(session_id, str) or not session_id or "/" in session_id \
            or "\0" in session_id or session_id in (".", ".."):
        return True
    grok = os.path.join(home, ".grok")
    try:
        # Not followed, and never blocking on a FIFO: this may run as root
        # on a path the user controls.
        fd = os.open(os.path.join(grok, "active_sessions.json"),
                     os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        fd = None
    except OSError:
        return True
    if fd is not None:
        try:
            info = os.fstat(fd)
            if not stat_module.S_ISREG(info.st_mode) or info.st_size > GROK_INDEX_MAX_BYTES:
                return True
            data = os.read(fd, GROK_INDEX_MAX_BYTES + 1)
        except OSError:
            return True
        finally:
            os.close(fd)
        try:
            if names_session(json.loads(data.decode("utf-8")), session_id):
                return True
        except (ValueError, RecursionError):
            return True
    sessions = os.path.join(grok, "sessions")
    try:
        directories = os.listdir(sessions)
    except FileNotFoundError:
        return False
    except OSError:
        return True
    # lexists, like the Swift fileExists: any entry by that name counts,
    # even a dangling link.
    return any(os.path.lexists(os.path.join(sessions, name, session_id))
               for name in directories)


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


def peer_uid(sock):
    """The uid on the other end of a Unix socket, or None."""
    try:
        if hasattr(socket, "SO_PEERCRED"):
            size = struct.calcsize("3i")
            _, uid, _ = struct.unpack(
                "3i", sock.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, size))
            return uid
        if platform.system() == "Darwin":
            # LOCAL_PEERCRED (0x001 at SOL_LOCAL) is a struct xucred:
            # u_int cr_version, uid_t cr_uid, short cr_ngroups, gid_t[16].
            raw = sock.getsockopt(0, 0x001, 76)
            return struct.unpack_from("=II", raw, 0)[1]
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


def bounded(work, seconds, default):
    """work() on a daemon thread, or `default` when it raises or has not
    finished in `seconds`. A late result is discarded."""
    result = []

    def run():
        try:
            result.append(work())
        except Exception:
            pass
    thread = threading.Thread(target=run, name="swarmbar-bounded")
    thread.daemon = True
    thread.start()
    thread.join(seconds)
    return result[0] if result else default


def hook_homes():
    """Homes with a remote bridge installed, in home_dirs order."""
    return [home for home in home_dirs()
            if any(os.path.isfile(os.path.join(home, marker)) for marker in HOOK_MARKERS)]


class HookHomeError(Exception):
    """A home whose hook socket cannot be served, with the reason."""


def error_text(error):
    return getattr(error, "strerror", None) or str(error)


def supplementary_groups(user, gid):
    """The owner's groups, always passed to the child: left out, it would
    keep root's."""
    try:
        groups = os.getgrouplist(user, gid)
    except (OSError, KeyError, TypeError):
        groups = [gid]
    try:
        limit = os.sysconf("SC_NGROUPS_MAX")
    except (OSError, ValueError):
        limit = 16
    return groups[:max(limit, 1)]


def spawn_step(owner, kind, directory, child):
    """A step child: STEP_SOURCE run with `kind`, as the owner when this is
    root (uid, gid and the owner's groups, always all three), umask 177, no
    environment to speak of and nothing on stdio. `child` is its end of the
    socketpair."""
    ids = {}
    if os.geteuid() == 0:
        user, uid, gid = owner
        ids = {"user": uid, "group": gid, "extra_groups": supplementary_groups(user, gid)}
    return subprocess.Popen(
        [sys.executable, "-I", "-S", "-c", STEP_SOURCE, kind, directory,
         str(child.fileno())],
        umask=0o177, cwd="/", env={"PATH": "/usr/bin:/bin"},
        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL, pass_fds=(child.fileno(),), close_fds=True,
        **ids)


def run_as_user(owner, kind, directory):
    """Runs one step ("prepare", "bind" or "connect") as the home's owner
    and returns the descriptors it produced.

    As root, or when STEP_CHILD is set, the step runs in a child python
    started as the owner, which passes the descriptors back over a
    socketpair. Otherwise the helper already is the owner and runs the same
    step in-process, or the home is not its to serve.
    """
    user, uid, gid = owner
    root = os.geteuid() == 0
    child_path = STEP_CHILD if STEP_CHILD is not None else root
    if not root and os.geteuid() != uid:
        raise HookHomeError("home has another owner")
    if not child_path:
        try:
            return STEP_BY_KIND[kind](directory, _UMASK_LOCK)
        except StepError as error:
            raise HookHomeError(str(error))
    parent, child = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        try:
            proc = spawn_step(owner, kind, directory, child)
        except (OSError, subprocess.SubprocessError, ValueError) as error:
            raise HookHomeError("cannot start a step as the owner: %s" % error_text(error))
        finally:
            child.close()
        try:
            parent.settimeout(USER_STEP_SECONDS)
            data, fds, _, _ = socket.recv_fds(parent, 4096, 8)
        except (socket.timeout, OSError) as error:
            proc.kill()
            proc.wait()
            raise HookHomeError("step did not finish: %s" % error_text(error))
    finally:
        parent.close()
    try:
        proc.wait(USER_STEP_SECONDS)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()
    if data != b"ok":
        for fd in fds:
            os.close(fd)
        raise HookHomeError(data.decode("utf-8", "replace")[len("error:"):] or "step failed")
    return fds


# Setup writes. Config files change only through write_file, which holds
# them to ALLOWED, to the hash the plan was made against and to a one-time
# backup. As root each write runs in a step child that is the home's owner,
# so root never opens a path inside a user's home.
#
# remove_file takes only SwarmBar's own bridge files: the plugin and the
# two scripts. An agent's config is edited back, never deleted.
REMOVABLE = (ALLOWED[5], ALLOWED[6], ALLOWED[7])
SHA256_HEX = re.compile(r"[0-9a-f]{64}")
# Far past any config or bridge script.
WRITE_MAX_BYTES = 4 * 1024 * 1024
# fsync on a slow disk is the long part.
FILE_STEP_SECONDS = 30


def matches_allowed(relative, patterns):
    """Whether a path relative to a home is one the patterns name, compared
    a component at a time. The one wildcard, .claude*, means a directory
    whose name starts with .claude and is not a backup, the same rule
    discovery and the probe use."""
    parts = relative.split("/")
    for pattern in patterns:
        wanted = pattern.split("/")
        if len(wanted) != len(parts):
            continue
        ok = True
        for want, part in zip(wanted, parts):
            if want == ".claude*":
                ok = part.startswith(".claude") and not is_backup_name(part)
            else:
                ok = part == want
            if not ok:
                break
        if ok:
            return True
    return False


def allowed_target(path, patterns=ALLOWED):
    """(home, realpath) when a path may be written, else None.

    The path must be absolute, with no ".." component and no NUL. Its
    realpath must sit inside a home from home_dirs(), and inside the same
    home the path itself names, so a symlink can move a write within a home
    (one profile linked to another) but never out of it. The realpath,
    relative to that home, must match a pattern. home is as home_dirs()
    spells it, matching the probe and the snapshot.
    """
    if not isinstance(path, str) or not path or "\x00" in path or not os.path.isabs(path):
        return None
    if ".." in path.split("/"):
        return None
    resolved = os.path.realpath(path)
    lexical = os.path.normpath(path)
    for home in home_dirs():
        real_home = os.path.realpath(home)
        spellings = set(h.rstrip("/") + "/" for h in (home, real_home))
        if not any(lexical.startswith(prefix) for prefix in spellings):
            continue
        inside = real_home.rstrip("/") + "/"
        if not resolved.startswith(inside):
            continue
        if matches_allowed(resolved[len(inside):], patterns):
            return home, resolved
    return None


def run_file_step(owner, kind, job):
    """Runs a file job ("write" or "remove") as the home's owner and returns
    its result.

    As root, or when STEP_CHILD is set, the job goes to a step child over
    the socketpair as JSON and its result comes back the same way.
    Otherwise the helper already is the owner, or the home is not its to
    write.
    """
    user, uid, gid = owner
    root = os.geteuid() == 0
    if uid is None or (not root and os.geteuid() != uid):
        return {"ok": False, "error": "not allowed"}
    child_path = STEP_CHILD if STEP_CHILD is not None else root
    if not child_path:
        try:
            return _STEPS["FILE_BY_KIND"][kind](job)
        except Exception as error:
            return {"ok": False, "error": error_text(error)}
    parent, child = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        try:
            proc = spawn_step(owner, kind, "-", child)
        except (OSError, subprocess.SubprocessError, ValueError) as error:
            return {"ok": False, "error": "cannot start a write as the owner: %s"
                    % error_text(error)}
        finally:
            child.close()
        chunks = []
        try:
            parent.settimeout(FILE_STEP_SECONDS)
            parent.sendall(json.dumps(job).encode("utf-8"))
            parent.shutdown(socket.SHUT_WR)
            while True:
                chunk = parent.recv(65536)
                if not chunk:
                    break
                chunks.append(chunk)
        except (socket.timeout, OSError) as error:
            proc.kill()
            proc.wait()
            return {"ok": False, "error": "write did not finish: %s" % error_text(error)}
    finally:
        parent.close()
    try:
        proc.wait(FILE_STEP_SECONDS)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()
    reply = b"".join(chunks)
    try:
        result = json.loads(reply.decode("utf-8"))
    except ValueError:
        text = reply.decode("utf-8", "replace")
        return {"ok": False, "error": text[len("error:"):] if text.startswith("error:")
                else "write step failed"}
    if not isinstance(result, dict):
        return {"ok": False, "error": "write step failed"}
    return result


def write_file(request):
    """{path, content_b64, expect_sha256, mode}: replaces an allowed file
    whose sha256 is expect_sha256, or creates one with `mode` when it is
    "absent". Answers {"ok": true, "written": true, "backup": path or null}
    or {"ok": false, "error": "not allowed" | "changed" | why}."""
    path = request.get("path")
    content = request.get("content_b64")
    expect = request.get("expect_sha256")
    mode = request.get("mode", 0o644)
    if not isinstance(content, str) or not isinstance(expect, str) \
            or (expect != "absent" and not SHA256_HEX.fullmatch(expect)) \
            or isinstance(mode, bool) or not isinstance(mode, int) or not 0 <= mode <= 0o777:
        return {"ok": False, "error": "malformed request"}
    try:
        data = base64.b64decode(content, validate=True)
    except (ValueError, TypeError):
        return {"ok": False, "error": "malformed request"}
    if len(data) > WRITE_MAX_BYTES:
        return {"ok": False, "error": "too large"}
    target = allowed_target(path)
    if target is None:
        return {"ok": False, "error": "not allowed"}
    home, resolved = target
    job = {"path": path, "target": resolved, "home": os.path.realpath(home),
           "content_b64": content, "expect_sha256": expect, "mode": mode}
    return run_file_step(home_owner(home), "write", job)


def remove_file(request):
    """{path}: removes one of SwarmBar's bridge files. Answers {"ok": true,
    "removed": true | false} or {"ok": false, "error"}."""
    path = request.get("path")
    target = allowed_target(path, REMOVABLE)
    if target is None:
        return {"ok": False, "error": "not allowed"}
    home, resolved = target
    job = {"path": path, "target": resolved, "home": os.path.realpath(home)}
    return run_file_step(home_owner(home), "remove", job)


# kimi_events. The [[hooks]] schema of a Kimi-family build is a strict
# enum, and one name it does not know drops the whole hooks section (see
# CLAUDE.md, "Things not to do"). The enum is printed verbatim when doctor
# meets a name it does not know, so a throwaway home holding one bogus
# event lists exactly what that build allows.
KIMI_BINARIES = ("kimi", "kimi-code", "bearcode")
KIMI_PROBE_EVENT = "SwarmBarProbeEvent"
KIMI_PROBE_CONFIG = '[[hooks]]\nevent = "%s"\ncommand = "true"\n' % KIMI_PROBE_EVENT
KIMI_DOCTOR_SECONDS = 15
EVENT_NAME = re.compile(r"^[A-Z][A-Za-z0-9]*$")
ANSI_ESCAPE = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")


def accepted_events(text):
    """The event names a doctor error lists after "expected one of", in
    order, or None when it lists none.

    Today's builds print `expected one of "PreToolUse"|"Stop"|...`. Quoted
    names are taken whatever the quotes and separators; with no quotes the
    list is split on |, commas, "or" and "and". A line naming the event
    field is preferred, since other config errors print the same phrase.
    """
    lines = ANSI_ESCAPE.sub("", text or "").splitlines()
    ordered = [l for l in lines if "event" in l] + [l for l in lines if "event" not in l]
    for line in ordered:
        index = line.lower().find("expected one of")
        if index < 0:
            continue
        rest = line[index + len("expected one of"):]
        names = re.findall(r"[\"'`]([A-Za-z][A-Za-z0-9_]*)[\"'`]", rest)
        if not names:
            names = [part.strip(" \t:[]().") for part in
                     re.split(r"\s*(?:[|,]|\bor\b|\band\b)\s*", rest)]
        found = []
        for name in names:
            if EVENT_NAME.match(name) and name != KIMI_PROBE_EVENT and name not in found:
                found.append(name)
        if found:
            return found
    return None


def kimi_executable(binary):
    """The vetted realpath of the build a kimi_events request names, or None.

    A plain name must be one of the family's own and is found on PATH;
    anything else must be an absolute path to an executable file. Either
    way the name it was asked by, or the file it resolves to, must be a
    Kimi-family name, or the BearCode bundle agent_name recognizes, so a
    request cannot run an arbitrary program. The realpath is what runs,
    never a name that could be repointed in between."""
    if not isinstance(binary, str) or not binary or "\x00" in binary:
        return None
    if binary in KIMI_BINARIES:
        # A relative PATH entry would find whatever the current directory
        # holds.
        found = shutil.which(binary)
        if not found or not os.path.isabs(found):
            return None
    elif os.path.isabs(binary) and ".." not in binary.split("/"):
        found = binary
    else:
        return None
    real = os.path.realpath(found)
    if not os.path.isfile(real) or not os.access(real, os.X_OK):
        return None
    if os.path.basename(found) in KIMI_BINARIES or os.path.basename(real) in KIMI_BINARIES \
            or real.endswith("/" + BEARCODE_ARGS):
        return real
    return None


def root_only_path(path):
    """Whether only root can have changed a file: it and every directory
    above it are root's and writable by nobody else."""
    current = path
    while True:
        try:
            info = os.lstat(current)
        except OSError:
            return False
        if info.st_uid != 0 or not only_owner_can_write(info):
            return False
        parent = os.path.dirname(current)
        if parent == current:
            return True
        current = parent


def doctor_identity(home, executable):
    """subprocess options that run doctor as the owner of the home being
    configured, or None when it must not run at all. As root, it runs as
    root only for root's own home and only a build nobody but root can
    have changed: anything else would hand root to whoever could. {} means
    run as this process."""
    user, uid, gid = home_owner(home)
    if uid is None:
        return None
    if os.geteuid() != 0:
        return {} if uid == os.geteuid() else None
    if uid == 0:
        return {} if root_only_path(executable) else None
    return {"user": uid, "group": gid, "extra_groups": supplementary_groups(user, gid)}


def kimi_events(request):
    """{binary, home}: the hook event names that build accepts, asked as
    the owner of the home being configured, as {"events": [...]}, or
    {"events": null, "error": why}."""
    binary = request.get("binary")
    executable = kimi_executable(binary)
    if executable is None:
        if binary in KIMI_BINARIES:
            return {"events": None, "error": "%s is not on PATH" % binary}
        return {"events": None, "error": "not a Kimi-family binary"}
    home = request.get("home")
    homes = dict((os.path.realpath(h), h) for h in home_dirs())
    if not isinstance(home, str) or "\x00" in home or os.path.realpath(home) not in homes:
        return {"events": None, "error": "not a home"}
    home = homes[os.path.realpath(home)]
    ids = doctor_identity(home, executable)
    if ids is None:
        return {"events": None, "error": "will not run %s for %s" % (executable, home)}
    temp = tempfile.mkdtemp(prefix="swarmbar-kimi-")
    try:
        config = os.path.join(temp, "config.toml")
        with open(config, "w") as handle:
            handle.write(KIMI_PROBE_CONFIG)
        if ids:
            # Its owner must read the config. It names a bogus event and
            # nothing else, so there is nothing in it to keep private.
            os.chmod(temp, 0o755)
            os.chmod(config, 0o644)
        real_home = os.path.realpath(home)
        if ids:
            # Never root's PATH for another user: the system's, then the
            # owner's own, where kimi and bun-installed builds live.
            search = ":".join(["/usr/local/bin", "/usr/bin", "/bin",
                               os.path.join(real_home, ".local", "bin"),
                               os.path.join(real_home, ".bun", "bin")])
        else:
            search = os.environ.get("PATH") or "/usr/local/bin:/usr/bin:/bin"
        env = {"PATH": search, "HOME": real_home, "KIMI_CODE_HOME": temp}
        if os.environ.get("LANG"):
            env["LANG"] = os.environ["LANG"]
        try:
            done = run_command([executable, "doctor"], timeout=KIMI_DOCTOR_SECONDS,
                               env=env, cwd=temp, start_new_session=True, **ids)
        except subprocess.TimeoutExpired:
            return {"events": None, "error": "doctor timed out"}
        except (OSError, subprocess.SubprocessError, ValueError) as error:
            return {"events": None, "error": "cannot run doctor: %s" % error_text(error)}
    finally:
        shutil.rmtree(temp, ignore_errors=True)
    text = (done.stdout or b"").decode("utf-8", "replace") + "\n" \
        + (done.stderr or b"").decode("utf-8", "replace")
    events = accepted_events(text)
    if events is None:
        return {"events": None, "error": "doctor did not list the events it accepts"}
    return {"events": events}


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
    """A JSON object, or None for anything else, deeply nested input included."""
    try:
        message = json.loads(line.decode("utf-8"))
    except (ValueError, RecursionError):
        return None
    return message if isinstance(message, dict) else None


def encode_lines(messages):
    return b"".join((json.dumps(message) + "\n").encode("utf-8") for message in messages)


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
        # The 700 directory already keeps everyone else out; this holds even
        # if it were opened. None means the platform would not say, which
        # leaves the directory as the only bound.
        uid = peer_uid(conn)
        if uid is not None and uid not in (hub.uid, 0):
            return
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
    """One request waiting for a Mac's decision, and the event announcing
    it, kept to replay to followers that connect while it waits."""

    def __init__(self, conn, message):
        self.conn = conn
        self.message = message
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
        # Follower side: rids the owner holds, and rids whose replayed hook
        # event this Mac already has.
        self.relayed = set()
        self.replayed = set()
        self.error = None

    def owner(self):
        return self.user, self.uid, self.gid

    # Setup

    def start(self):
        for name in (HOOK_SOCKET, BROKER_SOCKET):
            if len(os.path.join(self.directory, name).encode("utf-8")) > MAX_SOCKET_PATH:
                raise HookHomeError("socket path too long")
        if self.uid is None:
            raise HookHomeError("cannot examine home")
        try:
            self.dir_fd, self.lock_fd = run_as_user(self.owner(), "prepare", self.directory)
        except (OSError, HookHomeError) as error:
            raise HookHomeError(error_text(error))
        with self.transition:
            if self.try_lock():
                try:
                    self.become_owner()
                except (OSError, HookHomeError) as error:
                    self.release()
                    raise HookHomeError(error_text(error))
                return
        self.role = "follower"
        thread = threading.Thread(target=self.follow, name="swarmbar-follower")
        thread.daemon = True
        thread.start()

    def try_lock(self):
        try:
            fcntl.flock(self.lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return True
        except (OSError, TypeError):
            return False

    def become_owner(self):
        """Binds and serves both sockets. Only the lock holder ever gets
        here, so the stale ones its step removes are never a live owner's.
        The caller holds `transition`."""
        if self.closing:
            return
        fds = run_as_user(self.owner(), "bind", self.directory)
        servers = []
        for fd, name, handler in zip(fds, (HOOK_SOCKET, BROKER_SOCKET),
                                     (HookHandler, BrokerHandler)):
            server = _QuietServer(os.path.join(self.directory, name), handler,
                                  bind_and_activate=False)
            server.socket.close()
            server.socket = socket.socket(fileno=fd)
            server.hub = self
            servers.append(server)
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
        """Relays the owner's events until the connection drops, then tries
        the lock at once, so a clean owner exit hands over immediately.
        Otherwise it waits LOCK_RETRY_SECONDS between rounds."""
        while not self.closing:
            if self.take_over():
                return
            conn = self.connect_broker()
            if conn is not None:
                self.read_broker(conn)
                if self.take_over():
                    return
            if self.stopped.wait(LOCK_RETRY_SECONDS):
                return

    def take_over(self):
        """True when this follower is done following: it took the lock, or
        it is closing."""
        with self.transition:
            if self.closing:
                return True
            if not self.try_lock():
                return False
            # The owner is really gone, and whatever it held died with it:
            # the agent has fallen back to its own prompt.
            lost, self.relayed, self.replayed = self.relayed, set(), set()
            for rid in sorted(lost):
                self.relay.emit({"event": "hook_resolved", "rid": rid})
            try:
                self.become_owner()
                return True
            except (OSError, HookHomeError) as error:
                self.error = error_text(error)
                fcntl.flock(self.lock_fd, fcntl.LOCK_UN)
                return False

    def connect_broker(self):
        try:
            (fd,) = run_as_user(self.owner(), "connect", self.directory)
        except (OSError, HookHomeError, ValueError):
            return None
        conn = socket.socket(fileno=fd)
        conn.settimeout(BROKER_SEND_TIMEOUT)
        with self.lock:
            if self.closing:
                conn.close()
                return None
            self.broker = conn
        return conn

    def read_broker(self, conn):
        """Relays until the connection drops. Dropping clears nothing: the
        owner may simply have let this follower go, and its holds are still
        open. Only a resolution, the owner's "pending" list on reconnect, or
        taking the lock from a dead owner clears a row."""
        try:
            for line in read_lines(conn, lambda: self.closing):
                message = parse_line(line)
                if message is not None:
                    self.relay_message(message)
        finally:
            with self.lock:
                self.broker = None
            conn.close()

    def relay_message(self, message):
        kind, rid = message.get("type"), message.get("rid")
        if kind == "pending":
            rids = message.get("rids")
            still = set(r for r in rids if isinstance(r, str)) if isinstance(rids, list) else set()
            for gone in sorted(self.relayed - still):
                self.relay.emit({"event": "hook_resolved", "rid": gone})
            self.relayed &= still
            self.replayed &= still
            return
        if kind == "held":
            if isinstance(rid, str):
                if rid in self.relayed:
                    self.replayed.add(rid)
                self.relayed.add(rid)
            return
        event = message.get("event")
        if event == "hook" and rid in self.replayed:
            # A replay of a hold this Mac already shows.
            self.replayed.discard(rid)
            return
        if event == "hook_resolved":
            self.relayed.discard(rid)
            self.replayed.discard(rid)
        if event in ("hook", "hook_resolved"):
            self.relay.emit(message)

    def forward_reply(self, rid, body):
        conn = self.broker
        if conn is None:
            return
        with self.broker_send:
            try:
                conn.sendall(encode_lines([{"type": "reply", "rid": rid, "body": body}]))
            except OSError:
                drop_connection(conn)

    # Owner

    def add_follower(self, conn):
        """Registers a follower and replays the open holds to it. The send
        lock is taken before the follower is visible to broadcasts, so
        nothing about a hold can reach it ahead of the replay."""
        send_lock = threading.Lock()
        with self.lock:
            if self.closing:
                return False
            self.followers[conn] = send_lock
            open_holds = [(rid, held.message) for rid, held in self.pending.items()
                          if not held.done.is_set()]
            send_lock.acquire()
        try:
            messages = [{"type": "pending", "rids": [rid for rid, _ in open_holds]}]
            for rid, message in open_holds:
                messages += [{"type": "held", "rid": rid}, message]
            conn.sendall(encode_lines(messages))
        except OSError:
            drop_connection(conn)
        finally:
            send_lock.release()
        return True

    def remove_follower(self, conn):
        with self.lock:
            self.followers.pop(conn, None)

    def follower_count(self):
        with self.lock:
            return len(self.followers)

    def broadcast(self, messages):
        """Sends messages to every follower in one write each, and returns
        how many took them. One that cannot take them in BROKER_SEND_TIMEOUT
        is dropped, and reconnects."""
        data = encode_lines(messages)
        with self.lock:
            followers = list(self.followers.items())
        delivered = 0
        for conn, send_lock in followers:
            failed = False
            with send_lock:
                try:
                    conn.sendall(data)
                except OSError:
                    failed = True
            if failed:
                drop_connection(conn)
                self.remove_follower(conn)
            else:
                delivered += 1
        return delivered

    def publish(self, message, held=False):
        """To every follower first, then queued for this helper's Mac, so a
        Mac that is not reading delays nobody. Returns whether any Mac will
        see it."""
        delivered = self.broadcast(
            ([{"type": "held", "rid": message["rid"]}] if held else []) + [message])
        return self.relay.emit(message) or delivered > 0

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

    def permission_check(self, sock, body):
        """(peer, holdable) for a PermissionRequest. The Grok session check
        runs only for a chain that already proves claude."""
        peer = peer_chain(sock)
        if not isinstance(peer, list):
            peer = []
        if not is_holdable("PermissionRequest", peer):
            return peer, False
        return peer, not grok_session(self.home, body.get("session_id"))

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
        # Only a PermissionRequest needs the peer, and it is bounded: a late
        # decision is a refusal. Every other event is answered without one.
        peer, holdable = [], event == "OpenCodePermission"
        if event == "PermissionRequest":
            peer, holdable = bounded(
                lambda: self.permission_check(handler.connection, payload),
                DECIDE_SECONDS, ([], False))
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
            "held": holdable,
        }
        if holdable:
            self.hold(handler, message)
            return
        # Answered before anything else happens, Grok above all: the Macs
        # are only told afterwards, for status.
        handler.answer({})
        self.publish(message)

    def hold(self, handler, message):
        rid = message["rid"]
        held = Held(handler.connection, message)
        deadline = time.monotonic() + HOLD_SECONDS
        with self.lock:
            if self.closing:
                drop_connection(held.conn)
                return
            full = len(self.pending) >= MAX_HOLDS
            if not full:
                self.pending[rid] = held
        if full:
            message["held"] = False
            handler.answer({})
            self.publish(message)
            return
        if not self.publish(message, held=True):
            # No Mac will ever see this request, so none can answer it, and
            # waiting out the hold would only stall the agent.
            self.resolve(rid, {})
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
        if dropped:
            self.broadcast([{"event": "hook_resolved", "rid": rid} for rid, _ in dropped])
        with self.transition:
            with self.lock:
                servers, self.servers = self.servers, []
                followers = list(self.followers)
            if servers and self.dir_fd is not None:
                # unlinkat through the directory this helper opened. Removing
                # a name never touches the file behind it.
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
    to this helper's Mac; it is write_line except in tests. Events reach it
    through a bounded queue and one writer thread, so a Mac that stops
    reading never stalls a request or another Mac."""

    def __init__(self, emit=None):
        self.emit_line = emit if emit is not None else write_line
        self.hubs = {}
        self.lock = threading.Lock()
        self.closed = False
        self.dropped = 0
        self.queue = queue.Queue(EMIT_QUEUE_SIZE)
        writer = threading.Thread(target=self.drain, name="swarmbar-emit")
        writer.daemon = True
        writer.start()

    def emit(self, message):
        """Queues an event for this helper's Mac. False when it was dropped."""
        try:
            self.queue.put_nowait(message)
            return True
        except queue.Full:
            with self.lock:
                self.dropped += 1
            return False

    def drain(self):
        while True:
            try:
                message = self.queue.get(timeout=0.2)
            except queue.Empty:
                if self.closed:
                    return
                continue
            try:
                self.emit_line(message)
            except Exception:
                # The Mac is gone or going. Its helper exits on stdin EOF.
                pass

    def refresh(self):
        """Starts a hub for every newly qualifying home and keeps the rest.
        Returns warnings: homes that cannot be served, which are retried on
        the next refresh, and events dropped since the last one."""
        warnings = []
        with self.lock:
            dropped, self.dropped = self.dropped, 0
        if dropped:
            warnings.append("dropped %d hook events: the Mac was not reading" % dropped)
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


# The pasted command: `python3 swarmbar-helper.py apply <blob>`, the blob
# being base64 of zlib-compressed JSON, a list of operations. It is how a
# host is set up when the Mac cannot do it over ssh itself (no passwordless
# sudo), so a person runs it, with sudo when every user is watched. It is
# also the only way the narrow sudo rule is ever installed.
SUDOERS_PATH = "/etc/sudoers.d/swarmbar"
SUDOERS_USER = re.compile(r"[a-z_][a-z0-9_-]*[$]?")
SUDOERS_USER_MAX = 32
VISUDO_PATHS = ("/usr/sbin/visudo",)
# A blob is a few configs and maybe the helper's own source. Bounded, so a
# small blob cannot expand into gigabytes.
MAX_OPERATIONS_BYTES = 8 * 1024 * 1024


def narrow_rule_run():
    """Whether this is the installed root helper run by a login user through
    the narrow sudo rule. That rule lets the user run the helper with any
    arguments, so the operations that set the rule up, and the pasted
    command that carries them, must not work through it: the user could
    otherwise widen the rule or replace the program it names."""
    path = globals().get("__file__")
    if not path or os.geteuid() != 0:
        return False
    if os.path.realpath(path) != os.path.realpath(HELPER_PATHS[0]):
        return False
    return os.environ.get("SUDO_UID", "0") not in ("", "0")


NARROW_RULE_REFUSAL = {"ok": False, "error": "refused under the SwarmBar sudo rule; "
                       "run the setup command with sudo instead"}


def fsync_directory(directory):
    """Makes a rename in `directory` durable. Best effort: the file is in
    place either way, and a filesystem that cannot sync a directory is not
    a reason to report the install as failed."""
    try:
        fd = os.open(directory, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    except OSError:
        return
    try:
        os.fsync(fd)
    except OSError:
        pass
    finally:
        os.close(fd)


def visudo_path():
    for path in VISUDO_PATHS:
        if os.path.isfile(path) and os.access(path, os.X_OK):
            return path
    return shutil.which("visudo")


def helper_destination():
    """Where install_helper puts the helper: root's copy, the one the sudo
    rule names, or the login user's own."""
    if os.geteuid() == 0:
        return HELPER_PATHS[0]
    return os.path.join(os.path.expanduser("~"), USER_HELPER)


def own_bytes():
    path = globals().get("__file__")
    if not path or not os.path.isfile(path):
        return None
    with open(path, "rb") as handle:
        return handle.read()


def install_helper(request, source=None):
    """{dest, expect_sha256}: this file, installed atomically (a temp file
    beside it, then a rename) at helper_destination(), mode 700. It is
    SwarmBar's own file, so replacing the inode is right, unlike an agent's
    config. The bytes are read once, hashed and written as read, so
    expect_sha256, when given, checks exactly what is installed.

    As root the directory must be root's and writable by nobody else: the
    sudo rule runs whatever sits at that path as root, so a directory
    another user can write would let them choose it. The user's own copy
    goes in ~/.swarmbar, which must be theirs and not a link.
    """
    if narrow_rule_run():
        return NARROW_RULE_REFUSAL
    dest = request.get("dest")
    if not isinstance(dest, str) or dest != helper_destination():
        return {"ok": False, "error": "not allowed"}
    expect = request.get("expect_sha256")
    if expect is not None and (not isinstance(expect, str) or not SHA256_HEX.fullmatch(expect)):
        return {"ok": False, "error": "malformed request"}
    if source is None:
        try:
            source = own_bytes()
        except OSError:
            source = None
    if source is None:
        return {"ok": False, "error": "cannot read the helper itself"}
    digest = hashlib.sha256(source).hexdigest()
    if expect is not None and digest != expect:
        return {"ok": False, "error": "changed"}
    directory = os.path.dirname(dest)
    try:
        if os.geteuid() == 0:
            os.makedirs(directory, 0o755, exist_ok=True)
            info = os.stat(directory)
            if info.st_uid != 0 or not only_owner_can_write(info):
                return {"ok": False, "error": "%s is writable by another user" % directory}
        else:
            try:
                os.mkdir(directory, 0o700)
            except FileExistsError:
                pass
            info = os.lstat(directory)
            if not stat_module.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid():
                return {"ok": False, "error": "%s is not this user's own directory" % directory}
            if stat_module.S_IMODE(info.st_mode) != 0o700:
                os.chmod(directory, 0o700)
        fd, temp = tempfile.mkstemp(prefix=".swarmbar-helper.", dir=directory)
    except OSError as error:
        return {"ok": False, "error": "cannot install: %s" % error_text(error)}
    try:
        with os.fdopen(fd, "wb") as handle:
            os.fchmod(fd, 0o700)
            handle.write(source)
            handle.flush()
            os.fsync(fd)
        os.replace(temp, dest)
        fsync_directory(directory)
    except OSError as error:
        return {"ok": False, "error": "cannot install: %s" % error_text(error)}
    finally:
        if os.path.lexists(temp):
            os.unlink(temp)
    return {"ok": True, "installed": dest, "sha256": digest}


def install_sudoers(request):
    """{user}: /etc/sudoers.d/swarmbar, letting one user run the root helper
    and nothing else without a password. Root only. The rule is written
    to a temp file, checked by visudo, and only then renamed into place,
    mode 440. The temp name has a dot in it, which sudo's includedir skips,
    so an unchecked rule is never live. Once in place the whole
    configuration is checked again, and a failure takes the rule back out:
    a sudoers that does not parse locks everyone out of sudo."""
    if os.geteuid() != 0:
        return {"ok": False, "error": "needs root"}
    if narrow_rule_run():
        return NARROW_RULE_REFUSAL
    user = request.get("user")
    if not isinstance(user, str) or len(user) > SUDOERS_USER_MAX \
            or not SUDOERS_USER.fullmatch(user):
        return {"ok": False, "error": "bad user name"}
    try:
        import pwd
        pwd.getpwnam(user)
    except (ImportError, KeyError):
        return {"ok": False, "error": "no such user: %s" % user}
    visudo = visudo_path()
    if visudo is None:
        return {"ok": False, "error": "visudo not found"}
    rule = "%s ALL=(root) NOPASSWD: %s\n" % (user, HELPER_PATHS[0])
    temp = None
    try:
        fd, temp = tempfile.mkstemp(prefix=".swarmbar.", dir=os.path.dirname(SUDOERS_PATH))
        with os.fdopen(fd, "w") as handle:
            os.fchmod(fd, 0o440)
            handle.write(rule)
            handle.flush()
            os.fsync(fd)
        try:
            checked = run_command([visudo, "-cf", temp], timeout=10)
        except (OSError, subprocess.SubprocessError) as error:
            return {"ok": False, "error": "cannot run visudo: %s" % error_text(error)}
        if checked.returncode != 0:
            said = (checked.stderr or checked.stdout or b"").decode("utf-8", "replace").strip()
            return {"ok": False, "error": "visudo rejected the rule: %s" % said}
        os.replace(temp, SUDOERS_PATH)
        fsync_directory(os.path.dirname(SUDOERS_PATH))
    except OSError as error:
        return {"ok": False, "error": "cannot install the rule: %s" % error_text(error)}
    finally:
        if temp is not None and os.path.lexists(temp):
            os.unlink(temp)
    try:
        whole = run_command([visudo, "-c"], timeout=10)
        failed = whole.returncode != 0
        said = (whole.stderr or whole.stdout or b"").decode("utf-8", "replace").strip()
    except (OSError, subprocess.SubprocessError) as error:
        failed, said = True, error_text(error)
    if failed:
        try:
            os.unlink(SUDOERS_PATH)
            fsync_directory(os.path.dirname(SUDOERS_PATH))
            undone = "the rule was removed"
        except OSError as error:
            undone = "and removing it failed: %s" % error_text(error)
        return {"ok": False, "error": "sudo configuration did not check with the rule in "
                "place (%s); %s" % (said, undone)}
    return {"ok": True, "installed": SUDOERS_PATH}


def apply_operation(operation, source):
    kind = operation.get("op")
    if kind == "write_file":
        return write_file(operation)
    if kind == "remove_file":
        return remove_file(operation)
    if kind == "install_helper":
        return install_helper(operation, source)
    if kind == "sudoers":
        return install_sudoers(operation)
    return {"ok": False, "error": "unknown operation"}


def describe_operation(operation, result):
    """One line for a person reading the terminal: what ran, on what, and
    how it went."""
    kind = operation.get("op")
    subject = operation.get("path") or operation.get("dest") or operation.get("user") or ""
    label = ("%s %s" % (kind, subject)).strip()
    if result.get("ok"):
        if result.get("backup"):
            return "ok: %s (backup at %s)" % (label, result["backup"])
        if result.get("removed") is False:
            return "ok: %s (already gone)" % label
        return "ok: %s" % label
    return "failed: %s: %s" % (label, result.get("error", "unknown error"))


def decode_operations(blob):
    """The operations in a blob, or None. zlib as python writes it, or the
    raw deflate that Foundation's .zlib produces."""
    try:
        packed = base64.b64decode("".join(blob.split()), validate=True)
    except (ValueError, TypeError):
        return None
    data = None
    for wbits in (zlib.MAX_WBITS, -zlib.MAX_WBITS):
        unpacker = zlib.decompressobj(wbits)
        try:
            data = unpacker.decompress(packed, MAX_OPERATIONS_BYTES)
        except zlib.error:
            continue
        # Output left unread means past the bound, and a stream with no end
        # was cut short. Neither is a blob to act on.
        if unpacker.unconsumed_tail or not unpacker.eof:
            return None
        break
    if data is None:
        return None
    try:
        operations = json.loads(data.decode("utf-8"))
    except ValueError:
        return None
    if not isinstance(operations, list) or not all(isinstance(o, dict) for o in operations):
        return None
    return operations


def apply_main(args):
    """Runs every operation in order, printing a line for each, and stops at
    the first failure. Returns the exit status."""
    if narrow_rule_run():
        sys.stdout.write("failed: %s\n" % NARROW_RULE_REFUSAL["error"])
        sys.stdout.flush()
        return 2
    operations = decode_operations(args[0]) if len(args) == 1 else None
    if not operations:
        sys.stdout.write("failed: cannot read the setup operations\n")
        sys.stdout.flush()
        return 2
    try:
        # Read once, now, so every install in the list is the same bytes.
        source = own_bytes()
    except OSError:
        source = None
    for index, operation in enumerate(operations):
        try:
            result = apply_operation(operation, source)
        except Exception as error:
            result = {"ok": False, "error": "internal error: %s" % error}
        sys.stdout.write(describe_operation(operation, result) + "\n")
        if not result.get("ok"):
            left = len(operations) - index - 1
            if left:
                # Otherwise a person reading the output cannot tell that
                # the rest was skipped rather than never planned.
                sys.stdout.write("stopped: %d more %s not run\n"
                                 % (left, "change" if left == 1 else "changes"))
            sys.stdout.flush()
            return 1
        sys.stdout.flush()
    return 0


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
            elif command == "write_file":
                response = write_file(request)
            elif command == "remove_file":
                response = remove_file(request)
            elif command == "kimi_events":
                response = kimi_events(request)
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
    # The probe runs before anything is installed and must leave no trace,
    # so it never reaches main(), which sets up hook homes and a writer
    # thread. Its program came from stdin, so stdin is not a request stream.
    if len(sys.argv) > 1 and sys.argv[1] == "probe":
        probe_main()
    elif len(sys.argv) > 1 and sys.argv[1] == "apply":
        # The pasted setup command. Like the probe it is one shot: no hook
        # homes, no writer thread, and stdin is not a request stream.
        sys.exit(apply_main(sys.argv[2:]))
    else:
        main()
