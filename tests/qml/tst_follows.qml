// Marking a saved playlist across the lists that hold it.
//
// The failure this guards is the one `tst_likes.qml` guards for tracks: the card's heart is
// drawn from the element the delegate was handed, and a delegate over a JS array model is
// handed a COPY. Writing `is_following` into an entry of the stored list changes the list
// and nothing on screen, so a save looks like it did not happen while VK already holds the
// playlist. `Follows.mark` answers with a new list for exactly that reason.
//
// The second half is the key: a followed list lives under MY ids as a copy of the original,
// so the card of the original, the copy on «Избранное» and the open playlist all answer to
// the key of the ORIGINAL. Marking by the copy's own place would edit one of them.
//
// Run:
//   QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -import tests/qml -input tests/qml
import QtQuick
import QtTest
import "../../Follows.js" as Follows

TestCase {
  name: "Follows"
  when: windowShown
  width: 320
  height: 200

  // The panel's own shape, cut down: a list of playlist cards, each reading one element.
  Item {
    id: panel
    property var playlists: []

    Column {
      Repeater {
        id: cards
        model: panel.playlists
        delegate: Item {
          width: 100
          height: 16
          property var item: modelData
          property bool filled: item ? item.is_following === true : false
        }
      }
    }

    function markFollowing(key, following, copyOwner, copyPlaylist) {
      playlists = Follows.mark(playlists, key, following, copyOwner, copyPlaylist)
    }
  }

  function playlistsOfMine() {
    panel.playlists = [
      { key: "1_10", title: "Ночной", is_following: false },
      { key: "2_20", title: "Гроза", is_following: false },
      { key: "3_30", title: "Штиль", is_following: true, copy_owner_id: 7, copy_playlist_id: 30 }
    ]
  }

  function test_the_card_heart_fills_after_a_save() {
    playlistsOfMine()
    compare(cards.count, 3)
    compare(cards.itemAt(0).filled, false, "the card starts an outline")
    panel.markFollowing("1_10", true, 9, 10)
    compare(cards.itemAt(0).filled, true, "the card of the saved playlist is filled")
    compare(cards.itemAt(1).filled, false, "another card keeps its heart")
    compare(cards.itemAt(2).filled, true, "a saved list stays saved")
  }

  function test_removing_empties_the_heart_again() {
    playlistsOfMine()
    panel.markFollowing("3_30", false, 0, 0)
    compare(cards.itemAt(2).filled, false)
    compare(cards.itemAt(2).item.copy_owner_id, 0, "the ids of the copy are dropped with it")
  }

  // The trap itself, kept as a test: this is what an in-place edit does to the panel.
  function test_editing_the_playlist_in_place_is_invisible() {
    playlistsOfMine()
    panel.playlists[0].is_following = true
    compare(panel.playlists[0].is_following, true)
    compare(cards.itemAt(0).filled, false, "the delegate was given a copy, not the element")
  }

  function test_a_list_with_nothing_to_change_is_the_same_list() {
    playlistsOfMine()
    var before = panel.playlists
    compare(Follows.mark(before, "9_90", true, 1, 1) === before, true, "another key changes nothing")
    compare(Follows.mark(before, "1_10", false, 0, 0) === before, true, "the state already holds")
    compare(Follows.mark(null, "1_10", true, 1, 1), null)
    compare(Follows.mark([], "1_10", true, 1, 1).length, 0)
  }

  // The ids of the copy are what an unfollow needs: a remove call names the playlist it is
  // removing, and pointing it at the original deletes a playlist that is not mine.
  function test_the_copy_ids_are_carried_with_the_state() {
    playlistsOfMine()
    var after = Follows.mark(panel.playlists, "1_10", true, 9, 10)
    compare(after[0].is_following, true)
    compare(after[0].copy_owner_id, 9)
    compare(after[0].copy_playlist_id, 10)
    var gone = Follows.mark(after, "1_10", false, 9, 10)
    compare(gone[0].is_following, false)
    compare(gone[0].copy_owner_id, 0, "a removed list is nobody's copy")
  }

  function test_the_given_list_is_not_edited() {
    playlistsOfMine()
    var before = panel.playlists
    var after = Follows.mark(before, "1_10", true, 9, 10)
    compare(after === before, false)
    compare(before[0].is_following, false, "the old list kept the old state")
    compare(after[1] === before[1], true, "the untouched playlists are the same objects")
  }

  // The card of the original, the copy on «Избранное» and the open playlist are three
  // elements with one key, and the heart is one fact about all of them.
  function test_every_entry_of_the_key_is_marked() {
    panel.playlists = [
      { key: "5_50", title: "a", owner_id: 5, playlist_id: 50, is_following: false },
      { key: "5_50", title: "a", owner_id: 9, playlist_id: 50,
        copy_owner_id: 9, copy_playlist_id: 50, is_following: false }
    ]
    panel.markFollowing("5_50", true, 9, 50)
    compare(cards.itemAt(0).filled, true)
    compare(cards.itemAt(1).filled, true)
    compare(cards.itemAt(0).item.owner_id, 5, "the original keeps its own ids")
  }
}
