#!/bin/bash
# 只编译并运行离屏 AppKit 协调者检查，不启动产品或操作窗口。
set -euo pipefail
cd "$(dirname "$0")/.."
output="${1:-temp/conversation-scroll-checks}"
mkdir -p "$output"
# 滚动宿主现在只额外依赖 PerfTrace；构建这个实际源码的最小模块，关闭测量。
# 不要求先构建完整 App，也不引入内核运行时。
swiftc -parse-as-library -swift-version 6 -emit-library -emit-module \
  -module-name WestieKit Packages/WestieKit/Sources/WestieKit/PerfTrace.swift \
  -emit-module-path "$output/WestieKit.swiftmodule" -o "$output/libWestieKit.dylib"
swiftc -parse-as-library -swift-version 6 -I "$output" -L "$output" -lWestieKit \
  -Xlinker -rpath -Xlinker @executable_path \
  App/Westie/Views/ConversationScroll.swift scripts/tests/ConversationScrollerChecks.swift \
  -o "$output/checks"
"$output/checks"
