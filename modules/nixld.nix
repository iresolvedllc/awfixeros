{ config, lib, pkgs, ... }:

{
  programs.nix-ld.enable = true;
  programs.nix-ld.libraries = with pkgs; [
    glib
    gtk3
    # gtk2 is marked broken on nixos-unstable (final release Dec 2020,
    # removal before NixOS 27.05) and refuses to evaluate.
    gdk-pixbuf
    nspr
    nss
    alsa-lib
    dbus
    cups
    expat
    libxcb
    libxkbcommon
    libx11
    libxcomposite
    libxdamage
    libxfixes
    libxrandr
    cairo
    pango
    udev
    fontconfig
    freetype
    at-spi2-atk
    at-spi2-core
    mesa
    libdrm
    libGL
    wayland
  ];
}
