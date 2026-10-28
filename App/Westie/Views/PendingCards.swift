import SwiftUI

struct ApprovalCard: View {
    let approval: PendingApproval
    let answer: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("需要你的允许：\(approval.toolName)", systemImage: "hand.raised")
                .font(.headline)
            Text(approval.reason)
                .textSelection(.enabled)
                .foregroundStyle(.secondary)
            HStack {
                Button("拒绝") { answer(false) }
                Button("允许一次") { answer(true) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.08), in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.orange.opacity(0.35)))
    }
}

struct QuestionCard: View {
    let question: PendingQuestion
    let answer: ([String: [String]], [String: String]) -> Void
    @State private var selections: [String: [String]] = [:]
    @State private var custom: [String: String] = [:]

    private var complete: Bool {
        question.items.allSatisfy { !(selections[$0.id] ?? []).isEmpty || !(custom[$0.id] ?? "").isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(question.items) { item in
                VStack(alignment: .leading, spacing: 8) {
                    if let header = item.header {
                        Text(header).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(item.question).font(.headline)
                    ForEach(item.options, id: \.label) { option in
                        Toggle(isOn: binding(item, option.label)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.label)
                                if let description = option.description {
                                    Text(description).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                    TextField("其他回答（可选）", text: Binding(
                        get: { custom[item.id] ?? "" }, set: { custom[item.id] = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                }
            }
            Button("提交回答") { answer(selections, custom) }
                .buttonStyle(.borderedProminent)
                .disabled(!complete)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.blue.opacity(0.06), in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.blue.opacity(0.3)))
    }

    /// 单选题选中即替换，多选题切换。
    private func binding(_ item: PendingQuestion.Item, _ label: String) -> Binding<Bool> {
        Binding(
            get: { selections[item.id, default: []].contains(label) },
            set: { on in
                var current = selections[item.id, default: []]
                if item.multiSelect {
                    if on { current.append(label) } else { current.removeAll { $0 == label } }
                } else {
                    current = on ? [label] : []
                }
                selections[item.id] = current
            }
        )
    }
}
