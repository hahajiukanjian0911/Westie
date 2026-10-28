#!/bin/sh
# 开发用：在隔离的 DSH_HOME 里启动 Westie 内核（不带任何 API key），stdout 打印连接地址。
# 用法：scripts/kernel.sh [端口]   DSH_HOME 默认 temp/dsh-home
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
export DSH_HOME="${DSH_HOME:-$ROOT/temp/dsh-home}"
unset DEEPSEEK_API_KEY OPENAI_API_KEY ANTHROPIC_API_KEY
DSH="$ROOT/kernel/launch.mjs"
run() { mise exec -C "$ROOT/kernel" -- node "$DSH" "$@"; }
if [ ! -f "$DSH_HOME/profiles/westie/package.json" ]; then
  mkdir -p "$DSH_HOME/profiles/westie"
  printf '{\n  "name": "westie-profile",\n  "private": true,\n  "dsh": { "profile": { "bundles": ["@deepseek-ai/dsh-base", "@deepseek-ai/dsh-web-app"] } }\n}\n' \
    > "$DSH_HOME/profiles/westie/package.json"
  run plugin --profile westie add "file:$ROOT/kernel/bundle" >&2
fi
exec mise exec -C "$ROOT/kernel" -- node "$DSH" --profile westie --no-open --port "${1:-3181}"
