import AppKit

@main struct Tests {
  static func snapshot(_ text: String, _ caret: Int) -> GhostDocumentHistory.Snapshot {
    .init(start: 0, text: text, documentLength: text.utf16.count, selection: NSRange(location: caret, length: 0))
  }
  static func setup(_ text: String) -> (GhostCompletion, FakeClient) {
    GhostCompletion.selectionHistory = GhostHistory()
    let client = FakeClient(text, text.utf16.count)
    let ghost = GhostCompletion()
    ghost.active = true; ghost.client = client
    ghost.documentHistory.reset(snapshot(text, client.caret))
    ghost.documentHistory.expect(.replace, selection: client.selectedRange())
    return (ghost, client)
  }
  static func main() {
    do {
      let (g, c) = setup("重复")
      let old = GhostCompletion.selectionHistory.append("重复")!
      _ = g.documentHistory.remember(old, text: "重复", at: NSRange(location: 0, length: 2), snapshot: snapshot("重复", 2))
      g.willCommit("重复", client: c); g.committed("重复", client: c, selected: true)
      let new = g.pendingSelectionReceipt!
      precondition(g.pendingExpectedCaret == 4)
      precondition(!g.capture(c), "old repeated suffix must not confirm a new commit")
      precondition(g.pendingSelectionReceipt == new)
      c.text = "重复重复"; c.caret = 4; g.confirmCommit(c)
      precondition(g.pendingSelectionReceipt == nil)
      g.documentHistory.expect(.replace, selection: NSRange(location: 0, length: 2))
      c.text = "重复"; c.caret = 0; _ = g.observeDocument(c, invalidate: false)
      precondition(GhostCompletion.selectionHistory.text(for: old) == nil)
      precondition(GhostCompletion.selectionHistory.text(for: new) == "重复", "new receipt must not bind to old word")
      g.cancel()
    }
    for (word, kept) in [("你好", "你"), ("你", ""), ("🙂好", "🙂")] {
      let (g, c) = setup("前")
      g.willCommit(word, client: c); g.committed(word, client: c, selected: true)
      let receipt = g.pendingSelectionReceipt!
      g.pendingCommitBackspace = true
      c.text = "前" + kept; c.caret = c.text.utf16.count
      g.confirmCommit(c)
      precondition(g.pendingSelectionReceipt == nil)
      precondition(GhostCompletion.selectionHistory.text(for: receipt) == (kept.isEmpty ? nil : kept))
      if !kept.isEmpty {
        g.documentHistory.expect(.backward, selection: c.selectedRange())
        c.text = "前"; c.caret = 1; _ = g.observeDocument(c, invalidate: false)
        precondition(GhostCompletion.selectionHistory.text(for: receipt) == nil)
      }
      g.cancel()
    }
    for missingExpected in [false, true] {
      let (g, c) = setup("旧")
      let old = GhostCompletion.selectionHistory.append("旧")!
      g.willCommit("旧", client: c); g.committed("旧", client: c, selected: true)
      let new = g.pendingSelectionReceipt!
      if missingExpected { g.pendingExpectedCaret = nil }
      g.pendingCommitDeadline = 0; g.confirmCommit(c)
      precondition(GhostCompletion.selectionHistory.text(for: new) == nil)
      precondition(GhostCompletion.selectionHistory.text(for: old) == "旧")
      precondition(g.pendingCommitText.isEmpty)
      g.cancel()
    }
    do {
      let (g, c) = setup("x")
      g.capturedRange = c.selectedRange(); g.capturedPrefix = "x"; g.capturedApp = "test.fake"
      g.buffer.context = [100]
      g.buffer.queued = (1...7).map { GhostToken(id: $0, bytes: [UInt8(96 + $0)]) }
      let accepted = g.buffer.accept()!
      let ticket = g.revision
      g.pendingTab = GhostCompletion.PendingTab(text: accepted, before: c.selectedRange(), expected: NSRange(location: 2, length: 0), deadline: ProcessInfo.processInfo.systemUptime + 0.6)
      g.streamInFlight = true
      g.confirmTab(c)
      precondition(g.pendingTab != nil && g.revision == ticket)
      precondition(g.buffer.queued.map(\.id) == Array(2...7))
      g.streamInFlight = false; g.fill(ticket: ticket)
      precondition(Probe.requests.isEmpty, "must not refill before actual insertion confirms")
      c.text = "xa"; c.caret = 2; g.confirmTab(c)
      precondition(g.pendingTab == nil && g.revision == ticket)
      precondition(Probe.requests == [1], "accepting first token must request only token 8")
      Probe.complete?(["completion_probabilities": [["id": 8, "bytes": [104]]]])
      precondition(g.buffer.queued.map(\.id) == Array(2...8))
      precondition(g.buffer.context == [100, 1])
      g.cancel()
    }
    do {
      let (g, c) = setup("x")
      g.capturedRange = c.selectedRange(); g.capturedPrefix = "x"; g.capturedApp = "test.fake"
      g.buffer.context = [100]
      g.buffer.queued = (1...7).map { GhostToken(id: $0, bytes: [UInt8(96 + $0)]) }
      g.buffer.queued.removeFirst()
      g.pendingTab = GhostCompletion.PendingTab(text: "a", before: NSRange(location: 1, length: 0),
        expected: NSRange(location: 2, length: 0), deadline: ProcessInfo.processInfo.systemUptime + 0.6)
      g.extraTabs = 2
      g.streamInFlight = true
      g.confirmTab(c)
      precondition(g.pendingTab != nil && g.extraTabs == 2, "unconfirmed extra Tabs must not cancel the stream")
      g.streamInFlight = false
      c.text = "xa"; c.caret = 2; g.confirmTab(c)
      precondition(g.pendingTab != nil, "queued Tabs must start the next insertion after confirm")
      precondition(g.buffer.queued.map(\.id) == Array(3...7))
      precondition(g.extraTabs == 1)
      c.text = "xab"; c.caret = 3; g.confirmTab(c)
      precondition(g.pendingTab != nil)
      precondition(g.buffer.queued.map(\.id) == Array(4...7))
      precondition(g.extraTabs == 0)
      g.cancel()
    }
    do {
      let (g, c) = setup("x")
      g.capturedRange = c.selectedRange(); g.capturedPrefix = "x"; g.capturedApp = "test.fake"
      g.buffer.context = [100]
      g.buffer.queued = (2...7).map { GhostToken(id: $0, bytes: [UInt8(96 + $0)]) }
      g.pendingTab = GhostCompletion.PendingTab(text: "a", before: NSRange(location: 1, length: 0),
        expected: NSRange(location: 2, length: 0), deadline: ProcessInfo.processInfo.systemUptime + 0.6)
      g.streamInFlight = true
      let ticket = g.revision
      g.deactivate()
      precondition(g.buffer.queued.map(\.id) == Array(2...7), "IMK deactivate must keep remaining tokens")
      precondition(g.pendingTab != nil && g.revision == ticket)
      g.activate(client: c)
      precondition(g.buffer.queued.map(\.id) == Array(2...7), "IMK reactivate must not drop the remaining prediction")
      precondition(g.revision == ticket)
      g.cancel()
    }
    do {
      let (g, c) = setup("abc")
      c.caret = 1
      precondition(g.capture(c) && g.capturedPrefix == "a", "real following text no longer blocks capture")
      precondition(g.valid(c), "following text no longer invalidates a preview")
      c.text = "abc\n"; c.caret = 3
      precondition(g.capture(c) && g.capturedPrefix == "abc", "virtual or real trailing newline must not block capture")
      c.text = ""; c.caret = 0
      precondition(g.capture(c) && g.capturedPrefix.isEmpty, "empty prefix may be captured")
      precondition(g.valid(c), "empty captured prefix remains valid")
      g.cancel()
    }
    do {
      Probe.requests = []; Probe.bodies = []; Probe.complete = nil
      let g = GhostCompletion(), c = FakeClient("abc", 3)
      g.activate(client: c)
      RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.025))
      g.activityMonitor?.fire()
      c.caret = 1; g.activityMonitor?.fire()
      precondition(Probe.requests.isEmpty, "focus/caret activity must not start generation")
      c.caret = 3
      g.willCommit("d", client: c)
      c.text = "abcd"; c.caret = 4
      g.committed("d", client: c)
      RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.025))
      precondition(Probe.requests == [3], "one commit must send exactly one initial request")
      precondition(Probe.bodies[0]["prompt_text"] as? String == "abcd")
      precondition(Probe.bodies[0]["prompt"] == nil)
      precondition(Probe.bodies[0]["history_texts"] == nil)
      Probe.complete?(["context_tokens": [100, 101], "instruction_tokens": [99]])
      precondition(g.buffer.context == [100, 101] && g.buffer.queued.isEmpty)
      precondition(g.buffer.instruction == [99])
      precondition(g.buffer.prompt == [99, 100, 101])
      for id in 1...3 { Probe.complete?(["completion_probabilities": [["id": id, "bytes": [96 + id]]]]) }
      precondition(g.buffer.queued.map(\.id) == Array(1...3))
      precondition(g.streamedTokens == 3, "metadata must not count as a generated token")
      for id in 4...7 { Probe.complete?(["completion_probabilities": [["id": id, "bytes": [96 + id]]]]) }
      precondition(g.buffer.queued.map(\.id) == Array(1...3), "the initial stream must stop after three tokens")
      g.streamInFlight = false; g.fill(ticket: g.revision)
      precondition(Probe.requests == [3, 1], "horizon continues one token at a time after the first three")
      for id in 4...7 {
        Probe.complete?(["completion_probabilities": [["id": id, "bytes": [96 + id]]]])
        g.streamInFlight = false
        g.fill(ticket: g.revision)
      }
      precondition(g.buffer.queued.map(\.id) == Array(1...7))
      precondition(Probe.requests == [3, 1, 1, 1, 1], "full horizon must not request an eighth token")
      g.activityMonitor?.fire()
      RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.025))
      precondition(Probe.requests == [3, 1, 1, 1, 1], "idle monitor must not duplicate completed first request")
      c.caret = 1; g.activityMonitor?.fire()
      precondition(Probe.requests == [3, 1, 1, 1, 1], "caret changes invalidate without regeneration")
      g.deactivate()
    }
    for delayedRectangle in [false, true] {
      Probe.requests = []; Probe.bodies = []; Probe.complete = nil
      let (g, c) = setup("a")
      g.willCommit("b", client: c)
      if delayedRectangle {
        c.text = "ab"; c.caret = 2; c.rectangleReady = false
      }
      g.committed("b", client: c)
      if delayedRectangle { precondition(g.pendingCommitDeadline == 0, "commit confirms before rectangle is ready") }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
        c.text = "ab"; c.caret = 2; c.rectangleReady = true
      }
      RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.20))
      precondition(g.captureAttempt >= 5, "test must exercise more than the old five retries")
      precondition(Probe.requests == [3], "delayed caret/rectangle must still produce exactly one initial request")
      precondition(Probe.bodies[0]["prompt_text"] as? String == "ab")
      g.cancel()
    }
    do {
      let (g, c) = setup("ab")
      g.captureDeadline = ProcessInfo.processInfo.systemUptime + 0.6
      precondition(g.capture(c))
      g.buffer.context = [100]
      g.buffer.queued = [GhostToken(id: 1, bytes: [97]), GhostToken(id: 2, bytes: [98])]
      g.streamInFlight = true; g.visible = true
      let ticket = g.revision, oldRect = g.capturedRect, oldShows = Probe.shows
      c.rectangleOffsetX = 40; c.rectangleOffsetY = -20
      precondition(g.valid(c, checkText: false), "same committed text may re-anchor a late layout move")
      precondition(g.revision == ticket && g.streamInFlight)
      precondition(g.buffer.queued.map(\.id) == [1, 2], "layout movement must retain pending tokens")
      precondition(g.capturedRect != oldRect && g.lastActivityRect == g.capturedRect)
      precondition(Probe.shows == oldShows + 1, "visible preview should move with its corrected anchor")
      c.text = "ac"; c.rectangleOffsetX = 80
      precondition(!g.valid(c, checkText: false), "same-range replacement must not be accepted as layout movement")
      g.cancel()
    }
    for unreadable in [false, true] {
      let (g, c) = setup("ab")
      g.captureDeadline = ProcessInfo.processInfo.systemUptime + 0.6
      precondition(g.capture(c))
      c.rectangleOffsetX = 20
      if unreadable { c.textReadable = false } else { g.captureDeadline = 0 }
      precondition(!g.valid(c, checkText: false), "unreadable prefix or expired layout window must reject relocation")
      g.cancel()
    }
    do {
      Probe.requests = []; Probe.bodies = []; Probe.complete = nil
      let (g, c) = setup("x")
      g.capturedRange = c.selectedRange(); g.capturedPrefix = "x"; g.capturedApp = "test.fake"
      g.buffer.context = [100]
      g.buffer.instruction = [99]
      g.buffer.queued = [GhostToken(id: 1, bytes: [97])]
      g.tokenInterval = 0.03
      let ticket = g.revision
      g.continueHorizon(ticket: ticket)
      precondition(Probe.requests.isEmpty, "must not request the next token immediately")
      RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.015))
      precondition(Probe.requests.isEmpty, "must wait the token interval")
      RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.04))
      precondition(Probe.requests == [1], "later tokens are requested one at a time")
      g.streamInFlight = false
      Probe.requests = []
      g.extraTabs = 1
      g.continueHorizon(ticket: ticket)
      precondition(Probe.requests == [1], "queued Tabs must not wait for the token interval")
      g.cancel()
    }
    do {
      let (g, _) = setup("x")
      let font = NSFont.systemFont(ofSize: 12)
      g.buffer.queued = [GhostToken(id: 1, bytes: Array("甲".utf8)), GhostToken(id: 2, bytes: Array("乙".utf8))]
      g.appearStartedAt = 0
      g.appearingIndex = nil
      precondition(g.fadingPreview(font: font).string == "甲乙")
      let color = g.fadingPreview(font: font).attribute(.foregroundColor, at: 0, effectiveRange: nil) as! NSColor
      let rgb = color.usingColorSpace(.deviceRGB)!
      precondition(rgb.redComponent > 0.9 && rgb.alphaComponent > 0.5, "inline ghost ink must be light so difference invert stays visible on white pages")
      g.appearingIndex = 1
      g.appearStartedAt = ProcessInfo.processInfo.systemUptime
      precondition(g.fadingPreview(font: font).string == "甲乙")
      g.cancel()
    }
    print("PASS: receipt/Unicode/deletion/Tab cases; following-text/empty capture, focus inactivity, one request per commit, metadata and delayed readiness; layout re-anchor keeps ticket/queue and rejects changed/nil text or expired deadline")
  }
}
