{ pkgs, ... }:

{
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Hostname is set per-host under hosts/*/default.nix
  networking.networkmanager.enable = true;

  time.timeZone = "America/Los_Angeles";

  # The default nixos.pool.ntp.org hosts don't answer on this network (UDP 123
  # timeouts), so timesyncd never syncs and the clock drifts behind.
  services.timesyncd.servers = [ "time.cloudflare.com" ];
  services.timesyncd.fallbackServers = [ "time.cloudflare.com" ];

  i18n.defaultLocale = "en_US.UTF-8";
  i18n.extraLocaleSettings = {
    LC_ADDRESS = "en_US.UTF-8";
    LC_IDENTIFICATION = "en_US.UTF-8";
    LC_MEASUREMENT = "en_US.UTF-8";
    LC_MONETARY = "en_US.UTF-8";
    LC_NAME = "en_US.UTF-8";
    LC_NUMERIC = "en_US.UTF-8";
    LC_PAPER = "en_US.UTF-8";
    LC_TELEPHONE = "en_US.UTF-8";
    LC_TIME = "en_US.UTF-8";
  };

  # Keep the always-on system set lean. Heavy GUI apps stay as packages but
  # are not started as daemons — open only when needed (RAM is the constraint).
  # Toolchains live in programming.nix. Scanners and packet tools live in hacking.nix.
  environment.systemPackages = with pkgs; [
    vesktop
    telegram-desktop
    ffmpeg
    mediainfo
    gource
    gnupg
    inotify-tools
    inotify-info
    goaccess
    ghostty
    foot
    obsidian
    zed-editor
    fd
    ghorg
    nixd
    killall
    jq
    sd
    jc
    ouch
    eza
    ripgrep
    tree
    watchexec
    git
    nautilus
    gh
    vim
    unzip
    btop
    direnv
    mpv
    yt-dlp
  ];
}
