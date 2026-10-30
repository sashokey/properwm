#!/usr/bin/env python3
"""在构建日志里找「一致性只在更高版本的 macOS 上可用」这类警告，找到就失败。

用法：python3 Scripts/check_availability_warnings.py <构建日志> [更多日志...]

为什么需要这道闸（2026-09-08 加，起因是三个版本连着发坏）：
新 SDK 把 `CGRect` / `CGPoint` / `CGSize` / `CGVector` 的 `Hashable`、`Codable` 一致性标成
macOS 15+，而本项目最低部署目标是 macOS 12。`Set<CGRect>` 这种写法**编译只给警告**
（Swift 6 语言模式下才是错误），构建照样成功、单测在新系统上照样全绿，
到 macOS 14 及更早的机器上却是运行时找不到见证表 → 启动即段错误。
0.11.0 / 0.11.1 / 0.11.2 就是这样在老系统上全部打不开的。

日志必须来自一次**完整**编译（clean build 或全新 checkout）：增量构建不重编的文件不会再打印警告。
"""
import pathlib
import re
import sys

# 编译器原话：conformance of 'CGRect' to 'Hashable' is only available in macOS 15.0 or newer
PATTERN = re.compile(r'is only available in macOS')
# 我们自己的源码路径才算数：SDK / 依赖包里的同类警告不该拦发版。
OURS = re.compile(r'/(App|Core|Platform|Tests|UI)/[^ ]*\.swift')


def main() -> int:
    logs = [pathlib.Path(a) for a in sys.argv[1:]]
    if not logs:
        print(__doc__)
        return 2

    hits = []
    for log in logs:
        if not log.exists():
            print(f'❌ 构建日志不存在：{log}')
            return 1
        for line in log.read_text(errors='replace').splitlines():
            if PATTERN.search(line) and OURS.search(line):
                hits.append(line.strip())

    if hits:
        print('❌ 构建日志里有「一致性 / API 只在更高版本 macOS 上可用」的警告。')
        print('   这类警告不拦构建，但在最低支持的系统上是运行时崩溃，必须改掉：')
        for line in dict.fromkeys(hits):
            print(f'   {line}')
        return 1

    print(f'✅ 未发现跨版本一致性警告（扫了 {len(logs)} 份构建日志）')
    return 0


if __name__ == '__main__':
    sys.exit(main())
