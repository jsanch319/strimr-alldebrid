import { parsePreparedMedia, type PreparedMedia } from "./preparedMedia.js";
export interface LocalPlaybackSource {
  playbackURL: URL;
  authorizationHeaders?: Readonly<Record<string, string>>;
}

export { isMappedVideoPath } from "./shared.js";
import { isMappedVideoPath } from "./shared.js";

export async function resolveBrowserVideo(token: string, signal: AbortSignal) {
  const response = await fetch("/api/playback", {
    method: "POST", headers: { Authorization: `Bearer ${token}` }, signal,
  });
  if (!response.ok) throw new Error("No authorized browser-compatible video is configured for you. Ask the operator to configure this exact title and your Discord user ID.");
  const source = await response.json() as PreparedMedia & { browserPath?: string; mimeType?: string };
  if (!isMappedVideoPath(source.browserPath) || !["video/mp4", "application/vnd.apple.mpegurl"].includes(source.mimeType ?? "")) {
    throw new Error("The configured video mapping is invalid.");
  }
  return { ...parsePreparedMedia(source), browserPath: source.browserPath, mimeType: source.mimeType };
}

export interface ClientPlaybackSourceResolver {
  resolve(mediaId: string, sourceIdentifier: string | null): Promise<LocalPlaybackSource>;
}

/**
 * Kept behind a per-client interface: implementations must resolve using that user's own Strimr session.
 * Resolved URLs and headers must never be copied into WatchRoom or Activity messages.
 */
export async function resolveLocalPlaybackSource(
  resolver: ClientPlaybackSourceResolver,
  mediaId: string,
  sourceIdentifier: string | null,
): Promise<LocalPlaybackSource> {
  if (!mediaId.trim()) throw new Error("A media ID is required to resolve playback.");
  return resolver.resolve(mediaId, sourceIdentifier);
}
