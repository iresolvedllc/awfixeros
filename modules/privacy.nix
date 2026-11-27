{ pkgs, ... }:

{
  # Packages only. Nothing here is started at boot.
  # Tor Browser and Mullvad Browser carry their own network stacks.
  # `services.tor.enable` would start the system tor daemon.
  # `services.mullvad-vpn.enable` would start mullvad-daemon (and can
  # block traffic). Leave both off; the binaries are still on PATH.

  services.tor = {
    enable = false;
    openFirewall = false;
    client = {
      enable = false;
      dns.enable = false;
      transparentProxy.enable = false;
    };
    relay.enable = false;
    controlSocket.enable = false;
    torsocks.enable = false;
    tsocks.enable = false;
  };

  services.mullvad-vpn = {
    enable = false;
    gui.enable = false;
    enableEarlyBootBlocking = false;
    # Module default is true, which adds a setuid mullvad-exclude once the
    # daemon is turned on. Keep the wrapper off.
    enableExcludeWrapper = false;
  };

  environment.systemPackages = with pkgs; [
    tor-browser
    mullvad-browser

    tor
    torsocks
    nyx

    # Pluggable transports a later torrc can exec. Not wired into a daemon.
    obfs4
    snowflake
    webtunnel

    proxychains-ng

    # CLI + daemon binary, and the GUI. The systemd unit stays disabled.
    mullvad
    mullvad-vpn
  ];
}
