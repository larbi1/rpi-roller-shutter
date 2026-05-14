#!/bin/bash
###################################################################
##   Waveshare RPi Relay Board (B) — Roller Shutter Controller  ##
##   v1.2.0  ·  Raspberry Pi 5 · libgpiod v2.x / v1.x          ##
###################################################################
##  4 shutters, 2 relays each (UP + DOWN), active-low            ##
##  SH1: UP=CH1/BCM5   DOWN=CH2/BCM6                            ##
##  SH2: UP=CH3/BCM13  DOWN=CH4/BCM16                           ##
##  SH3: UP=CH5/BCM19  DOWN=CH6/BCM20                           ##
##  SH4: UP=CH7/BCM21  DOWN=CH8/BCM26                           ##
##  SAFETY: UP and DOWN are interlocked — never active together  ##
###################################################################

set -euo pipefail

# ── Constants ────────────────────────────────────────────────────
readonly VERSION="1.2.0"
readonly SCRIPT_NAME="$(basename "$0")"
readonly SHUTTER_HOME="${SHUTTER_HOME:-/home/akaw/waveshare-shutter}"
readonly STATE_DIR="/tmp/shutter_board"
readonly CONFIG_DIR="${SHUTTER_HOME}/config"
readonly LOG_FILE="/tmp/shutter_board.log"
readonly MAX_LOG_KB=2048

# BCM pin mapping — index 0 unused (shutters are 1-indexed)
readonly -a UP_PINS=(0 5 13 19 21)    # SH1-SH4 UP   relay pins
readonly -a DOWN_PINS=(0 6 16 20 26)  # SH1-SH4 DOWN relay pins
readonly -a SHUTTERS=(1 2 3 4)

readonly GPIO_ON=0    # active-low: GPIO LOW  = relay energized
readonly GPIO_OFF=1   # active-low: GPIO HIGH = relay released

readonly CHANGE_DELAY="0.5"           # seconds between direction reversal
readonly DEFAULT_TRAVEL_MS=25000      # fallback travel time if not configured

# ── Colors ───────────────────────────────────────────────────────
if [[ -t 1 && "${TERM:-dumb}" != "dumb" ]]; then
    RED=$'\033[0;31m'  GREEN=$'\033[0;32m'  YELLOW=$'\033[1;33m'
    CYAN=$'\033[0;36m' BOLD=$'\033[1m'      DIM=$'\033[2m'  RESET=$'\033[0m'
else
    RED='' GREEN='' YELLOW='' CYAN='' BOLD='' DIM='' RESET=''
fi

# ── Logging ──────────────────────────────────────────────────────
_log() {
    if [[ -f "$LOG_FILE" ]] && (( $(du -k "$LOG_FILE" 2>/dev/null | cut -f1) >= MAX_LOG_KB )); then
        mv "$LOG_FILE" "${LOG_FILE}.old"
    fi
    printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2" >> "$LOG_FILE" 2>/dev/null || true
}
info()  { echo -e "${GREEN}[INFO]${RESET}  $*"; _log INFO  "$*"; }
warn()  { echo -e "${YELLOW}[WARN]${RESET}  $*" >&2; _log WARN  "$*"; }
error() { echo -e "${RED}[ERROR]${RESET} $*" >&2; _log ERROR "$*"; }
ok()    { echo -e "${GREEN}[OK]${RESET}    $*"; _log OK    "$*"; }
die()   { error "$*"; exit 1; }

# ── Config helpers ────────────────────────────────────────────────
# Read key from shN.conf, return default if absent
_conf_get() {
    local sh=$1 key=$2 default=${3:-""}
    local conf="${CONFIG_DIR}/sh${sh}.conf"
    if [[ -f "$conf" ]]; then
        local val
        val=$(grep -m1 "^${key}=" "$conf" 2>/dev/null | cut -d= -f2- || true)
        echo "${val:-$default}"
    else
        echo "$default"
    fi
}

# Write or update key=value in shN.conf
_conf_set() {
    local sh=$1 key=$2 value=$3
    local conf="${CONFIG_DIR}/sh${sh}.conf"
    mkdir -p "$CONFIG_DIR"
    if [[ -f "$conf" ]] && grep -q "^${key}=" "$conf" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$conf"
    else
        echo "${key}=${value}" >> "$conf"
    fi
}

# ── Dependencies ─────────────────────────────────────────────────
check_deps() {
    local missing=() dep
    for dep in gpioset gpiodetect; do
        command -v "$dep" &>/dev/null || missing+=("$dep")
    done
    (( ${#missing[@]} == 0 )) || die "Missing: ${missing[*]}. Run: sudo apt install gpiod"
}

# ── libgpiod version detection ───────────────────────────────────
GPIOD_MAJOR=1
GPIOD_V2_HOLD=""

detect_gpiod_version() {
    local ver
    ver=$(gpioset --version 2>&1 | grep -oP 'v\K\d+' | head -1 || echo "1")
    GPIOD_MAJOR=${ver:-1}
    if (( GPIOD_MAJOR >= 2 )); then
        local help_text
        help_text=$(gpioset --help 2>&1 || true)
        if grep -qE '\-\-daemonize|-z,' <<< "$help_text"; then
            GPIOD_V2_HOLD="daemonize"
        elif grep -qE '\-\-interactive|-i,' <<< "$help_text"; then
            GPIOD_V2_HOLD="interactive"
        else
            die "libgpiod v${GPIOD_MAJOR}: no --daemonize or --interactive found"
        fi
    fi
    _log INFO "libgpiod v${GPIOD_MAJOR}  hold=${GPIOD_V2_HOLD:-signal(v1)}"
}

# ── GPIO chip detection ───────────────────────────────────────────
GPIO_CHIP=""

detect_gpio_chip() {
    local detect_out
    detect_out=$(gpiodetect 2>/dev/null) || die "gpiodetect failed"
    GPIO_CHIP=$(grep -oP '^gpiochip\d+(?=.*(?:rp1-gpio|pinctrl-rp1))' <<< "$detect_out" | head -1 || true)
    if [[ -z "$GPIO_CHIP" ]]; then
        local best_chip="" best_count=0 chip num_lines
        while IFS= read -r line; do
            chip=$(grep -oP '^gpiochip\d+' <<< "$line" || true)
            num_lines=$(grep -oP '\(\K\d+(?= lines\))' <<< "$line" || echo "0")
            [[ -z "$chip" ]] && continue
            (( num_lines > best_count )) && { best_count=$num_lines; best_chip=$chip; }
        done <<< "$detect_out"
        [[ -n "$best_chip" ]] && GPIO_CHIP="$best_chip"
    fi
    [[ -n "$GPIO_CHIP" ]] || die "No GPIO chip found. Run: gpiodetect"
    _log INFO "GPIO chip: $GPIO_CHIP"
}

# ── gpioset wrapper (v1/v2 chip argument syntax) ─────────────────
_gpioset() {
    if (( GPIOD_MAJOR >= 2 )); then
        gpioset --chip "$GPIO_CHIP" "$@"
    else
        gpioset "$GPIO_CHIP" "$@"
    fi
}

# ── Process finder (word-boundary pin match) ──────────────────────
_find_gpioset_pid() {
    local pin=$1
    ps ax -o pid,args 2>/dev/null \
        | grep "gpioset" | grep -v grep | grep -w "$pin" \
        | awk '{print $1; exit}' || true
}

# ── PID / state helpers ───────────────────────────────────────────
_statefile()    { echo "${STATE_DIR}/sh${1}.state"; }
_posfile()      { echo "${STATE_DIR}/sh${1}.pos"; }
_movefile()     { echo "${STATE_DIR}/sh${1}.move_start"; }
_save_state()   { echo "$2" > "$(_statefile "$1")"; }
_read_state()   {
    local sf; sf=$(_statefile "$1")
    [[ -f "$sf" ]] && cat "$sf" || echo "stopped"
}
_read_pos() {
    local pf; pf=$(_posfile "$1")
    [[ -f "$pf" ]] && cat "$pf" || echo "50"
}
_save_pos()     { echo "$2" > "$(_posfile "$1")"; }
_now_ms()       { date +%s%3N; }
_record_move_start() { _now_ms > "$(_movefile "$1")"; }

# ── Position update on movement stop ─────────────────────────────
_update_pos_on_stop() {
    local sh=$1
    local direction; direction=$(_read_state "$sh")
    local mf; mf=$(_movefile "$sh")
    [[ -f "$mf" ]] || return 0

    local start_ms; start_ms=$(cat "$mf")
    local elapsed=$(( $(_now_ms) - start_ms ))
    local cur; cur=$(_read_pos "$sh")
    local new_pos

    if [[ "$direction" == "up" ]]; then
        local up_ms; up_ms=$(_conf_get "$sh" UP_MS "$DEFAULT_TRAVEL_MS")
        new_pos=$(( cur - (elapsed * 100 / up_ms) ))
    elif [[ "$direction" == "down" ]]; then
        local down_ms; down_ms=$(_conf_get "$sh" DOWN_MS "$DEFAULT_TRAVEL_MS")
        new_pos=$(( cur + (elapsed * 100 / down_ms) ))
    else
        rm -f "$mf"; return 0
    fi

    (( new_pos < 0 ))   && new_pos=0
    (( new_pos > 100 )) && new_pos=100
    _save_pos "$sh" "$new_pos"
    rm -f "$mf"
}

# ── Low-level GPIO pin control ────────────────────────────────────
_pin_release() {
    local pin=$1
    local pid; pid=$(_find_gpioset_pid "$pin")
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
    sleep 0.05
}

_pin_on() {
    local pin=$1
    local err_tmp; err_tmp=$(mktemp)

    _pin_release "$pin"

    if (( GPIOD_MAJOR >= 2 )); then
        _gpioset --daemonize "${pin}=${GPIO_ON}" 2>"$err_tmp" || true
        if [[ -s "$err_tmp" ]]; then
            error "gpioset failed on BCM${pin}: $(cat "$err_tmp")"
            rm -f "$err_tmp"; return 1
        fi
        sleep 0.2
        local daemon_pid; daemon_pid=$(_find_gpioset_pid "$pin")
        [[ -n "$daemon_pid" ]] || { error "daemon not found for BCM${pin}"; rm -f "$err_tmp"; return 1; }
    else
        _gpioset --mode=signal "${pin}=${GPIO_ON}" 2>"$err_tmp" &
        sleep 0.1
        if [[ -s "$err_tmp" ]]; then
            error "gpioset failed on BCM${pin}: $(cat "$err_tmp")"
            rm -f "$err_tmp"; return 1
        fi
    fi
    rm -f "$err_tmp"
}

# ── Shutter-level operations ──────────────────────────────────────

# Stop: update position then release both relays
_shutter_stop() {
    local sh=$1
    _update_pos_on_stop "$sh"
    _pin_release "${UP_PINS[$sh]}"
    _pin_release "${DOWN_PINS[$sh]}"
    _save_state "$sh" "stopped"
}

# Move UP: interlock DOWN → record start → activate UP
_shutter_up() {
    local sh=$1
    local current; current=$(_read_state "$sh")

    if [[ "$current" == "down" ]]; then
        _update_pos_on_stop "$sh"    # record position before reversing
        _pin_release "${DOWN_PINS[$sh]}"
        sleep "$CHANGE_DELAY"
    fi

    _pin_on "${UP_PINS[$sh]}" || return 1
    _record_move_start "$sh"
    _save_state "$sh" "up"
    ok "SH${sh}  UP  (BCM${UP_PINS[$sh]} ON / BCM${DOWN_PINS[$sh]} OFF)"
}

# Move DOWN: interlock UP → record start → activate DOWN
_shutter_down() {
    local sh=$1
    local current; current=$(_read_state "$sh")

    if [[ "$current" == "up" ]]; then
        _update_pos_on_stop "$sh"    # record position before reversing
        _pin_release "${UP_PINS[$sh]}"
        sleep "$CHANGE_DELAY"
    fi

    _pin_on "${DOWN_PINS[$sh]}" || return 1
    _record_move_start "$sh"
    _save_state "$sh" "down"
    ok "SH${sh}  DOWN  (BCM${DOWN_PINS[$sh]} ON / BCM${UP_PINS[$sh]} OFF)"
}

# Open (UP for duration then stop); uses per-shutter UP_MS as default
shutter_open() {
    local sh=$1
    local up_ms; up_ms=$(_conf_get "$sh" UP_MS "$DEFAULT_TRAVEL_MS")
    local ms=${2:-$up_ms}
    [[ "$ms" =~ ^[0-9]+$ ]] || die "Duration must be a positive integer (ms). Got: $ms"
    info "SH${sh}  opening  (${ms}ms) ..."
    _shutter_up "$sh" || return 1
    sleep "$(awk "BEGIN{printf \"%.3f\", $ms/1000}")"
    _shutter_stop "$sh"
    # After full-travel open, force position to 0% (fully open)
    if (( ms >= up_ms )); then
        _save_pos "$sh" 0
    fi
    ok "SH${sh}  open complete  (pos=$(( $(_read_pos "$sh") ))%)"
}

# Close (DOWN for duration then stop); uses per-shutter DOWN_MS as default
shutter_close() {
    local sh=$1
    local down_ms; down_ms=$(_conf_get "$sh" DOWN_MS "$DEFAULT_TRAVEL_MS")
    local ms=${2:-$down_ms}
    [[ "$ms" =~ ^[0-9]+$ ]] || die "Duration must be a positive integer (ms). Got: $ms"
    info "SH${sh}  closing  (${ms}ms) ..."
    _shutter_down "$sh" || return 1
    sleep "$(awk "BEGIN{printf \"%.3f\", $ms/1000}")"
    _shutter_stop "$sh"
    # After full-travel close, force position to 100% (fully closed)
    if (( ms >= down_ms )); then
        _save_pos "$sh" 100
    fi
    ok "SH${sh}  close complete  (pos=$(( $(_read_pos "$sh") ))%)"
}

# ── Calibration ───────────────────────────────────────────────────
# Full DOWN then full UP to establish known position (0% = fully open).
# Motors with end stops: run with 20% buffer — motor stops itself.
# Degraded mode (no end stops): run for exactly down_ms / up_ms.
shutter_calibrate() {
    local sh=$1
    local end_stops; end_stops=$(_conf_get "$sh" END_STOPS "yes")
    local down_ms; down_ms=$(_conf_get "$sh" DOWN_MS "$DEFAULT_TRAVEL_MS")
    local up_ms; up_ms=$(_conf_get "$sh" UP_MS "$DEFAULT_TRAVEL_MS")
    local name; name=$(_conf_get "$sh" NAME "SH${sh}")
    local wait_ms

    info "SH${sh} (${name})  CALIBRATE — phase 1: closing fully..."

    _shutter_down "$sh" || return 1

    if [[ "$end_stops" == "yes" ]]; then
        wait_ms=$(( down_ms * 12 / 10 ))   # 20% extra: motor stops at end stop
    else
        wait_ms=$down_ms
    fi
    sleep "$(awk "BEGIN{printf \"%.3f\", $wait_ms/1000}")"

    # Stop without position tracking (we're forcing to 100%)
    _pin_release "${DOWN_PINS[$sh]}"
    rm -f "$(_movefile "$sh")"
    _save_pos "$sh" 100
    _save_state "$sh" "stopped"
    ok "SH${sh}  fully closed (100%)"

    sleep 1

    info "SH${sh} (${name})  CALIBRATE — phase 2: opening fully..."

    _pin_on "${UP_PINS[$sh]}" || return 1
    _record_move_start "$sh"
    _save_state "$sh" "up"

    if [[ "$end_stops" == "yes" ]]; then
        wait_ms=$(( up_ms * 12 / 10 ))
    else
        wait_ms=$up_ms
    fi
    sleep "$(awk "BEGIN{printf \"%.3f\", $wait_ms/1000}")"

    _pin_release "${UP_PINS[$sh]}"
    rm -f "$(_movefile "$sh")"
    _save_pos "$sh" 0
    _save_state "$sh" "stopped"
    ok "SH${sh}  fully open (0%) — calibration complete"
}

# ── Position command ──────────────────────────────────────────────
# Move shutter to target position % (0=open, 100=closed).
# Uses dead-reckoning from configured travel times.
shutter_to_pos() {
    local sh=$1 target=$2
    [[ "$target" =~ ^[0-9]+$ ]] && (( target <= 100 )) || die "Position must be 0–100. Got: $target"

    local current; current=$(_read_pos "$sh")
    local diff=$(( target - current ))

    if (( diff == 0 )); then
        info "SH${sh}  already at ${target}%"; return 0
    elif (( diff > 0 )); then
        # Closing (going down)
        local down_ms; down_ms=$(_conf_get "$sh" DOWN_MS "$DEFAULT_TRAVEL_MS")
        local travel=$(( diff * down_ms / 100 ))
        (( travel < 200 )) && { info "SH${sh}  delta too small (${travel}ms), skipping"; return 0; }
        info "SH${sh}  → ${target}%  (closing ${diff}%, ${travel}ms)..."
        _shutter_down "$sh" || return 1
        sleep "$(awk "BEGIN{printf \"%.3f\", $travel/1000}")"
        _shutter_stop "$sh"
        _save_pos "$sh" "$target"
    else
        # Opening (going up)
        local up_ms; up_ms=$(_conf_get "$sh" UP_MS "$DEFAULT_TRAVEL_MS")
        local travel=$(( (-diff) * up_ms / 100 ))
        (( travel < 200 )) && { info "SH${sh}  delta too small (${travel}ms), skipping"; return 0; }
        info "SH${sh}  → ${target}%  (opening ${#diff}%, ${travel}ms)..."
        _shutter_up "$sh" || return 1
        sleep "$(awk "BEGIN{printf \"%.3f\", $travel/1000}")"
        _shutter_stop "$sh"
        _save_pos "$sh" "$target"
    fi
    ok "SH${sh}  position reached: ${target}%"
}

# Force set position without any movement (manual override)
shutter_setpos() {
    local sh=$1 pct=$2
    [[ "$pct" =~ ^[0-9]+$ ]] && (( pct <= 100 )) || die "Position must be 0–100. Got: $pct"
    _save_pos "$sh" "$pct"
    ok "SH${sh}  position set to ${pct}% (no movement)"
}

# ── Config command ────────────────────────────────────────────────
shutter_config_show() {
    echo ""
    echo "${BOLD}Shutter Configuration  (config dir: ${CONFIG_DIR})${RESET}"
    echo "  ────────────────────────────────────────────────────────────────"
    printf "  %-6s  %-10s  %-12s  %-12s  %-8s  %s\n" \
           "SH" "END_STOPS" "UP_MS" "DOWN_MS" "POS%" "NAME"
    echo "  ────────────────────────────────────────────────────────────────"
    for sh in "${SHUTTERS[@]}"; do
        local end_stops; end_stops=$(_conf_get "$sh" END_STOPS "yes")
        local up_ms;     up_ms=$(_conf_get "$sh" UP_MS "$DEFAULT_TRAVEL_MS")
        local down_ms;   down_ms=$(_conf_get "$sh" DOWN_MS "$DEFAULT_TRAVEL_MS")
        local name;      name=$(_conf_get "$sh" NAME "SH${sh}")
        local pos;       pos=$(_read_pos "$sh")
        printf "  SH%-4d  %-10s  %-12s  %-12s  %-8s  %s\n" \
               "$sh" "$end_stops" "${up_ms}ms" "${down_ms}ms" "${pos}%" "$name"
    done
    echo "  ────────────────────────────────────────────────────────────────"
    echo ""
}

shutter_config_set() {
    local sh=$1; shift
    _validate_shutter "$sh"
    for kv in "$@"; do
        [[ "$kv" == *"="* ]] || die "Expected KEY=value, got: $kv"
        local key="${kv%%=*}"
        local val="${kv#*=}"
        _conf_set "$sh" "$key" "$val"
        ok "SH${sh}  ${key}=${val}"
    done
}

# ── Status display ────────────────────────────────────────────────
shutter_status() {
    echo ""
    echo "${BOLD}Waveshare RPi Relay Board (B) — Roller Shutter Controller  v${VERSION}${RESET}"
    echo "  Chip: ${GPIO_CHIP}   libgpiod v${GPIOD_MAJOR}.x"
    echo "  ───────────────────────────────────────────────────────────────────"
    printf "  %-6s  %-10s  %-10s  %-6s  %-10s  %-9s  %s\n" \
           "SH" "UP pin" "DOWN pin" "POS%" "STATE" "END_STOPS" "DAEMON"
    echo "  ───────────────────────────────────────────────────────────────────"

    for sh in "${SHUTTERS[@]}"; do
        local up_pin=${UP_PINS[$sh]} down_pin=${DOWN_PINS[$sh]}
        local state; state=$(_read_state "$sh")
        local pos;   pos=$(_read_pos "$sh")
        local up_pid; up_pid=$(_find_gpioset_pid "$up_pin")
        local down_pid; down_pid=$(_find_gpioset_pid "$down_pin")
        local end_stops; end_stops=$(_conf_get "$sh" END_STOPS "yes")

        local daemon_info="stopped"
        [[ -n "$up_pid"   ]] && daemon_info="UP PID ${up_pid}"
        [[ -n "$down_pid" ]] && daemon_info="DOWN PID ${down_pid}"

        local color="$DIM"
        [[ "$state" == "up"   ]] && color="$GREEN"
        [[ "$state" == "down" ]] && color="$CYAN"

        printf "  SH%-4d  BCM %-6d  BCM %-6d  %-6s  %b%-10s%b  %-9s  %s\n" \
            "$sh" "$up_pin" "$down_pin" "${pos}%" \
            "$color" "${state^^}" "$RESET" \
            "$end_stops" "$daemon_info"
    done

    echo "  ───────────────────────────────────────────────────────────────────"
    echo ""
}

# ── Validation ────────────────────────────────────────────────────
_validate_shutter() {
    [[ "${1:-}" =~ ^[1-4]$ ]] || die "Invalid shutter '${1:-}'. Valid: 1 2 3 4"
}

# ── Help ──────────────────────────────────────────────────────────
print_help() {
    cat <<EOF

${BOLD}Waveshare RPi Relay Board (B) — Roller Shutter Controller  v${VERSION}${RESET}
Raspberry Pi 5 · libgpiod · 4 shutters · active-low

${BOLD}USAGE${RESET}
  ${SCRIPT_NAME} <command> [shutter ...] [options]

${BOLD}RELAY COMMANDS${RESET}
  up        <1-4 ...>              Start moving UP (motor stops at end stop if equipped)
  down      <1-4 ...>              Start moving DOWN
  stop      <1-4 ...| all>         Stop immediately (both relays off)
  open      <1-4> [ms]             Move UP for duration then stop  (default: per-shutter UP_MS)
  close     <1-4> [ms]             Move DOWN for duration then stop (default: per-shutter DOWN_MS)

${BOLD}POSITION COMMANDS${RESET}
  calibrate <1-4| all>             Full close then full open — establishes 0% position
  pos       <1-4> <0-100>          Move to position % (requires configured travel times)
  setpos    <1-4> <0-100>          Force-set position without movement (manual override)

${BOLD}CONFIG / INFO${RESET}
  config                           Show per-shutter motor configuration table
  config    <1-4> KEY=val ...      Set config keys (END_STOPS, UP_MS, DOWN_MS, NAME)
  status                           Show all shutter states + positions
  reset                            Stop all shutters safely
  help                             Show this message

${BOLD}MOTOR TYPES${RESET}
  END_STOPS=yes  (Somfy, Nice, etc.) — relay stays on; motor stops at mechanical/electronic end stop
                  Use 'up'/'down' for continuous; 'open'/'close' for timed with auto-stop
  END_STOPS=no   (Degraded mode)     — relay MUST be stopped after UP_MS/DOWN_MS or motor is damaged
                  Always use 'open'/'close'; never use 'up'/'down' indefinitely

${BOLD}SHUTTER → RELAY MAPPING${RESET}
  SH1: UP=CH1/BCM5   DOWN=CH2/BCM6
  SH2: UP=CH3/BCM13  DOWN=CH4/BCM16
  SH3: UP=CH5/BCM19  DOWN=CH6/BCM20
  SH4: UP=CH7/BCM21  DOWN=CH8/BCM26

${BOLD}EXAMPLES${RESET}
  ${SCRIPT_NAME} calibrate all           # Calibrate all 4 shutters (sets 0% position)
  ${SCRIPT_NAME} pos 1 50               # Move SH1 to 50% (half-open)
  ${SCRIPT_NAME} config 1 UP_MS=28000 DOWN_MS=26000 END_STOPS=yes
  ${SCRIPT_NAME} config 2 END_STOPS=no UP_MS=20000  # Degraded mode (no end stops)
  ${SCRIPT_NAME} up 1 3                 # Move SH1 and SH3 up
  ${SCRIPT_NAME} open 1 25000           # Open SH1 for 25s then stop
  ${SCRIPT_NAME} stop all               # Stop all shutters
  ${SCRIPT_NAME} setpos 1 0             # Force position to 0% after manual full-open
  DEBUG=1 ${SCRIPT_NAME} status

${BOLD}SAFETY${RESET}
  UP and DOWN relays are interlocked — activating one direction always
  releases the opposite first, with a ${CHANGE_DELAY}s delay.

${BOLD}DEBUG${RESET}
  DEBUG=1 ${SCRIPT_NAME} status
  ps aux | grep gpioset

EOF
}

# ── Initialisation ────────────────────────────────────────────────
init() {
    mkdir -p "$STATE_DIR"
    check_deps
    detect_gpiod_version
    detect_gpio_chip
    if [[ "${DEBUG:-0}" == "1" ]]; then
        info "chip=${GPIO_CHIP}  libgpiod_v${GPIOD_MAJOR}  hold=${GPIOD_V2_HOLD:-signal(v1)}"
        info "SHUTTER_HOME=${SHUTTER_HOME}  CONFIG_DIR=${CONFIG_DIR}"
    fi
}

# ── Entry point ───────────────────────────────────────────────────
main() {
    (( $# > 0 )) || { print_help; exit 0; }

    local cmd=$1; shift

    case "$cmd" in
        help|--help|-h) print_help; exit 0 ;;
        up|down|stop|open|close|status|reset|calibrate|pos|setpos|config) ;;
        *) error "Unknown command: '${cmd}'"; print_help; exit 1 ;;
    esac

    # config show doesn't need GPIO hardware
    if [[ "$cmd" == "config" && $# -eq 0 ]]; then
        mkdir -p "$STATE_DIR"
        shutter_config_show
        exit 0
    fi

    # config set doesn't need GPIO
    if [[ "$cmd" == "config" && $# -ge 1 ]]; then
        local sh=$1; shift
        _validate_shutter "$sh"
        if [[ $# -eq 0 ]]; then
            mkdir -p "$STATE_DIR"
            shutter_config_show
            exit 0
        fi
        shutter_config_set "$sh" "$@"
        exit 0
    fi

    init

    case "$cmd" in
        up)
            (( $# > 0 )) || die "Missing shutter. Usage: ${SCRIPT_NAME} up <1-4> [...]"
            for sh in "$@"; do _validate_shutter "$sh"; _shutter_up "$sh"; done
            ;;
        down)
            (( $# > 0 )) || die "Missing shutter. Usage: ${SCRIPT_NAME} down <1-4> [...]"
            for sh in "$@"; do _validate_shutter "$sh"; _shutter_down "$sh"; done
            ;;
        stop)
            (( $# > 0 )) || die "Missing shutter. Usage: ${SCRIPT_NAME} stop <1-4 ...| all>"
            if [[ "${1:-}" == "all" ]]; then
                for sh in "${SHUTTERS[@]}"; do _shutter_stop "$sh"; done
                ok "All shutters stopped."
            else
                for sh in "$@"; do _validate_shutter "$sh"; _shutter_stop "$sh"; done
            fi
            ;;
        open)
            [[ -n "${1:-}" ]] || die "Missing shutter. Usage: ${SCRIPT_NAME} open <1-4> [ms]"
            _validate_shutter "$1"
            shutter_open "$1" "${2:-}"
            ;;
        close)
            [[ -n "${1:-}" ]] || die "Missing shutter. Usage: ${SCRIPT_NAME} close <1-4> [ms]"
            _validate_shutter "$1"
            shutter_close "$1" "${2:-}"
            ;;
        calibrate)
            if [[ "${1:-}" == "all" || $# -eq 0 ]]; then
                info "Calibrating all shutters..."
                for sh in "${SHUTTERS[@]}"; do shutter_calibrate "$sh"; sleep 2; done
                ok "All shutters calibrated."
            else
                for sh in "$@"; do _validate_shutter "$sh"; shutter_calibrate "$sh"; done
            fi
            ;;
        pos)
            [[ $# -ge 2 ]] || die "Usage: ${SCRIPT_NAME} pos <1-4> <0-100>"
            _validate_shutter "$1"
            shutter_to_pos "$1" "$2"
            ;;
        setpos)
            [[ $# -ge 2 ]] || die "Usage: ${SCRIPT_NAME} setpos <1-4> <0-100>"
            _validate_shutter "$1"
            shutter_setpos "$1" "$2"
            ;;
        status) shutter_status ;;
        reset)
            info "Stopping all shutters ..."
            for sh in "${SHUTTERS[@]}"; do _shutter_stop "$sh"; done
            ok "All shutters stopped."
            ;;
    esac
}

main "$@"
