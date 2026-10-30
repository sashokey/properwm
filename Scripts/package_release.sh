#!/usr/bin/env bash
set -euo pipefail

[[ "${GITHUB_ACTIONS:-}" == "true" ]] || { echo "Build packages through GitHub Actions."; exit 1; }

PROPERWM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROPERWM_ROOT"
VERSION="${PROPERWM_VERSION:-$(python3 -c 'import json; print(json.load(open(".github/release.json"))["version"])')}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Version must be X.Y.Z"; exit 1; }
mkdir -p build dist

xcodebuild build \
  -project ProperWM.xcodeproj \
  -scheme ProperWM \
  -configuration Release \
  -derivedDataPath build/ReleaseDerivedData \
  -destination 'generic/platform=macOS' \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  CLANG_ENABLE_CODE_COVERAGE=NO CLANG_COVERAGE_MAPPING=NO \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$GITHUB_RUN_NUMBER" \
  2>&1 | tee build/xcodebuild-release.log

APP="build/ReleaseDerivedData/Build/Products/Release/ProperWM.app"
BINARY="$APP/Contents/MacOS/ProperWM"
test -x "$BINARY"
cp LICENSE NOTICE "$APP/Contents/Resources/"
/usr/libexec/PlistBuddy -c "Add :ProperWMSourceRevision string $GITHUB_SHA" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :ProperWMBuildURL string $GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID" "$APP/Contents/Info.plist"

source Scripts/lib/release_binary.sh
strip_release_binary "$BINARY"
verify_release_binary "$BINARY"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"

python3 - "$APP" "$VERSION" <<'PY'
import pathlib
import plistlib
import sys

app = pathlib.Path(sys.argv[1])
with (app / "Contents/Info.plist").open("rb") as source:
    info = plistlib.load(source)
assert info["CFBundleIdentifier"] == "io.github.sashokey.properwm"
assert info["CFBundleName"] == "ProperWM"
assert info["CFBundleExecutable"] == "ProperWM"
assert info["CFBundleShortVersionString"] == sys.argv[2]
assert "NSAppleEventsUsageDescription" not in info
assert not any(key.startswith("SU") for key in info)
assert not (app / "Contents/Frameworks/Sparkle.framework").exists()
for notice in ["LICENSE", "NOTICE"]:
    assert (app / "Contents/Resources" / notice).is_file()
PY

ditto -c -k --sequesterRsrc --keepParent "$APP" "dist/ProperWM-$VERSION.zip"
git archive --format=zip --prefix="ProperWM-$VERSION-source/" \
  --output="dist/ProperWM-$VERSION-source.zip" "$GITHUB_SHA"

cd dist
shasum -a 256 "ProperWM-$VERSION.zip" "ProperWM-$VERSION-source.zip" > SHA256SUMS.txt
shasum -a 256 -c SHA256SUMS.txt
