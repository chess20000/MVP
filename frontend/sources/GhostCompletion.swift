import AppKit
import InputMethodKit
import Carbon

struct GhostToken {
  let id: Int
  let bytes: [UInt8]
  // Remove boundary spaces without changing model IDs or split UTF-8 bytes.
  var textBytes: [UInt8] {
    Array(bytes.drop(while: { $0 == 0x20 }).reversed()
      .drop(while: { $0 == 0x20 }).reversed())
  }
}

// Maintains model token boundaries, including tokens that split a UTF-8 character.
struct GhostBuffer {
  var context: [Int] = []
  var instruction: [Int] = []
  var queued: [GhostToken] = []
  var pending: [UInt8] = []
  mutating func accept() -> String? {
    guard !queued.isEmpty else { return nil }
    let token = queued.removeFirst()
    context = Array((context + [token.id]).suffix(256))
    pending += token.textBytes
    let text = Self.validPrefix(pending)
    pending.removeFirst(text.utf8.count)
    return text
  }
  var preview: String { Self.validPrefix(pending + queued.flatMap(\.textBytes)) }
  var prompt: [Int] {
    let current = Array((context + queued.map(\.id)).suffix(256))
    return instruction + current
  }
  var missing: Int { max(0, 7 - queued.count) }
  static func validPrefix(_ bytes: [UInt8]) -> String {
    // An incomplete UTF-8 character needs at most three more bytes.
    for drop in 0...min(3, bytes.count) {
      if let text = String(bytes: bytes.prefix(bytes.count - drop), encoding: .utf8) { return text }
    }
    return ""
  }
}

// Parse complete SSE frames as bytes so network chunking cannot split Chinese text.
final class GhostStream: NSObject, URLSessionDataDelegate {
  private var pending = Data()
  private var session: URLSession?
  private var task: URLSessionDataTask?
  private let receive: ([String: Any]) -> Void
  private let finished: (Bool) -> Void
  init(request: URLRequest, receive: @escaping ([String: Any]) -> Void,
       finished: @escaping (Bool) -> Void) {
    self.receive = receive
    self.finished = finished
    super.init()
    let config = URLSessionConfiguration.ephemeral
    session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    task = session?.dataTask(with: request)
    task?.resume()
  }
  func cancel() { task?.cancel(); session?.invalidateAndCancel(); session = nil }
  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                  completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
    completionHandler((response as? HTTPURLResponse)?.statusCode == 200 ? .allow : .cancel)
  }
  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    pending.append(data)
    while let end = pending.range(of: Data([10, 10])) {
      let frame = pending.subdata(in: pending.startIndex..<end.lowerBound)
      pending.removeSubrange(pending.startIndex..<end.upperBound)
      for line in frame.split(separator: 10) where line.starts(with: [100, 97, 116, 97, 58, 32]) {
        if let object = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(6))) as? [String: Any] {
          DispatchQueue.main.async { [weak self] in self?.receive(object) }
        }
      }
    }
  }
  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    session.finishTasksAndInvalidate()
    self.session = nil
    let success = error == nil && (task.response as? HTTPURLResponse)?.statusCode == 200
    DispatchQueue.main.async { [weak self] in self?.finished(success) }
  }
}

private final class GhostPreviewView: NSView {
  var text = NSAttributedString() {
    didSet { needsDisplay = true }
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.isOpaque = false
  }

  required init?(coder: NSCoder) { nil }

  override var isOpaque: Bool { false }
  override var isFlipped: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  func applyInvertBlend(_ on: Bool) {
    wantsLayer = true
    layer?.isOpaque = false
    layer?.compositingFilter = on ? "differenceBlendMode" : nil
  }

  override func draw(_ dirtyRect: NSRect) {
    NSGraphicsContext.current?.cgContext.setShouldSmoothFonts(false)
    text.draw(in: bounds)
  }
}

// Local-only continuation. Suggestions never enter Rime's candidate stream or user dictionary.
final class GhostCompletion {
  // Shared only in this input-method process; never saved to disk.
  private static var selectionHistory = GhostHistory()
  private static var selections: [String] { selectionHistory.texts }
  private let endpoint = URL(string: "http://127.0.0.1:18081")!
  private var active = false
  private var revision = UUID()
  private var backendGeneration = GhostCompletion.readBackendGeneration()
  private var work: DispatchWorkItem?
  private var request: URLSessionDataTask?
  private var stream: GhostStream?
  private var streamInFlight = false
  private var streamedTokens = 0
  private var streamExpected = 0
  private var monitor: Timer?
  private var activityMonitor: Timer?
  private var lastActivityRange = NSRange(location: NSNotFound, length: 0)
  private var lastActivityRect = NSRect.zero
  private var panel: NSPanel?
  private weak var client: IMKTextInput?
  private var buffer = GhostBuffer()
  private var visible = false
  private var capturedRange = NSRange(location: NSNotFound, length: 0)
  private var capturedPrefix = ""
  private var capturedApp = ""
  private var capturedRect = NSRect.zero
  private var capturedWindowLevel = NSWindow.Level.popUpMenu.rawValue
  private var recent = ""
  private var lastCommittedCaret: Int?
  private var pendingCommitText = ""
  private var pendingCommitDeadline: TimeInterval = 0
  private var preparedCommitCaret: Int?
  private var pendingExpectedCaret: Int?
  private var pendingSelectionReceipt: GhostHistory.Receipt?
  private var pendingCommitBackspace = false
  private var preparedDocument: GhostDocumentHistory.Snapshot?
  private var pendingDocument: GhostDocumentHistory.Snapshot?
  private struct PendingTab {
    let text: String
    let before: NSRange
    let expected: NSRange
    let deadline: TimeInterval
  }
  private var pendingTab: PendingTab?
  private var extraTabs = 0
  private var lastTabUptime: TimeInterval = 0
  private var reattach: DispatchWorkItem?
  private var tabConfirmation: DispatchWorkItem?
  private var captureAttempt = 0
  private var captureDeadline: TimeInterval = 0
  private var retryCapture = false
  private var streamStartedAt: TimeInterval = 0
  private var hasFollowingText = false
  private var tokenInterval: TimeInterval = 0.3
  private var appearDuration: TimeInterval = 0.2
  private var fillDelay: DispatchWorkItem?
  private var appearTimer: Timer?
  private var appearingIndex: Int?
  private var appearStartedAt: TimeInterval = 0
  private struct UndoAnchor {
    let range: NSRange
    let prefix: String
    let rect: NSRect
  }
  private var undoAnchor: UndoAnchor?
  private var selectionReceipts: [GhostHistory.Receipt] = []
  private var pendingDeletion = false
  private let documentHistory = GhostDocumentHistory()
  private var documentNeedsRefresh = false
  private var enabled: Bool {
    !FileManager.default.fileExists(atPath: SquirrelApp.userDir.appendingPathComponent("ghost/disabled").path)
  }

  private static func readBackendGeneration() -> String? {
    let url = SquirrelApp.userDir.appendingPathComponent("ghost/backend-generation")
    do {
      return try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    } catch {
      // An absent marker is the original llama.cpp installation. An unreadable
      // existing marker must not allow tokens from an unknown tokenizer through.
      return FileManager.default.fileExists(atPath: url.path) ? nil : ""
    }
  }

  private func synchronizeBackendGeneration() -> Bool {
    guard let current = Self.readBackendGeneration() else {
      cancel(clearHistory: true)
      return false
    }
    guard current == backendGeneration else {
      backendGeneration = current
      // Unlike the temporary disabled flag, this change remains observable after
      // a blocked run loop resumes. All old request tickets become invalid too.
      // The shared 128-selection text history is independent of tokenizer IDs.
      cancel(clearHistory: true)
      return false
    }
    return true
  }

  private func invalidateRequest() {
    revision = UUID()
    tabConfirmation?.cancel(); tabConfirmation = nil; pendingTab = nil
    extraTabs = 0
    reattach?.cancel(); reattach = nil
    work?.cancel(); work = nil
    request?.cancel(); request = nil
    stream?.cancel(); stream = nil
    streamInFlight = false; streamedTokens = 0; streamExpected = 0
    fillDelay?.cancel(); fillDelay = nil
    stopAppear()
  }

  func cancel(clearHistory: Bool = false) {
    invalidateRequest()
    monitor?.invalidate(); monitor = nil
    panel?.orderOut(nil); visible = false
    buffer = GhostBuffer()
    if clearHistory {
      discardPendingSelection()
      recent = ""; lastCommittedCaret = nil
      pendingCommitText = ""; pendingCommitDeadline = 0
      pendingExpectedCaret = nil
      pendingSelectionReceipt = nil
      pendingCommitBackspace = false; pendingDocument = nil
    }
  }

  func handle(_ event: NSEvent, client: IMKTextInput?) -> Bool {
    guard event.type == .keyDown else { return false }
    guard synchronizeBackendGeneration(), enabled else { cancel(); return false }
    let plain = event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
    if plain && event.keyCode == 48 {
      return acceptTabPress(client: client)
    }
    if pendingTab != nil, let client, self.client === client {
      confirmTab(client)
      if pendingTab != nil { cancel() }
    }
    if let client, self.client !== client {
      cancel(clearHistory: true)
      clearUndo(); documentHistory.reset()
    }
    if let client { confirmCommit(client) }
    if let client {
      if documentHistory.hasSnapshot { _ = observeDocument(client) }
      else if pendingDeletion { reconcileDeletion(client) }
    }
    let dismissed = visible && plain && event.keyCode == 53
    if let client, documentHistory.hasSnapshot {
      let marked = client.markedRange()
      if marked.location == NSNotFound || marked.length == 0 {
        let action: GhostDocumentHistory.Action?
        if event.keyCode == 51 { action = .backward }
        else if event.keyCode == 117 { action = .forward }
        else if event.modifierFlags.contains(.command) {
          action = ["x", "v"].contains(event.charactersIgnoringModifiers?.lowercased() ?? "") ? .replace : nil
        } else if ![48, 53, 123, 124, 125, 126, 115, 119, 116, 121].contains(Int(event.keyCode)),
                  !event.modifierFlags.contains(.control) { action = .replace }
        else { action = nil }
        documentHistory.expect(action, selection: client.selectedRange())
      }
    } else if event.keyCode == 51, let client {
      beginDeletion(client)
    } else if [117, 123, 124, 125, 126, 115, 119, 116, 121].contains(Int(event.keyCode))
                || event.modifierFlags.contains(.command) {
      clearUndo()
    }
    let navigation = [51, 117, 123, 124, 125, 126, 115, 119, 116, 121].contains(Int(event.keyCode))
      || event.modifierFlags.contains(.command)
    let awaitingDeletion = event.keyCode == 51 && pendingSelectionReceipt != nil
    if awaitingDeletion { pendingCommitBackspace = true }
    cancel(clearHistory: navigation && !awaitingDeletion)
    return dismissed
  }

  private var livePrediction: Bool {
    pendingTab != nil || extraTabs > 0 || !buffer.queued.isEmpty || streamInFlight || work != nil || request != nil || fillDelay != nil
  }

  func activate(client: IMKTextInput) {
    reattach?.cancel(); reattach = nil
    let keep = livePrediction
    if !keep {
      cancel(clearHistory: true)
      clearUndo()
      documentHistory.reset(); documentNeedsRefresh = false
      pendingSelectionReceipt = nil; preparedCommitCaret = nil
    }
    active = true
    self.client = client
    watch(client)
    if keep {
      if pendingTab != nil { confirmTab(client) }
      else if !buffer.queued.isEmpty {
        stopAppear()
        show(client: client)
      }
    }
  }

  func deactivate() {
    stopAppear()
    if let client { confirmCommit(client) }
    if let client {
      if documentHistory.hasSnapshot { _ = observeDocument(client, invalidate: false) }
      else if pendingDeletion { reconcileDeletion(client) }
    }
    activityMonitor?.invalidate(); activityMonitor = nil
    monitor?.invalidate(); monitor = nil
    panel?.orderOut(nil); visible = false
    guard livePrediction else {
      clearUndo()
      documentHistory.reset(); documentNeedsRefresh = false
      preparedCommitCaret = nil
      active = false
      cancel(clearHistory: true)
      return
    }
    // Browsers deactivate IMK around insertText. Keep the remaining tokens until
    // activate() returns, then drop them only if the field is actually gone.
    let ticket = revision
    reattach?.cancel()
    let item = DispatchWorkItem { [weak self] in
      guard let self, self.revision == ticket else { return }
      self.active = false
      self.cancel(clearHistory: true)
    }
    reattach = item
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: item)
  }

  private func watch(_ client: IMKTextInput) {
    lastActivityRange = client.selectedRange()
    lastActivityRect = caret(client)
    activityMonitor?.invalidate()
    activityMonitor = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self, weak client] _ in
      guard let self, let client else { return }
      guard self.synchronizeBackendGeneration() else { return }
      if self.pendingTab != nil { return }
      self.confirmCommit(client)
      let edited = self.streamInFlight || self.request != nil ? false : self.observeDocument(client)
      if edited || self.documentNeedsRefresh {
        self.cancel()
        self.documentNeedsRefresh = false
        return
      }
      if self.streamInFlight || self.request != nil || self.visible || !self.buffer.queued.isEmpty {
        guard self.valid(client) else {
          if self.capture(client), !self.buffer.queued.isEmpty {
            self.show(client: client)
            return
          }
          if !self.buffer.queued.isEmpty {
            self.panel?.orderOut(nil); self.visible = false
            return
          }
          self.cancel(clearHistory: true)
          return
        }
      }
      let range = client.selectedRange(), rect = self.caret(client)
      if range != self.lastActivityRange || rect != self.lastActivityRect {
        self.lastActivityRange = range; self.lastActivityRect = rect
      }
    }
  }

  func willCommit(_ text: String, client: IMKTextInput) {
    preparedCommitCaret = nil
    preparedDocument = nil
    guard active, self.client === client, !text.isEmpty else { return }
    confirmCommit(client)
    preparedDocument = documentHistory.snapshot
    let marked = client.markedRange()
    let selection = marked.location != NSNotFound && marked.length > 0 ? marked : client.selectedRange()
    if selection.location != NSNotFound, selection.location >= 0,
       selection.location <= Int.max - text.utf16.count {
      preparedCommitCaret = selection.location + text.utf16.count
    }
  }

  func committed(_ text: String, client: IMKTextInput, selected: Bool = false) {
    let expectedCaret = preparedCommitCaret
    let before = preparedDocument
    preparedCommitCaret = nil
    preparedDocument = nil
    // Clear the previous model's fallback before recording this new commitment.
    _ = synchronizeBackendGeneration()
    guard !IsSecureEventInputEnabled(), !text.isEmpty else { return }
    discardPendingSelection()
    recent = String((recent + text).suffix(2048))
    lastCommittedCaret = expectedCaret
    pendingCommitText = text
    pendingExpectedCaret = expectedCaret
    pendingSelectionReceipt = selected ? Self.selectionHistory.append(text) : nil
    pendingCommitBackspace = false
    pendingDocument = before
    pendingCommitDeadline = ProcessInfo.processInfo.systemUptime + 0.6
    confirmCommit(client)
    activity(client: client)
  }

  /// insertText may return before a web client's cached document/selection updates.
  /// A matching old word alone is not evidence that this commitment became visible.
  private func confirmCommit(_ client: IMKTextInput) {
    guard active, self.client === client, !IsSecureEventInputEnabled(),
          !pendingCommitText.isEmpty else { return }
    guard ProcessInfo.processInfo.systemUptime < pendingCommitDeadline else {
      discardPendingSelection()
      pendingCommitText = ""; pendingExpectedCaret = nil; pendingSelectionReceipt = nil
      pendingCommitDeadline = 0; pendingCommitBackspace = false; pendingDocument = nil
      recent = ""; lastCommittedCaret = nil
      return
    }
    guard let expected = pendingExpectedCaret else { return }
    let ticket = revision
    let marked = client.markedRange()
    guard marked.location == NSNotFound || marked.length == 0 else { return }
    let range = client.selectedRange()
    guard range.location != NSNotFound, range.length == 0,
          range.location >= 0, let actual = prefix(client, range: range),
          active, revision == ticket, self.client === client,
          GhostFocus.matches(app: client.bundleIdentifier() ?? "", caret: { self.caret(client) }) else { return }
    let text = pendingCommitText
    let start = expected - text.utf16.count
    guard start >= 0 else { return }
    var kept = text
    var document: GhostDocumentHistory.Snapshot?
    if range.location != expected {
      // An immediate Backspace can arrive before the full committed word was ever
      // readable. Confirm the remaining insertion against the pre-commit document.
      guard pendingCommitBackspace, range.location >= start, range.location < expected,
            let before = pendingDocument, before.start == 0,
            before.end == before.documentLength,
            before.selection.location == start, before.selection.length == 0,
            let after = documentSnapshot(client), after.start == 0,
            after.end == after.documentLength else { return }
      let units = Array(text.utf16.prefix(range.location - start))
      kept = String(decoding: units, as: UTF16.self)
      guard kept.utf16.elementsEqual(units) else { return }
      let old = before.text as NSString
      let predicted = old.substring(to: start) + kept + old.substring(from: start)
      guard after.text.utf16.elementsEqual(predicted.utf16) else { return }
      document = after
    }
    guard actual.hasSuffix(kept), active, revision == ticket, self.client === client else { return }
    if document == nil { document = documentSnapshot(client) }
    guard active, revision == ticket, self.client === client else { return }
    let receipt = pendingSelectionReceipt
    if let document {
      _ = documentHistory.observe(document, history: Self.selectionHistory)
      clearUndo()
      if let receipt {
        if kept != text { _ = Self.selectionHistory.revise(receipt, expected: text, replacement: kept) }
        if !kept.isEmpty {
          _ = documentHistory.remember(receipt, text: kept,
            at: NSRange(location: start, length: kept.utf16.count), snapshot: document)
        }
      }
    } else if let receipt {
      let previous = String(actual.dropLast(kept.count))
      let oldScalars = Array((undoAnchor?.prefix ?? "").unicodeScalars)
      let newScalars = Array(previous.unicodeScalars)
      let overlap = min(oldScalars.count, newScalars.count)
      let continuous = undoAnchor.map { $0.range.location + kept.utf16.count == range.location } ?? false
      if !continuous || !oldScalars.suffix(overlap).elementsEqual(newScalars.suffix(overlap)) { selectionReceipts = [] }
      selectionReceipts.append(receipt)
      selectionReceipts = Array(selectionReceipts.suffix(128))
      undoAnchor = UndoAnchor(range: range, prefix: actual, rect: caret(client))
      pendingDeletion = false
    }
    recent = actual; lastCommittedCaret = range.location
    pendingCommitText = ""; pendingExpectedCaret = nil; pendingSelectionReceipt = nil
    pendingCommitDeadline = 0; pendingCommitBackspace = false; pendingDocument = nil
  }

  private func discardPendingSelection() {
    if let receipt = pendingSelectionReceipt {
      _ = Self.selectionHistory.revise(receipt, expected: pendingCommitText, replacement: "")
    }
    pendingSelectionReceipt = nil
  }

  func acceptTabPress(client: IMKTextInput?) -> Bool {
    guard synchronizeBackendGeneration(), enabled else { cancel(); return false }
    guard active, let client, self.client === client else { return true }
    let now = ProcessInfo.processInfo.systemUptime
    if now - lastTabUptime < 0.02 { return true }
    lastTabUptime = now
    if pendingTab != nil {
      extraTabs = min(7, extraTabs + 1)
      confirmTab(client)
      return true
    }
    if !buffer.queued.isEmpty { return takeQueuedToken(client) }
    if work != nil || request != nil || streamInFlight {
      extraTabs = min(7, extraTabs + 1)
      return true
    }
    return false
  }

  @discardableResult
  private func takeQueuedToken(_ client: IMKTextInput) -> Bool {
    guard !buffer.queued.isEmpty else {
      if work != nil || request != nil || streamInFlight {
        extraTabs = min(7, extraTabs + 1)
        return true
      }
      return false
    }
    if !valid(client) {
      if capture(client) { /* continue at the new caret */ }
      else {
        extraTabs = min(7, extraTabs + 1)
        return true
      }
    }
    let ticket = revision
    guard synchronizeBackendGeneration(), enabled, revision == ticket else { return false }
    guard let accepted = buffer.accept() else { return false }
    stopAppear()
    clearUndo()
    discardPendingSelection()
    pendingCommitText = ""; pendingExpectedCaret = nil; pendingCommitDeadline = 0
    pendingSelectionReceipt = nil
    if !accepted.isEmpty {
      let before = capturedRange
      guard before.location <= Int.max - accepted.utf16.count else { cancel(); return true }
      pendingTab = PendingTab(text: accepted, before: before,
        expected: NSRange(location: before.location + accepted.utf16.count, length: 0),
        deadline: ProcessInfo.processInfo.systemUptime + 0.6)
      documentHistory.expect(.replace, selection: client.selectedRange())
      client.insertText(accepted, replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
      self.client = client
      active = true
      reattach?.cancel(); reattach = nil
      panel?.orderOut(nil); visible = false
      confirmTab(client)
      return true
    }
    // Preserve the original stream and its unaccepted tokens. Once it finishes,
    // fill() appends only the missing tail (token 8 after accepting token 1).
    guard active, revision == ticket, self.client === client else { return true }
    recent = String((recent + accepted).suffix(2048))
    lastCommittedCaret = capturedRange.location + accepted.utf16.count
    guard capture(client) else { cancel(); return true }
    lastActivityRange = capturedRange
    lastActivityRect = capturedRect
    show(client: client)
    fill(ticket: ticket)
    drainExtraTabs(client)
    return true
  }

  private func drainExtraTabs(_ client: IMKTextInput) {
    guard extraTabs > 0, pendingTab == nil else { return }
    extraTabs -= 1
    _ = takeQueuedToken(client)
  }

  private func selectionMatchesCaptured(_ client: IMKTextInput) -> Bool {
    let selection = client.selectedRange()
    guard selection.location != NSNotFound, selection.location >= 0 else { return false }
    if selection.length == 0 { return selection == capturedRange }
    return selection.location <= capturedRange.location
      && selection.location + selection.length == capturedRange.location
  }

  private func validPendingTab(_ client: IMKTextInput) -> Bool {
    guard let pending = pendingTab, active, self.client === client, enabled,
          !IsSecureEventInputEnabled(), GhostFocus.matches(app: capturedApp, caret: { self.caret(client) }) else { return false }
    let marked = client.markedRange()
    guard marked.location == NSNotFound || marked.length == 0 else { return false }
    let range = client.selectedRange()
    if range == pending.before || range == pending.expected { return true }
    if range.location == pending.before.location, range.length == pending.text.utf16.count { return true }
    if let actual = prefix(client, range: pending.expected), actual.hasSuffix(pending.text) { return true }
    return false
  }

  private func confirmTab(_ client: IMKTextInput) {
    guard let pending = pendingTab else { return }
    let ticket = revision
    guard synchronizeBackendGeneration(), revision == ticket else { return }
    self.client = client
    active = true
    guard enabled, !IsSecureEventInputEnabled() else {
      if revision == ticket { cancel(clearHistory: true) }
      return
    }
    let marked = client.markedRange()
    if marked.location == NSNotFound || marked.length == 0 {
      let actual = prefix(client, range: pending.expected)
      let landed = actual?.hasSuffix(pending.text) == true
      let caretReady = client.selectedRange() == pending.expected && (actual == nil || landed)
      if landed || caretReady {
        lastCommittedCaret = pending.expected.location
        recent = actual ?? String((capturedPrefix + pending.text).suffix(2048))
        if applyTabCapture(client, caret: pending.expected, prefix: recent) {
          guard active, revision == ticket, self.client === client else { return }
          _ = observeDocument(client, invalidate: false)
          pendingTab = nil
          tabConfirmation?.cancel(); tabConfirmation = nil
          lastActivityRange = capturedRange; lastActivityRect = capturedRect
          show(client: client)
          fill(ticket: ticket)
          drainExtraTabs(client)
          return
        }
      }
    }
    guard ProcessInfo.processInfo.systemUptime < pending.deadline else { cancel(); return }
    tabConfirmation?.cancel()
    let item = DispatchWorkItem { [weak self, weak client] in
      guard let self, let client, self.revision == ticket else { return }
      self.confirmTab(client)
    }
    tabConfirmation = item
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.035, execute: item)
  }

  private func applyTabCapture(_ client: IMKTextInput, caret: NSRange, prefix: String) -> Bool {
    guard synchronizeBackendGeneration() else { return false }
    let ticket = revision
    guard active, self.client === client, enabled, !IsSecureEventInputEnabled() else { return false }
    let app = client.bundleIdentifier() ?? ""
    let rect = self.caret(client)
    let useRect = (rect.height > 0 && rect.minX.isFinite && rect.minY.isFinite) ? rect : capturedRect
    guard useRect.height > 0, useRect.minX.isFinite, useRect.minY.isFinite,
          !app.isEmpty, GhostFocus.matches(app: app, caret: { useRect }),
          active, revision == ticket, self.client === client else { return false }
    capturedRange = caret
    capturedPrefix = prefix
    capturedApp = app
    capturedRect = useRect
    capturedWindowLevel = max(NSWindow.Level.popUpMenu.rawValue, Int(client.windowLevel()) + 1)
    return true
  }

  private func clearUndo() {
    undoAnchor = nil; selectionReceipts = []; pendingDeletion = false
  }

  /// Read only a 2048-UTF16 window in the active client. Marked pinyin is transient;
  /// keep the pre-composition snapshot until actual commitment or cancellation.
  private func documentSnapshot(_ client: IMKTextInput) -> GhostDocumentHistory.Snapshot? {
    let ticket = revision
    guard active, self.client === client, !IsSecureEventInputEnabled(),
          synchronizeBackendGeneration(), revision == ticket else { return nil }
    let marked = client.markedRange()
    guard marked.location == NSNotFound || marked.length == 0 else { return nil }
    let selection = client.selectedRange(), length = client.length()
    guard length != NSNotFound, length >= 0, selection.location != NSNotFound,
          selection.location >= 0, selection.length >= 0,
          selection.location <= length, selection.length <= length - selection.location else { return nil }
    var start = max(0, min(selection.location - 1024, length - 2048))
    if selection.length <= 2048 { start = max(start, selection.location + selection.length - 2048) }
    let range = NSRange(location: start, length: min(2048, length - start))
    let text: String?
    if range.length == 0 { text = "" }
    else {
      var actual = NSRange(location: NSNotFound, length: 0)
      if let value = client.string(from: range, actualRange: &actual),
         actual.location != NSNotFound, actual.location >= 0, actual.location <= start,
         start - actual.location <= value.utf16.count,
         range.length <= value.utf16.count - (start - actual.location) {
        let units = Array(value.utf16).dropFirst(start - actual.location).prefix(range.length)
        let decoded = String(decoding: units, as: UTF16.self)
        text = decoded.utf16.elementsEqual(units) ? decoded : nil
      } else { text = client.attributedSubstring(from: range)?.string }
    }
    guard active, self.client === client, revision == ticket,
          synchronizeBackendGeneration(), revision == ticket,
          GhostFocus.matches(app: client.bundleIdentifier() ?? "", caret: { self.caret(client) }),
          let text, text.utf16.count == range.length else { return nil }
    return GhostDocumentHistory.Snapshot(start: start, text: text, documentLength: length, selection: selection)
  }

  @discardableResult
  private func observeDocument(_ client: IMKTextInput, invalidate: Bool = true) -> Bool {
    guard documentHistory.hasSnapshot, let snapshot = documentSnapshot(client) else { return false }
    let changed = documentHistory.observe(snapshot, history: Self.selectionHistory)
    if changed, invalidate {
      cancel(clearHistory: true)
      documentNeedsRefresh = true
    }
    return changed
  }

  private func beginDeletion(_ client: IMKTextInput) {
    guard self.client === client else { clearUndo(); return }
    guard !pendingDeletion, let anchor = undoAnchor else { return }
    let range = client.selectedRange()
    let rect = caret(client)
    guard range == anchor.range, prefix(client, range: range) == anchor.prefix,
          abs(rect.minX - anchor.rect.minX) < 3, abs(rect.minY - anchor.rect.minY) < 3 else {
      clearUndo(); return
    }
    pendingDeletion = true
  }

  private func reconcileDeletion(_ client: IMKTextInput) {
    guard self.client === client else { clearUndo(); return }
    guard pendingDeletion, let anchor = undoAnchor else { return }
    pendingDeletion = false
    let range = client.selectedRange()
    guard range.location != NSNotFound, range.length == 0 else { clearUndo(); return }
    let removedLength = anchor.range.location - range.location
    if removedLength == 0 { return } // Backspace may have edited only the pinyin composition.
    let before = anchor.prefix as NSString
    guard removedLength > 0, removedLength <= before.length,
          let current = prefix(client, range: range) else { clearUndo(); return }
    let kept = before.substring(to: before.length - removedLength)
    let removed = before.substring(from: before.length - removedLength)
    guard current.hasSuffix(kept),
          let receipts = Self.selectionHistory.rewind(receipts: selectionReceipts, deletedSuffix: removed) else {
      clearUndo(); return
    }
    selectionReceipts = receipts
    undoAnchor = UndoAnchor(range: range, prefix: current, rect: caret(client))
    recent = current
  }

  private func activity(client: IMKTextInput, retry: Bool = false) {
    guard synchronizeBackendGeneration() else { return }
    cancel()
    guard active, enabled, !IsSecureEventInputEnabled() else { return }
    if !retry {
      captureAttempt = 0
      captureDeadline = ProcessInfo.processInfo.systemUptime + 0.6
    }
    self.client = client
    lastActivityRange = client.selectedRange(); lastActivityRect = caret(client)
    let ticket = revision
    let item = DispatchWorkItem { [weak self, weak client] in
      guard let self, self.synchronizeBackendGeneration(), let client, self.revision == ticket else { return }
      self.work = nil
      self.confirmCommit(client)
      if self.documentHistory.hasSnapshot { _ = self.observeDocument(client, invalidate: false) }
      else { self.reconcileDeletion(client) }
      self.documentNeedsRefresh = false
      guard self.revision == ticket else { return }
      guard self.capture(client) else {
        if self.retryCapture,
           ProcessInfo.processInfo.systemUptime < self.captureDeadline {
          self.captureAttempt += 1
          self.activity(client: client, retry: true)
        }
        return
      }
      // Tokenize the committed prefix and stream the first three tokens immediately.
      // Later tokens are requested one at a time after tokenInterval.
      self.postStream(body: ["prompt_text": self.capturedPrefix,
        "n_predict": 3,
        "return_tokens": true, "n_probs": 1, "ignore_eos": true,
        "temperature": 0.2, "top_k": 20, "top_p": 0.8,
        "repeat_penalty": 1.1, "stream": true, "cache_prompt": true], ticket: ticket) { [weak self] result in
          guard let self, self.revision == ticket else { return }
          if let context = result["context_tokens"] as? [Int],
             let instruction = result["instruction_tokens"] as? [Int] {
            guard !instruction.isEmpty, instruction.count <= 249, context.count <= 256,
                  context.count + instruction.count <= 505,
                  context.allSatisfy({ $0 >= 0 }), instruction.allSatisfy({ $0 >= 0 }),
                  self.buffer.context.isEmpty, self.buffer.queued.isEmpty else { self.cancel(); return }
            self.buffer.context = context
            self.buffer.instruction = instruction
            return
          }
          self.receiveTokens(result, ticket: ticket)
        }
    }
    work = item
    if retry { DispatchQueue.main.asyncAfter(deadline: .now() + 0.015, execute: item) }
    else { DispatchQueue.main.async(execute: item) }
  }

  private func prefix(_ client: IMKTextInput, range: NSRange) -> String? {
    guard range.location != NSNotFound, range.location >= 0, range.length == 0 else { return nil }
    if range.location == 0 { return "" }
    let start = max(0, range.location - 2048)
    var actual = NSRange(location: NSNotFound, length: 0)
    if let text = client.string(from: NSRange(location: start, length: range.location - start), actualRange: &actual),
       actual.location != NSNotFound, actual.location >= 0, actual.location <= range.location {
      let count = range.location - actual.location
      if actual.length >= count, count <= (text as NSString).length { return (text as NSString).substring(to: count) }
    }
    return client.attributedSubstring(from: NSRange(location: start, length: range.location - start))?.string
  }

  private func caret(_ client: IMKTextInput) -> NSRect {
    var rect = NSRect.zero
    _ = client.attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
    if rect.height <= 0 || !rect.minX.isFinite || !rect.minY.isFinite {
      let selection = client.selectedRange()
      if selection.location != NSNotFound, selection.length == 0 {
        var actual = NSRange(location: NSNotFound, length: 0)
        rect = client.firstRect(forCharacterRange: selection, actualRange: &actual)
      }
    }
    return rect
  }

  private func capture(_ client: IMKTextInput) -> Bool {
    guard synchronizeBackendGeneration() else { return false }
    let ticket = revision
    retryCapture = false
    guard active, self.client === client, enabled, !IsSecureEventInputEnabled() else { return false }
    confirmCommit(client)
    guard active, revision == ticket, self.client === client else { return false }
    let app = client.bundleIdentifier() ?? ""
    let marked = client.markedRange()
    guard marked.location == NSNotFound || marked.length == 0 else { return false }
    let range = client.selectedRange()
    guard range.location != NSNotFound, range.location >= 0, range.length == 0 else {
      retryCapture = ProcessInfo.processInfo.systemUptime < captureDeadline
      if !retryCapture { recent = "" }
      GhostDiagnostics.record(app: app, reason: "selection_unavailable", fields: ["selection": [range.location, range.length]])
      return false
    }
    let livePrefix = prefix(client, range: range)
    // A repeated word at the old caret must not count as the new insertion.
    if !pendingCommitText.isEmpty, let expected = pendingExpectedCaret,
       range.location != expected || (livePrefix != nil && livePrefix?.hasSuffix(pendingCommitText) != true) {
      retryCapture = true
      GhostDiagnostics.record(app: app, reason: "awaiting_committed_selection", fields: ["selection": range.location, "expected": expected])
      return false
    }
    // No text-length or end-of-document restriction: web editors can report
    // synthetic trailing characters. The current prefix still anchors each result.
    let newPrefix = livePrefix ?? recent
    let rect = caret(client)
    guard rect.height > 0, rect.minX.isFinite, rect.minY.isFinite else {
      retryCapture = ProcessInfo.processInfo.systemUptime < captureDeadline
      GhostDiagnostics.record(app: app, reason: "caret_rectangle_unavailable")
      return false
    }
    guard active, revision == ticket, self.client === client,
          !app.isEmpty, GhostFocus.matches(app: app, caret: { rect }) else {
      GhostDiagnostics.record(app: app, reason: "inactive_client", fields: ["foreground": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""])
      return false
    }
    hasFollowingText = false
    capturedRange = range
    capturedPrefix = newPrefix
    capturedApp = app
    capturedRect = rect
    capturedWindowLevel = max(NSWindow.Level.popUpMenu.rawValue, Int(client.windowLevel()) + 1)
    GhostDiagnostics.record(app: app, reason: "context_ready", fields: ["prefix_length": newPrefix.utf16.count, "window_level": capturedWindowLevel])
    return true
  }

  private func fill(ticket: UUID, delay: TimeInterval = 0) {
    fillDelay?.cancel(); fillDelay = nil
    guard synchronizeBackendGeneration(), revision == ticket else { return }
    if delay > 0 {
      let item = DispatchWorkItem { [weak self] in
        guard let self, self.revision == ticket else { return }
        self.fillDelay = nil
        self.fill(ticket: ticket)
      }
      fillDelay = item
      DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
      return
    }
    guard pendingTab == nil, !streamInFlight, buffer.missing > 0, !buffer.prompt.isEmpty else { return }
    // One token at a time keeps the GPU free if the user keeps typing.
    postStream(body: ["prompt": buffer.prompt, "n_predict": 1,
      "return_tokens": true, "n_probs": 1, "ignore_eos": true,
      "grammar": "root ::= [^\\n\\r]+", "temperature": 0.2, "top_k": 20, "top_p": 0.8,
      "repeat_penalty": 1.1, "stream": true, "cache_prompt": true], ticket: ticket) { [weak self] result in
        self?.receiveTokens(result, ticket: ticket)
      }
  }

  private func continueHorizon(ticket: UUID) {
    guard synchronizeBackendGeneration(), revision == ticket, buffer.missing > 0, pendingTab == nil else { return }
    fill(ticket: ticket, delay: extraTabs > 0 ? 0 : tokenInterval)
  }

  private func receiveTokens(_ result: [String: Any], ticket: UUID) {
    guard active, revision == ticket,
          let items = result["completion_probabilities"] as? [[String: Any]] else { return }
    let tokens = items.compactMap { item -> GhostToken? in
      guard let id = item["id"] as? Int, let bytes = item["bytes"] as? [Int],
            bytes.allSatisfy({ (0...255).contains($0) }) else { return nil }
      return GhostToken(id: id, bytes: bytes.map(UInt8.init))
    }
    guard streamedTokens < streamExpected else { return }
    let incoming = Array(tokens.prefix(min(1, min(streamExpected - streamedTokens, 7 - buffer.queued.count))))
    guard !incoming.isEmpty, !buffer.prompt.isEmpty else { return }
    streamedTokens += incoming.count
    buffer.queued += incoming
    if let client {
      if extraTabs > 0, pendingTab == nil {
        drainExtraTabs(client)
      } else {
        beginAppear(client: client)
        show(client: client)
      }
    }
  }

  private func valid(_ client: IMKTextInput, checkText: Bool = true) -> Bool {
    guard synchronizeBackendGeneration() else { return false }
    let ticket = revision
    guard active, self.client === client, enabled, !IsSecureEventInputEnabled(),
          GhostFocus.matches(app: capturedApp, caret: { self.caret(client) }) else { return false }
    let marked = client.markedRange()
    guard marked.location == NSNotFound || marked.length == 0 else { return false }
    guard selectionMatchesCaptured(client) else { return false }
    // Text is checked on acceptance and the monitor. A post-commit layout move
    // gets one additional text check instead of discarding an otherwise valid stream.
    let current = checkText ? prefix(client, range: capturedRange) : nil
    if let current, current != capturedPrefix {
      _ = observeDocument(client)
      documentNeedsRefresh = true
      return false
    }
    let rect = caret(client)
    guard rect.height > 0, rect.minX.isFinite, rect.minY.isFinite,
          active, revision == ticket, self.client === client else { return false }
    if abs(rect.minX - capturedRect.minX) >= 3 || abs(rect.minY - capturedRect.minY) >= 3 {
      guard ProcessInfo.processInfo.systemUptime < captureDeadline,
            (current ?? prefix(client, range: capturedRange)) == capturedPrefix,
            selectionMatchesCaptured(client),
            active, revision == ticket, self.client === client else { return false }
      capturedRect = rect
      lastActivityRect = rect
      if visible { show(client: client) }
    }
    return active && revision == ticket && self.client === client
  }

  private func postStream(body: [String: Any], ticket: UUID,
                          completion: @escaping ([String: Any]) -> Void) {
    guard synchronizeBackendGeneration(), revision == ticket, let client else {
      if revision == ticket { cancel(clearHistory: true) }
      return
    }
    guard valid(client, checkText: false), revision == ticket else { return }
    var req = URLRequest(url: endpoint.appendingPathComponent("completion"))
    req.httpMethod = "POST"; req.timeoutInterval = 3
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = try? JSONSerialization.data(withJSONObject: body)
    guard synchronizeBackendGeneration(), enabled, revision == ticket else { return }
    streamInFlight = true
    streamedTokens = 0
    streamExpected = body["n_predict"] as? Int ?? 0
    streamStartedAt = ProcessInfo.processInfo.systemUptime
    let expected = streamExpected
    stream = GhostStream(request: req, receive: { [weak self] result in
      guard let self, self.synchronizeBackendGeneration(), self.active, self.revision == ticket else { return }
      guard let client = self.client else { return }
      let anchored = self.pendingTab != nil ? self.validPendingTab(client) : self.valid(client, checkText: false)
      guard anchored, self.synchronizeBackendGeneration(), self.revision == ticket else { return }
      if self.streamedTokens == 0, result["completion_probabilities"] != nil {
        GhostDiagnostics.record(app: self.capturedApp, reason: "streaming", fields: ["first_token_ms": Int((ProcessInfo.processInfo.systemUptime - self.streamStartedAt) * 1000)])
      }
      completion(result)
    }, finished: { [weak self] success in
      guard let self, self.synchronizeBackendGeneration(), self.active, self.revision == ticket else { return }
      self.streamInFlight = false
      self.stream = nil
      // A failed/short stream must not start an automatic retry loop.
      if success && expected > 0 && self.streamedTokens == expected {
        self.continueHorizon(ticket: ticket)
      }
    })
  }

  private func previewAlpha(index: Int) -> CGFloat {
    0.7 - 0.64 * CGFloat(min(index, 6)) / 6
  }

  private var appearProgress: CGFloat {
    guard appearStartedAt > 0, appearDuration > 0 else { return 1 }
    return CGFloat(min(1, max(0, (ProcessInfo.processInfo.systemUptime - appearStartedAt) / appearDuration)))
  }

  private func stopAppear() {
    appearTimer?.invalidate(); appearTimer = nil
    appearStartedAt = 0
    appearingIndex = nil
  }

  private func beginAppear(client: IMKTextInput) {
    let index = buffer.queued.count - 1
    guard index >= 3 else {
      stopAppear()
      return
    }
    appearingIndex = index
    appearStartedAt = ProcessInfo.processInfo.systemUptime
    appearTimer?.invalidate()
    appearTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self, weak client] _ in
      guard let self, let client, self.pendingTab == nil else { return }
      if self.appearProgress >= 1 {
        self.stopAppear()
        self.show(client: client)
        return
      }
      self.show(client: client)
    }
  }

  private func fadingPreview(font: NSFont, ink: NSColor = NSColor(calibratedWhite: 1, alpha: 1)) -> NSMutableAttributedString {
    var leftover = buffer.pending
    let text = NSMutableAttributedString()
    for (index, token) in buffer.queued.enumerated() {
      leftover += token.textBytes
      let chunk = GhostBuffer.validPrefix(leftover)
      leftover.removeFirst(min(chunk.utf8.count, leftover.count))
      guard !chunk.isEmpty else { continue }
      var alpha = previewAlpha(index: index)
      if appearingIndex == index { alpha *= appearProgress }
      text.append(NSAttributedString(string: chunk, attributes: [
        .font: font,
        .foregroundColor: ink.withAlphaComponent(alpha)
      ]))
    }
    return text
  }

  private func show(client: IMKTextInput) {
    guard synchronizeBackendGeneration(), active, self.client === client, pendingTab == nil else { return }
    let ticket = revision
    let raw = buffer.preview
    guard !raw.isEmpty, !raw.contains("<|"), !raw.contains("<think"), !raw.contains("</think") else {
      panel?.orderOut(nil); visible = false; return
    }
    let rect = capturedRect
    guard active, revision == ticket, self.client === client else { return }
    let height = min(24, max(14, rect.height))
    let font = NSFont.systemFont(ofSize: height * 0.83)
    let screen = NSScreen.screens.first { $0.frame.intersects(rect) } ?? NSScreen.main
    let available = max(0, (screen?.visibleFrame.maxX ?? rect.maxX) - rect.maxX - 8)
    let invert = !hasFollowingText
    let shown = fadingPreview(font: font, ink: NSColor(calibratedWhite: invert ? 1 : 0, alpha: 1))
    while shown.length > 0 && shown.size().width > available {
      shown.deleteCharacters(in: NSRange(location: shown.length - 1, length: 1))
    }
    guard !shown.string.trimmingCharacters(in: .whitespaces).isEmpty else {
      panel?.orderOut(nil); visible = false; return
    }
    visible = true
    let width = ceil(shown.size().width) + 4
    if panel == nil {
      let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
      p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
      p.ignoresMouseEvents = true; p.hidesOnDeactivate = false
      p.level = .popUpMenu; p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
      p.appearance = NSAppearance(named: .aqua)
      panel = p
    }
    let preview = GhostPreviewView(frame: NSRect(x: 0, y: 0, width: width, height: height))
    preview.text = shown
    preview.applyInvertBlend(invert)
    panel?.contentView = preview
    panel?.appearance = NSAppearance(named: .aqua)
    panel?.level = NSWindow.Level(rawValue: capturedWindowLevel)
    panel?.backgroundColor = hasFollowingText ? NSColor(calibratedWhite: 1, alpha: 0.94) : .clear
    panel?.setFrame(NSRect(x: rect.maxX, y: hasFollowingText ? rect.minY - height - 2 : rect.minY,
                          width: width, height: height), display: true)
    panel?.orderFrontRegardless()
    if monitor == nil {
      monitor = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self, weak client] _ in
        guard let self else { return }
        if self.pendingTab != nil { return }
        guard let client else { return }
        if self.valid(client) { return }
        if self.capture(client), !self.buffer.queued.isEmpty { self.show(client: client); return }
        if !self.buffer.queued.isEmpty { self.panel?.orderOut(nil); self.visible = false; return }
        self.cancel()
      }
    }
  }

  deinit { reattach?.cancel(); tabConfirmation?.cancel(); fillDelay?.cancel(); appearTimer?.invalidate(); activityMonitor?.invalidate(); stream?.cancel(); request?.cancel(); work?.cancel(); monitor?.invalidate(); panel?.orderOut(nil) }
}
