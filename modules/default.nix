{ ... }:
{
  imports = [
    ./1password.nix
    ./chromium.nix
    ./environment.nix
    ./hacking.nix
    ./programming.nix
    ./firewall.nix
    ./security.nix
    ./privacy.nix
    ./flatpak.nix
    ./mango.nix
    ./nixld.nix
    ./nixpkgs.nix
    ./programs.nix
    ./services.nix
    ./sops.nix
    # memory / zram / swapfile live in hosts/laptop/memory.nix
    ./systemd.nix
    ./users.nix
  ];
}
