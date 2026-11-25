{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  alsa-lib,
  dbus,
  libglvnd,
  libpulseaudio,
  libx11,
  libxcb,
  libxcursor,
  libxi,
  libxkbcommon,
  libxrandr,
  pipewire,
  wayland,
}:

stdenv.mkDerivation rec {
  pname = "spotifast";
  version = "0.17.2";

  # https://github.com/crmne/spotifast/releases/tag/v0.17.2
  src = fetchurl {
    url = "https://github.com/crmne/spotifast/releases/download/v${version}/spotifast-v${version}-x86_64-unknown-linux-gnu.tar.gz";
    hash = "sha256-ikQ5R451WdcC75A/MqunS+Bj7J9bNa2K/8rhNGu0+tQ=";
  };

  sourceRoot = "spotifast-v${version}-x86_64-unknown-linux-gnu";

  nativeBuildInputs = [ autoPatchelfHook ];

  buildInputs = [
    alsa-lib
    libpulseaudio
    pipewire
    stdenv.cc.cc
  ];

  # egui/winit/glutin dlopen these (not in DT_NEEDED).
  runtimeDependencies = [
    dbus
    libglvnd
    libx11
    libxcb
    libxcursor
    libxi
    libxkbcommon
    libxrandr
    wayland
  ];

  dontConfigure = true;
  dontBuild = true;
  # Vendor Rust binary; stripping has broken similar prebuilts.
  dontStrip = true;

  installPhase = ''
    runHook preInstall

    install -Dm755 spotifast $out/bin/spotifast
    install -Dm644 packaging/applications/spotifast.desktop \
      $out/share/applications/spotifast.desktop
    install -Dm644 packaging/icons/spotifast.svg \
      $out/share/icons/hicolor/scalable/apps/spotifast.svg

    substituteInPlace $out/share/applications/spotifast.desktop \
      --replace-fail 'Exec=spotifast' "Exec=$out/bin/spotifast"

    runHook postInstall
  '';

  meta = {
    description = "Native Spotify client (egui + librespot)";
    homepage = "https://spotifast.rocks/";
    downloadPage = "https://github.com/crmne/spotifast/releases/tag/v${version}";
    changelog = "https://github.com/crmne/spotifast/releases/tag/v${version}";
    license = lib.licenses.mit;
    platforms = [ "x86_64-linux" ];
    mainProgram = "spotifast";
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
  };
}
