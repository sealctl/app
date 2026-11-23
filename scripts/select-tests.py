#!/usr/bin/env python3
"""Which tests a pull request needs (SPEC 17.1, "Test selection"). Python 3 standard library only.

    scripts/select-tests.py FILE...      the selection for these changed paths, as JSON
    scripts/select-tests.py --github     in a `changes` job: reads the event, the pull request's
                                         labels and files with `gh api`; writes GITHUB_OUTPUT

Paths map to suites in .github/test-map. Conservative: a path no line maps, the label
`ci:full`, or any run that is not a pull request selects everything. Swift packages and their
dependencies come from ios/Packages/*/Package.swift, the UI test classes from ios/UITests.
"""

import glob as globmod
import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MAP = os.path.join(ROOT, ".github", "test-map")
PACKAGES = "ios/Packages"
FULL_LABEL = "ci:full"
# GET /pulls/{n}/files lists at most 3000 files
MAX_FILES = 3000


def glob_re(glob):
    """`**` matches across folders (`**/` also matches no folder), `*` and `?` within one."""
    out, i = "", 0
    while i < len(glob):
        if glob.startswith("**/", i):
            out, i = out + "(?:.*/)?", i + 3
        elif glob.startswith("**", i):
            out, i = out + ".*", i + 2
        elif glob[i] == "*":
            out, i = out + "[^/]*", i + 1
        elif glob[i] == "?":
            out, i = out + "[^/]", i + 1
        else:
            out, i = out + re.escape(glob[i]), i + 1
    return re.compile(out + r"\Z")


def load_map(path=MAP):
    rules = []
    with open(path, encoding="utf-8") as f:
        for n, line in enumerate(f, 1):
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            glob, *suites = line.split()
            if not suites:
                raise SystemExit(f"{path}:{n}: no suites for {glob}")
            rules.append((glob, glob_re(glob), suites))
    return rules


def project():
    """Swift packages (dependencies, tests or not), the packages whose tests the sealctl scheme
    runs on the simulator, and the UI test classes."""
    packages = {}
    for manifest in sorted(globmod.glob(os.path.join(ROOT, PACKAGES, "*", "Package.swift"))):
        d = os.path.dirname(manifest)
        with open(manifest, encoding="utf-8") as f:
            deps = set(re.findall(r'\.package\(\s*path:\s*"\.\./([^"]+)"', f.read()))
        packages[os.path.basename(d)] = {"deps": deps, "tests": os.path.isdir(os.path.join(d, "Tests"))}
    with open(os.path.join(ROOT, "ios", "project.yml"), encoding="utf-8") as f:
        scheme = re.findall(r"-\s*package:\s*(\w+)/(\w+)", f.read())
    ui = set()
    for swift in globmod.glob(os.path.join(ROOT, "ios", "UITests", "*.swift")):
        with open(swift, encoding="utf-8") as f:
            ui |= set(re.findall(r"^final class (\w+): SealctlTestCase", f.read(), re.M))
    return {"packages": packages, "scheme": dict(scheme), "ui": ui}


def select(files, proj, rules, full_reason=None):
    """The selection for a list of changed paths, or everything with `full_reason`."""
    packages, ui_classes = proj["packages"], proj["ui"]
    for glob, _, suites in rules:
        for s in suites:
            kind, _, name = s.partition(":")
            ok = (s in ("all", "none", "ios", "ios:all", "android", "pkg:all", "ui:all")
                  or (kind == "pkg" and name in packages) or (kind == "ui" and name in ui_classes))
            if not ok:
                raise SystemExit(f".github/test-map: unknown suite {s!r} for {glob}")
    full = full_reason
    ios = android = False
    pkgs, changed, ui = set(), set(), set()
    for f in files:
        matched = [s for _, rx, suites in rules if rx.match(f) for s in suites]
        if not matched:
            full = full or f"{f} is not in .github/test-map"
            continue
        for s in matched:
            kind, _, name = s.partition(":")
            if s == "all":
                full = full or f"{f} runs everything"
            elif s == "ios":
                ios = True
            elif s == "ios:all":
                ios = True
                pkgs |= set(packages)
                ui.add("all")
            elif s == "android":
                android = True
            elif s == "pkg:all":
                pkgs |= set(packages)
            elif kind == "pkg":
                pkgs.add(name)
            elif kind == "ui":
                ui.add(name)
        parts = f.split("/")
        if f.startswith(PACKAGES + "/") and len(parts) > 3 and parts[2] in packages:
            pkgs.add(parts[2])
            if parts[3] != "Tests":
                changed.add(parts[2])
    if full:
        return {
            "full": True, "reason": full, "ios": True, "android": True,
            "packages": sorted(p for p, v in packages.items() if v["tests"]),
            "simulator": sorted(proj["scheme"].values()),
            "ui": ["all"],
        }
    # a package whose dependency changed runs its tests too
    while True:
        more = {p for p, v in packages.items() if v["deps"] & changed} - changed
        if not more:
            break
        changed |= more
    pkgs = sorted(p for p in pkgs | changed if packages[p]["tests"])
    ui = ["all"] if "all" in ui else sorted(ui)
    return {
        "full": False, "reason": "",
        "ios": bool(ios or pkgs or ui), "android": android,
        "packages": pkgs,
        "simulator": sorted(proj["scheme"][p] for p in pkgs if p in proj["scheme"]),
        "ui": ui,
    }


def gh(*args):
    return subprocess.run(["gh", "api", *args], check=True, capture_output=True, text=True).stdout.split("\n")


def github():
    event = os.environ.get("EVENT", "")
    repo, pr = os.environ.get("REPO", ""), os.environ.get("PR", "")
    files, reason = [], None
    if event != "pull_request":
        reason = f"a {event or 'non-pull-request'} run tests everything"
    else:
        try:
            labels = [l for l in gh(f"repos/{repo}/pulls/{pr}", "--jq", ".labels[].name") if l]
            if FULL_LABEL in labels:
                reason = f"label {FULL_LABEL}"
            else:
                files = [l for l in gh("--paginate", f"repos/{repo}/pulls/{pr}/files",
                                       "--jq", ".[] | .filename, (.previous_filename // empty)") if l]
                if len(files) >= MAX_FILES:
                    reason = f"{len(files)} files: more than the API lists"
                elif not files:
                    reason = "no changed files listed"
        except (subprocess.CalledProcessError, OSError) as e:
            reason = f"could not read the pull request ({e}): everything"
    sel = select(files, project(), load_map(), reason)
    pad = lambda xs: " " + " ".join(xs) + " " if xs else ""
    with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as out:
        for k in ("full", "ios", "android"):
            out.write(f"{k}={str(sel[k]).lower()}\n")
        out.write(f"packages={' '.join(sel['packages'])}\n")
        out.write(f"simulator={' '.join(sel['simulator'])}\n")
        out.write(f"ui={pad(sel['ui'])}\n")
    lines = [
        "### Test selection",
        "",
        f"- everything: **{sel['full']}**" + (f" ({sel['reason']})" if sel["reason"] else ""),
        f"- iOS job: {sel['ios']}",
        f"- Swift package tests: {', '.join(sel['packages']) or 'none'}",
        f"- UI tests: {', '.join(sel['ui']) or 'none'}",
        f"- Android (Gradle) jobs: {sel['android']}",
        f"- changed files: {len(files)}",
    ]
    print("\n".join(lines))
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as s:
            s.write("\n".join(lines) + "\n")


def main(argv):
    if argv == ["--github"]:
        github()
        return
    files = argv or [l.strip() for l in sys.stdin if l.strip()]
    json.dump(select(files, project(), load_map()), sys.stdout, indent=2)
    print()


if __name__ == "__main__":
    main(sys.argv[1:])
