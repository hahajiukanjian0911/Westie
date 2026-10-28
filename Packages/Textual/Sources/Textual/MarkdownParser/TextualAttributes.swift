import SwiftUI

extension AttributeScopes {
  /// Attributes used by Textual when parsing and rendering markup.
  public struct TextualAttributes: AttributeScope {
    /// Stores an attachment value in attributed content.
    public enum AttachmentAttribute: AttributedStringKey {
      public typealias Value = AnyAttachment
      public static let name = "Textual.Attachment"
    }

    /// Stores a URL for a custom emoji placeholder.
    ///
    /// Textual uses this attribute as an intermediate representation before resolving emoji into
    /// an attachment.
    public enum EmojiURLAttribute: AttributedStringKey {
      public typealias Value = URL
      public static let name = "Textual.EmojiURL"
    }

    /// Westie 补丁：流式输出时字的到达时间（`Date.timeIntervalSinceReferenceDate`）。
    /// 渲染时转成 ``StreamBirth`` 自定义属性，供 TextRenderer 按时间画淡入。
    public enum StreamBirthAttribute: AttributedStringKey {
      public typealias Value = Double
      public static let name = "Textual.StreamBirth"
    }

    /// A property for accessing an attachment attribute.
    public let attachment: AttachmentAttribute

    /// A property for accessing an emoji URL attribute.
    public let emojiURL: EmojiURLAttribute

    /// Westie 补丁：到达时间。
    public let streamBirth: StreamBirthAttribute

    public let foundation: AttributeScopes.FoundationAttributes
  }

  /// The Textual attribute scope.
  public var textual: TextualAttributes.Type {
    TextualAttributes.self
  }
}

extension AttributeDynamicLookup {
  /// Provides dynamic member lookup for Textual attributes.
  public subscript<T: AttributedStringKey>(
    dynamicMember keyPath: KeyPath<AttributeScopes.TextualAttributes, T>
  ) -> T {
    return self[T.self]
  }
}

/// Westie 补丁：带有 `streamBirth` 的文字在 `Text.Layout.Run` 上可读到这个属性。
public struct StreamBirth: TextAttribute {
  public let time: Double

  public init(time: Double) {
    self.time = time
  }
}
