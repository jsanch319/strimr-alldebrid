import "dotenv/config";
import { createHmac, timingSafeEqual, randomBytes } from "node:crypto";
import { createServer } from "node:http";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { readFileSync } from "node:fs";
import express from "express";
import { WebSocket, WebSocketServer, type RawData } from "ws";
import {
  defaultMedia,
  sanitizeMedia,
  type InitialPlaybackState,
  type RoomCommand,
  type SafeMediaMetadata,
  type WatchRoom,
} from "../src/shared.js";
import { isControlMode, RoomService } from "./roomService.js";
import { NativePairing } from "./nativePairing.js";
import { authorizedVideo, parseCatalog } from "./playbackCatalog.js";

const port = Number(process.env.PORT ?? 3001);
const appID = process.env.DISCORD_CLIENT_ID ?? "";
const clientSecret = process.env.DISCORD_CLIENT_SECRET ?? "";
const botToken = process.env.DISCORD_BOT_TOKEN ?? "";
const tokenSecret = process.env.ROOM_TOKEN_SECRET ?? "";
const redirectURI = process.env.DISCORD_REDIRECT_URI ?? "https://127.0.0.1";
const activityConfigurationComplete = Boolean(appID && clientSecret && botToken && tokenSecret.length >= 32);
const app = express();
export const server = createServer(app);
export const webSocketServer = new WebSocketServer({ noServer: true, maxPayload: 16 * 1024 });
const rooms = new RoomService();
const pairing = new NativePairing();
const catalog = (() => {
  try {
    return process.env.AUTHORIZED_MEDIA_CATALOG_PATH
      ? parseCatalog(JSON.parse(readFileSync(process.env.AUTHORIZED_MEDIA_CATALOG_PATH, "utf8"))) : [];
  } catch { throw new Error("Invalid authorized media catalog. Check the documented schema; catalog contents are not logged."); }
})();
class MembershipDenied extends Error {}
const membership = new Map<string, number>();
const nativeLeases = new Map<string, { identity: Omit<RoomIdentity, "exp">; expires: number }>();
const requests = new Map<string, { count: number; until: number }>();
const nativeKey = (instanceId: string, userId: string) => `${instanceId}:${userId}`;
const sockets = new Map<WebSocket, { sessionId: string; userId: string; expires: number }>();
const heartbeat = setInterval(() => {
  for (const [key, lease] of nativeLeases) {
    if (lease.expires <= Date.now()) {
      nativeLeases.delete(key);
      leaveIfDisconnected(lease.identity.instanceId, lease.identity.userId);
    }
  }
  for (const webSocket of webSocketServer.clients) {
    const identity = sockets.get(webSocket);
    if (identity) {
      if (identity.expires <= Date.now()) { webSocket.close(1008, "Session expired"); continue; }
      void verifyActivityParticipant(identity.sessionId, identity.userId).catch((error) => webSocket.close(error instanceof MembershipDenied ? 1008 : 1013, "Membership verification unavailable"));
    }
    if ((webSocket as WebSocket & { isAlive?: boolean }).isAlive === false) {
      webSocket.terminate();
      continue;
    }
    (webSocket as WebSocket & { isAlive?: boolean }).isAlive = false;
    webSocket.ping();
  }
}, 20_000);

app.use(express.json({ limit: "8kb" }));
app.use("/api", (request, response, next) => {
  response.setHeader("Cache-Control", "no-store");
  response.setHeader("Referrer-Policy", "no-referrer");
  // Bound pairing guesses/auth abuse. Configure trusted proxy/IP policy at deployment.
  for (const [key, item] of requests) if (item.until <= Date.now()) requests.delete(key);
  let key = request.ip ?? "unknown";
  try {
    const header = request.headers.authorization;
    if (header?.startsWith("Bearer ")) key = `user:${verifyRoomToken(header.slice(7)).userId}`;
  } catch { /* Invalid tokens share the bounded unauthenticated IP budget. */ }
  if (requests.size >= 10_000 && !requests.has(key)) { response.status(429).json({ error: "Request limit reached. Retry shortly." }); return; }
  const item = requests.get(key) ?? { count: 0, until: Date.now() + 60_000 };
  item.count += 1; requests.set(key, item);
  if (item.count > 180 || requests.size > 10_000) { response.status(429).json({ error: "Request limit reached. Retry shortly." }); return; }
  next();
});
app.get("/api/config", (_request, response) => {
  response.json({
    clientId: appID,
    configured: activityConfigurationComplete,
    message: activityConfigurationComplete
      ? null
      : "Discord Watch Together needs server-side Discord OAuth, bot, and room-signing configuration.",
  });
});
app.get("/healthz", (_request, response) => response.json({ status: "ok" }));
app.post("/api/auth", async (request, response) => {
  if (!activityConfigurationComplete) {
    response.status(503).json({ error: "Discord Activity server configuration is required." });
    return;
  }
  const { code, instanceId } = request.body as { code?: unknown; instanceId?: unknown };
  if (typeof code !== "string" || code.length > 2000 ||
      typeof instanceId !== "string" || !/^[\w.-]{1,200}$/.test(instanceId))
  {
    response.status(400).json({ error: "Invalid Discord authorization response." });
    return;
  }

  try {
    const { user, accessToken } = await exchangeCode(code);
    await verifyActivityParticipant(instanceId, user.id);
    response.json({
      token: signRoomToken({ userId: user.id, username: user.global_name || user.username, instanceId }),
      user: { id: user.id, username: user.global_name || user.username },
      access_token: accessToken,
    });
  } catch (error) {
    console.error("Discord Activity authentication failed.");
    response.status(401).json({ error: "Discord could not verify this Activity session." });
  }
});

app.post("/api/playback", async (request, response) => {
  try {
    const identity = await authenticated(request);
    const room = rooms.get(identity.instanceId);
    if (!room?.participants.some((p) => p.userId === identity.userId)) throw new Error("Join the Activity room first.");
    response.json(authorizedVideo(catalog, room.media, identity.userId));
  } catch { response.status(403).json({ error: "No authorized browser-compatible source is available for you in this room. Ask the operator to configure this title and your Discord ID." }); }
});

app.post("/api/native/code", async (request, response) => {
  try {
    const identity = await authenticated(request, "activity");
    const room = rooms.get(identity.instanceId);
    if (!room?.participants.some((p) => p.userId === identity.userId)) throw new Error("Join first.");
    response.json({ code: pairing.issue(identity), expiresIn: 120 });
  } catch { response.status(403).json({ error: "Join an authenticated Discord Activity before pairing Strimr." }); }
});

app.post("/api/native/pair", async (request, response) => {
  try {
    const identity = pairing.redeem(request.body?.code);
    await verifyActivityParticipant(identity.instanceId, identity.userId);
    const media = sanitizeMedia(request.body?.media);
    let room = rooms.get(identity.instanceId);
    if (!media.mediaId || !room?.participants.some((p) => p.userId === identity.userId)) throw new Error("Join first.");
    if (room.media.mediaId && !sameMedia(room.media, media)) throw new Error("Open the same movie or exact episode in Strimr and Discord.");
    if (room.hostUserId === identity.userId) {
      if (request.body?.initialPlayback === undefined) throw new Error("A ready native playback position is required.");
      const initial = parseInitialPlayback(request.body?.initialPlayback);
      // Refresh same-title metadata from the ready player. Details/launch metadata
      // can have a rounded runtime; never publish an intermediate reset to zero.
      const selectedSourceIdentifier = room.media.mediaId ? room.media.selectedSourceIdentifier : null;
      room = rooms.command(identity.instanceId, identity.userId, { type: "change-media", media: { ...media, selectedSourceIdentifier } });
      room = rooms.command(identity.instanceId, identity.userId, { type: "sync-playback", ...initial, revision: room.revision });
      broadcast(identity.instanceId, room);
    } else if (!room.media.mediaId) {
      throw new Error("The host must choose the title first.");
    }
    const nativeIdentity = { ...identity, kind: "native" as const, nativeSession: randomBytes(18).toString("base64url") };
    nativeLeases.set(nativeKey(identity.instanceId, identity.userId), { identity: nativeIdentity, expires: Date.now() + 15_000 });
    response.json({ token: signRoomToken(nativeIdentity), userId: identity.userId, room, serverTime: Date.now() });
  } catch { response.status(403).json({ error: "Pairing failed. Use a fresh code from your Activity and open the same movie or exact episode." }); }
});

app.post("/api/native/sync", async (request, response) => {
  try {
    const identity = await authenticated(request, "native");
    let room = rooms.get(identity.instanceId);
    if (!room || !sameMedia(room.media, sanitizeMedia(request.body?.media))) throw new Error("The room title changed. Reconnect with the matching title.");
    const lease = nativeLeases.get(nativeKey(identity.instanceId, identity.userId));
    if (!lease || lease.expires <= Date.now() || lease.identity.nativeSession !== identity.nativeSession) throw new Error("Native pairing expired. Pair again in Discord.");
    lease.expires = Date.now() + 15_000;
    const priorRevision = room.revision;
    if (request.body?.command) room = rooms.command(identity.instanceId, identity.userId, parseCommand(request.body.command));
    broadcast(identity.instanceId, room);
    response.json({ room, serverTime: Date.now(), commandAccepted: Boolean(request.body?.command) && room.revision > priorRevision });
  } catch { response.status(403).json({ error: "Room synchronization unavailable. Check Discord membership, permissions and the selected title, then pair again." }); }
});

app.post("/api/native/leave", async (request, response) => {
  try {
    const identity = await authenticated(request, "native");
    if (nativeLeases.get(nativeKey(identity.instanceId, identity.userId))?.identity.nativeSession !== identity.nativeSession) throw new Error("Native pairing replaced.");
    nativeLeases.delete(nativeKey(identity.instanceId, identity.userId));
    leaveIfDisconnected(identity.instanceId, identity.userId);
    response.json({ left: true });
  } catch { response.status(403).json({ error: "Native session unavailable." }); }
});

const clientDirectory = resolve(fileURLToPath(new URL("../dist", import.meta.url)));
app.use(express.static(clientDirectory));
app.get("*", (_request, response) => response.sendFile(resolve(clientDirectory, "index.html")));
app.use((_error: unknown, _request: express.Request, response: express.Response, _next: express.NextFunction) => {
  response.status(400).json({ error: "Invalid Activity request." });
});

server.on("upgrade", (request, socket, head) => {
  if (new URL(request.url ?? "/", "http://localhost").pathname !== "/ws") {
    socket.destroy();
    return;
  }
  webSocketServer.handleUpgrade(request, socket, head, (webSocket) => {
    webSocketServer.emit("connection", webSocket, request);
  });
});

webSocketServer.on("connection", (webSocket) => {
  let roomIdentity: { sessionId: string; userId: string } | null = null;
  (webSocket as WebSocket & { isAlive?: boolean }).isAlive = true;
  webSocket.on("pong", () => {
    (webSocket as WebSocket & { isAlive?: boolean }).isAlive = true;
  });
  webSocket.once("message", async (data) => {
    try {
      const request = parseJSON(data);
      if (request.type !== "join" || typeof request.token !== "string") {
        throw new Error("Join the room before sending commands.");
      }
      const identity = verifyRoomToken(request.token);
      if (identity.kind === "native") throw new Error("Use the native synchronization endpoint.");
      await verifyActivityParticipant(identity.instanceId, identity.userId);
      if (webSocket.readyState !== WebSocket.OPEN) return;
      if (request.sessionId !== identity.instanceId) throw new Error("This Discord identity is for another Activity.");
      const media = isPlainRecord(request.media) ? sanitizeMedia(request.media) : defaultMedia;
      const initialPlayback = parseInitialPlayback(request.initialPlayback);
      roomIdentity = { sessionId: identity.instanceId, userId: identity.userId };
      sockets.set(webSocket, { ...roomIdentity, expires: identity.exp });
      rooms.join(
        identity.instanceId,
        { userId: identity.userId, username: identity.username, joinedAt: Date.now() },
        media,
        Date.now(),
        initialPlayback,
      );
      broadcast(identity.instanceId);
    } catch (error) {
      send(webSocket, { type: "error", message: errorMessage(error) });
      webSocket.close(1008, "Invalid room request");
    }
  });

  webSocket.on("message", async (data) => {
    if (!roomIdentity) return;
    try {
      const request = parseJSON(data);
      if (request.type === "join") return;
      await verifyActivityParticipant(roomIdentity.sessionId, roomIdentity.userId);
      if (webSocket.readyState !== WebSocket.OPEN) return;
      const command = parseCommand(request.command);
      const room = rooms.command(roomIdentity.sessionId, roomIdentity.userId, command);
      broadcast(room.sessionId, room);
    } catch (error) {
      send(webSocket, { type: "error", message: errorMessage(error) });
    }
  });

  webSocket.on("close", () => {
    const identity = sockets.get(webSocket);
    if (!identity) return;
    sockets.delete(webSocket);
    if ([...sockets.values()].some((candidate) =>
      candidate.sessionId === identity.sessionId && candidate.userId === identity.userId
    )) return;
    leaveIfDisconnected(identity.sessionId, identity.userId);
  });
});

server.listen(port, "0.0.0.0", () => {
  console.info(`Discord Watch Together room service listening on port ${port}`);
});
server.on("close", () => clearInterval(heartbeat));

async function exchangeCode(code: string) {
  const body = new URLSearchParams({
    client_id: appID,
    client_secret: clientSecret,
    grant_type: "authorization_code",
    code,
    redirect_uri: redirectURI,
  });
  const tokenResponse = await fetch("https://discord.com/api/oauth2/token", {
    signal: AbortSignal.timeout(8000),
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body,
  });
  if (!tokenResponse.ok) throw new Error("Discord OAuth token exchange was rejected.");
  const token = await tokenResponse.json() as { access_token?: string };
  if (!token.access_token) throw new Error("Discord OAuth did not return an access token.");

  const userResponse = await fetch("https://discord.com/api/users/@me", {
    signal: AbortSignal.timeout(8000),
    headers: { Authorization: `Bearer ${token.access_token}` },
  });
  if (!userResponse.ok) throw new Error("Discord user lookup was rejected.");
  const user = await userResponse.json() as { id?: string; username?: string; global_name?: string | null };
  if (!user.id || !user.username) throw new Error("Discord returned incomplete user information.");
  return { user: { id: user.id, username: user.username, global_name: user.global_name }, accessToken: token.access_token };
}

async function verifyActivityParticipant(instanceId: string, userId: string): Promise<void> {
  const key = nativeKey(instanceId, userId);
  for (const [key, expires] of membership) if (expires <= Date.now()) membership.delete(key);
  if ((membership.get(key) ?? 0) > Date.now()) return;
  const url = `https://discord.com/api/applications/${encodeURIComponent(appID)}/activity-instances/${encodeURIComponent(instanceId)}`;
  const response = await fetch(url, { headers: { Authorization: `Bot ${botToken}` }, signal: AbortSignal.timeout(8000) });
  if (!response.ok) throw new Error("Discord Activity instance verification failed.");
  const instance = await response.json() as { application_id?: string; users?: string[] };
  if (instance.application_id !== appID || !instance.users?.includes(userId)) {
    throw new MembershipDenied("The authenticated user is not part of this Discord Activity.");
  }
  membership.set(key, Date.now() + 30_000);
}

interface RoomIdentity {
  nativeSession?: string;
  kind?: "native" | "activity";
  userId: string;
  username: string;
  instanceId: string;
  exp: number;
}

function signRoomToken(identity: Omit<RoomIdentity, "exp">): string {
  const payload = encodeBase64URL(JSON.stringify({ ...identity, exp: Date.now() + 8 * 60 * 60 * 1000 }));
  return `${payload}.${signature(payload)}`;
}

function verifyRoomToken(token: string): RoomIdentity {
  const [payload, receivedSignature, extra] = token.split(".");
  if (!payload || !receivedSignature || extra || !tokenSecret) throw new Error("Invalid room identity.");
  const expected = Buffer.from(signature(payload));
  const received = Buffer.from(receivedSignature);
  if (expected.length !== received.length || !timingSafeEqual(expected, received)) {
    throw new Error("Invalid room identity.");
  }
  const identity = JSON.parse(Buffer.from(payload, "base64url").toString("utf8")) as Partial<RoomIdentity>;
  if (typeof identity.userId !== "string" || typeof identity.username !== "string" ||
      typeof identity.instanceId !== "string" || typeof identity.exp !== "number" || identity.exp <= Date.now())
  {
    throw new Error("Expired room identity.");
  }
  return identity as RoomIdentity;
}

function signature(payload: string): string {
  return createHmac("sha256", tokenSecret).update(payload).digest("base64url");
}

function encodeBase64URL(value: string): string {
  return Buffer.from(value).toString("base64url");
}

function parseJSON(data: RawData): Record<string, unknown> {
  const value: unknown = JSON.parse(data.toString());
  if (!isPlainRecord(value)) throw new Error("Invalid message.");
  return value;
}

function parseInitialPlayback(value: unknown): InitialPlaybackState {
  if (value === undefined) return { position: 0, isPlaying: false };
  if (!isPlainRecord(value) ||
      typeof value.position !== "number" || !Number.isFinite(value.position) ||
      typeof value.isPlaying !== "boolean")
  {
    throw new Error("Invalid initial playback state.");
  }
  return { position: Math.max(0, value.position), isPlaying: value.isPlaying };
}

function parseCommand(value: unknown): RoomCommand {
  if (!isPlainRecord(value) || typeof value.type !== "string") throw new Error("Invalid room command.");
  switch (value.type) {
    case "sync-playback":
      if (typeof value.position !== "number" || !Number.isFinite(value.position) || typeof value.isPlaying !== "boolean" || !Number.isSafeInteger(value.revision)) throw new Error("Invalid playback sample.");
      return { type: value.type, position: value.position, isPlaying: value.isPlaying, revision: value.revision as number };
    case "play":
    case "pause":
      return { type: value.type };
    case "seek":
      if (typeof value.position !== "number" || !Number.isFinite(value.position)) throw new Error("Invalid seek position.");
      return { type: "seek", position: value.position };
    case "skip":
      if (typeof value.seconds !== "number" || !Number.isFinite(value.seconds)) throw new Error("Invalid skip amount.");
      return { type: "skip", seconds: value.seconds };
    case "set-control-mode":
      if (!isControlMode(value.mode)) throw new Error("Invalid room control mode.");
      return { type: value.type, mode: value.mode };
    case "set-approved-users":
    case "set-source-access":
      if (!Array.isArray(value.userIds) || !value.userIds.every((id) => typeof id === "string")) {
        throw new Error("Invalid user permission list.");
      }
      return { type: value.type, userIds: value.userIds };
    case "change-source":
      if (typeof value.sourceIdentifier !== "string") throw new Error("Invalid source identifier.");
      return { type: value.type, sourceIdentifier: value.sourceIdentifier };
    case "change-media":
      return { type: value.type, media: sanitizeMedia(value.media) };
    default:
      throw new Error("Unsupported room command.");
  }
}

function broadcast(sessionId: string, room = rooms.get(sessionId)): void {
  if (!room) return;
  for (const [webSocket, identity] of sockets) {
    if (identity.sessionId === sessionId && webSocket.readyState === WebSocket.OPEN) {
      send(webSocket, { type: "room", room, serverTime: Date.now() });
    }
  }
}

function send(webSocket: WebSocket, message: unknown): void {
  if (webSocket.readyState === WebSocket.OPEN || webSocket.readyState === WebSocket.CONNECTING) {
    webSocket.send(JSON.stringify(message));
  }
}

function isPlainRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function errorMessage(error: unknown): string {
  if (error instanceof SyntaxError) return "Invalid JSON room message.";
  return error instanceof Error ? error.message : "The room request failed.";
}

async function authenticated(request: express.Request, kind?: "native" | "activity"): Promise<RoomIdentity> {
  const header = request.headers.authorization;
  if (!header?.startsWith("Bearer ")) throw new Error("Authentication required.");
  const identity = verifyRoomToken(header.slice(7));
  if (kind && (identity.kind ?? "activity") !== kind) throw new Error("Wrong session type.");
  if (kind === "native" && !identity.nativeSession) throw new Error("Native session required.");
  await verifyActivityParticipant(identity.instanceId, identity.userId);
  return identity;
}
function sameMedia(a: SafeMediaMetadata, b: SafeMediaMetadata) {
  return a.mediaId === b.mediaId && a.mediaType === b.mediaType && a.season === b.season && a.episode === b.episode;
}
function leaveIfDisconnected(instanceId: string, userId: string) {
  if ([...sockets.values()].some((s) => s.sessionId === instanceId && s.userId === userId) ||
      (nativeLeases.get(nativeKey(instanceId, userId))?.expires ?? 0) > Date.now()) return;
  const updated = rooms.leave(instanceId, userId);
  if (updated) broadcast(instanceId, updated);
}
