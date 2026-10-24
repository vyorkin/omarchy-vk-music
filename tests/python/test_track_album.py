"""The record a track belongs to, as the player's third line wants it.

Two payload shapes carry it and neither always does: the catalog answers put the
record in `album.title`, the legacy `audio.get` answers put a free-form string in
`subtitle`, and a queue built from the second one usually has neither. The player
prints something else in that case, so an empty answer here is a real answer.

Run from the repository root:

    python3 -m unittest discover -s tests/python -v
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "backend"))

import vk_api  # noqa: E402

ITEM = {"id": 1, "owner_id": 2, "title": "Irony", "artist": "majiko", "duration": 246}


def track(**fields):
    return vk_api.Track.from_item({**ITEM, **fields})


class TrackAlbumTest(unittest.TestCase):
    def test_the_catalog_album_wins(self):
        self.assertEqual(track(album={"id": 5, "title": "Irony"}, subtitle="2020").album, "Irony")

    def test_the_legacy_subtitle_stands_in_for_it(self):
        self.assertEqual(track(subtitle="Live 2017").album, "Live 2017")

    def test_a_track_with_neither_has_no_album(self):
        self.assertEqual(track().album, "")

    def test_an_album_without_a_title_falls_back_to_the_subtitle(self):
        self.assertEqual(track(album={"id": 5, "title": ""}, subtitle="Single").album, "Single")

    def test_an_album_that_is_not_an_object_is_ignored(self):
        self.assertEqual(track(album=5, subtitle="").album, "")

    def test_the_state_the_panel_reads_carries_the_album(self):
        self.assertEqual(track(album={"id": 5, "title": "Irony"}).to_dict()["album"], "Irony")


if __name__ == "__main__":
    unittest.main()
