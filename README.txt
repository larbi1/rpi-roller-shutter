================================================================================
  Waveshare RPi Relay Board (B) — Roller Shutter Controller  v1.2.0
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

  Step 6 — Configure motor travel times (one-time setup):
    shutter_control.sh config 1 UP_MS=28000 DOWN_MS=26000 NAME=Salon
    shutter_control.sh config 2 UP_MS=25000 DOWN_MS=25000 NAME=Chambre
    shutter_control.sh config 3 UP_MS=30000 DOWN_MS=30000 NAME=Bureau
    shutter_control.sh config 4 UP_MS=22000 DOWN_MS=22000 NAME=Cuisine
    # For motors WITHOUT end stops (degraded mode):
    shutter_control.sh config 1 END_STOPS=no

  Step 7 — Calibrate shutters (sets 0% position):
    shutter_control.sh calibrate all

  Step 8 — Verify:
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

MOTOR TYPES
-----------
  END_STOPS=yes  (default — Somfy, Nice, Came, and most branded motors)
    Motor has electronic or mechanical end stops. The relay stays energized;
    the motor stops itself when it reaches the limit. Safe for continuous
    'up'/'down' commands. Calibration uses +20% buffer time to ensure the
    motor reaches the end stop.

  END_STOPS=no  (degraded mode — bare motors without limits)
    Motor has no end stops. The relay MUST be cut after UP_MS/DOWN_MS
    milliseconds or the motor risks damage. Always use 'open'/'close'
    (timed commands). Never use 'up'/'down' alone indefinitely.
    Set: shutter_control.sh config 1 END_STOPS=no

POSITION TRACKING
-----------------
  Position is tracked by dead-reckoning (0% = fully open, 100% = fully closed).
  The system measures elapsed time and divides by configured travel time.

  - Run 'calibrate' to establish ground truth after configuration
  - After a reboot, positions reset to 50% (unknown). Use 'setpos' to restore:
      shutter_control.sh setpos 1 0    # after manually verifying SH1 is fully open
  - Use 'pos' to move to a target percentage:
      shutter_control.sh pos 1 50      # move SH1 to half-open

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

Button modes (set MODE in config/button.conf):

  Mode 1 (default — 2 buttons per shutter):
    Short press UP   (stopped)  → start moving UP
    Short press UP   (moving)   → STOP
    Short press DOWN (stopped)  → start moving DOWN
    Short press DOWN (moving)   → STOP
    Long press any   (≥3 s, release to trigger) → ALL STOP (safety action)

  Mode 5 (single-button cycle):
    Each press advances the cycle: UP → STOP → DOWN → STOP → UP …
    Both buttons of a shutter trigger the same cycle (can wire just one)
    Long press ≥3 s still → ALL STOP (safety action)
    Enable: echo "MODE=5" > ~/waveshare-shutter/config/button.conf
            sudo systemctl restart shutter-buttons

⚠  SAFETY: Button wiring (3.3V signal) must be completely separate from
   mains wiring (230V AC). Never route them in the same conduit or connect
   to relay screw terminals.

BASH CLI USAGE
--------------
  shutter_control.sh up        <1-4> [...]      Move shutter(s) UP (continuous)
  shutter_control.sh down      <1-4> [...]      Move shutter(s) DOWN (continuous)
  shutter_control.sh stop      <1-4 ...|all>    Stop shutter(s) immediately
  shutter_control.sh open      <1-4> [ms]       Move UP for N ms then stop
  shutter_control.sh close     <1-4> [ms]       Move DOWN for N ms then stop
  shutter_control.sh calibrate <1-4|all>        Full close then open → pos=0%
  shutter_control.sh pos       <1-4> <0-100>    Move to position % (requires calibration)
  shutter_control.sh setpos    <1-4> <0-100>    Force-set position without movement
  shutter_control.sh config                     Show motor config for all shutters
  shutter_control.sh config    <1-4> KEY=val    Set config key (END_STOPS/UP_MS/DOWN_MS/NAME)
  shutter_control.sh status                     Show all shutter states + positions
  shutter_control.sh reset                      Stop all shutters
  shutter_control.sh help                       Show usage

Examples:
  shutter_control.sh up 1 3               # Move SH1 and SH3 up simultaneously
  shutter_control.sh down 2 4             # Move SH2 and SH4 down simultaneously
  shutter_control.sh stop all             # Stop all shutters
  shutter_control.sh open 1 25000         # Open SH1 fully (25 seconds)
  shutter_control.sh close 2              # Close SH2 (uses configured DOWN_MS)
  shutter_control.sh calibrate all        # Calibrate all 4 shutters
  shutter_control.sh pos 1 50             # Move SH1 to half-open
  shutter_control.sh config 1 UP_MS=28000 DOWN_MS=26000 NAME=Salon
  DEBUG=1 shutter_control.sh status       # Verbose debug output

WEB DASHBOARD
-------------
  Start:   sudo systemctl start shutter-web
  Stop:    sudo systemctl stop  shutter-web
  Status:  sudo systemctl status shutter-web

  Access: http://<rpi-ip>:8081

  The dashboard shows 4 shutter cards with:
  - Animated blind-slat icon (shows up/stop/down state)
  - Position bar (0–100% fill, updates after stop)
  - Per-shutter ▲ (Up) / ■ (Stop) / ▼ (Down) / ⟳ (Calibrate) buttons
  - Settings panel (⚙ icon): motor name, end stops, travel times, set position
  - Global "All Up / All Stop / All Down / ⟳ Cal All" buttons
  - Auto-refresh every 3 seconds

REST API
--------
  GET  /api/status                          All shutter states + positions (JSON)
  POST /api/shutter/{1-4}/up               Start moving up
  POST /api/shutter/{1-4}/down             Start moving down
  POST /api/shutter/{1-4}/stop             Stop immediately
  POST /api/shutter/{1-4}/open?ms=25000    Timed open (ms optional, default=UP_MS)
  POST /api/shutter/{1-4}/close?ms=25000   Timed close (ms optional, default=DOWN_MS)
  POST /api/shutter/{1-4}/calibrate        Full close then open → position = 0%
  POST /api/shutter/{1-4}/pos?pct=50       Move to position % (0=open, 100=closed)
  POST /api/shutter/{1-4}/setpos?pct=50    Force-set position without movement
  GET  /api/shutter/{1-4}/config           Get motor config (JSON)
  POST /api/shutter/{1-4}/config           Set config (JSON body: NAME/END_STOPS/UP_MS/DOWN_MS)
  POST /api/all/up                         All shutters up
  POST /api/all/down                       All shutters down
  POST /api/all/stop                       Stop all shutters
  POST /api/all/open?ms=25000              Timed open all
  POST /api/all/close?ms=25000             Timed close all
  POST /api/all/calibrate                  Calibrate all shutters sequentially

SAFETY
------
  - Relay interlock: UP and DOWN are never active simultaneously (0.5s delay enforced)
  - Cross-process locking: lock files in /tmp/shutter_board/ prevent web server
    and button daemon from commanding the same shutter at the exact same moment
  - State is tracked in /tmp/shutter_board/shN.state (lost on reboot — safe default)
  - Position tracked in /tmp/shutter_board/shN.pos (lost on reboot — use setpos to restore)
  - Relays de-energised at boot — shutters stay at last physical position

CALIBRATION
-----------
  Calibration is required once after configuring motor travel times, and again
  if the shutter is manually repositioned (e.g. power cut during movement).

  What it does:
    1. Move DOWN for configured DOWN_MS (×1.2 if END_STOPS=yes) → pos = 100%
    2. Wait 1 second
    3. Move UP for configured UP_MS (×1.2 if END_STOPS=yes) → pos = 0%

  After calibration, 'pos' commands will be accurate to ±2–5% depending on
  motor consistency and travel time accuracy.

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

  Position inaccurate:
    shutter_control.sh calibrate all   # re-calibrate
    # Or manually set: shutter_control.sh setpos 1 0  (if you know it's fully open)

  Button wiring check (without Pi):
    Use a multimeter in continuity mode across the two terminals of
    each button contact — should show open when released, closed when pressed.

NOTES
-----
  - Relay board uses active-low logic: GPIO LOW = relay ON
  - libgpiod required (NOT sysfs, NOT RPi.GPIO)
  - python3-gpiod v1.x and v2.x both supported (auto-detected at runtime)
  - SHUTTER_HOME env var controls config directory location (default: /home/akaw/waveshare-shutter)
  - See CLAUDE.md for AI assistant context and architecture details
================================================================================
