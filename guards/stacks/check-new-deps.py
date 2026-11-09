#!/usr/bin/env python3
# kit-keeper-Opus5.5-agent, 2026-10-26 (engineering rules section
# 15, "New dependencies"). Copy to scripts/check-new-deps.py; the stack's
# acceptance/stack-checks.sh runs main's copy against the PR's lock.
#
# For each package version in the PR's lock and not in main's:
#   - FAIL if it was published less than --cooldown-days ago (default 7),
#     unless cooldown-skips.txt names it with an advisory;
#   - NEW-NAME if the package's first release is under --young-days old
#     (default 90): reported for the reviewer;
#   - PyPI only: FAIL if the same package's version on main had a
#     publisher signature (PEP 740 attestation) and the new one has none;
#     otherwise SIGNED or UNSIGNED is reported.
# A registry that can't be reached is a FAIL: the check never passes on
# missing data. Standard library only. Exit 0 only when nothing FAILs.
#
# Usage: check-new-deps.py pypi|go|maven|npm <main's lock> <PR's lock>
#            [--skips cooldown-skips.txt] [--cooldown-days 7] [--young-days 90]
# Locks: pypi requirements.lock, go go.sum, maven lockfile.json (from
# maven-lockfile), npm package-lock.json (v2 or v3).
import argparse, datetime as dt, json, re, sys, urllib.error, urllib.parse, urllib.request
from email.utils import parsedate_to_datetime

UTC = dt.timezone.utc
TIMEOUT = 20


class Unreachable(Exception):
    pass


def http(url, method="GET"):
    """(status, body bytes, headers); 404 is an answer, anything else failing is Unreachable."""
    req = urllib.request.Request(url, method=method, headers={"User-Agent": "kit-check-new-deps"})
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            return r.status, (r.read() if method == "GET" else b""), r.headers
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return 404, b"", e.headers
        raise Unreachable(f"{url}: HTTP {e.code}")
    except Exception as e:  # DNS, TLS, timeout
        raise Unreachable(f"{url}: {e}")


def get_json(url):
    status, body, _ = http(url)
    if status == 404:
        return None
    try:
        return json.loads(body)
    except ValueError:
        raise Unreachable(f"{url}: not JSON")


def iso(s):
    return dt.datetime.fromisoformat(s.replace("Z", "+00:00")).astimezone(UTC)


# ---- lock parsers: set of (name, version) --------------------------------

def norm_py(name):
    return re.sub(r"[-_.]+", "-", name).lower()


def parse_pypi(text):
    return {(norm_py(m.group(1)), m.group(2))
            for m in re.finditer(r"(?m)^([A-Za-z0-9][A-Za-z0-9._-]*)==([^\s;\\]+)", text)}


def parse_go(text):
    out = set()
    for line in text.splitlines():
        parts = line.split()
        if len(parts) == 3:
            out.add((parts[0], parts[1].removesuffix("/go.mod")))
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


def parse_npm(text):
    data, out = json.loads(text), set()
    for path, p in (data.get("packages") or {}).items():
        if path and "version" in p and not p.get("link"):
            out.add((path.rsplit("node_modules/", 1)[-1], p["version"]))
    for name, p in (data.get("dependencies") or {}).items():  # lockfile v1
        if "version" in p:
            out.add((name, p["version"]))
    return out


# ---- registries: (published, first release, signature note) ------------

def pypi_times(name, version):
    v = get_json(f"https://pypi.org/pypi/{name}/{version}/json")
    if v is None:
        raise Unreachable(f"PyPI has no {name}=={version}")
    files = v.get("urls") or []
    if not files:
        raise Unreachable(f"PyPI lists no files for {name}=={version}")
    published = min(iso(f["upload_time_iso_8601"]) for f in files)
    allv = get_json(f"https://pypi.org/pypi/{name}/json") or {}
    times = [iso(f["upload_time_iso_8601"]) for fs in (allv.get("releases") or {}).values() for f in fs]
    return published, (min(times) if times else published), [f["filename"] for f in files]


def pypi_signed(name, version, filenames):
    for fn in filenames:
        status, _, _ = http(f"https://pypi.org/integrity/{name}/{version}/{urllib.parse.quote(fn)}/provenance")
        if status == 200:
            return True
    return False


def go_escape(path):
    return re.sub(r"[A-Z]", lambda m: "!" + m.group(0).lower(), path)


def go_times(module, version):
    base = f"https://proxy.golang.org/{go_escape(module)}/@v"
    info = get_json(f"{base}/{version}.info")
    if info is None:
        raise Unreachable(f"the Go proxy has no {module}@{version}")
    published = iso(info["Time"])
    status, body, _ = http(f"{base}/list")
    versions = [v for v in body.decode().split() if v] if status == 200 else []
    first = published
    if versions:
        def key(v):
            return [int(x) if x.isdigit() else 0 for x in re.split(r"[.\-+]", v.lstrip("v"))[:3]]
        oldest = sorted(versions, key=key)[0]
        o = get_json(f"{base}/{oldest}.info")
        if o:
            first = min(first, iso(o["Time"]))
    return published, first, None


def maven_last_modified(group, artifact, version):
    url = f"https://repo1.maven.org/maven2/{group.replace('.', '/')}/{artifact}/{version}/{artifact}-{version}.pom"
    status, _, headers = http(url, method="HEAD")
    if status == 404 or not headers.get("Last-Modified"):
        raise Unreachable(f"Maven Central has no {group}:{artifact}:{version}")
    return parsedate_to_datetime(headers["Last-Modified"]).astimezone(UTC)


def maven_times(ga, version):
    group, artifact = ga.split(":", 1)
    published = maven_last_modified(group, artifact, version)
    status, body, _ = http(f"https://repo1.maven.org/maven2/{group.replace('.', '/')}/{artifact}/maven-metadata.xml")
    m = re.search(r"<version>([^<]+)</version>", body.decode()) if status == 200 else None
    first = published
    if m and m.group(1) != version:
        first = min(first, maven_last_modified(group, artifact, m.group(1)))
    return published, first, None


def npm_times(name, version):
    d = get_json(f"https://registry.npmjs.org/{name.replace('/', '%2F')}")
    if d is None or version not in (d.get("time") or {}):
        raise Unreachable(f"npm has no {name}@{version}")
    return iso(d["time"][version]), iso(d["time"]["created"]), None


TIMES = {"pypi": pypi_times, "go": go_times, "maven": maven_times, "npm": npm_times}
PARSE = {"pypi": parse_pypi, "go": parse_go, "maven": parse_maven, "npm": parse_npm}


def main(argv=None, now=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("ecosystem", choices=sorted(TIMES))
    ap.add_argument("base")
    ap.add_argument("pr")
    ap.add_argument("--skips", default="cooldown-skips.txt")
    ap.add_argument("--cooldown-days", type=int, default=7)
    ap.add_argument("--young-days", type=int, default=90)
    a = ap.parse_args(argv)
    now = now or dt.datetime.now(UTC)
    parse = PARSE[a.ecosystem]
    try:
        base = parse(open(a.base).read())
    except FileNotFoundError:
        base = set()
    pr = parse(open(a.pr).read())
    skips = {}
    try:
        for line in open(a.skips):
            line = line.split("#", 1)[0].split()
            if len(line) >= 2:
                skips[line[0]] = " ".join(line[1:])
    except FileNotFoundError:
        pass

    new = sorted(pr - base)
    on_main = {}
    for n, v in base:
        on_main.setdefault(n, v)
    fails = 0
    if not new:
        print("DEPS: no new package versions")
    for name, version in new:
        tag = f"{name}=={version}" if a.ecosystem == "pypi" else f"{name}@{version}"
        try:
            published, first, files = TIMES[a.ecosystem](name, version)
            age = (now - published).days
            if age < a.cooldown_days:
                if tag in skips:
                    print(f"SKIP     {tag}: published {age} days ago; cooldown skipped: {skips[tag]}")
                else:
                    print(f"FAIL     {tag}: published {age} days ago, under the {a.cooldown_days}-day cooldown")
                    fails += 1
            else:
                print(f"OK       {tag}: published {age} days ago")
            if (now - first).days < a.young_days:
                print(f"NEW-NAME {name}: first release {(now - first).days} days ago")
            if a.ecosystem == "pypi":
                signed = pypi_signed(name, version, files)
                old = on_main.get(name)
                if old and old != version and not signed:
                    _, _, old_files = pypi_times(name, old)
                    if pypi_signed(name, old, old_files):
                        print(f"FAIL     {tag}: {name}=={old} on main was signed by its publisher; this version isn't")
                        fails += 1
                        continue
                print(f"{'SIGNED' if signed else 'UNSIGNED':<8} {tag}")
        except Unreachable as e:
            print(f"FAIL     {tag}: registry not reachable or no answer ({e}): not passed on missing data")
            fails += 1
    print(f"DEPS: {len(new)} new, {fails} failing")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
