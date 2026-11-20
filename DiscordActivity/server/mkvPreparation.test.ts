import assert from "node:assert/strict";
import test from "node:test";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { inspectMkv, prepareMkv, probeFile, type MediaProbe } from "../tools/prepareMkv.js";
import { parsePreparedMedia, selectRendition } from "../src/preparedMedia.js";
import { authorizedVideo, parseCatalog } from "./playbackCatalog.js";
import { defaultMedia } from "../src/shared.js";
const exec = promisify(execFile);
const user = "111111111111111111";
import { makeMkv } from "../testSupport/mediaFixture.js";

test("4K MKV video is remuxed without re-encoding; audio choices and captions remain mapped", async () => {
  const dir = await mkdtemp(join(tmpdir(), "strimr-mkv-4k-"));
  try {
    const input = await makeMkv(dir, 3840, 2160, "libx264", 2);
    const entry = await prepareMkv({ input, outputRoot: dir, slug: "owned-4k", mediaId: "movie:42", userIds: [user], authorized: true, transcode: false });
    assert.equal(entry.renditions!.length, 2);
    assert.deepEqual(new Set(entry.renditions!.map((r) => r.language)), new Set(["en", "es"]));
    const rendition = entry.renditions![0]!;
    assert.equal(rendition.mode, "stream-copy"); assert.equal(rendition.width, 3840); assert.equal(rendition.height, 2160);
    const output = join(dir, "owned-4k", rendition.browserPath.split("/").pop()!);
    const before = await exec("ffmpeg", ["-v", "error", "-i", input, "-map", "0:v:0", "-f", "framemd5", "-"], { maxBuffer: 1024 * 1024 });
    const after = await exec("ffmpeg", ["-v", "error", "-i", output, "-map", "0:v:0", "-f", "framemd5", "-"], { maxBuffer: 1024 * 1024 });
    const hashes = (s: string) => s.split("\n").filter((l) => l && !l.startsWith("#")).map((l) => l.split(",").pop()!.trim());
    assert.deepEqual(hashes(before.stdout), hashes(after.stdout));
    assert.equal(entry.subtitles![0]!.browserPath, "/media/owned-4k/subtitle-0.vtt");
    assert.match(await readFile(join(dir, "owned-4k", "subtitle-0.vtt"), "utf8"), /Owned test caption/);
    assert.ok((await readFile(join(dir, "owned-4k", "subtitles-original.mks"))).length > 0);
    assert.equal(JSON.stringify(entry).includes(input), false);
    assert.equal(JSON.stringify(entry).includes(dir), false);
    const api = authorizedVideo(parseCatalog([entry]), { ...defaultMedia, mediaId: "movie:42" }, user);
    assert.equal(api.renditions!.length, 2);
    assert.throws(() => authorizedVideo([entry], { ...defaultMedia, mediaId: "movie:42" }, "222222222222222222"));
  } finally { await rm(dir, { recursive: true, force: true }); }
});

test("unsupported MKV video codec gets a labeled H264 fallback with the same timeline and resolution", async () => {
  const dir = await mkdtemp(join(tmpdir(), "strimr-mkv-transcode-"));
  try {
    const input = await makeMkv(dir, 320, 180, "ffv1");
    const source = await probeFile(input);
    const entry = await prepareMkv({ input, outputRoot: dir, slug: "compat", mediaId: "movie:43", userIds: [user], authorized: true, preset: "ultrafast" });
    assert.ok(entry.renditions!.every((r) => r.mode === "video-transcode"));
    const prepared = await probeFile(join(dir, "compat", entry.renditions![0]!.browserPath.split("/").pop()!));
    assert.equal(prepared.streams.find((s) => s.codec_type === "video")!.codec_name, "h264");
    assert.equal(entry.renditions![0]!.width, 320); assert.equal(entry.renditions![0]!.height, 180);
    assert.ok(Math.abs(Number(prepared.format.duration) - Number(source.format.duration)) < 0.2);
    assert.ok(entry.notices!.some((s) => s.includes("lossy")));
    assert.equal(selectRendition(entry.renditions!, "audio-1", true, () => "probably")!.language, "es");
  } finally { await rm(dir, { recursive: true, force: true }); }
});

test("preparation rejects network links, missing authorization, encrypted sources and private rendition URLs", async () => {
  const options = { input: "https://private.invalid/file.mkv?token=secret", outputRoot: "/tmp", slug: "safe", mediaId: "movie:42", userIds: [user], authorized: true };
  await assert.rejects(prepareMkv({ ...options, authorized: false }), /authorization/);
  await assert.rejects(prepareMkv(options), (e: Error) => !e.message.includes("private.invalid") && !e.message.includes("secret"));
  const probe: MediaProbe = { streams: [{ index: 0, codec_type: "video", codec_name: "h264", width: 3840, height: 2160, side_data_list: [{ side_data_type: "Encryption initialization data" }] }], format: { format_name: "matroska,webm", duration: "10" } };
  assert.throws(() => inspectMkv(probe), /DRM/);
  assert.throws(() => parsePreparedMedia({ subtitles: [{ id: "s", label: "en", language: "en", default: false, forced: false, browserPath: "https://private.invalid/sub?key=secret" }] }));
});

test("incompatible audio is converted separately while the video remains stream copied", async () => {
  const dir = await mkdtemp(join(tmpdir(), "strimr-mkv-audio-"));
  try {
    const input = await makeMkv(dir, 320, 180, "libx264", 6, "flac");
    const entry = await prepareMkv({ input, outputRoot: dir, slug: "aac", mediaId: "movie:44", userIds: [user], authorized: true, transcode: false });
    assert.equal(entry.renditions!.length, 2);
    assert.ok(entry.renditions!.every((r) => r.mode === "audio-conversion" && r.audioCodec === "mp4a.40.2"));
    const output = await probeFile(join(dir, "aac", entry.renditions![0]!.browserPath.split("/").pop()!));
    assert.equal(output.streams.find((s) => s.codec_type === "video")!.codec_name, "h264");
    assert.equal(output.streams.find((s) => s.codec_type === "audio")!.channels, 2);
    assert.equal(entry.subtitles!.length, 1);
  } finally { await rm(dir, { recursive: true, force: true }); }
});
