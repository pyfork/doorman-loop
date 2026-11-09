#!/usr/bin/env python3
# kit-keeper-Opus5.5-agent, 2026-10-26
# Unit test for guards/stacks/check-new-deps.py with the registries
# stubbed: nothing new passes; a registry that can't be reached fails;
# a young package name is reported; a PyPI signature that disappears
# between main's version and the PR's fails; the cooldown and its named
# skip hold. Run from the repo root: python3 -I guards/tests/check-new-deps-test.py
import contextlib, datetime as dt, importlib.util, io, os, sys, tempfile

sys.dont_write_bytecode = True  # no __pycache__ next to the script under test
spec = importlib.util.spec_from_file_location("deps", os.path.join(os.getcwd(), "guards/stacks/check-new-deps.py"))
deps = importlib.util.module_from_spec(spec)
spec.loader.exec_module(deps)
UTC = dt.timezone.utc
NOW = dt.datetime(2026, 10, 26, tzinfo=UTC)
days = lambda n: NOW - dt.timedelta(days=n)
fails = 0
work = tempfile.mkdtemp()


def write(name, text):
    p = os.path.join(work, name)
    open(p, "w").write(text)
    return p


def run(base, pr, times=None, signed=None, skips=""):
    """Run main() on two pypi locks, registries stubbed; (rc, output)."""
    def fake_times(name, version):
        t = (times or {}).get((name, version))
        if t is None:
            raise deps.Unreachable(f"{name}=={version}: connection refused")
        return t[0], t[1], [f"{name}-{version}.whl"]
    deps.TIMES["pypi"] = fake_times
    deps.pypi_times = fake_times
    deps.pypi_signed = lambda n, v, f: (n, v) in (signed or set())
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        rc = deps.main(["pypi", write("b.lock", base), write("p.lock", pr), "--skips", write("s.txt", skips)], now=NOW)
    return rc, out.getvalue()


def expect(tid, rc, out, want_rc, text):
    global fails
    if rc == want_rc and text in out:
        print(f"PASS {tid}: {text}")
    else:
        print(f"FAIL {tid}: expected rc={want_rc} with '{text}', got rc={rc}:")
        print("    " + out.replace("\n", "\n    "))
        fails = 1


base = "pytest==8.3.5 \\\n    --hash=sha256:a\n"
expect("T1", *run(base, base), 0, "DEPS: no new package versions")
pr = base + "requests==2.32.3 \\\n    --hash=sha256:b\n"
expect("T2", *run(base, pr, times={("requests", "2.32.3"): (days(400), days(5000))}), 0, "OK       requests==2.32.3: published 400 days ago")
expect("T3", *run(base, pr, times={}), 1, "registry not reachable or no answer")
expect("T4", *run(base, pr, times={("requests", "2.32.3"): (days(3), days(5000))}), 1, "under the 7-day cooldown")
expect("T5", *run(base, pr, times={("requests", "2.32.3"): (days(3), days(5000))}, skips="requests==2.32.3 GHSA-xxxx\n"), 0, "cooldown skipped: GHSA-xxxx")
young = base + "reqeusts==0.1.0 \\\n    --hash=sha256:c\n"
expect("T6", *run(base, young, times={("reqeusts", "0.1.0"): (days(20), days(20))}), 0, "NEW-NAME reqeusts: first release 20 days ago")
old = "urllib3==2.7.0 \\\n    --hash=sha256:d\n"
bump = "urllib3==2.8.0 \\\n    --hash=sha256:e\n"
t = {("urllib3", "2.7.0"): (days(80), days(5000)), ("urllib3", "2.8.0"): (days(40), days(5000))}
expect("T7", *run(old, bump, times=t, signed={("urllib3", "2.7.0")}), 1, "on main was signed by its publisher; this version isn't")
expect("T8", *run(old, bump, times=t, signed={("urllib3", "2.7.0"), ("urllib3", "2.8.0")}), 0, "SIGNED   urllib3==2.8.0")
expect("T9", *run(old, bump, times=t, signed=set()), 0, "UNSIGNED urllib3==2.8.0")

# Parsers on real lock shapes
go = deps.parse_go("github.com/a/b v1.0.0 h1:x\ngithub.com/a/b v1.0.0/go.mod h1:y\n")
maven = deps.parse_maven('{"dependencies":[{"groupId":"g","artifactId":"a","version":"1","children":[{"groupId":"g","artifactId":"c","version":"2","children":[]}]}],"mavenPlugins":[{"groupId":"p","artifactId":"q","version":"3"}]}')
npm = deps.parse_npm('{"packages":{"":{},"node_modules/@s/x":{"version":"1.0.0"},"node_modules/a/node_modules/b":{"version":"2.0.0"},"node_modules/l":{"link":true,"version":"0"}}}')
for tid, got, want in [("T10 go.sum", go, {("github.com/a/b", "v1.0.0")}),
                       ("T11 lockfile.json", maven, {("g:a", "1"), ("g:c", "2"), ("p:q", "3")}),
                       ("T12 package-lock", npm, {("@s/x", "1.0.0"), ("b", "2.0.0")})]:
    if got == want:
        print(f"PASS {tid}: {sorted(got)}")
    else:
        print(f"FAIL {tid}: {sorted(got)} != {sorted(want)}"); fails = 1
print("check-new-deps-test: all passed" if not fails else "check-new-deps-test: FAILED")
sys.exit(fails)
