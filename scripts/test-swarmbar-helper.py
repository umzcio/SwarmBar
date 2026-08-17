#!/usr/bin/env python3
"""Tests for swarmbar-helper.py's pure parts.

Run directly: python3 scripts/test-swarmbar-helper.py

Not part of the Xcode test bundle: project.yml lists the scripts it ships
one by one, so nothing here reaches the app. Kept in python because
tail_of is python, and the case it exists to cover (a trailing record
bigger than the read window) is only reproducible against a real file.

python 3.9 compatible, like the helper itself.
"""

import importlib.util
import json
import os
import shutil
import tempfile
import time
import unittest

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


class SessionRecordTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="swarmbar-helper-sessions-")
        self.root = os.path.join(self.dir, ".claude", "projects")
        self.project = os.path.join(self.root, "-projects-demo")
        os.makedirs(self.project)

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def add(self, name, text):
        path = os.path.join(self.project, name)
        with open(path, "wb") as handle:
            handle.write(text.encode("utf-8"))
        return path

    def test_a_normal_session_is_shipped_whole(self):
        self.add("a.jsonl", record('{"type":"user"}'))
        warnings = []
        sessions = helper.claude_sessions(time.time(), warnings, [self.root])
        self.assertEqual(len(sessions), 1)
        self.assertEqual(sessions[0]["tail"], record('{"type":"user"}'))
        self.assertEqual(warnings, [])

    def test_an_over_ceiling_record_is_omitted_with_a_warning(self):
        self.add("good.jsonl", record('{"type":"user"}'))
        original = helper.MAX_TAIL_BYTES
        helper.MAX_TAIL_BYTES = helper.TAIL_BYTES * 2
        try:
            self.add("bad.jsonl", big_record("huge", helper.TAIL_BYTES * 4))
            warnings = []
            sessions = helper.claude_sessions(
                time.time(), warnings, [self.root])
        finally:
            helper.MAX_TAIL_BYTES = original
        paths = [s["path"] for s in sessions]
        self.assertTrue(any(p.endswith("good.jsonl") for p in paths))
        self.assertFalse(any(p.endswith("bad.jsonl") for p in paths))
        self.assertTrue(any("bad.jsonl" in w for w in warnings), warnings)
        # Never the empty tail that silently deletes the row.
        self.assertFalse(any(s["tail"] == "" for s in sessions))

    def test_a_session_still_being_written_is_omitted_with_a_warning(self):
        self.add("fresh.jsonl", '{"type":"user"')
        warnings = []
        sessions = helper.claude_sessions(
            time.time(), warnings, [self.root])
        self.assertEqual(sessions, [])
        self.assertTrue(any("fresh.jsonl" in w for w in warnings), warnings)


if __name__ == "__main__":
    unittest.main(verbosity=2)
