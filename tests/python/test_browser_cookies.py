"""Which browser profile's VK session the browser sign-in uses.

A machine keeps several Firefox-family profiles, and more than one of them can
hold a complete `p`/`remixsid` pair. Choosing the first one is how the panel
signed itself into an account the user was not looking at; the session with the
newest `lastAccessed` is the one in the open window.

Run from the repository root:

    python3 -m unittest discover -s tests/python -v
"""

from __future__ import annotations

import os
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

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


class LoginWindowTest(unittest.TestCase):
    """The window that makes a second account possible at all.

    Reading the everyday browser's freshest session returns the account it is
    signed into — that is how «sign in with the browser» re-added the active
    account instead of adding a second one. The login window is a profile of its
    own, so only what the user typed in there can come out of it.
    """

    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.profile = self.root / "login-profile"
        self.profile.mkdir()
        vk_auth._login_window = None

    def tearDown(self) -> None:
        vk_auth._login_window = None
        self.directory.cleanup()

    def with_profile(self):
        return mock.patch.object(vk_auth, "LOGIN_PROFILE_DIR", self.profile)

    def test_a_window_nobody_signed_into_says_so(self) -> None:
        with self.with_profile():
            with self.assertRaises(vk_auth.LoginWindowEmptyError):
                vk_auth.login_profile_cookies()

    def test_a_window_with_a_vk_page_still_open_but_no_cookies_says_so(self) -> None:
        sqlite3.connect(self.profile / "cookies.sqlite").close()
        with self.with_profile():
            with self.assertRaises(vk_auth.LoginWindowEmptyError):
                vk_auth.login_profile_cookies()

    def test_the_window_is_read_and_no_other_profile_is(self) -> None:
        make_store(self.profile, "window", 1_000)
        make_store(self.root / "zz-everyday", "everyday", 9_999)
        with self.with_profile():
            cookies = vk_auth.login_profile_cookies()
        self.assertEqual(cookies, {"p": "window-p", "remixsid": "window-s"})

    def test_the_browser_is_started_on_its_own_profile_and_instance(self) -> None:
        with mock.patch.dict("os.environ", {"OMARCHY_VK_MUSIC_BROWSER": "zen-browser"}):
            command = vk_auth.login_browser_command(self.profile)
        self.assertIsNotNone(command)
        self.assertEqual(command[0], "zen-browser")
        self.assertIn("--new-instance", command)
        self.assertIn(str(self.profile), command)

    def test_a_lock_held_by_something_else_is_not_a_login_window(self) -> None:
        (self.profile / "lock").symlink_to(f"127.0.0.1:+{os.getpid()}")
        self.assertEqual(vk_auth._profile_lock_pid(self.profile), os.getpid())
        # This test process does not run a browser on the profile, so the pid in
        # the lock must not be adopted as a window to close.
        self.assertFalse(vk_auth._is_login_profile_process(os.getpid()))

    def test_closing_without_a_window_is_not_an_error(self) -> None:
        with self.with_profile():
            self.assertFalse(vk_auth.close_login_window())


if __name__ == "__main__":
    unittest.main()
