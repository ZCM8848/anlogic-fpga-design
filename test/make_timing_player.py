# -*- coding: utf-8 -*-
"""
Build an interactive HTML player that shows the original video on the left and
the measured orange-LED timing on the right, so the timing can be checked by eye.

Input : test/results/frames.csv, test/results/off_pulses.csv  (from led_blink_analysis.py)
Output: test/player/index.html + test/player/port_video.mp4
"""

import csv
import json
import os
import re
import shutil

import cv2
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
RES = os.path.join(HERE, "results")
OUT = os.path.join(HERE, "player")
SRC_VIDEO = r"C:\Users\Z___C\Documents\FPGA_is_good\test\VID_20261027_013309_rotated.mp4"

os.makedirs(OUT, exist_ok=True)

# --------------------------------------------------------------------------- #
# data
# --------------------------------------------------------------------------- #
rows = list(csv.DictReader(open(os.path.join(RES, "frames.csv"), encoding="utf-8")))
pulses = list(csv.DictReader(open(os.path.join(RES, "off_pulses.csv"), encoding="utf-8")))

with open(os.path.join(RES, "summary.txt"), encoding="utf-8") as fh:
    summary = fh.read()
m = re.search(r"R = (\d+)", summary)
THR = int(m.group(1)) if m else 200

times = np.array([float(r["time_s"]) for r in rows])
dt = float(np.median(np.diff(times)))
DUR = float(times[-1])
off_ms = [round(float(p["duration_s"]) * 1000) for p in pulses]
starts = np.array([float(p["start_s"]) for p in pulses])
MED_OFF = float(np.median(off_ms)) if off_ms else 0.0
MED_GAP = float(np.median(np.diff(starts)) * 1000) if len(starts) > 1 else 0.0

cap = cv2.VideoCapture(SRC_VIDEO)
VW = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
VH = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
cap.release()

if VH > VW:
    VSTYLE = "height:620px;width:auto"
    WSTYLE = "width:fit-content"
else:
    VSTYLE = "width:100%;height:auto"
    WSTYLE = ""
MAGX = f"~{300 / max(60, round(min(VW, VH) * 0.11)):.1f}×"

data = {
    "t": [round(v, 4) for v in times],
    "s": [1 if r["state"] == "ON" else 0 for r in rows],
    "r": [int(float(r["led_core_R"])) for r in rows],
    "x": [round(float(r["led_cx"]), 2) for r in rows],
    "y": [round(float(r["led_cy"]), 2) for r in rows],
    "v": [int(r["visible"]) for r in rows],
    "w": VW,
    "h": VH,
    "thr": THR,
    "pulses": [
        {
            "s": round(float(p["start_s"]), 4),
            "e": round(float(p["end_s"]), 4),
            "d": round(float(p["duration_s"]) * 1000),
            "f": int(p["frames"]),
            "g": (round(float(p["gap_from_prev_end_s"]), 3)
                  if p["gap_from_prev_end_s"] else None),
        }
        for p in pulses
    ],
}

# values substituted into the page
META = f"{VW} × {VH} · {1/dt:.0f} fps · {DUR:.1f} s"
RESMS = f"{dt * 500:.0f}"
NPULSE = len(pulses)

# keep the exact video the analysis was run on next to the HTML
dst_video = os.path.join(OUT, "port_video.mp4")
if not (os.path.exists(dst_video) and os.path.getsize(dst_video) == os.path.getsize(SRC_VIDEO)):
    shutil.copy2(SRC_VIDEO, dst_video)

win_start = next(float(r["time_s"]) for r in rows if r["visible"] == "1")
data["win"] = [round(win_start, 3), round(data["t"][-1], 3)]

payload = json.dumps(data, ensure_ascii=False, separators=(",", ":"))

# --------------------------------------------------------------------------- #
# page
# --------------------------------------------------------------------------- #
HTML = r"""<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>网口橙色灯时序回放</title>
<style>
  :root{
    --bg:#0d1015; --card:#151922; --card2:#1b2029; --line:#262d3a;
    --fg:#e8edf5; --dim:#8590a3; --on:#ff9f1c; --on2:#ffbe55;
    --off:#3a4150; --green:#35d07f; --red:#ff5d5d; --mono:"Consolas","SFMono-Regular",Menlo,monospace;
  }
  *{box-sizing:border-box}
  body{margin:0;background:radial-gradient(1200px 600px at 20% -10%,#1a2130 0%,var(--bg) 55%);
       color:var(--fg);font:13px/1.45 "Segoe UI","Microsoft YaHei",system-ui,sans-serif}
  header{padding:16px 22px 10px}
  h1{margin:0;font-size:18px;font-weight:600;letter-spacing:.3px}
  .sub{color:var(--dim);font-size:12px;margin-top:3px}
  main{display:grid;grid-template-columns:minmax(340px,.82fr) minmax(560px,1.45fr);
       gap:16px;padding:6px 22px 26px;align-items:start;max-width:1680px}
  @media (max-width:1050px){main{grid-template-columns:1fr}}
  .col{display:flex;flex-direction:column;gap:14px;min-width:0}
  .card{background:linear-gradient(180deg,var(--card2),var(--card));border:1px solid var(--line);
        border-radius:12px;padding:12px 14px;box-shadow:0 6px 24px rgba(0,0,0,.25)}
  .card-title{font-size:12px;font-weight:600;letter-spacing:.4px;color:#cfd6e4;
              display:flex;align-items:center;gap:8px;margin-bottom:9px}
  .dim{color:var(--dim);font-weight:400;font-size:11px}
  .mono{font-family:var(--mono)}

  /* ---------------- video ---------------- */
  .video-wrap{position:relative;background:#000;border-radius:8px;overflow:hidden;
              border:1px solid #0a0c10;max-width:480px;margin:0 auto}
  video{display:block;width:100%;height:auto;background:#000}
  #ring{position:absolute;border:1.5px solid #ffd166;border-radius:50%;
        transform:translate(-50%,-50%);pointer-events:none;display:none;
        box-shadow:0 0 8px rgba(255,209,102,.9),inset 0 0 5px rgba(255,209,102,.5)}
  .controls{display:flex;flex-wrap:wrap;gap:7px;align-items:center;margin-top:10px}
  button,select{background:#202633;color:var(--fg);border:1px solid #2d3546;border-radius:7px;
         padding:6px 10px;font:12px inherit;cursor:pointer;transition:.12s}
  button:hover,select:hover{background:#283042;border-color:#3d4860}
  button.primary{background:#2b2417;border-color:#6b4c14;color:#ffce7a}
  button.primary:hover{background:#3a2f1a}
  #clock{margin-left:auto;color:var(--dim);font-size:11.5px}
  #magWrap{display:flex;justify-content:center}
  #mag{width:300px;height:300px;border-radius:10px;background:#000;image-rendering:pixelated}
  .mag-note{width:100%;display:flex;justify-content:space-between;color:var(--dim);
            font-size:11px;margin-top:6px}

  /* ---------------- status ---------------- */
  .status{display:grid;grid-template-columns:1.25fr .85fr .85fr .85fr .9fr;gap:10px}
  @media (max-width:720px){.status{grid-template-columns:1fr 1fr}}
  .stat{background:linear-gradient(180deg,var(--card2),var(--card));border:1px solid var(--line);
         border-radius:11px;padding:9px 11px}
  .stat label{display:block;color:var(--dim);font-size:10.5px;letter-spacing:.3px;margin-bottom:3px}
  .stat b{font-family:var(--mono);font-size:15px;font-weight:600;letter-spacing:.2px}
  .badge{display:flex;flex-direction:column;justify-content:center;border-radius:11px;
         border:1px solid var(--line);padding:9px 13px;background:linear-gradient(180deg,var(--card2),var(--card))}
  .badge .k{font-size:10.5px;color:var(--dim);letter-spacing:.3px;margin-bottom:2px}
  .badge .v{font-size:22px;font-weight:700;letter-spacing:.5px;font-family:var(--mono)}
  .badge.on{border-color:#7a5412;box-shadow:0 0 22px rgba(255,159,28,.18) inset}
  .badge.on .v{color:var(--on)}
  .badge.off{border-color:#6b2b2b;box-shadow:0 0 22px rgba(255,93,93,.15) inset}
  .badge.off .v{color:var(--red)}
  .badge.na .v{color:var(--dim);font-size:17px}

  canvas.tl{display:block;width:100%;border-radius:8px;background:#0b0e13;cursor:crosshair}
  #ov{height:74px}
  #detail{height:176px}
  .win-btns{margin-left:auto;display:flex;gap:5px}
  .win-btns button{padding:2px 8px;font-size:11px}
  .win-btns button.active{background:#3a2f1a;border-color:#7a5412;color:#ffce7a}
  .legend{display:flex;gap:14px;color:var(--dim);font-size:11px;margin-top:7px}
  .sw{display:inline-block;width:9px;height:9px;border-radius:2px;margin-right:5px;vertical-align:-1px}

  /* ---------------- table ---------------- */
  .table-wrap{max-height:300px;overflow:auto;border:1px solid var(--line);border-radius:8px;position:relative}
  table{width:100%;border-collapse:collapse;font-family:var(--mono);font-size:11.5px}
  thead th{position:sticky;top:0;background:#202633;color:#cfd6e4;font-weight:600;
           text-align:right;padding:6px 9px;border-bottom:1px solid var(--line);z-index:1}
  thead th:first-child{text-align:left}
  tbody td{padding:5px 9px;text-align:right;border-bottom:1px solid #1d232e;color:#c6cddb}
  tbody td:first-child{text-align:left;color:var(--dim)}
  tbody tr{cursor:pointer}
  tbody tr:hover{background:#1d2431}
  tbody tr.active{background:#3a2410;color:#ffd7a0}
  tbody tr.active td{color:#ffd7a0}
  tbody tr.selected{box-shadow:inset 3px 0 0 var(--on)}
  tbody tr.passed td{color:#69748a}
  .loop{display:flex;align-items:center;gap:5px;margin-left:12px;color:var(--dim);
        font-size:11px;font-weight:400;cursor:pointer}
  .loop input{accent-color:var(--on);width:13px;height:13px;cursor:pointer}
  .hint{color:var(--dim);font-size:11px;margin-top:8px}
  kbd{background:#202633;border:1px solid #323b4d;border-bottom-width:2px;border-radius:4px;
      padding:0 5px;font:11px var(--mono);color:#cfd6e4}
</style>
</head>
<body>
<header>
  <h1>网口橙色灯时序回放</h1>
  <div class="sub">左边：原视频（黄圈为程序跟踪到的橙色灯）&nbsp;·&nbsp;右边：由 <span class="mono">frames.csv</span> 驱动的实时时序&nbsp;·&nbsp;拖动 / 点击时间轴可跳转&nbsp;·&nbsp;时间分辨率 ±1 帧 ≈ __RESMS__ ms</div>
</header>

<main>
  <!-- ================= LEFT ================= -->
  <section class="col">
    <div class="card">
      <div class="card-title">原视频 <span class="dim">__META__</span></div>
      <div class="video-wrap" id="vwrap" style="__WSTYLE__">
        <video id="vid" src="port_video.mp4" controls preload="auto" playsinline style="__VSTYLE__"></video>
        <div id="ring"></div>
      </div>
      <div class="controls">
        <button id="playBtn" class="primary">▶ 播放</button>
        <button id="firstBtn" title="跳到第 1 次熄灭前 0.4 s">跳到第 1 次熄灭</button>
        <button data-step="-1">◀ 帧</button>
        <button data-step="1">帧 ▶</button>
        <select id="speed" title="播放速度">
          <option value="0.25">0.25×</option>
          <option value="0.5">0.5×</option>
          <option value="1" selected>1×</option>
        </select>
        <span id="clock" class="mono">0.000 / __DUR__ s</span>
      </div>
    </div>

    <div class="card">
      <div class="card-title">橙色灯放大 <span class="dim">跟随灯的位置</span></div>
      <div id="magWrap"><canvas id="mag" width="300" height="300"></canvas></div>
      <div class="mag-note"><span>放大 __MAGX__</span><span id="magState">—</span></div>
    </div>
  </section>

  <!-- ================= RIGHT ================= -->
  <section class="col">
    <div class="status">
      <div class="badge na" id="badge"><span class="k">当前状态</span><span class="v" id="badgeV">—</span></div>
      <div class="stat"><label>视频时间</label><b id="sTime">0.000 s</b></div>
      <div class="stat"><label>本段已持续</label><b id="sElapsed">—</b></div>
      <div class="stat"><label>距下次变化</label><b id="sRemain">—</b></div>
      <div class="stat"><label>熄灭计数</label><b id="sCount">0 / __NPULSE__</b></div>
    </div>

    <div class="card">
      <div class="card-title">全程时序 <span class="dim">整段 0 – __DUR__ s，点击跳转</span></div>
      <canvas id="ov" class="tl"></canvas>
      <div class="legend">
        <span><i class="sw" style="background:var(--on)"></i>橙色灯亮</span>
        <span><i class="sw" style="background:#2a2f3a"></i>橙色灯熄灭</span>
        <span><i class="sw" style="background:#4a4030"></i>无有效信号</span>
        <span style="margin-left:auto">红线 = 当前播放位置</span>
      </div>
    </div>

    <div class="card">
      <div class="card-title">局部放大 <span class="dim">亮度曲线 + ON/OFF（阈值 R=__THR__）</span>
        <span class="win-btns">
          <button data-win="2">2 s</button>
          <button data-win="6" class="active">6 s</button>
          <button data-win="12">12 s</button>
        </span>
      </div>
      <canvas id="detail" class="tl"></canvas>
      <div class="legend">
        <span><i class="sw" style="background:var(--red)"></i>灯芯亮度（红色分量）</span>
        <span><i class="sw" style="background:var(--on)"></i>判定为 ON</span>
        <span><i class="sw" style="background:#2a2f3a"></i>判定为 OFF</span>
      </div>
    </div>

    <div class="card">
      <div class="card-title">__NPULSE__ 次熄灭 <span class="dim">中位 __MEDOFF__ ms · 间隔中位 __MEDGAP__ ms · 点击任意行跳到该次熄灭前 0.4 s 并以 0.5× 播放</span>
        <label class="loop"><input type="checkbox" id="loopChk"> 循环该段</label>
      </div>
      <div class="table-wrap" id="twrap">
        <table>
          <thead><tr><th>#</th><th>起始 (s)</th><th>结束 (s)</th><th>时长 (ms)</th><th>距上次 (s)</th></tr></thead>
          <tbody id="tbody"></tbody>
        </table>
      </div>
      <div class="hint">快捷键：<kbd>空格</kbd> 播放/暂停 &nbsp;<kbd>←</kbd><kbd>→</kbd> 单帧 &nbsp;·&nbsp;
        建议用 0.5× 播放，对照右侧“当前状态”和放大窗口肉眼核对。</div>
    </div>
  </section>
</main>

<script>
window.__errs = [];
window.addEventListener('error', e => window.__errs.push((e.message || '') + ' @' + (e.lineno || 0) + ':' + (e.colno || 0)));
const D = __DATA__;
const T = D.t, S = D.s, RR = D.r, X = D.x, Y = D.y, VIS = D.v;
const THR = D.thr;
const N = T.length, DUR = T[N-1];
const WIN0 = D.win[0], WIN1 = D.win[1];
const PULSES = D.pulses;
const VW = D.w, VH = D.h;

const vid = document.getElementById('vid');
const ring = document.getElementById('ring');
const mag = document.getElementById('mag');
const ov = document.getElementById('ov');
const detail = document.getElementById('detail');
const badge = document.getElementById('badge');
const badgeV = document.getElementById('badgeV');
const sTime = document.getElementById('sTime');
const sElapsed = document.getElementById('sElapsed');
const sRemain = document.getElementById('sRemain');
const sCount = document.getElementById('sCount');
const clock = document.getElementById('clock');
const magState = document.getElementById('magState');
const playBtn = document.getElementById('playBtn');
const tbody = document.getElementById('tbody');
const twrap = document.getElementById('twrap');

function clamp(v,a,b){ return Math.max(a, Math.min(b, v)); }

/* ---------- runs (same midpoint rule as the analysis script) ---------- */
const RUNS = [];
(function(){
  let st = 0;
  for (let i = 1; i <= N; i++) {
    if (i === N || S[i] !== S[st]) {
      const start = st === 0 ? T[0] : (T[st-1] + T[st]) / 2;
      const end   = i === N ? T[N-1] : (T[i-1] + T[i]) / 2;
      RUNS.push({on: !!S[st], start, end});
      st = i;
    }
  }
})();
function runAt(t){
  let lo = 0, hi = RUNS.length - 1;
  while (lo < hi) {
    const m = (lo + hi) >> 1;
    if (RUNS[m].end < t) lo = m + 1; else hi = m;
  }
  return RUNS[lo];
}

/* ---------- frame lookup ---------- */
function frameAt(t){
  let lo = 0, hi = N - 1;
  if (t <= T[0]) return 0;
  if (t >= T[hi]) return hi;
  while (lo < hi) { const m = (lo + hi) >> 1; if (T[m] < t) lo = m + 1; else hi = m; }
  let i = lo;
  if (i > 0 && (t - T[i-1]) < (T[i] - t)) i--;
  return i;
}

/* ---------- canvases ---------- */
function fit(c){
  const d = window.devicePixelRatio || 1;
  const w = c.clientWidth, h = c.clientHeight;
  if (c.width !== Math.round(w*d) || c.height !== Math.round(h*d)) {
    c.width = Math.round(w*d); c.height = Math.round(h*d);
  }
  const ctx = c.getContext('2d');
  ctx.setTransform(d,0,0,d,0,0);
  return {ctx, w, h};
}

/* ---------- seeking ---------- */
let winSec = 6, ws = Math.max(0, WIN0 - 0.5);

function snapWindow(t){
  ws = clamp(t - winSec*0.35, 0, Math.max(0, DUR - winSec));
}
function seek(t, play=false, rate=null){
  vid.currentTime = clamp(t, 0, DUR);
  if (rate !== null) { vid.playbackRate = rate;
    document.getElementById('speed').value = String(rate); }
  snapWindow(vid.currentTime);
  if (play) vid.play().catch(()=>{});
}

/* ---------- table ---------- */
const trs = [];
let loopOn = false, loopRange = null, selPulse = -1;

function playPulse(k){
  const p = PULSES[k];
  selPulse = k;
  loopRange = [Math.max(0, p.s - 0.4), Math.min(DUR, p.e + 0.6)];
  trs.forEach((tr,i)=>tr.classList.toggle('selected', i===k));
  seek(loopRange[0], true, 0.5);
}

PULSES.forEach((p, k) => {
  const tr = document.createElement('tr');
  tr.innerHTML = `<td>${k+1}</td><td>${p.s.toFixed(3)}</td><td>${p.e.toFixed(3)}</td>`+
                 `<td>${p.d}</td><td>${p.g === null ? '—' : p.g.toFixed(3)}</td>`;
  tr.addEventListener('click', () => playPulse(k));
  tbody.appendChild(tr);
  trs.push(tr);
});

document.getElementById('loopChk').addEventListener('change', e => {
  loopOn = e.target.checked;
  if (loopOn && !loopRange) playPulse(0);
});

/* ---------- drawing ---------- */
function drawOverview(t){
  const {ctx, w, h} = fit(ov);
  ctx.clearRect(0,0,w,h);
  const y0 = 22, y1 = h - 24;
  // not-in-view region
  ctx.fillStyle = '#232026';
  ctx.fillRect(0, y0, WIN0/DUR*w, y1-y0);
  // runs
  for (const r of RUNS) {
    const x0 = r.start/DUR*w, x1 = r.end/DUR*w;
    ctx.fillStyle = r.on ? '#ff9f1c' : '#2a2f3a';
    ctx.fillRect(x0, y0, Math.max(1, x1-x0), y1-y0);
  }
  // grid + labels
  ctx.strokeStyle = 'rgba(255,255,255,.07)'; ctx.lineWidth = 1;
  ctx.fillStyle = '#6e788c'; ctx.font = '10px Consolas, monospace';
  ctx.textAlign = 'center';
  for (let s = 0; s <= Math.floor(DUR); s += 5) {
    const x = s/DUR*w;
    ctx.beginPath(); ctx.moveTo(x, y1); ctx.lineTo(x, y1+4); ctx.stroke();
    ctx.fillText(s + 's', x, h-6);
  }
  // pulses ticks
  ctx.fillStyle = '#ff5d5d';
  for (const p of PULSES) {
    const x = p.s/DUR*w;
    ctx.fillRect(x-1, y0-6, 2, 5);
  }
  // playhead
  const x = t/DUR*w;
  ctx.strokeStyle = '#ff3b3b'; ctx.lineWidth = 1.5;
  ctx.beginPath(); ctx.moveTo(x, y0-10); ctx.lineTo(x, y1+6); ctx.stroke();
  ctx.fillStyle = '#ff3b3b';
  ctx.beginPath(); ctx.arc(x, y0-10, 3, 0, Math.PI*2); ctx.fill();
}

function drawDetail(t){
  const {ctx, w, h} = fit(detail);
  ctx.clearRect(0,0,w,h);
  const a = ws, b = ws + winSec;
  const top = 16, bot = h - 26;
  const xof = v => (v - a)/(b - a)*w;

  // OFF shading for runs
  for (const r of RUNS) {
    if (!r.on && r.end > a && r.start < b) {
      ctx.fillStyle = 'rgba(255,93,93,.07)';
      ctx.fillRect(xof(Math.max(a,r.start)), top, xof(Math.min(b,r.end))-xof(Math.max(a,r.start)), bot-top);
    }
  }

  // brightness curve
  let i0 = frameAt(a), i1 = frameAt(b);
  ctx.beginPath();
  for (let i = i0; i <= i1; i++) {
    const x = xof(T[i]);
    const y = top + (1 - RR[i]/255) * (bot - top - 2) + 1;
    if (i === i0) ctx.moveTo(x,y); else ctx.lineTo(x,y);
  }
  ctx.strokeStyle = '#ff6b4a'; ctx.lineWidth = 1.2; ctx.stroke();

  // threshold
  const ythr = top + (1 - THR/255) * (bot - top - 2) + 1;
  ctx.setLineDash([3,3]); ctx.strokeStyle = 'rgba(200,210,230,.35)';
  ctx.beginPath(); ctx.moveTo(0, ythr); ctx.lineTo(w, ythr); ctx.stroke();
  ctx.setLineDash([]);
  ctx.fillStyle = 'rgba(200,210,230,.45)'; ctx.font = '9.5px Consolas, monospace';
  ctx.textAlign = 'left'; ctx.fillText('R=' + THR, 3, ythr-3);

  // ON/OFF bar
  const by = bot + 6, bh = 9;
  for (const r of RUNS) {
    if (r.end > a && r.start < b) {
      const x0 = xof(Math.max(a, r.start)), x1 = xof(Math.min(b, r.end));
      ctx.fillStyle = r.on ? 'rgba(255,159,28,.9)' : '#2a2f3a';
      ctx.fillRect(x0, by, Math.max(1, x1-x0), bh);
    }
  }

  // pulse numbers
  ctx.font = '9px Consolas, monospace';
  ctx.textAlign = 'center';
  PULSES.forEach((p, k) => {
    if (p.e > a && p.s < b) {
      const x = xof((p.s+p.e)/2);
      ctx.fillStyle = 'rgba(255,93,93,.9)';
      ctx.fillText('#'+(k+1), x, top - 5);
    }
  });

  // time ticks
  const step = winSec <= 2 ? 0.25 : (winSec <= 6 ? 0.5 : 1);
  ctx.strokeStyle = 'rgba(255,255,255,.08)';
  ctx.fillStyle = '#6e788c'; ctx.textAlign = 'center';
  for (let s = Math.ceil(a/step)*step; s <= b + 1e-6; s += step) {
    const x = xof(s);
    ctx.beginPath(); ctx.moveTo(x, by+bh); ctx.lineTo(x, by+bh+3); ctx.stroke();
    ctx.fillText(s.toFixed(step < 1 ? 2 : 1), x, by+bh+14);
  }

  // playhead
  const x = xof(t);
  ctx.strokeStyle = '#ff3b3b'; ctx.lineWidth = 1.5;
  ctx.beginPath(); ctx.moveTo(x, top-8); ctx.lineTo(x, by+bh+3); ctx.stroke();
}

function drawMag(i, vis, on){
  const ctx = mag.getContext('2d');
  const W = mag.width, H = mag.height;
  const SZ = Math.max(60, Math.round(Math.min(VW, VH) * 0.11));
  ctx.clearRect(0,0,W,H);
  if (!vis) {
    ctx.fillStyle = '#0a0c10'; ctx.fillRect(0,0,W,H);
    ctx.fillStyle = '#6e788c'; ctx.font = '14px "Microsoft YaHei",sans-serif';
    ctx.textAlign = 'center'; ctx.fillText('网口未就绪（灯未亮）', W/2, H/2);
    return;
  }
  let cx = X[i], cy = Y[i];
  const sx = clamp(cx - SZ/2, 0, VW - SZ), sy = clamp(cy - SZ/2, 0, VH - SZ);
  if (vid.readyState >= 2) {
    ctx.imageSmoothingEnabled = false;
    ctx.drawImage(vid, sx, sy, SZ, SZ, 0, 0, W, H);
  } else {
    ctx.fillStyle = '#000'; ctx.fillRect(0,0,W,H);
  }
  // ring at tracked LED position
  const mx = (cx - sx)/SZ*W, my = (cy - sy)/SZ*H;
  ctx.strokeStyle = on ? '#ffd166' : '#66708a';
  ctx.lineWidth = 2;
  ctx.beginPath(); ctx.arc(mx, my, W*0.28, 0, Math.PI*2); ctx.stroke();
  // state chip
  ctx.fillStyle = on ? 'rgba(255,159,28,.92)' : 'rgba(60,66,80,.9)';
  ctx.fillRect(0, H-24, W, 24);
  ctx.fillStyle = on ? '#1a1206' : '#cfd6e4';
  ctx.font = 'bold 13px Consolas, monospace';
  ctx.textAlign = 'center';
  ctx.fillText((on ? 'ON  · 亮' : 'OFF · 熄灭') + '   ' + vid.currentTime.toFixed(3) + ' s', W/2, H-7);
}

/* ---------- main loop ---------- */
let lastActive = -1, lastBadge = '';

function tick(){
  const t = vid.currentTime;

  // loop the selected OFF pulse while playing
  if (loopOn && loopRange && !vid.paused && t >= loopRange[1]) {
    vid.currentTime = loopRange[0];
    requestAnimationFrame(tick);
    return;
  }

  const i = frameAt(t);
  const vis = !!VIS[i];
  const on = vis && !!S[i];

  // clock + ring
  clock.textContent = t.toFixed(3) + ' / ' + DUR.toFixed(3) + ' s';
  if (vis) {
    ring.style.display = 'block';
    ring.style.left = (X[i]/VW*100) + '%';
    ring.style.top  = (Y[i]/VH*100) + '%';
    const d = Math.max(4, Math.min(VW, VH) * 0.10 / VW * 100);
    ring.style.width = d + '%';
    ring.style.paddingBottom = d + '%';
  } else {
    ring.style.display = 'none';
  }

  // badge
  const cls = !vis ? 'na' : (on ? 'on' : 'off');
  if (cls !== lastBadge) {
    badge.className = 'badge ' + cls;
    badgeV.textContent = !vis ? '无有效信号' : (on ? '亮 · ON' : '灭 · OFF');
    lastBadge = cls;
  }

  // run info
  if (vis) {
    const r = runAt(t);
    sTime.textContent = t.toFixed(3) + ' s';
    sElapsed.textContent = (t - r.start).toFixed(3) + ' s / ' + (r.end - r.start).toFixed(3) + ' s';
    sRemain.textContent = Math.max(0, r.end - t).toFixed(3) + ' s';
  } else {
    sTime.textContent = t.toFixed(3) + ' s';
    sElapsed.textContent = '—';
    sRemain.textContent = '—';
  }
  let done = 0, act = -1;
  PULSES.forEach((p, k) => {
    if (p.e <= t) done++;
    if (t >= p.s && t <= p.e) act = k;
  });
  sCount.textContent = done + ' / ' + PULSES.length + (act >= 0 ? ' (第'+(act+1)+'次中)' : '');

  // table highlight
  trs.forEach((tr, k) => {
    tr.classList.toggle('active', k === act);
    tr.classList.toggle('passed', k !== act && PULSES[k].e <= t);
  });
  if (act !== lastActive) {
    lastActive = act;
    if (act >= 0) {
      const tr = trs[act];
      twrap.scrollTop = tr.offsetTop - twrap.clientHeight/2 + tr.offsetHeight/2;
    }
  }

  // detail window follow
  const target = clamp(t - winSec*0.35, 0, Math.max(0, DUR - winSec));
  if (Math.abs(target - ws) > winSec*0.6) ws = target;
  else ws += (target - ws) * 0.18;

  drawOverview(t);
  drawDetail(t);
  drawMag(i, vis, on);
  magState.textContent = vis ? ('R = ' + RR[i]) : '—';

  requestAnimationFrame(tick);
}

/* ---------- interactions ---------- */
playBtn.addEventListener('click', () => {
  if (vid.paused) vid.play(); else vid.pause();
});
vid.addEventListener('play',  () => playBtn.textContent = '⏸ 暂停');
vid.addEventListener('pause', () => playBtn.textContent = '▶ 播放');

document.querySelectorAll('[data-step]').forEach(btn => {
  btn.addEventListener('click', () => {
    vid.pause();
    const dir = parseInt(btn.dataset.step, 10);
    const i = clamp(frameAt(vid.currentTime) + dir, 0, N-1);
    seek(T[i] + 0.001);
  });
});

document.getElementById('speed').addEventListener('change', e => {
  vid.playbackRate = parseFloat(e.target.value);
});

document.getElementById('firstBtn').addEventListener('click', () => {
  playPulse(0);
});

ov.addEventListener('click', e => {
  const r = ov.getBoundingClientRect();
  seek((e.clientX - r.left)/r.width*DUR);
});

detail.addEventListener('click', e => {
  const r = detail.getBoundingClientRect();
  seek(ws + (e.clientX - r.left)/r.width*winSec);
});

document.querySelectorAll('[data-win]').forEach(btn => {
  btn.addEventListener('click', () => {
    document.querySelectorAll('[data-win]').forEach(b => b.classList.remove('active'));
    btn.classList.add('active');
    winSec = parseFloat(btn.dataset.win);
    snapWindow(vid.currentTime);
  });
});

document.addEventListener('keydown', e => {
  if (e.target.tagName === 'INPUT' || e.target.tagName === 'SELECT') return;
  if (e.code === 'Space') { e.preventDefault(); if (vid.paused) vid.play(); else vid.pause(); }
  if (e.code === 'ArrowLeft')  { e.preventDefault(); vid.pause(); const i = clamp(frameAt(vid.currentTime)-1,0,N-1); seek(T[i]+0.001); }
  if (e.code === 'ArrowRight') { e.preventDefault(); vid.pause(); const i = clamp(frameAt(vid.currentTime)+1,0,N-1); seek(T[i]+0.001); }
});

window.addEventListener('resize', () => { snapWindow(vid.currentTime); });

/* start */
vid.addEventListener('loadedmetadata', () => {
  seek(Math.max(0, WIN0 + 0.2));
  vid.pause();
  playBtn.textContent = '▶ 播放';
});
tick();
</script>
</body>
</html>
"""

html = HTML.replace("__DATA__", payload)
for key, val in (("__META__", META), ("__RESMS__", RESMS), ("__NPULSE__", str(NPULSE)),
                 ("__MEDOFF__", f"{MED_OFF:.0f}"), ("__MEDGAP__", f"{MED_GAP:.0f}"),
                 ("__THR__", str(THR)), ("__DUR__", f"{DUR:.3f}"),
                 ("__VSTYLE__", VSTYLE), ("__WSTYLE__", WSTYLE), ("__MAGX__", MAGX)):
    html = html.replace(key, val)
with open(os.path.join(OUT, "index.html"), "w", encoding="utf-8") as fh:
    fh.write(html)

print("wrote", os.path.join(OUT, "index.html"))
print("video", dst_video, os.path.getsize(dst_video), "bytes")
print("frames", len(data["t"]), "pulses", len(data["pulses"]))
