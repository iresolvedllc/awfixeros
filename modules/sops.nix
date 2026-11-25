# ---------------------------------------------------------------------------
# sops-nix — age-encrypted secrets
#
# Key layout (single-user laptop; one dedicated age key, no sshd host keys):
#   ~/.config/sops/age/keys.txt — private key. Used by `sops` CLI edits AND by
#                                 NixOS activation via sops.age.keyFile below.
#   .sops.yaml                  — encrypts to the matching public key.
#
# The private key is backed up in 1Password ("awfixeros — sops age key").
# Never commit key material: .gitignore blocks **/keys.txt and
# **/*AGE-SECRET-KEY*, and .sops.yaml only ever contains the public key.
#
# To add a secret:
#   1. add the key to secrets/secrets.yaml (`sops secrets/secrets.yaml`)
#   2. declare `sops.secrets.<name>` here (empty values are fine)
#   3. consume as: config.sops.secrets.<name>.path
#      — for services, use restartUnits so a secret change restarts the unit
# ---------------------------------------------------------------------------

{
  config,
  pkgs,
  ...
}:

{
  sops = {
    defaultSopsFile = ../secrets/secrets.yaml;
    defaultSopsFormat = "yaml";

    # Fail eval if a declared secret is missing from the sops file.
    validateSopsFiles = true;

    age = {
      keyFile = "/home/awfixer/.config/sops/age/keys.txt";
      # sshd is disabled — never try to derive keys from OpenSSH host keys.
      sshKeyPaths = [ ];
      generateKey = false;
    };

    secrets = {
      # Keep while the placeholder key exists in secrets/secrets.yaml.
      placeholder = { };

      # Declared so eval passes; empty until you fill the values in.
      nix-access-token-github = { };
      depot-token = { };
    };
  };

  # CLI tools for creating/editing secrets
  environment.systemPackages = with pkgs; [
    sops
    age
  ];
}
