{
  config,
  lib,
  pkgs,
  ...
}:
let
  home = config.home.homeDirectory;
in
{
  # Marketplace plugins (Railway's auto-approve-api.sh and the same pattern
  # elsewhere under ~/.grok) ship #!/bin/bash. NixOS has no /bin/bash, so the
  # kernel refuses the exec and Grok reports the hook as exit 126. Reapply
  # after each switch because `grok plugin update` checks the upstream
  # shebang back out.
  home.activation.grokFhsShebangs = lib.hm.dag.entryAfter [ "writeBoundary" "linkGeneration" ] ''
    if [ -n "''${DRY_RUN_CMD:-}" ]; then
      echo "grok-shebangs: would rewrite #!/bin/bash under ~/.grok"
    else
      ${pkgs.python3}/bin/python3 ${./grok-fix-shebangs.py} \
        ${lib.escapeShellArg "${home}/.grok"} \
        ${lib.escapeShellArg "${home}/.config/hypr/custom/scripts"}
    fi
  '';
}
