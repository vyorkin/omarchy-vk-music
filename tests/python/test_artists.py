"""The artist search, the artist page and its whole list of tracks.

`audio.searchArtists` answers with as many items as asked for and no total, so a
full page is what says another may follow. `catalog.getAudioArtist` names the
artist's section and `catalog.getSection` fills it, with the card at the top
level of the section answer rather than inside it. `audio.getAudiosByArtist`
does carry a total, and that is what the page's «Ещё» reads.

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


def track_item(number: int) -> dict:
    return {
        "id": number,
        "owner_id": 1,
        "title": f"Track {number}",
        "artist": "King Crimson",
        "main_artists": [{"id": "170", "name": "King Crimson"}],
        "duration": 200,
    }


def fake_artist(number: int) -> dict:
    return {
        "id": str(1000 + number),
        "name": f"Artist {number}",
        "photo_200": f"https://example.invalid/{number}.jpg",
    }


class FakeArtistClient:
    def __init__(self, search_page: int = 0, artist_tracks: int = 0, total: int = 0) -> None:
        self.search_page = search_page
        self.artist_tracks = artist_tracks
        self.total = total
        self.searches: list[dict] = []
        self.sections: list[dict] = []
        self.all_tracks: list[dict] = []

    def search_artists(self, query: str, *, count: int, offset: int):
        self.searches.append({"query": query, "count": count, "offset": offset})
        return [vk_api.Artist.from_item(fake_artist(offset + i))
                for i in range(self.search_page)]

    def artist_section(self, *, artist_id: str = "", url: str = ""):
        self.sections.append({"artist_id": artist_id, "url": url})
        return vk_api.Section(id="artist-section", title="King Crimson", url=url)

    def section(self, section_id: str, *, start_from: str | None = None):
        return vk_api.SectionBlocks(
            id=section_id,
            title="King Crimson",
            next_offset="",
            url="https://vk.ru/artist/170",
            audios=(vk_api.Track.from_item(track_item(1)),),
            playlists=(vk_api.Playlist.from_item({"id": 7, "owner_id": -1,
                                                  "title": "Red", "type": "album"}),),
            artists=(vk_api.Artist.from_item(fake_artist(1)),),
            links=(),
        )

    def audios_by_artist(self, artist_id: str, *, count: int, offset: int):
        self.all_tracks.append({"artist_id": artist_id, "count": count, "offset": offset})
        return ([vk_api.Track.from_item(track_item(offset + i))
                 for i in range(self.artist_tracks)], self.total)


class StubPlayer(backend.Player):
    def __init__(self, client: FakeArtistClient) -> None:
        self.client = client

    def api(self, function):  # noqa: ANN001 - the real signature is a callable
        return function()


class ArtistSearchTest(unittest.TestCase):
    def test_a_page_asks_for_the_artist_page_size_and_the_offset(self):
        client = FakeArtistClient(search_page=backend.ARTIST_SEARCH_PAGE_SIZE)
        page = StubPlayer(client).artist_search("King Crimson", offset=50)

        self.assertEqual(client.searches, [{
            "query": "King Crimson",
            "count": backend.ARTIST_SEARCH_PAGE_SIZE,
            "offset": 50,
        }])
        self.assertEqual(len(page["artists"]), backend.ARTIST_SEARCH_PAGE_SIZE)
        self.assertTrue(page["more"])

    def test_a_short_page_is_the_end(self):
        client = FakeArtistClient(search_page=2)
        page = StubPlayer(client).artist_search("King Crimson")

        self.assertEqual(len(page["artists"]), 2)
        self.assertFalse(page["more"])

    def test_an_empty_query_never_reaches_vk(self):
        client = FakeArtistClient(search_page=1)
        page = StubPlayer(client).artist_search("   ")

        self.assertEqual(client.searches, [])
        self.assertEqual(page, {"query": "", "artists": [], "more": False})


class ArtistPageTest(unittest.TestCase):
    def test_the_page_carries_the_card_the_popular_tracks_and_the_records(self):
        client = FakeArtistClient()
        page = StubPlayer(client).artist(id="170")

        self.assertEqual(client.sections, [{"artist_id": "170", "url": ""}])
        self.assertEqual(page["artist"]["name"], "Artist 1")
        self.assertEqual(page["artist"]["id"], "1001")
        self.assertEqual([t["title"] for t in page["tracks"]], ["Track 1"])
        self.assertEqual([p["title"] for p in page["playlists"]], ["Red"])
        self.assertEqual(page["url"], "https://vk.ru/artist/170")

    def test_a_page_without_a_key_is_refused(self):
        with self.assertRaises(vk_api.VkApiError):
            StubPlayer(FakeArtistClient()).artist()


class ArtistTracksTest(unittest.TestCase):
    def test_the_total_says_whether_another_page_exists(self):
        client = FakeArtistClient(artist_tracks=200, total=200)
        page = StubPlayer(client).artist_tracks(artistId="170")

        self.assertEqual(client.all_tracks, [{
            "artist_id": "170",
            "count": backend.ARTIST_TRACK_PAGE_SIZE,
            "offset": 0,
        }])
        self.assertEqual(len(page["tracks"]), 200)
        self.assertEqual(page["total"], 200)
        self.assertFalse(page["more"])

    def test_a_page_before_the_total_has_another(self):
        client = FakeArtistClient(artist_tracks=100, total=300)
        page = StubPlayer(client).artist_tracks(artistId="170", offset=100)

        self.assertEqual(client.all_tracks[0]["offset"], 100)
        self.assertTrue(page["more"])

    def test_an_artist_without_an_id_is_refused(self):
        with self.assertRaises(vk_api.VkApiError):
            StubPlayer(FakeArtistClient()).artist_tracks()


class ArtistCallTest(unittest.TestCase):
    def test_the_search_asks_for_its_page_size(self):
        client = vk_api.VkClient("token")
        calls: list[tuple[str, dict]] = []

        def call(method, **params):  # noqa: ANN001 - the client's own transport
            calls.append((method, params))
            return {"count": 1, "items": [fake_artist(1)]}

        client.call = call  # type: ignore[method-assign]
        artists = client.search_artists("King Crimson", count=50, offset=100)

        self.assertEqual(calls, [(
            "audio.searchArtists",
            {"q": "King Crimson", "count": 50, "offset": 100},
        )])
        self.assertEqual([artist.id for artist in artists], ["1001"])

    def test_the_whole_list_reports_vks_total(self):
        client = vk_api.VkClient("token")
        calls: list[tuple[str, dict]] = []

        def call(method, **params):  # noqa: ANN001 - the client's own transport
            calls.append((method, params))
            return {"count": 200, "items": [track_item(1), track_item(2)]}

        client.call = call  # type: ignore[method-assign]
        tracks, total = client.audios_by_artist("170", count=300, offset=0)

        self.assertEqual(calls, [(
            "audio.getAudiosByArtist",
            {"artist_id": "170", "count": 300, "offset": 0},
        )])
        self.assertEqual(len(tracks), 2)
        self.assertEqual(total, 200)

    def test_the_artist_section_is_read_by_its_id(self):
        client = vk_api.VkClient("token")
        calls: list[tuple[str, dict]] = []

        def call(method, **params):  # noqa: ANN001 - the client's own transport
            calls.append((method, params))
            return {"catalog": {"default_section": "",
                                "sections": [{"id": "artist-section",
                                              "title": "King Crimson"}]}}

        client.call = call  # type: ignore[method-assign]
        section = client.artist_section(artist_id="170")

        self.assertEqual(calls, [("catalog.getAudioArtist",
                                  {"artist_id": "170", "url": None})])
        self.assertEqual(section.id, "artist-section")


class ArtistStateTest(unittest.TestCase):
    def test_the_ids_of_the_artist_links_survive_a_queue_round_trip(self):
        track = vk_api.Track.from_item(track_item(1))
        state = backend.track_to_state(track)
        again = backend.track_to_state(backend.track_from_state(state))

        self.assertEqual(again["artists"], [{"id": "170", "name": "King Crimson"}])
        self.assertEqual(again, state)


if __name__ == "__main__":
    unittest.main()
