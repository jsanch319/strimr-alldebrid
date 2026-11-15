# AllDebrid + TMDb + Simkl

## Configuration and use

1. Connect AllDebrid using its existing login. Home works without a Plex, Jellyfin, Emby, or Seerr account.
2. Home → accounts menu → TMDb Settings: save your TMDb API Read Access Token in device Keychain (see TMDB.md).
3. Home → accounts menu → Simkl Account: use the existing device authorization flow. Server-free accounts use a separate stable profile scope; server-backed profiles retain their existing tracker accounts.
4. Open a movie or TV episode → Find Available Sources. The app reads existing saved video links and ready magnet files, shows every matching variant, and unlocks the selected file only when you choose it. No content is acquired or downloaded.
5. Resume is enabled by default when that title/episode has a saved unfinished position. Turn off the Resume toggle to start over. Each playback resolves a fresh URL, so expiring AllDebrid URLs never become progress identities.

My List uses Simkl's Plan to Watch bucket. Add/remove actions use the same token provider and write gate as existing scrobbling. Removing from Simkl uses its canonical history/remove endpoint, which also clears history and rating: the UI requires confirmation and describes this effect. Adding an existing watched title to Plan to Watch changes its Simkl status; no second watch-history write is made.

The combined Continue Watching row uses Simkl saved-playback percentages, with local checkpoints as an offline cache. See the cross-device update below. Simkl next unwatched episodes appear in a separate Next Episodes row, without invented resume times. Watched episode indicators use Simkl's per-episode history. iOS catalog playback uses the existing PlayerWrapper/PlayerViewModel and a single TrackerPlaybackSession, including its existing watched-write retry queue. Server playback and the original AllDebrid library path remain available.

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

At the initial audit, no SHA, patch, or accessible workspace for the reported 31-file commit was supplied. The later SHA check is recorded below. It could not be compared file-by-file or transferred. **The original changes were not recovered.** The missing capabilities reimplemented here are Simkl library read/sync and My List mutation, server-free Simkl account access, Continue Watching progress, strict catalog-to-AllDebrid matching, source selection, local resume persistence and player callbacks, and catalog scrobbling. No files were added to meet a count. If the original commit later becomes available, compare it against this branch before transferring any additional changes.

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
- iOS/iPadOS, macOS and tvOS now use their original Strimr PlayerView and controls through a presentation adapter; the separate catalog AVPlayer UI has been removed. Live account authorization and switching actual devices require manual verification.

API references: https://api.simkl.org/api-reference/simkl/get-playback-sessions and https://api.simkl.org/guides/scrobble (including `min_progress`).

### Supplied original commit

The user subsequently supplied SHA `b2ca1ad239c962ce48c3cc886459d5d0791515d2`. It is absent from the attached checkout and its reflogs/unreachable objects. `git fetch origin <SHA>` returns `not our ref`; GitHub's commit API returns HTTP 422, "No commit found for SHA". No other usable original checkout is attached. Its file-level changes therefore still cannot be compared or recovered here. This update is an implementation on PR #2, not recovery of that commit.

## Original Strimr UI comparison

AllDebrid-only mode now instantiates the same `HomeView` as the original app, with a server-free `HomeViewModel` data source. The previous custom Discover heading, fixed-size poster rails, orange progress bars, single custom hero and percentage captions have been removed from Home.

| Element | Original component reused |
| --- | --- |
| Home layout, scrolling, page margins and vertical row spacing | `HomeView` |
| Hero height, masks, animation, auto-advance, page indicators and action buttons | `HomeHeroCarousel` / `HomeHeroSlide` |
| Row headings and horizontal scroll spacing | `HomeRowSectionView`, `MediaHubSection`, `MediaCarousel` |
| Posters, landscape Continue Watching cards, fonts and corner shapes | `PortraitMediaCard`, `LandscapeMediaCard`, `MediaCard` |
| Time left and progress fill/track colors | `RemainingTimeFormatter`, unchanged `CardProgressBar` |
| See All grid and navigation | `HubDetailView` with a preloaded catalog model |
| Playback controls, seek bar, colors and settings | Original platform `PlayerWrapper` / `PlayerView` |

The only new Home controls are native search and account actions needed to configure/query the server-free data sources. Search is on its own native hub page so it does not change Home's hero/row layout. Artwork uses the existing image renderer/cache and spoiler preferences, with allowlisted TMDb URLs when no server artwork service exists. Hero off/Continue Watching/Discover, poster-size and card-label preferences remain active. Unknown runtimes do not produce invented remaining-time labels.

AllDebrid saved links and magnet files also use the original native player; the catalog-specific AVPlayer screen and additional close-button overlay are removed. tvOS shares the existing recorder destination for local catalog streams without adding offline-server storage to tvOS. macOS receives a close-presentation callback so closing an AllDebrid sheet does not reset an unrelated player window. No playback settings, theme assets, control styling or layout metrics are changed.

Validation compares the component tree and source against main: `CardProgressBar` is byte-for-byte unchanged, and player control, timeline styling, theme and layout-metric files are unchanged. Adapter tests verify the combined native movie/TV row, remaining-time fields, hero identities/preferences and direct artwork without a media server. Simulator screenshots and real-device visual/playback comparisons have not been performed in this Linux workspace; compilation/tests do not establish pixel-level or real-account behavior.


## Current requirements audit (combined Home and Streaming Services)

The unavailable original commit cannot establish a file-by-file checklist. This audit instead compares the supplied original specification and later requirements with the accessible PR implementation. **None of the original 31-file commit is claimed recovered.**

| Requirement | Current implementation |
| --- | --- |
| Original Home, hero, poster rows, colors, spacing and navigation | Shared original Home with a catalog data adapter; only Streaming Services has custom cards |
| Continue Watching | One mixed movie/episode row, newest progress first, above Trending Movies; completed sessions excluded; original landscape cards, remaining-time labels and progress styling |
| Remote resume and tracking | Simkl paused-playback snapshots, existing recorder/channel/player; local pending cache/outbox; pause/stop synchronization |
| TMDb discovery | Trending/popular/top-rated movies and TV, upcoming movies, full details/seasons/episodes, recommendations and paginated multi-search |
| Personalized rows | Recommended For You from up to two actual watched Simkl seeds, excluding existing library titles; unwatched movie/show rows from real non-completed Simkl entries; no synthetic personalization for an empty history |
| My List and history | Simkl Plan to Watch read/add/remove, watched movie/episode state, next episodes, account-scoped delta/history sync |
| AllDebrid | Existing authentication, library access, exact title/ID/year/episode matching, variant selection, fresh URL resolution, explicit unavailable state, original native player |
| Streaming Services | Nine requested services; TMDb provider-list IDs/logos; real regional subscription discovery, Movies/TV filters, paginated native poster grid, existing details/source/player flow |
| Credentials and rate limits | Device Keychain and existing secure tracker store; existing TMDb/Simkl cooldowns and error handling; no embedded keys |
| Original media servers and Discord | Existing paths preserved; existing build variables/setup documentation retained |

### Streaming Services setup and behavior

Configure the TMDb read token using Home's accounts menu. Streaming Services exposes a country picker, initially using the device's region (US only when the device has none). That choice is stored on the device. The API uses `watch_region`, provider IDs returned by TMDb, `with_watch_monetization_types=flatrate`, and popularity sorting. Provider aliases include renamed brands and subscription tiers; IDs, poster titles and logos are not fabricated. Region-specific empty results are shown honestly. Catalog availability does not authorize playback from a streaming platform: playback still requires matching files already available in the user's AllDebrid library. TMDb/JustWatch attribution is visible below the cards.

The previous Recently Added row has been removed from server-free Home; its files remain available in AllDebrid Library. Separate movie/TV Continue Watching rows have been replaced, per the latest requirement. Recommendations and unwatched rows use the unchanged native row components. Search supports explicit Load More; provider grids support Load More up to TMDb's 500-page limit.

### Remaining verification and limits

The referenced StreamUp screenshot was not attached to this workspace, so the custom cards follow the written description; a screenshot-level comparison remains unverified. Physical-device layout, real service logos/catalog availability, real-account authorization, actual AllDebrid playback, and two-Apple-device Simkl resume require live manual verification. Automated request/model/player tests and compilation cannot establish those outcomes. Simkl's percentage/retention/mapping limitations above remain applicable. Unmapped anime and unfinished titles absent from Simkl's paused-playback API cannot receive invented cross-device timestamps. TMDb branding currently uses textual attribution; approval of a final TMDb logo asset remains unfinished.
