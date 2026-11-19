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

## Server-confirmed watchlist and persisted posters

The current toolchain regression confirms that the old numeric code 0 is the
`rateLimited` branch originating from HTTP 429. Its original burst/user/app quota
reason cannot be recovered from the old footer. Existing bounded reads and quota
holds remain; reconnecting does not reset a quota.

Explicit Plan to Watch uses `/sync/add-to-list`, with `to: plantowatch` on each
movie/show and stable identifiers. An HTTP 200 or empty `added` object alone does
not fill the bookmark. A matching response ID and destination confirm addition;
incomplete/legacy acknowledgements require one read-back of that media kind's
Plan to Watch list. Contradictory IDs/status, unresolved titles, malformed replies,
denied credentials or failed confirmation produce useful errors and retain the
prior bookmark/cache. There is no automatic retry of an uncertain POST.

Removal uses Simkl's canonical `/sync/history/remove`. A one-item deletion count
confirms removal; ambiguous replies require a read-back. This Simkl API removes
its library/history entry, as the existing confirmation dialog explains. Local
exact resume records are not deleted. No separate remote watchlist-only deletion
API is invented.

Discovery pulls and watchlist changes share an operation gate so an in-flight
older pull cannot overwrite a newly confirmed bookmark. Confirmation is persisted
even before the first successful sync; cold mutation first restores existing
account cache. A follow-up sync updates My List automatically. Failed follow-up
reads retain the already confirmed change.

Every visible My List card hydrates TMDb metadata through the shared store rather
than relying on Home's first 40 items. Movie and TV namespaces remain distinct.
Absent TMDb IDs use exact IMDb/TVDB lookup constrained to the correct media kind;
there is no title-text fallback. Verified poster/backdrop paths and ID mappings
are cached per account across restarts, without copying full cast/season payloads.
Unmapped titles remain explicitly unmapped; missing artwork is never replaced
with an unrelated poster. TMDb configuration errors show actionable My List
messages. This cache and watchlist data contain no access/refresh tokens.

### Canonical-only save receipts

A single-title `/sync/add-to-list` response may acknowledge the requested status
with only `ids.simkl`. The old confirmation fallback discarded that canonical ID
and searched the read-back solely using the originally sent external IDs. If the
read-back also supplied only the canonical ID, Strimr rejected an accepted save.
The failure message was below all details content, away from the tapped button.

The single response row in the requested movie/show namespace now supplies a
canonical identity for the confirmation read. It does not itself count as
success: the read must contain that identity in `plantowatch`, with no conflicting
external ID. Multiple ambiguous receipts, wrong media types, conflicting IDs,
wrong status, empty lists and failed reads never fill the bookmark. After a
match, retain both the requested TMDb identity and confirmed Simkl identity so
My List, the details bookmark and subsequent syncs refer to the same title.
Missing TMDb artwork is hydrated separately after confirmation and cached.

Save failures appear directly under the watchlist controls. Authorization and
quota errors during read-back retain their actionable messages; no uncertain
POST is automatically repeated. Diagnostic categories distinguish unconfirmed
status from unavailable confirmation and HTTP/network failures, without logging
tokens, request bodies, account details or title identifiers.

Reference contract: https://api.simkl.org/openapi.json (`/sync/add-to-list` and
`/sync/all-items/{type}/{status}`). Tests use isolated HTTP fixtures, including
canonical-only movie/show acknowledgements and reads, not a real user's token.
These reproduce the code defect; they do not establish the HTTP response seen on
an individual iPhone. A recurring device failure still needs the privacy-safe
stage/category/HTTP status above to distinguish quota, authorization and network
causes. The old numeric error alone cannot recover its original response body.
