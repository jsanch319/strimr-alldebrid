import assert from "node:assert/strict";
import test from "node:test";
import { once } from "node:events";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { WebSocket } from "ws";

// Real local HTTP/WS transports, mocked Discord provider only. This is not an
// actual Discord Activity or two-device playback certification.
test("HTTP/WS authenticated Activity and native pairing preserve permission and resume contracts", async (t) => {
  const appId = "999999999999999999", host = "111111111111111111", friend = "222222222222222222";
  const directory = mkdtempSync(join(tmpdir(), "strimr-discord-"));
  const catalog = join(directory, "catalog.json");
  writeFileSync(catalog, JSON.stringify([{ mediaId: "movie:42", season: null, episode: null,
    sourceIdentifier: "owned-cut", browserPath: "/media/owned/film.mp4", mimeType: "video/mp4", allowedDiscordUserIds: [host, friend] }]));
  Object.assign(process.env, { PORT: "0", DISCORD_CLIENT_ID: appId, DISCORD_CLIENT_SECRET: "fixture-secret",
    DISCORD_BOT_TOKEN: "fixture-bot", ROOM_TOKEN_SECRET: "fixture-room-signing-secret-long-enough", AUTHORIZED_MEDIA_CATALOG_PATH: catalog });
  const original = globalThis.fetch;
  t.mock.method(globalThis, "fetch", async (input: string | URL | Request, init?: RequestInit) => {
    const url = String(input);
    if (!url.startsWith("https://discord.com/")) return original(input, init);
    if (url.endsWith("oauth2/token")) {
      const body = init?.body as URLSearchParams;
      return Response.json({ access_token: body.get("code") === "host-code" ? "host-token" : "friend-token" });
    }
    if (url.endsWith("users/@me")) {
      const headers = init?.headers as Record<string, string>;
      return Response.json({ id: headers.Authorization === "Bearer host-token" ? host : friend, username: "Fixture" });
    }
    if (url.includes("activity-instances/activity")) return Response.json({ application_id: appId, users: [host, friend] });
    throw new Error("Unexpected external request in isolated test.");
  });
  const { server, webSocketServer } = await import("./index.js");
  if (!server.listening) await once(server, "listening");
  const address = server.address() as { port: number };
  const origin = `http://127.0.0.1:${address.port}`;
  t.after(async () => {
    for (const socket of webSocketServer.clients) socket.terminate();
    webSocketServer.close(); server.closeAllConnections(); await new Promise<void>((resolve) => server.close(() => resolve()));
    rmSync(directory, { recursive: true, force: true });
  });
  async function post(path: string, body: unknown, token?: string) {
    const response = await fetch(origin + path, { method: "POST", headers: {
      "Content-Type": "application/json", ...(token ? { Authorization: `Bearer ${token}` } : {}),
    }, body: JSON.stringify(body) });
    return { status: response.status, body: await response.json() as any };
  }
  async function connect(token: string) {
    const socket = new WebSocket(origin.replace("http:", "ws:") + "/ws");
    await once(socket, "open");
    const state = once(socket, "message");
    socket.send(JSON.stringify({ type: "join", token, sessionId: "activity" }));
    await state; return socket;
  }
  assert.equal((await post("/api/playback", {})).status, 403);
  const a = await post("/api/auth", { code: "host-code", instanceId: "activity" });
  const b = await post("/api/auth", { code: "friend-code", instanceId: "activity" });
  assert.equal(a.status, 200); assert.equal(a.body.access_token, "host-token");
  const first = await connect(a.body.token), second = await connect(b.body.token);
  t.after(() => { first.terminate(); second.terminate(); });
  const code = await post("/api/native/code", {}, a.body.token);
  const media = { mediaId: "movie:42", title: "Owned film", mediaType: "movie", season: null, episode: null, duration: 3600 };
  const pair = await post("/api/native/pair", { code: code.body.code, media, initialPlayback: { position: 333.125, isPlaying: true } });
  assert.equal(pair.status, 200); assert.ok(pair.body.room.currentPosition >= 333.125);
  assert.equal((await post("/api/native/pair", { code: code.body.code, media })).status, 403);
  const source = await post("/api/playback", {}, b.body.token);
  assert.equal(source.status, 200); assert.equal(source.body.browserPath, "/media/owned/film.mp4");
  assert.equal(JSON.stringify(pair.body.room).includes("token"), false);
  assert.equal(JSON.stringify(pair.body.room).includes("/media/"), false);
  const pause = await post("/api/native/sync", { media, command: { type: "sync-playback", revision: pair.body.room.revision, position: 456.875, isPlaying: false } }, pair.body.token);
  assert.equal(pause.status, 200); assert.equal(pause.body.room.currentPosition, 456.875);
  assert.equal(pause.body.commandAccepted, true);
  const stale = await post("/api/native/sync", { media, command: { type: "sync-playback", revision: 0, position: 0, isPlaying: true } }, pair.body.token);
  assert.equal(stale.body.room.currentPosition, 456.875); assert.equal(stale.body.room.isPlaying, false);
  assert.equal(stale.body.commandAccepted, false);
  const replacementCode = await post("/api/native/code", {}, a.body.token);
  const replacement = await post("/api/native/pair", { code: replacementCode.body.code,
    media: { ...media, duration: 3599.75 }, initialPlayback: { position: 456.875, isPlaying: false } });
  assert.equal(replacement.status, 200);
  assert.equal(replacement.body.room.media.duration, 3599.75);
  assert.equal(replacement.body.room.currentPosition, 456.875);
  assert.equal((await post("/api/native/sync", { media }, pair.body.token)).status, 403);
  assert.equal((await post("/api/native/leave", {}, pair.body.token)).status, 403);
  assert.equal((await post("/api/native/sync", { media }, replacement.body.token)).status, 200);
  assert.equal((await post("/api/native/sync", { media: { ...media, episode: 2 } }, pair.body.token)).status, 403);
  assert.equal((await post("/api/native/code", {}, pair.body.token)).status, 403);
  const friendCode = await post("/api/native/code", {}, b.body.token);
  const friendPair = await post("/api/native/pair", { code: friendCode.body.code, media }, undefined);
  assert.equal(friendPair.status, 200);
  const denied = await post("/api/native/sync", { media, command: { type: "sync-playback", revision: pause.body.room.revision, position: 0, isPlaying: true } }, friendPair.body.token);
  assert.equal(denied.status, 403);
  assert.equal((await post("/api/native/leave", {}, replacement.body.token)).status, 200);
});
