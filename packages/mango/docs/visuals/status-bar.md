---
title: Status Bar
description: Configure mangobar and Waybar for mangowm.
---

## Recommended: mangobar

We recommend [mangobar](https://github.com/mangowm/mangobar), a dedicated status bar for mangowm built on `wlr-layer-shell`. It integrates directly with mangowm over IPC, so it stays in sync with your tags, layouts and windows. It ships with built-in modules for workspaces, layout, window title, keymode, keyboard layout, CPU/memory, brightness, volume, clock, network, battery, system tray, and user-defined `custom/<name>` modules.

On Arch Linux, install the AUR package [`mangobar-git`](https://aur.archlinux.org/packages/mangobar-git):

```bash
yay -S mangobar-git
```

Or build from source:

```bash
git clone https://github.com/mangowm/mangobar.git
cd mangobar
./build.sh
```

Start `mangobar` in your mangowm configuration:

```bash
exec_once=mangobar
```

It reads its configuration from `$MANGOBAR_CONFIG` or `~/.config/mangobar/config.jsonc`, and its styling from `~/.config/mangobar/style.css`. See the [mangobar repository](https://github.com/mangowm/mangobar) for a complete reference and example configuration.

## Alternative: the built-in bar

mango ships a minimal floating bar rendered by the compositor itself (no extra
process). It shows tag buttons on the left, and the SNI system tray, battery and
a clock on the right. It is off by default; enable it with:

```bash
bar_enable=1
```

Works out of the box: the missing-tray build (`-Dtray=disabled`) keeps the bar
without tray icons. Battery is polled from `/sys/class/power_supply`; the clock
 wakes once per minute unless the format contains `%S`.

| Option | Default | Description |
| :--- | :--- | :--- |
| `bar_enable` | `0` | Enable the built-in bar (mutually exclusive with mangobar). |
| `bar_height` | `30` | Bar height in logical px. |
| `bar_top_gap` | `6` | Float gap above the bar. |
| `bar_lr_gap` | `6` | Float gap on the left/right edges. |
| `bar_corner_radius` | `10` | Bar background corner radius. |
| `bar_background_color` | `0x9f1a1b26` | Bar surface color. |
| `bar_clock_format` | `%H:%M` | `strftime` format of the clock. |
| `bar_battery_interval` | `300000` | Battery poll interval in ms. |
| `bar_tray_icon_size` | `20` | Tray icon size in logical px. |
| `bar_decorate_font_desc` | `monospace Bold 13` | Widget font. |
| `bar_decorate_fg_color` | `0xffc0caf5` | Text color (idle tags / tray labels). |
| `bar_decorate_focus_fg_color` | `0xff1d2021` | Text color of the active tag. |
| `bar_decorate_focus_bg_color` | `0xff7aa2f7` | Background of the active tag. |
| `bar_decorate_padding_x` | `6` | Side padding of the bar content. |

Tag state: transparent = empty, focused colors = current tag, `urgentcolor` =
a window on that tag is urgent. The `S` button (shown while the special
workspace has windows) toggles the special view. Clicking a tag button switches
to it; clicking tray icons activates the item (right click = secondary
action).

### Installation

On Arch Linux, install the AUR package [`mangobar-git`](https://aur.archlinux.org/packages/mangobar-git):

```sh
yay -S mangobar-git
```

Or build from source:

```sh
git clone https://github.com/mangowm/mangobar.git
cd mangobar
meson setup build -Dprefix=/usr
ninja -C build
sudo ninja -C build install
```

### Usage

Start `mangobar` in your mangowm configuration:

```ini
exec_once=mangobar
```

It reads its configuration from `$MANGOBAR_CONFIG` or `~/.config/mangobar/config.jsonc`, and its styling from `~/.config/mangobar/style.css`. See the [mangobar repository](https://github.com/mangowm/mangobar) for a complete reference and example configuration.

---

## Waybar Module Configuration

### `config.jsonc`

Add the following to your Waybar configuration:

```jsonc
{
  "modules-left": [
    "mango/workspaces",
    "mango/layout",
    "mango/window"
  ],
  "modules-right": [
    "mango/language",
    "mango/keymode",
  ],
  "mango/workspaces": {
      "format": "{icon}",
      "hide-empty": true,
      "on-click": "activate",
      "on-click-right": "toggle",
      "overview-label": "OVERVIEW",
  },
  "mango/keymode": {
  	"format": "{}",
  	// "format-default": " Default",
    // "format-test": " Test",
  },
  "mango/window": {
    "format": "{}",
	  "icon-size": 20
  },
  "mango/layout": {
      "format": "{}",
      // "format-S": "Scroller",
      // "format-T": "Tile",
  },
  "mango/language": {
  "format": "{short}",
  },
}
```

## Styling Example

You can style the tags using standard CSS in `style.css`.

### `style.css`

```css
#workspaces {
  border-color: #c9b890;
  background: rgba(40, 40, 40, 0.76);
}

#workspaces button {
  background: none;
  color: #ddca9e;
}

#workspaces button.hidden {
  color: #9e906f;
  background-color: transparent;
}

#workspaces button.visible {
  color: #ddca9e;
}

#workspaces button:hover {
  color: #d79921;
}

#workspaces button.active {
  background-color: #ddca9e;
  color: #282828;
}

#workspaces button.urgent {
  background-color: #ef5e5e;
  color: #282828;
}

#workspaces button.overview {
  background-color: #ef5e5e;
  color: #282828;
}

#window {
  background-color: #CA9297;
  color: #282828;
}

window#waybar.empty #window {
    background: none;
    margin: 0px;
    padding: 0px;
}

#layout {
  background-color: #CA9297;
  color: #282828;
}

#language {
  background-color: #CA9297;
  color: #282828;
}

#keymode {
  background-color: #CA9297;
  color: #282828;
}

```

## Complete Configuration Example

> **Tip:** You can find a complete Waybar configuration for mangowm at [waybar-config](https://github.com/DreamMaoMao/waybar-config).
