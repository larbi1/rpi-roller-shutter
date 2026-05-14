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
- `shutter_control.sh` — CLI relay controller (up/down/stop/open/close/calibrate/pos/setpos/config/status/reset)
- `shutter_web.py` — Flask REST API + HTML dashboard on port 8081
- `button_daemon.py` — GPIO button monitor daemon (python3-gpiod, event-driven)
- `templates/index.html` — live web UI with per-shutter controls, position bar, settings panel
- `shutter-web.service` — systemd unit for web server
- `shutter-buttons.service` — systemd unit for button daemon
- `config/shN.conf` — per-shutter motor config (NAME, END_STOPS, UP_MS, DOWN_MS)
- `config/button.conf` — button mode config (MODE=1 or MODE=5)

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

## Motor Types

| Type             | END_STOPS | Behaviour                                          |
|------------------|-----------|----------------------------------------------------|
| Somfy, Nice, etc | yes       | Relay stays on; motor stops itself at end stop.    |
|                  |           | Safe for `up`/`down` continuous. Calibrate with +20% buffer. |
| Degraded mode    | no        | No end stops — relay **must** be cut after UP_MS/DOWN_MS.    |
|                  |           | Only use `open`/`close` (timed). Never use `up`/`down` alone. |

## Per-Shutter Configuration

Config files live in `$SHUTTER_HOME/config/shN.conf` (bash key=value format):

```
NAME=Salon
END_STOPS=yes
UP_MS=28000
DOWN_MS=26000
```

Set via CLI: `shutter_control.sh config 1 UP_MS=28000 DOWN_MS=26000 END_STOPS=yes NAME=Salon`
Set via API: `POST /api/shutter/1/config` with JSON body `{"UP_MS":"28000","DOWN_MS":"26000"}`
Show all:    `shutter_control.sh config`

## Position Tracking (Dead-Reckoning)

- 0% = fully open, 100% = fully closed
- Tracked in `/tmp/shutter_board/shN.pos` (lost on reboot — use `setpos` to restore)
- Updated automatically on every stop based on elapsed_ms / travel_ms × 100 delta
- `calibrate` forces position to exact 0% after full-travel open
- `pos <sh> <pct>` moves to target using configured travel times (requires calibration first)
- `setpos <sh> <pct>` forces position without movement (manual override after reboot)

## Safety: Interlock Logic

The `_shutter_up` and `_shutter_down` functions **always** release the
opposite relay before activating the requested direction, with a 0.5 s
delay to let the motor coil discharge:

```bash
_shutter_up() {
    if [[ "$current" == "down" ]]; then
        _update_pos_on_stop "$sh"       # record position before reversing
        _pin_release "${DOWN_PINS[$sh]}"
        sleep 0.5
    fi
    _pin_on "${UP_PINS[$sh]}"
    _record_move_start "$sh"
    _save_state "$sh" "up"
}
```

**Never** call `_pin_on` without first calling `_pin_release` on the
opposite direction pin. The wrapper functions enforce this.

## GPIO Architecture

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
├── sh1.state       "up" | "down" | "stopped"
├── sh1.pos         integer 0–100 (%)
├── sh1.move_start  epoch-ms timestamp (start of current movement)
├── sh1.lock        flock mutex
├── sh2.state / sh2.pos / sh2.move_start / sh2.lock
...
└── sh0.lock        global "all" lock
```

State files are in `/tmp` — lost on reboot. Use `setpos` to restore position.

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
├── _setup_logging()             — rotate + configure file+stdout handler
├── _detect_chip()               — find /dev/gpiochipN (rp1-gpio preferred)
├── _get_button_mode()           — read MODE from config/button.conf (1 or 5)
├── _try_lock(sh)                — non-blocking flock on sh{N}.lock
├── _read_state(sh)              — read /tmp/shutter_board/sh{N}.state
├── _run(args)                   — subprocess call to shutter_control.sh
├── _handle_mode1(sh, dir, ms)   — Mode 1: toggle start/stop per direction
├── _handle_mode5(sh, ms)        — Mode 5: single-button cycle (state machine)
├── _on_release(pin, ms)         — dispatch: debounce / long-press / mode dispatch
├── _loop_v2(chip_dev)           — gpiod v2: request_lines + wait_edge_events
└── _loop_v1(chip_dev)           — gpiod v1: get_line + event_get_fd + select.select
```

Button modes:

**Mode 1** (default — 2 buttons per shutter, X-4VR V2 Mode 1):
- Short press UP (stopped) → `up N`
- Short press UP (moving)  → `stop N`
- Short press DOWN (stopped) → `down N`
- Short press DOWN (moving)  → `stop N`
- Long press ≥3 s → `stop all`
- Debounce: events < 50 ms discarded

**Mode 5** (single-button cycle, write `MODE=5` to `config/button.conf`):
- Each button press advances the cycle: UP → STOP → DOWN → STOP → UP …
- Both UP and DOWN buttons of a shutter trigger the same cycle
- Long press ≥3 s still → `stop all` and resets all cycle states
- State machine per shutter: 0=ready_up → 1=moving_up → 2=ready_down → 3=moving_down → 0

## Script Architecture

```
shutter_control.sh
├── check_deps()             — verify gpioset, gpiodetect
├── detect_gpiod_version()   — parse 'gpioset --version' for v1/v2
├── detect_gpio_chip()       — find chip with most lines (rp1-gpio preferred)
├── _conf_get(sh, key, def)  — read key from config/shN.conf
├── _conf_set(sh, key, val)  — write key to config/shN.conf
├── _gpioset()               — v1/v2 compatible gpioset wrapper
├── _find_gpioset_pid()      — find daemon PID by pin (word-boundary grep)
├── _pin_release(pin)        — kill daemon holding pin, wait 50ms
├── _pin_on(pin)             — release then start daemon for pin
├── _update_pos_on_stop(sh)  — dead-reckoning position update on stop
├── _record_move_start(sh)   — stamp movement start time
├── _shutter_stop(sh)        — update pos, release both relays
├── _shutter_up(sh)          — interlock stop DOWN, delay, activate UP, record start
├── _shutter_down(sh)        — interlock stop UP, delay, activate DOWN, record start
├── shutter_open(sh, ms)     — up for ms then stop; forces pos=0% if full travel
├── shutter_close(sh, ms)    — down for ms then stop; forces pos=100% if full travel
├── shutter_calibrate(sh)    — full close (+20% buffer) → pos=100 → full open → pos=0
├── shutter_to_pos(sh, pct)  — move to % using dead-reckoning travel time
├── shutter_setpos(sh, pct)  — force-set position without movement
├── shutter_config_show()    — display per-shutter config table
├── shutter_config_set(sh)   — update key=value pairs in shN.conf
├── shutter_status()         — display state + position + daemon PIDs
└── main()                   — argument parsing and dispatch
```

## REST API Quick Reference

```
GET  /api/status                          → all shutter states + positions (JSON)
POST /api/shutter/{1-4}/up               → start moving up (continuous)
POST /api/shutter/{1-4}/down             → start moving down (continuous)
POST /api/shutter/{1-4}/stop             → stop immediately
POST /api/shutter/{1-4}/open?ms=25000    → timed open (default: per-shutter UP_MS)
POST /api/shutter/{1-4}/close?ms=25000   → timed close (default: per-shutter DOWN_MS)
POST /api/shutter/{1-4}/calibrate        → full close then open → position = 0%
POST /api/shutter/{1-4}/pos?pct=50       → move to position % (0=open, 100=closed)
POST /api/shutter/{1-4}/setpos?pct=50    → force-set position without movement
GET  /api/shutter/{1-4}/config           → get motor config JSON
POST /api/shutter/{1-4}/config           → set config (JSON: NAME/END_STOPS/UP_MS/DOWN_MS)
POST /api/all/up                          → all shutters up
POST /api/all/down                        → all shutters down
POST /api/all/stop                        → stop all shutters
POST /api/all/open?ms=25000               → timed open all
POST /api/all/close?ms=25000              → timed close all
POST /api/all/calibrate                   → calibrate all shutters sequentially
```

## Common Tasks for Claude

### Changing shutter count or pin assignments
Edit `UP_PINS`, `DOWN_PINS`, `SHUTTERS` in `shutter_control.sh`,
`RELAY_MAP` in `shutter_web.py`, and `BUTTON_PINS` in `button_daemon.py`.

### Changing travel time default
Edit `DEFAULT_TRAVEL_MS` in `shutter_control.sh`.
Per-shutter times are set via `config 1 UP_MS=28000 DOWN_MS=26000`.

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

### v1.2.0 config and position tests
- [ ] `./shutter_control.sh config` shows all 4 shutters with defaults
- [ ] `./shutter_control.sh config 1 UP_MS=28000 END_STOPS=yes` updates sh1.conf
- [ ] `./shutter_control.sh calibrate 1` — SH1 closes then opens, ends at 0%
- [ ] `./shutter_control.sh status` shows POS% column
- [ ] `./shutter_control.sh pos 1 50` moves SH1 to ~50%
- [ ] `./shutter_control.sh setpos 1 0` forces position to 0% without movement
- [ ] Web UI shows position bar per shutter card
- [ ] Web UI ⚙ opens settings panel (Name, End stops, Open/Close time, Move to %, Force set %)
- [ ] Web UI "Save Settings" saves config and confirms
- [ ] Web UI ⟳ calibrate button works per card
- [ ] Web UI "⟳ Cal All" calibrates all 4 sequentially

### Button daemon tests (requires wired buttons)
- [ ] `journalctl -u shutter-buttons -n 20` shows "Button daemon ready"
- [ ] Short press UP on SH1 button → shutter starts moving up (relay click)
- [ ] Short press UP again → shutter stops
- [ ] Short press DOWN on SH1 → shutter starts moving down
- [ ] Short press DOWN again → shutter stops
- [ ] Long press (≥3 s) any button → all 4 shutters stop
- [ ] `tail /tmp/shutter_board_buttons.log` shows press events with duration
- [ ] Simultaneous web command + button press on same shutter → one wins, no crash
- [ ] Mode 5: add `MODE=5` to config/button.conf → restart service → each press cycles UP→STOP→DOWN→STOP

### Web control tests
- [ ] `./shutter_control.sh up 1` starts SH1 moving up (relay click)
- [ ] `./shutter_control.sh stop 1` stops SH1 immediately
- [ ] `./shutter_control.sh down 2` starts SH2 down
- [ ] `./shutter_control.sh up 2` reverses SH2 (0.5s pause before UP)
- [ ] `./shutter_control.sh open 3 5000` moves SH3 up for 5s then stops
- [ ] `./shutter_control.sh stop all` stops all shutters
- [ ] `DEBUG=1 ./shutter_control.sh status` shows chip/version info
- [ ] Web UI at http://<rpi-ip>:8081 shows 4 shutter cards
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
- Do not use `up`/`down` (continuous) on motors with END_STOPS=no — always use `open`/`close`
