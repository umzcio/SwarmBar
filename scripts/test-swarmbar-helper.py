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
import shutil
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

    def test_homes_and_shape(self):
        snap = helper.snapshot()
        self.assertEqual([h["path"] for h in snap["homes"]], [self.home])
        self.assertTrue(snap["homes"][0]["user"])
        self.assertNotIn("sessions", snap)
        self.assertEqual(snap["processes"], [])
        self.assertFalse(snap["processes_failed"])


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


if __name__ == "__main__":
    unittest.main(verbosity=2)
