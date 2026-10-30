#!/usr/bin/env bash
# 构建 Release 版并用 **Developer ID 证书**签名后装进 /Applications，供 owner 日常使用
# 兼验收。
#
# 为什么需要这个脚本：
#   1. 日常包必须是 Release。Debug 没有编译器优化，最小化这类时序/动画敏感的操作
#      手感明显变差，曾被误判成版本回归（2026-07-26 的教训）。
#   2. 签名身份必须固定。系统的辅助功能授权绑的是代码身份，临时（ad-hoc）签名只能
#      拿每次构建都变的 CDHash 当身份 —— 每装一次新版授权就失配一次，而系统设置里
#      那条看着还是开的。
#   3. 开发构建与正式包 **bundle id 相同**，会抢同一条权限记录：两边身份不一致就
#      互相作废。所以 build_and_run.sh 必须和本脚本用同一张证书。
#
# 2026-08-19 起用 Developer ID 而不是自建的本地证书：它的 designated requirement
# 绑的是团队 OU（不是 CDHash），跨重建、跨版本都稳定，而且与用户下载到的发布包
# **身份完全一致** —— 于是本机验收出来的权限行为就是用户的真实行为。
#
# 与 package_release.sh 的分工：那个出对外发布的包（额外做公证 + Gatekeeper 评估），
# 这个只装本机、不公证（本机构建没有 quarantine 标记，Gatekeeper 不拦；公证一次
# 要几十分钟，日常安装扛不住）。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT/macos-dock-cc-v2.xcodeproj"
SCHEME="macos-dock-cc-v2"
BUILT_NAME="macos-dock-cc-v2"
APP_NAME="Tungsten Edge"
DEST="/Applications/$APP_NAME.app"
ENTITLEMENTS="$ROOT/Resources/TungstenEdge.entitlements"
DD="$ROOT/build/LocalReleaseDD"
PRODUCTS="$DD/Build/Products/Release"

DEVELOPER_ID="${DEVELOPER_ID_APPLICATION:-Developer ID Application: Suzhou Mubai Creativity Design Co., Ltd. (DRPT2MJQD5)}"
FALLBACK_IDENTITY="macos-dock-cc Local Code Signing"

[[ -f "$ENTITLEMENTS" ]] || { echo "error: 找不到 entitlements：$ENTITLEMENTS" >&2; exit 1; }

# strip_release_binary / verify_release_binary, shared with package_release.sh.
source "$ROOT/Scripts/lib/release_binary.sh"

# 回退分支是给没有本项目 Developer ID 证书的人留的（仓库是 GPL 公开的、有 fork），
# 不是给自己用的 —— 掉进回退分支意味着装出来的包和发布包身份不同，授权会打架。
IDENTITIES="$(security find-identity -v -p codesigning 2>&1)"
if grep -Fq "\"$DEVELOPER_ID\"" <<<"$IDENTITIES"; then
  IDENTITY="$DEVELOPER_ID"
elif grep -Fq "\"$FALLBACK_IDENTITY\"" <<<"$IDENTITIES"; then
  IDENTITY="$FALLBACK_IDENTITY"
  echo "warning: 没找到 Developer ID 证书，回退到「${FALLBACK_IDENTITY}」。" >&2
  echo "         装出来的包与发布包身份不同，辅助功能授权会和发布包互相作废。" >&2
else
  echo "error: 找不到任何可用的签名证书。" >&2
  echo "       期望「${DEVELOPER_ID}」或「${FALLBACK_IDENTITY}」。" >&2
  echo "       没有它就只能 ad-hoc 签名，每次安装都会让辅助功能授权失效。" >&2
  exit 1
fi

echo "==> 构建 Release…"
# Same arch and coverage settings as package_release.sh (see Scripts/lib/release_binary.sh).
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -derivedDataPath "$DD" \
  ARCHS="x86_64 arm64" ONLY_ACTIVE_ARCH=NO \
  CLANG_COVERAGE_MAPPING=NO \
  build >/tmp/tungsten-local-install.log 2>&1
echo "    ok"

STAGE="$(mktemp -d)"
APP="$STAGE/$APP_NAME.app"
cp -R "$PRODUCTS/$BUILT_NAME.app" "$APP"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE"   # 与发布包保持一致

# Strip the staged copy before signing, exactly as the release does; the build's dSYM
# stays in $PRODUCTS for symbolication.
echo "==> 剥符号表并检查主程序…"
strip_release_binary "$APP/Contents/MacOS/$BUILT_NAME" && verify_release_binary "$APP/Contents/MacOS/$BUILT_NAME" \
  || { echo "error: 主程序带着覆盖率插桩或符号表，不安装（原因见上一行）" >&2; exit 1; }

# 与 package_release.sh 逐项对齐：hardened runtime + 安全时间戳 + 同一份 entitlements。
# --timestamp 要联网（约 1 秒）。它对运行期行为没有影响，留着是为了让本机包与发布包
# 的签名配置完全一致 —— 万一以后离线场景嫌它碍事，删掉它是安全的。
#
# Sparkle 框架里有嵌套代码（Updater.app / Autoupdate），外层 app 签一次**够不着**它们；
# 而 hardened runtime 下主程序只肯加载同一 Team ID 签过的库——Xcode 构建出来的 Sparkle
# 还挂着本地构建证书（没有 Team ID），不重签的话 dyld 直接拒载，app 启动即崩
# （2026-08-21 撞上：Sparkle 是 08-20 嵌进来的，这个脚本当时没跟着改）。
# 所以和发布脚本一样由内向外签：嵌套代码 → 框架 → app。不加 --deep：已废弃，
# 而且会把外层 entitlements 错套到嵌套代码上。
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
[[ -d "$SPARKLE" ]] || { echo "error: 构建产物里没有嵌入 Sparkle.framework" >&2; exit 1; }
# 两个 XPC 服务只给沙箱宿主用，发布包也不带；必须在签框架**之前**删，否则封印对不上内容。
rm -rf "$SPARKLE/Versions/B/XPCServices"
echo "==> 由内向外签 Sparkle 的嵌套代码…"
for nested in "$SPARKLE/Versions/B/Updater.app" "$SPARKLE/Versions/B/Autoupdate"; do
  [[ -e "$nested" ]] || { echo "error: Sparkle 缺少预期的嵌套代码：$nested" >&2; exit 1; }
  codesign --force --sign "$IDENTITY" --options runtime --timestamp "$nested"
done
codesign --force --sign "$IDENTITY" --options runtime --timestamp "$SPARKLE"

echo "==> 用「${IDENTITY}」签名（hardened runtime + entitlements）…"
codesign --force \
  --sign "$IDENTITY" \
  --options runtime \
  --timestamp \
  --entitlements "$ENTITLEMENTS" \
  "$APP"

# 主程序和 Sparkle 的 Team ID 必须一致，否则上面说的拒载会在用户机器上重演。
APP_TEAM="$(codesign -dvv "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
SPARKLE_TEAM="$(codesign -dvv "$SPARKLE" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
[[ "$APP_TEAM" == "$SPARKLE_TEAM" ]] \
  || { echo "error: Sparkle 与主程序的 Team ID 不一致（$SPARKLE_TEAM vs $APP_TEAM），hardened runtime 会拒载" >&2; exit 1; }

# 签完立刻回读确认，别等到运行期才发现 entitlement 没进去。
codesign -dvvv "$APP" 2>&1 | grep -E "^Authority=|^Identifier=|^TeamIdentifier=|flags=" | sed 's/^/    /'
SIGNED_ENTS="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null || true)"
grep -q 'com.apple.security.automation.apple-events' <<<"$SIGNED_ENTS" \
  || { echo "error: 签名后的 app 里没有 Apple Events entitlement（Finder 目录预览会失效）" >&2; exit 1; }
# 先落进变量再判，**不要写成 `codesign … | grep -q`**：`grep -q` 命中就立刻关掉管道，
# codesign 吃到 SIGPIPE 退出码非零，在 `set -o pipefail` 下整条管道被判失败——签名明明
# 是对的，脚本却报「没有 hardened runtime 标志」（2026-08-19 实际撞上）。
SIGNED_INFO="$(codesign -dvvv "$APP" 2>&1 || true)"
grep -q 'flags=.*runtime' <<<"$SIGNED_INFO" \
  || { echo "error: 签名后的 app 没有 hardened runtime 标志" >&2; exit 1; }

echo "==> 退出正在运行的实例…"
pkill -x "$BUILT_NAME" >/dev/null 2>&1 || true
for _ in $(seq 1 25); do
  pgrep -x "$BUILT_NAME" >/dev/null 2>&1 || break
  sleep 0.2
done

# 注意花括号：紧跟其后的省略号是多字节字符，写成 $DEST… 会被当成变量名的一部分，
# 在 set -u 下直接报 unbound variable。
echo "==> 安装到 ${DEST}…"
rm -rf "$DEST"
ditto "$APP" "$DEST"          # 必须用 ditto：普通 cp 不保留符号链接，会破坏签名
rm -rf "$STAGE"

VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DEST/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$DEST/Contents/Info.plist")"
echo "==> 完成：$VER ($BUILD)"
# 注意 --deep 校验抓不到嵌套代码签错身份（.claude/rules/auto-update.md），真正的闸门是上面的 Team ID 比对。
codesign --verify --strict "$DEST" && echo "    签名校验通过"
echo "    启动：open \"$DEST\""
