"""«Моя музыка» is ordered by when a track was liked, newest first.

VK keeps the like time in `date` and hands the section back in its own layout: live,
a page of 21.10.2026 stood above a page of 07.11.2026, and the oldest track of one
page was still newer than the newest of the next. These tests pin the two halves:
the section is sorted by `date` descending, every other section keeps VK's order.

Run from the repository root:

    python3 -m unittest discover -s tests/python -v
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "backend"))

import backend  # noqa: E402
import vk_api  # noqa: E402

ALL = "PUldVA8FR0RzSVNUWE1JSmRSS0wEGEleZFFfTgQAWldyWFEL"


def track(number: int, date: int | None) -> vk_api.Track:
    return vk_api.Track.from_item({
        "id": number,
        "owner_id": 1,
        "title": f"Track {number}",
        "artist": "Artist",
        "duration": 100,
        "date": date,
    })


class FakeSectionClient:
    def __init__(self, url: str, audios: list[vk_api.Track]) -> None:
        self.url = url
        self.audios = audios
        self.calls: list[dict] = []

    def sections(self):
        return [vk_api.Section(id=ALL, title="Моя музыка", url=self.url)]

    def section(self, section_id: str, *, start_from: str | None = None):
        self.calls.append({"id": section_id, "start_from": start_from})
        return vk_api.SectionBlocks(
            id=section_id, title="", next_offset="", url=self.url,
            audios=tuple(self.audios), playlists=(),
        )


class StubPlayer(backend.Player):
    """`section_items` without the account, the lock or the network."""

    def __init__(self, client: FakeSectionClient) -> None:
        self.client = client

    def api(self, function):  # noqa: ANN001 - the real signature is a callable
        return function()


class MyMusicOrderTest(unittest.TestCase):
    def test_the_section_is_newest_like_first_and_keeps_vks_dates(self):
        # The order VK answered with is its own layout, not a date order: the first
        # item is older than the second, and an undated item sits in between.
        client = FakeSectionClient(
            "https://vk.ru/audios681411438?section=all",
            [track(1, 1_000), track(2, 3_000), track(3, None), track(4, 2_000)],
        )
        page = StubPlayer(client).section_items(ALL)

        self.assertEqual([t["audio_id"] for t in page["tracks"]], [2, 4, 1, 3])
        self.assertEqual([t["date"] for t in page["tracks"]], [3_000, 2_000, 1_000, 0])

    def test_the_slug_names_the_same_section(self):
        client = FakeSectionClient(
            "https://vk.ru/audios681411438?section=all",
            [track(1, 1_000), track(2, 3_000)],
        )
        page = StubPlayer(client).section_items("all")

        self.assertEqual([t["audio_id"] for t in page["tracks"]], [2, 1])

    def test_another_section_keeps_vks_order(self):
        # The editorial order of a section is the content; sorting it by like time
        # would replace it with a list VK never intended.
        client = FakeSectionClient(
            "https://vk.ru/audios681411438?section=explore",
            [track(1, 1_000), track(2, 3_000)],
        )
        page = StubPlayer(client).section_items("PUldVA8FR0RzEXPLORE01")

        self.assertEqual([t["audio_id"] for t in page["tracks"]], [1, 2])

    def test_each_more_page_is_sorted_on_its_own(self):
        # The pages are cut by date, so sorting each one in place also sorts the list
        # the panel concatenates. A page that ignored the sort would land its oldest
        # track under the newest of the page above it.
        client = FakeSectionClient(
            "https://vk.ru/audios681411438?section=all",
            [track(2, 500), track(1, 900)],
        )
        page = StubPlayer(client).section_items(ALL, offset="cursor")

        self.assertEqual(client.calls, [{"id": ALL, "start_from": "cursor"}])
        self.assertEqual([t["audio_id"] for t in page["tracks"]], [1, 2])

    def test_the_state_a_list_travels_in_carries_the_like_time(self):
        state = backend.track_to_state(track(1, 1_700_000_000))
        self.assertEqual(state["date"], 1_700_000_000)
        self.assertEqual(backend.track_to_state(backend.track_from_state(state)), state)


if __name__ == "__main__":
    unittest.main()
