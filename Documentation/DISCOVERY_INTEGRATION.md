# AllDebrid + TMDb + Simkl

## Configuration and use

1. Connect AllDebrid using its existing login. Home works without a Plex, Jellyfin, Emby, or Seerr account.
2. Home → TMDb Settings: save your TMDb API Read Access Token in device Keychain (see TMDB.md).
3. Home → Simkl Account: use the existing device authorization flow. Server-free accounts use a separate stable profile scope; server-backed profiles retain their existing tracker accounts.
4. Open a movie or TV episode → Find Available Sources. The app reads existing saved video links and ready magnet files, shows every matching variant, and unlocks the selected file only when you choose it. No content is acquired or downloaded.
5. Resume is enabled by default when that title/episode has a saved unfinished position. Turn off the Resume toggle to start over. Each playback resolves a fresh URL, so expiring AllDebrid URLs never become progress identities.

My List uses Simkl's Plan to Watch bucket. Add/remove actions use the same token provider and write gate as existing scrobbling. Removing from Simkl uses its canonical history/remove endpoint, which also clears history and rating: the UI requires confirmation and describes this effect. Adding an existing watched title to Plan to Watch changes its Simkl status; no second watch-history write is made.

Continue Watching Movies and Continue Watching TV Shows use Simkl saved-playback percentages, with local checkpoints as an offline cache. See the cross-device update below. Simkl next unwatched episodes appear in a separate Next Episodes row, without invented resume times. Watched episode indicators use Simkl's per-episode history. iOS catalog playback uses the existing PlayerWrapper/PlayerViewModel and a single TrackerPlaybackSession, including its existing watched-write retry queue. Server playback and the original AllDebrid library path remain available.

## Sync, matching, and persistence

- User interaction, foregrounding Home, and returning from catalog playback trigger sync. No unconditional background timer polls Simkl.
- A sync checks activities first. Initial sync loads movies/shows with episode history; later syncs use date_from. The checkpoint is captured before pulls and saved only after all pulls succeed. Removal activity triggers an IDs-only reconciliation. Errors retain the cached list; rate limits establish a cooldown.
- Library snapshots and playback positions are scoped to the active profile and Simkl account name, stored in UserDefaults as JSON. They contain metadata and positions, never API credentials or unlocked playback URLs. Tokens remain in the existing secure account store.
- Matching accepts explicit TMDb/IMDb markers or an exact normalized title with a compatible release year. TV matching additionally requires the exact season/episode marker. It rejects fuzzy substring matches and ambiguous multi-episode names. Select a source to choose among resolution/codec variants. Source selection remains mandatory even with one candidate.
- Simkl anime without verified TMDb season mapping is excluded from this movie/TV sync. Missing TMDb IDs remain visible as text in See All and cannot silently match another title. Very large Simkl libraries can exceed API max_items limits; the UI retains cache and shows an error rather than advancing the checkpoint.
- Catalog playback uses `min_progress=100` so partial stops remain resumable. Existing media-server tracking thresholds remain unchanged. Remote clears replace acknowledged local Continue Watching cache.

## Validation boundaries

HTTP-stub tests cover watchlist request shape, unresolved IDs, activity-gated sync, retained cache on error, profile isolation, strict matching and source variants. Persistence tests cover relaunch, account scopes, completion, and transient startup zero. Existing TMDb, AllDebrid, tracker and player tests remain in place. Run SwiftFormat 0.64.5 and the existing GitHub macOS/iOS/tvOS workflows. Live token authorization, real AllDebrid files, network failures during playback, and device resume require manual device validation.

## Original-work recovery audit

The accessible checkout has only the two original PR #2 commits (`782b6b8`, `4aed664`) beyond base `121d700`. PR #2 originally changed seven files. All available local/remote branches and reflogs were inspected and `git fsck --full --no-reflogs --unreachable` found no additional commit objects. Workspace directories contained no other usable checkout, patch, or Git bundle. The repository's older build-check ZIP is a source archive, not the missing commit.

At the initial audit, no SHA, patch, or accessible workspace for the reported 31-file commit was supplied. The later SHA check is recorded below. It could not be compared file-by-file or transferred. **The original changes were not recovered.** The missing capabilities reimplemented here are Simkl library read/sync and My List mutation, server-free Simkl account access, separate Continue Watching rails, strict catalog-to-AllDebrid matching, source selection, local resume persistence and player callbacks, and catalog scrobbling. No files were added to meet a count. If the original commit later becomes available, compare it against this branch before transferring any additional changes.

## Cross-device resume update

Catalog playback now uses `PlaybackProgressRecorder` through its destination adapter, injected into the existing `PlayerViewModel`. `PlayerWrapper` continues to own playback and seeking. The existing `TrackerPlaybackSession`/`TrackerPlaybackChannel`, Simkl transport/token provider, write gate, and watched-write retry queue handle all catalog scrobbles. The server `ProgressSynchronizer` and catalog checkpoint reconciliation share the same newest-pending-change conflict rule. No media server is fabricated and no Firebase, Supabase, or CloudKit dependency is introduced.

Simkl `GET /sync/playback?hide_watched=true` supplies a full saved-playback snapshot. Home and pre-play refreshes import movies and TV episodes, including titles never played on this device. Acknowledged local cache yields to remote rewinds and clears. Only newer unsent checkpoints can be replayed, through the existing tracking channel, before re-reading Simkl. Invalid/truncated responses retain cache; they never mean "all progress was deleted". Positions from the earlier local-only PR implementation are kept as migration/offline checkpoints, not permanent authoritative state. Completed legacy cache is not uploaded as a new watched event.

For catalog playback only, scrobbles send the documented `min_progress=100` URL parameter on start/pause/stop. Partial stops (including >80%) remain resumable; actual completion sends 100%. Existing media-server tracking retains its policy. Writes happen on play/pause/stop/end or recovery of an unsent checkpoint during user interaction, never periodic network heartbeats. Local recorder checkpoints remain throttled by the existing player's timeline interval.

### Simkl API limitations

- Simkl supplies **percentages**, not exact timestamps or the original file duration. The player converts the percentage using the **selected file's actual duration**, including when duration arrives late. Different cuts/editions can therefore resume at a different scene; second/frame-accurate cross-device resume is not guaranteed.
- Saved playbacks are created by pause or stop. **Pause or close the first device before switching.** An active playback is not a portable exact-position stream, and starting/resuming can clear its saved pause. Force-killing the app or losing the network can leave the other device behind the latest local checkpoint.
- The documented retention windows are Free 7 days, PRO 30 days, VIP 90 days; saved records may also be replaced or removed. The app consumes the API's returned snapshot instead of inventing progress for missing sessions. The server's documented expiry/retention behavior is not a durability guarantee.
- Paused sessions may lack TMDb IDs. The app uses known library/cache IDs or TMDb's external-ID lookup; unsupported/unmapped titles are reported rather than guessed. Anime season numbering remains limited to verified mappings. Unknown/non-finite file duration prevents percentage-to-seconds conversion until the engine has a usable duration.
- Conflict resolution has no per-device transaction/version API: newer unsent checkpoints can be replayed using timestamps, while acknowledged cache always yields to Simkl. Concurrent playback and inaccurate device clocks cannot be resolved perfectly. Rate limits or API outages retain an explicitly cached/pending resume point until synchronization succeeds.
- iOS/iPadOS use Strimr's existing player; the existing macOS/tvOS catalog AVPlayer fallback is limited to containers/codecs supported by AVPlayer. Live account authorization and switching actual devices require manual verification.

API references: https://api.simkl.org/api-reference/simkl/get-playback-sessions and https://api.simkl.org/guides/scrobble (including `min_progress`).

### Supplied original commit

The user subsequently supplied SHA `b2ca1ad239c962ce48c3cc886459d5d0791515d2`. It is absent from the attached checkout and its reflogs/unreachable objects. `git fetch origin <SHA>` returns `not our ref`; GitHub's commit API returns HTTP 422, "No commit found for SHA". No other usable original checkout is attached. Its file-level changes therefore still cannot be compared or recovered here. This update is an implementation on PR #2, not recovery of that commit.
