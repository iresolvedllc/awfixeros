{ config, lib, pkgs, ... }:

{ 
  security.pam.loginLimits = [
    { domain = "*"; item = "core"; type = "-"; value = "0"; }
  ];
  users.users.awfixer = {
    isNormalUser = true;
    description = "awfixer";
    extraGroups = [
      "networkmanager"
      "wheel"
      "docker"
    ];
    shell = pkgs.zsh;
  };
}
