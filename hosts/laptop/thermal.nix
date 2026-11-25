{ lib, pkgs, ... }:

{
  # ---------------------------------------------------------------------------
  # MacBook9,1 (m3-6Y30) power keep-alive
  #
  # Hardware reality (verified 2026-10-13, SMC key walk of all 701 entries):
  # this 12" Retina MacBook is FANLESS. The SMC exposes exactly one F* key
  # (FNum = 0) and no fan keys at all — FNum=0 is not a driver bug, it is the
  # correct SMC state for a fanless chassis.
  #
  # intel_rapl nonetheless advertises PL1/PL2 = 49 W on this 4.5 W part, and
  # power-profiles-daemon was once left on `performance`: idle → ~20 min →
  # chassis thermal poweroff. The governor (packages/macbook-thermal) caps
  # RAPL at 15/22 W and throttles (EPP=power + no_turbo) above 85 C.
  #
  # Do not rebuild the kernel here: compiling linux on this 4.5 W dual-core
  # will cook it. Everything runs in userspace over sysfs.
  # ---------------------------------------------------------------------------

  environment.systemPackages = [ pkgs.macbook-thermal ];

  # applesmc contributes nothing on a fanless board (no fan keys, no usable
  # key set) and logs `fan=0` noise; the governor no longer needs its I/O
  # ports gone, but keeping it unloaded is the honest configuration.
  boot.blacklistedKernelModules = [ "applesmc" ];

  boot.kernelModules = [
    # coretemp exposes the package temp the governor polls; intel_rapl_msr
    # is what lets sysfs RAPL be rewritten after firmware set absurd caps.
    "coretemp"
    "intel_rapl_msr"
  ];

  # TLP fights power-profiles-daemon (already enabled for Hyprland widgets).
  # `balanced` (not `performance`, which cooked the chassis, and not
  # `power-saver`, which pinned the m3 at ~600 MHz). The governor still
  # drops EPP to `power` and disables turbo if the package gets hot.
  systemd.services.macbook-power-profile = {
    description = "MacBook9,1 default balanced power profile";
    wantedBy = [ "multi-user.target" ];
    after = [ "power-profiles-daemon.service" ];
    wants = [ "power-profiles-daemon.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.power-profiles-daemon}/bin/powerprofilesctl set balanced";
    };
  };

  systemd.services.macbook-thermal = {
    description = "MacBook9,1 fanless RAPL cap + EPP governor";
    wantedBy = [ "multi-user.target" ];
    after = [ "systemd-modules-load.service" ];
    serviceConfig = {
      Type = "simple";
      ExecStart = "${lib.getExe pkgs.macbook-thermal}";
      Restart = "always";
      RestartSec = "2s";
    };
  };
}
