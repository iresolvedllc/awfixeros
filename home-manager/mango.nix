# Mango Wayland compositor (dwl-based) — user session config.
# System side (SDDM + login entry + portals) lives in modules/mango.nix.
# Docs: https://mangowm.github.io/docs/installation#nixos
{
  config,
  lib,
  pkgs,
  mangowm,
  mangoLatest,
  ...
}:

{
  imports = [ mangowm.hmModules.mango ];

  wayland.windowManager.mango = {
    enable = true;
    # Local fork build from packages/mango (system module shares it — the
    # module validates config.conf with `mango -c … -p`).
    package = mangoLatest;

    # Autostart carried over from the Hyprland `hyprland.start` hook. The
    # module writes this to ~/.config/mango/autostart.sh and adds the
    # exec_once line to config.conf automatically.
    autostart_sh = ''
      1password --silent &
    '';

    # Written to ~/.config/mango/config.conf (validated at build time by
    # `mango -c … -p`). Keys use upstream names — see assets/config.conf.
    settings = {
      # Laptop panel (MacBook9,1) — same 1.5 scale the Hyprland config used.
      # width/height/refresh unset → preferred mode.
      monitor_rule = [ "name:eDP-1,scale:1.5" ];

      # This fork's built-in floating bar (tag buttons + battery + clock +
      # SNI tray). Off by default in the compositor; 1 turns it on. The other
      # bar_* keys (bar_height 30, bar_top_gap/lr_gap 6, clock %H:%M) already
      # have sane defaults.
      bar_enable = 1;

      # Animations/blur off on 8 GiB / m3-6Y30 — less compositor CPU/RAM churn.
      animations = 0;
      blur = 0;

      # Gaps + borders mirroring the old Hyprland look.
      gap_inner_horizontal = 4;
      gap_inner_vertical = 4;
      gap_outer_horizontal = 8;
      gap_outer_vertical = 8;
      border_px = 2;
      focus_color = "0x00ffccaa";
      border_color = "0x272727aa";

      # Input (matches the Hyprland input block).
      xkb_rules_layout = "us";
      sloppy_focus = 1;
      trackpad_natural_scrolling = 1;

      # Layouts: master-stack ("tile") on all tags, like upstream defaults.
      tag_rule = map (i: "id:${toString i},layout_name:tile") (lib.range 1 9);

      bind = [
        # Config / session
        "SUPER,R,reload_config"
        "SUPER,M,quit"

        # Launcher + apps: mlaunch is the fork's built-in launcher — chords,
        # plus release of a *solo* Super tap (see bindr below; mango's
        # hold-keyguard makes Super+chord presses not fire it).
        "SUPER,D,spawn,mlaunch"
        "ALT,space,spawn,mlaunch"
        "SUPER,Return,spawn,foot"
        "SUPER,B,spawn,helium"
        "SUPER,E,spawn,nautilus"
        "SUPER,K,spawn,kraken"

        # Window management
        "SUPER,Q,killclient,"
        "SUPER,F,togglefullscreen,"
        "SUPER+ALT,space,togglefloating,"
        "SUPER,N,switch_layout"

        # Focus (arrows + the same H/L/J chords Hyprland had)
        "SUPER,Tab,focusstack,next"
        "SUPER,Left,focusdir,left"
        "SUPER,Right,focusdir,right"
        "SUPER,Up,focusdir,up"
        "SUPER,Down,focusdir,down"
        "SUPER,H,focusdir,left"
        "SUPER,L,focusdir,right"
        "SUPER,J,focusdir,down"

        # Move windows
        "SUPER+SHIFT,Left,move_client,left"
        "SUPER+SHIFT,Right,move_client,right"
        "SUPER+SHIFT,Up,move_client,up"
        "SUPER+SHIFT,Down,move_client,down"

        # Tags 1-5 (Hyprland workspaces 1-5 parity): view / move-and-follow
        "SUPER,1,view,1,0"
        "SUPER,2,view,2,0"
        "SUPER,3,view,3,0"
        "SUPER,4,view,4,0"
        "SUPER,5,view,5,0"
        "SUPER+SHIFT,1,tag,1,0"
        "SUPER+SHIFT,2,tag,2,0"
        "SUPER+SHIFT,3,tag,3,0"
        "SUPER+SHIFT,4,tag,4,0"
        "SUPER+SHIFT,5,tag,5,0"

        # Screenshots — grim/slurp/satty scripts work on any wlroots
        # compositor (screenshot-window stays Hyprland-only: hyprctl).
        "SUPER+SHIFT,S,spawn,screenshot-region"
        "SUPER+SHIFT,F,spawn,screenshot-full"

        # Media keys — audio stack is disabled; these drive Spotify via MPRIS.
        # NOTE: no separate XF86AudioPause bind — xkb maps Play and Pause to
        # the same keycodes (inet <I22>/<I172> play/pause toggle keys), and
        # mango resolves binds by keycode, so a second line is a duplicate.
        # This one bind fires for Pause-emitting keyboards too.
        "NONE,XF86AudioPlay,spawn,playerctl play-pause"
        "NONE,XF86AudioNext,spawn,playerctl next"
        "NONE,XF86AudioPrev,spawn,playerctl previous"

        # Brightness hardware keys (direct brightnessctl fallback).
        "NONE,XF86MonBrightnessUp,spawn,brightnessctl s 5%+"
        "NONE,XF86MonBrightnessDown,spawn,brightnessctl s 5%-"
      ];

      # Solo Super tap → mlaunch on release. The compositor sets
      # last_hold_keycode on the press and mouse/trackpad events clear it, so
      # a Super+chord hold never triggers this — only the independent press.
      # (mangonag's `bindr` docs example: bindr=Super,Super_L,spawn,rofi …)
      bindr = [
        "Super,Super_L,spawn,mlaunch"
        "Super,Super_R,spawn,mlaunch"
      ];

      # Mouse-held window management (same as Hyprland SUPER+drag/resize).
      mousebind = [
        "SUPER,btn_left,moveresize,curmove"
        "SUPER,btn_right,moveresize,curresize"
      ];

      # SUPER + scroll → switch tags (Hyprland SUPER+mouse wheel parity).
      axisbind = [
        "SUPER,UP,viewtoleft_have_client"
        "SUPER,DOWN,viewtoright_have_client"
      ];

      # 3-finger horizontal swipe → switch tags (Hyprland gesture parity).
      gesturebind = [
        "none,left,3,viewtoleft,0"
        "none,right,3,viewtoright,0"
      ];
    };
  };

  # Only set browser Wayland hint here. Do not set XDG_SESSION_* —
  # SDDM/mango own those; forcing them can break session registration.
  home.sessionVariables = {
    NIXOS_OZONE_WL = "1";
    # Electron / Chromium WebRTC capture via XDG ScreenCast → PipeWire
    ELECTRON_OZONE_PLATFORM_HINT = "auto";
    # Qt apps follow the KDE color scheme (darkly) that ii manages
    QT_QPA_PLATFORMTHEME = "kde";
  };

  # Hyprland is gone — on every rebuild, clear the files its home-manager
  # setup dropped into ~/.config/hypr (hyprland.lua, bindings.lua,
  # .luarc.json, hypridle.conf and the stray .conf/.backup files).
  # Everything was backed up to ~/backups/hyprland-* first.
  home.activation.clearHyprlandHomeFiles = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    if [ -e "$HOME/.config/hypr" ]; then
      run rm -rf "$HOME/.config/hypr"
    fi
  '';
}
