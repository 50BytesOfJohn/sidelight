#!/usr/bin/env python3 -I
"""Drives the running SidePanel purely through config.json hot-reload.
1) position x size matrix: checks the logged NSWindow frame against visibleFrame-derived expectations.
2) window avoidance per edge (smart mode): opens tools/testwin windows overlapping the panel, floating and
   snapped, and reads avoidance.log.
Run with the app already running. Abort if the Tauri PoC is running (both would fight over test windows)."""
import json, os, re, subprocess, sys, time

HOME = os.path.expanduser("~")
CFG = f"{HOME}/Library/Application Support/SidePanelNative/config.json"
FRAMES = f"{HOME}/Library/Logs/SidePanelNative/frames.log"
AVOID = f"{HOME}/Library/Logs/SidePanelNative/avoidance.log"
TESTWIN = os.path.join(os.path.dirname(__file__), "..", "tools", "testwin")
WIDTH = {"regular": 320, "compact": 190, "minimal": 68}
BAR = 44

def tauri_running():
    return subprocess.run(["pgrep", "-if", "sidepanel-?tauri"], capture_output=True).returncode == 0

def edit(**kw):
    c = json.load(open(CFG)); c.update(kw)
    tmp = CFG + ".tmp"; json.dump(c, open(tmp, "w"), indent=2); os.replace(tmp, CFG)   # atomic like most editors

def last_line(path, pattern):
    lines = [l for l in open(path).read().splitlines() if re.search(pattern, l)]
    return lines[-1] if lines else ""

def rect(s):
    n = list(map(float, re.findall(r"-?[\d.]+", s)))
    return n[:4]

def frame_matrix():
    print("== frame matrix (via config.json hot-reload) ==")
    vf = None; ok = True
    edit(position="bottom", size="compact"); time.sleep(1.3)   # start from a different state so left/regular is a real change
    for pos in ["left", "right", "top", "bottom"]:
        for size in (["regular", "compact", "minimal"] if pos in ("left", "right") else ["minimal"]):
            mark = len(open(FRAMES).read().splitlines())
            edit(position=pos, size=size)
            time.sleep(1.3)
            new = open(FRAMES).read().splitlines()[mark:]
            line = new[-1] if new else ""
            m = re.search(r"frame=(\{\{.*?\}\}) visibleFrame=(\{\{.*?\}\}) alpha=([\d.]+)", line)
            if not m: print(f"  {pos:6} {size:8} NO LOG"); ok = False; continue
            f, vf = rect(m.group(1)), rect(m.group(2)); alpha = float(m.group(3))
            x, y, w, h = vf
            exp = {"left": [x, y, WIDTH[size], h], "right": [x + w - WIDTH[size], y, WIDTH[size], h],
                   "top": [x, y + h - BAR, w, BAR], "bottom": [x, y, w, BAR]}[pos]
            good = all(abs(a - b) < 0.5 for a, b in zip(f, exp)) and alpha > 0.99
            ok &= good
            print(f"  {pos:6} {size:8} frame={f} expected={exp} alpha={alpha} {'OK' if good else 'MISMATCH'}")
    return ok, vf

def avoidance(vf):
    print("== avoidance per edge (smart) ==")
    x, y, w, h = vf
    cases = {
        # position: [(label, testwin frame [x,y,w,h], expected action)]
        "left":   [("floating", [40, 300, 700, 400], "shift"), ("snapped", [x, 300, 900, 400], "clip")],
        "right":  [("floating", [x + w - 450, 300, 400, 400], "shift"), ("snapped", [x + w - 800, 300, 800, 400], "clip")],
        "top":    [("floating", [400, y + h - 420, 700, 400], "shift"), ("snapped", [400, y + h - 500, 700, 500], "clip")],
        "bottom": [("floating", [400, y + 20, 700, 400], "shift"), ("snapped", [400, y, 700, 500], "clip")],
    }
    results = []
    for pos, cs in cases.items():
        edit(position=pos, size="regular", avoidMode="smart")
        time.sleep(1.3)
        for label, fr, expect in cs:
            if tauri_running(): print("  Tauri PoC started; aborting avoidance test"); return results
            mark = len(open(AVOID).read().splitlines()) if os.path.exists(AVOID) else 0
            out = subprocess.run([TESTWIN] + [str(v) for v in fr], capture_output=True, text=True).stdout
            time.sleep(0.3)
            new = [l for l in open(AVOID).read().splitlines()[mark:] if "testwin" in l]
            end = re.search(r"end frame=(.*)", out)
            line = new[0] if new else "NO FIX LOGGED"
            act = re.search(r"action=(\S+)", line)
            got = act.group(1) if act else "-"
            good = got.startswith(expect)
            results.append((pos, label, good))
            print(f"  {pos:6} {label:8} start={fr} end={end.group(1) if end else '?'} action={got} expected={expect} {'OK' if good else 'CHECK'}")
            d = re.search(r"delay_ms=([\d.]+)", line)
            e = re.search(r"edge=(\S+)", line)
            if d and e: print(f"         delay_ms={d.group(1)} edge={e.group(1)}")
    return results

if __name__ == "__main__":
    if tauri_running() and "--no-avoid" not in sys.argv: sys.exit("Tauri PoC is running; retry later")
    orig = open(CFG).read()
    try:
        ok, vf = frame_matrix()
        if "--no-avoid" not in sys.argv: avoidance(vf)
    finally:
        open(CFG + ".tmp", "w").write(orig); os.replace(CFG + ".tmp", CFG)   # restore
        print("config restored")
