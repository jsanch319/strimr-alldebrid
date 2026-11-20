import type { WatchRoom } from "./shared.js";

export function positionAt(room: WatchRoom, now: number) {
  const elapsed = room.isPlaying ? Math.max(0, (now - room.updatedAt) / 1000) : 0;
  return Math.min(room.currentPosition + elapsed, room.media.duration || Number.MAX_SAFE_INTEGER);
}

export interface VideoPort {
  currentTime: number;
  readonly readyState: number;
  readonly paused: boolean;
  readonly seekable: { length: number; start(i: number): number; end(i: number): number };
  pause(): void;
  play(): Promise<void>;
}

/** Applies room state only; it never publishes media events back into the room. */
export class VideoSync {
  blocked = false;
  private playing = false;
  private restored = false;
  constructor(private readonly video: VideoPort) {}
  enable() { this.blocked = false; }
  async apply(room: WatchRoom, now: number): Promise<"ready" | "waiting" | "tap"> {
    const target = positionAt(room, now);
    if (this.video.readyState < 1) return "waiting";
    if (Math.abs(this.video.currentTime - target) > (!this.restored || !room.isPlaying ? 0.05 : 1.5)) {
      let seekable = false;
      for (let i = 0; i < this.video.seekable.length; i++) {
        if (target >= this.video.seekable.start(i) && target <= this.video.seekable.end(i)) seekable = true;
      }
      if (!seekable) { this.video.pause(); return "waiting"; }
      this.video.currentTime = target;
    }
    this.restored = true;
    if (!room.isPlaying || (room.media.duration > 0 && target >= room.media.duration - 0.05)) this.video.pause();
    else if (this.video.paused && !this.playing && !this.blocked) {
      this.playing = true;
      try { await this.video.play(); }
      catch { this.blocked = true; }
      finally { this.playing = false; }
    }
    return this.blocked ? "tap" : "ready";
  }
}
