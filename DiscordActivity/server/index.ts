import "dotenv/config";
import { createHmac, timingSafeEqual } from "node:crypto";
import { createServer } from "node:http";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
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

const port = Number(process.env.PORT ?? 3001);
const appID = process.env.DISCORD_CLIENT_ID ?? "";
const clientSecret = process.env.DISCORD_CLIENT_SECRET ?? "";
const botToken = process.env.DISCORD_BOT_TOKEN ?? "";
const tokenSecret = process.env.ROOM_TOKEN_SECRET ?? "";
const redirectURI = process.env.DISCORD_REDIRECT_URI ?? "https://127.0.0.1";
const activityConfigurationComplete = Boolean(appID && clientSecret && botToken && tokenSecret.length >= 32);
const app = express();
const server = createServer(app);
const webSocketServer = new WebSocketServer({ noServer: true, maxPayload: 16 * 1024 });
const rooms = new RoomService();
const sockets = new Map<WebSocket, { sessionId: string; userId: string }>();
const heartbeat = setInterval(() => {
  for (const webSocket of webSocketServer.clients) {
    if ((webSocket as WebSocket & { isAlive?: boolean }).isAlive === false) {
      webSocket.terminate();
      continue;
    }
    (webSocket as WebSocket & { isAlive?: boolean }).isAlive = false;
    webSocket.ping();
  }
}, 20_000);

app.use(express.json({ limit: "8kb" }));
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
    const user = await exchangeCode(code);
    await verifyActivityParticipant(instanceId, user.id);
    response.json({
      token: signRoomToken({ userId: user.id, username: user.global_name || user.username, instanceId }),
      user: { id: user.id, username: user.global_name || user.username },
    });
  } catch (error) {
    console.error("Discord Activity authentication failed:", error);
    response.status(401).json({ error: "Discord could not verify this Activity session." });
  }
});

const clientDirectory = resolve(fileURLToPath(new URL("../dist", import.meta.url)));
app.use(express.static(clientDirectory));
app.get("*", (_request, response) => response.sendFile(resolve(clientDirectory, "index.html")));

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
  webSocket.once("message", (data) => {
    try {
      const request = parseJSON(data);
      if (request.type !== "join" || typeof request.token !== "string") {
        throw new Error("Join the room before sending commands.");
      }
      const identity = verifyRoomToken(request.token);
      if (request.sessionId !== identity.instanceId) throw new Error("This Discord identity is for another Activity.");
      const media = isPlainRecord(request.media) ? sanitizeMedia(request.media) : defaultMedia;
      const initialPlayback = parseInitialPlayback(request.initialPlayback);
      roomIdentity = { sessionId: identity.instanceId, userId: identity.userId };
      sockets.set(webSocket, roomIdentity);
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

  webSocket.on("message", (data) => {
    if (!roomIdentity) return;
    try {
      const request = parseJSON(data);
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
    const updated = rooms.leave(identity.sessionId, identity.userId);
    if (updated) broadcast(identity.sessionId, updated);
  });
});

server.listen(port, "0.0.0.0", () => {
  console.info(`Discord Watch Together room service listening on port ${port}`);
});
server.on("close", () => clearInterval(heartbeat));

async function exchangeCode(code: string): Promise<{ id: string; username: string; global_name?: string | null }> {
  const body = new URLSearchParams({
    client_id: appID,
    client_secret: clientSecret,
    grant_type: "authorization_code",
    code,
    redirect_uri: redirectURI,
  });
  const tokenResponse = await fetch("https://discord.com/api/oauth2/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body,
  });
  if (!tokenResponse.ok) throw new Error("Discord OAuth token exchange was rejected.");
  const token = await tokenResponse.json() as { access_token?: string };
  if (!token.access_token) throw new Error("Discord OAuth did not return an access token.");

  const userResponse = await fetch("https://discord.com/api/users/@me", {
    headers: { Authorization: `Bearer ${token.access_token}` },
  });
  if (!userResponse.ok) throw new Error("Discord user lookup was rejected.");
  const user = await userResponse.json() as { id?: string; username?: string; global_name?: string | null };
  if (!user.id || !user.username) throw new Error("Discord returned incomplete user information.");
  return { id: user.id, username: user.username, global_name: user.global_name };
}

async function verifyActivityParticipant(instanceId: string, userId: string): Promise<void> {
  const url = `https://discord.com/api/applications/${encodeURIComponent(appID)}/activity-instances/${encodeURIComponent(instanceId)}`;
  const response = await fetch(url, { headers: { Authorization: `Bot ${botToken}` } });
  if (!response.ok) throw new Error("Discord Activity instance verification failed.");
  const instance = await response.json() as { application_id?: string; users?: string[] };
  if (instance.application_id !== appID || !instance.users?.includes(userId)) {
    throw new Error("The authenticated user is not part of this Discord Activity.");
  }
}

interface RoomIdentity {
  userId: string;
  username: string;
  instanceId: string;
  exp: number;
}

function signRoomToken(identity: Omit<RoomIdentity, "exp">): string {
  const payload = encodeBase64URL(JSON.stringify({ ...identity, exp: Date.now() + 15 * 60 * 1000 }));
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
  return error instanceof Error ? error.message : "The room request failed.";
}
