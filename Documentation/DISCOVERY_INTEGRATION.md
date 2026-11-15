# AllDebrid + TMDb + Simkl

## Configuration and use

1. Connect AllDebrid using its existing login. Home works without a Plex, Jellyfin, Emby, or Seerr account.
2. Home → TMDb Settings: save your TMDb API Read Access Token in device Keychain (see TMDB.md).
3. Home → Simkl Account: use the existing device authorization flow. Server-free accounts use a separate stable profile scope; server-backed profiles retain their existing tracker accounts.
4. Open a movie or TV episode → Find Available Sources. The app reads existing saved video links and ready magnet files, shows every matching variant, and unlocks the selected file only when you choose it. No content is acquired or downloaded.
5. Resume is enabled by default when that title/episode has a saved unfinished position. Turn off the Resume toggle to start over. Each playback resolves a fresh URL, so expiring AllDebrid URLs never become progress identities.

My List uses Simkl's Plan to Watch bucket. Add/remove actions use the same token provider and write gate as existing scrobbling. Removing from Simkl uses its canonical history/remove endpoint, which also clears history and rating: the UI requires confirmation and describes this effect. Adding an existing watched title to Plan to Watch changes its Simkl status; no second watch-history write is made.

Continue Watching Movies and Continue Watching TV Shows use locally stored exact positions. Simkl next unwatched episodes appear in a separate Next Episodes row, without invented resume times. Watched episode indicators use Simkl's per-episode history. iOS catalog playback uses the existing PlayerWrapper/PlayerViewModel and a single TrackerPlaybackSession, including its existing watched-write retry queue. Server playback and the original AllDebrid library path remain available.

## Sync, matching, and persistence

- User interaction, foregrounding Home, and returning from catalog playback trigger sync. No unconditional background timer polls Simkl.
- A sync checks activities first. Initial sync loads movies/shows with episode history; later syncs use date_from. The checkpoint is captured before pulls and saved only after all pulls succeed. Removal activity triggers an IDs-only reconciliation. Errors retain the cached list; rate limits establish a cooldown.
- Library snapshots and playback positions are scoped to the active profile and Simkl account name, stored in UserDefaults as JSON. They contain metadata and positions, never API credentials or unlocked playback URLs. Tokens remain in the existing secure account store.
- Matching accepts explicit TMDb/IMDb markers or an exact normalized title with a compatible release year. TV matching additionally requires the exact season/episode marker. It rejects fuzzy substring matches and ambiguous multi-episode names. Select a source to choose among resolution/codec variants. Source selection remains mandatory even with one candidate.
- Simkl anime without verified TMDb season mapping is excluded from this movie/TV sync. Missing TMDb IDs remain visible as text in See All and cannot silently match another title. Very large Simkl libraries can exceed API max_items limits; the UI retains cache and shows an error rather than advancing the checkpoint.
- Catalog playback completion uses the existing Simkl 80% stop policy. Local Continue Watching completion uses 95% or an explicit playback-finished event. A title watched elsewhere can remain in local Continue Watching until played here again: local positions are deliberately not fabricated from remote status.

## Validation boundaries

HTTP-stub tests cover watchlist request shape, unresolved IDs, activity-gated sync, retained cache on error, profile isolation, strict matching and source variants. Persistence tests cover relaunch, account scopes, completion, and transient startup zero. Existing TMDb, AllDebrid, tracker and player tests remain in place. Run SwiftFormat 0.64.5 and the existing GitHub macOS/iOS/tvOS workflows. Live token authorization, real AllDebrid files, network failures during playback, and device resume require manual device validation.

## Original-work recovery audit

The accessible checkout has only the two original PR #2 commits (`782b6b8`, `4aed664`) beyond base `121d700`. PR #2 originally changed seven files. All available local/remote branches and reflogs were inspected and `git fsck --full --no-reflogs --unreachable` found no additional commit objects. Workspace directories contained no other usable checkout, patch, or Git bundle. The repository's older build-check ZIP is a source archive, not the missing commit.

No SHA, patch, or accessible workspace for the reported 31-file commit was supplied. It could not be compared file-by-file or transferred. **The original changes were not recovered.** The missing capabilities reimplemented here are Simkl library read/sync and My List mutation, server-free Simkl account access, separate Continue Watching rails, strict catalog-to-AllDebrid matching, source selection, local resume persistence and player callbacks, and catalog scrobbling. No files were added to meet a count. If the original commit later becomes available, compare it against this branch before transferring any additional changes.
