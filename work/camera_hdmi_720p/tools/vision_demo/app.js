/* Vision Parameter Lab — interactive mirror of camera_hdmi_720p VISION_PARAMS.
 * 320x180 binned domain, run extraction, run-based CCL, filters, merge, tracking, gate.
 */
(() => {
  'use strict';

  const W = 320;
  const H = 180;
  const SCALE = 3;
  const MAX_RUNS = 1024;
  const MAX_LABELS = 96;
  const MAX_PREV = 160;
  const MAX_DET = 8;
  const MAX_TRK = 8;
  const BG_DARK = 100;

  const DEFAULTS = {
    enable: 1,
    bg_thr: 30,
    min_run: 2,
    bg_capture_delay: 120,
    bg_settle_frames: 10,
    min_area: 100,
    max_area: 1500,
    min_w: 18,
    max_w: 100,
    min_h: 5,
    max_h: 50,
    min_fill: 0,
    min_ratio: 0,
    edge_margin: 0,
    merge_dist: 34,
    max_run_len: 200,
    box_w_small: 43,
    gate_x: 96,
    gate_y0: 14,
    gate_y1: 166,
    roi_y1: 166,
    track_gate: 55,
    max_miss: 5,
    min_hits: 2,
    min_move: 9,
    min_window: 21,
    vx_max: -1,
    static_max_age: 30,
    sensorNoise: 2,
    ballG: 210,
  };

  const PARAM_INFO = {
    enable: { label: '总开关', unit: '', desc: '关闭后不跑 run / CCL / 跟踪，只显示相机画面。', try: '关掉再打开，观察算法层全部消失/恢复。' },
    bg_thr: { label: '背景差分阈值', unit: '', desc: '|G - bg| ≥ bg_thr 才算前景。增大只保留高亮球，噪声减少；减小更敏感，但噪声/边缘更容易进入。', try: '30 → 80：球会缩小甚至断裂；30 → 10：噪声明显增多。' },
    min_run: { label: '最小 run 长度', unit: 'px', desc: '一行内连续前景短于该值的 run 丢弃。用于去掉孤立噪声。', try: '0 → 5：小碎点消失；过大会切掉远距离小球。' },
    roi_y1: { label: 'ROI 底边 y', unit: 'px', desc: '只处理 y ≤ roi_y1 的行；下方球堆不进入 run/CCL。', try: '166 → 180：底部球堆进入 CCL，容易标签溢出；166 → 120：只保留上半场。' },
    max_run_len: { label: '最大 run 长度', unit: 'px', desc: '单行 run 长于该值丢弃。用于防止底部球堆/长条形成巨大连通域。', try: '200 → 60：长条和球堆被切掉；0 = 不限制。' },
    min_area: { label: '最小面积', unit: 'px²', desc: 'CCL 面积下限（320×180 小图像素）。', try: '100 → 300：小球/碎片被拒绝。' },
    max_area: { label: '最大面积', unit: 'px²', desc: 'CCL 面积上限。', try: '1500 → 500：近处大球被拒绝；1500 → 5000：允许更大球。' },
    min_w: { label: '最小宽度', unit: 'px', desc: 'bbox 宽度下限（小图像素）。', try: '18 → 30：窄碎片被拒绝。' },
    max_w: { label: '最大宽度', unit: 'px', desc: 'bbox 宽度上限。', try: '100 → 50：宽条/多球粘连被拒绝。' },
    min_h: { label: '最小高度', unit: 'px', desc: 'bbox 高度下限。', try: '5 → 10：扁噪声被拒绝。' },
    max_h: { label: '最大高度', unit: 'px', desc: 'bbox 高度上限。', try: '50 → 30：高瘦干扰被拒绝。' },
    min_fill: { label: '最小填充率', unit: '%', desc: '面积 / bbox 面积 × 100。圆球约 70-80%；0 = 不检查。', try: '0 → 60：细长/空心干扰被拒绝。' },
    min_ratio: { label: '最小长短比', unit: '%', desc: '短边 / 长边 × 100。圆球接近 100；细长干扰低；0 = 不检查。', try: '0 → 70：细长噪声被拒绝。' },
    edge_margin: { label: '边缘剔除', unit: 'px', desc: 'bbox 距画面边缘小于该值则剔除；0 = 不检查。', try: '0 → 20：贴边球/碎片被拒绝。' },
    merge_dist: { label: '碎块合并半径', unit: 'px', desc: '两个检测质心距离小于该值时合并。用于把被高光切开的球拼回一个。', try: '0：分离球/高光碎片各算一个；34：合并；80：相邻球可能被误并。' },
    box_w_small: { label: '轨迹框边长', unit: 'px', desc: '轨迹显示框边长（小图像素），约球直径 43；只影响显示，不影响计数。', try: '43 → 20/70 观察框与球的关系。' },
    gate_x: { label: '门线 x', unit: 'px', desc: '轨迹从 old_cx > gate_x 到 cx ≤ gate_x 且可见时计数。', try: '96 → 160：球更晚计数；96 → 40：更早计数。' },
    gate_y0: { label: '门线 y 下限', unit: 'px', desc: '穿越点的 y 必须 ≥ gate_y0。', try: '14 → 60：只统计中上部球。' },
    gate_y1: { label: '门线 y 上限', unit: 'px', desc: '穿越点的 y 必须 ≤ gate_y1。', try: '166 → 100：底部球不计数。' },
    track_gate: { label: '跟踪关联半径', unit: 'px', desc: '检测与轨迹预测点的欧氏距离门限。增大更容易关联，但可能串球；减小容易断轨。', try: '55 → 20：快速球易断；55 → 150：相邻球可能被错误关联。' },
    max_miss: { label: '最大丢失帧数', unit: '帧', desc: '轨迹连续丢失超过该帧数后删除。增大可跨遮挡，减小更快清理。', try: '5 → 1：短暂漏检就删；5 → 20：遮挡后更容易接上。' },
    min_hits: { label: '最少命中次数', unit: '次', desc: '轨迹至少命中多少次才 visible/可计数。', try: '2 → 5：新球更晚显示/计数。' },
    min_move: { label: '最小总位移', unit: 'px', desc: '从起始点的最大 x/y 位移达到该值才可见。用于排除静止反光。', try: '9 → 30：缓慢球不计数；9 → 2：微小漂移也计数。' },
    min_window: { label: '最小窗口位移', unit: 'px', desc: '最近 5 帧位移 ≥ 该值（向左）才可见。用于抑制缓慢漂移。', try: '21 → 5：慢球也计数；21 → 40：只有快速球计数。' },
    vx_max: { label: '左向速度门限', unit: 'px/帧', desc: '要求 vx ≤ vx_max（负数）。0 会禁止所有计数。', try: '-1 → -0.5：更快才计数；-1 → -5：几乎不计数。' },
    static_max_age: { label: '静止轨迹寿命', unit: '帧', desc: '轨迹存活超过该帧且总位移/窗口位移都小，则删除。', try: '30 → 5：静止球很快消失；30 → 200：长期保留。' },
    bg_capture_delay: { label: '背景采集等待', unit: '帧', desc: '启动后等待多少帧再采背景；只影响启动时序，逐帧演示不模拟。', try: '数值不影响画面，仅说明固件启动流程。' },
    bg_settle_frames: { label: '采背景前稳定帧', unit: '帧', desc: '采背景前清空流水线的帧数；只影响启动时序。', try: '数值不影响画面，仅说明固件启动流程。' },
    sensorNoise: { label: '传感器噪声', unit: '', desc: '给相机图像加的随机噪声幅度；用于测试 bg_thr/min_run/面积筛选。', try: '0 → 20：配合 bg_thr=30 观察噪声 run。' },
    ballG: { label: '球亮度 G', unit: '', desc: '球的灰度；背景约 100。球 210 与背景差约 110。', try: '210 → 120：差变小，降低 bg_thr 才能看到。' },
  };

  const GROUPS = [
    { id: 'front', title: '前端 / run 提取', open: true, keys: ['enable', 'bg_thr', 'min_run', 'roi_y1', 'max_run_len'] },
    { id: 'filter', title: 'Blob 筛选', open: true, keys: ['min_area', 'max_area', 'min_w', 'max_w', 'min_h', 'max_h', 'min_fill', 'min_ratio', 'edge_margin'] },
    { id: 'merge', title: '碎块合并', open: true, keys: ['merge_dist'] },
    { id: 'geometry', title: '几何 / 门线', open: true, keys: ['box_w_small', 'gate_x', 'gate_y0', 'gate_y1'] },
    { id: 'tracking', title: '跟踪 / 计数', open: true, keys: ['track_gate', 'max_miss', 'min_hits', 'min_move', 'min_window', 'vx_max', 'static_max_age'] },
    { id: 'startup', title: '启动时序（说明）', open: false, keys: ['bg_capture_delay', 'bg_settle_frames'] },
    { id: 'scene', title: '场景（非 VISION_PARAMS）', open: false, keys: ['sensorNoise', 'ballG'] },
  ];

  const STRUCTURAL = [
    ['MAX_RUNS', String(MAX_RUNS), '整帧 run_mem 深度；超过则 run_overflow'],
    ['MAX_PREV', String(MAX_PREV), '单行 CCL 工作区；320 宽理论最大 160'],
    ['MAX_LABELS', String(MAX_LABELS), '连通域标号上限；超过则 ccl_overflow'],
    ['MAX_DET', String(MAX_DET), '每帧参与跟踪的检测数'],
    ['MAX_TRK', String(MAX_TRK), '同时存在的轨迹数'],
    ['BALL_W × BALL_H', '320 × 180', '4×4 灰度平均后的小图'],
  ];

  const SPEC = {
    enable: { type: 'bool' },
    bg_thr: { min: 0, max: 255, step: 1 },
    min_run: { min: 0, max: 30, step: 1 },
    roi_y1: { min: 0, max: 180, step: 1 },
    max_run_len: { min: 0, max: 320, step: 1 },
    min_area: { min: 0, max: 2000, step: 1 },
    max_area: { min: 0, max: 5000, step: 10 },
    min_w: { min: 0, max: 160, step: 1 },
    max_w: { min: 0, max: 320, step: 1 },
    min_h: { min: 0, max: 90, step: 1 },
    max_h: { min: 0, max: 180, step: 1 },
    min_fill: { min: 0, max: 100, step: 1 },
    min_ratio: { min: 0, max: 100, step: 1 },
    edge_margin: { min: 0, max: 80, step: 1 },
    merge_dist: { min: 0, max: 120, step: 1 },
    box_w_small: { min: 4, max: 100, step: 1 },
    gate_x: { min: 0, max: 320, step: 1 },
    gate_y0: { min: 0, max: 180, step: 1 },
    gate_y1: { min: 0, max: 180, step: 1 },
    track_gate: { min: 1, max: 181, step: 1 },
    max_miss: { min: 0, max: 30, step: 1 },
    min_hits: { min: 1, max: 20, step: 1 },
    min_move: { min: 0, max: 100, step: 1 },
    min_window: { min: 0, max: 100, step: 1 },
    vx_max: { min: -30, max: 0, step: 1 },
    static_max_age: { min: 0, max: 200, step: 1 },
    bg_capture_delay: { min: 0, max: 300, step: 1 },
    bg_settle_frames: { min: 0, max: 60, step: 1 },
    sensorNoise: { min: 0, max: 40, step: 1 },
    ballG: { min: 120, max: 255, step: 1 },
  };

  const $ = (id) => document.getElementById(id);
  const clamp = (v, a, b) => Math.min(b, Math.max(a, v));
  const int = (v) => Math.round(Number(v) || 0);
  const abs = Math.abs;

  const state = {
    params: { ...DEFAULTS },
    scenePreset: 'standard',
    seed: 20261029,
    frame: 0,
    count: 0,
    playing: true,
    fps: 15,
    live: true,
    selected: null,
    hoverBlob: null,
    balls: [],
    pile: [],
    noiseRects: [],
    longBar: null,
    bg: new Uint8Array(W * H),
    tracks: [],
    nextId: 1,
    crossFlash: [],
    result: null,
    lastTime: 0,
    acc: 0,
    focusParam: 'bg_thr',
  };

  const view = {
    camera: true,
    mask: false,
    score: false,
    runs: true,
    blobs: true,
    rejected: true,
    tracks: true,
    gate: true,
  };

  const canvas = $('view');
  const ctx = canvas.getContext('2d');
  const cam = document.createElement('canvas');
  cam.width = W;
  cam.height = H;
  const camCtx = cam.getContext('2d');
  const imageData = camCtx.createImageData(W, H);

  // ---------------- PRNG / scene ----------------
  function mulberry32(a) {
    return function () {
      a |= 0;
      a = (a + 0x6D2B79F5) | 0;
      let t = Math.imul(a ^ (a >>> 15), 1 | a);
      t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
      return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
  }

  function buildBackground(seed) {
    const rng = mulberry32(seed);
    const bg = new Uint8Array(W * H);
    for (let y = 0; y < H; y++) {
      for (let x = 0; x < W; x++) {
        const dx = (x - W / 2) / W;
        const dy = (y - H / 2) / H;
        let g = 94 + 10 * Math.sin(x * 0.045 + seed * 0.013) +
                7 * Math.cos(y * 0.09 + x * 0.011) +
                6 * rng() - 10 * (dx * dx + dy * dy);
        bg[y * W + x] = clamp(Math.round(g), 0, 255);
      }
    }
    return bg;
  }

  function makeScene(preset, seed) {
    const rng = mulberry32(seed ^ 0x9E3779B9);
    const balls = [];
    const pile = [];
    const noiseRects = [];
    let longBar = null;

    const addBall = (x, y, r, vx, vy, split) => {
      balls.push({ x, y, r, vx, vy, split: !!split, static: vx === 0 && vy === 0 });
    };

    if (preset === 'clean') {
      addBall(260, 55, 16, -6.0, 0.06, false);
      addBall(210, 105, 16, -7.0, -0.04, false);
      addBall(160, 140, 16, -5.5, 0.04, false);
    } else if (preset === 'reverse') {
      addBall(260, 55, 16, -6.5, 0.04, false);
      addBall(210, 105, 16, -7.0, -0.04, false);
      addBall(80, 75, 16, 6.0, 0.02, false);
      addBall(130, 135, 16, 5.0, -0.04, false);
    } else if (preset === 'static') {
      addBall(220, 65, 16, 0, 0, false);
      addBall(160, 120, 16, 0, 0, false);
      addBall(260, 105, 16, -6.0, 0.04, false);
    } else if (preset === 'noisy') {
      addBall(250, 60, 16, -6.5, 0.04, true);
      addBall(190, 120, 16, -5.5, -0.04, false);
      addBall(130, 80, 16, -5.0, 0.02, false);
      for (let i = 0; i < 18; i++) {
        noiseRects.push({
          x: 20 + Math.floor(rng() * 280),
          y: 15 + Math.floor(rng() * 140),
          w: 1 + Math.floor(rng() * 4),
          h: 1 + Math.floor(rng() * 3),
        });
      }
    } else {
      addBall(275, 48, 16, -6.0, 0.06, false);
      addBall(235, 92, 16, -7.0, -0.02, false);
      addBall(195, 58, 16, -5.5, 0.04, true);
      addBall(160, 132, 16, -6.5, 0.02, false);
      addBall(118, 88, 16, -8.0, -0.04, false);
      addBall(80, 45, 16, -5.0, 0.04, false);
      addBall(205, 158, 16, 0, 0, false); // static: static_max_age demo
      longBar = { x: 40, y: 100, w: 240, h: 4 };
      noiseRects.push({ x: 250, y: 30, w: 1, h: 1 });
      noiseRects.push({ x: 258, y: 40, w: 3, h: 1 });
      noiseRects.push({ x: 250, y: 50, w: 6, h: 4 });
      noiseRects.push({ x: 250, y: 70, w: 30, h: 8 });
      noiseRects.push({ x: 250, y: 120, w: 120, h: 6 });
    }

    if (preset !== 'clean' && preset !== 'static') {
      for (let i = 0; i < 7; i++) {
        pile.push({ x: 20 + i * 46, y: 184, r: 16 });
      }
    }
    if (preset === 'longbar') {
      longBar = { x: 20, y: 110, w: 280, h: 5 };
    }

    return { balls, pile, noiseRects, longBar };
  }

  function resetScene(seed) {
    state.seed = seed >>> 0;
    state.bg = buildBackground(state.seed);
    const s = makeScene(state.scenePreset, state.seed);
    state.balls = s.balls;
    state.pile = s.pile;
    state.noiseRects = s.noiseRects;
    state.longBar = s.longBar;
  }

  function advanceBalls() {
    const rng = mulberry32(state.seed ^ (state.frame * 2654435761));
    for (const b of state.balls) {
      if (b.static) continue;
      b.x += b.vx;
      b.y += b.vy;
      if (b.y < b.r) { b.y = b.r; b.vy = abs(b.vy); }
      if (b.y > H - b.r) { b.y = H - b.r; b.vy = -abs(b.vy); }
      if (b.vx < 0 && b.x < -b.r) {
        b.x = W + b.r + rng() * 20;
        b.y = 25 + rng() * 130;
      }
      if (b.vx > 0 && b.x > W + b.r) {
        b.x = -b.r - rng() * 20;
        b.y = 25 + rng() * 130;
      }
    }
  }

  function drawRectG(img, x, y, w, h, g) {
    const x0 = clamp(Math.round(x), 0, W);
    const x1 = clamp(Math.round(x + w), 0, W);
    const y0 = clamp(Math.round(y), 0, H);
    const y1 = clamp(Math.round(y + h), 0, H);
    for (let yy = y0; yy < y1; yy++) {
      for (let xx = x0; xx < x1; xx++) img[yy * W + xx] = g;
    }
  }

  function buildImage() {
    const p = state.params;
    const img = new Uint8Array(state.bg);
    const rng = mulberry32((state.seed ^ 0x51ED270B) + state.frame * 7919);
    const noise = p.sensorNoise;

    if (noise > 0) {
      for (let i = 0; i < img.length; i++) {
        img[i] = clamp(img[i] + Math.round((rng() * 2 - 1) * noise), 0, 255);
      }
    }

    for (const b of state.balls) {
      const r = b.r;
      const y0 = Math.max(0, Math.floor(b.y - r));
      const y1 = Math.min(H - 1, Math.ceil(b.y + r));
      const x0 = Math.max(0, Math.floor(b.x - r));
      const x1 = Math.min(W - 1, Math.ceil(b.x + r));
      for (let y = y0; y <= y1; y++) {
        const dy = y - b.y;
        for (let x = x0; x <= x1; x++) {
          const dx = x - b.x;
          const d2 = dx * dx + dy * dy;
          if (d2 > r * r) continue;
          let g = p.ballG - Math.round(12 * Math.sqrt(d2) / r);
          if (b.split && Math.abs(dy) <= 2.2) g = state.bg[y * W + x] + 4;
          img[y * W + x] = clamp(g, 0, 255);
        }
      }
    }

    for (const c of state.pile) {
      const y0 = Math.max(0, Math.floor(c.y - c.r));
      const y1 = Math.min(H - 1, Math.ceil(c.y + c.r));
      const x0 = Math.max(0, Math.floor(c.x - c.r));
      const x1 = Math.min(W - 1, Math.ceil(c.x + c.r));
      for (let y = y0; y <= y1; y++) {
        const dy = y - c.y;
        for (let x = x0; x <= x1; x++) {
          const dx = x - c.x;
          if (dx * dx + dy * dy <= c.r * c.r) img[y * W + x] = p.ballG;
        }
      }
    }

    if (state.longBar) {
      drawRectG(img, state.longBar.x, state.longBar.y, state.longBar.w, state.longBar.h, p.ballG);
    }
    for (const r of state.noiseRects) {
      drawRectG(img, r.x, r.y, r.w, r.h, p.ballG);
    }
    return img;
  }

  // ---------------- algorithm ----------------
  function find(parent, l) {
    let r = l;
    while (parent[r] !== r) r = parent[r];
    while (parent[l] !== l) {
      const n = parent[l];
      parent[l] = r;
      l = n;
    }
    return r;
  }

  function union(parent, a, b) {
    const ra = find(parent, a);
    const rb = find(parent, b);
    if (ra !== rb) parent[rb] = ra;
  }

  function computeStatic() {
    const p = state.params;
    const img = buildImage();
    const diff = new Uint8Array(W * H);
    const mask = new Uint8Array(W * H);
    for (let i = 0; i < img.length; i++) {
      const d = abs(img[i] - state.bg[i]);
      diff[i] = d;
      mask[i] = d >= p.bg_thr ? 1 : 0;
    }

    const runs = [];
    let skipRoi = 0;
    let skipLen = 0;
    let skipMin = 0;
    for (let y = 0; y < H; y++) {
      let x = 0;
      while (x < W) {
        while (x < W && !mask[y * W + x]) x++;
        if (x >= W) break;
        const xs = x;
        while (x < W && mask[y * W + x]) x++;
        const xe = x - 1;
        const len = xe - xs + 1;
        let reason = '';
        if (y > p.roi_y1) reason = 'roi';
        else if (p.max_run_len > 0 && len > p.max_run_len) reason = 'len';
        else if (p.min_run > 0 && len < p.min_run) reason = 'min';
        if (reason === 'roi') skipRoi++;
        else if (reason === 'len') skipLen++;
        else if (reason === 'min') skipMin++;
        runs.push({ y, xs, xe, len, reason, kept: !reason });
      }
    }

    const kept = runs.filter((r) => r.kept);
    const ccl = runCCL(kept, p);
    return { img, diff, mask, runs, skipRoi, skipLen, skipMin, ...ccl };
  }

  function runCCL(runs, p) {
    const feats = new Array(MAX_LABELS).fill(null);
    const parent = new Array(MAX_LABELS);
    for (let i = 0; i < MAX_LABELS; i++) parent[i] = i;
    let prev = [];
    let cur = [];
    let prevY = -1;
    let nextLabel = 0;
    let overflow = false;

    const newFeat = () => ({
      valid: 1, area: 0, x0: W, x1: 0, y0: H, y1: 0, sumx: 0, sumy: 0,
    });

    for (const r of runs) {
      const y = r.y;
      const xs = r.xs;
      const xe = r.xe;
      const len = r.len;
      if (y !== prevY) {
        if (y > prevY + 1) {
          prev = [];
        } else {
          prev = cur;
        }
        cur = [];
        prevY = y;
      }

      let found = -1;
      for (const pr of prev) {
        if (pr.xs <= xe && pr.xe >= xs) {
          const pl = find(parent, pr.lbl);
          if (found < 0) found = pl;
          else union(parent, found, pl);
        }
      }

      let lbl;
      if (found < 0) {
        if (nextLabel < MAX_LABELS) {
          lbl = nextLabel;
          parent[lbl] = lbl;
          feats[lbl] = newFeat();
          nextLabel++;
        } else {
          lbl = MAX_LABELS - 1;
          overflow = true;
          if (!feats[lbl]) feats[lbl] = newFeat();
        }
      } else {
        lbl = find(parent, found);
      }

      const f = feats[lbl];
      f.valid = 1;
      f.area += len;
      if (xs < f.x0) f.x0 = xs;
      if (xe > f.x1) f.x1 = xe;
      if (y < f.y0) f.y0 = y;
      if (y > f.y1) f.y1 = y;
      f.sumx += Math.floor((xs + xe) * len / 2);
      f.sumy += y * len;

      if (cur.length < MAX_PREV) {
        cur.push({ xs, xe, lbl });
      } else {
        overflow = true;
      }
    }

    if (overflow) {
      return { blobs: [], detsBefore: [], detsAfter: [], mergePairs: [], overflow: true, nextLabel };
    }

    for (let i = 0; i < nextLabel; i++) {
      if (!feats[i] || !feats[i].valid) continue;
      const root = find(parent, i);
      if (root !== i && feats[root] && feats[i]) {
        const a = feats[root];
        const b = feats[i];
        a.valid = 1;
        a.area += b.area;
        if (b.x0 < a.x0) a.x0 = b.x0;
        if (b.x1 > a.x1) a.x1 = b.x1;
        if (b.y0 < a.y0) a.y0 = b.y0;
        if (b.y1 > a.y1) a.y1 = b.y1;
        a.sumx += b.sumx;
        a.sumy += b.sumy;
        b.valid = 0;
      }
    }

    const blobs = [];
    let passCount = 0;
    for (let i = 0; i < nextLabel; i++) {
      const f = feats[i];
      if (!f || !f.valid || find(parent, i) !== i) continue;
      const area = f.area;
      const w = f.x1 - f.x0 + 1;
      const h = f.y1 - f.y0 + 1;
      const mn = Math.min(w, h);
      const mx = Math.max(w, h);
      const fill = w > 0 && h > 0 ? Math.round(area * 100 / (w * h)) : 0;
      const ratio = mx > 0 ? Math.round(mn * 100 / mx) : 0;
      let pass = true;
      let reason = 'pass';
      let reasonKey = '';
      if (area < p.min_area) { pass = false; reason = `area ${area} < min_area ${p.min_area}`; reasonKey = 'area'; }
      else if (area > p.max_area) { pass = false; reason = `area ${area} > max_area ${p.max_area}`; reasonKey = 'area'; }
      else if (w < p.min_w) { pass = false; reason = `w ${w} < min_w ${p.min_w}`; reasonKey = 'w'; }
      else if (w > p.max_w) { pass = false; reason = `w ${w} > max_w ${p.max_w}`; reasonKey = 'w'; }
      else if (h < p.min_h) { pass = false; reason = `h ${h} < min_h ${p.min_h}`; reasonKey = 'h'; }
      else if (h > p.max_h) { pass = false; reason = `h ${h} > max_h ${p.max_h}`; reasonKey = 'h'; }
      else if (p.min_fill > 0 && fill < p.min_fill) { pass = false; reason = `fill ${fill}% < ${p.min_fill}%`; reasonKey = 'fill'; }
      else if (p.min_ratio > 0 && ratio < p.min_ratio) { pass = false; reason = `ratio ${ratio}% < ${p.min_ratio}%`; reasonKey = 'ratio'; }
      else if (p.edge_margin > 0 &&
               (f.x0 < p.edge_margin || f.y0 < p.edge_margin ||
                f.x1 >= W - p.edge_margin || f.y1 >= H - p.edge_margin)) {
        pass = false; reason = `edge margin ${p.edge_margin}`; reasonKey = 'edge';
      }
      const cx = area > 0 ? Math.floor(f.sumx / area) : 0;
      const cy = area > 0 ? Math.floor(f.sumy / area) : 0;
      const blob = {
        label: i, area, x0: f.x0, y0: f.y0, x1: f.x1, y1: f.y1,
        w, h, fill, ratio, cx, cy, pass, reason, reasonKey,
      };
      if (pass) passCount++;
      blobs.push(blob);
    }

    // C insert_det_sorted: up to 8, area sorted.
    const detsBefore = [];
    for (const b of blobs) {
      if (!b.pass) continue;
      const d = { label: b.label, cx: b.cx, cy: b.cy, area: b.area };
      if (detsBefore.length < MAX_DET) {
        let k = detsBefore.length;
        while (k > 0 && detsBefore[k - 1].area < d.area) { detsBefore[k] = detsBefore[k - 1]; k--; }
        detsBefore[k] = d;
      } else if (d.area > detsBefore[MAX_DET - 1].area) {
        detsBefore[MAX_DET - 1] = d;
        let k = MAX_DET - 1;
        while (k > 0 && detsBefore[k - 1].area < detsBefore[k].area) {
          const tmp = detsBefore[k - 1];
          detsBefore[k - 1] = detsBefore[k];
          detsBefore[k] = tmp;
          k--;
        }
      }
    }

    const { detsAfter, mergePairs } = mergeDets(detsBefore, p.merge_dist);
    return { blobs, detsBefore, detsAfter, mergePairs, overflow: false, nextLabel, passCount };
  }

  function mergeDets(dets, md) {
    if (dets.length <= 1 || md <= 0) return { detsAfter: dets.slice(), mergePairs: [] };
    const sorted = dets.slice().sort((a, b) => b.area - a.area);
    const keep = [];
    const pairs = [];
    for (const d of sorted) {
      let merged = false;
      for (const k of keep) {
        const dx = d.cx - k.cx;
        const dy = d.cy - k.cy;
        if (dx * dx + dy * dy < md * md) {
          pairs.push({ ax: d.cx, ay: d.cy, bx: k.cx, by: k.cy });
          const total = k.area + d.area;
          k.cx = Math.floor((k.cx * k.area + d.cx * d.area) / total);
          k.cy = Math.floor((k.cy * k.area + d.cy * d.area) / total);
          k.area = total;
          k.mergedLabels.push(d.label);
          merged = true;
          break;
        }
      }
      if (!merged) {
        keep.push({ label: d.label, cx: d.cx, cy: d.cy, area: d.area, mergedLabels: [] });
      }
    }
    return { detsAfter: keep, mergePairs: pairs };
  }

  // ---------------- tracking ----------------
  function halfFloor(v) {
    if (v >= 0) return v >> 1;
    return -(((-v) + 1) >> 1);
  }

  function emptyTrack() {
    return {
      valid: 0, id: 0, cx: 0, cy: 0, vx: 0, vy: 0,
      prev_cx: 0, prev_cy: 0, missed: 0, hits: 0, counted: 0,
      start_cx: 0, start_cy: 0, age: 0, moved: 0, window_move: 0,
      hist: [0, 0, 0, 0, 0], hist_n: 0, visible: 0,
    };
  }

  function pushHist(t, x) {
    for (let k = 4; k > 0; k--) t.hist[k] = t.hist[k - 1];
    t.hist[0] = x;
    if (t.hist_n < 5) t.hist_n++;
    t.window_move = t.hist[0] - t.hist[t.hist_n - 1];
  }

  function trackUpdate(dets) {
    const p = state.params;
    const usedT = new Array(MAX_TRK).fill(0);
    const usedD = new Array(MAX_DET).fill(0);
    const wasValid = state.tracks.map((t) => t.valid);
    const pairs = [];
    let gate = p.track_gate;
    if (gate > 181) gate = 181;
    const gate2 = gate * gate;

    for (let i = 0; i < MAX_TRK; i++) {
      const t = state.tracks[i];
      if (t.valid) {
        t.prev_cx = t.cx;
        t.prev_cy = t.cy;
        t.cx += t.vx;
        t.cy += t.vy;
        t.age++;
      }
    }

    for (let i = 0; i < MAX_TRK; i++) {
      const t = state.tracks[i];
      if (!t.valid) continue;
      for (let j = 0; j < dets.length; j++) {
        const dx = dets[j].cx - t.cx;
        const dy = dets[j].cy - t.cy;
        const d2 = dx * dx + dy * dy;
        if (d2 <= gate2) pairs.push({ d2, ti: i, di: j });
      }
    }
    pairs.sort((a, b) => a.d2 - b.d2);

    for (const pair of pairs) {
      if (usedT[pair.ti] || usedD[pair.di]) continue;
      const t = state.tracks[pair.ti];
      const d = dets[pair.di];
      usedT[pair.ti] = 1;
      usedD[pair.di] = 1;
      const old_cx = t.prev_cx;
      const dvx = d.cx - old_cx;
      const dvy = d.cy - t.prev_cy;
      t.vx = halfFloor(t.vx + dvx);
      t.vy = halfFloor(t.vy + dvy);
      t.cx = d.cx;
      t.cy = d.cy;
      t.missed = 0;
      t.hits++;
      t.moved = abs(t.cx - t.start_cx);
      const dy0 = abs(t.cy - t.start_cy);
      if (dy0 > t.moved) t.moved = dy0;
      pushHist(t, t.cx);
      t.visible = (t.hits >= p.min_hits) &&
                  (t.missed === 0) &&
                  (t.moved >= p.min_move) &&
                  (t.window_move <= -p.min_window) &&
                  (t.vx <= p.vx_max);

      if (t.visible && !t.counted &&
          old_cx > p.gate_x && t.cx <= p.gate_x &&
          t.cy >= p.gate_y0 && t.cy <= p.gate_y1) {
        t.counted = 1;
        state.count++;
        state.crossFlash.push({ x: p.gate_x, y: t.cy, ttl: 12 });
      }
    }

    for (let j = 0; j < dets.length; j++) {
      if (usedD[j]) continue;
      for (let i = 0; i < MAX_TRK; i++) {
        const t = state.tracks[i];
        if (!t.valid) {
          const d = dets[j];
          t.valid = 1;
          t.id = state.nextId;
          state.nextId++;
          if (state.nextId > 15) state.nextId = 1;
          t.cx = d.cx; t.cy = d.cy;
          t.vx = 0; t.vy = 0;
          t.prev_cx = d.cx; t.prev_cy = d.cy;
          t.missed = 0; t.hits = 1; t.counted = 0;
          t.start_cx = d.cx; t.start_cy = d.cy;
          t.age = 1; t.moved = 0; t.window_move = 0;
          t.hist = [d.cx, 0, 0, 0, 0]; t.hist_n = 1;
          t.visible = 0;
          break;
        }
      }
    }

    for (let i = 0; i < MAX_TRK; i++) {
      if (!wasValid[i]) continue;
      const t = state.tracks[i];
      if (!usedT[i]) {
        t.missed++;
        t.visible = 0;
        t.moved = abs(t.cx - t.start_cx);
        const dy0 = abs(t.cy - t.start_cy);
        if (dy0 > t.moved) t.moved = dy0;
        pushHist(t, t.cx);
      }
      if (t.missed > p.max_miss) {
        t.valid = 0;
        t.visible = 0;
      } else if (t.age > p.static_max_age &&
                 t.moved < p.min_move &&
                 abs(t.window_move) < p.min_window) {
        t.valid = 0;
        t.visible = 0;
      }
    }
  }

  // ---------------- simulation ----------------
  function resetSim() {
    state.frame = 0;
    state.count = 0;
    state.selected = null;
    state.nextId = 1;
    state.crossFlash = [];
    state.tracks = Array.from({ length: MAX_TRK }, emptyTrack);
    resetScene(state.seed);
    processFrame(false, true);
    toast('场景与轨迹已重置');
  }

  function processFrame(advance, updateTracks) {
    if (advance) {
      state.frame++;
      advanceBalls();
      state.crossFlash = state.crossFlash.map((f) => ({ ...f, ttl: f.ttl - 1 })).filter((f) => f.ttl > 0);
    }
    const result = computeStatic();
    state.result = result;
    if (updateTracks) {
      if (state.params.enable) trackUpdate(result.detsAfter);
      else trackUpdate([]);
    }
    if (state.selected != null) {
      const found = result.blobs.find((b) => b.label === state.selected);
      if (!found) state.selected = null;
    }
    render();
    updateUI();
  }

  // ---------------- render ----------------
  function heatColor(d) {
    if (d < 10) return [10, 14, 22];
    if (d < 40) return [20, 50, 110];
    if (d < 90) return [0, 160, 200];
    if (d < 150) return [255, 210, 40];
    return [255, 60, 80];
  }

  function renderBase() {
    const r = state.result;
    const data = imageData.data;
    for (let i = 0; i < W * H; i++) {
      let cr, cg, cb;
      if (view.score) {
        const c = heatColor(r.diff[i]);
        cr = c[0]; cg = c[1]; cb = c[2];
      } else if (view.mask && !view.camera) {
        const m = r.mask[i];
        cr = m ? 30 : 8; cg = m ? 240 : 20; cb = m ? 120 : 26;
      } else {
        const g = r.img[i];
        cr = g; cg = g; cb = Math.min(255, g + 8);
        if (view.mask && r.mask[i]) {
          cr = Math.min(255, cr + 10); cg = 255; cb = Math.min(255, cb + 40);
        }
      }
      const o = i * 4;
      data[o] = cr; data[o + 1] = cg; data[o + 2] = cb; data[o + 3] = 255;
    }
    camCtx.putImageData(imageData, 0, 0);
    ctx.setTransform(SCALE, 0, 0, SCALE, 0, 0);
    ctx.clearRect(0, 0, W, H);
    ctx.imageSmoothingEnabled = false;
    ctx.drawImage(cam, 0, 0, W, H);
  }

  function label(text, x, y, color, bg) {
    ctx.font = '5px ui-monospace, Consolas, monospace';
    const w = ctx.measureText(text).width;
    if (bg !== false) {
      ctx.fillStyle = 'rgba(4,8,14,0.72)';
      ctx.fillRect(x - 1, y - 5, w + 2, 6);
    }
    ctx.fillStyle = color;
    ctx.fillText(text, x, y - 1);
  }

  function renderOverlay() {
    const p = state.params;
    const r = state.result;
    if (!r) return;

    // ROI
    if (view.gate) {
      ctx.save();
      ctx.strokeStyle = 'rgba(34,211,238,0.55)';
      ctx.lineWidth = 0.5;
      ctx.setLineDash([3, 3]);
      ctx.beginPath();
      ctx.moveTo(0, p.roi_y1 + 0.5);
      ctx.lineTo(W, p.roi_y1 + 0.5);
      ctx.stroke();
      ctx.setLineDash([]);
      ctx.fillStyle = 'rgba(34,211,238,0.045)';
      ctx.fillRect(0, p.roi_y1 + 0.5, W, H - p.roi_y1);
      label(`ROI y<=${p.roi_y1}`, 3, p.roi_y1 - 2, 'rgba(34,211,238,.85)');
      ctx.restore();

      // Gate
      ctx.save();
      ctx.strokeStyle = 'rgba(255,79,216,0.9)';
      ctx.lineWidth = 0.75;
      ctx.setLineDash([4, 2]);
      ctx.beginPath();
      ctx.moveTo(p.gate_x + 0.5, p.gate_y0);
      ctx.lineTo(p.gate_x + 0.5, p.gate_y1);
      ctx.stroke();
      ctx.setLineDash([]);
      ctx.beginPath();
      ctx.arc(p.gate_x + 0.5, p.gate_y0, 1.2, 0, Math.PI * 2);
      ctx.arc(p.gate_x + 0.5, p.gate_y1, 1.2, 0, Math.PI * 2);
      ctx.fillStyle = 'rgba(255,79,216,.9)';
      ctx.fill();
      label(`GATE x=${p.gate_x}`, p.gate_x + 2, p.gate_y0 + 6, '#ff4fd8');
      ctx.restore();
    }

    // Runs
    if (view.runs) {
      for (const run of r.runs) {
        if (!run.kept && !view.rejected) continue;
        ctx.strokeStyle = run.kept ? 'rgba(61,220,151,0.95)' : 'rgba(255,92,122,0.45)';
        ctx.lineWidth = run.kept ? 0.7 : 0.45;
        ctx.beginPath();
        ctx.moveTo(run.xs, run.y + 0.5);
        ctx.lineTo(run.xe + 1, run.y + 0.5);
        ctx.stroke();
      }
    }

    // Merge pairs
    if (view.blobs && r.mergePairs.length) {
      ctx.save();
      ctx.strokeStyle = 'rgba(34,211,238,0.55)';
      ctx.lineWidth = 0.4;
      ctx.setLineDash([2, 2]);
      for (const m of r.mergePairs) {
        ctx.beginPath();
        ctx.moveTo(m.ax, m.ay);
        ctx.lineTo(m.bx, m.by);
        ctx.stroke();
      }
      ctx.restore();
    }

    // Blobs
    if (view.blobs) {
      for (const b of r.blobs) {
        if (!b.pass && !view.rejected) continue;
        const sel = state.selected === b.label;
        ctx.save();
        ctx.strokeStyle = sel ? '#ffcf5c' : (b.pass ? 'rgba(91,140,255,0.9)' : 'rgba(255,92,122,0.65)');
        ctx.lineWidth = sel ? 1.1 : 0.55;
        ctx.setLineDash(b.pass ? [] : [2, 2]);
        ctx.strokeRect(b.x0 + 0.5, b.y0 + 0.5, b.w - 1, b.h - 1);
        ctx.setLineDash([]);
        if (sel) {
          ctx.fillStyle = 'rgba(255,207,92,0.08)';
          ctx.fillRect(b.x0, b.y0, b.w, b.h);
        }
        label(`#${b.label} A${b.area}`, b.x0 + 1, b.y0 > 6 ? b.y0 - 1 : b.y0 + 6,
              b.pass ? '#9ec0ff' : '#ff9aaa');
        ctx.restore();
      }
    }

    // Tracks
    if (view.tracks && p.enable) {
      for (const t of state.tracks) {
        if (!t.valid) continue;
        const bw = p.box_w_small;
        const x0 = t.cx - bw / 2;
        const y0 = t.cy - bw / 2;
        ctx.save();
        ctx.strokeStyle = t.visible ? 'rgba(255,207,92,0.95)' : 'rgba(130,145,170,0.55)';
        ctx.lineWidth = t.visible ? 0.8 : 0.5;
        ctx.setLineDash(t.missed ? [2, 2] : []);
        ctx.strokeRect(x0 + 0.5, y0 + 0.5, bw - 1, bw - 1);
        ctx.setLineDash([]);
        ctx.fillStyle = t.visible ? '#ffcf5c' : '#8b9bb5';
        ctx.beginPath();
        ctx.arc(t.cx, t.cy, 1, 0, Math.PI * 2);
        ctx.fill();
        label(`ID${t.id} ${t.visible ? 'VIS' : '--'} m${t.missed}`, x0 + 1, y0 > 6 ? y0 - 1 : y0 + 6,
              t.visible ? '#ffcf5c' : '#8b9bb5');
        label(`vx${t.vx} w${t.window_move}`, x0 + 1, y0 + bw + 5,
              t.visible ? '#ffcf5c' : '#8b9bb5');
        if (t.visible && p.track_gate <= 120) {
          ctx.strokeStyle = 'rgba(255,207,92,0.16)';
          ctx.beginPath();
          ctx.arc(t.cx, t.cy, p.track_gate, 0, Math.PI * 2);
          ctx.stroke();
        }
        ctx.restore();
      }
    }

    // Gate crossing flash
    for (const f of state.crossFlash) {
      const k = 1 - f.ttl / 12;
      ctx.save();
      ctx.strokeStyle = `rgba(61,220,151,${0.9 * (1 - k)})`;
      ctx.lineWidth = 0.8;
      ctx.beginPath();
      ctx.arc(f.x, f.y, 3 + k * 14, 0, Math.PI * 2);
      ctx.stroke();
      ctx.restore();
    }

    // HUD
    ctx.save();
    ctx.font = '5px ui-monospace, Consolas, monospace';
    ctx.fillStyle = 'rgba(4,8,14,0.62)';
    ctx.fillRect(2, 2, 120, 26);
    ctx.fillStyle = '#bcd0ec';
    ctx.fillText(`F ${state.frame}  COUNT ${state.count}`, 4, 8);
    ctx.fillText(`RUN ${r.runs.filter((x) => x.kept).length}/${r.runs.length}  SKIP R${r.skipRoi} L${r.skipLen} M${r.skipMin}`, 4, 14);
    ctx.fillText(`BLOB ${r.blobs.filter((b) => b.pass).length}/${r.blobs.length}  TRK ${state.tracks.filter((t) => t.valid).length}`, 4, 20);
    ctx.restore();
  }

  function render() {
    renderBase();
    renderOverlay();
  }

  // ---------------- UI ----------------
  function fmt(v) { return Number.isInteger(v) ? String(v) : String(v); }

  function buildControls() {
    const root = $('controls');
    root.innerHTML = '';
    for (const g of GROUPS) {
      const details = document.createElement('details');
      details.className = 'group';
      details.open = g.open;
      const summary = document.createElement('summary');
      summary.textContent = g.title;
      details.appendChild(summary);
      const body = document.createElement('div');
      body.className = 'group-body';
      for (const key of g.keys) body.appendChild(buildParamRow(key));
      details.appendChild(body);
      root.appendChild(details);
    }

    // structural card
    const card = document.createElement('div');
    card.className = 'info-card';
    card.innerHTML = '<h3>结构参数（只读）</h3>' +
      STRUCTURAL.map(([k, v, d]) =>
        `<div class="mini" style="line-height:1.7;margin-bottom:4px"><b style="color:#cfdaeb">${k}=${v}</b><br>${d}</div>`
      ).join('') +
      '<p class="hint" style="margin-top:6px">这些是综合期常量，改它们需要重新跑 syn_1/phy_1；不是日常调参。</p>';
    root.appendChild(card);
  }

  function buildParamRow(key) {
    const info = PARAM_INFO[key];
    const spec = SPEC[key];
    const row = document.createElement('div');
    row.className = 'param';
    row.dataset.key = key;

    if (spec.type === 'bool') {
      const lab = document.createElement('label');
      lab.className = 'pname';
      lab.textContent = info.label;
      const cb = document.createElement('input');
      cb.type = 'checkbox';
      cb.checked = !!state.params[key];
      cb.addEventListener('change', () => setParam(key, cb.checked ? 1 : 0));
      lab.prepend(cb);
      row.appendChild(lab);
    } else {
      const lab = document.createElement('label');
      const name = document.createElement('span');
      name.className = 'pname';
      name.textContent = info.label;
      name.title = info.desc;
      const unit = document.createElement('span');
      unit.className = 'unit';
      unit.textContent = info.unit || '';
      lab.appendChild(name);
      lab.appendChild(unit);
      const range = document.createElement('input');
      range.type = 'range';
      range.min = spec.min; range.max = spec.max; range.step = spec.step;
      range.value = state.params[key];
      const num = document.createElement('input');
      num.type = 'number';
      num.min = spec.min; num.max = spec.max; num.step = spec.step;
      num.value = state.params[key];
      range.addEventListener('input', () => {
        num.value = range.value;
        setParam(key, Number(range.value));
      });
      num.addEventListener('input', () => {
        const v = clamp(Number(num.value), spec.min, spec.max);
        range.value = v;
        setParam(key, v);
      });
      lab.addEventListener('mouseenter', () => showParamInfo(key));
      lab.addEventListener('click', () => showParamInfo(key));
      row.appendChild(lab);
      row.appendChild(range);
      row.appendChild(num);
    }
    row.addEventListener('mouseenter', () => showParamInfo(key));
    return row;
  }

  function updateControlValues() {
    for (const key of Object.keys(state.params)) {
      const row = document.querySelector(`.param[data-key="${key}"]`);
      if (!row) continue;
      const range = row.querySelector('input[type="range"]');
      const num = row.querySelector('input[type="number"]');
      const cb = row.querySelector('input[type="checkbox"]');
      if (range) range.value = state.params[key];
      if (num) num.value = state.params[key];
      if (cb) cb.checked = !!state.params[key];
    }
  }

  function setParam(key, value) {
    if (key in SPEC && SPEC[key].type !== 'bool') {
      value = clamp(Number(value), SPEC[key].min, SPEC[key].max);
    } else {
      value = Number(value);
    }
    state.params[key] = value;
    showParamInfo(key);
    if (!state.playing && state.live) {
      processFrame(false, false);
      $('footerHint').textContent = `${PARAM_INFO[key].label}=${fmt(value)} 已应用（筛选/几何即时；跟踪单步生效）`;
    } else {
      $('footerHint').textContent = `${PARAM_INFO[key].label}=${fmt(value)}（下一帧生效）`;
    }
    updateControlValues();
  }

  function showParamInfo(key) {
    const info = PARAM_INFO[key];
    if (!info) return;
    state.focusParam = key;
    const v = state.params[key];
    $('paramValue').textContent = `${info.label} = ${fmt(v)}${info.unit ? ' ' + info.unit : ''}`;
    $('paramInfo').innerHTML =
      `<h3>${info.label}</h3>` +
      `<p class="muted">${info.desc}</p>` +
      `<p class="muted" style="margin-top:6px"><b style="color:#cfdaeb">当前值</b> ${fmt(v)}${info.unit ? ' ' + info.unit : ''}</p>` +
      `<p class="muted" style="margin-top:4px"><b style="color:#cfdaeb">试试</b> ${info.try}</p>`;
    document.querySelectorAll('.param.focus').forEach((n) => n.classList.remove('focus'));
    const row = document.querySelector(`.param[data-key="${key}"]`);
    if (row) row.classList.add('focus');
  }

  function toast(msg) {
    const t = $('toast');
    t.textContent = msg;
    t.classList.add('show');
    clearTimeout(toast._timer);
    toast._timer = setTimeout(() => t.classList.remove('show'), 1600);
  }

  function updateUI() {
    const r = state.result;
    if (!r) return;
    const kept = r.runs.filter((x) => x.kept).length;
    const pass = r.blobs.filter((b) => b.pass).length;
    const validT = state.tracks.filter((t) => t.valid);
    const visT = state.tracks.filter((t) => t.valid && t.visible);
    $('statFrame').textContent = state.frame;
    $('statCount').textContent = state.count;
    $('statRuns').textContent = `${kept}/${r.runs.length}`;
    $('statBlobs').textContent = `${pass}/${r.blobs.length}`;
    $('statTracks').textContent = `${validT.length}/${visT.length}`;
    $('stageReadout').textContent =
      `F ${state.frame} · RUN ${kept}/${r.runs.length} · BLOB ${pass}/${r.blobs.length} · TRK ${validT.length} · COUNT ${state.count}`;
    $('blobSummary').textContent = `${pass} pass / ${r.blobs.length} raw`;
    $('trackSummary').textContent = `${validT.length} valid / ${visT.length} visible`;
    renderBlobList();
    renderTrackList();
  }

  function renderBlobList() {
    const r = state.result;
    if (!r) return;
    const list = $('blobList');
    if (!r.blobs.length) {
      list.innerHTML = '<div class="mini">没有连通域（可能全被 ROI/长度/min_run 过滤）。</div>';
      return;
    }
    const blobs = r.blobs.slice().sort((a, b) => (b.pass - a.pass) || (b.area - a.area)).slice(0, 16);
    list.innerHTML = blobs.map((b) => {
      const sel = b.label === state.selected ? ' selected' : '';
      return `<div class="list-item ${b.pass ? 'pass' : 'fail'}${sel}" data-label="${b.label}">
        <div class="li-head"><span>#${b.label} ${b.pass ? 'PASS' : 'REJECT'}</span><span>A=${b.area}</span></div>
        <div class="li-sub">bbox ${b.x0},${b.y0} → ${b.x1},${b.y1} · w${b.w} h${b.h}</div>
        <div class="li-sub">fill ${b.fill}% · ratio ${b.ratio}% · c ${b.cx},${b.cy}</div>
        <div class="${b.pass ? 'li-ok' : 'li-reason'}">${b.pass ? '通过筛选' : b.reason}</div>
      </div>`;
    }).join('');
    list.querySelectorAll('.list-item').forEach((el) => {
      el.addEventListener('click', () => {
        state.selected = Number(el.dataset.label);
        render();
        updateUI();
      });
      el.addEventListener('mouseenter', () => {
        const b = r.blobs.find((x) => x.label === Number(el.dataset.label));
        if (b) $('footerHint').textContent = `#${b.label} area=${b.area} bbox=${b.x0},${b.y0}-${b.x1},${b.y1} ${b.pass ? 'PASS' : b.reason}`;
      });
    });
  }

  function renderTrackList() {
    const list = $('trackList');
    const valid = state.tracks.filter((t) => t.valid);
    if (!valid.length) {
      list.innerHTML = '<div class="mini">没有有效轨迹。新检测需要先累计 hits。</div>';
      return;
    }
    list.innerHTML = valid.map((t) => `
      <div class="list-item ${t.visible ? 'pass' : ''}">
        <div class="li-head"><span>ID ${t.id} ${t.visible ? 'VISIBLE' : 'TRACKING'}</span><span>${t.counted ? 'COUNTED' : ''}</span></div>
        <div class="li-sub">c ${t.cx},${t.cy} · vx ${t.vx} · hit ${t.hits} miss ${t.missed}</div>
        <div class="li-sub">moved ${t.moved} · window ${t.window_move} · age ${t.age}</div>
      </div>
    `).join('');
  }

  function canvasPoint(e) {
    const rect = canvas.getBoundingClientRect();
    return {
      x: (e.clientX - rect.left) / rect.width * W,
      y: (e.clientY - rect.top) / rect.height * H,
    };
  }

  function hitBlob(pt) {
    const r = state.result;
    if (!r) return null;
    for (let i = r.blobs.length - 1; i >= 0; i--) {
      const b = r.blobs[i];
      if (pt.x >= b.x0 - 1 && pt.x <= b.x1 + 1 && pt.y >= b.y0 - 1 && pt.y <= b.y1 + 1) return b;
    }
    return null;
  }

  // ---------------- events ----------------
  function bind() {
    $('btnPlay').addEventListener('click', () => {
      state.playing = !state.playing;
      $('btnPlay').textContent = state.playing ? '暂停' : '播放';
      state.lastTime = 0;
      state.acc = 0;
    });
    $('btnStep').addEventListener('click', () => {
      state.playing = false;
      $('btnPlay').textContent = '播放';
      processFrame(true, true);
    });
    $('btnReset').addEventListener('click', resetSim);
    $('btnRandom').addEventListener('click', () => {
      state.seed = (Math.random() * 1e9) >>> 0;
      resetSim();
      toast('已换场景');
    });
    $('btnDefaults').addEventListener('click', () => {
      state.params = { ...DEFAULTS };
      updateControlValues();
      resetSim();
      showParamInfo(PARAM_INFO[state.focusParam] ? state.focusParam : 'bg_thr');
      toast('参数已恢复默认');
    });
    $('fps').addEventListener('change', (e) => { state.fps = Number(e.target.value); });
    $('scenePreset').addEventListener('change', (e) => {
      state.scenePreset = e.target.value;
      resetSim();
      toast(`场景：${e.target.selectedOptions[0].textContent}`);
    });
    $('chkLive').addEventListener('change', (e) => { state.live = e.target.checked; });

    const map = {
      vCamera: 'camera', vMask: 'mask', vScore: 'score', vRuns: 'runs',
      vBlobs: 'blobs', vRejected: 'rejected', vTracks: 'tracks', vGate: 'gate',
    };
    for (const [id, key] of Object.entries(map)) {
      $(id).addEventListener('change', (e) => { view[key] = e.target.checked; render(); });
    }

    canvas.addEventListener('click', (e) => {
      const b = hitBlob(canvasPoint(e));
      state.selected = b ? b.label : null;
      render();
      updateUI();
    });
    canvas.addEventListener('mousemove', (e) => {
      const b = hitBlob(canvasPoint(e));
      if (b) {
        $('footerHint').textContent =
          `#${b.label} area=${b.area} bbox=${b.x0},${b.y0}-${b.x1},${b.y1} ${b.pass ? 'PASS' : b.reason}`;
      }
    });
    canvas.addEventListener('mouseleave', () => {
      $('footerHint').textContent = '点击 Blob 查看筛选原因';
    });
  }

  function loop(t) {
    if (!state.lastTime) state.lastTime = t;
    if (state.playing) {
      const dt = Math.min(200, t - state.lastTime);
      state.lastTime = t;
      state.acc += dt;
      const interval = 1000 / state.fps;
      let steps = 0;
      while (state.acc >= interval && steps < 4) {
        state.acc -= interval;
        processFrame(true, true);
        steps++;
      }
    } else {
      state.lastTime = t;
    }
    requestAnimationFrame(loop);
  }

  // ---------------- init ----------------
  buildControls();
  bind();
  updateControlValues();
  showParamInfo('bg_thr');
  resetSim();
  requestAnimationFrame(loop);
})();