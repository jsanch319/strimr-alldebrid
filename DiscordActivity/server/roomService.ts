import {
  defaultMedia,
  sanitizeMedia,
  type ControlMode,
  type Participant,
  type RoomCommand,
  type SafeMediaMetadata,
  type WatchRoom,
} from "../src/shared.js";

interface ConnectedUser {
  userId: string;
  username: string;
  joinedAt: number;
}

interface RoomRecord {
  state: WatchRoom;
  users: Map<string, ConnectedUser>;
  expiresAt: number | null;
}

const EMPTY_ROOM_TTL = 10 * 60 * 1000;

export class RoomService {
  private readonly rooms = new Map<string, RoomRecord>();

  join(sessionId: string, user: ConnectedUser, media: SafeMediaMetadata, now = Date.now()): WatchRoom {
    this.validateSessionId(sessionId);
    this.prune(now);
    let room = this.rooms.get(sessionId);
    if (!room) {
      room = {
        state: {
          sessionId,
          media: sanitizeMedia(media),
          currentPosition: 0,
          isPlaying: false,
          hostUserId: user.userId,
          participants: [],
          controlMode: "host-only",
          approvedUserIds: [],
          sourceChangeUserIds: [],
          updatedAt: now,
        },
        users: new Map(),
        expiresAt: null,
      };
      this.rooms.set(sessionId, room);
    }

    room.expiresAt = null;
    room.users.set(user.userId, { ...user, joinedAt: room.users.get(user.userId)?.joinedAt ?? now });
    if (!room.state.hostUserId || !room.users.has(room.state.hostUserId)) {
      room.state.hostUserId = this.oldestUser(room).userId;
    }
    return this.snapshot(room, now);
  }

  leave(sessionId: string, userId: string, now = Date.now()): WatchRoom | null {
    const room = this.rooms.get(sessionId);
    if (!room) return null;
    room.users.delete(userId);
    if (room.users.size === 0) {
      room.state.currentPosition = this.currentPosition(room.state, now);
      room.expiresAt = now + EMPTY_ROOM_TTL;
      room.state.isPlaying = false;
    } else if (room.state.hostUserId === userId) {
      room.state.hostUserId = this.oldestUser(room).userId;
    }
    room.state.updatedAt = now;
    return room.users.size > 0 ? this.snapshot(room, now) : null;
  }

  get(sessionId: string, now = Date.now()): WatchRoom | null {
    this.prune(now);
    const room = this.rooms.get(sessionId);
    return room ? this.snapshot(room, now) : null;
  }

  command(sessionId: string, userId: string, command: RoomCommand, now = Date.now()): WatchRoom {
    const room = this.rooms.get(sessionId);
    if (!room || !room.users.has(userId)) throw new Error("Join the room before sending commands.");
    const state = room.state;
    const isHost = state.hostUserId === userId;

    switch (command.type) {
      case "play":
      case "pause":
      case "seek":
      case "skip": {
        if (!this.canControl(state, userId)) throw new Error("You do not have playback control.");
        const position = this.currentPosition(state, now);
        state.currentPosition = command.type === "seek"
          ? this.clampPosition(command.position, state.media.duration)
          : command.type === "skip"
            ? this.clampPosition(position + command.seconds, state.media.duration)
            : position;
        if (command.type === "play") state.isPlaying = true;
        if (command.type === "pause") state.isPlaying = false;
        break;
      }
      case "set-control-mode":
        this.requireHost(isHost);
        state.controlMode = command.mode;
        if (command.mode !== "approved") state.approvedUserIds = [];
        break;
      case "set-approved-users":
        this.requireHost(isHost);
        state.approvedUserIds = this.validUserIds(command.userIds, room, userId);
        state.controlMode = "approved";
        break;
      case "set-source-access":
        this.requireHost(isHost);
        state.sourceChangeUserIds = this.validUserIds(command.userIds, room, userId);
        break;
      case "change-source":
        if (!isHost && !state.sourceChangeUserIds.includes(userId)) {
          throw new Error("Only the host can change the playback source.");
        }
        state.media = { ...state.media, selectedSourceIdentifier: safeIdentifier(command.sourceIdentifier) };
        break;
      case "change-media":
        this.requireHost(isHost);
        state.media = sanitizeMedia(command.media);
        state.currentPosition = 0;
        state.isPlaying = false;
        break;
      default:
        throw new Error("Unsupported room command.");
    }
    state.updatedAt = now;
    return this.snapshot(room, now);
  }

  private snapshot(room: RoomRecord, now: number): WatchRoom {
    const state = room.state;
    const participants: Participant[] = [...room.users.values()]
      .sort((left, right) => left.joinedAt - right.joinedAt)
      .map((user) => {
        const host = user.userId === state.hostUserId;
        return {
          userId: user.userId,
          username: user.username,
          host,
          canControl: host || state.controlMode === "everyone" ||
            (state.controlMode === "approved" && state.approvedUserIds.includes(user.userId)),
          canChangeSource: host || state.sourceChangeUserIds.includes(user.userId),
        };
      });
    return {
      ...state,
      currentPosition: this.currentPosition(state, now),
      participants,
      approvedUserIds: [...state.approvedUserIds],
      sourceChangeUserIds: [...state.sourceChangeUserIds],
    };
  }

  private currentPosition(state: WatchRoom, now: number): number {
    const elapsed = state.isPlaying ? Math.max(0, (now - state.updatedAt) / 1000) : 0;
    return this.clampPosition(state.currentPosition + elapsed, state.media.duration);
  }

  private clampPosition(position: number, duration: number): number {
    if (!Number.isFinite(position)) throw new Error("Playback position must be finite.");
    return Math.max(0, Math.min(position, duration > 0 ? duration : Number.MAX_SAFE_INTEGER));
  }

  private validUserIds(ids: string[], room: RoomRecord, hostUserId: string): string[] {
    if (!Array.isArray(ids)) throw new Error("User permissions must be a list.");
    return [...new Set(ids.filter((id) => typeof id === "string" && id !== hostUserId && room.users.has(id)))];
  }

  private canControl(state: WatchRoom, userId: string): boolean {
    return state.hostUserId === userId || state.controlMode === "everyone" ||
      (state.controlMode === "approved" && state.approvedUserIds.includes(userId));
  }

  private oldestUser(room: RoomRecord): ConnectedUser {
    const oldest = [...room.users.values()].sort((left, right) => left.joinedAt - right.joinedAt)[0];
    if (!oldest) throw new Error("Cannot select a host for an empty room.");
    return oldest;
  }

  private requireHost(isHost: boolean): void {
    if (!isHost) throw new Error("Only the host can change room settings.");
  }

  private prune(now: number): void {
    for (const [id, room] of this.rooms) {
      if (room.expiresAt !== null && room.expiresAt <= now) this.rooms.delete(id);
    }
  }

  private validateSessionId(sessionId: string): void {
    if (!/^[\w.-]{1,200}$/.test(sessionId)) throw new Error("Invalid Discord Activity instance.");
  }
}

function safeIdentifier(value: string): string {
  if (typeof value !== "string" || !/^[\w:.-]{1,180}$/.test(value.trim())) {
    throw new Error("Invalid source identifier.");
  }
  return value.trim();
}

export function isControlMode(value: unknown): value is ControlMode {
  return value === "host-only" || value === "everyone" || value === "approved";
}

export function initialRoomMedia(value: unknown): SafeMediaMetadata {
  return value && typeof value === "object" ? sanitizeMedia(value) : defaultMedia;
}
