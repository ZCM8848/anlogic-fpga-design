# -*- coding: utf-8 -*-
"""
Orange LED blink-timing analyser for an Ethernet-port video.

What it does
------------
1. Decodes the video frame by frame and locates the orange link/activity LED
   (bright orange blob, tracked over the whole clip while the camera moves).
2. Samples the LED core brightness on every frame at the tracked position.
   The green LED (which is continuously on) is used as a visibility control,
   so periods where the port is out of view are excluded.
3. Classifies every frame as ON / OFF (Otsu threshold on the LED brightness),
   converts the frame sequence into ON/OFF intervals and writes the results.

Outputs (default: <script dir>/results/)
----------------------------------------
  frames.csv          one row per video frame: time, state, LED brightness, ...
  events.csv          ON/OFF intervals with best-estimate start/end times
  off_pulses.csv      only the "off" pulses (what the eye sees as the blink)
  summary.txt         human readable statistics
  led_timeline.png    brightness waveform + ON/OFF state over the whole clip
  led_timeline_zoom.png  4 x 8 s zoom panels
  led_brightness_hist.png  bimodal histogram + chosen threshold
  verification.jpg    contact sheet with the tracked LED marked
  led_on_off_zoom.png close-up of the LED in the ON and OFF state
  led_tracked.mp4     2x zoomed verification video

Timing resolution
-----------------
The clip is ~29 fps, so every transition is known to +/- one frame
(about +/-17 ms); the reported transition time is the midpoint between the
last frame in the old state and the first frame in the new state.
"""

import argparse
import csv
import os
import subprocess
import sys

import cv2
import numpy as np
import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt


# --------------------------------------------------------------------------- #
# helpers
# --------------------------------------------------------------------------- #
def run_ffprobe(args):
    try:
        out = subprocess.run(["ffprobe", "-v", "error"] + args,
                             capture_output=True, text=True, check=True)
        return out.stdout
    except FileNotFoundError:
        sys.exit("ffprobe not found - please install FFmpeg and add it to PATH.")
    except subprocess.CalledProcessError as exc:
        sys.exit("ffprobe failed:\n" + exc.stderr)


def read_timestamps(video):
    """Presentation time (seconds) of every decoded video frame."""
    txt = run_ffprobe(["-select_streams", "v:0", "-show_entries",
                       "frame=pts_time", "-of", "csv=p=0", video])
    pts = []
    for tok in txt.replace(",", " ").split():
        try:
            pts.append(float(tok))
        except ValueError:
            pass
    if not pts:
        sys.exit("ffprobe returned no video frames.")
    return np.asarray(pts, dtype=np.float64)


def read_meta(video):
    txt = run_ffprobe(["-select_streams", "v:0", "-show_entries",
                       "stream=width,height,avg_frame_rate,nb_frames,duration",
                       "-of", "default=nw=1", video])
    meta = {}
    for line in txt.splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            meta[k] = v
    return meta


# --------------------------------------------------------------------------- #
# detection
# --------------------------------------------------------------------------- #
def orange_candidates(frame):
    """Connected components of saturated orange pixels.

    Returns [(area, cx, cy, x, y, w, h)].  The orange plastic window around the
    LED usually shows up as two lobes (left/right of the blown-out white core),
    so the caller uses the bounding box of the lobes to look for the core.
    """
    b = frame[:, :, 0].astype(np.int16)
    g = frame[:, :, 1].astype(np.int16)
    r = frame[:, :, 2].astype(np.int16)
    mask = ((r >= 190) & (r - g >= 45) & (g - b >= 25)).astype(np.uint8)
    n, _lab, stats, cents = cv2.connectedComponentsWithStats(mask, 8)
    out = []
    for j in range(1, n):
        area = int(stats[j, cv2.CC_STAT_AREA])
        if area < 15:
            continue
        out.append((area, float(cents[j][0]), float(cents[j][1]),
                    int(stats[j, cv2.CC_STAT_LEFT]), int(stats[j, cv2.CC_STAT_TOP]),
                    int(stats[j, cv2.CC_STAT_WIDTH]), int(stats[j, cv2.CC_STAT_HEIGHT])))
    return out


def green_visible(frame):
    """Is the (always-on) green LED visible?  Used as a port-in-view control."""
    b = frame[:, :, 0].astype(np.int16)
    g = frame[:, :, 1].astype(np.int16)
    r = frame[:, :, 2].astype(np.int16)
    mask = ((g >= 150) & (g - r >= 60) & (g - b >= 60)).astype(np.uint8)
    n, _lab, stats, _c = cv2.connectedComponentsWithStats(mask, 8)
    return any(int(stats[j, cv2.CC_STAT_AREA]) >= 5 for j in range(1, n))


def sample_core(frame, x, y, half=3):
    """Brightness of the LED core: max red value in a (2*half+1)^2 window."""
    h, w = frame.shape[:2]
    x0, x1 = max(0, int(round(x)) - half), min(w, int(round(x)) + half + 1)
    y0, y1 = max(0, int(round(y)) - half), min(h, int(round(y)) + half + 1)
    patch = frame[y0:y1, x0:x1, 2].astype(np.int16)
    return int(patch.max()) if patch.size else 0


def measure(video, n_frames):
    cap = cv2.VideoCapture(video)
    if not cap.isOpened():
        sys.exit(f"cannot open {video}")

    area = np.zeros(n_frames)
    cx = np.full(n_frames, np.nan)
    cy = np.full(n_frames, np.nan)
    seen = np.zeros(n_frames, dtype=bool)
    green = np.zeros(n_frames, dtype=bool)

    i = 0
    prev = None
    while i < n_frames:
        ok, frame = cap.read()
        if not ok:
            break
        cand = orange_candidates(frame)
        if cand:
            # follow the LED window that is closest to the previous position
            if prev is None:
                # first fix: the LED's blown-out core is the whitest compact
                # blob inside an orange housing (the yellow cable has no white
                # core, and reflections are more orange/less white)
                b = frame[:, :, 0].astype(np.int16)
                g = frame[:, :, 1].astype(np.int16)
                r = frame[:, :, 2].astype(np.int16)

                def white_count(c):
                    x0, y0, w, h = c[3], c[4], c[5], c[6]
                    rr = r[y0:y0 + h, x0:x0 + w]
                    gg = g[y0:y0 + h, x0:x0 + w]
                    bb = b[y0:y0 + h, x0:x0 + w]
                    return int(((rr >= 245) & (gg >= 225) & (bb >= 170)).sum())

                ref = max(cand, key=white_count)
            else:
                ref = min(cand, key=lambda c: np.hypot(c[1] - prev[0], c[2] - prev[1]))
            # use only this component's box: merging nearby components would let
            # bright reflections on the metal pull the centroid away from the LED
            x0 = max(0, ref[3] - 2)
            y0 = max(0, ref[4] - 2)
            x1 = min(frame.shape[1], ref[3] + ref[5] + 2)
            y1 = min(frame.shape[0], ref[4] + ref[6] + 2)
            patch = frame[y0:y1, x0:x1, 2].astype(np.int16)
            mx = int(patch.max()) if patch.size else 0
            # the LED core is the brightest spot inside the orange window
            if mx >= 240:
                yy, xx = np.nonzero(patch >= mx - 8)
                nx = x0 + float(xx.mean())
                ny = y0 + float(yy.mean())
                cx[i], cy[i] = nx, ny
                area[i] = ref[0]
                seen[i] = True
                prev = (nx, ny)
        green[i] = green_visible(frame)
        i += 1
    cap.release()
    if i != n_frames:
        print(f"warning: decoded {i} of {n_frames} frames")

    # LED centre through frames where the LED is off: interpolate the path
    idx = np.nonzero(seen)[0]
    if len(idx) < 10:
        sys.exit("orange LED was not found reliably - check the colour thresholds.")
    xi = np.interp(np.arange(n_frames), idx, cx[idx])
    yi = np.interp(np.arange(n_frames), idx, cy[idx])

    # second pass: sample the LED core at the interpolated positions
    core = np.zeros(n_frames)
    cap = cv2.VideoCapture(video)
    i = 0
    while True:
        ok, frame = cap.read()
        if not ok:
            break
        core[i] = sample_core(frame, xi[i], yi[i])
        i += 1
    cap.release()

    return dict(area=area, cx=xi, cy=yi, seen=seen, green=green, core=core)


# --------------------------------------------------------------------------- #
# classification
# --------------------------------------------------------------------------- #
def otsu_threshold(values):
    vals = np.asarray(values, dtype=np.float64)
    hist, edges = np.histogram(vals, bins=256)
    centers = (edges[:-1] + edges[1:]) / 2.0
    total = hist.sum()
    w0 = np.cumsum(hist)
    w1 = total - w0
    m0 = np.cumsum(hist * centers)
    mt = m0[-1]
    valid = (w0 > 0) & (w1 > 0)
    between = np.zeros_like(centers)
    mu0 = np.divide(m0, w0, out=np.zeros_like(m0), where=w0 > 0)
    mu1 = np.divide(mt - m0, w1, out=np.zeros_like(m0), where=w1 > 0)
    between[valid] = w0[valid] * w1[valid] * (mu0[valid] - mu1[valid]) ** 2
    return float(centers[int(np.argmax(between))])


def build_events(state, t):
    """Convert a boolean per-frame state into intervals.

    Transition time = midpoint between the last frame of the old state and the
    first frame of the new state.
    """
    events = []
    n = len(state)
    start = 0
    for i in range(1, n + 1):
        if i == n or state[i] != state[start]:
            s, e = start, i - 1
            if s == 0:
                t_on = t[0]
            else:
                t_on = 0.5 * (t[s - 1] + t[s])
            if e == n - 1:
                t_off = t[-1]
            else:
                t_off = 0.5 * (t[e] + t[e + 1])
            events.append(dict(state=bool(state[start]), first_frame=s,
                               last_frame=e, first_time=t[s], last_time=t[e],
                               start=t_on, end=t_off, duration=t_off - t_on))
            start = i
    return events


# --------------------------------------------------------------------------- #
# main
# --------------------------------------------------------------------------- #
def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("video", nargs="?",
                    default=r"C:\Users\Z___C\Downloads\3cf24ad916cfc541522e8355c18f846a_cropped.mp4",
                    help="input video")
    ap.add_argument("-o", "--outdir", default=None,
                    help="output directory (default: <script dir>/results)")
    args = ap.parse_args()

    here = os.path.dirname(os.path.abspath(__file__))
    outdir = args.outdir or os.path.join(here, "results")
    os.makedirs(outdir, exist_ok=True)

    ts = read_timestamps(args.video)
    meta = read_meta(args.video)
    n = len(ts)
    print(f"{n} frames, {meta.get('width')}x{meta.get('height')}, "
          f"duration {ts[-1]:.3f} s, avg {meta.get('avg_frame_rate')} fps")

    data = measure(args.video, n)
    core, green = data["core"], data["green"]

    valid = np.nonzero(green)[0]
    if len(valid) == 0:
        sys.exit("the green LED is never visible - wrong clip?")
    first, last = int(valid[0]), int(valid[-1])
    sl = slice(first, last + 1)

    thr = otsu_threshold(core[sl])
    on = core >= thr
    on[:first] = False
    on[last + 1:] = False

    # make sure the two clusters are really separated
    off_vals = core[sl][~on[sl]]
    on_vals = core[sl][on[sl]]
    print(f"threshold {thr:.0f}  (off max {off_vals.max() if off_vals.size else 0}, "
          f"on min {on_vals.min() if on_vals.size else 0})")

    events = build_events(on[sl], ts[sl])
    off_pulses = [e for e in events if not e["state"]]

    # ----------------------------- CSV ------------------------------------ #
    with open(os.path.join(outdir, "frames.csv"), "w", newline="", encoding="utf-8") as fh:
        wr = csv.writer(fh)
        wr.writerow(["frame", "time_s", "visible", "state", "led_core_R",
                     "orange_area_px", "led_cx", "led_cy"])
        for i in range(n):
            wr.writerow([i, f"{ts[i]:.6f}", int(green[i]),
                         "ON" if on[i] else "OFF", core[i],
                         int(data["area"][i]) if data["seen"][i] else 0,
                         f"{data['cx'][i]:.2f}", f"{data['cy'][i]:.2f}"])

    with open(os.path.join(outdir, "events.csv"), "w", newline="", encoding="utf-8") as fh:
        wr = csv.writer(fh)
        wr.writerow(["#", "state", "first_frame", "last_frame",
                     "first_time_s", "last_time_s",
                     "start_s", "end_s", "duration_s"])
        for k, e in enumerate(events, 1):
            wr.writerow([k, "ON" if e["state"] else "OFF", e["first_frame"],
                         e["last_frame"], f"{e['first_time']:.6f}",
                         f"{e['last_time']:.6f}", f"{e['start']:.6f}",
                         f"{e['end']:.6f}", f"{e['duration']:.6f}"])

    with open(os.path.join(outdir, "off_pulses.csv"), "w", newline="", encoding="utf-8") as fh:
        wr = csv.writer(fh)
        wr.writerow(["#", "start_s", "end_s", "duration_s", "frames",
                     "gap_from_prev_end_s"])
        prev_end = None
        for k, e in enumerate(off_pulses, 1):
            gap = "" if prev_end is None else f"{e['start'] - prev_end:.3f}"
            wr.writerow([k, f"{e['start']:.6f}", f"{e['end']:.6f}",
                         f"{e['duration']:.6f}",
                         e["last_frame"] - e["first_frame"] + 1, gap])
            prev_end = e["end"]

    # ----------------------------- summary -------------------------------- #
    def stats(vals):
        v = np.asarray(vals, dtype=float)
        if v.size == 0:
            return "n/a"
        return (f"n={v.size}  mean={v.mean()*1000:.0f} ms  "
                f"median={np.median(v)*1000:.0f} ms  "
                f"min={v.min()*1000:.0f} ms  max={v.max()*1000:.0f} ms")

    on_dur = [e["duration"] for e in events if e["state"]]
    off_dur = [e["duration"] for e in off_pulses]
    off_starts = np.array([e["start"] for e in off_pulses])
    off_intervals = np.diff(off_starts) if len(off_starts) > 1 else np.array([])
    total = ts[last] - ts[first]
    duty = (on[first:last + 1].sum() * np.median(np.diff(ts))) / total

    lines = []
    lines.append("Orange LED blink timing - summary")
    lines.append("=" * 46)
    lines.append(f"video          : {os.path.basename(args.video)}")
    lines.append(f"frames         : {n}  ({meta.get('width')}x{meta.get('height')})")
    lines.append(f"frame interval : {np.median(np.diff(ts))*1000:.2f} ms "
                 f"(~{1/np.median(np.diff(ts)):.2f} fps)")
    lines.append(f"visible window : {ts[first]:.3f} - {ts[last]:.3f} s "
                 f"({total:.3f} s, frames {first}-{last})")
    lines.append("")
    lines.append(f"brightness threshold : R = {thr:.0f}  "
                 f"(off cluster max {off_vals.max() if off_vals.size else 0}, "
                 f"on cluster min {on_vals.min() if on_vals.size else 0})")
    lines.append(f"ON frames  : {int(on[first:last+1].sum())} "
                 f"({100*on[first:last+1].mean():.1f} %)")
    lines.append(f"OFF frames : {int((~on[first:last+1]).sum())} "
                 f"({100*(~on[first:last+1]).mean():.1f} %)")
    lines.append(f"time ON    : {duty*100:.1f} % of the visible window")
    lines.append("")
    lines.append(f"ON  intervals : {stats(on_dur)}")
    lines.append(f"OFF pulses    : {stats(off_dur)}")
    lines.append(f"gap between OFF pulses (start-to-start): {stats(off_intervals)}")
    lines.append("")
    lines.append("OFF pulse list (the visible 'blinks'):")
    lines.append("  #   start[s]   end[s]  dur[ms]")
    for k, e in enumerate(off_pulses, 1):
        lines.append(f"  {k:2d}  {e['start']:8.3f}  {e['end']:7.3f}  "
                     f"{e['duration']*1000:7.0f}")
    lines.append("")
    lines.append("Note: transitions are located to +/- one frame "
                 f"(+/-{np.median(np.diff(ts))*500:.0f} ms).")
    text = "\n".join(lines)
    with open(os.path.join(outdir, "summary.txt"), "w", encoding="utf-8") as fh:
        fh.write(text + "\n")
    print(text)

    # ----------------------------- plots ---------------------------------- #
    tt = ts[first:last + 1]
    cc = core[first:last + 1]
    oo = on[first:last + 1]

    fig, ax = plt.subplots(2, 1, figsize=(16, 6), sharex=True,
                           gridspec_kw={"height_ratios": [3, 1]})
    ax[0].plot(tt, cc, lw=0.8, color="#c0392b")
    ax[0].axhline(thr, ls="--", lw=0.8, color="0.4",
                  label=f"threshold R={thr:.0f}")
    ax[0].fill_between(tt, 0, 260, where=~oo, color="#2c3e50", alpha=0.18,
                       step="mid", label="OFF")
    ax[0].set_ylim(0, 265)
    ax[0].set_ylabel("LED core brightness (red channel)")
    ax[0].legend(loc="lower right", fontsize=8)
    ax[0].grid(alpha=0.25)
    ax[1].step(tt, oo.astype(int), where="mid", color="#2c3e50")
    ax[1].set_ylim(-0.2, 1.2)
    ax[1].set_yticks([0, 1])
    ax[1].set_yticklabels(["OFF", "ON"])
    ax[1].set_xlabel("video time [s]")
    ax[1].grid(alpha=0.25)
    ax[1].set_xlim(tt[0], tt[-1])
    fig.suptitle("Orange LED of the Ethernet port - brightness and ON/OFF state")
    fig.tight_layout()
    fig.savefig(os.path.join(outdir, "led_timeline.png"), dpi=150)
    plt.close(fig)

    # zoom panels
    span = tt[-1] - tt[0]
    npanel = 4
    seg = np.ceil(span / npanel)
    fig, axes = plt.subplots(npanel, 1, figsize=(16, 9), sharey=True)
    for k in range(npanel):
        a = tt[0] + k * seg
        b = min(a + seg, tt[-1])
        m = (tt >= a) & (tt <= b)
        axes[k].plot(tt[m], cc[m], lw=1.0, color="#c0392b")
        axes[k].fill_between(tt[m], 0, 260, where=~oo[m], color="#2c3e50",
                             alpha=0.18, step="mid")
        axes[k].axhline(thr, ls="--", lw=0.7, color="0.4")
        axes[k].set_xlim(a, b)
        axes[k].set_ylim(0, 265)
        axes[k].grid(alpha=0.25)
        axes[k].set_ylabel("R")
        axes[k].set_title(f"{a:.1f} - {b:.1f} s", fontsize=8, loc="right")
    axes[-1].set_xlabel("video time [s]")
    fig.suptitle("Orange LED - zoomed blink waveform")
    fig.tight_layout()
    fig.savefig(os.path.join(outdir, "led_timeline_zoom.png"), dpi=150)
    plt.close(fig)

    fig, ax = plt.subplots(figsize=(8, 4))
    ax.hist(core[sl], bins=np.arange(0, 261, 5), color="#c0392b")
    ax.axvline(thr, ls="--", color="0.3", label=f"threshold {thr:.0f}")
    ax.set_xlabel("LED core brightness (red channel)")
    ax.set_ylabel("frames")
    ax.set_title("Brightness histogram - clearly bimodal")
    ax.legend()
    fig.tight_layout()
    fig.savefig(os.path.join(outdir, "led_brightness_hist.png"), dpi=150)
    plt.close(fig)

    # ------------------------ verification assets ------------------------- #
    # contact sheet: at most ~72 evenly spaced frames, LED circled
    cap0 = cv2.VideoCapture(args.video)
    ok, tmp_frame = cap0.read()
    fh_, fw_ = tmp_frame.shape[:2] if ok else (1, 1)
    cap0.release()
    if fw_ <= 250:
        zoom = 2.0
    elif fw_ <= 700:
        zoom = 1.0
    else:
        zoom = 360.0 / fw_
    step = max(1, int(np.ceil((last - first + 1) / 72)))
    picks = list(range(first, last + 1, step))
    cols = 8
    rown = int(np.ceil(len(picks) / cols))
    th, tw = int(round(fh_ * zoom)), int(round(fw_ * zoom))
    ring_r = max(6, int(round(min(fw_, fh_) * 0.05 * zoom)))
    sheet = np.zeros((rown * th, cols * tw, 3), np.uint8)
    cap = cv2.VideoCapture(args.video)
    for k, i in enumerate(picks):
        cap.set(cv2.CAP_PROP_POS_FRAMES, i)
        ok, frame = cap.read()
        if not ok:
            continue
        img = cv2.resize(frame, (tw, th), interpolation=cv2.INTER_AREA)
        if data["seen"][i]:
            cv2.circle(img, (int(round(data["cx"][i] * zoom)),
                             int(round(data["cy"][i] * zoom))), ring_r,
                       (0, 255, 255), 2)
        label = f"{ts[i]:.2f}s {'ON ' if on[i] else 'off'}"
        cv2.putText(img, label, (2, 14), cv2.FONT_HERSHEY_SIMPLEX, 0.4,
                    (0, 0, 0), 2)
        cv2.putText(img, label, (2, 14), cv2.FONT_HERSHEY_SIMPLEX, 0.4,
                    (255, 255, 255), 1)
        r, c = divmod(k, cols)
        sheet[r * th:(r + 1) * th, c * tw:(c + 1) * tw] = img
    cap.release()
    cv2.imwrite(os.path.join(outdir, "verification.jpg"), sheet,
                [cv2.IMWRITE_JPEG_QUALITY, 80])

    # side-by-side close-up: a long ON frame vs a long OFF frame
    on_idx = [i for i in range(first, last + 1) if on[i]]
    off_idx = [i for i in range(first, last + 1) if not on[i]]
    if on_idx and off_idx:
        # a frame right before the longest OFF pulse (same camera position)
        longest = max(off_pulses, key=lambda e: e["last_frame"] - e["first_frame"])
        i_on = longest["first_frame"] + first - 1
        i_off = (longest["first_frame"] + longest["last_frame"]) // 2 + first
        half = max(20, int(round(min(fw_, fh_) * 0.06)))
        zcrop = max(2, min(8, int(round(520 / (2 * half)))))
        tiles = []
        cap = cv2.VideoCapture(args.video)
        for i, tag in ((i_on, "ON"), (i_off, "OFF")):
            cap.set(cv2.CAP_PROP_POS_FRAMES, i)
            ok, frame = cap.read()
            if not ok:
                continue
            cx_, cy_ = int(round(data["cx"][i])), int(round(data["cy"][i]))
            x0 = np.clip(cx_ - half, 0, frame.shape[1] - 1)
            x1 = np.clip(cx_ + half, 1, frame.shape[1])
            y0 = np.clip(cy_ - half, 0, frame.shape[0] - 1)
            y1 = np.clip(cy_ + half, 1, frame.shape[0])
            crop = frame[y0:y1, x0:x1]
            crop = cv2.resize(crop, None, fx=zcrop, fy=zcrop,
                              interpolation=cv2.INTER_NEAREST)
            crop = cv2.copyMakeBorder(crop, 26, 4, 4, 4, cv2.BORDER_CONSTANT,
                                      value=(30, 30, 30))
            cv2.putText(crop, f"{tag}  {ts[i]:.2f}s  R={core[i]}", (6, 19),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.55, (255, 255, 255), 1)
            tiles.append(crop)
        cap.release()
        if tiles:
            h = max(t.shape[0] for t in tiles)
            w = sum(t.shape[1] for t in tiles)
            comp = np.full((h, w, 3), 30, np.uint8)
            x = 0
            for t in tiles:
                comp[:t.shape[0], x:x + t.shape[1]] = t
                x += t.shape[1]
            cv2.imwrite(os.path.join(outdir, "led_on_off_zoom.png"), comp)

    # zoomed verification video with the LED marked and the state printed
    zoom_v = 2.0 if fw_ <= 250 else 1.0
    if max(fw_, fh_) * zoom_v > 760:
        zoom_v = 760.0 / max(fw_, fh_)
    vw_out = int(fw_ * zoom_v) // 2 * 2
    vh_out = int(fh_ * zoom_v) // 2 * 2
    ring_v = max(6, int(round(min(fw_, fh_) * 0.05 * zoom_v)))
    fourcc = cv2.VideoWriter_fourcc(*"mp4v")
    fps = 1.0 / np.median(np.diff(ts))
    raw_path = os.path.join(outdir, "_tracked_raw.mp4")
    vid_out = cv2.VideoWriter(raw_path, fourcc, fps, (vw_out, vh_out))
    cap = cv2.VideoCapture(args.video)
    i = 0
    while True:
        ok, frame = cap.read()
        if not ok:
            break
        img = cv2.resize(frame, (vw_out, vh_out), interpolation=cv2.INTER_AREA)
        if green[i]:
            cv2.circle(img, (int(round(data["cx"][i] * zoom_v)),
                             int(round(data["cy"][i] * zoom_v))), ring_v,
                       (0, 255, 255), 2)
        label = f"{ts[i]:6.2f}s  {'ON' if on[i] else 'OFF'}"
        cv2.putText(img, label, (4, 20), cv2.FONT_HERSHEY_SIMPLEX, 0.55,
                    (0, 0, 0), 2)
        cv2.putText(img, label, (4, 20), cv2.FONT_HERSHEY_SIMPLEX, 0.55,
                    (255, 255, 255), 1)
        vid_out.write(img)
        i += 1
    cap.release()
    vid_out.release()
    final_path = os.path.join(outdir, "led_tracked.mp4")
    try:
        subprocess.run(["ffmpeg", "-y", "-v", "error", "-i", raw_path,
                        "-c:v", "libx264", "-preset", "veryfast", "-crf", "24",
                        "-pix_fmt", "yuv420p", "-movflags", "+faststart",
                        final_path], check=True)
        os.remove(raw_path)
    except Exception:
        os.replace(raw_path, final_path)

    print(f"\nresults written to {outdir}")


if __name__ == "__main__":
    main()
