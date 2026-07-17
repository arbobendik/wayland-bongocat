# Bongo Cat Wayland Overlay

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](https://opensource.org/licenses/MIT)
[![Version](https://img.shields.io/badge/version-2.0.2-blue.svg)](https://github.com/saatvik333/wayland-bongocat/releases)

A cute Wayland overlay that shows an animated bongo cat reacting to your keyboard input.

![Demo](assets/demo.gif)

> Fork of [saatvik333/wayland-bongocat](https://github.com/saatvik333/wayland-bongocat) with optional session
> autostart: a user systemd service plus a supervisor script that periodically repositions the cat
> with a short show/hide (Y-axis) animation. Upstream remains MIT-licensed; see [LICENSE](LICENSE).

## Features

- 🎯 Real-time keyboard animation
- 🔥 Hot-reload configuration
- 🎮 Auto-hides in fullscreen apps
- 🖥️ Multi-monitor support
- 😴 Idle/scheduled sleep mode
- 🎨 SVG-based rendering (pixel-perfect at any size)
- ⚡ Lightweight (~8MB RAM)
- 🚶 Optional animated reposition session (show/hide peek + random X)
- 🧩 User systemd unit for graphical-session autostart

## Quick Start

Pick **one** install path, then run `./install.sh`. That single script:

1. Ensures your user is in group `input` (keyboard access)
2. Finds keyboards and writes `~/.config/bongocat/bongocat.conf`
3. Installs the show/hide session supervisor
4. Enables the user systemd service

### AUR

```bash
yay -S bongocat
git clone https://github.com/arbobendik/wayland-bongocat.git
cd wayland-bongocat
./install.sh --system-only
```

### From source (this fork)

```bash
git clone https://github.com/arbobendik/wayland-bongocat.git
cd wayland-bongocat
./install.sh --from-source
```

Useful flags: `--keyboard-name 'keyd virtual keyboard'`, `--force-config`, `--dry-run`, `--help`.

Manual run without the session service:

```bash
bongocat --watch-config
```

## Fork changes vs upstream

- Smooth hot-reload for animated show/hide repositioning
- `scripts/bongocat-session.sh` + `systemd/user/bongocat.service`
- `./install.sh` one-shot setup

## Configuration

Create `~/.config/bongocat/bongocat.conf`:

```ini
# ═══════════════════════════════════════════════════════════════════════════
# BONGO CAT CONFIG - Minimal defaults, uncomment to customize
# ═══════════════════════════════════════════════════════════════════════════

# Position & Size
cat_height=110
cat_align=center
cat_x_offset=0
cat_y_offset=0

# Appearance
overlay_height=120
overlay_opacity=0
overlay_position=bottom
# mirror_x=0
# mirror_y=0

# Input device (run bongocat-find-devices to find yours)
keyboard_device=/dev/input/event4

# Multi-monitor (comma-separated monitor names)
# monitor=eDP-1,HDMI-A-1

# Sleep mode (optional)
# idle_sleep_timeout=300
# enable_scheduled_sleep=0
# sleep_begin=22:00
# sleep_end=06:00
```

### Options Reference

<details>
<summary>Click to expand all options</summary>

| Option                     | Values            | Default  | Description                          |
| -------------------------- | ----------------- | -------- | ------------------------------------ |
| `cat_height`               | 10-200            | 40       | Cat size in pixels                   |
| `cat_align`                | left/center/right | center   | Horizontal alignment                 |
| `cat_x_offset`             | any int           | 100      | Horizontal offset from alignment     |
| `cat_y_offset`             | any int           | 10       | Vertical offset from center          |
| `enable_antialiasing`      | 0/1               | 1        | **Deprecated** — no-op with SVG      |
| `overlay_height`           | 20-300            | 50       | Overlay bar height in pixels         |
| `overlay_opacity`          | 0-255             | 150      | Background opacity (0=transparent)   |
| `overlay_position`         | top/bottom        | top      | Screen edge position                 |
| `layer`                    | background/bottom/top/overlay | top | Wayland layer type            |
| `keyboard_device`          | /dev/input/path   | auto     | Specific evdev device to monitor     |
| `keyboard_name`            | string            | —        | Match device by name (for hotplug)   |
| `monitor`                  | comma list        | auto     | Monitors to render on                |
| `fps`                      | 1-120             | 60       | Animation frame rate                 |
| `mirror_x`                 | 0/1               | 0        | Flip cat horizontally                |
| `mirror_y`                 | 0/1               | 0        | Flip cat vertically                  |
| `enable_hand_mapping`      | 0/1               | 1        | Map keys to left/right hand frames   |
| `keypress_duration`        | ms                | 100      | How long key-down frame is held      |
| `idle_frame`               | 0-4               | 0        | Frame shown when idle                |
| `idle_sleep_timeout`       | seconds           | 0        | Sleep after idle (0=disabled)        |
| `hotplug_scan_interval`    | seconds           | 30       | Device rescan interval (0=once)      |
| `enable_scheduled_sleep`   | 0/1               | 0        | Enable time-based sleep schedule     |
| `sleep_begin`              | HH:MM             | 00:00    | Sleep schedule start time            |
| `sleep_end`                | HH:MM             | 00:00    | Sleep schedule end time              |
| `disable_fullscreen_hide`  | 0/1               | 0        | Keep overlay visible in fullscreen   |
| `enable_debug`             | 0/1               | 0        | Enable debug logging                 |
| `test_animation_duration`  | ms                | 200      | Test animation frame duration        |
| `test_animation_interval`  | ms                | 0        | Test animation repeat interval       |

Changing monitor count while running requires a restart; other settings are
hot-reloadable with `--watch-config`.

</details>

## Command Line

```bash
bongocat [OPTIONS]

  -c, --config FILE    Config file path (default: auto-detect)
  -m, --monitor NAME   Force specific monitor output
  -w, --watch-config   Auto-reload on config change
  -t, --toggle         Start/stop toggle
  -h, --help           Help
  -v, --version        Version
```

> [!CAUTION]
> **Privacy Notice**: `enable_debug=1` logs all keystrokes to stdout/stderr. Ensure this is disabled (default: 0) for normal usage.

## Troubleshooting

<details>
<summary>Permission denied on input device</summary>

```bash
sudo usermod -a -G input $USER
# Then log out and back in
```

</details>

<details>
<summary>Cat not responding to keyboard</summary>

1. Run `bongocat-find-devices` to find correct device
2. Update `keyboard_device` in config
3. Restart bongocat

</details>

<details>
<summary>Not showing on correct monitor</summary>

Set `monitor=YOUR_MONITOR` (single) or `monitor=MON1,MON2` (multi) in config. Find names with `wlr-randr` or `hyprctl monitors`.

</details>

## Building

```bash
make release   # Optimized
make debug     # Sanitizers
make test
```

**Requirements:** wayland-client, gcc/clang, make

## License

MIT License - see [LICENSE](LICENSE).

Upstream project: [saatvik333/wayland-bongocat](https://github.com/saatvik333/wayland-bongocat)
(Copyright (c) 2025 Saatvik Sharma).
