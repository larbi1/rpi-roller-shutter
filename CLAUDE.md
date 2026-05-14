# CLAUDE.md — Waveshare RPi Relay Board (B) Roller Shutter Controller

## Project Summary

Bash CLI + Python web server + GPIO button daemon to control **4 roller shutters**
using a **Waveshare RPi Relay Board (B)** on a **Raspberry Pi 5** with libgpiod.

Each shutter uses **2 relays** (UP + DOWN). UP and DOWN are interlocked —
they can never be active simultaneously.

Two independent control channels:
- **Web** — Flask REST API + dashboard on port 8081 (any browser on local network)
- **Buttons** — 4 × double push-button units wired to RPi GPIO (physical wall control)

Files:
- `shutter_control.sh` — CLI relay controller (up/down/stop/open/close/status/reset)
- `shutter_web.py` — Flask REST API + HTML dashboard on port 8081
- `button_daemon.py` — GPIO button monitor daemon (python3-gpiod, event-driven)
- `templates/index.html` — live web UI with per-shutter ▲/■/▼ controls
- `shutter-web.service` — systemd unit for web server
- `shutter-buttons.service` — systemd unit for button daemon

## Critical Hardware Facts

| Property        | Value                                          |
|-----------------|------------------------------------------------|
| Board           | Waveshare RPi Relay Board (B)                  |
| Channels used   | **8** (2 per shutter × 4 shutters)             |
| Logic           | **Active-low** (GPIO 0 = relay ON)             |
| Platform        | Raspberry Pi 5                                 |
| GPIO driver     | libgpiod (NOT sysfs, NOT RPi.GPIO)             |

### Shutter → Relay Mapping (OUTPUT)

| Shutter | UP relay   | DOWN relay  |
|---------|------------|-------------|
| SH1     | CH1 BCM 5  | CH2 BCM 6   |
| SH2     | CH3 BCM 13 | CH4 BCM 16  |
| SH3     | CH5 BCM 19 | CH6 BCM 20  |
| SH4     | CH7 BCM 21 | CH8 BCM 26  |

### Button → GPIO Mapping (INPUT)

Each shutter needs one **double momentary NO push-button** unit (UP + DOWN in one).
Compatible models: Schneider Odace S520207, Legrand Dooxie 600122, or similar.
Wiring: contact A → GND, contact B → GPIO; internal pull-up enabled; idle=HIGH.

| Shutter | UP BCM (header) | DOWN BCM (header) |
|---------|-----------------|-------------------|
| SH1     | BCM 4  (pin 7)  | BCM 17 (pin 11)   |
| SH2     | BCM 27 (pin 13) | BCM 22 (pin 15)   |
| SH3     | BCM 23 (pin 16) | BCM 24 (pin 18)   |
| SH4     | BCM 25 (pin 22) | BCM 12 (pin 32)   |

## Safety: Interlock Logic

The `_shutter_up` and `_shutter_down` functions **always** release the
opposite relay before activating the requested direction, with a 0.5 s
delay to let the motor coil discharge:

```bash
_shutter_up() {
    if [[ "$current" == "down" ]]; then
        _pin_release "${DOWN_PINS[$sh]}"
        sleep 0.5
    fi
    _pin_on "${UP_PINS[$sh]}"
    _save_state "$sh" "up"
}
```

**Never** call `_pin_on` without first calling `_pin_release` on the
opposite direction pin. The wrapper functions enforce this.

## GPIO Architecture (same as relay-b project)

- libgpiod v2.x: `gpioset --daemonize <chip> <pin>=<value>` — line held
  until the daemon is killed
- libgpiod v1.x: `gpioset --mode=signal <chip> <pin>=<value> &` — held
  until SIGTERM
- **NEVER** use `--mode=exit` (line releases immediately on exit)
- GPIO chip auto-detected from `gpiodetect` output (highest line count)
- Exclusive line ownership: only one daemon holds each pin at a time

## State Directory Layout

```
/tmp/shutter_board/
├── sh1.state    "up" | "down" | "stopped"
├── sh2.state
├── sh3.state
└── sh4.state
```

State files are in `/tmp` — lost on reboot. The systemd service does not
auto-restore state on start (shutters are left in last physical position).

## Cross-Process Locking

Both `shutter_web.py` and `button_daemon.py` call `shutter_control.sh`.
Lock files in `STATE_DIR` prevent concurrent commands on the same shutter:

| File              | Holder                 | Mode        |
|-------------------|------------------------|-------------|
| `sh1.lock`–`sh4.lock` | web (blocking 6s) / button (non-blocking, drop) | per-shutter |
| `sh0.lock`        | "all" commands         | global      |

Button daemon uses non-blocking flock — drops command if busy (safe).
Web server uses blocking flock — waits up to 6s (covers timed open/close).

## button_daemon.py Architecture

```
button_daemon.py
├── _setup_logging()         — rotate + configure file+stdout handler
├── _detect_chip()           — find /dev/gpiochipN (rp1-gpio preferred)
├── _try_lock(sh)            — non-blocking flock on sh{N}.lock
├── _read_state(sh)          — read /tmp/shutter_board/sh{N}.state
├── _run(args)               — subprocess call to shutter_control.sh
├── _on_release(pin, ms)     — decide action: debounce / long-press / short-press
├── _loop_v2(chip_dev)       — gpiod v2: request_lines + wait_edge_events
└── _loop_v1(chip_dev)       — gpiod v1: get_line + event_get_fd + select.select
```

Button behaviour (X-4VR V2 Mode 1 style):
- Short press UP (stopped) → `up N`
- Short press UP (moving)  → `stop N`
- Short press DOWN (stopped) → `down N`
- Short press DOWN (moving)  → `stop N`
- Long press ≥3 s (any, trigger on release) → `stop all`
- Debounce: events < 50 ms discarded (mechanical bounce)

## Script Architecture

```
shutter_control.sh
├── check_deps()             — verify gpioset, gpiodetect
├── detect_gpiod_version()   — parse 'gpioset --version' for v1/v2
├── detect_gpio_chip()       — find chip with most lines (≥27)
├── _gpioset()               — v1/v2 compatible gpioset wrapper
├── _find_gpioset_pid()      — find daemon PID by pin (word-boundary grep)
├── _pin_release(pin)        — kill daemon holding pin, wait 50ms
├── _pin_on(pin)             — release then start daemon for pin
├── _shutter_stop(sh)        — release both relays for shutter
├── _shutter_up(sh)          — interlock stop DOWN, delay, activate UP
├── _shutter_down(sh)        — interlock stop UP, delay, activate DOWN
├── shutter_open(sh, ms)     — up for ms then stop
├── shutter_close(sh, ms)    — down for ms then stop
├── shutter_status()         — display state table with daemon PIDs
└── main()                   — argument parsing and dispatch
```

## REST API Quick Reference

```
GET  /api/status                        → all shutter states (JSON)
POST /api/shutter/{1-4}/up             → start moving up
POST /api/shutter/{1-4}/down           → start moving down
POST /api/shutter/{1-4}/stop           → stop immediately
POST /api/shutter/{1-4}/open?ms=25000  → timed open
POST /api/shutter/{1-4}/close?ms=25000 → timed close
POST /api/all/up                        → all shutters up
POST /api/all/down                      → all shutters down
POST /api/all/stop                      → stop all shutters
POST /api/all/open?ms=25000             → timed open all
POST /api/all/close?ms=25000            → timed close all
```

## Common Tasks for Claude

### Changing shutter count or pin assignments
Edit `UP_PINS`, `DOWN_PINS`, `SHUTTERS` in `shutter_control.sh`,
`RELAY_MAP` in `shutter_web.py`, and `BUTTON_PINS` in `button_daemon.py`.

### Changing travel time default
Edit `DEFAULT_TRAVEL_MS` in `shutter_control.sh` and the `ms` default
in `shutter_web.py` route handlers.

### Running the web server
```bash
cd /home/akaw/waveshare-shutter
python3 shutter_web.py          # port 8081
PORT=9090 python3 shutter_web.py
```

### systemd services
```bash
sudo systemctl start   shutter-web
sudo systemctl stop    shutter-web
sudo systemctl status  shutter-web
sudo systemctl enable  shutter-web       # auto-start on boot

sudo systemctl start   shutter-buttons
sudo systemctl stop    shutter-buttons
sudo systemctl status  shutter-buttons
sudo systemctl enable  shutter-buttons   # auto-start on boot
tail -f /tmp/shutter_board_buttons.log   # live button event log
```

## Testing Checklist

Before reporting changes as complete, verify on the RPi 5:

### Button daemon tests (requires wired buttons)
- [ ] `journalctl -u shutter-buttons -n 20` shows "Button daemon ready"
- [ ] Short press UP on SH1 button → shutter starts moving up (relay click)
- [ ] Short press UP again → shutter stops
- [ ] Short press DOWN on SH1 → shutter starts moving down
- [ ] Short press DOWN again → shutter stops
- [ ] Long press (≥3 s) any button → all 4 shutters stop
- [ ] `tail /tmp/shutter_board_buttons.log` shows press events with duration
- [ ] Simultaneous web command + button press on same shutter → one wins, no crash

### Web control tests
- [ ] `./shutter_control.sh status` shows all shutters (stopped)
- [ ] `./shutter_control.sh up 1` starts SH1 moving up (relay click)
- [ ] `./shutter_control.sh stop 1` stops SH1 immediately
- [ ] `./shutter_control.sh down 2` starts SH2 down
- [ ] `./shutter_control.sh up 2` reverses SH2 (0.5s pause before UP)
- [ ] `./shutter_control.sh open 3 5000` moves SH3 up for 5s then stops
- [ ] `./shutter_control.sh stop all` stops all shutters
- [ ] `./shutter_control.sh reset` stops all (same as stop all)
- [ ] `DEBUG=1 ./shutter_control.sh status` shows chip/version info
- [ ] Web UI at http://<rpi-ip>:8081 shows 4 shutter cards
- [ ] Web ▲/■/▼ buttons work for each shutter
- [ ] "All Up / All Stop / All Down" global buttons work
- [ ] `ps aux | grep gpioset` shows 1 daemon per active shutter direction

## Do Not

- Do not use `--mode=exit` anywhere in GPIO operations
- Do not use sysfs (`/sys/class/gpio/...`) — deprecated on RPi 5
- Do not activate both UP and DOWN relays of the same shutter simultaneously
- Do not skip the interlock delay when reversing direction
- Do not use `gpioget` on a line held by the daemon (exclusive ownership)
- Do not change ports: relay-web=8080, shutter-web=8081
- Do not connect button wiring to relay screw terminals — signal level only (3.3V/GND)
- Do not use sysfs GPIO for buttons — use python3-gpiod only
- Do not poll GPIO in a sleep loop — button_daemon.py uses kernel edge events
