#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

python3 - "$ROOT" "${1:-$ROOT/.github/scripts/check-go-fuzz.sh}" <<'PY'
import re
import subprocess
import sys
import tempfile
from pathlib import Path

root = Path(sys.argv[1])
guard = Path(sys.argv[2])
prefix = "jobs:\n  go-fuzz:\n    steps:\n"
first = "      - name: first target\n        run: go test -fuzz=FuzzAlpha -fuzztime=30s ./services/alpha/\n"
second = "      - name: second target\n        run: go test -fuzz=FuzzBeta -fuzztime=30s ./services/beta/\n"
good = prefix + first + second
real_workflow = (root / ".github/workflows/ci.yml").read_text(encoding="utf-8")
real_sources = [(path.relative_to(root), path.read_text(encoding="utf-8")) for path in root.rglob("*_test.go")]

with tempfile.TemporaryDirectory(prefix="go-fuzz-test-", dir=root) as temporary:
    fixture = Path(temporary)
    workflow = fixture / ".github/workflows/ci.yml"
    workflow.parent.mkdir(parents=True)
    for name, package in [("FuzzAlpha", "alpha"), ("FuzzBeta", "beta")]:
        path = fixture / "services" / package / "fuzz_test.go"
        path.parent.mkdir(parents=True)
        path.write_text(f"package {package}\nimport \"testing\"\nfunc {name}(f *testing.F) {{}}\n", encoding="utf-8")

    def expect_status(expected, label, content=good, reason=""):
        workflow.write_text(content, encoding="utf-8")
        result = subprocess.run(["bash", str(guard), str(fixture)], text=True, capture_output=True)
        assert result.returncode == expected, f"{label}: got {result.returncode}, want {expected}\n{result.stdout}{result.stderr}"
        if expected:
            assert "AssertionError:" in result.stderr and reason in result.stderr, f"{label}: wrong failure\n{result.stderr}"
        print(f"PASS: {label}")

    expect_status(0, "both target steps run")
    expect_status(1, "removed target run", prefix + first, "FuzzBeta")
    expect_status(1, "YAML comment cannot supply flags", good.replace("-fuzz=FuzzBeta", "# -fuzz=FuzzBeta"), "expected exactly one")
    expect_status(1, "commented-out run cannot supply coverage", good.replace("        run: go test -fuzz=FuzzBeta", "        # run: go test -fuzz=FuzzBeta"), "FuzzBeta")
    expect_status(1, "disabled step cannot supply coverage", good.replace(second, second + "        if: false\n"), "FuzzBeta")
    expect_status(0, "explicit true condition", good.replace(second, second + "        if: true\n"))
    expect_status(1, "unknown condition fails closed", good.replace(second, second + "        if: success()\n"), "unsupported step condition")
    expect_status(1, "expression condition fails closed", good.replace(second, second + "        if: ${{ inputs.fuzz }}\n"), "unsupported step condition")

    for bound, reason in [
        ("0.1ns", "unsupported -fuzztime bound"),
        ("1.5s", "unsupported -fuzztime bound"),
        ("0s", "non-positive"),
        ("-1s", "non-positive"),
        ("1m30s", "unsupported -fuzztime bound"),
        ("30", "unsupported -fuzztime bound"),
        ("30x", "unsupported -fuzztime bound"),
    ]:
        expect_status(1, f"reject bound {bound}", good.replace("30s", bound), reason)

    # Hand-calculated adjacent int64-nanosecond boundaries discriminate each
    # unit conversion in both directions, including a smaller wrong factor.
    for unit, last_valid, first_invalid in [
        ("ns", "9223372036854775807", "9223372036854775808"),
        ("us", "9223372036854775", "9223372036854776"),
        ("ms", "9223372036854", "9223372036855"),
        ("s", "9223372036", "9223372037"),
        ("m", "153722867", "153722868"),
        ("h", "2562047", "2562048"),
    ]:
        expect_status(0, f"adjacent valid boundary {unit}", good.replace("30s", last_valid + unit))
        expect_status(1, f"just-over-limit boundary {unit}", good.replace("30s", first_invalid + unit), "overflow -fuzztime")
        expect_status(0, f"small valid bound {unit}", good.replace("30s", "1" + unit))

    for flag in ["-fuzztime=30s", "-fuzztime=1s", "-fuzz=FuzzAlpha", "-fuzz=FuzzBeta"]:
        reason = "duplicate -" + flag.split("=", 1)[0][1:]
        expect_status(1, f"duplicate or conflicting {flag}", good.replace(" ./services/alpha/", f" {flag} ./services/alpha/"), reason)
    for content in [good.replace("-fuzz=FuzzAlpha", "-args -fuzz=FuzzAlpha"), good.replace(" ./services/alpha/", " -args ./services/alpha/")]:
        expect_status(1, "-args placement", content, "unsupported -args")
    expect_status(1, "anchored selector rejected explicitly", good.replace("FuzzAlpha -fuzztime", "^FuzzAlpha$ -fuzztime"), "unsupported -fuzz selector")
    expect_status(1, "unsupported extra flag", good.replace("go test", "go test -v"), "unsupported go test flag")
    expect_status(1, "missing time bound", good.replace(" -fuzztime=30s", ""), "expected exactly one")
    expect_status(1, "empty run cannot supply coverage", good.replace("go test -fuzz=FuzzBeta -fuzztime=30s ./services/beta/", ""), "FuzzBeta")
    expect_status(1, "wrong package does not cover target", good.replace("./services/beta/", "./services/other/"), "FuzzBeta")
    expect_status(1, "package wildcard rejected", good.replace("./services/beta/", "./services/..."), "unsupported package path")
    expect_status(1, "shell wrapper rejected", good.replace("go test", "echo go test"), "expected bare go test")
    expect_status(1, "shell operator rejected", good.replace("go test", "true && go test"), "unsupported shell syntax")
    expect_status(1, "shell expansion rejected", good.replace("30s", "$(bound)"), "unsupported -fuzztime bound")
    expect_status(0, "flags in either order", good.replace("-fuzz=FuzzAlpha -fuzztime=30s", "-fuzztime=30s -fuzz=FuzzAlpha"))
    expect_status(0, "trailing comments allowed", good.replace("./services/beta/", "./services/beta/ # a comment"))
    expect_status(0, "literal run block", good.replace("run: go test", "run: |\n          go test"))
    expect_status(0, "comment-only literal line", good.replace("run: go test", "run: |\n          # comment\n          go test"))
    expect_status(0, "blank lines", good.replace(first, "\n" + first + "\n"))
    for indent in [0, 2, 4, 6, 8, 10]:
        for location, content in [("before steps", good.replace("    steps:", " " * indent + "# comment\n    steps:")), ("between steps", good.replace(second, " " * indent + "# comment\n" + second))]:
            expect_status(0, f"standalone comment at indent {indent} {location}", content)
    expect_status(0, "next job cannot corrupt scan", good + "  other:\n    steps:\n      - run: false\n")
    expect_status(1, "another job cannot supply coverage", prefix + first + "  other:\n    steps:\n" + second, "FuzzBeta")
    expect_status(0, "action metadata ignored", prefix + "      - uses: example/action\n        with:\n          arbitrary: value\n" + first + second)

    for label, content, reason in [
        ("missing job", good.replace("  go-fuzz:", "  other:"), "exactly one go-fuzz job"),
        ("duplicate job", good + good, "exactly one go-fuzz job"),
        ("missing steps", good.replace("    steps:", "    absent:"), "one go-fuzz steps list"),
        ("duplicate steps", good + "    steps:\n", "one go-fuzz steps list"),
        ("bad step structure", good.replace("      - name: first target", "        name: first target"), "unsupported steps structure"),
        ("bad run indentation", good + "          stray\n", "unsupported run indentation"),
        ("bad step field", good.replace("        run:", "        invalid field\n        run:"), "unsupported step field syntax"),
        ("working directory override", good.replace(second, second + "        working-directory: elsewhere\n"), "unsupported run-step field"),
        ("duplicate condition", good.replace(second, second + "        if: true\n        if: true\n"), "duplicate run-step field"),
        ("folded scalar", good.replace("run: go test", "run: >\n          go test"), "unsupported run scalar"),
        ("quoted scalar", good.replace("run: go test", "run: 'go test"), "unsupported run scalar"),
    ]:
        expect_status(1, label, content, reason)

    extra = fixture / "services/alpha/extra_test.go"
    extra.write_text("package alpha\nfunc FuzzNew(f *testing.F) {}\n", encoding="utf-8")
    expect_status(1, "new fuzz target requires command", reason="FuzzNew")
    extra.write_text('// func FuzzComment(f *testing.F) {}\n/*\nfunc FuzzBlock(f *testing.F) {}\n*/\nvar example = `\nfunc FuzzString(f *testing.F) {}\n`\n', encoding="utf-8")
    expect_status(0, "Go comments and strings are not targets")
    for path in fixture.rglob("*_test.go"):
        path.write_text("package empty\n", encoding="utf-8")
    expect_status(1, "empty inventory fails closed", reason="empty Go fuzz target inventory")

    for relative, source in real_sources:
        if re.search(r"(?m)^func Fuzz", source):
            path = fixture / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(source, encoding="utf-8")
    expect_status(0, "both real target steps run", real_workflow)
    job = re.search(r"(?ms)^  go-fuzz:\n(.*?)(?=^  \S|\Z)", real_workflow).group(1)
    real_runs = re.findall(r"(?m)^        run: go test -fuzz=(\w+) -fuzztime=\S+ \S+\n", job)
    assert real_runs, "expected real fuzz commands for removal checks"
    for name in real_runs:
        without_run = re.sub(r"(?m)^        run: go test -fuzz=" + name + r" -fuzztime=\S+ \S+\n", "", real_workflow)
        expect_status(1, f"removed real run: {name}", without_run, name)

print("All Go fuzz guard regression cases passed.")
PY
