{ config, pkgs, lib, ... }:

let
  version = "3.31.15";
  # Commit from downloads.cursor.com production channel (api/download).
  commit = "3eb8c13390837371c7c2f2013dc57fdbc802c753";
  cursorPackage = pkgs."code-cursor".overrideAttrs (old: rec {
    inherit version;
    src = pkgs.appimageTools.extract {
      pname = "cursor";
      inherit version;
      src = pkgs.fetchurl {
        url = "https://downloads.cursor.com/production/${commit}/linux/x64/Cursor-${version}-x86_64.AppImage";
        hash = "sha256-ZGgK+FrcBp+JDVF8Il7KmAX4BpYbdn4PYBMLP3ajIF0=";
      };
    };
    sourceRoot = "cursor-${version}-extracted/usr/share/cursor";
    # Cursor 3.31 ships rg in @cursor/ripgrep-linux-x64. nixpkgs postPatch
    # still deletes @vscode/ripgrep/bin/rg, which this release no longer has.
    postPatch =
      let
        from = "rm resources/app/node_modules/@vscode/ripgrep/bin/rg\n";
        to = ''
          mkdir -p resources/app/node_modules/@vscode/ripgrep/bin
          rm -f resources/app/node_modules/@vscode/ripgrep/bin/rg
        '';
        patched = lib.replaceStrings [ from ] [ to ] old.postPatch;
      in
      if patched == old.postPatch then
        throw "cursor postPatch no longer removes @vscode/ripgrep/bin/rg"
      else
        patched;
  });
in
{
  programs.cursor = {
    enable = true;
    package = cursorPackage.fhs;
    profiles.default.enableMcpIntegration = true;
    argvSettings = {
      "password-store" = "gnome-libsecret";
    };
  };

  programs.mcp = {
    enable = true;
    servers = {
      nixos = {
        command = "uvx";
        args = [ "mcp-nixos" ];
      };
      # Absolute path so FHS/GUI Cursor never depends on a stripped PATH
      # (plugin still registers bare `1password-mcp`; this hardens User mcp.json).
      "1password" = {
        command = "/run/current-system/sw/bin/1password-mcp";
        args = [ ];
      };
    };
  };

  home.packages = [ pkgs.uv ];
}
