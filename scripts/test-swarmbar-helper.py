#!/usr/bin/env python3
"""Tests for swarmbar-helper.py's pure parts.

Run directly: python3 scripts/test-swarmbar-helper.py

Not part of the Xcode test bundle: project.yml lists the scripts it ships
one by one, so nothing here reaches the app. Kept in python because
tail_of is python, and the case it exists to cover (a trailing record
bigger than the read window) is only reproducible against a real file.

python 3.9 compatible, like the helper itself.
"""

import atexit
import base64
import hashlib
import importlib.util
import io
import json
import os
import random
import re
import select
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import zlib
from unittest import mock

_spec = importlib.util.spec_from_file_location(
    "swarmbar_helper",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "swarmbar-helper.py"),
)
helper = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(helper)

# main() looks for hook homes as it starts. Every test that does not choose
# its own homes gets an empty one, so none of them ever looks at a real home.
_EMPTY_HOME = tempfile.mkdtemp(prefix="swarmbar-empty-home-")
os.environ.setdefault("SWARMBAR_HELPER_HOMES", _EMPTY_HOME)
atexit.register(shutil.rmtree, _EMPTY_HOME, True)


def record(text):
    """One JSONL record of roughly `text` shape, newline terminated."""
    return text + "\n"


def big_record(marker, size):
    """A single record of at least `size` bytes, uniquely identifiable."""
    padding = "x" * max(size - len(marker) - 16, 0)
    return '{"m":"%s","pad":"%s"}\n' % (marker, padding)


class TailOfTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="swarmbar-helper-test-")

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def write(self, name, text):
        path = os.path.join(self.dir, name)
        with open(path, "wb") as handle:
            handle.write(text.encode("utf-8"))
        return path, os.stat(path).st_size

    def tail(self, name, text):
        path, size = self.write(name, text)
        return helper.tail_of(path, size)

    def test_small_file_returns_whole(self):
        text = record('{"a":1}') + record('{"b":2}')
        self.assertEqual(self.tail("small.jsonl", text), text)

    def test_trailing_partial_line_is_trimmed(self):
        text = record('{"a":1}') + '{"b":2'
        self.assertEqual(self.tail("partial.jsonl", text), record('{"a":1}'))

    def test_file_with_no_complete_record_is_incomplete(self):
        self.assertIs(self.tail("fresh.jsonl", '{"a":1'), helper.INCOMPLETE)

    def test_empty_file_is_incomplete(self):
        self.assertIs(self.tail("empty.jsonl", ""), helper.INCOMPLETE)

    def test_trailing_record_larger_than_the_window_is_returned_whole(self):
        # The regression this whole guard exists for. The last record is
        # bigger than TAIL_BYTES, so a fixed 64 KB window finds no newline
        # and used to return "", which deletes the row on the Mac.
        text = record('{"first":1}') + big_record("huge", helper.TAIL_BYTES + 4096)
        result = self.tail("oversized.jsonl", text)
        self.assertNotEqual(result, "")
        self.assertIsInstance(result, str)
        self.assertIn('"m":"huge"', result)
        self.assertTrue(result.endswith("\n"))
        # A whole record, not a fragment of one. Doubling to 128 KB covers
        # this whole file, so the earlier record comes back too, which is
        # the same "reading from offset 0 always counts as complete" rule
        # the local monitor follows.
        lines = result.strip().splitlines()
        self.assertEqual(json.loads(lines[-1])["m"], "huge")
        self.assertEqual(json.loads(lines[0])["first"], 1)

    def test_oversized_trailing_record_still_yields_complete_json(self):
        text = record('{"first":1}') + big_record("huge", helper.TAIL_BYTES * 3)
        result = self.tail("oversized3.jsonl", text)
        self.assertIsInstance(result, str)
        parsed = [json.loads(line) for line in result.strip().splitlines()]
        self.assertEqual(parsed[-1]["m"], "huge")

    def test_complete_records_after_an_oversized_one_are_returned(self):
        text = (record('{"first":1}')
                + big_record("huge", helper.TAIL_BYTES + 4096)
                + record('{"last":1}'))
        result = self.tail("after.jsonl", text)
        self.assertIsInstance(result, str)
        self.assertIn('"last":1', result)

    def test_record_beyond_the_ceiling_is_omitted_not_emptied(self):
        # MAX_TAIL_BYTES is 4 MB, too slow to build honestly in a test, so
        # the ceiling is lowered for this one case. The branch under test is
        # the same one.
        original = helper.MAX_TAIL_BYTES
        helper.MAX_TAIL_BYTES = helper.TAIL_BYTES * 2
        try:
            text = record('{"first":1}') + big_record(
                "huge", helper.TAIL_BYTES * 4)
            result = self.tail("ceiling.jsonl", text)
            self.assertIs(result, helper.OVERSIZED)
            self.assertNotEqual(result, "")
        finally:
            helper.MAX_TAIL_BYTES = original

    def test_unreadable_file_returns_none(self):
        self.assertIsNone(helper.tail_of(os.path.join(self.dir, "nope.jsonl"), 10))

    def test_window_stops_at_the_first_complete_record_boundary(self):
        # A normal large file: many small records, well past TAIL_BYTES.
        # The first window already holds complete records, so the tail is
        # bounded rather than the whole file.
        text = "".join(record('{"i":%d}' % i) for i in range(20000))
        result = self.tail("many.jsonl", text)
        self.assertIsInstance(result, str)
        self.assertLess(len(result), helper.TAIL_BYTES)
        self.assertTrue(result.endswith(record('{"i":19999}')))


def decode_chunks(entry):
    """[(offset, bytes)] for one manifest entry."""
    return [(offset, base64.b64decode(data)) for offset, data in entry["chunks"]]


class ManifestTests(unittest.TestCase):
    """The protocol 3 snapshot, against a temporary home.

    Every file here is synthetic and lives under a temp dir that
    SWARMBAR_HELPER_HOMES points at, so no real agent state is read.
    """

    def setUp(self):
        self.home = os.path.realpath(tempfile.mkdtemp(prefix="swarmbar-manifest-"))
        self.env = mock.patch.dict(os.environ, {"SWARMBAR_HELPER_HOMES": self.home})
        self.env.start()
        # ps and lsof are not what these tests are about, and on a machine
        # with live agents they make every snapshot slow.
        self.ps = mock.patch.object(helper, "agent_processes", return_value=[])
        self.ps.start()
        helper.SHIPPED.clear()

    def tearDown(self):
        self.ps.stop()
        self.env.stop()
        helper.SHIPPED.clear()
        shutil.rmtree(self.home, ignore_errors=True)

    def put(self, relative, data, mode="wb"):
        path = os.path.join(self.home, relative)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        if isinstance(data, str):
            data = data.encode("utf-8")
        with open(path, mode) as handle:
            handle.write(data)
        return path

    def read(self, path):
        with open(path, "rb") as handle:
            return handle.read()

    def entry(self, snap, path):
        for item in snap["files"]:
            if item["path"] == path:
                return item
        return None

    def many_records(self, count, partial=""):
        return "".join(record('{"i":%d,"pad":"%s"}' % (i, "y" * 40))
                       for i in range(count)) + partial

    EVENTS = ".grok/sessions/s1/abc/events.jsonl"

    def test_first_snapshot_ships_tail_chunk_at_true_offset(self):
        # Well past TAIL_BYTES, and mid-write: the last line is partial.
        path = self.put(self.EVENTS, self.many_records(4000, partial='{"i":"half'))
        content = self.read(path)
        snap = helper.snapshot()
        self.assertEqual(snap["protocol"], 3)
        self.assertEqual(snap["stream"], helper.STREAM_ID)
        item = self.entry(snap, path)
        self.assertIsNotNone(item)
        self.assertTrue(item["reset"])
        self.assertEqual(item["size"], len(content))
        chunks = decode_chunks(item)
        self.assertEqual(len(chunks), 1)
        offset, data = chunks[0]
        self.assertGreater(offset, 0)
        # The bytes are the file's own bytes at that offset, through the
        # size the manifest reports, so the next growth chunk lines up.
        self.assertEqual(data, content[offset:])
        self.assertEqual(offset + len(data), item["size"])
        self.assertLessEqual(len(data), helper.TAIL_BYTES)

    def test_second_snapshot_ships_nothing_for_unchanged_file(self):
        path = self.put(self.EVENTS, self.many_records(10))
        helper.snapshot()
        item = self.entry(helper.snapshot(), path)
        # Still listed: the manifest names every in-scope file every time.
        self.assertIsNotNone(item)
        self.assertEqual(item["chunks"], [])
        self.assertFalse(item["reset"])

    def test_append_ships_only_growth(self):
        path = self.put(self.EVENTS, self.many_records(10))
        old_size = os.stat(path).st_size
        helper.snapshot()
        appended = record('{"added":true}') + '{"half'
        self.put(self.EVENTS, appended, mode="ab")
        item = self.entry(helper.snapshot(), path)
        self.assertFalse(item["reset"])
        self.assertEqual(decode_chunks(item), [(old_size, appended.encode("utf-8"))])

    def test_shrink_resets(self):
        path = self.put(self.EVENTS, self.many_records(50))
        helper.snapshot()
        replacement = record('{"fresh":1}')
        self.put(self.EVENTS, replacement)
        item = self.entry(helper.snapshot(), path)
        self.assertTrue(item["reset"])
        self.assertEqual(decode_chunks(item), [(0, replacement.encode("utf-8"))])

    def test_growth_past_the_ceiling_resets_with_a_fresh_tail(self):
        path = self.put(self.EVENTS, self.many_records(10))
        helper.snapshot()
        original = helper.MAX_TAIL_BYTES
        helper.MAX_TAIL_BYTES = helper.TAIL_BYTES * 2
        try:
            self.put(self.EVENTS, self.many_records(4000), mode="ab")
            item = self.entry(helper.snapshot(), path)
        finally:
            helper.MAX_TAIL_BYTES = original
        content = self.read(path)
        self.assertTrue(item["reset"])
        ((offset, data),) = decode_chunks(item)
        self.assertEqual(data, content[offset:])
        self.assertLessEqual(len(data), helper.TAIL_BYTES)

    def test_head_tail_ships_first_line_at_zero(self):
        first = record('{"type":"session_meta","cwd":"/home/u/demo"}')
        path = self.put(".claude/projects/-home-u-demo/a.jsonl",
                        first + self.many_records(4000))
        content = self.read(path)
        item = self.entry(helper.snapshot(), path)
        chunks = decode_chunks(item)
        self.assertEqual(len(chunks), 2)
        self.assertEqual(chunks[0], (0, first.encode("utf-8")))
        offset, data = chunks[1]
        self.assertEqual(data, content[offset:])

    def test_codex_head_grows_past_a_large_first_line(self):
        first = record('{"type":"session_meta","base":"%s"}' % ("z" * 40000))
        path = self.put(".codex/sessions/2026/10/22/rollout-demo.jsonl",
                        first + self.many_records(10))
        item = self.entry(helper.snapshot(), path)
        self.assertEqual(decode_chunks(item)[0], (0, first.encode("utf-8")))

    LAST_PROMPT = record('{"type":"last-prompt","lastPrompt":"Synthetic prompt."}')
    STAMPED = record('{"type":"user","timestamp":"2026-10-01T10:00:00.000Z","cwd":"/home/u/demo"}')

    def test_claude_head_runs_to_the_first_timestamped_line(self):
        path = self.put(".claude/projects/-home-u-demo/b.jsonl",
                        self.LAST_PROMPT + self.STAMPED + self.many_records(4000))
        chunks = decode_chunks(self.entry(helper.snapshot(), path))
        self.assertEqual(chunks[0], (0, (self.LAST_PROMPT + self.STAMPED).encode("utf-8")))

    def test_claude_head_without_a_timestamp_in_the_cap_is_the_first_line(self):
        content = self.LAST_PROMPT + self.many_records(200) + self.STAMPED
        path = self.put(".claude/projects/-home-u-demo/c.jsonl", content)
        size = os.stat(path).st_size
        self.assertEqual(helper.stamped_head_chunk(path, size, limit=4096),
                         (0, self.LAST_PROMPT.encode("utf-8")))
        # Within a cap that reaches it, the same file runs to the stamp.
        self.assertEqual(helper.stamped_head_chunk(path, size)[1], content.encode("utf-8"))

    def test_codex_head_stays_the_first_line(self):
        first = record('{"type":"session_meta","payload":{"cwd":"/home/u/demo"}}')
        path = self.put(".codex/sessions/2026/10/22/rollout-stamped.jsonl",
                        first + self.STAMPED + self.many_records(10))
        self.assertEqual(decode_chunks(self.entry(helper.snapshot(), path))[0],
                         (0, first.encode("utf-8")))

    def test_overlapping_head_and_tail_agree_on_a_small_file(self):
        content = self.LAST_PROMPT + self.STAMPED + self.many_records(5, partial='{"half')
        path = self.put(".claude/projects/-home-u-demo/d.jsonl", content)
        item = self.entry(helper.snapshot(), path)
        chunks = decode_chunks(item)
        self.assertEqual(len(chunks), 2)
        # The tail starts at zero too, so the head covers part of it. Both
        # are the file's own bytes at their own offsets, so either write
        # order leaves the same mirror.
        self.assertEqual(chunks[1][0], 0)
        for ordered in (chunks, list(reversed(chunks))):
            mirror = bytearray(item["size"])
            for offset, data in ordered:
                mirror[offset:offset + len(data)] = data
            self.assertEqual(bytes(mirror), content.encode("utf-8"))

    def test_whole_file_reships_on_change(self):
        path = self.put(".grok/active_sessions.json", '{"sessions":[]}')
        first = self.entry(helper.snapshot(), path)
        self.assertTrue(first["reset"])
        self.assertEqual(decode_chunks(first), [(0, b'{"sessions":[]}')])
        self.assertEqual(self.entry(helper.snapshot(), path)["chunks"], [])
        self.put(".grok/active_sessions.json", '{"sessions":[1]}')
        later = os.stat(path).st_mtime + 5
        os.utime(path, (later, later))
        changed = self.entry(helper.snapshot(), path)
        self.assertTrue(changed["reset"])
        self.assertEqual(decode_chunks(changed), [(0, b'{"sessions":[1]}')])

    def test_old_file_outside_window_is_not_listed(self):
        path = self.put(self.EVENTS, self.many_records(5))
        old = time.time() - helper.DISCOVERY_WINDOW_SECONDS - 60
        os.utime(path, (old, old))
        snap = helper.snapshot()
        self.assertIsNone(self.entry(snap, path))
        # An unwindowed spec keeps an equally old file.
        history = self.put(".gemini/antigravity-cli/history.jsonl", record('{"p":1}'))
        os.utime(history, (old, old))
        self.assertIsNotNone(self.entry(helper.snapshot(), history))

    def test_file_that_leaves_and_returns_ships_fresh(self):
        path = self.put(self.EVENTS, self.many_records(5))
        helper.snapshot()
        os.remove(path)
        self.assertIsNone(self.entry(helper.snapshot(), path))
        self.assertNotIn(path, helper.SHIPPED)
        self.put(self.EVENTS, self.many_records(5))
        item = self.entry(helper.snapshot(), path)
        self.assertTrue(item["reset"])
        self.assertEqual(decode_chunks(item)[0][0], 0)

    def test_backup_named_claude_root_is_skipped_with_warning(self):
        live = self.put(".claude/projects/-p/a.jsonl", record('{"type":"user"}'))
        backup = self.put(".claude.pre-move-backup/projects/-p/b.jsonl",
                          record('{"type":"user"}'))
        # A second name for the live root must not list its files twice.
        os.symlink(os.path.join(self.home, ".claude"),
                   os.path.join(self.home, ".claude-alias"))
        snap = helper.snapshot()
        paths = [f["path"] for f in snap["files"]]
        self.assertIn(live, paths)
        self.assertNotIn(backup, paths)
        self.assertEqual(sum(p.endswith("/a.jsonl") for p in paths), 1)
        self.assertTrue(any(".claude.pre-move-backup" in w for w in snap["warnings"]),
                        snap["warnings"])

    def test_conversation_db_only_with_presence_lock(self):
        base = ".gemini/antigravity-cli/"
        lock = self.put(base + "presence/conv-a.lock", "")
        live = self.put(base + "conversations/conv-a.db", b"SQLite synthetic a")
        wal = self.put(base + "conversations/conv-a.db-wal", b"wal a")
        ended = self.put(base + "conversations/conv-b.db", b"SQLite synthetic b")
        snap = helper.snapshot()
        self.assertIsNotNone(self.entry(snap, live))
        self.assertIsNotNone(self.entry(snap, wal))
        self.assertIsNone(self.entry(snap, ended))
        # A presence lock is listed for its existence and times, never read.
        lock_item = self.entry(snap, lock)
        self.assertIsNotNone(lock_item)
        self.assertEqual(lock_item["chunks"], [])

    def test_oversized_whole_file_is_omitted_not_empty(self):
        original = helper.WHOLE_MAX_BYTES
        helper.WHOLE_MAX_BYTES = 16
        try:
            path = self.put(".local/share/opencode/opencode.db", b"x" * 64)
            snap = helper.snapshot()
        finally:
            helper.WHOLE_MAX_BYTES = original
        self.assertIsNone(self.entry(snap, path))
        self.assertIn({"path": path, "reason": "too large"}, snap["omitted"])

    def test_tail_with_no_complete_record_is_omitted_not_empty(self):
        path = self.put(self.EVENTS, '{"i":"still being written')
        snap = helper.snapshot()
        self.assertIsNone(self.entry(snap, path))
        self.assertEqual([o["path"] for o in snap["omitted"]], [path])
        self.assertNotIn(path, helper.SHIPPED)

    def test_tail_over_the_ceiling_is_omitted_not_empty(self):
        original = helper.MAX_TAIL_BYTES
        helper.MAX_TAIL_BYTES = helper.TAIL_BYTES * 2
        try:
            path = self.put(self.EVENTS, record('{"first":1}')
                            + big_record("huge", helper.TAIL_BYTES * 4))
            snap = helper.snapshot()
        finally:
            helper.MAX_TAIL_BYTES = original
        self.assertIsNone(self.entry(snap, path))
        (omitted,) = snap["omitted"]
        self.assertEqual(omitted["path"], path)
        self.assertIn("no complete record", omitted["reason"])

    def test_ancestor_dirs_are_listed(self):
        session = ".kimi-code/sessions/wd_demo_0a1b/session_1234"
        self.put(session + "/state.json", '{"status":"idle"}')
        self.put(session + "/agents/main/wire.jsonl", record('{"t":1}'))
        os.makedirs(os.path.join(self.home, ".grok/sessions/s1/abc/subagents/sub-1"))
        snap = helper.snapshot()
        dirs = [d["path"] for d in snap["dirs"]]
        for relative in (".kimi-code", ".kimi-code/sessions",
                         ".kimi-code/sessions/wd_demo_0a1b", session,
                         session + "/agents", session + "/agents/main",
                         ".grok/sessions/s1/abc/subagents/sub-1"):
            self.assertIn(os.path.join(self.home, relative), dirs)
        self.assertNotIn(self.home, dirs)
        self.assertEqual(len(dirs), len(set(dirs)))
        for item in snap["dirs"]:
            self.assertIn("mtime", item)
            self.assertIn("created", item)

    def test_sqlite_shm_sidecars_are_not_shipped(self):
        opencode = ".local/share/opencode/"
        agy = ".gemini/antigravity-cli/"
        self.put(agy + "presence/conv-a.lock", "")
        kept = [self.put(opencode + "opencode.db", b"db"),
                self.put(opencode + "opencode.db-wal", b"wal"),
                self.put(agy + "conversation_summaries.db", b"db"),
                self.put(agy + "conversation_summaries.db-wal", b"wal"),
                self.put(agy + "conversations/conv-a.db", b"db"),
                self.put(agy + "conversations/conv-a.db-wal", b"wal")]
        dropped = [self.put(opencode + "opencode.db-shm", b"shm"),
                   self.put(agy + "conversation_summaries.db-shm", b"shm"),
                   self.put(agy + "conversations/conv-a.db-shm", b"shm")]
        snap = helper.snapshot()
        for path in kept:
            self.assertIsNotNone(self.entry(snap, path), path)
        for path in dropped:
            self.assertIsNone(self.entry(snap, path), path)

    def test_codex_first_ship_covers_the_widest_fallback_window(self):
        spec = [s for s in helper.SPECS if s.tool == "codex"][0]
        self.assertEqual(spec.tail_start, helper.MAX_TAIL_BYTES)

    def test_failed_snapshot_does_not_advance_shipped(self):
        path = self.put(self.EVENTS, self.many_records(10))
        old_size = os.stat(path).st_size
        helper.snapshot()
        appended = record('{"added":true}')
        self.put(self.EVENTS, appended, mode="ab")
        with mock.patch.object(helper, "agent_processes",
                               side_effect=RuntimeError("synthetic")):
            with self.assertRaises(RuntimeError):
                helper.snapshot()
        # The growth the failed snapshot built is shipped again, not lost.
        item = self.entry(helper.snapshot(), path)
        self.assertEqual(decode_chunks(item), [(old_size, appended.encode("utf-8"))])

    @unittest.skipIf(os.geteuid() == 0, "root reads a chmod 000 directory anyway")
    def test_unreadable_directory_is_omitted_not_silent(self):
        session = os.path.join(self.home, ".kimi-code/sessions/wd_demo_0a1b/session_1234")
        self.put(session + "/state.json", '{"status":"idle"}')
        grok = os.path.join(self.home, ".grok/sessions/s1")
        self.put(self.EVENTS, record('{"t":1}'))
        os.chmod(session, 0)
        os.chmod(grok, 0)
        try:
            snap = helper.snapshot()
        finally:
            os.chmod(session, 0o755)
            os.chmod(grok, 0o755)
        reasons = {o["path"]: o["reason"] for o in snap["omitted"]}
        # Inside a directory it may list but not search, the file is a
        # candidate whose stat fails; a directory it may not list at all is
        # reported itself. Neither reads as an empty result.
        self.assertIn(session + "/state.json", reasons)
        self.assertIn(grok, reasons)
        # Paths that simply do not exist stay out of omitted.
        for path in reasons:
            self.assertTrue(path.startswith(session) or path == grok, path)

    @unittest.skipIf(os.geteuid() == 0, "root lists a chmod 000 directory anyway")
    def test_unlistable_home_is_omitted_not_only_warned(self):
        self.put(self.EVENTS, record('{"t":1}'))
        os.chmod(self.home, 0)
        try:
            snap = helper.snapshot()
        finally:
            os.chmod(self.home, 0o755)
        homes = [o for o in snap["omitted"] if o["path"] == self.home]
        self.assertEqual(len(homes), 1)
        self.assertTrue(homes[0]["reason"].startswith("cannot list"))
        self.assertTrue(any(w.startswith("cannot list home") for w in snap["warnings"]))

    def test_homes_and_shape(self):
        snap = helper.snapshot()
        self.assertEqual([h["path"] for h in snap["homes"]], [self.home])
        self.assertTrue(snap["homes"][0]["user"])
        self.assertNotIn("sessions", snap)
        self.assertEqual(snap["processes"], [])
        self.assertFalse(snap["processes_failed"])


def reader_tail(data, start):
    """A port of ClaudeCodeMonitor.tail(of:startingAt:) over bytes.

    It doubles from `start` until the window holds a newline with at least
    one byte after it, returns everything after that newline, reads from 0
    as complete, and gives up (None) at the ceiling.
    """
    size = len(data)
    window = min(start, helper.MAX_TAIL_BYTES)
    while True:
        offset = size - window if size > window else 0
        text = data[offset:]
        if offset == 0:
            return text
        newline = text.find(b"\n")
        if newline != -1 and text[newline + 1:]:
            return text[newline + 1:]
        if window >= helper.MAX_TAIL_BYTES:
            return None
        window = min(window * 2, helper.MAX_TAIL_BYTES)


class MirrorEquivalenceTests(unittest.TestCase):
    """The property this protocol exists for: a sparse mirror built only
    from snapshot chunks reads, through the Mac's own tail reader, exactly
    as the real file does, poll after poll."""

    GROK = ".grok/sessions/s1/abc/events.jsonl"
    CODEX = ".codex/sessions/2026/10/22/rollout-demo.jsonl"

    def setUp(self):
        self.home = os.path.realpath(tempfile.mkdtemp(prefix="swarmbar-mirror-"))
        self.env = mock.patch.dict(os.environ, {"SWARMBAR_HELPER_HOMES": self.home})
        self.env.start()
        self.ps = mock.patch.object(helper, "agent_processes", return_value=[])
        self.ps.start()
        helper.SHIPPED.clear()
        self.mirrors = {}

    def tearDown(self):
        self.ps.stop()
        self.env.stop()
        helper.SHIPPED.clear()
        shutil.rmtree(self.home, ignore_errors=True)

    def apply(self, snap):
        """What the Mac does: reset discards, the file takes the manifest's
        size (holes read as zeros), and chunks land at their offsets."""
        for item in snap["files"]:
            mirror = self.mirrors.get(item["path"])
            if item["reset"] or mirror is None:
                mirror = bytearray()
            size = item["size"]
            mirror = mirror[:size] + bytearray(max(0, size - len(mirror)))
            for offset, data in decode_chunks(item):
                mirror[offset:offset + len(data)] = data
            self.mirrors[item["path"]] = mirror

    def records(self, rng, step):
        count, width = rng.choice([
            (1, 10), (5, 200), (50, 200), (3, 30000), (1, 90000),
            (1, 150000), (1, 300000)])
        return b"".join(b'{"s":%d,"p":"%s"}\n' % (step, b"x" * rng.randint(1, width))
                        for _ in range(count))

    def test_mirror_reads_like_the_file(self):
        rng = random.Random(20261022)
        paths = {}
        for relative, starts in ((self.GROK, (helper.TAIL_BYTES,)),
                                 (self.CODEX, (helper.TAIL_BYTES, 1 << 20,
                                               helper.MAX_TAIL_BYTES))):
            path = os.path.join(self.home, relative)
            os.makedirs(os.path.dirname(path))
            with open(path, "wb") as handle:
                handle.write(b'{"type":"session_meta","s":0}\n')
            paths[path] = starts
        compared = 0
        for step in range(40):
            for path in paths:
                if step == 8:
                    # A shrink: the file is replaced by something shorter.
                    data, mode = b'{"type":"session_meta","s":8}\n', "wb"
                elif step == 12:
                    # Growth past the 4 MB ceiling, in ordinary records.
                    # The fresh tail it forces leaves a hole ahead of it.
                    data, mode = b"".join(
                        b'{"s":12,"i":%d,"p":"%s"}\n' % (i, b"y" * 1000)
                        for i in range(5000)), "ab"
                elif step in (14, 20):
                    # One record far wider than the first window, so the
                    # reader doubles back past where the mirror begins.
                    width = 200000 if step == 14 else 1500000
                    data, mode = b'{"s":%d,"p":"%s"}\n' % (step, b"z" * width), "ab"
                else:
                    data, mode = self.records(rng, step), "ab"
                    if rng.random() < 0.3:
                        data += b'{"partial'
                with open(path, mode) as handle:
                    handle.write(data)
            snap = helper.snapshot()
            self.apply(snap)
            for path, starts in paths.items():
                with open(path, "rb") as handle:
                    real = handle.read()
                item = [f for f in snap["files"] if f["path"] == path][0]
                tail_offset, tail = decode_chunks(item)[-1] if item["chunks"] else (0, b"")
                if item["reset"] and tail_offset > 0:
                    # The tail opens on the newline ending the record before.
                    self.assertEqual(tail[:1], b"\n")
                    self.assertEqual(real[tail_offset:tail_offset + 1], b"\n")
                mirror = bytes(self.mirrors[path])
                self.assertEqual(len(mirror), len(real))
                for start in starts:
                    self.assertEqual(reader_tail(mirror, start), reader_tail(real, start),
                                     "step %d, %s, start %d" % (step, path, start))
                    compared += 1
                if path.endswith(self.CODEX):
                    first = real[:real.index(b"\n") + 1]
                    self.assertEqual(mirror[:len(first)], first)
        self.assertEqual(compared, 40 * 4)


class ReaderOffsetTests(unittest.TestCase):
    def test_small_file_reads_from_zero(self):
        self.assertEqual(helper.reader_offset(100, 50, helper.TAIL_BYTES), 0)

    def test_break_inside_first_window(self):
        size = 10 * helper.TAIL_BYTES
        self.assertEqual(helper.reader_offset(size, size - 10, helper.TAIL_BYTES),
                         size - helper.TAIL_BYTES)

    def test_window_doubles_back_to_the_break(self):
        size = 10 * helper.TAIL_BYTES
        last_break = size - helper.TAIL_BYTES - 1
        self.assertEqual(helper.reader_offset(size, last_break, helper.TAIL_BYTES),
                         size - 2 * helper.TAIL_BYTES)

    def test_gives_up_at_the_ceiling(self):
        size = 4 * helper.MAX_TAIL_BYTES
        self.assertEqual(helper.reader_offset(size, -1, helper.TAIL_BYTES),
                         size - helper.MAX_TAIL_BYTES)


class ShipDecisionTests(unittest.TestCase):
    def test_first_sight_is_fresh(self):
        self.assertEqual(helper.ship_decision(None, None, 10, 1.0), "fresh")

    def test_unchanged_is_nothing(self):
        self.assertEqual(helper.ship_decision(10, 1.0, 10, 1.0), "none")

    def test_growth(self):
        self.assertEqual(helper.ship_decision(10, 1.0, 20, 2.0), "growth")

    def test_growth_past_the_ceiling_is_fresh(self):
        self.assertEqual(helper.ship_decision(
            10, 1.0, 11 + helper.MAX_TAIL_BYTES, 2.0), "fresh")

    def test_shrink_is_fresh(self):
        self.assertEqual(helper.ship_decision(20, 1.0, 10, 2.0), "fresh")

    def test_same_size_rewritten_is_fresh(self):
        self.assertEqual(helper.ship_decision(10, 1.0, 10, 2.0), "fresh")


class ProtocolTests(unittest.TestCase):
    def run_main(self, *requests):
        stdin = io.StringIO("".join(json.dumps(r) + "\n" for r in requests))
        stdout = io.StringIO()
        helper.main(stdin, stdout)
        return [json.loads(l) for l in stdout.getvalue().splitlines()]

    def test_ping_echoes_id(self):
        (reply,) = self.run_main({"id": 7, "cmd": "ping"})
        self.assertEqual(reply["id"], 7)
        self.assertTrue(reply["ok"])
        self.assertEqual(reply["protocol"], 3)
        self.assertRegex(reply["sha256"], r"^[0-9a-f]{64}$")
        self.assertEqual(reply["euid"], os.geteuid())
        self.assertEqual(reply["stream"], helper.STREAM_ID)

    def test_ping_sha256_is_the_hash_of_the_helper_file(self):
        path = os.path.join(
            os.path.dirname(os.path.abspath(__file__)), "swarmbar-helper.py")
        with open(path, "rb") as handle:
            expected = hashlib.sha256(handle.read()).hexdigest()
        (reply,) = self.run_main({"id": 1, "cmd": "ping"})
        self.assertEqual(reply["sha256"], expected)

    def test_echo_returns_its_value_under_its_id(self):
        replies = self.run_main(
            {"id": 3, "cmd": "echo", "value": "first"},
            {"id": 4, "cmd": "echo", "value": {"n": 2}},
            {"id": 5, "cmd": "echo"},
        )
        self.assertEqual([r["id"] for r in replies], [3, 4, 5])
        self.assertTrue(all(r["ok"] for r in replies))
        self.assertEqual(replies[0]["value"], "first")
        self.assertEqual(replies[1]["value"], {"n": 2})
        self.assertIsNone(replies[2]["value"])

    def test_unknown_command_keeps_id(self):
        (reply,) = self.run_main({"id": 12, "cmd": "nope"})
        self.assertEqual(reply["id"], 12)
        self.assertFalse(reply["ok"])

    def test_concurrent_writes_do_not_interleave(self):
        sink = io.StringIO()
        previous = helper._OUT
        helper._OUT = sink
        try:
            def work(n):
                for i in range(200):
                    helper.write_line({"event": "t", "n": n, "i": i, "pad": "x" * 500})
            threads = [threading.Thread(target=work, args=(n,)) for n in range(8)]
            for t in threads:
                t.start()
            for t in threads:
                t.join()
        finally:
            helper._OUT = previous
        lines = sink.getvalue().splitlines()
        self.assertEqual(len(lines), 1600)
        for line in lines:
            json.loads(line)

    def test_homes_override(self):
        a = tempfile.mkdtemp(prefix="swarmbar-home-a-")
        b = tempfile.mkdtemp(prefix="swarmbar-home-b-")
        try:
            with mock.patch.dict(os.environ, {
                    "SWARMBAR_HELPER_HOMES": a + ":" + b + ":/nonexistent-home"}):
                self.assertEqual(helper.home_dirs(), [a, b])
        finally:
            shutil.rmtree(a, ignore_errors=True)
            shutil.rmtree(b, ignore_errors=True)

    def test_non_root_sees_only_own_home(self):
        env = dict(os.environ)
        env.pop("SWARMBAR_HELPER_HOMES", None)
        with mock.patch.dict(os.environ, env, clear=True), \
                mock.patch.object(os, "geteuid", return_value=1000):
            self.assertEqual(helper.home_dirs(), [os.path.expanduser("~")])


PS_SAMPLE = (
    "    1     0 0 root     ?        systemd         /sbin/init splash\n"
    "  500     1 1000 zach     pts/1    tmux: server    tmux new -s work\n"
    "  610   500 1000 zach     pts/2    bash            -bash\n"
    "  700   610 1000 zach     pts/2    claude          claude --resume abc --model x\n"
    "  800     1 1000 zach     ?        node            node /home/z/bearcode-cli/apps/kimi-code/dist/main.mjs --yolo\n"
)


def completed(argv, code, out):
    import subprocess
    return subprocess.CompletedProcess(argv, code, out.encode("utf-8"), b"")


class FakeRunner(object):
    """Stands in for helper.run_command so no test touches a real process."""

    def __init__(self, ps=None, panes=None, capture="", lsof="", ps_code=0):
        self.ps, self.panes, self.capture = ps, panes or {}, capture
        self.lsof, self.ps_code = lsof, ps_code
        self.calls = []

    def __call__(self, argv, timeout=5):
        self.calls.append(list(argv))
        if argv[0] == "ps":
            return completed(argv, self.ps_code, self.ps if self.ps is not None else PS_SAMPLE)
        if argv[0] == "tmux":
            socket = argv[2]
            if "list-panes" in argv:
                if socket not in self.panes:
                    return completed(argv, 1, "")
                return completed(argv, 0, self.panes[socket])
            if "capture-pane" in argv:
                return completed(argv, 0, self.capture)
        if argv[0] == "lsof":
            return completed(argv, 0, self.lsof)
        return completed(argv, 1, "")


class ProcessTableTests(unittest.TestCase):
    def setUp(self):
        patches = [
            mock.patch.object(helper, "process_cwd", return_value="/work"),
            mock.patch.object(helper, "tmux_sockets", return_value=["/tmp/tmux-1000/default"]),
            # No uid in these samples names a real account, so the printed
            # user stands, whoever runs the tests.
            mock.patch("pwd.getpwuid", side_effect=KeyError("no such uid")),
        ]
        for p in patches:
            p.start()
            self.addCleanup(p.stop)

    def run_table(self, runner):
        with mock.patch.object(helper, "run_command", runner):
            warnings = []
            return helper.agent_processes(warnings), warnings

    def test_parse_ps_keeps_args_with_spaces(self):
        rows = helper.parse_ps(PS_SAMPLE)
        claude = [r for r in rows if r["pid"] == 700][0]
        self.assertEqual(claude["args"], "claude --resume abc --model x")
        self.assertEqual(claude["ppid"], 610)
        self.assertEqual(claude["tty"], "pts/2")
        self.assertEqual(claude["comm"], "claude")
        self.assertEqual([r for r in rows if r["pid"] == 1][0]["tty"], "")

    def test_parse_ps_takes_basename_of_a_path_comm(self):
        rows = helper.parse_ps("  9  1 1000 zach ttys001 /opt/bin/codex codex exec go\n")
        self.assertEqual(rows[0]["comm"], "codex")
        self.assertEqual(rows[0]["args"], "codex exec go")

    def test_ps_asks_for_the_uid(self):
        runner = FakeRunner()
        self.run_table(runner)
        ps = [call for call in runner.calls if call[0] == "ps"][0]
        self.assertIn("uid=", ps[-1])
        # GNU width syntax (user:64=) is rejected by BSD ps.
        self.assertNotIn(":", ps[-1])

    def test_user_resolved_from_uid_not_the_truncated_column(self):
        """procps truncates a long name to `longuser+`, which would never
        match the home's owner on the Mac and would drop every session."""
        entry = mock.Mock(pw_name="longusername")
        with mock.patch("pwd.getpwuid", return_value=entry) as lookup:
            rows = helper.parse_ps("  10  1 1001 longuser+ pts/1 claude claude\n")
        lookup.assert_called_with(1001)
        self.assertEqual(rows[0]["user"], "longusername")
        self.assertNotIn("uid", rows[0])

    def test_unknown_uid_keeps_the_printed_user(self):
        rows = helper.parse_ps("  10  1 4242 someone pts/1 claude claude\n")
        self.assertEqual(rows[0]["user"], "someone")

    def test_parse_ps_skips_malformed_lines(self):
        self.assertEqual(helper.parse_ps("garbage\n  x 1 0 u t c a\n  5 1 x u t c a\n"), [])

    def test_bearcode_found_by_args(self):
        table, _ = self.run_table(FakeRunner())
        pids = sorted(p["pid"] for p in table)
        self.assertEqual(pids, [700, 800])
        bear = [p for p in table if p["pid"] == 800][0]
        self.assertEqual(bear["comm"], "bearcode")
        self.assertIn("bearcode-cli/apps/kimi-code/dist/main.mjs", bear["args"])

    def test_pane_found_through_ancestry(self):
        runner = FakeRunner(panes={"/tmp/tmux-1000/default": "%3 500\n%4 999\n"})
        table, _ = self.run_table(runner)
        claude = [p for p in table if p["pid"] == 700][0]
        self.assertEqual(claude["pane"], {"socket": "/tmp/tmux-1000/default", "id": "%3"})
        self.assertIsNone([p for p in table if p["pid"] == 800][0]["pane"])

    def test_bare_tty_agent_has_no_pane(self):
        runner = FakeRunner(panes={"/tmp/tmux-1000/default": "%4 999\n"})
        table, _ = self.run_table(runner)
        self.assertTrue(all(p["pane"] is None for p in table))

    def test_missing_tmux_means_null_panes_not_failure(self):
        fake = FakeRunner()

        def runner(argv, timeout=5):
            if argv[0] == "tmux":
                raise OSError("no tmux")
            return fake(argv, timeout)
        table, _ = self.run_table(runner)
        self.assertIsNotNone(table)
        self.assertTrue(all(p["pane"] is None for p in table))

    def test_failing_socket_is_skipped_others_still_work(self):
        with mock.patch.object(helper, "tmux_sockets",
                               return_value=["/tmp/tmux-0/default", "/tmp/tmux-1000/default"]):
            runner = FakeRunner(panes={"/tmp/tmux-1000/default": "%3 500\n"})
            table, _ = self.run_table(runner)
        claude = [p for p in table if p["pid"] == 700][0]
        self.assertEqual(claude["pane"]["id"], "%3")

    def test_ancestry_walk_is_bounded(self):
        parents = {1: 2, 2: 3, 3: 1}
        self.assertIsNone(helper.pane_for(1, parents, {99: {"socket": "s", "id": "%1"}}))
        chain = dict((n, n + 1) for n in range(1, 100))
        self.assertIsNone(helper.pane_for(1, chain, {40: {"socket": "s", "id": "%1"}}))
        self.assertEqual(helper.pane_for(1, chain, {20: {"socket": "s", "id": "%1"}})["id"], "%1")

    def test_ps_failure_sets_processes_failed(self):
        table, warnings = self.run_table(FakeRunner(ps_code=1))
        self.assertIsNone(table)
        self.assertTrue(warnings)
        with mock.patch.object(helper, "run_command", FakeRunner(ps_code=1)), \
                mock.patch.object(helper, "manifest", return_value=([], [], [], {})), \
                mock.patch.object(helper, "home_entries", return_value=[]):
            snap = helper.snapshot()
        self.assertTrue(snap["processes_failed"])
        self.assertEqual(snap["processes"], [])

    def test_ps_oserror_returns_none(self):
        def boom(argv, timeout=5):
            raise OSError("no ps")
        with mock.patch.object(helper, "run_command", boom):
            self.assertIsNone(helper.agent_processes([]))

    def test_held_files_only_for_codex_and_agy(self):
        ps = ("  10  1 1000 z ttys001 codex codex\n  11  1 1000 z ttys002 agy agy\n"
              "  12  1 1000 z ttys003 claude claude\n")
        lsof = "p10\nn/h/.codex/sessions/2026/a.jsonl\nn/etc/hosts\nn/h/presence/x.lock\n"
        with mock.patch.object(helper.platform, "system", return_value="Darwin"):
            table, _ = self.run_table(FakeRunner(ps=ps, lsof=lsof))
        by = dict((p["comm"], p) for p in table)
        self.assertEqual(by["codex"]["open"], ["/h/.codex/sessions/2026/a.jsonl"])
        self.assertEqual(by["agy"]["open"], ["/h/presence/x.lock"])
        self.assertEqual(by["claude"]["open"], [])

    def test_held_files_read_proc_on_linux(self):
        ps = "  10  1 1000 z pts/1 codex codex\n"
        links = ["/h/.codex/sessions/r.jsonl", "/dev/null", "/h/.codex/other.jsonl"]
        with mock.patch.object(helper.platform, "system", return_value="Linux"), \
                mock.patch.object(helper, "proc_fd_links", return_value=links):
            table, _ = self.run_table(FakeRunner(ps=ps))
        self.assertEqual(table[0]["open"], ["/h/.codex/sessions/r.jsonl"])
        self.assertFalse(table[0].get("open_failed", False))

    def test_unreadable_fd_dir_is_flagged_not_empty(self):
        ps = "  10  1 1000 z pts/1 codex codex\n"
        with mock.patch.object(helper.platform, "system", return_value="Linux"), \
                mock.patch.object(helper, "proc_fd_links", return_value=None):
            table, warnings = self.run_table(FakeRunner(ps=ps))
        self.assertTrue(table[0]["open_failed"])
        self.assertTrue([w for w in warnings if "10" in w])

    def test_lsof_failure_is_flagged(self):
        ps = "  10  1 1000 z ttys1 codex codex\n"
        def runner(argv, timeout=5):
            if argv[0] == "lsof":
                raise OSError("gone")
            return FakeRunner(ps=ps)(argv, timeout)
        with mock.patch.object(helper.platform, "system", return_value="Darwin"):
            table, _ = self.run_table(runner)
        self.assertTrue(table[0]["open_failed"])

    def test_darwin_truncated_comm_resolved_from_argv0(self):
        ps = ("  30  1 1000 zach ttys001 /Users/zach/.loc /Users/zach/.local/bin/claude --resume\n"
              "  31  1 1000 zach ttys002 /Users/zach/.cod /Users/zach/.codex/bin/codex exec\n"
              "  32  1 1000 zach ttys003 /Users/zach/.loc /Users/zach/.local/bin/other --x\n")
        table, _ = self.run_table(FakeRunner(ps=ps))
        self.assertEqual(sorted((p["pid"], p["comm"]) for p in table),
                         [(30, "claude"), (31, "codex")])

    def test_unparseable_ps_output_is_a_failure(self):
        table, warnings = self.run_table(FakeRunner(ps="complete nonsense\n"))
        self.assertIsNone(table)
        self.assertTrue(warnings)

    def test_agent_that_is_the_pane_pid_gets_the_pane(self):
        runner = FakeRunner(ps="  700  1 1000 z pts/1 claude claude\n",
                            panes={"/tmp/tmux-1000/default": "%9 700\n"})
        table, _ = self.run_table(runner)
        self.assertEqual(table[0]["pane"]["id"], "%9")

    def test_screen_only_for_agy_with_a_pane_and_last_60_lines(self):
        ps = ("  10  1 1000 z pts/1 agy agy\n  11  1 1000 z pts/2 claude claude\n"
              "  500 1 1000 z pts/3 tmux tmux\n  20 500 1000 z pts/4 agy agy\n")
        capture = "\n".join("line%d" % n for n in range(100)) + "\n"
        runner = FakeRunner(ps=ps, panes={"/tmp/tmux-1000/default": "%7 500\n"}, capture=capture)
        with mock.patch.object(helper.platform, "system", return_value="Darwin"):
            table, _ = self.run_table(runner)
        by = dict((p["pid"], p) for p in table)
        self.assertIsNone(by[10]["screen"])
        self.assertIsNone(by[11]["screen"])
        lines = by[20]["screen"].splitlines()
        self.assertEqual(len(lines), 60)
        self.assertEqual(lines[-1], "line99")


class TmuxRecorder(object):
    """Stands in for helper.run_command and records argv lists and inputs."""

    def __init__(self, screen="", fail_on_send=None, capture_code=0, ps=None, panes=None,
                 fail_when=None):
        self.capture_code = capture_code
        # A predicate on argv: a matching tmux call exits 1.
        self.fail_when = fail_when
        self.ps, self.panes = ps, panes or {}
        self.calls = []
        self.inputs = []
        self.screen = screen
        self.fail_on_send = fail_on_send
        self.sends = 0

    def __call__(self, argv, timeout=5, input=None):
        self.calls.append(list(argv))
        self.inputs.append(input)
        if argv[0] == "ps":
            return subprocess.CompletedProcess(
                argv, 0, stdout=(self.ps or "").encode("utf-8"), stderr=b"")
        if "list-panes" in argv:
            text = self.panes.get(argv[2])
            return subprocess.CompletedProcess(
                argv, 0 if text is not None else 1,
                stdout=(text or "").encode("utf-8"), stderr=b"")
        code = 0
        if "send-keys" in argv:
            self.sends += 1
            if self.fail_on_send == self.sends:
                code = 1
        out = self.screen.encode("utf-8") if "capture-pane" in argv else b""
        if "capture-pane" in argv:
            code = self.capture_code
        if self.fail_when is not None and self.fail_when(argv):
            code = 1
        return subprocess.CompletedProcess(argv, code, stdout=out, stderr=b"")

    def sent(self):
        return [c for c in self.calls if "send-keys" in c]


class TmuxCommandTests(unittest.TestCase):
    def setUp(self):
        import socket as socket_module
        # Short path: unix socket paths are limited to about 100 bytes.
        self.root = os.path.realpath(tempfile.mkdtemp(dir="/tmp"))
        self.addCleanup(shutil.rmtree, self.root, True)
        os.makedirs(os.path.join(self.root, "tmux-1"))
        path = os.path.join(self.root, "tmux-1", "default")
        self.server = socket_module.socket(socket_module.AF_UNIX)
        self.addCleanup(self.server.close)
        self.server.bind(path)
        self.sock = path
        self.pane = {"socket": path, "id": "%3"}
        patcher = mock.patch.dict(os.environ, {"TMUX_TMPDIR": self.root})
        patcher.start()
        self.addCleanup(patcher.stop)

    def call(self, request, recorder):
        with mock.patch.object(helper, "run_command", recorder), \
                mock.patch.object(helper.time, "sleep"):
            return helper.handle_tmux(request)

    def test_key_mapping(self):
        self.assertEqual(helper.tmux_key_args("UP"), ["Up"])
        self.assertEqual(helper.tmux_key_args("DOWN"), ["Down"])
        self.assertEqual(helper.tmux_key_args("ESC"), ["Escape"])
        self.assertEqual(helper.tmux_key_args("\n"), ["Enter"])
        self.assertEqual(helper.tmux_key_args("1"), ["-l", "--", "1"])

    def test_capture_is_visible_screen_only(self):
        rec = TmuxRecorder(screen="hello")
        out = self.call({"cmd": "capture", "pane": self.pane, "lines": 500}, rec)
        self.assertEqual(out["text"], "hello")
        self.assertEqual(rec.calls[0], ["tmux", "-S", self.sock, "capture-pane",
                                        "-p", "-t", "%3"])

    def test_keys_not_sent_when_expect_missing(self):
        rec = TmuxRecorder(screen="1. Approve once\n2. Deny")
        out = self.call({"cmd": "keys", "pane": self.pane, "keys": ["2"],
                         "expect": ["3. Approve always"]}, rec)
        self.assertEqual(out, {"sent": False, "reason": "changed"})
        self.assertEqual(rec.sent(), [])

    def test_keys_sent_in_order_with_literal_flag(self):
        rec = TmuxRecorder(screen="1. Approve once")
        sleeps = []
        with mock.patch.object(helper, "run_command", rec), \
                mock.patch.object(helper.time, "sleep", sleeps.append):
            out = helper.handle_tmux({"cmd": "keys", "pane": self.pane,
                                      "keys": ["DOWN", "1", "\n"],
                                      "expect": ["Approve once"], "gap": 0.3})
        self.assertEqual(out, {"sent": True})
        base = ["tmux", "-S", self.sock, "send-keys", "-t", "%3"]
        self.assertEqual(rec.sent(), [base + ["Down"], base + ["-l", "--", "1"],
                                      base + ["Enter"]])
        self.assertEqual(sleeps, [0.3, 0.3])

    def test_gap_is_clamped(self):
        rec = TmuxRecorder()
        sleeps = []
        with mock.patch.object(helper, "run_command", rec), \
                mock.patch.object(helper.time, "sleep", sleeps.append):
            helper.handle_tmux({"cmd": "keys", "pane": self.pane, "keys": ["UP", "UP"],
                                "expect": [], "gap": 60})
        self.assertEqual(sleeps, [0.5])

    def test_label_only_in_history_sends_nothing(self):
        # The fake returns the visible screen; history is never requested.
        rec = TmuxRecorder(screen="2. Deny")
        out = self.call({"cmd": "keys", "pane": self.pane, "keys": ["1"],
                         "expect": ["Approve once"]}, rec)
        self.assertEqual(out, {"sent": False, "reason": "changed"})
        self.assertEqual(rec.sent(), [])
        self.assertTrue(all("-S" not in c[3:] for c in rec.calls))

    def test_failed_confirming_capture_sends_nothing(self):
        rec = TmuxRecorder(capture_code=1)
        out = self.call({"cmd": "keys", "pane": self.pane, "keys": ["1"],
                         "expect": ["Approve"]}, rec)
        self.assertEqual(out, {"sent": False, "reason": "capture failed"})
        self.assertEqual(rec.sent(), [])

    def test_empty_expect_skips_confirmation(self):
        rec = TmuxRecorder()
        out = self.call({"cmd": "keys", "pane": self.pane, "keys": ["ESC"], "expect": []}, rec)
        self.assertEqual(out, {"sent": True})
        self.assertFalse(any("capture-pane" in c for c in rec.calls))

    def test_send_failure_reports_count(self):
        rec = TmuxRecorder(fail_on_send=2)
        out = self.call({"cmd": "keys", "pane": self.pane, "keys": ["UP", "UP", "UP"],
                         "expect": []}, rec)
        self.assertEqual(out, {"sent": False, "reason": "send failed", "sent_count": 1})
        self.assertEqual(len(rec.sent()), 2)

    def target_recorder(self, ps=PS_SAMPLE, pane_line="%3 610\n"):
        return TmuxRecorder(screen="1. Approve once", ps=ps, panes={self.sock: pane_line})

    def test_keys_sent_when_target_still_matches(self):
        rec = self.target_recorder()
        out = self.call({"cmd": "keys", "pane": self.pane, "keys": ["1"],
                         "expect": ["Approve once"], "pid": 700, "comm": "claude"}, rec)
        self.assertEqual(out, {"sent": True})
        self.assertEqual(len(rec.sent()), 1)

    def test_keys_not_sent_when_pid_gone(self):
        rec = self.target_recorder()
        out = self.call({"cmd": "keys", "pane": self.pane, "keys": ["1"],
                         "expect": [], "pid": 999, "comm": "claude"}, rec)
        self.assertEqual(out, {"sent": False, "reason": "changed"})
        self.assertEqual(rec.sent(), [])

    def test_keys_not_sent_when_comm_changed(self):
        # The pid was reused by another agent, or the snapshot named another.
        rec = self.target_recorder()
        out = self.call({"cmd": "keys", "pane": self.pane, "keys": ["y"],
                         "expect": [], "pid": 700, "comm": "codex"}, rec)
        self.assertEqual(out, {"sent": False, "reason": "changed"})
        self.assertEqual(rec.sent(), [])

    def test_keys_not_sent_when_pane_changed(self):
        rec = self.target_recorder(pane_line="%4 610\n")
        out = self.call({"cmd": "keys", "pane": self.pane, "keys": ["1"],
                         "expect": [], "pid": 700, "comm": "claude"}, rec)
        self.assertEqual(out, {"sent": False, "reason": "changed"})
        self.assertEqual(rec.sent(), [])

    def test_keys_not_sent_when_ps_fails(self):
        rec = self.target_recorder(ps="")
        out = self.call({"cmd": "keys", "pane": self.pane, "keys": ["1"],
                         "expect": [], "pid": 700, "comm": "claude"}, rec)
        self.assertEqual(out, {"sent": False, "reason": "changed"})
        self.assertEqual(rec.sent(), [])

    def test_target_args_must_come_together(self):
        for extra in ({"pid": 700}, {"comm": "claude"}, {"pid": "700", "comm": "claude"},
                      {"pid": True, "comm": "claude"}, {"pid": 700, "comm": 3}):
            request = {"cmd": "keys", "pane": self.pane, "keys": ["1"], "expect": []}
            request.update(extra)
            rec = self.target_recorder()
            self.assertEqual(self.call(request, rec), {"ok": False, "error": "bad keys"}, extra)
            self.assertEqual(rec.sent(), [])

    def test_expect_more_needs_the_count_to_rise(self):
        # "ok" was on screen twice before the paste. Twice is not enough.
        for screen, sent in (("ok\n> ok", False), ("ok\n> x", False), ("ok\nok\n> ok", True)):
            rec = TmuxRecorder(screen=screen)
            out = self.call({"cmd": "keys", "pane": self.pane, "keys": ["\n"],
                             "expect_more": [{"text": "ok", "before": 2}]}, rec)
            expected = {"sent": True} if sent else {"sent": False, "reason": "changed"}
            self.assertEqual(out, expected, screen)
            self.assertEqual(len(rec.sent()), 1 if sent else 0, screen)

    def test_expect_more_counts_without_overlap(self):
        # "aa" occurs once in "aaa" as python counts it, not twice.
        rec = TmuxRecorder(screen="aaa")
        out = self.call({"cmd": "keys", "pane": self.pane, "keys": ["\n"],
                         "expect_more": [{"text": "aa", "before": 1}]}, rec)
        self.assertEqual(out, {"sent": False, "reason": "changed"})

    def test_expect_more_works_beside_expect_and_target(self):
        rec = self.target_recorder()
        out = self.call({"cmd": "keys", "pane": self.pane, "keys": ["\n"],
                         "expect": ["Approve once"], "pid": 700, "comm": "claude",
                         "expect_more": [{"text": "Approve", "before": 0}]}, rec)
        self.assertEqual(out, {"sent": True})
        rec = self.target_recorder()
        out = self.call({"cmd": "keys", "pane": self.pane, "keys": ["\n"],
                         "expect": ["Missing"], "pid": 700, "comm": "claude",
                         "expect_more": [{"text": "Approve", "before": 0}]}, rec)
        self.assertEqual(out, {"sent": False, "reason": "changed"})

    def test_malformed_expect_more_is_bad_keys(self):
        for bad in ("ok", {"text": "ok", "before": 0}, [{"text": "ok"}], [{"before": 0}],
                    [{"text": 3, "before": 0}], [{"text": "ok", "before": "0"}],
                    [{"text": "ok", "before": True}], [{"text": "ok", "before": -1}],
                    [{"text": "", "before": 0}], ["ok"]):
            rec = TmuxRecorder(screen="ok ok ok")
            out = self.call({"cmd": "keys", "pane": self.pane, "keys": ["\n"],
                             "expect_more": bad}, rec)
            self.assertEqual(out, {"ok": False, "error": "bad keys"}, bad)
            self.assertEqual(rec.sent(), [], bad)

    def test_paste_brackets_itself_and_never_sends_enter(self):
        # The local reply's form, verified live on every tool: the markers
        # are sent whatever mode the app is in, and -r keeps LF as LF where
        # plain paste-buffer would turn each one into a CR, an Enter.
        rec = TmuxRecorder()
        with mock.patch.object(helper, "paste_buffer_name", return_value="swarmbar-1-ab"):
            out = self.call({"cmd": "paste", "pane": self.pane, "text": "hi\nthere"}, rec)
        self.assertEqual(out, {"sent": True})
        base = ["tmux", "-S", self.sock]
        self.assertEqual(rec.calls, [
            base + ["load-buffer", "-b", "swarmbar-1-ab", "-"],
            base + ["send-keys", "-t", "%3", "-H", "1b", "5b", "32", "30", "30", "7e"],
            base + ["paste-buffer", "-r", "-d", "-b", "swarmbar-1-ab", "-t", "%3"],
            base + ["send-keys", "-t", "%3", "-H", "1b", "5b", "32", "30", "31", "7e"],
        ])
        self.assertEqual(rec.inputs[0], b"hi\nthere")
        self.assertFalse(any("Enter" in c or "-p" in c for c in rec.calls))

    def paste_failing(self, *steps):
        """A paste whose tmux calls for the named steps exit 1. A step is
        "load-buffer", "paste-buffer", "delete-buffer", or "200"/"201" for
        the markers."""
        def fails(argv):
            if "send-keys" in argv:
                return {"30": "200", "31": "201"}[argv[-2]] in steps
            return any(step in argv for step in steps)
        rec = TmuxRecorder(fail_when=fails)
        with mock.patch.object(helper, "paste_buffer_name", return_value="swarmbar-1-ab"):
            out = self.call({"cmd": "paste", "pane": self.pane, "text": "hi"}, rec)
        return out, rec

    def tail(self, rec, count):
        return [c[3:] for c in rec.calls[-count:]]

    DELETE = ["delete-buffer", "-b", "swarmbar-1-ab"]
    CLOSE = ["send-keys", "-t", "%3", "-H", "1b", "5b", "32", "30", "31", "7e"]

    def test_failed_load_is_its_own_reason_and_sends_nothing_else(self):
        # Nothing reached the pane, which the Mac reports as nothing sent.
        out, rec = self.paste_failing("load-buffer")
        self.assertEqual(out, {"sent": False, "reason": "load failed"})
        self.assertEqual(len(rec.calls), 1)

    def test_failed_opening_marker_drops_the_buffer_only(self):
        out, rec = self.paste_failing("200")
        self.assertEqual(out, {"sent": False, "reason": "send failed"})
        self.assertEqual(len(rec.calls), 3)
        self.assertEqual(self.tail(rec, 1), [self.DELETE])
        self.assertFalse(any("paste-buffer" in c for c in rec.calls))

    def test_failed_paste_still_closes_the_bracket(self):
        # ESC[200~ went out, so ESC[201~ follows even when the paste fails,
        # or the pane is left in paste mode. Its own failure changes nothing,
        # and nor does a failed cleanup.
        for steps in (("paste-buffer",), ("paste-buffer", "201"),
                      ("paste-buffer", "201", "delete-buffer")):
            out, rec = self.paste_failing(*steps)
            self.assertEqual(out, {"sent": False, "reason": "send failed"}, steps)
            self.assertEqual(len(rec.calls), 5, steps)
            self.assertEqual(self.tail(rec, 2), [self.CLOSE, self.DELETE], steps)

    def test_failed_closing_marker_reports_send_failed(self):
        out, rec = self.paste_failing("201")
        self.assertEqual(out, {"sent": False, "reason": "send failed"})
        self.assertEqual(len(rec.calls), 5)
        self.assertEqual(self.tail(rec, 1), [self.DELETE])

    def test_paste_buffer_names_are_per_request(self):
        first, second = helper.paste_buffer_name(), helper.paste_buffer_name()
        self.assertNotEqual(first, second)
        self.assertTrue(re.match(r"^swarmbar-%d-[0-9a-f]{32}$" % os.getpid(), first), first)

    def test_paste_sent_when_target_still_matches(self):
        rec = self.target_recorder()
        out = self.call({"cmd": "paste", "pane": self.pane, "text": "hi",
                         "pid": 700, "comm": "claude"}, rec)
        self.assertEqual(out, {"sent": True})
        self.assertTrue(any("paste-buffer" in c for c in rec.calls))

    def test_paste_not_sent_when_target_changed(self):
        # The pid is gone, is another agent, or has left the pane, and so is
        # a failed ps: nothing is loaded or pasted.
        for extra, pane_line, ps in (({"pid": 999, "comm": "claude"}, "%3 610\n", PS_SAMPLE),
                                     ({"pid": 700, "comm": "codex"}, "%3 610\n", PS_SAMPLE),
                                     ({"pid": 700, "comm": "claude"}, "%4 610\n", PS_SAMPLE),
                                     ({"pid": 700, "comm": "claude"}, "%3 610\n", "")):
            request = {"cmd": "paste", "pane": self.pane, "text": "hi"}
            request.update(extra)
            rec = self.target_recorder(ps=ps, pane_line=pane_line)
            self.assertEqual(self.call(request, rec), {"sent": False, "reason": "changed"}, extra)
            self.assertFalse(any("load-buffer" in c or "paste-buffer" in c for c in rec.calls), extra)

    def test_paste_target_args_must_come_together(self):
        for extra in ({"pid": 700}, {"comm": "claude"}, {"pid": "700", "comm": "claude"},
                      {"pid": True, "comm": "claude"}, {"pid": 700, "comm": 3}):
            request = {"cmd": "paste", "pane": self.pane, "text": "hi"}
            request.update(extra)
            rec = self.target_recorder()
            self.assertEqual(self.call(request, rec), {"ok": False, "error": "bad target"}, extra)
            self.assertFalse(any("load-buffer" in c or "paste-buffer" in c for c in rec.calls), extra)

    def test_paste_strips_control_characters(self):
        rec = TmuxRecorder()
        self.call({"cmd": "paste", "pane": self.pane,
                   "text": "a\x1b[201~b\tc\nd\x00\x7fe"}, rec)
        self.assertEqual(rec.inputs[0], b"a[201~b\tc\nde")

    def test_bad_pane_refused(self):
        bad = [
            {"socket": self.sock, "id": "3"},
            {"socket": self.sock, "id": "%3; rm"},
            {"socket": "/tmp/other/default", "id": "%3"},
            {"socket": "tmux-1000/default", "id": "%3"},
            {"socket": "/etc/tmux-x/../passwd", "id": "%3"},
            None, "x", {},
        ]
        for pane in bad:
            rec = TmuxRecorder()
            out = self.call({"cmd": "keys", "pane": pane, "keys": ["1"], "expect": []}, rec)
            self.assertEqual(out, {"ok": False, "error": "bad pane"}, pane)
            self.assertEqual(rec.calls, [])

    def test_real_socket_accepted_and_resolved_path_used(self):
        link = os.path.join(self.root, "tmux-1", "alias")
        os.symlink(self.sock, link)
        rec = TmuxRecorder()
        out = self.call({"cmd": "keys", "pane": {"socket": link, "id": "%3"},
                         "keys": ["UP"], "expect": []}, rec)
        self.assertEqual(out, {"sent": True})
        self.assertEqual(rec.calls[0][2], self.sock)

    def test_non_socket_file_refused(self):
        plain = os.path.join(self.root, "tmux-1", "plain")
        open(plain, "w").close()
        self.assertIsNone(helper.valid_pane({"socket": plain, "id": "%1"}))

    def test_owner_mismatch_refused(self):
        real_stat = os.stat
        directory = os.path.join(self.root, "tmux-1")

        def fake(path, *args, **kwargs):
            info = real_stat(path, *args, **kwargs)
            if path == directory:
                return os.stat_result((info.st_mode, info.st_ino, info.st_dev,
                                       info.st_nlink, info.st_uid + 1, info.st_gid,
                                       info.st_size, 0, 0, 0))
            return info
        with mock.patch.object(helper.os, "stat", fake):
            self.assertIsNone(helper.valid_pane(self.pane))
        self.assertIsNotNone(helper.valid_pane(self.pane))

    def test_symlink_escaping_tmux_dir_refused(self):
        os.makedirs(os.path.join(self.root, "elsewhere"))
        link = os.path.join(self.root, "tmux-1", "sock")
        os.symlink(os.path.join(self.root, "elsewhere", "sock"), link)
        self.assertIsNone(helper.valid_pane({"socket": link, "id": "%1"}))

    def test_main_dispatch_echoes_id_on_bad_pane(self):
        out = io.StringIO()
        req = json.dumps({"cmd": "paste", "id": 9, "pane": {"socket": "/x", "id": "%1"},
                          "text": "a"}) + "\n"
        helper.main(stdin=io.StringIO(req), stdout=out)
        self.assertEqual(json.loads(out.getvalue()),
                         {"ok": False, "error": "bad pane", "id": 9})



class EventSink(object):
    """Collects what a relay sends its Mac, from any thread.

    Works as an emit callable for HookRelay and as a stdout stream for main.
    While `gate` is an unset Event, every emit blocks on it, which proves an
    answer reached the client before anything was forwarded.
    """

    def __init__(self):
        self.events = []
        self.cond = threading.Condition()
        self.gate = None
        self.partial = ""

    def __call__(self, obj):
        gate = self.gate
        if gate is not None:
            gate.wait(5)
        with self.cond:
            self.events.append(obj)
            self.cond.notify_all()

    def write(self, text):
        with self.cond:
            self.partial += text
            while "\n" in self.partial:
                line, self.partial = self.partial.split("\n", 1)
                if line.strip():
                    self.events.append(json.loads(line))
            self.cond.notify_all()

    def flush(self):
        pass

    def wait_for(self, predicate, timeout=3):
        with self.cond:
            self.cond.wait_for(
                lambda: any(predicate(e) for e in self.events), timeout)
            for event in self.events:
                if predicate(event):
                    return event
        return None

    def matching(self, predicate):
        with self.cond:
            return [e for e in self.events if predicate(e)]


def is_hook(path):
    return lambda e: e.get("event") == "hook" and e.get("path") == path


def is_resolved(rid):
    return lambda e: e.get("event") == "hook_resolved" and e.get("rid") == rid


def wait_until(predicate, timeout=3):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.01)
    return predicate()


def post_hook(home, event, body=None, account=None, raw=None):
    """Opens a hook request the way the bridge's curl does, and returns the
    socket with the request sent, so a test can decide when to read."""
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(5)
    client.connect(os.path.join(home, ".swarmbar", "hook.sock"))
    data = raw if raw is not None else json.dumps(body or {}).encode("utf-8")
    head = ("POST /hook/%s HTTP/1.1\r\nHost: swarmbar\r\n"
            "Content-Type: application/json\r\nContent-Length: %d\r\n"
            % (event, len(data)))
    if account is not None:
        head += "X-Claude-Account: %s\r\n" % account
    client.sendall(head.encode("ascii") + b"\r\n" + data)
    return client


def read_response(client, timeout=3):
    """(status line, headers, parsed body) by Content-Length, so it never
    waits for the server to close; or None when the connection closed with
    no response at all."""
    client.settimeout(timeout)
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = client.recv(65536)
        if not chunk:
            return None if not data else ("partial", {}, None)
        data += chunk
    head, rest = data.split(b"\r\n\r\n", 1)
    lines = head.decode("latin-1").split("\r\n")
    headers = {}
    for line in lines[1:]:
        name, _, value = line.partition(":")
        headers[name.strip().lower()] = value.strip()
    length = int(headers.get("content-length", "0"))
    while len(rest) < length:
        chunk = client.recv(65536)
        if not chunk:
            break
        rest += chunk
    return lines[0], headers, json.loads(rest[:length].decode("utf-8"))


def answered_within(client, seconds):
    readable, _, _ = select.select([client], [], [], seconds)
    return bool(readable)


def connection_dropped(client, timeout=3):
    """True when the server closed the connection without a byte of answer."""
    client.settimeout(timeout)
    try:
        return client.recv(65536) == b""
    except ConnectionResetError:
        return True


class HookRelayTests(unittest.TestCase):
    """The per-user hook socket, the broker and the Grok interlock.

    Each test runs real servers in-process on a temp home under /tmp (macOS
    caps a socket path near 104 bytes) and replaces peer_chain, so no real
    process is ever inspected.
    """

    DECISION = {"hookSpecificOutput": {"hookEventName": "PermissionRequest",
                                       "decision": {"behavior": "allow"}}}

    def setUp(self):
        self.home = os.path.realpath(tempfile.mkdtemp(dir="/tmp", prefix="sbh-"))
        self.bridge_dir = os.path.join(self.home, ".swarmbar")
        os.makedirs(self.bridge_dir)
        open(os.path.join(self.bridge_dir, "swarmbar-remote-hook.sh"), "w").close()
        self.sock_path = os.path.join(self.bridge_dir, "hook.sock")
        self.peer = ["curl", "bash", "claude"]
        self.patches = [
            mock.patch.dict(os.environ, {"SWARMBAR_HELPER_HOMES": self.home}),
            mock.patch.object(helper, "LOCK_RETRY_SECONDS", 0.05),
            mock.patch.object(helper, "SERVE_POLL_SECONDS", 0.05),
            mock.patch.object(helper, "HOLD_POLL_SECONDS", 0.05),
            mock.patch.object(helper, "peer_chain", side_effect=self.fake_peer),
            mock.patch.object(helper, "peer_uid", side_effect=lambda sock: os.getuid(),
                              create=True),
            mock.patch.object(helper, "agent_processes", return_value=[]),
        ]
        self.addCleanup(shutil.rmtree, self.home, True)
        for patch in self.patches:
            patch.start()
            self.addCleanup(patch.stop)
        self.peer_mock = helper.peer_chain
        self.relays = []
        self.clients = []

    def tearDown(self):
        for client in self.clients:
            client.close()
        for relay in self.relays:
            relay.close()

    def fake_peer(self, sock):
        if isinstance(self.peer, Exception):
            raise self.peer
        return list(self.peer)

    def relay(self, sink=None):
        sink = sink if sink is not None else EventSink()
        relay = helper.HookRelay(emit=sink)
        self.relays.append(relay)
        relay.refresh()
        return relay, sink

    def post(self, event, body=None, **kwargs):
        client = post_hook(self.home, event, body, **kwargs)
        self.clients.append(client)
        return client

    def hub(self, relay):
        return relay.hubs[self.home]

    def test_non_held_event_answers_immediately(self):
        relay, sink = self.relay()
        sink.gate = threading.Event()
        client = self.post("Stop", {"session_id": "s1"}, account="work")
        # The emit is blocked, so the answer cannot be waiting on the Mac.
        status, headers, body = read_response(client, timeout=2)
        self.assertEqual(status, "HTTP/1.1 200 OK")
        self.assertEqual(headers["content-type"], "application/json")
        self.assertEqual(body, {})
        sink.gate.set()
        event = sink.wait_for(is_hook("/hook/Stop"))
        self.assertIsNotNone(event)
        self.assertRegex(event["rid"], r"^[0-9a-f]{32}$")
        self.assertEqual(event["home"], self.home)
        self.assertEqual(event["account"], "work")
        self.assertEqual(event["peer"], [])
        self.assertEqual(event["body"], {"session_id": "s1"})
        self.assertIs(event["held"], False)
        self.assertIn("user", event)
        self.assertEqual(sink.matching(lambda e: e.get("event") == "hook_resolved"), [])

    def test_empty_account_header_is_null(self):
        relay, sink = self.relay()
        read_response(self.post("Stop", {}, account=""))
        self.assertIsNone(sink.wait_for(is_hook("/hook/Stop"))["account"])

    def test_claude_permission_is_held_until_reply(self):
        relay, sink = self.relay()
        client = self.post("PermissionRequest", {"session_id": "s1", "tool_name": "Bash"})
        event = sink.wait_for(is_hook("/hook/PermissionRequest"))
        self.assertIsNotNone(event)
        self.assertIs(event["held"], True)
        self.assertFalse(answered_within(client, 0.2))
        self.assertEqual(relay.handle_reply({"rid": event["rid"], "body": self.DECISION}),
                         {"ok": True})
        _, _, body = read_response(client)
        self.assertEqual(body, self.DECISION)
        self.assertIsNotNone(sink.wait_for(is_resolved(event["rid"])))

    def test_open_code_permission_is_held_whatever_the_peer(self):
        self.peer = []
        relay, sink = self.relay()
        client = self.post("OpenCodePermission", {"id": "per_1"})
        event = sink.wait_for(is_hook("/hook/OpenCodePermission"))
        self.assertFalse(answered_within(client, 0.2))
        relay.handle_reply({"rid": event["rid"], "body": {"reply": "once"}})
        self.assertEqual(read_response(client)[2], {"reply": "once"})

    def test_grok_peer_is_answered_immediately(self):
        # Grok 0.2.118 treats a hook timeout as consent, so a held Grok
        # request is an approved one. Grok nested inside a Claude session
        # is the case most likely to slip through, so it is pinned too.
        relay, sink = self.relay()
        for peer in (["curl", "bash", "grok"],
                     ["curl", "sh", "grok", "bash", "claude", "tmux: server"]):
            self.peer = peer
            sink.gate = threading.Event()
            client = self.post("PermissionRequest", {"session_id": "g1"})
            self.assertEqual(read_response(client, timeout=1)[2], {})
            sink.gate.set()
            event = sink.wait_for(lambda e: e.get("event") == "hook" and e["peer"] == peer)
            self.assertIsNotNone(event)
            self.assertIs(event["held"], False)
            self.assertEqual(sink.matching(is_resolved(event["rid"])), [])
            self.assertEqual(self.hub(relay).pending, {})

    def test_unknown_peer_is_answered_immediately(self):
        relay, sink = self.relay()
        for peer in ([], ["curl", "bash"], ["curl", "bash", "codex"],
                     ["curl", "bash", "Claude"], OSError("no peer")):
            self.peer = peer
            sink.gate = threading.Event()
            client = self.post("PermissionRequest", {"session_id": "u1"})
            self.assertEqual(read_response(client, timeout=1)[2], {}, peer)
            sink.gate.set()
        self.assertEqual(self.hub(relay).pending, {})

    def test_oversized_body_is_answered_and_not_forwarded(self):
        relay, sink = self.relay()
        raw = json.dumps({"marker": "big", "pad": "x" * helper.MAX_HOOK_BODY}).encode()
        self.assertEqual(read_response(self.post("PermissionRequest", raw=raw))[2], {})
        self.assertEqual(read_response(self.post("Stop", {"marker": "small"}))[2], {})
        self.assertIsNotNone(sink.wait_for(is_hook("/hook/Stop")))
        self.assertEqual(len(sink.matching(lambda e: e.get("event") == "hook")), 1)

    def test_hold_times_out_with_an_empty_answer(self):
        relay, sink = self.relay()
        with mock.patch.object(helper, "HOLD_SECONDS", 0.3):
            client = self.post("PermissionRequest", {"session_id": "s1"})
            event = sink.wait_for(is_hook("/hook/PermissionRequest"))
            self.assertEqual(read_response(client)[2], {})
            self.assertIsNotNone(sink.wait_for(is_resolved(event["rid"])))

    def test_client_that_leaves_resolves_the_hold(self):
        relay, sink = self.relay()
        client = self.post("PermissionRequest", {"session_id": "s1"})
        event = sink.wait_for(is_hook("/hook/PermissionRequest"))
        client.close()
        self.assertIsNotNone(sink.wait_for(is_resolved(event["rid"])))
        self.assertEqual(self.hub(relay).pending, {})

    def test_follower_receives_and_first_reply_wins(self):
        owner, owner_sink = self.relay()
        follower, follower_sink = self.relay()
        self.assertEqual(self.hub(owner).role, "owner")
        self.assertEqual(self.hub(follower).role, "follower")
        self.assertTrue(wait_until(lambda: self.hub(owner).follower_count() == 1))
        client = self.post("PermissionRequest", {"session_id": "s1"})
        first = owner_sink.wait_for(is_hook("/hook/PermissionRequest"))
        relayed = follower_sink.wait_for(is_hook("/hook/PermissionRequest"))
        self.assertIsNotNone(relayed)
        self.assertEqual(relayed, first)
        decision = {"hookSpecificOutput": {"decision": {"behavior": "deny"}}}
        self.assertEqual(follower.handle_reply({"rid": first["rid"], "body": decision}),
                         {"ok": True})
        self.assertEqual(read_response(client)[2], decision)
        # The slower Mac's answer arrives after the first one won.
        self.assertEqual(owner.handle_reply({"rid": first["rid"], "body": self.DECISION}),
                         {"ok": True})
        self.assertIsNotNone(owner_sink.wait_for(is_resolved(first["rid"])))
        self.assertIsNotNone(follower_sink.wait_for(is_resolved(first["rid"])))

    def test_follower_takes_over_when_owner_exits(self):
        owner, owner_sink = self.relay()
        follower, follower_sink = self.relay()
        self.assertTrue(wait_until(lambda: self.hub(owner).follower_count() == 1))
        held = self.post("PermissionRequest", {"session_id": "s1"})
        event = follower_sink.wait_for(is_hook("/hook/PermissionRequest"))
        self.assertIsNotNone(event)
        owner.close()
        # The held request is lost: no decision, and the follower's Mac is
        # told so its row does not wait on a request nobody can answer.
        self.assertTrue(connection_dropped(held))
        self.assertIsNotNone(follower_sink.wait_for(is_resolved(event["rid"])))
        self.assertTrue(wait_until(lambda: self.hub(follower).role == "owner"))
        self.assertEqual(read_response(self.post("Stop", {"after": 1}))[2], {})
        self.assertIsNotNone(follower_sink.wait_for(is_hook("/hook/Stop")))
        self.assertEqual(owner_sink.matching(is_hook("/hook/Stop")), [])

    def test_stdin_eof_drops_held_request(self):
        read_fd, write_fd = os.pipe()
        stdin = os.fdopen(read_fd, "r")
        writer = os.fdopen(write_fd, "w")
        sink = EventSink()
        previous = helper._OUT
        thread = threading.Thread(target=helper.main, args=(stdin, sink))
        thread.start()
        try:
            self.assertTrue(wait_until(lambda: os.path.exists(self.sock_path)))
            client = self.post("PermissionRequest", {"session_id": "s1"})
            self.assertIsNotNone(sink.wait_for(is_hook("/hook/PermissionRequest")))
            writer.write(json.dumps({"id": 5, "cmd": "hook_reply", "rid": "elsewhere",
                                     "body": {}}) + "\n")
            writer.flush()
            self.assertEqual(sink.wait_for(lambda e: e.get("id") == 5),
                             {"ok": True, "id": 5})
            writer.close()
            thread.join(3)
            self.assertFalse(thread.is_alive())
            self.assertTrue(connection_dropped(client))
            self.assertFalse(os.path.exists(self.sock_path))
            # The lock is free for the next helper.
            import fcntl
            fd = os.open(os.path.join(self.bridge_dir, "hook.lock"), os.O_RDWR)
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            finally:
                os.close(fd)
        finally:
            if not writer.closed:
                writer.close()
            thread.join(3)
            stdin.close()
            helper._OUT = previous

    def test_snapshot_starts_servers_for_new_hook_homes(self):
        os.remove(os.path.join(self.bridge_dir, "swarmbar-remote-hook.sh"))
        read_fd, write_fd = os.pipe()
        stdin = os.fdopen(read_fd, "r")
        writer = os.fdopen(write_fd, "w")
        sink = EventSink()
        previous = helper._OUT
        thread = threading.Thread(target=helper.main, args=(stdin, sink))
        thread.start()
        try:
            writer.write(json.dumps({"id": 1, "cmd": "ping"}) + "\n")
            writer.flush()
            self.assertIsNotNone(sink.wait_for(lambda e: e.get("id") == 1))
            self.assertFalse(os.path.exists(self.sock_path))
            plugins = os.path.join(self.home, ".config", "opencode", "plugins")
            os.makedirs(plugins)
            open(os.path.join(plugins, "swarmbar-remote.js"), "w").close()
            writer.write(json.dumps({"id": 2, "cmd": "snapshot"}) + "\n")
            writer.flush()
            self.assertIsNotNone(sink.wait_for(lambda e: e.get("id") == 2))
            self.assertTrue(os.path.exists(self.sock_path))
        finally:
            writer.close()
            thread.join(3)
            stdin.close()
            helper._OUT = previous

    def test_socket_mode_is_600(self):
        relay, _ = self.relay()
        for name in ("hook.sock", "broker.sock"):
            info = os.lstat(os.path.join(self.bridge_dir, name))
            self.assertTrue(stat.S_ISSOCK(info.st_mode), name)
            self.assertEqual(stat.S_IMODE(info.st_mode), 0o600, name)
        self.assertEqual(stat.S_IMODE(os.lstat(self.bridge_dir).st_mode), 0o700)


    # Review round 1

    def hold_one(self, relay, sink, body=None):
        body = body or {"session_id": "s1"}
        client = self.post("PermissionRequest", body)
        event = sink.wait_for(lambda e: is_hook("/hook/PermissionRequest")(e)
                              and e["body"] == body)
        self.assertIsNotNone(event)
        return client, event

    def test_step_child_setup_serves_and_follows(self):
        # As root each home step runs in a child started as the owner. Run
        # as an ordinary user here the child keeps this uid, but the child
        # and the descriptors passed back are the real thing.
        with mock.patch.object(helper, "STEP_CHILD", True):
            owner, owner_sink = self.relay()
            follower, follower_sink = self.relay()
            self.assertEqual(self.hub(owner).role, "owner")
            self.assertTrue(wait_until(lambda: self.hub(owner).follower_count() == 1))
            self.assertEqual(read_response(self.post("Stop", {"n": 1}))[2], {})
            client, event = self.hold_one(owner, owner_sink)
            self.assertIsNotNone(follower_sink.wait_for(is_hook("/hook/PermissionRequest")))
            follower.handle_reply({"rid": event["rid"], "body": self.DECISION})
            self.assertEqual(read_response(client)[2], self.DECISION)
            info = os.lstat(self.sock_path)
            self.assertEqual(stat.S_IMODE(info.st_mode), 0o600)

    def test_source_never_changes_ownership(self):
        with open(helper.__file__) as handle:
            source = handle.read()
        self.assertNotRegex(source, r"chown\s*\(")
        # A fork of a threaded process can deadlock in the child, and python
        # 3.12 warns about it on stderr, which the Mac reads as the failure.
        self.assertNotRegex(source, r"os\.fork\s*\(")

    def test_step_children_print_nothing(self):
        # The real script, twice, as owner and follower, with the step
        # children switched on as they are under root.
        env = dict(os.environ, SWARMBAR_HELPER_HOMES=self.home, SWARMBAR_HELPER_STEP_CHILD="1")
        script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "swarmbar-helper.py")
        procs, sinks, readers = [], [], []
        try:
            for _ in range(2):
                proc = subprocess.Popen(
                    [sys.executable, script], env=env, stdin=subprocess.PIPE,
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                sink = EventSink()
                reader = threading.Thread(
                    target=lambda p=proc, k=sink: [k.write(line.decode()) for line in p.stdout])
                reader.start()
                procs.append(proc)
                sinks.append(sink)
                readers.append(reader)
                self.assertTrue(wait_until(lambda: os.path.exists(self.sock_path)))
            # Posts until the follower, connected through its own step
            # child, has relayed one.
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline and not sinks[1].matching(is_hook("/hook/Stop")):
                self.assertEqual(read_response(self.post("Stop", {}))[2], {})
                time.sleep(0.05)
            for sink in sinks:
                self.assertTrue(sink.matching(is_hook("/hook/Stop")))
            errors = []
            for proc in procs:
                proc.stdin.close()
                errors.append(proc.stderr.read())
                proc.wait(10)
        finally:
            for proc in procs:
                if proc.poll() is None:
                    proc.kill()
                    proc.wait()
            for reader in readers:
                reader.join(5)
            for proc in procs:
                proc.stdout.close()
                proc.stderr.close()
        self.assertEqual(errors, [b"", b""])

    def test_hardlinked_lock_is_refused_and_never_chowned(self):
        target = os.path.join(self.home, "someone-elses-file")
        with open(target, "w") as handle:
            handle.write("keep")
        os.link(target, os.path.join(self.bridge_dir, "hook.lock"))
        refuse = mock.Mock(side_effect=AssertionError("ownership changed"))
        for child in (False, True):
            with mock.patch.object(helper, "STEP_CHILD", child), \
                    mock.patch.object(os, "chown", refuse), \
                    mock.patch.object(os, "fchown", refuse), \
                    mock.patch.object(os, "lchown", refuse):
                relay = helper.HookRelay(emit=EventSink())
                self.relays.append(relay)
                warnings = relay.refresh()
            self.assertTrue(any("hook.lock" in w for w in warnings), warnings)
            self.assertFalse(os.path.exists(self.sock_path))
        refuse.assert_not_called()
        self.assertEqual(os.stat(target).st_nlink, 2)

    def test_symlinked_bridge_dir_is_refused(self):
        elsewhere = os.path.join(self.home, "elsewhere")
        os.rename(self.bridge_dir, elsewhere)
        os.symlink(elsewhere, self.bridge_dir)
        relay = helper.HookRelay(emit=EventSink())
        self.relays.append(relay)
        warnings = relay.refresh()
        self.assertEqual(len(warnings), 1, warnings)
        self.assertFalse(os.path.exists(os.path.join(elsewhere, "hook.sock")))
        self.assertFalse(os.path.exists(os.path.join(elsewhere, "hook.lock")))

    def test_bridge_dir_owned_by_another_uid_is_refused(self):
        real_fstat = os.fstat

        def fstat(fd):
            info = real_fstat(fd)
            if stat.S_ISDIR(info.st_mode):
                values = list(info)
                values[stat.ST_UID] = info.st_uid + 4242
                return os.stat_result(values)
            return info
        with mock.patch.object(os, "fstat", side_effect=fstat):
            relay = helper.HookRelay(emit=EventSink())
            self.relays.append(relay)
            warnings = relay.refresh()
        self.assertTrue(any("another owner" in w for w in warnings), warnings)
        self.assertFalse(os.path.exists(self.sock_path))

    def test_blocked_mac_never_stalls_requests_or_followers(self):
        gate = threading.Event()
        self.addCleanup(gate.set)
        blocked = EventSink()
        blocked.gate = gate
        owner, _ = self.relay(blocked)
        follower, follower_sink = self.relay()
        self.assertTrue(wait_until(lambda: self.hub(owner).follower_count() == 1))
        # The owner's stdout is stuck from the first event on.
        self.assertEqual(read_response(self.post("Stop", {"n": 1}), timeout=2)[2], {})
        client = self.post("PermissionRequest", {"session_id": "s1"})
        event = follower_sink.wait_for(is_hook("/hook/PermissionRequest"))
        self.assertIsNotNone(event)
        self.assertEqual(read_response(self.post("Stop", {"n": 2}), timeout=2)[2], {})
        started = time.monotonic()
        self.assertEqual(owner.handle_reply({"rid": "unknown", "body": {}}), {"ok": True})
        self.assertLess(time.monotonic() - started, 0.5)
        follower.handle_reply({"rid": event["rid"], "body": self.DECISION})
        self.assertEqual(read_response(client, timeout=2)[2], self.DECISION)

    def test_events_a_stuck_mac_cannot_take_are_dropped_and_counted(self):
        gate = threading.Event()
        self.addCleanup(gate.set)
        blocked = EventSink()
        blocked.gate = gate
        with mock.patch.object(helper, "EMIT_QUEUE_SIZE", 2):
            relay, _ = self.relay(blocked)
        for n in range(6):
            self.assertEqual(read_response(self.post("Stop", {"n": n}), timeout=2)[2], {})
        warnings = relay.refresh()
        self.assertTrue(any("dropped" in w for w in warnings), warnings)

    def put_grok(self, relative, text):
        path = os.path.join(self.home, ".grok", relative)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as handle:
            handle.write(text)

    def assert_answered_at_once(self, relay, sink, body):
        sink.gate = threading.Event()
        client = self.post("PermissionRequest", body)
        self.assertEqual(read_response(client, timeout=2)[2], {}, body)
        sink.gate.set()
        self.assertEqual(self.hub(relay).pending, {})

    def test_session_in_grok_active_sessions_is_never_held(self):
        relay, sink = self.relay()
        shapes = [
            ["g-bare"],
            [{"id": "g-id"}],
            [{"session_id": "g-snake"}],
            [{"sessionId": "g-camel"}],
            {"sessions": [{"sessionID": "g-upper"}]},
        ]
        for shape in shapes:
            self.put_grok("active_sessions.json", json.dumps(shape))
            sid = json.dumps(shape).split('"')[-2]
            self.assert_answered_at_once(relay, sink, {"session_id": sid})
        # A session the file does not name is still held.
        client, event = self.hold_one(relay, sink, {"session_id": "claude-1"})
        relay.handle_reply({"rid": event["rid"], "body": self.DECISION})
        self.assertEqual(read_response(client)[2], self.DECISION)

    def test_unseen_hold_is_answered_at_once(self):
        # This helper's Mac cannot take the event and nobody follows, so no
        # one can answer: waiting out the hold would only stall the agent.
        gate = threading.Event()
        self.addCleanup(gate.set)
        blocked = EventSink()
        blocked.gate = gate
        with mock.patch.object(helper, "EMIT_QUEUE_SIZE", 1):
            relay, _ = self.relay(blocked)
        read_response(self.post("Stop", {"n": 1}))
        self.assertTrue(wait_until(lambda: relay.queue.qsize() == 0))
        read_response(self.post("Stop", {"n": 2}))
        self.assertTrue(wait_until(lambda: relay.queue.qsize() == 1))
        client = self.post("PermissionRequest", {"session_id": "s1"})
        self.assertEqual(read_response(client, timeout=2)[2], {})
        self.assertEqual(self.hub(relay).pending, {})

    def test_session_named_by_any_grok_session_entry_is_never_held(self):
        path = os.path.join(self.home, ".grok", "sessions", "cwd-x", "g-file")
        os.makedirs(os.path.dirname(path))
        open(path, "w").close()
        relay, sink = self.relay()
        self.assert_answered_at_once(relay, sink, {"session_id": "g-file"})

    def test_session_with_a_grok_session_dir_is_never_held(self):
        os.makedirs(os.path.join(self.home, ".grok", "sessions", "cwd-x", "g-dir"))
        relay, sink = self.relay()
        self.assert_answered_at_once(relay, sink, {"session_id": "g-dir"})
        self.assertIs(sink.wait_for(is_hook("/hook/PermissionRequest"))["held"], False)

    def test_unreadable_or_missing_session_id_is_never_held(self):
        relay, sink = self.relay()
        for body in ({}, {"session_id": 7}, {"session_id": "../x"}, {"session_id": ""}):
            self.assert_answered_at_once(relay, sink, body)
        self.put_grok("active_sessions.json", "{not json")
        self.assert_answered_at_once(relay, sink, {"session_id": "s1"})

    def test_nearest_agent_must_be_claude(self):
        relay, sink = self.relay()
        for peer in (["curl", "bash", "kimi", "bash", "claude"],
                     ["curl", "bash", "codex", "zsh", "claude"]):
            self.peer = peer
            self.assert_answered_at_once(relay, sink, {"session_id": "s1"})

    def test_slow_peer_lookup_is_answered_empty(self):
        release = threading.Event()
        self.addCleanup(release.set)
        self.peer_mock.side_effect = lambda sock: (release.wait(5), ["curl", "bash", "claude"])[1]
        relay, sink = self.relay()
        started = time.monotonic()
        client = self.post("PermissionRequest", {"session_id": "s1"})
        self.assertEqual(read_response(client, timeout=4)[2], {})
        self.assertLess(time.monotonic() - started, 2.2)
        self.assertEqual(sink.wait_for(is_hook("/hook/PermissionRequest"))["peer"], [])

    def test_only_permission_requests_look_up_the_peer(self):
        relay, sink = self.relay()
        for event in ("Stop", "PreToolUse", "Notification", "OpenCodePermission"):
            if event == "OpenCodePermission":
                client = self.post(event, {"id": "per_1"})
                held = sink.wait_for(is_hook("/hook/" + event))
                relay.handle_reply({"rid": held["rid"], "body": {}})
            else:
                client = self.post(event, {"session_id": "s1"})
            read_response(client)
        self.peer_mock.assert_not_called()

    def test_broker_peer_of_another_uid_is_turned_away(self):
        with mock.patch.object(helper, "peer_uid", return_value=os.getuid() + 4242):
            owner, _ = self.relay()
            follower, follower_sink = self.relay()
            time.sleep(0.3)
            self.assertEqual(self.hub(owner).follower_count(), 0)

    def test_new_follower_gets_open_holds_replayed(self):
        owner, owner_sink = self.relay()
        client, event = self.hold_one(owner, owner_sink)
        follower, follower_sink = self.relay()
        replayed = follower_sink.wait_for(is_hook("/hook/PermissionRequest"))
        self.assertEqual(replayed, event)
        self.assertIs(replayed["held"], True)
        follower.handle_reply({"rid": event["rid"], "body": self.DECISION})
        self.assertEqual(read_response(client)[2], self.DECISION)
        self.assertIsNotNone(follower_sink.wait_for(is_resolved(event["rid"])))

    def drop_followers(self, owner):
        hub = self.hub(owner)
        with hub.lock:
            conns = list(hub.followers)
        for conn in conns:
            helper.drop_connection(conn)

    def test_dropped_follower_keeps_rows_still_held(self):
        owner, owner_sink = self.relay()
        follower, follower_sink = self.relay()
        self.assertTrue(wait_until(lambda: self.hub(owner).follower_count() == 1))
        client, event = self.hold_one(owner, owner_sink)
        self.assertIsNotNone(follower_sink.wait_for(is_hook("/hook/PermissionRequest")))
        self.drop_followers(owner)
        self.assertTrue(wait_until(lambda: self.hub(owner).follower_count() == 0))
        self.assertTrue(wait_until(lambda: self.hub(owner).follower_count() == 1))
        time.sleep(0.1)
        self.assertEqual(follower_sink.matching(is_resolved(event["rid"])), [])
        self.assertEqual(len(follower_sink.matching(is_hook("/hook/PermissionRequest"))), 1)
        follower.handle_reply({"rid": event["rid"], "body": self.DECISION})
        self.assertEqual(read_response(client)[2], self.DECISION)

    def test_follower_clears_rows_resolved_while_away(self):
        with mock.patch.object(helper, "LOCK_RETRY_SECONDS", 0.3):
            owner, owner_sink = self.relay()
            follower, follower_sink = self.relay()
            self.assertTrue(wait_until(lambda: self.hub(owner).follower_count() == 1))
            client, event = self.hold_one(owner, owner_sink)
            self.assertIsNotNone(follower_sink.wait_for(is_hook("/hook/PermissionRequest")))
            self.drop_followers(owner)
            self.assertTrue(wait_until(lambda: self.hub(owner).follower_count() == 0))
            owner.handle_reply({"rid": event["rid"], "body": self.DECISION})
            self.assertEqual(read_response(client)[2], self.DECISION)
            self.assertIsNotNone(follower_sink.wait_for(is_resolved(event["rid"])))

    def test_holds_are_capped_per_home(self):
        with mock.patch.object(helper, "MAX_HOLDS", 1):
            relay, sink = self.relay()
            first, _ = self.hold_one(relay, sink, {"session_id": "s1"})
            second = self.post("PermissionRequest", {"session_id": "s2"})
            self.assertEqual(read_response(second, timeout=2)[2], {})
            overflow = sink.wait_for(
                lambda e: e.get("event") == "hook" and e["body"].get("session_id") == "s2")
            self.assertIs(overflow["held"], False)
            self.assertIs(sink.wait_for(
                lambda e: e.get("event") == "hook" and e["body"].get("session_id") == "s1")["held"],
                True)
            self.assertFalse(answered_within(first, 0.1))

    def test_non_object_bodies_are_answered_and_not_forwarded(self):
        relay, sink = self.relay()
        for raw in (b"[1, 2]", b'"text"', b"7", b"[" * 100000 + b"]" * 100000):
            self.assertEqual(read_response(self.post("Stop", raw=raw))[2], {}, raw[:10])
        self.assertEqual(read_response(self.post("Stop", {"last": 1}))[2], {})
        self.assertIsNotNone(sink.wait_for(is_hook("/hook/Stop")))
        self.assertEqual(len(sink.matching(lambda e: e.get("event") == "hook")), 1)
        self.assertIsNone(helper.parse_line(b"[" * 100000))


class PeerChainTests(unittest.TestCase):
    """peer_chain itself, against a fake process table."""

    def test_peer_chain_names_the_peer_and_its_ancestors(self):
        table = (
            "  900   800 curl            curl -s --unix-socket x\n"
            "  800   700 swarmbar-remote /bin/bash /home/u/.swarmbar/swarmbar-remote-hook.sh Stop\n"
            "  700   600 /Users/u/.loc   /Users/u/.local/bin/claude --resume\n"
            "  600   500 -bash           -bash\n"
            "  500   400 tmux: server    tmux\n"
            "  400   400 /Applications/Te /Applications/Terminal.app/Contents/MacOS/Terminal\n"
        )
        runner = FakeRunner(ps=table)
        with mock.patch.object(helper, "run_command", side_effect=runner), \
                mock.patch.object(helper, "peer_pid", return_value=900):
            chain = helper.peer_chain(None)
        self.assertEqual(chain, ["curl", "swarmbar-remote", "claude", "bash", "tmux:", "Terminal"])
        self.assertEqual(runner.calls[0][:2], ["ps", "-axo"])

    def test_peer_uid_of_a_socketpair_is_ours(self):
        left, right = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            self.assertEqual(helper.peer_uid(left), os.getuid())
        finally:
            left.close()
            right.close()

    def test_peer_chain_is_bounded_and_fails_empty(self):
        rows = "".join("%5d %5d sh sh\n" % (pid, pid + 1) for pid in range(100, 130))
        with mock.patch.object(helper, "run_command", side_effect=FakeRunner(ps=rows)), \
                mock.patch.object(helper, "peer_pid", return_value=100):
            self.assertEqual(len(helper.peer_chain(None)), helper.PEER_DEPTH)
        with mock.patch.object(helper, "run_command", side_effect=FakeRunner(ps_code=1)), \
                mock.patch.object(helper, "peer_pid", return_value=100):
            self.assertEqual(helper.peer_chain(None), [])
        with mock.patch.object(helper, "peer_pid", return_value=None):
            self.assertEqual(helper.peer_chain(None), [])


FAKE_PS = """#!/bin/sh
# Stands in for ps in the probe's own process: one synthetic claude.
echo "  4242     1 $(id -u) someone  ttys001  claude  claude --resume s1"
"""

FAKE_FAIL = """#!/bin/sh
exit 1
"""


def tree_state(root):
    """Every path under root with its size, mode and mtime, links unfollowed.
    The probe passes only if this is identical before and after it runs."""
    state = {}
    for directory, names, files in os.walk(root):
        for name in sorted(names + files):
            path = os.path.join(directory, name)
            info = os.lstat(path)
            state[os.path.relpath(path, root)] = (info.st_size, info.st_mode, info.st_mtime_ns)
    return state


class ProbeTests(unittest.TestCase):
    """`python3 - probe` reports and never changes anything on the host."""

    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="swarmbar-probe-test-")
        self.addCleanup(shutil.rmtree, self.root, True)
        self.home = os.path.join(self.root, "home", "u")
        os.makedirs(self.home)
        self.env = mock.patch.dict(os.environ, {"SWARMBAR_HELPER_HOMES": self.home})
        self.env.start()
        self.addCleanup(self.env.stop)

    def put(self, relative, text, mode=0o644):
        path = os.path.join(self.home, relative)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as handle:
            handle.write(text)
        os.chmod(path, mode)
        return path

    def probe(self, runner=None):
        with mock.patch.object(helper, "run_command", runner or FakeRunner(ps="")):
            return helper.probe()

    def populate(self):
        """A home with every kind of thing the probe looks at, including the
        bridge files that make main() set up a hook socket."""
        self.put(".claude/projects/-home-u-work/s1.jsonl", '{"type":"user"}\n')
        self.put(".claude/settings.json", '{"hooks": {"Stop": "swarmbar-remote-hook.sh"}}\n')
        self.put(".kimi-code/config.toml", "[providers]\n")
        self.put(".codex/sessions/2026/01/01/rollout-a.jsonl", "{}\n")
        self.put(".swarmbar/swarmbar-remote-hook.sh", "#!/bin/sh\n", 0o700)
        self.put(".swarmbar/swarmbar-helper", "# helper\n", 0o700)
        self.put(".config/opencode/plugins/swarmbar-remote.js", "// plugin\n")

    def test_probe_writes_nothing(self):
        self.populate()
        bin_dir = os.path.join(self.root, "bin")
        os.makedirs(bin_dir)
        for name, text in (("ps", FAKE_PS), ("sudo", FAKE_FAIL), ("tmux", FAKE_FAIL),
                           ("lsof", FAKE_FAIL)):
            path = os.path.join(bin_dir, name)
            with open(path, "w") as handle:
                handle.write(text)
            os.chmod(path, 0o755)
        script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "swarmbar-helper.py")
        with open(script, "rb") as handle:
            source = handle.read()
        env = dict(os.environ, SWARMBAR_HELPER_HOMES=self.home, HOME=self.home,
                   PATH=bin_dir + os.pathsep + os.environ.get("PATH", ""))
        before = tree_state(self.root)
        # The Mac's exact argv. -B matters: Apple's python 3.9 otherwise
        # caches its startup modules' bytecode under ~/Library/Caches before
        # the first line of the helper runs.
        done = subprocess.run([sys.executable, "-B", "-", "probe"], input=source, env=env,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(done.stderr, b"")
        after = tree_state(self.root)
        self.assertEqual(sorted(set(after) ^ set(before)), [])
        self.assertEqual(after, before)
        lines = done.stdout.decode().splitlines()
        self.assertEqual(len(lines), 1)
        result = json.loads(lines[0])
        self.assertTrue(result["ok"])
        self.assertFalse(result["sudo_ok"])
        self.assertEqual([p["comm"] for p in result["processes"]], ["claude"])
        self.assertNotIn("screen", result["processes"][0])
        self.assertIn("claude", result["installed"][self.home])

    def test_probe_reports_configs_with_hash(self):
        text = '{"hooks": {}}\n'
        path = self.put(".claude/settings.json", text)
        big = self.put(".config/opencode/opencode.json", "x" * (256 * 1024 + 1))
        self.put(".bearcode/config.toml", "[hooks]\n")
        configs = self.probe()["configs"][self.home]
        by_path = dict((c["path"], c) for c in configs)
        claude = by_path[os.path.realpath(path)]
        self.assertEqual(claude["tool"], "claude")
        self.assertEqual(claude["sha256"], hashlib.sha256(text.encode()).hexdigest())
        self.assertEqual(claude["text"], text)
        oversized = by_path[os.path.realpath(big)]
        self.assertEqual(oversized["tool"], "opencode")
        self.assertIsNone(oversized["text"])
        with open(big, "rb") as handle:
            self.assertEqual(oversized["sha256"], hashlib.sha256(handle.read()).hexdigest())
        self.assertEqual(by_path[os.path.realpath(
            os.path.join(self.home, ".bearcode/config.toml"))]["tool"], "bearcode")
        # Bridge scripts are allowlisted for writing but are not configs.
        self.put(".swarmbar/swarmbar-remote-hook.sh", "#!/bin/sh\n")
        tools = [c["tool"] for c in self.probe()["configs"][self.home]]
        self.assertEqual(sorted(tools), ["bearcode", "claude", "opencode"])

    def test_probe_skips_backup_claude_roots(self):
        self.put(".claude/settings.json", "{}\n")
        self.put(".claude-cio.pre-symlink-backup/settings.json", "{}\n")
        self.put(".claude-cio.pre-symlink-backup/projects/p/s.jsonl", "{}\n")
        paths = [c["path"] for c in self.probe()["configs"][self.home]]
        self.assertEqual(paths, [os.path.realpath(os.path.join(self.home, ".claude/settings.json"))])

    def test_probe_dedupes_claude_settings_by_realpath(self):
        shared = self.put(".claude/settings.json", "{}\n")
        os.makedirs(os.path.join(self.home, ".claude-work"))
        os.symlink(shared, os.path.join(self.home, ".claude-work", "settings.json"))
        configs = self.probe()["configs"][self.home]
        self.assertEqual([c["path"] for c in configs], [os.path.realpath(shared)])

    def test_probe_reports_tools_present(self):
        self.put(".claude/projects/p/s.jsonl", "{}\n")
        self.put(".claude-old/projects/p/s.jsonl", "{}\n")
        self.put(".grok/active_sessions.json", "{}\n")
        self.put(".gemini/antigravity-cli/history.jsonl", "")
        self.put(".local/share/opencode/opencode.db", "")
        # A config dir with no projects is not Claude in use.
        self.put(".claude-empty/settings.json", "{}\n")
        tools = self.probe()["tools"][self.home]
        self.assertEqual(tools, ["claude", "opencode", "grok", "antigravity"])

    def test_probe_detects_installed_bridges(self):
        self.put(".claude/projects/p/s.jsonl", "{}\n")
        self.put(".claude/settings.json", '{"command": "~/.swarmbar/swarmbar-remote-hook.sh"}\n')
        self.put(".kimi-code/config.toml", 'command = "swarmbar-hook.sh"\n')
        self.put(".bearcode/config.toml", 'command = "swarmbar-remote-kimi-hook.sh"\n')
        self.put(".config/opencode/opencode.jsonc", '{"plugin": ["swarmbar-remote.js"]}\n')
        # Each bridge counts only once its script is there too.
        self.assertEqual(self.probe()["installed"][self.home], [])
        self.put(".swarmbar/swarmbar-remote-hook.sh", "#!/bin/sh\n")
        self.put(".swarmbar/swarmbar-remote-kimi-hook.sh", "#!/bin/sh\n")
        self.put(".config/opencode/plugins/swarmbar-remote.js", "// plugin\n")
        self.assertEqual(self.probe()["installed"][self.home], ["claude", "bearcode", "opencode"])

    def test_claude_counts_as_installed_only_in_every_root(self):
        self.put(".swarmbar/swarmbar-remote-hook.sh", "#!/bin/sh\n")
        self.put(".claude/projects/p/s.jsonl", "{}\n")
        self.put(".claude/settings.json", '"swarmbar-remote-hook.sh"\n')
        self.put(".claude-work/projects/p/s.jsonl", "{}\n")
        self.assertEqual(self.probe()["installed"][self.home], [])
        self.put(".claude-work/settings.json", '"swarmbar-remote-hook.sh"\n')
        self.assertEqual(self.probe()["installed"][self.home], ["claude"])

    def test_probe_sudo_ok_comes_from_sudo_n_true(self):
        class Sudo(FakeRunner):
            def __call__(self, argv, timeout=5):
                if argv[0] == "sudo":
                    self.calls.append((list(argv), timeout))
                    return completed(argv, 0, "")
                return FakeRunner.__call__(self, argv, timeout)
        runner = Sudo(ps="")
        self.assertTrue(self.probe(runner)["sudo_ok"])
        self.assertIn((["sudo", "-n", "true"], 5), runner.calls)
        self.assertFalse(self.probe(FakeRunner(ps=""))["sudo_ok"])
        with mock.patch.object(helper, "run_command",
                               side_effect=subprocess.TimeoutExpired("sudo", 5)):
            self.assertFalse(helper.probe()["sudo_ok"])

    def test_probe_never_captures_panes(self):
        runner = FakeRunner(ps="  700  1 1000 u pts/2 agy agy\n",
                            panes={"/tmp/tmux-1000/default": "%3 1\n"})
        with mock.patch.object(helper, "tmux_sockets", return_value=["/tmp/tmux-1000/default"]), \
                mock.patch.object(helper, "process_cwd", return_value="/work"):
            result = self.probe(runner)
        self.assertFalse(any("capture-pane" in call for call in runner.calls))
        self.assertEqual(result["processes"][0]["pane"],
                         {"socket": "/tmp/tmux-1000/default", "id": "%3"})
        self.assertNotIn("screen", result["processes"][0])
        self.assertFalse(result["processes_failed"])

    def test_probe_reports_failed_ps(self):
        result = self.probe(FakeRunner(ps_code=1))
        self.assertTrue(result["processes_failed"])
        self.assertEqual(result["processes"], [])

    def test_probe_hashes_installed_helpers(self):
        self.put(".swarmbar/swarmbar-helper", "# helper\n", 0o700)
        result = self.probe()
        mine = os.path.join(self.home, ".swarmbar", "swarmbar-helper")
        self.assertIn({"path": mine, "sha256": hashlib.sha256(b"# helper\n").hexdigest()},
                      result["helper"])

    def test_probe_identity_fields(self):
        result = self.probe()
        self.assertEqual(result["protocol"], helper.PROTOCOL_VERSION)
        self.assertEqual(result["euid"], os.geteuid())
        for key in ("system", "python", "hostname", "user"):
            self.assertIsInstance(result[key], str)
        self.assertEqual(result["homes"], [{"path": self.home, "user": helper.home_owner(self.home)[0]}])

    def test_unreadable_config_is_reported_not_dropped(self):
        path = self.put(".kimi-code/config.toml", "[hooks]\n")
        real_open = open

        def refusing(name, *args, **kwargs):
            if os.path.realpath(name) == os.path.realpath(path):
                raise PermissionError(13, "Permission denied")
            return real_open(name, *args, **kwargs)
        with mock.patch("builtins.open", side_effect=refusing):
            result = self.probe()
        self.assertEqual(result["configs"][self.home], [
            {"tool": "kimi", "path": os.path.realpath(path), "sha256": None, "text": None}])
        self.assertTrue(any("kimi" in w and path in w for w in result["warnings"]), result["warnings"])

    def test_unreadable_bridge_config_is_unknown_not_missing(self):
        self.put(".swarmbar/swarmbar-remote-kimi-hook.sh", "#!/bin/sh\n")
        path = self.put(".kimi-code/config.toml", 'command = "swarmbar-remote-kimi-hook.sh"\n')
        real_open = open

        def refusing(name, *args, **kwargs):
            if os.path.realpath(name) == os.path.realpath(path):
                raise PermissionError(13, "Permission denied")
            return real_open(name, *args, **kwargs)
        with mock.patch("builtins.open", side_effect=refusing):
            result = self.probe()
        self.assertEqual(result["installed"][self.home], [])
        self.assertEqual(result["installed_unknown"][self.home], ["kimi"])
        self.assertTrue(any("kimi" in w for w in result["warnings"]), result["warnings"])
        # Readable again, it is simply installed, and nothing is unknown.
        result = self.probe()
        self.assertEqual(result["installed"][self.home], ["kimi"])
        self.assertEqual(result["installed_unknown"][self.home], [])

    def test_probe_hashes_itself_only_when_run_from_a_file(self):
        script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "swarmbar-helper.py")
        with open(script, "rb") as handle:
            digest = hashlib.sha256(handle.read()).hexdigest()
        self.assertEqual(self.probe()["self_sha256"], digest)
        with mock.patch.object(helper, "__file__", "<stdin>"):
            self.assertIsNone(self.probe()["self_sha256"])

    def test_failed_probe_names_its_python(self):
        out = io.StringIO()
        with mock.patch.object(helper, "probe", side_effect=RuntimeError("boom")), \
                mock.patch.object(sys, "stdout", out):
            helper.probe_main()
        result = json.loads(out.getvalue())
        self.assertFalse(result["ok"])
        self.assertEqual(result["python"], helper.platform.python_version())
        self.assertIn("boom", result["error"])

    def test_probe_refuses_configs_not_the_home_owners_own(self):
        open_dir = self.put(".kimi-code/config.toml", "[hooks]\n")
        os.chmod(os.path.dirname(open_dir), 0o777)
        outside = os.path.join(self.root, "planted.json")
        with open(outside, "w") as handle:
            handle.write("PLANTED-BYTES\n")
        os.makedirs(os.path.join(self.home, ".config", "opencode"))
        os.symlink(outside, os.path.join(self.home, ".config", "opencode", "opencode.json"))
        theirs = os.path.realpath(self.put(".bearcode/config.toml", "PLANTED-BYTES\n"))
        real_lstat = os.lstat

        def owned_by_another(path, *args, **kwargs):
            info = real_lstat(path, *args, **kwargs)
            if path != theirs:
                return info
            values = list(tuple(info))
            values[4] = info.st_uid + 1
            return os.stat_result(values)
        with mock.patch.object(os, "lstat", owned_by_another):
            result = self.probe()
        by_tool = dict((c["tool"], c) for c in result["configs"][self.home])
        for tool in ("kimi", "opencode", "bearcode"):
            self.assertIsNone(by_tool[tool]["sha256"], tool)
            self.assertIsNone(by_tool[tool]["text"], tool)
        self.assertEqual(sum("refusing" in w for w in result["warnings"]), 3, result["warnings"])
        self.assertNotIn("PLANTED", json.dumps(result["configs"]))

    def test_bridge_check_refuses_a_config_that_is_not_the_owners_own(self):
        self.put(".swarmbar/swarmbar-remote-kimi-hook.sh", "#!/bin/sh\n")
        outside = os.path.join(self.root, "planted.toml")
        with open(outside, "w") as handle:
            handle.write('command = "swarmbar-remote-kimi-hook.sh"\n')
        os.makedirs(os.path.join(self.home, ".kimi-code"))
        os.symlink(outside, os.path.join(self.home, ".kimi-code", "config.toml"))
        real_open = open
        opened = []

        def watching(name, *args, **kwargs):
            opened.append(os.path.realpath(name) if isinstance(name, str) else name)
            return real_open(name, *args, **kwargs)
        with mock.patch("builtins.open", side_effect=watching):
            result = self.probe()
        self.assertNotIn(os.path.realpath(outside), opened)
        self.assertEqual(result["installed"][self.home], [])
        self.assertEqual(result["installed_unknown"][self.home], ["kimi"])
        self.assertTrue(any("cannot tell whether kimi" in w for w in result["warnings"]),
                        result["warnings"])

    def test_allowed_patterns(self):
        self.assertEqual(helper.ALLOWED, (
            ".claude*/settings.json",
            ".kimi-code/config.toml",
            ".bearcode/config.toml",
            ".config/opencode/opencode.json",
            ".config/opencode/opencode.jsonc",
            ".config/opencode/plugins/swarmbar-remote.js",
            ".swarmbar/swarmbar-remote-hook.sh",
            ".swarmbar/swarmbar-remote-kimi-hook.sh",
        ))


def sha(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def encoded(text):
    return base64.b64encode(text.encode("utf-8")).decode("ascii")


def apply_blob(operations, raw=False):
    """What the Mac puts on the apply command line: zlib, or the raw deflate
    that Foundation's .zlib produces, then base64."""
    data = json.dumps(operations).encode("utf-8")
    if raw:
        packer = zlib.compressobj(9, zlib.DEFLATED, -15)
        packed = packer.compress(data) + packer.flush()
    else:
        packed = zlib.compress(data)
    return base64.b64encode(packed).decode("ascii")


class OwnerWritableTests(unittest.TestCase):
    """only_owner_can_write: group write is the owner's own only through a
    user-private group, and other write never is."""

    UID, GID = 4100, 4100

    def info(self, mode, gid=None):
        values = [stat.S_IFDIR | mode, 1, 1, 2, self.UID, self.GID if gid is None else gid,
                  0, 0, 0, 0]
        return os.stat_result(values)

    def users(self, members=(), others=()):
        owner = mock.Mock(pw_name="u", pw_uid=self.UID, pw_gid=self.GID)
        group = mock.Mock(gr_mem=list(members))
        everyone = [owner] + [mock.Mock(pw_name=name, pw_uid=uid, pw_gid=gid)
                              for name, uid, gid in others]
        return (mock.patch("pwd.getpwuid", return_value=owner),
                mock.patch("pwd.getpwall", return_value=everyone),
                mock.patch("grp.getgrgid", return_value=group))

    def check(self, info, **users):
        patches = self.users(**users)
        with patches[0], patches[1], patches[2]:
            return helper.only_owner_can_write(info)

    def test_user_private_group_775_passes(self):
        self.assertTrue(self.check(self.info(0o775)))
        self.assertTrue(self.check(self.info(0o775), members=["u"]))
        self.assertTrue(self.check(self.info(0o755), members=["v"]))

    def test_group_with_another_member_is_refused(self):
        self.assertFalse(self.check(self.info(0o775), members=["u", "v"]))

    def test_another_users_primary_group_is_refused(self):
        self.assertFalse(self.check(self.info(0o775), others=[("v", 4200, self.GID)]))
        # Nor a group that is not the owner's primary one at all.
        self.assertFalse(self.check(self.info(0o775, gid=4300)))

    def test_other_writable_is_always_refused(self):
        self.assertFalse(self.check(self.info(0o1777)))
        self.assertFalse(self.check(self.info(0o757)))

    def test_upg_directories_pass_everywhere_the_rule_applies(self):
        # A real 775 tree under this user's own group, as Ubuntu's umask
        # 002 makes it: home rule, write walk and probe read all accept it
        # once the group reads as private, and refuse it when it does not.
        root = os.path.realpath(tempfile.mkdtemp(dir="/tmp", prefix="sbu-"))
        self.addCleanup(shutil.rmtree, root, True)
        home = os.path.join(root, "u")
        config = os.path.join(home, ".kimi-code", "config.toml")
        os.makedirs(os.path.dirname(config))
        with open(config, "w") as handle:
            handle.write("old\n")
        for directory in (home, os.path.dirname(config)):
            os.chmod(directory, 0o775)
        info = os.stat(home)
        owner = mock.Mock(pw_name="u", pw_uid=info.st_uid, pw_gid=info.st_gid, pw_dir=home)
        for members, ok in (([], True), (["someone"], False)):
            with mock.patch("pwd.getpwuid", return_value=owner), \
                    mock.patch("pwd.getpwall", return_value=[owner]), \
                    mock.patch("grp.getgrgid", return_value=mock.Mock(gr_mem=members)), \
                    mock.patch.dict(os.environ, {"SWARMBAR_HELPER_HOMES": home}):
                self.assertEqual(helper.owned_home(home), ok)
                warnings = []
                configs = helper.home_configs(home, warnings)
                self.assertEqual(configs[0]["sha256"] is not None, ok, warnings)
                result = helper.write_file({"path": config, "content_b64": encoded("new\n"),
                                            "expect_sha256": sha("old\n"), "mode": 0o644})
                self.assertEqual(result["ok"], ok, result)
        with open(config) as handle:
            self.assertEqual(handle.read(), "new\n")


class SetupWriteTests(unittest.TestCase):
    """write_file and remove_file: the allowlist, the precondition hash, the
    one-time backup, writes in place and restore on failure."""

    def setUp(self):
        self.root = os.path.realpath(tempfile.mkdtemp(dir="/tmp", prefix="sbw-"))
        self.addCleanup(shutil.rmtree, self.root, True)
        self.home = os.path.join(self.root, "u")
        os.makedirs(self.home)
        env = mock.patch.dict(os.environ, {"SWARMBAR_HELPER_HOMES": self.home})
        env.start()
        self.addCleanup(env.stop)

    def put(self, relative, text, mode=0o644):
        path = os.path.join(self.home, relative)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as handle:
            handle.write(text)
        os.chmod(path, mode)
        return path

    def read(self, path):
        with open(path) as handle:
            return handle.read()

    def write(self, path, text, expect, mode=0o644):
        return helper.write_file({"path": path, "content_b64": encoded(text),
                                  "expect_sha256": expect, "mode": mode})

    def test_write_refused_when_hash_differs(self):
        path = self.put(".claude/settings.json", '{"a": 1}\n')
        self.assertEqual(self.write(path, "{}\n", sha("something else")),
                         {"ok": False, "error": "changed"})
        # A file that is there when the plan expected none is changed too.
        self.assertEqual(self.write(path, "{}\n", "absent"), {"ok": False, "error": "changed"})
        self.assertEqual(self.read(path), '{"a": 1}\n')
        self.assertFalse(os.path.lexists(path + ".backup-swarmbar"))
        # And a file that is missing when the plan expected one.
        missing = os.path.join(self.home, ".kimi-code", "config.toml")
        self.assertEqual(self.write(missing, "x\n", sha("x\n")), {"ok": False, "error": "changed"})
        self.assertFalse(os.path.lexists(missing))

    def test_write_refused_outside_allowlist(self):
        refused = {"ok": False, "error": "not allowed"}
        settings = self.put(".claude/settings.json", "{}\n")
        # A ".." component, even one that resolves back onto an allowed file.
        dotted = os.path.join(self.home, ".claude", "..", ".claude", "settings.json")
        self.assertEqual(self.write(dotted, "x\n", sha("{}\n")), refused)
        # A symlink whose target leaves the home.
        outside = os.path.join(self.root, "outside.toml")
        with open(outside, "w") as handle:
            handle.write("keep\n")
        os.makedirs(os.path.join(self.home, ".kimi-code"))
        linked = os.path.join(self.home, ".kimi-code", "config.toml")
        os.symlink(outside, linked)
        self.assertEqual(self.write(linked, "x\n", sha("keep\n")), refused)
        self.assertEqual(self.read(outside), "keep\n")
        # Files the list does not name, in a home and out of one.
        bashrc = self.put(".bashrc", "keep\n")
        self.assertEqual(self.write(bashrc, "x\n", sha("keep\n")), refused)
        stray = os.path.join(self.root, ".claude", "settings.json")
        self.assertEqual(self.write(stray, "x\n", "absent"), refused)
        self.assertFalse(os.path.lexists(stray))
        for bad in ("relative/.claude/settings.json", settings + "\x00", "", None, 7):
            self.assertFalse(helper.write_file({"path": bad, "content_b64": encoded("x"),
                                                "expect_sha256": "absent", "mode": 0o644})["ok"])
        self.assertEqual(self.read(settings), "{}\n")
        self.assertEqual(self.read(bashrc), "keep\n")

    def test_symlink_inside_the_home_resolves_to_its_target(self):
        # A second profile linked to the first writes the shared file once.
        shared = self.put(".claude-work/settings.json", "{}\n")
        os.symlink(os.path.join(self.home, ".claude-work"), os.path.join(self.home, ".claude"))
        self.assertEqual(helper.allowed_target(os.path.join(self.home, ".claude", "settings.json")),
                         (self.home, shared))

    def test_backup_named_claude_root_is_refused(self):
        for name in (".claude-old", ".claude.pre-symlink-backup", ".claude.bak"):
            path = self.put(name + "/settings.json", "{}\n")
            self.assertIsNone(helper.allowed_target(path), name)
            self.assertEqual(self.write(path, "x\n", sha("{}\n")),
                             {"ok": False, "error": "not allowed"})
        live = self.put(".claude-work/settings.json", "{}\n")
        self.assertTrue(self.write(live, "x\n", sha("{}\n"))["written"])

    def test_backup_taken_once(self):
        path = self.put(".claude/settings.json", "one\n", 0o640)
        first = self.write(path, "two\n", sha("one\n"))
        self.assertEqual(first, {"ok": True, "written": True, "backup": path + ".backup-swarmbar"})
        second = self.write(path, "three\n", sha("two\n"))
        self.assertEqual(second["backup"], path + ".backup-swarmbar")
        self.assertEqual(self.read(path), "three\n")
        # The backup is the file as it was before SwarmBar first touched it.
        self.assertEqual(self.read(path + ".backup-swarmbar"), "one\n")
        self.assertEqual(stat.S_IMODE(os.stat(path + ".backup-swarmbar").st_mode), 0o640)
        # The written file keeps its own mode; mode is only for new files.
        self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o640)

    def test_hardlink_partner_sees_write(self):
        path = self.put(".kimi-code/config.toml", "old\n")
        partner = os.path.join(self.root, "profile-config.toml")
        os.link(path, partner)
        inode = os.stat(path).st_ino
        self.assertTrue(self.write(path, "new\n", sha("old\n"))["written"])
        self.assertEqual(self.read(partner), "new\n")
        self.assertEqual(os.stat(path).st_ino, inode)
        self.assertEqual(os.stat(path).st_nlink, 2)

    def test_failed_write_restores_backup(self):
        path = self.put(".kimi-code/config.toml", "original\n")
        real_write = helper._STEPS["write_bytes"]
        calls = []

        def failing_once(handle, data):
            calls.append(data)
            if len(calls) == 1:
                # Half a write, then the disk gives out.
                handle.seek(0)
                handle.truncate()
                handle.write(data[:3])
                raise OSError(28, "No space left on device")
            real_write(handle, data)
        with mock.patch.dict(helper._STEPS, {"write_bytes": failing_once}):
            result = self.write(path, "replacement\n", sha("original\n"))
        self.assertFalse(result["ok"])
        self.assertIn("No space left on device", result["error"])
        self.assertEqual(self.read(path), "original\n")
        self.assertEqual(self.read(path + ".backup-swarmbar"), "original\n")

    def test_failed_new_file_leaves_nothing(self):
        path = os.path.join(self.home, ".swarmbar", "swarmbar-remote-hook.sh")

        def failing(handle, data):
            raise OSError(28, "No space left on device")
        with mock.patch.dict(helper._STEPS, {"write_bytes": failing}):
            result = self.write(path, "#!/bin/sh\n", "absent", 0o700)
        self.assertFalse(result["ok"])
        self.assertFalse(os.path.lexists(path))

    def test_new_file_is_created_with_its_mode(self):
        path = os.path.join(self.home, ".swarmbar", "swarmbar-remote-hook.sh")
        result = self.write(path, "#!/bin/sh\n", "absent", 0o700)
        self.assertEqual(result, {"ok": True, "written": True, "backup": None})
        self.assertEqual(self.read(path), "#!/bin/sh\n")
        self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o700)
        # The bridge directory it made is the 700 one the hook steps require.
        self.assertEqual(stat.S_IMODE(os.stat(os.path.dirname(path)).st_mode), 0o700)
        self.assertFalse(os.path.lexists(path + ".backup-swarmbar"))

    def test_write_as_dropped_owner_runs_in_a_child(self):
        # As root every write runs in a child started as the home's owner.
        # Run as an ordinary user here the child keeps this uid, but the
        # child and its protocol are the real thing.
        settings = self.put(".claude/settings.json", "{}\n")
        script = os.path.join(self.home, ".swarmbar", "swarmbar-remote-hook.sh")
        with mock.patch.object(helper, "STEP_CHILD", True), \
                mock.patch.object(subprocess, "Popen", wraps=subprocess.Popen) as spawn:
            self.assertEqual(self.write(settings, '{"hooks": {}}\n', sha("{}\n")),
                             {"ok": True, "written": True, "backup": settings + ".backup-swarmbar"})
            self.assertEqual(self.write(script, "#!/bin/sh\n", "absent", 0o700)["backup"], None)
            self.assertEqual(self.write(settings, "x\n", sha("{}\n")),
                             {"ok": False, "error": "changed"})
            self.assertEqual(helper.remove_file({"path": script}), {"ok": True, "removed": True})
        self.assertEqual(spawn.call_count, 4)
        for call in spawn.call_args_list:
            argv = call.args[0]
            self.assertEqual(argv[1:4], ["-I", "-S", "-c"])
            self.assertIn(argv[5], ("write", "remove"))
            self.assertEqual(call.kwargs.get("umask"), 0o177)
        self.assertEqual(self.read(settings), '{"hooks": {}}\n')
        self.assertEqual(self.read(settings + ".backup-swarmbar"), "{}\n")
        self.assertFalse(os.path.lexists(script))

    def test_write_never_changes_ownership(self):
        path = self.put(".claude/settings.json", "{}\n")
        refuse = mock.Mock(side_effect=AssertionError("ownership changed"))
        with mock.patch.object(os, "chown", refuse), mock.patch.object(os, "fchown", refuse), \
                mock.patch.object(os, "lchown", refuse):
            self.assertTrue(self.write(path, "x\n", sha("{}\n"))["written"])
        refuse.assert_not_called()

    def test_remove_only_bridge_files(self):
        plugin = self.put(".config/opencode/plugins/swarmbar-remote.js", "// plugin\n")
        hook = self.put(".swarmbar/swarmbar-remote-kimi-hook.sh", "#!/bin/sh\n")
        settings = self.put(".claude/settings.json", "{}\n")
        self.assertEqual(helper.remove_file({"path": plugin}), {"ok": True, "removed": True})
        self.assertEqual(helper.remove_file({"path": hook}), {"ok": True, "removed": True})
        self.assertFalse(os.path.lexists(plugin) or os.path.lexists(hook))
        # Already gone is done, so undo can run twice.
        self.assertEqual(helper.remove_file({"path": plugin}), {"ok": True, "removed": False})
        self.assertEqual(helper.remove_file({"path": settings}),
                         {"ok": False, "error": "not allowed"})
        self.assertTrue(os.path.exists(settings))

    def test_mode_1777_dir_is_not_a_home(self):
        shared = os.path.join(self.root, "Shared")
        os.makedirs(shared)
        os.chmod(shared, 0o1777)
        sibling = os.path.join(self.root, "v")
        os.makedirs(sibling)
        entry = mock.Mock(pw_dir=self.home)
        env = dict(os.environ)
        env.pop("SWARMBAR_HELPER_HOMES")
        with mock.patch.dict(os.environ, env, clear=True), \
                mock.patch("pwd.getpwuid", return_value=entry), \
                mock.patch.object(helper, "home_candidates",
                                  return_value=[shared, sibling, self.home]):
            # Shared is writable by all; the sibling is this user's but not
            # the home passwd names.
            self.assertEqual(helper.home_dirs(), [self.home])
            os.chmod(self.home, 0o775)
            self.assertEqual(helper.home_dirs(), [])
        os.chmod(self.home, 0o755)

    def test_intermediate_symlink_is_refused(self):
        real = self.put("elsewhere/opencode/opencode.json", "{}\n")
        os.symlink(os.path.join(self.home, "elsewhere"), os.path.join(self.home, ".config"))
        linked = os.path.join(self.home, ".config", "opencode", "opencode.json")
        self.assertEqual(self.write(linked, "x\n", sha("{}\n")),
                         {"ok": False, "error": "not allowed"})
        # The child's own walk refuses it too, as it would a link swapped in
        # after the parent resolved the path.
        job = {"home": self.home, "target": linked}
        with self.assertRaises(helper._STEPS["Refused"]):
            helper._STEPS["walk_to_parent"](job, False)
        self.assertEqual(self.read(real), "{}\n")

    def test_claude_dir_symlinked_out_of_home_is_refused(self):
        outside = os.path.join(self.root, "outside-claude")
        os.makedirs(outside)
        with open(os.path.join(outside, "settings.json"), "w") as handle:
            handle.write("{}\n")
        os.symlink(outside, os.path.join(self.home, ".claude"))
        path = os.path.join(self.home, ".claude", "settings.json")
        self.assertIsNone(helper.allowed_target(path))
        self.assertEqual(self.write(path, "x\n", sha("{}\n")), {"ok": False, "error": "not allowed"})
        self.assertEqual(self.read(os.path.join(outside, "settings.json")), "{}\n")

    def test_writable_directory_on_the_way_is_refused(self):
        path = self.put(".kimi-code/config.toml", "old\n")
        os.chmod(os.path.dirname(path), 0o777)
        self.assertEqual(self.write(path, "new\n", sha("old\n")),
                         {"ok": False, "error": "not allowed"})
        self.assertEqual(self.read(path), "old\n")

    def test_hardlink_to_another_owners_file_is_refused(self):
        theirs = os.path.join(self.root, "someone-elses")
        with open(theirs, "w") as handle:
            handle.write("theirs\n")
        os.makedirs(os.path.join(self.home, ".kimi-code"))
        path = os.path.join(self.home, ".kimi-code", "config.toml")
        os.link(theirs, path)
        inode = os.stat(theirs).st_ino
        real_fstat = os.fstat

        def owned_by_another(fd):
            info = real_fstat(fd)
            if info.st_ino != inode:
                return info
            values = list(tuple(info))
            values[4] = info.st_uid + 1
            return os.stat_result(values)
        with mock.patch.object(os, "fstat", owned_by_another):
            self.assertEqual(self.write(path, "mine\n", sha("theirs\n")),
                             {"ok": False, "error": "not allowed"})
        self.assertEqual(self.read(theirs), "theirs\n")
        self.assertFalse(os.path.lexists(path + ".backup-swarmbar"))

    def test_preplanted_backup_symlink_is_refused(self):
        path = self.put(".kimi-code/config.toml", "old\n")
        decoy = os.path.join(self.root, "decoy")
        with open(decoy, "w") as handle:
            handle.write("decoy\n")
        os.symlink(decoy, path + ".backup-swarmbar")
        self.assertEqual(self.write(path, "new\n", sha("old\n")),
                         {"ok": False, "error": "backup path is not a file"})
        self.assertEqual(self.read(path), "old\n")
        self.assertEqual(self.read(decoy), "decoy\n")
        # A directory there is no backup either.
        os.unlink(path + ".backup-swarmbar")
        os.mkdir(path + ".backup-swarmbar")
        self.assertEqual(self.write(path, "new\n", sha("old\n"))["error"],
                         "backup path is not a file")

    def test_requests_reach_the_writers(self):
        path = self.put(".claude/settings.json", "{}\n")
        stdin = io.StringIO(json.dumps({"id": 1, "cmd": "write_file", "path": path,
                                        "content_b64": encoded("x\n"),
                                        "expect_sha256": sha("{}\n"), "mode": 0o644}) + "\n"
                            + json.dumps({"id": 2, "cmd": "remove_file", "path": path}) + "\n"
                            + json.dumps({"id": 3, "cmd": "kimi_events", "binary": "kimi; true",
                                          "home": self.home})
                            + "\n")
        stdout = io.StringIO()
        helper.main(stdin, stdout)
        replies = [json.loads(line) for line in stdout.getvalue().splitlines()]
        self.assertEqual(replies[0], {"ok": True, "written": True,
                                      "backup": path + ".backup-swarmbar", "id": 1})
        self.assertEqual(replies[1], {"ok": False, "error": "not allowed", "id": 2})
        self.assertIsNone(replies[2]["events"])
        self.assertEqual(replies[2]["id"], 3)


DOCTOR_ERROR = (
    "Kimi doctor found 1 issue.\n"
    "\n"
    "ERROR config.toml  /tmp/sbk-x/config.toml\n"
    "  Invalid configuration in /tmp/sbk-x/config.toml.\n"
    "  Validation issues:\n"
    '    hooks[0].event: Invalid option: expected one of "PreToolUse"|"PostToolUse"|'
    '"PermissionRequest"|"PermissionResult"|"UserPromptSubmit"|"Stop"|"SessionStart"|'
    '"SessionEnd"|"Notification"\n'
    "SKIP tui.toml     /tmp/sbk-x/tui.toml\n"
    "  File does not exist; built-in defaults will apply.\n"
)


class KimiEventsTests(unittest.TestCase):
    """kimi_events asks a Kimi-family build which hook events it accepts."""

    def setUp(self):
        self.root = os.path.realpath(tempfile.mkdtemp(dir="/tmp", prefix="sbk-"))
        self.addCleanup(shutil.rmtree, self.root, True)
        self.home = os.path.join(self.root, "u")
        self.bin = os.path.join(self.root, "bin")
        os.makedirs(self.home)
        os.makedirs(self.bin)
        self.kimi = self.executable(os.path.join(self.bin, "kimi"), "#!/bin/sh\nexit 1\n")
        env = mock.patch.dict(os.environ, {"SWARMBAR_HELPER_HOMES": self.home,
                                           "PATH": self.bin + os.pathsep + "/usr/bin:/bin",
                                           "SBK_SECRET": "must not reach doctor"})
        env.start()
        self.addCleanup(env.stop)

    def executable(self, path, text):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as handle:
            handle.write(text)
        os.chmod(path, 0o755)
        return path

    def events(self, binary="kimi", home=None):
        return helper.kimi_events({"binary": binary, "home": home or self.home})

    def recording(self, seen, text=DOCTOR_ERROR):
        def doctor(argv, timeout=5, input=None, **options):
            seen["argv"], seen["timeout"], seen["options"] = list(argv), timeout, options
            seen["home"] = options["env"]["KIMI_CODE_HOME"]
            with open(os.path.join(seen["home"], "config.toml")) as handle:
                seen["config"] = handle.read()
            return completed(argv, 1, text)
        return doctor

    def test_kimi_events_parses_accepted_list(self):
        seen = {}
        with mock.patch.object(helper, "run_command", self.recording(seen)):
            result = self.events()
        self.assertEqual(result, {"events": [
            "PreToolUse", "PostToolUse", "PermissionRequest", "PermissionResult",
            "UserPromptSubmit", "Stop", "SessionStart", "SessionEnd", "Notification"]})
        self.assertEqual(seen["argv"], [self.kimi, "doctor"])
        self.assertEqual(seen["timeout"], 15)
        self.assertIn('event = "SwarmBarProbeEvent"', seen["config"])
        self.assertEqual(seen["config"].count("[[hooks]]"), 1)
        self.assertFalse(os.path.exists(seen["home"]))

    def test_doctor_runs_the_vetted_realpath_in_a_scrubbed_environment(self):
        real = self.executable(os.path.join(self.root, "dist", "kimi-code"), "#!/bin/sh\n")
        os.symlink(real, os.path.join(self.bin, "kimi-code"))
        seen = {}
        with mock.patch.object(helper, "run_command", self.recording(seen)):
            self.assertIsNotNone(self.events(os.path.join(self.bin, "kimi-code"))["events"])
        self.assertEqual(seen["argv"][0], real)
        env = seen["options"]["env"]
        self.assertEqual(set(env) - {"LANG"}, {"PATH", "HOME", "KIMI_CODE_HOME"})
        self.assertEqual(env["HOME"], self.home)
        self.assertTrue(seen["options"]["start_new_session"])
        self.assertNotIn("user", seen["options"])

    def test_bearcode_bundle_is_a_family_build(self):
        bundle = self.executable(os.path.join(
            self.root, "bearcode-cli", "apps", "kimi-code", "dist", "main.mjs"), "#!/bin/sh\n")
        link = os.path.join(self.bin, "bc")
        os.symlink(bundle, link)
        seen = {}
        with mock.patch.object(helper, "run_command", self.recording(seen)):
            self.assertIsNotNone(self.events(link)["events"])
        self.assertEqual(seen["argv"][0], bundle)

    def test_parser_takes_other_quoting_and_separators(self):
        self.assertEqual(helper.accepted_events(
            "hooks[0].event: expected one of 'PreToolUse', 'Stop', 'SessionEnd'"),
            ["PreToolUse", "Stop", "SessionEnd"])
        self.assertEqual(helper.accepted_events(
            "Invalid enum value. Expected one of: PreToolUse, Stop or Notification."),
            ["PreToolUse", "Stop", "Notification"])
        self.assertEqual(helper.accepted_events(
            "\x1b[31mhooks[0].event\x1b[0m: expected one of [\"Stop\", \"SessionEnd\"]"),
            ["Stop", "SessionEnd"])
        self.assertIsNone(helper.accepted_events("Kimi doctor found no issues.\n"))
        self.assertIsNone(helper.accepted_events(""))

    def test_kimi_events_reports_what_it_could_not_learn(self):
        quiet = lambda argv, timeout=5, input=None, **options: completed(argv, 0, "No issues.\n")
        with mock.patch.object(helper, "run_command", quiet):
            result = self.events()
        self.assertIsNone(result["events"])
        self.assertTrue(result["error"])

        def slow(argv, timeout=5, input=None, **options):
            raise subprocess.TimeoutExpired(argv, timeout)
        with mock.patch.object(helper, "run_command", slow):
            result = self.events()
        self.assertIsNone(result["events"])
        self.assertIn("time", result["error"])

    def test_kimi_events_rejects_bad_binary(self):
        plain = os.path.join(self.root, "other", "kimi")
        os.makedirs(os.path.dirname(plain))
        with open(plain, "w") as handle:
            handle.write("#!/bin/sh\n")
        os.chmod(plain, 0o644)
        runner = mock.Mock(side_effect=AssertionError("ran"))
        with mock.patch.object(helper, "run_command", runner):
            for bad in ("kimi; true", "../kimi", "bin/kimi", "python3", "/nonexistent/kimi",
                        plain, "/bin/sh", "", None, ["kimi"]):
                result = self.events(bad)
                self.assertIsNone(result["events"], bad)
                self.assertTrue(result["error"], bad)
            # And a home that is not one.
            for home in (self.root, "/", os.path.join(self.home, "missing")):
                self.assertEqual(self.events(home=home)["error"], "not a home")
        runner.assert_not_called()

    def test_root_runs_doctor_as_the_home_owner(self):
        seen = {}
        with mock.patch.object(os, "geteuid", return_value=0), \
                mock.patch.object(helper, "run_command", self.recording(seen)):
            self.assertIsNotNone(self.events()["events"])
        self.assertEqual(seen["options"]["user"], os.stat(self.home).st_uid)
        self.assertEqual(seen["options"]["group"], helper.home_owner(self.home)[2])
        # Never root's PATH: the system's, then the owner's own bin dirs.
        self.assertEqual(seen["options"]["env"]["PATH"], ":".join([
            "/usr/local/bin", "/usr/bin", "/bin",
            os.path.join(self.home, ".local", "bin"), os.path.join(self.home, ".bun", "bin")]))

    def test_root_home_runs_only_a_build_only_root_can_change(self):
        runner = mock.Mock(side_effect=AssertionError("ran"))
        with mock.patch.object(os, "geteuid", return_value=0), \
                mock.patch.object(helper, "home_owner", return_value=("root", 0, 0)), \
                mock.patch.object(helper, "run_command", runner):
            # The build here is this test's, not root's alone.
            self.assertIsNone(self.events()["events"])
        runner.assert_not_called()
        seen = {}
        with mock.patch.object(os, "geteuid", return_value=0), \
                mock.patch.object(helper, "home_owner", return_value=("root", 0, 0)), \
                mock.patch.object(helper, "root_only_path", return_value=True), \
                mock.patch.object(helper, "run_command", self.recording(seen)):
            self.assertIsNotNone(self.events()["events"])
        self.assertNotIn("user", seen["options"])
        self.assertFalse(helper.root_only_path(self.kimi))

    def test_kimi_events_against_a_fake_build(self):
        # The real run_command against a script standing in for kimi, which
        # answers only when it finds the probe config where it was told to.
        fake = self.executable(os.path.join(self.root, "dist", "kimi-code"),
            "#!/bin/sh\n"
            '[ "$1" = doctor ] || exit 2\n'
            '[ -z "$SBK_SECRET" ] || exit 4\n'
            'grep -q \'event = "SwarmBarProbeEvent"\' "$KIMI_CODE_HOME/config.toml" || exit 3\n'
            'echo "$KIMI_CODE_HOME" > "%s/home-was"\n'
            "echo 'hooks[0].event: Invalid option: expected one of \"Stop\"|\"SessionEnd\"'\n"
            "exit 1\n" % self.root)
        self.assertEqual(self.events(fake), {"events": ["Stop", "SessionEnd"]})
        with open(os.path.join(self.root, "home-was")) as handle:
            self.assertFalse(os.path.exists(handle.read().strip()))

    def test_timeout_kills_the_whole_process_group(self):
        pidfile = os.path.join(self.root, "grandchild")
        script = self.executable(os.path.join(self.root, "slow"),
                                 "#!/bin/sh\nsleep 30 &\necho $! > %s\nwait\n" % pidfile)
        with self.assertRaises(subprocess.TimeoutExpired):
            helper.run_command([script], timeout=1, start_new_session=True)
        with open(pidfile) as handle:
            grandchild = int(handle.read())

        def gone():
            try:
                os.kill(grandchild, 0)
            except ProcessLookupError:
                return True
            # A zombie until init reaps it still counts as killed.
            state = subprocess.run(["ps", "-o", "stat=", "-p", str(grandchild)],
                                   stdout=subprocess.PIPE).stdout.strip()
            return state.startswith(b"Z") or not state
        self.assertTrue(wait_until(gone, 5))


class ApplyTests(unittest.TestCase):
    """`swarmbar-helper.py apply <blob>`: the pasted-command path."""

    def setUp(self):
        self.root = os.path.realpath(tempfile.mkdtemp(dir="/tmp", prefix="sba-"))
        self.addCleanup(shutil.rmtree, self.root, True)
        self.home = os.path.join(self.root, "u")
        os.makedirs(self.home)
        env = mock.patch.dict(os.environ, {"SWARMBAR_HELPER_HOMES": self.home})
        env.start()
        self.addCleanup(env.stop)

    def put(self, relative, text):
        path = os.path.join(self.home, relative)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as handle:
            handle.write(text)
        return path

    def read(self, path):
        with open(path) as handle:
            return handle.read()

    def apply(self, blob):
        out = io.StringIO()
        with mock.patch.object(sys, "stdout", out):
            code = helper.apply_main([blob])
        return code, out.getvalue().splitlines()

    def write_op(self, path, text, expect):
        return {"op": "write_file", "path": path, "content_b64": encoded(text),
                "expect_sha256": expect, "mode": 0o644}

    def test_apply_runs_operations_in_order_and_stops_on_failure(self):
        first = self.put(".claude/settings.json", "{}\n")
        second = self.put(".kimi-code/config.toml", "edited by hand\n")
        third = os.path.join(self.home, ".bearcode", "config.toml")
        os.makedirs(os.path.dirname(third))
        code, lines = self.apply(apply_blob([
            self.write_op(first, "one\n", sha("{}\n")),
            self.write_op(second, "two\n", sha("what the plan read\n")),
            self.write_op(third, "three\n", "absent"),
        ]))
        self.assertNotEqual(code, 0)
        self.assertEqual(self.read(first), "one\n")
        self.assertEqual(self.read(second), "edited by hand\n")
        self.assertFalse(os.path.lexists(third))
        self.assertTrue(lines[0].startswith("ok: write_file " + first), lines)
        self.assertTrue(lines[1].startswith("failed: write_file " + second), lines)
        self.assertIn("changed", lines[1])
        self.assertFalse(any(third in line for line in lines), lines)
        self.assertEqual(len(lines), 3)

    def test_apply_decodes_zlib_and_base64(self):
        for raw in (False, True):
            name = ".bearcode/config.toml" if raw else ".kimi-code/config.toml"
            path = os.path.join(self.home, name)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            code, lines = self.apply(apply_blob([self.write_op(path, "x\n", "absent")], raw=raw))
            self.assertEqual(code, 0, lines)
            self.assertEqual(self.read(path), "x\n")
            self.assertEqual(len(lines), 1)
        for bad in ("not base64!", base64.b64encode(b"not zlib").decode(),
                    apply_blob({"op": "write_file"}), apply_blob(["write_file"]), ""):
            code, lines = self.apply(bad)
            self.assertNotEqual(code, 0, bad)
            self.assertTrue(lines and lines[0].startswith("failed"), lines)

    def test_decompression_is_bounded(self):
        path = os.path.join(self.home, ".kimi-code", "config.toml")
        os.makedirs(os.path.dirname(path))
        bomb = json.dumps([self.write_op(path, "x\n", "absent")]) + " " * (9 * 1024 * 1024)
        packed = base64.b64encode(zlib.compress(bomb.encode())).decode()
        self.assertLess(len(packed), 64 * 1024)
        code, lines = self.apply(packed)
        self.assertNotEqual(code, 0)
        self.assertFalse(os.path.lexists(path))
        # A stream cut short is refused too.
        whole = base64.b64decode(apply_blob([self.write_op(path, "x\n", "absent")]))
        code, lines = self.apply(base64.b64encode(whole[:-6]).decode())
        self.assertNotEqual(code, 0)
        self.assertFalse(os.path.lexists(path))

    def test_install_helper_checks_the_bytes_it_copies(self):
        dest = os.path.join(self.home, ".swarmbar", "swarmbar-helper")
        with open(helper.__file__, "rb") as handle:
            digest = hashlib.sha256(handle.read()).hexdigest()
        with mock.patch.dict(os.environ, {"HOME": self.home}):
            result = helper.install_helper({"dest": dest, "expect_sha256": "0" * 64})
            self.assertEqual(result, {"ok": False, "error": "changed"})
            self.assertFalse(os.path.lexists(dest))
            result = helper.install_helper({"dest": dest, "expect_sha256": digest})
            self.assertTrue(result["ok"], result)
            self.assertEqual(result["sha256"], digest)
            self.assertFalse(helper.install_helper({"dest": dest, "expect_sha256": digest + "\n"})["ok"])

    def test_unknown_operation_stops(self):
        path = os.path.join(self.home, ".kimi-code", "config.toml")
        os.makedirs(os.path.dirname(path))
        code, lines = self.apply(apply_blob([{"op": "chmod", "path": path},
                                             self.write_op(path, "x\n", "absent")]))
        self.assertNotEqual(code, 0)
        self.assertFalse(os.path.lexists(path))

    def test_apply_command_line_starts_nothing_else(self):
        # The real script, as the pasted command runs it: no hook socket, no
        # request loop on stdin, one line per operation.
        self.put(".swarmbar/swarmbar-remote-hook.sh", "#!/bin/sh\n")
        path = self.put(".claude/settings.json", "{}\n")
        script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "swarmbar-helper.py")
        done = subprocess.run(
            [sys.executable, script, "apply",
             apply_blob([self.write_op(path, "x\n", sha("{}\n"))])],
            env=dict(os.environ, SWARMBAR_HELPER_HOMES=self.home), stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(done.stderr, b"")
        self.assertEqual(len(done.stdout.decode().splitlines()), 1)
        self.assertEqual(self.read(path), "x\n")
        self.assertFalse(os.path.lexists(os.path.join(self.home, ".swarmbar", "hook.sock")))
        self.assertFalse(os.path.lexists(os.path.join(self.home, ".swarmbar", "hook.lock")))

    def test_install_helper_as_login_user(self):
        dest = os.path.join(self.home, ".swarmbar", "swarmbar-helper")
        with mock.patch.dict(os.environ, {"HOME": self.home}):
            code, lines = self.apply(apply_blob([{"op": "install_helper", "dest": dest}]))
            self.assertEqual(code, 0, lines)
            with open(helper.__file__, "rb") as handle:
                with open(dest, "rb") as installed:
                    self.assertEqual(installed.read(), handle.read())
            self.assertEqual(stat.S_IMODE(os.stat(dest).st_mode), 0o700)
            self.assertEqual(stat.S_IMODE(os.stat(os.path.dirname(dest)).st_mode), 0o700)
            # Anywhere else is refused.
            elsewhere = os.path.join(self.home, "bin", "swarmbar-helper")
            code, lines = self.apply(apply_blob([{"op": "install_helper", "dest": elsewhere}]))
            self.assertNotEqual(code, 0)
            self.assertFalse(os.path.lexists(elsewhere))
            self.assertEqual(os.listdir(os.path.dirname(dest)), ["swarmbar-helper"])

    def test_root_helper_needs_a_directory_only_root_can_write(self):
        lib = os.path.join(self.root, "lib")
        os.makedirs(lib)
        dest = os.path.join(lib, "swarmbar-helper")
        with mock.patch.object(helper, "HELPER_PATHS", (dest,)), \
                mock.patch.object(os, "geteuid", return_value=0):
            result = helper.install_helper({"dest": dest})
        self.assertFalse(result["ok"])
        self.assertFalse(os.path.lexists(dest))


class SudoersTests(unittest.TestCase):
    """The narrow sudo rule: one user, one command, checked by visudo."""

    def setUp(self):
        self.dir = os.path.realpath(tempfile.mkdtemp(dir="/tmp", prefix="sbs-"))
        self.addCleanup(shutil.rmtree, self.dir, True)
        self.path = os.path.join(self.dir, "swarmbar")
        for patch in (mock.patch.object(helper, "SUDOERS_PATH", self.path),
                      mock.patch.object(helper, "visudo_path", return_value="/usr/sbin/visudo")):
            patch.start()
            self.addCleanup(patch.stop)

    def test_sudoers_requires_root(self):
        runner = mock.Mock(side_effect=AssertionError("ran"))
        with mock.patch.object(os, "geteuid", return_value=1000), \
                mock.patch.object(helper, "run_command", runner):
            result = helper.install_sudoers({"user": "nobody"})
        self.assertFalse(result["ok"])
        self.assertEqual(os.listdir(self.dir), [])
        runner.assert_not_called()

    def test_sudoers_rejects_bad_user_names(self):
        runner = mock.Mock(side_effect=AssertionError("ran"))
        with mock.patch.object(os, "geteuid", return_value=0), \
                mock.patch.object(helper, "run_command", runner):
            for bad in ("", "Root", "-x", "a b", "nobody\n", "x\nALL ALL=(ALL) NOPASSWD: ALL",
                        "../x", "a$b", "sbx-no-such-user", None, 0):
                result = helper.install_sudoers({"user": bad})
                self.assertFalse(result["ok"], bad)
        self.assertEqual(os.listdir(self.dir), [])
        runner.assert_not_called()

    def test_sudoers_installs_a_checked_rule(self):
        checked = {}

        def visudo(argv, timeout=5, input=None, **options):
            checked.setdefault("calls", []).append(list(argv))
            if argv[1] == "-cf":
                checked["argv"] = list(argv)
                with open(argv[-1]) as handle:
                    checked["text"] = handle.read()
                checked["mode"] = stat.S_IMODE(os.stat(argv[-1]).st_mode)
            return completed(argv, 0, "parsed OK\n")
        with mock.patch.object(os, "geteuid", return_value=0), \
                mock.patch.object(helper, "run_command", visudo):
            result = helper.install_sudoers({"user": "nobody"})
        self.assertTrue(result["ok"], result)
        rule = "nobody ALL=(root) NOPASSWD: /usr/local/lib/swarmbar-helper\n"
        self.assertEqual(checked["argv"][:2], ["/usr/sbin/visudo", "-cf"])
        self.assertEqual(checked["text"], rule)
        self.assertEqual(checked["mode"], 0o440)
        # sudo's includedir skips names with a dot, so the unchecked file is
        # never live under a name sudo would read.
        self.assertIn(".", os.path.basename(checked["argv"][-1]))
        self.assertEqual(os.listdir(self.dir), ["swarmbar"])
        self.assertEqual(self.read(), rule)
        self.assertEqual(stat.S_IMODE(os.stat(self.path).st_mode), 0o440)
        # Then the whole configuration, with the rule in place.
        self.assertEqual(checked["calls"][-1], ["/usr/sbin/visudo", "-c"])

    def test_rule_that_breaks_the_whole_configuration_is_taken_out(self):
        def visudo(argv, timeout=5, input=None, **options):
            return completed(argv, 0 if argv[1] == "-cf" else 1, "")
        with mock.patch.object(os, "geteuid", return_value=0), \
                mock.patch.object(helper, "run_command", visudo):
            result = helper.install_sudoers({"user": "nobody"})
        self.assertFalse(result["ok"])
        self.assertIn("removed", result["error"])
        self.assertEqual(os.listdir(self.dir), [])

    def test_narrow_rule_cannot_set_itself_up(self):
        installed = os.path.join(self.dir, "swarmbar-helper")
        shutil.copy(helper.__file__, installed)
        with mock.patch.object(helper, "__file__", installed), \
                mock.patch.object(helper, "HELPER_PATHS", (installed,)), \
                mock.patch.object(os, "geteuid", return_value=0), \
                mock.patch.dict(os.environ, {"SUDO_UID": "1000"}), \
                mock.patch.object(helper, "run_command", mock.Mock(side_effect=AssertionError)):
            self.assertTrue(helper.narrow_rule_run())
            self.assertIn("sudo rule", helper.install_sudoers({"user": "nobody"})["error"])
            self.assertIn("sudo rule", helper.install_helper({"dest": installed})["error"])
            out = io.StringIO()
            with mock.patch.object(sys, "stdout", out):
                code = helper.apply_main([apply_blob([{"op": "sudoers", "user": "nobody"}])])
            self.assertNotEqual(code, 0)
            self.assertIn("sudo rule", out.getvalue())
        self.assertFalse(os.path.lexists(self.path))
        # Root itself (sudo from root, or no sudo) is not the narrow rule,
        # and neither is a copy run from anywhere else.
        for env, path in (({"SUDO_UID": "0"}, installed), ({"SUDO_UID": ""}, installed),
                          ({"SUDO_UID": "1000"}, helper.__file__)):
            with mock.patch.object(helper, "__file__", path), \
                    mock.patch.object(helper, "HELPER_PATHS", (installed,)), \
                    mock.patch.object(os, "geteuid", return_value=0), \
                    mock.patch.dict(os.environ, env):
                self.assertFalse(helper.narrow_rule_run(), (env, path))

    def test_rule_visudo_rejects_is_never_installed(self):
        failing = lambda argv, timeout=5, input=None, **options: completed(argv, 1, "syntax error")
        with mock.patch.object(os, "geteuid", return_value=0), \
                mock.patch.object(helper, "run_command", failing):
            result = helper.install_sudoers({"user": "nobody"})
        self.assertFalse(result["ok"])
        self.assertEqual(os.listdir(self.dir), [])

    def read(self):
        with open(self.path) as handle:
            return handle.read()


if __name__ == "__main__":
    unittest.main(verbosity=2)
