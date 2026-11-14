# Strimr Discord Watch Together

This is a standalone Discord Activity and room service. It does not embed or replace
Strimr's native player. The Activity shares playback metadata and control state;
each Strimr client is responsible for resolving its own authorized playback source.

## Requirements

- Node.js 22 or newer and npm
- A Discord application with Activities enabled
- A publicly reachable HTTPS URL for testing with Discord (a tunnel is suitable)
- A persistent HTTPS/WSS host for a deployed room service

## Create and configure a Discord application

1. Create an application in the [Discord Developer Portal](https://discord.com/developers/applications).
2. Under **Activities**, enable the Activity and configure its URL mapping. Map `/` to
   the HTTPS host serving this Activity and its room service. When the client and
   WebSocket service are split across hosts, add `/api` and `/ws` mappings to their
   respective hosts; the `/ws` target must accept WebSocket upgrades.
3. Configure the Entry Point command so users can launch the Activity, and enable the
   platforms you plan to test.
4. Under **OAuth2**, add `https://127.0.0.1` as the redirect URI. The Embedded App SDK
   handles the in-Activity authorization redirect.
5. Copy the public Application/Client ID. Do not copy the Client Secret or bot token
   into client-side configuration.
6. Create a bot for the application and grant it access to the Activity Instance API.
   The room service uses that API to verify that each authenticated Discord user is
   actually participating in the Activity.

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
DISCORD_ACTIVITY_URL = https://your-activity-host.example
```

The native button opens the Discord Activity URL with only safe media metadata in its
query string. If either value is missing, Strimr shows a configuration-required
message. Neither value is a secret.

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
- The source resolver interface is deliberately per-client. A future native bridge
  must resolve playback using each participant's own Strimr credentials and must keep
  the resulting URL and headers local.
- Discord IDs/usernames are used to identify room participants. Media metadata and
  source identifiers should be treated as visible to everyone in that Activity.
