import assert from "node:assert/strict";
import test from "node:test";
import { NativePairing } from "./nativePairing.js";
import { authorizedVideo, parseCatalog } from "./playbackCatalog.js";
import { defaultMedia, type WatchRoom } from "../src/shared.js";
import { VideoSync, positionAt } from "../src/videoSync.js";
import { isMappedVideoPath } from "../src/sourceResolver.js";
import { RoomService } from "./roomService.js";

const host = "111111111111111111", friend = "222222222222222222";
const entry = { mediaId: "movie:42", season: null, episode: null, sourceIdentifier: "authorized-cut", browserPath: "/media/owned/film.mp4", mimeType: "video/mp4", allowedDiscordUserIds: [host, friend] };
const media = { ...defaultMedia, mediaId: "movie:42", title: "Owned film", duration: 3600 };
function room(playing = true, position = 333.125): WatchRoom {
  return { revision: 1, sessionId: "activity", media, currentPosition: position, isPlaying: playing,
    hostUserId: host, participants: [], controlMode: "host-only", approvedUserIds: [], sourceChangeUserIds: [], updatedAt: 10_000 };
}
function fakeVideo() {
  return { currentTime: 0, paused: true, readyState: 0, plays: 0,
    seekable: { length: 0, start: () => 0, end: () => 3600 },
    pause() { this.paused = true; }, async play() { this.plays++; this.paused = false; } };
}

test("authorized source lookup is exact by title, episode, source and participant", () => {
  const catalog = parseCatalog([entry]);
  assert.equal(authorizedVideo(catalog, media, friend).browserPath, entry.browserPath);
  assert.throws(() => authorizedVideo(catalog, media, "333333333333333333"));
  assert.throws(() => authorizedVideo(catalog, { ...media, mediaId: "movie:43" }, host));
  assert.throws(() => authorizedVideo(catalog, { ...media, season: 1, episode: 2 }, host));
  assert.throws(() => authorizedVideo(catalog, { ...media, selectedSourceIdentifier: "other-cut" }, host));
  assert.equal(JSON.stringify(authorizedVideo(catalog, media, friend)).includes(host), false);
});

test("catalog rejects credential URLs, arbitrary fetches, traversal and wildcard permission", () => {
  for (const path of ["https://private.test/video?token=secret", "//private.test/file.mp4", "/media/../secret.mp4", "/media/%2e%2e/file.mp4", "/media/file.mp4?token=secret"]) {
    assert.equal(isMappedVideoPath(path), false);
    assert.throws(() => parseCatalog([{ ...entry, browserPath: path }]));
  }
  assert.throws(() => parseCatalog([{ ...entry, allowedDiscordUserIds: ["*"] }]));
  assert.throws(() => parseCatalog([{ ...entry, mimeType: "application/vnd.apple.mpegurl" }]));
});

test("pairing is one-use, expiring and replaces a prior code for the same user", () => {
  let now = 0;
  const pairing = new NativePairing(() => now);
  const identity = { userId: host, username: "Host", instanceId: "activity" };
  const old = pairing.issue(identity), code = pairing.issue(identity);
  assert.equal(code.length, 24);
  assert.throws(() => pairing.redeem(old));
  assert.deepEqual(pairing.redeem(code), identity);
  assert.throws(() => pairing.redeem(code));
  const expired = pairing.issue(identity); now = 120_001;
  assert.throws(() => pairing.redeem(expired));
});

test("snapshots do not double-count elapsed time and permission changes preserve position", () => {
  const rooms = new RoomService();
  rooms.join("activity", { userId: host, username: "Host", joinedAt: 0 }, media, 0, { position: 100.25, isPlaying: true });
  const snapshot = rooms.get("activity", 10_000)!;
  assert.equal(snapshot.currentPosition, 110.25);
  assert.equal(positionAt(snapshot, 11_000), 111.25);
  rooms.command("activity", host, { type: "set-control-mode", mode: "everyone" }, 12_000);
  assert.equal(rooms.get("activity", 13_000)!.currentPosition, 113.25);
});

test("native samples are revision checked and cannot bypass room permissions", () => {
  const rooms = new RoomService();
  rooms.join("activity", { userId: host, username: "Host", joinedAt: 0 }, media, 0);
  rooms.join("activity", { userId: friend, username: "Friend", joinedAt: 1 }, media, 1);
  assert.throws(() => rooms.command("activity", friend, { type: "sync-playback", position: 10, isPlaying: true, revision: 0 }, 2));
  const seek = rooms.command("activity", host, { type: "seek", position: 123.125 }, 3);
  const stale = rooms.command("activity", host, { type: "sync-playback", position: 0, isPlaying: true, revision: 0 }, 4);
  assert.equal(stale.currentPosition, 123.125); assert.equal(stale.revision, seek.revision);
  const update = rooms.command("activity", host, { type: "sync-playback", position: 456.5, isPlaying: true, revision: seek.revision }, 5);
  assert.equal(update.currentPosition, 456.5); assert.equal(update.isPlaying, true);
});

test("video waits for seekable resume instead of playing at zero", async () => {
  const video = fakeVideo(), sync = new VideoSync(video);
  assert.equal(await sync.apply(room(), 10_000), "waiting");
  video.readyState = 1;
  assert.equal(await sync.apply(room(), 10_000), "waiting"); assert.equal(video.plays, 0);
  video.seekable.length = 1;
  assert.equal(await sync.apply(room(), 10_000), "ready"); assert.equal(video.currentTime, 333.125);
  assert.equal(video.paused, false);
  await sync.apply(room(false, 600.75), 10_000);
  assert.equal(video.currentTime, 600.75); assert.equal(video.paused, true);
});

test("mobile autoplay denial requires a local gesture rather than retrying indefinitely", async () => {
  const video = fakeVideo(); video.readyState = 1; video.seekable.length = 1;
  const play = video.play.bind(video); let denied = true;
  video.play = async () => { if (denied) { video.plays++; throw new Error("NotAllowedError"); } await play(); };
  const sync = new VideoSync(video);
  assert.equal(await sync.apply(room(), 10_000), "tap");
  await sync.apply(room(), 10_000); assert.equal(video.plays, 1);
  denied = false; sync.enable(); await sync.apply(room(), 10_000); assert.equal(video.paused, false);
});

test("two simulated playback clients follow the same room pause seek and late join state", async () => {
  const rooms = new RoomService();
  rooms.join("activity", { userId: host, username: "Host", joinedAt: 0 }, media, 0, { position: 55.125, isPlaying: true });
  const first = fakeVideo(), second = fakeVideo();
  first.readyState = second.readyState = 1; first.seekable.length = second.seekable.length = 1;
  const a = new VideoSync(first), b = new VideoSync(second);
  await a.apply(rooms.get("activity", 5000)!, 5000);
  await b.apply(rooms.join("activity", { userId: friend, username: "Friend", joinedAt: 5000 }, media, 5000), 5000);
  assert.equal(first.currentTime, second.currentTime);
  const pause = rooms.command("activity", host, { type: "pause" }, 6000);
  await a.apply(pause, 6000); await b.apply(pause, 6000);
  assert.equal(first.paused, true); assert.equal(second.paused, true);
  const seek = rooms.command("activity", host, { type: "seek", position: 777.875 }, 7000);
  await a.apply(seek, 7000); await b.apply(seek, 7000);
  assert.equal(first.currentTime, 777.875); assert.equal(second.currentTime, 777.875);
});

test("completed video is held at the end rather than automatically replayed", async () => {
  const video = fakeVideo(); video.readyState = 1; video.seekable.length = 1; video.currentTime = 3600;
  const sync = new VideoSync(video);
  await sync.apply(room(true, 3600), 10_000);
  assert.equal(video.plays, 0); assert.equal(video.currentTime, 3600);
});
