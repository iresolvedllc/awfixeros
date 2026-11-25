{ pkgs, mangoLatest, ... }:

let
  # nixpkgs sddm-astronaut: theme dir is share/sddm/themes/sddm-astronaut-theme
  # Optional: .override { embeddedTheme = "purple_leaves"; }  # see Themes/*.conf
  # Optional: .override { themeConfig = { FormPosition = "left"; /* … */ }; }
  sddmTheme = pkgs.sddm-astronaut;
in
{
  # Mango Wayland compositor (dwl-based) — flake module from
  # github:mangowm/mango (imported in flake.nix). addLoginEntry defaults to
  # true, registering mango.desktop with the display manager automatically.
  # Portals (wlr ScreenCast/Screenshot + gtk FileChooser), polkit and xwayland
  # are all wired up by the mango NixOS module itself.
  programs.mango = {
    enable = true;
    # Local fork (packages/mango) via cached nixpkgs deps + tiny local compile
    # (flake.nix) — avoids the mangowm flake's from-source wlroots/scenefx
    # toolchain build.
    package = mangoLatest;
  };

  # OOM policy lives in modules/systemd.nix (oomd/earlyoom off + sysctl + DefaultOOMPolicy)
  services.displayManager.sddm = {
    enable = true;
    wayland.enable = true;
    theme = "sddm-astronaut-theme";
    # Theme + its Qt6 QML deps (qtmultimedia, qtsvg, qtvirtualkeyboard) for the greeter
    extraPackages = [ sddmTheme ];
  };
  # Prefer Mango at the greeter (hyprland entry is gone; mango.desktop comes
  # from the mango package via addLoginEntry).
  services.displayManager.defaultSession = "mango";

  # GTK settings and Dolphin trash://
  programs.dconf.enable = true;
  services.gvfs.enable = true;

  # Theme must also be on the system path so SDDM finds it under share/sddm/themes
  environment.systemPackages = with pkgs; [
    sddmTheme
  ];

  # Unlock the login keyring with the SDDM session password (libsecret / Seahorse)
  security.pam.services.sddm.enableGnomeKeyring = true;
  services.gnome.gnome-keyring.enable = true;

  # Battery + power status widgets / power profile switching
  services.upower.enable = true;
  services.power-profiles-daemon.enable = true;


  # Intel iGPU (MacBook9,1) — explicit so Wayland sessions always get mesa
  hardware.graphics.enable = true;

  # Hint Electron / Chromium forks (Helium) to use Wayland
  environment.sessionVariables.NIXOS_OZONE_WL = "1";
}
