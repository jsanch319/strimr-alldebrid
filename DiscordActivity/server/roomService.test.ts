import assert from "node:assert/strict";
import test from "node:test";
import { defaultMedia, type RoomCommand } from "../src/shared.js";
import { RoomService } from "./roomService.js";

const media = { ...defaultMedia, mediaId: "movie-42", title: "Test Movie", duration: 3600 };

test("new rooms default to host-only playback and source changes", () => {
  const rooms = new RoomService();
  const room = rooms.join("activity-1", { userId: "host", username: "Host", joinedAt: 1 }, media, 1);
  assert.equal(room.controlMode, "host-only");
  assert.equal(room.participants[0]?.canControl, true);
  assert.equal(room.participants[0]?.canChangeSource, true);
});

test("the first join seeds playback state and later joins do not overwrite it", () => {
  const rooms = new RoomService();
  const firstRoom = rooms.join(
    "activity-seed",
    { userId: "host", username: "Host", joinedAt: 10_000 },
    media,
    10_000,
    { position: 45, isPlaying: true },
  );
  assert.equal(firstRoom.currentPosition, 45);
  assert.equal(firstRoom.isPlaying, true);

  const joinedRoom = rooms.join(
    "activity-seed",
    { userId: "friend", username: "Friend", joinedAt: 20_000 },
    media,
    20_000,
    { position: 0, isPlaying: false },
  );
  assert.equal(joinedRoom.currentPosition, 55);
  assert.equal(joinedRoom.isPlaying, true);
});

test("host can grant everyone playback control without granting source selection", () => {
  const rooms = roomWithParticipants();
  rooms.command("activity-1", "host", { type: "set-control-mode", mode: "everyone" }, 10);
  const room = rooms.get("activity-1", 10);
  assert.equal(room?.participants.find(({ userId }) => userId === "friend")?.canControl, true);
  assert.equal(room?.participants.find(({ userId }) => userId === "friend")?.canChangeSource, false);
  assert.throws(() => rooms.command("activity-1", "friend", {
    type: "change-source",
    sourceIdentifier: "another-source",
  }), /Only the host/);
});

test("host can explicitly grant source changes without changing playback permissions", () => {
  const rooms = roomWithParticipants();
  rooms.command("activity-1", "host", { type: "set-source-access", userIds: ["friend"] }, 10);
  const room = rooms.get("activity-1", 10);
  assert.equal(room?.participants.find(({ userId }) => userId === "friend")?.canControl, false);
  assert.equal(room?.participants.find(({ userId }) => userId === "friend")?.canChangeSource, true);
  rooms.command("activity-1", "friend", { type: "change-source", sourceIdentifier: "source-2" }, 11);
  assert.equal(rooms.get("activity-1", 11)?.media.selectedSourceIdentifier, "source-2");
  assert.throws(() => rooms.command("activity-1", "friend", {
    type: "change-source",
    sourceIdentifier: "https://private.example/video?token=secret",
  }), /Invalid source identifier/);
});

test("approved mode restricts playback controls to host-approved participants", () => {
  const rooms = roomWithParticipants();
  assert.throws(() => rooms.command("activity-1", "friend", { type: "play" }, 10_000), /do not have playback control/);
  rooms.command("activity-1", "host", { type: "set-approved-users", userIds: ["friend", "unknown"] }, 10_000);
  assert.equal(rooms.get("activity-1", 10_000)?.participants.find(({ userId }) => userId === "friend")?.canControl, true);
  assert.equal(rooms.get("activity-1", 10_000)?.participants.some(({ userId }) => userId === "unknown"), false);
  rooms.command("activity-1", "friend", { type: "play" }, 20_000);
  assert.equal(rooms.get("activity-1", 22_000)?.currentPosition, 2);
});

test("only host may change room control permissions", () => {
  const rooms = roomWithParticipants();
  assert.throws(() => rooms.command("activity-1", "friend", {
    type: "set-control-mode",
    mode: "everyone",
  }), /Only the host/);
});

test("host departure transfers control and reconnect revives the room", () => {
  const rooms = roomWithParticipants();
  const room = rooms.leave("activity-1", "host", 10);
  assert.equal(room?.hostUserId, "friend");
  assert.equal(room?.participants[0]?.host, true);
  rooms.leave("activity-1", "friend", 20);
  const reconnected = rooms.join(
    "activity-1",
    { userId: "host", username: "Host", joinedAt: 30 },
    media,
    30,
  );
  assert.equal(reconnected.hostUserId, "host");
});

test("metadata sanitation drops credentials and playback URLs", () => {
  const rooms = new RoomService();
  const room = rooms.join(
    "activity-2",
    { userId: "host", username: "Host", joinedAt: 1 },
    {
      ...media,
      apiKey: "never-share",
      playbackUrl: "https://private.example/video",
      authorization: "Bearer private",
      selectedSourceIdentifier: "https://private.example/video?token=secret",
    } as typeof media,
    1,
  );
  assert.deepEqual(room.media, media);
  assert.equal(JSON.stringify(room).includes("never-share"), false);
  assert.equal(JSON.stringify(room).includes("private.example"), false);
  assert.equal(JSON.stringify(room).includes("authorization"), false);
});

test("seek and skip are timestamped, duration-bounded room controls", () => {
  const rooms = roomWithParticipants();
  const commands: RoomCommand[] = [
    { type: "seek", position: 100 },
    { type: "skip", seconds: 30 },
  ];
  rooms.command("activity-1", "host", commands[0]!, 10);
  rooms.command("activity-1", "host", commands[1]!, 20);
  assert.equal(rooms.get("activity-1", 20)?.currentPosition, 130);
  rooms.command("activity-1", "host", { type: "seek", position: 5000 }, 30);
  assert.equal(rooms.get("activity-1", 30)?.currentPosition, 3600);
});

function roomWithParticipants(): RoomService {
  const rooms = new RoomService();
  rooms.join("activity-1", { userId: "host", username: "Host", joinedAt: 1 }, media, 1);
  rooms.join("activity-1", { userId: "friend", username: "Friend", joinedAt: 2 }, media, 2);
  return rooms;
}
