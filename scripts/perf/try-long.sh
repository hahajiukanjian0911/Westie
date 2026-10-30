#!/bin/bash
# 前台验收用：假模型 + 性能夹具副本（400 会话、150 轮长会话），不碰 ~/.dsh 和 ~/.config/westie，不发真实请求。
# 夹具由 `python3 scripts/perf/run.py` 首次运行时生成。每次运行都从夹具重新复制一份数据，可以随便发消息、展开、翻页。关掉 App 后假模型自动退出。
set -euo pipefail
cd "$(dirname "$0")/../.."
M=temp/perf/manual; rm -rf "$M"; mkdir -p "$M"
cp -R temp/perf/fixtures/home "$M/home"
NODE="$HOME/.local/share/mise/installs/node/24/bin/node"
"$NODE" scripts/mock-llm.mjs 3199 > "$M/mock.log" 2>&1 &
MOCK=$!; trap 'kill $MOCK 2>/dev/null' EXIT
sleep 0.5
env -u DEEPSEEK_API_KEY open -W -n --env WESTIE_MOCK_LLM=3199 --env "WESTIE_DSH_HOME=$PWD/$M/home" \
  --env "WESTIE_CONFIG_HOME=$PWD/$M/config" temp/DerivedData/Build/Products/Debug/Westie.app
