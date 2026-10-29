# Westie

DeepSeek Harness（DSH）的原生 macOS 客户端：沿用 DSH 内核，界面用 SwiftUI + AppKit 自己做。

## 结构

| 目录 | 内容 |
|---|---|
| `kernel/` | 自带的 DSH 内核：npm 依赖（锁定 0.2.1-rc.3，与 DSH.app 同版本）、启动壳 `launch.mjs`、`bundle/`（`@westie/kernel-bundle`，关掉只服务浏览器界面的行） |
| `Packages/WestieKit` | 内核进程管理（`KernelProcess`）、Remote 连接（`KernelConnection`）、数据折叠（`WorkspaceBoard`、`Transcript`） |
| `App/Westie` | App：`AppModel`（生命周期、会话、审批与提问）、`ConversationModel`、界面；Markdown 用 [Textual](https://github.com/gonzalezreal/textual)（MIT）渲染 |
| `Packages/Textual` | Textual 0.5.0 的副本，打了流式出字所需的小补丁（见 `PATCHES.md`） |
| `scripts/` | 开发工具：`kernel.sh` 单独起内核、`probe.mjs` 链路探针、`mock-llm.mjs` 假模型、`dump-remote.mjs` 导出接口描述符 |

界面由五个平级的面板组成：顶部、主边栏、对话、侧边栏、底部（`PanelLayout`、`Workbench`）。面板只管位置、尺寸和收起；内容是窗口，一个面板里的窗口可以并排显示或收着，窗口能拖到别的面板。布局保存在 UserDefaults，不写 `~/.dsh`；按数据目录分开保存（真实 `~/.dsh` 沿用 `Westie.panelLayout.v1`，其他目录在键后加路径），不会把一份数据里的会话窗口恢复到另一份里。

拖放规则（设计稿 `deliverables/Westie/reviews/2026-10-28-panels/v3`）：拖动时布局不动，只有一张小卡跟着指针，落点浮出松手后的样子。外框最外一圈（24pt，停 150ms）打开那条边上没显示的面板；窗口卡片的前三成或后三成表示并排插在它前面或后面，正中间表示叠进去；指针到对话面板上沿会浮出五格布局条。标题栏的布局按钮弹出同一张五格图，不拖也能移。窗口移走后，如果原面板空了、还有收着的窗口，就原地列出它们供补位。对话面板里的窗口全收着时也一直这样列出。指针靠近窗口顶部正中会浮出一根拖动条，拖它或标题栏空白处移动窗口，拖动中按 Esc 取消。系统自动拖动 App 已关掉，只有外框露出的地方能拖 App（双击按系统设置缩放）。

设置是工作台里的一张卡片（设计稿 `deliverables/Westie/reviews/2026-10-29-settings/v1` 方向 B）：⌘, 或侧栏底部「设置」在对话面板里打开。通用、账号、高级写进内核（`settings/update`、`credentials/*`、`account/*`）；外观（浅深色、主题、颗粒质感、对话宽度、字体）是 Westie 自己的，存在 UserDefaults。字体分界面、对话、代码三类（`Typography`）：西文字体打底，中文字体挂在 cascade list 上；字体页按 v4 方向 B：四组搭配、一根字号滑杆、行距三档，展开后逐项改字体、字号、行高、段距、字距和代码行高。外观页另有「对话宽度」四档（窄、标准、宽、铺满），调消息与输入框的最大宽度，换字体搭配时保持不变；旧滑杆的中间宽度保留，≥1240 的旧值迁移为铺满（0）。字号与间距读写时按控件范围钳制，非有限数值回到默认值。

App 启动时拉起内核（Node 子进程，profile `westie`），用启动令牌经 `/connect` 接入，一元调用走 `POST /api/<方法>`，流走 WebSocket `/api/remote.mux`。

## 开发

```sh
cd kernel && mise exec -- pnpm install && cd ..   # 安装内核（约 530MB，在 kernel/node_modules）
xcodegen generate                                 # project.yml → Westie.xcodeproj
xcodebuild -scheme Westie -derivedDataPath temp/DerivedData build
```

## 数据

默认与 DSH 共用 `~/.dsh`：会话、工作区、登录凭据都沿用，Westie 只在其中新增 `profiles/westie`。内核锁定为与 DSH.app 相同的版本，存储相关代码逐字节一致，写入格式不会被升级。

`storages/workspace.json` 没有跨进程写锁，两个内核同时运行会互相覆盖，所以 Westie 与 DSH.app 互斥：DSH.app 在运行时 Westie 不启动内核并等待它退出；Westie 运行中 DSH.app 启动，Westie 立即停掉自己的内核让位。

`WESTIE_DSH_HOME=<目录>` 可改用别的数据目录（不与 DSH.app 互斥）。

测试用本地假模型，数据在 `temp/dsh-home`，并清除所有 `*_API_KEY`，不会碰 `~/.dsh`、不会发出真实模型请求：

```sh
node scripts/mock-llm.mjs 3190 &
open --env WESTIE_MOCK_LLM=3190 temp/DerivedData/Build/Products/Debug/Westie.app
```

假模型的暗号：`/bash` 调一次无害的 bash、`/approve` 触发审批、`/ask` 向你提问、`/md` 回一段覆盖常见语法的 Markdown，消息以 `slow` 结尾时放慢出字，其余消息原样回显。假模型模式下也可以用 `WESTIE_DSH_HOME` 另指一份测试数据，和已开着的测试实例互不干扰。

## 测试

```sh
cd Packages/WestieKit && WESTIE_KERNEL_IT=1 swift test    # 含真实内核集成测试（只调只读方法）
```

DEBUG 构建支持 `WESTIE_AUTOMATION` 后台驱动 App（步骤见 `App/Westie/Automation.swift`），只调用 App 自己的方法、截自己窗口，不合成输入、不前置窗口。不在假模型模式时只允许只读步骤（`select`、`earlier`、`shot`、`dump`、`wait`、`quit`）。`select:` 可写序号或会话 id；序号按侧栏可见列表算（空会话不计），可复现的脚本优先用 id。`earlier[:页数]` 往前翻页，省略页数翻到会话开头：

```sh
open -g -j -n --env WESTIE_MOCK_LLM=3190 \
  --env "WESTIE_AUTOMATION=new;prompt:/approve;idle;shot:$PWD/temp/shots/a.png;approve;idle;dump;quit" \
  --env WESTIE_AUTOMATION_LOG=$PWD/temp/logs/automation.log temp/DerivedData/Build/Products/Debug/Westie.app
```
