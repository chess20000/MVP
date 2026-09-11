import Foundation

@main
struct DocumentHistoryTests {
  static func snapshot(_ text: String, _ caret: Int, selection: Int = 0,
                       start: Int = 0) -> GhostDocumentHistory.Snapshot {
    let units = Array(text.utf16)
    return .init(start: start,
      text: String(decoding: units.dropFirst(start).prefix(2048), as: UTF16.self),
      documentLength: units.count, selection: NSRange(location: caret, length: selection))
  }
  static func remember(_ text: String, range: NSRange, in snapshot: GhostDocumentHistory.Snapshot,
                       history: GhostHistory, tracker: GhostDocumentHistory) {
    let receipt = history.append(text)!
    precondition(tracker.remember(receipt, text: text, at: range, snapshot: snapshot))
  }
  static func main() {
    do {
      let h = GhostHistory(), t = GhostDocumentHistory()
      let s = snapshot("甲重复乙重复丙", 3)
      remember("重复", range: NSRange(location: 1, length: 2), in: s, history: h, tracker: t)
      remember("重复", range: NSRange(location: 4, length: 2), in: s, history: h, tracker: t)
      t.expect(.backward, selection: s.selection)
      precondition(t.observe(snapshot("甲重乙重复丙", 2), history: h))
      precondition(h.texts == ["重", "重复"])
      t.expect(.replace, selection: NSRange(location: 1, length: 1))
      precondition(t.observe(snapshot("甲乙重复丙", 1), history: h))
      precondition(h.texts == ["重复"])
      t.expect(.forward, selection: NSRange(location: 2, length: 0))
      precondition(t.observe(snapshot("甲乙复丙", 2), history: h))
      precondition(h.texts == ["复"])
    }
    do {
      let h = GhostHistory(), t = GhostDocumentHistory()
      let s = snapshot("天气很好", 1, selection: 2)
      remember("天气很好", range: NSRange(location: 0, length: 4), in: s, history: h, tracker: t)
      t.expect(.replace, selection: s.selection)
      precondition(t.observe(snapshot("天不错好", 3), history: h))
      precondition(h.texts == ["天好"])
    }
    for action in [GhostDocumentHistory.Action.backward, .replace] {
      let h = GhostHistory(), t = GhostDocumentHistory()
      let s = snapshot("天气很好", action == .backward ? 4 : 0, selection: action == .backward ? 0 : 4)
      remember("天气很好", range: NSRange(location: 0, length: 4), in: s, history: h, tracker: t)
      t.expect(action, selection: s.selection)
      precondition(t.observe(snapshot("", 0), history: h))
      precondition(h.texts.isEmpty)
    }
    do {
      let h = GhostHistory(), t = GhostDocumentHistory()
      let s = snapshot("甲乙丙", 3)
      remember("甲乙丙", range: NSRange(location: 0, length: 3), in: s, history: h, tracker: t)
      precondition(t.observe(snapshot("甲丁丙", 3), history: h))
      precondition(h.texts == ["甲丙"])
    }
    do {
      let h = GhostHistory(), t = GhostDocumentHistory()
      let s = snapshot("哈哈", 2)
      remember("哈", range: NSRange(location: 0, length: 1), in: s, history: h, tracker: t)
      remember("哈", range: NSRange(location: 1, length: 1), in: s, history: h, tracker: t)
      precondition(t.observe(snapshot("哈", 1), history: h))
      precondition(h.texts == ["哈", "哈"] && !t.hasTrackedSelections)
    }
    do {
      let h = GhostHistory(), t = GhostDocumentHistory()
      let text = String(repeating: "a", count: 2045) + "天气很好"
      let s = snapshot(text, 2049, start: 1)
      remember("天气很好", range: NSRange(location: 2045, length: 4), in: s, history: h, tracker: t)
      t.expect(.backward, selection: s.selection)
      precondition(t.observe(snapshot(String(text.dropLast()), 2048), history: h))
      precondition(h.texts == ["天气很"])
    }
    do {
      let h = GhostHistory(), t = GhostDocumentHistory()
      let s = snapshot("甲天气乙", 2)
      remember("天气", range: NSRange(location: 1, length: 2), in: s, history: h, tracker: t)
      t.expect(.replace, selection: s.selection)
      precondition(t.observe(snapshot("甲天很好气乙", 4), history: h))
      precondition(h.texts == ["天气"])
      t.expect(.forward, selection: NSRange(location: 4, length: 0))
      precondition(t.observe(snapshot("甲天很好乙", 4), history: h))
      precondition(h.texts == ["天"])
    }
    do {
      let h = GhostHistory(), t = GhostDocumentHistory()
      let text = "好👨‍👩‍👧‍👦👍🏽"
      let s = snapshot(text, text.utf16.count)
      remember(text, range: NSRange(location: 0, length: text.utf16.count), in: s, history: h, tracker: t)
      t.expect(.backward, selection: s.selection)
      let next = "好👨‍👩‍👧‍👦"
      precondition(t.observe(snapshot(next, next.utf16.count), history: h))
      precondition(h.texts == [next])
    }
    do {
      let h = GhostHistory(capacity: 1), t = GhostDocumentHistory()
      let s = snapshot("同词", 2)
      remember("同词", range: NSRange(location: 0, length: 2), in: s, history: h, tracker: t)
      h.append("同词")
      t.expect(.replace, selection: NSRange(location: 0, length: 2))
      precondition(t.observe(snapshot("", 0), history: h))
      precondition(h.texts == ["同词"])
    }
    print("GhostDocumentHistory: 9 edit/provenance groups passed")
  }
}
