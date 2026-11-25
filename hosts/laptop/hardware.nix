# Vendored from `nixos-generate-config` on MacBook9,1 (m3-6Y30).
# Refresh with:
#   nixos-generate-config --show-hardware-config > hosts/laptop/hardware.nix
# then re-check UUIDs and module imports.
{
  config,
  lib,
  modulesPath,
  ...
}:

{
  # Vendored from `nixos-generate-config` on MacBook9,1 (m3-6Y30); trimmed to
  # the pure disk/ACPI manifest. Module/boot config moved to ./kernel.nix
  # (initrd lists, blacklists, params) and ./thermal.nix (coretemp/rapl).
  # Refresh with:
  #   nixos-generate-config --show-hardware-config > hosts/laptop/hardware.nix
  # then re-check UUIDs and module imports.
  imports = [
    (modulesPath + "/hardware/network/broadcom-43xx.nix")
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  fileSystems."/" = {
    device = "/dev/disk/by-uuid/fac49b73-2d2d-4aef-9f4e-d4879413504c";
    fsType = "ext4";
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-uuid/A5F8-BB1A";
    fsType = "vfat";
    options = [
      "fmask=0077"
      "dmask=0077"
    ];
  };

  # Disk swap is declared in ./memory.nix (not here).
  swapDevices = [ ];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
  hardware.enableRedistributableFirmware = lib.mkDefault true;
}
