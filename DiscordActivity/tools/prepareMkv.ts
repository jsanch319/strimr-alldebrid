import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { mkdtemp, realpath, rename, rm, stat, writeFile } from "node:fs/promises";
import { resolve, join } from "node:path";
import { pathToFileURL } from "node:url";
import { parseCatalog, type AuthorizedVideo } from "../server/playbackCatalog.js";
import type { VideoRendition, PreparedSubtitle } from "../src/preparedMedia.js";

const execute = promisify(execFile);
class PreparationError extends Error {}
export interface MediaStream {
  index: number; codec_type: string; codec_name: string; profile?: string; level?: number;
  width?: number; height?: number; channels?: number; color_transfer?: string; codec_tag_string?: string;
  disposition?: Record<string, number>; tags?: Record<string, string>;
  side_data_list?: { side_data_type?: string }[];
}
export interface MediaProbe { streams: MediaStream[]; format: { format_name: string; start_time?: string; duration?: string } }
export interface PrepareOptions {
  input: string; outputRoot: string; slug: string; mediaId: string; userIds: string[];
  season?: number | null; episode?: number | null;
  authorized: boolean; transcode?: boolean; allowSDRFallback?: boolean; preset?: string; timeoutSeconds?: number;
}
const videoCopy = new Set(["h264", "hevc"]);
const audioCopy = new Set(["aac", "mp3", "ac3", "eac3", "alac", "opus"]);
const textSubtitles = new Set(["subrip", "ass", "ssa", "webvtt", "mov_text", "text"]);
const languageMap: Record<string, string> = { eng: "en", spa: "es", fra: "fr", fre: "fr", deu: "de", ger: "de", ita: "it", jpn: "ja", por: "pt", zho: "zh", chi: "zh", kor: "ko", rus: "ru" };
function language(stream: MediaStream) {
  const raw = (stream.tags?.language ?? "und").toLowerCase();
  return languageMap[raw] ?? (/^[a-z]{2,3}$/.test(raw) ? raw : "und");
}
function encrypted(stream: MediaStream) {
  return /^(encv|enca)$/.test(stream.codec_tag_string ?? "") ||
    stream.side_data_list?.some((s) => /encrypt|drm/i.test(s.side_data_type ?? "")) ||
    Object.keys(stream.tags ?? {}).some((key) => /^(encryption|enc_key|drm|key_id)/i.test(key));
}
export function inspectMkv(probe: MediaProbe) {
  if (!probe.format.format_name.split(",").some((v) => v === "matroska" || v === "webm") || probe.streams.some(encrypted)) throw new PreparationError("Only clear, authorized Matroska inputs are supported. DRM keys are never accepted.");
  const video = probe.streams.find((s) => s.codec_type === "video" && !s.disposition?.attached_pic);
  const duration = Number(probe.format.duration), start = Number(probe.format.start_time ?? "0");
  if (!video || !video.width || !video.height || !Number.isFinite(duration) || duration <= 0 || !Number.isFinite(start)) throw new PreparationError("Source has no usable video timeline.");
  if (probe.streams.filter((s) => s.codec_type === "audio").length > 32 || probe.streams.filter((s) => s.codec_type === "subtitle").length > 64) throw new PreparationError("Source exceeds preparation track limits.");
  return { video, duration, start, hdr: ["smpte2084", "arib-std-b67"].includes(video.color_transfer ?? ""),
    audio: probe.streams.filter((s) => s.codec_type === "audio"), subtitles: probe.streams.filter((s) => s.codec_type === "subtitle") };
}
export async function probeFile(file: string): Promise<MediaProbe> {
  try {
    const { stdout } = await execute("ffprobe", ["-v", "error", "-protocol_whitelist", "file,pipe", "-show_streams", "-show_format", "-of", "json", file], { timeout: 30_000, maxBuffer: 8 * 1024 * 1024 });
    return JSON.parse(stdout) as MediaProbe;
  } catch { throw new PreparationError("Media inspection failed. Check the local file and FFprobe installation; input details are not logged."); }
}
function codec(stream: MediaStream) {
  if (stream.codec_name === "hevc") return `hvc1.${stream.profile?.includes("10") ? "2" : "1"}.6.L${stream.level ?? 153}.B0`;
  if (stream.codec_name === "h264") {
    const profile = ({ Baseline: 66, "Constrained Baseline": 66, Main: 77, High: 100, "High 10": 110 } as Record<string, number>)[stream.profile ?? ""] ?? 100;
    return `avc1.${profile.toString(16).padStart(2, "0")}00${(stream.level ?? 51).toString(16).padStart(2, "0")}`;
  }
  return ({ aac: stream.profile?.includes("HE") ? (stream.profile.includes("v2") ? "mp4a.40.29" : "mp4a.40.5") : "mp4a.40.2", mp3: "mp4a.69", ac3: "ac-3", eac3: "ec-3", alac: "alac", opus: "opus" } as Record<string, string>)[stream.codec_name] ?? "";
}

/** Offline operator job only. Inputs are local authorized MKVs, never private URLs or provider credentials. */
export async function prepareMkv(options: PrepareOptions): Promise<AuthorizedVideo> {
  if (!options.authorized) throw new PreparationError("Explicit authorization to deliver this media through Discord is required.");
  if (!/^[a-zA-Z0-9_-]{1,80}$/.test(options.slug) || !["ultrafast", "fast", "medium", "slow"].includes(options.preset ?? "medium")) throw new PreparationError("Invalid preparation options.");
  let input: string;
  try {
    if (/^[a-z]+:\/\//i.test(options.input) || !options.input.toLowerCase().endsWith(".mkv")) throw new PreparationError();
    input = await realpath(options.input);
    if (!(await stat(input)).isFile()) throw new PreparationError();
  } catch { throw new PreparationError("A local authorized MKV file is required. Network links and credentials are not accepted."); }
  const plan = inspectMkv(await probeFile(input));
  const prefix = `/media/${options.slug}`;
  const dummy = { mediaId: options.mediaId, sourceIdentifier: options.slug, season: options.season ?? null, episode: options.episode ?? null,
    browserPath: `${prefix}/audio-0-copy.mp4`, mimeType: "video/mp4", allowedDiscordUserIds: options.userIds };
  parseCatalog([dummy]); // Validate public identity/ACL before producing any deliverable.
  const root = await realpath(options.outputRoot);
  const destination = join(root, options.slug);
  try { await stat(destination); throw new PreparationError("Output already exists. Use a new versioned slug."); }
  catch (error) { if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error; }
  const staging = await mkdtemp(join(root, ".mkv-preparing-"));
  const timeout = Math.min(86400, Math.max(60, options.timeoutSeconds ?? 21600)) * 1000;
  const run = async (args: string[]) => {
    try { await execute("ffmpeg", ["-nostdin", "-hide_banner", "-loglevel", "error", "-y", ...args], { timeout, killSignal: "SIGKILL", maxBuffer: 1024 * 1024 }); }
    catch { throw new PreparationError("Media preparation failed. Check FFmpeg codec/filter support and disk space. Private paths and process output are not logged."); }
  };
  const originalInput = ["-protocol_whitelist", "file,pipe", "-i", input];
  const normalized = ["-copyts", "-start_at_zero", ...originalInput];
  const outputFlags = ["-map_metadata", "-1", "-avoid_negative_ts", "disabled", "-movflags", "+faststart"];
  const renditions: VideoRendition[] = [], subtitles: PreparedSubtitle[] = [], notices: string[] = [];
  try {
    let fallback: string | undefined;
    if (options.transcode !== false && (!plan.hdr || options.allowSDRFallback)) {
      fallback = join(staging, ".compat-video.mp4");
      const filters = plan.hdr ? "zscale=t=linear:npl=100,format=gbrpf32le,tonemap=tonemap=hable:desat=0,zscale=p=bt709:t=bt709:m=bt709:r=tv,format=yuv420p" : "format=yuv420p";
      await run([...normalized, "-map", `0:${plan.video.index}`, "-an", "-sn", "-c:v", "libx264", "-preset", options.preset ?? "medium", "-crf", "18", "-threads", "2", "-vf", `${filters},pad=ceil(iw/2)*2:ceil(ih/2)*2`, "-fps_mode", "passthrough", ...(plan.hdr ? ["-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709"] : []), ...outputFlags, fallback]);
      notices.push(plan.hdr ? "Compatibility video is lossy 4K-capable SDR tone-mapping; original HDR video is retained in copy renditions where supported." : "Compatibility video is a lossy H.264 encode at the source resolution; it is not a lossless remux.");
    } else if (plan.hdr) notices.push("HDR transcoding was not performed. Explicit SDR tone-mapping approval is required for a compatibility encode; copied HDR/Dolby Vision device support is not guaranteed.");
    const audios: (MediaStream | undefined)[] = plan.audio.length ? plan.audio : [undefined];
    for (let n = 0; n < audios.length; n++) {
      const audio = audios[n], audioId = `audio-${n}`;
      const lang = audio ? language(audio) : "und";
      const label = audio ? `${lang} · ${audio.disposition?.comment ? "commentary" : audio.disposition?.visual_impaired ? "audio description" : "main"} · track ${n + 1}` : "No audio";
      const add = async (mode: VideoRendition["mode"], copyAudio: boolean) => {
        const id = `${audioId}-${mode}`, filename = `${id}.mp4`, path = join(staging, filename);
        let inputs: string[], videoMap: string;
        if (mode === "video-transcode") {
          if (!fallback) return;
          inputs = ["-copyts", "-itsoffset", String(-plan.start), ...originalInput, "-protocol_whitelist", "file,pipe", "-i", fallback]; videoMap = "1:v:0";
        } else { inputs = normalized; videoMap = `0:${plan.video.index}`; }
        await run([...inputs, "-map", videoMap, ...(audio ? ["-map", `0:${audio.index}`] : ["-an"]), "-sn", "-c:v", "copy",
          ...(plan.video.codec_name === "hevc" && mode !== "video-transcode" ? ["-tag:v", "hvc1"] : []),
          ...(audio ? copyAudio ? ["-c:a", "copy"] : ["-c:a", "aac", "-profile:a", "aac_low", "-ac", "2", "-b:a", "192k"] : []), ...outputFlags, path]);
        const verified = await probeFile(path);
        const v = verified.streams.find((s) => s.codec_type === "video")!;
        const a = verified.streams.find((s) => s.codec_type === "audio");
        if (Math.abs(Number(verified.format.duration) - plan.duration) > 1 || Math.abs(v.width! - plan.video.width!) > 1 || Math.abs(v.height! - plan.video.height!) > 1) throw new PreparationError("Prepared media changed the source dimensions or timeline unexpectedly. Nothing was published.");
        renditions.push({ id, audioId, audioLabel: label, language: lang, browserPath: `${prefix}/${filename}`, mimeType: "video/mp4", videoCodec: codec(v), audioCodec: a ? codec(a) : "", mode, width: v.width!, height: v.height! });
      };
      if (videoCopy.has(plan.video.codec_name)) {
        if (!audio || audioCopy.has(audio.codec_name)) {
          try { await add("stream-copy", true); }
          catch (error) {
            if (!fallback) throw error;
            await rm(join(staging, `${audioId}-stream-copy.mp4`), { force: true });
            notices.push(`Audio track ${n + 1}: original-codec MP4 muxing failed; a compatibility encode is available.`);
          }
        }
        if (audio && (audio.codec_name !== "aac" || (audio.channels ?? 2) > 2 || (audio.profile !== undefined && audio.profile !== "LC"))) await add("audio-conversion", false);
      }
      if (fallback) await add("video-transcode", false);
    }
    if (!renditions.length) throw new PreparationError("No compatible output was produced. Enable a permitted transcoding fallback or choose another authorized source.");
    if (plan.subtitles.length) {
      await run([...normalized, "-map", "0:s", "-map", "0:t?", "-c", "copy", "-map_metadata", "-1", "-f", "matroska", join(staging, "subtitles-original.mks")]);
    }
    for (let n = 0; n < plan.subtitles.length; n++) {
      const s = plan.subtitles[n]!, id = `subtitle-${n}`;
      let browserPath: string | null = null;
      if (textSubtitles.has(s.codec_name)) {
        const filename = `${id}.vtt`;
        await run([...normalized, "-map", `0:${s.index}`, "-vn", "-an", "-c:s", "webvtt", "-map_metadata", "-1", join(staging, filename)]);
        browserPath = `${prefix}/${filename}`;
      } else notices.push(`Subtitle track ${n + 1} is not browser-renderable; its original data is retained in the subtitle archive. Provide authorized WebVTT to display it.`);
      subtitles.push({ id, label: `${language(s)} · ${s.codec_name}${browserPath ? "" : " · requires WebVTT"}`, language: language(s), browserPath, default: !!s.disposition?.default, forced: !!s.disposition?.forced });
    }
    if (plan.subtitles.some((s) => ["ass", "ssa"].includes(s.codec_name))) notices.push("WebVTT preserves subtitle text/timing, not all ASS styling. Original subtitles/fonts are retained in the archive.");
    const first = renditions[0]!;
    const entry = parseCatalog([{ ...dummy, browserPath: first.browserPath, renditions, subtitles, notices }])[0]!;
    await writeFile(join(staging, "catalog-entry.json"), JSON.stringify(entry, null, 2));
    await writeFile(join(staging, "preparation-report.json"), JSON.stringify({ duration: plan.duration, width: plan.video.width, height: plan.video.height, sourceCodec: plan.video.codec_name, hdr: plan.hdr, audioTracks: plan.audio.length, subtitleTracks: plan.subtitles.length, notices }, null, 2));
    if (fallback) await rm(fallback);
    await rename(staging, destination);
    return entry;
  } catch (error) { await rm(staging, { recursive: true, force: true }); throw error; }
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const args = process.argv.slice(2), value = (key: string) => args[args.indexOf(key) + 1];
  try {
    if (!["--input", "--output-root", "--slug", "--media-id", "--users"].every((key) => args.includes(key))) throw new PreparationError("Required: --input LOCAL.mkv --output-root DIRECTORY --slug NAME --media-id ID --users DISCORD_IDS --authorized-for-discord");
    await prepareMkv({ input: value("--input")!, outputRoot: value("--output-root")!, slug: value("--slug")!, mediaId: value("--media-id")!, userIds: value("--users")!.split(","), authorized: args.includes("--authorized-for-discord"), transcode: !args.includes("--no-transcode"), allowSDRFallback: args.includes("--allow-sdr-fallback"), preset: args.includes("--preset") ? value("--preset") : "medium", season: args.includes("--season") ? Number(value("--season")) : null, episode: args.includes("--episode") ? Number(value("--episode")) : null });
    console.info("Prepared authorized media. Merge catalog-entry.json into the server catalog and publish only the approved media assets.");
  } catch (error) { console.error(error instanceof PreparationError ? error.message : "Preparation failed. Check local paths, options, permissions and available disk space; private details are not logged."); process.exitCode = 1; }
}
