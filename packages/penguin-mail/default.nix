{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  makeWrapper,
  wrapGAppsHook4,
  bubblewrap,
  cairo,
  gdk-pixbuf,
  glib,
  glib-networking,
  gnupg,
  graphene,
  gsettings-desktop-schemas,
  gtk4,
  hunspellDicts,
  libadwaita,
  librsvg,
  pango,
  webkitgtk_6_0,
}:

stdenv.mkDerivation rec {
  pname = "penguin-mail";
  version = "1.0.12";

  # https://github.com/c9dev/penguin-mail/releases/tag/v1.0.12
  # Needs GTK 4, libadwaita >= 1.8, WebKitGTK 6.0 (upstream README).
  src = fetchurl {
    url = "https://github.com/c9dev/penguin-mail/releases/download/v${version}/penguin-mail-${version}-x86_64.tar.gz";
    hash = "sha256-9DlaZXlGLbybmFf8lOqVc/QHx75m6il6P4JNR6lEyek=";
  };

  sourceRoot = "penguin-mail-${version}-x86_64";

  nativeBuildInputs = [
    autoPatchelfHook
    makeWrapper
    wrapGAppsHook4
  ];

  buildInputs = [
    cairo
    gdk-pixbuf
    glib
    glib-networking
    graphene
    gsettings-desktop-schemas
    gtk4
    libadwaita
    librsvg
    pango
    stdenv.cc.cc
    webkitgtk_6_0
  ];

  dontConfigure = true;
  dontBuild = true;
  dontStrip = true;
  # Wrap only the GUI; the CLI is a plain Rust binary.
  dontWrapGApps = true;

  installPhase = ''
    runHook preInstall

    install -Dm755 bin/penguin-mail $out/bin/penguin-mail
    install -Dm755 bin/penguin-mail-cli $out/bin/penguin-mail-cli
    mkdir -p $out/share
    cp -a share/. $out/share/

    substituteInPlace $out/share/applications/io.github.c9dev.PenguinMail.desktop \
      --replace-fail 'Exec=penguin-mail' "Exec=$out/bin/penguin-mail"

    runHook postInstall
  '';

  # gappsWrapperArgs is filled by wrapGAppsHook's preFixupPhases hook.
  # WebKit's bwrap/xdg-dbus-proxy paths are baked into nixpkgs webkitgtk.
  # Skill scripts and OpenPGP look up bubblewrap / gpg / gpgsm on PATH.
  # Spellcheck reads hunspell dicts from DICPATH (no /usr/share/hunspell on NixOS).
  preFixup = ''
    wrapProgram $out/bin/penguin-mail \
      "''${gappsWrapperArgs[@]}" \
      --prefix PATH : ${
        lib.makeBinPath [
          bubblewrap
          gnupg
        ]
      } \
      --prefix DICPATH : ${
        lib.makeSearchPath "share/hunspell" [
          hunspellDicts.en_US
          hunspellDicts.en_GB-ise
          hunspellDicts.pt_PT
        ]
      }
  '';

  meta = {
    description = "Mail and calendar for Linux (Gmail, Outlook, IMAP/POP3, CalDAV)";
    homepage = "https://github.com/c9dev/penguin-mail";
    downloadPage = "https://github.com/c9dev/penguin-mail/releases/tag/v${version}";
    changelog = "https://github.com/c9dev/penguin-mail/releases/tag/v${version}";
    license = lib.licenses.gpl3Plus;
    platforms = [ "x86_64-linux" ];
    mainProgram = "penguin-mail";
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
  };
}
