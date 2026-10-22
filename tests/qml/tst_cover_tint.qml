// The fallback a cover-less tile is drawn from: its monogram and its hue.
//
// Two things can go wrong here without any pixel changing on the screen where the
// bug was found. A monogram of the wrong word («DA» for «Death and Death-Doom») reads
// as noise, and a hue that is not stable across opens repaints the whole gallery the
// next time the popup is shown. Both are numbers and strings, so they are tested as
// such — no shell, no theme, no VK.
//
// Run:
//   QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -import tests/qml -input tests/qml
import QtQuick
import QtTest
import "../../CoverTint.js" as CoverTint

TestCase {
  name: "CoverTint"

  function test_two_letters_from_two_words() {
    compare(CoverTint.monogram("Блюз: Краткая история"), "БК")
    compare(CoverTint.monogram("Neue Deutsche Todeskunst"), "ND")
    compare(CoverTint.monogram("Arch Enemy — Doomsday Machine (2005)"), "AE")
  }

  // Short words are skipped rather than abbreviated: a conjunction is not the name
  // of the playlist, and the first letter of the first real word is what the eye needs.
  function test_short_words_do_not_become_letters() {
    compare(CoverTint.monogram("Death and Death-Doom 90s"), "DD")
    compare(CoverTint.monogram("От Disco до Rave"), "DR")
    compare(CoverTint.monogram("The Dark Side of the Moon"), "DS")
  }

  // A hyphen is a word break, not a letter: «Хоррор-панк» is two words.
  function test_punctuation_splits_words() {
    compare(CoverTint.monogram("Хоррор-панк"), "ХП")
    compare(CoverTint.monogram("blues/jazz"), "BJ")
    compare(CoverTint.monogram("«Космос»"), "К")
  }

  function test_one_word_gives_one_letter() {
    compare(CoverTint.monogram("Сын"), "С")
    compare(CoverTint.monogram("Открытия"), "О")
  }

  // Nothing to abbreviate: the tile falls back to its glyph alone.
  function test_empty_titles() {
    compare(CoverTint.monogram(""), "")
    compare(CoverTint.monogram(undefined), "")
    compare(CoverTint.monogram(null), "")
    compare(CoverTint.monogram("   ??  "), "")
  }

  function test_hue_is_stable_and_in_range() {
    compare(CoverTint.hue("Блюз: Краткая история"), CoverTint.hue("Блюз: Краткая история"))
    var titles = ["Блюз", "Cof сайд проекты", "Хоррор-панк", "Darkwave", ""]
    for (var i = 0; i < titles.length; i++) {
      var value = CoverTint.hue(titles[i])
      verify(value >= 0 && value < 360, "hue out of range for " + titles[i] + ": " + value)
    }
    compare(CoverTint.hue(""), 0)
  }

  // Neighbours on the screen must not land on the same hue: thirty cards of one
  // colour would read as one playlist.
  function test_hues_spread_over_a_screen_of_cards() {
    var titles = [
      "Блюз: Краткая история", "Краткая история джаза", "Darkwave", "EBM", "Chiptune",
      "Synthwave", "Eurodance", "Готик-рок", "Панк-рок", "Thrash-Metal", "Industrial",
      "Country \\ Кантри", "Nu-Metal", "Futurepop", "Aggrotech", "Dark Techno"
    ]
    var seen = {}
    var distinct = 0
    for (var i = 0; i < titles.length; i++) {
      var value = CoverTint.hue(titles[i])
      if (seen[value] === undefined) {
        seen[value] = true
        distinct += 1
      }
    }
    verify(distinct >= titles.length - 1, "only " + distinct + " distinct hues for " + titles.length + " titles")
  }
}
