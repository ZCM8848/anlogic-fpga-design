/* FPGA UI Layout Studio — camera_hdmi_720p
 * 纯前端、离线可用：拖拽/输入坐标排版 1280x720 OSD 元素，导出 JSON / Verilog / C。
 */
(() => {
  'use strict';

  const W = 1280;
  const H = 720;
  const RENDER_SCALE = 2;
  const STORE_KEY = 'fpga_ui_layout_studio_v1';
  const MONO = '"Cascadia Code", Consolas, "Courier New", monospace';
  const SANS = '"Segoe UI", "Microsoft YaHei", "PingFang SC", sans-serif';

  // 160x160 Anlogic logo, exported from anlogic_logo_rom.v (base64 keeps canvas untainted on file://)
  const LOGO_DATA_URL = 'data:image/png;base64,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';

  const $ = (id) => document.getElementById(id);

  const TYPES = {
    logo:      { label: '安路 Logo',  icon: '▣', prefix: 'LOGO',   w: 160, h: 160, color: '#1f315c', text: '',           hasText: false },
    count:     { label: '钢珠计数',   icon: '#', prefix: 'COUNT',  w: 120, h: 24,  color: '#00e6ff', text: '00000',      hasText: true  },
    osd_text:  { label: 'OSD 文本',   icon: 'A', prefix: 'OSD',    w: 200, h: 24,  color: '#fff200', text: 'ANLU FPGA',  hasText: true  },
    frame:     { label: '帧计数',     icon: 'F', prefix: 'FRAME',  w: 200, h: 22,  color: '#ffffff', text: 'FRAME 000123', hasText: true },
    label:     { label: '标签',       icon: 'T', prefix: 'LABEL',  w: 140, h: 20,  color: '#8be9fd', text: 'LABEL',      hasText: true  },
    debug:     { label: '调试统计',   icon: 'D', prefix: 'DEBUG',  w: 340, h: 92,  color: '#7cfc9a', text: 'DET 3  TRK 3\nGATE 96  FPS 60\nRUN 512  LBL 5', hasText: true },
    box:       { label: '球框样例',   icon: '□', prefix: 'BOX',    w: 56,  h: 56,  color: '#00ff66', text: 'BALL 3',     hasText: true  },
    gate:      { label: '门线',       icon: '│', prefix: 'GATE',   w: 2,   h: 720, color: '#ff3366', text: 'GATE',       hasText: true  },
    roi:       { label: '检测 ROI',   icon: '▭', prefix: 'ROI',    w: 640, h: 360, color: '#00aaff', text: 'ROI',        hasText: true  },
    crosshair: { label: '十字准线',   icon: '+', prefix: 'CROSS',  w: 32,  h: 32,  color: '#ffffff', text: '',           hasText: false },
    colorbar:  { label: '彩条参考',   icon: '▥', prefix: 'CBAR',   w: 210, h: 120, color: '#ffffff', text: '',           hasText: false },
  };

  const NOTES = {
    logo: 'RTL 中 Logo 是 160×160 的 ROM 图案：X/Y 可直接用于布局，W/H 目前仅作预览。',
    count: '当前 RTL Count 是 5×7 字模、每位 8px；X/Y 直接生效，W/H 供后续 24×24 字库使用。',
    gate: '识别门线固定为 x = 0.30·W = 384，移动它只改变预览，不会改变检测逻辑。',
    roi: '检测 ROI 由 MCU 参数 roi_y1 控制（小分辨率 166 → 全分辨率 664），此处仅预览。',
    box: '球框是运行时动态叠加，位置仅作样例参考。',
    debug: '调试统计文本由固件经串口/调试叠加上屏，布局用于规划位置。',
  };

  const PRESETS = {
    current: () => ([
      el('logo', 0, 0, { w: 160, h: 160, name: '安路 Logo' }),
      el('osd_text', 375, 120, { w: 200, h: 24, text: 'ANLU  LOGO  0000', name: '动态 OSD' }),
      el('count', 24, 56, { w: 40, h: 7, text: '00000', name: '钢珠计数' }),
    ]),
    competition: () => ([
      el('logo', 24, 24, { w: 160, h: 160, name: '安路 Logo' }),
      el('label', 24, 612, { w: 160, h: 18, text: 'STEEL BALL', name: '计数标题' }),
      el('count', 24, 638, { w: 150, h: 34, text: '00000', name: '钢珠计数' }),
      el('osd_text', 1016, 24, { w: 240, h: 24, text: 'ANLU HX1P35A', name: '赛事文本' }),
      el('frame', 1016, 676, { w: 240, h: 20, text: 'FRAME 000123', color: '#9aa7bd', name: '帧计数' }),
    ]),
    debug: () => ([
      el('roi', 0, 0, { w: 1280, h: 664, color: '#00aaff', name: '检测 ROI' }),
      el('gate', 384, 0, { w: 2, h: 720, color: '#ff3366', name: '门线 x=0.30W' }),
      el('count', 24, 16, { w: 120, h: 24, text: '00000', name: '钢珠计数' }),
      el('debug', 24, 52, { w: 340, h: 92, text: 'DET 3  TRK 3\nGATE 96  FPS 60\nRUN 512  LBL 5', name: '调试统计' }),
      el('box', 600, 300, { w: 56, h: 56, color: '#00ff66', text: 'BALL 3', name: '球框样例' }),
      el('crosshair', 624, 328, { w: 32, h: 32, color: '#ffffff', name: '十字准线' }),
    ]),
    blank: () => ([]),
  };

  // ---------------- state ----------------
  const state = {
    elements: [],
    selectedId: null,
    zoom: 0.75,
    grid: true,
    snap: true,
    safe: true,
    gridSize: 8,
    bgImage: null,
    bgOpacity: 1,
    logoImage: null,
    history: [],
    future: [],
    drag: null,
    guides: [],
    fieldSnapshot: null,
    modalMode: 'code',
    modalTab: 'verilog',
    counter: 1,
    userZoomed: false,
  };

  const canvas = $('stage');
  const ctx = canvas.getContext('2d');
  canvas.width = W * RENDER_SCALE;
  canvas.height = H * RENDER_SCALE;

  // 实际安路 Logo（从 anlogic_logo_rom.v 导出，160x160 透明底）
  const logoImage = new Image();
  logoImage.onload = () => { state.logoImage = logoImage; render(); };
  logoImage.src = LOGO_DATA_URL;

  // ---------------- helpers ----------------
  const clamp = (v, a, b) => Math.min(b, Math.max(a, v));
  const int = (v, d = 0) => {
    const n = Number(v);
    return Number.isFinite(n) ? Math.round(n) : d;
  };
  const uid = () => `el_${Date.now().toString(36)}_${state.counter++}`;
  const escapeHtml = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const getSelected = () => state.elements.find((e) => e.id === state.selectedId) || null;
  const snapshot = () => JSON.stringify(state.elements);

  function el(type, x, y, extra = {}) {
    const def = TYPES[type];
    return {
      id: uid(),
      type,
      name: def.label,
      x, y,
      w: def.w,
      h: def.h,
      color: def.color,
      text: def.text,
      visible: true,
      locked: false,
      ...extra,
    };
  }

  function normalizeElement(raw) {
    if (!raw || typeof raw !== 'object' || !TYPES[raw.type]) return null;
    const def = TYPES[raw.type];
    return {
      id: typeof raw.id === 'string' ? raw.id : uid(),
      type: raw.type,
      name: String(raw.name || def.label).slice(0, 60),
      x: clamp(int(raw.x, 0), 0, W - 2),
      y: clamp(int(raw.y, 0), 0, H - 2),
      w: clamp(int(raw.w, def.w), 2, W * 2),
      h: clamp(int(raw.h, def.h), 2, H * 2),
      color: /^#[0-9a-fA-F]{6}$/.test(raw.color || '') ? raw.color : def.color,
      text: raw.text == null ? def.text : String(raw.text).slice(0, 200),
      visible: raw.visible !== false,
      locked: raw.locked === true,
    };
  }

  function uniqueName(base) {
    const names = new Set(state.elements.map((e) => e.name));
    if (!names.has(base)) return base;
    let i = 2;
    while (names.has(`${base} ${i}`)) i++;
    return `${base} ${i}`;
  }

  function pushHistory(before) {
    if (before == null) return;
    if (before === snapshot()) return;
    state.history.push(before);
    if (state.history.length > 100) state.history.shift();
    state.future.length = 0;
  }

  function restore(snap) {
    try {
      const arr = JSON.parse(snap);
      if (Array.isArray(arr)) {
        state.elements = arr.map(normalizeElement).filter(Boolean);
        if (!state.elements.some((e) => e.id === state.selectedId)) state.selectedId = null;
        refreshAll();
        saveLocal();
      }
    } catch (_) { /* ignore */ }
  }

  function undo() {
    if (!state.history.length) return toast('没有可撤销的操作');
    state.future.push(snapshot());
    restore(state.history.pop());
    toast('已撤销');
  }

  function redo() {
    if (!state.future.length) return toast('没有可重做的操作');
    state.history.push(snapshot());
    restore(state.future.pop());
    toast('已重做');
  }

  // ---------------- rendering ----------------
  function render() {
    ctx.setTransform(RENDER_SCALE, 0, 0, RENDER_SCALE, 0, 0);
    ctx.clearRect(0, 0, W, H);

    if (state.bgImage) {
      drawCover(state.bgImage, state.bgOpacity);
    } else {
      ctx.fillStyle = '#0a0f18';
      ctx.fillRect(0, 0, W, H);
      const g = ctx.createRadialGradient(W / 2, H * 0.32, 40, W / 2, H * 0.55, W * 0.72);
      g.addColorStop(0, 'rgba(35, 58, 96, 0.20)');
      g.addColorStop(1, 'rgba(6, 9, 14, 0)');
      ctx.fillStyle = g;
      ctx.fillRect(0, 0, W, H);
    }

    if (state.grid) drawGrid();
    if (state.safe) drawSafeArea();

    for (const item of state.elements) {
      if (item.visible) drawElement(item);
    }

    const sel = getSelected();
    if (sel) drawSelection(sel);
    drawGuides();
  }

  function drawCover(img, opacity) {
    const s = Math.max(W / img.width, H / img.height);
    const dw = img.width * s;
    const dh = img.height * s;
    ctx.save();
    ctx.globalAlpha = opacity;
    ctx.drawImage(img, (W - dw) / 2, (H - dh) / 2, dw, dh);
    ctx.restore();
  }

  function drawGrid() {
    let step = state.gridSize;
    while (step * state.zoom < 6) step *= 2;
    const major = step * 8;

    ctx.save();
    ctx.lineWidth = 1 / state.zoom;
    for (let x = 0; x <= W; x += step) {
      ctx.strokeStyle = x % major === 0 ? 'rgba(140, 175, 230, 0.13)' : 'rgba(140, 175, 230, 0.055)';
      ctx.beginPath();
      ctx.moveTo(x + 0.5 / state.zoom, 0);
      ctx.lineTo(x + 0.5 / state.zoom, H);
      ctx.stroke();
    }
    for (let y = 0; y <= H; y += step) {
      ctx.strokeStyle = y % major === 0 ? 'rgba(140, 175, 230, 0.13)' : 'rgba(140, 175, 230, 0.055)';
      ctx.beginPath();
      ctx.moveTo(0, y + 0.5 / state.zoom);
      ctx.lineTo(W, y + 0.5 / state.zoom);
      ctx.stroke();
    }
    ctx.restore();
  }

  function drawSafeArea() {
    const mx = Math.round(W * 0.05);
    const my = Math.round(H * 0.05);
    ctx.save();
    ctx.strokeStyle = 'rgba(34, 211, 238, 0.30)';
    ctx.lineWidth = 1 / state.zoom;
    ctx.setLineDash([6 / state.zoom, 5 / state.zoom]);
    ctx.strokeRect(mx, my, W - mx * 2, H - my * 2);
    ctx.restore();
  }

  function roundPath(c, x, y, w, h, r) {
    const rr = Math.min(r, w / 2, h / 2);
    c.beginPath();
    c.moveTo(x + rr, y);
    c.lineTo(x + w - rr, y);
    c.quadraticCurveTo(x + w, y, x + w, y + rr);
    c.lineTo(x + w, y + h - rr);
    c.quadraticCurveTo(x + w, y + h, x + w - rr, y + h);
    c.lineTo(x + rr, y + h);
    c.quadraticCurveTo(x, y + h, x, y + h - rr);
    c.lineTo(x, y + rr);
    c.quadraticCurveTo(x, y, x + rr, y);
    c.closePath();
  }

  function chip(c, text, x, y, color, align = 'left') {
    const fs = Math.max(7, Math.min(16, 11 / state.zoom));
    c.save();
    c.font = `600 ${fs}px ${MONO}`;
    const tw = c.measureText(text).width;
    const px = 5 / state.zoom;
    const py = 3 / state.zoom;
    const bw = tw + px * 2;
    const bh = fs + py * 2;
    let bx = x;
    if (align === 'center') bx = x - bw / 2;
    if (align === 'right') bx = x - bw;
    c.fillStyle = 'rgba(5, 9, 15, 0.78)';
    roundPath(c, bx, y, bw, bh, 3 / state.zoom);
    c.fill();
    c.strokeStyle = color;
    c.globalAlpha = 0.55;
    c.lineWidth = 1 / state.zoom;
    c.stroke();
    c.globalAlpha = 1;
    c.fillStyle = color;
    c.textAlign = 'left';
    c.textBaseline = 'top';
    c.fillText(text, bx + px, y + py);
    c.restore();
    return bh;
  }

  function drawElement(item) {
    const { w, h, color } = item;
    const c = ctx;
    c.save();
    c.translate(item.x, item.y);

    switch (item.type) {
      case 'logo': drawLogo(c, w, h, item); break;
      case 'count': drawCount(c, w, h, color, item.text); break;
      case 'osd_text':
      case 'frame':
      case 'label':
        drawTextChip(c, w, h, color, item.text, item.type === 'frame' || item.type === 'label');
        break;
      case 'debug': drawDebug(c, w, h, color, item.text); break;
      case 'box': drawBox(c, w, h, color, item.text); break;
      case 'gate': drawGate(c, w, h, color, item.text); break;
      case 'roi': drawRoi(c, w, h, color, item.text); break;
      case 'crosshair': drawCrosshair(c, w, h, color); break;
      case 'colorbar': drawColorbar(c, w, h); break;
      default: break;
    }

    c.restore();
  }

  function drawLogo(c, w, h) {
    if (state.logoImage) {
      c.drawImage(state.logoImage, 0, 0, w, h);
      return;
    }
    const r = Math.min(8, w * 0.06, h * 0.06);
    c.save();
    roundPath(c, 0, 0, w, h, r);
    const g = c.createLinearGradient(0, 0, w, h);
    g.addColorStop(0, '#16233d');
    g.addColorStop(1, '#0d1626');
    c.fillStyle = g;
    c.fill();
    c.strokeStyle = 'rgba(120, 160, 220, 0.25)';
    c.lineWidth = 1;
    c.stroke();

    // red ribbon
    c.beginPath();
    c.moveTo(w * 0.10, h * 0.24);
    c.lineTo(w * 0.46, h * 0.24);
    c.lineTo(w * 0.30, h * 0.52);
    c.lineTo(w * 0.10, h * 0.52);
    c.closePath();
    c.fillStyle = '#ec1c2d';
    c.fill();
    c.beginPath();
    c.moveTo(w * 0.38, h * 0.24);
    c.lineTo(w * 0.47, h * 0.24);
    c.lineTo(w * 0.31, h * 0.52);
    c.lineTo(w * 0.22, h * 0.52);
    c.closePath();
    c.fillStyle = 'rgba(236, 28, 45, 0.55)';
    c.fill();

    c.textAlign = 'left';
    c.textBaseline = 'middle';
    c.fillStyle = '#ffffff';
    c.font = `700 ${Math.max(8, h * 0.20)}px ${SANS}`;
    c.fillText('安路', w * 0.55, h * 0.38);

    c.fillStyle = 'rgba(170, 195, 230, 0.72)';
    c.font = `600 ${Math.max(5, h * 0.075)}px ${MONO}`;
    c.fillText('ANLOGIC', w * 0.55, h * 0.56);

    c.fillStyle = 'rgba(120, 150, 195, 0.45)';
    c.font = `400 ${Math.max(4, h * 0.055)}px ${MONO}`;
    c.fillText('HX1P35A', w * 0.55, h * 0.68);

    c.strokeStyle = 'rgba(236, 28, 45, 0.55)';
    c.lineWidth = Math.max(1, w * 0.008);
    c.beginPath();
    c.moveTo(w * 0.10, h * 0.78);
    c.lineTo(w * 0.90, h * 0.78);
    c.stroke();
    c.restore();
  }

  function drawCount(c, w, h, color, text) {
    const digits = String(text || '00000').replace(/[^0-9]/g, '').padStart(5, '0').slice(-5);
    c.save();
    roundPath(c, 0, 0, w, h, Math.min(4, h * 0.18));
    c.fillStyle = 'rgba(0, 0, 0, 0.58)';
    c.fill();
    c.strokeStyle = color;
    c.globalAlpha = 0.42;
    c.lineWidth = Math.max(1, h * 0.035);
    c.stroke();
    c.globalAlpha = 1;

    const cell = w / 5;
    const fs = Math.min(h * 1.30, cell * 2.0);
    c.font = `700 ${fs}px ${MONO}`;
    c.textAlign = 'center';
    c.textBaseline = 'middle';
    c.fillStyle = color;
    for (let i = 0; i < 5; i++) {
      c.fillText(digits[i], cell * i + cell / 2, h * 0.53);
    }
    c.restore();
  }

  function drawTextChip(c, w, h, color, text, subtle) {
    c.save();
    c.fillStyle = subtle ? 'rgba(0, 0, 0, 0.30)' : 'rgba(0, 0, 0, 0.52)';
    roundPath(c, 0, 0, w, h, Math.min(3, h * 0.18));
    c.fill();
    c.strokeStyle = color;
    c.globalAlpha = 0.22;
    c.lineWidth = 1;
    c.stroke();
    c.globalAlpha = 1;

    let fs = Math.max(6, h * 0.72);
    c.font = `600 ${fs}px ${MONO}`;
    const tw = c.measureText(text || '').width;
    if (tw > w - 8 && tw > 0) {
      fs = Math.max(5, fs * (w - 8) / tw);
      c.font = `600 ${fs}px ${MONO}`;
    }
    c.fillStyle = color;
    c.textAlign = 'left';
    c.textBaseline = 'middle';
    c.fillText(text || '', 4, h * 0.54);
    c.restore();
  }

  function drawDebug(c, w, h, color, text) {
    c.save();
    roundPath(c, 0, 0, w, h, 5);
    c.fillStyle = 'rgba(0, 0, 0, 0.60)';
    c.fill();
    c.strokeStyle = color;
    c.globalAlpha = 0.35;
    c.lineWidth = 1;
    c.stroke();
    c.globalAlpha = 1;

    const lines = String(text || '').split('\n');
    const fs = Math.max(5, Math.min(h / (lines.length + 0.7), w / 22));
    c.font = `500 ${fs}px ${MONO}`;
    c.fillStyle = color;
    c.textAlign = 'left';
    c.textBaseline = 'top';
    lines.forEach((line, i) => {
      c.fillText(line, 7, 6 + i * fs * 1.42);
    });
    c.restore();
  }

  function drawBox(c, w, h, color, text) {
    c.save();
    c.strokeStyle = color;
    c.lineWidth = Math.max(1.5, Math.min(w, h) * 0.035);
    c.strokeRect(0, 0, w, h);
    const tick = Math.min(w, h) * 0.24;
    c.lineWidth = Math.max(2, Math.min(w, h) * 0.06);
    const corners = [[0, 0, 1, 1], [w, 0, -1, 1], [0, h, 1, -1], [w, h, -1, -1]];
    for (const [x, y, dx, dy] of corners) {
      c.beginPath();
      c.moveTo(x, y + dy * tick);
      c.lineTo(x, y);
      c.lineTo(x + dx * tick, y);
      c.stroke();
    }
    if (text) chip(c, text, 0, -Math.max(13, h * 0.28), color);
    c.restore();
  }

  function drawGate(c, w, h, color, text) {
    c.save();
    if (w > 5) {
      c.fillStyle = color;
      c.globalAlpha = 0.08;
      c.fillRect(0, 0, w, h);
      c.globalAlpha = 1;
    }
    c.strokeStyle = color;
    c.lineWidth = Math.max(1.2, w);
    c.setLineDash([7, 6]);
    c.beginPath();
    c.moveTo(w / 2, 0);
    c.lineTo(w / 2, h);
    c.stroke();
    c.setLineDash([]);
    c.beginPath();
    c.moveTo(w / 2 - 5, 0);
    c.lineTo(w / 2 + 5, 0);
    c.lineTo(w / 2, 8);
    c.closePath();
    c.fillStyle = color;
    c.fill();
    if (text) chip(c, text, w + 6, 6, color);
    c.restore();
  }

  function drawRoi(c, w, h, color, text) {
    c.save();
    c.fillStyle = color;
    c.globalAlpha = 0.055;
    c.fillRect(0, 0, w, h);
    c.globalAlpha = 1;
    c.strokeStyle = color;
    c.lineWidth = 1.2;
    c.setLineDash([8, 6]);
    c.strokeRect(0, 0, w, h);
    c.setLineDash([]);
    if (text) chip(c, text, 5, 5, color);
    c.restore();
  }

  function drawCrosshair(c, w, h, color) {
    c.save();
    c.strokeStyle = color;
    c.lineWidth = 1;
    c.globalAlpha = 0.9;
    c.beginPath();
    c.moveTo(-w / 2, h / 2);
    c.lineTo(w * 1.5, h / 2);
    c.moveTo(w / 2, -h / 2);
    c.lineTo(w / 2, h * 1.5);
    c.stroke();
    c.beginPath();
    c.arc(w / 2, h / 2, Math.min(w, h) * 0.28, 0, Math.PI * 2);
    c.stroke();
    c.globalAlpha = 0.5;
    c.setLineDash([3, 3]);
    c.strokeRect(0, 0, w, h);
    c.restore();
  }

  function drawColorbar(c, w, h) {
    const colors = ['#ffffff', '#ffff00', '#00ffff', '#00ff00', '#ff00ff', '#ff0000', '#0000ff'];
    const bw = w / colors.length;
    c.save();
    for (let i = 0; i < colors.length; i++) {
      c.fillStyle = colors[i];
      c.fillRect(i * bw, 0, bw + 1, h);
    }
    c.fillStyle = 'rgba(0,0,0,0.55)';
    c.fillRect(0, h - 14, w, 14);
    c.fillStyle = '#fff';
    c.font = `600 9px ${MONO}`;
    c.textAlign = 'center';
    c.textBaseline = 'middle';
    for (let i = 0; i < colors.length; i++) {
      c.fillText('75%', i * bw + bw / 2, h - 7);
    }
    c.restore();
  }

  function handlePoints(item) {
    const { x, y, w, h } = item;
    return [
      ['nw', x, y], ['n', x + w / 2, y], ['ne', x + w, y],
      ['e', x + w, y + h / 2], ['se', x + w, y + h],
      ['s', x + w / 2, y + h], ['sw', x, y + h], ['w', x, y + h / 2],
    ];
  }

  function drawSelection(item) {
    const c = ctx;
    const t = 1 / state.zoom;
    c.save();
    c.strokeStyle = '#5b8cff';
    c.lineWidth = t;
    c.setLineDash([]);
    c.strokeRect(item.x, item.y, item.w, item.h);

    const size = 7 / state.zoom;
    for (const [, px, py] of handlePoints(item)) {
      c.fillStyle = '#f4f8ff';
      c.fillRect(px - size / 2, py - size / 2, size, size);
      c.strokeStyle = '#3f6fe8';
      c.strokeRect(px - size / 2, py - size / 2, size, size);
    }

    const fs = 10 / state.zoom;
    const label = `${item.name}  ${item.x},${item.y}  ${item.w}×${item.h}`;
    c.font = `600 ${fs}px ${MONO}`;
    const tw = c.measureText(label).width;
    const pad = 4 / state.zoom;
    const bh = fs + pad * 2;
    let by = item.y - bh - 4 / state.zoom;
    if (by < 0) by = item.y + 4 / state.zoom;
    let bx = item.x;
    if (bx + tw + pad * 2 > W) bx = W - tw - pad * 2;
    c.fillStyle = 'rgba(15, 30, 56, 0.92)';
    roundPath(c, bx, by, tw + pad * 2, bh, 3 / state.zoom);
    c.fill();
    c.strokeStyle = 'rgba(91, 140, 255, 0.8)';
    c.stroke();
    c.fillStyle = '#dce9ff';
    c.textAlign = 'left';
    c.textBaseline = 'top';
    c.fillText(label, bx + pad, by + pad);
    c.restore();
  }

  function drawGuides() {
    if (!state.guides.length) return;
    const c = ctx;
    c.save();
    c.strokeStyle = '#ff4fd8';
    c.lineWidth = 1 / state.zoom;
    c.setLineDash([4 / state.zoom, 3 / state.zoom]);
    for (const g of state.guides) {
      c.beginPath();
      if (g.axis === 'v') {
        c.moveTo(g.pos, 0);
        c.lineTo(g.pos, H);
      } else {
        c.moveTo(0, g.pos);
        c.lineTo(W, g.pos);
      }
      c.stroke();
    }
    c.restore();
  }

  // ---------------- hit testing ----------------
  function canvasPoint(e) {
    const rect = canvas.getBoundingClientRect();
    return {
      x: (e.clientX - rect.left) / state.zoom,
      y: (e.clientY - rect.top) / state.zoom,
    };
  }

  function hitHandle(pt) {
    const item = getSelected();
    if (!item) return null;
    const tol = 8 / state.zoom;
    for (const [name, x, y] of handlePoints(item)) {
      if (Math.abs(pt.x - x) <= tol && Math.abs(pt.y - y) <= tol) return name;
    }
    return null;
  }

  function hitElement(pt) {
    const pad = 5 / state.zoom;
    for (let i = state.elements.length - 1; i >= 0; i--) {
      const item = state.elements[i];
      if (!item.visible) continue;
      if (item.type === 'gate') {
        const cx = item.x + item.w / 2;
        if (Math.abs(pt.x - cx) <= Math.max(6 / state.zoom, item.w) && pt.y >= item.y - pad && pt.y <= item.y + item.h + pad) return item;
        continue;
      }
      if (pt.x >= item.x - pad && pt.x <= item.x + item.w + pad &&
          pt.y >= item.y - pad && pt.y <= item.y + item.h + pad) return item;
    }
    return null;
  }

  // ---------------- dragging ----------------
  function onPointerDown(e) {
    if (e.button !== 0) return;
    const pt = canvasPoint(e);
    const handle = hitHandle(pt);
    if (handle) {
      const item = getSelected();
      if (item && !item.locked) {
        e.preventDefault();
        canvas.setPointerCapture(e.pointerId);
        state.drag = {
          mode: 'resize',
          handle,
          pt,
          item,
          start: { x: item.x, y: item.y, w: item.w, h: item.h },
          before: snapshot(),
          moved: false,
        };
      }
      return;
    }

    const item = hitElement(pt);
    if (item) {
      select(item.id);
      if (!item.locked) {
        e.preventDefault();
        canvas.setPointerCapture(e.pointerId);
        state.drag = {
          mode: 'move',
          pt,
          item,
          start: { x: item.x, y: item.y, w: item.w, h: item.h },
          before: snapshot(),
          moved: false,
        };
      }
    } else {
      select(null);
    }
  }

  function onPointerMove(e) {
    const pt = canvasPoint(e);
    $('cursorReadout').textContent = `x = ${Math.round(pt.x)}, y = ${Math.round(pt.y)}`;

    if (!state.drag) {
      updateHoverCursor(pt);
      return;
    }

    e.preventDefault();
    const d = state.drag;
    const dx = pt.x - d.pt.x;
    const dy = pt.y - d.pt.y;
    const item = d.item;
    if (!item || item.locked) return;

    if (d.mode === 'move') {
      let nx = d.start.x + dx;
      let ny = d.start.y + dy;
      if (e.shiftKey) {
        if (Math.abs(dx) >= Math.abs(dy)) ny = d.start.y;
        else nx = d.start.x;
      }
      const snapped = snapMove(item, nx, ny, e.altKey);
      item.x = clamp(Math.round(snapped.x), 0, W - 2);
      item.y = clamp(Math.round(snapped.y), 0, H - 2);
    } else {
      resizeItem(item, d, dx, dy, e.altKey);
    }

    d.moved = true;
    render();
    syncInspectorNumbers();
    updateHint();
    queueSave();
  }

  function onPointerUp(e) {
    const d = state.drag;
    if (!d) return;
    state.drag = null;
    state.guides = [];
    try { canvas.releasePointerCapture(e.pointerId); } catch (_) { /* ignore */ }
    if (d.moved) {
      pushHistory(d.before);
      saveLocal();
      render();
    }
  }

  function updateHoverCursor(pt) {
    const handle = hitHandle(pt);
    let cursor = 'default';
    if (handle) {
      cursor = {
        nw: 'nwse-resize', se: 'nwse-resize',
        ne: 'nesw-resize', sw: 'nesw-resize',
        n: 'ns-resize', s: 'ns-resize',
        e: 'ew-resize', w: 'ew-resize',
      }[handle] || 'default';
    } else if (hitElement(pt)) {
      cursor = 'move';
    }
    canvas.style.cursor = cursor;
  }

  function snapMove(item, nx, ny, disable) {
    if (disable) {
      state.guides = [];
      return { x: nx, y: ny };
    }
    const { vx, hy } = alignmentLines(item.id);
    const th = 7 / state.zoom;
    const g = state.gridSize;
    const guides = [];

    const sx = bestSnap([nx, nx + item.w / 2, nx + item.w], vx, th);
    if (sx) {
      nx += sx.delta;
      guides.push({ axis: 'v', pos: sx.line });
    } else if (state.snap) {
      nx = Math.round(nx / g) * g;
    }

    const sy = bestSnap([ny, ny + item.h / 2, ny + item.h], hy, th);
    if (sy) {
      ny += sy.delta;
      guides.push({ axis: 'h', pos: sy.line });
    } else if (state.snap) {
      ny = Math.round(ny / g) * g;
    }

    state.guides = guides;
    return { x: nx, y: ny };
  }

  function resizeItem(item, d, dx, dy, disable) {
    const min = 3;
    let nx = d.start.x;
    let ny = d.start.y;
    let nw = d.start.w;
    let nh = d.start.h;

    if (d.handle.includes('w')) {
      nx = clamp(d.start.x + dx, 0, d.start.x + d.start.w - min);
      nw = d.start.x + d.start.w - nx;
    }
    if (d.handle.includes('e')) {
      nw = Math.max(min, d.start.w + dx);
    }
    if (d.handle.includes('n')) {
      ny = clamp(d.start.y + dy, 0, d.start.y + d.start.h - min);
      nh = d.start.y + d.start.h - ny;
    }
    if (d.handle.includes('s')) {
      nh = Math.max(min, d.start.h + dy);
    }

    if (!disable) {
      const { vx, hy } = alignmentLines(item.id);
      const th = 7 / state.zoom;
      const g = state.gridSize;
      const guides = [];

      if (d.handle.includes('w')) {
        const s = bestSnap([nx], vx, th);
        if (s) { nx += s.delta; nw = d.start.x + d.start.w - nx; guides.push({ axis: 'v', pos: s.line }); }
        else if (state.snap) { const gx = Math.round(nx / g) * g; nw -= gx - nx; nx = gx; }
      } else if (d.handle.includes('e')) {
        const right = nx + nw;
        const s = bestSnap([right], vx, th);
        if (s) { nw += s.delta; guides.push({ axis: 'v', pos: s.line }); }
        else if (state.snap) nw = Math.round((nx + nw) / g) * g - nx;
      }

      if (d.handle.includes('n')) {
        const s = bestSnap([ny], hy, th);
        if (s) { ny += s.delta; nh = d.start.y + d.start.h - ny; guides.push({ axis: 'h', pos: s.line }); }
        else if (state.snap) { const gy = Math.round(ny / g) * g; nh -= gy - ny; ny = gy; }
      } else if (d.handle.includes('s')) {
        const bottom = ny + nh;
        const s = bestSnap([bottom], hy, th);
        if (s) { nh += s.delta; guides.push({ axis: 'h', pos: s.line }); }
        else if (state.snap) nh = Math.round((ny + nh) / g) * g - ny;
      }

      state.guides = guides;
    } else {
      state.guides = [];
    }

    item.x = clamp(Math.round(nx), 0, W - min);
    item.y = clamp(Math.round(ny), 0, H - min);
    item.w = clamp(Math.round(nw), min, W * 2);
    item.h = clamp(Math.round(nh), min, H * 2);
  }

  function alignmentLines(excludeId) {
    const vx = [0, W / 2, W];
    const hy = [0, H / 2, H];
    for (const item of state.elements) {
      if (!item.visible || item.id === excludeId) continue;
      vx.push(item.x, item.x + item.w / 2, item.x + item.w);
      hy.push(item.y, item.y + item.h / 2, item.y + item.h);
    }
    return { vx, hy };
  }

  function bestSnap(candidates, lines, threshold) {
    let best = null;
    for (const c of candidates) {
      for (const line of lines) {
        const delta = line - c;
        if (Math.abs(delta) <= threshold && (!best || Math.abs(delta) < Math.abs(best.delta))) {
          best = { delta, line };
        }
      }
    }
    return best;
  }

  // ---------------- selection / inspector ----------------
  function select(id) {
    state.selectedId = id;
    buildInspector();
    renderLayers();
    render();
    updateHint();
  }

  function updateHint() {
    const item = getSelected();
    $('selectionHint').textContent = item
      ? `${item.name} · x=${item.x} y=${item.y} · ${item.w}×${item.h}`
      : '未选择元素';
  }

  function buildInspector() {
    const item = getSelected();
    const empty = $('inspectorEmpty');
    const body = $('inspectorBody');
    $('selectionType').textContent = item ? TYPES[item.type].label : '—';

    if (!item) {
      empty.classList.remove('hidden');
      body.classList.add('hidden');
      body.innerHTML = '';
      return;
    }
    empty.classList.add('hidden');
    body.classList.remove('hidden');

    const def = TYPES[item.type];
    const textField = def.hasText ? `
      <label class="field field-full">
        <span>${item.type === 'debug' ? '文本（可多行）' : '文本 / 内容'}</span>
        ${item.type === 'debug'
          ? `<textarea data-field="text" rows="3" style="height:62px;padding:7px 8px;border-radius:6px;border:1px solid var(--line);background:#0b111b;color:var(--text);font-family:var(--mono);font-size:11px;outline:0;resize:vertical">${escapeHtml(item.text)}</textarea>`
          : `<input type="text" data-field="text" value="${escapeHtml(item.text)}">`}
      </label>` : '';

    body.innerHTML = `
      <div class="field-grid">
        <label class="field"><span>X</span><input type="number" data-field="x" value="${item.x}" step="1"></label>
        <label class="field"><span>Y</span><input type="number" data-field="y" value="${item.y}" step="1"></label>
        <label class="field"><span>W</span><input type="number" data-field="w" value="${item.w}" step="1" min="2"></label>
        <label class="field"><span>H</span><input type="number" data-field="h" value="${item.h}" step="1" min="2"></label>
      </div>
      <label class="field field-full"><span>名称</span><input type="text" data-field="name" value="${escapeHtml(item.name)}"></label>
      ${textField}
      <div class="field-row">
        <span>颜色</span>
        <input type="color" data-field="color" value="${item.color}">
        <input class="hex" type="text" data-field="colorHex" value="${item.color}" maxlength="7">
      </div>
      <div class="check-row">
        <label class="check"><input type="checkbox" data-field="visible" ${item.visible ? 'checked' : ''}> 可见</label>
        <label class="check"><input type="checkbox" data-field="locked" ${item.locked ? 'checked' : ''}> 锁定</label>
      </div>
      <div class="inspector-actions">
        <button class="btn" data-act="duplicate">复制</button>
        <button class="btn btn-danger" data-act="delete">删除</button>
        <button class="btn" data-act="up">上移一层</button>
        <button class="btn" data-act="down">下移一层</button>
        <button class="btn" data-act="front">置顶</button>
        <button class="btn" data-act="back">置底</button>
        <button class="btn" data-act="center-h">水平居中</button>
        <button class="btn" data-act="center-v">垂直居中</button>
        <button class="btn full" data-act="reset-size">恢复默认尺寸</button>
      </div>
      <div class="param-box">
        <div class="param-head">
          <span>RTL 参数</span>
          <button data-act="copy-param">复制</button>
        </div>
        <pre id="paramPreview">${escapeHtml(paramBlock(item))}</pre>
      </div>
      ${NOTES[item.type] ? `<p class="inspector-note">${NOTES[item.type]}</p>` : ''}
    `;
  }

  function syncInspectorNumbers() {
    const item = getSelected();
    if (!item) return;
    for (const field of ['x', 'y', 'w', 'h']) {
      const input = document.querySelector(`#inspectorBody [data-field="${field}"]`);
      if (input && document.activeElement !== input) input.value = item[field];
    }
    const preview = $('paramPreview');
    if (preview) preview.textContent = paramBlock(item);
  }

  function handleFieldInput(e) {
    const item = getSelected();
    if (!item) return;
    const field = e.target.dataset.field;
    if (!field) return;

    if (field === 'x') item.x = clamp(int(e.target.value, item.x), 0, W - 2);
    else if (field === 'y') item.y = clamp(int(e.target.value, item.y), 0, H - 2);
    else if (field === 'w') item.w = clamp(int(e.target.value, item.w), 2, W * 2);
    else if (field === 'h') item.h = clamp(int(e.target.value, item.h), 2, H * 2);
    else if (field === 'name') item.name = e.target.value.slice(0, 60) || TYPES[item.type].label;
    else if (field === 'text') item.text = e.target.value.slice(0, 200);
    else if (field === 'color') {
      item.color = e.target.value;
      const hex = document.querySelector('#inspectorBody [data-field="colorHex"]');
      if (hex) hex.value = item.color;
    } else if (field === 'colorHex') {
      let v = e.target.value.trim();
      if (!v.startsWith('#')) v = `#${v}`;
      if (/^#[0-9a-fA-F]{6}$/.test(v)) {
        item.color = v.toLowerCase();
        const picker = document.querySelector('#inspectorBody [data-field="color"]');
        if (picker) picker.value = item.color;
      }
    } else if (field === 'visible') item.visible = e.target.checked;
    else if (field === 'locked') item.locked = e.target.checked;

    render();
    if (field === 'name' || field === 'visible' || field === 'locked') renderLayers();
    const preview = $('paramPreview');
    if (preview) preview.textContent = paramBlock(item);
    updateHint();
    queueSave();
  }

  function handleFieldChange(e) {
    if (!e.target.dataset || !e.target.dataset.field) return;
    if (state.fieldSnapshot != null) {
      pushHistory(state.fieldSnapshot);
      state.fieldSnapshot = snapshot();
    }
    saveLocal();
    renderLayers();
  }

  function handleInspectorClick(e) {
    const btn = e.target.closest('[data-act]');
    if (!btn) return;
    const item = getSelected();
    if (!item) return;
    const act = btn.dataset.act;

    if (act === 'delete') return deleteSelected();
    if (act === 'duplicate') return duplicateSelected();
    if (act === 'up') return moveSelected(1);
    if (act === 'down') return moveSelected(-1);
    if (act === 'front') return moveSelected(999);
    if (act === 'back') return moveSelected(-999);
    if (act === 'center-h') {
      const before = snapshot();
      item.x = Math.round((W - item.w) / 2);
      pushHistory(before);
    }
    if (act === 'center-v') {
      const before = snapshot();
      item.y = Math.round((H - item.h) / 2);
      pushHistory(before);
    }
    if (act === 'reset-size') {
      const before = snapshot();
      item.w = TYPES[item.type].w;
      item.h = TYPES[item.type].h;
      pushHistory(before);
    }
    if (act === 'copy-param') {
      copyText(paramBlock(item));
      return;
    }
    buildInspector();
    renderLayers();
    render();
    updateHint();
    saveLocal();
  }

  // ---------------- element operations ----------------
  function addElement(type) {
    if (!TYPES[type]) return;
    const before = snapshot();
    const def = TYPES[type];
    const base = {
      logo: [24, 24], count: [24, H - 64], osd_text: [W / 2 - 100, 80],
      frame: [W - 260, H - 44], label: [64, 64], debug: [24, 60],
      box: [W / 2 - 28, H / 2 - 28], gate: [Math.round(W * 0.3), 0],
      roi: [64, 64], crosshair: [W / 2 - 16, H / 2 - 16], colorbar: [W - 240, H - 160],
    }[type] || [64, 64];

    const same = state.elements.filter((e) => e.type === type).length;
    const x = clamp(base[0] + same * 14, 0, W - def.w);
    const y = clamp(base[1] + same * 14, 0, H - def.h);
    const item = el(type, Math.round(x), Math.round(y), { name: uniqueName(def.label), w: def.w, h: def.h });
    state.elements.push(item);
    pushHistory(before);
    select(item.id);
    render();
    saveLocal();
    toast(`已添加：${item.name}`);
  }

  function deleteSelected() {
    const item = getSelected();
    if (!item) return;
    const before = snapshot();
    state.elements = state.elements.filter((e) => e.id !== item.id);
    state.selectedId = null;
    pushHistory(before);
    refreshAll();
    saveLocal();
    toast(`已删除：${item.name}`);
  }

  function duplicateSelected() {
    const item = getSelected();
    if (!item) return;
    const before = snapshot();
    const copy = {
      ...item,
      id: uid(),
      name: uniqueName(`${item.name} 副本`),
      x: clamp(item.x + 16, 0, W - item.w),
      y: clamp(item.y + 16, 0, H - item.h),
    };
    state.elements.push(copy);
    pushHistory(before);
    select(copy.id);
    render();
    saveLocal();
    toast('已复制元素');
  }

  function moveSelected(delta) {
    const item = getSelected();
    if (!item) return;
    const idx = state.elements.findIndex((e) => e.id === item.id);
    if (idx < 0) return;
    let target;
    if (delta === 999) target = state.elements.length - 1;
    else if (delta === -999) target = 0;
    else target = clamp(idx + delta, 0, state.elements.length - 1);
    if (target === idx) return;
    const before = snapshot();
    const [moved] = state.elements.splice(idx, 1);
    state.elements.splice(target, 0, moved);
    pushHistory(before);
    renderLayers();
    render();
    updateHint();
    saveLocal();
  }

  // ---------------- layers ----------------
  function renderLayers() {
    const list = $('layerList');
    $('layerCount').textContent = String(state.elements.length);
    if (!state.elements.length) {
      list.innerHTML = '<div class="empty-state" style="padding:24px 10px">还没有元素<br>从左侧添加一个</div>';
      return;
    }
    list.innerHTML = [...state.elements].reverse().map((item) => {
      const def = TYPES[item.type];
      const sel = item.id === state.selectedId ? ' selected' : '';
      const hidden = item.visible ? '' : ' hidden-el';
      return `
        <div class="layer-row${sel}${hidden}" data-id="${item.id}" title="${escapeHtml(item.name)}">
          <span class="ltype">${def.icon}</span>
          <span class="lname">${escapeHtml(item.name)}</span>
          <button class="lbtn ${item.visible ? 'on' : 'off'}" data-act="vis" title="${item.visible ? '隐藏' : '显示'}">${iconEye(item.visible)}</button>
          <button class="lbtn ${item.locked ? 'on' : 'off'}" data-act="lock" title="${item.locked ? '解锁' : '锁定'}">${iconLock(item.locked)}</button>
        </div>`;
    }).join('');
  }

  function iconEye(on) {
    return `<svg viewBox="0 0 16 16"><path d="M1.2 8S3.7 3.6 8 3.6 14.8 8 14.8 8 12.3 12.4 8 12.4 1.2 8 1.2 8z"/><circle cx="8" cy="8" r="2.1"/>${on ? '' : '<path d="M2 2l12 12"/>'}</svg>`;
  }

  function iconLock(on) {
    return `<svg viewBox="0 0 16 16"><rect x="3.4" y="7" width="9.2" height="6.4" rx="1.2"/><path d="M5.6 7V5.1a2.4 2.4 0 014.8 0V7"/>${on ? '' : ''}</svg>`;
  }

  function handleLayerClick(e) {
    const row = e.target.closest('.layer-row');
    if (!row) return;
    const id = row.dataset.id;
    const act = e.target.closest('[data-act]')?.dataset.act;
    const item = state.elements.find((el) => el.id === id);
    if (!item) return;

    if (act === 'vis' || act === 'lock') {
      const before = snapshot();
      if (act === 'vis') item.visible = !item.visible;
      else item.locked = !item.locked;
      pushHistory(before);
      renderLayers();
      render();
      if (item.id === state.selectedId) buildInspector();
      saveLocal();
      return;
    }
    select(id);
  }

  // ---------------- code generation ----------------
  function semanticNames() {
    const count = {};
    const map = new Map();
    for (const item of state.elements) {
      const base = TYPES[item.type].prefix;
      count[base] = (count[base] || 0) + 1;
      map.set(item.id, count[base] === 1 ? base : `${base}_${count[base]}`);
    }
    return map;
  }

  function paramBlock(item) {
    const names = semanticNames();
    const nm = names.get(item.id) || TYPES[item.type].prefix;
    return [
      `\`define UI_${nm}_X 12'd${item.x}`,
      `\`define UI_${nm}_Y 12'd${item.y}`,
      `\`define UI_${nm}_W 12'd${item.w}`,
      `\`define UI_${nm}_H 12'd${item.h}`,
    ].join('\n');
  }

  function buildJson() {
    return JSON.stringify({
      app: 'fpga-ui-layout-studio',
      version: 1,
      canvas: { width: W, height: H },
      elements: state.elements.map((item) => ({ ...item })),
    }, null, 2) + '\n';
  }

  function buildVerilog() {
    const names = semanticNames();
    const time = new Date().toLocaleString('zh-CN', { hour12: false });
    const out = [];
    out.push('// ============================================================');
    out.push('// ui_layout.vh — generated by FPGA UI Layout Studio');
    out.push(`// ${time}`);
    out.push(`// Canvas ${W} x ${H} (HDMI 720p)`);
    out.push('// 用法：在 RTL 中 `include 本文件，把 UI_*_X/Y/W/H 赋给 localparam。');
    out.push('// ============================================================');
    out.push('`ifndef UI_LAYOUT_VH');
    out.push('`define UI_LAYOUT_VH');
    out.push('');
    out.push(`\`define UI_CANVAS_W 12'd${W}`);
    out.push(`\`define UI_CANVAS_H 12'd${H}`);
    out.push(`\`define UI_ELEM_COUNT ${state.elements.length}`);
    out.push('');

    state.elements.forEach((item, i) => {
      const nm = names.get(item.id);
      out.push(`// [${i}] ${TYPES[item.type].label} — ${item.name} (${item.w}x${item.h} @ ${item.x},${item.y})`);
      out.push(`\`define UI_${nm}_X 12'd${item.x}`);
      out.push(`\`define UI_${nm}_Y 12'd${item.y}`);
      out.push(`\`define UI_${nm}_W 12'd${item.w}`);
      out.push(`\`define UI_${nm}_H 12'd${item.h}`);
      out.push(`\`define UI_EL${i}_X 12'd${item.x}`);
      out.push(`\`define UI_EL${i}_Y 12'd${item.y}`);
      out.push(`\`define UI_EL${i}_W 12'd${item.w}`);
      out.push(`\`define UI_EL${i}_H 12'd${item.h}`);
      out.push('');
    });

    out.push('`endif // UI_LAYOUT_VH');
    return out.join('\n') + '\n';
  }

  function buildC() {    const names = semanticNames();
    const out = [];
    out.push('/* ============================================================');
    out.push(' * ui_layout_regs.h — generated by FPGA UI Layout Studio');
    out.push(` * ${new Date().toLocaleString('zh-CN', { hour12: false })}`);
    out.push(` * Canvas ${W} x ${H} (HDMI 720p)`);
    out.push(' * ============================================================ */');
    out.push('#ifndef UI_LAYOUT_REGS_H');
    out.push('#define UI_LAYOUT_REGS_H');
    out.push('');
    out.push(`#define UI_CANVAS_W ${W}`);
    out.push(`#define UI_CANVAS_H ${H}`);
    out.push(`#define UI_ELEM_COUNT ${state.elements.length}`);
    out.push('');
    state.elements.forEach((item, i) => {
      const nm = names.get(item.id);
      out.push(`/* [${i}] ${TYPES[item.type].label} — ${item.name.replace(/\*\//g, '* /')} */`);
      out.push(`#define UI_${nm}_X ${item.x}`);
      out.push(`#define UI_${nm}_Y ${item.y}`);
      out.push(`#define UI_${nm}_W ${item.w}`);
      out.push(`#define UI_${nm}_H ${item.h}`);
      out.push(`#define UI_EL${i}_X ${item.x}`);
      out.push(`#define UI_EL${i}_Y ${item.y}`);
      out.push(`#define UI_EL${i}_W ${item.w}`);
      out.push(`#define UI_EL${i}_H ${item.h}`);
      out.push('');
    });
    out.push('#endif /* UI_LAYOUT_REGS_H */');
    return out.join('\n') + '\n';
  }

  function codeForTab(tab) {
    if (tab === 'json') return buildJson();
    if (tab === 'c') return buildC();
    return buildVerilog();
  }

  function fileNameForTab(tab) {
    if (tab === 'json') return 'ui_layout.json';
    if (tab === 'c') return 'ui_layout_regs.h';
    return 'ui_layout.vh';
  }

  // ---------------- modal ----------------
  function openCode(tab = 'verilog') {
    state.modalMode = 'code';
    state.modalTab = tab;
    $('modalTitle').textContent = '生成配置文件';
    $('modalTabs').classList.remove('hidden');
    $('modalActions').classList.remove('hidden');
    document.querySelectorAll('.modal-tab').forEach((b) => b.classList.toggle('active', b.dataset.tab === tab));
    $('modalCode').textContent = codeForTab(tab);
    $('modal').classList.remove('hidden');
  }

  function openHelp() {
    state.modalMode = 'help';
    $('modalTitle').textContent = '使用帮助';
    $('modalTabs').classList.add('hidden');
    $('modalActions').classList.add('hidden');
    $('modalCode').textContent = HELP_TEXT.trim();
    $('modal').classList.remove('hidden');
  }

  function closeModal() {
    $('modal').classList.add('hidden');
  }

  function refreshModal() {
    if ($('modal').classList.contains('hidden')) return;
    if (state.modalMode === 'code') $('modalCode').textContent = codeForTab(state.modalTab);
  }

  const HELP_TEXT = `
FPGA UI Layout Studio — 1280 x 720 OSD 排布器

【移动】
  · 拖拽元素
  · Shift + 拖拽锁轴
  · 方向键 1px，Shift + 方向键 10px

【缩放 / 对齐】
  · 滚轮滚动，Ctrl + 滚轮缩放
  · 拖拽时自动吸附网格 / 元素边缘 / 画布中心
  · 按住 Alt 临时关闭吸附
  · 选中后可拖 8 个手柄改尺寸

【快捷键】
  Ctrl/Cmd + D   复制
  Delete         删除
  Ctrl/Cmd + Z   撤销
  Ctrl/Cmd + Y   重做
  Ctrl/Cmd + S   导出 JSON
  Esc            取消选择 / 关闭弹窗

【导出】
  · JSON：可再次导入，或交给脚本生成 RTL
  · Verilog .vh：UI_LOGO_X/Y/W/H 等宏
  · C .h：给 MCU 固件用的坐标宏

【当前 RTL 对应关系】
  Logo X/Y      -> hdmi_mixer.v  LOGO_X / LOGO_Y
  Count X/Y     -> cv_top.v  CNT_X / CNT_Y
  OSD X/Y/W/H   -> hdmi_mixer.v  DYN_OSD_X/Y/W/H
  门线 x=384    -> 检测逻辑固定 x = 0.30 x 1280

提示：W/H 对 Logo 与 Count 目前主要用于后续 24x24 字库排版，
X/Y 是可以直接落到现有 RTL 的参数。
`;

  // ---------------- export / import ----------------
  async function copyText(text) {
    try {
      await navigator.clipboard.writeText(text);
      toast('已复制到剪贴板');
    } catch (_) {
      const ta = document.createElement('textarea');
      ta.value = text;
      ta.style.position = 'fixed';
      ta.style.opacity = '0';
      document.body.appendChild(ta);
      ta.select();
      try { document.execCommand('copy'); toast('已复制到剪贴板'); } catch (err) { toast('复制失败，请手动选择文本'); }
      ta.remove();
    }
  }

  function download(filename, text) {
    const blob = new Blob([text], { type: 'text/plain;charset=utf-8' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = filename;
    document.body.appendChild(a);
    a.click();
    a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 1200);
  }

  function exportPng() {
    const saveGrid = state.grid;
    const saveSafe = state.safe;
    const saveSel = state.selectedId;
    state.grid = false;
    state.safe = false;
    state.selectedId = null;
    render();
    const out = document.createElement('canvas');
    out.width = W;
    out.height = H;
    out.getContext('2d').drawImage(canvas, 0, 0, W, H);
    const url = out.toDataURL('image/png');
    state.grid = saveGrid;
    state.safe = saveSafe;
    state.selectedId = saveSel;
    render();
    const a = document.createElement('a');
    a.href = url;
    a.download = 'ui_layout_preview.png';
    document.body.appendChild(a);
    a.click();
    a.remove();
    toast('已导出 ui_layout_preview.png');
  }

  function applyPreset(key) {
    const make = PRESETS[key];
    if (!make) return;
    const before = snapshot();
    state.elements = make();
    state.selectedId = null;
    pushHistory(before);
    refreshAll();
    saveLocal(false);
    $('presetSelect').value = key;
    toast(key === 'blank' ? '已清空画布' : '已载入预设');
  }

  function loadDesign(obj) {
    if (!obj || !Array.isArray(obj.elements)) throw new Error('不是有效的布局文件');
    const items = obj.elements.map(normalizeElement).filter(Boolean);
    state.elements = items;
    state.selectedId = null;
    state.history = [];
    state.future = [];
    refreshAll();
    saveLocal();
  }

  function importJsonFile(file) {
    const reader = new FileReader();
    reader.onload = () => {
      try {
        loadDesign(JSON.parse(String(reader.result)));
        toast(`已导入 ${state.elements.length} 个元素`);
      } catch (err) {
        toast(`导入失败：${err.message}`);
      }
    };
    reader.readAsText(file);
  }

  // ---------------- persistence / toast ----------------
  let saveTimer = null;
  function queueSave() {
    clearTimeout(saveTimer);
    saveTimer = setTimeout(saveLocal, 350);
  }

  function saveLocal(markCustom = true) {
    try {
      localStorage.setItem(STORE_KEY, JSON.stringify({ elements: state.elements, zoom: state.zoom }));
    } catch (_) { /* ignore quota */ }
    if (markCustom) {
      const sel = $('presetSelect');
      if (sel) sel.value = 'custom';
    }
  }

  function loadLocal() {
    try {
      const raw = localStorage.getItem(STORE_KEY);
      if (!raw) return false;
      const obj = JSON.parse(raw);
      if (!Array.isArray(obj.elements)) return false;
      const items = obj.elements.map(normalizeElement).filter(Boolean);
      if (!items.length) return false;
      state.elements = items;
      if (typeof obj.zoom === 'number') state.zoom = clamp(obj.zoom, 0.15, 1.4);
      return true;
    } catch (_) {
      return false;
    }
  }

  let toastTimer = null;
  function toast(msg) {
    const t = $('toast');
    t.textContent = msg;
    t.classList.add('show');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => t.classList.remove('show'), 1800);
  }

  // ---------------- view ----------------
  function setZoom(z) {
    state.zoom = clamp(z, 0.15, 1.4);
    applyZoom();
    render();
    saveLocal(false);
  }

  function applyZoom() {
    canvas.style.width = `${Math.round(W * state.zoom)}px`;
    canvas.style.height = `${Math.round(H * state.zoom)}px`;
    $('canvasShell').style.width = `${Math.round(W * state.zoom)}px`;
    $('canvasShell').style.height = `${Math.round(H * state.zoom)}px`;
    $('zoomLabel').textContent = `${Math.round(state.zoom * 100)}%`;
    $('canvasScaleLabel').textContent = `${Math.round(state.zoom * 100)}%`;
  }

  function fitView() {
    const sc = $('stageScroll');
    const availW = Math.max(200, sc.clientWidth - 76);
    const availH = Math.max(120, sc.clientHeight - 76);
    state.userZoomed = false;
    setZoom(Math.min(availW / W, availH / H));
  }

  function refreshAll() {
    if (state.selectedId && !getSelected()) state.selectedId = null;
    renderLayers();
    buildInspector();
    render();
    updateHint();
  }

  // ---------------- events ----------------
  function bind() {
    $('palette').addEventListener('click', (e) => {
      const btn = e.target.closest('[data-add]');
      if (btn) addElement(btn.dataset.add);
    });

    $('layerList').addEventListener('click', handleLayerClick);

    $('zoomOut').addEventListener('click', () => { state.userZoomed = true; setZoom(state.zoom - 0.1); });
    $('zoomIn').addEventListener('click', () => { state.userZoomed = true; setZoom(state.zoom + 0.1); });
    $('zoomFit').addEventListener('click', fitView);

    $('chkGrid').addEventListener('change', (e) => { state.grid = e.target.checked; render(); });
    $('chkSnap').addEventListener('change', (e) => { state.snap = e.target.checked; toast(e.target.checked ? '网格吸附已开' : '网格吸附已关'); });
    $('chkSafe').addEventListener('change', (e) => { state.safe = e.target.checked; render(); });
    $('gridSize').addEventListener('change', (e) => { state.gridSize = int(e.target.value, 8); render(); saveLocal(); });

    $('presetSelect').addEventListener('change', (e) => applyPreset(e.target.value));

    $('btnImport').addEventListener('click', () => $('fileImport').click());
    $('fileImport').addEventListener('change', (e) => {
      const file = e.target.files && e.target.files[0];
      if (file) importJsonFile(file);
      e.target.value = '';
    });
    $('btnExportJson').addEventListener('click', () => {
      download('ui_layout.json', buildJson());
      toast('已导出 ui_layout.json');
    });
    $('btnPng').addEventListener('click', exportPng);
    $('btnCode').addEventListener('click', () => openCode('verilog'));
    $('btnHelp').addEventListener('click', openHelp);

    $('modalClose').addEventListener('click', closeModal);
    $('modal').addEventListener('click', (e) => { if (e.target === $('modal')) closeModal(); });
    document.querySelectorAll('.modal-tab').forEach((btn) => {
      btn.addEventListener('click', () => {
        state.modalTab = btn.dataset.tab;
        document.querySelectorAll('.modal-tab').forEach((b) => b.classList.toggle('active', b === btn));
        refreshModal();
      });
    });
    $('btnCopyCode').addEventListener('click', () => copyText($('modalCode').textContent));
    $('btnDownloadCode').addEventListener('click', () => {
      if (state.modalMode !== 'code') return;
      download(fileNameForTab(state.modalTab), $('modalCode').textContent);
      toast(`已下载 ${fileNameForTab(state.modalTab)}`);
    });

    $('bgUploadBtn').addEventListener('click', () => $('bgUpload').click());
    $('bgUpload').addEventListener('change', (e) => {
      const file = e.target.files && e.target.files[0];
      if (!file) return;
      const reader = new FileReader();
      reader.onload = () => {
        const img = new Image();
        img.onload = () => { state.bgImage = img; render(); toast('背景图已载入（不导出）'); };
        img.src = String(reader.result);
      };
      reader.readAsDataURL(file);
      e.target.value = '';
    });
    $('bgResetBtn').addEventListener('click', () => { state.bgImage = null; render(); });
    $('bgOpacity').addEventListener('input', (e) => { state.bgOpacity = int(e.target.value, 100) / 100; render(); });

    $('inspectorBody').addEventListener('focusin', (e) => {
      if (e.target.matches('input, textarea, select')) state.fieldSnapshot = snapshot();
    });
    $('inspectorBody').addEventListener('input', handleFieldInput);
    $('inspectorBody').addEventListener('change', handleFieldChange);
    $('inspectorBody').addEventListener('click', handleInspectorClick);

    canvas.addEventListener('pointerdown', onPointerDown);
    window.addEventListener('pointermove', onPointerMove);
    window.addEventListener('pointerup', onPointerUp);
    canvas.addEventListener('dblclick', () => {
      const item = getSelected();
      if (item && TYPES[item.type].hasText) {
        const input = document.querySelector('#inspectorBody [data-field="text"]');
        if (input) { input.focus(); input.select(); }
      }
    });

    $('stageScroll').addEventListener('wheel', (e) => {
      if (e.ctrlKey) {
        e.preventDefault();
        state.userZoomed = true;
        setZoom(state.zoom * (e.deltaY < 0 ? 1.1 : 0.9));
      }
    }, { passive: false });

    window.addEventListener('keydown', onKeyDown);
    window.addEventListener('resize', () => { if (!state.userZoomed) fitView(); });

    if (typeof ResizeObserver !== 'undefined') {
      const ro = new ResizeObserver(() => {
        if (!state.userZoomed) fitView();
      });
      ro.observe($('stageScroll'));
    }
  }

  function onKeyDown(e) {
    if (!$('modal').classList.contains('hidden')) {
      if (e.key === 'Escape') closeModal();
      return;
    }
    const target = e.target;
    const typing = target && (target.matches('input, textarea, select') || target.isContentEditable);
    const mod = e.ctrlKey || e.metaKey;

    if (typing) {
      if (mod && e.key.toLowerCase() === 's') { e.preventDefault(); download('ui_layout.json', buildJson()); toast('已导出 ui_layout.json'); }
      return;
    }

    if (mod && e.key.toLowerCase() === 'z') {
      e.preventDefault();
      if (e.shiftKey) redo(); else undo();
      return;
    }
    if (mod && e.key.toLowerCase() === 'y') { e.preventDefault(); redo(); return; }
    if (mod && e.key.toLowerCase() === 'd') { e.preventDefault(); duplicateSelected(); return; }
    if (mod && e.key.toLowerCase() === 's') {
      e.preventDefault();
      download('ui_layout.json', buildJson());
      toast('已导出 ui_layout.json');
      return;
    }
    if (e.key === 'Delete' || e.key === 'Backspace') {
      if (getSelected()) { e.preventDefault(); deleteSelected(); }
      return;
    }
    if (e.key === 'Escape') { select(null); return; }

    const item = getSelected();
    if (!item) return;
    const step = e.shiftKey ? 10 : 1;
    let dx = 0;
    let dy = 0;
    if (e.key === 'ArrowLeft') dx = -step;
    else if (e.key === 'ArrowRight') dx = step;
    else if (e.key === 'ArrowUp') dy = -step;
    else if (e.key === 'ArrowDown') dy = step;
    else return;

    e.preventDefault();
    const before = snapshot();
    item.x = clamp(item.x + dx, 0, W - 2);
    item.y = clamp(item.y + dy, 0, H - 2);
    pushHistory(before);
    render();
    syncInspectorNumbers();
    updateHint();
    queueSave();
  }

  // ---------------- public API (automation / console) ----------------
  window.FPGAUILayout = {
    version: 1,
    storageKey: STORE_KEY,
    preset: applyPreset,
    setDesign: loadDesign,
    get design() { return JSON.parse(buildJson()); },
    json: buildJson,
    verilog: buildVerilog,
    cHeader: buildC,
    select: (id) => select(id),
    add: addElement,
    remove: deleteSelected,
    undo,
    redo,
    fit: fitView,
    exportPng,
  };

  // ---------------- init ----------------
  function init() {
    const restored = loadLocal();
    if (!restored) state.elements = PRESETS.competition();

    $('chkGrid').checked = state.grid;
    $('chkSnap').checked = state.snap;
    $('chkSafe').checked = state.safe;
    $('gridSize').value = String(state.gridSize);
    $('presetSelect').value = restored ? 'custom' : 'competition';
    state.userZoomed = restored;

    applyZoom();
    refreshAll();
    bind();

    requestAnimationFrame(() => {
      if (!restored) fitView();
      else applyZoom();
      render();
    });
  }

  init();
})();
