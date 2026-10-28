import SwiftUI

// MARK: - Overview
//
// HighlightedTextFragment displays syntax-highlighted code using a two-phase approach.
// Tokenization runs asynchronously and is keyed by content, while highlighting runs
// synchronously on token or environment changes (theme, color scheme, dynamic type).
//
// The presentationIntent is preserved after highlighting so pasteboard formatters can
// reconstruct the block structure when copying code.

struct HighlightedTextFragment: View {
  @Environment(\.textEnvironment) private var textEnvironment

  @State private var model = Model()

  private let content: AttributedSubstring
  private let languageHint: String?
  private let theme: StructuredText.HighlighterTheme

  init(
    _ content: AttributedSubstring,
    languageHint: String?,
    theme: StructuredText.HighlighterTheme
  ) {
    self.content = content
    self.languageHint = languageHint
    self.theme = theme
  }

  var body: some View {
    TextFragment(model.highlightedCode ?? AttributedString(content))
      .foregroundStyle(theme.foregroundColor)
      .task(id: content) {
        await model.tokenize(
          content: content,
          languageHint: languageHint
        )
      }
      .onChange(of: Tuple(model.tokens, textEnvironment)) { _, newValue in
        model.highlight(
          tokens: newValue.values.0,
          content: content,
          presentationIntent: content.presentationIntent,
          using: theme,
          environment: newValue.values.1
        )
      }
  }
}

extension HighlightedTextFragment {
  @MainActor @Observable final class Model {
    var tokens: [CodeToken] = []
    var highlightedCode: AttributedString?

    func tokenize(content: AttributedSubstring, languageHint: String?) async {
      let code = String(content.characters[...])
      // Westie 补丁：流式追加时保留已分好的 token，只把新增部分先当普通文本，
      // 避免每来一段字整块先变回无色再上色。
      let previous = tokens.map(\.content).joined()
      if !previous.isEmpty, code.hasPrefix(previous), code != previous {
        tokens = tokens + [CodeToken(content: String(code.dropFirst(previous.count)), type: .plain)]
      } else if code != previous {
        tokens = [CodeToken(content: code, type: .plain)]
      }

      if let tokenizer = CodeTokenizer.shared, let languageHint {
        let result = await tokenizer.tokenize(code: code, language: languageHint)
        // 内容已经变了：这份结果过期，交给新的任务
        guard !Task.isCancelled else { return }
        tokens = result
      }
    }

    func highlight(
      tokens: [CodeToken],
      content: AttributedSubstring? = nil,
      presentationIntent: PresentationIntent?,
      using theme: StructuredText.HighlighterTheme,
      environment: TextEnvironmentValues
    ) {
      var attributes = AttributeContainer()
      // Re-apply the presentation intent for pasteboard formatters
      attributes.presentationIntent = presentationIntent
      ForegroundColorProperty(theme.foregroundColor)
        .apply(in: &attributes, environment: environment)
      var highlightedCode = AttributedString()

      for token in tokens {
        var content = AttributedString(token.content)
        var tokenAttributes = attributes

        if let tokenProperties = theme.tokenProperties[token.type] {
          tokenProperties.apply(in: &tokenAttributes, environment: environment)
        }

        content.mergeAttributes(tokenAttributes)
        highlightedCode.append(content)
      }

      // Westie 补丁：高亮会重建字符串，把原文上的到达时间按字符位置搬过来
      if let content, highlightedCode.characters.count == content.characters.count {
        for (birth, range) in content.runs[AttributeScopes.TextualAttributes.StreamBirthAttribute.self] {
          guard let birth else { continue }
          let lower = content.characters.distance(from: content.startIndex, to: range.lowerBound)
          let upper = content.characters.distance(from: content.startIndex, to: range.upperBound)
          let start = highlightedCode.characters.index(highlightedCode.startIndex, offsetBy: lower)
          let end = highlightedCode.characters.index(highlightedCode.startIndex, offsetBy: upper)
          highlightedCode[start..<end].textual.streamBirth = birth
        }
      }

      self.highlightedCode = highlightedCode
    }
  }
}
