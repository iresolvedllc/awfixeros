#!/usr/bin/env python3
"""Rewrite FHS bash shebangs so NixOS can exec the file.

NixOS links /bin/sh and /usr/bin/env. It does not provide /bin/bash.
A direct exec of a #!/bin/bash script fails:

    bad interpreter: No such file or directory

and the hook runner reports that as exit 126. #!/usr/bin/env bash works
here because /usr/bin/env exists and bash is on PATH.

Only the first line is changed, and only when it is exactly one of the
known-bad shebangs. Symlinks are left alone so store-backed plugins are
not rewritten into /nix/store.
"""

from __future__ import annotations

import os
import sys

REPLACEMENTS = {
    b"#!/bin/bash": b"#!/usr/bin/env bash",
    b"#!/usr/bin/bash": b"#!/usr/bin/env bash",
}
SKIP_DIRS = {
    ".git",
    "__pycache__",
    "logs",
    "memory-v2",
    "memtrace",
    "node_modules",
    "sessions",
}


def rewrite(path: str) -> bool:
    if os.path.islink(path) or not os.path.isfile(path):
        return False
    try:
        with open(path, "rb") as handle:
            first = handle.read(200)
    except OSError as exc:
        print(f"skip {path}: {exc}", file=sys.stderr)
        return False
    if not first.startswith(b"#!"):
        return False
    line, sep, _rest = first.partition(b"\n")
    cr = b"\r" if line.endswith(b"\r") else b""
    body = line[:-1] if cr else line
    replacement = REPLACEMENTS.get(body)
    if replacement is None:
        return False
    if not os.access(path, os.W_OK):
        print(f"skip read-only {path}", file=sys.stderr)
        return False
    old_prefix = body + cr + sep
    new_prefix = replacement + cr + sep
    with open(path, "rb") as handle:
        data = handle.read()
    if not data.startswith(old_prefix):
        return False
    with open(path, "wb") as handle:
        handle.write(new_prefix)
        handle.write(data[len(old_prefix) :])
    print(path)
    return True


def main(roots: list[str]) -> int:
    changed = 0
    for root in roots:
        if not os.path.isdir(root):
            continue
        for dirpath, dirs, files in os.walk(root):
            dirs[:] = [name for name in dirs if name not in SKIP_DIRS]
            for name in files:
                if rewrite(os.path.join(dirpath, name)):
                    changed += 1
    print(f"rewrote {changed} shebang(s)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(f"usage: {sys.argv[0]} DIR [DIR...]", file=sys.stderr)
        sys.exit(2)
    sys.exit(main(sys.argv[1:]))
