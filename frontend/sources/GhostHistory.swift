import Foundation

/// Process-local selection history. All calls belong on the input controller's main thread.
final class GhostHistory {
  typealias Receipt = UUID
  static let shared = GhostHistory()

  private struct Entry {
    let receipt: Receipt
    var text: String
  }

  private let capacity: Int
  private var entries: [Entry] = []

  init(capacity: Int = 128) {
    precondition((1...128).contains(capacity))
    self.capacity = capacity
  }

  var texts: [String] { entries.map(\.text) }

  func text(for receipt: Receipt) -> String? {
    entries.first { $0.receipt == receipt }?.text
  }

  /// A document-range proof may remove an interior part of a selection, not just its tail.
  @discardableResult
  func revise(_ receipt: Receipt, expected: String, replacement: String) -> Bool {
    guard let index = entries.firstIndex(where: { $0.receipt == receipt }),
          entries[index].text.utf16.elementsEqual(expected.utf16) else { return false }
    if replacement.isEmpty { entries.remove(at: index) }
    else { entries[index].text = replacement }
    return true
  }

  @discardableResult
  func append(_ text: String) -> Receipt? {
    guard !text.isEmpty else { return nil }
    let receipt = Receipt()
    entries.append(Entry(receipt: receipt, text: text))
    if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
    return receipt
  }

  /// Withdraw an observed document deletion from the given consecutive input receipts.
  /// Receipts must be ordered oldest first and bound to the same input session by the caller.
  /// Returns the remaining receipts, or nil without changing anything if the suffix does not
  /// exactly match. Missing receipts are allowed only at the front after ring eviction.
  /// Entries outside this receipt chain are never inspected for a text match or modified.
  func rewind(receipts: [Receipt], deletedSuffix: String) -> [Receipt]? {
    guard !receipts.isEmpty, !deletedSuffix.isEmpty,
          Set(receipts).count == receipts.count else { return nil }

    let locations = Dictionary(uniqueKeysWithValues: entries.enumerated().map {
      ($0.element.receipt, $0.offset)
    })
    var indices: [Int] = []
    for receipt in receipts {
      guard let index = locations[receipt] else {
        if !indices.isEmpty { return nil }
        continue
      }
      if let previous = indices.last, index != previous + 1 { return nil }
      indices.append(index)
    }
    guard !indices.isEmpty else { return nil }

    // Scalars preserve the exact observed text even when one grapheme spans two commits
    // or the application deletes only a combining mark / part of an emoji sequence.
    let deleted = Array(deletedSuffix.unicodeScalars)
    var remaining = deleted.count
    var changes: [(index: Int, text: String)] = []
    for index in indices.reversed() {
      let original = Array(entries[index].text.unicodeScalars)
      let count = min(original.count, remaining)
      guard original.suffix(count).elementsEqual(deleted[(remaining - count)..<remaining]) else {
        return nil
      }
      let retained = original.dropLast(count)
      changes.append((index, String(String.UnicodeScalarView(retained))))
      remaining -= count
      if remaining == 0 { break }
    }
    guard remaining == 0 else { return nil }

    // Descending indices keep subsequent edits valid when entire entries are removed.
    for change in changes {
      if change.text.isEmpty { entries.remove(at: change.index) }
      else { entries[change.index].text = change.text }
    }
    let live = Set(entries.map(\.receipt))
    return receipts.filter { live.contains($0) }
  }
}

/// Bounded, process-local provenance for selections in one active input client.
/// Coordinates are UTF-16 document offsets, matching InputMethodKit. The caller must
/// reset when the input client/field changes; matching text is never a field identity.
final class GhostDocumentHistory {
  struct Snapshot {
    let start: Int
    let text: String
    let documentLength: Int
    let selection: NSRange
    var end: Int { start + text.utf16.count }

    func substring(_ range: NSRange) -> String? {
      guard range.location >= start, range.length >= 0,
            range.location <= end, range.length <= end - range.location else { return nil }
      let units = Array(text.utf16)
      let selected = units[(range.location - start)..<(range.location - start + range.length)]
      let result = String(decoding: selected, as: UTF16.self)
      return result.utf16.elementsEqual(selected) ? result : nil
    }
  }

  enum Action { case backward, forward, replace }
  private struct Expectation { let action: Action; let selection: NSRange }
  private struct Span {
    let receipt: GhostHistory.Receipt
    let range: NSRange
    let text: String
    var end: Int { range.location + range.length }
  }
  private struct Edit { let removed: NSRange; let inserted: String }
  private(set) var snapshot: Snapshot?
  private var spans: [Span] = []
  private var expected: Expectation?
  var hasSnapshot: Bool { snapshot != nil }
  var hasTrackedSelections: Bool { !spans.isEmpty }

  func reset(_ snapshot: Snapshot? = nil) {
    self.snapshot = snapshot; spans = []; expected = nil
  }

  func expect(_ action: Action?, selection: NSRange) {
    expected = action.map { Expectation(action: $0, selection: selection) }
  }

  @discardableResult
  func remember(_ receipt: GhostHistory.Receipt, text: String, at range: NSRange,
                snapshot: Snapshot) -> Bool {
    guard snapshot.substring(range)?.utf16.elementsEqual(text.utf16) == true else { return false }
    self.snapshot = snapshot
    spans.append(Span(receipt: receipt, range: range, text: text))
    prune(to: snapshot)
    return true
  }

  /// Returns true whenever observed text changed, including an ambiguous edit whose
  /// provenance must be discarded. The caller must invalidate model tokens in either case.
  @discardableResult
  func observe(_ after: Snapshot, history: GhostHistory) -> Bool {
    guard let before = snapshot else { snapshot = after; return false }
    defer { snapshot = after }
    let overlapStart = max(before.start, after.start)
    let overlapEnd = min(before.end, after.end)
    let overlap = NSRange(location: overlapStart, length: max(0, overlapEnd - overlapStart))
    let equal = before.documentLength == after.documentLength && overlapEnd >= overlapStart
      && before.substring(overlap)?.utf16.elementsEqual(after.substring(overlap)?.utf16 ?? "".utf16) == true
    if equal {
      if before.selection != after.selection { expected = nil }
      prune(to: after)
      return false
    }

    // A shared IMK proxy may now refer to a different field. With no observed
    // editing key, simultaneous selection and text changes cannot prove deletion.
    if expected == nil, before.selection != after.selection {
      spans = []; expected = nil
      return true
    }

    let delta = after.documentLength - before.documentLength
    var edit: Edit?
    if let expected {
      var removed = expected.selection
      if removed.length == 0 {
        switch expected.action {
        case .backward:
          if delta < 0, -delta <= removed.location {
            removed = NSRange(location: removed.location + delta, length: -delta)
          }
        case .forward:
          if delta < 0 { removed.length = -delta }
        case .replace: break
        }
      }
      let insertedLength = removed.length + delta
      if insertedLength >= 0,
         let inserted = after.substring(NSRange(location: removed.location, length: insertedLength)) {
        let candidate = Edit(removed: removed, inserted: inserted)
        if verifies(candidate, before: before, after: after) { edit = candidate }
      }
    }
    if edit == nil { edit = uniqueDifference(before: before, after: after) }
    expected = nil
    guard let edit else { spans = []; return true }

    let old = spans
    var revised: [Span] = []
    let cutStart = edit.removed.location
    let cutEnd = cutStart + edit.removed.length
    for span in old {
      let leftCount = max(0, min(span.end, cutStart) - span.range.location)
      let rightStart = max(span.range.location, cutEnd)
      let rightCount = max(0, span.end - rightStart)
      let units = Array(span.text.utf16)
      if leftCount > 0 {
        revised.append(Span(receipt: span.receipt,
          range: NSRange(location: span.range.location, length: leftCount),
          text: String(decoding: units.prefix(leftCount), as: UTF16.self)))
      }
      if rightCount > 0 {
        revised.append(Span(receipt: span.receipt,
          range: NSRange(location: rightStart + delta, length: rightCount),
          text: String(decoding: units.suffix(rightCount), as: UTF16.self)))
      }
    }
    let receipts = Set(old.map(\.receipt))
    for receipt in receipts {
      let original = old.filter { $0.receipt == receipt }.map(\.text).joined()
      let replacement = revised.filter { $0.receipt == receipt }.map(\.text).joined()
      if !history.revise(receipt, expected: original, replacement: replacement) {
        revised.removeAll { $0.receipt == receipt }
      }
    }
    spans = revised
    prune(to: after)
    return true
  }

  private func prune(to snapshot: Snapshot) {
    let outside = Set(spans.filter {
      $0.range.location < snapshot.start || $0.end > snapshot.end
    }.map(\.receipt))
    spans.removeAll { outside.contains($0.receipt) }
    // Interior insertions may split a receipt into fragments; bound that metadata too.
    if spans.count > 512 { spans = [] }
  }

  private func verifies(_ edit: Edit, before: Snapshot, after: Snapshot) -> Bool {
    let start = edit.removed.location, end = start + edit.removed.length
    let delta = edit.inserted.utf16.count - edit.removed.length
    guard start >= 0, end <= before.documentLength,
          before.documentLength + delta == after.documentLength,
          before.substring(edit.removed) != nil,
          after.substring(NSRange(location: start, length: edit.inserted.utf16.count))?
            .utf16.elementsEqual(edit.inserted.utf16) == true else { return false }
    let leftStart = max(before.start, after.start)
    let leftEnd = min(start, min(before.end, after.end))
    if leftEnd > leftStart {
      let range = NSRange(location: leftStart, length: leftEnd - leftStart)
      guard before.substring(range)?.utf16.elementsEqual(after.substring(range)?.utf16 ?? "".utf16) == true else { return false }
    }
    let rightStart = max(end, max(before.start, after.start - delta))
    let rightEnd = min(before.end, after.end - delta)
    if rightEnd > rightStart {
      let old = NSRange(location: rightStart, length: rightEnd - rightStart)
      let new = NSRange(location: rightStart + delta, length: old.length)
      guard before.substring(old)?.utf16.elementsEqual(after.substring(new)?.utf16 ?? "".utf16) == true else { return false }
    }
    return true
  }

  private func uniqueDifference(before: Snapshot, after: Snapshot) -> Edit? {
    let delta = after.documentLength - before.documentLength
    let start = max(before.start, after.start)
    let oldEnd = min(before.end, after.end - delta)
    guard oldEnd >= start, oldEnd + delta >= start,
          let oldText = before.substring(NSRange(location: start, length: oldEnd - start)),
          let newText = after.substring(NSRange(location: start, length: oldEnd + delta - start)) else { return nil }
    let old = Array(oldText.utf16), new = Array(newText.utf16)
    var left = 0, right = 0
    while left < min(old.count, new.count), old[left] == new[left] { left += 1 }
    while right < min(old.count, new.count), old[old.count - 1 - right] == new[new.count - 1 - right] { right += 1 }
    // Repeated characters permit more than one deletion position. Only an observed
    // keyboard selection can disambiguate them; never pick one by text similarity.
    guard left + right <= min(old.count, new.count) else { return nil }
    let removed = NSRange(location: start + left, length: old.count - left - right)
    let insertedUnits = new[left..<(new.count - right)]
    let inserted = String(decoding: insertedUnits, as: UTF16.self)
    guard inserted.utf16.elementsEqual(insertedUnits),
          removed.location > start || start == 0,
          removed.location + removed.length < oldEnd || oldEnd == before.documentLength else { return nil }
    let edit = Edit(removed: removed, inserted: inserted)
    return verifies(edit, before: before, after: after) ? edit : nil
  }
}
