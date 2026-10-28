import SwiftUI
import Textual

/// 回复的 Markdown 排版，按设计稿 `deliverables/Westie/reviews/2026-10-28-markdown` 实现：
/// v1 排版——正文 14pt 常规字重、行距放宽，层级靠字号和留白；表格去竖线，代码块带语言名和悬停复制。
/// v2 出字——流式时新到的字按到达时间淡入，代码块底色等装饰随第一笔字淡入，表格收齐后整块出现。
struct MarkdownText: View {
    let text: String
    var streaming = false
    @State private var parser = StreamingMarkdownParser()
    @Environment(\.palette) private var palette

    var body: some View {
        Group {
            if streaming {
                // 只在流式时逐帧重画：TextRenderer 按当前时间算每段字的透明度
                TimelineView(.animation) { context in
                    styled(StructuredText(StreamingMarkdownParser.holdBack(text), parser: parser))
                        .textRenderer(StreamFadeRenderer(now: context.date.timeIntervalSinceReferenceDate))
                }
                .environment(\.appearFade, true)
            } else {
                styled(StructuredText(markdown: text))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func styled(_ content: StructuredText) -> some View {
        content
            .font(.system(size: MarkdownMetrics.body))
            .foregroundStyle(palette.ink2)
            .textual.textSelection(.enabled)
            .textual.inlineStyle(
                InlineStyle()
                    .code(.monospaced, .fontScale(MarkdownMetrics.codeScale),
                          .foregroundColor(DynamicColor(palette.ink)), .backgroundColor(DynamicColor(palette.bubble)))
                    .strong(.fontWeight(.semibold), .foregroundColor(DynamicColor(palette.ink)))
                    .link(.foregroundColor(DynamicColor(palette.ink)),
                          .underlineStyle(Text.LineStyle(pattern: .solid, color: palette.ink5)))
            )
            .textual.paragraphStyle(BodyParagraphStyle())
            .textual.headingStyle(BodyHeadingStyle(palette: palette))
            .textual.listItemStyle(BodyListItemStyle())
            .textual.listItemSpacing(.fontScaled(top: 4 / MarkdownMetrics.body))
            .textual.unorderedListMarker(DotListMarker(palette: palette))
            .textual.orderedListMarker(NumberListMarker(palette: palette))
            .textual.blockQuoteStyle(QuoteStyle(palette: palette))
            .textual.tableStyle(RuledTableStyle(palette: palette))
            .textual.tableCellStyle(RuledTableCellStyle(palette: palette))
            .textual.codeBlockStyle(CodeCardStyle(palette: palette))
            .textual.highlighterTheme(Self.theme(palette))
            .textual.thematicBreakStyle(HairlineBreakStyle(palette: palette))
    }

    /// 代码高亮只用配色里已有的几种颜色，克制一些。
    static func theme(_ palette: Palette) -> StructuredText.HighlighterTheme {
        let keyword = AnyTextProperty(.foregroundColor(DynamicColor(palette.accent)))
        let string = AnyTextProperty(.foregroundColor(DynamicColor(palette.ok)))
        let number = AnyTextProperty(.foregroundColor(DynamicColor(palette.warn)))
        let comment = AnyTextProperty(.foregroundColor(DynamicColor(palette.ink4)))
        return .init(
            foregroundColor: DynamicColor(palette.ink2),
            backgroundColor: DynamicColor(palette.code),
            tokenProperties: [
                .keyword: keyword, .literal: keyword, .boolean: keyword,
                .string: string, .char: string, .regex: string,
                .number: number,
                .comment: comment,
            ]
        )
    }
}

/// 排版数值照抄设计稿 v1 的 CSS（`.new .md`）。
enum MarkdownMetrics {
    static let body: CGFloat = 14
    /// 行内代码和代码块 12.5pt。
    static let codeScale: CGFloat = 12.5 / 14
    /// 中文正文行高约 1.75 倍：系统字体自然行高之外再加的行距（按 14pt 折算）。
    static let bodyLineSpacing: CGFloat = 0.5
    static let halfLeading: CGFloat = 3.5
}

// MARK: - 排版（v1）

private struct BodyParagraphStyle: StructuredText.ParagraphStyle {
    func makeBody(configuration: Configuration) -> some View {
        // 上下各留半个行距，对应 CSS 行高在单行上下留出的空隙
        configuration.label
            .textual.lineSpacing(.fontScaled(MarkdownMetrics.bodyLineSpacing))
            .padding(.vertical, MarkdownMetrics.halfLeading)
            .textual.blockSpacing(StructuredText.BlockSpacing(top: 12))
    }
}

/// 标题靠字号和上方留白分层级，不靠更粗的字重：二级 17pt、三级及以下与正文同号。
private struct BodyHeadingStyle: StructuredText.HeadingStyle {
    let palette: Palette

    func makeBody(configuration: Configuration) -> some View {
        let level = configuration.headingLevel
        let size: CGFloat = level <= 1 ? 20 : level == 2 ? 17 : 14
        let top: CGFloat = level <= 2 ? 28 : 22
        configuration.label
            .textual.fontScale(size / MarkdownMetrics.body)
            .textual.lineSpacing(.fontScaled(0.15))
            .fontWeight(.semibold)
            .foregroundStyle(palette.ink)
            .textual.blockSpacing(StructuredText.BlockSpacing(top: top, bottom: 6))
    }
}

/// 列表文字统一缩进 20pt，标记放在缩进里。
private struct BodyListItemStyle: StructuredText.ListItemStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextCenter, spacing: 0) {
            configuration.marker.frame(width: 20, alignment: .leading)
            configuration.block
        }
    }
}

/// 无序列表：5pt 淡色圆点，嵌套一层改为空心。
private struct DotListMarker: StructuredText.UnorderedListMarker {
    let palette: Palette

    func makeBody(configuration: Configuration) -> some View {
        Group {
            if configuration.indentationLevel > 1 {
                Circle().strokeBorder(palette.ink4, lineWidth: 1)
            } else {
                Circle().fill(palette.ink4)
            }
        }
        .frame(width: 5, height: 5)
        .padding(.leading, 6)
    }
}

/// 有序列表：编号退到 ink3，等宽数字右对齐，不带句点。
private struct NumberListMarker: StructuredText.OrderedListMarker {
    let palette: Palette

    func makeBody(configuration: Configuration) -> some View {
        Text("\(configuration.ordinal)")
            .monospacedDigit()
            .foregroundStyle(palette.ink3)
            .frame(width: 14, alignment: .trailing)
    }
}

/// 引用：字色退一级，左边一根 2pt 细线。
private struct QuoteStyle: StructuredText.BlockQuoteStyle {
    let palette: Palette

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(palette.ink3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 16)
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1).fill(palette.ink5)
                    .frame(width: 2).padding(.vertical, 4)
                    .modifier(AppearFade())
            }
    }
}

/// 表格：去掉竖线，只在行与行之间留一根细线。
private struct RuledTableStyle: StructuredText.TableStyle {
    let palette: Palette

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .textual.tableCellSpacing(horizontal: 0, vertical: 0)
            .textual.tableOverlay { layout in
                Canvas { context, _ in
                    for row in layout.rowIndices.dropFirst() {
                        let bounds = layout.rowBounds(row)
                        context.fill(Path(CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: 1)),
                                     with: .color(palette.cardStroke))
                    }
                }
                .modifier(AppearFade())
            }
            .textual.blockSpacing(StructuredText.BlockSpacing(top: 16, bottom: 16))
    }
}

/// 表头小一号、退到 ink3；正文 13pt，首列用 ink 便于扫读。
private struct RuledTableCellStyle: StructuredText.TableCellStyle {
    let palette: Palette

    func makeBody(configuration: Configuration) -> some View {
        let header = configuration.row == 0
        configuration.label
            .textual.fontScale(header ? 12 / 14 : 13 / 14)
            .fontWeight(header ? .medium : .regular)
            .foregroundStyle(header ? palette.ink3 : configuration.column == 0 ? palette.ink : palette.ink2)
            .textual.lineSpacing(.fontScaled(0.2))
            .padding(.top, header ? 0 : 9)
            .padding(.bottom, header ? 8 : 9)
            .padding(.trailing, 28)
    }
}

/// 代码块：顶部一行淡色语言名，复制按钮悬停时出现。
private struct CodeCardStyle: StructuredText.CodeBlockStyle {
    let palette: Palette

    func makeBody(configuration: Configuration) -> some View {
        CodeCard(configuration: configuration, palette: palette)
            .textual.blockSpacing(StructuredText.BlockSpacing(top: 16, bottom: 16))
    }
}

private struct CodeCard: View {
    let configuration: StructuredText.CodeBlockStyleConfiguration
    let palette: Palette
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(configuration.languageHint ?? "")
                    .font(.system(size: 11)).tracking(0.2)
                    .foregroundStyle(palette.ink4)
                Spacer()
                Button {
                    configuration.codeBlock.copyToPasteboard()
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.4))
                        copied = false
                    }
                } label: {
                    Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11))
                        .labelStyle(.titleAndIcon)
                        .padding(.horizontal, 7).frame(height: 22)
                        .contentShape(.rect)
                }
                .buttonStyle(CopyButtonStyle(palette: palette))
                .opacity(hovering || copied ? 1 : 0)
                .animation(.easeOut(duration: 0.15), value: hovering)
            }
            .frame(height: 32)
            .padding(.leading, 16).padding(.trailing, 8)

            Overflow {
                configuration.label
                    .textual.lineSpacing(.fontScaled(0.4))
                    .textual.fontScale(MarkdownMetrics.codeScale)
                    .fixedSize(horizontal: false, vertical: true)
                    .monospaced()
                    .padding(.horizontal, 16).padding(.bottom, 14)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 10).fill(palette.code).modifier(AppearFade())
        }
        .onHover { hovering = $0 }
    }
}

private struct CopyButtonStyle: ButtonStyle {
    let palette: Palette
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(hovering ? palette.ink : palette.ink3)
            .background(hovering ? palette.rowHoverSolid : .clear, in: .rect(cornerRadius: 6))
            .onHover { hovering = $0 }
    }
}

private struct HairlineBreakStyle: StructuredText.ThematicBreakStyle {
    let palette: Palette

    func makeBody(configuration _: Configuration) -> some View {
        Rectangle().fill(palette.cardStroke).frame(height: 1)
            .modifier(AppearFade())
            .textual.blockSpacing(StructuredText.BlockSpacing(top: 28, bottom: 20))
    }
}

// MARK: - 出字（v2）

/// 流式时把每个字的到达时间记下来：和上一次解析的文字比出公共前缀，之后的都是新到的。
/// 只给还在淡入的字挂 `streamBirth`，淡入完的字不带属性，和静态排版一致。
@MainActor
final class StreamingMarkdownParser: MarkupParser {
    private let base = AttributedStringMarkdownParser.markdown()
    private var characters: [Character] = []
    private var births: [Double] = []

    func attributedString(for input: String) throws -> AttributedString {
        var result = try base.attributedString(for: input)
        let now = Date.timeIntervalSinceReferenceDate
        let current = Array(result.characters)

        var common = 0
        let limit = min(current.count, characters.count)
        while common < limit, current[common] == characters[common] { common += 1 }
        births = Array(births.prefix(common)) + Array(repeating: now, count: current.count - common)
        characters = current

        // 从第一个还在淡入的字开始，按到达时间分段挂属性
        guard let first = births.firstIndex(where: { now - $0 < StreamFadeRenderer.duration }) else { return result }
        var index = result.characters.index(result.startIndex, offsetBy: first)
        var offset = first
        while offset < births.count {
            let birth = births[offset]
            var end = offset
            while end < births.count, births[end] == birth { end += 1 }
            let upper = result.characters.index(index, offsetBy: end - offset)
            if now - birth < StreamFadeRenderer.duration {
                result[index..<upper].textual.streamBirth = birth
            }
            index = upper
            offset = end
        }
        return result
    }

    /// 没写完的语法先不显示，免得露出 Markdown 原文或排版来回跳：
    /// 末尾的表格等收齐再整块出现；只有 `-`/`=` 的行会把上一段临时变成标题；
    /// 最后一行没闭合的 `**` 和反引号截到开头之前。代码块里不处理。
    static func holdBack(_ text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var inFence = false
        for line in lines where line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inFence.toggle() }
        guard !inFence else { return text }

        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).hasPrefix("|") { lines.removeLast() }
        if let last = lines.last?.trimmingCharacters(in: .whitespaces), !last.isEmpty,
           last.allSatisfy({ "-=*`".contains($0) }) {
            lines.removeLast()
        }
        guard var last = lines.popLast() else { return "" }
        for marker in ["**", "`"] {
            let parts = last.components(separatedBy: marker)
            if parts.count % 2 == 0, let range = last.range(of: marker, options: .backwards) {
                last = String(last[..<range.lowerBound])
            }
        }
        lines.append(last)
        return lines.joined(separator: "\n")
    }
}

/// 按 `StreamBirth` 画淡入：0.36s、先快后慢，与设计稿的 cubic-bezier(.2,.6,.3,1) 接近。
struct StreamFadeRenderer: TextRenderer {
    static let duration: Double = 0.36
    var now: Double

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            for run in line {
                guard let birth = run[StreamBirth.self] else {
                    context.draw(run)
                    continue
                }
                let progress = min(max((now - birth.time) / Self.duration, 0), 1)
                if progress >= 1 {
                    context.draw(run)
                } else {
                    var faded = context
                    faded.opacity = 1 - pow(1 - progress, 3)
                    faded.draw(run)
                }
            }
        }
    }
}

private struct AppearFadeKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// 流式回复里为 true：代码块底色、引用线、分隔线、表格线出现时淡入。
    var appearFade: Bool {
        get { self[AppearFadeKey.self] }
        set { self[AppearFadeKey.self] = newValue }
    }
}

/// 第一次出现时 0.28s 淡入，之后保持不透明；静态排版里不生效。
private struct AppearFade: ViewModifier {
    @Environment(\.appearFade) private var enabled
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(!enabled || shown ? 1 : 0)
            .onAppear {
                guard enabled, !shown else { return }
                withAnimation(.easeOut(duration: 0.28)) { shown = true }
            }
    }
}
