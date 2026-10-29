import Testing
@testable import WestieKit

@Test func thoughtSentenceKeepsPartialTailHidden() {
    #expect(ThoughtSentence.lastComplete(in: "正在看 3.5 和 a.swift") == nil)
    #expect(ThoughtSentence.lastComplete(in: "先看代码。正在") == "先看代码。")
    #expect(ThoughtSentence.lastComplete(in: "Done. Still working") == "Done.")
    #expect(ThoughtSentence.lastComplete(in: "Done.") == nil) // 流中句点还可能接词或数字
}

@Test func thoughtSentenceHandlesAbbreviationsAndEllipses() {
    #expect(ThoughtSentence.lastComplete(in: "Ask Dr. Smith") == nil)
    #expect(ThoughtSentence.lastComplete(in: "Use e.g. Swift types") == nil)
    #expect(ThoughtSentence.lastComplete(in: "Ask Dr. Smith. Next") == "Ask Dr. Smith.")
    #expect(ThoughtSentence.lastComplete(in: "J. Smith is ready. Next") == "J. Smith is ready.")
    #expect(ThoughtSentence.lastComplete(in: "Wait... Next") == "Wait...")
    #expect(ThoughtSentence.lastComplete(in: "再想想……接着") == "再想想……")
    #expect(ThoughtSentence.lastComplete(in: "再想想…") == nil)
    #expect(ThoughtSentence.lastComplete(in: "“完成。”下一句") == "“完成。”")
    #expect(ThoughtSentence.lastComplete(in: "Done!\n\n") == "Done!")
    #expect(ThoughtSentence.lastComplete(in: "……？！") == nil)
}
