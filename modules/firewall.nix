{ lib, ... }:

{
  # ---------------------------------------------------------------------------
  # Inbound lockdown (laptop)
  # - Outbound connections (including ssh CLIENT to mine) stay allowed
  # - Inbound new connections are dropped by default
  # - OpenSSH server is fully disabled (no daemon, no port 22 hole)
  # ---------------------------------------------------------------------------

  # Never run an SSH server on this machine
  services.openssh = {
    enable = false;
    openFirewall = false;
    startWhenNeeded = false;
  };

  # Belt-and-suspenders: prevent socket-activated / residual sshd units
  systemd.services.sshd.enable = false;
  systemd.services."sshd@".enable = false;
  systemd.sockets.sshd.enable = lib.mkForce false;

  # No initrd SSH either (remote unlock would be inbound)
  boot.initrd.network.ssh.enable = false;

  # -----------------------------------------------------------------------
  # Reverse-path filter stays at the NixOS default ("loose").

  networking.firewall = {
    enable = true;

    # Drop refused packets (no RST / ICMP unreachable — harder to scan)
    rejectPackets = false;

    # Do not answer pings
    allowPing = false;

    # No inbound ports. A dev server on 127.0.0.1 still works.
    # mDNS, Spotify Connect, and Tailscale are not configured here.
    # Mullvad is installed in privacy.nix and opens no ports.
    allowedTCPPorts = [ ];
    allowedUDPPorts = [ ];
    logRefusedConnections = true;
    allowedTCPPortRanges = [ ];
    allowedUDPPortRanges = [ ];

    # Do not trust any interface enough to skip filtering.
    trustedInterfaces = [ ];
  };

  # Client tools stay available (ssh, scp, sftp) via openssh package on PATH
  # when home-manager / system packages pull them in — we only kill the server.
}
