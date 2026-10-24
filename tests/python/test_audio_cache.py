"""How a track reaches ffmpeg.

The URL ffmpeg is given is a signed link, so it must not appear in the command:
`/proc/<pid>/cmdline` is world readable and the link works from this machine
for anyone who copies it. These tests pin that down without VK, mpv or a network.

Run from the repository root:

    python3 -m unittest discover -s tests/python -v
"""

from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "backend"))

import audio_cache  # noqa: E402
from audio_cache import AudioCache, CacheError  # noqa: E402

SIGNED = "https://cs1-3.vk.com/audio/abc/def.mp3?extra=base64&sig=deadbeef0123"


class FakeFfmpeg:
    """Stands in for the process, recording what it was asked to open."""

    def __init__(self, succeed: bool = True) -> None:
        self.succeed = succeed
        self.calls: list[list[str]] = []
        self.playlists: list[tuple[Path, str, int]] = []

    def __call__(self, command, tmp, on_progress=None):
        self.calls.append(command)
        playlist = Path(command[command.index("-i") + 1])
        self.playlists.append(
            (playlist, playlist.read_text(encoding="utf-8"), playlist.stat().st_mode & 0o777)
        )
        if self.succeed:
            tmp.write_bytes(b"ID3 fake audio")
            return True, ""
        return False, "boom"


class ConcatenatedInputTest(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        self.cache = AudioCache(Path(self.directory.name))

    def tearDown(self) -> None:
        self.directory.cleanup()

    def test_the_signed_url_stays_out_of_the_command_line(self) -> None:
        ffmpeg = FakeFfmpeg()
        self.cache._run_ffmpeg = ffmpeg

        self.cache.download(SIGNED, "1_42")

        self.assertEqual(len(ffmpeg.calls), 1)
        joined = " ".join(ffmpeg.calls[0])
        self.assertNotIn("sig=deadbeef0123", joined)
        self.assertNotIn("cs1-3.vk.com", joined)
        self.assertIn("file 'https://cs1-3.vk.com/audio/abc/def.mp3?extra=base64&sig=deadbeef0123'",
                      ffmpeg.playlists[0][1])

    def test_the_playlist_is_readable_only_by_its_owner(self) -> None:
        ffmpeg = FakeFfmpeg()
        self.cache._run_ffmpeg = ffmpeg

        self.cache.download(SIGNED, "1_42")

        self.assertEqual(ffmpeg.playlists[0][2], 0o600)

    def test_the_playlist_does_not_outlive_the_download(self) -> None:
        ffmpeg = FakeFfmpeg()
        self.cache._run_ffmpeg = ffmpeg

        self.cache.download(SIGNED, "1_42")

        self.assertFalse(ffmpeg.playlists[0][0].exists())

    def test_the_playlist_goes_even_when_ffmpeg_fails(self) -> None:
        ffmpeg = FakeFfmpeg(succeed=False)
        self.cache._run_ffmpeg = ffmpeg

        with self.assertRaises(CacheError):
            self.cache.download(SIGNED, "1_42")

        self.assertTrue(ffmpeg.playlists)
        for playlist, _, _ in ffmpeg.playlists:
            self.assertFalse(playlist.exists())

    def test_the_demuxer_is_told_it_may_follow_an_https_url(self) -> None:
        ffmpeg = FakeFfmpeg()
        self.cache._run_ffmpeg = ffmpeg

        self.cache.download(SIGNED, "1_42")

        command = ffmpeg.calls[0]
        self.assertEqual(command[command.index("-f") + 1], "concat")
        self.assertEqual(command[command.index("-safe") + 1], "0")
        whitelist = command[command.index("-protocol_whitelist") + 1].split(",")
        for protocol in ("file", "crypto", "http", "https", "tcp", "tls"):
            self.assertIn(protocol, whitelist)

    def test_a_quote_in_the_url_cannot_break_out_of_the_line(self) -> None:
        line = audio_cache._concat_entry("https://x/y'z\\w.mp3")
        self.assertEqual(line, "file 'https://x/y'\\''z\\\\w.mp3'\n")

    def test_the_second_attempt_reencodes_with_the_same_playlist(self) -> None:
        ffmpeg = FakeFfmpeg(succeed=False)
        self.cache._run_ffmpeg = ffmpeg

        with self.assertRaises(CacheError):
            self.cache.download(SIGNED, "1_42")

        self.assertEqual(len(ffmpeg.calls), 2)
        self.assertEqual(ffmpeg.calls[1][ffmpeg.calls[1].index("-c:a") + 1], "libmp3lame")
        self.assertEqual(ffmpeg.playlists[0][0], ffmpeg.playlists[1][0])


if __name__ == "__main__":
    unittest.main()
