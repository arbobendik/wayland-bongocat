#!/usr/bin/env bash
# Supervises bongocat and periodically repositions it with a short show/hide y-axis animation.

set -euo pipefail

readonly ANIMATION_SEC=1.5
readonly REPOSITION_INTERVAL_SEC=30
readonly FRAME_INTERVAL_SEC=0.02
readonly RESTART_FRAME_INTERVAL_SEC=0.06
readonly Y_REST=45
readonly Y_PEAK=100
readonly X_MIN=0
readonly X_MAX=500
readonly ANIMATION_STEPS="$(awk "BEGIN {
  n = int(${ANIMATION_SEC} / ${FRAME_INTERVAL_SEC})
  print (n > 0) ? n : 1
}")"
readonly STOP_WAIT_SEC=0.15
readonly START_WAIT_SEC=0.20

readonly CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/bongocat"
readonly CONFIG="${CONFIG_DIR}/bongocat.conf"
readonly CONFIG_TEMPLATE="${CONFIG_DIR}/bongocat.conf.template"
# Optional override: BONGOCAT=/path/to/bongocat
readonly USER_PATCHED_BONGOCAT="$HOME/.local/bin/bongocat-patched"
readonly SYSTEM_PATCHED_BONGOCAT=/usr/local/bin/bongocat-patched
readonly SYSTEM_BONGOCAT=/usr/bin/bongocat
readonly REPO_BONGOCAT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/build/bongocat"
readonly PID_FILE="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/bongocat.pid"

bongocat_pid=""
RELOAD_MODE="hotreload"
USE_WATCH_CONFIG=1

log() {
  printf '[bongocat-session] %s\n' "$*" >&2
}

resolve_bongocat() {
  if [[ -n "${BONGOCAT:-}" && -x "$BONGOCAT" ]]; then
    echo "$BONGOCAT"
    return 0
  fi
  if [[ -x "$SYSTEM_PATCHED_BONGOCAT" ]]; then
    echo "$SYSTEM_PATCHED_BONGOCAT"
    return 0
  fi
  if [[ -x "$USER_PATCHED_BONGOCAT" ]]; then
    echo "$USER_PATCHED_BONGOCAT"
    return 0
  fi
  if command -v bongocat >/dev/null 2>&1; then
    command -v bongocat
    return 0
  fi
  if [[ -x "$SYSTEM_BONGOCAT" ]]; then
    echo "$SYSTEM_BONGOCAT"
    return 0
  fi
  if [[ -x "$REPO_BONGOCAT" ]]; then
    echo "$REPO_BONGOCAT"
    return 0
  fi
  log "ERROR: no bongocat binary found"
  return 1
}

inotify_watch_available() {
  python3 - "$CONFIG" <<'PY'
import ctypes
import ctypes.util
import os
import sys

config = sys.argv[1]
libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
libc.inotify_init1.argtypes = [ctypes.c_int]
libc.inotify_init1.restype = ctypes.c_int
libc.inotify_add_watch.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_uint32]
libc.inotify_add_watch.restype = ctypes.c_int

fd = libc.inotify_init1(0x800)
if fd < 0:
    raise SystemExit(1)
watch = libc.inotify_add_watch(fd, config.encode(), 0x2 | 0x8)
os.close(fd)
raise SystemExit(0 if watch >= 0 else 1)
PY
}

choose_reload_mode() {
  if inotify_watch_available; then
    RELOAD_MODE="hotreload"
    USE_WATCH_CONFIG=1
    log "Using hot-reload mode (--watch-config)"
    return 0
  fi

  RELOAD_MODE="restart"
  USE_WATCH_CONFIG=0
  log "WARNING: inotify watches exhausted, using restart mode (install 99-inotify.conf and reboot or sysctl --system)"
}

stop_all_bongocat() {
  if [[ -n "${bongocat_pid:-}" ]] && kill -0 "$bongocat_pid" 2>/dev/null; then
    kill -TERM "$bongocat_pid" 2>/dev/null || true
    wait "$bongocat_pid" 2>/dev/null || true
  fi
  bongocat_pid=""

  if pgrep -f 'bongocat-patched|/usr/bin/bongocat' >/dev/null 2>&1; then
    pkill -TERM -f 'bongocat-patched|/usr/bin/bongocat' 2>/dev/null || true
    local i=0
    while pgrep -f 'bongocat-patched|/usr/bin/bongocat' >/dev/null 2>&1 && (( i < 100 )); do
      sleep 0.05
      i=$(( i + 1 ))
    done
  fi

  if pgrep -f 'bongocat-patched|/usr/bin/bongocat' >/dev/null 2>&1; then
    pkill -KILL -f 'bongocat-patched|/usr/bin/bongocat' 2>/dev/null || true
    sleep 0.05
  fi

  rm -f "$PID_FILE"
  sleep "$STOP_WAIT_SEC"
}

cleanup() {
  log "Stopping bongocat"
  stop_all_bongocat
}

trap cleanup EXIT INT TERM

config_is_text() {
  # Reject null-byte / binary corruption that previously killed startup.
  python3 - "$CONFIG" <<'PY'
import sys
from pathlib import Path
data = Path(sys.argv[1]).read_bytes()
raise SystemExit(0 if data and b"\0" not in data else 1)
PY
}

restore_config_from_template() {
  if [[ ! -f "$CONFIG_TEMPLATE" ]]; then
    log "ERROR: config corrupt and template missing: $CONFIG_TEMPLATE"
    return 1
  fi
  log "WARNING: restoring config from template $CONFIG_TEMPLATE"
  local tmp
  tmp="$(mktemp "${CONFIG}.XXXXXX")"
  cp -a --no-preserve=ownership "$CONFIG_TEMPLATE" "$tmp"
  chmod 644 "$tmp"
  mv -f "$tmp" "$CONFIG"
}

ensure_config() {
  mkdir -p "$CONFIG_DIR"

  if [[ ! -f "$CONFIG" ]]; then
    if [[ -f "$CONFIG_TEMPLATE" ]]; then
      restore_config_from_template || return 1
    else
      log "ERROR: config not found: $CONFIG"
      return 1
    fi
  fi

  if ! config_is_text; then
    restore_config_from_template || return 1
  fi

  validate_config || {
    restore_config_from_template || return 1
    validate_config
  }
}

validate_config() {
  local lines
  if ! config_is_text; then
    log "ERROR: config contains binary/null data"
    return 1
  fi
  lines="$(wc -l < "$CONFIG")"
  if (( lines > 100 )); then
    log "ERROR: config looks corrupt (${lines} lines), refusing to continue"
    return 1
  fi
  if ! grep -qE '^cat_x_offset=' "$CONFIG" || ! grep -qE '^cat_y_offset=' "$CONFIG"; then
    log "ERROR: config missing offset keys"
    return 1
  fi
  return 0
}

atomic_write_config() {
  local content=$1
  local tmp
  tmp="$(mktemp "${CONFIG}.XXXXXX")"
  printf '%s\n' "$content" > "$tmp"
  chmod 644 "$tmp"
  mv -f "$tmp" "$CONFIG"
}

apply_config() {
  local x=$1
  local y=$2
  local updated

  validate_config || return 1

  # Rewrite offsets in memory and replace the file atomically.
  # Avoid sed -i, which can leave a truncated/corrupt file if interrupted mid-write.
  updated="$(
    awk -v x="$x" -v y="$y" '
      BEGIN { seen_x = 0; seen_y = 0 }
      /^[[:space:]]*#?[[:space:]]*cat_x_offset=/ {
        print "cat_x_offset=" x
        seen_x = 1
        next
      }
      /^[[:space:]]*#?[[:space:]]*cat_y_offset=/ {
        print "cat_y_offset=" y
        seen_y = 1
        next
      }
      { print }
      END {
        if (!seen_x) print "cat_x_offset=" x
        if (!seen_y) print "cat_y_offset=" y
      }
    ' "$CONFIG"
  )"

  atomic_write_config "$updated"
  validate_config
}

read_config_x() {
  local value
  value="$(grep -E '^cat_x_offset=' "$CONFIG" 2>/dev/null | tail -1 | cut -d= -f2 || true)"
  if [[ -z "$value" ]]; then
    echo 0
  else
    echo "$value"
  fi
}

lerp() {
  local from=$1
  local to=$2
  local step=$3
  local total=$4
  echo $(( from + (to - from) * step / total ))
}

bongocat_alive() {
  if [[ -n "${bongocat_pid:-}" ]] && kill -0 "$bongocat_pid" 2>/dev/null; then
    return 0
  fi
  if [[ -f "$PID_FILE" ]]; then
    local pid
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      bongocat_pid=$pid
      return 0
    fi
  fi
  return 1
}

start_bongocat() {
  local attempt
  local bin
  local -a args=()

  bin="$(resolve_bongocat)"
  stop_all_bongocat

  if (( USE_WATCH_CONFIG )); then
    args+=(--watch-config)
  fi

  for attempt in 1 2; do
    "$bin" "${args[@]}" &
    bongocat_pid=$!
    sleep "$START_WAIT_SEC"

    if bongocat_alive; then
      return 0
    fi

    log "bongocat start attempt ${attempt} failed, retrying"
    stop_all_bongocat
  done

  log "ERROR: bongocat failed to start"
  return 1
}

ensure_bongocat() {
  if bongocat_alive; then
    return 0
  fi
  log "bongocat not running, restarting"
  start_bongocat
}

apply_and_show() {
  local x=$1
  local y=$2

  apply_config "$x" "$y"

  if [[ "$RELOAD_MODE" == restart ]]; then
    start_bongocat
    sleep "$RESTART_FRAME_INTERVAL_SEC"
    return 0
  fi

  sleep "$FRAME_INTERVAL_SEC"
  ensure_bongocat
}

animate_y() {
  local from_y=$1
  local to_y=$2
  local x=$3
  local step
  local y

  for (( step = 1; step <= ANIMATION_STEPS; step++ )); do
    y="$(lerp "$from_y" "$to_y" "$step" "$ANIMATION_STEPS")"
    apply_and_show "$x" "$y"
  done
}

reposition_once() {
  local current_x=$1
  local new_x=$(( RANDOM % (X_MAX - X_MIN + 1) + X_MIN ))

  log "Repositioning: x ${current_x} -> ${new_x}"

  animate_y "$Y_REST" "$Y_PEAK" "$current_x"
  apply_and_show "$new_x" "$Y_PEAK"
  animate_y "$Y_PEAK" "$Y_REST" "$new_x"

  echo "$new_x"
}

main() {
  ensure_config || exit 1
  choose_reload_mode

  local current_x
  current_x="$(read_config_x)"
  apply_config "$current_x" "$Y_REST"
  start_bongocat
  log "Started $(resolve_bongocat) (mode=${RELOAD_MODE}, x=${current_x}, y=${Y_REST}, steps=${ANIMATION_STEPS})"

  while true; do
    sleep "$REPOSITION_INTERVAL_SEC"
    current_x="$(reposition_once "$current_x")"
    log "Reposition complete (x=${current_x}, y=${Y_REST})"
  done
}

main "$@"
