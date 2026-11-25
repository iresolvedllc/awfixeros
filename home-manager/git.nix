{ config, lib, pkgs, ... }:

let
  onePasswordAgent = "${config.home.homeDirectory}/.1password/agent.sock";

  # Public halves of the 1Password SSH keys. Private keys stay in the agent.
  # Change `activeAccount` and rebuild (`hm-act` / `nrs`) to hot-swap GitHub login + signing together.
  accounts = {
    awfixer = {
      name = "awfixer";
      email = "github@awfixer.me";
      # 1Password item "github" — SSH login
      loginKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFy/OIaYvM76NowPoD9tfRNjEybQQEhsR1s6RUS85zNu";
      # 1Password item "git-signing" — ssh-sign
      signingKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHgScIZg527PNvtCt84Zf0AlFTgJ6A08BE3X7wwvPJIR";
    };
    solved = {
      name = "solvedgg";
      email = "contact@solved.gg";
      # 1Password item "GitHub Auth Solved" — SSH login
      loginKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFWLAU/ynapAk9ggusoq1GwyEIezpK69ZQ33QBgqDX9z";
      # 1Password item "GitHub Signing Solved" — ssh-sign
      signingKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFVNrftO0yMosEXTrDmEamuBMhCwFr9j1N9YnD3cg9PA";
    };
  };

  activeAccount = "solved";
  acct = accounts.${activeAccount};

  loginPubs = lib.mapAttrs (
    name: a: pkgs.writeText "github-${name}-login.pub" "${a.loginKey} github-${name}\n"
  ) accounts;
  loginPub = loginPubs.${activeAccount};

  githubHost = pub: {
    HostName = "github.com";
    User = "git";
    IdentityAgent = onePasswordAgent;
    IdentitiesOnly = "yes";
    IdentityFile = toString pub;
  };
in
{
  programs.git = {
    enable = true;
    package = pkgs.git;
    settings = {
      user.name = acct.name;
      user.email = acct.email;
      core.sshCommand = "${pkgs.openssh}/bin/ssh -o IdentityAgent=${onePasswordAgent}";

      # Leave line endings alone. core.filemode stays at the Linux default
      # (true): setting it false hides executable-bit changes from git status.
      core.autocrlf = "false";

      # Depot Code credential helper (lives in the theautist checkout).
      # Password comes from DEPOT_TOKEN env or the repo's .env.
      credential."https://zq45253sg7.code.depot.dev".helper =
        "/home/awfixer/Projects/theautist/scripts/git-credential-depot";
      credential."https://zq45253sg7.code.depot.dev".username = "x-token";

      # OmniDiff replaces git's internal diff for `git diff`, `git log -p`,
      # and `git show`. Text mode when stdout is a pipe (git's pager).
      # `git diff --no-ext-diff` is the builtin. `git difftool` is the TUI.
      diff.external = lib.getExe pkgs.omnidiff;
      diff.tool = "omnidiff";
      difftool.prompt = false;
      difftool.omnidiff.cmd = "${lib.getExe pkgs.omnidiff} \"\$LOCAL\" \"\$REMOTE\"";
    };
    signing = {
      format = "ssh";
      key = acct.signingKey;
      signer = "${lib.getExe' pkgs._1password-gui "op-ssh-sign"}";
      signByDefault = true;
    };
  };

  # github.com follows `activeAccount`. Aliases keep a specific login even if the default flips:
  #   git@github.com-awfixer:org/repo.git
  #   git@github.com-solved:org/repo.git
  home.packages = [ pkgs.omnidiff ];

  programs.ssh.settings = {
    "github.com" = githubHost loginPub;
    "github.com-awfixer" = githubHost loginPubs.awfixer;
    "github.com-solved" = githubHost loginPubs.solved;
  };
}
