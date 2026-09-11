import Foundation

@main
struct GhostHistoryTests {
  static func main() {
    testRingEviction()
    testPartialAndContinuousDeletion()
    testAtomicMismatch()
    testSessionIsolation()
    testUnicode()
    print("GhostHistory: 5 test groups passed")
  }

  static func testRingEviction() {
    let history = GhostHistory()
    let receipts = (0..<130).map { history.append("字\($0)")! }
    precondition(history.texts.count == 128)
    precondition(history.texts.first == "字2")
    precondition(history.rewind(receipts: [receipts[0]], deletedSuffix: "字0") == nil)
    precondition(history.texts.count == 128)
    let retained = history.rewind(receipts: receipts, deletedSuffix: "字129")!
    precondition(retained == Array(receipts[2..<129]))
    precondition(history.texts.count == 127 && history.texts.last == "字128")

    let tiny = GhostHistory(capacity: 1)
    let stale = tiny.append("相同")!
    let current = tiny.append("相同")!
    precondition(stale != current)
    precondition(tiny.rewind(receipts: [stale], deletedSuffix: "相同") == nil)
    precondition(tiny.texts == ["相同"])
  }

  static func testPartialAndContinuousDeletion() {
    let history = GhostHistory()
    let first = history.append("今天")!
    let second = history.append("天气很好")!
    var receipts = [first, second]
    receipts = history.rewind(receipts: receipts, deletedSuffix: "很好")!
    precondition(history.texts == ["今天", "天气"] && receipts == [first, second])
    receipts = history.rewind(receipts: receipts, deletedSuffix: "天天气")!
    precondition(history.texts == ["今"] && receipts == [first])
    receipts = history.rewind(receipts: receipts, deletedSuffix: "今")!
    precondition(history.texts.isEmpty && receipts.isEmpty)
    precondition(history.append("") == nil && history.texts.isEmpty)
  }

  static func testAtomicMismatch() {
    let history = GhostHistory()
    let receipts = [history.append("原文")!, history.append("尾巴")!]
    precondition(history.rewind(receipts: receipts, deletedSuffix: "错误尾巴") == nil)
    precondition(history.texts == ["原文", "尾巴"])
    precondition(history.rewind(receipts: receipts, deletedSuffix: "更早原文尾巴") == nil)
    precondition(history.texts == ["原文", "尾巴"])
    precondition(history.rewind(receipts: receipts.reversed(), deletedSuffix: "原文") == nil)
    precondition(history.rewind(receipts: [receipts[1], receipts[1]], deletedSuffix: "尾巴") == nil)
    precondition(history.rewind(receipts: receipts, deletedSuffix: "") == nil)
    precondition(history.texts == ["原文", "尾巴"])
  }

  static func testSessionIsolation() {
    let history = GhostHistory()
    let a = history.append("重复")!
    let b = history.append("重复")!
    let c = history.append("尾")!
    precondition(history.rewind(receipts: [a, c], deletedSuffix: "重复尾") == nil)
    precondition(history.rewind(receipts: [c], deletedSuffix: "重复尾") == nil)
    precondition(history.texts == ["重复", "重复", "尾"])
    precondition(history.rewind(receipts: [a], deletedSuffix: "重复") == [])
    precondition(history.texts == ["重复", "尾"])
    precondition(history.rewind(receipts: [b, c], deletedSuffix: "尾") == [b])
    precondition(history.texts == ["重复"])
  }

  static func testUnicode() {
    let history = GhostHistory()
    let emoji = history.append("好👨‍👩‍👧‍👦👍🏽")!
    precondition(history.rewind(receipts: [emoji], deletedSuffix: "👍🏽") == [emoji])
    precondition(history.texts == ["好👨‍👩‍👧‍👦"])
    precondition(history.rewind(receipts: [emoji], deletedSuffix: "👨‍👩‍👧‍👦") == [emoji])
    precondition(history.texts == ["好"])

    let accent = history.append("e")!
    let mark = history.append("\u{301}")!
    precondition(history.rewind(receipts: [accent, mark], deletedSuffix: "e\u{301}") == [])
    precondition(history.texts == ["好"])

    let decomposed = history.append("cafe\u{301}")!
    precondition(history.rewind(receipts: [decomposed], deletedSuffix: "é") == nil)
    precondition(history.rewind(receipts: [decomposed], deletedSuffix: "\u{301}") == [decomposed])
    precondition(history.texts == ["好", "cafe"])

    let skinTone = history.append("👍🏽")!
    precondition(history.rewind(receipts: [skinTone], deletedSuffix: "🏽") == [skinTone])
    precondition(history.texts.last == "👍")
  }
}
