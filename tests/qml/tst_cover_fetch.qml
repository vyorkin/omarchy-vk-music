// The cover ask: which URL a tile requests, and when it stops asking.
//
// The failure these guard is a log that filled with the same 404: VK hands out the URL of
// a cover it has deleted, and every reopened gallery asked for it again — forty times in
// one boot — while the retry meant to recover a reset stream had to carry a nonce, or Qt
// would answer from its own cache of the failed URL and never reach the network.
//
// Run:
//   QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -import tests/qml -input tests/qml
import QtQuick
import QtTest
import "../../CoverFetch.js" as CoverFetch

TestCase {
  name: "CoverFetch"

  readonly property string signed: "https://cdn.example/impg/cover.jpg?size=300x300&sign=abc"

  function test_the_first_ask_is_the_source_untouched() {
    compare(CoverFetch.request(signed, 0), signed)
  }

  function test_the_retry_carries_a_nonce_after_the_existing_query() {
    compare(CoverFetch.request(signed, 1), signed + "&omarchyRetry=1")
  }

  function test_a_source_without_a_query_gets_the_nonce_behind_a_question_mark() {
    var bare = "https://cdn.example/cover.jpg"
    compare(CoverFetch.request(bare, 2), bare + "?omarchyRetry=2")
  }

  function test_a_source_that_failed_twice_is_not_asked_for_again() {
    var source = "https://cdn.example/gone.jpg?sign=dead"
    CoverFetch.mark(source)
    verify(CoverFetch.known(source))
    compare(CoverFetch.request(source, 0), "")
    compare(CoverFetch.request(source, 1), "")
    compare(CoverFetch.request(source, -1), "")
  }

  function test_giving_up_asks_for_nothing_even_before_the_source_is_marked() {
    compare(CoverFetch.request(signed, -1), "")
  }

  function test_an_empty_source_is_not_a_failure_and_is_not_asked_for() {
    CoverFetch.mark("")
    verify(!CoverFetch.known(""))
    compare(CoverFetch.request("", 0), "")
  }

  function test_one_source_is_not_another() {
    CoverFetch.mark("https://cdn.example/one.jpg")
    verify(!CoverFetch.known("https://cdn.example/two.jpg"))
  }

  function test_a_local_path_is_never_given_a_nonce() {
    compare(CoverFetch.request("/tmp/cover.jpg", 0), "/tmp/cover.jpg")
    compare(CoverFetch.request("/tmp/cover.jpg", 1), "/tmp/cover.jpg")
  }
}
