#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

python3 - "${1:-$ROOT}" <<'PY'
import re
import sys
import unicodedata
from pathlib import Path

# Supported grammar: root jobs mapping, two-space job IDs, four-space job fields, six-space steps,
# eight-space step fields; run: plain single-line or literal | (ten-space lines).
# Commands are bare `go test -fuzz=Name -fuzztime=Nu ./package/` (flags in either
# order), Name=Fuzz[A-Z0-9_][A-Za-z0-9_]*, N=positive integer, u=ns|us|ms|s|m|h,
# <= int64 ns.
# Only absent/true/false step conditions; false supplies no coverage. Trailing
# whitespace-separated # comments are allowed. Anchors, compound/fractional
# durations, other flags, shell syntax and other run-step fields fail loudly.
# Block scalar contents are not mapping keys; quoted YAML scalars must fit one line.
# YAML keys match [A-Za-z_][A-Za-z0-9_.-]*,
# with optional spaces/tabs before the colon and whitespace after it. Outside
# scalar bodies, only mapping entries and sequence items are modeled. Anchors,
# tags, aliases, complex/quoted keys and uncertain scalar forms fail closed.
# Inline collections are limited to {} and single-line lists of bare tokens.
# Inventory uses Go's Fuzz/non-lowercase suffix rule; names outside the ASCII
# command grammar are explicitly unsupported, including the bare name Fuzz.
# Each accepted selector must regex-match exactly one discovered name in its package.


def require(condition, reason):
    if not condition:
        raise AssertionError(reason)


def inventory(root):
    targets = set()
    # Remove Go comments and literals so examples cannot invent fuzz targets.
    literals = r'//[^\n]*|/\*.*?\*/|"(?:\\.|[^"\\])*"|`[^`]*`|\'(?:\\.|[^\'\\])*\''
    for path in root.rglob("*_test.go"):
        source = re.sub(literals, " ", path.read_text(encoding="utf-8"), flags=re.S)
        tokens = re.findall(r"\w+|[{}()]", source)
        depth = 0
        for index, token in enumerate(tokens):
            if token == "{":
                depth += 1
            elif token == "}":
                depth -= 1
            elif depth == 0 and token == "func" and index + 2 < len(tokens) and tokens[index + 2] == "(":
                name = tokens[index + 1]
                if name.startswith("Fuzz") and (len(name) == 4 or unicodedata.category(name[4]) != "Ll"):
                    require(re.fullmatch(r"Fuzz[A-Z0-9_][A-Za-z0-9_]*", name), "unsupported fuzz target name: " + name)
                    targets.add((name, "./" + path.parent.relative_to(root).as_posix()))
    require(targets, "empty Go fuzz target inventory")
    return targets


def yaml_structure(workflow):
    # Full-line comments have no YAML structure, regardless of indentation.
    lines = [line for line in workflow.splitlines() if line.strip() and not line.lstrip().startswith("#")]
    structure, index = [], 0
    while index < len(lines):
        line = lines[index]
        index += 1
        match = re.fullmatch(r"( *)(- )?([A-Za-z_][A-Za-z0-9_.-]*)[ \t]*:(?:[ \t]+(.*)|$)", line)
        if match is None:
            item = re.fullmatch(r"( *)- (.*)", line)
            require(item is not None, "unsupported YAML key or line")
            prefix, key, value = item[1] + "- ", None, item[2].strip()
        else:
            prefix, key, value = match[1] + (match[2] or ""), match[3], (match[4] or "").strip()
        require(not value.startswith(("&", "!", "*")), "unsupported YAML scalar property")
        if value.startswith(("'", '"')):
            require(re.fullmatch(r"'(?:[^']|'')*'\s*(?:#.*)?", value) or
                    re.fullmatch(r'"(?:[^"\\]|\\.)*"\s*(?:#.*)?', value),
                    "unsupported multiline quoted YAML scalar")
        else:
            value = re.split(r"(?:^|\s+)#", value, maxsplit=1)[0].rstrip()
            if value.startswith(("[", "{")):
                require(value == "{}" or re.fullmatch(r"\[(?:[A-Za-z0-9_./-]+(?:[ \t]*,[ \t]*[A-Za-z0-9_./-]+)*)?\]", value),
                        "unsupported YAML flow scalar")
            require(not value.startswith(("?", ":", "%", "@", "`")), "unsupported YAML key or line")
        structure.append(prefix + (key + ":" if key is not None else "") + (" " if key and value else "") + value)
        if value.startswith(("|", ">")):
            require(re.fullmatch(r"[|>](?:[1-9][+-]?|[+-][1-9]?)?", value), "unsupported YAML block scalar")
            indent = len(prefix)
            body = []
            while index < len(lines) and len(lines[index]) - len(lines[index].lstrip()) > indent:
                body.append(lines[index])
                index += 1
            if key == "run":
                structure.extend(body)
    return structure


def job_steps(workflow):
    lines = yaml_structure(workflow)
    roots = [i for i, line in enumerate(lines) if line == "jobs:"]
    require(len(roots) == 1, "expected exactly one root jobs mapping")
    jobs = []
    for line in lines[roots[0] + 1:]:
        if not line.startswith(" "):
            break
        jobs.append(line)
    lines = jobs
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
                selector, package = target
                matches = sorted(name for name, directory in targets if directory == package and re.search(selector, name))
                require(len(matches) <= 1, "ambiguous -fuzz selector: " + selector + " (" + package + "): " + ", ".join(matches))
                require(matches, "no matching Go fuzz target for -fuzz selector: " + selector + " (" + package + ")")
                covered.add((matches[0], package))
    missing = sorted(targets - covered)
    require(not missing, "go-fuzz lacks bounded commands for: " + ", ".join(f"{name} ({package})" for name, package in missing))
    print(f"All {len(targets)} Go fuzz targets have bounded go-fuzz commands.")
except AssertionError as error:
    print(f"AssertionError: {error}", file=sys.stderr)
    sys.exit(1)
PY
