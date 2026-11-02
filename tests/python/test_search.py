"""Search asks VK for a full page and says whether another page exists.

`audio.search` answers 30 items when `count` is not given, which is how a search
for an artist showed exactly 30 tracks while VK had hundreds. These tests pin the
two halves of the fix: the request carries VK's maximum page size, and the answer
tells the panel when asking for the next page is worthwhile.

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


def item(number: int) -> dict:
    return {
        "id": number,
        "owner_id": 1,
        "title": f"Track {number}",
        "artist": "Artist",
        "duration": 100,
    }


class FakeSearchClient:
    """A client whose page has a fixed size, starting at the requested offset."""

    def __init__(self, page_size: int) -> None:
        self.page_size = page_size
        self.calls: list[dict] = []

    def search(self, query: str, *, offset: int | None = None, count: int | None = None):
        self.calls.append({"query": query, "offset": offset, "count": count})
        start = offset or 0
        return [vk_api.Track.from_item(item(start + i)) for i in range(self.page_size)]


class StubPlayer(backend.Player):
    """`search_items` without the account, the lock or the network."""

    def __init__(self, client: FakeSearchClient) -> None:
        self.client = client

    def api(self, function):  # noqa: ANN001 - the real signature is a callable
        return function()


class SearchPageTest(unittest.TestCase):
    def test_the_first_page_asks_for_vks_maximum(self):
        client = FakeSearchClient(backend.SEARCH_PAGE_SIZE)
        page = StubPlayer(client).search_items("Кино")

        self.assertEqual(client.calls, [{"query": "Кино", "offset": None,
                                        "count": backend.SEARCH_PAGE_SIZE}])
        self.assertEqual(len(page["tracks"]), backend.SEARCH_PAGE_SIZE)
        self.assertTrue(page["more"])

    def test_a_short_page_is_the_end_of_the_list(self):
        client = FakeSearchClient(5)
        page = StubPlayer(client).search_items("Кино")

        self.assertEqual(len(page["tracks"]), 5)
        self.assertFalse(page["more"])

    def test_the_next_page_starts_where_the_list_ends(self):
        client = FakeSearchClient(3)
        page = StubPlayer(client).search_items("Кино", offset=300)

        self.assertEqual(client.calls[0]["offset"], 300)
        self.assertEqual(client.calls[0]["count"], backend.SEARCH_PAGE_SIZE)
        self.assertEqual(len(page["tracks"]), 3)
        self.assertFalse(page["more"])


class SearchCallTest(unittest.TestCase):
    def test_the_page_size_reaches_the_api_call(self):
        client = vk_api.VkClient("token")
        calls: list[tuple[str, dict]] = []

        def call(method, **params):  # noqa: ANN001 - the client's own transport
            calls.append((method, params))
            return {"count": 1, "items": []}

        client.call = call  # type: ignore[method-assign]
        client.search("Кино", offset=300, count=backend.SEARCH_PAGE_SIZE)

        self.assertEqual(calls, [(
            "audio.search",
            {"q": "Кино", "offset": 300, "count": backend.SEARCH_PAGE_SIZE},
        )])


if __name__ == "__main__":
    unittest.main()
