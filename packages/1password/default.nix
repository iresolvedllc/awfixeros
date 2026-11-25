{
  fetchurl,
  _1password-gui,
  polkitPolicyOwners ? [ ],
}:

let
  # Linux beta channel: the desktop app and the bundled 1password-mcp.
  # scripts/update-pins.py reads the apt index named below.
  # Debian writes the build as 8.12.48~24.BETA; the tarball uses a dash.
  # update: apt https://downloads.1password.com/linux/debian/amd64/dists/beta/main/binary-amd64/Packages
  version = "8.12.48-24.BETA";

  src = fetchurl {
    url = "https://downloads.1password.com/linux/tar/beta/x86_64/1password-${version}.x64.tar.gz";
    hash = "sha256-wXU6tAsBxKGhCVxyoLO66eaP30HE9WibzAGdf9b3QU4=";
  };
in
# polkitPolicyOwners has to be an argument of this function. The NixOS module
# calls .override with it, and that rebuilds from here. An overrideAttrs
# applied earlier would be dropped, and the GUI would fall back to nixpkgs.
(_1password-gui.override { inherit polkitPolicyOwners; }).overrideAttrs (old: {
  inherit version src;

  meta = (old.meta or { }) // {
    description = "1Password Linux beta (desktop app and 1password-mcp)";
  };

  # nixpkgs patchelfs 1password, BrowserSupport, and op-ssh-sign, not
  # 1password-mcp. Copy the interpreter and rpath from the main binary.
  # glibc sonames live next to the dynamic linker, not on the rpath, and
  # libgcc_s may be in lib/ while the nixpkgs rpath still says lib64.
  postInstall = (old.postInstall or "") + ''
    app=$out/share/1password/1password
    mcp=$out/share/1password/1password-mcp
    if [ ! -f "$app" ] || [ ! -f "$mcp" ]; then
      echo "1password beta tarball is missing 1password or 1password-mcp" >&2
      exit 1
    fi
    interp=$(patchelf --print-interpreter "$app")
    rpath=$(patchelf --print-rpath "$app")
    patchelf --set-interpreter "$interp" --set-rpath "$rpath" "$mcp"
    ln -s "$mcp" $out/bin/1password-mcp

    check_needed() {
      elf="$1"
      interp_dir=$(dirname "$(patchelf --print-interpreter "$elf")")
      elf_rpath=$(patchelf --print-rpath "$elf")
      needed=$(patchelf --print-needed "$elf")
      for soname in $needed; do
        found=0
        old_ifs=$IFS
        IFS=:
        for dir in $elf_rpath "$interp_dir" "$out/share/1password"; do
          if [ -e "$dir/$soname" ]; then
            found=1
            break
          fi
          case "$dir" in
            */lib64)
              alt="''${dir%/lib64}/lib"
              if [ -e "$alt/$soname" ]; then
                found=1
                break
              fi
              ;;
          esac
        done
        IFS=$old_ifs
        if [ "$found" -ne 1 ]; then
          echo "1password: $elf needs $soname and it is not on the rpath" >&2
          exit 1
        fi
      done
    }
    check_needed "$app"
    check_needed "$mcp"
  '';
})
