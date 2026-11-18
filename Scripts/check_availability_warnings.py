import argparse
import pathlib
import re
import sys

PATTERN = re.compile(r"is only available in macOS")
SOURCE = re.compile(r"/(App|Core|Platform|Tests|Tools|UI)/[^ ]*\.swift")


def availability_warnings(logs):
    hits = []
    for log in logs:
        for line in log.read_text(errors="replace").splitlines():
            if PATTERN.search(line) and SOURCE.search(line):
                hits.append(line.strip())
    return list(dict.fromkeys(hits))


def main():
    parser = argparse.ArgumentParser(
        description="Reject source code requiring a newer macOS than the deployment target."
    )
    parser.add_argument("logs", nargs="+", type=pathlib.Path)
    args = parser.parse_args()
    try:
        hits = availability_warnings(args.logs)
    except OSError as error:
        print(f"Cannot read build log: {error}", file=sys.stderr)
        return 1
    if hits:
        print("Deployment availability violations:", file=sys.stderr)
        for line in hits:
            print(line, file=sys.stderr)
        return 1
    print(f"No deployment availability violations in {len(args.logs)} build logs.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
