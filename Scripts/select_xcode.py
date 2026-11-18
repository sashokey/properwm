import pathlib
import re
import sys

STABLE_NAME = re.compile(r"Xcode_(\d+(?:\.\d+)*)\.app")


def newest_stable_xcode(applications: pathlib.Path) -> pathlib.Path:
    candidates = {}
    for alias in applications.glob("Xcode*.app"):
        path = alias.resolve()
        match = STABLE_NAME.fullmatch(path.name)
        if not match or not path.is_dir():
            continue
        version = tuple(int(part) for part in match.group(1).split("."))
        if version[0] < 27:
            continue
        normalized = version + (0,) * (3 - len(version))
        candidates[path] = normalized
    if not candidates:
        raise ValueError("No stable Xcode 27 or newer is installed")
    return max(candidates, key=lambda path: (candidates[path], str(path)))


if __name__ == "__main__":
    try:
        print(newest_stable_xcode(pathlib.Path("/Applications")))
    except ValueError as error:
        print(error, file=sys.stderr)
        sys.exit(1)
