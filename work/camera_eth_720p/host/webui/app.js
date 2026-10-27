/* CAMERA_ETH_720P // HOST CONSOLE — 前端逻辑 */
const $ = (s) => document.querySelector(s);
const $$ = (s) => Array.from(document.querySelectorAll(s));

let logSeq = 0;
let selected = null;
let lastSessionsSig = "";
let lastLiveOk = null;
let lastRecOn = null;

async function api(path, body) {
  const opt = body === undefined
    ? {}
    : { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) };
  const r = await fetch(path, opt);
  return r.json();
}

function fmtBytes(n) {
  if (!n) return "0 B";
  const u = ["B", "KB", "MB", "GB"];
  let i = 0;
  while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
  return `${n.toFixed(n >= 100 ? 0 : 1)} ${u[i]}`;
}

function defaultName() {
  const d = new Date();
  const p = (v) => String(v).padStart(2, "0");
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}_${p(d.getHours())}${p(d.getMinutes())}${p(d.getSeconds())}`;
}

/* ------------------------------------------------------------------ status */
function setChip(sel, on) {
  const el = $(sel);
  el.classList.toggle("on", !!on);
}

async function tick() {
  let s;
  try { s = await api("/api/status"); } catch (e) { return; }

  // 设备
  $("#st-n").textContent = s.uart.ok ? s.uart.n : "—";
  $("#st-t").textContent = s.uart.ok ? s.uart.t : "—";
  $("#st-c").textContent = s.uart.ok ? s.uart.c : "—";
  $("#st-s").textContent = s.uart.ok ? s.uart.sid : "—";
  $("#st-v").textContent = s.uart.ok ? s.uart.v : "—";
  const v = s.uart.v || 0;
  const flags = [];
  if (v & 1) flags.push("CFG");
  if (v & 2) flags.push("SENSOR");
  if (v & 4) flags.push("OVF!");
  if (v & 8) flags.push("RX");
  $("#st-flags").textContent = s.uart.ok ? (flags.join(" · ") || "—") : "NO UART";
  $("#st-flags").style.color = (v & 4) ? "#ff6b62" : "#5ad98c";

  // HUD
  $("#hud-frame").textContent = s.live.frame || "—";
  $("#hud-fps").textContent = s.live.fps ? s.live.fps.toFixed(1) : "—";
  $("#hud-ae").textContent = s.live.ae || "—";
  $("#hud-ag").textContent = s.live.ag ? `${s.live.ag} (${s.live.ag === 48 ? "2X" : s.live.ag === 16 ? "1X" : "?"})` : "—";
  $("#hud-pkts").textContent = s.live.packets.toLocaleString();

  setChip("#chip-link", s.live.ok);
  setChip("#chip-cam", s.uart.ok && s.uart.c > 0);
  setChip("#chip-rec", s.rec.on);
  setChip("#chip-job", s.job.running);

  if (lastLiveOk !== s.live.ok) {
    $("#nosignal").classList.toggle("show", !s.live.ok);
    lastLiveOk = s.live.ok;
  }
  if (lastRecOn !== s.rec.on) {
    $("#rec-flag").classList.toggle("show", s.rec.on);
    $("#btn-rec").disabled = s.rec.on;
    $("#btn-stop").disabled = !s.rec.on;
    lastRecOn = s.rec.on;
  }

  $("#rec-hint").textContent = s.rec.on
    ? `${s.rec.name} · ${s.rec.seconds.toFixed(1)}s · ${s.rec.packets.toLocaleString()} pkt`
    : "STANDBY";

  $("#job-hint").textContent = s.job.running
    ? `${s.job.label} · ${s.job.session}`
    : "IDLE";

  renderSessions(s.sessions);
}

/* ---------------------------------------------------------------- sessions */
function renderSessions(list) {
  const sig = JSON.stringify(list);
  if (sig === lastSessionsSig) return;
  lastSessionsSig = sig;

  const box = $("#sess-list");
  box.innerHTML = "";
  $("#sess-count").textContent = list.length;

  if (!list.length) {
    box.innerHTML = '<div class="hint">暂无录制</div>';
    return;
  }
  if (!selected || !list.find((x) => x.name === selected)) selected = list[0].name;

  for (const it of list) {
    const el = document.createElement("div");
    el.className = "sess" + (it.name === selected ? " sel" : "");
    el.dataset.name = it.name;
    const meta = [];
    if (it.frames != null) meta.push(`${it.frames} f`);
    if (it.fps != null) meta.push(`${it.fps} fps`);
    if (it.bytes) meta.push(fmtBytes(it.bytes));

    el.innerHTML = `
      <div class="sess-top">
        <b>${it.name}</b>
        <em>${meta.join(" · ") || "—"}</em>
      </div>
      <div class="sess-tags">
        ${it.has_pcap ? '<span class="tag ok">PCAP</span>' : ""}
        ${it.has_meta ? '<span class="tag ok">META</span>' : ""}
        ${it.has_raw ? '<span class="tag ok">RAW10</span>' : ""}
        ${it.has_png ? '<span class="tag ok">PNG</span>' : ""}
        ${it.has_mp4 ? '<span class="tag ok">MP4</span>' : ""}
      </div>
      <div class="sess-actions">
        <button data-act="dir">DIR</button>
        <button data-act="process">PROCESS</button>
      </div>`;

    el.addEventListener("click", (e) => {
      const act = e.target.dataset && e.target.dataset.act;
      if (act === "dir") {
        api("/api/open", { session: it.name });
        return;
      }
      if (act === "process") {
        selected = it.name;
        $$(".sess").forEach((s) => s.classList.toggle("sel", s.dataset.name === selected));
        processSession(it.name);
        return;
      }
      selected = it.name;
      $$(".sess").forEach((s) => s.classList.toggle("sel", s.dataset.name === selected));
    });
    box.appendChild(el);
  }
}

/* ------------------------------------------------------------------- jobs */
function currentOptions() {
  return {
    meta: $("#opt-meta").checked,
    png: $("#opt-png").checked,
    mp4: $("#opt-mp4").checked,
    raw: $("#opt-raw").checked,
  };
}

async function processSession(name) {
  const options = currentOptions();
  if (!options.meta && !options.png && !options.mp4 && !options.raw) {
    pushLocal("[warn] 至少选一个产物");
    return;
  }
  const r = await api("/api/session/render", { session: name, options });
  pushLocal(r.ok ? `[job] 已排队: ${name}` : `[error] ${r.msg}`);
  tick();
}

/* -------------------------------------------------------------------- log */
function pushLocal(text) {
  const el = $("#log");
  el.textContent += `${text}\n`;
  el.scrollTop = el.scrollHeight;
}

async function pollLog() {
  try {
    const r = await api(`/api/log?since=${logSeq}`);
    if (r.lines && r.lines.length) {
      const el = $("#log");
      const atBottom = el.scrollHeight - el.scrollTop - el.clientHeight < 40;
      el.textContent += r.lines.join("\n") + "\n";
      logSeq = r.seq;
      $("#log-n").textContent = r.seq;
      if (atBottom) el.scrollTop = el.scrollHeight;
    } else if (r.seq > logSeq) {
      logSeq = r.seq;
      $("#log-n").textContent = r.seq;
    }
  } catch (e) { /* ignore */ }
}

/* ------------------------------------------------------------------ actions */
$("#btn-rec").addEventListener("click", async () => {
  const name = $("#rec-name").value.trim() || defaultName();
  $("#rec-name").value = name;
  const duration = parseInt($("#rec-dur").value, 10);
  const auto = $("#opt-auto").checked;
  const r = await api("/api/record/start", { name, duration, auto, options: currentOptions() });
  if (!r.ok) pushLocal(`[error] ${r.msg}`);
  lastRecOn = null;
  tick();
});

$("#btn-stop").addEventListener("click", async () => {
  await api("/api/record/stop", {});
  lastRecOn = null;
  setTimeout(tick, 300);
});

$("#btn-run").addEventListener("click", () => {
  if (!selected) { pushLocal("[warn] 先选一个 session"); return; }
  processSession(selected);
});

/* -------------------------------------------------------------------- boot */
function clock() {
  const d = new Date();
  const p = (v) => String(v).padStart(2, "0");
  $("#clock").textContent = `${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`;
}

function reloadFeed() {
  const img = $("#feed");
  img.src = "/stream.mjpg?t=" + Date.now();
  lastLiveOk = null;
}
$("#feed").addEventListener("error", () => {
  setTimeout(reloadFeed, 2000);
});

clock();
setInterval(clock, 1000);
reloadFeed();
tick();
setInterval(tick, 900);
setInterval(pollLog, 700);
