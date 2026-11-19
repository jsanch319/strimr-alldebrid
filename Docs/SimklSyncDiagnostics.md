# Simkl sync failures

The old Home message appended `TrackerAPIError.localizedDescription`. Swift
synthesizes its NSError domain/code; `error 0` is not an HTTP status or a documented
Simkl error. The regression suite records which original enum case bridges to
zero for the build toolchain. Operational decisions use typed cases, never that
number. A device HTTP trace was not provided, so the original response body and
whether it was a burst or daily quota cannot be recovered from that message alone.

The current official contract was checked against:
- https://api.simkl.org/conventions/headers
- https://api.simkl.org/conventions/errors
- https://api.simkl.org/resources/rate-limits
- https://api.simkl.org/openapi.json

All user reads include app identity and Bearer authorization. The existing V2
refresh flow remains; a rejected refresh or a renewed token that is rejected
again now invalidates the binding once and asks for reconnection. Subsequent
requests cannot keep refreshing the same invalid credentials. An asynchronous
connection check may not overwrite a reconnect flag or a replacement account.
A temporary network/server failure never invalidates authorization.

Simkl origin reads and writes share a serial request gate. The existing one-POST
per-second gate remains. GET retries are bounded to two retries (three attempts)
for selected transient network failures, HTTP 500/502/503/504, and brief burst
429 limits. Writes are not blindly retried after an uncertain outcome. Daily and
unknown quota waits are honored across this client's reads/writes; daily reset
is not solved by reconnecting. See Simkl Connected Apps for other integrations'
usage. A cold app restart must rediscover a server quota if no hold is in memory.

Library pulls remain activity-gated and incremental. After one complete playback
pull in this launch, unchanged activity timestamps do not trigger redundant
playback downloads unless a local checkpoint is pending. Failed playback pulls
never advance that marker. Cached lists remain visible when authorization needs
reconnection. Exact local movie/episode checkpoints and pending writes are not
cleared by read, decode, network or authorization failures. A successful empty
server snapshot is distinct from a failed request. Existing conflict and completed/
restart semantics remain in CatalogProgressStore.

Home only shows actionable, concise guidance: reconnect, restore connectivity,
check rejected configuration/access, or retry a persistent unreadable/service
response. Short recoverable failures and a quota waiting to reset do not produce
a raw error footer. They are still classified and logged; suppressing a temporary
footer is not a claim that the sync succeeded.

In macOS Console with the iPhone connected, filter subsystem `app.strimr.simkl`,
category `Sync`. Events give a caller-owned stage (activities, movie/episode list,
paused playback, decode, token refresh or write), a stable failure category, known
HTTP status, numeric URLSession error and a whitelisted 429 reason (burst/user
quota/app quota/unknown). HTTP 0 means no exact HTTP status is established. No
raw errors, bodies, URLs, tokens, device IDs, account names or title IDs are logged.
Share only these filtered events, app/iOS versions and reproduction steps. Do not
post authorization headers, Keychain exports or a full network/sysdiagnose capture.

Tests use isolated URLSession fixtures, no real account credentials. Live token
refresh, actual watchlist/progress delivery between signed iPhones, and quota
behavior for the user's account remain device/account checks. No client ID,
secret or Apple entitlement was changed by this fix.
