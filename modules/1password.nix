{ config, lib, pkgs, ... }:

let
  # Official 1Password Chrome-extension IDs (stable + betas) that BrowserSupport accepts.
  allowedOrigins = [
    "chrome-extension://hjlinigoblmkhjejkmbegnoaljkphmgo/"
    "chrome-extension://bkpbhnjcbehoklfkljkkbbmipaphipgl/"
    "chrome-extension://gejiddohjgogedgjnonbofjigllpkmbf/"
    "chrome-extension://khgocmkkpikpnmmkgmdnfckapcdkgfaf/"
    "chrome-extension://aeblfdkhhhdcdjpifhhbdiojplfjncoa/"
    "chrome-extension://dppgmdbiimibapkepcbdbmkaabgiofem/"
  ];

  # Must use the setgid security wrapper — the raw store binary is rejected.
  browserSupportPath = "/run/wrappers/bin/1Password-BrowserSupport";

  nmhManifest = builtins.toJSON {
    name = "com.1password.1password";
    description = "1Password BrowserSupport";
    path = browserSupportPath;
    type = "stdio";
    allowed_origins = allowedOrigins;
  };

  # Executable basenames for 1Password BrowserSupport allow-list
  # (/etc/1password/custom_allowed_browsers). Must match the on-disk binary
  # name (basename of /proc/<pid>/exe), not necessarily /proc/comm.
  # Helium → helium; Orion GTK flatpak command → oriongtk.
  # Note: Orion renames its process comm to "main"; allow-list still uses
  # the executable basename `oriongtk`.
  allowedBrowsers = ''
    helium
    oriongtk
    brave
  '';

  # Config dirs where Chromium-style Native Messaging Hosts are read.
  # Relative to $HOME/.config/ unless absolute (see seed script).
  # Orion GTK beta is the Flatpak (com.kagi.OrionGtk). Config lives at:
  #   ~/.var/app/com.kagi.OrionGtk/...
  nmhConfigDirs = [
    # relative → $HOME/.config/<dir>/NativeMessagingHosts
    "net.imput.helium"
    "com.kagi.OrionGtk"
    "oriongtk"
  ];

  # Absolute-under-home paths (not under .config).
  nmhHomeRelativeDirs = [
    ".var/app/com.kagi.OrionGtk/config"
    ".var/app/com.kagi.OrionGtk/config/chromium"
  ];

  # packages/1password patchelfs the bundled 1password-mcp and links it on
  # $out/bin. The setgid wrapper still has to be the binary clients exec:
  # Cursor and other GUI clients spawn with a stripped PATH, and on Linux
  # 1Password rejects the connection when the MCP parent is a user-owned
  # AppImage or FHS binary (BinaryPermissions). Launch through bash so the
  # parent of the real server is a system shell, then exec the setgid
  # wrapper (same pattern as BrowserSupport).
  # See: https://www.1password.community/developers-69/1password-mcp-on-linux-rejecting-mcp-connections-25021
  onepasswordMcpClient = pkgs.writeShellScriptBin "1password-mcp" ''
    set -euo pipefail
    bin=/run/wrappers/bin/1password-mcp-bin
    if [ ! -x "$bin" ]; then
      echo "1password-mcp: missing setgid wrapper at $bin (rebuild/switch nixos?)" >&2
      exit 127
    fi
    "$bin" "$@" <&0 &
    child=$!
    trap 'kill "$child" 2>/dev/null || true' TERM INT HUP
    wait "$child"
  '';
in
{
  # Desktop app + CLI (installs setgid 1Password-BrowserSupport wrapper).
  programs._1password = {
    enable = true;
    package = pkgs._1password-cli;
  };

  programs._1password-gui = {
    enable = true;
    polkitPolicyOwners = [ "awfixer" ];
  };

  # setgid trampoline for the MCP binary (mirrors 1Password-BrowserSupport).
  security.wrappers."1password-mcp-bin" = {
    source = "${config.programs._1password-gui.package}/bin/1password-mcp";
    owner = "root";
    group = "onepassword";
    setuid = false;
    setgid = true;
  };

  # Client-facing `1password-mcp` on PATH (bash parent + setgid child).
  environment.systemPackages = [ onepasswordMcpClient ];

  environment.etc = {
    # 1Password only trusts browsers on its built-in list, or entries here.
    # Docs: https://support.1password.com/additional-browsers/
    # Own this path exclusively (chromium.nix used to also set it).
    "1password/custom_allowed_browsers" = lib.mkForce {
      text = allowedBrowsers;
      # Executable bit is conventional for this file on 1Password's docs/examples.
      mode = "0755";
    };

    # Helium (and other Chromium forks) can read system NMH from here.
    # packages/helium binds /etc/chromium into its environment.
    "chromium/native-messaging-hosts/com.1password.1password.json".text = nmhManifest;
  };

  # 1Password's NMH installer only knows a hard-coded list of config dirs
  # (chrome, chromium, brave, vivaldi, …). It never writes to Helium's or
  # Orion's config trees. Seed NativeMessagingHosts for every user.
  system.userActivationScripts.onepasswordCustomBrowserNmh = {
    text = ''
      ${lib.concatMapStrings (dir: ''
        nmh_dir="$HOME/.config/${dir}/NativeMessagingHosts"
        mkdir -p "$nmh_dir"
        printf '%s\n' '${nmhManifest}' > "$nmh_dir/com.1password.1password.json"
      '') nmhConfigDirs}
      ${lib.concatMapStrings (dir: ''
        nmh_dir="$HOME/${dir}/NativeMessagingHosts"
        mkdir -p "$nmh_dir"
        printf '%s\n' '${nmhManifest}' > "$nmh_dir/com.1password.1password.json"
      '') nmhHomeRelativeDirs}
    '';
  };
}
