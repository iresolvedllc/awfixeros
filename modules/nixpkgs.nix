{ config, lib, pkgs, ... }:

{
  nixpkgs.overlays = [
    (final: prev: {
      # nixpkgs 26.11 removed buildGo125Module (Go 1.25 EOL). sops-nix still
      # calls it; alias to the current 1.26 builder until upstream switches.
      buildGo125Module = final.buildGo126Module;
      # filen-desktop: deep dep canvas 3.1.0 omits `#include <cstdint>`, which
      # GCC 15+ requires. Backport of nixpkgs 230cb0e018ae; drop once our pin
      # advances past it (or filen bumps canvas >= 3.2.1).
      filen-desktop = prev.filen-desktop.overrideAttrs (oldAttrs: {
        npmRebuildFlags = [ "--ignore-scripts" ];
        preBuild = (oldAttrs.preBuild or "") + ''
          substituteInPlace node_modules/canvas/src/CharData.h \
            --replace-fail '#pragma once' '#pragma once
          #include <cstdint>'

          npm rebuild
        '';
      });
      helium-browser = final.callPackage ../packages/helium { };
      helium-devtools = final.callPackage ../packages/helium-devtools { };
      gloomberb = final.callPackage ../packages/gloomberb { };
      openwork = final.callPackage ../packages/openwork { };
      kraken-desktop = final.callPackage ../packages/kraken { };
      freebuff-desktop = final.callPackage ../packages/freebuff-desktop { };
      vela-cli = final.callPackage ../packages/vela { };
      t3-code = final.callPackage ../packages/t3-code { };
      grok-bot = final.callPackage ../packages/grok-bot { };
      macbook-thermal = final.callPackage ../packages/macbook-thermal { };
      spotifast = final.callPackage ../packages/spotifast { };
      penguin-mail = final.callPackage ../packages/penguin-mail { };
      omnidiff = final.callPackage ../packages/omnidiff { };
    })
  ];

  # 8 GiB machine: never parallel-build (multiple rustc/llvm jobs → instant OOM).
  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    max-jobs = 1;
    cores = 2;
    # Leave free space / breathing room for the session during store GC pressure.
    min-free = 512 * 1024 * 1024; # 512 MiB
    max-free = 3 * 1024 * 1024 * 1024; # 3 GiB target after GC
  };

  nixpkgs.config.allowUnfree = true;
}
