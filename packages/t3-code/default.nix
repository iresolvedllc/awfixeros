{
  lib,
  stdenv,
  fetchurl,
  appimageTools,
  makeWrapper,
  wrapGAppsHook3,
  # Linked dynamic libraries (same class of deps as vscode/helium).
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
  addDriverRunpath,
}:

let
  pname = "t3-code";
  # Nightly channel. scripts/update-pins.py refreshes this pin.
  version = "0.1.13-nightly.20261125.5258";

  src = fetchurl {
    url = "https://github.com/pingdotgg/t3code/releases/download/v${version}/T3-Code-Nightly-x86_64.AppImage";
    hash = "sha256-ScVxQGUbI29gHovDNYqmXPjbRE9nCzjhnm/KNuCnvKA=";
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
stdenv.mkDerivation rec {
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
    cp -a ${appimageContents}/. $out/share/t3-code/
    chmod -R u+w $out/share/t3-code
    rm -rf $out/share/t3-code/{AppRun,.DirIcon,chrome-sandbox,t3code.desktop,t3code.png,usr}

    # Desktop entry from the AppImage. electron-builder writes
    # Exec=AppRun --no-sandbox %U (older builds omit --no-sandbox) and a
    # channel-specific Name= ("T3 Code (Alpha)" or "T3 Code (Nightly)").
    desktop=${appimageContents}/t3code.desktop
    if ! grep -Eq '^Exec=AppRun( --no-sandbox)? %U$' "$desktop"; then
      echo "t3code.desktop Exec line is not AppRun [--no-sandbox] %U:" >&2
      grep '^Exec=' "$desktop" >&2 || true
      exit 1
    fi
    name=$(sed -n 's/^Name=//p' "$desktop" | head -n 1)
    if [ -z "$name" ]; then
      echo "t3code.desktop is missing Name=" >&2
      exit 1
    fi

    mkdir -p $out/share/applications
    # Main launcher does not own the URI scheme; the handler entry does.
    sed -E \
      -e 's|^Exec=AppRun( --no-sandbox)? %U$|Exec=t3code %F|' \
      -e '/^MimeType=/d' \
      "$desktop" > $out/share/applications/t3code.desktop

    # URI-handler entry: browser OAuth callbacks open t3code:// URLs, which
    # must be routed back into the running app via --open-url.
    sed -E \
      -e 's|^Exec=AppRun( --no-sandbox)? %U$|Exec=t3code --open-url %U|' \
      -e "s|^Name=.*|Name=$name URL Handler|" \
      "$desktop" > $out/share/applications/t3code-url-handler.desktop
    echo "NoDisplay=true" >> $out/share/applications/t3code-url-handler.desktop

    # Icons
    if [ -f ${appimageContents}/t3code.png ]; then
      install -Dm644 ${appimageContents}/t3code.png \
        $out/share/icons/hicolor/512x512/apps/t3code.png
    fi
    if [ -d ${appimageContents}/usr/share/icons ]; then
      cp -a ${appimageContents}/usr/share/icons $out/share/
    fi

    # Interpreter + RPATH so we do NOT need bubblewrap/FHS.
    # chrome-sandbox is dropped above so electron falls back to the
    # user-namespace sandbox instead of aborting on a non-setuid helper.
    # Nightlies add native helpers under resources/ (browser-secret, capture).
    patch_elf() {
      elf="$1"
      if [ -f "$elf" ] && [ -x "$elf" ]; then
        magic=$(od -An -t x1 -N 4 "$elf" | tr -d ' ')
        if [ "$magic" = "7f454c46" ]; then
          patchelf --set-interpreter "$(cat $NIX_CC/nix-support/dynamic-linker)" "$elf" || true
          patchelf --set-rpath "$out/share/t3-code:${rpath}" "$elf" || true
        fi
      fi
    }
    patch_elf $out/share/t3-code/t3code
    patch_elf $out/share/t3-code/chrome_crashpad_handler
    find $out/share/t3-code/resources -type f -executable -print0 |
      while IFS= read -r -d ''' elf; do
        patch_elf "$elf"
      done
    for so in $out/share/t3-code/lib*.so*; do
      if [ -f "$so" ]; then
        patchelf --set-rpath "$out/share/t3-code:${rpath}" "$so" || true
      fi
    done
    # Native node modules (node-pty, ffi-rs, msgpackr-extract, ...)
    find $out/share/t3-code/resources/app.asar.unpacked -type f -name '*.node' \
      -exec patchelf --set-rpath "$out/share/t3-code:${rpath}" {} \; || true

    # Replace bundled vulkan loader with nixpkgs one when present.
    if [ -e $out/share/t3-code/libvulkan.so.1 ]; then
      rm -f $out/share/t3-code/libvulkan.so.1
      ln -s ${lib.getLib vulkan-loader}/lib/libvulkan.so.1 $out/share/t3-code/libvulkan.so.1
    fi

    # NOTE: no ozone flags here - ELECTRON_OZONE_PLATFORM_HINT=auto is set
    # system-wide; passing NIXOS_OZONE_WL conditionals via makeWrapper
    # results in a literal unexpanded string being handed to electron.
    makeWrapper $out/share/t3-code/t3code $out/bin/t3code \
      "''${gappsWrapperArgs[@]}" \
      --prefix LD_LIBRARY_PATH : "$out/share/t3-code:${rpath}" \
      --prefix PATH : "${lib.makeBinPath [ pciutils ]}"

    runHook postInstall
  '';

  meta = {
    description = "T3 Code — Theo's AI-first fork of VS Code";
    homepage = "https://github.com/pingdotgg/t3code";
    changelog = "https://github.com/pingdotgg/t3code/releases/tag/v${version}";
    license = lib.licenses.unfree;
    platforms = [ "x86_64-linux" ];
    mainProgram = "t3code";
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
  };
}
