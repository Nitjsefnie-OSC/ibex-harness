#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

python3 - "${1:-$ROOT}" <<'PY'
import re
import sys
from pathlib import Path

# Supported grammar: two-space job IDs, four-space job fields, six-space steps,
# eight-space step fields; run: plain single-line or literal | (ten-space lines).
# Commands are bare `go test -fuzz=Name -fuzztime=Nu ./package/` (flags in either
# order), Name=Fuzz[A-Z0-9_]\w*, N=positive integer, u=ns|us|ms|s|m|h, <= int64 ns.
# Only absent/true/false step conditions; false supplies no coverage. Trailing
# whitespace-separated # comments are allowed. Anchors, compound/fractional
# durations, other flags, shell syntax and other run-step fields fail loudly.


def require(condition, reason):
    if not condition:
        raise AssertionError(reason)


def inventory(root):
    targets = set()
    # Remove Go comments and literals so examples cannot invent fuzz targets.
    literals = r'//[^\n]*|/\*.*?\*/|"(?:\\.|[^"\\])*"|`[^`]*`|\'(?:\\.|[^\'\\])*\''
    for path in root.rglob("*_test.go"):
        source = re.sub(literals, " ", path.read_text(encoding="utf-8"), flags=re.S)
        for name in re.findall(r"(?m)^\s*func\s+(Fuzz[A-Z0-9_]\w*)\s*\(", source):
            targets.add((name, "./" + path.parent.relative_to(root).as_posix()))
    require(targets, "empty Go fuzz target inventory")
    return targets


def job_steps(workflow):
    # Full-line comments have no YAML structure, regardless of indentation.
    lines = [line for line in workflow.splitlines() if line.strip() and not line.lstrip().startswith("#")]
    starts = [i for i, line in enumerate(lines) if line == "  go-fuzz:"]
    require(len(starts) == 1, "expected exactly one go-fuzz job")
    job = []
    for line in lines[starts[0] + 1:]:
        if len(line) - len(line.lstrip()) <= 2:
            break
        job.append(line)
    require(job.count("    steps:") == 1, "expected one go-fuzz steps list")
    steps, current = [], None
    for line in job[job.index("    steps:") + 1:]:
        indent = len(line) - len(line.lstrip())
        if indent == 4:
            break
        if line.startswith("      - "):
            current = [line[8:]]
            steps.append(current)
        else:
            require(current is not None and indent >= 8, "unsupported steps structure")
            current.append(line[8:])
    return steps


def commands(step):
    # Action metadata is irrelevant to this assertion; inspect only run steps.
    if not any(line.startswith("run:") for line in step):
        return []
    fields, body = {}, []
    for line in step:
        if line.startswith("  "):
            require(fields.get("run") == "|", "unsupported run indentation")
            body.append(line[2:])
            continue
        match = re.fullmatch(r"([a-z-]+):\s*(.*)", line)
        require(match is not None, "unsupported step field syntax")
        key, value = match.groups()
        require(key in {"name", "if", "run"}, "unsupported run-step field: " + key)
        require(key not in fields, "duplicate run-step field: " + key)
        fields[key] = re.split(r"\s+#", value, maxsplit=1)[0].strip()
        if key == "run":
            run = fields[key]
            require(run == "|" or not run.startswith(("|", ">", "'", '"')), "unsupported run scalar")
    condition = fields.get("if", "true")
    require(condition in {"true", "false"}, "unsupported step condition: " + condition)
    if condition == "false":
        return []
    run = fields["run"]
    return body if run == "|" else [run]


def target_for(command):
    command = re.split(r"\s+#", command, maxsplit=1)[0].strip()
    if not command or command.startswith("#"):
        return None
    require(not re.search(r"[^A-Za-z0-9_./=^$*+?()\[\]{}|:\s-]", command), "unsupported shell syntax")
    words = command.split()
    require(words[:2] == ["go", "test"], "unsupported command: expected bare go test")
    require("-args" not in words, "unsupported -args: fuzz flags must reach go test")
    flags = {}
    for word in words[2:-1]:
        match = re.fullmatch(r"-(fuzz|fuzztime)=(.*)", word)
        require(match is not None, "unsupported go test flag: " + word)
        key, value = match.groups()
        require(key not in flags, "duplicate -" + key + " flag")
        flags[key] = value
    require(set(flags) == {"fuzz", "fuzztime"}, "expected exactly one -fuzz and one -fuzztime")
    name = flags["fuzz"]
    require(re.fullmatch(r"Fuzz[A-Z0-9_]\w*", name), "unsupported -fuzz selector: " + name)
    bound = flags["fuzztime"]
    match = re.fullmatch(r"(-?[0-9]+)(ns|us|ms|s|m|h)", bound)
    require(match is not None, "unsupported -fuzztime bound (integer single-unit duration required): " + bound)
    amount, unit = match.groups()
    factors = {"ns": 1, "us": 1000, "ms": 1000000, "s": 1000000000, "m": 60000000000, "h": 3600000000000}
    duration = int(amount) * factors[unit]
    require(duration > 0, "non-positive -fuzztime bound: " + bound)
    require(duration <= 9223372036854775807, "overflow -fuzztime bound: " + bound)
    package = words[-1]
    require(re.fullmatch(r"\./[A-Za-z0-9_-]+(?:/[A-Za-z0-9_-]+)*/?", package), "unsupported package path: " + package)
    return name, package.rstrip("/")


try:
    root = Path(sys.argv[1]).resolve()
    targets = inventory(root)
    workflow = (root / ".github/workflows/ci.yml").read_text(encoding="utf-8")
    covered = set()
    for step in job_steps(workflow):
        for command in commands(step):
            target = target_for(command)
            if target is not None:
                covered.add(target)
    missing = sorted(targets - covered)
    require(not missing, "go-fuzz lacks bounded commands for: " + ", ".join(f"{name} ({package})" for name, package in missing))
    print(f"All {len(targets)} Go fuzz targets have bounded go-fuzz commands.")
except AssertionError as error:
    print(f"AssertionError: {error}", file=sys.stderr)
    sys.exit(1)
PY
