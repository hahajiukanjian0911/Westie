import Foundation

/// 从流式思考中取最近一句完整的话；省略未写完的尾句。
public enum ThoughtSentence {
    public static func lastComplete(in text: String) -> String? {
        var last: String?
        var start = text.startIndex
        var index = start
        let closers: Set<Character> = ["\"", "'", "”", "’", "」", "』", "）", ")"]
        let abbreviations: Set<String> = ["mr.", "mrs.", "ms.", "dr.", "prof.", "sr.", "jr.", "e.g.", "i.e.", "vs.", "etc."]
        while index < text.endIndex {
            let char = text[index]
            var next = text.index(after: index)
            var ends = false
            switch char {
            case "。", "！", "？", "!", "?", "\n":
                ends = true
            case "…":
                // 中文省略号是两个 …，一个还可能是尚未传完的标点。
                while next < text.endIndex, text[next] == "…" { next = text.index(after: next) }
                ends = text.distance(from: index, to: next) >= 2
            case ".":
                // 句点后需已收到空白（或闭引号及空白），避免把文件名、小数和未传完的词拆开。
                var after = next
                while after < text.endIndex, closers.contains(text[after]) { after = text.index(after: after) }
                if after < text.endIndex, text[after].isWhitespace {
                    let token = text[start..<next].split(whereSeparator: { $0.isWhitespace }).last.map(String.init) ?? ""
                    let parts = token.split(separator: ".")
                    let initial = !parts.isEmpty && parts.allSatisfy { $0.count == 1 && $0.allSatisfy(\.isLetter) }
                    ends = !abbreviations.contains(token.lowercased()) && !initial
                }
            default:
                break
            }
            if ends {
                while next < text.endIndex, closers.contains(text[next]) { next = text.index(after: next) }
                let sentence = text[start..<next].trimmingCharacters(in: .whitespacesAndNewlines)
                // 标点本身不构成思考句（连续问号、省略号后面等）。
                if sentence.contains(where: { $0.isLetter || $0.isNumber }) { last = sentence }
                start = next
            }
            index = next
        }
        return last
    }
}
