#!/usr/bin/env python3
"""
button_daemon.py — Roller shutter physical button controller  v1.1.0
Event-driven GPIO button monitor using python3-gpiod.
Supports gpiod v1.x (select-based) and v2.x (wait_edge_events).

Wiring: contact leg A → RPi GND, contact leg B → RPi GPIO.
Internal pull-up: idle = HIGH (open), pressed = LOW → falling edge.

Compatible double push-button units (4 required for 4 shutters):
  • Schneider Electric Odace S520207 (double poussoir volets-roulants)
  • Legrand Dooxie double push-button for roller shutters
  • Leroy Merlin Modern / any momentary NO double push-button

Pin assignment (BCM → header pin):
  SH1: UP=BCM4(pin7)   DOWN=BCM17(pin11)
  SH2: UP=BCM27(pin13) DOWN=BCM22(pin15)
  SH3: UP=BCM23(pin16) DOWN=BCM24(pin18)
  SH4: UP=BCM25(pin22) DOWN=BCM12(pin32)
"""

import fcntl
import logging
import os
import select
import signal
import subprocess
import sys
import time

# ── Configuration ─────────────────────────────────────────────────
SHUTTER_SCRIPT = os.environ.get("SHUTTER_SCRIPT", "/usr/local/bin/shutter_control.sh")
STATE_DIR      = "/tmp/shutter_board"
LOG_FILE       = "/tmp/shutter_board_buttons.log"
MAX_LOG_BYTES  = 1_048_576  # 1 MB

DEBOUNCE_MS   = 50     # discard events shorter than this (mechanical bounce)
LONG_PRESS_MS = 3_000  # >= this on release → ALL STOP

# BCM pin → (shutter_number, direction)
BUTTON_PINS: dict[int, tuple[int, str]] = {
    4:  (1, "up"),
    17: (1, "down"),
    27: (2, "up"),
    22: (2, "down"),
    23: (3, "up"),
    24: (3, "down"),
    25: (4, "up"),
    12: (4, "down"),
}

# ── Logging ───────────────────────────────────────────────────────
def _setup_logging() -> None:
    if os.path.exists(LOG_FILE) and os.path.getsize(LOG_FILE) >= MAX_LOG_BYTES:
        os.replace(LOG_FILE, LOG_FILE + ".old")
    fmt = logging.Formatter("%(asctime)s [%(levelname)s] %(message)s")
    root = logging.getLogger()
    for h in [logging.FileHandler(LOG_FILE), logging.StreamHandler(sys.stdout)]:
        h.setFormatter(fmt)
        root.addHandler(h)
    root.setLevel(logging.INFO)

log = logging.getLogger(__name__)

# ── Cross-process lock files (shared with shutter_web.py) ─────────
def _try_lock(sh: int):
    """Non-blocking exclusive flock on sh{N}.lock. Returns open fd or None if busy."""
    path = os.path.join(STATE_DIR, f"sh{sh}.lock")
    fd = open(path, "w")
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return fd
    except OSError:
        fd.close()
        return None

def _unlock(fd) -> None:
    if fd is not None:
        try:
            fcntl.flock(fd, fcntl.LOCK_UN)
            fd.close()
        except OSError:
            pass

# ── State reader ──────────────────────────────────────────────────
def _read_state(sh: int) -> str:
    try:
        with open(os.path.join(STATE_DIR, f"sh{sh}.state")) as f:
            return f.read().strip()
    except FileNotFoundError:
        return "stopped"

# ── Command runner ────────────────────────────────────────────────
def _run(args: list) -> None:
    try:
        r = subprocess.run(
            [SHUTTER_SCRIPT] + [str(a) for a in args],
            capture_output=True, text=True, timeout=10,
        )
        if r.returncode != 0:
            log.warning("rc=%d for %s: %s", r.returncode, args,
                        (r.stdout + r.stderr).strip())
    except subprocess.TimeoutExpired:
        log.error("timeout: %s", args)
    except Exception as exc:
        log.error("error running %s: %s", args, exc)

# ── GPIO chip detection ───────────────────────────────────────────
def _detect_chip() -> str:
    """Return /dev/gpiochipN for the active RPi GPIO chip."""
    try:
        out = subprocess.check_output(["gpiodetect"], text=True, timeout=5)
    except Exception:
        log.warning("gpiodetect failed, defaulting to /dev/gpiochip0")
        return "/dev/gpiochip0"
    for line in out.splitlines():
        if "rp1-gpio" in line or "pinctrl-rp1" in line:
            chip = line.split()[0]
            log.info("chip: %s (rp1-gpio)", chip)
            return f"/dev/{chip}"
    best, best_n = "gpiochip0", 0
    for line in out.splitlines():
        parts = line.split()
        if not parts:
            continue
        try:
            n = int(line.split("(")[1].split(" line")[0])
            if n > best_n:
                best_n, best = n, parts[0]
        except (IndexError, ValueError):
            pass
    log.info("chip: %s (fallback, %d lines)", best, best_n)
    return f"/dev/{best}"

# ── Button release handler ────────────────────────────────────────
def _on_release(pin: int, duration_ms: float) -> None:
    """Decide and dispatch action based on which button was released and for how long."""
    sh, direction = BUTTON_PINS[pin]

    if duration_ms < DEBOUNCE_MS:
        return  # mechanical bounce — discard silently

    if duration_ms >= LONG_PRESS_MS:
        log.info("LONG PRESS pin=%d sh=%d (%.0f ms) → stop all", pin, sh, duration_ms)
        fd = _try_lock(0)  # sh=0: global lock slot
        if fd is None:
            log.warning("global lock busy, dropping all-stop")
            return
        try:
            _run(["stop", "all"])
        finally:
            _unlock(fd)
        return

    # Short press: start moving if stopped, stop if already moving
    state = _read_state(sh)
    action = direction if state == "stopped" else "stop"
    log.info("pin=%d sh=%d dir=%s state=%s → %s (%.0f ms)",
             pin, sh, direction, state, action, duration_ms)

    fd = _try_lock(sh)
    if fd is None:
        log.warning("sh%d locked, dropping %s", sh, action)
        return
    try:
        _run([action, str(sh)])
    finally:
        _unlock(fd)

# ── gpiod v2 event loop ───────────────────────────────────────────
def _loop_v2(chip_dev: str) -> None:
    import gpiod
    from gpiod.line import Bias, Edge
    import datetime

    pins = list(BUTTON_PINS.keys())
    press_ts: dict[int, float] = {}

    cfg = {tuple(pins): gpiod.LineSettings(edge_detection=Edge.BOTH, bias=Bias.PULL_UP)}
    log.info("gpiod v2: requesting %d lines on %s", len(pins), chip_dev)
    with gpiod.request_lines(chip_dev, consumer="shutter-buttons", config=cfg) as req:
        log.info("Button daemon ready.")
        while True:
            if req.wait_edge_events(datetime.timedelta(seconds=1)):
                for ev in req.read_edge_events():
                    pin = ev.line_offset
                    now = time.monotonic() * 1000
                    if ev.event_type == gpiod.EdgeEvent.Type.FALLING_EDGE:
                        press_ts[pin] = now
                    elif ev.event_type == gpiod.EdgeEvent.Type.RISING_EDGE:
                        if pin in press_ts:
                            _on_release(pin, now - press_ts.pop(pin))

# ── gpiod v1 event loop (select-based) ───────────────────────────
def _loop_v1(chip_dev: str) -> None:
    import gpiod

    pins = list(BUTTON_PINS.keys())
    press_ts: dict[int, float] = {}

    chip = gpiod.Chip(chip_dev)
    line_objs = [chip.get_line(p) for p in pins]

    req = gpiod.line_request()
    req.consumer = "shutter-buttons"
    req.request_type = gpiod.LINE_REQ_EV_BOTH_EDGES
    req.flags = gpiod.LINE_REQ_FLAG_BIAS_PULL_UP
    for line in line_objs:
        line.request(req)

    fd_to_line = {line.event_get_fd(): line for line in line_objs}
    log.info("gpiod v1: monitoring %d lines on %s (select-based)", len(pins), chip_dev)
    log.info("Button daemon ready.")

    try:
        while True:
            readable, _, _ = select.select(list(fd_to_line.keys()), [], [], 1.0)
            for fd in readable:
                line = fd_to_line[fd]
                ev = line.event_read()
                pin = line.offset()
                now = time.monotonic() * 1000
                if ev.type == gpiod.LineEvent.FALLING_EDGE:
                    press_ts[pin] = now
                elif ev.type == gpiod.LineEvent.RISING_EDGE:
                    if pin in press_ts:
                        _on_release(pin, now - press_ts.pop(pin))
    finally:
        for line in line_objs:
            try:
                line.release()
            except Exception:
                pass
        chip.close()

# ── Entry point ───────────────────────────────────────────────────
def main() -> None:
    _setup_logging()
    log.info("=== Shutter Button Daemon v1.1.0 starting ===")

    if not os.path.isfile(SHUTTER_SCRIPT) or not os.access(SHUTTER_SCRIPT, os.X_OK):
        log.error("Not found or not executable: %s", SHUTTER_SCRIPT)
        sys.exit(1)

    os.makedirs(STATE_DIR, exist_ok=True)
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    signal.signal(signal.SIGINT,  lambda *_: sys.exit(0))

    try:
        import gpiod
    except ImportError:
        log.error("python3-gpiod not installed. Run: sudo apt install python3-gpiod")
        sys.exit(1)

    chip_dev = _detect_chip()
    ver = getattr(gpiod, "__version__", "1.0.0")
    major = int(ver.split(".")[0])
    log.info("python3-gpiod v%s (API major=%d)", ver, major)

    if major >= 2:
        _loop_v2(chip_dev)
    else:
        _loop_v1(chip_dev)


if __name__ == "__main__":
    main()
