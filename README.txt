================================================================================
  Waveshare RPi Relay Board (B) — Roller Shutter Controller  v1.1.0
  Raspberry Pi 5 · libgpiod · 4 Shutters · Web + Physical Buttons
================================================================================

OVERVIEW
--------
Controls 4 roller shutters using a Waveshare RPi Relay Board (B).
Each shutter uses 2 relays (UP + DOWN) with hardware interlock safety.

Two independent control channels operate simultaneously:
  1. Web dashboard  —  any browser on the local network → http://<rpi-ip>:8081
  2. Physical buttons — wall-mounted double push-buttons for instant local control

  SH1: UP=CH1/BCM5   DOWN=CH2/BCM6
  SH2: UP=CH3/BCM13  DOWN=CH4/BCM16
  SH3: UP=CH5/BCM19  DOWN=CH6/BCM20
  SH4: UP=CH7/BCM21  DOWN=CH8/BCM26

REQUIREMENTS
------------
  sudo apt update && sudo apt install gpiod python3-gpiod python3-flask

DEPLOY (on the Raspberry Pi)
-----------------------------
  Step 1 — Install dependencies:
    sudo apt update && sudo apt install -y gpiod python3-gpiod python3-flask

  Step 2 — Clone the repository:
    git clone https://github.com/larbi1/rpi-roller-shutter.git ~/waveshare-shutter

  Step 3 — Install the CLI script:
    sudo cp ~/waveshare-shutter/shutter_control.sh /usr/local/bin/
    sudo chmod +x /usr/local/bin/shutter_control.sh

  Step 4 — Install and enable the web service:
    sudo cp ~/waveshare-shutter/shutter-web.service /etc/systemd/system/
    sudo systemctl daemon-reload
    sudo systemctl enable --now shutter-web

  Step 5 — (After wiring buttons) Install and enable the button service:
    sudo cp ~/waveshare-shutter/shutter-buttons.service /etc/systemd/system/
    sudo systemctl daemon-reload
    sudo systemctl enable --now shutter-buttons

  Step 6 — Verify:
    shutter_control.sh status
    sudo systemctl status shutter-web
    sudo systemctl status shutter-buttons

  Web dashboard: http://<rpi-ip>:8081

UPDATE (pull latest from GitHub)
----------------------------------
  cd ~/waveshare-shutter && git pull
  sudo cp shutter_control.sh /usr/local/bin/
  sudo systemctl restart shutter-web
  sudo systemctl restart shutter-buttons

PHYSICAL BUTTONS — HARDWARE
-----------------------------
4 double momentary push-button units required (one per shutter).
Each unit provides two independent NO contacts: UP and DOWN.

Compatible models (any one will work):
  • Schneider Electric Odace S520207
      "Double poussoir pour volets-roulants" (with directional arrows)
      Standard Odace wall-plate format, 68 mm flush box
  • Legrand Dooxie 600122 (Leroy Merlin ref 90303603)
      "Bouton poussoir volet roulant alu"
  • Leroy Merlin Modern Noir (ref 86990486)
      "Bouton poussoir pour volets roulants automatiques avec flèches"

Wiring (all models):
  - Contact leg A → RPi GND (any GND pin: 6, 9, 14, 20, 25, 30, 34, or 39)
  - Contact leg B → RPi GPIO input pin (see pin table below)
  - No external resistors needed — RPi internal pull-up used
  - Use 2-conductor signal cable (2×0.5 mm²), routed separately from 230V mains

Button GPIO pin assignment (BCM / header):
  SH1: UP = BCM4  (header pin 7)   DOWN = BCM17 (header pin 11)
  SH2: UP = BCM27 (header pin 13)  DOWN = BCM22 (header pin 15)
  SH3: UP = BCM23 (header pin 16)  DOWN = BCM24 (header pin 18)
  SH4: UP = BCM25 (header pin 22)  DOWN = BCM12 (header pin 32)

Button behaviour:
  Short press UP   (stopped)  → start moving UP
  Short press UP   (moving)   → STOP
  Short press DOWN (stopped)  → start moving DOWN
  Short press DOWN (moving)   → STOP
  Long press any   (≥3 s, release to trigger) → ALL STOP (safety action)

⚠  SAFETY: Button wiring (3.3V signal) must be completely separate from
   mains wiring (230V AC). Never route them in the same conduit or connect
   to relay screw terminals.

BASH CLI USAGE
--------------
  shutter_control.sh up    <1-4> [...]      Move shutter(s) UP
  shutter_control.sh down  <1-4> [...]      Move shutter(s) DOWN
  shutter_control.sh stop  <1-4 ...|all>    Stop shutter(s) immediately
  shutter_control.sh open  <1-4> [ms]       Move UP for N ms then stop (default: 30000)
  shutter_control.sh close <1-4> [ms]       Move DOWN for N ms then stop (default: 30000)
  shutter_control.sh status                 Show all shutter states
  shutter_control.sh reset                  Stop all shutters
  shutter_control.sh help                   Show usage

Examples:
  shutter_control.sh up 1 3               # Move SH1 and SH3 up simultaneously
  shutter_control.sh down 2 4             # Move SH2 and SH4 down simultaneously
  shutter_control.sh stop all             # Stop all shutters
  shutter_control.sh open 1 25000         # Open SH1 fully (25 seconds)
  shutter_control.sh close 2              # Close SH2 (30s default)
  DEBUG=1 shutter_control.sh status       # Verbose debug output

WEB DASHBOARD
-------------
  Start:   sudo systemctl start shutter-web
  Stop:    sudo systemctl stop  shutter-web
  Status:  sudo systemctl status shutter-web

  Access: http://<rpi-ip>:8081

  The dashboard shows 4 shutter cards with:
  - Animated blind-slat icon (shows up/stop/down state)
  - Per-shutter ▲ (Up) / ■ (Stop) / ▼ (Down) buttons
  - Global "All Up / All Stop / All Down" buttons
  - Auto-refresh every 3 seconds

REST API
--------
  GET  /api/status                        All shutter states (JSON)
  POST /api/shutter/{1-4}/up              Start moving up
  POST /api/shutter/{1-4}/down            Start moving down
  POST /api/shutter/{1-4}/stop            Stop immediately
  POST /api/shutter/{1-4}/open?ms=25000   Timed open (ms optional)
  POST /api/shutter/{1-4}/close?ms=25000  Timed close (ms optional)
  POST /api/all/up                        All shutters up
  POST /api/all/down                      All shutters down
  POST /api/all/stop                      Stop all shutters
  POST /api/all/open?ms=25000             Timed open all
  POST /api/all/close?ms=25000            Timed close all

SAFETY
------
  - Relay interlock: UP and DOWN are never active simultaneously (0.5s delay enforced)
  - Cross-process locking: lock files in /tmp/shutter_board/ prevent web server
    and button daemon from commanding the same shutter at the exact same moment
  - State is tracked in /tmp/shutter_board/shN.state (lost on reboot — safe default)
  - Relays de-energised at boot — shutters stay at last physical position

TROUBLESHOOTING
---------------
  Web only (no buttons):
    sudo systemctl status shutter-web
    journalctl -u shutter-web -n 50

  Buttons not responding:
    sudo systemctl status shutter-buttons
    journalctl -u shutter-buttons -n 50
    tail -f /tmp/shutter_board_buttons.log

  No relay click:
    gpiodetect                         # verify chip detected
    DEBUG=1 shutter_control.sh up 1    # verbose relay output
    ps aux | grep gpioset              # check for stale daemons

  "Device or resource busy":
    shutter_control.sh stop all        # stop all daemons
    pkill -f gpioset                   # force kill if stuck

  Button wiring check (without Pi):
    Use a multimeter in continuity mode across the two terminals of
    each button contact — should show open when released, closed when pressed.

NOTES
-----
  - Relay board uses active-low logic: GPIO LOW = relay ON
  - libgpiod required (NOT sysfs, NOT RPi.GPIO)
  - python3-gpiod v1.x and v2.x both supported (auto-detected at runtime)
  - See CLAUDE.md for AI assistant context and architecture details
================================================================================
