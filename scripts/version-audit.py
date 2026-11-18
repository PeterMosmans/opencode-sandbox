#!/usr/bin/env python3
# Copyright (C) 2026 Peter Mosmans [Go Forward]
# SPDX-License-Identifier: GPL-3.0-or-later
# ruff: noqa: BLE001, FLY002, S110, S112, B008
"""Audit and bump every version pin used by the sandbox image.

Sources: npm (package.json), PyPI (requirements.txt), GitHub release
binaries (engram, buildx, compose - including their SHA256 pins) and the
Docker base image digest pinned in the Dockerfile. A GitHub binary bump
is only ever proposed together with the checksums from that release's
checksums.txt (fail-closed: no checksum, no bump).

Set GITHUB_TOKEN to raise the GitHub API rate limit.
"""

from __future__ import annotations

import concurrent.futures
import difflib
import json
import os
import re
import sys
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path

try:
    import httpx
    import typer
    from rich.console import Console
    from rich.table import Table
except ImportError as exc:  # pragma: no cover
    sys.exit(
        f"missing dependency: {exc.name} - install with: "
        "python3 -m venv .venv && .venv/bin/pip install httpx typer rich"
    )

TIMEOUT = 30.0
ROOT = Path(__file__).resolve().parent.parent
MAKEFILE = ROOT / "Makefile"
ENV_FILE = ROOT / ".env"
ENV_EXAMPLE = ROOT / "env.example"
DOCKERFILE = ROOT / "Dockerfile"
PACKAGE_JSON = ROOT / "package.json"
REQUIREMENTS = ROOT / "requirements.txt"

SOURCES = ("npm", "pypi", "github", "docker")
SHA256_RE = re.compile(r"[0-9a-f]{64}")
EXACT_PIN_RE = re.compile(r"\d+(\.\d+)*")

# GitHub release tools: version/sha variable names and the artifact names
# inside each release's checksums.txt ({v} = version without leading 'v').
GITHUB_TOOLS: dict[str, dict] = {
    "engram": {
        "repo": "Gentleman-Programming/engram",
        "version_var": "ENGRAM_VERSION",
        "sha_vars": {
            "ENGRAM_SHA256": "engram_{v}_linux_amd64.tar.gz",
        },
    },
    "buildx": {
        "repo": "docker/buildx",
        "version_var": "BUILDX_VERSION",
        "sha_vars": {
            "BUILDX_SHA256_AMD64": "buildx-v{v}.linux-amd64",
            "BUILDX_SHA256_ARM64": "buildx-v{v}.linux-arm64",
        },
    },
    "compose": {
        "repo": "docker/compose",
        "version_var": "COMPOSE_VERSION",
        "sha_vars": {
            "COMPOSE_SHA256_AMD64": "docker-compose-linux-x86_64",
            "COMPOSE_SHA256_ARM64": "docker-compose-linux-aarch64",
        },
    },
}

PIN_VARS = [
    var
    for tool in GITHUB_TOOLS.values()
    for var in [tool["version_var"], *tool["sha_vars"]]
]

MANIFEST_ACCEPT = ", ".join(
    [
        "application/vnd.oci.image.index.v1+json",
        "application/vnd.docker.distribution.manifest.list.v2+json",
        "application/vnd.oci.image.manifest.v1+json",
        "application/vnd.docker.distribution.manifest.v2+json",
    ]
)

DOCKERFILE_FROM_RE = re.compile(
    r"^FROM\s+(?P<image>[^\s@]+)@sha256:(?P<digest>[0-9a-f]{64})",
    re.MULTILINE,
)

app = typer.Typer(add_completion=False, help=__doc__)
console = Console()


@dataclass
class Item:
    source: str
    name: str
    current: str
    latest: str
    status: str  # ok | outdated | ahead | pin-mismatch | unknown
    note: str = ""


@dataclass
class Edit:
    path: Path
    pattern: re.Pattern
    repl: str
    label: str


def _get(client: httpx.Client, url: str, **kw) -> httpx.Response:
    resp = client.get(url, timeout=TIMEOUT, **kw)
    resp.raise_for_status()
    return resp


def _read(path: Path) -> str:
    return path.read_text(encoding="utf-8") if path.is_file() else ""


def _ver_tuple(value: str) -> tuple[int, ...] | None:
    """Numeric core of a version string for ordering, None if unparseable."""
    parts = value.split(".")
    nums = []
    for part in parts:
        m = re.match(r"^(\d+)(?:[-+].*)?$", part)
        if not m:
            return None
        nums.append(int(m.group(1)))
    return tuple(nums) if nums else None


def is_outdated(current: str, latest: str) -> bool:
    """True only when latest is strictly newer than current."""
    if current == latest:
        return False
    cur, new = _ver_tuple(current), _ver_tuple(latest)
    if cur is not None and new is not None:
        # Pad so 1.2 compares equal to 1.2.0
        size = max(len(cur), len(new))
        cur += (0,) * (size - len(cur))
        new += (0,) * (size - len(new))
        return cur < new
    return True


def version_status(current: str, latest: str) -> str:
    if current == latest:
        return "ok"
    if is_outdated(current, latest):
        return "outdated"
    return "ahead"


def parse_vars(path: Path, keys: list[str], makefile: bool = False) -> dict:
    """Parse KEY=value (or Makefile KEY ?= value) lines from a file.

    First assignment wins, matching apply_edits (first-match editing).
    """
    out = {}
    remaining = set(keys)
    for line in _read(path).splitlines():
        for key in list(remaining):
            sep = r"\s*\?=\s*" if makefile else r"\s*=\s*"
            m = re.match(rf"^{key}{sep}(\S+)", line)
            if m:
                out[key] = m.group(1)
                remaining.discard(key)
    return out


def pin_values() -> dict:
    """Effective pin values: .env overrides the Makefile defaults."""
    vals = parse_vars(MAKEFILE, PIN_VARS, makefile=True)
    vals.update(parse_vars(ENV_FILE, PIN_VARS))
    return vals


def pin_files() -> list[Path]:
    return [p for p in (MAKEFILE, ENV_EXAMPLE, ENV_FILE) if p.is_file()]


def npm_deps() -> dict:
    return json.loads(_read(PACKAGE_JSON))["dependencies"]


def pypi_deps() -> dict:
    deps = {}
    for line in _read(REQUIREMENTS).splitlines():
        m = re.match(r"^([A-Za-z0-9._-]+)==(\S+)", line)
        if m:
            deps[m.group(1)] = m.group(2)
    return deps


def npm_latest(client: httpx.Client, name: str) -> str:
    quoted = name.replace("/", "%2F")
    return _get(client, f"https://registry.npmjs.org/{quoted}/latest").json()["version"]


def pypi_latest(client: httpx.Client, name: str) -> str:
    return _get(client, f"https://pypi.org/pypi/{name}/json").json()["info"]["version"]


def gh_headers() -> dict:
    token = os.environ.get("GITHUB_TOKEN")
    return {"Authorization": f"Bearer {token}"} if token else {}


def github_latest(client: httpx.Client, repo: str) -> str:
    tag = _get(
        client,
        f"https://api.github.com/repos/{repo}/releases/latest",
        headers=gh_headers(),
    ).json()["tag_name"]
    return tag.removeprefix("v")


def github_checksums(client: httpx.Client, repo: str, version: str) -> dict:
    """Parse a release's checksums.txt into {artifact: sha256}.

    Only well-formed lowercase hex digests are accepted; anything else
    makes the whole manifest unusable (fail-closed).
    """
    url = f"https://github.com/{repo}/releases/download/v{version}/checksums.txt"
    sums = {}
    for line in _get(client, url).text.splitlines():
        parts = line.split()
        if len(parts) >= 2 and SHA256_RE.fullmatch(parts[0]):
            name = parts[1].lstrip("*").removeprefix("./")
            sums[name] = parts[0]
    if not sums:
        raise ValueError("no valid checksums found in manifest")
    return sums


def docker_current() -> tuple[str, str]:
    m = DOCKERFILE_FROM_RE.search(_read(DOCKERFILE))
    if not m:
        raise ValueError("no digest-pinned FROM line found in Dockerfile")
    return m.group("image"), m.group("digest")


def docker_latest(client: httpx.Client, image: str) -> str:
    repo, _, tag = image.partition(":")
    if "/" in repo:
        host = repo.split("/", 1)[0]
        if "." in host or ":" in host:
            raise ValueError(f"unsupported registry in image '{image}'")
    else:
        repo = f"library/{repo}"
    token = _get(
        client,
        "https://auth.docker.io/token",
        params={
            "service": "registry.docker.io",
            "scope": f"repository:{repo}:pull",
        },
    ).json()["token"]
    resp = client.get(
        f"https://registry-1.docker.io/v2/{repo}/manifests/{tag}",
        timeout=TIMEOUT,
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": MANIFEST_ACCEPT,
        },
    )
    resp.raise_for_status()
    return resp.headers["docker-content-digest"].removeprefix("sha256:")


def check_npm(client: httpx.Client, name: str, current: str) -> Item:
    try:
        latest = npm_latest(client, name)
    except Exception:
        return Item("npm", name, current, "?", "unknown")
    return Item("npm", name, current, latest, version_status(current, latest))


def check_pypi(client: httpx.Client, name: str, current: str) -> Item:
    try:
        latest = pypi_latest(client, name)
    except Exception:
        return Item("pypi", name, current, "?", "unknown")
    return Item("pypi", name, current, latest, version_status(current, latest))


def check_github(
    client: httpx.Client,
    tool: str,
    cfg: dict,
    current: str,
    pins: dict,
    verify_pins: bool,
) -> Item:
    try:
        latest = github_latest(client, cfg["repo"])
    except Exception:
        return Item("github", tool, current, "?", "unknown")
    status = version_status(current, latest)
    note = ""
    if verify_pins:
        try:
            sums = github_checksums(client, cfg["repo"], current)
            bad = [
                var
                for var, art in cfg["sha_vars"].items()
                if sums.get(art.format(v=current)) != pins.get(var)
            ]
            if bad:
                status = "pin-mismatch"
                note = "pinned checksum differs from upstream: " + ", ".join(bad)
        except Exception:
            note = "checksums.txt unavailable for pinned version"
    return Item("github", tool, current, latest, status, note)


def check_docker(client: httpx.Client) -> Item:
    try:
        image, current = docker_current()
        latest = docker_latest(client, image)
    except Exception as exc:
        return Item("docker", "base image", "?", "?", "unknown", str(exc))
    status = "ok" if latest == current else "outdated"
    return Item("docker", image, current[:16] + "…", latest[:16] + "…", status)


def collect(client: httpx.Client, sources: list[str], verify_pins: bool) -> list[Item]:
    jobs: list[Callable[[], Item]] = []
    if "npm" in sources:
        for name, ver in npm_deps().items():
            jobs.append(lambda n=name, v=ver: check_npm(client, n, v))
    if "pypi" in sources:
        for name, ver in pypi_deps().items():
            jobs.append(lambda n=name, v=ver: check_pypi(client, n, v))
    if "github" in sources:
        pins = pin_values()
        for tool, cfg in GITHUB_TOOLS.items():
            cur = pins.get(cfg["version_var"], "?")
            jobs.append(
                lambda t=tool, c=cfg, v=cur, p=pins: check_github(
                    client, t, c, v, p, verify_pins
                )
            )
    if "docker" in sources:
        jobs.append(lambda: check_docker(client))
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        return list(pool.map(lambda job: job(), jobs))


STATUS_STYLE = {
    "ok": "green",
    "outdated": "yellow",
    "ahead": "cyan",
    "pin-mismatch": "red",
    "unknown": "dim",
}


def render(items: list[Item]) -> tuple[int, int]:
    """Print the audit table; return (problems, unknowns)."""
    table = Table(title="Version audit")
    table.add_column("Source")
    table.add_column("Item")
    table.add_column("Current")
    table.add_column("Latest")
    table.add_column("Status")
    table.add_column("Note", overflow="fold")
    problems = 0
    unknowns = 0
    for item in items:
        if item.status in ("outdated", "pin-mismatch"):
            problems += 1
        elif item.status == "unknown":
            unknowns += 1
        table.add_row(
            item.source,
            item.name,
            item.current,
            item.latest,
            f"[{STATUS_STYLE[item.status]}]{item.status}[/]",
            item.note,
        )
    console.print(table)
    summary = f"{len(items)} checked, {problems} need attention."
    if unknowns:
        summary += f" {unknowns} could not be checked (network/API?)."
    console.print(summary)
    return problems, unknowns


def var_edit(path: Path, var: str, value: str) -> Edit:
    makefile = path == MAKEFILE
    sep = " ?= " if makefile else "="
    pattern = rf"^{var}\s*\?=\s*\S+" if makefile else rf"^{var}\s*=\s*\S+"
    return Edit(path, re.compile(pattern), f"{var}{sep}{value}", f"{var} → {value}")


def compute_edits(
    client: httpx.Client, sources: list[str]
) -> tuple[list[Edit], list[str]]:
    edits: list[Edit] = []
    skipped: list[str] = []
    if "npm" in sources:
        for name, ver in npm_deps().items():
            if not EXACT_PIN_RE.fullmatch(ver):
                skipped.append(
                    f"{name}: pin '{ver}' is not an exact version - not bumping"
                )
                continue
            try:
                latest = npm_latest(client, name)
            except Exception:
                continue
            if is_outdated(ver, latest):
                pat = re.compile(rf'"{re.escape(name)}":\s*"{re.escape(ver)}"')
                edits.append(
                    Edit(
                        PACKAGE_JSON,
                        pat,
                        f'"{name}": "{latest}"',
                        f"package.json: {name} {ver} → {latest}",
                    )
                )
    if "pypi" in sources:
        for name, ver in pypi_deps().items():
            try:
                latest = pypi_latest(client, name)
            except Exception:
                continue
            if is_outdated(ver, latest):
                edits.append(
                    Edit(
                        REQUIREMENTS,
                        re.compile(rf"^{re.escape(name)}==\S+$"),
                        f"{name}=={latest}",
                        f"requirements.txt: {name} {ver} → {latest}",
                    )
                )
    if "github" in sources:
        pins = pin_values()
        for tool, cfg in GITHUB_TOOLS.items():
            current = pins.get(cfg["version_var"])
            if not current:
                continue
            try:
                latest = github_latest(client, cfg["repo"])
            except Exception:
                continue
            # Fail-closed: only propose changes together with fresh
            # upstream checksums (this also repairs drifted pins of the
            # latest version).
            try:
                sums = github_checksums(client, cfg["repo"], latest)
            except Exception:
                if latest != current:
                    skipped.append(
                        f"{tool} {latest}: checksums.txt unavailable - not bumping"
                    )
                continue
            new_sums = {}
            missing = None
            for var, art in cfg["sha_vars"].items():
                digest = sums.get(art.format(v=latest))
                if not digest:
                    missing = art
                    break
                new_sums[var] = digest
            if missing:
                skipped.append(
                    f"{tool} {latest}: {missing} missing from "
                    "checksums.txt - not bumping"
                )
                continue
            # Per file: only rewrite a file's checksums when that file
            # ends up at the version the checksums belong to (either it
            # already pins it, or we bump its version line in the same
            # pass). Files pinning something newer are left alone.
            for path in pin_files():
                vals = parse_vars(
                    path,
                    [cfg["version_var"], *new_sums],
                    path == MAKEFILE,
                )
                file_ver = vals.get(cfg["version_var"])
                if file_ver is None:
                    continue
                if file_ver != latest:
                    if not is_outdated(file_ver, latest):
                        continue
                    edits.append(var_edit(path, cfg["version_var"], latest))
                for var, digest in new_sums.items():
                    if var in vals and vals[var] != digest:
                        edits.append(var_edit(path, var, digest))
    if "docker" in sources:
        try:
            image, current = docker_current()
            latest = docker_latest(client, image)
            if latest != current:
                edits.append(
                    Edit(
                        DOCKERFILE,
                        re.compile(rf"(?<=@sha256:){current}"),
                        latest,
                        f"Dockerfile: base image digest {current[:16]}… → "
                        f"{latest[:16]}…",
                    )
                )
        except Exception:
            pass
    return edits, skipped


def apply_edits(edits: list[Edit]) -> tuple[dict[Path, str], list[str]]:
    """Apply edits line-wise; return ({path: new_content}, missed_labels)."""
    result: dict[Path, str] = {}
    missed: list[str] = []
    by_file: dict[Path, list[Edit]] = {}
    for edit in edits:
        by_file.setdefault(edit.path, []).append(edit)
    for path, file_edits in by_file.items():
        lines = _read(path).splitlines(keepends=True)
        for edit in file_edits:
            for i, line in enumerate(lines):
                if edit.pattern.search(line):
                    new = edit.pattern.sub(edit.repl, line)
                    if new != line:
                        lines[i] = new
                        break
            else:
                missed.append(edit.label)
        content = "".join(lines)
        if content != _read(path):
            result[path] = content
    return result, missed


def validate_sources(sources: list[str]) -> list[str]:
    chosen = sources or list(SOURCES)
    for src in chosen:
        if src not in SOURCES:
            console.print(
                f"[red]unknown source '{src}'[/] (choose from: {', '.join(SOURCES)})"
            )
            raise typer.Exit(code=2)
    return chosen


def load_deps(sources: list[str]) -> None:
    """Fail early with a clear message when a pin file is unreadable."""
    try:
        if "npm" in sources:
            npm_deps()
        if "pypi" in sources:
            pypi_deps()
        if "docker" in sources:
            docker_current()
    except Exception as exc:
        console.print(f"[red]cannot read pin files:[/] {exc}")
        raise typer.Exit(code=2)


@app.command()
def check(
    source: list[str] = typer.Option(
        [], "--source", "-s", help="Limit to: npm, pypi, github, docker"
    ),
    verify_pins: bool = typer.Option(
        True, help="Verify pinned checksums against upstream manifests"
    ),
) -> None:
    """Check every pin against upstream; exit code = items needing attention."""
    sources = validate_sources(source)
    load_deps(sources)
    with httpx.Client(follow_redirects=True) as client:
        items = collect(client, sources, verify_pins)
    problems, _unknowns = render(items)
    raise typer.Exit(code=min(problems, 125))


@app.command()
def bump(
    source: list[str] = typer.Option(
        [], "--source", "-s", help="Limit to: npm, pypi, github, docker"
    ),
    write: bool = typer.Option(
        False, "--write", "-w", help="Apply the proposed bumps to the files"
    ),
    patch: bool = typer.Option(
        False, "--patch", "-p", help="Show a unified diff of the proposal"
    ),
) -> None:
    """Propose version bumps (GitHub tools always incl. fresh checksums)."""
    sources = validate_sources(source)
    load_deps(sources)
    with httpx.Client(follow_redirects=True) as client:
        edits, skipped = compute_edits(client, sources)
    for note in skipped:
        console.print(f"[red]skipped:[/] {note}")
    contents, missed = apply_edits(edits)
    for label in missed:
        console.print(f"[red]not applied (no matching line):[/] {label}")
    if not contents:
        if not skipped:
            console.print("[green]Everything is at the latest version.[/]")
        raise typer.Exit(code=1 if skipped or missed else 0)
    if write:
        for path, content in contents.items():
            path.write_text(content, encoding="utf-8")
            console.print(f"[green]updated[/] {path.relative_to(ROOT)}")
    elif patch:
        # Plain stdout: rich would soft-wrap long diff lines when piped.
        for path, content in contents.items():
            diff = difflib.unified_diff(
                _read(path).splitlines(keepends=True),
                content.splitlines(keepends=True),
                fromfile=str(path.relative_to(ROOT)),
                tofile=str(path.relative_to(ROOT)),
            )
            sys.stdout.write("".join(diff))
    else:
        table = Table(title="Proposed bumps (use --patch or --write)")
        table.add_column("Change")
        for edit in edits:
            table.add_row(edit.label)
        console.print(table)
    console.print(
        "[dim]After bumping: run 'make check-pins' then rebuild the image.[/]"
    )
    if skipped or missed:
        raise typer.Exit(code=1)


if __name__ == "__main__":
    app()
