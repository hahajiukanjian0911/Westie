import AppKit
import SwiftUI

/// 字体：界面、对话、代码三类（设计稿 `deliverables/Westie/reviews/2026-10-29-settings/v2`，交互与间距见 v4 的 B）。
/// 界面和对话各挑一款西文、一款中文，中文字体挂在西文字体的 cascade list 上，只管西文没有的字；
/// 代码只挑一款等宽字体，不带中文的等宽字体，汉字跟随对话的中文字体。
struct FontOption: Identifiable, Hashable, Sendable {
    enum SystemDesign: Hashable, Sendable { case standard, serif, monospaced }

    let name: String
    /// 字体族名；nil 表示系统字体（SF Pro / New York / SF Mono，按名字查不到，只能这样调用）。
    let family: String?
    var design: SystemDesign = .standard
    /// 没装时给出的安装命令所用的 Homebrew cask。
    var cask: String?
    /// 一个短标签：「系统」「中英等宽」。
    var tag: String?
    /// 自带中文字形、中英等宽（代码字体用）。
    var coversCJK = false

    var id: String { name }

    @MainActor var installed: Bool {
        guard let family else { return true }
        return FontOption.installedFamilies.contains(family)
    }

    @MainActor static var installedFamilies: Set<String> = Set(NSFontManager.shared.availableFontFamilies)

    // MARK: 推荐

    static let sfPro = FontOption(name: "SF Pro", family: nil, tag: "系统")
    static let pingFang = FontOption(name: "苹方", family: "PingFang SC", tag: "系统")
    static let sfMono = FontOption(name: "SF Mono", family: nil, design: .monospaced, tag: "系统")

    static let uiLatin: [FontOption] = [
        sfPro,
        FontOption(name: "Inter", family: "Inter", cask: "font-inter"),
        FontOption(name: "Helvetica Neue", family: "Helvetica Neue"),
        FontOption(name: "Avenir Next", family: "Avenir Next"),
    ]
    static let uiCJK: [FontOption] = [
        pingFang,
        FontOption(name: "鸿蒙黑体", family: "HarmonyOS Sans SC", cask: "font-harmonyos-sans"),
        FontOption(name: "冬青黑体", family: "Hiragino Sans GB"),
        FontOption(name: "兰亭黑", family: "Lantinghei SC"),
    ]
    static let chatLatin: [FontOption] = [
        sfPro,
        FontOption(name: "New York", family: nil, design: .serif, tag: "系统"),
        FontOption(name: "Charter", family: "Charter"),
        FontOption(name: "Georgia", family: "Georgia"),
        FontOption(name: "Helvetica Neue", family: "Helvetica Neue"),
        FontOption(name: "Source Serif 4", family: "Source Serif 4", cask: "font-source-serif-4"),
    ]
    static let chatCJK: [FontOption] = [
        pingFang,
        FontOption(name: "霞鹜文楷", family: "LXGW WenKai", cask: "font-lxgw-wenkai"),
        FontOption(name: "思源宋体", family: "Noto Serif CJK SC", cask: "font-noto-serif-cjk-sc"),
        FontOption(name: "宋体-简", family: "Songti SC"),
        FontOption(name: "楷体-简", family: "Kaiti SC"),
        FontOption(name: "冬青黑体", family: "Hiragino Sans GB"),
    ]
    static let code: [FontOption] = [
        sfMono,
        FontOption(name: "Maple Mono NF CN", family: "Maple Mono NF CN", cask: "font-maple-mono-nf-cn", tag: "中英等宽", coversCJK: true),
        FontOption(name: "更纱等宽", family: "Sarasa Mono SC", cask: "font-sarasa-gothic", tag: "中英等宽", coversCJK: true),
        FontOption(name: "JetBrains Mono", family: "JetBrains Mono", cask: "font-jetbrains-mono"),
        FontOption(name: "Fira Code", family: "Fira Code", cask: "font-fira-code"),
        FontOption(name: "Menlo", family: "Menlo"),
    ]

    /// 按名字找推荐字体；不在推荐里但本机装了（从「其他字体…」选的），就按字体族名直接用。
    static func find(_ name: String?, in list: [FontOption]) -> FontOption {
        if let match = list.first(where: { $0.name == name }) { return match }
        if let name, NSFontManager.shared.availableFontFamilies.contains(name) {
            return FontOption(name: name, family: name, design: list[0].design)
        }
        return list[0]
    }
}

/// 当前选中的三类字体，放进环境里，各处按需取 `Font`。
struct Typography: Equatable, Sendable {
    var uiLatin = FontOption.sfPro
    var uiCJK = FontOption.pingFang
    var chatLatin = FontOption.sfPro
    var chatCJK = FontOption.pingFang
    var chatSize: CGFloat = 14
    var codeFont = FontOption.sfMono
    var codeSize: CGFloat = 12.5
    /// 对话正文的行高（字号的倍数）、段落之间的距离（pt）、字距（字号的倍数）。
    var lineHeight: CGFloat = 1.7
    var paragraphSpacing: CGFloat = 12
    var tracking: CGFloat = 0
    /// 代码的行高（字号的倍数）。
    var codeLineHeight: CGFloat = 1.55
    /// 对话栏（消息与输入框）的最大宽度；0 表示铺满整个窗口。
    var chatWidth: CGFloat = 760

    /// 对话宽度四档（设计稿 `2026-10-29-chat-width/v2` 的 A）：名字、宽度（0 为铺满）、示意图里栏占的比例。
    static let chatWidthOptions: [(name: String, width: CGFloat, fraction: CGFloat)] = [
        ("窄", 640, 0.46), ("标准", 760, 0.58), ("宽", 960, 0.76), ("铺满", 0, 0.94),
    ]
    var chatColumnWidth: CGFloat { chatWidth <= 0 ? .infinity : chatWidth }

    static let chatSizes: ClosedRange<CGFloat> = 13...18
    static let codeSizes: ClosedRange<CGFloat> = 11...16
    static let lineHeights: ClosedRange<CGFloat> = 1.4...2.1
    static let paragraphSpacings: ClosedRange<CGFloat> = 4...24
    static let trackings: ClosedRange<CGFloat> = -0.02...0.08
    static let codeLineHeights: ClosedRange<CGFloat> = 1.3...1.9

    /// 正文行高换算成 SwiftUI / Textual 的行距：字体自然行高之外再加多少（以字号为单位）。
    var chatLineSpacingEm: CGFloat {
        max(0, lineHeight - Self.naturalLineHeight(Self.make(chatLatin, cjk: chatCJK, size: chatSize, weight: .regular)))
    }

    var codeLineSpacingEm: CGFloat {
        max(0, codeLineHeight - Self.naturalLineHeight(Self.make(codeFont, cjk: nil, size: codeSize, weight: .regular)))
    }

    /// 某个字号下正文的行距（pt），思考过程这类小一号的正文用。
    func chatLineSpacing(size: CGFloat) -> CGFloat { chatLineSpacingEm * size }

    /// 字距（pt）。
    func chatTracking(size: CGFloat) -> CGFloat { tracking * size }

    /// 字体自然行高与字号之比。
    static func naturalLineHeight(_ font: NSFont) -> CGFloat {
        let ct = font as CTFont
        return (CTFontGetAscent(ct) + CTFontGetDescent(ct) + CTFontGetLeading(ct)) / font.pointSize
    }

    /// 字号显示：整数不带小数，半号带一位。
    static func sizeLabel(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }

    func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        Font(Self.make(uiLatin, cjk: uiCJK, size: size, weight: weight))
    }

    var chat: Font { chat(size: chatSize) }

    func chat(size: CGFloat) -> Font { Font(Self.make(chatLatin, cjk: chatCJK, size: size, weight: .regular)) }

    var code: Font { codeFont(size: codeSize) }

    func codeFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font(Self.make(codeFont, cjk: codeFont.coversCJK ? nil : chatCJK, size: size, weight: weight))
    }

    /// 西文字体打底，中文字体放进 cascade list；字体没装时退回同类系统字体。
    static func make(_ latin: FontOption, cjk: FontOption?, size: CGFloat, weight: Font.Weight) -> NSFont {
        let nsWeight = weight.nsWeight
        var base: NSFont
        if let family = latin.family,
           let font = NSFont(descriptor: NSFontDescriptor(fontAttributes: [.family: family, .traits: [NSFontDescriptor.TraitKey.weight: nsWeight]]), size: size),
           font.familyName == family {
            base = font
        } else {
            base = systemFont(latin.design, size: size, weight: nsWeight)
            // 系统字体（.AppleSystemUIFont 一族）接非苹方的中文字体时，会按苹方的规则给句号、逗号、分号
            // 多加半个字宽。改用同一款字体的文件（SFNS.ttf 等），带上系统字体的字重和视觉字号，就没有这个问题。
            // 只有标准的 SF Pro 接苹方是对的；New York、SF Mono 自带的中文后备一样会加宽。
            if !nativePair(latin, cjk) {
                base = fileSystemFont(latin.design, matching: base) ?? base
            }
        }
        // SF Pro 本来就以苹方为中文后备，不用再挂
        guard let family = cjk?.family, !nativePair(latin, cjk) else { return base }
        let fallback = NSFontDescriptor(fontAttributes: [.family: family, .traits: [NSFontDescriptor.TraitKey.weight: nsWeight]])
        let descriptor = base.fontDescriptor.addingAttributes([.cascadeList: [fallback]])
        return NSFont(descriptor: descriptor, size: size) ?? base
    }
}

extension Typography {
    /// SF Pro + 苹方（或不带中文）：直接用系统字体最稳。
    private static func nativePair(_ latin: FontOption, _ cjk: FontOption?) -> Bool {
        latin.family == nil && latin.design == .standard && (cjk == nil || cjk?.family == FontOption.pingFang.family)
    }

    static func systemFont(_ design: FontOption.SystemDesign, size: CGFloat, weight: NSFont.Weight) -> NSFont {
        switch design {
        case .monospaced: return .monospacedSystemFont(ofSize: size, weight: weight)
        case .serif:
            let system = NSFont.systemFont(ofSize: size, weight: weight)
            return system.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: size) } ?? system
        case .standard: return .systemFont(ofSize: size, weight: weight)
        }
    }

    /// 系统字体对应的字体文件，只加载一次。
    nonisolated(unsafe) private static let fileDescriptors: [FontOption.SystemDesign: CTFontDescriptor] = {
        let files: [FontOption.SystemDesign: String] = [.standard: "SFNS.ttf", .serif: "NewYork.ttf", .monospaced: "SFNSMono.ttf"]
        return files.compactMapValues { file in
            let url = URL(filePath: "/System/Library/Fonts/\(file)")
            return (CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor])?.first
        }
    }()

    /// 从字体文件取同一款字体，字重、视觉字号等可变轴照抄系统字体当前的取值。
    private static func fileSystemFont(_ design: FontOption.SystemDesign, matching system: NSFont) -> NSFont? {
        guard let file = fileDescriptors[design] else { return nil }
        let variation = CTFontCopyVariation(system as CTFont) ?? ([:] as CFDictionary)
        let descriptor = CTFontDescriptorCreateCopyWithAttributes(file, [kCTFontVariationAttribute: variation] as CFDictionary)
        return CTFontCreateWithFontDescriptor(descriptor, system.pointSize, nil) as NSFont
    }

    #if DEBUG
    /// 自动化核对用：一段中文在对话字体下的宽度，标点被加宽时会明显变大。
    var chatProbeWidth: CGFloat {
        let font = Self.make(chatLatin, cjk: chatCJK, size: chatSize, weight: .regular)
        return NSAttributedString(string: "件。我，区；暂", attributes: [.font: font]).size().width
    }
    #endif
}

private extension Font.Weight {
    var nsWeight: NSFont.Weight {
        switch self {
        case .ultraLight: .ultraLight
        case .thin: .thin
        case .light: .light
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        case .black: .black
        default: .regular
        }
    }
}

private struct TypographyKey: EnvironmentKey {
    static let defaultValue = Typography()
}

extension EnvironmentValues {
    var typography: Typography {
        get { self[TypographyKey.self] }
        set { self[TypographyKey.self] = newValue }
    }
}

/// 界面字体：替代 `.font(.system(size:weight:))`，跟随外观设置里的「界面」字体。
private struct UIFontModifier: ViewModifier {
    let size: CGFloat
    let weight: Font.Weight
    @Environment(\.typography) private var typography

    func body(content: Content) -> some View {
        content.font(typography.ui(size, weight))
    }
}

extension View {
    func uiFont(_ size: CGFloat, _ weight: Font.Weight = .regular) -> some View {
        modifier(UIFontModifier(size: size, weight: weight))
    }
}
