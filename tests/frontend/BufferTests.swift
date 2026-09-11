import Foundation

@main
struct BufferTests {
  static func main() {
    var spaced = GhostBuffer(queued: [
      GhostToken(id: 1, bytes: Array(" 公园 ".utf8)),
      GhostToken(id: 2, bytes: Array(" ".utf8)),
      GhostToken(id: 3, bytes: Array(" 散步".utf8))
    ])
    assert(spaced.preview == "公园散步")
    assert(spaced.accept() == "公园")
    assert(spaced.preview == "散步")
    assert(spaced.accept() == "")
    assert(spaced.accept() == "散步")
    assert(spaced.context == [1, 2, 3])
    assert(GhostToken(id: 4, bytes: Array("hello world\n".utf8)).textBytes == Array("hello world\n".utf8))
    var b = GhostBuffer(context: Array(0..<300), queued: [GhostToken(id: 1, bytes: Array("公园".utf8)), GhostToken(id: 2, bytes: Array("散步".utf8))])
    assert(b.accept() == "公园")
    assert(b.preview == "散步")
    assert(b.queued.count == 1 && b.context.count == 256 && b.prompt.count == 256)
    var split = GhostBuffer(queued: [GhostToken(id: 3, bytes: [0xE4]), GhostToken(id: 4, bytes: [0xB8, 0xAD])])
    assert(split.preview == "中")
    assert(split.accept() == "")
    assert(split.pending == [0xE4])
    assert(split.accept() == "中")
    assert(split.pending.isEmpty)
    assert(split.accept() == nil)
    var rolling = GhostBuffer(context: Array(0..<256), queued: (0..<7).map { GhostToken(id: $0, bytes: Array("字".utf8)) })
    for _ in 0..<50 {
     assert(rolling.queued.count == 7)
     assert(rolling.accept() == "字")
     assert(rolling.missing == 1)
     rolling.queued.append(GhostToken(id: 1, bytes: Array("字".utf8)))
     assert(rolling.prompt.count == 256)
    }
    print("PASS: one model token per Tab, UTF-8 split tokens, 256-token prompt bound, rolling seven-token horizon")

    var checks = 0
    for currentCount in [0, 1, 248, 249, 250, 255, 256, 257, 300, 600] {
      for instructionCount in [1, 8, 248, 249] {
        for queueCount in 0...7 {
          let current = Array(0..<currentCount)
          let instruction = Array(10000..<(10000 + instructionCount))
          let queue = (0..<queueCount).map { GhostToken(id: 20000 + $0, bytes: Array("字".utf8)) }
          let candidate = GhostBuffer(context: current, instruction: instruction, queued: queue)
          let primary = Array((current + queue.map(\.id)).suffix(256))
          let expectedInstruction = instruction
          assert(candidate.prompt == expectedInstruction + primary)
          assert(candidate.prompt.count <= 505)
          assert(candidate.prompt.count + candidate.missing <= 512)
          assert(primary.count <= 256)
          checks += 1
        }
      }
    }
    var extended = GhostBuffer(context: Array(0..<256), instruction: Array(10000..<10249), queued: (0..<7).map { GhostToken(id: 20000 + $0, bytes: Array("字".utf8)) })
    for step in 0..<512 {
      assert(extended.queued.count == 7 && extended.prompt.count == 505)
      let oldPrompt = extended.prompt
      let expectedID = extended.queued[0].id
      assert(extended.accept() == "字")
      assert(extended.context.last == expectedID && extended.context.count == 256)
      assert(extended.prompt == oldPrompt)
      assert(extended.missing == 1 && extended.prompt.count + extended.missing <= 512)
      extended.queued.append(GhostToken(id: 30000 + step, bytes: Array("字".utf8)))
    }
    print("PASS: \(checks) prompt-budget boundary cases; current <=256, input <=505, input+output <=512; 512 rolling accepts with instruction")
  }
}
