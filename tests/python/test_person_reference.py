"""A pasted link names a person, whatever shape VK's own pages hand out.

The «Люди» field takes a link as readily as a screen name, and a music page's
address (`vk.ru/audios2733436`) is exactly what VK's «Follow» button leaves on
the clipboard. It used to be handed to `users.get` whole, which answers nobody,
so the panel said «Человек не найден» for a person whose playlists and tracks
are open through their id.

Run from the repository root:

    python3 -m unittest discover -s tests/python -v
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "backend"))

import backend  # noqa: E402


class PersonReferenceTest(unittest.TestCase):
    def test_music_page_link(self) -> None:
        for link in (
            "https://vk.ru/audios2733436",
            "https://vk.com/audios2733436/",
            "https://m.vk.com/audios2733436?section=all",
            "vk.ru/audios2733436?section=all#top",
        ):
            with self.subTest(link=link):
                self.assertEqual(backend.parse_person_reference(link), "2733436")

    def test_profile_link_and_name(self) -> None:
        self.assertEqual(backend.parse_person_reference("https://vk.com/id213706100"), "213706100")
        self.assertEqual(backend.parse_person_reference("@durov"), "durov")
        self.assertEqual(backend.parse_person_reference("durov"), "durov")
        self.assertEqual(backend.parse_person_reference("2733436"), "2733436")

    def test_playlist_link_names_its_owner(self) -> None:
        self.assertEqual(
            backend.parse_person_reference(
                "https://vk.com/music/playlist/2733436_28967029_abcdef"
            ),
            "2733436",
        )

    def test_empty(self) -> None:
        self.assertEqual(backend.parse_person_reference("  "), "")


if __name__ == "__main__":
    unittest.main()
