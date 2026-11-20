import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { writeFile } from "node:fs/promises";
import { join } from "node:path";
const exec = promisify(execFile);
export async function makeMkv(directory: string, width = 320, height = 180, codec = "libx264", duration = 6, audioCodec = "aac") {
  const input = join(directory, "owned-fixture.mkv"), srt = join(directory, "captions.srt");
  const end = Math.min(duration - 0.1, 4.5);
  const endTime = `00:00:${String(Math.floor(end)).padStart(2, "0")},${String(Math.round((end % 1) * 1000)).padStart(3, "0")}`;
  await writeFile(srt, `1\n00:00:00,500 --> ${endTime}\nOwned test caption\n`);
  await exec("ffmpeg", ["-nostdin", "-v", "error", "-y", "-f", "lavfi", "-i", `color=c=blue:s=${width}x${height}:r=2:d=${duration}`,
    "-f", "lavfi", "-i", `sine=frequency=440:duration=${duration}`, "-f", "lavfi", "-i", `sine=frequency=880:duration=${duration}`,
    "-i", srt, "-map", "0:v", "-map", "1:a", "-map", "2:a", "-map", "3:s", "-c:v", codec,
    ...(codec === "libx264" ? ["-preset", "ultrafast", "-pix_fmt", "yuv420p"] : []), "-threads", "2",
    "-c:a", audioCodec, "-c:s", "srt", "-metadata:s:a:0", "language=eng", "-metadata:s:a:1", "language=spa",
    "-metadata:s:s:0", "language=eng", "-t", String(duration), input], { timeout: 60_000 });
  return input;
}

