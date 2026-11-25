{
  lib,
  stdenv,
  fetchurl,
  appimageTools,
  makeWrapper,
  wrapGAppsHook3,
  # Linked dynamic libraries (same class of deps as t3-code / helium).
  alsa-lib,
  at-spi2-atk,
  at-spi2-core,
  atk,
  cairo,
  cups,
  dbus,
  expat,
  fontconfig,
  freetype,
  gdk-pixbuf,
  glib,
  gtk3,
  libdrm,
  libx11,
  libxcb,
  libxcomposite,
  libxdamage,
  libxext,
  libxfixes,
  libxkbcommon,
  libxrandr,
  libgbm,
  nspr,
  nss,
  pango,
  systemd,
  libGL,
  vulkan-loader,
  wayland,
  pciutils,
}:

let
  pname = "freebuff-desktop";
  # Desktop channel. The whole line is tagged pre-release upstream.
  version = "0.0.205";

  src = fetchurl {
    url = "https://github.com/CodebuffAI/codebuff-community/releases/download/freebuff-desktop-v${version}/Freebuff-${version}-linux-x86_64.AppImage";
    hash = "sha256-HfbTF3z7jjr+kJL6t8IEVxU16TxCLhxu1vNaANqOWBU=";
  };

  appimageContents = appimageTools.extract { inherit pname version src; };

  rpath = lib.makeLibraryPath [
    stdenv.cc.cc.lib
    alsa-lib
    at-spi2-atk
    at-spi2-core
    atk
    cairo
    cups
    dbus
    expat
    fontconfig
    freetype
    gdk-pixbuf
    glib
    gtk3
    libdrm
    libx11
    libxcb
    libxcomposite
    libxdamage
    libxext
    libxfixes
    libxkbcommon
    libxrandr
    libgbm
    nspr
    nss
    pango
    systemd
    libGL
    vulkan-loader
    wayland
    pciutils
  ];
in
stdenv.mkDerivation {
  inherit pname version;

  src = appimageContents;

  dontConfigure = true;
  dontBuild = true;

  nativeBuildInputs = [
    makeWrapper
    wrapGAppsHook3
  ];

  # Avoid wrapping the many helper binaries; we only wrap the launcher.
  dontWrapGApps = true;

  installPhase = ''
    runHook preInstall

    mkdir -p $out/{bin,share}
    cp -a ${appimageContents}/. $out/share/freebuff/
    chmod -R u+w $out/share/freebuff
    rm -rf $out/share/freebuff/{AppRun,.DirIcon,chrome-sandbox,freebuff.desktop,freebuff.png,usr}

    # electron-builder writes:
    #   Exec=AppRun --no-sandbox --ozone-platform-hint=auto %U
    desktop=${appimageContents}/freebuff.desktop
    if ! grep -Eq '^Exec=AppRun --no-sandbox --ozone-platform-hint=auto %U$' "$desktop"; then
      echo "freebuff desktop Exec line changed:" >&2
      grep '^Exec=' "$desktop" >&2 || true
      exit 1
    fi

    mkdir -p $out/share/applications
    sed -E \
      -e 's|^Exec=AppRun --no-sandbox --ozone-platform-hint=auto %U$|Exec=freebuff %U|' \
      "$desktop" > $out/share/applications/freebuff.desktop

    if [ -d ${appimageContents}/usr/share/icons ]; then
      cp -a ${appimageContents}/usr/share/icons $out/share/
    fi

    # Interpreter + RPATH so we do NOT need bubblewrap/FHS.
    # chrome-sandbox is dropped above so electron falls back instead of
    # aborting on a non-setuid helper. --no-sandbox is passed by the wrapper.
    patch_elf() {
      elf="$1"
      if [ -f "$elf" ] && [ -x "$elf" ]; then
        magic=$(od -An -t x1 -N 4 "$elf" | tr -d ' ')
        if [ "$magic" = "7f454c46" ]; then
          if patchelf --print-interpreter "$elf" >/dev/null 2>&1; then
            patchelf --set-interpreter "$(cat $NIX_CC/nix-support/dynamic-linker)" "$elf"
          fi
          patchelf --set-rpath "$out/share/freebuff:${rpath}" "$elf" || true
        fi
      fi
    }
    patch_elf $out/share/freebuff/freebuff
    patch_elf $out/share/freebuff/chrome_crashpad_handler
    for so in $out/share/freebuff/lib*.so*; do
      if [ -f "$so" ]; then
        patchelf --set-rpath "$out/share/freebuff:${rpath}" "$so" || true
      fi
    done

    # Bundled bun is a standalone ELF. Setting rpath moves non-alloc
    # sections and drops the embedded payload, so only the interpreter changes.
    bun=$out/share/freebuff/resources/bun/bun
    if [ -f "$bun" ]; then
      patchelf --set-interpreter "$(cat $NIX_CC/nix-support/dynamic-linker)" "$bun"
    fi

    # Replace bundled vulkan loader with nixpkgs one when present.
    if [ -e $out/share/freebuff/libvulkan.so.1 ]; then
      rm -f $out/share/freebuff/libvulkan.so.1
      ln -s ${lib.getLib vulkan-loader}/lib/libvulkan.so.1 $out/share/freebuff/libvulkan.so.1
    fi

    # Literal flags only. makeWrapper must not see NIXOS_OZONE_WL shell
    # expansion; that string is handed to electron as argv.
    makeWrapper $out/share/freebuff/freebuff $out/bin/freebuff \
      "''${gappsWrapperArgs[@]}" \
      --prefix LD_LIBRARY_PATH : "$out/share/freebuff:${rpath}" \
      --prefix PATH : "${lib.makeBinPath [ pciutils ]}" \
      --add-flags "--no-sandbox" \
      --add-flags "--ozone-platform-hint=auto" \
      --add-flags "--enable-features=WaylandWindowDecorations" \
      --add-flags "--enable-wayland-ime=true"

    runHook postInstall
  '';

  meta = {
    description = "Freebuff desktop client";
    homepage = "https://freebuff.com";
    license = lib.licenses.unfree;
    platforms = [ "x86_64-linux" ];
    mainProgram = "freebuff";
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
  };
}
