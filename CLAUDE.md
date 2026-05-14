# CLAUDE.md — Waveshare RPi Relay Board (B) Roller Shutter Controller

## Project Summary

Bash CLI + Python web server to control **4 roller shutters** using a
**Waveshare RPi Relay Board (B)** on a **Raspberry Pi 5** with libgpiod.

Each shutter uses **2 relays** (UP + DOWN). UP and DOWN are interlocked —
they can never be active simultaneously.

- `shutter_control.sh` — CLI (up/down/stop/open/close/status/reset)
- `shutter_web.py` — Flask REST API + HTML dashboard on port 8081
- `templates/index.html` — live web UI with per-shutter ▲/■/▼ controls

## Critical Hardware Facts

| Property        | Value                                          |
|-----------------|------------------------------------------------|
| Board           | Waveshare RPi Relay Board (B)                  |
| Channels used   | **8** (2 per shutter × 4 shutters)             |
| Logic           | **Active-low** (GPIO 0 = relay ON)             |
| Platform        | Raspberry Pi 5                                 |
| GPIO driver     | libgpiod (NOT sysfs, NOT RPi.GPIO)             |

### Shutter → Relay Mapping

| Shutter | UP relay   | DOWN relay  |
|---------|------------|-------------|
| SH1     | CH1 BCM 5  | CH2 BCM 6   |
| SH2     | CH3 BCM 13 | CH4 BCM 16  |
| SH3     | CH5 BCM 19 | CH6 BCM 20  |
| SH4     | CH7 BCM 21 | CH8 BCM 26  |

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
Edit `UP_PINS`, `DOWN_PINS`, `SHUTTERS` in `shutter_control.sh`
and `RELAY_MAP` in `shutter_web.py`.

### Changing travel time default
Edit `DEFAULT_TRAVEL_MS` in `shutter_control.sh` and the `ms` default
in `shutter_web.py` route handlers.

### Running the web server
```bash
cd /home/akaw/waveshare-shutter
python3 shutter_web.py          # port 8081
PORT=9090 python3 shutter_web.py
```

### systemd service
```bash
sudo systemctl start   shutter-web
sudo systemctl stop    shutter-web
sudo systemctl status  shutter-web
sudo systemctl enable  shutter-web   # auto-start on boot
```

## Testing Checklist

Before reporting changes as complete, verify on the RPi 5:
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
