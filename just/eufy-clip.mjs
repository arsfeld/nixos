#!/usr/bin/env node
// Pull recorded clips off the HomeBase's local storage.
//
// eufy's web portal and the cloud APIs only ever see cloud-backed events.
// Footage kept on the HomeBase is reachable only over P2P, through the station's
// own database, and `ha-eufy-sdk` (the integration this fleet runs) has no
// command for it — the SDK exposes live media and event thumbnails only. The one
// client that speaks the local protocol is bropat/eufy-security-ws, archived
// 2026-09-12 but still published as an image. This drives it.
//
// Runs on galactica: it needs LAN P2P reach to the stations and the sops
// secret. `just eufy::...` from raider copies this over and runs it there.
//
// eufy allows a single session per account, and the secondary account is held by
// eufy-sdk-bridge (hosts/galactica/services/eufy.nix), so `up` stops that bridge
// and `down` restarts it. Home Assistant's eufy entities are dead in between —
// keep the window short, or give this its own third account.
//
// Four things about the protocol are undocumented or documented wrongly, and
// each fails by returning nothing rather than by erroring usefully:
//
//   1. startDate/endDate are parsed as "YYYYMMDD" strings, not Dates or epoch
//      millis, and endDate is EXCLUSIVE. from == to returns zero rows, which
//      reads exactly like "nothing was recorded that day".
//   2. `serialNumbers` is required despite the docs marking it optional. Omit it
//      and the client throws "serialNumbers is not iterable", which reaches the
//      caller as a bare `unknown_error`.
//   3. FilterStorageType.NONE (0) filters to *no* storage rather than meaning
//      "unfiltered". LOCAL (1) is what you want here.
//   4. cipher_id 0 means "no per-account cipher", but the client only tests
//      `cipher_id !== undefined`, so passing the 0 through sends it down a
//      branch where getCipher(0) returns nothing and it dies on
//      Object.keys(undefined). The key has to be absent, not zero.
//
// And one thing about the hardware: see pickVia below.
//
// Usage:
//   eufy-clip up                      stop the bridge, start the ws server, log in
//   eufy-clip code <2fa>              submit an emailed 2FA code
//   eufy-clip captcha <id> <answer>   submit a captcha answer
//   eufy-clip stations                list stations and devices
//   eufy-clip list <YYYYMMDD> [<YYYYMMDD>] [--all]
//   eufy-clip grab <YYYYMMDD> [--device=NAME] [--from=HH:MM] [--to=HH:MM]
//                             [--out=DIR] [--dry-run] [--via=SERIAL]
//   eufy-clip get <record_id> <YYYYMMDD> [out.mp4]
//   eufy-clip down                    stop the ws server, restart the bridge

import { spawnSync } from "node:child_process";
import { writeFileSync, mkdtempSync, rmSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const WS_URL = "ws://127.0.0.1:3099"; // 3001 is forgejo
const SCHEMA = 21;
const CONTAINER = "eufy-clip-ws";
const IMAGE = "docker.io/bropat/eufy-security-ws:latest";
const DATA_DIR = "/var/data/eufy-clip-ws";
const BRIDGE_UNIT = "podman-eufy-sdk-bridge.service";
const SECRET = "/run/secrets/eufy-sdk-bridge-env";
const TZ = "America/Toronto";

const FilterStorageType = { NONE: 0, LOCAL: 1, CLOUD: 2 };
const FilterEventType = { ALL: 0, VIDEO: 1, ALERT: 2 };
const P2PStorageType = { 0: "none", 1: "emmc", 2: "hd", 3: "sdcard", 4: "sensor", 5: "alarm" };

const sh = (cmd, args, opts = {}) => {
  const r = spawnSync(cmd, args, { encoding: "utf8", ...opts });
  if (r.status !== 0 && !opts.allowFail) {
    throw new Error(`${cmd} ${args.join(" ")} failed (${r.status}): ${r.stderr || r.stdout}`);
  }
  return (r.stdout || "").trim();
};

const localStamp = (d) => d.toLocaleString("sv-SE", { timeZone: TZ });

// endDate is exclusive, so a caller's inclusive range needs the end pushed out.
const nextDay = (ymd) => {
  const d = new Date(`${ymd.slice(0, 4)}-${ymd.slice(4, 6)}-${ymd.slice(6, 8)}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + 1);
  return d.toISOString().slice(0, 10).replace(/-/g, "");
};

// ── ws client ────────────────────────────────────────────────────────────────

class Ws {
  constructor(url) {
    this.url = url;
    this.id = 0;
    this.pending = new Map();
    this.waiters = [];
  }

  async open() {
    this.ws = new WebSocket(this.url);
    await new Promise((res, rej) => {
      this.ws.onopen = res;
      this.ws.onerror = () => rej(new Error(`cannot reach the ws server at ${this.url}`));
    });
    this.ws.onmessage = (m) => this._onMessage(JSON.parse(m.data));
    await this.event((m) => m.type === "version", 10000); // the server greets first
    await this.cmd("set_api_schema", { schemaVersion: SCHEMA });
  }

  _onMessage(msg) {
    if (msg.type === "result" && this.pending.has(msg.messageId)) {
      const { res, rej } = this.pending.get(msg.messageId);
      this.pending.delete(msg.messageId);
      msg.success ? res(msg.result ?? {}) : rej(new Error(msg.errorCode || JSON.stringify(msg)));
    }
    for (const w of [...this.waiters]) {
      if (w.match(msg)) {
        this.waiters.splice(this.waiters.indexOf(w), 1);
        w.res(msg);
      }
    }
    if (msg.type === "event") this.onEvent?.(msg.event);
  }

  cmd(command, args = {}, timeoutMs = 30000) {
    const messageId = `m${++this.id}`;
    return new Promise((res, rej) => {
      this.pending.set(messageId, { res, rej });
      this.ws.send(JSON.stringify({ messageId, command, ...args }));
      setTimeout(() => {
        if (this.pending.delete(messageId)) rej(new Error(`${command}: timed out`));
      }, timeoutMs);
    });
  }

  // The database queries and the download answer asynchronously, as events,
  // never as the command result — so every one of them waits on this.
  event(match, timeoutMs = 120000) {
    return new Promise((res, rej) => {
      const w = { match, res };
      this.waiters.push(w);
      setTimeout(() => {
        if (this.waiters.includes(w)) {
          this.waiters.splice(this.waiters.indexOf(w), 1);
          rej(new Error("timed out waiting for an event"));
        }
      }, timeoutMs);
    });
  }

  close() { this.ws?.close(); }
}

const isEvent = (name, source) => (m) =>
  m.type === "event" && m.event?.event === name && (!source || m.event.source === source);

// ── container lifecycle ──────────────────────────────────────────────────────

const running = () =>
  sh("sudo", ["podman", "ps", "--format", "{{.Names}}"], { allowFail: true })
    .split("\n").includes(CONTAINER);

function up() {
  if (running()) { console.log("ws server already running"); return; }

  if (sh("systemctl", ["is-active", BRIDGE_UNIT], { allowFail: true }) === "active") {
    console.log(`stopping ${BRIDGE_UNIT} (eufy allows one session per account)`);
    sh("sudo", ["systemctl", "stop", BRIDGE_UNIT]);
  }

  // The bridge's own secondary-account credentials, under the names
  // eufy-security-ws expects.
  const env = Object.fromEntries(
    sh("sudo", ["cat", SECRET]).split("\n").filter(Boolean).map((l) => {
      const i = l.indexOf("=");
      return [l.slice(0, i), l.slice(i + 1).replace(/^["']|["']$/g, "")];
    })
  );

  sh("sudo", ["mkdir", "-p", DATA_DIR]);
  // Pass the credentials as inherited environment, never as argv: argv is
  // visible in the process table, in `podman inspect`, and in the text of any
  // error that echoes the failed command.
  sh("sudo", [
    "--preserve-env=USERNAME,PASSWORD",
    "podman", "run", "-d", "--rm", "--name", CONTAINER,
    "--publish", "127.0.0.1:3099:3000",
    "--volume", `${DATA_DIR}:/data`,   // persists the session, so no 2FA per run
    "--env", "USERNAME",
    "--env", "PASSWORD",
    "--env", "COUNTRY=CA",
    "--env", "TRUSTED_DEVICE_NAME=galactica-clip",
    IMAGE,
  ], { env: { ...process.env, USERNAME: env.EUFY_EMAIL, PASSWORD: env.EUFY_PASSWORD } });
  console.log("ws server started");
}

function down() {
  if (running()) sh("sudo", ["podman", "stop", CONTAINER], { allowFail: true });
  console.log(`restarting ${BRIDGE_UNIT}`);
  sh("sudo", ["systemctl", "start", BRIDGE_UNIT]);
  console.log("bridge back up — HA's eufy entities will recover shortly");
}

// ── connection + auth ────────────────────────────────────────────────────────

async function connect() {
  const ws = new Ws(WS_URL);
  for (let i = 0; i < 30; i++) {           // the server needs a moment after start
    try { await ws.open(); break; }
    catch (e) { if (i === 29) throw e; await new Promise((r) => setTimeout(r, 1000)); }
  }

  ws.onEvent = (e) => {
    if (e.event === "verify code")
      console.log("\n2FA REQUIRED — check the account's email, then: eufy-clip code <code>");
    if (e.event === "captcha request")
      console.log(`\nCAPTCHA REQUIRED — id ${e.captchaId}\n${e.captcha}`);
  };

  const { connected } = await ws.cmd("driver.is_connected").catch(() => ({ connected: false }));
  if (!connected) {
    await ws.cmd("driver.connect").catch((e) => console.log(`connect: ${e.message}`));
    await Promise.race([
      ws.event(isEvent("connected", "driver")),
      new Promise((r) => setTimeout(r, 12000)),
    ]).catch(() => {});
  }
  return ws;
}

// ── inventory + query ────────────────────────────────────────────────────────

// At schema 21 state.stations / state.devices are arrays of serial-number
// strings, not objects; names come from a per-serial properties call.
const propsOf = async (ws, kind, sn) => {
  const r = await ws.cmd(`${kind}.get_properties`, { serialNumber: sn }).catch(() => null);
  const p = r?.properties ?? {};
  return { name: p.name ?? sn, model: p.model ?? "?", station: p.stationSerialNumber ?? sn };
};

async function inventory(ws) {
  const state = await ws.cmd("start_listening");
  const byStation = {}, names = {}, stationOf = {};
  for (const sn of state.state.devices ?? []) {
    const d = await propsOf(ws, "device", sn);
    names[sn] = d.name;
    stationOf[sn] = d.station;
    (byStation[d.station] ??= []).push(sn);
  }
  for (const sn of state.state.stations ?? []) byStation[sn] ??= [sn];
  return { byStation, names, stationOf };
}

async function queryStation(ws, stationSn, deviceSns, from, to, storageType) {
  // Neutralise the rejection up front. Stations that reject the command below
  // (the lock and the tracker are "stations" too) would otherwise leave this
  // promise unawaited, and its timeout then fires as an unhandled rejection
  // minutes later — killing the process in the middle of a later download.
  const pending = ws.event(isEvent("database query by date", "station"), 45000)
    .then((m) => m, () => null);
  try {
    await ws.cmd("station.database_query_by_date", {
      serialNumber: stationSn,
      serialNumbers: deviceSns,   // required, despite the docs
      startDate: from,            // "YYYYMMDD" strings, not Dates
      endDate: nextDay(to),       // and the end is exclusive
      eventType: FilterEventType.VIDEO,
      storageType,
    });
  } catch (e) {
    if (e.message !== "device_not_supported") console.error(`  ${stationSn}: ${e.message}`);
    return [];
  }
  return (await pending)?.event.data ?? [];
}

// Which device to address the download to.
//
// A camera that is its own station (the wired indoor cams here) still writes its
// recordings to the HomeBase's disk — storage_path starts /zx/hdd_data0/ipclink/
// and the record's own station_sn names the HomeBase, not the camera. But the
// client routes device.start_download to the *device's* station and then refuses
// outright to ask a different one (WrongStationError). Addressed to the camera,
// the request is accepted and answered with silence: no data, no error, just
// "haven't received any data for 5 seconds" in the server log.
//
// The HomeBase serves by absolute path and doesn't care which of its own devices
// the request came through, so route via one of those instead. Devices that
// already belong to the recording's station (the eufyCams, the doorbell) are
// unaffected and address themselves.
const pickVia = (rec, stationOf, byStation) => {
  if (stationOf[rec.device_sn] === rec.station_sn) return rec.device_sn;
  const owned = (byStation[rec.station_sn] ?? []).filter((d) => stationOf[d] === rec.station_sn);
  return owned[0] ?? rec.device_sn;
};

// ── download ─────────────────────────────────────────────────────────────────

// The station serves one download at a time, so callers must await each.
async function downloadRec(ws, rec, outPath, via) {
  if (!rec.storage_path) throw new Error(`record ${rec.record_id} has no storage_path`);
  const sn = via ?? rec.device_sn;

  const work = mkdtempSync(join(tmpdir(), "eufy-clip-"));
  const vChunks = [], aChunks = [];
  let meta = null;

  const toBuf = (b) =>
    typeof b === "string" ? Buffer.from(b, "base64")
    : Array.isArray(b) ? Buffer.from(b)
    : Buffer.from(b?.data ?? []);

  const prevHandler = ws.onEvent;
  ws.onEvent = (e) => {
    if (e.serialNumber !== sn) return;
    if (e.event === "download video data") { vChunks.push(toBuf(e.buffer)); meta ??= e.metadata; }
    if (e.event === "download audio data") aChunks.push(toBuf(e.buffer));
  };

  try {
    const finished = ws.event(isEvent("download finished", "device"), 300000)
      .then(() => true, () => false);
    await ws.cmd("device.start_download", {
      serialNumber: sn,
      path: rec.storage_path,
      // Absent, not zero — see note 4 in the header.
      ...(rec.cipher_id ? { cipherId: rec.cipher_id } : {}),
    });
    if (!(await finished)) {
      const got = Buffer.concat(vChunks).length;
      throw new Error(got
        ? `stalled after ${(got / 1048576).toFixed(1)} MiB`
        : "no data — station never answered");
    }
  } finally {
    ws.onEvent = prevHandler;
  }

  const video = Buffer.concat(vChunks), audio = Buffer.concat(aChunks);
  if (!video.length) {
    rmSync(work, { recursive: true, force: true });
    throw new Error("download finished but no video data arrived");
  }

  // What arrives is raw elementary streams, not a container: H.264/H.265 video
  // and AAC audio as separate chunk events, to be muxed here.
  const isH265 = /265|hevc/i.test(meta?.videoCodec ?? "");
  const vRaw = join(work, isH265 ? "v.h265" : "v.h264");
  writeFileSync(vRaw, video);

  const fps = meta?.videoFPS > 0 ? String(meta.videoFPS) : "15";
  const args = ["-y", "-loglevel", "error", "-fflags", "+genpts",
                "-f", isH265 ? "hevc" : "h264", "-framerate", fps, "-i", vRaw];
  if (audio.length) {
    const aRaw = join(work, "a.aac");
    writeFileSync(aRaw, audio);
    args.push("-f", "aac", "-i", aRaw, "-c:a", "aac");
  }
  args.push("-c:v", "copy", "-movflags", "+faststart", outPath);
  sh("ffmpeg", args);
  rmSync(work, { recursive: true, force: true });
  return { bytes: statSync(outPath).size };
}

// ── commands ─────────────────────────────────────────────────────────────────

async function stations() {
  const ws = await connect();
  const state = await ws.cmd("start_listening");
  for (const sn of state.state.stations ?? []) {
    const { name, model } = await propsOf(ws, "station", sn);
    console.log(`station  ${sn}  ${name}  (${model})`);
  }
  for (const sn of state.state.devices ?? []) {
    const { name, model, station } = await propsOf(ws, "device", sn);
    console.log(`device   ${sn}  ${name}  (${model})  station=${station}`);
  }
  ws.close();
}

async function list(from, to, all) {
  const ws = await connect();
  const { byStation, names } = await inventory(ws);
  const storageType = all ? FilterStorageType.CLOUD : FilterStorageType.LOCAL;

  const rows = [];
  for (const [sn, devs] of Object.entries(byStation))
    rows.push(...(await queryStation(ws, sn, devs, from, to, storageType)));
  rows.sort((a, b) => new Date(a.start_time) - new Date(b.start_time));

  if (!rows.length) { console.log("no clips in that range"); ws.close(); return; }
  console.log("record_id     start                 dur  device                storage");
  for (const r of rows) {
    const start = new Date(r.start_time);
    const secs = Math.round((new Date(r.end_time) - start) / 1000);
    const where = r.storage_cloud ? "cloud" : (P2PStorageType[r.storage_type] ?? r.storage_type);
    console.log(
      `${String(r.record_id).padEnd(13)} ${localStamp(start)}  ${String(secs).padStart(4)}s  ` +
      `${(names[r.device_sn] ?? r.device_sn).padEnd(20)}  ${where}`
    );
  }
  ws.close();
}

async function get(recordId, outPath, day) {
  const ws = await connect();
  const { byStation, stationOf } = await inventory(ws);
  let rec = null;
  for (const [sn, devs] of Object.entries(byStation)) {
    const rows = await queryStation(ws, sn, devs, day, day, FilterStorageType.LOCAL);
    const hit = rows.find((r) => String(r.record_id) === String(recordId));
    if (hit) { rec = hit; break; }
  }
  if (!rec) throw new Error(`record ${recordId} not found on ${day}`);
  const { bytes } = await downloadRec(ws, rec, outPath, pickVia(rec, stationOf, byStation));
  console.log(`wrote ${outPath} (${(bytes / 1048576).toFixed(1)} MiB)`);
  ws.close();
}

// Everything matching a device + local-time window on one day: one database
// query, then sequential downloads. A failure on one clip doesn't stop the rest.
async function grab(day, { device, fromTime, toTime, outDir, dryRun, via }) {
  const ws = await connect();
  const { byStation, names, stationOf } = await inventory(ws);

  const rows = [];
  for (const [sn, devs] of Object.entries(byStation))
    rows.push(...(await queryStation(ws, sn, devs, day, day, FilterStorageType.LOCAL)));

  const sel = rows
    .filter((r) => {
      const name = names[r.device_sn] ?? r.device_sn;
      if (device && !name.toLowerCase().includes(device.toLowerCase())) return false;
      const hhmm = localStamp(new Date(r.start_time)).slice(11, 16);
      return (!fromTime || hhmm >= fromTime) && (!toTime || hhmm <= toTime);
    })
    .sort((a, b) => new Date(a.start_time) - new Date(b.start_time));

  const total = sel.reduce((n, r) => n + (r.folder_size || 0), 0);
  console.log(`${sel.length} clip(s) matched${total ? `, ~${(total / 1048576).toFixed(0)} MiB on disk` : ""}`);
  for (const r of sel) {
    const secs = Math.round((new Date(r.end_time) - new Date(r.start_time)) / 1000);
    console.log(`  ${r.record_id}  ${localStamp(new Date(r.start_time))}  ` +
                `${String(secs).padStart(4)}s  ${names[r.device_sn] ?? r.device_sn}`);
  }
  if (dryRun || !sel.length) { ws.close(); return; }

  sh("mkdir", ["-p", outDir]);
  let ok = 0;
  const failed = [];
  for (const [i, r] of sel.entries()) {
    const t = localStamp(new Date(r.start_time)).replace(/[- :]/g, "").slice(0, 14);
    const slug = (names[r.device_sn] ?? r.device_sn).toLowerCase().replace(/[^a-z0-9]+/g, "-");
    const out = join(outDir, `${slug}-${t}-${r.record_id}.mp4`);
    process.stdout.write(`[${i + 1}/${sel.length}] ${r.record_id} ... `);
    try {
      const { bytes } = await downloadRec(ws, r, out, via ?? pickVia(r, stationOf, byStation));
      console.log(`${(bytes / 1048576).toFixed(1)} MiB`);
      ok++;
    } catch (e) {
      console.log(`FAILED: ${e.message}`);
      failed.push(r.record_id);
    }
  }
  console.log(`\n${ok}/${sel.length} downloaded into ${outDir}`);
  if (failed.length) console.log(`failed: ${failed.join(", ")}`);
  ws.close();
}

// ── entry ────────────────────────────────────────────────────────────────────

const [cmd, ...rest] = process.argv.slice(2);
const args = rest.filter((a) => !a.startsWith("--"));
const flags = rest.filter((a) => a.startsWith("--"));
const flag = (n, d) => {
  const f = flags.find((x) => x.startsWith(`--${n}=`));
  return f ? f.slice(n.length + 3) : d;
};

try {
  switch (cmd) {
    case "up": up(); break;
    case "down": down(); break;
    case "stations": await stations(); break;
    case "code": {
      const ws = await connect();
      console.log(await ws.cmd("driver.set_verify_code", { verifyCode: args[0] }));
      ws.close(); break;
    }
    case "captcha": {
      const ws = await connect();
      console.log(await ws.cmd("driver.set_captcha", { captchaId: args[0], captcha: args[1] }));
      ws.close(); break;
    }
    case "list": await list(args[0], args[1] ?? args[0], flags.includes("--all")); break;
    case "grab":
      await grab(args[0], {
        device: flag("device"),
        fromTime: flag("from"),
        toTime: flag("to"),
        outDir: flag("out", `/var/tmp/eufy-clips/${args[0]}`),
        dryRun: flags.includes("--dry-run"),
        via: flag("via"),
      });
      break;
    case "get": {
      if (!/^\d{8}$/.test(args[1] ?? "")) throw new Error("usage: get <record_id> <YYYYMMDD> [out.mp4]");
      await get(args[0], args[2] ?? `clip-${args[0]}.mp4`, args[1]);
      break;
    }
    default:
      console.log("usage: eufy-clip up|code|captcha|stations|list|grab|get|down  (see header)");
  }
  process.exit(0);
} catch (e) {
  console.error(`error: ${e.message}`);
  process.exit(1);
}
