# TMDb discovery

Home now reads the TMDb catalog directly. No Plex, Jellyfin, Emby, or Seerr account is required on the AllDebrid-only Home path. Existing server rows and the AllDebrid library remain available.

1. Create an account at https://www.themoviedb.org.
2. Visit https://www.themoviedb.org/settings/api and request API access under TMDb's terms.
3. Copy the **API Read Access Token** (v4 bearer token, not the v3 API key).
4. On Home, open the accounts menu → **TMDb Settings**, paste the token, and select **Save Token**.

No build setting or GitHub Actions secret is needed. Each device stores its own token in Keychain using `AfterFirstUnlockThisDeviceOnly`. Do not commit or log tokens. Remove or replace the token through TMDb Settings; revoke it through TMDb if compromised. Shipping a private service credential inside an IPA would not keep it secret; use your own authenticated backend if deploying centrally managed credentials.

Discovery includes weekly trending movies/TV, popular movies/TV, upcoming movies, top-rated movies/TV, catalog search, movie/TV details, recommendations, and every TV season (including specials) with episode names, descriptions, and air dates. Existing TMDBImageService supplies posters and backdrops. Search excludes people and debounces input. The client supports page parameters; the initial UI displays the first page of each feed/search/recommendations.

Successful responses are cached in memory for five minutes, bounded to 150 entries. HTTP 429 establishes a client-wide cooldown using Retry-After seconds or HTTP dates (60-second fallback). Requests are not automatically retried; the UI shows when to retry. HTTP authentication and server errors display actionable messages. Network calls use a 30-second timeout. Saving/removing credentials clears the cache and cooldown.

TMDb identities include both media type and numeric ID, since movie and TV IDs can overlap. Details also retrieve IMDb and TVDB external IDs for future matching. Preserve the numeric TMDb ID as Simkl `ids.tmdb` with the corresponding media type. Existing Simkl authentication/scrobbling and AllDebrid authentication/playback are reused; catalog playback supplies known TMDb identities to the existing tracking channel. TMDb is metadata only: it does not establish file availability or acquire files.

## Current boundaries

The detail view now offers Simkl My List actions and matches movies/episodes to available AllDebrid files with explicit source selection and Simkl-backed resume positions with offline checkpoints. See [the integration guide](DISCOVERY_INTEGRATION.md) for setup, sync behavior, matching rules, and validation boundaries. Details show related titles. Home also combines TMDb recommendations from up to two actual Simkl watch-history seeds, excluding titles already in the Simkl library. Server-based Seerr hero behavior is preserved; direct TMDb discovery powers the server-free Home. Discovery uses the original Strimr hero carousel with movie/TV slides and the original card rows. Attribution text and a TMDb link are included; review TMDb's current branding requirements and add its approved logo before distribution.

## Validation

Run `swiftformat .` and `swiftformat --lint .` using the repository's pinned 0.64.5 release. Build and test with the existing Xcode workflows on macOS; Linux cannot compile SwiftUI, Security, or the iOS app. Configure a real token on a device to verify catalog results, invalid-token errors, search cancellation, season switching, recommendations, and AllDebrid-only navigation. Verify existing media-server Home and AllDebrid playback independently.
