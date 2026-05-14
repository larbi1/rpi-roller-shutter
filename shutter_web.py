#!/usr/bin/env python3
"""
Waveshare RPi Relay Board (B) — Roller Shutter Web Controller v1.0.0
REST API + live HTML dashboard for 4-shutter control on Raspberry Pi 5.

Usage:
    python3 shutter_web.py            # listens on 0.0.0.0:8081
    PORT=9090 python3 shutter_web.py

Requires: flask  (sudo apt install python3-flask)
"""

import os
import subprocess
from flask import Flask, jsonify, render_template, request

# ── Config ────────────────────────────────────────────────────────
SHUTTER_SCRIPT = os.environ.get("SHUTTER_SCRIPT", "/usr/local/bin/shutter_control.sh")
STATE_DIR      = "/tmp/shutter_board"
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

# ── Helpers ───────────────────────────────────────────────────────

def _run(args: list[str], timeout: int = 60) -> tuple[bool, str]:
    try:
        r = subprocess.run(
            [SHUTTER_SCRIPT] + args,
            capture_output=True, text=True, timeout=timeout,
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


def _all_states() -> dict:
    return {
        str(sh): {
            "state":    _read_state(sh),
            "up_bcm":   RELAY_MAP[sh]["up_bcm"],
            "down_bcm": RELAY_MAP[sh]["down_bcm"],
        }
        for sh in SHUTTERS
    }


def _sh_json(sh: int, ok: bool, msg: str) -> dict:
    return {
        "shutter": sh,
        "state":   _read_state(sh),
        "success": ok,
        "message": msg,
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
    ok, msg = _run(["up", str(sh)])
    return jsonify(_sh_json(sh, ok, msg)), 200 if ok else 500


@app.route("/api/shutter/<int:sh>/down", methods=["POST"])
def shutter_down(sh: int):
    if sh not in SHUTTERS:
        return jsonify({"error": f"Invalid shutter {sh}. Valid: 1-4"}), 400
    ok, msg = _run(["down", str(sh)])
    return jsonify(_sh_json(sh, ok, msg)), 200 if ok else 500


@app.route("/api/shutter/<int:sh>/stop", methods=["POST"])
def shutter_stop(sh: int):
    if sh not in SHUTTERS:
        return jsonify({"error": f"Invalid shutter {sh}. Valid: 1-4"}), 400
    ok, msg = _run(["stop", str(sh)])
    return jsonify(_sh_json(sh, ok, msg)), 200 if ok else 500


@app.route("/api/shutter/<int:sh>/open", methods=["POST"])
def shutter_open(sh: int):
    if sh not in SHUTTERS:
        return jsonify({"error": f"Invalid shutter {sh}. Valid: 1-4"}), 400
    ms = request.args.get("ms", "30000")
    if not ms.isdigit() or int(ms) < 1:
        return jsonify({"error": "ms must be a positive integer"}), 400
    ok, msg = _run(["open", str(sh), ms], timeout=int(ms) // 1000 + 5)
    return jsonify(_sh_json(sh, ok, msg)), 200 if ok else 500


@app.route("/api/shutter/<int:sh>/close", methods=["POST"])
def shutter_close(sh: int):
    if sh not in SHUTTERS:
        return jsonify({"error": f"Invalid shutter {sh}. Valid: 1-4"}), 400
    ms = request.args.get("ms", "30000")
    if not ms.isdigit() or int(ms) < 1:
        return jsonify({"error": "ms must be a positive integer"}), 400
    ok, msg = _run(["close", str(sh), ms], timeout=int(ms) // 1000 + 5)
    return jsonify(_sh_json(sh, ok, msg)), 200 if ok else 500


@app.route("/api/all/up", methods=["POST"])
def all_up():
    results = []
    for sh in SHUTTERS:
        ok, msg = _run(["up", str(sh)])
        results.append(_sh_json(sh, ok, msg))
    return jsonify({"shutters": _all_states(), "results": results})


@app.route("/api/all/down", methods=["POST"])
def all_down():
    results = []
    for sh in SHUTTERS:
        ok, msg = _run(["down", str(sh)])
        results.append(_sh_json(sh, ok, msg))
    return jsonify({"shutters": _all_states(), "results": results})


@app.route("/api/all/stop", methods=["POST"])
def all_stop():
    ok, msg = _run(["stop", "all"])
    return jsonify({"success": ok, "message": msg, "shutters": _all_states()})


@app.route("/api/all/open", methods=["POST"])
def all_open():
    ms = request.args.get("ms", "30000")
    results = []
    for sh in SHUTTERS:
        ok, msg = _run(["open", str(sh), ms], timeout=int(ms) // 1000 + 5)
        results.append(_sh_json(sh, ok, msg))
    return jsonify({"shutters": _all_states(), "results": results})


@app.route("/api/all/close", methods=["POST"])
def all_close():
    ms = request.args.get("ms", "30000")
    results = []
    for sh in SHUTTERS:
        ok, msg = _run(["close", str(sh), ms], timeout=int(ms) // 1000 + 5)
        results.append(_sh_json(sh, ok, msg))
    return jsonify({"shutters": _all_states(), "results": results})


if __name__ == "__main__":
    app.run(host=HOST, port=PORT, debug=False)
