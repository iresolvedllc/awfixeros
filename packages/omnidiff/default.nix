{
  lib,
  stdenv,
  fetchurl,
}:

stdenv.mkDerivation rec {
  pname = "omnidiff";
  version = "0.6.0";

  # Static musl build: no Nix dynamic linker to patch.
  # https://github.com/ivankovic/omnidiff/releases/tag/v0.6.0
  src = fetchurl {
    url = "https://github.com/ivankovic/omnidiff/releases/download/v${version}/omnidiff-x86_64-unknown-linux-musl.tar.gz";
    hash = "sha256-84KSYOSjvjjFzdJkIag84Jm7JyPuie/EuuoiEkJD4n0=";
  };

  completions = fetchurl {
    url = "https://github.com/ivankovic/omnidiff/releases/download/v${version}/omnidiff-completions-and-man.tar.gz";
    hash = "sha256-7iyU+/bfx+vD5xhpA/z/+WR3NheVCA7WgDcg0jPFi+U=";
  };

  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;
  dontStrip = true;

  installPhase = ''
    runHook preInstall

    tar -xzf $src -C .
    install -Dm755 omnidiff $out/bin/omnidiff

    tar -xzf $completions -C .
    install -Dm644 completions/_omnidiff $out/share/zsh/site-functions/_omnidiff
    install -Dm644 completions/omnidiff.bash $out/share/bash-completion/completions/omnidiff
    install -Dm644 completions/omnidiff.fish $out/share/fish/vendor_completions.d/omnidiff.fish
    install -Dm644 omnidiff.1 $out/share/man/man1/omnidiff.1

    runHook postInstall
  '';

  meta = {
    description = "Content-aware diff for code, images, fonts, archives, and PDFs";
    homepage = "https://github.com/ivankovic/omnidiff";
    changelog = "https://github.com/ivankovic/omnidiff/releases/tag/v${version}";
    license = lib.licenses.agpl3Only;
    platforms = [ "x86_64-linux" ];
    mainProgram = "omnidiff";
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
  };
}
