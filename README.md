# Westie

DeepSeek Harness（DSH）的原生 macOS 客户端：沿用 DSH 内核，界面用 SwiftUI + AppKit 自己做。

## 结构

| 目录 | 内容 |
|---|---|
| `kernel/` | 自带的 DSH 内核：npm 依赖（锁定 0.2.1-rc.4）、启动壳 `launch.mjs`、`bundle/`（`@westie/kernel-bundle`，关掉只服务浏览器界面的行） |
| `Packages/WestieKit` | 内核进程管理（`KernelProcess`）、Remote 连接（`KernelConnection`）、数据折叠（`WorkspaceBoard`、`Transcript`） |
| `App/Westie` | App：`AppModel`（生命周期、会话、审批与提问）、`ConversationModel`、界面 |
| `scripts/` | 开发工具：`kernel.sh` 单独起内核、`probe.mjs` 链路探针、`mock-llm.mjs` 假模型、`dump-remote.mjs` 导出接口描述符 |

App 启动时拉起内核（Node 子进程，profile `westie`），用启动令牌经 `/connect` 接入，一元调用走 `POST /api/<方法>`，流走 WebSocket `/api/remote.mux`。

## 开发

```sh
cd kernel && mise exec -- pnpm install && cd ..   # 安装内核（约 530MB，在 kernel/node_modules）
xcodegen generate                                 # project.yml → Westie.xcodeproj
xcodebuild -scheme Westie -derivedDataPath temp/DerivedData build
```

开发版的内核数据在 `temp/dsh-home`，与真实的 `~/.dsh` 隔离，并清除所有 `*_API_KEY`，不会发出真实模型请求。

要真正发消息，用本地假模型：

```sh
node scripts/mock-llm.mjs 3190 &
open --env WESTIE_MOCK_LLM=3190 temp/DerivedData/Build/Products/Debug/Westie.app
```

假模型的暗号：`/bash` 调一次无害的 bash、`/approve` 触发审批、`/ask` 向你提问，其余消息原样回显。

## 测试

```sh
cd Packages/WestieKit && WESTIE_KERNEL_IT=1 swift test    # 含真实内核集成测试（只调只读方法）
```

DEBUG 构建支持 `WESTIE_AUTOMATION` 后台驱动 App（步骤见 `App/Westie/Automation.swift`），只调用 App 自己的方法、截自己窗口，不合成输入、不前置窗口：

```sh
open -g -j -n --env WESTIE_MOCK_LLM=3190 \
  --env "WESTIE_AUTOMATION=new;prompt:/approve;idle;shot:$PWD/temp/shots/a.png;approve;idle;dump;quit" \
  --env WESTIE_AUTOMATION_LOG=$PWD/temp/logs/automation.log temp/DerivedData/Build/Products/Debug/Westie.app
```
