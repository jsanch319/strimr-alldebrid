import { isMappedVideoPath } from "./shared.js";

export interface VideoRendition {
  id: string;
  browserPath: string;
  mimeType: "video/mp4";
  audioId: string;
  audioLabel: string;
  language: string;
  videoCodec: string;
  audioCodec: string;
  mode: "stream-copy" | "audio-conversion" | "video-transcode";
  width: number;
  height: number;
}
export interface PreparedSubtitle {
  id: string;
  label: string;
  language: string;
  browserPath: string | null;
  default: boolean;
  forced: boolean;
}
export interface PreparedMedia {
  renditions?: VideoRendition[];
  subtitles?: PreparedSubtitle[];
  notices?: string[];
}
const identifier = (s: unknown): s is string => typeof s === "string" && /^[\w-]{1,80}$/.test(s);
const text = (s: unknown): s is string => typeof s === "string" && s.length <= 120 && !/[\u0000-\u001f]/.test(s) && !s.includes("://");
const language = (s: unknown): s is string => typeof s === "string" && /^[a-z]{2,3}(?:-[A-Za-z0-9]{2,8})*$/.test(s);
export function parsePreparedMedia(raw: PreparedMedia): PreparedMedia {
  const renditions = raw.renditions ?? [], subtitles = raw.subtitles ?? [], notices = raw.notices ?? [];
  if (!Array.isArray(renditions) || renditions.length > 128 || !Array.isArray(subtitles) || subtitles.length > 64 ||
      !Array.isArray(notices) || notices.length > 128 || !notices.every((n) => typeof n === "string" && n.length <= 500 && !n.includes("://"))) throw new Error("Invalid prepared media.");
  const seen = new Set<string>();
  for (const r of renditions) {
    if (!r || !identifier(r.id) || seen.has(r.id) || !identifier(r.audioId) || !text(r.audioLabel) || !language(r.language) ||
        !isMappedVideoPath(r.browserPath) || !r.browserPath.endsWith(".mp4") || r.mimeType !== "video/mp4" ||
        !["stream-copy", "audio-conversion", "video-transcode"].includes(r.mode) ||
        ![r.videoCodec, r.audioCodec].every((v) => typeof v === "string" && /^[a-zA-Z0-9.-]{0,80}$/.test(v)) ||
        ![r.width, r.height].every((n) => Number.isSafeInteger(n) && n > 0 && n <= 16384)) throw new Error("Invalid prepared rendition.");
    seen.add(r.id);
  }
  const subtitleIDs = new Set<string>();
  for (const s of subtitles) {
    if (!s || !identifier(s.id) || subtitleIDs.has(s.id) || !text(s.label) || !language(s.language) ||
        typeof s.default !== "boolean" || typeof s.forced !== "boolean" ||
        (s.browserPath !== null && !(typeof s.browserPath === "string" && /^\/media\/[a-zA-Z0-9_/-]+\.vtt$/.test(s.browserPath)))) throw new Error("Invalid subtitle.");
    subtitleIDs.add(s.id);
  }
  // Copy only browser-safe fields. Never carry worker input paths, URLs or process logs.
  return {
    renditions: renditions.map((r) => ({ id: r.id, browserPath: r.browserPath, mimeType: r.mimeType,
      audioId: r.audioId, audioLabel: r.audioLabel, language: r.language, videoCodec: r.videoCodec,
      audioCodec: r.audioCodec, mode: r.mode, width: r.width, height: r.height })),
    subtitles: subtitles.map((s) => ({ id: s.id, label: s.label, language: s.language,
      browserPath: s.browserPath, default: s.default, forced: s.forced })), notices: [...notices],
  };
}

export function selectRendition(renditions: VideoRendition[], audioId: string, compatibleOnly: boolean,
  supported: (mime: string) => string): VideoRendition | undefined {
  const candidates = renditions.filter((r) => r.audioId === audioId && (!compatibleOnly || r.mode !== "stream-copy"));
  return candidates.find((r) => supported(`video/mp4; codecs="${[r.videoCodec, r.audioCodec].filter(Boolean).join(",")}"`)) ??
    candidates.find((r) => r.mode === "video-transcode") ?? candidates[0];
}
