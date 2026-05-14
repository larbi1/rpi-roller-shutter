#!/usr/bin/env python3
"""
Waveshare RPi Relay Board (B) — Roller Shutter Web Controller v1.2.0
REST API + live HTML dashboard for 4-shutter control on Raspberry Pi 5.

Usage:
    python3 shutter_web.py            # listens on 0.0.0.0:8081
    PORT=9090 python3 shutter_web.py

Requires: flask  (sudo apt install python3-flask)
"""

import fcntl
import os
import subprocess
import time
from contextlib import contextmanager
from flask import Flask, jsonify, render_template, request

# ── Config ────────────────────────────────────────────────────────
SHUTTER_SCRIPT = os.environ.get("SHUTTER_SCRIPT", "/usr/local/bin/shutter_control.sh")
SHUTTER_HOME   = os.environ.get("SHUTTER_HOME", "/home/akaw/waveshare-shutter")
STATE_DIR      = "/tmp/shutter_board"
CONFIG_DIR     = os.path.join(SHUTTER_HOME, "config")
HOST           = "0.0.0.0"
PORT           = int(os.environ.get("PORT", 8081))

SHUTTERS = [1, 2, 3, 4]
RELAY_MAP = {
    1: {"up_bcm": 5,  "down_bcm": 6},
    2: {"up_bcm": 13, "down_bcm": 16},
    3: {"up_bcm": 19, "down_bcm": 20},
    4: {"up_bcm": 21, "down_bcm": 26},
}

app = Flask(__name__)

# ── Lock files (cross-process mutex with button_daemon.py) ─────────

@contextmanager
def _lock(sh: int):
    """Blocking exclusive flock on sh{N}.lock (sh=0: global). Waits up to 6 s."""
    os.makedirs(STATE_DIR, exist_ok=True)
    path = os.path.join(STATE_DIR, f"sh{sh}.lock")
    deadline = time.monotonic() + 6.0
    with open(path, "w") as fd:
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except OSError:
                if time.monotonic() >= deadline:
                    break
                time.sleep(0.05)
        try:
            yield
        finally:
            try:
                fcntl.flock(fd, fcntl.LOCK_UN)
            except OSError:
                pass

# ── Config helpers ─────────────────────────────────────────────────

_CONF_DEFAULTS = {
    "NAME":      lambda sh: f"SH{sh}",
    "END_STOPS": lambda _: "yes",
    "UP_MS":     lambda _: "25000",
    "DOWN_MS":   lambda _: "25000",
}


def _read_config(sh: int) -> dict:
    """Parse shN.conf key=value file. Returns defaults for missing keys."""
    result = {k: fn(sh) for k, fn in _CONF_DEFAULTS.items()}
    path = os.path.join(CONFIG_DIR, f"sh{sh}.conf")
    try:
        with open(path) as fh:
            for line in fh:
                line = line.strip()
                if "=" in line and not line.startswith("#"):
                    k, _, v = line.partition("=")
                    result[k.strip()] = v.strip()
    except FileNotFoundError:
        pass
    return result


def _write_config(sh: int, data: dict) -> None:
    """Write/update key=value pairs in shN.conf (bash-compatible format)."""
    os.makedirs(CONFIG_DIR, exist_ok=True)
    path = os.path.join(CONFIG_DIR, f"sh{sh}.conf")
    existing: dict = {}
    try:
        with open(path) as fh:
            for line in fh:
                line = line.strip()
                if "=" in line and not line.startswith("#"):
                    k, _, v = line.partition("=")
                    existing[k.strip()] = v.strip()
    except FileNotFoundError:
        pass
    existing.update(data)
    with open(path, "w") as fh:
        for k, v in existing.items():
            fh.write(f"{k}={v}\n")

# ── Helpers ───────────────────────────────────────────────────────

def _run(args: list[str], timeout: int = 60) -> tuple[bool, str]:
    env = {**os.environ, "SHUTTER_HOME": SHUTTER_HOME}
    try:
        r = subprocess.run(
            [SHUTTER_SCRIPT] + args,
            capture_output=True, text=True, timeout=timeout, env=env,
        )
        return r.returncode == 0, (r.stdout + r.stderr).strip()
    except subprocess.TimeoutExpired:
        return False, "Command timed out"
    except Exception as exc:
        return False, str(exc)


def _read_state(sh: int) -> str:
    try:
        with open(os.path.join(STATE_DIR, f"sh{sh}.state")) as fh:
            return fh.read().strip()
    except FileNotFoundError:
        return "stopped"


def _read_pos(sh: int) -> int:
    try:
        with open(os.path.join(STATE_DIR, f"sh{sh}.pos")) as fh:
            return max(0, min(100, int(fh.read().strip())))
    except (FileNotFoundError, ValueError):
        return 50


def _all_states() -> dict:
    return {
        str(sh): {
            "state":    _read_state(sh),
            "position": _read_pos(sh),
            "up_bcm":   RELAY_MAP[sh]["up_bcm"],
            "down_bcm": RELAY_MAP[sh]["down_bcm"],
        }
        for sh in SHUTTERS
    }


def _sh_json(sh: int, ok: bool, msg: str) -> dict:
    return {
        "shutter":  sh,
        "state":    _read_state(sh),
        "position": _read_pos(sh),
        "success":  ok,
        "message":  msg,
        **RELAY_MAP[sh],
    }

# ── Routes ────────────────────────────────────────────────────────

@app.route("/")
def index():
    return render_template("index.html")


@app.route("/api/status")
def api_status():
    return jsonify({"shutters": _all_states()})


@app.route("/api/shutter/<int:sh>/up", methods=["POST"])
def shutter_up(sh: int):
    if sh not in SHUTTERS:
        return jsonify({"error": f"Invalid shutter {sh}. Valid: 1-4"}), 400
    with _lock(sh):
        ok, msg = _run(["up", str(sh)])
    return jsonify(_sh_json(sh, ok, msg)), 200 if ok else 500


@app.route("/api/shutter/<int:sh>/down", methods=["POST"])
def shutter_down(sh: int):
    if sh not in SHUTTERS:
        return jsonify({"error": f"Invalid shutter {sh}. Valid: 1-4"}), 400
    with _lock(sh):
        ok, msg = _run(["down", str(sh)])
    return jsonify(_sh_json(sh, ok, msg)), 200 if ok else 500


@app.route("/api/shutter/<int:sh>/stop", methods=["POST"])
def shutter_stop(sh: int):
    if sh not in SHUTTERS:
        return jsonify({"error": f"Invalid shutter {sh}. Valid: 1-4"}), 400
    with _lock(sh):
        ok, msg = _run(["stop", str(sh)])
    return jsonify(_sh_json(sh, ok, msg)), 200 if ok else 500


@app.route("/api/shutter/<int:sh>/open", methods=["POST"])
def shutter_open(sh: int):
    if sh not in SHUTTERS:
        return jsonify({"error": f"Invalid shutter {sh}. Valid: 1-4"}), 400
    cfg = _read_config(sh)
    ms = request.args.get("ms", cfg["UP_MS"])
    if not str(ms).isdigit() or int(ms) < 1:
        return jsonify({"error": "ms must be a positive integer"}), 400
    with _lock(sh):
        ok, msg = _run(["open", str(sh), str(ms)], timeout=int(ms) // 1000 + 5)
    return jsonify(_sh_json(sh, ok, msg)), 200 if ok else 500


@app.route("/api/shutter/<int:sh>/close", methods=["POST"])
def shutter_close(sh: int):
    if sh not in SHUTTERS:
        return jsonify({"error": f"Invalid shutter {sh}. Valid: 1-4"}), 400
    cfg = _read_config(sh)
    ms = request.args.get("ms", cfg["DOWN_MS"])
    if not str(ms).isdigit() or int(ms) < 1:
        return jsonify({"error": "ms must be a positive integer"}), 400
    with _lock(sh):
        ok, msg = _run(["close", str(sh), str(ms)], timeout=int(ms) // 1000 + 5)
    return jsonify(_sh_json(sh, ok, msg)), 200 if ok else 500


@app.route("/api/shutter/<int:sh>/calibrate", methods=["POST"])
def shutter_calibrate(sh: int):
    if sh not in SHUTTERS:
        return jsonify({"error": f"Invalid shutter {sh}. Valid: 1-4"}), 400
    cfg = _read_config(sh)
    total_ms = int(cfg["UP_MS"]) + int(cfg["DOWN_MS"]) + 2000
    if cfg["END_STOPS"] == "yes":
        total_ms = int(total_ms * 1.3)
    timeout = total_ms // 1000 + 10
    with _lock(sh):
        ok, msg = _run(["calibrate", str(sh)], timeout=timeout)
    return jsonify(_sh_json(sh, ok, msg)), 200 if ok else 500


@app.route("/api/shutter/<int:sh>/pos", methods=["POST"])
def shutter_pos(sh: int):
    if sh not in SHUTTERS:
        return jsonify({"error": f"Invalid shutter {sh}. Valid: 1-4"}), 400
    pct = request.args.get("pct", "")
    if not str(pct).isdigit() or not (0 <= int(pct) <= 100):
        return jsonify({"error": "pct must be 0–100"}), 400
    cfg = _read_config(sh)
    max_ms = max(int(cfg["UP_MS"]), int(cfg["DOWN_MS"]))
    with _lock(sh):
        ok, msg = _run(["pos", str(sh), str(pct)], timeout=max_ms // 1000 + 5)
    return jsonify(_sh_json(sh, ok, msg)), 200 if ok else 500


@app.route("/api/shutter/<int:sh>/setpos", methods=["POST"])
def shutter_setpos(sh: int):
    if sh not in SHUTTERS:
        return jsonify({"error": f"Invalid shutter {sh}. Valid: 1-4"}), 400
    pct = request.args.get("pct", "")
    if not str(pct).isdigit() or not (0 <= int(pct) <= 100):
        return jsonify({"error": "pct must be 0–100"}), 400
    ok, msg = _run(["setpos", str(sh), str(pct)])
    return jsonify(_sh_json(sh, ok, msg)), 200 if ok else 500


@app.route("/api/shutter/<int:sh>/config", methods=["GET"])
def shutter_config_get(sh: int):
    if sh not in SHUTTERS:
        return jsonify({"error": f"Invalid shutter {sh}. Valid: 1-4"}), 400
    return jsonify({"shutter": sh, "config": _read_config(sh)})


@app.route("/api/shutter/<int:sh>/config", methods=["POST"])
def shutter_config_set(sh: int):
    if sh not in SHUTTERS:
        return jsonify({"error": f"Invalid shutter {sh}. Valid: 1-4"}), 400
    data = request.get_json(silent=True) or {}
    allowed = {"NAME", "END_STOPS", "UP_MS", "DOWN_MS"}
    filtered = {k: str(v) for k, v in data.items() if k in allowed}
    if not filtered:
        return jsonify({"error": "No valid keys. Allowed: NAME, END_STOPS, UP_MS, DOWN_MS"}), 400
    _write_config(sh, filtered)
    return jsonify({"shutter": sh, "config": _read_config(sh)})


@app.route("/api/all/up", methods=["POST"])
def all_up():
    results = []
    with _lock(0):
        for sh in SHUTTERS:
            ok, msg = _run(["up", str(sh)])
            results.append(_sh_json(sh, ok, msg))
    return jsonify({"shutters": _all_states(), "results": results})


@app.route("/api/all/down", methods=["POST"])
def all_down():
    results = []
    with _lock(0):
        for sh in SHUTTERS:
            ok, msg = _run(["down", str(sh)])
            results.append(_sh_json(sh, ok, msg))
    return jsonify({"shutters": _all_states(), "results": results})


@app.route("/api/all/stop", methods=["POST"])
def all_stop():
    with _lock(0):
        ok, msg = _run(["stop", "all"])
    return jsonify({"success": ok, "message": msg, "shutters": _all_states()})


@app.route("/api/all/open", methods=["POST"])
def all_open():
    ms = request.args.get("ms", "30000")
    results = []
    with _lock(0):
        for sh in SHUTTERS:
            ok, msg = _run(["open", str(sh), ms], timeout=int(ms) // 1000 + 5)
            results.append(_sh_json(sh, ok, msg))
    return jsonify({"shutters": _all_states(), "results": results})


@app.route("/api/all/close", methods=["POST"])
def all_close():
    ms = request.args.get("ms", "30000")
    results = []
    with _lock(0):
        for sh in SHUTTERS:
            ok, msg = _run(["close", str(sh), ms], timeout=int(ms) // 1000 + 5)
            results.append(_sh_json(sh, ok, msg))
    return jsonify({"shutters": _all_states(), "results": results})


@app.route("/api/all/calibrate", methods=["POST"])
def all_calibrate():
    results = []
    with _lock(0):
        for sh in SHUTTERS:
            cfg = _read_config(sh)
            total_ms = int(cfg["UP_MS"]) + int(cfg["DOWN_MS"]) + 2000
            if cfg["END_STOPS"] == "yes":
                total_ms = int(total_ms * 1.3)
            timeout = total_ms // 1000 + 10
            ok, msg = _run(["calibrate", str(sh)], timeout=timeout)
            results.append(_sh_json(sh, ok, msg))
    return jsonify({"shutters": _all_states(), "results": results})


if __name__ == "__main__":
    app.run(host=HOST, port=PORT, debug=False)
