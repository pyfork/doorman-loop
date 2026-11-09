#!/usr/bin/env python3
# guard-builder-Opus5.5-agent, 2026-10-26 (engineering rules
# section 15, supply-chain item 5): the daily re-scan of main's locks.
# A lock that passed its audit on the day it merged can be hit by an
# advisory published later; nothing else looks again. The daily sweep runs
# this on main's copy and reports what it prints.
#
# Finds every tracked lock: requirements*.lock (PyPI), go.mod (Go),
# package-lock.json (npm), lockfile.json from maven-lockfile and
# gradle.lockfile (Maven). Asks OSV (api.osv.dev) about every package
# version in them. Standard library only, so nothing installs in the
# sweep's job, which holds an issues token.
#
# Prints Markdown lines, one per vulnerable package version.
# Exit 0: no known vulnerability (or no lock). Exit 1: found some.
# Exit 2: couldn't scan (OSV unreachable, a lock that doesn't parse): the
# sweep reports that, so a failed scan never reads as a clean one.
# Usage: scan-locks.py [repo root]   (default: the current directory)
import json, os, re, subprocess, sys, urllib.error, urllib.request

OSV = "https://api.osv.dev/v1"
TIMEOUT = 30
BATCH = 1000  # OSV's querybatch limit


class Unreachable(Exception):
    pass


def http_json(url, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, headers={"User-Agent": "kit-scan-locks", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        raise Unreachable(f"{url}: HTTP {e.code}")
    except Exception as e:  # DNS, TLS, timeout, not JSON
        raise Unreachable(f"{url}: {e}")


# ---- lock parsers: set of (name, version) --------------------------------
# The PyPI, npm and maven-lockfile parsers match rules/stacks/check-new-deps.py;
# a guard file reads no project file, so they are copied, not imported.

def parse_pypi(text):
    return {(re.sub(r"[-_.]+", "-", m.group(1)).lower(), m.group(2))
            for m in re.finditer(r"(?m)^([A-Za-z0-9][A-Za-z0-9._-]*)==([^\s;\\]+)", text)}


def parse_gomod(text):
    """require lines of go.mod (the build list since Go 1.17), single or in a block."""
    text = re.sub(r"//.*", "", text)
    out = set()
    for block in re.findall(r"(?ms)^require\s*\((.*?)^\)", text):
        for line in block.splitlines():
            parts = line.split()
            if len(parts) >= 2:
                out.add((parts[0], parts[1]))
    for m in re.finditer(r"(?m)^require\s+(\S+)\s+(\S+)\s*$", text):
        out.add((m.group(1), m.group(2)))
    return out


def parse_npm(text):
    data, out = json.loads(text), set()
    for path, p in (data.get("packages") or {}).items():
        if path and "version" in p and not p.get("link"):
            out.add((path.rsplit("node_modules/", 1)[-1], p["version"]))
    for name, p in (data.get("dependencies") or {}).items():  # lockfile v1
        if "version" in p:
            out.add((name, p["version"]))
    return out


def parse_maven(text):
    out, data = set(), json.loads(text)

    def walk(nodes):
        for n in nodes or []:
            if n.get("groupId") and n.get("artifactId") and n.get("version"):
                out.add((f"{n['groupId']}:{n['artifactId']}", n["version"]))
            walk(n.get("children"))
            walk(n.get("dependencies"))
    walk(data.get("dependencies"))
    walk(data.get("mavenPlugins"))
    return out


def parse_gradle(text):
    return {(m.group(1), m.group(2)) for m in re.finditer(r"(?m)^([^#\s:]+:[^\s:]+):([^\s=]+)=", text)}


def kind(path):
    """(OSV ecosystem, parser) for a lock file name, or None."""
    base = os.path.basename(path)
    if re.fullmatch(r"requirements[\w.-]*\.lock", base):
        return "PyPI", parse_pypi
    return {"go.mod": ("Go", parse_gomod), "package-lock.json": ("npm", parse_npm),
            "lockfile.json": ("Maven", parse_maven), "gradle.lockfile": ("Maven", parse_gradle)}.get(base)


def find_locks(root):
    files = subprocess.run(["git", "-C", root, "ls-files"], capture_output=True, text=True, check=True).stdout.split()
    return sorted(f for f in files if kind(f) and "node_modules/" not in f)


# ---- OSV ------------------------------------------------------------------

def query(pkgs):
    """{(ecosystem, name, version): [vuln id, ...]} for pkgs, a list of those triples."""
    hits = {}
    for i in range(0, len(pkgs), BATCH):
        chunk = pkgs[i:i + BATCH]
        res = http_json(f"{OSV}/querybatch", {"queries": [
            {"package": {"ecosystem": e, "name": n}, "version": v} for e, n, v in chunk]})
        results = res.get("results")
        if not isinstance(results, list) or len(results) != len(chunk):
            raise Unreachable("OSV querybatch: answer doesn't match the question")
        for pkg, r in zip(chunk, results):
            if r.get("next_page_token"):
                raise Unreachable(f"OSV querybatch: more results than one page for {pkg[1]}")
            ids = [v["id"] for v in r.get("vulns") or []]
            if ids:
                hits[pkg] = ids
    return hits


def detail(vid, ecosystem, name):
    """(aliases, summary, severity, fixed versions) of one advisory; None if withdrawn."""
    v = http_json(f"{OSV}/vulns/{vid}")
    if v.get("withdrawn"):
        return None
    sev = (v.get("database_specific") or {}).get("severity") or ""
    fixed = []
    for a in v.get("affected") or []:
        p = a.get("package") or {}
        if p.get("ecosystem") == ecosystem and p.get("name", "").lower() == name.lower():
            fixed += [ev["fixed"] for r in a.get("ranges") or [] for ev in r.get("events") or [] if "fixed" in ev]
    summary = (v.get("summary") or v.get("details", "")[:120] or "no summary").strip()
    return set(v.get("aliases") or []), summary, sev, sorted(set(fixed))


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    root = argv[0] if argv else "."
    pkgs, where = [], {}
    try:
        for f in find_locks(root):
            eco, parse = kind(f)
            for n, v in parse(open(os.path.join(root, f)).read()):
                key = (eco, n, v)
                if key not in where:
                    pkgs.append(key)
                where.setdefault(key, []).append(f)
    except (ValueError, OSError, subprocess.CalledProcessError) as e:
        print(f"- A lock couldn't be read: {e}")
        return 2
    if not pkgs:
        return 0
    try:
        hits = query(pkgs)
        lines = []
        for (eco, n, v), ids in sorted(hits.items()):
            seen = set()  # one line per advisory: GHSA and PYSEC ids alias each other
            for vid in sorted(ids):
                d = None if vid in seen else detail(vid, eco, n)
                if d is None:
                    continue
                aliases, summary, sev, fixed = d
                seen |= aliases | {vid}
                same = sorted(a for a in aliases if a in ids)
                fix = f"fixed in {', '.join(fixed)}" if fixed else "no fixed version yet"
                sev = f" ({sev.lower()})" if sev else ""
                aka = f" (also {', '.join(same)})" if same else ""
                lines.append(f"- `{n}` {v} in `{', '.join(where[(eco, n, v)])}`: "
                             f"[{vid}](https://osv.dev/vulnerability/{vid}){aka}{sev}, {summary}; {fix}")
    except Unreachable as e:
        print(f"- OSV couldn't be asked: {e}")
        return 2
    print("\n".join(lines) if lines else "", end="\n" if lines else "")
    return 1 if lines else 0


if __name__ == "__main__":
    sys.exit(main())
