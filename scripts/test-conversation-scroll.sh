#!/bin/bash
# 只编译并运行离屏 AppKit 协调者检查，不启动产品或操作窗口。
set -euo pipefail
cd "$(dirname "$0")/.."
output="${1:-temp/conversation-scroll-checks}"
mkdir -p "$output"
swiftc -parse-as-library -swift-version 6 \
  App/Westie/Views/ConversationScroll.swift scripts/tests/ConversationScrollerChecks.swift \
  -o "$output/checks"
"$output/checks"
