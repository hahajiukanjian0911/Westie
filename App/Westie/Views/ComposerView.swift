import SwiftUI
import WestieKit

/// 输入框：回车发送、Shift+回车换行，随内容长高（最多 10 行）；运行中显示停止按钮。
struct ComposerView: View {
    let model: AppModel
    let conversation: ConversationModel
    let running: Bool
    @State private var draft = ""
    @FocusState private var focused: Bool
    @Environment(\.palette) private var palette
    @Environment(\.typography) private var typography

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("给 Agent 发消息", text: $draft, prompt: Text("给 Agent 发消息").foregroundStyle(palette.ink4), axis: .vertical)
                .textFieldStyle(.plain)
                .font(typography.chat)
                .lineLimit(1...10)
                .focused($focused)
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.shift) { return .ignored }
                    send()
                    return .handled
                }
            HStack {
                ModelMenu(model: model, conversation: conversation)
                Spacer()
                if running {
                    Button("停止", systemImage: "stop.fill") {
                        Task { await model.cancel(sessionId: conversation.sessionId) }
                    }
                    .labelStyle(.iconOnly)
                    .help("停止当前回合")
                }
                Button("发送", systemImage: "arrow.up") { send() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(SendButtonStyle())
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
        .background(palette.box, in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(palette.boxStroke, lineWidth: 0.5))
        .shadow(color: palette.boxShadow, radius: 4, y: 2)
        .onAppear { focused = true }
    }

    private func send() {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        draft = ""
        Task { await model.send(text, to: conversation.sessionId) }
    }
}

/// 模型与思考档位。思考档位按约定做成滑杆，收在模型弹层里。
private struct ModelMenu: View {
    let model: AppModel
    let conversation: ConversationModel
    @State private var showing = false

    private var current: (choice: ModelChoice?, effort: String?) {
        if let override = conversation.modelOverride { return (override.choice, override.effort) }
        if let selection = conversation.modelSelection {
            let choice = model.models.first { $0.provider == selection.provider && $0.model == selection.model }
            return (choice, selection.effort ?? choice?.defaultEffort)
        }
        return (model.defaultModel, model.defaultModel?.defaultEffort)
    }

    var body: some View {
        Button {
            showing.toggle()
        } label: {
            HStack(spacing: 4) {
                Text(current.choice?.name ?? "模型")
                if let effort = current.effort { Text("· \(effort)").foregroundStyle(.secondary) }
                Image(systemName: "chevron.down").imageScale(.small)
            }
            .uiFont(12)
        }
        .buttonStyle(.borderless)
        .disabled(model.models.isEmpty)
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            ModelPicker(model: model, conversation: conversation, initial: current)
        }
    }
}

struct ModelPicker: View {
    let model: AppModel
    let conversation: ConversationModel
    @State private var choice: ModelChoice?
    @State private var effortIndex: Double = 0
    @Environment(\.palette) private var palette

    private var groups: [(name: String, models: [ModelChoice])] {
        var result: [(name: String, models: [ModelChoice])] = []
        for option in model.models {
            if let index = result.firstIndex(where: { $0.name == option.group }) {
                result[index].models.append(option)
            } else {
                result.append((option.group, [option]))
            }
        }
        return result
    }

    init(model: AppModel, conversation: ConversationModel, initial: (choice: ModelChoice?, effort: String?)) {
        self.model = model
        self.conversation = conversation
        _choice = State(initialValue: initial.choice)
        let efforts = initial.choice?.efforts ?? []
        _effortIndex = State(initialValue: Double(efforts.firstIndex(of: initial.effort ?? "") ?? 0))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 自己画的单选行：系统的单选 Picker 不跟随界面字体。有多个提供方时按提供方分组，同名模型才分得清。
            VStack(alignment: .leading, spacing: 2) {
                ForEach(groups, id: \.name) { group in
                    if groups.count > 1 {
                        Text(group.name).uiFont(11).foregroundStyle(palette.ink3)
                            .padding(.top, group.name == groups.first?.name ? 0 : 6).padding(.leading, 6)
                    }
                    ForEach(group.models) { option in
                        ModelRow(name: option.name, selected: option == choice) { choice = option }
                    }
                }
            }
            if let efforts = choice?.efforts, efforts.count > 1 {
                VStack(alignment: .leading, spacing: 4) {
                    Text("思考：\(efforts[min(Int(effortIndex), efforts.count - 1)])")
                        .uiFont(12)
                    Slider(value: $effortIndex, in: 0...Double(efforts.count - 1), step: 1)
                }
            }
        }
        .padding(14)
        .frame(width: 260)
        .onChange(of: choice) { _, new in
            effortIndex = Double(new?.efforts.firstIndex(of: new?.defaultEffort ?? "") ?? 0)
            apply()
        }
        .onChange(of: effortIndex) { apply() }
    }

    private func apply() {
        guard let choice else { return }
        let efforts = choice.efforts
        let effort = efforts.isEmpty ? nil : efforts[min(Int(effortIndex), efforts.count - 1)]
        Task { await model.selectModel(choice, effort: effort, for: conversation.sessionId) }
    }
}

private struct ModelRow: View {
    let name: String
    let selected: Bool
    let action: () -> Void
    @Environment(\.palette) private var palette
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .uiFont(10, .semibold)
                    .foregroundStyle(palette.accent)
                    .opacity(selected ? 1 : 0)
                Text(name).uiFont(13).foregroundStyle(palette.ink)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .frame(height: 26)
            .background(hovering ? palette.rowHover : .clear, in: .rect(cornerRadius: 6))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// 发送：强调色圆按钮，没内容时变淡（同主窗口 v7）。
private struct SendButtonStyle: ButtonStyle {
    @Environment(\.palette) private var palette
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .uiFont(13, .semibold)
            .foregroundStyle(palette.onAccent)
            .frame(width: 28, height: 28)
            .background(palette.accent, in: .circle)
            .opacity(enabled ? 1 : 0.35)
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.24), value: configuration.isPressed)
    }
}
