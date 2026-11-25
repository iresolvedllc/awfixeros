#!/usr/bin/env python3
"""Refresh every pinned package and flake input, then build them.

Discovery, not a package list:

- every packages/<name>/default.nix and packages/<name>/nix/default.nix
- every flake.nix in the repo

A new package is picked up when its default.nix fetches a GitHub release,
an npm tarball, a redirect URL, a latest.json named in a comment, or an apt
index named in a comment (`# update: apt <Packages URL>`). The apt stanza
defaults to Package: 1password; a second word selects another stanza
(`# update: apt <url> <package>`). Debian '~' in the version is written as
'-' so it matches the upstream tarball name. A new flake input is picked up
from flake.nix. Nothing in this script names a derivation.

Pins that stay put:

- `# update: skip` in the comment block above a version or flake input
- `# update: skip` in the first 20 lines of a flake.nix (skips that whole flake)
- a flake URL that already pins a 40-character commit
- a flake input that is only a branch, unless you pass --inputs

Branch inputs are nixpkgs, home-manager, sops-nix, and anything else whose
URL has no version tag. --inputs runs `nix flake update` on those.
"""

from __future__ import annotations

import argparse
import base64
import gzip
import json
import re
import subprocess
import sys
import urllib.request
from pathlib import Path

FAKE_HASH = "sha256-" + ("A" * 43) + "="
VERSION_ASSIGN = re.compile(r'^([ \t]*)version = "([^"]+)";\s*$', re.M)
COMMIT_ASSIGN = re.compile(r'^([ \t]*)commit = "([^"]+)";\s*$', re.M)
HASH_ASSIGN = re.compile(r'^([ \t]*)(hash|npmDepsHash) = "(sha256-[^"]+)";\s*$', re.M)
URL_ASSIGN = re.compile(r'url = "([^"]+)";')
TAG_ASSIGN = re.compile(r'tag = "([^"]+)";')
OWNER_ASSIGN = re.compile(r'owner = "([^"]+)";')
REPO_ASSIGN = re.compile(r'repo = "([^"]+)";')
PNAME_ASSIGN = re.compile(r'^([ \t]*)pname = "([^"]+)";\s*$', re.M)
FETCH_START = re.compile(r"\b(fetchurl|fetchzip|fetchFromGitHub)\b")
GITHUB_URL = re.compile(
    r"https://github\.com/([^/]+)/([^/]+)/releases/download/([^\"']+)"
)
NPM_URL = re.compile(
    r"https://registry\.npmjs\.org/(.+)/-/[^/]+-\$\{version\}\.tgz"
)
DIRECTIVE = re.compile(r"update:\s*(\S+)(?:\s+(\S+))?")
SKIP_DIRS = {".git", "node_modules", "target", "result", "__pycache__"}


def version_key(value: str) -> tuple:
    parts = re.findall(r"\d+|[A-Za-z]+", value)
    key = []
    for part in parts:
        if part.isdigit():
            key.append((0, int(part)))
        else:
            key.append((1, part.lower()))
    return tuple(key)


def candidate_versions(tag: str) -> list[str]:
    found = [tag]
    if tag.startswith("v"):
        found.append(tag[1:])
    match = re.search(r"v(\d+\.\d+[0-9A-Za-z.\-]*)", tag)
    if match:
        found.append(match.group(1))
    unique = []
    for item in found:
        if item not in unique:
            unique.append(item)
    return unique


def render(template: str, version: str, pname: str | None, commit: str | None) -> str:
    text = template.replace("${version}", version)
    if pname is not None:
        text = text.replace("${pname}", pname)
    if commit is not None:
        text = text.replace("${commit}", commit)
    return text


def comment_block_before(lines: list[str], index: int) -> str:
    comments = []
    cursor = index - 1
    while cursor >= 0:
        stripped = lines[cursor].strip()
        if stripped == "":
            if comments:
                break
            cursor -= 1
            continue
        if stripped.startswith("#"):
            comments.append(stripped)
            cursor -= 1
            continue
        break
    return "\n".join(reversed(comments))


def has_skip(text: str) -> bool:
    return bool(re.search(r"update:\s*skip\b", text))


def gh_json(path: str) -> object:
    proc = subprocess.run(
        ["gh", "api", path],
        check=False,
        capture_output=True,
        text=True,
    )
    if proc.returncode == 0 and proc.stdout.strip():
        return json.loads(proc.stdout)
    url = path if path.startswith("https://") else f"https://api.github.com/{path}"
    request = urllib.request.Request(
        url,
        headers={
            "User-Agent": "awfixeros-update",
            "Accept": "application/vnd.github+json",
        },
    )
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.load(response)


def http_json(url: str) -> object:
    request = urllib.request.Request(url, headers={"User-Agent": "awfixeros-update"})
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.load(response)


def follow_url(url: str) -> str:
    proc = subprocess.run(
        [
            "curl",
            "-fsSL",
            "--range",
            "0-0",
            "-o",
            "/dev/null",
            "-w",
            "%{url_effective}",
            url,
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    return proc.stdout.strip()


def prefetch(url: str) -> str:
    proc = subprocess.run(
        ["nix", "store", "prefetch-file", "--json", "--hash-type", "sha256", url],
        check=True,
        capture_output=True,
        text=True,
    )
    return json.loads(proc.stdout)["hash"]


def github_releases(owner: str, repo: str) -> list[dict]:
    found = []
    for page in range(1, 4):
        data = gh_json(f"repos/{owner}/{repo}/releases?per_page=100&page={page}")
        if not isinstance(data, list):
            raise RuntimeError(f"{owner}/{repo}: {data}")
        if not data:
            break
        found.extend(data)
        if len(data) < 100:
            break
    return found


def tag_prefix(template: str) -> str | None:
    match = re.search(r"/releases/download/([^/]+)/", template)
    if not match or "${version}" not in match.group(1):
        return None
    prefix = match.group(1).split("${version}", 1)[0]
    return prefix if len(prefix) >= 4 else None


def tags_with_prefix(owner: str, repo: str, prefix: str) -> list[str]:
    names = []
    for page in range(1, 6):
        try:
            data = gh_json(
                f"repos/{owner}/{repo}/git/matching-refs/tags/{prefix}?per_page=100&page={page}"
            )
        except Exception:
            break
        if not isinstance(data, list) or not data:
            break
        for item in data:
            ref = item.get("ref", "") if isinstance(item, dict) else ""
            if ref.startswith("refs/tags/"):
                names.append(ref.removeprefix("refs/tags/"))
        if len(data) < 100:
            break
    return names


def release_has_asset(owner: str, repo: str, tag: str, filename: str) -> bool:
    try:
        data = gh_json(f"repos/{owner}/{repo}/releases/tags/{tag}")
    except Exception:
        return False
    if not isinstance(data, dict):
        return False
    return any(asset.get("name") == filename for asset in data.get("assets") or [])


def resolve_github_version(
    owner: str, repo: str, template: str, pname: str | None, current: str
) -> str | None:
    releases = github_releases(owner, repo)
    found = matching_release_version(template, pname, current, releases)
    if found:
        return found
    prefix = tag_prefix(template)
    if not prefix:
        return None
    candidates = []
    for tag in tags_with_prefix(owner, repo, prefix):
        for version in candidate_versions(tag):
            rendered = render(template, version, pname, None)
            segment = re.search(r"/releases/download/([^/]+)/", rendered)
            if segment and segment.group(1) == tag and version_key(version) >= version_key(current):
                candidates.append((version_key(version), version, tag, rendered.rsplit("/", 1)[-1]))
    candidates.sort(reverse=True)
    seen = set()
    for _key, version, tag, filename in candidates:
        if version in seen:
            continue
        seen.add(version)
        if release_has_asset(owner, repo, tag, filename):
            return version
        if len(seen) >= 8:
            break
    return None


def matching_release_version(
    template: str,
    pname: str | None,
    current: str,
    releases: list[dict],
) -> str | None:
    nightly = "nightly" in current

    def consider(release: dict) -> str | None:
        if release.get("draft"):
            return None
        tag = release.get("tag_name") or ""
        if nightly and "nightly" not in tag:
            return None
        names = {asset.get("name") for asset in release.get("assets") or []}
        urls = {asset.get("browser_download_url") for asset in release.get("assets") or []}
        for version in candidate_versions(tag):
            rendered = render(template, version, pname, None)
            filename = rendered.rsplit("/", 1)[-1]
            tag_in_url = re.search(r"/releases/download/([^/]+)/", rendered)
            if tag_in_url and tag_in_url.group(1) == tag and (rendered in urls or filename in names):
                return version
        return None

    pools = []
    if nightly:
        pools.append(releases)
    else:
        pools.append([item for item in releases if not item.get("prerelease")])
        pools.append([item for item in releases if item.get("prerelease")])
    for pool in pools:
        for release in pool:
            found = consider(release)
            if found:
                return found
    return None


def latest_semver_tag(owner: str, repo: str) -> str | None:
    data = gh_json(f"repos/{owner}/{repo}/tags?per_page=100")
    if not isinstance(data, list):
        raise RuntimeError(f"{owner}/{repo} tags: {data}")
    names = [
        item["name"]
        for item in data
        if isinstance(item, dict) and re.fullmatch(r"v?\d+\.\d+\.\d+", item.get("name", ""))
    ]
    if not names:
        return None
    return max(names, key=lambda name: version_key(name[1:] if name.startswith("v") else name))


def nearest_pname(lines: list[str], index: int) -> str | None:
    for cursor in range(index, -1, -1):
        match = PNAME_ASSIGN.match(lines[cursor].rstrip("\n"))
        if match:
            return match.group(2)
    return None


def package_files(root: Path) -> list[Path]:
    base = root / "packages"
    if not base.is_dir():
        return []
    found = []
    for child in sorted(path for path in base.iterdir() if path.is_dir()):
        for candidate in (child / "default.nix", child / "nix" / "default.nix"):
            if candidate.is_file():
                found.append(candidate)
    return found


def flake_files(root: Path) -> list[Path]:
    found = []
    for dirpath, dirnames, filenames in os_walk(root):
        if "flake.nix" in filenames:
            found.append(Path(dirpath) / "flake.nix")
    return found


def os_walk(root: Path):
    import os

    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [
            name
            for name in dirnames
            if name not in SKIP_DIRS and not name.startswith(".")
        ]
        yield dirpath, dirnames, filenames


def output_names(root: Path) -> dict[str, str]:
    """Map a packages/... path to the flake output that callPackage's it."""
    mapping = {}
    pattern = re.compile(
        r"^\s*([A-Za-z_][\w-]*)\s*=\s*(?:[\w.]+\.)?callPackage\s+(\./|\.\./)+(packages/\S+?)\s*\{",
        re.M,
    )
    for path in [root / "flake.nix", * (root / "modules").rglob("*.nix")]:
        if not path.is_file():
            continue
        text = path.read_text()
        for name, _prefix, rel in pattern.findall(text):
            mapping[rel.rstrip("/")] = name
    return mapping


def parse_fetchers(lines: list[str]) -> list[dict]:
    fetchers = []
    cursor = 0
    while cursor < len(lines):
        if not FETCH_START.search(lines[cursor]):
            cursor += 1
            continue
        kind = FETCH_START.search(lines[cursor]).group(1)
        block = [lines[cursor]]
        depth = lines[cursor].count("{") - lines[cursor].count("}")
        cursor += 1
        while cursor < len(lines) and depth > 0:
            block.append(lines[cursor])
            depth += lines[cursor].count("{") - lines[cursor].count("}")
            cursor += 1
        body = "".join(block)
        fetchers.append(
            {
                "kind": kind,
                "start": cursor - len(block),
                "body": body,
                "url": URL_ASSIGN.search(body).group(1) if URL_ASSIGN.search(body) else None,
                "tag": TAG_ASSIGN.search(body).group(1) if TAG_ASSIGN.search(body) else None,
                "owner": OWNER_ASSIGN.search(body).group(1) if OWNER_ASSIGN.search(body) else None,
                "repo": REPO_ASSIGN.search(body).group(1) if REPO_ASSIGN.search(body) else None,
            }
        )
    return fetchers


def version_bindings(lines: list[str]) -> list[dict]:
    bindings = []
    for index, line in enumerate(lines):
        match = VERSION_ASSIGN.match(line.rstrip("\n"))
        if not match:
            continue
        bindings.append(
            {
                "index": index,
                "indent": match.group(1),
                "version": match.group(2),
                "skip": has_skip(comment_block_before(lines, index)),
            }
        )
    return bindings


def binding_for(bindings: list[dict], line_index: int) -> dict | None:
    chosen = None
    for binding in bindings:
        if binding["index"] <= line_index:
            chosen = binding
        else:
            break
    return chosen


def file_directives(text: str) -> dict[str, str]:
    found = {}
    for kind, arg in DIRECTIVE.findall(text):
        if kind in {"redirect", "json", "apt"} and arg:
            found[kind] = arg
    return found


def http_bytes(url: str) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": "awfixeros-update"})
    with urllib.request.urlopen(request, timeout=60) as response:
        return response.read()


def read_apt_index(url: str) -> str:
    urls = [url] if url.endswith(".gz") else [url, url + ".gz"]
    last = None
    data = None
    for candidate in urls:
        try:
            data = http_bytes(candidate)
            break
        except Exception as exc:
            last = exc
            data = None
    if data is None:
        raise RuntimeError(last)
    if data[:2] == b"\x1f\x8b":
        data = gzip.decompress(data)
    return data.decode()


def apt_package_version(text: str, package: str) -> str | None:
    """Version of one Debian stanza. '~' becomes '-' to match tarball names."""
    current = None
    version = None
    for raw in text.splitlines():
        line = raw.strip()
        if line.startswith("Package:"):
            if current == package and version:
                return version
            current = line.split(":", 1)[1].strip()
            version = None
            continue
        if current != package or not line.startswith("Version:"):
            continue
        version = line.split(":", 1)[1].strip()
        if re.match(r"\d+:", version):
            version = version.split(":", 1)[1]
        version = version.replace("~", "-")
    if current == package:
        return version
    return None


def apt_stanza(text: str) -> str:
    # The package name, when present, stays on the directive line. The next
    # line is often `version = "..."`, and \\s would swallow that newline.
    match = re.search(r"update:\s+apt\s+\S+[ \t]+(\S+)", text)
    return match.group(1) if match else "1password"


def replace_quoted(text: str, old: str, new: str) -> str:
    if old == new:
        return text
    return text.replace(f'"{old}"', f'"{new}"')


def set_hash_lines(text: str, old: str, new: str, limit: int = 1) -> str:
    pattern = re.compile(rf'^([ \t]*(?:hash|npmDepsHash) = "){re.escape(old)}(";)\s*$', re.M)
    text, count = pattern.subn(rf"\g<1>{new}\2", text, count=limit)
    if count != 1:
        raise RuntimeError(f"expected to replace one hash, replaced {count}")
    return text


class Planner:
    def __init__(self, root: Path, inputs: bool):
        self.root = root
        self.inputs = inputs
        self.actions: list[str] = []
        self.errors: list[str] = []

    def note(self, message: str) -> None:
        self.actions.append(message)
        print(message)

    def fail(self, message: str) -> None:
        self.errors.append(message)
        print(f"error: {message}", file=sys.stderr)


def update_package(path: Path, planner: Planner, check: bool) -> bool:
    original = path.read_text()
    if has_skip("\n".join(original.splitlines()[:20])):
        planner.note(f"skip {path.relative_to(planner.root)} (file is marked update: skip)")
        return False
    lines = original.splitlines()
    bindings = version_bindings(lines)
    fetchers = parse_fetchers(lines)
    directives = file_directives(original)
    text = original
    changed = False
    seen_bindings: set[int] = set()

    targets = []
    for fetcher in fetchers:
        binding = binding_for(bindings, fetcher["start"])
        if binding is None:
            continue
        if binding["skip"]:
            if binding["index"] not in seen_bindings:
                planner.note(
                    f"skip {path.relative_to(planner.root)} {binding['version']}"
                )
                seen_bindings.add(binding["index"])
            continue
        template = fetcher["url"] or fetcher["tag"]
        if not template or "${version}" not in template:
            continue
        targets.append((binding, fetcher))

    for binding, fetcher in targets:
        key = binding["index"]
        if key in seen_bindings:
            continue
        seen_bindings.add(key)
        current = binding["version"]
        pname = nearest_pname(lines, binding["index"])
        desired = None
        attempted = False
        try:
            if fetcher["url"] and GITHUB_URL.match(fetcher["url"]):
                attempted = True
                match = GITHUB_URL.match(fetcher["url"])
                owner, repo = match.group(1), match.group(2)
                desired = resolve_github_version(owner, repo, fetcher["url"], pname, current)
            elif fetcher["url"] and NPM_URL.match(fetcher["url"]):
                attempted = True
                package = NPM_URL.match(fetcher["url"]).group(1)
                meta = http_json(f"https://registry.npmjs.org/{package}/latest")
                desired = meta["version"] if isinstance(meta, dict) else None
            elif fetcher["owner"] and fetcher["repo"] and fetcher["tag"]:
                attempted = True
                releases = github_releases(fetcher["owner"], fetcher["repo"])
                nightly = "nightly" in current
                ordered = releases
                if not nightly:
                    ordered = [item for item in releases if not item.get("prerelease")] + [
                        item for item in releases if item.get("prerelease")
                    ]
                for release in ordered:
                    tag = release.get("tag_name") or ""
                    if nightly and "nightly" not in tag:
                        continue
                    for version in candidate_versions(tag):
                        if render(fetcher["tag"], version, pname, None) == tag:
                            desired = version
                            break
                    if desired:
                        break
        except Exception as exc:
            planner.fail(f"{path.relative_to(planner.root)}: {exc}")
            continue
        if not attempted:
            continue
        if not desired:
            planner.fail(
                f"{path.relative_to(planner.root)}: no release matched {fetcher['url'] or fetcher['tag']}"
            )
            continue
        if version_key(desired) < version_key(current):
            planner.note(
                f"keep {path.relative_to(planner.root)} at {current} ({desired} would be a downgrade)"
            )
            continue
        if desired == current:
            planner.note(f"current {path.relative_to(planner.root)} {current}")
            continue
        planner.note(f"bump {path.relative_to(planner.root)} {current} -> {desired}")
        text = replace_quoted(text, current, desired)
        changed = True

    if "redirect" in directives or (
        "${commit}" in original and re.search(r"^\s*#\s+https://\S+", original, re.M)
    ):
        redirect = directives.get("redirect")
        if not redirect:
            redirect = re.search(r"^\s*#\s+(https://\S+)", original, re.M).group(1)
        url_match = re.search(r'url = "([^"]*\$\{commit\}[^"]*)";', original)
        version_match = VERSION_ASSIGN.search(original)
        commit_match = COMMIT_ASSIGN.search(original)
        if url_match and version_match and commit_match:
            try:
                final = follow_url(redirect)
                pattern = re.escape(url_match.group(1))
                pattern = pattern.replace(re.escape("${version}"), r"(?P<version>[^/_]+)")
                pattern = pattern.replace(re.escape("${commit}"), r"(?P<commit>[0-9a-fA-F]{7,40})")
                pattern = pattern.replace(re.escape("${pname}"), r"[^/]+")
                found = re.fullmatch(pattern, final)
                if not found:
                    planner.fail(f"{path.name}: redirect {final} did not match {url_match.group(1)}")
                else:
                    new_version = found.group("version")
                    new_commit = found.group("commit")
                    if new_version != version_match.group(2) or new_commit != commit_match.group(2):
                        planner.note(
                            f"bump {path.relative_to(planner.root)} {version_match.group(2)}@{commit_match.group(2)[:12]} -> {new_version}@{new_commit[:12]}"
                        )
                        text = replace_quoted(text, version_match.group(2), new_version)
                        text = replace_quoted(text, commit_match.group(2), new_commit)
                        changed = True
                    else:
                        planner.note(f"current {path.relative_to(planner.root)} {new_version}")
            except Exception as exc:
                planner.fail(f"{path.relative_to(planner.root)} redirect: {exc}")

    json_url = directives.get("json")
    if not json_url:
        json_comment = re.search(r"https://\S+latest\.json", original)
        if json_comment and not re.search(r"url = \"[^\"]*\$\{version\}", original):
            json_url = json_comment.group(0)
    if json_url:
        version_match = VERSION_ASSIGN.search(text)
        try:
            payload = http_json(json_url)
            remote = payload.get("version") if isinstance(payload, dict) else None
            if remote and version_match and remote != version_match.group(2):
                planner.note(
                    f"bump {path.relative_to(planner.root)} {version_match.group(2)} -> {remote}"
                )
                text = replace_quoted(text, version_match.group(2), remote)
                changed = True
            elif remote:
                planner.note(f"current {path.relative_to(planner.root)} {remote}")
        except Exception as exc:
            planner.fail(f"{path.relative_to(planner.root)} json: {exc}")

    apt_url = directives.get("apt")
    if apt_url:
        version_match = VERSION_ASSIGN.search(text)
        stanza = apt_stanza(original)
        try:
            remote = apt_package_version(read_apt_index(apt_url), stanza)
            current = version_match.group(2) if version_match else None
            if not remote or not current:
                planner.fail(
                    f"{path.relative_to(planner.root)}: apt index has no Package: {stanza}"
                )
            elif version_key(remote) < version_key(current):
                planner.note(
                    f"keep {path.relative_to(planner.root)} at {current} ({remote} would be a downgrade)"
                )
            elif remote == current:
                planner.note(f"current {path.relative_to(planner.root)} {current}")
            else:
                planner.note(f"bump {path.relative_to(planner.root)} {current} -> {remote}")
                text = replace_quoted(text, current, remote)
                changed = True
        except Exception as exc:
            planner.fail(f"{path.relative_to(planner.root)} apt: {exc}")

    if not changed and not seen_bindings and "redirect" not in directives and not json_url and not apt_url:
        planner.note(f"build-only {path.relative_to(planner.root)}")
    if not changed:
        return False
    if check:
        return True

    # Drop hashes that belong to the fetches we just retargeted. The build
    # below fills them back in, one mismatch at a time.
    refreshed = re.sub(
        r'^([ \t]*(?:hash|npmDepsHash) = ")sha256-[^"]+(";)\s*$',
        rf"\g<1>{FAKE_HASH}\2",
        text,
        flags=re.M,
    )
    # Unversioned fetchers in a file we did not retarget keep their hash.
    # A file that changed version invalidates every hash in that file; the
    # local package version at the bottom of helium-devtools has no hash.
    path.write_text(refreshed)
    return True


def repair_hashes(path: Path, installable: list[str], planner: Planner) -> None:
    for _attempt in range(8):
        text = path.read_text()
        if FAKE_HASH not in text:
            return
        proc = subprocess.run(installable, capture_output=True, text=True)
        output = proc.stderr + proc.stdout
        if proc.returncode == 0:
            return
        match = re.search(r"specified:\s+(\S+)\s+got:\s+(\S+)", output)
        if not match or match.group(1) != FAKE_HASH:
            # fetchurl hashes can be filled without a full build.
            url_match = re.search(r'url = "([^"]+)";', text)
            if url_match and "${" not in url_match.group(1) and FAKE_HASH in text:
                try:
                    digest = prefetch(url_match.group(1))
                    path.write_text(set_hash_lines(text, FAKE_HASH, digest))
                    continue
                except Exception:
                    pass
            planner.fail(f"{path.name} build failed while refreshing hashes\n{output[-2000:]}")
            return
        path.write_text(set_hash_lines(text, FAKE_HASH, match.group(2)))
        planner.note(f"hash {path.relative_to(planner.root)} {match.group(2)}")
    planner.fail(f"{path.name}: hashes still unsettled")


def prefetch_fetchurls(path: Path, planner: Planner) -> None:
    """Fill fetchurl fake hashes from the file itself. fetchzip stays for the build."""
    text = path.read_text()
    if FAKE_HASH not in text or "fetchurl" not in text:
        return
    # Walk fetchurl blocks only.
    fetchers = parse_fetchers(text.splitlines())
    for fetcher in fetchers:
        if fetcher["kind"] != "fetchurl" or not fetcher["url"] or "${" in fetcher["url"]:
            continue
        if FAKE_HASH not in fetcher["body"]:
            continue
        digest = prefetch(fetcher["url"])
        text = set_hash_lines(text, FAKE_HASH, digest)
        planner.note(f"hash {path.relative_to(planner.root)} {digest}")
    path.write_text(text)


def flake_inputs(text: str) -> list[dict]:
    inputs_at = re.search(r"\binputs\s*=\s*\{", text)
    if not inputs_at:
        return []
    start = inputs_at.end()
    depth = 1
    cursor = start
    while cursor < len(text) and depth:
        if text[cursor] == "{":
            depth += 1
        elif text[cursor] == "}":
            depth -= 1
        cursor += 1
    body = text[start : cursor - 1]
    lines = body.splitlines()
    found = []
    index = 0
    while index < len(lines):
        plain = re.match(r'^([ \t]*)([A-Za-z_][\w-]*)\.url\s*=\s*"([^"]+)";\s*$', lines[index])
        nested = re.match(r'^([ \t]*)([A-Za-z_][\w-]*)\s*=\s*\{', lines[index])
        if plain:
            found.append(
                {
                    "name": plain.group(2),
                    "url": plain.group(3),
                    "comments": comment_block_before(lines, index),
                    "span": (index, index),
                }
            )
            index += 1
            continue
        if nested and nested.group(2) != "inputs":
            depth = lines[index].count("{") - lines[index].count("}")
            end = index + 1
            block = [lines[index]]
            while end < len(lines) and depth > 0:
                block.append(lines[end])
                depth += lines[end].count("{") - lines[end].count("}")
                end += 1
            url_match = re.search(r'url\s*=\s*"([^"]+)"', "\n".join(block))
            follows = "follows" in "\n".join(block) and url_match is None
            if url_match:
                found.append(
                    {
                        "name": nested.group(2),
                        "url": url_match.group(1),
                        "comments": comment_block_before(lines, index),
                        "follows_only": follows,
                    }
                )
            index = end
            continue
        index += 1
    return found


def classify_flake_url(url: str) -> tuple[str, str, str, str | None]:
    """Return owner, repo, kind, value. kind is pin, tag, or branch."""
    match = re.match(
        r"github:([^/]+)/([^/?]+)(?:/([^?]+))?(?:/?\?ref=([^&\s]+))?",
        url,
    )
    if not match:
        return "", "", "unknown", None
    owner, repo, rev, ref = match.group(1), match.group(2), match.group(3), match.group(4)
    value = ref or rev
    if value and re.fullmatch(r"[0-9a-f]{40}", value):
        return owner, repo, "pin", value
    if value and re.fullmatch(r"v?\d+\.\d+\.\d+", value):
        return owner, repo, "tag", value
    return owner, repo, "branch", value


def update_flake(path: Path, planner: Planner, check: bool, only: list[str]) -> bool:
    original = path.read_text()
    if has_skip("\n".join(original.splitlines()[:20])):
        planner.note(f"skip {path.relative_to(planner.root)} (flake is marked update: skip)")
        return False
    text = original
    changed = False
    names_to_lock = []
    for item in flake_inputs(original):
        if only and not any(name == item["name"] or name in path.as_posix() for name in only):
            continue
        if has_skip(item["comments"]):
            planner.note(f"skip flake input {item['name']}")
            continue
        owner, repo, kind, value = classify_flake_url(item["url"])
        if kind == "unknown":
            planner.note(f"skip flake input {item['name']} ({item['url']})")
            continue
        if kind == "pin":
            planner.note(f"skip flake input {item['name']} (commit pin)")
            continue
        if kind == "branch":
            if planner.inputs:
                planner.note(f"lock flake input {item['name']} to branch {value or 'default'}")
                names_to_lock.append(item["name"])
            else:
                planner.note(f"skip flake input {item['name']} (branch; pass --inputs to move it)")
            continue
        try:
            latest = latest_semver_tag(owner, repo)
        except Exception as exc:
            planner.fail(f"{item['name']}: {exc}")
            continue
        if not latest:
            planner.fail(f"{item['name']}: no semver tags on {owner}/{repo}")
            continue
        if latest == value:
            planner.note(f"current flake input {item['name']} {value}")
            continue
        if version_key(latest.lstrip("v")) < version_key((value or "").lstrip("v")):
            planner.note(f"keep flake input {item['name']} at {value}")
            continue
        planner.note(f"bump flake input {item['name']} {value} -> {latest}")
        text = text.replace(item["url"], item["url"].replace(value, latest), 1)
        names_to_lock.append(item["name"])
        changed = True
    if changed and not check:
        path.write_text(text)
    if names_to_lock and not check and path == planner.root / "flake.nix":
        for name in names_to_lock:
            planner.note(f"nix flake update {name}")
            subprocess.run(["nix", "flake", "update", name], cwd=planner.root, check=True)
    elif names_to_lock and not check:
        rel = path.parent.relative_to(planner.root)
        for name in names_to_lock:
            planner.note(f"nix flake update {name} in {rel}")
            subprocess.run(
                ["nix", "flake", "update", "--flake", str(path.parent), name],
                cwd=planner.root,
                check=True,
            )
    return changed


def installable_for(root: Path, path: Path, outputs: dict[str, str]) -> list[str]:
    rel = path.parent.relative_to(root).as_posix()
    if rel.endswith("/nix"):
        key = rel
    else:
        key = rel
    # callPackage ./packages/foo and ./packages/foo/nix both appear.
    name = outputs.get(key) or outputs.get(key.removesuffix("/nix"))
    if name and (root / "flake.nix").read_text().find(f"./{key}") != -1 or name:
        # Prefer a flake output only when flake.nix itself calls this path.
        flake_text = (root / "flake.nix").read_text()
        if f"./{key}" in flake_text or f"../{key}" in flake_text:
            if name and re.search(rf"{name}\s*=\s*pkgs\.callPackage\s+\./{key}", flake_text):
                return ["nix", "build", "--no-link", f"{root}#{name}"]
    expr = f"""
let
  flake = builtins.getFlake "{root}";
  pkgs = import flake.inputs.nixpkgs {{
    system = "x86_64-linux";
    config.allowUnfree = true;
  }};
in pkgs.callPackage {path} {{}}
"""
    return ["nix", "build", "--no-link", "--impure", "--expr", expr]


def validate(root: Path, planner: Planner, only: list[str]) -> None:
    outputs = output_names(root)
    installables = []
    for path in package_files(root):
        if only and not any(item in path.as_posix() for item in only):
            continue
        command = installable_for(root, path, outputs)
        if command[1] == "build" and command[3].startswith(str(root)) is False and command[3].startswith("/"):
            pass
        if "--expr" in command:
            planner.note(f"build {path.relative_to(root)}")
            proc = subprocess.run(command, cwd=root)
            if proc.returncode != 0:
                planner.fail(f"build failed: {path.relative_to(root)}")
        else:
            installables.append(command[-1])
    if installables:
        planner.note("build " + " ".join(installables))
        proc = subprocess.run(["nix", "build", "--no-link", *installables], cwd=root)
        if proc.returncode != 0:
            planner.fail("flake package build failed")
    if only:
        return
    try:
        raw = subprocess.run(
            [
                "nix",
                "eval",
                "--json",
                f"{root}#nixosConfigurations",
                "--apply",
                "builtins.attrNames",
            ],
            check=True,
            capture_output=True,
            text=True,
            cwd=root,
        )
        names = json.loads(raw.stdout)
    except Exception as exc:
        planner.fail(f"could not list nixosConfigurations: {exc}")
        return
    for name in names:
        planner.note(f"build nixosConfigurations.{name}")
        proc = subprocess.run(
            [
                "nix",
                "build",
                "--no-link",
                f"{root}#nixosConfigurations.{name}.config.system.build.toplevel",
            ],
            cwd=root,
        )
        if proc.returncode != 0:
            planner.fail(f"system build failed: {name}")


def self_test() -> None:
    assert version_key("0.22.4.1") > version_key("0.22.3.1")
    assert version_key("0.1.13-nightly.20261125.5245") > version_key(
        "0.1.12-nightly.20261122.5071"
    )
    template = "https://github.com/CodebuffAI/codebuff-community/releases/download/freebuff-desktop-v${version}/Freebuff-${version}-linux-x86_64.AppImage"
    releases = [
        {
            "tag_name": "freebuff-v0.2.38",
            "draft": False,
            "prerelease": False,
            "assets": [{"name": "ignore", "browser_download_url": "https://example.invalid/ignore"}],
        },
        {
            "tag_name": "freebuff-desktop-v0.0.205",
            "draft": False,
            "prerelease": True,
            "assets": [
                {
                    "name": "Freebuff-0.0.205-linux-x86_64.AppImage",
                    "browser_download_url": "https://github.com/CodebuffAI/codebuff-community/releases/download/freebuff-desktop-v0.0.205/Freebuff-0.0.205-linux-x86_64.AppImage",
                }
            ],
        },
    ]
    assert matching_release_version(template, None, "0.0.204", releases) == "0.0.205"
    nightly = "https://github.com/pingdotgg/t3code/releases/download/v${version}/T3-Code-Nightly-x86_64.AppImage"
    nightlies = [
        {
            "tag_name": "v0.1.13-nightly.20261125.5245",
            "draft": False,
            "prerelease": True,
            "assets": [
                {
                    "name": "T3-Code-Nightly-x86_64.AppImage",
                    "browser_download_url": "https://github.com/pingdotgg/t3code/releases/download/v0.1.13-nightly.20261125.5245/T3-Code-Nightly-x86_64.AppImage",
                }
            ],
        }
    ]
    assert (
        matching_release_version(nightly, "t3-code", "0.1.12-nightly.20261122.5071", nightlies)
        == "0.1.13-nightly.20261125.5245"
    )
    sample = '''
    inputs = {
      nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
      # update: skip
      mangowm = {
        url = "github:mangowm/mango";
      };
      pinned = {
        url = "github:nexu-io/open-design/db9ebb7ba84d81dffdd21de248cbcd992c791836";
      };
      nix-flatpak.url = "github:gmodena/nix-flatpak/?ref=v0.8.0";
    };
    '''
    parsed = {item["name"]: item for item in flake_inputs(sample)}
    assert set(parsed) == {"nixpkgs", "mangowm", "pinned", "nix-flatpak"}
    assert has_skip(parsed["mangowm"]["comments"])
    assert classify_flake_url(parsed["pinned"]["url"])[2] == "pin"
    assert classify_flake_url(parsed["nix-flatpak"]["url"]) == (
        "gmodena",
        "nix-flatpak",
        "tag",
        "v0.8.0",
    )
    assert classify_flake_url(parsed["nixpkgs"]["url"])[2] == "branch"
    apt_index = """
Package: 1password-cli
Version: 2.44.0-beta.02

Package: 1password
Version: 1:8.12.48~24.BETA
Filename: pool/main/1/1password/1password-8.12.48-24.BETA.amd64.deb

Package: other
Version: 9.9.9
"""
    assert apt_package_version(apt_index, "1password") == "8.12.48-24.BETA"
    assert apt_package_version(apt_index, "1password-cli") == "2.44.0-beta.02"
    assert apt_package_version(apt_index, "missing") is None
    assert version_key("8.12.48-24.BETA") > version_key("8.12.46-26.BETA")
    assert apt_stanza("# update: apt https://example.invalid/Packages") == "1password"
    assert apt_stanza("# update: apt https://example.invalid/Packages 1password-cli") == "1password-cli"
    assert (
        apt_stanza("# update: apt https://example.invalid/Packages\nversion = \"8.12.48-24.BETA\";")
        == "1password"
    )
    print("self-test ok")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="print the plan and do not write or build")
    parser.add_argument("--no-build", action="store_true", help="update pins and do not build")
    parser.add_argument(
        "--inputs",
        action="store_true",
        help="also move branch flake inputs (nixpkgs, home-manager, sops-nix, ...)",
    )
    parser.add_argument(
        "--only",
        action="append",
        default=[],
        help="limit to a package directory or flake input name; repeatable",
    )
    parser.add_argument("--self-test", action="store_true", help="run the built-in matcher checks")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return 0

    root = Path(__file__).resolve().parent.parent
    planner = Planner(root, args.inputs)
    only = args.only

    def wanted(label: str) -> bool:
        if not only:
            return True
        return any(item in label for item in only)

    changed_files: list[Path] = []
    for path in package_files(root):
        label = path.relative_to(root).as_posix()
        if not wanted(label) and not wanted(path.parent.name):
            continue
        try:
            if update_package(path, planner, args.check):
                changed_files.append(path)
        except Exception as exc:
            planner.fail(f"{label}: {exc}")

    for path in flake_files(root):
        label = path.relative_to(root).as_posix()
        names = [item["name"] for item in flake_inputs(path.read_text())]
        if only and not any(item == name or item in label for item in only for name in names):
            continue
        try:
            update_flake(path, planner, args.check, only)
        except Exception as exc:
            planner.fail(f"{label}: {exc}")

    if not args.check:
        outputs = output_names(root)
        for path in changed_files:
            try:
                prefetch_fetchurls(path, planner)
                repair_hashes(path, installable_for(root, path, outputs), planner)
            except Exception as exc:
                planner.fail(f"{path.relative_to(root)}: {exc}")
        if not args.no_build and not planner.errors:
            validate(root, planner, only)

    if planner.errors:
        print(f"\n{len(planner.errors)} problem(s).", file=sys.stderr)
        return 1
    if not planner.actions:
        print("nothing to update")
    return 0


if __name__ == "__main__":
    sys.exit(main())
