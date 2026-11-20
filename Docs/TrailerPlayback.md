# Trailer previews and provider limits

TMDb `movie/{id}/videos`, `tv/{id}/videos` and `tv/{id}/season/{n}/videos`
provide discovery metadata. Only entries marked `official: true` and `type: Trailer`
are eligible. The user's language is preferred; other official languages remain
available. Empty or missing season video lists fall back to the series. Requests
share in-flight work and the existing five-minute bounded response cache.

## Providers

- **YouTube:** user-initiated fullscreen IFrame Player API in WKWebView. The native
  app supplies its bundle ID as the base-URL/Referer identity. Provider controls,
  branding, ads and restrictions remain intact. No stream extraction, ad skipping,
  automatic looping or hero autoplay. Open on Provider remains available if an
  uploader, region, age restriction, consent screen or playback error prevents embedding.
- **Vimeo:** user-initiated fullscreen official iframe. Domain restrictions may
  require opening the provider. No extraction, autoplay or automatic looping.
- **Authorized direct HLS/MP4:** native AVPlayer, initially muted in the hero,
  starts after two settled seconds, with artwork retained until the video layer
  reports ready. Mute/Unmute is available. Looping is permitted only when a direct
  provider explicitly declares an ad-free repeatable asset; otherwise it stops at end.

**There is currently no direct-trailer feed configured. TMDb's YouTube/Vimeo keys
are not MP4/HLS URLs.** Normal TMDb titles therefore keep the cinematic artwork
instead of automatically playing video behind the hero buttons. Home has no
Watch Trailer button; movie/TV details retain manual trailer playback. `HomeHeroSlide.authorizedTrailer` is the typed adapter input for a future
provider-supplied direct stream bound to that title's catalog ID. No fake stream,
undocumented scraper, paid provider or backend was added. This direct adapter input
is capability, not a claim that any live direct trailer has been discovered or verified.

YouTube prohibits covering any part of its embedded player with application
logos/buttons. That conflicts with the requested video-behind-hero-controls layout,
so its authorized fullscreen player stays unobscured and the hero uses the static
fallback. Native header/footer actions sit outside the embedded player. Its
viewport is at least 200 × 200 points and the page scrolls on small screens.

References:
- https://developer.themoviedb.org/reference/movie-videos
- https://developer.themoviedb.org/reference/tv-series-videos
- https://developer.themoviedb.org/reference/tv-season-videos
- https://developers.google.com/youtube/terms/required-minimum-functionality
- https://developers.google.com/youtube/iframe_api_reference

## Lifecycle and data use

Automatic native previews require an active, visible, settled featured slide,
Reduce Motion/VoiceOver off, Low Power Mode off and a satisfied network path.
Low Data Mode disables automatic previews; expensive/cellular paths require the
explicit Playback Settings opt-in (off by default). Swiping immediately stops the
old preview. Offscreen, navigation and background transitions stop previews.
The existing eight-second carousel timer pauses while a direct preview is active.
Manual trailer playback pauses when backgrounded and never auto-resumes with sound.
The shared audio coordinator stops trailers before feature playback loads; trailers
never use Simkl scrobbling or the feature's resume recorder.

## Validation limits

Unit tests cover official selection, language preference, series/season fallback,
provider IDs, embed configuration, power/network/visibility gates, ownership conflicts,
stream URL restrictions and setting migration. Credential-free simulator fixtures
exercise movie/TV trailer entry/close and preserve feature actions; they do not press
Play in the provider or verify ads, actual streams, muting, background playback or
native looping. No user account keys are used by those tests.

Signed-iPhone testing is required for provider consent/embedding/region restrictions,
real trailer playback and audio, native direct-video readiness and looping, muting,
rapid carousel swipes, offscreen/background behavior and cellular/Low Power/Reduce
Motion transitions. No real provider/channel/stream is called verified playable by
this implementation alone. No new paid API key is required; TMDb uses the existing token.

The iPhone hero now uses exactly half of its available vertical container height,
without compact-height caps. Native direct previews crossfade over the retained
artwork; their subtle speaker control sits at the bottom-right and changes only
mute state. Each new featured item starts muted. Unsupported providers retain the
backdrop with no Home trailer button.
