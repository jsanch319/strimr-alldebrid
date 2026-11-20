# AllDebrid + TMDb + Simkl

## Configuration and use

1. Connect AllDebrid using its existing login. Home works without a Plex, Jellyfin, Emby, or Seerr account.
2. Home → accounts menu → TMDb Settings: save your TMDb API Read Access Token in device Keychain (see TMDB.md).
3. Home → accounts menu → Simkl Account: use the existing device authorization flow. Server-free accounts use a separate stable profile scope; server-backed profiles retain their existing tracker accounts.
4. Open a movie or TV episode → Find Available Sources. The app reads existing saved video links and ready magnet files, shows every matching variant, and unlocks the selected file only when you choose it. No content is acquired or downloaded.
5. Resume is enabled by default when that title/episode has a saved unfinished position. Turn off the Resume toggle to start over. Each playback resolves a fresh URL, so expiring AllDebrid URLs never become progress identities.

My List uses Simkl's Plan to Watch bucket. Add/remove actions use the same token provider and write gate as existing scrobbling. Removing from Simkl uses its canonical history/remove endpoint, which also clears history and rating: the UI requires confirmation and describes this effect. Adding an existing watched title to Plan to Watch changes its Simkl status; no second watch-history write is made.

The combined Continue Watching row uses Simkl saved-playback percentages, with durable exact-second local checkpoints and a Simkl percentage fallback. See the cross-device update below. Simkl next unwatched episodes appear in a separate Next Episodes row, without invented resume times. Watched episode indicators use Simkl's per-episode history. iOS catalog playback uses the existing PlayerWrapper/PlayerViewModel and a single TrackerPlaybackSession, including its existing watched-write retry queue. Server playback and the original AllDebrid library path remain available.

## Sync, matching, and persistence

- User interaction, foregrounding Home, and returning from catalog playback trigger sync. No unconditional background timer polls Simkl.
- A sync checks activities first. Initial sync loads movies/shows with episode history; later syncs use date_from. The checkpoint is captured before pulls and saved only after all pulls succeed. Removal activity triggers an IDs-only reconciliation. Errors retain the cached list; rate limits establish a cooldown.
- Library snapshots and playback positions are scoped to the active profile and Simkl account name, stored in UserDefaults as JSON. They contain metadata and positions, never API credentials or unlocked playback URLs. Tokens remain in the existing secure account store.
- Matching accepts explicit TMDb/IMDb markers or an exact normalized title with a compatible release year. TV matching additionally requires the exact season/episode marker. It rejects fuzzy substring matches and ambiguous multi-episode names. Select a source to choose among resolution/codec variants. Source selection remains mandatory even with one candidate.
- Simkl anime without verified TMDb season mapping is excluded from this movie/TV sync. Missing TMDb IDs remain visible as text in See All and cannot silently match another title. Very large Simkl libraries can exceed API max_items limits; the UI retains cache and shows an error rather than advancing the checkpoint.
- Catalog playback uses `min_progress=100` so partial stops remain resumable. Existing media-server tracking thresholds remain unchanged. Expired or absent remote pauses do not delete unfinished local Continue Watching checkpoints.

## Validation boundaries

HTTP-stub tests cover watchlist request shape, unresolved IDs, activity-gated sync, retained cache on error, profile isolation, strict matching and source variants. Persistence tests cover relaunch, account scopes, completion, and transient startup zero. Existing TMDb, AllDebrid, tracker and player tests remain in place. Run SwiftFormat 0.64.5 and the existing GitHub macOS/iOS/tvOS workflows. Live token authorization, real AllDebrid files, network failures during playback, and device resume require manual device validation.

## Original-work recovery audit

The accessible checkout has only the two original PR #2 commits (`782b6b8`, `4aed664`) beyond base `121d700`. PR #2 originally changed seven files. All available local/remote branches and reflogs were inspected and `git fsck --full --no-reflogs --unreachable` found no additional commit objects. Workspace directories contained no other usable checkout, patch, or Git bundle. The repository's older build-check ZIP is a source archive, not the missing commit.

At the initial audit, no SHA, patch, or accessible workspace for the reported 31-file commit was supplied. The later SHA check is recorded below. It could not be compared file-by-file or transferred. **The original changes were not recovered.** The missing capabilities reimplemented here are Simkl library read/sync and My List mutation, server-free Simkl account access, Continue Watching progress, strict catalog-to-AllDebrid matching, source selection, local resume persistence and player callbacks, and catalog scrobbling. No files were added to meet a count. If the original commit later becomes available, compare it against this branch before transferring any additional changes.

## Cross-device resume update

Catalog playback now uses `PlaybackProgressRecorder` through its destination adapter, injected into the existing `PlayerViewModel`. `PlayerWrapper` continues to own playback and seeking. The existing `TrackerPlaybackSession`/`TrackerPlaybackChannel`, Simkl transport/token provider, write gate, and watched-write retry queue handle all catalog scrobbles. The server `ProgressSynchronizer` and catalog checkpoint reconciliation share the same newest-pending-change conflict rule. No media server is fabricated and no Firebase, Supabase, or CloudKit dependency is introduced.

Simkl `GET /sync/playback?hide_watched=true` supplies saved movie/episode percentages for cross-device fallback. Local recorder checkpoints retain exact fractional seconds, selected-file duration, stable typed TMDb/season/episode identity and an update timestamp. Acknowledgement does not convert these exact seconds into percentages. An exact checkpoint wins against older or equal remote activity. A genuinely newer remote pause is selected as the current cross-device session, preserving the older exact checkpoint as provenance. A fresh device uses the remote percentage once the selected file's actual duration is ready.

Unfinished device checkpoints have no time expiry or count-based eviction. Missing Simkl sessions may mean retention expiry or clearing, so they do not delete device-recorded progress. Explicit newer watched history completes a title. Completion, manual clear and deliberate restart retain timestamped fences so stale remote pauses cannot restore the previous position. Clear Saved Resume Position is available in the source picker; it clears local resume without deleting Simkl watch history or fabricating a watched event. Replay from the beginning writes its zero-position fence only after an available source resolves successfully. Newer local progress recorded during a network replay is preserved.

The existing PlaybackProgressRecorder writes through its catalog destination every ten seconds during normal playback, immediately on pause/state changes, and at stop/completion. Lifecycle callbacks additionally checkpoint inactive/background and engine-error events, including buffering, where the OS/player delivers them. The original native player performs the ready-to-seek operation; startup timeline events are ignored until that resume seek completes. The player and tracker session are initialized once per presentation. No extra playback engine or periodic Simkl heartbeat is added. Sudden process termination or power loss can still lose progress since the last delivered checkpoint; UserDefaults/OS lifecycle delivery is not an atomic power-loss guarantee.

For catalog playback only, scrobbles send the documented `min_progress=100` URL parameter on start/pause/stop. Partial stops (including >80%) remain resumable; actual completion sends 100%. Existing media-server tracking retains its policy. Writes happen on play/pause/stop/end or recovery of an unsent checkpoint during user interaction, never periodic network heartbeats. Local recorder checkpoints remain throttled by the existing player's timeline interval.

### Simkl API limitations

- Simkl supplies **percentages**, not exact timestamps or the original file duration. The player converts the percentage using the **selected file's actual duration**, including when duration arrives late. Different cuts/editions can therefore resume at a different scene; second/frame-accurate cross-device resume is not guaranteed.
- Saved playbacks are created by pause or stop. **Pause or close the first device before switching.** An active playback is not a portable exact-position stream, and starting/resuming can clear its saved pause. Force-killing the app or losing the network can leave the other device behind the latest local checkpoint.
- The documented retention windows are Free 7 days, PRO 30 days, VIP 90 days; saved records may also be replaced or removed. The app imports the API snapshot but preserves real unfinished device checkpoints when a session disappears. The server's documented expiry/retention behavior is not a durability guarantee.
- Paused sessions may lack TMDb IDs. The app uses known library/cache IDs or TMDb's external-ID lookup; unsupported/unmapped titles are reported rather than guessed. Anime season numbering remains limited to verified mappings. Unknown/non-finite file duration prevents percentage-to-seconds conversion until the engine has a usable duration.
- Conflict resolution has no per-device transaction/version API: newer unsent checkpoints can be replayed using timestamps, while acknowledged exact local seconds win against older/equal percentages; genuinely newer remote activity can supersede them. Concurrent playback and inaccurate device clocks cannot be resolved perfectly. Rate limits or API outages retain an explicitly cached/pending resume point until synchronization succeeds.
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
| Remote resume and tracking | Simkl paused-playback snapshots, existing recorder/channel/player; durable local checkpoint/outbox; pause/stop synchronization |
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

The referenced StreamUp screenshot was not attached to this workspace. Public reference research found the developer's [AllDebrid Home screenshots](https://www.reddit.com/r/AllDebrid/comments/1uugci3/streamup_ultimate_media_library_for_tvos/) and [Apple-device preview](https://www.reddit.com/r/Simkl/comments/1x57r8w/streamup_ultimate_media_library_available_in/). The specific Disney+/Hulu service-card pair could not be verified in those accessible images. The refined section follows the supplied layout description and the public cards' layered-artwork/rounded-gradient treatment: adaptive large cards, upper-left logos and subscription labels, overlapping real regional posters, lower-left platform/description/arrow, and aligned horizontal scrolling. No reference screenshot is bundled as application content. Pixel-level fidelity remains unverified. Physical-device layout, real service logos/catalog availability, real-account authorization, actual AllDebrid playback, and two-Apple-device Simkl resume require live manual verification. Automated request/model/player tests and compilation cannot establish those outcomes. Simkl's percentage/retention/mapping limitations above remain applicable. Unmapped anime and unfinished titles absent from Simkl's paused-playback API cannot receive invented cross-device timestamps. TMDb Setup reuses Strimr’s bundled TMDb logo alongside its attribution text and link.


## Hybrid resume validation

Automated tests cover exact fractional seconds after acknowledgement and relaunch; Simkl percentage fallback using actual loaded duration; ignoring pre-seek startup positions; lifecycle checkpoints during buffering; completion/restart/clear fences; distinct movie/TV/season/episode identities; expiry without local loss; older and newer remote conflicts; progress arriving during replay; and persistence beyond 1,000 records. Existing server ProgressSynchronizer tests continue to exercise the shared newest-change conflict policy, and original player/tracker tests remain required. Real-device engine seeking, app suspension/interruptions, force-termination, different-file editions, and account-to-account/device-to-device behavior still require manual verification.

## Native iOS catalog navigation and dynamic Home backdrop

The AllDebrid-only entry now enters the original `MainTabView`, which selects a server-free native `TabView` branch. The media-server branch and coordinator routes remain unchanged. There is one Home, using the existing `HomeView`/catalog view model, not a second discovery Home.

The six destinations are:

| Destination | Content |
| --- | --- |
| Home | Original iOS hero/vertical rails, combined Continue Watching, discovery and Streaming Services |
| Search | Existing paginated TMDb multi-search, independent of AllDebrid file availability |
| Movies | Trending, popular, upcoming and top-rated TMDb movies; actual history-based movie recommendations |
| TV Shows | Trending, popular and top-rated TMDb series; existing details/seasons/episodes and TV recommendations |
| My List | Simkl Plan to Watch, All/Movies/TV filters, real posters, explicit unmapped-title text, account access and pull-to-refresh |
| Settings | Existing settings plus AllDebrid, Simkl and TMDb configuration; playback/audio/subtitles/interface and other existing options |

The bottom bar declares Home, Search, Movies, TV Shows and More. Search uses Strimr's existing dedicated native search role, so the OS can render it as a separate search affordance. More contains My List and Settings, using the original app-managed overflow pattern rather than UIKit adding a second navigation bar. Each primary tab and More retain independent NavigationStacks. Compact traits are applied only to the tab container to retain bottom placement on regular-width iOS windows; destination content receives the original horizontal size class. No custom player or tab-bar skin is introduced. The original profile/user-menu chrome remains, with catalog account settings and without unavailable server-only Favorites/Downloads links in the server-free menu.

The attached tvOS Home screenshot is used for **background behavior**, not its top navigation or focus/layout. iOS keeps its original hero title, scrolling, row spacing and native landscape Continue Watching artwork/progress/remaining-time captions. The featured carousel reports its current title; Home requests that exact title's TMDb backdrop behind the page. Row detail/play actions select the corresponding title backdrop; the next featured-page change resumes featured-title background selection. Episodes use their own series backdrop, never an unrelated poster or episode still. Missing/failed artwork clears to the neutral native background.

Backdrop rendering reuses the decoded `ArtworkResourceView` cache, `ImageCornerColorSampler`, and `MediaBackdropGradient` used by Strimr's native artwork infrastructure. The incoming image is prepared before replacing the old layer; a half-second opacity transition, ambient blur and directional gradients blend it behind readable text. Request generations prevent a late image replacing a newer title. Reduce Motion disables the crossfade and keeps one image layer. The existing hero artwork and controls remain unchanged. Simkl sync, hybrid resume, source selection and native players are untouched by this navigation update. Catalog loads coalesce across tabs.

Automated checks cover the six-destination overflow partition, movie/TV feed separation, episode-to-series backdrop identity, missing/failed image behavior, cached current-image reuse, Reduce Motion layers and late-request rejection, alongside the existing player/resume/tracker/server tests. Physical iPhone/iPad layout, actual tab-bar placement/search-role behavior across OS versions, retained deep navigation during size changes, screenshot fidelity, contrast/blur and transition smoothness still require device/simulator UI testing. Compilation and model tests do not establish those visual outcomes.

## Shared content backdrops and catalog details

The existing cached backdrop renderer now serves content-scoped surfaces on Home, its Continue Watching/Next Episodes/discovery/recommendation rows, Movies, TV Shows, Search, My List, See All grids and streaming-provider discovery. Native cards report sufficiently visible bounds; a settled card near the upper-middle of the viewport supplies a touch/scroll highlight. Taps take priority until scrolling resumes. Duplicate titles in different rows have separate visibility tokens. Home's visible hero retains featured priority; scrolling down allows rows to drive the background. Streaming-service cards use a real featured catalog title shown on that card, not a platform logo as movie artwork. Each screen has its own scope; Settings and account configuration explicitly clear that scope and use the neutral native background.

The same renderer uses the decoded image cache, sampled corner colors, gradients, stale-request rejection, and Reduce Motion behavior. A 160 ms settling delay skips intermediate images during fast swipes. Missing backdrop data uses a neutral fallback; episode backdrops belong to their actual series. A detail screen is locked to its own title so a recommendation rail cannot put another film's image behind the current synopsis; opening a recommendation gives the next details screen its matching backdrop.

`TMDBDetailView` follows the supplied iPhone reference: large backdrop behind the page, artwork-tinted cinematic blending, rounded Play/Resume with season/episode and remaining-time captions, Restart, watched/watchlist controls, title/year/runtime/rating/region-specific certification, tagline/synopsis with Read More, genres, actual production companies or network, and seasons/episodes below. Missing metadata is omitted rather than invented. Certification comes from TMDb movie release dates or TV content ratings for the configured watch region. The original native navigation/back button, Home layout, bottom navigation and player controls remain in use.

Movie/episode actions resolve stable typed TMDb and S/E keys through the existing progress store. A TV details page preserves an explicitly selected episode, otherwise chooses actual saved progress, Simkl's next episode or a real loaded episode. Restart passes a start-from-beginning preference into the existing source picker; it still resets only after a playable source resolves. Manual Mark as Watched writes the selected movie/episode through the existing Simkl identity builder, token transport and write gate, validates unmatched-ID responses, and only then completes/acknowledges the local resume record. It does not silently mark a whole TV series watched. Watchlist removal retains its existing warning about Simkl history/rating removal.

Additional tests cover viewport selection and independent screen scopes, duplicate-row visibility, exact/percentage detail captions, movie/episode isolation, certification/runtime/studio decoding, validated Simkl watched payloads and completion only after confirmed writes. The existing iOS scheme has no test target; the automated test target runs on macOS. The iOS compile workflow additionally attempts an app startup smoke test on an installed iPhone simulator and uploads its launch screenshot. That fresh simulator has no user credentials, so a passing startup check does **not** validate authenticated catalog navigation, live Simkl writes, playback, or screenshot fidelity. Those interactions, small-screen/dynamic-type layout, contrast, scrolling highlights and transition smoothness remain device/UI verification requirements.
