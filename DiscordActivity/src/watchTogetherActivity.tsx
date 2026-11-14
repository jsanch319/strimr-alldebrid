import React from "react";
import type { ControlMode, InitialPlaybackState, RoomCommand, WatchRoom } from "./shared.js";

export interface ActivitySession {
  token: string;
  user: { id: string; username: string };
  sessionId: string;
  media: WatchRoom["media"];
  initialPlayback: InitialPlaybackState;
  openInvite: () => Promise<void>;
}

export function WatchTogetherActivity({ session }: { session: ActivitySession }) {
  const [room, setRoom] = React.useState<WatchRoom | null>(null);
  const [connection, setConnection] = React.useState("Connecting");
  const [error, setError] = React.useState("");
  const [position, setPosition] = React.useState(0);
  const [inviteError, setInviteError] = React.useState("");
  const socketRef = React.useRef<WebSocket | null>(null);
  const reconnectDelay = React.useRef(500);
  const serverClockOffset = React.useRef(0);
  const canControl = room?.participants.find(({ userId }) => userId === session.user.id)?.canControl ?? false;
  const isHost = room?.hostUserId === session.user.id;

  React.useEffect(() => {
    let stopped = false;
    let reconnect: ReturnType<typeof setTimeout> | undefined;
    function connect() {
      if (stopped) return;
      const protocol = location.protocol === "https:" ? "wss:" : "ws:";
      const socket = new WebSocket(`${protocol}//${location.host}/ws`);
      socketRef.current = socket;
      setConnection("Connecting");
      socket.addEventListener("open", () => {
        reconnectDelay.current = 500;
        socket.send(JSON.stringify({
          type: "join",
          token: session.token,
          sessionId: session.sessionId,
          media: session.media,
          initialPlayback: session.initialPlayback,
        }));
        setConnection("Connected");
      });
      socket.addEventListener("message", (event) => {
        const message = JSON.parse(String(event.data)) as {
          type: string;
          room?: WatchRoom;
          message?: string;
          serverTime?: number;
        };
        if (message.type === "room" && message.room) {
          if (typeof message.serverTime === "number") {
            serverClockOffset.current = message.serverTime - Date.now();
          }
          setRoom(message.room);
          setPosition(positionAt(message.room, serverClockOffset.current));
          setError("");
        } else if (message.type === "error") {
          setError(message.message ?? "The room request failed.");
        }
      });
      socket.addEventListener("close", () => {
        socketRef.current = null;
        if (stopped) return;
        setConnection("Reconnecting");
        reconnect = setTimeout(connect, reconnectDelay.current);
        reconnectDelay.current = Math.min(reconnectDelay.current * 2, 10_000);
      });
      socket.addEventListener("error", () => socket.close());
    }
    connect();
    return () => {
      stopped = true;
      if (reconnect) clearTimeout(reconnect);
      socketRef.current?.close();
      socketRef.current = null;
    };
  }, [session]);

  React.useEffect(() => {
    if (!room) return;
    const timer = setInterval(() => {
      const next = positionAt(room, serverClockOffset.current);
      setPosition((previous) => Math.abs(previous - next) > 0.4 ? next : previous);
    }, 1000);
    return () => clearInterval(timer);
  }, [room]);

  function send(command: RoomCommand) {
    const socket = socketRef.current;
    if (!socket || socket.readyState !== WebSocket.OPEN) {
      setError("Connection lost. Reconnecting to the room…");
      return;
    }
    socket.send(JSON.stringify({ command }));
    setError("");
  }

  async function invite() {
    setInviteError("");
    try {
      await session.openInvite();
    } catch (caught) {
      setInviteError(caught instanceof Error ? caught.message : "Discord could not open the invite dialog.");
    }
  }

  function updateMode(mode: ControlMode) {
    send({ type: "set-control-mode", mode });
  }

  function toggleApprovedUser(userId: string, approved: boolean) {
    if (!room) return;
    const approvedUserIds = new Set(room.approvedUserIds);
    if (approved) approvedUserIds.add(userId);
    else approvedUserIds.delete(userId);
    send({ type: "set-approved-users", userIds: [...approvedUserIds] });
  }

  function toggleSourceAccess(userId: string, allowed: boolean) {
    if (!room) return;
    const sourceChangeUserIds = new Set(room.sourceChangeUserIds);
    if (allowed) sourceChangeUserIds.add(userId);
    else sourceChangeUserIds.delete(userId);
    send({ type: "set-source-access", userIds: [...sourceChangeUserIds] });
  }

  const duration = room?.media.duration ?? 0;
  const maxPosition = duration || Math.max(position, 3600);

  return (
    <main className="activity-shell">
      <header className="topbar">
        <div className="brand"><span className="brand-mark small">S</span> Strimr <span>Watch Together</span></div>
        <div className={`connection ${connection.toLowerCase()}`}><i />{connection}</div>
      </header>

      <section className="watch-card">
        <div className="artwork" aria-label="Media artwork placeholder">
          <div className="artwork-symbol">▶</div>
          <span>STRIMR</span>
        </div>
        <div className="media-info">
          <p className="eyebrow">WATCH PARTY</p>
          <h1>{room?.media.title ?? "Joining room…"}</h1>
          {room?.media.mediaType === "episode" && (
            <p className="episode">
              {room.media.season === null ? "" : `Season ${room.media.season}`}
              {room.media.episode === null ? "" : ` · Episode ${room.media.episode}`}
            </p>
          )}
          <p className="room-status">{room?.isPlaying ? "Playing together" : "Paused"} · {connection}</p>
          <div className="timeline">
            <input
              aria-label="Playback position"
              type="range"
              min="0"
              max={maxPosition}
              step="1"
              value={Math.min(position, maxPosition)}
              disabled={!canControl}
              onChange={(event) => setPosition(Number(event.currentTarget.value))}
              onPointerUp={() => send({ type: "seek", position })}
              onKeyUp={(event) => {
                if (event.key.startsWith("Arrow")) send({ type: "seek", position });
              }}
            />
            <div className="timecodes"><span>{formatTime(position)}</span><span>{formatTime(duration)}</span></div>
          </div>
          <div className="transport">
            <button className="secondary-button" disabled={!canControl} onClick={() => send({ type: "skip", seconds: -15 })}>
              −15
            </button>
            <button
              className="play-button"
              aria-label={room?.isPlaying ? "Pause for everyone" : "Play for everyone"}
              disabled={!canControl}
              onClick={() => send({ type: room?.isPlaying ? "pause" : "play" })}
            >
              {room?.isPlaying ? "Ⅱ" : "▶"}
            </button>
            <button className="secondary-button" disabled={!canControl} onClick={() => send({ type: "skip", seconds: 15 })}>
              +15
            </button>
            <button className="invite-button" onClick={() => void invite()}>Invite</button>
          </div>
          <p className="sync-note">Playback position syncs here. Each participant resolves playback in their own Strimr app.</p>
        </div>
      </section>

      <section className="participants-card">
        <div className="section-heading">
          <div><h2>Participants</h2><p>{room?.participants.length ?? 0} in this room</p></div>
          {isHost && (
            <label className="toggle-control">
              <input
                type="checkbox"
                checked={room?.controlMode === "everyone"}
                onChange={(event) => updateMode(event.currentTarget.checked ? "everyone" : "host-only")}
              />
              <span className="switch" />
              <span>Let others control playback</span>
            </label>
          )}
        </div>

        {isHost && (
          <div className="permission-settings">
            <label htmlFor="control-mode">Playback control</label>
            <select
              id="control-mode"
              value={room?.controlMode ?? "host-only"}
              onChange={(event) => updateMode(event.currentTarget.value as ControlMode)}
            >
              <option value="host-only">Host Only</option>
              <option value="everyone">Everyone</option>
              <option value="approved">Approved Users</option>
            </select>
          </div>
        )}

        <ul className="participant-list">
          {room?.participants.map((participant) => (
            <li key={participant.userId}>
              <div className="avatar">{participant.username.slice(0, 1).toUpperCase()}</div>
              <span className="participant-name">{participant.username}</span>
              {participant.host && <span className="badge host-badge">Host</span>}
              <span className={`badge ${participant.canControl ? "control-badge" : "muted-badge"}`}>
                {participant.canControl ? "Can control" : "View only"}
              </span>
              {isHost && room?.controlMode === "approved" && !participant.host && (
                <label className="permission-check">
                  <input
                    type="checkbox"
                    checked={room.approvedUserIds.includes(participant.userId)}
                    onChange={(event) => toggleApprovedUser(participant.userId, event.currentTarget.checked)}
                  />
                  Playback
                </label>
              )}
              {isHost && !participant.host && (
                <label className="permission-check source-permission">
                  <input
                    type="checkbox"
                    checked={room?.sourceChangeUserIds.includes(participant.userId) ?? false}
                    onChange={(event) => toggleSourceAccess(participant.userId, event.currentTarget.checked)}
                  />
                  Sources
                </label>
              )}
            </li>
          ))}
          {!room && <li className="muted">Waiting for the room session…</li>}
        </ul>

        <p className="permission-note">
          Source changes are host-only unless explicitly granted. Playback sources and private URLs are never shared in this room.
        </p>
      </section>
      {(error || inviteError) && <p role="alert" className="error-message">{error || inviteError}</p>}
    </main>
  );
}

function positionAt(room: WatchRoom, serverClockOffset: number): number {
  const elapsed = room.isPlaying
    ? Math.max(0, (Date.now() + serverClockOffset - room.updatedAt) / 1000)
    : 0;
  return Math.min(room.currentPosition + elapsed, room.media.duration || Number.MAX_SAFE_INTEGER);
}

function formatTime(seconds: number): string {
  const value = Math.max(0, Math.floor(seconds));
  const hours = Math.floor(value / 3600);
  const minutes = Math.floor((value % 3600) / 60);
  const remainder = value % 60;
  return hours > 0
    ? `${hours}:${String(minutes).padStart(2, "0")}:${String(remainder).padStart(2, "0")}`
    : `${minutes}:${String(remainder).padStart(2, "0")}`;
}
