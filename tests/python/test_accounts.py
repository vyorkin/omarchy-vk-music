"""The multi-account store and the per-account slice of the state file.

These are the two places where a mistake is expensive and invisible: a wrong
key writes one account's queue over another's, and a migration that drops the
old token silently signs the user out. Both are plain data, so they are tested
without VK, mpv or a shell.

Run from the repository root:

    python3 -m unittest discover -s tests/python -v
"""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "backend"))

import backend  # noqa: E402
import vk_auth  # noqa: E402


def web_record(user_id: int, token: str) -> dict:
    return {
        "mode": "web",
        "access_token": token,
        "expires": 0,
        "user_id": user_id,
        "cookies": {"p": "cookie-p", "remixsid": "cookie-s"},
        "client_id": "1",
        "user_agent": "ua",
        "device_id": "device",
    }


def track(number: int) -> dict:
    return {
        "key": f"1_{number}",
        "owner_id": 1,
        "audio_id": number,
        "title": f"Track {number}",
        "artist": "Artist",
        "duration": 100,
        "url": "",
        "is_liked": False,
    }


class AccountTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        root = Path(self.directory.name)
        config = root / "omarchy-vk-music"
        config.mkdir()
        vk_auth.CONFIG_DIR = config
        vk_auth.ACCOUNTS_FILE = config / "accounts.json"
        vk_auth.TOKEN_FILE = config / "token.json"
        backend.CONFIG_DIR = config
        backend.STATE_FILE = config / "state.json"
        backend.CACHE_DIR = root / "cache"
        backend.AUDIO_CACHE_DIR = root / "cache" / "audio"
        backend.COVER_DIR = root / "cache" / "covers"
        backend.RUNTIME_DIR = root / "run"
        backend.RUNTIME_DIR.mkdir()
        backend.SOCKET_PATH = backend.RUNTIME_DIR / "music.sock"
        backend.MPV_SOCKET = backend.RUNTIME_DIR / "mpv.sock"

    def tearDown(self) -> None:
        self.directory.cleanup()

    # -- the store ---------------------------------------------------------

    def test_legacy_token_becomes_one_account(self) -> None:
        vk_auth.TOKEN_FILE.write_text(json.dumps(web_record(111, "token-111")))

        self.assertEqual(vk_auth.active_account_id(), "111")
        self.assertEqual(vk_auth.active_record()["access_token"], "token-111")
        self.assertFalse(vk_auth.TOKEN_FILE.exists())
        self.assertEqual([item["id"] for item in vk_auth.account_list()], [111])

    def test_second_account_joins_and_switches(self) -> None:
        vk_auth.save_account(web_record(111, "token-111"), profile={"name": "One"})
        vk_auth.save_account(
            web_record(222, "token-222"),
            profile={"user_id": 222, "name": "Two", "photo": "photo-222"},
        )

        self.assertEqual(vk_auth.active_account_id(), "222")
        accounts = vk_auth.account_list()
        self.assertEqual([(item["id"], item["name"]) for item in accounts], [(222, "Two"), (111, "One")])
        self.assertTrue(accounts[0]["active"])
        self.assertEqual(vk_auth.account_record(222)["photo"], "photo-222")

        switched = vk_auth.set_active_account(111)
        self.assertEqual(switched["user_id"], 111)
        self.assertEqual(vk_auth.active_account_id(), "111")

    def test_removing_the_active_account_hands_over_the_next_one(self) -> None:
        vk_auth.save_account(web_record(111, "token-111"))
        vk_auth.save_account(web_record(222, "token-222"))
        vk_auth.set_active_account(111)

        self.assertEqual(vk_auth.remove_account(111)["user_id"], 222)
        self.assertEqual(vk_auth.active_account_id(), "222")
        self.assertIsNone(vk_auth.remove_account(222))
        self.assertIsNone(vk_auth.active_account_id())
        self.assertEqual(vk_auth.account_list(), [])

    def test_the_store_keeps_a_hint_beside_the_token(self) -> None:
        vk_auth.save_account(web_record(111, "token-111"))
        written = json.loads(vk_auth.ACCOUNTS_FILE.read_text())
        record = written["accounts"]["111"]
        self.assertEqual(record["token_hint"], "token-...9 chars")
        self.assertEqual(record["access_token"], "token-111")
        self.assertEqual(vk_auth.ACCOUNTS_FILE.stat().st_mode & 0o777, 0o600)

    # -- state -------------------------------------------------------------

    def test_an_old_state_file_moves_to_the_active_account(self) -> None:
        vk_auth.save_account(web_record(111, "token-111"))
        backend.STATE_FILE.write_text(
            json.dumps(
                {
                    "preferences": {},
                    "queue": [track(1), track(2)],
                    "index": 1,
                    "position": 42,
                    "likedCopies": {"1_1": "9_1"},
                    "searchHistory": ["jazz"],
                    "recentPeople": [{"id": 5, "name": "Person"}],
                }
            )
        )
        player = backend.Player()
        player.mpv = _SilentMpv()
        player.load_session()

        self.assertEqual([item.key for item in player.queue], ["1_1", "1_2"])
        self.assertEqual(player.index, 1)
        self.assertEqual(player.position, 42)

        player.save_state()
        document = json.loads(backend.STATE_FILE.read_text())
        self.assertNotIn("queue", document)
        self.assertEqual(sorted(document["accounts"]), ["111"])

    def test_each_account_keeps_its_own_queue_and_likes(self) -> None:
        vk_auth.save_account(web_record(111, "token-111"))
        vk_auth.save_account(web_record(222, "token-222"))
        vk_auth.set_active_account(111)
        backend.STATE_FILE.write_text(
            json.dumps({"preferences": {}, "queue": [track(1)], "index": 0, "position": 7})
        )

        player = backend.Player()
        player.mpv = _SilentMpv()
        player.load_session()
        player.liked_copies = {"1_1": "9_1"}
        player.save_state()

        player.switch_account(222)
        self.assertEqual(player.queue, [])
        self.assertEqual(player.liked_copies, {})
        player.queue = [backend.track_from_state(track(7))]
        player.index = 0
        player.position = 3
        player.save_state()

        player.switch_account(111)
        self.assertEqual([item.key for item in player.queue], ["1_1"])
        self.assertEqual(player.position, 7)
        self.assertEqual(player.liked_copies, {"1_1": "9_1"})

        player.switch_account(222)
        self.assertEqual([item.key for item in player.queue], ["1_7"])
        self.assertEqual(player.position, 3)

    def test_recent_queries_can_be_forgotten(self) -> None:
        vk_auth.save_account(web_record(111, "token-111"))
        player = backend.Player()
        player.mpv = _SilentMpv()
        player.load_session()
        player.remember_search("radiohead")
        player.remember_search("kino")
        player.remember_search("kino")  # a repeat moves to the front, it does not double
        self.assertEqual(player.search_history, ["kino", "radiohead"])

        player.forget_search_history()

        self.assertEqual(player.search_history, [])
        document = json.loads(backend.STATE_FILE.read_text())
        self.assertEqual(document["accounts"]["111"]["searchHistory"], [])
        self.assertEqual(player.status()["history"], [])

    def test_removing_an_account_drops_its_state_slice(self) -> None:
        vk_auth.save_account(web_record(111, "token-111"))
        vk_auth.save_account(web_record(222, "token-222"))
        vk_auth.set_active_account(222)
        backend.STATE_FILE.write_text(json.dumps({"preferences": {}}))

        player = backend.Player()
        player.mpv = _SilentMpv()
        player.load_session()
        player.queue = [backend.track_from_state(track(2))]
        player.index = 0
        player.save_state()

        remaining = player.remove_account(222)

        self.assertEqual(remaining["user_id"], 111)
        self.assertEqual(player.account_id(), 111)
        document = json.loads(backend.STATE_FILE.read_text())
        self.assertNotIn("222", document["accounts"])


class _SilentMpv:
    """Player calls into mpv while switching accounts; the store is the subject."""

    def command(self, *args, **kwargs) -> None:
        pass

    def ensure(self) -> None:
        pass


if __name__ == "__main__":
    unittest.main()
