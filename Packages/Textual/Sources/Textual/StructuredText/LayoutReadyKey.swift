import SwiftUI

/// Westie: a host may reveal a new Markdown layout after parsing and the
/// preference-driven sizing passes have all committed their current inputs.
/// This reports layout readiness only; asynchronous attachment downloads are separate.
public struct TextualLayoutReadyKey: PreferenceKey {
  public static var defaultValue: Bool { true }

  public static func reduce(value: inout Bool, nextValue: () -> Bool) {
    value = nextValue() && value
  }
}
