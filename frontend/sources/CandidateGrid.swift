import AppKit

struct GridSelection {
  var column: Int?
  // Digits are one-based, the Rime candidate index is zero-based.
  mutating func digit(_ digit: Int, count: Int) -> Int? {
    guard (1...5).contains(digit) else { return nil }
    guard let column else { self.column = digit; return nil }
    let index = (digit - 1) * 5 + column - 1
    return index < count ? index : nil
  }
}

final class CandidateGrid {
  private var panel: NSPanel?
  private var entries: [String] = []
  private var selection = GridSelection()
  private var choose: ((Int) -> Void)?
  private var inputRect = NSRect.zero
  var isVisible: Bool { panel?.isVisible == true }
  var hasColumn: Bool { selection.column != nil }

  func open(entries: [String], at rect: NSRect, choose: @escaping (Int) -> Void) {
    self.entries = Array(entries.prefix(25)); self.choose = choose; inputRect = rect
    selection = GridSelection()
    render()
  }
  func close() { panel?.orderOut(nil); entries = []; selection = GridSelection(); choose = nil }
  func back() { selection.column = nil; render() }
  func digit(_ digit: Int) {
    let hadColumn = selection.column != nil
    if let index = selection.digit(digit, count: entries.count) { choose?(index) }
    else { if hadColumn { NSSound.beep() }; render() }
  }
  private func render() {
    guard !entries.isEmpty else { return }
    let screen = NSScreen.screens.first { $0.frame.intersects(inputRect) } ?? NSScreen.main
    let screenRect = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 700)
    let padding: CGFloat = 8
    let columnGap: CGFloat = 4
    let rowGap: CGFloat = 3
    let textFont = NSFont.systemFont(ofSize: 16)
    let widestText = entries.map { ($0 as NSString).size(withAttributes: [.font: textFont]).width }.max() ?? 0
    let preferredCellWidth = min(116, max(100, ceil(widestText) + 38))
    let width = min(5 * preferredCellWidth + 2 * padding + 4 * columnGap, screenRect.width - 16)
    let cellWidth = (width - 2 * padding - 4 * columnGap) / 5
    let cellHeight: CGFloat = 36
    let height = 5 * cellHeight + 2 * padding + 4 * rowGap
    if panel == nil {
      let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
      p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true
      p.level = .init(Int(CGShieldingWindowLevel()))
      p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
      panel = p
    }
    let root = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
    root.material = .popover; root.blendingMode = .behindWindow; root.state = .active
    root.wantsLayer = true; root.layer?.cornerRadius = 8
    for index in 0..<25 {
      let row = index / 5 + 1, col = index % 5 + 1
      let cell = GridCell(frame: NSRect(x: padding + CGFloat(col - 1) * (cellWidth + columnGap),
         y: padding + CGFloat(5 - row) * (cellHeight + rowGap), width: cellWidth, height: cellHeight))
      cell.text = index < entries.count ? entries[index] : "—"
      cell.coordinate = "\(col)\(row)"
      cell.active = selection.column == nil || selection.column == col
      cell.highlighted = selection.column == col
      cell.available = index < entries.count
      cell.toolTip = index < entries.count ? "1\(col)\(row) · \(entries[index])" : nil
      cell.click = { [weak self] in guard let self, index < self.entries.count else { return }; self.choose?(index) }
      root.addSubview(cell)
    }
    panel?.contentView = root
    let x = min(max(inputRect.minX, screenRect.minX + 8), screenRect.maxX - width - 8)
    let below = inputRect.minY - height - 8
    let y = below >= screenRect.minY ? below : min(inputRect.maxY + 8, screenRect.maxY - height - 8)
    panel?.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    panel?.orderFrontRegardless()
  }
}

private final class GridCell: NSView {
  var text = ""
  var coordinate = ""
  var active = true
  var highlighted = false
  var available = true
  var click: (() -> Void)?
  override func draw(_ dirtyRect: NSRect) {
    let background = highlighted && available ? NSColor.controlAccentColor.withAlphaComponent(0.16) : NSColor.quaternaryLabelColor.withAlphaComponent(0.06)
    background.setFill(); NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
    let para = NSMutableParagraphStyle(); para.lineBreakMode = .byTruncatingTail
    let color: NSColor = available ? (active ? .labelColor : .secondaryLabelColor) : .tertiaryLabelColor
    (coordinate as NSString).draw(in: NSRect(x: 6, y: (bounds.height - 15) / 2, width: 20, height: 15), withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor])
    (text as NSString).draw(in: NSRect(x: 31, y: (bounds.height - 21) / 2, width: bounds.width - 37, height: 21), withAttributes: [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: color, .paragraphStyle: para])
  }
  override func mouseDown(with event: NSEvent) { if available { click?() } }
  override func isAccessibilityElement() -> Bool { true }
  override func accessibilityRole() -> NSAccessibility.Role? { .button }
  override func accessibilityLabel() -> String? { "\(coordinate) \(text)" }
  override func accessibilityPerformPress() -> Bool { guard available else { return false }; click?(); return true }
}
