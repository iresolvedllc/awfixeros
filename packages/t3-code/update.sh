#!/usr/bin/env bash
# Pin packages/t3-code by running the repo-wide updater for this package.
# The full check, including the NixOS build, is:
#   scripts/update-pins.py
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/update-pins.py" --only t3-code --no-build "$@"
