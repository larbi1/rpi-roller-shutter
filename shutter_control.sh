#!/bin/bash
###################################################################
##   Waveshare RPi Relay Board (B) — Roller Shutter Controller  ##
##   v1.1.0  ·  Raspberry Pi 5 · libgpiod v2.x / v1.x          ##
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
readonly VERSION="1.1.0"
readonly SCRIPT_NAME="$(basename "$0")"
readonly STATE_DIR="/tmp/shutter_board"
readonly LOG_FILE="/tmp/shutter_board.log"
readonly MAX_LOG_KB=2048

# BCM pin mapping — index 0 unused (shutters are 1-indexed)
readonly -a UP_PINS=(0 5 13 19 21)    # SH1-SH4 UP   relay pins
readonly -a DOWN_PINS=(0 6 16 20 26)  # SH1-SH4 DOWN relay pins
readonly -a SHUTTERS=(1 2 3 4)

readonly GPIO_ON=0    # active-low: GPIO LOW  = relay energized
readonly GPIO_OFF=1   # active-low: GPIO HIGH = relay released

# Motor protection: wait this long between releasing one direction
# and engaging the opposite (lets motor coil discharge)
readonly CHANGE_DELAY="0.5"

# Default full-travel duration for open/close commands (ms)
readonly DEFAULT_TRAVEL_MS=30000

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

# ── Process finder (word-boundary pin match, avoids PID collisions) ──
_find_gpioset_pid() {
    local pin=$1
    ps ax -o pid,args 2>/dev/null \
        | grep "gpioset" | grep -v grep | grep -w "$pin" \
        | awk '{print $1; exit}' || true
}

# ── PID / state helpers ───────────────────────────────────────────
_pidfile()      { echo "${STATE_DIR}/sh${1}_${2}.pid"; }   # sh=shutter, dir=up|down
_statefile()    { echo "${STATE_DIR}/sh${1}.state"; }
_save_state()   { echo "$2" > "$(_statefile "$1")"; }
_read_state()   {
    local sf; sf=$(_statefile "$1")
    [[ -f "$sf" ]] && cat "$sf" || echo "stopped"
}

# ── Low-level GPIO pin control ────────────────────────────────────
_pin_release() {
    local pin=$1
    # Kill via any stray daemon holding this pin
    local pid; pid=$(_find_gpioset_pid "$pin")
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
    sleep 0.05
}

_pin_on() {
    local pin=$1
    local err_tmp; err_tmp=$(mktemp)

    _pin_release "$pin"   # release first (exclusive ownership)

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

# Stop: release both relays
_shutter_stop() {
    local sh=$1
    _pin_release "${UP_PINS[$sh]}"
    _pin_release "${DOWN_PINS[$sh]}"
    _save_state "$sh" "stopped"
}

# Move UP: release DOWN, delay, activate UP
_shutter_up() {
    local sh=$1
    local current; current=$(_read_state "$sh")

    # If moving down, stop and wait before reversing
    if [[ "$current" == "down" ]]; then
        _pin_release "${DOWN_PINS[$sh]}"
        sleep "$CHANGE_DELAY"
    fi

    _pin_on "${UP_PINS[$sh]}" || return 1
    _save_state "$sh" "up"
    ok "SH${sh}  UP  (BCM${UP_PINS[$sh]} ON / BCM${DOWN_PINS[$sh]} OFF)"
}

# Move DOWN: release UP, delay, activate DOWN
_shutter_down() {
    local sh=$1
    local current; current=$(_read_state "$sh")

    # If moving up, stop and wait before reversing
    if [[ "$current" == "up" ]]; then
        _pin_release "${UP_PINS[$sh]}"
        sleep "$CHANGE_DELAY"
    fi

    _pin_on "${DOWN_PINS[$sh]}" || return 1
    _save_state "$sh" "down"
    ok "SH${sh}  DOWN  (BCM${DOWN_PINS[$sh]} ON / BCM${UP_PINS[$sh]} OFF)"
}

# Open: move UP for duration then stop
shutter_open() {
    local sh=$1 ms=${2:-$DEFAULT_TRAVEL_MS}
    [[ "$ms" =~ ^[0-9]+$ ]] || die "Duration must be a positive integer (ms). Got: $ms"
    info "SH${sh}  opening  (${ms}ms) ..."
    _shutter_up "$sh" || return 1
    sleep "$(awk "BEGIN{printf \"%.3f\", $ms/1000}")"
    _shutter_stop "$sh"
    ok "SH${sh}  open complete"
}

# Close: move DOWN for duration then stop
shutter_close() {
    local sh=$1 ms=${2:-$DEFAULT_TRAVEL_MS}
    [[ "$ms" =~ ^[0-9]+$ ]] || die "Duration must be a positive integer (ms). Got: $ms"
    info "SH${sh}  closing  (${ms}ms) ..."
    _shutter_down "$sh" || return 1
    sleep "$(awk "BEGIN{printf \"%.3f\", $ms/1000}")"
    _shutter_stop "$sh"
    ok "SH${sh}  close complete"
}

# ── Status display ────────────────────────────────────────────────
shutter_status() {
    echo ""
    echo "${BOLD}Waveshare RPi Relay Board (B) — Roller Shutter Controller  v${VERSION}${RESET}"
    echo "  Chip: ${GPIO_CHIP}   libgpiod v${GPIOD_MAJOR}.x"
    echo "  ─────────────────────────────────────────────────────────"
    printf "  %-6s  %-10s  %-10s  %-8s  %s\n" "SHUTTER" "UP pin" "DOWN pin" "STATE" "DAEMON"
    echo "  ─────────────────────────────────────────────────────────"

    for sh in "${SHUTTERS[@]}"; do
        local up_pin=${UP_PINS[$sh]} down_pin=${DOWN_PINS[$sh]}
        local state; state=$(_read_state "$sh")
        local up_pid; up_pid=$(_find_gpioset_pid "$up_pin")
        local down_pid; down_pid=$(_find_gpioset_pid "$down_pin")

        local daemon_info="stopped"
        [[ -n "$up_pid"   ]] && daemon_info="UP PID ${up_pid}"
        [[ -n "$down_pid" ]] && daemon_info="DOWN PID ${down_pid}"

        local color="$DIM"
        [[ "$state" == "up"   ]] && color="$GREEN"
        [[ "$state" == "down" ]] && color="$CYAN"

        printf "  SH%-4d  BCM %-6d  BCM %-6d  %b%-8s%b  %s\n" \
            "$sh" "$up_pin" "$down_pin" "$color" "${state^^}" "$RESET" "$daemon_info"
    done

    echo "  ─────────────────────────────────────────────────────────"
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

${BOLD}COMMANDS${RESET}
  up     <1-4 ...>              Start moving shutter(s) UP
  down   <1-4 ...>              Start moving shutter(s) DOWN
  stop   <1-4 ...| all>         Stop shutter(s) (both relays off)
  open   <1-4> [ms]             Move UP for duration then stop  (default: ${DEFAULT_TRAVEL_MS}ms)
  close  <1-4> [ms]             Move DOWN for duration then stop (default: ${DEFAULT_TRAVEL_MS}ms)
  status                        Show all shutter states
  reset                         Stop all shutters safely
  help                          Show this message

${BOLD}SHUTTER → RELAY MAPPING${RESET}
  SH1: UP=CH1/BCM5   DOWN=CH2/BCM6
  SH2: UP=CH3/BCM13  DOWN=CH4/BCM16
  SH3: UP=CH5/BCM19  DOWN=CH6/BCM20
  SH4: UP=CH7/BCM21  DOWN=CH8/BCM26

${BOLD}EXAMPLES${RESET}
  ${SCRIPT_NAME} up 1 3              # Move SH1 and SH3 up
  ${SCRIPT_NAME} down 2 4            # Move SH2 and SH4 down
  ${SCRIPT_NAME} stop all            # Stop all shutters
  ${SCRIPT_NAME} open 1 25000        # Open SH1 in 25 seconds
  ${SCRIPT_NAME} close 2             # Close SH2 (${DEFAULT_TRAVEL_MS}ms default)
  ${SCRIPT_NAME} status              # Show current states

${BOLD}SAFETY${RESET}
  UP and DOWN relays are interlocked — activating one direction
  always releases the opposite first, with a ${CHANGE_DELAY}s delay.

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
    fi
}

# ── Entry point ───────────────────────────────────────────────────
main() {
    (( $# > 0 )) || { print_help; exit 0; }

    local cmd=$1; shift

    case "$cmd" in
        help|--help|-h) print_help; exit 0 ;;
        up|down|stop|open|close|status|reset) ;;
        *) error "Unknown command: '${cmd}'"; print_help; exit 1 ;;
    esac

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
            shutter_open "$1" "${2:-$DEFAULT_TRAVEL_MS}"
            ;;
        close)
            [[ -n "${1:-}" ]] || die "Missing shutter. Usage: ${SCRIPT_NAME} close <1-4> [ms]"
            _validate_shutter "$1"
            shutter_close "$1" "${2:-$DEFAULT_TRAVEL_MS}"
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
