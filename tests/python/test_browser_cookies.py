"""Which browser profile's VK session the browser sign-in uses.

A machine keeps several Firefox-family profiles, and more than one of them can
hold a complete `p`/`remixsid` pair. Choosing the first one is how the panel
signed itself into an account the user was not looking at; the session with the
newest `lastAccessed` is the one in the open window.

Run from the repository root:

    python3 -m unittest discover -s tests/python -v
"""

from __future__ import annotations

import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "backend"))

import vk_auth  # noqa: E402


def make_store(directory: Path, label: str, last_accessed: int) -> Path:
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / "cookies.sqlite"
    connection = sqlite3.connect(path)
    connection.execute(
        "CREATE TABLE moz_cookies ("
        "name TEXT, value TEXT, host TEXT, lastAccessed INTEGER)"
    )
    connection.executemany(
        "INSERT INTO moz_cookies (name, value, host, lastAccessed) VALUES (?, ?, ?, ?)",
        [
            ("p", f"{label}-p", ".login.vk.ru", last_accessed),
            ("remixsid", f"{label}-s", ".vk.ru", last_accessed),
        ],
    )
    connection.commit()
    connection.close()
    return path


class CookieProfileTest(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.older = make_store(self.root / "aa-old", "old", 1_000)
        self.newer = make_store(self.root / "zz-new", "new", 2_000)

    def tearDown(self) -> None:
        self.directory.cleanup()

    def test_the_newest_session_wins_whatever_the_order(self) -> None:
        for candidates in ([self.older, self.newer], [self.newer, self.older]):
            chosen = vk_auth._best_cookie_set(candidates)
            self.assertEqual(chosen, {"p": "new-p", "remixsid": "new-s"})

    def test_an_incomplete_profile_is_skipped(self) -> None:
        partial = self.root / "partial"
        partial.mkdir()
        path = partial / "cookies.sqlite"
        connection = sqlite3.connect(path)
        connection.execute(
            "CREATE TABLE moz_cookies ("
            "name TEXT, value TEXT, host TEXT, lastAccessed INTEGER)"
        )
        connection.execute(
            "INSERT INTO moz_cookies VALUES ('remixsid', 'only', '.vk.ru', 9999)"
        )
        connection.commit()
        connection.close()

        chosen = vk_auth._best_cookie_set([path, self.older])

        self.assertEqual(chosen, {"p": "old-p", "remixsid": "old-s"})

    def test_values_are_returned_without_the_timestamp_named(self) -> None:
        cookies = vk_auth.read_firefox_cookies(self.newer, vk_auth.COOKIE_NAMES)
        self.assertEqual(cookies, {"p": "new-p", "remixsid": "new-s"})


if __name__ == "__main__":
    unittest.main()
