#!/usr/bin/env python3
"""Download uBlock Origin / EasyList filter lists and compile them to WebKit content-blocker JSON.

Each group becomes one WKContentRuleList. Exceptions only apply inside their own list,
so uBO's unbreak list is added to every group whose rules it may need to relax.
"""

import hashlib
import json
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "Sources/Lithium/Resources/Filters"
TOOLS = ROOT / ".tools"
CONVERTER_REPO = "https://github.com/AdguardTeam/SafariConverterLib.git"
CONVERTER_TAG = "v4.3.0"
CONVERTER_BIN = TOOLS / "SafariConverterLib/.build/release/ConverterTool"

SOURCES_FILE = (ROOT / "Sources/Lithium/Resources/FilterSources.json").read_bytes()
SOURCES = json.loads(SOURCES_FILE)
# In the manifest, as the app's updater writes it (FilterUpdater.Sources.digest): a list's new
# address or a changed token changes no group, and must still rebuild the set.
SOURCES_DIGEST = hashlib.sha256(SOURCES_FILE).hexdigest()
LISTS = SOURCES["lists"]
GROUPS = SOURCES["groups"]
# uBO preprocessor tokens that hold for a WebKit content blocker.
TRUE_TOKENS = set(SOURCES["trueTokens"])
# Manifest.currentFormat in the app: 2 keeps uBO's +js() filters apart in scriptlets.txt.
FORMAT = 2
# Rules a download needs to count as a list, as in the app's updater (FilterUpdater.minimumRules).
MINIMUM_RULES = 10


def fetch(url: str) -> str:
    request = urllib.request.Request(url, headers={"User-Agent": "Lithium-filter-updater"})
    with urllib.request.urlopen(request, timeout=60) as response:
        body = response.read().decode("utf-8", errors="replace")
    # An HTML page (an error or login page served with 200) would parse into junk rules, which
    # the app would then ship and fall back to.
    if next((c for c in body if not c.isspace() and c != "﻿"), "") == "<":
        raise SystemExit(f"update-filters.py: {url} answered an HTML page, not a filter list")
    return body


def download(name: str) -> list[str]:
    """The list's rules. A captive portal, a parked domain or an emptied file answers 200 too:
    a list with fewer than MINIMUM_RULES rules fails the build, as the app's updater fails it."""
    lines = expand(LISTS[name], set())
    if len(lines) < MINIMUM_RULES:
        raise SystemExit(f"update-filters.py: {name} has {len(lines)} rules, not a filter list")
    return lines


def eval_condition(expr: str) -> bool:
    py = re.sub(r"!(?!=)", " not ", expr).replace("&&", " and ").replace("||", " or ")
    py = re.sub(r"[A-Za-z_][A-Za-z0-9_]*", lambda m: m.group(0) if m.group(0) in ("not", "and", "or") else str(m.group(0) in TRUE_TOKENS), py)
    # Anything but tokens, operators and parentheses (digits, `**`, a call) is no condition: it
    # could otherwise raise and stop the build, or hang it (`9**9**9`).
    if not re.fullmatch(r"(\s|True|False|not|and|or|\(|\))*", py):
        return False
    try:
        return bool(eval(py, {"__builtins__": {}}))
    except Exception:
        return False


def expand(url: str, seen: set[str]) -> list[str]:
    if url in seen:
        return []
    seen.add(url)
    lines: list[str] = []
    stack: list[bool] = []
    for line in fetch(url).splitlines():
        stripped = line.strip()
        if stripped.startswith("!#if "):
            stack.append(eval_condition(stripped[5:]))
        elif stripped == "!#else" and stack:
            stack[-1] = not stack[-1]
        elif stripped == "!#endif" and stack:
            stack.pop()
        elif not all(stack):
            continue
        elif stripped.startswith("!#include "):
            # Only from the list's own server, as in the app's updater.
            included = urllib.parse.urljoin(url, stripped[10:].strip())
            here, there = urllib.parse.urlsplit(url), urllib.parse.urlsplit(included)
            if (there.scheme, there.netloc.lower()) == (here.scheme, here.netloc.lower()):
                lines += expand(included, seen)
        elif stripped and not stripped.startswith(("!", "[Adblock")):
            lines.append(stripped)
    return lines


def converter_tag(repo: Path) -> str:
    result = subprocess.run(["git", "-C", str(repo), "describe", "--tags", "--exact-match"], capture_output=True, text=True)
    return result.stdout.strip() if result.returncode == 0 else ""


def ensure_converter() -> None:
    """The converter at CONVERTER_TAG. A clone of another tag (CONVERTER_TAG raised with
    Package.swift's version) is cloned and built again: the bundled set would otherwise be
    built with the old converter while the app's updater uses the new one."""
    repo = TOOLS / "SafariConverterLib"
    current = repo.exists() and converter_tag(repo) == CONVERTER_TAG
    if current and CONVERTER_BIN.exists():
        return
    TOOLS.mkdir(exist_ok=True)
    if not current:
        shutil.rmtree(repo, ignore_errors=True)
        subprocess.run(["git", "clone", "--depth", "1", "--branch", CONVERTER_TAG, CONVERTER_REPO, str(repo)], check=True)
    subprocess.run(["swift", "build", "-c", "release", "--product", "ConverterTool"], cwd=repo, check=True)


def convert(rules: list[str], output: Path) -> dict:
    result = subprocess.run(
        [str(CONVERTER_BIN), "convert", "--advanced-blocking", "true"],
        input="\n".join(rules), capture_output=True, text=True, check=True,
    )
    stats = json.loads(result.stdout)
    output.write_text(stats.pop("safariRulesJSON"))
    return stats


def build(out: Path) -> None:
    # lists/ keeps each list as downloaded: the app's updater falls back to it when a list fails.
    (out / "lists").mkdir(parents=True, exist_ok=True)
    cache: dict[str, list[str]] = {}
    # "converter" lets --check rebuild a set an older converter built (see complete()).
    manifest = {"format": FORMAT, "updated": datetime.now(timezone.utc).isoformat(timespec="seconds"), "groups": {}, "sources": SOURCES_DIGEST, "converter": CONVERTER_TAG}
    advanced: list[str] = []
    scriptlets: list[str] = []
    for group, names in GROUPS.items():
        rules: list[str] = []
        for name in names:
            if name not in cache:
                print(f"fetch {name}", file=sys.stderr)
                cache[name] = download(name)
                (out / "lists" / f"{name}.txt").write_text("\n".join(cache[name]))
            # uBO's +js() filters run with uBO's own scriptlets in the app (UBOScriptlets.swift), unconverted.
            is_scriptlet = lambda r: name.startswith("ubo-") and ("##+js(" in r or "#@#+js(" in r)
            # Rules that run code in pages come only from uBO's own lists (FilterUpdater.isAllowed).
            allowed = lambda r: name.startswith("ubo-") or not ("+js(" in r or "#%#" in r or "#@%#" in r)
            scriptlets += [r for r in cache[name] if is_scriptlet(r)]
            rules += [r for r in cache[name] if allowed(r) and not is_scriptlet(r)]
        rules = list(dict.fromkeys(rules))
        stats = convert(rules, out / f"{group}.json")
        advanced += (stats.get("advancedRulesText") or "").splitlines()
        manifest["groups"][group] = {
            "lists": names,
            "sourceRules": stats["sourceRulesCount"],
            "webkitRules": stats["safariRulesCount"],
            "discarded": stats["discardedSafariRules"],
            "errors": stats["errorsCount"],
        }
        print(f"{group}: {stats['safariRulesCount']} WebKit rules, {stats['discardedSafariRules']} discarded", file=sys.stderr)
    advanced = list(dict.fromkeys(advanced))
    (out / "advanced.txt").write_text("\n".join(advanced) + "\n")
    manifest["advancedRules"] = len(advanced)
    print(f"advanced: {len(advanced)} rules for the in-page engine", file=sys.stderr)
    scriptlets = list(dict.fromkeys(scriptlets))
    (out / "scriptlets.txt").write_text("\n".join(scriptlets) + "\n")
    manifest["scriptletRules"] = len(scriptlets)
    print(f"scriptlets: {len(scriptlets)} uBO +js() filters", file=sys.stderr)
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")


def complete(folder: Path) -> bool:
    """Whether folder holds a whole set built from FilterSources.json with CONVERTER_TAG: a manifest that parses, and every file it names."""
    try:
        manifest = json.loads((folder / "manifest.json").read_text())
        lists = {group: entry["lists"] for group, entry in manifest["groups"].items()}
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        return False
    names = {name for names in GROUPS.values() for name in names}
    files = [f"{group}.json" for group in GROUPS] + ["advanced.txt", "scriptlets.txt"] + [f"lists/{name}.txt" for name in names]
    return manifest.get("format") == FORMAT and manifest.get("sources") == SOURCES_DIGEST and manifest.get("converter") == CONVERTER_TAG and lists == GROUPS and all((folder / file).is_file() for file in files)


def main() -> int:
    # scripts/build-app.sh asks first, so it never builds the app with a missing or half-written set.
    if sys.argv[1:] == ["--check"]:
        return 0 if complete(OUT) else 1
    ensure_converter()
    # Built apart and swapped in whole, so a failed fetch or a ^C leaves the previous set as it
    # was, never new group files next to an old manifest. .tools/ is on the same volume, and
    # outside the target's resources.
    TOOLS.mkdir(exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix="Filters-", dir=TOOLS))
    previous = staging.with_name(staging.name + "-previous")
    try:
        staging.chmod(0o755)
        build(staging)
        if OUT.exists():
            OUT.rename(previous)
        staging.rename(OUT)
    finally:
        if previous.exists() and not OUT.exists():
            previous.rename(OUT)
        shutil.rmtree(staging, ignore_errors=True)
        shutil.rmtree(previous, ignore_errors=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
