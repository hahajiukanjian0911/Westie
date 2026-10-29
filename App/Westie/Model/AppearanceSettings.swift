import AppKit
import Observation
import SwiftUI

/// Westie 自己的外观：浅深色、主题、颗粒质感。只存在 UserDefaults，不写 `~/.dsh`。
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
        defaults.set(["mode": mode.rawValue, "theme": themeIndex, "grain": grain], forKey: Self.key)
    }
}
