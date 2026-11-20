import assert from "node:assert/strict";
import test from "node:test";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { createServer as createHTTPServer } from "node:http";
import { once } from "node:events";
import express from "express";
import { createServer as createViteServer } from "vite";
import puppeteer from "puppeteer-core";
import { makeMkv } from "../testSupport/mediaFixture.js";
import { prepareMkv } from "../tools/prepareMkv.js";
import { probeFile } from "../tools/prepareMkv.js";

test("actual Chromium decodes prepared MKV video with audio selection captions seek and resume", { timeout: 120_000 }, async (t) => {
  const directory = await mkdtemp(join(tmpdir(), "strimr-mkv-browser-"));
  let closeBrowser = async () => {}, closeHTTP = async () => {}, closeVite = async () => {};
  t.after(async () => {
    try { await closeBrowser(); await closeHTTP(); await closeVite(); }
    finally { await rm(directory, { recursive: true, force: true }); }
  });
  const input = await makeMkv(directory, 320, 180, "libx264", 8);
  const entry = await prepareMkv({ input, outputRoot: directory, slug: "browser", mediaId: "movie:42", userIds: ["111111111111111111"], authorized: true, preset: "ultrafast" });
  const duration = Number((await probeFile(input)).format.duration);
  // The inline harness is not an on-disk Vite entry. Prebundle its dependencies so a
  // cold CI cache cannot trigger a development-only page reload during playback.
  const vite = await createViteServer({ root: resolve("."), optimizeDeps: {
    include: ["react", "react-dom/client", "react/jsx-dev-runtime", "react/jsx-runtime", "hls.js"], noDiscovery: true,
  }, server: { middlewareMode: true }, appType: "custom" });
  closeVite = () => vite.close();
  const app = express();
  let resolutions = 0;
  app.post("/api/playback", (_request, response) => { resolutions++; response.json(entry); });
  app.use("/media", express.static(directory));
  app.get("/mkv-browser-test", async (_request, response) => {
    response.type("html").send(await vite.transformIndexHtml("/mkv-browser-test", `<!doctype html><html><body>
      <h1>Chromium component test — not Discord</h1><div id="root"></div><button id="group-play">Play room</button><button id="group-pause">Pause room</button><button id="group-seek">Seek room</button>
      <script type="module">
        import React from 'react';
        import '/src/style.css';
        import { createRoot } from 'react-dom/client';
        import { EmbeddedVideo } from '/src/embeddedVideo.tsx';
        let room = {revision:0, sessionId:'test', media:{mediaId:'movie:42',title:'Generated owned fixture',mediaType:'movie',season:null,episode:null,duration:${duration},selectedSourceIdentifier:null},currentPosition:1.25,isPlaying:false,updatedAt:Date.now(),participants:[],hostUserId:'test',controlMode:'host-only',approvedUserIds:[],sourceChangeUserIds:[]};
        const root = createRoot(document.getElementById('root'));
        const render=()=>root.render(React.createElement(EmbeddedVideo,{room,token:'fixture-only',native:false,clockOffset:0,connected:true}));render();
        document.getElementById('group-play').onclick=()=>{room={...room,revision:room.revision+1,isPlaying:true,updatedAt:Date.now()};render()};
        document.getElementById('group-pause').onclick=()=>{room={...room,revision:room.revision+1,currentPosition:document.querySelector('video').currentTime,isPlaying:false,updatedAt:Date.now()};render()};
        document.getElementById('group-seek').onclick=()=>{room={...room,revision:room.revision+1,currentPosition:3.125,isPlaying:false,updatedAt:Date.now()};render()};
      </script></body></html>`));
  });
  app.use(vite.middlewares);
  const server = createHTTPServer(app); server.listen(0, "127.0.0.1"); await once(server, "listening");
  closeHTTP = async () => { server.closeAllConnections(); await new Promise<void>((resolve) => server.close(() => resolve())); };
  const binary = process.env.STRIMR_CHROMIUM_PATH ?? ["/usr/bin/chromium", "/usr/bin/google-chrome"].find(existsSync);
  assert.ok(binary, "Set STRIMR_CHROMIUM_PATH to an installed Chromium/Chrome binary; browser tests are not skipped.");
  // Test-only sandbox flag for isolated Linux CI. No production player or iOS security setting changes.
  const browser = await puppeteer.launch({ executablePath: binary, headless: true, args: ["--no-sandbox", "--disable-dev-shm-usage"], userDataDir: join(directory, "chrome-profile") });
  closeBrowser = () => browser.close();
  const page = await browser.newPage();
  const errors: string[] = [];
  page.on("pageerror", (error) => errors.push(String(error)));
  await page.setViewport({ width: 390, height: 844 });
  await page.goto(`http://127.0.0.1:${(server.address() as { port: number }).port}/mkv-browser-test`);
  await page.waitForFunction(() => { const video = document.querySelector("video"); return video && video.readyState >= 2 && Math.abs(video.currentTime - 1.25) < 0.2; }, { timeout: 30_000 });
  await page.select('select[aria-label="Subtitle track"]', "subtitle-0");
  await page.waitForFunction(() => { const t = document.querySelector("video")!.textTracks[0]; return t?.mode === "showing" && t.activeCues?.length === 1; });
  // A simulated decoder failure checks bounded fallback without changing the room clock.
  await page.$eval("video", (el) => el.dispatchEvent(new Event("error")));
  await page.waitForFunction(() => document.querySelector("video")!.currentSrc.includes("video-transcode") && Math.abs(document.querySelector("video")!.currentTime - 1.25) < 0.2);
  await page.select('select[aria-label="Audio track"]', "audio-1");
  await page.waitForFunction(() => document.querySelector("video")!.currentSrc.includes("audio-1") && Math.abs(document.querySelector("video")!.currentTime - 1.25) < 0.2);
  await page.select('select[aria-label="Video compatibility"]', "compatible");
  await page.waitForFunction(() => document.querySelector("video")!.currentSrc.includes("video-transcode") && Math.abs(document.querySelector("video")!.currentTime - 1.25) < 0.2);
  assert.equal(await page.$eval('select[aria-label="Subtitle track"]', (el) => (el as HTMLSelectElement).value), "subtitle-0");
  await page.click("#group-play");
  const enable = await page.waitForSelector('::-p-text(Enable playback on this device)', { timeout: 1500 }).catch(() => null);
  if (enable) await enable.click();
  await page.waitForFunction(() => document.querySelector("video")!.currentTime > 1.7 && !document.querySelector("video")!.paused, { timeout: 15_000 });
  await page.click("#group-pause");
  await page.waitForFunction(() => document.querySelector("video")!.paused);
  await page.click("#group-seek");
  await page.waitForFunction(() => Math.abs(document.querySelector("video")!.currentTime - 3.125) < 0.2 && document.querySelector("video")!.paused);
  await page.waitForFunction(() => document.querySelector("video")!.textTracks[0]?.mode === "showing" && document.querySelector("video")!.textTracks[0]?.activeCues?.length === 1);
  assert.equal(resolutions, 1, "Audio/quality fallback reuses validated metadata without resolving the source again");
  assert.deepEqual(errors, []);
  if (process.env.STRIMR_BROWSER_ARTIFACTS) {
    await mkdir(process.env.STRIMR_BROWSER_ARTIFACTS, { recursive: true });
    await writeFile(join(process.env.STRIMR_BROWSER_ARTIFACTS, "mkv-browser-result.json"), JSON.stringify({ environment: "Chromium component harness, not Discord", initialResume: 1.25, seek: 3.125, audio: "audio-1", subtitles: "subtitle-0", quality: "video-transcode", passed: true }, null, 2));
    await page.screenshot({ path: join(process.env.STRIMR_BROWSER_ARTIFACTS, "mkv-browser-component.png"), fullPage: true });
  }
});
