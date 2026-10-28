#!/bin/sh
# 开发用：在隔离的 DSH_HOME 里启动 Westie 内核（不带任何 API key），stdout 打印连接地址。
# 与 KernelProcess.ensureProfile 一致：组合包直接复制进 profile，清单只在首次创建。
# 用法：scripts/kernel.sh [端口]   DSH_HOME 默认 temp/dsh-home
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
export DSH_HOME="${DSH_HOME:-$ROOT/temp/dsh-home}"
PROFILE="$DSH_HOME/profiles/westie"
for key in $(env | sed -n 's/^\([A-Z_]*_API_KEY\)=.*/\1/p'); do unset "$key"; done
mkdir -p "$PROFILE/node_modules/@westie"
rm -rf "$PROFILE/node_modules/@westie/kernel-bundle"
cp -R "$ROOT/kernel/bundle" "$PROFILE/node_modules/@westie/kernel-bundle"
[ -f "$PROFILE/package.json" ] || printf '{\n  "name": "westie-profile",\n  "private": true,\n  "dsh": { "profile": { "bundles": ["@deepseek-ai/dsh-base", "@deepseek-ai/dsh-web-app", "@westie/kernel-bundle"] } }\n}\n' > "$PROFILE/package.json"
exec mise exec -C "$ROOT/kernel" -- node "$ROOT/kernel/launch.mjs" --profile westie --no-open --port "${1:-3181}"
