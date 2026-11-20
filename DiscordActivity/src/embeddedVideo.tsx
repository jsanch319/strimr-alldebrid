import React from "react";
import type Hls from "hls.js";
import type { WatchRoom } from "./shared.js";
import { VideoSync } from "./videoSync.js";
import { resolveBrowserVideo } from "./sourceResolver.js";

export function EmbeddedVideo({ room, token, native, clockOffset, connected }: {
  room: WatchRoom | null; token: string; native: boolean; clockOffset: number; connected: boolean;
}) {
  const video = React.useRef<HTMLVideoElement>(null);
  const sync = React.useRef<VideoSync | null>(null);
  const latest = React.useRef({ room, clockOffset, connected });
  latest.current = { room, clockOffset, connected };
  const [status, setStatus] = React.useState("Loading authorized video…");
  const [error, setError] = React.useState("");
  const [tap, setTap] = React.useState(false);
  const [muted, setMuted] = React.useState(false);
  const [retry, setRetry] = React.useState(0);
  React.useEffect(() => {
    const element = video.current;
    if (!element || !room || !room.media.mediaId || native) return;
    let active = true;
    let failed = false;
    const abort = new AbortController();
    let hls: Hls | undefined;
    const controller = new VideoSync(element);
    sync.current = controller;
    const started = Date.now();
    setError(""); setStatus("Loading authorized video…"); setTap(false);
    const apply = () => {
      const current = latest.current;
      if (!current.room || !active || failed || element.error) return;
      if (!current.connected) { element.pause(); setStatus("Reconnecting to the room…"); return; }
      void controller.apply(current.room, Date.now() + current.clockOffset).then((state) => {
        if (active) {
          setTap(state === "tap"); setStatus(state === "waiting" ? "Waiting for video to become seekable…" : "");
          if (state === "waiting" && Date.now() - started > 30_000) setError("Video cannot yet restore the room position. Retry or ask for a seekable compatible source; playback has not restarted at zero.");
        }
      });
    };
    const fail = () => {
      failed = true; element.pause();
      if (active) setError("This source could not play in Discord. Check its codec, HTTPS mapping, byte-range/HLS support and authorization. No alternate content was opened.");
    };
    for (const event of ["loadedmetadata", "canplay", "progress", "seeked"]) element.addEventListener(event, apply);
    element.addEventListener("error", fail);
    const checkEdition = () => {
      const expected = latest.current.room?.media.duration ?? 0;
      if (expected > 0 && Number.isFinite(element.duration) && Math.abs(expected - element.duration) > Math.max(15, expected * 0.01)) {
        failed = true; element.pause(); setError("This source has a different duration/edition. Configure the same cut before synchronizing.");
      }
    };
    element.addEventListener("loadedmetadata", checkEdition);
    const timer = setInterval(apply, 750);
    void (async () => {
      try {
        const source = await resolveBrowserVideo(token, abort.signal);
        if (!active) return;
        if (source.mimeType === "application/vnd.apple.mpegurl" && !element.canPlayType("application/vnd.apple.mpegurl")) {
          const HlsPlayer = (await import("hls.js")).default;
          if (!active) return;
          if (!HlsPlayer.isSupported()) throw new Error("This Discord device cannot play the configured HLS stream. Configure a compatible MP4 source.");
          hls = new HlsPlayer({ maxBufferLength: 30 });
          hls.on(HlsPlayer.Events.ERROR, (_event, data) => { if (data.fatal) { hls?.destroy(); fail(); } });
          hls.loadSource(source.browserPath); hls.attachMedia(element);
        } else if (source.mimeType === "video/mp4" || source.mimeType === "application/vnd.apple.mpegurl") {
          element.src = source.browserPath; element.load();
        } else throw new Error("Unsupported video type. Configure an authorized MP4 or clear HLS source.");
      } catch (caught) { if (active && !abort.signal.aborted) { failed = true; setError(caught instanceof Error ? caught.message : "Video unavailable."); } }
    })();
    return () => {
      active = false; abort.abort(); clearInterval(timer); hls?.destroy();
      for (const event of ["loadedmetadata", "canplay", "progress", "seeked"]) element.removeEventListener(event, apply);
      element.removeEventListener("error", fail); element.pause(); element.removeAttribute("src"); element.load(); sync.current = null;
      element.removeEventListener("loadedmetadata", checkEdition);
    };
  }, [room?.media.mediaId, room?.media.season, room?.media.episode, room?.media.selectedSourceIdentifier, token, native, retry]);
  if (native) return <div className="video-status">Your Strimr player handles playback. Other participants watch here in Discord.</div>;
  return <section className="embedded-video" aria-label="Synchronized video">
    <video ref={video} playsInline preload="metadata" muted={muted} controls={false} disablePictureInPicture disableRemotePlayback />
    {status && <p role="status">{status}</p>}
    {tap && <button onClick={() => { sync.current?.enable(); const state = latest.current; if (state.room) void sync.current?.apply(state.room, Date.now() + state.clockOffset); }}>Enable playback on this device</button>}
    <button aria-label={muted ? "Unmute this device" : "Mute this device"} onClick={() => setMuted(!muted)}>{muted ? "Unmute" : "Mute"}</button>
    {error && <p role="alert">{error} <button onClick={() => setRetry((n) => n + 1)}>Retry video</button></p>}
  </section>;
}
