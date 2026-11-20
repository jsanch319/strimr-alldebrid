# Strimr Discord Watch Together

This is a standalone Discord Activity and room service. It does not embed or replace
Strimr's native player. The Activity now contains an HTML5 MP4/clear-HLS player and
a paired native control bridge. A friend can watch inside Discord without installing
Strimr or opening a separate website. Each viewer needs an independently authorized
copy of the same title/edition. No AllDebrid credential or private resolved URL is
transferred to Discord, the room service, or the other participants.

**Implementation status:** automated HTTP/WebSocket, permission and playback-model
tests are available. This change has NOT been verified inside Discord with two real
participants. Deployment, mobile autoplay, audio routing, app switching and real
video playback must pass the acceptance checklist below before calling it working.

## Requirements

- Node.js 22 or newer and npm
- A Discord application with Activities enabled
- A publicly reachable HTTPS URL for testing with Discord (a tunnel is suitable)
- A persistent HTTPS/WSS host for a deployed room service

## Create and configure a Discord application

1. Create an application in the [Discord Developer Portal](https://discord.com/developers/applications).
2. Under **Activities**, enable the Activity and configure its URL mapping. Map `/` to
   the HTTPS host serving this Activity and its room service. A single `/` mapping
   covers `/api` and `/ws` on this unified host. For split hosts, map those prefixes
   to targets preserving the corresponding `/api` and `/ws` paths; the WebSocket
   target must accept upgrades.
3. Configure the Entry Point command so users can launch the Activity, and enable the
   platforms you plan to test.
4. Under **OAuth2**, add `https://127.0.0.1` as the redirect URI. The Embedded App SDK
   handles the in-Activity authorization redirect.
5. Copy the public Application/Client ID. Do not copy the Client Secret or bot token
   into client-side configuration.
6. Use the bot belonging to this application and configure its token on the server.
   The room service calls Discord's Activity Instance API to verify that each
   authenticated Discord user is actually participating in the Activity.

The room API checks every participant with Discord's Activity Instance endpoint.
It therefore requires the application bot token. Keep the bot token, OAuth client
secret, and room signing key in the server's secret manager/environment only.

## Local development

From the repository root:

```sh
cd DiscordActivity
npm ci
cp .env.example .env
```

Set these values in `DiscordActivity/.env`:

```dotenv
VITE_DISCORD_CLIENT_ID=your-public-application-id
DISCORD_CLIENT_ID=your-public-application-id
DISCORD_CLIENT_SECRET=server-only-oauth-client-secret
DISCORD_BOT_TOKEN=server-only-bot-token
DISCORD_REDIRECT_URI=https://127.0.0.1
ROOM_TOKEN_SECRET=at-least-32-random-bytes
PORT=3001
```

Generate a signing secret locally with `openssl rand -base64 32`. Never commit `.env`.
Run the app and room service together:

```sh
npm run dev
```

In another terminal, expose port `5173` through a temporary HTTPS tunnel, then set the
Discord Activity URL mapping `/` target to that tunnel's hostname. The Vite server
proxies `/api` and `/ws` to the local room service on port `3001`. In Discord, enable
Developer Mode, join a voice channel, open the Activity launcher, and start the
development application. A browser opened directly is not a substitute for Discord's
Embedded App SDK environment.

For the native Strimr button, set these public values in the local
`Config/Config.xcconfig` (copy it from `Config/Config-example.xcconfig` if needed):

```xcconfig
DISCORD_APPLICATION_CLIENT_ID = your-public-application-id
DISCORD_ACTIVITY_URL = https://your-deployed-activity-host.example
```

The Activity is not deployed by the iOS build. Deploy the `DiscordActivity/` app as a
long-running Node.js web service with HTTPS and WebSocket support. For example, create
a Render Web Service from this repository with root directory `DiscordActivity`,
build command `npm ci && npm run build`, and start command `npm start`. Configure the
server-only environment values from `DiscordActivity/.env.example` in the hosting
service's secret settings. Do not put the bot token, OAuth client secret, or room
signing key in `Config.xcconfig`, GitHub variables, or the iOS app.

After deployment, copy the service's HTTPS origin (for example,
`https://strimr-watch-together.onrender.com`, with no path or trailing slash) into
`DISCORD_ACTIVITY_URL`. In the Discord Developer Portal, enable Activities and map `/`
to that host. The `/` mapping covers the unified HTTP/WebSocket service; permit
WebSocket upgrades. Avoid adding prefix mappings that strip `/api` or `/ws`. Enable iOS under Activities' supported platforms and configure
the Entry Point command. The app ID is the public Application ID shown in the portal,
not the OAuth client secret.

The native detail and player buttons open Discord's Activity deep link for that
Application ID with safe media/playback metadata only. iOS checks that Discord is
installed before opening the link. To make a SideStore IPA launch the deployed
Activity, add the following **repository Actions variables** (Settings → Secrets and
variables → Actions → Variables):

- `DISCORD_APPLICATION_CLIENT_ID`: public Discord Application ID.
- `DISCORD_ACTIVITY_URL`: deployed HTTPS origin described above.

The iOS build and SideStore workflows embed those public values in the app's Info.plist.
Without them, the safe placeholders from `Config-example.xcconfig` are used and the
Watch Together button reports that configuration is required. Neither value is a
secret.

## Build, test, run

```sh
npm ci
npm test
npm run build
npm start
```

`npm start` serves the built `dist` client and the WebSocket/HTTP room service from the
same host. Deploy the build to a long-running Node.js host with HTTPS/WSS and configure
the four server-only OAuth, bot, and signing values as environment secrets.

## Room behavior and privacy

- Discord's Activity instance ID is the room ID; Discord joins participants to the
  same Activity instance.
- New rooms use **Host Only** playback controls. The host can switch to **Everyone**,
  or **Approved Users**, at any time. The “Let others control playback” toggle switches
  between Host Only and Everyone.
- Source changes remain host-only unless the host explicitly grants source access to a
  participant. Playback permission does not grant source permission.
- A departing host is replaced by the longest-connected participant. Empty rooms
  remain in memory for ten minutes for reconnects. Room state is in-memory only in this
  foundation, so a server restart ends active rooms.
- Playback state is event-driven and timestamped; clients estimate current position
  from the last update instead of broadcasting every frame.
- Server-side room types are allowlisted. OAuth/bot credentials, authorization
  headers, and playback URLs are not part of room state or broadcast messages.
- The iPhone keeps its existing player/source and pairs using a private, one-use code.
  Browser participants resolve an operator-configured authorized source per user.
- Discord IDs/usernames are used to identify room participants. Media metadata and
  source identifiers should be treated as visible to everyone in that Activity.

## Configure authorized browser video (required)

There is no general movie discovery or AllDebrid redistribution endpoint here.
Supply an operator-controlled catalog for content you have permission to deliver to
the listed participants. Set `AUTHORIZED_MEDIA_CATALOG_PATH` to an absolute path on
the server. Keep this file outside Git (the pattern `authorized-media*.local.json`
is ignored). An empty catalog fails clearly; it never plays an unrelated demo clip.

Example **schema only**, replace every ID/path with your own authorized title:

```json
[
  {
    "mediaId": "movie:42",
    "season": null,
    "episode": null,
    "sourceIdentifier": "authorized-theatrical-cut",
    "browserPath": "/media/owned/film.mp4",
    "mimeType": "video/mp4",
    "allowedDiscordUserIds": ["111111111111111111", "222222222222222222"]
  }
]
```

Use the exact Strimr media identifier (TMDb catalog movies normally `movie:<id>`,
episodes `tv:<series-id>:s<season>:e<episode>`); set the exact season/episode for TV.
These are identifiers, not streaming URLs. A different cut/duration cannot be used
interchangeably. The player flags significant duration mismatches. The room title
and exact episode must match the already-open native player before pairing.

In Discord URL Mappings add `/media` → the **authorized media origin**. The Activity
requests `/media/owned/film.mp4`; the origin must serve that path under the mapping's
prefix rules. Verify the final proxy request in Discord's developer tools. Use
relative URLs for every HLS playlist, segment, subtitle and key, keeping them within
approved mappings. Supply correct content types, byte-range support for MP4, HTTPS,
and origin/proxy CORS settings. A normal browser test does not prove Discord proxy
compatibility. For local development only, add a Vite `/media` proxy to your own
authorized media origin; none is configured by default.

MP4/H.264/AAC is a practical compatibility starting point. Clear HLS uses native HLS
where available, otherwise hls.js where MediaSource is supported. MKV, unsupported
codecs, encrypted/DRM services and arbitrary AllDebrid links are not converted or
unlocked. No paid video API is added; hosting/media bandwidth is operator-provided.
The native iPhone continues using its original source, quality and player pipeline.

The catalog ACL controls source discovery, **not the origin's asset access policy**.
Anything delivered to a browser can be inspected by that authorized viewer. Configure
only assets permitted for this exposure; protected providers require their own
authorized access mechanism. Do not put tokens, query credentials, private AllDebrid
URLs or authorization headers in the catalog or room. The server is not a media relay.

## Pair Strimr and invite a friend

1. Deploy/configure the Activity and media mappings, enable its iOS/Android platforms,
   and allow both real Discord test accounts (or complete Discord distribution setup).
2. Start the Activity in Discord. The SDK authorizes/authenticates the current user;
   the server verifies actual Activity membership with Discord's bot-authenticated API.
3. Select **Use my Strimr iPhone player**. This stops video on that Discord client and
   displays a private, single-use, 144-bit pairing code that expires in two minutes.
   Copy it; never send it in a channel message or invitation.
4. In Strimr open the movie/exact episode and start its existing authorized playback.
   In the native player's Discord control choose **Connect to Activity**, paste the
   code, and connect. The room host seeds the exact position (fractional seconds
   retained). If Discord's launch URL dropped title query data, pairing initializes
   an empty room; it refuses to replace an already selected different title.
5. Use **Invite** in the Activity (`openInviteDialog`). The friend joins the same
   Activity in Discord and watches the configured video there. They need Discord,
   permission for that source and access to the Activity, not Strimr or Codex.
6. On mobile, **Enable playback on this device** may be required by autoplay/audio
   policy. It is a local gesture and does not grant room-control privileges. Muting
   is per device. Native and browser controls obey the existing Host Only / Everyone /
   Approved Users policy; source permission remains independent.

Strimr's player is reused for seeks/play/pause and its existing resume/Simkl recorder
continues to observe playback. There is no second AVPlayer, source URL upload, or
new progress database. Paired sessions use 1x speed, restoring the prior session rate
on disconnect. SharePlay and Discord coordination cannot run concurrently. Changing
to another title disconnects pairing rather than controlling the wrong episode.

Room snapshots are rebased to their own timestamps. Native samples carry a room
revision so old local state cannot overwrite a newer seek/pause. Temporary zero
positions are not published over a valid resume unless the user intentionally seeks
there. The browser waits for metadata/seekability before restoring a nonzero position.
It never starts at zero as a fallback for an unseekable saved position. Remote video
application does not send events back into the room, preventing echo loops.

Native polling is once per two seconds with one in-flight request and bounded failure
handling. Pairing tokens stay in memory; disconnect/reopening requires fresh pairing.
Native presence leases expire after missed polls; host transfer and reconnection use
the existing room lifecycle. Discord membership is rechecked with a 30-second cache.
Room tokens expire after eight hours; reopen the Activity/pair again after expiry.
Single-instance deployment is required: rooms, pair codes and leases are in memory.
Configure HTTPS/WSS, trusted reverse-proxy/IP rules and edge rate limiting. Do not log
Authorization headers, `/api/auth`/pair request bodies or private pairing responses.

## Required real Discord acceptance tests (NOT yet performed)

- Two real participants: host plays in Strimr on a signed iPhone, friend plays video
  inside the supported Discord mobile Activity. Record Discord/iOS versions and the
  authorized source/codec. A mock browser or two simulated clients does not count.
- Invite/join late at a nonzero exact resume; play/pause and seek both directions.
  Check host-only, everyone, approved users and independent source permissions.
- Confirm one active audio/video pipeline per participant. Test mute, mobile gesture
  requirements, background/lock/unlock and switching between Strimr and Discord.
  **Do not assume the host's Activity membership or iOS polling survives app switches.**
  A second device running the host's Discord Activity may be needed; verify with the
  target Discord build rather than claiming a one-iPhone workflow is certified.
- Disconnect/rejoin, host departure, network interruption and expired pairing/session.
  Resume data must remain valid; stale native samples must not restore zero.
- Wrong episode/edition, absent authorization, unavailable mapping, unsupported codec,
  nonseekable source, buffering, and autoplay denial must fail clearly.
- Inspect room frames, access logs, browser storage and invitations for leaked
  AllDebrid keys/private URLs. Browser viewers see only their authorized mapped asset.

Until these pass on the deployed app, report the feature as implemented but unverified
in Discord, including any mobile limitations. The local test suite mocks Discord's
identity service and uses simulated video ports; it does not claim end-to-end playback.
