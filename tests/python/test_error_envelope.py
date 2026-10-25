"""The envelope every refusal travels in, and the reason codes inside it.

The panel reads `code` and `params` and nothing else, so these two are the interface:
a sentence may be reworded, translated or dropped without breaking the interface, while
a reason code cannot be added or renamed without a template on the panel side. That is
what makes them worth a test of their own.

The sentences stay for the two adapters a human reads — the CLI and the journal.

Run from the repository root:

    python3 -m unittest discover -s tests/python -v
"""

from __future__ import annotations

import os
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "backend"))

# The backend reads its state and cache from the user's directories at import time.
_TMP = tempfile.mkdtemp(prefix="vkmusic-envelope-")
os.environ.setdefault("HOME", _TMP)
os.environ.setdefault("XDG_CONFIG_HOME", str(Path(_TMP) / ".config"))
os.environ.setdefault("XDG_CACHE_HOME", str(Path(_TMP) / ".cache"))

import backend  # noqa: E402
from vk_api import VkApiError, VkHaltError, classify, describe  # noqa: E402


class ReasonCodes(unittest.TestCase):
    def test_vk_codes_become_reasons(self):
        self.assertEqual(classify(VkApiError(5, "authorization failed")), "token_rejected")
        self.assertEqual(classify(VkApiError(9, "flood control")), "flood_control")
        self.assertEqual(classify(VkApiError(14, "captcha")), "captcha")
        self.assertEqual(classify(VkApiError(6, "too many")), "rate_limited")
        self.assertEqual(classify(VkApiError(3, "unknown method")), "method_unavailable")
        self.assertEqual(classify(VkApiError(500, "boom")), "vk_error")

    def test_an_audio_denial_is_named_before_the_numeric_code(self):
        for code in (15, 200, 201):
            self.assertEqual(classify(VkApiError(code, "denied")), "no_audio_access")

    def test_our_own_refusal_names_itself(self):
        error = VkApiError(0, "person not found: kino", reason="person_not_found")
        self.assertEqual(classify(error), "person_not_found")
        # A code-0 error with no reason is still a refusal, not a VK failure.
        self.assertEqual(classify(VkApiError(0, "something")), "request_refused")

    def test_every_reason_has_a_sentence_for_the_journal(self):
        reasons = set()
        reasons.update(backend.HALT_REASONS.values())
        for code in (3, 5, 6, 9, 14, 15, 200, 201, 500):
            reasons.add(classify(VkApiError(code, "x")))
        for reason in reasons:
            sentence = describe(reason)
            self.assertNotIn("vk error:", sentence, reason)
            self.assertTrue(sentence)

    def test_an_unknown_reason_still_says_something(self):
        self.assertEqual(describe("who_knows"), "vk error: who_knows")


class Envelope(unittest.TestCase):
    def test_the_halt_reasons_are_the_three_that_stop_traffic(self):
        self.assertEqual(backend.HALT_REASONS, {5: "token_rejected", 9: "flood_control", 14: "captcha"})

    def test_a_refusal_carries_a_code_and_params(self):
        payload = backend.error_payload("vk_error", "person not found", {"reason": "person_not_found"})
        self.assertFalse(payload["ok"])
        self.assertEqual(payload["error"]["code"], "vk_error")
        self.assertEqual(payload["error"]["params"], {"reason": "person_not_found"})
        self.assertEqual(payload["error"]["message"], "person not found")

    def test_params_are_optional(self):
        payload = backend.error_payload("internal_error", "boom")
        self.assertNotIn("params", payload["error"])


class Dispatch(unittest.TestCase):
    def setUp(self) -> None:
        self.backend = backend.Backend()

    def test_an_unknown_command_names_itself(self):
        payload = self.backend.handle({"command": "nowhere"})
        self.assertEqual(payload["error"]["code"], "unknown_command")
        self.assertEqual(payload["error"]["params"], {"command": "nowhere"})

    def test_a_vk_failure_carries_the_reason_and_the_detail(self):
        def explode(**_kwargs):
            raise VkApiError(0, "person not found: kino", reason="person_not_found",
                            params={"query": "kino"})

        self.backend.cmd_explode = explode
        payload = self.backend.handle({"command": "explode"})
        self.assertEqual(payload["error"]["code"], "vk_error")
        self.assertEqual(payload["error"]["params"]["reason"], "person_not_found")
        self.assertEqual(payload["error"]["params"]["query"], "kino")
        # The sentence a human reads still names the person; the panel never sees it.
        self.assertIn("person not found", payload["error"]["message"])

    def test_a_message_that_is_just_the_reason_is_not_said_twice(self):
        def explode(**_kwargs):
            raise VkApiError(9, "flood control")

        self.backend.cmd_explode = explode
        payload = self.backend.handle({"command": "explode"})
        self.assertEqual(payload["error"]["params"]["reason"], "flood_control")
        self.assertEqual(payload["error"]["message"], "flood control")

    def test_a_halt_carries_its_reason(self):
        def explode(**_kwargs):
            raise VkHaltError(VkApiError(14, "captcha needed"))

        self.backend.cmd_explode = explode
        payload = self.backend.handle({"command": "explode"})
        self.assertEqual(payload["error"]["code"], "halted")
        self.assertEqual(payload["error"]["params"], {"reason": "captcha"})

    def test_bad_arguments_are_a_refusal_not_a_crash(self):
        payload = self.backend.handle({"command": "queue_add", "keys": None, "nonsense": 1})
        self.assertEqual(payload["error"]["code"], "bad_request")
        self.assertIn("detail", payload["error"]["params"])


if __name__ == "__main__":
    unittest.main()
