#!/usr/bin/env python3
# guard-builder-Opus5.5-agent, 2026-10-26
# Unit test for guards/templates/.github/scripts/scan-locks.py with OSV
# stubbed: every lock kind is found and parsed; a hit is reported once per
# advisory (aliases merged) with its fixed version; a withdrawn advisory is
# dropped; a clean lock exits 0; OSV unreachable, a short answer, a second
# page or a lock that doesn't parse exits 2, never 0.
# Run from the repo root: python3 -I guards/tests/scan-locks-test.py
import contextlib, importlib.util, io, json, os, subprocess, sys, tempfile

sys.dont_write_bytecode = True  # no __pycache__ next to the script under test
spec = importlib.util.spec_from_file_location("scan", os.path.join(os.getcwd(), "guards/templates/.github/scripts/scan-locks.py"))
scan = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scan)
fails = 0


def expect(name, cond, got=""):
    global fails
    if cond:
        print(f"PASS {name}")
    else:
        print(f"FAIL {name}: {got}")
        fails += 1


def repo(files):
    d = tempfile.mkdtemp()
    subprocess.run(["git", "init", "-q", d], check=True)
    for path, text in files.items():
        os.makedirs(os.path.dirname(os.path.join(d, path)) or d, exist_ok=True)
        open(os.path.join(d, path), "w").write(text)
    subprocess.run(["git", "-C", d, "add", "-A"], check=True)
    return d


def stub(vulns=None, details=None, down=False, short=False, page=False):
    """OSV stand-in: vulns {(eco, name, version): [ids]}, details {id: advisory}."""
    asked = []

    def fake(url, body=None):
        if down:
            raise scan.Unreachable(f"{url}: connection refused")
        if url.endswith("/querybatch"):
            qs = body["queries"]
            asked.extend((q["package"]["ecosystem"], q["package"]["name"], q["version"]) for q in qs)
            res = [{"vulns": [{"id": i} for i in (vulns or {}).get((q["package"]["ecosystem"], q["package"]["name"], q["version"]), [])]} for q in qs]
            if page and res:
                res[0]["next_page_token"] = "x"
            return {"results": res[:-1] if short else res}
        return (details or {})[url.rsplit("/", 1)[1]]
    scan.http_json = fake
    return asked


def run(root):
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        rc = scan.main([root])
    return rc, out.getvalue()


PYLOCK = "# header\nflask==3.1.1 \\\n    --hash=sha256:aa\nPyTest==8.3.5 \\\n    --hash=sha256:bb\n    # via -r requirements.in\n"
GOMOD = """module example.com/app

go 1.24

require github.com/go-chi/chi/v5 v5.2.1 // indirect note

require (
\tgithub.com/google/uuid v1.6.0
\t// golang.org/x/old v0.1.0
\tgolang.org/x/net v0.38.0 // indirect
)
"""
NPM = json.dumps({"lockfileVersion": 3, "packages": {"": {"name": "app"}, "node_modules/lodash": {"version": "4.17.20"},
                  "node_modules/a/node_modules/@s/x": {"version": "1.0.0"}, "node_modules/local": {"link": True, "version": "0"}}})
MAVEN = json.dumps({"dependencies": [{"groupId": "org.apache.logging.log4j", "artifactId": "log4j-core", "version": "2.14.1",
                    "children": [{"groupId": "org.apache.logging.log4j", "artifactId": "log4j-api", "version": "2.14.1"}]}]})
GRADLE = "# This is a Gradle generated file\ncom.google.guava:guava:33.0.0-jre=compileClasspath,runtimeClasspath\nempty=annotationProcessor\n"
ALL = {"requirements.lock": PYLOCK, "requirements-checks.lock": "ruff==0.9.0 \\\n    --hash=sha256:cc\n",
       "go.mod": GOMOD, "web/package-lock.json": NPM, "lockfile.json": MAVEN, "gradle.lockfile": GRADLE,
       "requirements.in": "flask\n", "go.sum": "github.com/x/y v1.0.0 h1:zz\n"}

# T1: every lock kind is found and parsed, nothing else is asked about
root = repo(ALL)
asked = stub()
rc, out = run(root)
want = {("PyPI", "flask", "3.1.1"), ("PyPI", "pytest", "8.3.5"), ("PyPI", "ruff", "0.9.0"),
        ("Go", "github.com/go-chi/chi/v5", "v5.2.1"), ("Go", "github.com/google/uuid", "v1.6.0"), ("Go", "golang.org/x/net", "v0.38.0"),
        ("npm", "lodash", "4.17.20"), ("npm", "@s/x", "1.0.0"),
        ("Maven", "org.apache.logging.log4j:log4j-core", "2.14.1"), ("Maven", "org.apache.logging.log4j:log4j-api", "2.14.1"),
        ("Maven", "com.google.guava:guava", "33.0.0-jre")}
expect("T1 every lock kind parsed, nothing extra", set(asked) == want, sorted(set(asked) ^ want))
expect("T2 nothing known: exit 0, prints nothing", rc == 0 and out == "", (rc, out))

# T3: a hit, two ids that alias each other, one line with the fixed version
adv = lambda aliases, fixed, eco="PyPI", name="pytest", **kw: {"summary": "pytest has vulnerable tmpdir handling", "aliases": aliases,
      "database_specific": {"severity": "MODERATE"}, "affected": [{"package": {"ecosystem": eco, "name": name},
      "ranges": [{"type": "ECOSYSTEM", "events": [{"introduced": "0"}, {"fixed": fixed}]}]}], **kw}
stub({("PyPI", "pytest", "8.3.5"): ["PYSEC-2026-1845", "GHSA-6w46-j5rx-g56g"]},
     {"GHSA-6w46-j5rx-g56g": adv(["PYSEC-2026-1845"], "9.0.3"), "PYSEC-2026-1845": adv(["GHSA-6w46-j5rx-g56g"], "9.0.3")})
rc, out = run(root)
lines = out.splitlines()
expect("T3 a hit exits 1", rc == 1, rc)
expect("T4 aliases merged into one line", len(lines) == 1 and "(also PYSEC-2026-1845)" in lines[0], out)
expect("T5 the line names package, version, lock, severity and fix",
       lines and all(s in lines[0] for s in ("`pytest` 8.3.5", "`requirements.lock`", "(moderate)", "fixed in 9.0.3",
                                               "https://osv.dev/vulnerability/GHSA-6w46-j5rx-g56g")), out)

# T6: a withdrawn advisory is not reported; an advisory with no fix says so
stub({("npm", "lodash", "4.17.20"): ["GHSA-old"], ("Go", "golang.org/x/net", "v0.38.0"): ["GO-2026-1"]},
     {"GHSA-old": adv([], "4.17.21", "npm", "lodash", withdrawn="2026-01-01T00:00:00Z"),
      "GO-2026-1": {"summary": "x/net: a bug", "affected": [{"package": {"ecosystem": "Go", "name": "golang.org/x/net"}, "ranges": []}]}})
rc, out = run(root)
expect("T6 withdrawn dropped, no-fix named", rc == 1 and "lodash" not in out and "no fixed version yet" in out and "GO-2026-1" in out, out)
stub({("npm", "lodash", "4.17.20"): ["GHSA-old"]}, {"GHSA-old": adv([], "4.17.21", "npm", "lodash", withdrawn="2026-01-01T00:00:00Z")})
expect("T7 only withdrawn advisories: exit 0", run(root)[0] == 0)

# T8 to T10: a scan that can't finish never reads as clean
stub(down=True)
rc, out = run(root)
expect("T8 OSV unreachable: exit 2, says so", rc == 2 and "OSV couldn't be asked" in out, (rc, out))
stub(short=True)
expect("T9 an answer shorter than the question: exit 2", run(root)[0] == 2)
stub(page=True)
expect("T10 more than one page of results: exit 2", run(root)[0] == 2)

# T11: a lock that doesn't parse: exit 2
stub()
rc, out = run(repo({"package-lock.json": "{not json"}))
expect("T11 a broken lock: exit 2, says so", rc == 2 and "couldn't be read" in out, (rc, out))

# T12: no lock at all: exit 0, nothing asked
asked = stub()
rc, out = run(repo({"README.md": "hi\n"}))
expect("T12 no lock: exit 0, OSV not asked", rc == 0 and asked == [] and out == "", (rc, asked, out))

# T13: an untracked lock is not scanned (main's tracked files only)
root2 = repo({"requirements.lock": "a==1.0 \\\n    --hash=sha256:dd\n"})
open(os.path.join(root2, "package-lock.json"), "w").write(NPM)
asked = stub()
run(root2)
expect("T13 untracked lock ignored", asked == [("PyPI", "a", "1.0")], asked)

print("scan-locks-test: all passed" if fails == 0 else f"scan-locks-test: {fails} failed")
sys.exit(1 if fails else 0)
