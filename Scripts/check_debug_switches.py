#!/usr/bin/env python3
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parent.parent
REGISTRY = ROOT / "Core/Support/DebugSwitch.swift"
SOURCE_DIRS = ("App", "Core", "Platform")
SUPPORT_DIRS = ("Tests", "Tools", "Scripts")
SUPPORT_SUFFIXES = {".py", ".sh", ".swift"}
CASE = re.compile(r'^\s*case\s+(\w+)\s*=\s*"(DOCK_[A-Z0-9_]+)"', re.M)
LITERAL = re.compile(r'"(DOCK_[A-Z0-9_]+)"')
NAME = re.compile(r"\bDOCK_[A-Z0-9_]+\b")
REFERENCE = re.compile(r"\bDebugSwitch\.(\w+)\b")


def files_in(directories, suffixes):
    for directory in directories:
        for path in sorted((ROOT / directory).rglob("*")):
            if path.suffix in suffixes and path.is_file():
                yield path


def main() -> int:
    registered = {raw: case for case, raw in CASE.findall(REGISTRY.read_text())}
    if not registered:
        print(f"{REGISTRY.relative_to(ROOT)} defines no debug switches")
        return 1

    problems = []
    referenced = set()
    for path in files_in(SOURCE_DIRS, {".swift"}):
        if path == REGISTRY:
            continue
        for number, line in enumerate(path.read_text().splitlines(), 1):
            referenced.update(REFERENCE.findall(line))
            for name in LITERAL.findall(line):
                replacement = (
                    f"DebugSwitch.{registered[name]}"
                    if name in registered else "a registered DebugSwitch case"
                )
                problems.append(f'{path.relative_to(ROOT)}:{number}: use {replacement} for "{name}"')

    for path in files_in(SUPPORT_DIRS, SUPPORT_SUFFIXES):
        if path == Path(__file__).resolve():
            continue
        for number, line in enumerate(path.read_text(errors="ignore").splitlines(), 1):
            for name in NAME.findall(line):
                if name not in registered:
                    problems.append(f"{path.relative_to(ROOT)}:{number}: unregistered switch {name}")

    for name, case in registered.items():
        if case not in referenced:
            problems.append(f"{REGISTRY.relative_to(ROOT)}: unused switch {name} (.{case})")

    if problems:
        print("\n".join(problems))
        return 1
    print(f"Validated {len(registered)} debug switches.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
