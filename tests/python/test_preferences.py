"""One description of a preference, and the panel's ability to draw it.

A range, a default and a set of options used to exist three times: in the daemon's tables,
in the widget's fallback expressions, and in the sliders' `minimum`/`maximum`. Two of them
had already drifted — the daemon clamped the marquee pause to 6000 ms while the slider
offered 4000 — and nothing could notice, because no test looked at both sides.

The schema is now the only description: these tests check that it is complete, that the
tables the rest of the daemon reads are derived from it rather than written twice, and that
every key has a label in all eight languages for the panel to show.

Run from the repository root:

    python3 -m unittest discover -s tests/python -v
"""

from __future__ import annotations

import os
import re
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "backend"))

_TMP = tempfile.mkdtemp(prefix="vkmusic-prefs-")
os.environ.setdefault("HOME", _TMP)
os.environ.setdefault("XDG_CONFIG_HOME", str(Path(_TMP) / ".config"))
os.environ.setdefault("XDG_CACHE_HOME", str(Path(_TMP) / ".cache"))

import backend  # noqa: E402

KINDS = {"switch", "number", "choice", "ordered", "list", "text"}
LANGUAGES = ("en", "de", "es", "fr", "ja", "zh", "uk", "ru")


class Schema(unittest.TestCase):
    def test_every_entry_describes_itself(self):
        for key, spec in backend.PREFERENCE_SCHEMA.items():
            with self.subTest(key=key):
                self.assertIn(spec.get("kind"), KINDS)
                self.assertIn("default", spec)
                if spec["kind"] == "number":
                    self.assertLess(spec["min"], spec["max"])
                    self.assertGreater(spec["step"], 0)
                    self.assertGreaterEqual(spec["default"], spec["min"])
                    self.assertLessEqual(spec["default"], spec["max"])
                if spec["kind"] == "choice":
                    self.assertGreaterEqual(len(spec["options"]), 2)
                    self.assertIn(spec["default"], spec["options"])
                if spec["kind"] == "ordered":
                    self.assertGreaterEqual(len(spec["options"]), 2)
                    self.assertTrue(set(spec["default"]) <= set(spec["options"]))

    def test_the_derived_tables_come_from_the_schema(self):
        self.assertEqual(backend.DEFAULT_PREFERENCES,
                         {key: spec["default"] for key, spec in backend.PREFERENCE_SCHEMA.items()})
        self.assertEqual(backend.PREFERENCE_ENUMS,
                         {key: tuple(spec["options"]) for key, spec in backend.PREFERENCE_SCHEMA.items()
                          if "options" in spec})
        self.assertEqual(backend.PREFERENCE_RANGES,
                         {key: (spec["min"], spec["max"]) for key, spec in backend.PREFERENCE_SCHEMA.items()
                          if "min" in spec})

    # A default that the coercion changes is a default the panel would show differently from
    # what it stores: the two sides must agree on the value nobody chose.
    def test_every_default_survives_coercion(self):
        for key, spec in backend.PREFERENCE_SCHEMA.items():
            with self.subTest(key=key):
                self.assertEqual(backend.coerce_preference(key, spec["default"]), spec["default"])

    def test_a_value_outside_the_range_is_clamped_to_it(self):
        low, high = backend.PREFERENCE_RANGES["marqueePauseMs"]
        self.assertEqual(backend.coerce_preference("marqueePauseMs", -100), low)
        self.assertEqual(backend.coerce_preference("marqueePauseMs", 10 ** 6), high)

    def test_a_word_outside_the_options_falls_back_to_the_default(self):
        self.assertEqual(backend.coerce_preference("coverShape", "triangular"), "rounded")


class Answer(unittest.TestCase):
    def setUp(self) -> None:
        self.backend = backend.Backend()

    # The panel opens its settings from one answer, so the answer has to carry both.
    def test_the_command_returns_the_values_and_the_description(self):
        payload = self.backend.handle({"command": "preferences"})
        self.assertTrue(payload["ok"])
        self.assertEqual(payload["data"]["schema"], backend.PREFERENCE_SCHEMA)
        self.assertEqual(payload["data"]["values"], backend.DEFAULT_PREFERENCES)

    def test_writing_a_preference_returns_the_new_values(self):
        payload = self.backend.handle(
            {"command": "preferences", "set": {"marqueeSpeed": 120}})
        self.assertEqual(payload["data"]["values"]["marqueeSpeed"], 120)


class Labels(unittest.TestCase):
    """The panel shows a setting by the key `setting:<key>`, so each key needs a label."""

    def rows(self) -> dict[str, str]:
        text = (REPO / "i18n.js").read_text(encoding="utf-8")
        return {
            match.group(1): match.group(0)
            for match in re.finditer(r'^T\["(setting:[a-zA-Z]+)"\] = \{.*\}$', text, re.MULTILINE)
        }

    # `shown: False` is a setting the panel draws no labelled control for: it is reachable
    # from the command line, and it owes the panel nothing. Everything else owes a label.
    def test_every_shown_setting_has_a_label(self):
        rows = self.rows()
        missing = [
            key for key, spec in backend.PREFERENCE_SCHEMA.items()
            if spec.get("shown") is not False and f"setting:{key}" not in rows
        ]
        self.assertEqual(missing, [])

    def test_every_label_speaks_all_eight_languages(self):
        for key, line in self.rows().items():
            with self.subTest(key=key):
                for language in LANGUAGES:
                    self.assertRegex(line, rf'\b{language}: "[^"]+"')

    def test_a_label_is_not_the_key(self):
        for key, line in self.rows().items():
            with self.subTest(key=key):
                self.assertNotIn(f'ru: "{key}"', line)


if __name__ == "__main__":
    unittest.main()
