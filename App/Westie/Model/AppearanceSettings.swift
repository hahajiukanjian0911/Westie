import AppKit
import Observation
import SwiftUI

/// Westie 自己的外观：浅深色、主题、颗粒质感、字体。只存在 UserDefaults，不写 `~/.dsh`。
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
    var chatSize: Double { didSet { save() } }
    var codeFont: String { didSet { save() } }
    var codeSize: Double { didSet { save() } }
    var lineHeight: Double { didSet { save() } }
    var paragraphSpacing: Double { didSet { save() } }
    var tracking: Double { didSet { save() } }
    var codeLineHeight: Double { didSet { save() } }
    /// 对话栏宽度（不属于搭配，换搭配时不变）。
    var chatWidth: Double { didSet { save() } }

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
        codeSize = (size * 0.9 * 2).rounded() / 2
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

    @ObservationIgnored private let defaults: UserDefaults
    private static let key = "Westie.appearance.v1"

    /// 自动化测试用单独的存储（与面板布局同一个 suite），不动日常使用的外观。
    private static var storage: UserDefaults {
        guard ProcessInfo.processInfo.environment["WESTIE_AUTOMATION"] != nil,
              let suite = UserDefaults(suiteName: "com.hahajiukanjian.westie.automation")
        else { return .standard }
        return suite
    }

    init(defaults: UserDefaults = AppearanceSettings.storage) {
        self.defaults = defaults
        let saved = defaults.dictionary(forKey: Self.key) ?? [:]
        mode = (saved["mode"] as? String).flatMap(Mode.init) ?? .system
        themeIndex = saved["theme"] as? Int ?? 0
        grain = saved["grain"] as? Bool ?? true
        let fonts = saved["fonts"] as? [String: Any] ?? [:]
        uiLatin = fonts["uiLatin"] as? String ?? FontOption.uiLatin[0].name
        uiCJK = fonts["uiCJK"] as? String ?? FontOption.uiCJK[0].name
        chatLatin = fonts["chatLatin"] as? String ?? FontOption.chatLatin[0].name
        chatCJK = fonts["chatCJK"] as? String ?? FontOption.chatCJK[0].name
        chatSize = fonts["chatSize"] as? Double ?? 14
        codeFont = fonts["code"] as? String ?? FontOption.code[0].name
        codeSize = fonts["codeSize"] as? Double ?? 12.5
        lineHeight = fonts["lineHeight"] as? Double ?? 1.7
        paragraphSpacing = fonts["paragraphSpacing"] as? Double ?? 12
        tracking = fonts["tracking"] as? Double ?? 0
        codeLineHeight = fonts["codeLineHeight"] as? Double ?? 1.55
        chatWidth = fonts["chatWidth"] as? Double ?? 760
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
        defaults.set(["mode": mode.rawValue, "theme": themeIndex, "grain": grain, "fonts": fonts], forKey: Self.key)
    }
}
