export interface LocalPlaybackSource {
  playbackURL: URL;
  authorizationHeaders?: Readonly<Record<string, string>>;
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
