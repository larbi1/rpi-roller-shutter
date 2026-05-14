================================================================================
  Waveshare RPi Relay Board (B) — Roller Shutter Controller  v1.0.0
  Raspberry Pi 5 · libgpiod · 4 Shutters
================================================================================

OVERVIEW
--------
Controls 4 roller shutters using a Waveshare RPi Relay Board (B).
Each shutter uses 2 relays (UP + DOWN) with hardware interlock safety —
UP and DOWN are never active at the same time.

  SH1: UP=CH1/BCM5   DOWN=CH2/BCM6
  SH2: UP=CH3/BCM13  DOWN=CH4/BCM16
  SH3: UP=CH5/BCM19  DOWN=CH6/BCM20
  SH4: UP=CH7/BCM21  DOWN=CH8/BCM26

REQUIREMENTS
------------
  sudo apt update && sudo apt install gpiod python3-flask

INSTALLATION
------------
1. Copy shutter_control.sh to RPi:
     scp shutter_control.sh akaw@<rpi-ip>:/tmp/
     ssh akaw@<rpi-ip> "sudo cp /tmp/shutter_control.sh /usr/local/bin/ && sudo chmod +x /usr/local/bin/shutter_control.sh"

2. Copy web server files to RPi:
     scp -r shutter_web.py templates akaw@<rpi-ip>:~/waveshare-shutter/

3. Install the systemd service:
     scp shutter-web.service akaw@<rpi-ip>:/tmp/
     ssh akaw@<rpi-ip> "sudo cp /tmp/shutter-web.service /etc/systemd/system/ && sudo systemctl daemon-reload && sudo systemctl enable shutter-web"

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
  The interlock logic in shutter_control.sh ensures:
  - Activating UP always releases DOWN first, then waits 0.5s
  - Activating DOWN always releases UP first, then waits 0.5s
  - This protects the motor from simultaneous relay activation

  State is tracked in /tmp/shutter_board/shN.state
  State is LOST on reboot (shutters stay at last physical position).

TROUBLESHOOTING
---------------
  No relay click:
    gpiodetect                       # verify chip is detected
    DEBUG=1 shutter_control.sh up 1  # verbose output
    ps aux | grep gpioset            # check for stale daemons

  "Device or resource busy":
    shutter_control.sh stop all      # stop all daemons
    pkill -f gpioset                 # force kill if stuck

  Web server won't start:
    python3 -c "import flask"        # check flask is installed
    sudo systemctl status shutter-web
    journalctl -u shutter-web -n 50

  Wrong chip detected:
    gpiodetect                       # list chips
    gpioinfo gpiochip0 | head -30    # inspect pins

NOTES
-----
  - Relay board uses active-low logic: GPIO LOW = relay ON
  - libgpiod is required (NOT sysfs, NOT RPi.GPIO)
  - The script auto-detects the correct GPIO chip
  - Each relay daemon runs as a background gpioset process
  - See CLAUDE.md for AI assistant context and architecture details
================================================================================
