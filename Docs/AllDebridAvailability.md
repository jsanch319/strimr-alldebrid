# AllDebrid playback availability

Before Auto Play or manual selection, the connected account is authenticated and
its library snapshot is retrieved. Ready file selection uses the existing strict
title/alias/year and exact season/episode matcher, including stable external IDs.
No content is acquired and no new source provider is introduced.

Only processing magnets with matching title identity are labeled Processing.
A season pack can justify waiting for that season, but never proves an individual
episode is playable: after readiness, the exact requested episode file must exist.
Unrelated pending magnets do not hide a missing title. Terminal magnet states are
not called processing.

The compact status sheet offers Retry. While visible and foregrounded, processing
checks use a 10-to-30-second bounded delay; missing/incomplete snapshots use
30-to-60 seconds. Polling stops when sources are ready, feature playback opens,
credentials change, the sheet disappears, or the app backgrounds. Authentication
and rate-limit failures stop automatic polling until the user retries. SwiftUI
structured tasks cancel requests and source opening checks cancellation/account
scope before using a resolved URL. Automatic source fallback keeps its existing
quality queue and does not restart at the highest failed source.

Simkl refresh occurs before feature playback; exact local resume and the existing
native player/recorders remain unchanged. Polling does not repeatedly force Simkl
sync while a file is processing. Filename metadata is not a cryptographic guarantee
of file contents; ambiguous or mismatched titles/episodes remain ineligible.

Tests use library snapshots and provider mocks, not account credentials. Real
processing completion, account transitions and source playback still require a
signed-device check against the user's authorized AllDebrid library.

## Optional authorized acquisition

The resolver can now search explicitly configured authorized providers after a complete missing-library check, or accept user-provided authorized links. No providers are bundled. See [AuthorizedSources.md](AuthorizedSources.md) for configuration, documented endpoints, matching and duplicate-submission protections. Existing library matches always take priority.
