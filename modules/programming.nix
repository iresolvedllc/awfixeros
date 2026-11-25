{ pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    go
    gotools
    gox
    gow
    libcap
    kotlin
    gradle
    openjdk
    android-tools
    protobuf
    protocol
    pkg-config
    openssl
    opentofu
    just
    llvmPackages.libclang
    php
    php85Packages.composer
    gleam
    erlang-language-platform
    beam29Packages.elixir
    beam29Packages.erlang
    gcc
    gnumake
    rustup
    python3
    nodejs
    uv
    watchman
  ];
}
