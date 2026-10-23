#!/usr/bin/env python3
"""Tests for swarmbar-helper.py's pure parts.

Run directly: python3 scripts/test-swarmbar-helper.py

Not part of the Xcode test bundle: project.yml lists the scripts it ships
one by one, so nothing here reaches the app. Kept in python because
tail_of is python, and the case it exists to cover (a trailing record
bigger than the read window) is only reproducible against a real file.

python 3.9 compatible, like the helper itself.
"""

import base64
import hashlib
import importlib.util
import io
import json
import os
import random
import shutil
import subprocess
import tempfile
import threading
import time
import unittest
from unittest import mock

_spec = importlib.util.spec_from_file_location(
    "swarmbar_helper",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "swarmbar-helper.py"),
)
helper = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(helper)


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

    def __init__(self, screen="", fail_on_send=None, capture_code=0):
        self.capture_code = capture_code
        self.calls = []
        self.inputs = []
        self.screen = screen
        self.fail_on_send = fail_on_send
        self.sends = 0

    def __call__(self, argv, timeout=5, input=None):
        self.calls.append(list(argv))
        self.inputs.append(input)
        code = 0
        if "send-keys" in argv:
            self.sends += 1
            if self.fail_on_send == self.sends:
                code = 1
        out = self.screen.encode("utf-8") if "capture-pane" in argv else b""
        if "capture-pane" in argv:
            code = self.capture_code
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

    def test_paste_never_sends_enter(self):
        rec = TmuxRecorder()
        out = self.call({"cmd": "paste", "pane": self.pane, "text": "hi\nthere"}, rec)
        self.assertEqual(out, {"sent": True})
        self.assertEqual(rec.calls[0][3:], ["load-buffer", "-b", "swarmbar", "-"])
        self.assertEqual(rec.inputs[0], b"hi\nthere")
        self.assertEqual(rec.calls[1][3:], ["paste-buffer", "-p", "-d", "-b",
                                            "swarmbar", "-t", "%3"])
        self.assertFalse(any("send-keys" in c for c in rec.calls))

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


if __name__ == "__main__":
    unittest.main(verbosity=2)
