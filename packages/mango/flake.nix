# update: skip
# Local compositor patch. Do not float this flake's inputs.
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    scenefx = {
      url = "github:wlrfx/scenefx";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      flake-parts,
      ...
    }@inputs:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [
        inputs.flake-parts.flakeModules.easyOverlay
      ];

      flake = {
        hmModules.mango = import ./nix/hm-modules.nix self;
        nixosModules.mango = import ./nix/nixos-modules.nix self;
      };

      perSystem =
        {
          config,
          pkgs,
          ...
        }:
        let
          inherit (pkgs) callPackage;
          mango = callPackage ./nix {
            scenefx = inputs.scenefx.packages.${pkgs.stdenv.hostPlatform.system}.default;
          };
        in
        {
          packages.default = mango;
          overlayAttrs = {
            inherit (config.packages) mango;
          };
          packages = {
            inherit mango;
            hm-options-json = pkgs.callPackage (import ./nix/generate-options.nix self) {
              module = ./nix/hm-modules.nix;
              optionPrefix = "wayland.windowManager.mango.";
            };
            nixos-options-json = pkgs.callPackage (import ./nix/generate-options.nix self) {
              module = ./nix/nixos-modules.nix;
              optionPrefix = "programs.mango.";
            };
          };
          devShells.default = pkgs.mkShell {
            # Reuse the package's nativeBuildInputs/buildInputs (meson, ninja,
            # pkg-config, wayland-scanner, wlroots, scenefx, ...) so the shell
            # stays in sync with the build derivation.
            inputsFrom = [ mango ];

            packages = with pkgs; [
              clang
              clang-tools
              ccache
              gdb
              git
              meson
              ninja
            ];

            shellHook = ''
              echo "mango dev shell"
              echo "  meson setup build && meson compile -C build"
              echo "  ./format.sh  # clang-format"
            '';
          };
          formatter = pkgs.nixfmt;
        };
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
    };
}
