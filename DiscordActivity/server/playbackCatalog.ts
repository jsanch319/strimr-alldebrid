import type { SafeMediaMetadata } from "../src/shared.js";
import { isMappedVideoPath } from "../src/sourceResolver.js";

export interface AuthorizedVideo {
  mediaId: string;
  season: number | null;
  episode: number | null;
  sourceIdentifier: string;
  browserPath: string;
  mimeType: "video/mp4" | "application/vnd.apple.mpegurl";
  allowedDiscordUserIds: string[];
}

// /media is a Discord mapping to an origin authorized to serve these viewers.
// This is not an AllDebrid relay, arbitrary URL fetcher, or DRM unlocker.
export function parseCatalog(raw: unknown): AuthorizedVideo[] {
  if (!Array.isArray(raw)) throw new Error("Authorized media catalog must be an array.");
  return raw.map((value: unknown) => {
    const item = value as AuthorizedVideo;
    if (!item || typeof item.mediaId !== "string" || !/^[\w:.-]{1,180}$/.test(item.mediaId) ||
        typeof item.sourceIdentifier !== "string" || !/^[\w:.-]{1,180}$/.test(item.sourceIdentifier) ||
        !isMappedVideoPath(item.browserPath) ||
        ![item.season, item.episode].every((n) => n === null || (Number.isSafeInteger(n) && n! >= 0)) ||
        !["video/mp4", "application/vnd.apple.mpegurl"].includes(item.mimeType) ||
        item.browserPath.endsWith(".mp4") !== (item.mimeType === "video/mp4") ||
        !Array.isArray(item.allowedDiscordUserIds) || !item.allowedDiscordUserIds.length ||
        !item.allowedDiscordUserIds.every((id) => /^\d{17,20}$/.test(id))) {
      throw new Error("Invalid authorized media catalog entry.");
    }
    return { mediaId: item.mediaId, season: item.season, episode: item.episode,
      sourceIdentifier: item.sourceIdentifier, browserPath: item.browserPath,
      mimeType: item.mimeType, allowedDiscordUserIds: [...item.allowedDiscordUserIds] };
  });
}

export function authorizedVideo(catalog: AuthorizedVideo[], media: SafeMediaMetadata, userId: string) {
  const entry = catalog.find((item) => item.mediaId === media.mediaId &&
    item.season === media.season && item.episode === media.episode &&
    (!media.selectedSourceIdentifier || item.sourceIdentifier === media.selectedSourceIdentifier) &&
    item.allowedDiscordUserIds.includes(userId));
  if (!entry) throw new Error("No authorized browser-compatible video is configured for this title and participant.");
  return { browserPath: entry.browserPath, mimeType: entry.mimeType, sourceIdentifier: entry.sourceIdentifier };
}
