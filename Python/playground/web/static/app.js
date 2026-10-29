/* Ball Vision Playground — algorithm-level preview + annotation.
   No FPGA connection: the backend decodes the sample MP4 and runs the
   fixed-point detector. */

const W = 1280, H = 720;
const $ = (id) => document.getElementById(id);

const S = {
  clips: [], clip: null, index: 0, total: 0, fps: 60,
  meta: null, params: {}, playing: false, timer: null,
  procView: "score",
  anno: { frames: {} }, annoLoadedFor: null,
  calib: { line: null, ball: null, temp: [], tool: null, known_mm: 40, px_per_mm: null, ball_px: null },
  dense: { clip: null, list: [], pos: 0 },
  modal: { open: false, mode: null, selected: null, drag: null, temp: null, forceNew: false, addCenter: false, move: null },
  saveTimer: null,
};

async function api(path, opts = {}) {
  const r = await fetch(path, {
    headers: { "Content-Type": "application/json" },
    ...opts,
  });
  if (!r.ok) throw new Error(`${r.status} ${await r.text()}`);
  return r.json();
}

function pct(v) { return `${Math.round(v * 100)}%`; }

async function init() {
  const data = await api("/api/clips");
  S.clips = data.clips;
  S.params = data.params;
  const sel = $("clip");
  sel.innerHTML = "";
  for (const c of S.clips) {
    const o = document.createElement("option");
    o.value = c.stem;
    o.textContent = `${c.name}  (${c.frames}f @ ${c.fps.toFixed(0)}fps)`;
    sel.appendChild(o);
  }
  if (!S.clips.length) throw new Error("Python/sample 下没有 mp4");
  S.clip = S.clips[0].stem;
  sel.value = S.clip;
  fillParams();
  await loadCalibration();
  await loadAnnotations();
  await goto(0);
  bind();
}

function bind() {
  $("clip").addEventListener("change", async (e) => {
    S.clip = e.target.value;
    S.index = 0;
    await loadCalibration();
    await loadAnnotations();
    await goto(0);
  });
  $("play").addEventListener("click", togglePlay);
  $("prev").addEventListener("click", () => { pause(); goto(S.index - 1); });
  $("next").addEventListener("click", () => { pause(); goto(S.index + 1); });
  $("seek").addEventListener("input", (e) => { pause(); goto(parseInt(e.target.value, 10)); });
  $("apply").addEventListener("click", applyParams);
  $("proc-view").addEventListener("change", (e) => {
    S.procView = e.target.value;
    refreshFullView();
  });
  $("proc-open").addEventListener("click", () => {
    const src = $("img-proc-full").src;
    if (src) window.open(src, "_blank");
  });
  $("anno-open").addEventListener("click", openAnno);
  $("anno-next").addEventListener("click", nextUnannotated);
  $("anno-dense").addEventListener("click", denseFrames);
  $("calib-open").addEventListener("click", openCalib);
  $("modal-close").addEventListener("click", closeModal);
  $("modal-prev").addEventListener("click", () => { pause(); goto(S.index - 1); });
  $("modal-next").addEventListener("click", () => { pause(); goto(S.index + 1); });
  $("modal-canvas").addEventListener("pointerdown", canvasDown);
  $("modal-canvas").addEventListener("pointermove", canvasMove);
  window.addEventListener("pointerup", canvasUp);
  $("modal-canvas").addEventListener("pointercancel", canvasUp);
  document.addEventListener("keydown", (e) => {
    if (!S.modal.open) return;
    if (e.key === "ArrowLeft") { pause(); goto(S.index - 1); }
    else if (e.key === "ArrowRight") { pause(); goto(S.index + 1); }
    else if ((e.key === "Delete" || e.key === "Backspace") && S.modal.mode === "anno") {
      deleteSelected();
    }
  });
  $("img-orig").addEventListener("load", () => { if (S.modal.open) drawModal(); });
}

function fillParams() {
  const p = S.params;
  $("p-mode").value = p.mode;
  $("p-diameter").value = p.ball_diameter_px;
  $("p-usebg").checked = !!p.use_bg;
  $("p-bgthr").value = p.bg_thr;
  $("p-bright").value = p.bright_thr;
  $("p-darkwin").value = p.dark_win;
  $("p-darkthr").value = p.dark_thr;
  $("p-tgate").value = p.track_gate_px;
  $("p-ox").value = p.offset_x_px;
  $("p-oy").value = p.offset_y_px;
}

async function applyParams() {
  const body = {
    mode: $("p-mode").value,
    ball_diameter_px: parseInt($("p-diameter").value, 10),
    use_bg: $("p-usebg").checked,
    bg_thr: parseInt($("p-bgthr").value, 10),
    bright_thr: parseInt($("p-bright").value, 10),
    dark_win: parseInt($("p-darkwin").value, 10),
    dark_thr: parseInt($("p-darkthr").value, 10),
    track_gate_px: parseInt($("p-tgate").value, 10),
    offset_x_px: parseInt($("p-ox").value, 10),
    offset_y_px: parseInt($("p-oy").value, 10),
  };
  S.params = await api("/api/params", { method: "POST", body: JSON.stringify(body) });
  fillParams();
  await goto(S.index);
}

async function goto(i) {
  i = Math.max(0, Math.min((S.total || 1) - 1, i));
  const m = await api(`/api/frame?clip=${encodeURIComponent(S.clip)}&index=${i}`);
  S.meta = m;
  S.index = m.index;
  S.total = m.total;
  S.fps = m.fps;
  const tag = `&r=${Date.now()}`;
  $("img-orig").src = m.images.orig + tag;
  $("img-proc").src = m.images.proc + tag;
  $("img-proc-full").src = (m.images[S.procView] || m.images.score) + tag;
  $("img-osd").src = m.images.osd + tag;
  render();
  if (S.modal.open) drawModal();
}

function refreshFullView() {
  if (!S.meta) return;
  const url = S.meta.images[S.procView];
  if (url) $("img-proc-full").src = `${url}&r=${Date.now()}`;
}

function render() {
  const m = S.meta;
  if (!m) return;
  $("framelabel").textContent = `${m.index} / ${m.total - 1}`;
  $("seek").max = m.total - 1;
  $("seek").value = m.index;
  $("countbadge").textContent = `COUNT ${m.count}`;
  $("s-mode").textContent = m.mode;
  $("s-mean").textContent = m.frame_mean;
  $("s-det").textContent = m.detections.length;
  $("s-trk").textContent = m.tracks.filter((t) => t.visible).length;
  $("s-mask").textContent = m.mask_pixels ?? "-";
  $("s-score").textContent = `${m.score_mean ?? "-"} / ${m.score_max ?? "-"}`;
  $("s-count").textContent = m.count;
  $("proc-view").value = S.procView;
  $("s-gate").textContent = `${Math.round(m.width * m.params.gate_x_ratio)} px`;
  $("s-reset").textContent = m.reset ? "跳帧：跟踪与计数已重置" : "";
  $("clipinfo").textContent = `${m.width}×${m.height} @ ${m.fps.toFixed(0)}fps`;
  const ev = $("events");
  ev.innerHTML = "";
  for (const e of (m.events || []).slice(-10).reverse()) {
    const d = document.createElement("div");
    d.textContent = `f${e.frame}  #${e.track_id}  (${e.cx},${e.cy})  → ${e.count_after}`;
    ev.appendChild(d);
  }
  $("calib-info").textContent = S.calib.px_per_mm
    ? `${S.calib.px_per_mm.toFixed(2)} px/mm · D=${S.calib.ball_px?.toFixed(1) ?? "-"} px`
    : "未标定";
}

function pause() {
  S.playing = false;
  $("play").textContent = "▶";
  if (S.timer) { clearTimeout(S.timer); S.timer = null; }
}

function togglePlay() {
  if (S.playing) { pause(); return; }
  if (S.modal.open) return;
  S.playing = true;
  $("play").textContent = "❚❚";
  loop();
}

async function loop() {
  if (!S.playing) return;
  if (S.index >= S.total - 1) { pause(); return; }
  const t0 = performance.now();
  try { await goto(S.index + 1); }
  catch (e) { console.error(e); pause(); return; }
  const dt = performance.now() - t0;
  S.timer = setTimeout(loop, Math.max(0, 33 - dt));
}

/* ---------------- annotations ---------------- */

async function loadAnnotations() {
  S.anno = await api(`/api/annotations?clip=${encodeURIComponent(S.clip)}`);
  if (!S.anno.frames) S.anno.frames = {};
  S.annoLoadedFor = S.clip;
}

async function saveAnnotations() {
  S.anno.clip = S.clip;
  S.anno.width = W;
  S.anno.height = H;
  await api("/api/annotations", { method: "POST", body: JSON.stringify(S.anno) });
}

function scheduleSave() {
  clearTimeout(S.saveTimer);
  S.saveTimer = setTimeout(() => saveAnnotations().catch(console.error), 350);
}

function frameAnno() {
  const key = String(S.index);
  if (!S.anno.frames[key]) S.anno.frames[key] = { balls: [] };
  if (!S.anno.frames[key].balls) S.anno.frames[key].balls = [];
  return S.anno.frames[key].balls;
}

function ballCount(balls) {
  return (balls || []).reduce((s, b) => s + Math.max(1, (b.centers || []).length), 0);
}

function nextBallId() {
  let mx = 0;
  for (const f of Object.values(S.anno.frames)) {
    for (const b of (f.balls || [])) mx = Math.max(mx, b.id || 0);
  }
  return mx + 1;
}

async function nextUnannotated() {
  pause();
  for (let k = 1; k <= S.total; k++) {
    const idx = (S.index + k) % S.total;
    const f = S.anno.frames[String(idx)];
    if (!f || !f.balls || ballCount(f.balls) === 0) {
      await goto(idx);
      if (S.modal.open) drawModal();
      return;
    }
  }
}

async function denseFrames() {
  pause();
  try {
    const r = await api(`/api/scan?clip=${encodeURIComponent(S.clip)}`);
    if (r.missing || !r.top.length) {
      $("anno-status").textContent = "无 scan 结果：先运行 tools/scan_clip.py";
      return;
    }
    if (S.dense.clip !== S.clip) {
      S.dense = { clip: S.clip, list: r.top.map((x) => x.i), pos: 0 };
    }
    const idx = S.dense.list[S.dense.pos % S.dense.list.length];
    S.dense.pos += 1;
    await goto(idx);
    if (S.modal.open) drawModal();
    $("anno-status").textContent =
      `密集候选 ${S.dense.pos}/${S.dense.list.length}（scan 共 ${r.frames} 帧）`;
  } catch (e) {
    console.error(e);
    $("anno-status").textContent = "scan 读取失败";
  }
}

/* ---------------- modal / canvas ---------------- */

function openModal(mode, title) {
  pause();
  S.modal.open = true;
  S.modal.mode = mode;
  S.modal.selected = null;
  S.modal.drag = null;
  S.modal.temp = null;
  S.modal.forceNew = false;
  S.modal.addCenter = false;
  S.modal.move = null;
  $("modal").classList.remove("hidden");
  $("modal-title").textContent = title;
  setModalTools();
  drawModal();
}

function closeModal() {
  if (S.modal.mode === "anno") saveAnnotations().catch(console.error);
  S.modal.open = false;
  $("modal").classList.add("hidden");
}

function setModalTools() {
  const box = $("modal-tools");
  box.innerHTML = "";
  const add = (label, fn) => {
    const b = document.createElement("button");
    b.textContent = label;
    b.addEventListener("click", fn);
    box.appendChild(b);
    return b;
  };
  if (S.modal.mode === "anno") {
    add("保存标注", () => saveAnnotations().then(() => { $("modal-status").textContent = "已保存"; }));
    add("新建框", () => {
      S.modal.forceNew = true;
      S.modal.addCenter = false;
      $("modal-status").textContent = "拖动画一个新框（Shift+拖动同样可强制新建）";
    });
    add("加点", () => {
      if (!S.modal.selected) { $("modal-status").textContent = "先点选一个框，再加球心"; return; }
      S.modal.addCenter = true;
      S.modal.forceNew = false;
      $("modal-status").textContent = "点击选中框内部添加球心（用于一条拖影里有多颗球）";
    });
    add("删除选中", deleteSelected);
    add("下一未标注", nextUnannotated);
    $("modal-status").textContent = "拖动鼠标框住整条拖影；绿色为算法 proposal";
  } else {
    const sel = document.createElement("select");
    sel.innerHTML = "<option value='40'>滑道宽度 40 mm（完全入镜）</option><option value='10'>钢球直径 10 mm</option><option value='160'>滑道长度 160 mm（未完全入镜，不建议）</option>";
    sel.value = String(S.calib.known_mm);
    sel.addEventListener("change", () => { S.calib.known_mm = parseFloat(sel.value); });
    box.appendChild(sel);
    add("画已知长度", () => { S.calib.tool = "line"; S.calib.temp = []; $("modal-status").textContent = "点击两个端点"; });
    add("画球轮廓", () => { S.calib.tool = "ball"; $("modal-status").textContent = "拖动画出静止球轮廓"; });
    add("清除", () => { S.calib.line = null; S.calib.ball = null; S.calib.temp = []; S.calib.px_per_mm = null; S.calib.ball_px = null; drawModal(); });
    add("保存标定", saveCalibration);
    $("modal-status").textContent = "用已知尺寸标定 px/mm；球径 = 10mm × px/mm";
  }
}

function openAnno() {
  if (S.annoLoadedFor !== S.clip) loadAnnotations().then(() => openModal("anno", `标注 · frame ${S.index}`));
  else openModal("anno", `标注 · frame ${S.index}`);
}

function openCalib() {
  openModal("calib", `标定 · frame ${S.index}`);
}

function canvasPoint(e) {
  const c = $("modal-canvas");
  const r = c.getBoundingClientRect();
  return [
    Math.max(0, Math.min(W, (e.clientX - r.left) * W / r.width)),
    Math.max(0, Math.min(H, (e.clientY - r.top) * H / r.height)),
  ];
}

function canvasDown(e) {
  const [x, y] = canvasPoint(e);
  if (S.modal.mode === "anno") {
    if (S.modal.addCenter && S.modal.selected) {
      const [x0, y0, x1, y1] = S.modal.selected.box;
      if (x >= x0 && x <= x1 && y >= y0 && y <= y1) {
        if (!S.modal.selected.centers) S.modal.selected.centers = [];
        S.modal.selected.centers.push([Math.round(x), Math.round(y)]);
        S.modal.addCenter = false;
        scheduleSave();
        drawModal();
      } else {
        $("modal-status").textContent = "新球心必须点在选中框内部";
      }
      return;
    }
    const force = S.modal.forceNew || e.shiftKey;
    const hit = force ? null : hitBall(x, y);
    if (hit) {
      if (S.modal.selected === hit) {
        S.modal.move = {
          sx: x, sy: y,
          box: [...hit.box],
          centers: (hit.centers || []).map((c) => [...c]),
        };
      } else {
        S.modal.selected = hit;
        drawModal();
      }
      return;
    }
    S.modal.selected = null;
    S.modal.forceNew = false;
    S.modal.move = null;
    S.modal.drag = { x0: x, y0: y, x1: x, y1: y };
  } else if (S.calib.tool === "line") {
    S.calib.temp.push([x, y]);
    if (S.calib.temp.length >= 2) {
      S.calib.line = [S.calib.temp[0], S.calib.temp[1]];
      S.calib.temp = [];
      computeCalibration();
    }
    drawModal();
  } else if (S.calib.tool === "ball") {
    S.modal.drag = { x0: x, y0: y, x1: x, y1: y };
  }
}

function canvasMove(e) {
  const [x, y] = canvasPoint(e);
  if (S.modal.move) {
    const m = S.modal.move;
    const dx = Math.round(x - m.sx);
    const dy = Math.round(y - m.sy);
    const b = S.modal.selected;
    if (!b) return;
    b.box = [m.box[0] + dx, m.box[1] + dy, m.box[2] + dx, m.box[3] + dy];
    b.cx = (b.box[0] + b.box[2]) / 2;
    b.cy = (b.box[1] + b.box[3]) / 2;
    b.centers = (m.centers || []).map((c) => [c[0] + dx, c[1] + dy]);
    drawModal();
    return;
  }
  if (!S.modal.drag) return;
  S.modal.drag.x1 = x;
  S.modal.drag.y1 = y;
  drawModal();
}

function canvasUp() {
  if (S.modal.move) {
    S.modal.move = null;
    scheduleSave();
    drawModal();
    return;
  }
  if (!S.modal.drag) return;
  const d = S.modal.drag;
  const box = normBox(d.x0, d.y0, d.x1, d.y1);
  if (box[2] - box[0] > 6 && box[3] - box[1] > 6) {
    if (S.modal.mode === "anno") {
      const cx = (box[0] + box[2]) / 2, cy = (box[1] + box[3]) / 2;
      const balls = frameAnno();
      const b = { id: nextBallId(), box, cx, cy, centers: [], kind: "trail" };
      balls.push(b);
      S.modal.selected = b;
      scheduleSave();
    } else if (S.calib.tool === "ball") {
      S.calib.ball = box;
      computeCalibration();
    }
  }
  S.modal.drag = null;
  drawModal();
}

function normBox(x0, y0, x1, y1) {
  return [Math.min(x0, x1), Math.min(y0, y1), Math.max(x0, x1), Math.max(y0, y1)].map(Math.round);
}

function hitBall(x, y) {
  const balls = frameAnno();
  for (let i = balls.length - 1; i >= 0; i--) {
    const [x0, y0, x1, y1] = balls[i].box;
    if (x >= x0 && x <= x1 && y >= y0 && y <= y1) return balls[i];
  }
  return null;
}

function deleteSelected() {
  if (!S.modal.selected) return;
  const balls = frameAnno();
  S.anno.frames[String(S.index)].balls = balls.filter((b) => b !== S.modal.selected);
  S.modal.selected = null;
  scheduleSave();
  drawModal();
}

function drawModal() {
  const c = $("modal-canvas");
  const ctx = c.getContext("2d");
  ctx.clearRect(0, 0, W, H);
  const img = $("img-orig");
  if (img.complete && img.naturalWidth) ctx.drawImage(img, 0, 0, W, H);
  else { ctx.fillStyle = "#111"; ctx.fillRect(0, 0, W, H); }

  ctx.lineWidth = 2;
  ctx.font = "16px Consolas, monospace";
  ctx.textBaseline = "bottom";

  if (S.modal.mode === "anno") {
    // algorithm proposals (only moving/confirmed tracks; static scratches stay hidden)
    if (S.meta) {
      ctx.setLineDash([6, 5]);
      ctx.strokeStyle = "#49d17c";
      for (const d of S.meta.tracks.filter((t) => t.visible)) {
        const [x0, y0, x1, y1] = d.box;
        ctx.strokeRect(x0, y0, x1 - x0, y1 - y0);
      }
      ctx.setLineDash([]);
    }
    // user boxes
    for (const b of frameAnno()) {
      const [x0, y0, x1, y1] = b.box;
      const sel = b === S.modal.selected;
      ctx.strokeStyle = sel ? "#ff5d5d" : "#ffd166";
      ctx.lineWidth = sel ? 4 : 3;
      ctx.strokeRect(x0, y0, x1 - x0, y1 - y0);
      ctx.fillStyle = ctx.strokeStyle;
      ctx.fillText(`#${b.id}`, x0 + 4, Math.max(18, y0 - 4));
      const centres = (b.centers && b.centers.length) ? b.centers : [[b.cx, b.cy]];
      for (const [px, py] of centres) {
        ctx.beginPath();
        ctx.arc(px, py, 4, 0, Math.PI * 2);
        ctx.fill();
        ctx.setLineDash([4, 6]);
        ctx.strokeStyle = "#5ad7ff";
        ctx.beginPath();
        ctx.arc(px, py, (S.params.ball_diameter_px || 171) / 2, 0, Math.PI * 2);
        ctx.stroke();
        ctx.setLineDash([]);
      }
    }
    if (S.modal.drag) {
      const [x0, y0, x1, y1] = normBox(S.modal.drag.x0, S.modal.drag.y0, S.modal.drag.x1, S.modal.drag.y1);
      ctx.strokeStyle = "#ffd166";
      ctx.lineWidth = 2;
      ctx.strokeRect(x0, y0, x1 - x0, y1 - y0);
    }
    $("modal-title").textContent = `标注 · frame ${S.index}`;
    $("modal-status").textContent =
      `frame ${S.index} · 标注 ${ballCount(frameAnno())} 球 · 算法 ${S.meta ? S.meta.tracks.filter((t) => t.visible).length : 0}`;
  } else {
    // calibration
    if (S.calib.line) {
      ctx.strokeStyle = "#ff9f43";
      ctx.lineWidth = 3;
      ctx.beginPath();
      ctx.moveTo(...S.calib.line[0]);
      ctx.lineTo(...S.calib.line[1]);
      ctx.stroke();
      const len = Math.hypot(S.calib.line[1][0] - S.calib.line[0][0], S.calib.line[1][1] - S.calib.line[0][1]);
      ctx.fillStyle = "#ff9f43";
      ctx.fillText(`${len.toFixed(1)} px`, S.calib.line[0][0] + 6, S.calib.line[0][1] - 6);
    }
    for (const p of S.calib.temp) {
      ctx.fillStyle = "#ffd166";
      ctx.beginPath(); ctx.arc(p[0], p[1], 5, 0, Math.PI * 2); ctx.fill();
    }
    if (S.calib.ball) {
      const [x0, y0, x1, y1] = S.calib.ball;
      ctx.strokeStyle = "#5ad7ff";
      ctx.lineWidth = 3;
      ctx.strokeRect(x0, y0, x1 - x0, y1 - y0);
    }
    if (S.modal.drag) {
      const [x0, y0, x1, y1] = normBox(S.modal.drag.x0, S.modal.drag.y0, S.modal.drag.x1, S.modal.drag.y1);
      ctx.strokeStyle = "#5ad7ff";
      ctx.lineWidth = 2;
      ctx.strokeRect(x0, y0, x1 - x0, y1 - y0);
    }
    $("modal-title").textContent = `标定 · frame ${S.index}`;
    $("modal-status").textContent =
      S.calib.px_per_mm ? `${S.calib.px_per_mm.toFixed(3)} px/mm · D=${S.calib.ball_px.toFixed(1)} px` : "先画已知长度";
  }
}

function computeCalibration() {
  if (!S.calib.line) return;
  const [a, b] = S.calib.line;
  const px = Math.hypot(b[0] - a[0], b[1] - a[1]);
  S.calib.px_per_mm = px / S.calib.known_mm;
  S.calib.ball_px = 10 * S.calib.px_per_mm;
  if (S.calib.ball) {
    const [x0, y0, x1, y1] = S.calib.ball;
    S.calib.ball_px = Math.min(x1 - x0, y1 - y0);
  }
  render();
}

async function saveCalibration() {
  if (!S.calib.px_per_mm) { $("modal-status").textContent = "请先画已知长度"; return; }
  const data = {
    clip: S.clip,
    known_mm: S.calib.known_mm,
    line: S.calib.line,
    ball_box: S.calib.ball,
    px_per_mm: S.calib.px_per_mm,
    ball_diameter_px: S.calib.ball_px,
  };
  await api("/api/calibration", { method: "POST", body: JSON.stringify(data) });
  S.params = await api("/api/params", {
    method: "POST",
    body: JSON.stringify({ ball_diameter_px: Math.round(S.calib.ball_px) }),
  });
  fillParams();
  $("modal-status").textContent = "标定已保存";
  await goto(S.index);
}

async function loadCalibration() {
  const c = await api("/api/calibration");
  if (c && c.px_per_mm) {
    S.calib.px_per_mm = c.px_per_mm;
    S.calib.ball_px = c.ball_diameter_px;
    S.calib.known_mm = c.known_mm || 40;
    S.calib.line = c.line || null;
    S.calib.ball = c.ball_box || null;
  } else {
    S.calib.px_per_mm = null;
    S.calib.ball_px = null;
  }
}

init().catch((e) => {
  console.error(e);
  document.body.insertAdjacentHTML("afterbegin",
    `<pre style="color:#ff5d5d;padding:12px;white-space:pre-wrap">初始化失败：${e}</pre>`);
});
