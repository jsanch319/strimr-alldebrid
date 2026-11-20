import React from "react";
import type Hls from "hls.js";
import type { WatchRoom } from "./shared.js";
import { VideoSync } from "./videoSync.js";
import { resolveBrowserVideo } from "./sourceResolver.js";
import { selectRendition, type VideoRendition } from "./preparedMedia.js";

type Source = Awaited<ReturnType<typeof resolveBrowserVideo>>;
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
  const [audio, setAudio] = React.useState("");
  const [quality, setQuality] = React.useState<"auto" | "copy" | "compatible">("auto");
  const [subtitle, setSubtitle] = React.useState<string | null>(null);
  const [source, setSource] = React.useState<Source | null>(null);
  const [rendition, setRendition] = React.useState<VideoRendition | null>(null);
  const cache = React.useRef<{ key: string; source: Source } | null>(null);
  const attempted = React.useRef(new Set<string>());
  const mediaKey = JSON.stringify([room?.media.mediaId, room?.media.season, room?.media.episode, room?.media.selectedSourceIdentifier, token]);
  React.useEffect(() => {
    attempted.current.clear(); cache.current = null; setSource(null); setRendition(null);
    setAudio(""); setSubtitle(null); setQuality("auto");
  }, [mediaKey]);
  const selectedSubtitle = subtitle ?? source?.subtitles?.find((s) => s.browserPath && (s.forced || s.default))?.id ?? "";
  const applySubtitles = () => {
    const element = video.current;
    if (!element) return;
    for (let i = 0; i < element.textTracks.length; i++) {
      element.textTracks[i]!.mode = element.textTracks[i]!.id === selectedSubtitle ? "showing" : "disabled";
    }
  };
  React.useEffect(applySubtitles, [selectedSubtitle, source]);
  const subtitleSelection = React.useRef(applySubtitles);
  subtitleSelection.current = applySubtitles;

  React.useEffect(() => {
    const element = video.current;
    if (!element || !room || !room.media.mediaId || native) return;
    let active = true, failed = false;
    const abort = new AbortController();
    let hls: Hls | undefined, loaded: VideoRendition | undefined, metadata: Source | undefined;
    const controller = new VideoSync(element);
    sync.current = controller;
    const started = Date.now();
    setError(""); setStatus("Loading authorized video…"); setTap(false);
    const apply = () => {
      const current = latest.current;
      if (!current.room || !active || failed || element.error) return;
      if (!current.connected) { element.pause(); setStatus("Reconnecting to the room…"); return; }
      void controller.apply(current.room, Date.now() + current.clockOffset).then((state) => {
        if (!active) return;
        setTap(state === "tap"); setStatus(state === "waiting" ? "Waiting for video to become seekable…" : "");
        if (state === "waiting" && Date.now() - started > 30_000) setError("Video cannot yet restore the room position. Retry or choose a compatible rendition; playback has not restarted at zero.");
      });
    };
    const fail = () => {
      if (!active || failed) return;
      failed = true; element.pause();
      if (loaded) {
        attempted.current.add(loaded.id);
        const alternatives = metadata?.renditions?.filter((r) => r.audioId === loaded!.audioId && !attempted.current.has(r.id));
        if (quality === "auto" && alternatives?.length) { setStatus("Trying the next prepared compatible rendition…"); setRetry((n) => n + 1); return; }
      }
      setError("This rendition could not play on this device. Choose a prepared compatible rendition or ask the operator for one. The room position and private Strimr source are unchanged.");
    };
    for (const event of ["loadedmetadata", "canplay", "progress", "seeked"]) element.addEventListener(event, apply);
    element.addEventListener("error", fail);
    const checkEdition = () => {
      subtitleSelection.current();
      const expected = latest.current.room?.media.duration ?? 0;
      if (expected > 0 && Number.isFinite(element.duration) && Math.abs(expected - element.duration) > Math.max(15, expected * 0.01)) {
        failed = true; element.pause(); setError("This source has a different duration/edition. Configure the same cut before synchronizing.");
      }
    };
    element.addEventListener("loadedmetadata", checkEdition);
    const timer = setInterval(apply, 750);
    void (async () => {
      try {
        metadata = cache.current?.key === mediaKey ? cache.current.source : await resolveBrowserVideo(token, abort.signal);
        if (!active) return;
        cache.current = { key: mediaKey, source: metadata }; setSource(metadata);
        let browserPath = metadata.browserPath, mimeType = metadata.mimeType;
        if (metadata.renditions?.length) {
          const requestedAudio = metadata.renditions.some((r) => r.audioId === audio) ? audio : metadata.renditions[0]!.audioId;
          const candidates = metadata.renditions.filter((r) => !attempted.current.has(r.id) && (quality !== "copy" || r.mode !== "video-transcode"));
          loaded = selectRendition(candidates, requestedAudio, quality === "compatible", (mime) => element.canPlayType(mime));
          if (!loaded) throw new Error("No rendition is available for this audio/quality choice. Select Auto or prepare a compatible encode.");
          browserPath = loaded.browserPath; mimeType = loaded.mimeType; setRendition(loaded);
        } else setRendition(null);
        if (mimeType === "application/vnd.apple.mpegurl" && !element.canPlayType("application/vnd.apple.mpegurl")) {
          const HlsPlayer = (await import("hls.js")).default;
          if (!active) return;
          if (!HlsPlayer.isSupported()) throw new Error("This Discord device cannot play HLS. Configure an authorized compatible MP4 rendition.");
          hls = new HlsPlayer({ maxBufferLength: 30 });
          hls.on(HlsPlayer.Events.ERROR, (_event, data) => { if (data.fatal) { hls?.destroy(); fail(); } });
          hls.loadSource(browserPath); hls.attachMedia(element);
        } else { element.src = browserPath; element.load(); }
      } catch (caught) { if (active && !abort.signal.aborted) { failed = true; setError(caught instanceof Error ? caught.message : "Video unavailable."); } }
    })();
    return () => {
      active = false; abort.abort(); clearInterval(timer); hls?.destroy();
      for (const event of ["loadedmetadata", "canplay", "progress", "seeked"]) element.removeEventListener(event, apply);
      element.removeEventListener("loadedmetadata", checkEdition); element.removeEventListener("error", fail);
      element.pause(); element.removeAttribute("src"); element.load(); sync.current = null;
    };
  }, [mediaKey, native, audio, quality, retry]);

  if (native) return <div className="video-status">Your Strimr player handles playback. Other participants watch here in Discord.</div>;
  const audioChoices = [...new Map((source?.renditions ?? []).map((r) => [r.audioId, r.audioLabel])).entries()];
  return <section className="embedded-video" aria-label="Synchronized video">
    <video ref={video} playsInline preload="metadata" muted={muted} controls={false} disablePictureInPicture disableRemotePlayback crossOrigin="anonymous">
      {source?.subtitles?.filter((s) => s.browserPath).map((s) => <track key={s.id} id={s.id} kind="subtitles" src={s.browserPath!} srcLang={s.language} label={s.label} onLoad={() => subtitleSelection.current()} />)}
    </video>
    {!!audioChoices.length && <div className="video-track-options">
      <label>Audio <select aria-label="Audio track" value={audio || audioChoices[0]?.[0]} onChange={(e) => setAudio(e.currentTarget.value)}>{audioChoices.map(([id, label]) => <option key={id} value={id}>{label}</option>)}</select></label>
      <label>Quality <select aria-label="Video compatibility" value={quality} onChange={(e) => { attempted.current.clear(); setQuality(e.currentTarget.value as typeof quality); }}>
        <option value="auto">Auto · prefer stream copy</option><option value="copy">Copy video · no video re-encoding</option><option value="compatible">Compatible audio/video</option>
      </select></label>
    </div>}
    {!!source?.subtitles?.length && <label>Subtitles <select aria-label="Subtitle track" value={selectedSubtitle} onChange={(e) => setSubtitle(e.currentTarget.value)}>
      <option value="">Off</option>{source.subtitles.map((s) => <option key={s.id} value={s.id} disabled={!s.browserPath}>{s.label}</option>)}
    </select></label>}
    {rendition && <p className="rendition-status">{rendition.width} × {rendition.height} · {rendition.mode === "stream-copy" ? "Original video/audio · stream copy" : rendition.mode === "audio-conversion" ? "Original video · audio converted to AAC stereo" : "Compatibility encode · video re-encoded (lossy)"}</p>}
    {source?.notices?.map((notice, i) => <p key={i} className="conversion-notice">{notice}</p>)}
    {status && <p role="status">{status}</p>}
    {tap && <button onClick={() => { sync.current?.enable(); const state = latest.current; if (state.room) void sync.current?.apply(state.room, Date.now() + state.clockOffset); }}>Enable playback on this device</button>}
    <button aria-label={muted ? "Unmute this device" : "Mute this device"} onClick={() => setMuted(!muted)}>{muted ? "Unmute" : "Mute"}</button>
    {error && <p role="alert">{error} <button onClick={() => { attempted.current.clear(); setRetry((n) => n + 1); }}>Retry video</button></p>}
  </section>;
}
