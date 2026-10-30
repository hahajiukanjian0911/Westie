# Westie 对 Textual 的补丁

来源：https://github.com/gonzalezreal/textual 0.5.0（`01b5187`），MIT 许可（见 LICENSE）。只复制了 `Sources/`，去掉了测试目标。

升级时先取上游新版本覆盖 `Sources/`，再重新打下面的补丁（搜 `Westie 补丁`）。

1. `MarkdownParser/TextualAttributes.swift`：新增属性 `streamBirth`（字的到达时间）和对应的 `StreamBirth: TextAttribute`。
2. `Internal/TextFragment/TextBuilder.swift`：带 `streamBirth` 的文字挂上 `StreamBirth` 自定义属性，App 的 TextRenderer 据此按时间画淡入。
3. `Internal/Highlighter/HighlightedTextFragment.swift`：
   - 流式追加时沿用已分好的 token，新增部分先按普通文本显示，避免每来一段字整块先变回无色再上色；
   - 内容变化后过期的分词结果直接丢弃；
   - 高亮重建字符串后，把原文上的 `streamBirth` 按字符位置搬过去。
4. `Internal/Helpers/VerticalAlignment+FirstTextCenter.swift`：`firstTextCenter` 改为 public，App 的列表样式用它让标记对齐首行中线。
5. `StructuredText/LayoutReadyKey.swift`：汇总初次解析、行内样式、文本构建、块间距、列表标记和表格/溢出尺寸的就绪状态，供按轮宿主完整布局后再显示；不等待异步附件下载。相关节点只报告状态，不改变已有排版与选择范围。`Overflow.swift` 改从自身几何取容器宽度，避免离屏内容依赖滚动可见性回调而停在中间尺寸。
