# AirPlay playback continuity

Strimr keeps one AetherEngine session and Apple's native route picker. The pinned
engine already owns wireless route handoffs, LAN playlist replacement, native-host
reuse, stall recovery and track carryover. Strimr must not run a competing route
reload loop, create a second AVPlayer or continually re-resolve a working URL.

The host checkpoints its existing recorder before presenting the route picker.
Engine item replacements retain the last accepted playhead and reject transient
zero-based clocks. Explicit seeking/restart, including native remote scrubbing,
sets a new checkpoint; loading another title resets it. Filtered timestamps never
reach PlayerViewModel, PlaybackProgressRecorder or Simkl tracking.

Initial resume waits for the engine's seek-landed event, rather than treating the
optimistic engine clock as proof of success. Waiting is bounded to 30 seconds
(after the engine seek call returns), canceled by source changes/stop, and reports
a playback failure instead of releasing the resume gate at zero. The engine owns
item readiness and deferred seeks. Stale source-load completions/errors cannot
update a newer session. A native remote HLS item receives a 20-second minimum
forward-buffer preference and AVPlayer's stall-minimization policy; this does not
cap quality, transcode codecs, or change local loopback buffering.

Existing catalog failure handling saves progress, pauses the failed source, then
uses the resolver's bounded, already-attempted-source-aware fallback. AllDebrid
links are resolved when selected. A currently failing signed URL is not endlessly
retried; another exact matching source or explicit Refresh/Retry is required.
There is **no new transparent same-source expired-URL renewal** in this change.
Some source formats cannot carry video to a particular receiver. AirPlay audio
routing alone is not proof that the receiver can decode its video or HDR format.

## Validation

Automated continuity tests cover exact-second retention through repeated route
replacement/zero clocks, deliberate restart, new-episode isolation and invalid
timestamps. Existing recorder, tracker and catalog fallback suites remain the
regression checks. These tests do not establish real receiver compatibility.

On a signed iPhone with a physical Apple TV or AirPlay receiver, test:

- Connect during a playing movie; verify a halfway resume checkpoint, correct
  picture/audio, English track and no simultaneous second local player.
- Repeat while paused; disconnect/reconnect and interrupt Wi-Fi. Check pause
  intent, native controls, subtitles, audio sync and persisted exact seconds.
- Switch exact episode/source while connecting; verify no stale error or old
  movie appears. Repeat using manual selection and automatic fallback.
- Test a working HLS source, an expired AllDebrid URL and an incompatible codec.
  Confirm bounded failure/fallback, Retry, no repeated permanently failing source,
  and no zero resume or Simkl update during the handoff.
- Lock/unlock, background/foreground, end playback and intentionally Restart.
  Check Continue Watching and Simkl with a real account; their remote API behavior
  cannot be verified with credential-free fixtures or a simulator alone.

Receiver connection states, recovery latency, actual Wi-Fi stalls, HDR/Dolby Vision
and paused handoff behavior remain hardware validation requirements. The native
route picker supplies route status; Strimr does not claim a connection succeeded
until Apple's playback pipeline establishes it.

## LG disconnection investigation

Two app/engine interaction defects were found in code (not reproduced against an
LG TV in this environment):

1. The iOS background policy paused on-demand playback when Background Audio was
   off, even if video was playing externally. AirPlay is now exempt without
   changing the user's setting or ordinary local playback policy. Active remote
   sessions also bypass the host's foreground video reload, avoiding a competing
   reload of a working TV stream.
2. The pinned engine's interruption-end policy excludes background native video
   from automatic resume. Strimr now allows one play command on the **same**
   native external AVPlayer after an interruption, only if iOS grants
   `shouldResume`, playback was running before interruption, the app is still in
   the background, and the exact session still exists. A pause/transport command,
   new source, stop, picker presentation or route change cancels this intent.
   Foreground/software/coordinated sessions retain the engine's sole resume owner.
   No route is programmatically selected or reconnected.

These fixes do not establish the cause of every LG disconnect. Route loss alone
cannot reliably distinguish a user disconnect from a network outage; Strimr must
not treat either as permission to seize the TV route again. Use the native picker
and Play when the OS does not authorize continuation.

### Privacy-safe diagnostics

On a signed iPhone, connect macOS Console, select the phone and filter subsystem
`app.strimr.playback`, category `AirPlay`. Capture the interval around a failure.
These are OS unified logs, not an analytics upload or an in-app export. The new
observer logs fixed event categories, route reason numbers, external-active and
AirPlay-audio-route flags, source *type*, interruption option flags, HTTP error
status numbers and whitelisted Apple error codes. It observes native-item replacement, waiting/playing/paused,
stalls and item failures. It logs no URLs, IPs, TV names, credentials, headers,
media identifiers, exact positions or raw NSError descriptions. Error categories
are diagnostic evidence, not proof: HTTP 401/403 can mean authorization/expiry;
404/410 means unavailable; known URL-session failures indicate networking;
selected AVFoundation decoder/format/protection errors indicate incompatibility;
URL-session redirect-limit failures have their own category.
A generic playback error or a route loss remains unclassified rather than guessed.
Do not attach unredacted engine/system logs; their privacy behavior is independent
of this new observer.

### URL, redirect and LAN findings

The iOS target already declares a Local Network usage description and background
audio capability. ATS permits the engine's HTTP transport. These declarations do
not prove that the user granted Local Network access or that an LG TV can reach
the phone on guest Wi-Fi/VPN/client-isolated networks. AetherEngine already swaps
its loopback origin to a LAN-reachable origin for wireless AirPlay; origin HLS can
instead be fetched by the receiver. That means phone and receiver access can fail
differently. No new permission bypass, proxy or DNS/redirect probe was added.

Signed AllDebrid URL expiration, redirect behavior on the LG receiver, LAN
reachability and receiver codec compatibility remain hypotheses until a device
trace identifies them. An HTTP error is recorded without its signed URL; this
change does not automatically renew links, replay a permanently incompatible
source, or reload a healthy stream. Existing exact-title source selection and
fallback remain in place.

### LG AirPlay 2 device checks still required

Test lock/unlock and foreground/background with Background Audio both off and on;
repeat playing and paused. Trigger Siri/call interruptions with and without system
resume permission. Pause or change source during interruption; deliberately
select iPhone output in the route picker; power off the TV; interrupt Wi-Fi;
restore Wi-Fi without selecting a route. Verify there is no forced reconnection,
no second player, no zero checkpoint, and the intended paused/playing state is
retained. Confirm the exact title/episode and Simkl/Continue Watching checkpoint.
Repeat with origin HLS, an engine-served stream, an expired authorized URL and an
unsupported receiver codec. Record TV model/firmware and iOS version separately
from the app logs. No physical LG TV or real account credentials were available
for this implementation.
