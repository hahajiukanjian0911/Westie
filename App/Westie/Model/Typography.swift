import AppKit
import SwiftUI

/// 字体：界面、对话、代码三类（设计稿 `deliverables/Westie/reviews/2026-10-29-settings/v2`）。
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
        FontOption(name: "Source Serif 4", family: "Source Serif 4", cask: "font-source-serif-4"),
    ]
    static let chatCJK: [FontOption] = [
        pingFang,
        FontOption(name: "霞鹜文楷", family: "LXGW WenKai", cask: "font-lxgw-wenkai"),
        FontOption(name: "思源宋体", family: "Noto Serif CJK SC", cask: "font-noto-serif-cjk-sc"),
        FontOption(name: "宋体-简", family: "Songti SC"),
        FontOption(name: "楷体-简", family: "Kaiti SC"),
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

    static let chatSizes: ClosedRange<CGFloat> = 13...18
    static let codeSizes: ClosedRange<CGFloat> = 11...16

    /// 字号显示：整数不带小数，半号带一位。
    static func sizeLabel(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }

    func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        Font(Self.make(uiLatin, cjk: uiCJK, size: size, weight: weight))
    }

    var chat: Font { Font(Self.make(chatLatin, cjk: chatCJK, size: chatSize, weight: .regular)) }

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
            switch latin.design {
            case .monospaced: base = .monospacedSystemFont(ofSize: size, weight: nsWeight)
            case .serif:
                let system = NSFont.systemFont(ofSize: size, weight: nsWeight)
                base = system.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: size) } ?? system
            case .standard: base = .systemFont(ofSize: size, weight: nsWeight)
            }
        }
        guard let family = cjk?.family else { return base }
        let fallback = NSFontDescriptor(fontAttributes: [.family: family, .traits: [NSFontDescriptor.TraitKey.weight: nsWeight]])
        let descriptor = base.fontDescriptor.addingAttributes([.cascadeList: [fallback]])
        return NSFont(descriptor: descriptor, size: size) ?? base
    }
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
