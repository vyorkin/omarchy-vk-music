// The daemon's own words: refusals and notices arrive as codes, and this is where they
// become sentences a person can read.
//
// Two shapes come out of the service, and both are tested here because both fail the same
// silent way: a code with no template used to mean an empty status line, which looks like
// «nothing happened» rather than like a translation missing.
//
//   failure(language, {code, params})  — a refusal, from the command's answer
//   message(language, {code, params})  — a notice or a halt, from the status
//
// Run:
//   QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -import tests/qml -input tests/qml
import QtQuick
import QtTest
import "../../i18n.js" as I18n

TestCase {
  name: "I18nMessages"

  function test_a_refusal_becomes_a_translated_sentence() {
    var error = { code: "vk_error", params: { reason: "flood_control", detail: "too many" } }
    compare(I18n.failure("ru", error), "VK: VK ограничивает запросы — too many")
    compare(I18n.failure("en", error), "VK: VK is limiting requests — too many")
  }

  // The reason inside a phrase is a code too, and it must be translated *before* it is
  // substituted — otherwise a Russian sentence quotes an English word.
  function test_the_reason_inside_a_phrase_is_translated_too() {
    var error = { code: "halted", params: { reason: "captcha" } }
    compare(I18n.failure("ru", error), "Остановлено: нужна капча")
    compare(I18n.failure("de", error), "Angehalten: ein Captcha ist nötig")
  }

  // A missing tail takes its separator with it: no phrase ends on a dash.
  function test_a_missing_parameter_leaves_no_dangling_separator() {
    var error = { code: "vk_error", params: { reason: "flood_control" } }
    compare(I18n.failure("en", error), "VK: VK is limiting requests")
    compare(I18n.failure("ru", { code: "bad_request", params: {} }), "Сервис отклонил запрос")
  }

  // A code nobody translated is printed as the code. That is ugly on purpose: an empty
  // line reads as «the panel did nothing», and nobody investigates that.
  function test_an_unknown_code_is_printed_as_the_code() {
    compare(I18n.failure("ru", { code: "brand_new_failure", params: {} }), "brand_new_failure")
    compare(I18n.message("ru", { code: "brand_new_notice", params: {} }), "brand_new_notice")
  }

  function test_a_notice_fills_the_track_and_the_reason() {
    var notice = { code: "track_skipped", params: { label: "Kino — Gruppa Krovi", reason: "unplayable" } }
    compare(I18n.message("en", notice), "Skipped “Kino — Gruppa Krovi”: unplayable")
    compare(I18n.message("ru", notice), "Пропущен трек «Kino — Gruppa Krovi»: unplayable")
  }

  // Every language answers for every key: a half-translated panel falls back to English
  // rather than to an empty line.
  function test_every_language_answers_every_key() {
    var missing = []
    for (var key in I18n.MESSAGES) {
      for (var i = 0; i < I18n.LANGUAGES.length; i++) {
        var language = I18n.LANGUAGES[i].code
        var value = I18n.MESSAGES[key][language]
        if (value === undefined || value === "") missing.push(key + "/" + language)
      }
    }
    compare(missing.join(","), "")
  }

  // A halt is looked up by its reason: «stopped» alone would not say what to do.
  function test_a_halt_names_its_reason() {
    compare(I18n.message("en", { code: "halted", params: { reason: "token_rejected" } }),
      "VK rejected the session. Sign in again.")
    compare(I18n.message("en", { code: "halted", params: { reason: "nobody_knows" } }),
      "The player is stopped: nobody_knows")
    compare(I18n.message("en", null), "")
    compare(I18n.message("en", ""), "")
  }

  // -- the keys -------------------------------------------------------------------

  // The sheet the «?» opens is the table, row for row: the keys as one column and the words
  // beside them. It used to be a parser of a translated sentence, and a word the parser
  // guessed wrong was a row of help that said the wrong thing about a key.
  function test_the_sheet_is_the_table() {
    var rows = I18n.hintRows("en")
    compare(rows.length, I18n.KEYS.length)
    compare(rows[0].keys, "Space")
    compare(rows[0].what, "pause")
    // The brackets stay apart, because they are a pair the reader presses twice.
    compare(rows[5].keys, "[ ]")
    compare(rows[7].what, "close")
    compare(I18n.hintRows("ru")[7].what, "закрыть")
  }

  // Every word in the table is a key, so a language that is missing one shows the key and
  // the test says which.
  function test_every_key_word_is_translated() {
    var missing = []
    for (var i = 0; i < I18n.KEYS.length; i++) {
      var word = I18n.KEYS[i].what
      var row = I18n.T[word]
      for (var l = 0; l < I18n.LANGUAGES.length; l++) {
        var language = I18n.LANGUAGES[l].code
        // The row itself, not the translated string: Ukrainian and Russian share the
        // spelling of «пауза», and a comparison of strings would call that a fallback.
        if (!row || row[language] === undefined || row[language] === "") {
          missing.push(word + "/" + language)
        }
      }
    }
    compare(missing.join(","), "")
  }

  // -- the labels -----------------------------------------------------------------

  function test_counted_nouns_take_the_languages_own_forms() {
    compare(I18n.plural("en", 1, "трек", "трека", "треков"), "трек")
    compare(I18n.plural("en", 2, "трек", "трека", "треков"), "треков")
    compare(I18n.plural("ru", 1, "трек", "трека", "треков"), "трек")
    compare(I18n.plural("ru", 3, "трек", "трека", "треков"), "трека")
    compare(I18n.plural("ru", 11, "трек", "трека", "треков"), "треков")
    compare(I18n.plural("ja", 5, "трек", "трека", "треков"), "треков")
  }

  function test_a_duration_reads_in_hours_and_minutes() {
    compare(I18n.span("ru", 0), "")
    // The unit keys carry their own spacing — «ч » has a trailing space, «мин» none —
    // which is what the panel has always shown: «6ч 55мин».
    compare(I18n.span("ru", 90), "2мин")
    compare(I18n.span("ru", 3720), "1ч 2мин")
    compare(I18n.span("en", 3720), "1 h 2 min")
    // A track with no length of its own adds nothing: a station is not a two-hour track.
    compare(I18n.tracksSpan("ru", [{ duration: 60 }, { duration: 0 }, { duration: 60 }]), "2мин")
  }

  function test_a_summary_counts_and_measures() {
    var tracks = [{ duration: 1800 }, { duration: 1800 }, { duration: 125 }]
    compare(I18n.summary("ru", tracks, "трек", "трека", "треков"), "3 трека · 1ч 2мин")
    compare(I18n.summary("ru", [], "трек", "трека", "треков"), "")
  }
}
