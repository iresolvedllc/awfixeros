{
  description = "NixOS configuration with Mango";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nix-flatpak.url = "github:gmodena/nix-flatpak/?ref=v0.8.0";
    # Daemon + static web packages, not the Electron desktop (no Linux release).
    # Pinned: upstream removed flake.nix in 49cc51058fd7
    # (chore(nix): retire official Nix distribution, #7644). HEAD is not a flake.
    open-design = {
      url = "github:nexu-io/open-design/db9ebb7ba84d81dffdd21de248cbcd992c791836";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Mango Wayland compositor (dwl-based). Provides nixosModules.mango and
    # hmModules.mango — https://mangowm.github.io/docs/installation#nixos
    # update: skip
    # The running compositor is the local patch in packages/mango.
    mangowm = {
      url = "github:mangowm/mango";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      home-manager,
      sops-nix,
      nix-flatpak,
      open-design,
      mangowm,
      ...
    }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };

      # Located via mcp-nixos (unstable):
      #   playwright / playwright-driver / playwright-test
      #   prisma → prisma_7, prisma-engines → prisma-engines_7
      playwrightBrowsers = pkgs.playwright-driver.browsers;
      prismaEngines = pkgs.prisma-engines;

      # Local mango fork (packages/mango) — adds the built-in floating bar.
      # Built with the same cached nixpkgs deps as pkgs.mango (wlroots_0_20,
      # scenefx 0.5) so only mango itself compiles; systemd enables the bar's
      # SNI tray (meson `tray` is auto, needs libsystemd pkg-config).
      mangoLatest = pkgs.callPackage ./packages/mango/nix {
        systemd = pkgs.systemd;
      };
      # Locally-built Prisma 8 engines (see ~/.local/prisma). Prefer these over
      # nixpkgs prisma-engines_7 so the CLI does not fetch linux-nixos binaries.
      localPrismaHome = "/home/awfixer/.local/prisma";
      localSchemaEngine = "${localPrismaHome}/bin/schema-engine";
      localPrismaFmt = "${localPrismaHome}/bin/prisma-fmt";

      # Shared env so project-local npm/bun playwright & prisma use system bins.
      playwrightPrismaHook = ''
        export PLAYWRIGHT_BROWSERS_PATH="${playwrightBrowsers}"
        export PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
        export PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS=true
        export PRISMA_HOME="${localPrismaHome}"
        if [ -x "${localSchemaEngine}" ]; then
          export PRISMA_SCHEMA_ENGINE_BINARY="${localSchemaEngine}"
        else
          export PRISMA_SCHEMA_ENGINE_BINARY="${prismaEngines}/bin/schema-engine"
        fi
        if [ -x "${localPrismaFmt}" ]; then
          export PRISMA_FMT_BINARY="${localPrismaFmt}"
        fi
        export PRISMA_ENGINES_CHECKSUM_IGNORE_MISSING=1
        export PATH="${localPrismaHome}/bin:$HOME/.local/bin:$PATH"
      '';

      nixosConfigurations =
        let
          # Host lives under ./hosts/laptop (hardware + zram/swap are pure).
          laptop = nixpkgs.lib.nixosSystem {
            system = "x86_64-linux";
            specialArgs = {
              inherit nix-flatpak mangoLatest;
            };
            modules = [
              ./hosts/laptop
              home-manager.nixosModules.home-manager
              sops-nix.nixosModules.sops
              nix-flatpak.nixosModules.nix-flatpak
              mangowm.nixosModules.mango
              ./modules
              (
                { ... }:
                {
                  home-manager = {
                    useGlobalPkgs = true;
                    useUserPackages = true;
                    backupFileExtension = "backup";
                    # Flake inputs needed inside home-manager modules
                    extraSpecialArgs = { inherit mangowm mangoLatest; };
                    users.awfixer = import ./home-manager;
                  };
                }
              )
            ];
          };
        in
        {
          inherit laptop;
          # Back-compat for `.#nixos` / older aliases
          nixos = laptop;
        };
    in
    {
      packages = {
        ${system} = {
          helium-browser = pkgs.callPackage ./packages/helium { };
          helium-devtools = pkgs.callPackage ./packages/helium-devtools { };
          gloomberb = pkgs.callPackage ./packages/gloomberb { };
          openwork = pkgs.callPackage ./packages/openwork { };
          kraken-desktop = pkgs.callPackage ./packages/kraken { };
          freebuff-desktop = pkgs.callPackage ./packages/freebuff-desktop { };
          vela-cli = pkgs.callPackage ./packages/vela { };
          t3-code = pkgs.callPackage ./packages/t3-code { };
          grok-bot = pkgs.callPackage ./packages/grok-bot { };
          spotifast = pkgs.callPackage ./packages/spotifast { };
          penguin-mail = pkgs.callPackage ./packages/penguin-mail { };
          omnidiff = pkgs.callPackage ./packages/omnidiff { };
          onepassword-beta = pkgs.callPackage ./packages/1password {
            _1password-gui = pkgs._1password-gui;
          };
          open-design-daemon = open-design.packages.${system}.daemon;
          open-design-web = open-design.packages.${system}.web;

          # Playwright / Prisma system binaries (for reuse outside the OS config)
          playwright-test = pkgs.playwright-test;
          playwright-browsers = playwrightBrowsers;
          playwright-driver = pkgs.playwright-driver;
          prisma = pkgs.prisma;
          prisma-engines = prismaEngines;
        };
      };

      inherit nixosConfigurations;

      # `nix develop ~/awfixeros` — sources hooks so system engines/browsers win
      devShells.${system}.default = pkgs.mkShell {
        name = "playwright-prisma";
        packages = with pkgs; [
          nodejs_latest
          playwright-test
          prisma
          prisma-engines
          # PHP + Composer for PHP projects (nix develop provides the runtime)
          php
          phpPackages.composer
        ];
        # prisma-engines setup-hook exports PRISMA_SCHEMA_ENGINE_BINARY in pure
        # nix builds; shellHook covers interactive + npm-local CLI usage.
        shellHook = playwrightPrismaHook + ''
          echo "playwright browsers → $PLAYWRIGHT_BROWSERS_PATH"
          echo "prisma schema-engine → $PRISMA_SCHEMA_ENGINE_BINARY"
          echo "prisma fmt → ''${PRISMA_FMT_BINARY:-unset}"
        '';
      };
    };
}
