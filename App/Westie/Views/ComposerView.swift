import SwiftUI
import WestieKit

/// 输入框：回车发送、Shift+回车换行，随内容长高（最多 10 行）；运行中显示停止按钮。
struct ComposerView: View {
    let model: AppModel
    let conversation: ConversationModel
    let running: Bool
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("给 Agent 发消息", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
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
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
        .background(.background, in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
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
            .font(.callout)
        }
        .buttonStyle(.borderless)
        .disabled(model.models.isEmpty)
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            ModelPicker(model: model, conversation: conversation, initial: current)
        }
    }
}

private struct ModelPicker: View {
    let model: AppModel
    let conversation: ConversationModel
    @State private var choice: ModelChoice?
    @State private var effortIndex: Double = 0

    init(model: AppModel, conversation: ConversationModel, initial: (choice: ModelChoice?, effort: String?)) {
        self.model = model
        self.conversation = conversation
        _choice = State(initialValue: initial.choice)
        let efforts = initial.choice?.efforts ?? []
        _effortIndex = State(initialValue: Double(efforts.firstIndex(of: initial.effort ?? "") ?? 0))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("模型", selection: $choice) {
                ForEach(model.models) { option in
                    Text(option.name).tag(Optional(option))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            if let efforts = choice?.efforts, efforts.count > 1 {
                VStack(alignment: .leading, spacing: 4) {
                    Text("思考：\(efforts[min(Int(effortIndex), efforts.count - 1)])")
                        .font(.callout)
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
