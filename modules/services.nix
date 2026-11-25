{ config, lib, pkgs, ... }:

{
  # xkb layout only — full X server stack is not required for Wayland SDDM/Mango,
  # but NixOS still wires xkb via this option for greeter/XWayland.
  services.xserver = {
    enable = true;
    xkb = {
      layout = "us";
      variant = "";
    };
    # No X desktop extras.
    excludePackages = [ ];
  };

  # PipeWire is required for Bluetooth A2DP (speakers/headsets).
  # Without it BlueZ fails with "a2dp-sink profile connect failed: Protocol not available".
  services.pipewire = {
    enable = true;
    audio.enable = true;
    alsa.enable = true;
    pulse.enable = true;
    jack.enable = false;
    wireplumber.enable = true;
  };
  virtualisation.docker = {
    enable = true;
    enableOnBoot = true;
    extraPackages = with pkgs; [
      docker-color-output
      docker-language-server
      docker-gc
    ];
  };
  services.pulseaudio.enable = false;
  security.rtkit.enable = true;

  # Bluetooth: root daemon + blueman tray. A2DP media endpoints come from WirePlumber.
  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
    settings.General = {
      Enable = "Source,Sink,Media,Socket";
    };
  };
  services.blueman.enable = true;
  environment.systemPackages = [ pkgs.bluez ];
}
