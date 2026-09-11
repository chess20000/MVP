// Test doubles only: no input events, windows, accessibility calls or HTTP requests.
import AppKit
protocol IMKTextInput: AnyObject {
  func selectedRange() -> NSRange
  func markedRange() -> NSRange
  func length() -> Int
  func bundleIdentifier() -> String?
  func string(from: NSRange, actualRange: UnsafeMutablePointer<NSRange>) -> String?
  func attributedSubstring(from: NSRange) -> NSAttributedString?
  func attributes(forCharacterIndex: Int, lineHeightRectangle: UnsafeMutablePointer<NSRect>) -> [String: Any]
  func firstRect(forCharacterRange: NSRange, actualRange: UnsafeMutablePointer<NSRange>) -> NSRect
  func windowLevel() -> Int
  func insertText(_ text: String, replacementRange: NSRange)
}
func IsSecureEventInputEnabled() -> Bool { false }
enum SquirrelApp { static let userDir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GHOST_TEST_USER_DIR"]!) }
enum GhostFocus { static func matches(app: String, caret: () -> NSRect) -> Bool { true } }
enum GhostDiagnostics { static func record(app: String, reason: String, fields: [String: Any] = [:]) {} }
enum Probe {
  static var requests: [Int] = []
  static var bodies: [[String: Any]] = []
  static var complete: (([String: Any]) -> Void)?
  static var shows = 0
}
final class FakeClient: IMKTextInput {
  var text: String
  var caret: Int
  var rectangleReady = true
  var textReadable = true
  var rectangleOffsetX = 0
  var rectangleOffsetY = 0
  init(_ text: String, _ caret: Int) { self.text = text; self.caret = caret }
  func selectedRange() -> NSRange { NSRange(location: caret, length: 0) }
  var marked = NSRange(location: NSNotFound, length: 0)
  func markedRange() -> NSRange { marked }
  func length() -> Int { text.utf16.count }
  func bundleIdentifier() -> String? { "test.fake" }
  func string(from range: NSRange, actualRange: UnsafeMutablePointer<NSRange>) -> String? {
    guard textReadable, range.location <= length() else { return nil }
    let count = min(range.length, length() - range.location)
    actualRange.pointee = NSRange(location: range.location, length: count)
    return (text as NSString).substring(with: actualRange.pointee)
  }
  func attributedSubstring(from range: NSRange) -> NSAttributedString? {
    guard textReadable, range.location + range.length <= length() else { return nil }
    return NSAttributedString(string: (text as NSString).substring(with: range))
  }
  func attributes(forCharacterIndex: Int, lineHeightRectangle: UnsafeMutablePointer<NSRect>) -> [String: Any] {
    lineHeightRectangle.pointee = rectangleReady ? NSRect(x: caret * 8 + rectangleOffsetX, y: 100 + rectangleOffsetY, width: 1, height: 16) : .zero
    return [:]
  }
  func firstRect(forCharacterRange: NSRange, actualRange: UnsafeMutablePointer<NSRange>) -> NSRect { .zero }
  func windowLevel() -> Int { 0 }
  // Deliberately leaves cached text and selection unchanged until a test publishes an update.
  func insertText(_ text: String, replacementRange: NSRange) {}
}
