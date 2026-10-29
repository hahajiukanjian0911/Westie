import SwiftUI
import WestieKit

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, account, appearance, advanced
    var id: Self { self }

    var title: String {
        switch self {
        case .general: "通用"
        case .account: "账号"
        case .appearance: "外观"
        case .advanced: "高级"
        }
    }

    var icon: String {
        switch self {
        case .general: "slider.horizontal.3"
        case .account: "person"
        case .appearance: "circle.lefthalf.filled"
        case .advanced: "terminal"
        }
    }
}

/// 设置卡片（设计稿 `deliverables/Westie/reviews/2026-10-29-settings/v1` 方向 B）：
/// 和会话窗口一样是工作台里的一张卡片；卡片里左侧分页，右侧居中一栏分组表单。
struct SettingsView: View {
    let model: AppModel
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 0) {
            nav
            Rectangle().fill(palette.cardStroke).frame(width: 0.5)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text(model.settings.tab.title)
                        .font(.system(size: 20, weight: .semibold))
                    page
                }
                .frame(maxWidth: 520, alignment: .leading)
                .padding(.horizontal, 32)
                .padding(.top, 12)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.never)
        }
        .overlay(alignment: .bottom) { errorLine }
    }

    private var nav: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(SettingsTab.allCases) { tab in
                SettingsNavRow(tab: tab, selected: model.settings.tab == tab) { model.settings.tab = tab }
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .frame(width: 176)
    }

    @ViewBuilder
    private var page: some View {
        switch model.settings.tab {
        case .general: GeneralPage(model: model)
        case .account: AccountPage(settings: model.settings)
        case .appearance: AppearancePage(appearance: model.appearance)
        case .advanced: AdvancedPage(settings: model.settings)
        }
    }

    @ViewBuilder
    private var errorLine: some View {
        if let message = model.settings.error {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(palette.bad)
                Text(message).lineLimit(2)
                Button("关闭", systemImage: "xmark") { model.settings.dismissError() }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(palette.box, in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(palette.boxStroke, lineWidth: 0.5))
            .padding(12)
        }
    }
}

private struct SettingsNavRow: View {
    let tab: SettingsTab
    let selected: Bool
    let action: () -> Void
    @Environment(\.palette) private var palette
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: tab.icon)
                    .font(.system(size: 12))
                    .foregroundStyle(selected ? palette.ink : palette.ink3)
                    .frame(width: 16)
                Text(tab.title).foregroundStyle(selected ? palette.ink : palette.ink2)
                Spacer(minLength: 0)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(
                selected ? palette.placeholder : hovering ? palette.rowHoverSolid : .clear,
                in: .rect(cornerRadius: Metrics.rowRadius)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - 表单零件

/// 一组设置：可选的小标题 + 一个白底圆角盒子，盒子里的行之间是细分隔线。
private struct SettingsGroup<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title).font(.system(size: 12)).foregroundStyle(palette.ink3).padding(.horizontal, 2)
            }
            VStack(spacing: 0) {
                Group(subviews: content) { rows in
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        if index > 0 { Rectangle().fill(palette.boxStroke.opacity(0.7)).frame(height: 0.5) }
                        row
                    }
                }
            }
            .background(palette.box, in: .rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(palette.boxStroke, lineWidth: 0.5))
        }
    }
}

private struct SettingsRow<Trailing: View>: View {
    let label: String
    @ViewBuilder var trailing: Trailing
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 16) {
            Text(label).foregroundStyle(palette.ink).lineLimit(1)
            Spacer(minLength: 8)
            trailing
        }
        .font(.system(size: 13))
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
    }
}

// MARK: - 通用

private struct GeneralPage: View {
    let model: AppModel
    @Environment(\.palette) private var palette

    private var settings: SettingsModel { model.settings }

    private var current: ModelChoice? {
        guard let selected = settings.defaultModel else { return model.defaultModel }
        return model.models.first { $0.provider == selected.provider && $0.model == selected.model } ?? model.defaultModel
    }

    var body: some View {
        SettingsGroup(title: "新会话默认") {
            SettingsRow(label: "模型") {
                if model.models.isEmpty {
                    Text("没有可用的模型").foregroundStyle(palette.ink3)
                } else {
                    Picker("模型", selection: Binding(get: { current }, set: { choice in
                        guard let choice else { return }
                        Task { await settings.setDefaultModel(choice, effort: choice.defaultEffort) }
                    })) {
                        ForEach(model.models) { Text($0.name).tag(Optional($0)) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            if let choice = current, choice.efforts.count > 1 {
                SettingsRow(label: "思考档位") {
                    EffortSlider(efforts: choice.efforts, effort: settings.defaultModel?.effort ?? choice.defaultEffort) { effort in
                        Task { await settings.setDefaultModel(choice, effort: effort) }
                    }
                }
            }
            SettingsRow(label: "权限") {
                Picker("权限", selection: Binding(get: { settings.permissionPreset }, set: { preset in
                    Task { await settings.setPermission(preset) }
                })) {
                    ForEach(SettingsModel.presets, id: \.0) { Text($0.1).tag($0.0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
    }
}

/// 思考档位：滑杆，档位名写在滑杆旁边。拖动中只改显示，松手才写进内核。
private struct EffortSlider: View {
    let efforts: [String]
    let effort: String?
    let commit: (String) -> Void
    @State private var index: Double = 0
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 12) {
            Slider(value: $index, in: 0...Double(efforts.count - 1), step: 1) { editing in
                if !editing { commit(efforts[Int(index)]) }
            }
            .frame(width: 180)
            Text(Self.label(efforts[min(Int(index), efforts.count - 1)]))
                .foregroundStyle(palette.ink)
                .frame(minWidth: 40, alignment: .leading)
        }
        .onChange(of: effort, initial: true) {
            index = Double(efforts.firstIndex(of: effort ?? "") ?? efforts.count - 1)
        }
    }

    static func label(_ effort: String) -> String {
        switch effort {
        case "none", "off": "关"
        case "minimal": "最低"
        case "low": "低"
        case "medium": "中"
        case "high": "高"
        case "xhigh": "很高"
        case "max": "最高"
        default: effort
        }
    }
}

// MARK: - 账号

private struct AccountPage: View {
    let settings: SettingsModel
    @Environment(\.palette) private var palette
    @State private var editingKey = false

    var body: some View {
        SettingsGroup(title: "DeepSeek 账号") {
            switch settings.account {
            case .unknown:
                SettingsRow(label: "DeepSeek 账号") { ProgressView().controlSize(.small) }
            case .signedOut:
                SettingsRow(label: "未登录") {
                    Button("登录") { Task { await settings.signIn() } }
                }
            case .signingIn:
                SettingsRow(label: "正在浏览器中登录…") {
                    Button("取消") { Task { await settings.cancelSignIn() } }
                }
            case .signedIn(let name, let balance):
                SettingsRow(label: name ?? "已登录") {
                    HStack(spacing: 10) {
                        if let balance { Text("余额 \(balance)").foregroundStyle(palette.ink3).monospacedDigit() }
                        Button("退出登录") { Task { await settings.signOut() } }
                            .buttonStyle(.borderless)
                            .foregroundStyle(palette.ink3)
                    }
                }
            }
        }
        SettingsGroup(title: "API Key") {
            SettingsRow(label: "DeepSeek") {
                HStack(spacing: 10) {
                    Text(settings.apiKeyConfigured ? "已设置" : "未设置").foregroundStyle(palette.ink3)
                    Button(settings.apiKeyConfigured ? "更换" : "添加") { editingKey = true }
                        .popover(isPresented: $editingKey, arrowEdge: .bottom) {
                            APIKeyEditor(settings: settings) { editingKey = false }
                        }
                }
            }
        }
    }
}

/// 输入新密钥：只往内核写，内核不会把它读回来。
private struct APIKeyEditor: View {
    let settings: SettingsModel
    let done: () -> Void
    @State private var value = ""

    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {
            SecureField("sk-…", text: $value)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .onSubmit(save)
            HStack {
                if settings.apiKeyConfigured {
                    Button("移除", role: .destructive) {
                        Task { await settings.removeAPIKey() }
                        done()
                    }
                }
                Spacer()
                Button("取消", action: done)
                Button("保存", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(14)
        .frame(width: 288)
    }

    private func save() {
        let key = value
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Task { await settings.setAPIKey(key) }
        done()
    }
}

// MARK: - 外观

private struct AppearancePage: View {
    @Bindable var appearance: AppearanceSettings
    @Environment(\.palette) private var palette

    var body: some View {
        SettingsGroup {
            SettingsRow(label: "外观") {
                Picker("外观", selection: $appearance.mode) {
                    ForEach(AppearanceSettings.Mode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
        SettingsGroup(title: "主题") {
            HStack(spacing: 6) {
                ForEach(Array(AppearanceSettings.themes.enumerated()), id: \.offset) { index, theme in
                    ThemeOrb(theme: theme, selected: appearance.themeIndex == index) { appearance.themeIndex = index }
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 14)
            .padding(.bottom, 12)
            SettingsRow(label: "颗粒质感") {
                Toggle("颗粒质感", isOn: $appearance.grain).toggleStyle(.switch).labelsHidden().controlSize(.small)
            }
        }
    }
}

/// 主题色球：近白的底，主色从右上、第二色从左下晕开（同外观设置 v2 的浅色色球）。
private struct ThemeOrb: View {
    let theme: AppearanceSettings.Theme
    let selected: Bool
    let pick: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: pick) {
            VStack(spacing: 7) {
                ZStack {
                    Palette.oklch(0.985, 0.005, theme.main.h, 1)
                    RadialGradient(colors: [color(theme.main), color(theme.main).opacity(0)], center: UnitPoint(x: 0.96, y: 0.02), startRadius: 0, endRadius: 30)
                    RadialGradient(colors: [color(theme.second), color(theme.second).opacity(0)], center: UnitPoint(x: 0.02, y: 0.98), startRadius: 0, endRadius: 28)
                }
                .frame(width: 34, height: 34)
                .clipShape(.circle)
                .overlay(Circle().strokeBorder(.black.opacity(0.1), lineWidth: 0.5))
                .padding(3.5)
                .overlay(Circle().strokeBorder(selected ? palette.accent : .clear, lineWidth: 1.5))
                Text(theme.name)
                    .font(.system(size: 12))
                    .foregroundStyle(selected ? palette.ink : palette.ink3)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(theme.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func color(_ value: (l: Double, c: Double, h: Double)) -> Color {
        Palette.oklch(value.l, value.c, value.h, 1)
    }
}

// MARK: - 高级

private struct AdvancedPage: View {
    let settings: SettingsModel
    @Environment(\.palette) private var palette

    var body: some View {
        SettingsGroup(title: "子代理") {
            SettingsRow(label: "最多嵌套") {
                CountStepper(value: settings.maxDepth, range: 0...8) { value in Task { await settings.setMaxDepth(value) } }
            }
            SettingsRow(label: "同时运行") {
                CountStepper(value: settings.maxActive, range: 1...32) { value in Task { await settings.setMaxActive(value) } }
            }
        }
        SettingsGroup {
            SettingsRow(label: "附带会话日志帮助改进") {
                Toggle("附带会话日志帮助改进", isOn: Binding(get: { settings.sessionLog }, set: { value in
                    Task { await settings.setSessionLog(value) }
                }))
                .toggleStyle(.switch).labelsHidden().controlSize(.small)
            }
        }
        SettingsGroup {
            SettingsRow(label: "设置文件") {
                Button("在编辑器中打开") { Task { await settings.openSettingsDocument() } }
            }
        }
    }
}

private struct CountStepper: View {
    let value: Int
    let range: ClosedRange<Int>
    let change: (Int) -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 6) {
            Text("\(value)").monospacedDigit().foregroundStyle(palette.ink).frame(minWidth: 20, alignment: .trailing)
            Stepper("", value: Binding(get: { value }, set: change), in: range).labelsHidden()
        }
    }
}
