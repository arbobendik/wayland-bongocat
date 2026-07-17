#!/usr/bin/env bash
# One-shot setup: input group, keyboard, config, session script, user systemd unit.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
USER_NAME="${USER:?}"
HOME_DIR="${HOME:?}"
XDG_CONFIG="${XDG_CONFIG_HOME:-$HOME_DIR/.config}"
CONFIG_DIR="$XDG_CONFIG/bongocat"
CONFIG="$CONFIG_DIR/bongocat.conf"
TEMPLATE="$CONFIG_DIR/bongocat.conf.template"
UNIT_DIR="$XDG_CONFIG/systemd/user"
LOCAL_BIN="$HOME_DIR/.local/bin"

FROM_SOURCE=0
SYSTEM_ONLY=0
FORCE_CONFIG=0
NONINTERACTIVE=0
DRY_RUN=0
KEYBOARD_NAME=""
START_SERVICE=1

usage() {
  cat <<'USAGE'
Usage: ./install.sh [options]

  --from-source       Build this repo and install ~/.local/bin/bongocat
  --system-only       Use an already-installed bongocat (e.g. AUR); do not build
  --keyboard-name N   Skip picker; write keyboard_name=N into the config
  --force-config      Overwrite ~/.config/bongocat/bongocat.conf
  --non-interactive   No prompts (requires --keyboard-name, or auto-picks keyd/first)
  --no-start          Install unit but do not enable/start it
  --dry-run           Print actions only
  -h, --help          Show help

Examples:
  yay -S bongocat && ./install.sh --system-only
  ./install.sh --from-source
USAGE
}

log() { printf '[install] %s\n' "$*" >&2; }
run() {
  if (( DRY_RUN )); then
    printf '[dry-run]' >&2
    printf ' %q' "$@" >&2
    printf '\n' >&2
    return 0
  fi
  "$@"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from-source) FROM_SOURCE=1; shift ;;
    --system-only) SYSTEM_ONLY=1; shift ;;
    --force-config) FORCE_CONFIG=1; shift ;;
    --non-interactive) NONINTERACTIVE=1; shift ;;
    --no-start) START_SERVICE=0; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --keyboard-name)
      KEYBOARD_NAME="${2:?--keyboard-name needs a value}"
      shift 2
      ;;
    --keyboard-name=*)
      KEYBOARD_NAME="${1#*=}"
      shift
      ;;
    -h|--help) usage; exit 0 ;;
    *)
      log "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
done

if (( FROM_SOURCE && SYSTEM_ONLY )); then
  log "Pick one of --from-source or --system-only"
  exit 1
fi

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    log "Missing required command: $1"
    exit 1
  }
}

ensure_input_group() {
  if id -nG "$USER_NAME" | tr ' ' '\n' | grep -qx input; then
    log "User ${USER_NAME} is already in group 'input'"
    return 0
  fi

  log "Adding ${USER_NAME} to group 'input' (needed to read keyboards)"
  if (( DRY_RUN )); then
    log "Would run: sudo usermod -aG input ${USER_NAME}"
    return 0
  fi
  if [[ "${EUID}" -eq 0 ]]; then
    usermod -aG input "$USER_NAME"
  else
    need_cmd sudo
    sudo usermod -aG input "$USER_NAME"
  fi
  log "Group updated. Log out and back in (or reboot) before key events work."
}

list_keyboards() {
  # Prints "name<TAB>path" lines for KEYBOARD devices.
  local finder="" out
  if [[ -x "$ROOT/scripts/find_input_devices.sh" ]]; then
    finder="$ROOT/scripts/find_input_devices.sh"
  elif command -v bongocat-find-devices >/dev/null 2>&1; then
    finder="$(command -v bongocat-find-devices)"
  else
    log "No device finder found (scripts/find_input_devices.sh or bongocat-find-devices)"
    return 1
  fi

  out="$("$finder" 2>/dev/null || true)"
  awk '
    /^\s*[✓*].*\[KEYBOARD\]/ {
      name = $0
      sub(/^.*\[KEYBOARD\][[:space:]]*/, "", name)
      getline
      path = $0
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", path)
      if (name != "" && path ~ /^\/dev\/input\//) {
        print name "\t" path
      }
    }
  ' <<<"$out"
}

pick_keyboard() {
  local -a names=() paths=()
  local line name path i choice default_idx=0

  if [[ -n "$KEYBOARD_NAME" ]]; then
    printf '%s\n' "$KEYBOARD_NAME"
    return 0
  fi

  while IFS=$'\t' read -r name path; do
    [[ -z "$name" ]] && continue
    names+=("$name")
    paths+=("$path")
    if [[ "$name" == "keyd virtual keyboard" ]]; then
      default_idx=$((${#names[@]} - 1))
    fi
  done < <(list_keyboards)

  if ((${#names[@]} == 0)); then
    log "No keyboards detected. Are you in group 'input', and is /dev/input readable?"
    exit 1
  fi

  if (( NONINTERACTIVE )); then
    log "Auto-selecting keyboard: ${names[$default_idx]}"
    printf '%s\n' "${names[$default_idx]}"
    return 0
  fi

  echo
  log "Detected keyboards:"
  for i in "${!names[@]}"; do
    printf '  %d) %s (%s)\n' "$((i + 1))" "${names[$i]}" "${paths[$i]}"
  done
  printf '  Enter choice [%d]: ' "$((default_idx + 1))"
  read -r choice || true
  if [[ -z "${choice:-}" ]]; then
    choice=$((default_idx + 1))
  fi
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#names[@]} )); then
    log "Invalid choice"
    exit 1
  fi
  printf '%s\n' "${names[$((choice - 1))]}"
}

write_config() {
  local keyboard_name=$1
  local example="$ROOT/bongocat.conf.example"

  if [[ ! -f "$example" ]]; then
    log "Missing $example"
    exit 1
  fi

  run mkdir -p "$CONFIG_DIR"
  if (( DRY_RUN )); then
    log "Would install template and config with keyboard_name=${keyboard_name}"
    return 0
  fi

  install -Dm644 "$example" "$TEMPLATE"

  if [[ -f "$CONFIG" && "$FORCE_CONFIG" -eq 0 ]]; then
    log "Keeping existing config: $CONFIG"
    # Ensure session offsets exist; set keyboard if missing.
    if ! grep -qE '^cat_x_offset=' "$CONFIG"; then
      printf '\ncat_x_offset=0\n' >>"$CONFIG"
    fi
    if ! grep -qE '^cat_y_offset=' "$CONFIG"; then
      printf 'cat_y_offset=45\n' >>"$CONFIG"
    fi
    if ! grep -qE '^keyboard_name=' "$CONFIG" && ! grep -qE '^keyboard_device=' "$CONFIG"; then
      printf 'keyboard_name=%s\n' "$keyboard_name" >>"$CONFIG"
    fi
    return 0
  fi

  local tmp
  tmp="$(mktemp)"
  # Prefer persistent keyboard_name; drop example keyboard_device line.
  awk -v kn="$keyboard_name" '
    BEGIN { done_input = 0 }
    /^keyboard_device=/ {
      if (!done_input) {
        print "# Selected by install.sh (persistent name)"
        print "keyboard_name=" kn
        print "# keyboard_device=/dev/input/eventX"
        done_input = 1
      }
      next
    }
    /^keyboard_name=/ {
      if (!done_input) {
        print "keyboard_name=" kn
        done_input = 1
      }
      next
    }
    /^cat_y_offset=/ { print "cat_y_offset=45"; next }
    { print }
    END {
      if (!done_input) {
        print "keyboard_name=" kn
      }
    }
  ' "$example" >"$tmp"
  install -Dm644 "$tmp" "$CONFIG"
  rm -f "$tmp"
  log "Wrote config: $CONFIG"
}

install_binary_from_source() {
  need_cmd make
  need_cmd gcc
  log "Building release binary"
  if (( DRY_RUN )); then
    log "Would run: make -C $ROOT release"
    log "Would install build/bongocat -> $LOCAL_BIN/bongocat"
    return 0
  fi
  make -C "$ROOT" release -j"$(nproc)"
  install -Dm755 "$ROOT/build/bongocat" "$LOCAL_BIN/bongocat"
  # Session helpers used by find_input_devices packaging name.
  if [[ -x "$ROOT/scripts/find_input_devices.sh" ]]; then
    install -Dm755 "$ROOT/scripts/find_input_devices.sh" "$LOCAL_BIN/bongocat-find-devices"
  fi
  log "Installed $LOCAL_BIN/bongocat"
}

ensure_bongocat_binary() {
  if (( FROM_SOURCE )); then
    install_binary_from_source
    return 0
  fi

  if (( SYSTEM_ONLY )); then
    if ! command -v bongocat >/dev/null 2>&1 && [[ ! -x /usr/bin/bongocat ]]; then
      log "No bongocat on PATH. Install the AUR package first: yay -S bongocat"
      exit 1
    fi
    log "Using system bongocat: $(command -v bongocat 2>/dev/null || echo /usr/bin/bongocat)"
    return 0
  fi

  # Auto: prefer existing binary; otherwise build this tree.
  if command -v bongocat >/dev/null 2>&1 || [[ -x /usr/bin/bongocat ]]; then
    log "Using existing bongocat: $(command -v bongocat 2>/dev/null || echo /usr/bin/bongocat)"
    log "Tip: use --from-source to install this fork's binary with smooth reposition patches"
    return 0
  fi

  log "No system bongocat found; building from this repository"
  install_binary_from_source
}

install_session() {
  run mkdir -p "$LOCAL_BIN" "$UNIT_DIR"
  if (( DRY_RUN )); then
    log "Would install session script and systemd user unit"
    return 0
  fi
  install -Dm755 "$ROOT/scripts/bongocat-session.sh" "$LOCAL_BIN/bongocat-session.sh"
  install -Dm644 "$ROOT/systemd/user/bongocat.service" "$UNIT_DIR/bongocat.service"
  log "Installed session script and user unit"
}

enable_service() {
  need_cmd systemctl
  if (( DRY_RUN )); then
    log "Would: systemctl --user daemon-reload && enable && restart bongocat.service"
    return 0
  fi
  systemctl --user daemon-reload
  systemctl --user enable bongocat.service
  if (( START_SERVICE )); then
    systemctl --user restart bongocat.service
    systemctl --user --no-pager --full status bongocat.service || true
  else
    log "Unit enabled; start later with: systemctl --user start bongocat.service"
  fi
}

main() {
  log "Repo: $ROOT"
  ensure_input_group
  ensure_bongocat_binary

  local keyboard
  keyboard="$(pick_keyboard)"
  log "Keyboard: $keyboard"

  write_config "$keyboard"
  install_session
  enable_service

  echo
  log "Done."
  log "Config:  $CONFIG"
  log "Service: systemctl --user status bongocat.service"
  if ! id -nG | tr ' ' '\n' | grep -qx input; then
    log "Re-login (or reboot) so group 'input' applies to this session."
  fi
}

main "$@"
