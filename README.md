# awfixeros

Single-flake NixOS configuration ("the monolith") for one x86_64-linux laptop: OS modules, Home Manager setup, vendored package builds, encrypted secrets, and Grok plugins all live in this repository.

## Rebuild

```sh
git -C ~/awfixeros pull
sudo nixos-rebuild switch --flake ~/awfixeros#laptop
```

`.#nixos` is an alias of the same config kept for older muscle memory. The machine's hostname is `nixos`.

## Update pins

```sh
scripts/update-pins.py
```

The script finds every `packages/<name>/default.nix` and every `flake.nix`. It moves GitHub release, npm, redirect, `latest.json`, and apt-index pins to the newest matching release, refreshes hashes, then builds those packages and each NixOS configuration. Adding a package or a flake input does not require editing the script.

An apt pin is a comment `# update: apt <Packages URL>` above `version`. The index stanza is `Package: 1password` unless the comment adds a second word (`# update: apt <url> <package>`). A `~` in the Debian version is written as `-` so it matches the upstream tarball name. `packages/1password` tracks the Linux beta channel this way, including the bundled `1password-mcp`.

A pin stays where it is when a comment above it says `# update: skip`, when a flake URL contains a 40-character commit, or when the input tracks a branch. Branch inputs such as `nixpkgs` move only with `scripts/update-pins.py --inputs`. `mangowm` is marked skip because the compositor in use is the local patch in `packages/mango`.

`scripts/update-pins.py --check` prints the plan and does not write or build.

## Repository layout

| Path | Contents |
| --- | --- |
| [`flake.nix`](flake.nix) | Flake entry point: inputs, exported packages, dev shell, `nixosConfigurations.laptop` |
| [`hosts/laptop/`](hosts/laptop/) | Machine-specific config: hardware, memory/zram/swap, kernel, thermal |
| [`modules/`](modules/) | NixOS modules, imported via `modules/default.nix` |
| [`home-manager/`](home-manager/) | Per-user Home Manager modules for user `awfixer` |
| [`packages/`](packages/) | Vendored derivations built via `callPackage`. The Mango compositor in `packages/mango` is a local patch and is not bumped with upstream |
| [`secrets/secrets.yaml`](secrets/secrets.yaml) | sops-nix encrypted secrets |
| [`ai/`](ai/) | Grok plugin bundles, symlinked into `~/.grok/plugins/<name>` by Home Manager |
| [`docs/superpowers/`](docs/superpowers/) | Design docs, plans, and findings (mostly helium-devtools work) |

## Flake inputs

- **nixpkgs** — `nixos-unstable`, with `allowUnfree`
- **home-manager**, **sops-nix** — follow nixpkgs
- **nix-flatpak** — `v0.8.0` (Cohesion on Flathub, Orion GTK beta on its own remote)
- **open-design** — pinned commit. Upstream removed `flake.nix`, so this input is not floating. It still exports the daemon and static web packages
- **mangowm** — NixOS and Home Manager modules. The running compositor is the local fork in `packages/mango`, not this input's package

## System modules (`modules/`)

`environment.nix` is boot, locale, network, and daily packages. `programming.nix` is language toolchains. `hacking.nix` is scanners and packet tools. `privacy.nix` installs Tor Browser, Mullvad Browser, tor, torsocks, and Mullvad VPN with their daemons left off. `security.nix` is host hardening: AppArmor, auditd, USBGuard, fwupd, sudo, and kernel sysctls. The firewall drops inbound traffic and opens no ports. Those package modules are imported, so the tools stay on the system.

Also imported: Mango, Flatpak, firewall, systemd tweaks, 1Password, Chromium, Nix LD, users, services, and sops-nix secrets.

## Home Manager (`home-manager/`)

User-level apps and settings: Mango, Ghostty, Helium, Cursor, T3 Code, Kraken Desktop, Gloomberb, OpenWork, Freebuff, Spotifast, Penguin Mail, Grok Bot, git/ssh, zsh, direnv, Bun, keyring, screenshots, plus XDG mime defaults (Helium for web links, OnlyOffice for MS Office formats).

## Exported packages

Build any of these without switching the whole system:

```sh
nix build .#kraken-desktop
```

| Output | What it is |
| --- | --- |
| `helium-browser` | Helium browser |
| `helium-devtools` | Python MCP server for debugging Helium (`packages/helium-devtools`, pytest suite included) |
| `gloomberb` | [Gloomberb](https://github.com/gloom-sh/gloomberb) binary wrapper |
| `openwork` | OpenWork desktop client (Electron) |
| `kraken-desktop` | Kraken Desktop |
| `freebuff-desktop` | Freebuff Desktop |
| `spotifast` | Spotifast native Spotify client |
| `penguin-mail` | Penguin Mail (GTK4 / WebKitGTK) |
| `vela-cli` | Vela CLI |
| `t3-code` | T3 Code editor |
| `grok-bot` | Grok Bot |
| `omnidiff` | Content-aware diff, used as `git diff` |
| `onepassword-beta` | 1Password Linux beta, including `1password-mcp` |
| `open-design-daemon` / `open-design-web` | From the pinned open-design flake input |
| `playwright-test`, `playwright-browsers`, `playwright-driver`, `prisma`, `prisma-engines` | System Playwright/Prisma binaries reused outside the OS config |

### Dev shell

```sh
nix develop ~/awfixeros
```

Provides Node.js, Playwright, Prisma engines, and PHP with Composer, and exports `PLAYWRIGHT_BROWSERS_PATH` / `PRISMA_SCHEMA_ENGINE_BINARY` so project-local npm/Bun installs use the system binaries instead of downloading their own.

## Secrets

Secrets are managed with [sops-nix](https://github.com/Mic92/sops-nix) using an age key:

- `~/.config/sops/age/keys.txt` — used by the `sops` CLI when editing
- `sops.age.keyFile` in `modules/sops.nix` — used by NixOS activation to decrypt

Edit with `sops secrets/secrets.yaml`. The age private key should be backed up in 1Password.

## Desktop

Mango is the Wayland session (`modules/mango.nix`, SDDM greeter). The compositor package is the local fork in `packages/mango`.
