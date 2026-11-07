# ADR-0004: a saved playlist is a copy under my own ids

Status: accepted, 2026-11-07.

## Context

The panel could open anybody's playlist and play it, and nothing else: there was no
way to keep one, and no way to hand one to somebody. VK's audio API has no
bookmark verb — `fave.getUsers` and `bookmarks.getBookmarks` answer «Unknown method
passed» — so the question was what the service does offer, and it was answered live
before anything was drawn:

* `audio.followPlaylist(owner_id, playlist_id, access_key)` returns `1`, and the
  list turns up in `audio.getPlaylists(owner_id=me)` — not as a reference but as a
  **copy under my own ids**, carrying `original_owner_id` and
  `original_playlist_id` to say which list it was.
* There is no unfollow method. `audio.unfollowPlaylist` answers «Unknown method
  passed» (error 3).
* `audio.deletePlaylist(owner_id=me, playlist_id=copy)` removes the copy and drops
  the original's follower count by one. Pointed at the original it answers error 15
  — a playlist that is not mine is never deleted — which is the safety that lets the
  same verb serve both «remove this saved list» and «delete my own playlist».
* `audio.getPlaylists(owner_id=me)` is **empty until something is saved**. That is
  why the design earlier concluded playlists come only from the catalog; the saved
  list has no other home, so it is also the only source for a page of saved lists.
* A search result carries `permissions.follow`. The generated blocks (`Для вас`,
  `Открытия`) do not, and following one is not offered at all.

## Decision

1. **The key of a playlist is the original's.** `owner_id_playlist_id` names the
   list a person means, and the same list arrives in three shapes — a card in a
   section, a search result, a copy on the saved page — so one key must mark all
   three. The ids of the copy ride beside it (`copy_owner_id`,
   `copy_playlist_id`) and are what a removal names.
2. **Saving is optimistic on screen and corrected by the answer.** The lists are
   marked the moment the heart is pressed, then replaced by the daemon's answer:
   `{following, playlist}` with the authoritative state and the copy's ids, or the
   previous state if the call was refused. A heart that fills a second late reads as
   a heart that did not hear the click.
3. **Removal is found by the daemon, not by the panel.** The panel may be looking at
   a search result it never saved, so it cannot name the copy. `playlist_follow`
   with `following: false` looks the copy up in `audio.getPlaylists(me)` by the
   original's ids and removes that; a list that is not saved is a no-op.
4. **Only a followable list gets a heart.** `permissions.follow` decides, and the
   generated lists have no heart on the cover at all: a control that cannot work is
   worse than no control, and the cover has no room to explain itself.
5. **The link is built from the original's ids** —
   `https://vk.com/music/playlist/<owner_id>_<playlist_id>_<access_key>` — by the
   daemon, once, for both the card and the open list. The copy's link would open a
   playlist of mine that the recipient cannot see, and a playlist without an
   `access_key` is not reachable by somebody who does not own it.
6. **Copying is `Quickshell.clipboardText`**, not `wl-copy` behind the daemon: the
   daemon is a service under `ProtectHome=read-only` with no session of its own, and
   the panel already runs inside the shell.
7. **«Избранное» is a page of the browse view with a chip of its own**, beside
   «Люди» and for the same reason: it is a way in, not a catalog section, and the
   «Разделы» setting must not be able to hide the saved lists.

## Consequences

* `Playlist` carries `original_owner_id`, `original_playlist_id`,
  `original_access_key`, `is_following`, `can_follow` and `link`; the panel's
  `Follows.mark` is the one place that spreads a save across the lists that hold
  it, for the same reason `Likes.mark` exists (a delegate is handed a copy of its
  element).
* A save changes what «Избранное» holds, so that page is re-answered after every
  save and removal instead of being patched locally.
* The status line can confirm a copy for three seconds. It is the one line in the
  card that says something without moving anything.
* The account's follower count changes on a save and returns on a removal — the
  same side effect VK's own «В мою музыку» has, on the user's own account.
* `audio.getPlaylists(me)` is now a fetch the panel makes repeatedly (the saved
  page), where before it was a probe that had once answered empty.

## Alternatives rejected

* **Following by creating a playlist and copying tracks.** Rejected: the copy VK
  makes is one call, keeps the original's cover and title, and stays linked to the
  original — a hand-made copy would drift from it and cost one call per track.
* **Marking the saved page from local state only.** Rejected: VK is the only place
  that knows what is saved, and the panel can be restarted at any time.
* **Unfollowing by `audio.deletePlaylist` on the original's ids.** Rejected: VK
  refuses it with error 15, and the danger is not theoretical — the same verb
  deletes a playlist of mine when it is pointed at one, so the ids must be the
  copy's.
* **A heart on every card, greyed out where it cannot work.** Rejected: on a cover
  100 px wide there is no room to say why, and a press that does nothing is the
  reading a person arrives at first.
* **Opening the link instead of copying it.** Rejected: the panel has no room for a
  browser, and a playlist link is usually going into a chat.
