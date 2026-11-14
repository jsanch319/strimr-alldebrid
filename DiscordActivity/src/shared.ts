export type ControlMode = "host-only" | "everyone" | "approved";

export interface SafeMediaMetadata {
  mediaId: string;
  title: string;
  mediaType: "movie" | "show" | "episode";
  season: number | null;
  episode: number | null;
  duration: number;
  selectedSourceIdentifier: string | null;
}

export interface InitialPlaybackState {
  position: number;
  isPlaying: boolean;
}

export interface Participant {
  userId: string;
  username: string;
  host: boolean;
  canControl: boolean;
  canChangeSource: boolean;
}

export interface WatchRoom {
  sessionId: string;
  media: SafeMediaMetadata;
  currentPosition: number;
  isPlaying: boolean;
  hostUserId: string;
  participants: Participant[];
  controlMode: ControlMode;
  approvedUserIds: string[];
  sourceChangeUserIds: string[];
  updatedAt: number;
}

export type RoomCommand =
  | { type: "play" }
  | { type: "pause" }
  | { type: "seek"; position: number }
  | { type: "skip"; seconds: number }
  | { type: "set-control-mode"; mode: ControlMode }
  | { type: "set-approved-users"; userIds: string[] }
  | { type: "set-source-access"; userIds: string[] }
  | { type: "change-source"; sourceIdentifier: string }
  | { type: "change-media"; media: SafeMediaMetadata };

export const defaultMedia: SafeMediaMetadata = {
  mediaId: "",
  title: "Choose a title in Strimr",
  mediaType: "movie",
  season: null,
  episode: null,
  duration: 0,
  selectedSourceIdentifier: null,
};

export function sanitizeMedia(value: unknown): SafeMediaMetadata {
  if (!value || typeof value !== "object") return defaultMedia;
  const media = value as Record<string, unknown>;
  const mediaType = media.mediaType;
  return {
    mediaId: safeIdentifier(media.mediaId),
    title: safeText(media.title, 180) || defaultMedia.title,
    mediaType: mediaType === "show" || mediaType === "episode" ? mediaType : "movie",
    season: safeInteger(media.season),
    episode: safeInteger(media.episode),
    duration: safeDuration(media.duration),
    selectedSourceIdentifier: safeIdentifier(media.selectedSourceIdentifier) || null,
  };
}

function safeText(value: unknown, maximum: number): string {
  return typeof value === "string" ? value.trim().slice(0, maximum) : "";
}

function safeIdentifier(value: unknown): string {
  const identifier = safeText(value, 180);
  return /^[\w:.-]{1,180}$/.test(identifier) ? identifier : "";
}

function safeInteger(value: unknown): number | null {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0 ? value : null;
}

function safeDuration(value: unknown): number {
  return typeof value === "number" && Number.isFinite(value) ? Math.min(Math.max(0, value), 7 * 24 * 3600) : 0;
}
