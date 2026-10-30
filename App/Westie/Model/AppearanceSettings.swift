import AppKit
import Observation
import SwiftUI

/// Westie 自己的外观：浅深色、主题、颗粒质感、字体。存在 `~/.config/westie/settings.json`（`ConfigStore`），不写内核数据。
/// 主题沿用外观设置 v2 的六个预设（`deliverables/Westie/reviews/2026-10-27-appearance-settings/v2/source/themes.js`）。
@MainActor @Observable
final class AppearanceSettings {
    enum Mode: String, CaseIterable, Identifiable {
        case light, dark, system
        var id: Self { self }
        var title: String {
            switch self {
            case .light: "浅色"
            case .dark: "深色"
            case .system: "跟随系统"
            }
        }
    }

    struct Theme: Identifiable {
        let name: String
        /// 色球用的浅色主色与第二色（oklch 的 L、C、H）。
        let main: (l: Double, c: Double, h: Double)
        let second: (l: Double, c: Double, h: Double)
        var id: String { name }

        /// 喂给 Palette 的两种色调。「雾」照抄主窗口 v7 的预设，其余按「雾」的比例从色球颜色缩下来。
        var hues: [Palette.Hue] {
            if name == "雾" { return Palette.mist }
            return [Palette.Hue(h: main.h, c: main.c * 0.63), Palette.Hue(h: second.h, c: second.c * 0.36)]
        }
    }

    static let themes: [Theme] = [
        Theme(name: "雾", main: (0.84, 0.035, 70), second: (0.9, 0.045, 25)),
        Theme(name: "石墨", main: (0.8, 0.045, 250), second: (0.9, 0.04, 200)),
        Theme(name: "林", main: (0.7, 0.12, 155), second: (0.88, 0.07, 95)),
        Theme(name: "海", main: (0.66, 0.12, 245), second: (0.88, 0.07, 185)),
        Theme(name: "余烬", main: (0.7, 0.13, 50), second: (0.87, 0.07, 15)),
        Theme(name: "鸢尾", main: (0.64, 0.15, 295), second: (0.86, 0.08, 340)),
    ]

    var mode: Mode { didSet { save(); apply() } }
    var themeIndex: Int { didSet { save() } }
    var grain: Bool { didSet { save() } }
    /// 字体：存的是推荐列表里的名字，找不到就回到列表第一款（系统字体）。字号、行高等是数值。
    var uiLatin: String { didSet { save() } }
    var uiCJK: String { didSet { save() } }
    var chatLatin: String { didSet { save() } }
    var chatCJK: String { didSet { save() } }
    var chatSize: Double {
        didSet {
            let valid = Self.clamp(chatSize, to: Typography.chatSizes, fallback: 14)
            if chatSize != valid { chatSize = valid } else { save() }
        }
    }
    var codeFont: String { didSet { save() } }
    var codeSize: Double {
        didSet {
            let valid = Self.clamp(codeSize, to: Typography.codeSizes, fallback: 12.5)
            if codeSize != valid { codeSize = valid } else { save() }
        }
    }
    var lineHeight: Double {
        didSet {
            let valid = Self.clamp(lineHeight, to: Typography.lineHeights, fallback: 1.7)
            if lineHeight != valid { lineHeight = valid } else { save() }
        }
    }
    var paragraphSpacing: Double {
        didSet {
            let valid = Self.clamp(paragraphSpacing, to: Typography.paragraphSpacings, fallback: 12)
            if paragraphSpacing != valid { paragraphSpacing = valid } else { save() }
        }
    }
    var tracking: Double {
        didSet {
            let valid = Self.clamp(tracking, to: Typography.trackings, fallback: 0)
            if tracking != valid { tracking = valid } else { save() }
        }
    }
    var codeLineHeight: Double {
        didSet {
            let valid = Self.clamp(codeLineHeight, to: Typography.codeLineHeights, fallback: 1.55)
            if codeLineHeight != valid { codeLineHeight = valid } else { save() }
        }
    }
    /// 对话栏宽度（不属于搭配，换搭配时不变）。
    var chatWidth: Double {
        didSet {
            let valid = Self.normalizedChatWidth(chatWidth)
            if chatWidth != valid { chatWidth = valid } else { save() }
        }
    }

    /// 一组搭配：一点即换全部字体、字号和行距（设计稿 v4 的 B）。
    struct FontPreset: Identifiable {
        let name: String
        var uiLatin = "SF Pro", uiCJK = "苹方", chatLatin = "SF Pro", chatCJK = "苹方", code = "SF Mono"
        var chatSize = 14.0, codeSize = 12.5, lineHeight = 1.7, paragraphSpacing = 12.0
        var id: String { name }
    }

    static let fontPresets: [FontPreset] = [
        FontPreset(name: "系统"),
        FontPreset(name: "阅读", chatLatin: "New York", chatCJK: "霞鹜文楷", code: "Maple Mono NF CN",
                   chatSize: 16, codeSize: 13.5, lineHeight: 1.95, paragraphSpacing: 18),
        FontPreset(name: "书卷", chatLatin: "Georgia", chatCJK: "宋体-简", code: "Menlo", chatSize: 15),
        FontPreset(name: "清爽", uiLatin: "Helvetica Neue", uiCJK: "冬青黑体", chatLatin: "Helvetica Neue", chatCJK: "冬青黑体",
                   code: "Maple Mono NF CN"),
    ]

    /// 行距三档：行高与段距一起变。
    static let densities: [(name: String, lineHeight: Double, paragraphSpacing: Double)] = [
        ("紧凑", 1.5, 8), ("标准", 1.7, 12), ("宽松", 1.95, 18),
    ]

    func apply(_ preset: FontPreset) {
        uiLatin = preset.uiLatin; uiCJK = preset.uiCJK
        chatLatin = preset.chatLatin; chatCJK = preset.chatCJK; codeFont = preset.code
        chatSize = preset.chatSize; codeSize = preset.codeSize
        lineHeight = preset.lineHeight; paragraphSpacing = preset.paragraphSpacing
        tracking = 0; codeLineHeight = 1.55
    }

    func matches(_ preset: FontPreset) -> Bool {
        uiLatin == preset.uiLatin && uiCJK == preset.uiCJK && chatLatin == preset.chatLatin && chatCJK == preset.chatCJK
            && codeFont == preset.code && chatSize == preset.chatSize && codeSize == preset.codeSize
            && lineHeight == preset.lineHeight && paragraphSpacing == preset.paragraphSpacing
            && tracking == 0 && codeLineHeight == 1.55
    }

    /// 只拖一根字号滑杆时，代码字号跟着走：对话字号的 0.9 倍，取到半号。
    func setChatSizeKeepingRatio(_ size: Double) {
        chatSize = size
        codeSize = (chatSize * 0.9 * 2).rounded() / 2
    }

    var typography: Typography {
        Typography(
            uiLatin: FontOption.find(uiLatin, in: FontOption.uiLatin),
            uiCJK: FontOption.find(uiCJK, in: FontOption.uiCJK),
            chatLatin: FontOption.find(chatLatin, in: FontOption.chatLatin),
            chatCJK: FontOption.find(chatCJK, in: FontOption.chatCJK),
            chatSize: chatSize,
            codeFont: FontOption.find(codeFont, in: FontOption.code),
            codeSize: codeSize,
            lineHeight: lineHeight,
            paragraphSpacing: paragraphSpacing,
            tracking: tracking,
            codeLineHeight: codeLineHeight,
            chatWidth: chatWidth
        )
    }

    var theme: Theme { Self.themes[min(max(themeIndex, 0), Self.themes.count - 1)] }

    @ObservationIgnored private let store: ConfigStore
    nonisolated static let key = "appearance"

    init(store: ConfigStore = .shared) {
        self.store = store
        let saved = store[Self.key] as? [String: Any] ?? [:]
        mode = (saved["mode"] as? String).flatMap(Mode.init) ?? .system
        themeIndex = saved["theme"] as? Int ?? 0
        grain = saved["grain"] as? Bool ?? true
        let fonts = saved["fonts"] as? [String: Any] ?? [:]
        uiLatin = fonts["uiLatin"] as? String ?? FontOption.uiLatin[0].name
        uiCJK = fonts["uiCJK"] as? String ?? FontOption.uiCJK[0].name
        chatLatin = fonts["chatLatin"] as? String ?? FontOption.chatLatin[0].name
        chatCJK = fonts["chatCJK"] as? String ?? FontOption.chatCJK[0].name
        chatSize = Self.clamp(fonts["chatSize"] as? Double ?? 14, to: Typography.chatSizes, fallback: 14)
        codeFont = fonts["code"] as? String ?? FontOption.code[0].name
        codeSize = Self.clamp(fonts["codeSize"] as? Double ?? 12.5, to: Typography.codeSizes, fallback: 12.5)
        lineHeight = Self.clamp(fonts["lineHeight"] as? Double ?? 1.7, to: Typography.lineHeights, fallback: 1.7)
        paragraphSpacing = Self.clamp(fonts["paragraphSpacing"] as? Double ?? 12, to: Typography.paragraphSpacings, fallback: 12)
        tracking = Self.clamp(fonts["tracking"] as? Double ?? 0, to: Typography.trackings, fallback: 0)
        codeLineHeight = Self.clamp(fonts["codeLineHeight"] as? Double ?? 1.55, to: Typography.codeLineHeights, fallback: 1.55)
        chatWidth = Self.normalizedChatWidth(fonts["chatWidth"] as? Double ?? 760)
        // 将迁移与修复后的数值写回，避免下一次启动重新读到旧值。
        save()
    }

    private static func clamp(_ value: Double, to range: ClosedRange<CGFloat>, fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    private static func normalizedChatWidth(_ value: Double) -> Double {
        guard value.isFinite, value >= 0 else { return 760 }
        // 拉到头（1240）及以上迁移为铺满；旧滑杆的中间宽度吸附到最近的一档，保证总有一张卡选中。
        if value == 0 || value >= 1240 { return 0 }
        let widths = Typography.chatWidthOptions.map { Double($0.width) }.filter { $0 > 0 }
        return widths.min { abs($0 - value) < abs($1 - value) } ?? 760
    }

    /// 浅深色落在 App 级 appearance 上（菜单、弹层一起变），不动系统设置。
    func apply() {
        switch mode {
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        case .system: NSApp.appearance = nil
        }
    }

    private func save() {
        let fonts: [String: Any] = [
            "uiLatin": uiLatin, "uiCJK": uiCJK, "chatLatin": chatLatin, "chatCJK": chatCJK,
            "chatSize": chatSize, "code": codeFont, "codeSize": codeSize,
            "lineHeight": lineHeight, "paragraphSpacing": paragraphSpacing, "tracking": tracking, "codeLineHeight": codeLineHeight, "chatWidth": chatWidth,
        ]
        store[Self.key] = ["mode": mode.rawValue, "theme": themeIndex, "grain": grain, "fonts": fonts]
    }
}
