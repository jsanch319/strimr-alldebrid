import React from "react";
import ReactDOM from "react-dom/client";
import { DiscordSDK } from "@discord/embedded-app-sdk";
import type { InitialPlaybackState, SafeMediaMetadata } from "./shared.js";
import { optionalQueryInteger } from "./shared.js";
import { WatchTogetherActivity, type ActivitySession } from "./watchTogetherActivity.js";
import "./style.css";

const rootElement = document.getElementById("root");
if (!rootElement) throw new Error("Missing Activity root element.");

ReactDOM.createRoot(rootElement).render(
  <ActivityRoot />,
);

function ActivityRoot() {
  const [status, setStatus] = React.useState<{ message: string; error: boolean }>({
    message: "Connecting to Discord…",
    error: false,
  });
  const [session, setSession] = React.useState<ActivitySession | null>(null);

  React.useEffect(() => {
    let active = true;
    async function connect() {
      try {
        const configurationResponse = await fetch("/api/config");
        const configuration = await configurationResponse.json() as {
          clientId: string;
          configured: boolean;
          message: string | null;
        };
        const clientId = import.meta.env.VITE_DISCORD_CLIENT_ID || configuration.clientId;
        if (!configuration.configured || !clientId) {
          throw new Error(configuration.message ?? "Set the Discord application Client ID and Activity server configuration.");
        }
        if (configuration.clientId !== clientId) {
          throw new Error("The frontend and room server Discord application IDs do not match.");
        }

        const discord = new DiscordSDK(clientId);
        await discord.ready();
        const state = crypto.randomUUID();
        const authorization = await discord.commands.authorize({
          client_id: clientId,
          response_type: "code",
          state,
          prompt: "none",
          scope: ["identify"],
        });
        if (!authorization.code) throw new Error("Discord did not authorize this Activity.");

        const authenticationResponse = await fetch("/api/auth", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ code: authorization.code, instanceId: discord.instanceId }),
        });
        const authentication = await authenticationResponse.json() as {
          token?: string;
          user?: { id: string; username: string };
          error?: string;
          access_token?: string;
        };
        if (!authenticationResponse.ok || !authentication.token || !authentication.user || !authentication.access_token) {
          throw new Error(authentication.error ?? "Discord authentication failed.");
        }
        const authenticated = await discord.commands.authenticate({ access_token: authentication.access_token });
        if (authenticated.user.id !== authentication.user.id) throw new Error("Discord identities did not match.");
        if (!active) return;
        setSession({
          token: authentication.token,
          user: authentication.user,
          sessionId: discord.instanceId,
          media: mediaFromURL(),
          initialPlayback: initialPlaybackFromURL(),
          openInvite: async () => {
            await discord.commands.openInviteDialog();
          },
        });
        setStatus({ message: "", error: false });
        try {
          await discord.commands.getActivityInstanceConnectedParticipants();
        } catch {
          // Server-side Activity Instance verification remains authoritative.
        }
      } catch (error) {
        if (active) {
          setStatus({
            message: error instanceof Error ? error.message : "Discord Activity setup failed.",
            error: true,
          });
        }
      }
    }

    void connect();
    return () => {
      active = false;
    };
  }, []);

  if (!session) {
    return (
      <main className="setup-state" role="status">
        <div className="brand-mark">S</div>
        <h1>Strimr Watch Together</h1>
        <p className={status.error ? "error-message" : "muted"}>{status.message}</p>
        {status.error && <p className="muted">Open this Activity inside Discord after configuration.</p>}
      </main>
    );
  }
  return <WatchTogetherActivity session={session} />;
}

function initialPlaybackFromURL(): InitialPlaybackState {
  const query = new URLSearchParams(location.search);
  const position = Number(query.get("position"));
  const duration = Number(query.get("duration"));
  const safeDuration = Number.isFinite(duration) && duration > 0 ? duration : Number.MAX_SAFE_INTEGER;
  return {
    position: Number.isFinite(position) ? Math.min(Math.max(0, position), safeDuration) : 0,
    isPlaying: query.get("is_playing") === "1",
  };
}

function mediaFromURL(): SafeMediaMetadata {
  const query = new URLSearchParams(location.search);
  const positiveInteger = (key: string) => optionalQueryInteger(query, key);
  const type = query.get("media_type");
  return {
    mediaId: query.get("media_id")?.slice(0, 180) ?? "",
    title: query.get("title")?.slice(0, 180) || "Choose a title in Strimr",
    mediaType: (type === "show" || type === "episode" ? type : "movie") as SafeMediaMetadata["mediaType"],
    season: positiveInteger("season"),
    episode: positiveInteger("episode"),
    duration: Math.min(Math.max(0, Number(query.get("duration")) || 0), 7 * 24 * 3600),
    selectedSourceIdentifier: query.get("source_id")?.slice(0, 180) || null,
  };
}
