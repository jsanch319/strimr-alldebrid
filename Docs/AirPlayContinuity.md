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
